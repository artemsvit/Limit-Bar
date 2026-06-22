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

    var isConnected: Bool { state == .connected }
    var isConnecting: Bool { state == .connecting }
}

struct LimitBalance: Codable, Equatable {
    var title: String
    var remainingPercent: Int
    var resetsAt: Date

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

    var shortName: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude"
        case .antigravity: return "Antigravity"
        case .gemini: return "Gemini"
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
                var updated = self.preferences.thresholds
                while updated.count <= index {
                    updated.append(NotificationPreferences.default.thresholds[min(index, NotificationPreferences.default.thresholds.count - 1)])
                }
                updated[index] = min(max(newValue, 1), 99)
                self.preferences.thresholds = updated
            }
        )
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
    private static let sentThresholdsKey = "limit-bar.sent-threshold-notifications.v1"

    static func requestAuthorizationIfNeeded() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { _, _ in }
    }

    static func sendTestNotification() {
        requestAuthorizationIfNeeded()

        let content = UNMutableNotificationContent()
        content.title = "Codex current is low"
        content.body = "24% remaining, below your 25% threshold. Resets in 4 hours."
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "limit-bar.test-notification",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    @MainActor
    static func notifyIfNeeded(
        service: LimitService,
        previous: ServiceLimit?,
        current: ServiceLimit,
        preferences: NotificationPreferences
    ) {
        guard preferences.isEnabled else { return }
        requestAuthorizationIfNeeded()

        evaluate(kind: "Current", service: service, previous: previous?.current, current: current.current, thresholds: preferences.normalizedThresholds)
        evaluate(kind: "Weekly", service: service, previous: previous?.weekly, current: current.weekly, thresholds: preferences.normalizedThresholds)
    }

    @MainActor
    private static func evaluate(
        kind: String,
        service: LimitService,
        previous: LimitBalance?,
        current: LimitBalance?,
        thresholds: [Int]
    ) {
        guard let current else { return }

        for threshold in thresholds where current.remainingPercent <= threshold {
            let token = notificationToken(service: service, kind: kind, threshold: threshold, resetAt: current.resetsAt)
            if sentThresholdTokens().contains(token) {
                continue
            }

            let crossedThreshold = previous == nil || previous!.resetsAt != current.resetsAt || previous!.remainingPercent > threshold
            guard crossedThreshold else { continue }

            deliverNotification(service: service, kind: kind, threshold: threshold, current: current)
            markSent(token: token)
        }
    }

    @MainActor
    private static func deliverNotification(service: LimitService, kind: String, threshold: Int, current: LimitBalance) {
        let content = UNMutableNotificationContent()
        content.title = "\(service.shortName) \(kind.lowercased()) is low"
        content.body = "\(current.remainingPercent)% remaining, below your \(threshold)% threshold. \(resetText(for: current.resetsAt))"
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: notificationToken(service: service, kind: kind, threshold: threshold, resetAt: current.resetsAt),
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    private static func resetText(for date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "Resets \(formatter.localizedString(for: date, relativeTo: Date()))."
    }

    private static func notificationToken(service: LimitService, kind: String, threshold: Int, resetAt: Date) -> String {
        "\(service.rawValue)|\(kind)|\(threshold)|\(Int(resetAt.timeIntervalSince1970))"
    }

    private static func sentThresholdTokens() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: sentThresholdsKey) ?? [])
    }

    private static func markSent(token: String) {
        var tokens = sentThresholdTokens()
        tokens.insert(token)
        UserDefaults.standard.set(Array(tokens), forKey: sentThresholdsKey)
    }
}

@MainActor
final class LimitStore: ObservableObject {
    @Published var services: [ServiceLimit] {
        didSet { save() }
    }

    private let storageKey = "limit-bar.services.v4"
    private let refreshInterval: TimeInterval = 180
    private var refreshTimer: Timer?

    init() {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([ServiceLimit].self, from: data) {
            services = LimitService.allCases.map { service in
                decoded.first(where: { $0.id == service }) ?? ServiceLimit.placeholder(for: service)
            }
        } else {
            services = LimitService.allCases.map(ServiceLimit.placeholder)
        }

        let timer = Timer(timeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshConnected(showLoading: false, presentErrors: false)
            }
        }
        timer.tolerance = 20
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    deinit {
        refreshTimer?.invalidate()
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
            .flatMap { [$0.current?.resetsAt, $0.weekly?.resetsAt] }
            .compactMap { $0 }
            .filter { $0 > Date() }
            .min()
    }

