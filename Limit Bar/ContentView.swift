//
//  ContentView.swift
//  Limit Bar
//
//  Created by Artem Svitelskyi on 13.05.2026.
//

import SwiftUI
import Combine
import Foundation
import AppKit
import ServiceManagement
import CoreServices
import UserNotifications

struct ServiceLimit: Identifiable, Codable, Equatable {
    let id: LimitService
    var state: ConnectionState
    var current: LimitBalance?
    var weekly: LimitBalance?
    var credits: CreditBalance?
    var accountEmail: String?
    var planName: String?
    var lastUpdated: Date?
    var errorMessage: String?
    /// When a refresh was last attempted, successful or not.
    var lastAttemptAt: Date?
    /// Set when a background refresh failed. Kept separate from `.failed` state so the
    /// last good numbers stay on screen, labelled, instead of the row going blank.
    var lastAttemptFailed: Bool?

    var isConnected: Bool { state == .connected }
    var isConnecting: Bool { state == .connecting }

    var isShowingStaleData: Bool {
        isConnected && (lastAttemptFailed ?? false)
    }
}

struct LimitBalance: Codable, Equatable {
    var title: String
    var remainingPercent: Int
    var resetsAt: Date
    /// The CLI gave no reset time, so `resetsAt` is only a guess of when the window
    /// would end. Claude prints none for a session that has not started yet.
    var isResetEstimated: Bool? = nil

    var hasKnownReset: Bool { !(isResetEstimated ?? false) }

    /// An untouched window has not started its clock; anything else without a reset
    /// time is simply not reported.
    static func unknownResetText(for balance: LimitBalance) -> String {
        balance.remainingPercent >= 100 ? "Idle · starts on next use" : "Reset time unavailable"
    }
    var usedPercent: Int { max(100 - remainingPercent, 0) }
}

struct CreditBalance: Codable, Equatable {
    var remaining: String
    var hasCredits: Bool
    var unlimited: Bool
}

enum ConnectionState: String, Codable, Equatable {
    case disconnected
    case connecting
    case connected
    case failed
}

enum LimitService: String, CaseIterable, Codable, Identifiable {
    case codex = "Codex"
    case claude = "Claude Code"
    case antigravity = "Antigravity"
    case gemini = "Gemini"

    static let activeCases: [LimitService] = [.codex, .claude, .antigravity]

    var id: String { rawValue }

    var isActiveProvider: Bool {
        Self.activeCases.contains(self)
    }

    var assetName: String {
        switch self {
        case .codex: return "CodexIcon"
        case .claude: return "ClaudeCodeIcon"
        case .antigravity: return "GeminiIcon"
        case .gemini: return "GeminiIcon"
        }
    }

    /// Pure switch over `self`; usable from background contexts such as tooltip text.
    nonisolated var shortName: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude"
        case .antigravity: return "Antigravity"
        case .gemini: return "Gemini"
        }
    }

    var menuBarAbbreviation: String {
        switch self {
        case .claude: return "Cl"
        case .codex: return "Cx"
        case .antigravity: return "Ag"
        case .gemini: return "Ge"
        }
    }

    /// Brand hue for the menu bar marker. Colour alone never carries the meaning - the
    /// tooltip and the popover always name the provider.
    var markerColor: NSColor {
        switch self {
        case .claude: return NSColor(red: 0.85, green: 0.45, blue: 0.32, alpha: 1)
        case .codex: return NSColor(red: 0.45, green: 0.44, blue: 0.95, alpha: 1)
        case .antigravity: return NSColor(red: 0.31, green: 0.66, blue: 0.45, alpha: 1)
        case .gemini: return NSColor(red: 0.36, green: 0.55, blue: 0.92, alpha: 1)
        }
    }
}

struct NotificationPreferences: Codable, Equatable {
    var isEnabled: Bool
    var thresholds: [Int]

    static let `default` = NotificationPreferences(isEnabled: false, thresholds: [50, 25, 10])

    var normalizedThresholds: [Int] {
        thresholds
            .map { min(max($0, 1), 99) }
            .sorted(by: >)
            .reduce(into: [Int]()) { partialResult, value in
                if !partialResult.contains(value) {
                    partialResult.append(value)
                }
            }
    }
}

enum MenuBarDisplayMode: String, Codable, CaseIterable {
    case bars
    case currentPercent
}

@MainActor
final class MenuBarDisplayPreferencesStore: ObservableObject {
    static let shared = MenuBarDisplayPreferencesStore()

    @Published var mode: MenuBarDisplayMode {
        didSet { save() }
    }

    private let storageKey = "limit-bar.menu-bar-display-mode.v1"

    private init() {
        if let raw = UserDefaults.standard.string(forKey: storageKey),
           let decoded = MenuBarDisplayMode(rawValue: raw) {
            mode = decoded
        } else {
            mode = .bars
        }
    }

    var showsCurrentPercent: Bool {
        get { mode == .currentPercent }
        set { mode = newValue ? .currentPercent : .bars }
    }

    private func save() {
        UserDefaults.standard.set(mode.rawValue, forKey: storageKey)
    }
}

enum RefreshInterval: Int, CaseIterable, Identifiable, Codable {
    case oneMinute = 60
    case twoMinutes = 120
    case fiveMinutes = 300
    case fifteenMinutes = 900

    var id: Int { rawValue }

    var displayName: String {
        switch self {
        case .oneMinute: return "1 minute"
        case .twoMinutes: return "2 minutes (Recommended)"
        case .fiveMinutes: return "5 minutes"
        case .fifteenMinutes: return "15 minutes"
        }
    }

    var shortName: String {
        switch self {
        case .oneMinute: return "1 min"
        case .twoMinutes: return "2 min"
        case .fiveMinutes: return "5 min"
        case .fifteenMinutes: return "15 min"
        }
    }
}

@MainActor
final class RefreshPreferencesStore: ObservableObject {
    static let shared = RefreshPreferencesStore()

    @Published var interval: RefreshInterval {
        didSet { save() }
    }

    private let storageKey = "limit-bar.refresh-interval.v1"

    private init() {
        if let raw = UserDefaults.standard.object(forKey: storageKey) as? Int,
           let decoded = RefreshInterval(rawValue: raw) {
            interval = decoded
        } else {
            interval = .twoMinutes
        }
    }

    private func save() {
        UserDefaults.standard.set(interval.rawValue, forKey: storageKey)
    }
}

@MainActor
final class NotificationPreferencesStore: ObservableObject {
    static let shared = NotificationPreferencesStore()

    @Published var preferences: NotificationPreferences {
        didSet { save() }
    }

    private let storageKey = "limit-bar.notification-preferences.v1"

    private init() {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode(NotificationPreferences.self, from: data) {
            preferences = decoded
        } else {
            preferences = .default
        }
    }

    var isEnabled: Bool {
        get { preferences.isEnabled }
        set { preferences.isEnabled = newValue }
    }

    var thresholds: [Int] {
        get { preferences.thresholds }
        set { preferences.thresholds = newValue }
    }

    func thresholdBinding(at index: Int) -> Binding<Int> {
        Binding(
            get: {
                guard self.preferences.thresholds.indices.contains(index) else { return NotificationPreferences.default.thresholds[index] }
                return self.preferences.thresholds[index]
            },
            set: { newValue in
                self.setThreshold(newValue, at: index)
            }
        )
    }

    /// Thresholds stay strictly ordered: early > warn > critical.
    ///
    /// `normalizedThresholds` sorts descending before the values are ever used, so a
    /// "Critical" set above "Early" would silently become the *first* alert while still
    /// being labelled critical. Clamping each value between its neighbours keeps the
    /// labels honest, which matters much more now that they can be dragged past
    /// each other.
    func setThreshold(_ value: Int, at index: Int) {
        var updated = preferences.thresholds
        let defaults = NotificationPreferences.default.thresholds
        while updated.count < defaults.count {
            updated.append(defaults[updated.count])
        }

        guard updated.indices.contains(index) else { return }

        let upper = index > 0 ? updated[index - 1] - 1 : 99
        let lower = index < updated.count - 1 ? updated[index + 1] + 1 : 1
        let safeUpper = min(max(upper, 1), 99)
        let safeLower = min(max(lower, 1), safeUpper)

        updated[index] = min(max(value, safeLower), safeUpper)
        preferences.thresholds = updated
    }

    /// Inclusive range a threshold may take, given its neighbours.
    func thresholdRange(at index: Int) -> ClosedRange<Int> {
        let values = preferences.thresholds
        let upper = index > 0 && values.indices.contains(index - 1) ? values[index - 1] - 1 : 99
        let lower = index < values.count - 1 && values.indices.contains(index + 1) ? values[index + 1] + 1 : 1
        let safeUpper = min(max(upper, 1), 99)
        let safeLower = min(max(lower, 1), safeUpper)
        return safeLower...safeUpper
    }

    func restoreDefaults() {
        preferences = .default
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}

enum UsageNotificationCenter {
    private static let legacySentThresholdsKey = "limit-bar.sent-threshold-notifications.v1"
    private static let notifiedLevelsKey = "limit-bar.notified-threshold-levels.v2"
    /// Remaining usage has to climb this far back above an alerted threshold before
    /// that threshold can alert again, so a value wobbling 49/51 around a 50% threshold
    /// does not alert on every refresh.
    private static let rearmMargin = 5

    static func requestAuthorizationIfNeeded() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { _, _ in }
    }

    static func sendTestNotification() {
        requestAuthorizationIfNeeded()

        let content = UNMutableNotificationContent()
        content.title = "Codex session limit is running low"
        content.body = "24% remaining, resets in 4 hours."
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "limit-bar.test-notification",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    /// v1 remembered alerts by (threshold, reset timestamp). Claude's weekly reset was
    /// often a guessed "now + 7 days" that moved on every refresh, so each refresh
    /// looked like a brand new window and alerted again. Seed the new per-limit state
    /// from what is on screen right now, silently, so upgrading does not re-alert either.
    @MainActor
    static func migrateLegacyState(services: [ServiceLimit], preferences: NotificationPreferences) {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: legacySentThresholdsKey) != nil else { return }
        defer { defaults.removeObject(forKey: legacySentThresholdsKey) }
        guard defaults.object(forKey: notifiedLevelsKey) == nil else { return }

        var levels: [String: Int] = [:]
        for service in services where service.isConnected {
            for (kind, balance) in [("Current", service.current), ("Weekly", service.weekly)] {
                guard let balance,
                      let level = crossedLevel(remaining: balance.remainingPercent, thresholds: preferences.normalizedThresholds)
                else { continue }
                levels[levelKey(service: service.id, kind: kind)] = level
            }
        }
        defaults.set(levels, forKey: notifiedLevelsKey)
    }

    @MainActor
    static func notifyIfNeeded(
        service: LimitService,
        current: ServiceLimit,
        preferences: NotificationPreferences
    ) {
        guard preferences.isEnabled else { return }
        requestAuthorizationIfNeeded()

        evaluate(kind: "Current", service: service, current: current.current, thresholds: preferences.normalizedThresholds)
        evaluate(kind: "Weekly", service: service, current: current.weekly, thresholds: preferences.normalizedThresholds)
    }

    /// One alert per threshold per window, tracked by value alone.
    ///
    /// Each limit remembers the most severe threshold it has already alerted for. It
    /// alerts again only on crossing a *more* severe threshold, and forgets only once
    /// remaining usage has genuinely come back up (the window reset), which does not
    /// depend on reset timestamps that some CLIs only report approximately.
    @MainActor
    private static func evaluate(
        kind: String,
        service: LimitService,
        current: LimitBalance?,
        thresholds: [Int]
    ) {
        guard let current else { return }

        let key = levelKey(service: service, kind: kind)
        let remaining = current.remainingPercent
        let level = crossedLevel(remaining: remaining, thresholds: thresholds)
        var levels = notifiedLevels()

        if let notified = levels[key], remaining >= notified + rearmMargin {
            levels[key] = level
        }

        if let level, levels[key].map({ level < $0 }) ?? true {
            deliverNotification(service: service, kind: kind, current: current, level: level, severity: severity(of: level, in: thresholds))
            levels[key] = level
        }

        UserDefaults.standard.set(levels, forKey: notifiedLevelsKey)
    }

    /// Thresholds arrive sorted from least to most severe (early, warn, critical).
    private static func severity(of level: Int, in thresholds: [Int]) -> ThresholdSeverity {
        let index = thresholds.firstIndex(of: level) ?? 0
        return ThresholdSeverity.allCases[min(index, ThresholdSeverity.allCases.count - 1)]
    }

    /// The most severe threshold the value is at or below, if any.
    private static func crossedLevel(remaining: Int, thresholds: [Int]) -> Int? {
        thresholds.filter { remaining <= $0 }.min()
    }

