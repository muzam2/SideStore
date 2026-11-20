//
//  ForegroundRefreshManager.swift
//  SideStore
//
//  Renews app signatures whenever SideStore comes to the foreground.
//
//  Nothing else in the app starts a refresh on its own: the legacy background fetch is
//  never scheduled (no minimum fetch interval is set), no BGTaskScheduler task is
//  registered, the widget is stripped from the Vision Pro build and the Shortcuts intent
//  only runs when the user set up an automation. A refresh also needs the device
//  connection (pairing + LocalDevVPN) and the network, which a suspended app does not
//  get. So renewal is tied to the one moment the app is guaranteed to run with all of
//  that available: when it is opened.
//

@preconcurrency import UIKit
import Combine
import CoreData
import UserNotifications
import Minimuxer

final class ForegroundRefreshManager: @unchecked Sendable {
    static let shared = ForegroundRefreshManager()

    /// Apps whose signature expires within this window are renewed. Free profiles last
    /// 7 days, so 6 days means: at most one automatic renewal a day, and every visit to
    /// SideStore puts all apps back to a full week.
    static let renewalWindow: TimeInterval = 6 * 24 * 60 * 60

    /// Pause after an attempt that reached Apple or the device and failed there (also keeps
    /// the failure toast from reappearing every time the window is activated).
    static let failureRetryInterval: TimeInterval = 5 * 60

    /// Pause after an attempt that could not start (no VPN / device connection yet, another
    /// operation running). Short, because the usual reaction is to switch LocalDevVPN on and
    /// come straight back.
    static let connectionRetryInterval: TimeInterval = 15

    /// Pause after a successful renewal. With `renewalWindow` nothing is due again for a day
    /// anyway; this only stops a renew-on-every-activation loop should a renewal ever come
    /// back without a later expiry date.
    static let renewedInterval: TimeInterval = 6 * 60 * 60

    static let databaseTimeout: TimeInterval = 60
    static let idleTimeout: TimeInterval = 3 * 60
    static let connectionTimeout: TimeInterval = 45
    static let refreshTimeout: TimeInterval = 5 * 60

    static let reminderNotificationID = "sidestore-renewal-reminder"

    private struct ExpirySummary: Sendable {
        let appName: String
        let expirationDate: Date
        let isSideStore: Bool
    }

    private enum Outcome: Sendable {
        case nothingDue
        case skipped(String)
        case renewed(count: Int)
        /// The device connection (pairing, LocalDevVPN, Wi-Fi) was not usable; nothing was attempted.
        case notConnected(Error, attempted: Int)
        case failed(Error, attempted: Int)
    }

    private final class ContinuationBox: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<[String: Result<InstalledApp, Error>], Error>?

        init(_ continuation: CheckedContinuation<[String: Result<InstalledApp, Error>], Error>) {
            self.continuation = continuation
        }

