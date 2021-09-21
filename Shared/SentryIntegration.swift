/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Foundation
import Sentry

public enum SentryTag: String {
    case swiftData = "SwiftData"
    case browserDB = "BrowserDB"
    case rustPlaces = "RustPlaces"
    case rustLogins = "RustLogins"
    case rustLog = "RustLog"
    case notificationService = "NotificationService"
    case unifiedTelemetry = "UnifiedTelemetry"
    case general = "General"
    case tabManager = "TabManager"
    case bookmarks = "Bookmarks"
    case nimbus = "Nimbus"
}

// For compatibility within Firefox-iOS, we replicate SentrySeverity as mapping of SentryLevel
public enum SentrySeverity: UInt {
    case none = 0, debug = 1, info = 2, warning = 3, error = 4, fatal = 5
    
    var level: SentryLevel {
        SentryLevel(rawValue: self.rawValue) ?? .none
    }
}

public class Sentry {
    public static let shared = Sentry()

    public static var crashedLastLaunch: Bool {
        return SentrySDK.crashedLastRun
    }

    private let SendEventError = NSError(domain: "mozilla", code: 0, userInfo: [NSLocalizedDescriptionKey: "Could not send sentry event"])
    private let SentryDSNKey = "SentryDSN"
    private let SentryDeviceAppHashKey = "SentryDeviceAppHash"
    private let DefaultDeviceAppHash = "0000000000000000000000000000000000000000"
    private let DeviceAppHashLength = UInt(20)

    private var enabled = false

    private var attributes: [String: Any] = [:]

    public func setup(sendUsageData: Bool) {
        assert(!enabled, "Sentry.setup() should only be called once")

        if DeviceInfo.isSimulator() {
            Logger.browserLogger.debug("Not enabling Sentry; Running in Simulator")
            return
        }

        if !sendUsageData {
            Logger.browserLogger.debug("Not enabling Sentry; Not enabled by user choice")
            return
        }

        var bundle = Bundle.main
        if bundle.bundleURL.pathExtension == "appex" {
            // Peel off two directory levels - MY_APP.app/PlugIns/MY_APP_EXTENSION.appex
            let url = bundle.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
            if let extensionBundle = Bundle(url: url) {
                bundle = extensionBundle
            }
        }

        guard let dsn = bundle.object(forInfoDictionaryKey: SentryDSNKey) as? String, !dsn.isEmpty else {
            Logger.browserLogger.debug("Not enabling Sentry; Not configured in Info.plist")
            return
        }

        Logger.browserLogger.debug("Enabling Sentry crash handler")

        SentrySDK.start { options in
            options.dsn = dsn

            // For all outgoing reports, override the default device identifier with our own random
            // version. Default to a blank (zero) identifier in case of errors.
            options.beforeSend = { event in
                let deviceAppHash = UserDefaults(suiteName: AppInfo.sharedContainerIdentifier)?.string(forKey: self.SentryDeviceAppHashKey)
                event.context?["app"]?["device_app_hash"] = deviceAppHash ?? self.DefaultDeviceAppHash

                var attributes = event.extra ?? [:]
                attributes.merge(with: self.attributes)
                event.extra = attributes
                return event
            }
            options.onCrashedLastRun = { event in
                SentrySDK.capture(event: event)
            }
            #if DEBUG
            options.debug = true
            options.diagnosticLevel = SentryLevel.debug
            #endif
        }
        enabled = true

        // If we have not already for this install, generate a completely random identifier
        // for this device. It is stored in the app group so that the same value will
        // be used for both the main application and the app extensions.
        if let defaults = UserDefaults(suiteName: AppInfo.sharedContainerIdentifier), defaults.string(forKey: SentryDeviceAppHashKey) == nil {
            defaults.set(Bytes.generateRandomBytes(DeviceAppHashLength).hexEncodedString, forKey: SentryDeviceAppHashKey)
        }

        // Ignore SIGPIPE exceptions globally.
        // https://stackoverflow.com/questions/108183/how-to-prevent-sigpipes-or-handle-them-properly
        signal(SIGPIPE, SIG_IGN)
    }

    public func crash() {
        SentrySDK.crash()
    }

    /*
         This is the behaviour we want for Sentry logging
                   .info .error .severe
         Debug      y      y       y
         Beta       y      y       y
         Relase     n      n       y
     */
    private func shouldNotSendEventFor(_ severity: SentryLevel) -> Bool {
        return !enabled || (AppConstants.BuildChannel == .release && severity != .fatal)
    }

    private func makeEvent(message: String, tag: String, severity: SentrySeverity, extra: [String: Any]?) -> Event {
        let event = Event(level: severity.level)
        event.message = SentryMessage(formatted: message)
        event.tags = ["tag": tag]
        if let extra = extra {
            event.extra = extra
        }
        return event
    }

    public func send(message: String, tag: SentryTag = .general, severity: SentrySeverity = .info, extra: [String: Any]? = nil, description: String? = nil, completion: SentryRequestFinished? = nil) {
        // Build the dictionary
        var extraEvents: [String: Any] = [:]
        if let paramEvents = extra {
            extraEvents.merge(with: paramEvents)
        }
        if let extraString = description {
            extraEvents.merge(with: ["errorDescription": extraString])
        }
        printMessage(message: message, extra: extraEvents)

        // Only report fatal errors on release
        if shouldNotSendEventFor(severity.level) {
            completion?(nil)
            return
        }

        let event = makeEvent(message: message, tag: tag.rawValue, severity: severity, extra: extraEvents)
        let id = SentrySDK.capture(event: event)
        completion?(id == SentryId.empty ? SendEventError : nil)
    }

    public func sendWithStacktrace(message: String, tag: SentryTag = .general, severity: SentrySeverity = .info, extra: [String: Any]? = nil, description: String? = nil, completion: SentryRequestFinished? = nil) {
        var extraEvents: [String: Any] = [:]
        if let paramEvents = extra {
            extraEvents.merge(with: paramEvents)
        }
        if let extraString = description {
            extraEvents.merge(with: ["errorDescription": extraString])
        }
        printMessage(message: message, extra: extraEvents)

        // Do not send messages to Sentry if disabled OR if we are not on beta and the severity isnt severe
        if shouldNotSendEventFor(severity.level) {
            completion?(nil)
            return
        }
        
        let event = self.makeEvent(message: message, tag: tag.rawValue, severity: severity, extra: extraEvents)
        let id = SentrySDK.capture(event: event)
        completion?(id == SentryId.empty ? SendEventError : nil)
    }

    public func addAttributes(_ attributes: [String: Any]) {
        self.attributes.merge(with: attributes)
    }

    public func breadcrumb(category: String, message: String) {
        let b = Breadcrumb(level: .info, category: category)
        b.message = message
        SentrySDK.addBreadcrumb(crumb: b)
    }

    public func clearBreadcrumbs() {
        SentrySDK.configureScope { scope in
            scope.clearBreadcrumbs()
        }
    }

    private func printMessage(message: String, extra: [String: Any]? = nil) {
        let string = extra?.reduce("") { (result: String, arg1) in
            let (key, value) = arg1
            return "\(result), \(key): \(value)"
        }
        Logger.browserLogger.debug("Sentry: \(message) \(string ??? "")")
    }
}