    @MainActor
    private static func deliverNotification(service: LimitService, kind: String, current: LimitBalance, level: Int, severity: ThresholdSeverity) {
        let content = UNMutableNotificationContent()
        content.title = title(service: service, kind: kind, level: level, severity: severity)
        content.body = body(for: current)
        // The first heads-up is informational; only the later ones make a sound.
        content.sound = severity == .early ? nil : .default

        // Stable per limit, so a newer alert replaces the older one in Notification
        // Center instead of stacking up beside it.
        let request = UNNotificationRequest(
            identifier: "limit-bar.usage.\(levelKey(service: service, kind: kind))",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    /// "Low" undersells 10% left and oversells 50%, so the wording follows the
    /// threshold the user set rather than one fixed phrase.
    private static func title(service: LimitService, kind: String, level: Int, severity: ThresholdSeverity) -> String {
        let limit = "\(service.shortName) \(kind == "Current" ? "session" : "weekly") limit"
        switch severity {
        case .early: return "\(limit) is below \(level)%"
        case .warn: return "\(limit) is running low"
        case .critical: return "\(limit) is almost used up"
        }
    }

    private static func body(for balance: LimitBalance) -> String {
        let remaining = "\(balance.remainingPercent)% remaining"
        guard balance.hasKnownReset else { return "\(remaining)." }

        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "\(remaining), resets \(formatter.localizedString(for: balance.resetsAt, relativeTo: Date()))."
    }

    private static func levelKey(service: LimitService, kind: String) -> String {
        "\(service.rawValue)|\(kind)"
    }

    private static func notifiedLevels() -> [String: Int] {
        UserDefaults.standard.dictionary(forKey: notifiedLevelsKey) as? [String: Int] ?? [:]
    }
}

@MainActor
final class LimitStore: ObservableObject {
    @Published var services: [ServiceLimit] {
        didSet {
            save()
            refreshCoordinator.reschedule()
        }
    }

    private let storageKey = "limit-bar.services.v4"
    /// One task per provider, so a slow CLI cannot stack up across triggers.
    private var inFlight: [LimitService: Task<Void, Never>] = [:] {
        didSet {
            objectWillChange.send()
        }
    }
    /// Providers whose refresh the user asked for. Only these show a loading skeleton;
    /// scheduled refreshes swap the new numbers in without one.
    @Published private(set) var manualRefreshes: Set<LimitService> = []
    private(set) lazy var refreshCoordinator = RefreshCoordinator(store: self)

    var isRefreshing: Bool {
        !inFlight.isEmpty
    }

    func isRefreshing(for service: LimitService) -> Bool {
        inFlight[service] != nil
    }

    func isManuallyRefreshing(_ service: LimitService) -> Bool {
        manualRefreshes.contains(service)
    }

    init() {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([ServiceLimit].self, from: data) {
            services = LimitService.allCases.map { service in
                decoded.first(where: { $0.id == service }) ?? ServiceLimit.placeholder(for: service)
            }
        } else {
            services = LimitService.allCases.map(ServiceLimit.placeholder)
        }

        UsageNotificationCenter.migrateLegacyState(
            services: services,
            preferences: NotificationPreferencesStore.shared.preferences
        )
        refreshCoordinator.start()
    }

    var activeServices: [ServiceLimit] {
        services.filter { $0.id.isActiveProvider }
    }

    var allConnected: Bool { activeServices.allSatisfy(\.isConnected) }
    var connectedCount: Int { activeServices.filter(\.isConnected).count }

    var lowestRemaining: Int? {
        activeServices
            .filter(\.isConnected)
            .flatMap { [$0.current?.remainingPercent, $0.weekly?.remainingPercent] }
            .compactMap { $0 }
            .min()
    }

    var nextReset: Date? {
        activeServices
            .filter(\.isConnected)
            .flatMap { [$0.current, $0.weekly] }
            .compactMap { $0 }
            .filter(\.hasKnownReset)
            .map(\.resetsAt)
            .filter { $0 > Date() }
            .min()
    }

    func connect(_ service: LimitService) {
        connect(service, showLoading: true, presentErrors: true)
    }

    private func connect(_ service: LimitService, showLoading: Bool, presentErrors: Bool) {
        // Coalesce: a refresh already running for this provider is as good as a new one.
        guard inFlight[service] == nil else { return }

        if showLoading {
            setState(.connecting, for: service, error: nil)
        }

        let task = Task { [weak self] in
            defer {
                self?.inFlight[service] = nil
                self?.manualRefreshes.remove(service)
            }

            do {
                let snapshot = try await ProviderConnector.fetch(service)
                self?.apply(snapshot, to: service)
            } catch {
                guard let self else { return }

                if showLoading {
                    self.setState(.failed, for: service, error: error.localizedDescription)
                } else {
                    // A quiet background refresh must not blank a working row, but the
                    // stale values it leaves behind have to be marked as such.
                    self.markAttemptFailed(for: service)
                }

                if presentErrors {
                    if service == .antigravity, AntigravityCLIConnector.isLoginError(error.localizedDescription) {
                        AntigravityAuthPresenter.show(message: error.localizedDescription)
                    } else {
                        ErrorAlertPresenter.show(message: error.localizedDescription)
                    }
                }
            }
        }

        inFlight[service] = task
    }

    /// The refresh button. If a scheduled refresh for a provider is already running,
    /// that one is joined rather than restarted, and shows the skeleton too.
    func refreshConnected() {
        for service in activeServices where service.isConnected {
            manualRefreshes.insert(service.id)
        }
        refreshConnected(showLoading: false, presentErrors: true)
    }

    /// Quiet refresh of one provider, used when its CLI shows signs of activity.
    func refreshInBackground(_ service: LimitService) {
        guard activeServices.contains(where: { $0.id == service && $0.isConnected }) else { return }
        connect(service, showLoading: false, presentErrors: false)
    }

    /// Quiet refresh used by the popover and the background schedule.
    func refreshInBackground() {
        refreshConnected(showLoading: false, presentErrors: false)
    }

    /// Refreshes only when the newest data is older than `maxAge`, so repeatedly opening
    /// the popover does not relaunch the provider CLIs each time.
    func refreshIfStale(maxAge: TimeInterval) {
        let connected = activeServices.filter(\.isConnected)
        guard !connected.isEmpty else { return }

        let isStale = connected.contains { service in
            guard let attempted = service.lastAttemptAt ?? service.lastUpdated else { return true }
            return Date().timeIntervalSince(attempted) >= maxAge
        }

        guard isStale else { return }
        refreshInBackground()
    }

    private func refreshConnected(showLoading: Bool, presentErrors: Bool) {
        for service in activeServices where service.isConnected {
            connect(service.id, showLoading: showLoading, presentErrors: presentErrors)
        }
    }

    private func markAttemptFailed(for service: LimitService) {
        guard let index = services.firstIndex(where: { $0.id == service }) else { return }
        services[index].lastAttemptAt = Date()
        services[index].lastAttemptFailed = true
    }

    func resetSetup() {
        services = LimitService.allCases.map(ServiceLimit.placeholder)
    }

    func disconnect(_ service: LimitService) {
        guard let index = services.firstIndex(where: { $0.id == service }) else { return }
        services[index] = ServiceLimit.placeholder(for: service)
    }

    func clearError(for service: LimitService) {
        guard let index = services.firstIndex(where: { $0.id == service }), services[index].state == .failed else { return }
        services[index].state = .disconnected
        services[index].errorMessage = nil
    }

    private func apply(_ snapshot: ProviderSnapshot, to service: LimitService) {
        guard let index = services.firstIndex(where: { $0.id == service }) else { return }
        services[index].state = .connected
        services[index].current = snapshot.current
        services[index].weekly = snapshot.weekly
        services[index].credits = snapshot.credits
        services[index].accountEmail = snapshot.accountEmail
        services[index].planName = snapshot.planName
        services[index].lastUpdated = Date()
        services[index].lastAttemptAt = Date()
        services[index].lastAttemptFailed = false
        services[index].errorMessage = nil
        UsageNotificationCenter.notifyIfNeeded(
            service: service,
            current: services[index],
            preferences: NotificationPreferencesStore.shared.preferences
        )
    }

    private func setState(_ state: ConnectionState, for service: LimitService, error: String?) {
        guard let index = services.firstIndex(where: { $0.id == service }) else { return }
        services[index].state = state
        services[index].errorMessage = error
        if state == .disconnected || state == .failed {
            services[index].current = nil
            services[index].weekly = nil
            services[index].credits = nil
            services[index].accountEmail = nil
            services[index].planName = nil
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(services) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}

/// Decides *when* usage is refreshed. `LimitStore` owns the data; this owns the policy.
///
/// Refreshes automatically in the background so the menu bar always shows fresh data,
/// upon waking from sleep, shortly after startup, and immediately when the user opens the popover.
///
/// Limits only move while a tool is being used, so on top of the fixed interval each
/// provider is also re-read soon after its CLI writes session activity to disk. That
/// keeps the menu bar current while you work, without polling faster when idle.
@MainActor
final class RefreshCoordinator {
    /// Data younger than this is fresh enough to show without relaunching the CLIs.
    private let popoverMaxAge: TimeInterval = 30
    /// Balances change at a reset boundary, so look shortly after one.
    private let postResetDelay: TimeInterval = 15
    /// While a provider is in use, re-read its limits at most this often.
    private let activeRefreshInterval: TimeInterval = 45
    /// Let a burst of session writes settle, and the provider's server account for the
    /// request, before reading.
    private let activitySettleDelay: TimeInterval = 8

    private unowned let store: LimitStore
    private let refreshPreferences = RefreshPreferencesStore.shared
    private var timer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var isAsleep = false
    private var pendingActivityRefresh: [LimitService: DispatchWorkItem] = [:]
    private lazy var activityMonitor = ProviderActivityMonitor { [weak self] service in
        self?.activityDetected(for: service)
    }

    init(store: LimitStore) {
        self.store = store
    }

    func start() {
        refreshPreferences.$interval
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.reschedule()
            }
            .store(in: &cancellables)

        let workspace = NSWorkspace.shared.notificationCenter
        workspace.publisher(for: NSWorkspace.willSleepNotification)
            .sink { [weak self] _ in self?.handleSleep() }
            .store(in: &cancellables)
        workspace.publisher(for: NSWorkspace.didWakeNotification)
            .sink { [weak self] _ in self?.handleWake() }
            .store(in: &cancellables)

        activityMonitor.start()

        // Initial refresh shortly after launch so the menu bar displays up-to-date numbers
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, !self.isAsleep else { return }
            self.store.refreshIfStale(maxAge: self.popoverMaxAge)
        }

        reschedule()
    }

    /// The user opened the popover: show them something current.
    func popoverWillShow() {
        store.refreshIfStale(maxAge: popoverMaxAge)
    }

    // MARK: - Activity

    /// Throttled rather than debounced: during a long session the writes never pause,
    /// and a debounce would hold the refresh back until the session ended.
    private func activityDetected(for service: LimitService) {
        guard !isAsleep, pendingActivityRefresh[service] == nil,
              let limit = store.activeServices.first(where: { $0.id == service }),
              limit.isConnected else { return }

        let sinceLast = (limit.lastAttemptAt ?? limit.lastUpdated).map { Date().timeIntervalSince($0) } ?? .infinity
        let delay = max(activeRefreshInterval - sinceLast, activitySettleDelay)

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingActivityRefresh[service] = nil
            guard !self.isAsleep else { return }
            self.store.refreshInBackground(service)
        }
        pendingActivityRefresh[service] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: - Scheduling

    func reschedule() {
        timer?.invalidate()
        timer = nil

        // Background polling feeds the menu bar status item and usage notifications.
        // It runs whenever the Mac is awake and at least one provider is connected.
        guard !isAsleep, store.connectedCount > 0 else { return }

        let delay = nextDelay()
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tick()
            }
        }
        timer.tolerance = min(15, delay * 0.1)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func nextDelay() -> TimeInterval {
        let standard = TimeInterval(refreshPreferences.interval.rawValue)

        // If a window resets before the next ordinary tick, wait for the reset instead:
        // that is the moment the numbers actually move.
        guard let nextReset = store.nextReset else { return standard }

        let untilReset = nextReset.timeIntervalSinceNow + postResetDelay
        guard untilReset > 0, untilReset < standard else { return standard }
        return max(untilReset, 10)
    }

    private func tick() {
        store.refreshInBackground()
        reschedule()
    }

    // MARK: - Sleep

    private func handleSleep() {
        isAsleep = true
        timer?.invalidate()
        timer = nil
        pendingActivityRefresh.values.forEach { $0.cancel() }
        pendingActivityRefresh.removeAll()
    }

    private func handleWake() {
        isAsleep = false
        store.refreshIfStale(maxAge: popoverMaxAge)
        reschedule()
    }
}

/// Reports which provider's CLI is being used, from writes to the folders each one
/// keeps its session history in.
///
/// Only files a real session writes are counted. Limit Bar's own probes write to
/// some of these folders too (`claude --print` records a session for its working
/// directory, `agy` logs every run), and counting those would make every refresh
/// trigger the next one.
final class ProviderActivityMonitor {
    private struct Source {
        let service: LimitService
        let root: String
        let counts: (String) -> Bool
    }

    private let onActivity: (LimitService) -> Void
    private let sources: [Source]
    private var stream: FSEventStreamRef?

    init(onActivity: @escaping (LimitService) -> Void) {
        self.onActivity = onActivity
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let antigravitySession: (String) -> Bool = { path in
            ["/brain/", "/conversations/", "/implicit/"].contains { path.contains($0) }
        }
        sources = [
            Source(service: .claude, root: home + "/.claude/projects/") { path in
                // Probe sessions live under project folders named after their working
                // directory, e.g. "-Users-me-Library-Application-Support-LimitBar-Probe".
                path.hasSuffix(".jsonl") && !path.contains("-Library-Application-Support-")
            },
            Source(service: .codex, root: home + "/.codex/sessions/") { $0.hasSuffix(".jsonl") },
            Source(service: .antigravity, root: home + "/.gemini/antigravity/", counts: antigravitySession),
            Source(service: .antigravity, root: home + "/.gemini/antigravity-cli/", counts: antigravitySession)
        ]
    }

    deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }

    func start() {
        guard stream == nil else { return }

        let roots = sources.map(\.root).filter { FileManager.default.fileExists(atPath: $0) }
        guard !roots.isEmpty else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let monitor = Unmanaged<ProviderActivityMonitor>.fromOpaque(info).takeUnretainedValue()
            let changed = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            // The stream is scheduled on the main queue.
            MainActor.assumeIsolated {
                monitor.handle(Array(changed.prefix(count)))
            }
        }

        guard let stream = FSEventStreamCreate(
            nil,
            callback,
            &context,
            roots as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            2,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents)
        ) else { return }

        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    private func handle(_ paths: [String]) {
        var active = Set<LimitService>()
        for path in paths {
            if let source = sources.first(where: { path.hasPrefix($0.root) }), source.counts(path) {
                active.insert(source.service)
            }
        }
        active.forEach(onActivity)
    }
}

extension ServiceLimit {
    static func placeholder(for service: LimitService) -> ServiceLimit {
        ServiceLimit(id: service, state: .disconnected, current: nil, weekly: nil, credits: nil, accountEmail: nil, planName: nil, lastUpdated: nil, errorMessage: nil)
    }
}

struct ProviderSnapshot: Equatable {
    var current: LimitBalance?
    var weekly: LimitBalance?
    var credits: CreditBalance?
    var accountEmail: String?
    var planName: String?
}

enum ProviderConnector {
    static func fetch(_ service: LimitService) async throws -> ProviderSnapshot {
        switch service {
        case .codex:
            return try await CodexCLIConnector.fetch()
        case .claude:
            return try await ClaudeCLIConnector.fetch()
        case .antigravity:
            return try await AntigravityCLIConnector.fetch()
        case .gemini:
            return try await GeminiCLIConnector.fetch()
        }
    }
}

struct CodexCLIConnector {
    /// Run from a directory the app owns rather than inheriting whatever the app was
    /// launched with, so the CLI resolves its state from a predictable place.
    private static func probeDirectory() -> URL? {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/LimitBar/CodexProbe", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return FileManager.default.fileExists(atPath: directory.path) ? directory : nil
    }

    static func fetch() async throws -> ProviderSnapshot {
        let result = try await ProcessRunner.run(
            executable: "/bin/zsh",
            arguments: ["-lc", rpcScript()],
            input: nil,
            timeout: 12,
            currentDirectory: probeDirectory()
        )

        guard result.status == 0 || !result.stdout.isEmpty else {
            throw ConnectorError.message(cleanError(result.stderr, fallback: "Codex CLI did not return usage data. Make sure Codex is installed and signed in."))
        }

        return try parseRPC(stdout: result.stdout)
    }

    private static func rpcScript() -> String {
        """
        {
        printf '%s\\n' '{"id":1,"method":"initialize","params":{"clientInfo":{"name":"limit-bar","version":"0.1"}}}'
        sleep 0.2
        printf '%s\\n' '{"method":"initialized","params":{}}'
        sleep 0.2
        printf '%s\\n' '{"id":2,"method":"account/rateLimits/read","params":{}}'
        sleep 0.2
        printf '%s\\n' '{"id":3,"method":"account/read","params":{}}'
        sleep 1
        } | codex -s read-only -a never app-server
        """
    }

    private static func parseRPC(stdout: String) throws -> ProviderSnapshot {
        var primary: LimitBalance?
        var secondary: LimitBalance?
        var credits: CreditBalance?
        var email: String?
        var plan: String?

        for line in stdout.split(whereSeparator: \.isNewline) {
            guard let data = String(line).data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = json["id"] as? Int,
                  let result = json["result"] as? [String: Any] else { continue }

            if id == 2, let rateLimits = result["rateLimits"] as? [String: Any] {
                primary = makeBalance(
                    title: "Session",
                    dictionary: rateLimits["primary"] as? [String: Any]
                )
                secondary = makeBalance(
                    title: "Weekly",
                    dictionary: rateLimits["secondary"] as? [String: Any]
                )
                credits = makeCredits(dictionary: rateLimits["credits"] as? [String: Any])
                if plan == nil {
                    plan = normalizePlan(rateLimits["planType"] as? String)
                }
            }

            if id == 3 {
                let account = result["account"] as? [String: Any] ?? result
                email = (account["email"] as? String) ?? email
                plan = normalizePlan((account["planType"] as? String) ?? (account["plan_type"] as? String)) ?? plan
            }
        }

        guard primary != nil || secondary != nil else {
            throw ConnectorError.message("Could not parse Codex rate limits. Try updating the Codex CLI.")
        }

        return ProviderSnapshot(current: primary, weekly: secondary, credits: credits, accountEmail: email, planName: plan)
    }