        func resume(with result: Result<[String: Result<InstalledApp, Error>], Error>) {
            let pending = self.lock.withLock { () -> CheckedContinuation<[String: Result<InstalledApp, Error>], Error>? in
                defer { self.continuation = nil }
                return self.continuation
            }
            pending?.resume(with: result)
        }
    }

    private let lock = NSLock()
    private var isRunning = false
    private var nextAttemptNotBefore: Date?

    /// Set after an attempt that failed for lack of a device connection, so the renewal can
    /// start as soon as the connection comes up (see `observeDeviceConnection`).
    private var isWaitingForConnection = false
    private var isObservingConnection = false

    /// Managed objects do not retain their context, so the context the apps were fetched in
    /// is held here. It is only replaced by the next run, never cleared, because a refresh
    /// that outlives `refreshTimeout` may still be using the objects.
    private var activeContext: NSManagedObjectContext?

    private init() {}

    /// Called from `SceneDelegate.sceneDidBecomeActive` (cold launch and every return to the app).
    func sceneDidBecomeActive() {
        self.start()
    }

    private func start(ignoringPause: Bool = false) {
        let shouldStart = self.lock.withLock { () -> Bool in
            guard !self.isRunning else { return false }
            if !ignoringPause, let notBefore = self.nextAttemptNotBefore, Date() < notBefore {
                return false
            }
            self.isRunning = true
            return true
        }
        guard shouldStart else { return }

        Task.detached(priority: .utility) {
            let outcome = await self.renewIfNeeded()

            let shouldObserveConnection = self.lock.withLock { () -> Bool in
                self.isRunning = false
                self.isWaitingForConnection = false

                switch outcome {
                case .nothingDue:
                    self.nextAttemptNotBefore = nil
                case .renewed:
                    self.nextAttemptNotBefore = Date().addingTimeInterval(Self.renewedInterval)
                case .skipped:
                    self.nextAttemptNotBefore = Date().addingTimeInterval(Self.connectionRetryInterval)
                case .failed:
                    self.nextAttemptNotBefore = Date().addingTimeInterval(Self.failureRetryInterval)
                case .notConnected:
                    self.nextAttemptNotBefore = Date().addingTimeInterval(Self.connectionRetryInterval)
                    self.isWaitingForConnection = true

                    // Start listening for the connection the first time it is found missing.
                    guard !self.isObservingConnection else { return false }
                    self.isObservingConnection = true
                    return true
                }
                return false
            }

            if shouldObserveConnection {
                self.observeDeviceConnection()
            }

            // Leave the reminders that are already scheduled alone if the database never came up.
            if DatabaseManager.shared.isStarted {
                let summary = await self.soonestExpiry()
                await self.scheduleRenewalReminders(for: summary)
                await self.report(outcome, soonest: summary)
            } else {
                await self.report(outcome, soonest: nil)
            }
        }
    }

    /// On a Vision Pro the SideStore window can stay active while LocalDevVPN is switched on
    /// in another window, so there may be no further `sceneDidBecomeActive` to retry from.
    /// minimuxer publishes its status on every network change; when the connection becomes
    /// usable after an attempt that failed for lack of it, try again right away.
    /// needs proper testing on a Vision Pro: not known whether the tunnel coming up is
    /// reported as a network change there. Reopening SideStore retries either way.
    private func observeDeviceConnection() {
        Task.detached(priority: .utility) {
            for await _ in minimuxerStatusPublisher.values {
                let isWaiting = self.lock.withLock { self.isWaitingForConnection }
                guard isWaiting else { continue }

                guard case .success = await isMinimuxerReady() else { continue }
                guard await Self.isApplicationActive() else { continue }

                debugLog("[ForegroundRefreshManager] Device connection is back. Retrying renewal...")
                self.start(ignoringPause: true)
            }
        }
    }

    @MainActor
    private static func isApplicationActive() -> Bool {
        return UIApplication.shared.applicationState == .active
    }

    // MARK: - Renewal

    private func renewIfNeeded() async -> Outcome {
        guard UserDefaults.standard.isBackgroundRefreshEnabled else {
            return .skipped("automatic refresh is turned off in Settings")
        }

        guard await self.waitForDatabase() else {
            return .skipped("database did not start in time")
        }

        guard AuthManager.shared.isAuthenticated, (try? await AuthManager.shared.getAuthenticatedTeam()) != nil else {
            return .skipped("not signed in")
        }

        let context = DatabaseManager.shared.persistentContainer.newBackgroundContext()
        self.lock.withLock { self.activeContext = context }
        let dueApps = await context.perform { () -> [InstalledApp] in
            let deadline = Date().addingTimeInterval(Self.renewalWindow)
            // Sorted by expiration date, SideStore itself last (same order "Refresh All" uses).
            return InstalledApp.fetchAppsForRefreshingAll(in: context).filter { $0.expirationDate < deadline }
        }

        guard !dueApps.isEmpty else { return .nothingDue }
        debugLog("[ForegroundRefreshManager] \(dueApps.count) app(s) expire within \(Int(Self.renewalWindow / 86400)) days. Renewing...")

        // The user (or an import) may already be installing/refreshing; let that finish first.
        let idleDeadline = Date().addingTimeInterval(Self.idleTimeout)
        while AppManager.shared.isActivelyManagingAnyApp {
            guard Date() < idleDeadline else {
                return .skipped("another app operation is still in progress")
            }
            try? await Task.sleep(nanoseconds: 5_000_000_000)
        }

        // minimuxer is started asynchronously at boot, so give the device connection a moment.
        if let error = await self.waitForDeviceConnection() {
            return .notConnected(error, attempted: dueApps.count)
        }

        do {
            let results = try await self.refresh(dueApps)
            let failure = results.values.compactMap { result -> Error? in
                guard case .failure(let error) = result else { return nil }
                return error
            }.first

            if let failure {
                return Self.outcome(for: failure, attempted: dueApps.count)
            }
            // Apps that report themselves as running are left out by the operation.
            guard !results.isEmpty else { return .skipped("no app was refreshed") }
            return .renewed(count: results.count)
        } catch {
            return Self.outcome(for: error, attempted: dueApps.count)
        }
    }

    /// A cancelled pipeline (e.g. the same apps are already being refreshed by hand) is not a failure worth a toast.
    private static func outcome(for error: Error, attempted: Int) -> Outcome {
        if error is CancellationError { return .skipped("cancelled") }   // OperationError.cancelled is a CancellationError
        return .failed(error, attempted: attempted)
    }

    private func waitForDatabase() async -> Bool {
        let deadline = Date().addingTimeInterval(Self.databaseTimeout)
        while !DatabaseManager.shared.isStarted {
            guard Date() < deadline else { return false }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return true
    }

    /// Returns nil once the device connection is usable, or the last error after the timeout.
    private func waitForDeviceConnection() async -> Error? {
        let deadline = Date().addingTimeInterval(Self.connectionTimeout)
        while true {
            switch await isMinimuxerReady() {
            case .success:
                return nil
            case .failure(let error):
                guard Date() < deadline else {
                    debugLog("[ForegroundRefreshManager] Device connection not ready: \(error)")
                    return error.asOperationError
                }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    private func refresh(_ apps: [InstalledApp]) async throws -> [String: Result<InstalledApp, Error>] {
        try await withCheckedThrowingContinuation { continuation in
            let box = ContinuationBox(continuation)

            do {
                // Same operation the Shortcuts intent uses; it also records a RefreshAttempt.
                try AppManager.shared.backgroundRefresh(apps, presentsNotifications: false) { result in
                    box.resume(with: result)
                }
            } catch {
                box.resume(with: .failure(error))
            }

            // Never leave the manager stuck in "running" if the operation does not call back.
            Task.detached {
                try? await Task.sleep(nanoseconds: UInt64(Self.refreshTimeout * 1_000_000_000))
                box.resume(with: .failure(OperationError.timedOut))
            }
        }
    }

    // MARK: - Reminders

    private func soonestExpiry() async -> ExpirySummary? {
        guard DatabaseManager.shared.isStarted else { return nil }

        let context = DatabaseManager.shared.persistentContainer.newBackgroundContext()
        return await context.perform { () -> ExpirySummary? in
            guard let app = InstalledApp.fetchAppsForRefreshingAll(in: context).min(by: { $0.expirationDate < $1.expirationDate }) else { return nil }
            return ExpirySummary(appName: app.name,
                                 expirationDate: app.expirationDate,
                                 isSideStore: app.bundleIdentifier == StoreApp.altstoreAppID)
        }
    }

    /// Local notifications ahead of the soonest expiry, so a week without opening SideStore
    /// does not end in silently expired apps. (SideStore's own 24 h / 6 h / 0 h warnings are
    /// scheduled by ScheduleExpirationWarningNotificationOperation.)
    private func scheduleRenewalReminders(for summary: ExpirySummary?) async {
        #if !os(tvOS)
        let milestones: [(id: String, timeBeforeExpiry: TimeInterval, label: String)] = [
            ("72h", 72 * 60 * 60, NSLocalizedString("3 days", comment: "")),
            ("48h", 48 * 60 * 60, NSLocalizedString("2 days", comment: "")),
            ("24h", 24 * 60 * 60, NSLocalizedString("24 hours", comment: ""))
        ]

        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: milestones.map { "\(Self.reminderNotificationID).\($0.id)" })

        guard UserDefaults.standard.isBackgroundRefreshEnabled, let summary else { return }

        for milestone in milestones {
            // SideStore already has its own 24 hour warning.
            if milestone.id == "24h" && summary.isSideStore { continue }

            let triggerInterval = summary.expirationDate.addingTimeInterval(-milestone.timeBeforeExpiry).timeIntervalSinceNow
            guard triggerInterval > 0 else { continue }

            let content = UNMutableNotificationContent()
            content.title = NSLocalizedString("Apps Expiring Soon", comment: "")
            content.body = String(format: NSLocalizedString("%@ expires in %@. Open SideStore to renew your apps.", comment: ""), summary.appName, milestone.label)
            content.sound = .default

            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: triggerInterval, repeats: false)
            let request = UNNotificationRequest(identifier: "\(Self.reminderNotificationID).\(milestone.id)", content: content, trigger: trigger)

            do {
                try await center.add(request)
            } catch {
                debugLog("[ForegroundRefreshManager] Failed to schedule reminder '\(milestone.id)': \(error)")
            }
        }
        #endif
    }

    // MARK: - Feedback

    @MainActor
    private func report(_ outcome: Outcome, soonest: ExpirySummary?) {
        let toastView: ToastView

        switch outcome {
        case .nothingDue:
            debugLog("[ForegroundRefreshManager] Nothing to renew.")
            return

        case .skipped(let reason):
            debugLog("[ForegroundRefreshManager] Skipped automatic renewal: \(reason)")
            return

        case .renewed(let count):
            debugLog("[ForegroundRefreshManager] Renewed \(count) app(s).")
            let text = count == 1 ? NSLocalizedString("Renewed 1 app", comment: "") : String(format: NSLocalizedString("Renewed %@ apps", comment: ""), NSNumber(value: count))
            var detailText: String?
            if let soonest {
                detailText = String(format: NSLocalizedString("Signatures are valid until %@.", comment: ""), Self.dateFormatter.string(from: soonest.expirationDate))
            }
            toastView = ToastView(text: text, detailText: detailText)

        case .notConnected(let error, let attempted), .failed(let error, let attempted):
            debugLog("[ForegroundRefreshManager] Automatic renewal of \(attempted) app(s) failed: \(error)")
            var detailText = error.localizedDescription
            if let soonest {
                let format = soonest.expirationDate > Date() ? NSLocalizedString("%@ expires %@.", comment: "") : NSLocalizedString("%@ expired %@.", comment: "")
                detailText += " " + String(format: format, soonest.appName, Self.dateFormatter.string(from: soonest.expirationDate))
            }
            toastView = ToastView(text: NSLocalizedString("Could not renew apps automatically", comment: ""), detailText: detailText, opensLog: true)
            toastView.preferredDuration = .longToastViewDuration
        }

        // needs proper testing on a Vision Pro: the toast is the only on-screen sign that a renewal ran.
        guard let viewController = UIApplication.shared.topViewController() else { return }
        toastView.show(in: viewController)
    }

    private static let dateFormatter: DateFormatter = {
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .short
        return dateFormatter
    }()
}