    func connect(_ service: LimitService) {
        connect(service, showLoading: true, presentErrors: true)
    }

    private func connect(_ service: LimitService, showLoading: Bool, presentErrors: Bool) {
        if showLoading {
            setState(.connecting, for: service, error: nil)
        }

        Task {
            do {
                let snapshot = try await ProviderConnector.fetch(service)
                apply(snapshot, to: service)
            } catch {
                if showLoading {
                    setState(.failed, for: service, error: error.localizedDescription)
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
    }

    func refreshConnected() {
        refreshConnected(showLoading: true, presentErrors: true)
    }

    private func refreshConnected(showLoading: Bool, presentErrors: Bool) {
        for service in activeServices where service.isConnected {
            connect(service.id, showLoading: showLoading, presentErrors: presentErrors)
        }
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
        let previous = services[index]
        services[index].state = .connected
        services[index].current = snapshot.current
        services[index].weekly = snapshot.weekly
        services[index].credits = snapshot.credits
        services[index].accountEmail = snapshot.accountEmail
        services[index].planName = snapshot.planName
        services[index].lastUpdated = Date()
        services[index].errorMessage = nil
        UsageNotificationCenter.notifyIfNeeded(
            service: service,
            previous: previous,
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
    static func fetch() async throws -> ProviderSnapshot {
        let result = try await ProcessRunner.run(
            executable: "/bin/zsh",
            arguments: ["-lc", rpcScript()],
            input: nil,
            timeout: 12
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
        } | codex -s read-only -a untrusted app-server
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
        try await ensureLoggedIn()

        if let statusLineSnapshot = try await fetchStatusLineUsage() {
            return statusLineSnapshot
        }

        let result = try await ProcessRunner.run(
            executable: "/usr/bin/env",
            arguments: ["claude", "--print", "/usage"],
            input: nil,
            timeout: 14
        )

        let output = [result.stdout, result.stderr].joined(separator: "\n")
        guard result.status == 0 || !output.isEmpty else {
            throw ConnectorError.message("Claude Code did not return usage data. Make sure Claude Code is installed and signed in.")
        }

        if output.localizedCaseInsensitiveContains("not logged in") || output.localizedCaseInsensitiveContains("please run /login") {
            throw ConnectorError.message("Claude Code is not logged in. Open Claude Code and run `/login`, then retry.")
        }

        return try parseUsage(output)
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
            .appendingPathComponent("Library/Application Support/CodexBar/ClaudeProbe", isDirectory: true)
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

        let script = """
        ( sleep 4; printf '/exit\\r'; sleep 1 ) | /usr/bin/script -q /dev/null /usr/bin/env claude --settings \(settingsURL.path.shellQuoted)
        """

        do {
            _ = try await ProcessRunner.run(
                executable: "/bin/zsh",
                arguments: ["-lc", script],
                input: nil,
                timeout: 14,
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

        guard current != nil || weekly != nil else { return nil }
        return ProviderSnapshot(current: current, weekly: weekly, credits: nil, accountEmail: nil, planName: "Claude")
    }

    private static func makeStatusLineBalance(title: String, dictionary: [String: Any]?, fallbackReset: Date) -> LimitBalance? {
        guard let dictionary,
              let used = number(dictionary["used_percentage"] ?? dictionary["usedPercent"]) else { return nil }

        let resetDate = number(dictionary["resets_at"] ?? dictionary["resetsAt"])
            .map { Date(timeIntervalSince1970: $0) } ?? fallbackReset
        return LimitBalance(
            title: title,
            remainingPercent: clampPercent(100 - Int(used.rounded())),
            resetsAt: resetDate
        )
    }

    private static func parseUsage(_ output: String) throws -> ProviderSnapshot {
        let clean = output.strippingANSI()
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
                planName: nil
            )
        }

        if isClaudeSessionUsageSummary(clean) {
            throw ConnectorError.message("Claude Code is connected, but this account only exposed session/API usage, not 5-hour and weekly subscription limits. Limit Bar can read Claude limits when Claude Code provides `rate_limits` through its status line.")
        }

        throw ConnectorError.message("Claude Code did not expose 5-hour or weekly usage limits in a recognized format.")
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
            arguments: [binary, "models"],
            input: nil,
            timeout: 14
        )

        let output = [result.stdout, result.stderr].joined(separator: "\n")
        guard result.status == 0 || !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            await openAntigravityLogin(binary: binary)
            throw ConnectorError.message(loginMessage)
        }

        if requiresUpdate(output) {
            throw ConnectorError.message("Antigravity CLI needs an update before limits can be read. Run `agy update`, sign in with Google again if prompted, then retry.")
        }

        if isUnauthenticated(output) {
            await openAntigravityLogin(binary: binary)
            throw ConnectorError.message(loginMessage)
        }

        guard result.status == 0, hasModelList(output) else {
            throw ConnectorError.message(cleanError(output, fallback: "Antigravity CLI did not return model access. Run `agy` in Terminal, complete Google OAuth login, then retry."))
        }

        let accountDetail = latestAuthenticatedEmail().map { " Signed in as \($0)." } ?? ""
        throw ConnectorError.message(
            "Antigravity CLI is authenticated\(accountDetail) However, Antigravity CLI 1.0.10 does not expose current or weekly usage limits in a readable command. `/usage` and `/quota` are not available in this installed CLI, so Limit Bar cannot show Antigravity limits yet."
        )
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

    private static func hasModelList(_ output: String) -> Bool {
        output
            .split(whereSeparator: \.isNewline)
            .contains { $0.localizedCaseInsensitiveContains("Gemini") || $0.localizedCaseInsensitiveContains("Claude") || $0.localizedCaseInsensitiveContains("GPT") }
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

struct ProcessRunner {
    struct Result {
        let stdout: String
        let stderr: String
        let status: Int32
    }

    static func run(
        executable: String,
        arguments: [String],
        input: String?,
        timeout: TimeInterval,
        environmentOverrides: [String: String] = [:],
        currentDirectory: URL? = nil
    ) async throws -> Result {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            let stdinPipe = Pipe()
            let finishGate = ProcessFinishGate()

            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
            if input != nil { process.standardInput = stdinPipe }
            process.environment = mergedEnvironment(overrides: environmentOverrides)
            process.currentDirectoryURL = currentDirectory

            @Sendable
            func finish(_ action: () throws -> Result) {
                guard finishGate.claim() else { return }

                do {
                    continuation.resume(returning: try action())
                } catch {
                    continuation.resume(throwing: error)
                }
            }

            process.terminationHandler = { proc in
                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                finish {
                    Result(
                        stdout: String(data: stdoutData, encoding: .utf8) ?? "",
                        stderr: String(data: stderrData, encoding: .utf8) ?? "",
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
                    if process.isRunning { process.terminate() }
                    continuation.resume(throwing: ConnectorError.message("Timed out while reading usage data."))
                }
            }
        }
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

private func clampPercent(_ value: Int) -> Int {
    min(max(value, 0), 100)
}

private func cleanError(_ stderr: String, fallback: String) -> String {
    let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
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

    func extractResetDates(now: Date = Date()) -> [Date] {
        let relativeHours = matches(pattern: #"resets?\s+(?:in\s+)?([0-9]+)\s*h"#).compactMap { Double($0).map { now.addingTimeInterval($0 * 3600) } }
        let relativeDays = matches(pattern: #"resets?\s+(?:in\s+)?([0-9]+)\s*d"#).compactMap { Double($0).map { now.addingTimeInterval($0 * 24 * 3600) } }
        return relativeHours + relativeDays
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

    var body: some View {
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
        .frame(height: 60)
        .settingsCardSurface(cornerRadius: 15)
        .help(service.errorMessage ?? statusText)
    }

    private var statusText: String {
        switch service.state {
        case .disconnected: return "Ready to connect"
        case .connecting: return "Reading local usage"
        case .connected: return "Connected"
        case .failed: return shortProviderError(service)
        }
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
            return SettingsPalette.blueFill.opacity(isHovering ? 0.10 : 0.06)
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
                Text("Check Now")
                    .font(.callout.weight(.semibold))
            }
            .foregroundStyle(foregroundColor)
            .frame(width: 112, height: 29)
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
        isEnabled ? SettingsPalette.blueFill.opacity(isHovering ? 0.10 : 0.06) : .clear
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

                MenuHeaderIconButton(systemName: "gearshape", helpText: "Open settings") {
                    SettingsWindowPresenter.shared.open(store: store)
                }

                MenuHeaderIconButton(systemName: "power") {
                    NSApp.terminate(nil)
                }
            }

            ForEach(store.activeServices.filter(\.isConnected)) { service in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        ServiceIcon(service: service.id, size: 22)
                        Text(service.id.shortName)
                            .font(.callout.weight(.medium))
                        Spacer()
                    }

                    CompactBalanceRow(kind: "Current", balance: service.current)
                    CompactBalanceRow(kind: "Weekly", balance: service.weekly)
                }
                .padding(10)
                .settingsCardSurface(cornerRadius: 14, fill: SettingsPalette.surfaceRaised)
            }

        }
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
        if lower.contains("session/api") || lower.contains("5-hour") || lower.contains("weekly") || lower.contains("rate_limits") {
            return "Usage limits unavailable"
        }
        if lower.contains("not logged in") || lower.contains("login") {
            return "Sign in required"
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
    @StateObject private var appUpdater = AppUpdater.shared
    @State private var startsAtLogin = LaunchAtLoginController.isEnabled
    @State private var notificationDetailsExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Limit Bar Settings")
                    .font(.system(size: 25, weight: .semibold, design: .rounded))
                Text("Manage local providers, alerts, and updates.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 10) {
                ForEach(store.activeServices) { service in
                    ConnectServiceRow(service: service)
                }
            }

            Rectangle()
                .fill(SettingsPalette.divider)
                .frame(height: 1)

            appOptionsCard

            notificationCard

            updatesCard
        }
        .padding(22)
        .frame(width: 580, height: 710, alignment: .topLeading)
        .background(AppSurfaceBackground())
        .onAppear {
            notificationDetailsExpanded = notificationSettings.isEnabled
        }
        .onChange(of: notificationSettings.isEnabled) { _, isEnabled in
            updateNotificationDetailsVisibility(isEnabled: isEnabled)
        }
    }

    private var appOptionsCard: some View {
        VStack(spacing: 10) {
            startAtLoginRow

            Rectangle()
                .fill(SettingsPalette.divider)
                .frame(height: 1)

            menuBarDisplayRow
        }
        .padding(12)
        .settingsCardSurface(cornerRadius: 15)
    }

    private var startAtLoginRow: some View {
        HStack(spacing: 10) {
            SettingsAccentIcon(systemName: "power", tint: .blue)

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
            SettingsAccentIcon(systemName: "percent", tint: .blue)

            VStack(alignment: .leading, spacing: 3) {
                Text("Show current percent")
                    .font(.headline)
                Text("Use 97% in the macOS menu bar instead of two bars.")
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
                SettingsAccentIcon(systemName: "bell", tint: .blue)

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
                VStack(alignment: .leading, spacing: 12) {
                    Rectangle()
                        .fill(SettingsPalette.divider)
                        .frame(height: 1)

                    HStack {
                        Text("Thresholds")
                            .font(.callout.weight(.semibold))
                        Spacer()
                        Button("Test Notification") {
                            UsageNotificationCenter.sendTestNotification()
                        }
                        .font(.callout.weight(.medium))
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 8) {
                        ThresholdEditorCard(title: "Early", value: notificationSettings.thresholdBinding(at: 0))
                        ThresholdEditorCard(title: "Warn", value: notificationSettings.thresholdBinding(at: 1))
                        ThresholdEditorCard(title: "Critical", value: notificationSettings.thresholdBinding(at: 2))
                    }

                    Text("Recommended: 50%, 25%, and 10%. Applies to current and weekly balances.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 12)
            }
        }
        .padding(12)
        .settingsCardSurface(cornerRadius: 15)
    }

    private var updatesCard: some View {
        HStack(spacing: 10) {
            SettingsAccentIcon(systemName: "arrow.triangle.2.circlepath", tint: .purple)

            VStack(alignment: .leading, spacing: 3) {
                Text("Software updates")
                    .font(.headline)
                Text(appUpdater.statusText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            UpdateActionPill(isEnabled: appUpdater.canCheckForUpdates) {
                appUpdater.checkForUpdates()
            }
        }
        .padding(12)
        .settingsCardSurface(cornerRadius: 15)
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
            AnyShapeStyle(SettingsPalette.blueToggleSurface)
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

struct ThresholdEditorCard: View {
    let title: String
    @Binding var value: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            ThresholdPercentField(value: $value)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .settingsCardSurface(cornerRadius: 14, fill: SettingsPalette.surfaceRaised)
    }
}

struct ThresholdPercentField: View {
    @Binding var value: Int
    @FocusState private var isFocused: Bool
    @State private var draftText = ""

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            TextField("50", text: $draftText)
                .textFieldStyle(.plain)
                .font(.system(size: 28, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
                .frame(width: 58)
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

            Text("%")
                .font(.system(size: 28, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(SettingsPalette.inputSurface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(isFocused ? SettingsPalette.inputFocusBorder : SettingsPalette.border, lineWidth: 1)
        )
        .onAppear {
            draftText = "\(value)"
        }
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

        let clampedValue = min(max(typedValue, 1), 99)
        value = clampedValue
        draftText = "\(clampedValue)"
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
        try? process.run()
    }
}

struct CompactBalanceRow: View {
    let kind: String
    let balance: LimitBalance?

    private var style: UsageAccentStyle {
        kind.localizedCaseInsensitiveContains("weekly") ? .weekly : .current
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(balance.map { "\($0.remainingPercent)%" } ?? "--")
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
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
            }

            LimitProgressBar(percent: balance?.remainingPercent ?? 0, style: style)
                .frame(height: 10)

            Text(compactResetText)
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private var compactResetText: String {
        guard let balance else { return "Waiting for balance" }
        let relative = RelativeDateTimeFormatter()
        relative.unitsStyle = .abbreviated
        return "Resets in \(relative.localizedString(for: balance.resetsAt, relativeTo: Date()))"
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
    static let pageTop = adaptiveColor(light: NSColor(red: 0.97, green: 0.96, blue: 0.94, alpha: 1), dark: NSColor(red: 0.07, green: 0.09, blue: 0.12, alpha: 1))
    static let pageBottom = adaptiveColor(light: NSColor(red: 0.92, green: 0.90, blue: 0.86, alpha: 1), dark: NSColor(red: 0.04, green: 0.05, blue: 0.07, alpha: 1))
    static let pageGlow = adaptiveColor(light: NSColor(red: 0.38, green: 0.63, blue: 0.94, alpha: 0.14), dark: NSColor(red: 0.12, green: 0.22, blue: 0.31, alpha: 0.28))
    static let surface = adaptiveColor(light: NSColor(red: 1.00, green: 1.00, blue: 1.00, alpha: 0.84), dark: NSColor(red: 0.12, green: 0.14, blue: 0.17, alpha: 0.96))
    static let surfaceRaised = adaptiveColor(light: NSColor(red: 0.98, green: 0.98, blue: 0.99, alpha: 0.94), dark: NSColor(red: 0.14, green: 0.16, blue: 0.19, alpha: 0.96))
    static let surfaceShell = adaptiveColor(light: NSColor(red: 1.00, green: 1.00, blue: 1.00, alpha: 0.74), dark: NSColor(red: 0.11, green: 0.13, blue: 0.16, alpha: 0.88))
    static let border = adaptiveColor(light: NSColor(red: 0.10, green: 0.12, blue: 0.16, alpha: 0.10), dark: NSColor.white.withAlphaComponent(0.08))
    static let borderStrong = adaptiveColor(light: NSColor(red: 0.10, green: 0.12, blue: 0.16, alpha: 0.14), dark: NSColor.white.withAlphaComponent(0.10))
    static let divider = adaptiveColor(light: NSColor(red: 0.10, green: 0.12, blue: 0.16, alpha: 0.10), dark: NSColor.white.withAlphaComponent(0.07))
    static let buttonSurface = adaptiveColor(light: NSColor(red: 0.95, green: 0.96, blue: 0.98, alpha: 0.96), dark: NSColor(red: 0.16, green: 0.18, blue: 0.22, alpha: 0.96))
    static let inputSurface = adaptiveColor(light: NSColor(red: 0.96, green: 0.97, blue: 0.98, alpha: 0.94), dark: NSColor(red: 0.16, green: 0.18, blue: 0.22, alpha: 0.96))
    static let inputFocusBorder = adaptiveColor(light: NSColor(red: 0.14, green: 0.37, blue: 0.74, alpha: 0.36), dark: NSColor(red: 0.50, green: 0.70, blue: 1.00, alpha: 0.40))
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

    static let blueFill = Color(red: 0.28, green: 0.56, blue: 0.93)
    static let blueFillDark = Color(red: 0.14, green: 0.37, blue: 0.74)
    static let blueButtonSurface = adaptiveColor(light: NSColor(red: 0.87, green: 0.92, blue: 0.98, alpha: 1), dark: NSColor(red: 0.16, green: 0.24, blue: 0.35, alpha: 1))
    static let blueButtonSurfaceHover = adaptiveColor(light: NSColor(red: 0.82, green: 0.89, blue: 0.97, alpha: 1), dark: NSColor(red: 0.18, green: 0.28, blue: 0.41, alpha: 1))
    static let blueToggleSurface = adaptiveColor(light: NSColor(red: 0.72, green: 0.82, blue: 0.94, alpha: 1), dark: NSColor(red: 0.20, green: 0.32, blue: 0.48, alpha: 1))
    static let blueAccentIconSurface = adaptiveColor(light: NSColor(red: 0.87, green: 0.92, blue: 0.98, alpha: 1), dark: NSColor(red: 0.13, green: 0.23, blue: 0.36, alpha: 1))
    static let blueText = adaptiveColor(light: NSColor(red: 0.13, green: 0.34, blue: 0.63, alpha: 1), dark: NSColor(red: 0.84, green: 0.92, blue: 1.00, alpha: 1))
    static let actionButtonSurface = adaptiveColor(light: NSColor(red: 0.90, green: 0.94, blue: 0.98, alpha: 1), dark: NSColor(red: 0.15, green: 0.21, blue: 0.29, alpha: 1))
    static let actionButtonSurfaceHover = adaptiveColor(light: NSColor(red: 0.85, green: 0.91, blue: 0.97, alpha: 1), dark: NSColor(red: 0.17, green: 0.25, blue: 0.35, alpha: 1))
    static let actionBorder = adaptiveColor(light: NSColor(red: 0.14, green: 0.37, blue: 0.62, alpha: 0.18), dark: NSColor(red: 0.58, green: 0.74, blue: 0.92, alpha: 0.18))
    static let actionText = adaptiveColor(light: NSColor(red: 0.12, green: 0.34, blue: 0.58, alpha: 1), dark: NSColor(red: 0.74, green: 0.86, blue: 0.98, alpha: 1))

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

    static let orangeFill = Color(red: 0.87, green: 0.46, blue: 0.33)
    static let orangeFillDark = Color(red: 0.66, green: 0.27, blue: 0.18)
}

private enum SettingsAccentTint {
    case blue
    case purple
}

private struct SettingsAccentIcon: View {
    let systemName: String
    let tint: SettingsAccentTint

    var body: some View {
        ZStack {
            Circle()
                .fill(backgroundFill)
                .frame(width: 36, height: 36)
                .overlay(
                    Circle()
                        .stroke(SettingsPalette.border, lineWidth: 1)
                )

            Image(systemName: systemName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(foregroundColor)
        }
    }

    private var backgroundFill: some ShapeStyle {
        tint == .blue ? SettingsPalette.blueAccentIconSurface : SettingsPalette.purpleAccentIconSurface
    }

    private var foregroundColor: Color {
        tint == .blue ? SettingsPalette.blueText : SettingsPalette.purpleText
    }
}

private extension ServiceLimit {
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