    private static func makeBalance(title: String, dictionary: [String: Any]?) -> LimitBalance? {
        guard let dictionary,
              let used = number(dictionary["usedPercent"]),
              let reset = number(dictionary["resetsAt"]) else { return nil }

        return LimitBalance(
            title: title,
            remainingPercent: clampPercent(100 - Int(used.rounded())),
            resetsAt: Date(timeIntervalSince1970: reset)
        )
    }

    private static func makeCredits(dictionary: [String: Any]?) -> CreditBalance? {
        guard let dictionary else { return nil }
        let balance = (dictionary["balance"] as? String) ?? number(dictionary["balance"]).map { String(Int($0)) } ?? "0"
        let hasCredits = dictionary["hasCredits"] as? Bool ?? false
        let unlimited = dictionary["unlimited"] as? Bool ?? false
        return CreditBalance(remaining: balance, hasCredits: hasCredits, unlimited: unlimited)
    }

    private static func normalizePlan(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        return raw
            .replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .map { word in
                word.prefix(1).uppercased() + word.dropFirst()
            }
            .joined(separator: " ")
    }
}

struct ClaudeCLIConnector {
    static func fetch() async throws -> ProviderSnapshot {
        // Fast path: headless `/usage` takes ~3s and avoids spinning up a heavy pty/TUI session.
        // Limits in its output already prove the CLI is signed in to a subscription,
        // so `claude auth status` - a second Node process on every refresh - only runs
        // when they are missing, to explain why.
        let printed = await fetchPrintUsage()
        if let snapshot = printed.snapshot {
            return snapshot
        }

        try await ensureLoggedIn()

        if printed.reportedLoggedOut {
            throw ConnectorError.message("Claude Code is not logged in. Open Claude Code and run `/login`, then retry.")
        }

        // Fallback: if headless print did not expose subscription limits, probe status line
        if let statusLineSnapshot = try await fetchStatusLineUsage() {
            return statusLineSnapshot
        }

        throw ConnectorError.message("Claude Code did not expose 5-hour or weekly usage limits in a recognized format.")
    }

    private static func fetchPrintUsage() async -> (snapshot: ProviderSnapshot?, reportedLoggedOut: Bool) {
        guard let result = try? await ProcessRunner.run(
            executable: "/usr/bin/env",
            arguments: ["claude", "--print", "/usage"],
            input: nil,
            timeout: 10
        ) else {
            return (nil, false)
        }

        let output = [result.stdout, result.stderr].joined(separator: "\n")
        if output.localizedCaseInsensitiveContains("not logged in") || output.localizedCaseInsensitiveContains("please run /login") {
            return (nil, true)
        }
        return (try? parseUsage(output), false)
    }

    private static func fetchStatusLineUsage() async throws -> ProviderSnapshot? {
        let fileManager = FileManager.default
        let tempDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("limitbar-claude-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDirectory) }

        let captureURL = tempDirectory.appendingPathComponent("statusline.json")
        let settingsURL = tempDirectory.appendingPathComponent("settings.json")
        let probeDirectory = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/LimitBar/ClaudeProbe", isDirectory: true)
        try fileManager.createDirectory(at: probeDirectory, withIntermediateDirectories: true)

        let captureCommand = "python3 -c 'import pathlib,sys; pathlib.Path(\"\(captureURL.path)\").write_text(sys.stdin.read())'"
        let settings: [String: Any] = [
            "statusLine": [
                "type": "command",
                "command": captureCommand,
                "refreshInterval": 1
            ]
        ]
        let settingsData = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted])
        try settingsData.write(to: settingsURL)

        // `rate_limits` is populated after Claude Code refreshes its subscription
        // usage. Starting a TUI and immediately exiting only gives the status-line
        // command session metadata, which is why `/usage`-style headless probes
        // report session/API usage instead of the 5-hour and weekly limits.
        let script = """
        ( sleep 2; printf '/usage\\r'; sleep 5; printf '\\033'; sleep 1; printf '/exit\\r'; sleep 1 ) | /usr/bin/script -q /dev/null /usr/bin/env claude --settings \(settingsURL.path.shellQuoted)
        """

        do {
            _ = try await ProcessRunner.run(
                executable: "/bin/zsh",
                arguments: ["-lc", script],
                input: nil,
                timeout: 18,
                currentDirectory: probeDirectory
            )
        } catch {
            return nil
        }

        guard let data = try? Data(contentsOf: captureURL),
              let raw = String(data: data, encoding: .utf8),
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        return try parseStatusLine(raw)
    }

    private static func ensureLoggedIn() async throws {
        let result = try await ProcessRunner.run(
            executable: "/usr/bin/env",
            arguments: ["claude", "auth", "status"],
            input: nil,
            timeout: 8
        )

        let output = [result.stdout, result.stderr].joined(separator: "\n")
        if output.localizedCaseInsensitiveContains(#""loggedIn": false"#) ||
            output.localizedCaseInsensitiveContains("\"authMethod\": \"none\"") ||
            output.localizedCaseInsensitiveContains("not logged in") {
            throw ConnectorError.message("Claude Code is not logged in for CLI access. Run `claude auth login` in Terminal, finish the browser login, then retry.")
        }

        if let data = output.data(using: .utf8),
           let status = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let provider = status["apiProvider"] as? String,
           provider.localizedCaseInsensitiveCompare("firstParty") != .orderedSame {
            throw ConnectorError.message("Claude Code is connected through an API or cloud provider account. Claude.ai 5-hour and weekly subscription limits are only available for first-party Claude.ai subscriptions.")
        }
    }

    private static func parseStatusLine(_ output: String) throws -> ProviderSnapshot? {
        guard let data = output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rateLimits = json["rate_limits"] as? [String: Any] else {
            return nil
        }

        let current = makeStatusLineBalance(
            title: "5 hour usage limit",
            dictionary: rateLimits["five_hour"] as? [String: Any],
            fallbackReset: Date().addingTimeInterval(5 * 60 * 60)
        )
        let weekly = makeStatusLineBalance(
            title: "Weekly usage limit",
            dictionary: rateLimits["seven_day"] as? [String: Any],
            fallbackReset: Date().addingTimeInterval(7 * 24 * 60 * 60)
        )

        // Some Claude Code builds expose the model-specific weekly bucket while
        // the aggregate seven-day bucket is unavailable. It is still a useful,
        // server-provided subscription limit, so show it instead of reporting
        // that Claude is disconnected.
        let weeklyFallback = weekly == nil
            ? makeStatusLineBalance(
                title: "Weekly Sonnet usage limit",
                dictionary: rateLimits["seven_day_sonnet"] as? [String: Any],
                fallbackReset: Date().addingTimeInterval(7 * 24 * 60 * 60)
            )
            : nil

        guard current != nil || weekly != nil || weeklyFallback != nil else { return nil }
        return ProviderSnapshot(current: current, weekly: weekly ?? weeklyFallback, credits: nil, accountEmail: nil, planName: "Claude")
    }

    private static func makeStatusLineBalance(title: String, dictionary: [String: Any]?, fallbackReset: Date) -> LimitBalance? {
        guard let dictionary,
              let used = number(dictionary["used_percentage"] ?? dictionary["usedPercent"] ?? dictionary["utilization"]) else { return nil }

        let reportedReset = date(dictionary["resets_at"] ?? dictionary["resetsAt"])
        let usedPercentage = used <= 1 ? used * 100 : used
        return LimitBalance(
            title: title,
            remainingPercent: clampPercent(100 - Int(usedPercentage.rounded())),
            resetsAt: reportedReset ?? fallbackReset,
            isResetEstimated: reportedReset == nil
        )
    }

    private static func parseUsage(_ output: String) throws -> ProviderSnapshot {
        let clean = output.strippingANSI()

        if let snapshot = parseUsageLines(clean) {
            return snapshot
        }

        let percents = clean.matches(pattern: #"([0-9]{1,3})\s*%\s*(?:remaining|left|available|used)?"#)
            .compactMap { Int($0) }
            .map(clampPercent)

        let dates = clean.extractResetDates()
        if percents.count >= 2 {
            return ProviderSnapshot(
                current: LimitBalance(title: "5 hour usage limit", remainingPercent: normalizeClaudePercent(percents[0], clean), resetsAt: dates.first ?? Date().addingTimeInterval(5 * 60 * 60)),
                weekly: LimitBalance(title: "Weekly usage limit", remainingPercent: normalizeClaudePercent(percents[1], clean), resetsAt: dates.dropFirst().first ?? Date().addingTimeInterval(7 * 24 * 60 * 60)),
                credits: nil,
                accountEmail: nil,
                planName: "Claude"
            )
        }

        if isClaudeSessionUsageSummary(clean) {
            throw ConnectorError.message("Claude Code is connected, but this account only exposed session/API usage, not 5-hour and weekly subscription limits. Limit Bar can read Claude limits when Claude Code provides `rate_limits` through its status line.")
        }

        throw ConnectorError.message("Claude Code did not expose 5-hour or weekly usage limits in a recognized format.")
    }

    /// Reads each limit from its own line, e.g.
    /// "Current session: 2% used · resets Sep 25 at 3:49pm (Europe/Kiev)".
    ///
    /// Pairing every percentage in the output with every reset date in order went
    /// wrong in two ways, verified against claude 2.1.281: an idle session prints no
    /// reset at all, so the session borrowed the weekly reset and the weekly limit
    /// fell back to a guessed "now + 7 days" that moved on every refresh; and the
    /// usage breakdown printed below the limits adds more, unrelated percentages.
    private static func parseUsageLines(_ text: String) -> ProviderSnapshot? {
        var current: LimitBalance?
        var weekly: LimitBalance?
        var modelWeekly: LimitBalance?

        for line in text.split(whereSeparator: \.isNewline).map(String.init) {
            let lower = line.lowercased()
            guard let match = line.matches(pattern: #"([0-9]{1,3})\s*%\s*(?:used|left|remaining)"#).first,
                  let value = Int(match) else { continue }

            let percent = clampPercent(value)
            let remaining = lower.contains("% used") ? clampPercent(100 - percent) : percent
            let reset = line.extractResetDates().first

            if lower.contains("session") || lower.contains("5-hour") || lower.contains("5 hour") {
                current = current ?? LimitBalance(
                    title: "5 hour usage limit",
                    remainingPercent: remaining,
                    resetsAt: reset ?? Date().addingTimeInterval(5 * 60 * 60),
                    isResetEstimated: reset == nil
                )
            } else if lower.contains("week") {
                let balance = LimitBalance(
                    title: "Weekly usage limit",
                    remainingPercent: remaining,
                    resetsAt: reset ?? Date().addingTimeInterval(7 * 24 * 60 * 60),
                    isResetEstimated: reset == nil
                )
                // "Current week (all models)" is the account-wide cap; per-model weekly
                // buckets are only a fallback when it is missing.
                if lower.contains("sonnet") || lower.contains("opus") {
                    modelWeekly = modelWeekly ?? balance
                } else {
                    weekly = weekly ?? balance
                }
            }
        }

        guard current != nil || weekly != nil || modelWeekly != nil else { return nil }
        return ProviderSnapshot(current: current, weekly: weekly ?? modelWeekly, credits: nil, accountEmail: nil, planName: "Claude")
    }

    private static func normalizeClaudePercent(_ value: Int, _ text: String) -> Int {
        let lower = text.lowercased()
        if lower.contains("% used") || lower.contains("utilization") {
            return clampPercent(100 - value)
        }
        return value
    }

    private static func isClaudeSessionUsageSummary(_ output: String) -> Bool {
        let lower = output.lowercased()
        return lower.contains("total cost:") &&
            lower.contains("total duration") &&
            lower.contains("usage:") &&
            lower.contains("input") &&
            lower.contains("output")
    }
}

struct GeminiCLIConnector {
    static func fetch() async throws -> ProviderSnapshot {
        _ = try await resolveBinary()
        throw ConnectorError.message("Gemini CLI does not expose quota through a headless usage command. Open Gemini CLI and use `/stats model`; Limit Bar can track Gemini after we add interactive stats capture or Google Cloud/API usage integration.")
    }

    private static func resolveBinary() async throws -> String {
        for candidate in ["gemini", "gemini-cli"] {
            let result = try await ProcessRunner.run(
                executable: "/usr/bin/env",
                arguments: ["which", candidate],
                input: nil,
                timeout: 4
            )
            if result.status == 0, !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return candidate
            }
        }

        throw ConnectorError.message("Gemini CLI not found. Install and authenticate Gemini CLI, then retry.")
    }

    private static func parseUsage(_ output: String) throws -> ProviderSnapshot {
        let clean = output.strippingANSI()
        let percents = clean.matches(pattern: #"([0-9]{1,3})\s*%\s*(?:remaining|left|available|used)?"#)
            .compactMap { Int($0) }
            .map(clampPercent)

        guard !percents.isEmpty else {
            throw ConnectorError.message("Gemini CLI did not expose usage data in a recognized format.")
        }

        let dates = clean.extractResetDates()
        return ProviderSnapshot(
            current: LimitBalance(title: "Session", remainingPercent: normalizePercent(percents[0], clean), resetsAt: dates.first ?? Date().addingTimeInterval(24 * 60 * 60)),
            weekly: percents.count > 1 ? LimitBalance(title: "Weekly", remainingPercent: normalizePercent(percents[1], clean), resetsAt: dates.dropFirst().first ?? Date().addingTimeInterval(7 * 24 * 60 * 60)) : nil,
            credits: nil,
            accountEmail: nil,
            planName: nil
        )
    }

    private static func isUnauthenticated(_ output: String) -> Bool {
        let clean = output.strippingANSI().lowercased()
        return clean.contains("not authenticated") ||
            clean.contains("not logged in") ||
            clean.contains("not logged") ||
            clean.contains("please login") ||
            clean.contains("please log in") ||
            clean.contains("run `gemini auth login`") ||
            clean.contains("run gemini auth login") ||
            clean.contains("unauthorized") ||
            clean.contains("401")
    }

    private static func isRateLimited(_ output: String) -> Bool {
        let clean = output.strippingANSI().lowercased()
        return clean.contains("rate limit") ||
            clean.contains("ratelimit") ||
            clean.contains("resource has been exhausted") ||
            clean.contains("quota") ||
            clean.contains("status 429") ||
            clean.contains("too many requests") ||
            clean.contains("ratelimitexceeded")
    }

    private static func normalizePercent(_ value: Int, _ text: String) -> Int {
        if text.localizedCaseInsensitiveContains("% used") {
            return clampPercent(100 - value)
        }
        return value
    }

    private static var trustedWorkspaceEnvironment: [String: String] {
        ["GEMINI_CLI_TRUST_WORKSPACE": "true"]
    }
}

struct AntigravityCLIConnector {
    static func fetch() async throws -> ProviderSnapshot {
        let binary = try await resolveBinary()
        let result = try await ProcessRunner.run(
            executable: "/usr/bin/env",
            arguments: [
                binary,
                "--print", "/usage",
                "--output-format", "json",
                "--print-timeout", "15s"
            ],
            input: nil,
            timeout: 20
        )

        let output = [result.stdout, result.stderr].joined(separator: "\n")
        guard result.status == 0 || !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            await openAntigravityLogin(binary: binary)
            throw ConnectorError.message(loginMessage)
        }

        if isUnauthenticated(output) {
            await openAntigravityLogin(binary: binary)
            throw ConnectorError.message(loginMessage)
        }

        guard result.status == 0 else {
            if requiresUpdate(output) {
                throw ConnectorError.message("Antigravity CLI needs an update before limits can be read. Run `agy update`, sign in with Google again if prompted, then retry.")
            }
            throw ConnectorError.message(cleanError(output, fallback: "Antigravity CLI did not return usage data. Run `agy` in Terminal, complete Google OAuth login, then retry."))
        }

        return try parseUsage(output)
    }

    private static func parseUsage(_ output: String) throws -> ProviderSnapshot {
        let clean = output.strippingANSI()
        guard let data = clean.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let command = root["command"] as? [String: Any],
              let commandData = command["data"] as? [String: Any],
              let groups = commandData["groups"] as? [[String: Any]] else {
            throw ConnectorError.message("Antigravity CLI did not return quota data in a recognized format. Run `agy /usage` in Terminal, then retry.")
        }

        var currentBalances: [LimitBalance] = []
        var weeklyBalances: [LimitBalance] = []

        for group in groups {
            guard let buckets = group["buckets"] as? [[String: Any]] else { continue }

            for bucket in buckets {
                guard let remaining = number(bucket["remaining_fraction"] ?? bucket["remainingFraction"]),
                      let reset = date(bucket["reset_time"] ?? bucket["resetTime"]) else { continue }

                let name = bucket["name"] as? String ?? "Usage limit"
                let balance = LimitBalance(
                    title: name,
                    remainingPercent: clampPercent(Int((remaining * 100).rounded())),
                    resetsAt: reset
                )

                if (bucket["window"] as? String)?.localizedCaseInsensitiveContains("weekly") == true ||
                    name.localizedCaseInsensitiveContains("weekly") {
                    weeklyBalances.append(balance)
                } else if (bucket["window"] as? String)?.localizedCaseInsensitiveContains("5h") == true ||
                            name.localizedCaseInsensitiveContains("five hour") {
                    currentBalances.append(balance)
                }
            }
        }

        guard !currentBalances.isEmpty || !weeklyBalances.isEmpty else {
            throw ConnectorError.message("Antigravity CLI returned no current or weekly quota buckets. Open Antigravity and run `/usage`, then retry.")
        }

        return ProviderSnapshot(
            current: mostConstrained(currentBalances, title: "5-hour limit"),
            weekly: mostConstrained(weeklyBalances, title: "Weekly limit"),
            credits: nil,
            accountEmail: latestAuthenticatedEmail(),
            planName: nil
        )
    }

    private static func mostConstrained(_ balances: [LimitBalance], title: String) -> LimitBalance? {
        guard let lowest = balances.min(by: { $0.remainingPercent < $1.remainingPercent }) else { return nil }
        return LimitBalance(title: title, remainingPercent: lowest.remainingPercent, resetsAt: lowest.resetsAt)
    }

    private static func resolveBinary() async throws -> String {
        for candidate in ["agy", "antigravity"] {
            let result = try await ProcessRunner.run(
                executable: "/usr/bin/env",
                arguments: ["which", candidate],
                input: nil,
                timeout: 4
            )
            let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if result.status == 0, !path.isEmpty {
                return path
            }
        }

        throw ConnectorError.message("Antigravity CLI not found. Install Antigravity, sign in with Google, then retry.")
    }

    static func isLoginError(_ output: String) -> Bool {
        isUnauthenticated(output)
    }

    private static func isUnauthenticated(_ output: String) -> Bool {
        let clean = output.strippingANSI().lowercased()
        return clean.contains("not authenticated") ||
            clean.contains("not logged in") ||
            clean.contains("not logged into antigravity") ||
            clean.contains("please login") ||
            clean.contains("please log in") ||
            clean.contains("sign in") ||
            clean.contains("log in again") ||
            clean.contains("login with google") ||
            clean.contains("google account") ||
            clean.contains("unauthorized") ||
            clean.contains("401")
    }

    private static func requiresUpdate(_ output: String) -> Bool {
        let clean = output.strippingANSI().lowercased()
        return clean.contains("no longer supported") ||
            clean.contains("agy update") ||
            clean.contains("please update")
    }

    private static var loginMessage: String {
        "Antigravity is not logged in for CLI access. Run `agy` in Terminal, press Enter to open Google OAuth, paste the browser code back into the CLI, then retry Connect."
    }

    private static func openAntigravityLogin(binary: String) async {
        _ = try? await ProcessRunner.run(
            executable: "/usr/bin/osascript",
            arguments: [
                "-e",
                """
                tell application "Terminal"
                    activate
                    do script "\(binary.shellQuoted)"
                end tell
                """
            ],
            input: nil,
            timeout: 4
        )
    }

    private static func latestAuthenticatedEmail() -> String? {
        let logDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini/antigravity-cli/log", isDirectory: true)

        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: logDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        let sortedLogs = urls
            .filter { $0.pathExtension == "log" }
            .sorted { lhs, rhs in
                let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return lhsDate > rhsDate
            }

        for url in sortedLogs.prefix(8) {
            guard let text = try? String(contentsOf: url, encoding: .utf8),
                  let email = text.matches(pattern: #"applyAuthResult:\s+email=([^,\s]+)"#).last,
                  !email.isEmpty else { continue }
            return email
        }

        return nil
    }
}

/// Thread-safe accumulator for the pipe readability handlers, which fire on a background queue.
private final class ProcessOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    // Synchronised by `lock`, not by an actor: the pipe readability handlers fire on a
    // background queue, so these must not be main actor isolated.
    nonisolated(unsafe) private var stdoutData = Data()
    nonisolated(unsafe) private var stderrData = Data()

    nonisolated func appendStandardOutput(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        stdoutData.append(data)
        lock.unlock()
    }

    nonisolated func appendStandardError(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        stderrData.append(data)
        lock.unlock()
    }

    nonisolated func snapshot() -> (stdout: String, stderr: String) {
        lock.lock()
        defer { lock.unlock() }
        return (
            String(data: stdoutData, encoding: .utf8) ?? "",
            String(data: stderrData, encoding: .utf8) ?? ""
        )
    }
}

struct ProcessRunner {
    struct Result {
        let stdout: String
        let stderr: String
        let status: Int32
    }

    static func defaultProbeDirectory() -> URL {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/LimitBar/Probe", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func run(
        executable: String,
        arguments: [String],
        input: String?,
        timeout: TimeInterval,
        environmentOverrides: [String: String] = [:],
        currentDirectory: URL? = nil
    ) async throws -> Result {
        let workingDirectory = currentDirectory ?? defaultProbeDirectory()
        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            let stdinPipe = Pipe()
            let finishGate = ProcessFinishGate()
            // Drained continuously: a child that outruns the 64KB pipe buffer would
            // otherwise block on write and never reach its termination handler. The
            // Claude probe runs a TUI through a pty, so it can be genuinely chatty.
            let output = ProcessOutputBuffer()

            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
            var overrides = environmentOverrides
            overrides["PWD"] = workingDirectory.path
            process.environment = mergedEnvironment(overrides: overrides)
            process.currentDirectoryURL = workingDirectory

            @Sendable
            func finish(_ action: () throws -> Result) {
                guard finishGate.claim() else { return }

                do {
                    continuation.resume(returning: try action())
                } catch {
                    continuation.resume(throwing: error)
                }
            }

            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                } else {
                    output.appendStandardOutput(data)
                }
            }

            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                } else {
                    output.appendStandardError(data)
                }
            }

            process.terminationHandler = { proc in
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                output.appendStandardOutput(stdoutPipe.fileHandleForReading.availableData)
                output.appendStandardError(stderrPipe.fileHandleForReading.availableData)

                let snapshot = output.snapshot()
                finish {
                    Result(
                        stdout: snapshot.stdout,
                        stderr: snapshot.stderr,
                        status: proc.terminationStatus
                    )
                }
            }

            do {
                try process.run()
                if let input, let data = input.data(using: .utf8) {
                    stdinPipe.fileHandleForWriting.write(data)
                    try? stdinPipe.fileHandleForWriting.close()
                }
            } catch {
                finish { throw ConnectorError.message(error.localizedDescription) }
                return
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if finishGate.claim() {
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    stderrPipe.fileHandleForReading.readabilityHandler = nil

                    if process.isRunning {
                        let pid = process.processIdentifier
                        // Capture the tree before signalling anything: killing the shell
                        // reparents its children to launchd, and the relationship is lost.
                        // Measured: `zsh -lc '... | script ... claude'` leaves `script` and
                        // `claude` running if only the shell is terminated.
                        let descendants = descendantProcessIDs(of: pid)

                        process.terminate()
                        for descendant in descendants {
                            kill(descendant, SIGTERM)
                        }

                        // SIGTERM is a request. Escalate so a wedged CLI cannot linger.
                        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                            if process.isRunning {
                                kill(pid, SIGKILL)
                            }
                            for descendant in descendants {
                                kill(descendant, SIGKILL)
                            }
                        }
                    }

                    continuation.resume(throwing: ConnectorError.message("Timed out while reading usage data."))
                }
            }
        }
    }

    /// Every PID descended from `root`, depth first.
    ///
    /// Must be called while `root` is still alive, otherwise its children have already been
    /// reparented to launchd and cannot be attributed back to us. Returns PIDs only - we
    /// never signal a process group, since our children inherit the app's own group and
    /// signalling it would hit Limit Bar itself.
    private static func descendantProcessIDs(of root: pid_t) -> [pid_t] {
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0

        guard sysctl(&name, UInt32(name.count), nil, &size, nil, 0) == 0, size > 0 else { return [] }

        let capacity = size / MemoryLayout<kinfo_proc>.stride + 16
        var entries = [kinfo_proc](repeating: kinfo_proc(), count: capacity)
        size = capacity * MemoryLayout<kinfo_proc>.stride

        guard sysctl(&name, UInt32(name.count), &entries, &size, nil, 0) == 0 else { return [] }

        var childrenByParent: [pid_t: [pid_t]] = [:]
        for entry in entries.prefix(size / MemoryLayout<kinfo_proc>.stride) {
            let pid = entry.kp_proc.p_pid
            guard pid > 1 else { continue }
            childrenByParent[entry.kp_eproc.e_ppid, default: []].append(pid)
        }

        var descendants: [pid_t] = []
        var queue = childrenByParent[root] ?? []
        while let pid = queue.popLast() {
            guard pid > 1, !descendants.contains(pid) else { continue }
            descendants.append(pid)
            queue.append(contentsOf: childrenByParent[pid] ?? [])
        }

        return descendants
    }

    private static func mergedEnvironment(overrides: [String: String] = [:]) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let additions = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
            NSHomeDirectory() + "/.bun/bin",
            NSHomeDirectory() + "/.npm-global/bin",
            NSHomeDirectory() + "/.local/bin"
        ]
        let existing = env["PATH"] ?? ""
        env["PATH"] = (additions + [existing]).joined(separator: ":")
        for (key, value) in overrides {
            env[key] = value
        }
        return env
    }
}

nonisolated final class ProcessFinishGate: @unchecked Sendable {
    private let lock = NSLock()
    private var didFinish = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard !didFinish else { return false }
        didFinish = true
        return true
    }
}

enum ConnectorError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case let .message(message): return message
        }
    }
}

private func number(_ value: Any?) -> Double? {
    if let value = value as? Double { return value }
    if let value = value as? Int { return Double(value) }
    if let value = value as? String { return Double(value) }
    return nil
}

private func date(_ value: Any?) -> Date? {
    if let timestamp = number(value) {
        return Date(timeIntervalSince1970: timestamp)
    }

    guard let string = value as? String else { return nil }
    return ISO8601DateFormatter().date(from: string)
}

private func clampPercent(_ value: Int) -> Int {
    min(max(value, 0), 100)
}

private func cleanError(_ stderr: String, fallback: String) -> String {
    let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
    let lower = trimmed.lowercased()

    if lower.contains("@openai/codex") &&
        lower.contains("enoent") &&
        lower.contains("spawn") {
        return "Codex CLI is installed, but its native executable is missing. Reinstall or update Codex with `npm install -g @openai/codex@latest`, then retry Connect."
    }

    return trimmed.isEmpty ? fallback : trimmed
}

private func openURL(_ string: String) {
    guard let url = URL(string: string) else { return }
    NSWorkspace.shared.open(url)
}

private extension String {
    var shellQuoted: String {
        "'\(replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    func strippingANSI() -> String {
        replacingOccurrences(of: #"\u001B\[[0-9;?]*[A-Za-z]"#, with: "", options: .regularExpression)
    }

    func matches(pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let range = NSRange(startIndex..<endIndex, in: self)
        return regex.matches(in: self, range: range).compactMap { match in
            guard match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: self) else { return nil }
            return String(self[range])
        }
    }

    /// Reset times mentioned in CLI prose, in the order they appear in the text -
    /// callers rely on index 0 being the first-mentioned window (typically the
    /// session/current limit) and index 1 the second (typically weekly).
    ///
    /// Claude Code's plain `/usage` output moved from relative phrasing ("resets
    /// in 4h") to an absolute wall-clock form ("resets Sep 21 at 12:10pm
    /// (Europe/Kiev)") at some point after this parser was written; verified live
    /// against claude 2.1.278, where the relative pattern no longer matches at
    /// all and the fallback silently guessed a fixed 5h/7d reset instead of the
    /// real one. Both forms are recognised here since either can appear
    /// depending on the CLI build.
    func extractResetDates(now: Date = Date()) -> [Date] {
        struct Occurrence { let location: Int; let date: Date }
        var found: [Occurrence] = []

        func addMatches(pattern: String, unit: TimeInterval) {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return }
            let range = NSRange(startIndex..<endIndex, in: self)
            for match in regex.matches(in: self, range: range) {
                guard match.numberOfRanges > 1,
                      let valueRange = Range(match.range(at: 1), in: self),
                      let value = Double(self[valueRange]) else { continue }
                found.append(Occurrence(location: match.range.location, date: now.addingTimeInterval(value * unit)))
            }
        }

        addMatches(pattern: #"resets?\s+(?:in\s+)?([0-9]+)\s*h\b"#, unit: 3600)
        addMatches(pattern: #"resets?\s+(?:in\s+)?([0-9]+)\s*d\b"#, unit: 24 * 3600)

        let absolutePattern = #"resets?\s+([A-Za-z]{3,9})\s+([0-9]{1,2})\s+at\s+([0-9]{1,2})(?::([0-9]{2}))?\s*([ap]m)\s*\(([^)]+)\)"#
        if let regex = try? NSRegularExpression(pattern: absolutePattern, options: [.caseInsensitive]) {
            let range = NSRange(startIndex..<endIndex, in: self)
            for match in regex.matches(in: self, range: range) {
                guard match.numberOfRanges > 6,
                      let monthRange = Range(match.range(at: 1), in: self),
                      let dayRange = Range(match.range(at: 2), in: self),
                      let hourRange = Range(match.range(at: 3), in: self),
                      let ampmRange = Range(match.range(at: 5), in: self),
                      let zoneRange = Range(match.range(at: 6), in: self),
                      let timeZone = TimeZone(identifier: String(self[zoneRange])),
                      let day = Int(self[dayRange]),
                      var hour = Int(self[hourRange])
                else { continue }

                let minute: Int
                if match.range(at: 4).location != NSNotFound, let minuteRange = Range(match.range(at: 4), in: self) {
                    minute = Int(self[minuteRange]) ?? 0
                } else {
                    minute = 0
                }

                let monthFormatter = DateFormatter()
                monthFormatter.locale = Locale(identifier: "en_US_POSIX")
                monthFormatter.dateFormat = "MMM"
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = timeZone
                guard let monthDate = monthFormatter.date(from: String(self[monthRange])) else { continue }
                let month = calendar.component(.month, from: monthDate)

                let isPM = self[ampmRange].lowercased() == "pm"
                if isPM, hour != 12 { hour += 12 }
                if !isPM, hour == 12 { hour = 0 }

                var components = DateComponents()
                components.year = calendar.component(.year, from: now)
                components.month = month
                components.day = day
                components.hour = hour
                components.minute = minute
                components.timeZone = timeZone

                guard var date = calendar.date(from: components) else { continue }
                // A reset time is always ahead of now. Landing more than a few days in
                // the past means the year rolled over, e.g. "Jan 2" parsed in late
                // December with no year in the source text to disambiguate.
                if date < now.addingTimeInterval(-3 * 24 * 3600) {
                    components.year = (components.year ?? 0) + 1
                    if let bumped = calendar.date(from: components) { date = bumped }
                }
                found.append(Occurrence(location: match.range.location, date: date))
            }
        }

        return found.sorted { $0.location < $1.location }.map(\.date)
    }
}

struct ContentView: View {
    @EnvironmentObject private var store: LimitStore

    var body: some View {
        VStack(spacing: 0) {
            HeaderView()
                .padding(.horizontal, 28)
                .padding(.vertical, 22)

            Divider()

            if store.connectedCount > 0 {
                DashboardView()
                    .padding(28)
            } else {
                OnboardingView()
                    .padding(28)
            }
        }
        .background(AppSurfaceBackground())
    }
}

struct HeaderView: View {
    @EnvironmentObject private var store: LimitStore

    var body: some View {
        HStack(spacing: 12) {
            if store.connectedCount > 0 {
                Image("AppLogo")
                    .resizable()
                    .scaledToFit()
                    .padding(7)
                    .frame(width: 38, height: 38)
            } else {
                HStack(spacing: 14) {
                    Image("AppLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 56, height: 56)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Limit Bar")
                            .font(.system(size: 28, weight: .semibold, design: .rounded))
                        Text("Track coding assistant usage")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            if let lowestRemaining = store.lowestRemaining {
                if let nextReset = store.nextReset { ResetBadge(date: nextReset) }
                BalanceBadge(percent: lowestRemaining)
            } else {
                Text("\(store.connectedCount)/\(LimitService.activeCases.count) connected")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.quaternary, in: Capsule())
            }
        }
    }
}

struct OnboardingView: View {
    @EnvironmentObject private var store: LimitStore

    var body: some View {
        VStack {
            Spacer(minLength: 12)

            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Connect services")
                        .font(.system(size: 30, weight: .semibold, design: .rounded))
                    Text("Limit Bar reads installed Codex, Claude Code, and Google Antigravity sessions. No passwords, no browser cookies, no fake balances.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(spacing: 12) {
                    ForEach(store.activeServices) { service in
                        ConnectServiceRow(service: service)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    SetupPromiseRow(symbol: "terminal", title: "Uses local tools", text: "Codex uses `codex app-server`; Claude Code and Antigravity use their installed CLIs.")
                    SetupPromiseRow(symbol: "clock", title: "Reset-first layout", text: "Current and weekly reset times stay visible before every long session.")
                    SetupPromiseRow(symbol: "lock", title: "Low-permission first", text: "Browser cookies and Keychain access are intentionally not part of this first connector pass.")
                }
            }
            .padding(22)
            .frame(width: 540, alignment: .leading)
            .limitCard()

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ConnectServiceRow: View {
    @EnvironmentObject private var store: LimitStore
    let service: ServiceLimit
    var showsSurface = true

    var body: some View {
        if showsSurface {
            rowContent
                .settingsCardSurface(cornerRadius: 15)
                .help(service.errorMessage ?? statusText)
        } else {
            rowContent
                .help(service.errorMessage ?? statusText)
        }
    }

    private var rowContent: some View {
        HStack(spacing: 10) {
            ServiceIcon(service: service.id, size: 36)

            VStack(alignment: .leading, spacing: 3) {
                Text(service.id.rawValue)
                    .font(.headline)
                Text(statusText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer()

            if service.isConnecting {
                ConnectingActionPill(compact: false)
            } else if service.isConnected {
                ServiceActionPill(service: service.id, isConnected: true, compact: false)
            } else {
                ServiceActionPill(service: service.id, isConnected: false, compact: false, disconnectedTitle: service.state == .failed ? "Retry" : "Connect")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(height: 56)
    }

    private var statusText: String {
        switch service.state {
        case .disconnected: return "Ready to connect"
        case .connecting: return "Reading local usage"
        case .connected: return connectedDetail
        case .failed: return shortProviderError(service)
        }
    }

    /// The status pill already says "Connected", so prefer account or plan detail here
    /// and only fall back to repeating the state when nothing else is known.
    private var connectedDetail: String {
        if let email = service.accountEmail, !email.isEmpty {
            return email
        }

        if let plan = service.planName,
           !plan.isEmpty,
           plan.caseInsensitiveCompare(service.id.shortName) != .orderedSame {
            return plan
        }

        return "Connected"
    }
}

struct ServiceActionPill: View {
    @EnvironmentObject private var store: LimitStore
    let service: LimitService
    let isConnected: Bool
    var compact: Bool
    var disconnectedTitle = "Connect"
    @State private var isHovering = false

    var body: some View {
        Button {
            if isConnected {
                store.disconnect(service)
            } else {
                store.connect(service)
            }
        } label: {
            HStack(spacing: compact ? 5 : 6) {
                Image(systemName: iconName)
                    .font(.system(size: compact ? 11 : 12, weight: .semibold))
                Text(title)
                    .font(compact ? .caption.weight(.semibold) : .callout.weight(.semibold))
                    .contentTransition(.opacity)
            }
            .foregroundStyle(foregroundColor)
            .frame(width: compact ? 94 : 108, height: compact ? 27 : 29)
            .background(backgroundFill, in: Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(borderColor, lineWidth: 1)
            )
            .shadow(color: shadowColor, radius: isConnected ? 4 : 2, y: 1)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(helpText)
    }

    private var title: String {
        if isConnected && isHovering {
            return "Disconnect"
        }
        if isConnected {
            return "Connected"
        }
        return disconnectedTitle
    }

    private var iconName: String {
        if isConnected && isHovering {
            return "xmark"
        }
        if isConnected {
            return "checkmark"
        }
        return disconnectedTitle == "Retry" ? "arrow.clockwise" : "link"
    }

    private var foregroundColor: Color {
        if isConnected {
            return isHovering ? SettingsPalette.destructiveText : SettingsPalette.successText
        }
        if disconnectedTitle == "Connect" {
            return SettingsPalette.actionText
        }
        return .primary
    }

    private var backgroundFill: AnyShapeStyle {
        if isConnected {
            if isHovering {
                return AnyShapeStyle(SettingsPalette.destructiveButtonSurface)
            }
            return AnyShapeStyle(SettingsPalette.successButtonSurface)
        }
        if disconnectedTitle == "Connect" {
            return AnyShapeStyle(isHovering ? SettingsPalette.actionButtonSurfaceHover : SettingsPalette.actionButtonSurface)
        }
        return AnyShapeStyle(SettingsPalette.buttonSurface)
    }

    private var borderColor: Color {
        if isConnected {
            return isHovering ? SettingsPalette.destructiveBorder : SettingsPalette.successBorder
        }
        if disconnectedTitle == "Connect" {
            return SettingsPalette.actionBorder
        }
        return SettingsPalette.border
    }

    private var shadowColor: Color {
        if isConnected {
            if isHovering {
                return SettingsPalette.redFill.opacity(0.08)
            }
            return SettingsPalette.greenFill.opacity(0.08)
        }
        if disconnectedTitle == "Connect" {
            return SettingsPalette.accentGlow.opacity(isHovering ? 0.10 : 0.06)
        }
        return .black.opacity(0.12)
    }

    private var helpText: String {
        if isConnected {
            return "Disconnect \(service.rawValue)"
        }
        return "Connect \(service.rawValue)"
    }
}

struct ConnectingActionPill: View {
    var compact = false

    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("Reading")
                .font(compact ? .caption.weight(.semibold) : .callout.weight(.semibold))
        }
        .foregroundStyle(.secondary)
        .frame(width: compact ? 94 : 108, height: compact ? 27 : 29)
        .background(SettingsPalette.buttonSurface, in: Capsule())
        .overlay(
            Capsule()
                .stroke(SettingsPalette.border, lineWidth: 1)
        )
    }
}

struct UpdateActionPill: View {
    let isEnabled: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .semibold))
                Text("Check for Updates")
                    .font(.callout.weight(.semibold))
            }
            .foregroundStyle(foregroundColor)
            .frame(width: 144, height: 29)
            .background(backgroundFill, in: Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(borderColor, lineWidth: 1)
            )
            .shadow(color: shadowColor, radius: isEnabled ? 4 : 0, y: 1)
            .opacity(isEnabled ? 1 : 0.62)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .onHover { isHovering = $0 }
        .help(isEnabled ? "Check for software updates" : "Software updates are not configured")
    }

    private var foregroundColor: Color {
        isEnabled ? SettingsPalette.actionText : .secondary
    }

    private var backgroundFill: AnyShapeStyle {
        if isEnabled {
            return AnyShapeStyle(isHovering ? SettingsPalette.actionButtonSurfaceHover : SettingsPalette.actionButtonSurface)
        }

        return AnyShapeStyle(SettingsPalette.buttonSurface)
    }

    private var borderColor: Color {
        isEnabled ? SettingsPalette.actionBorder : SettingsPalette.border
    }

    private var shadowColor: Color {
        isEnabled ? SettingsPalette.accentGlow.opacity(isHovering ? 0.10 : 0.06) : .clear
    }
}

struct SetupPromiseRow: View {
    let symbol: String
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption.weight(.semibold))
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct DashboardView: View {
    @EnvironmentObject private var store: LimitStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Balance")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button {
                    store.resetSetup()
                } label: {
                    Label("Start over", systemImage: "arrow.uturn.backward")
                }
                .buttonStyle(DashboardActionButtonStyle())

                Button {
                    store.refreshConnected()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(DashboardActionButtonStyle())
            }

            VStack(spacing: 12) {
                ForEach(store.activeServices.filter(\.isConnected)) { service in
                    ServiceBalanceCard(service: service)
                }
            }

            if store.connectedCount < LimitService.activeCases.count {
                VStack(spacing: 10) {
                    ForEach(store.activeServices.filter { !$0.isConnected }) { service in
                        ConnectServiceRow(service: service)
                    }
                }
                .padding(.top, 6)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct ServiceBalanceCard: View {
    let service: ServiceLimit

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                ServiceIcon(service: service.id, size: 40)

                VStack(alignment: .leading, spacing: 2) {
                    Text(service.id.rawValue)
                        .font(.headline)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if let planName = service.planName {
                    Text(planName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.quaternary, in: Capsule())
                }
            }

            HStack(spacing: 10) {
                BalanceMetric(kind: "Session", balance: service.current)
                BalanceMetric(kind: "Weekly", balance: service.weekly)
            }

            if let availabilityMessage = service.limitAvailabilityMessage {
                Label {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(availabilityMessage.title)
                            .font(.caption.weight(.semibold))
                        Text(availabilityMessage.detail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } icon: {
                    Image(systemName: availabilityMessage.systemImage)
                        .foregroundStyle(.orange)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.orange.opacity(0.18), lineWidth: 1)
                )
            }

            if service.id == .codex, let credits = service.credits {
                CreditsRow(credits: credits)
            }

            if let warningText = service.warningText {
                Label(warningText, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.orange)
            }
        }
        .padding(14)
        .limitCard()
        .accessibilityElement(children: .combine)
    }

    private var subtitle: String {
        if let email = service.accountEmail, !email.isEmpty {
            return service.lastUpdated.map { "\(email) · updated \($0.formatted(date: .omitted, time: .shortened))" } ?? email
        }

        if let lastUpdated = service.lastUpdated {
            return "Updated \(lastUpdated.formatted(date: .omitted, time: .shortened))"
        }

        return "Connected"
    }
}

struct CreditsRow: View {
    let credits: CreditBalance

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Credits")
                    .font(.callout.weight(.semibold))
                Spacer()
                Text(valueText)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(credits.hasCredits || credits.unlimited ? .primary : .secondary)
            }

            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .settingsCardSurface(cornerRadius: 13, fill: SettingsPalette.surfaceRaised)
    }

    private var valueText: String {
        if credits.unlimited { return "Unlimited" }
        return "\(credits.remaining) left"
    }

    private var caption: String {
        if credits.unlimited { return "Extra usage is available without a fixed balance." }
        if credits.hasCredits { return "Credits can continue Codex beyond plan limits." }
        return "No extra credits available."
    }
}

struct BalanceMetric: View {
    let kind: String
    let balance: LimitBalance?

    private var style: UsageAccentStyle {
        kind.localizedCaseInsensitiveContains("weekly") ? .weekly : .current
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(balance?.title ?? "Usage limit")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text(kind)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(style.textColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(style.chipFill, in: Capsule())
                        .overlay(
                            Capsule()
                                .stroke(style.chipBorder, lineWidth: 1)
                        )
                }
                Spacer()
            }

            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(balance.map { "\($0.remainingPercent)%" } ?? "--")
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text("remaining")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            LimitProgressBar(percent: balance?.remainingPercent ?? 0, style: style)
                .frame(height: 12)

            Text(resetText)
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()

            Text(headroomText)
                .font(.caption.weight(.medium))
                .foregroundStyle(headroomColor)
        }
        .padding(13)
        .settingsCardSurface(cornerRadius: 16, fill: SettingsPalette.surfaceRaised)
    }

    private var resetText: String {
        guard let balance else { return "Waiting for balance" }
        guard balance.hasKnownReset else { return LimitBalance.unknownResetText(for: balance) }
        return "Resets \(balance.resetsAt.formatted(date: kind == "Weekly" ? .abbreviated : .omitted, time: .shortened))"
    }

    private var headroomText: String {
        guard let balance else { return "Waiting for usage" }
        if balance.remainingPercent > 40 { return "Lasts until reset" }
        if balance.remainingPercent >= 20 { return "Limited headroom" }
        return "Low headroom"
    }

    private var headroomColor: Color {
        guard let balance else { return .secondary }
        if balance.remainingPercent < 20 { return .orange }
        return .secondary
    }

}

struct LimitProgressBar: View {
    let percent: Int
    let style: UsageAccentStyle

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(trackFill)
                    .overlay(
                        Capsule()
                            .stroke(trackBorder, lineWidth: 1)
                    )

                Capsule()
                    .fill(style.fill)
                    .frame(width: max(proxy.size.width * CGFloat(percent) / 100, percent > 0 ? 10 : 0))
                    .overlay(
                        Capsule()
                            .stroke(style.highlightBorder, lineWidth: 1)
                    )
                    .shadow(color: style.shadowColor, radius: 4, y: 1)
            }
        }
    }

    private var trackFill: AnyShapeStyle {
        AnyShapeStyle(
            LinearGradient(
                colors: [
                    SettingsPalette.trackTop,
                    SettingsPalette.trackBottom
                ],
                startPoint: .trailing,
                endPoint: .leading
            )
        )
    }

    private var trackBorder: Color {
        SettingsPalette.trackBorder
    }
}

struct MenuBarView: View {
    @EnvironmentObject private var store: LimitStore

    var body: some View {
        Group {
            if store.connectedCount == 0 {
                MenuSetupView()
            } else {
                MenuUsageView()
            }
        }
        .padding(14)
        .frame(width: 340)
    }
}

struct MenuBarProgressIcon: View {
    @EnvironmentObject private var store: LimitStore

    private var currentPercent: Int {
        store.activeServices
            .filter(\.isConnected)
            .compactMap { $0.current?.remainingPercent }
            .min() ?? 0
    }

    private var weeklyPercent: Int {
        store.activeServices
            .filter(\.isConnected)
            .compactMap { $0.weekly?.remainingPercent }
            .min() ?? 0
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            VerticalMenuBar(percent: currentPercent, style: .current)
            VerticalMenuBar(percent: weeklyPercent, style: .weekly)
        }
        .padding(.horizontal, 2)
        .frame(width: 18, height: 18)
        .accessibilityLabel("Limit Bar")
    }
}

struct VerticalMenuBar: View {
    let percent: Int
    let style: UsageAccentStyle

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottom) {
                Capsule()
                    .fill(SettingsPalette.iconTrack)
                    .overlay(
                        Capsule()
                            .stroke(SettingsPalette.iconTrackBorder, lineWidth: 0.5)
                    )

                Capsule()
                    .fill(percent == 0 ? AnyShapeStyle(SettingsPalette.iconTrackMuted) : style.fill)
                    .frame(height: max(proxy.size.height * CGFloat(percent) / 100, percent > 0 ? 4 : 0))
            }
        }
        .frame(width: 6)
    }
}

struct MenuSetupView: View {
    @EnvironmentObject private var store: LimitStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("AI Usage Limits")
                        .font(.system(size: 16, weight: .semibold))
                    Text("Connect local AI usage")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                MenuHeaderIconButton(systemName: "gearshape", helpText: "Open settings") {
                    SettingsWindowPresenter.shared.open(store: store)
                }

                MenuHeaderIconButton(systemName: "power") {
                    NSApp.terminate(nil)
                }
            }

            VStack(spacing: 10) {
                ForEach(store.activeServices) { service in
                    MenuConnectRow(service: service)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                SetupPromiseRow(symbol: "terminal", title: "Local tools", text: "Uses your installed Codex, Claude Code, and Antigravity sessions.")
                SetupPromiseRow(symbol: "clock", title: "Reset first", text: "Shows current and weekly reset times.")
                SetupPromiseRow(symbol: "lock", title: "No passwords", text: "No browser cookies or passwords in this first pass.")
            }
            .padding(.top, 2)
        }
    }
}

struct MenuUsageView: View {
    @EnvironmentObject private var store: LimitStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("AI Usage Limits")
                    .font(.system(size: 16, weight: .semibold))
                Spacer()

                if store.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 26, height: 26)
                        .help("Refreshing limits...")
                } else {
                    MenuHeaderIconButton(systemName: "arrow.clockwise", helpText: "Refresh limits") {
                        store.refreshConnected()
                    }
                }

                MenuHeaderIconButton(systemName: "gearshape", helpText: "Open settings") {
                    SettingsWindowPresenter.shared.open(store: store)
                }

                MenuHeaderIconButton(systemName: "power") {
                    NSApp.terminate(nil)
                }
            }

            ForEach(store.activeServices.filter(\.isConnected)) { service in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        ServiceIcon(service: service.id, size: 22)
                        Text(service.id.shortName)
                            .font(.callout.weight(.medium))

                        Spacer(minLength: 8)

                        // Always present, not conditional, so its presence never shifts
                        // the card's height - it used to appear as a footnote once the
                        // data turned a minute old, which visibly jumped the layout at
                        // that exact moment. `.center` (the HStack default) keeps the
                        // icon vertically centered against the title; `.firstTextBaseline`
                        // was tried here first and pulled the icon toward the text's
                        // baseline instead, since a plain image has none of its own.
                        HStack(spacing: 5) {
                            if service.isShowingStaleData {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(SettingsPalette.thresholdWarn)
                            }

                            Text(freshnessText(for: service))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }

                    CompactBalanceRow(kind: "Current", balance: service.current, isRefreshing: store.isManuallyRefreshing(service.id))
                    CompactBalanceRow(kind: "Weekly", balance: service.weekly, isRefreshing: store.isManuallyRefreshing(service.id))
                }
                .padding(10)
                .settingsCardSurface(cornerRadius: 14, fill: SettingsPalette.surfaceRaised)
            }

        }
    }

    /// "Updated 4m ago", or a quieter note that the last background refresh failed and
    /// these numbers are therefore older than they look - the small warning glyph next
    /// to it carries the emphasis, so the text itself stays as unobtrusive as the normal
    /// case rather than turning the whole corner orange.
    private func freshnessText(for service: ServiceLimit) -> String {
        guard let updated = service.lastUpdated else { return "" }

        let age = Date().timeIntervalSince(updated)
        let elapsed = Self.ageText(age) ?? "just now"

        if service.isShowingStaleData {
            return "Couldn't refresh · \(elapsed) ago"
        }

        return age >= 60 ? "Updated \(elapsed) ago" : "Updated just now"
    }

    /// DateComponentsFormatter, not RelativeDateTimeFormatter: the latter returns a whole
    /// phrase ("4 minutes ago") that reads wrong once embedded in a sentence.
    private static func ageText(_ interval: TimeInterval) -> String? {
        guard interval >= 60 else { return nil }

        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 1
        formatter.allowedUnits = interval >= 86_400 ? [.day] : (interval >= 3_600 ? [.hour] : [.minute])

        guard let text = formatter.string(from: interval), !text.isEmpty else { return nil }
        return text
    }
}

struct MenuConnectRow: View {
    @EnvironmentObject private var store: LimitStore
    let service: ServiceLimit
    var compact = false

    var body: some View {
        HStack(spacing: 10) {
            ServiceIcon(service: service.id, size: compact ? 24 : 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(service.id.rawValue)
                    .font(compact ? .caption.weight(.semibold) : .callout.weight(.semibold))
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer()

            if service.isConnecting {
                ConnectingActionPill(compact: true)
            } else if service.isConnected {
                ServiceActionPill(service: service.id, isConnected: true, compact: true)
            } else {
                ServiceActionPill(service: service.id, isConnected: false, compact: true, disconnectedTitle: service.state == .failed ? "Retry" : "Connect")
            }
        }
        .padding(.horizontal, compact ? 10 : 12)
        .padding(.vertical, compact ? 8 : 11)
        .settingsCardSurface(cornerRadius: 13, fill: SettingsPalette.surfaceRaised)
    }

    private var statusText: String {
        switch service.state {
        case .disconnected: return compact ? "Not connected" : "Ready to connect"
        case .connecting: return "Reading local usage"
        case .connected: return "Connected"
        case .failed: return shortProviderError(service)
        }
    }
}

private func shortProviderError(_ service: ServiceLimit) -> String {
    guard let message = service.errorMessage else { return "Connection failed" }
    let lower = message.lowercased()

    if service.id == .claude {
        if lower.contains("not logged in") || lower.contains("login") {
            return "Sign in required"
        }
        if lower.contains("session/api") {
            return "Session/API data only"
        }
        if lower.contains("rate_limits") || lower.contains("5-hour") || lower.contains("weekly") {
            return "Subscription limits unavailable"
        }
        if lower.contains("timed out") {
            return "Claude did not respond"
        }
    }

    if service.id == .antigravity {
        if lower.contains("update") || lower.contains("no longer supported") {
            return "Update required"
        }
        if lower.contains("google login") || lower.contains("google account") || lower.contains("sign in") || lower.contains("login") {
            return "Google sign-in required"
        }
        if lower.contains("usage limits") || lower.contains("/usage") || lower.contains("quota") {
            return "Usage limits unavailable"
        }
    }

    if lower.contains("timed out") {
        return "Timed out"
    }
    if lower.contains("not found") {
        return "CLI not found"
    }

    return message
}

struct MenuHeaderIconButton: View {
    let systemName: String
    var helpText = "Quit Limit Bar"
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 26, height: 26)
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(helpText)
    }
}

struct SettingsWindowView: View {
    @EnvironmentObject private var store: LimitStore
    @StateObject private var notificationSettings = NotificationPreferencesStore.shared
    @StateObject private var menuBarDisplaySettings = MenuBarDisplayPreferencesStore.shared
    @StateObject private var refreshPreferences = RefreshPreferencesStore.shared
    @StateObject private var appUpdater = AppUpdater.shared
    @State private var startsAtLogin = LaunchAtLoginController.isEnabled
    @State private var notificationDetailsExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            settingsHeader

            settingsSection("Providers") {
                providersCard
            }

            settingsSection("General") {
                appOptionsCard
            }

            settingsSection("Notifications") {
                notificationCard
            }

            settingsFooter
        }
        .padding(22)
        .frame(width: 580, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        .background(AppSurfaceBackground())
        .onAppear {
            notificationDetailsExpanded = notificationSettings.isEnabled
        }
        .onChange(of: notificationSettings.isEnabled) { _, isEnabled in
            updateNotificationDetailsVisibility(isEnabled: isEnabled)
        }
    }

    private var settingsHeader: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Limit Bar Settings")
                    .font(.system(size: 25, weight: .semibold, design: .rounded))
                Text("Manage local providers, alerts, and updates.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            UpdateActionPill(isEnabled: appUpdater.canCheckForUpdates) {
                appUpdater.checkForUpdates()
            }
        }
    }

    private func settingsSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .tracking(0.9)
                .foregroundStyle(.tertiary)
                .padding(.leading, 4)

            content()
        }
    }

    private var providersCard: some View {
        VStack(spacing: 0) {
            ForEach(Array(store.activeServices.enumerated()), id: \.element.id) { index, service in
                if index > 0 {
                    Rectangle()
                        .fill(SettingsPalette.divider)
                        .frame(height: 1)
                        .padding(.leading, 60)
                }

                ConnectServiceRow(service: service, showsSurface: false)
            }
        }
        .settingsCardSurface(cornerRadius: 15)
    }

    private var settingsFooter: some View {
        VStack(spacing: 4) {
            Text("Limit Bar v\(appVersion) (Build \(appBuild))")

            HStack(spacing: 3) {
                Text("Developed by")

                Link("Artem Svitelskyi", destination: URL(string: "https://artsvit.com")!)
                    .foregroundStyle(.primary)
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .padding(.top, 2)
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    private var appBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    }

    private var appOptionsCard: some View {
        VStack(spacing: 10) {
            startAtLoginRow

            Rectangle()
                .fill(SettingsPalette.divider)
                .frame(height: 1)

            menuBarDisplayRow

            Rectangle()
                .fill(SettingsPalette.divider)
                .frame(height: 1)

            refreshCadenceRow

            Rectangle()
                .fill(SettingsPalette.divider)
                .frame(height: 1)

            automaticUpdatesRow
        }
        .padding(12)
        .settingsCardSurface(cornerRadius: 15)
    }

    private var refreshCadenceRow: some View {
        HStack(spacing: 10) {
            SettingsAccentIcon(systemName: "arrow.clockwise", tint: .accent)

            VStack(alignment: .leading, spacing: 3) {
                Text("Refresh interval")
                    .font(.headline)
                Text("How often Limit Bar refreshes limits in the background.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            Picker("", selection: $refreshPreferences.interval) {
                ForEach(RefreshInterval.allCases) { item in
                    Text(item.shortName).tag(item)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 95)
        }
    }

    private var automaticUpdatesRow: some View {
        HStack(spacing: 10) {
            SettingsAccentIcon(systemName: "arrow.triangle.2.circlepath", tint: .accent)

            VStack(alignment: .leading, spacing: 3) {
                Text("Automatic update checks")
                    .font(.headline)
                Text("Look for a new version when Limit Bar starts, then once a day.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            Toggle("", isOn: automaticUpdateCheckBinding)
                .labelsHidden()
                .toggleStyle(BrandedLoginToggleStyle())
                .disabled(!appUpdater.isConfigured)
        }
        .opacity(appUpdater.isConfigured ? 1 : 0.55)
        .help(appUpdater.isConfigured ? "Check for updates in the background" : appUpdater.statusText)
    }

    private var automaticUpdateCheckBinding: Binding<Bool> {
        Binding(
            get: { appUpdater.automaticallyChecksForUpdates },
            set: { appUpdater.automaticallyChecksForUpdates = $0 }
        )
    }

    private var startAtLoginRow: some View {
        HStack(spacing: 10) {
            SettingsAccentIcon(systemName: "power", tint: .accent)

            VStack(alignment: .leading, spacing: 3) {
                Text("Start at login")
                    .font(.headline)
                Text("Open Limit Bar when you sign in.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            Toggle("", isOn: $startsAtLogin)
                .labelsHidden()
                .toggleStyle(BrandedLoginToggleStyle())
                .onChange(of: startsAtLogin) { _, isEnabled in
                    LaunchAtLoginController.setEnabled(isEnabled)
                    startsAtLogin = LaunchAtLoginController.isEnabled
                }
        }
    }

    private var menuBarDisplayRow: some View {
        HStack(spacing: 10) {
            SettingsAccentIcon(systemName: "percent", tint: .accent)

            VStack(alignment: .leading, spacing: 3) {
                Text("Show current percent")
                    .font(.headline)
                Text("Show percentages instead of usage bars for each provider.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            Toggle("", isOn: menuBarPercentBinding)
                .labelsHidden()
                .toggleStyle(BrandedLoginToggleStyle())
        }
    }

    private var notificationCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                SettingsAccentIcon(systemName: "bell", tint: .accent)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Usage notifications")
                        .font(.headline)
                    Text("Alert when remaining usage drops below your limits.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer()

                Toggle("", isOn: notificationEnabledBinding)
                    .labelsHidden()
                    .toggleStyle(BrandedLoginToggleStyle())
            }

            AccordionContent(isExpanded: notificationDetailsExpanded) {
                VStack(alignment: .leading, spacing: 10) {
                    Rectangle()
                        .fill(SettingsPalette.divider)
                        .frame(height: 1)

                    HStack(spacing: 10) {
                        Text("Alert thresholds")
                            .font(.callout.weight(.semibold))

                        Spacer(minLength: 0)

                        SettingsPillButton(title: "Send a test") {
                            UsageNotificationCenter.sendTestNotification()
                        }
                    }

                    HStack(spacing: 8) {
                        ThresholdTile(severity: .early, value: notificationSettings.thresholdBinding(at: 0))
                        ThresholdTile(severity: .warn, value: notificationSettings.thresholdBinding(at: 1))
                        ThresholdTile(severity: .critical, value: notificationSettings.thresholdBinding(at: 2))
                    }

                    HStack(spacing: 8) {
                        Text("0%")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()

                        ThresholdSlider(values: thresholdValues) { index, newValue in
                            notificationSettings.setThreshold(newValue, at: index)
                        }

                        Text("100%")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                    }

                    Text("Drag a handle or type a value. Recommended: 50%, 25%, and 10%. Applies to current and weekly balances.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 10)
            }
        }
        .padding(12)
        .settingsCardSurface(cornerRadius: 15)
    }

    private var thresholdValues: [Int] {
        (0..<3).map { notificationSettings.thresholdBinding(at: $0).wrappedValue }
    }

    private var notificationEnabledBinding: Binding<Bool> {
        Binding(
            get: { notificationSettings.isEnabled },
            set: { isEnabled in
                notificationSettings.isEnabled = isEnabled
                if isEnabled {
                    UsageNotificationCenter.requestAuthorizationIfNeeded()
                }
            }
        )
    }

    private var menuBarPercentBinding: Binding<Bool> {
        Binding(
            get: { menuBarDisplaySettings.showsCurrentPercent },
            set: { menuBarDisplaySettings.showsCurrentPercent = $0 }
        )
    }

    private func updateNotificationDetailsVisibility(isEnabled: Bool) {
        withAnimation(SettingsMotion.notificationsExpansion) {
            notificationDetailsExpanded = isEnabled
        }
    }
}

private enum SettingsMotion {
    static let notificationsExpansion = Animation.easeInOut(duration: 0.26)
}

private struct AccordionContent<Content: View>: View {
    let isExpanded: Bool
    let content: Content
    @State private var contentHeight: CGFloat = 0

    init(isExpanded: Bool, @ViewBuilder content: () -> Content) {
        self.isExpanded = isExpanded
        self.content = content()
    }

    var body: some View {
        content
            .fixedSize(horizontal: false, vertical: true)
            .background(
                GeometryReader { proxy in
                    Color.clear
                        .preference(key: AccordionHeightPreferenceKey.self, value: proxy.size.height)
                }
            )
            .frame(height: isExpanded ? contentHeight : 0, alignment: .top)
            .opacity(contentHeight == 0 ? 0 : 1)
        .clipped()
        .allowsHitTesting(isExpanded)
        .accessibilityHidden(!isExpanded)
        .onPreferenceChange(AccordionHeightPreferenceKey.self) { height in
            contentHeight = height
        }
        .animation(SettingsMotion.notificationsExpansion, value: isExpanded)
    }
}

private struct AccordionHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

enum LaunchAtLoginController {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
        } catch {
            // Keep UI simple for now. The toggle snaps back on next state read.
        }
    }
}

struct BrandedLoginToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                Capsule()
                    .fill(trackFill(isOn: configuration.isOn))
                    .overlay(
                        Capsule()
                            .strokeBorder(trackBorder(isOn: configuration.isOn), lineWidth: 1)
                    )

                Circle()
                    .fill(knobFill(isOn: configuration.isOn))
                    .frame(width: 22, height: 22)
                    .overlay(
                        Circle()
                            .strokeBorder(configuration.isOn ? SettingsPalette.accentBorder.opacity(0.32) : SettingsPalette.borderStrong, lineWidth: 0.8)
                    )
                    .shadow(color: .black.opacity(configuration.isOn ? 0.28 : 0.12), radius: 4, y: 1)
                    .padding(3)
            }
            .frame(width: 48, height: 28)
            .animation(.spring(response: 0.25, dampingFraction: 0.82), value: configuration.isOn)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Start at login")
        .accessibilityValue(configuration.isOn ? "On" : "Off")
    }

    private func trackFill(isOn: Bool) -> AnyShapeStyle {
        if isOn {
            AnyShapeStyle(
                LinearGradient(
                    colors: [SettingsPalette.accentToggleStart, SettingsPalette.accentToggleEnd],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
        } else {
            AnyShapeStyle(SettingsPalette.buttonSurface)
        }
    }

    private func trackBorder(isOn: Bool) -> Color {
        if isOn {
            return SettingsPalette.accentBorder.opacity(0.22)
        } else {
            return SettingsPalette.border
        }
    }

    private func knobFill(isOn: Bool) -> AnyShapeStyle {
        if isOn {
            AnyShapeStyle(SettingsPalette.knobOn)
        } else {
            AnyShapeStyle(SettingsPalette.knobOff)
        }
    }
}

enum ThresholdSeverity: CaseIterable {
    case early
    case warn
    case critical

    var title: String {
        switch self {
        case .early: return "Early"
        case .warn: return "Warn"
        case .critical: return "Critical"
        }
    }

    var color: Color {
        switch self {
        case .early: return SettingsPalette.thresholdEarly
        case .warn: return SettingsPalette.thresholdWarn
        case .critical: return SettingsPalette.thresholdCritical
        }
    }
}

/// One threshold input. The tile itself is the field: a single surface that takes
/// focus, so there is no box-inside-a-box nesting around the number.
struct ThresholdTile: View {
    let severity: ThresholdSeverity
    @Binding var value: Int
    @FocusState private var isFocused: Bool
    @State private var draftText = ""
    @State private var isHovering = false

    private let step = 5

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Circle()
                    .fill(severity.color)
                    .frame(width: 7, height: 7)

                Text(severity.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Spacer(minLength: 0)
            }

            HStack(alignment: .firstTextBaseline, spacing: 1) {
                TextField("50", text: $draftText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .multilineTextAlignment(.leading)
                    .frame(width: 42, alignment: .leading)
                    .focused($isFocused)
                    .onSubmit(commitDraft)
                    .onChange(of: draftText) { _, text in
                        sanitize(text)
                    }
                    .onChange(of: value) { _, newValue in
                        if !isFocused {
                            draftText = "\(newValue)"
                        }
                    }
                    .onChange(of: isFocused) { _, focused in
                        if focused {
                            draftText = "\(value)"
                        } else {
                            commitDraft()
                        }
                    }
                    .accessibilityLabel("\(severity.title) threshold")

                Text("%")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)

                Spacer(minLength: 4)

                stepper
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 4 }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SettingsPalette.surfaceRaised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(isFocused ? SettingsPalette.inputFocusBorder : SettingsPalette.border, lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onHover { isHovering = $0 }
        .onTapGesture { isFocused = true }
        .onAppear { draftText = "\(value)" }
    }

    private var stepper: some View {
        HStack(spacing: 4) {
            stepButton(symbol: "minus", delta: -step, hint: "Decrease")
            stepButton(symbol: "plus", delta: step, hint: "Increase")
        }
        .opacity(isHovering || isFocused ? 1 : 0.5)
        .animation(.easeInOut(duration: 0.15), value: isHovering)
        .animation(.easeInOut(duration: 0.15), value: isFocused)
    }

    private func stepButton(symbol: String, delta: Int, hint: String) -> some View {
        Button {
            adjust(by: delta)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
                .background(SettingsPalette.buttonSurface, in: Circle())
                .overlay(
                    Circle()
                        .strokeBorder(SettingsPalette.border, lineWidth: 1)
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(hint) \(severity.title) threshold")
    }

    private func adjust(by delta: Int) {
        let next = clamp(value + delta)
        value = next
        draftText = "\(next)"
    }

    private func clamp(_ candidate: Int) -> Int {
        min(max(candidate, 1), 99)
    }

    private func sanitize(_ text: String) {
        let filtered = String(text.filter(\.isNumber).prefix(2))
        guard filtered != text else { return }
        draftText = filtered
    }

    private func commitDraft() {
        guard let typedValue = Int(draftText) else {
            draftText = "\(value)"
            return
        }

        let clampedValue = clamp(typedValue)
        value = clampedValue
        draftText = "\(clampedValue)"
    }
}

/// The thresholds as one draggable scale, read right to left as a balance drains from
/// full to empty.
///
/// The coloured bands are the territory of each alert: everything left of the Critical
/// handle is critical, and so on. That makes a handle's position mean something while it
/// is being dragged, which a row of static markers never did.
struct ThresholdSlider: View {
    let values: [Int]
    /// (index, new value). The store clamps against neighbours.
    let onChange: (Int, Int) -> Void

    @State private var draggingIndex: Int?

    private let trackHeight: CGFloat = 8
    private let handleSize: CGFloat = 16
    private let severities = ThresholdSeverity.allCases

    var body: some View {
        GeometryReader { proxy in
            let usable = max(proxy.size.width - handleSize, 1)

            ZStack(alignment: .leading) {
                track(usable: usable)

                ForEach(orderedHandleIndices, id: \.self) { index in
                    handle(at: index, usable: usable)
                }
            }
            .frame(width: proxy.size.width, height: handleSize, alignment: .leading)
        }
        .frame(height: handleSize)
    }

    // MARK: - Track

    private func track(usable: CGFloat) -> some View {
        Capsule()
            .fill(SettingsPalette.sliderTrack)
            .frame(width: usable, height: trackHeight)
            .overlay(alignment: .leading) {
                ZStack(alignment: .leading) {
                    // Painted widest first so narrower bands sit on top.
                    band(from: 0, to: value(at: 0), color: severities[0].color, usable: usable)
                    band(from: 0, to: value(at: 1), color: severities[1].color, usable: usable)
                    band(from: 0, to: value(at: 2), color: severities[2].color, usable: usable)
                }
            }
            .clipShape(Capsule())
            .offset(x: handleSize / 2)
    }

    private func band(from: Int, to: Int, color: Color, usable: CGFloat) -> some View {
        let width = max(CGFloat(to - from) / 100 * usable, 0)
        return Rectangle()
            .fill(color.opacity(0.85))
            .frame(width: width, height: trackHeight)
            .offset(x: CGFloat(from) / 100 * usable)
    }

    // MARK: - Handles

    /// The handle being dragged is drawn last so it stays on top of its neighbours.
    private var orderedHandleIndices: [Int] {
        let all = Array(severities.indices)
        guard let draggingIndex else { return all }
        return all.filter { $0 != draggingIndex } + [draggingIndex]
    }

    private func handle(at index: Int, usable: CGFloat) -> some View {
        let severity = severities[index]
        let isDragging = draggingIndex == index

        return Circle()
            .fill(severity.color)
            .frame(width: handleSize, height: handleSize)
            .overlay(
                Circle().strokeBorder(SettingsPalette.surfaceRaised, lineWidth: 2)
            )
            .shadow(color: .black.opacity(0.45), radius: isDragging ? 5 : 3, y: 1)
            .scaleEffect(isDragging ? 1.18 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isDragging)
            // Generous invisible hit area: the visual handle is smaller than a
            // comfortable target, especially when two sit close together.
            .frame(width: handleSize + 14, height: handleSize + 12)
            .contentShape(Circle())
            .offset(x: position(for: value(at: index), usable: usable) - (handleSize + 14) / 2 + handleSize / 2)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        draggingIndex = index
                        onChange(index, percent(at: drag.location.x, usable: usable))
                    }
                    .onEnded { _ in
                        draggingIndex = nil
                    }
            )
            .accessibilityElement()
            .accessibilityLabel("\(severity.title) threshold")
            .accessibilityValue("\(value(at: index)) percent")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: onChange(index, value(at: index) + 1)
                case .decrement: onChange(index, value(at: index) - 1)
                @unknown default: break
                }
            }
    }

    // MARK: - Geometry

    private func value(at index: Int) -> Int {
        values.indices.contains(index) ? values[index] : 0
    }

    private func position(for value: Int, usable: CGFloat) -> CGFloat {
        CGFloat(min(max(value, 0), 100)) / 100 * usable
    }

    private func percent(at x: CGFloat, usable: CGFloat) -> Int {
        let clamped = min(max(x - handleSize / 2, 0), usable)
        return Int((clamped / usable * 100).rounded())
    }
}

/// Small bordered button so secondary actions read as tappable rather than as label text.
struct SettingsPillButton: View {
    let title: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(SettingsPalette.actionText)
                .padding(.horizontal, 11)
                .padding(.vertical, 5)
                .background(
                    isHovering ? SettingsPalette.actionButtonSurfaceHover : SettingsPalette.actionButtonSurface,
                    in: Capsule()
                )
                .overlay(
                    Capsule()
                        .strokeBorder(SettingsPalette.actionBorder, lineWidth: 1)
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

struct MenuActionRow: View {
    let title: String
    let systemImage: String
    var shortcut: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .frame(width: 18)
                Text(title)
                Spacer()
                if let shortcut {
                    Text(shortcut)
                        .foregroundStyle(.tertiary)
                        .monospaced()
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .font(.callout.weight(.medium))
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(.background.opacity(0.001), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

@MainActor
enum ErrorAlertPresenter {
    static func show(message: String) {
        let alert = NSAlert()
        alert.messageText = "Connection failed"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.icon = appAlertIcon()
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    static func appAlertIcon() -> NSImage? {
        guard let baseImage = NSApp.applicationIconImage ?? NSImage(named: "AppLogo") else {
            return nil
        }
        let size = NSSize(width: 64, height: 64)
        let rect = NSRect(origin: .zero, size: size)
        let image = NSImage(size: size)

        image.lockFocus()
        defer { image.unlockFocus() }

        NSColor.clear.setFill()
        rect.fill()

        let clipPath = NSBezierPath(roundedRect: rect, xRadius: 14, yRadius: 14)
        clipPath.addClip()
        baseImage.draw(in: rect)

        return image
    }
}

@MainActor
enum AntigravityAuthPresenter {
    static func show(message: String) {
        let alert = NSAlert()
        alert.messageText = "Connect Antigravity CLI"
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.icon = ErrorAlertPresenter.appAlertIcon()
        alert.addButton(withTitle: "Open CLI Login")
        alert.addButton(withTitle: "OK")

        if alert.runModal() == .alertFirstButtonReturn {
            openAntigravityCLI()
        }
    }

    private static func openAntigravityCLI() {
        let script = """
        tell application "Terminal"
            activate
            do script "agy"
        end tell
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        process.currentDirectoryURL = ProcessRunner.defaultProbeDirectory()
        try? process.run()
    }
}

/// Stand-in for `LimitProgressBar` while a manual refresh runs: the same empty track
/// at the same size, with a highlight sweeping across it, so only the bar itself
/// signals loading and nothing around it moves.
struct LimitBarSkeleton: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = 0

    var body: some View {
        GeometryReader { proxy in
            let sweepWidth = proxy.size.width * 0.35

            Capsule()
                .fill(
                    LinearGradient(
                        colors: [SettingsPalette.trackTop, SettingsPalette.trackBottom],
                        startPoint: .trailing,
                        endPoint: .leading
                    )
                )
                .overlay(alignment: .leading) {
                    LinearGradient(
                        colors: [.clear, Color.primary.opacity(reduceMotion ? 0 : 0.14), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: sweepWidth)
                    .offset(x: -sweepWidth + phase * (proxy.size.width + sweepWidth))
                }
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .stroke(SettingsPalette.trackBorder, lineWidth: 1)
                )
                .opacity(reduceMotion && phase > 0 ? 0.6 : 1)
        }
        .accessibilityLabel("Refreshing")
        .onAppear {
            let animation = reduceMotion
                ? Animation.easeInOut(duration: 0.9).repeatForever(autoreverses: true)
                : Animation.linear(duration: 1.1).repeatForever(autoreverses: false)
            withAnimation(animation) {
                phase = 1
            }
        }
    }
}

struct CompactBalanceRow: View {
    let kind: String
    let balance: LimitBalance?
    /// Swaps just the bar for a skeleton. The percentage and reset text keep showing
    /// the last known values, so the row never changes size.
    var isRefreshing: Bool = false

    private var style: UsageAccentStyle {
        kind.localizedCaseInsensitiveContains("weekly") ? .weekly : .current
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(balance.map { "\($0.remainingPercent)%" } ?? "--")
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(balance?.remainingPercent ?? 0)))
                Spacer()
                Text(kind)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(style.textColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(style.chipFill, in: Capsule())
                    .overlay(
                        Capsule()
                            .stroke(style.chipBorder, lineWidth: 1)
                    )
                    .offset(y: -4)
            }

            ZStack {
                if isRefreshing {
                    LimitBarSkeleton()
                        .transition(.opacity)
                } else {
                    LimitProgressBar(percent: balance?.remainingPercent ?? 0, style: style)
                        .transition(.opacity)
                }
            }
            .frame(height: 10)

            Text(compactResetText)
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .animation(.easeInOut(duration: 0.25), value: isRefreshing)
        .animation(.snappy, value: balance?.remainingPercent)
    }

    private var compactResetText: String {
        guard let balance else { return "Waiting for balance" }
        guard balance.hasKnownReset else { return LimitBalance.unknownResetText(for: balance) }

        let remaining = balance.resetsAt.timeIntervalSinceNow
        guard remaining > 0 else { return "Resets now" }
        guard remaining >= 60 else { return "Resets in <1m" }

        // RelativeDateTimeFormatter returns a whole phrase ("in 4h"), which read as
        // "Resets in in 4h" once prefixed. Format the duration on its own instead.
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 1
        formatter.allowedUnits = if remaining >= 86_400 {
            [.day, .hour]
        } else if remaining >= 3_600 {
            [.hour, .minute]
        } else {
            [.minute]
        }

        guard let duration = formatter.string(from: remaining), !duration.isEmpty else {
            return "Resets soon"
        }

        return "Resets in \(duration)"
    }

}

enum UsageAccentStyle {
    case current
    case weekly

    var fill: AnyShapeStyle {
        switch self {
        case .current:
            return AnyShapeStyle(
                LinearGradient(
                    colors: [
                        SettingsPalette.cyanFill.opacity(0.94),
                        SettingsPalette.cyanFillDark.opacity(0.98)
                    ],
                    startPoint: .trailing,
                    endPoint: .leading
                )
            )
        case .weekly:
            return AnyShapeStyle(
                LinearGradient(
                    colors: [
                        SettingsPalette.purpleFill.opacity(0.94),
                        SettingsPalette.purpleFillDark.opacity(0.98)
                    ],
                    startPoint: .trailing,
                    endPoint: .leading
                )
            )
        }
    }

    var chipFill: AnyShapeStyle {
        switch self {
        case .current:
            return AnyShapeStyle(SettingsPalette.cyanChip)
        case .weekly:
            return AnyShapeStyle(SettingsPalette.purpleChip)
        }
    }

    var textColor: Color {
        switch self {
        case .current:
            return SettingsPalette.cyanText
        case .weekly:
            return SettingsPalette.purpleText
        }
    }

    var chipBorder: Color {
        switch self {
        case .current:
            return SettingsPalette.cyanChipBorder
        case .weekly:
            return SettingsPalette.purpleChipBorder
        }
    }

    var highlightBorder: Color {
        SettingsPalette.borderStrong
    }

    var shadowColor: Color {
        switch self {
        case .current:
            return SettingsPalette.cyanFill.opacity(0.16)
        case .weekly:
            return SettingsPalette.purpleFill.opacity(0.16)
        }
    }
}

struct ServiceIcon: View {
    let service: LimitService
    let size: CGFloat

    var body: some View {
        Image(service.assetName)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
    }
}

struct BalanceBadge: View {
    let percent: Int

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text("\(percent)% min")
                .font(.caption.weight(.medium))
                .monospacedDigit()
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.quaternary, in: Capsule())
    }

    private var color: Color {
        if percent < 20 { return .red }
        if percent < 45 { return .orange }
        return .green
    }
}

struct ResetBadge: View {
    let date: Date

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "clock")
            Text(relativeText)
                .monospacedDigit()
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.quaternary, in: Capsule())
    }

    private var relativeText: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

struct AppSurfaceBackground: View {
    var body: some View {
        LinearGradient(
            colors: [
                SettingsPalette.pageTop,
                SettingsPalette.pageBottom
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .overlay(
            RadialGradient(
                colors: [
                    SettingsPalette.pageGlow,
                    .clear
                ],
                center: .topTrailing,
                startRadius: 20,
                endRadius: 260
            )
        )
            .ignoresSafeArea()
    }
}

private enum SettingsPalette {
    static let pageTop = adaptiveColor(light: NSColor(red: 0.96, green: 0.96, blue: 0.98, alpha: 1), dark: NSColor(red: 0.07, green: 0.09, blue: 0.12, alpha: 1))
    static let pageBottom = adaptiveColor(light: NSColor(red: 0.90, green: 0.91, blue: 0.95, alpha: 1), dark: NSColor(red: 0.04, green: 0.05, blue: 0.07, alpha: 1))
    static let pageGlow = adaptiveColor(light: NSColor(red: 0.38, green: 0.63, blue: 0.94, alpha: 0.14), dark: NSColor(red: 0.12, green: 0.22, blue: 0.31, alpha: 0.28))
    static let surface = adaptiveColor(light: NSColor(red: 1.00, green: 1.00, blue: 1.00, alpha: 0.84), dark: NSColor(red: 0.12, green: 0.14, blue: 0.17, alpha: 0.96))
    static let surfaceRaised = adaptiveColor(light: NSColor(red: 0.98, green: 0.98, blue: 0.99, alpha: 0.94), dark: NSColor(red: 0.14, green: 0.16, blue: 0.19, alpha: 0.96))
    static let surfaceShell = adaptiveColor(light: NSColor(red: 1.00, green: 1.00, blue: 1.00, alpha: 0.74), dark: NSColor(red: 0.11, green: 0.13, blue: 0.16, alpha: 0.88))
    static let border = adaptiveColor(light: NSColor(red: 0.10, green: 0.12, blue: 0.16, alpha: 0.10), dark: NSColor.white.withAlphaComponent(0.08))
    static let borderStrong = adaptiveColor(light: NSColor(red: 0.10, green: 0.12, blue: 0.16, alpha: 0.14), dark: NSColor.white.withAlphaComponent(0.10))
    static let divider = adaptiveColor(light: NSColor(red: 0.10, green: 0.12, blue: 0.16, alpha: 0.10), dark: NSColor.white.withAlphaComponent(0.07))
    static let buttonSurface = adaptiveColor(light: NSColor(red: 0.95, green: 0.96, blue: 0.98, alpha: 0.96), dark: NSColor(red: 0.16, green: 0.18, blue: 0.22, alpha: 0.96))
    static let inputSurface = adaptiveColor(light: NSColor(red: 0.96, green: 0.97, blue: 0.98, alpha: 0.94), dark: NSColor(red: 0.16, green: 0.18, blue: 0.22, alpha: 0.96))
    static let inputFocusBorder = adaptiveColor(light: NSColor(red: 0.36, green: 0.32, blue: 0.88, alpha: 0.42), dark: NSColor(red: 0.70, green: 0.64, blue: 0.98, alpha: 0.48))
    static let trackTop = adaptiveColor(light: NSColor(red: 0.95, green: 0.96, blue: 0.98, alpha: 0.96), dark: NSColor.white.withAlphaComponent(0.05))
    static let trackBottom = adaptiveColor(light: NSColor(red: 0.84, green: 0.87, blue: 0.91, alpha: 0.92), dark: NSColor.black.withAlphaComponent(0.24))
    static let trackBorder = adaptiveColor(light: NSColor(red: 0.10, green: 0.12, blue: 0.16, alpha: 0.10), dark: NSColor.white.withAlphaComponent(0.08))
    static let iconTrack = adaptiveColor(light: NSColor(red: 0.22, green: 0.26, blue: 0.33, alpha: 0.18), dark: NSColor.white.withAlphaComponent(0.16))
    static let iconTrackMuted = adaptiveColor(light: NSColor(red: 0.22, green: 0.26, blue: 0.33, alpha: 0.22), dark: NSColor.white.withAlphaComponent(0.22))
    static let iconTrackBorder = adaptiveColor(light: NSColor(red: 0.10, green: 0.12, blue: 0.16, alpha: 0.10), dark: NSColor.white.withAlphaComponent(0.08))
    static let accentBorder = adaptiveColor(light: NSColor.white.withAlphaComponent(0.34), dark: NSColor.white.withAlphaComponent(0.18))
    static let onAccentText = adaptiveColor(light: NSColor.white.withAlphaComponent(0.98), dark: NSColor.white.withAlphaComponent(0.94))
    static let knobOn = adaptiveColor(light: NSColor.white.withAlphaComponent(0.98), dark: NSColor.white.withAlphaComponent(0.96))
    static let knobOff = adaptiveColor(light: NSColor(red: 0.99, green: 0.99, blue: 1.00, alpha: 1), dark: NSColor.white.withAlphaComponent(0.86))

    // Accent matches the landing page: --accent #5b52e0 through #8b73ef.
    static let accentGlow = Color(red: 0.357, green: 0.322, blue: 0.878)
    static let accentToggleStart = Color(red: 0.357, green: 0.322, blue: 0.878)
    static let accentToggleEnd = Color(red: 0.545, green: 0.451, blue: 0.937)
    static let accentIconSurface = adaptiveColor(light: NSColor(red: 0.91, green: 0.89, blue: 0.99, alpha: 1), dark: NSColor(red: 0.19, green: 0.17, blue: 0.35, alpha: 1))
    static let accentIconGlyph = adaptiveColor(light: NSColor(red: 0.34, green: 0.26, blue: 0.62, alpha: 1), dark: NSColor(red: 0.78, green: 0.73, blue: 1.00, alpha: 1))
    static let actionButtonSurface = adaptiveColor(light: NSColor(red: 0.91, green: 0.90, blue: 0.99, alpha: 1), dark: NSColor(red: 0.19, green: 0.17, blue: 0.34, alpha: 1))
    static let actionButtonSurfaceHover = adaptiveColor(light: NSColor(red: 0.87, green: 0.85, blue: 0.98, alpha: 1), dark: NSColor(red: 0.23, green: 0.20, blue: 0.40, alpha: 1))
    static let actionBorder = adaptiveColor(light: NSColor(red: 0.36, green: 0.32, blue: 0.88, alpha: 0.22), dark: NSColor(red: 0.70, green: 0.64, blue: 0.98, alpha: 0.24))
    static let actionText = adaptiveColor(light: NSColor(red: 0.29, green: 0.25, blue: 0.71, alpha: 1), dark: NSColor(red: 0.80, green: 0.75, blue: 1.00, alpha: 1))

    static let greenFill = Color(red: 0.25, green: 0.58, blue: 0.39)
    static let greenFillDark = Color(red: 0.16, green: 0.41, blue: 0.27)
    static let greenButtonSurface = adaptiveColor(light: NSColor(red: 0.88, green: 0.94, blue: 0.90, alpha: 1), dark: NSColor(red: 0.15, green: 0.25, blue: 0.19, alpha: 1))
    static let successButtonSurface = adaptiveColor(light: NSColor(red: 0.89, green: 0.94, blue: 0.91, alpha: 1), dark: NSColor(red: 0.14, green: 0.24, blue: 0.18, alpha: 1))
    static let successBorder = adaptiveColor(light: NSColor(red: 0.18, green: 0.49, blue: 0.31, alpha: 0.18), dark: NSColor(red: 0.48, green: 0.78, blue: 0.58, alpha: 0.16))
    static let successText = adaptiveColor(light: NSColor(red: 0.12, green: 0.38, blue: 0.24, alpha: 1), dark: NSColor(red: 0.70, green: 0.90, blue: 0.76, alpha: 1))
    static let redFill = Color(red: 0.74, green: 0.35, blue: 0.38)
    static let redFillDark = Color(red: 0.52, green: 0.21, blue: 0.23)
    static let redButtonSurface = adaptiveColor(light: NSColor(red: 0.97, green: 0.90, blue: 0.90, alpha: 1), dark: NSColor(red: 0.32, green: 0.17, blue: 0.18, alpha: 1))
    static let destructiveButtonSurface = adaptiveColor(light: NSColor(red: 0.97, green: 0.90, blue: 0.90, alpha: 1), dark: NSColor(red: 0.30, green: 0.16, blue: 0.17, alpha: 1))
    static let destructiveBorder = adaptiveColor(light: NSColor(red: 0.62, green: 0.26, blue: 0.29, alpha: 0.18), dark: NSColor(red: 0.92, green: 0.52, blue: 0.56, alpha: 0.16))
    static let destructiveText = adaptiveColor(light: NSColor(red: 0.55, green: 0.20, blue: 0.23, alpha: 1), dark: NSColor(red: 0.96, green: 0.70, blue: 0.72, alpha: 1))

    static let cyanFill = Color(red: 0.26, green: 1.00, blue: 0.89)
    static let cyanFillDark = Color(red: 0.13, green: 0.57, blue: 0.71)
    static let cyanChip = adaptiveColor(light: NSColor(red: 0.06, green: 0.58, blue: 0.68, alpha: 0.08), dark: NSColor(red: 0.06, green: 0.58, blue: 0.68, alpha: 0.14))
    static let cyanChipBorder = adaptiveColor(light: NSColor(red: 0.06, green: 0.58, blue: 0.68, alpha: 0.16), dark: NSColor(red: 0.31, green: 0.88, blue: 0.94, alpha: 0.18))
    static let cyanText = adaptiveColor(light: NSColor(red: 0.06, green: 0.39, blue: 0.49, alpha: 1), dark: NSColor(red: 0.50, green: 0.88, blue: 0.94, alpha: 1))

    static let purpleFill = Color(red: 0.79, green: 0.67, blue: 1.00)
    static let purpleFillDark = Color(red: 0.36, green: 0.30, blue: 0.80)
    static let purpleAccentIconSurface = adaptiveColor(light: NSColor(red: 0.92, green: 0.89, blue: 0.98, alpha: 1), dark: NSColor(red: 0.24, green: 0.18, blue: 0.34, alpha: 1))
    static let purpleChip = adaptiveColor(light: NSColor(red: 0.49, green: 0.34, blue: 0.72, alpha: 0.08), dark: NSColor(red: 0.49, green: 0.34, blue: 0.72, alpha: 0.14))
    static let purpleChipBorder = adaptiveColor(light: NSColor(red: 0.49, green: 0.34, blue: 0.72, alpha: 0.16), dark: NSColor(red: 0.80, green: 0.68, blue: 0.94, alpha: 0.18))
    static let purpleText = adaptiveColor(light: NSColor(red: 0.34, green: 0.22, blue: 0.60, alpha: 1), dark: NSColor(red: 0.80, green: 0.68, blue: 0.94, alpha: 1))

    static let sliderTrack = adaptiveColor(light: NSColor(red: 0.10, green: 0.12, blue: 0.16, alpha: 0.12), dark: NSColor.white.withAlphaComponent(0.10))
    static let thresholdEarly = adaptiveColor(light: NSColor(red: 0.05, green: 0.52, blue: 0.50, alpha: 1), dark: NSColor(red: 0.31, green: 0.89, blue: 0.79, alpha: 1))
    static let thresholdWarn = adaptiveColor(light: NSColor(red: 0.74, green: 0.46, blue: 0.09, alpha: 1), dark: NSColor(red: 0.98, green: 0.75, blue: 0.38, alpha: 1))
    static let thresholdCritical = adaptiveColor(light: NSColor(red: 0.72, green: 0.24, blue: 0.27, alpha: 1), dark: NSColor(red: 0.98, green: 0.56, blue: 0.57, alpha: 1))

    static let orangeFill = Color(red: 0.87, green: 0.46, blue: 0.33)
    static let orangeFillDark = Color(red: 0.66, green: 0.27, blue: 0.18)
}

private enum SettingsAccentTint {
    case accent
    case purple
}

private struct SettingsAccentIcon: View {
    let systemName: String
    let tint: SettingsAccentTint

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(backgroundFill)
                .frame(width: 36, height: 36)
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .stroke(SettingsPalette.border, lineWidth: 1)
                )

            Image(systemName: systemName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(foregroundColor)
        }
    }

    private var backgroundFill: some ShapeStyle {
        tint == .accent ? SettingsPalette.accentIconSurface : SettingsPalette.purpleAccentIconSurface
    }

    private var foregroundColor: Color {
        tint == .accent ? SettingsPalette.accentIconGlyph : SettingsPalette.purpleText
    }
}

private extension ServiceLimit {
    var limitAvailabilityMessage: (title: String, detail: String, systemImage: String)? {
        guard id == .claude else { return nil }

        if current == nil && weekly == nil {
            return (
                "Subscription limits unavailable",
                "Claude Code connected, but did not provide 5-hour or weekly limits. Open Claude Code, run /usage, then refresh.",
                "arrow.triangle.2.circlepath"
            )
        }

        if current == nil {
            return (
                "5-hour limit unavailable",
                "Claude Code provided the weekly window, but not the current 5-hour window yet.",
                "clock.badge.questionmark"
            )
        }

        if weekly == nil {
            return (
                "Weekly limit unavailable",
                "Claude Code provided the current window, but not the weekly subscription window yet.",
                "calendar.badge.exclamationmark"
            )
        }

        return nil
    }

    var warningText: String? {
        guard let lowest = [current?.remainingPercent, weekly?.remainingPercent].compactMap({ $0 }).min() else { return nil }
        if lowest < 20 { return "\(id.shortName) is low. Wait for the next reset before starting a large task." }
        if lowest < 45 { return "\(id.shortName) has limited headroom for a long task." }
        return nil
    }
}

private extension View {
    func limitCard() -> some View {
        background(SettingsPalette.surfaceShell, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(SettingsPalette.borderStrong, lineWidth: 1)
            )
    }

    func settingsCardSurface(cornerRadius: CGFloat, fill: Color = SettingsPalette.surface) -> some View {
        background(fill, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(SettingsPalette.border, lineWidth: 1)
            )
    }
}

private struct DashboardActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(configuration.isPressed ? SettingsPalette.surfaceRaised : SettingsPalette.buttonSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(SettingsPalette.border, lineWidth: 1)
            )
            .foregroundStyle(.primary)
    }
}

private func adaptiveColor(light: NSColor, dark: NSColor) -> Color {
    Color(nsColor: NSColor(name: nil) { appearance in
        switch appearance.bestMatch(from: [.darkAqua, .aqua]) {
        case .darkAqua:
            return dark
        default:
            return light
        }
    })
}

#Preview {
    ContentView()
        .environmentObject(LimitStore())
}
