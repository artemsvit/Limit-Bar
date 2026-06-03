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
    case gemini = "Gemini"

    static let activeCases: [LimitService] = [.codex, .claude]

    var id: String { rawValue }

    var isActiveProvider: Bool {
        Self.activeCases.contains(self)
    }

    var assetName: String {
        switch self {
        case .codex: return "CodexIcon"
        case .claude: return "ClaudeCodeIcon"
        case .gemini: return "GeminiIcon"
        }
    }

    var shortName: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude"
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
                    ErrorAlertPresenter.show(message: error.localizedDescription)
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

        let result = try await ProcessRunner.run(
            executable: "/usr/bin/env",
            arguments: ["claude", "--allowed-tools", "", "--print", "/usage"],
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

        throw ConnectorError.message("Claude Code did not expose subscription usage. `/usage` usually requires a Claude Code paid subscription; API-key usage is not available in this connector yet.")
    }

    private static func normalizeClaudePercent(_ value: Int, _ text: String) -> Int {
        let lower = text.lowercased()
        if lower.contains("% used") || lower.contains("utilization") {
            return clampPercent(100 - value)
        }
        return value
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
        environmentOverrides: [String: String] = [:]
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
                    Text("Limit Bar reads installed Codex and Claude Code sessions. No passwords, no browser cookies, no fake balances.")
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
                    SetupPromiseRow(symbol: "terminal", title: "Uses local tools", text: "Codex uses `codex app-server`; Claude Code tries the installed `claude` CLI usage view.")
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
        HStack(spacing: 12) {
            ServiceIcon(service: service.id, size: 42)

            VStack(alignment: .leading, spacing: 3) {
                Text(service.id.rawValue)
                    .font(.headline)
                Text(statusText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
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
        .padding(.horizontal, 16)
        .padding(.vertical, 15)
        .background(.background.opacity(0.42), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.separator.opacity(0.32), lineWidth: 1)
        )
    }

    private var statusText: String {
        switch service.state {
        case .disconnected: return "Ready to connect"
        case .connecting: return "Reading local usage"
        case .connected: return "Connected"
        case .failed: return service.errorMessage ?? "Connection failed"
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
            .frame(width: compact ? 98 : 116, height: compact ? 28 : 30)
            .background(backgroundFill, in: Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(borderColor, lineWidth: 1)
            )
            .shadow(color: shadowColor, radius: isConnected ? 8 : 5, y: 2)
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
            return Color.white.opacity(0.95)
        }
        return disconnectedTitle == "Connect"
            ? Color.white.opacity(0.95)
            : Color.primary.opacity(0.9)
    }

    private var backgroundFill: AnyShapeStyle {
        if isConnected {
            if isHovering {
                return AnyShapeStyle(
                    LinearGradient(
                        colors: [
                            Color(red: 0.88, green: 0.45, blue: 0.47),
                            Color(red: 0.67, green: 0.19, blue: 0.23),
                            Color(red: 0.41, green: 0.11, blue: 0.15)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            }
            return AnyShapeStyle(
                LinearGradient(
                    colors: [
                        Color(red: 0.55, green: 0.88, blue: 0.63),
                        Color(red: 0.28, green: 0.67, blue: 0.39),
                        Color(red: 0.14, green: 0.40, blue: 0.24)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        }
        if disconnectedTitle == "Connect" {
            return AnyShapeStyle(
                LinearGradient(
                    colors: [
                        Color(red: 0.54, green: 0.78, blue: 1.00),
                        Color(red: 0.23, green: 0.57, blue: 0.98),
                        Color(red: 0.05, green: 0.37, blue: 0.88)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        }
        return AnyShapeStyle(Color(nsColor: .controlBackgroundColor))
    }

    private var borderColor: Color {
        if isConnected {
            return Color.white.opacity(isHovering ? 0.24 : 0.22)
        }
        if disconnectedTitle == "Connect" {
            return Color.white.opacity(0.18)
        }
        return Color.primary.opacity(0.08)
    }

    private var shadowColor: Color {
        if isConnected {
            if isHovering {
                return Color(red: 0.55, green: 0.18, blue: 0.20).opacity(0.30)
            }
            return Color(red: 0.18, green: 0.62, blue: 0.34).opacity(0.28)
        }
        if disconnectedTitle == "Connect" {
            return Color(red: 0.12, green: 0.38, blue: 0.84).opacity(0.24)
        }
        return .black.opacity(0.06)
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
        .frame(width: compact ? 98 : 116, height: compact ? 28 : 30)
        .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
        .overlay(
            Capsule()
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
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
                .buttonStyle(.bordered)

                Button {
                    store.refreshConnected()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
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
        .background(.background.opacity(0.45), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(.separator.opacity(0.28), lineWidth: 1)
        )
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
        .background(.background.opacity(0.48), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.separator.opacity(0.35), lineWidth: 1)
        )
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
                    .shadow(color: style.shadowColor, radius: 8, y: 3)
            }
        }
    }

    private var trackFill: AnyShapeStyle {
        AnyShapeStyle(
            LinearGradient(
                colors: [
                    Color.white.opacity(0.05),
                    Color.black.opacity(0.18)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private var trackBorder: Color {
        Color.white.opacity(0.08)
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
            VerticalMenuBar(percent: currentPercent)
            VerticalMenuBar(percent: weeklyPercent)
        }
        .padding(.horizontal, 2)
        .frame(width: 18, height: 18)
        .accessibilityLabel("Limit Bar")
    }
}

struct VerticalMenuBar: View {
    let percent: Int

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottom) {
                Capsule()
                    .fill(Color.primary.opacity(0.24))

                Capsule()
                    .fill(color)
                    .frame(height: max(proxy.size.height * CGFloat(percent) / 100, percent > 0 ? 4 : 0))
            }
        }
        .frame(width: 6)
    }

    private var color: Color {
        if percent == 0 { return Color.primary.opacity(0.24) }
        if percent < 20 { return .red }
        if percent < 45 { return .orange }
        return .green
    }
}

struct MenuSetupView: View {
    @EnvironmentObject private var store: LimitStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("AI Usage Limits")
                        .font(.system(size: 18, weight: .semibold))
                    Text("Connect local AI usage")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    SettingsWindowPresenter.shared.open(store: store)
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
            }

            VStack(spacing: 10) {
                ForEach(store.activeServices) { service in
                    MenuConnectRow(service: service)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                SetupPromiseRow(symbol: "terminal", title: "Local tools", text: "Uses your installed Codex and Claude Code sessions.")
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
                    .font(.system(size: 18, weight: .semibold))
                Spacer()

                Button {
                    SettingsWindowPresenter.shared.open(store: store)
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
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
                .background(.background.opacity(0.5), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
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
                    .lineLimit(2)
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
        .background(.background.opacity(0.45), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(.separator.opacity(0.32), lineWidth: 1)
        )
    }

    private var statusText: String {
        switch service.state {
        case .disconnected: return compact ? "Not connected" : "Ready to connect"
        case .connecting: return "Reading local usage"
        case .connected: return "Connected"
        case .failed: return service.errorMessage ?? "Connection failed"
        }
    }
}

struct SettingsWindowView: View {
    @EnvironmentObject private var store: LimitStore
    @StateObject private var notificationSettings = NotificationPreferencesStore.shared
    @StateObject private var appUpdater = AppUpdater.shared
    @State private var startsAtLogin = LaunchAtLoginController.isEnabled

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Limit Bar Settings")
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                Text("Connect local providers used by AI Usage Limits.")
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 12) {
                ForEach(store.activeServices) { service in
                    ConnectServiceRow(service: service)
                }
            }

            Divider()

            HStack(spacing: 12) {
                Image(systemName: "power.circle.fill")
                    .font(.system(size: 42))
                    .frame(width: 42, height: 42)
                    .foregroundStyle(
                        LinearGradient(
                            colors: [
                                Color(red: 0.54, green: 0.78, blue: 1.00),
                                Color(red: 0.23, green: 0.57, blue: 0.98),
                                Color(red: 0.05, green: 0.37, blue: 0.88)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                VStack(alignment: .leading, spacing: 3) {
                    Text("Start at login")
                        .font(.headline)
                    Text("Launch Limit Bar automatically when you sign in.")
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
            .padding(14)
            .background(.background.opacity(0.42), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(.separator.opacity(0.32), lineWidth: 1)
            )

            notificationCard

            updatesCard

            Spacer(minLength: 0)
        }
        .padding(28)
        .frame(width: 620, alignment: .topLeading)
        .background(AppSurfaceBackground())
        .onAppear {
            SettingsWindowPresenter.shared.updateHeight(showingNotificationsDetails: notificationSettings.isEnabled)
        }
        .onChange(of: notificationSettings.isEnabled) { _, isEnabled in
            SettingsWindowPresenter.shared.updateHeight(showingNotificationsDetails: isEnabled)
        }
    }

    private var notificationCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "bell.badge.fill")
                    .font(.system(size: 42))
                    .frame(width: 42, height: 42)
                    .foregroundStyle(
                        LinearGradient(
                            colors: [
                                Color(red: 0.54, green: 0.78, blue: 1.00),
                                Color(red: 0.23, green: 0.57, blue: 0.98),
                                Color(red: 0.05, green: 0.37, blue: 0.88)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                VStack(alignment: .leading, spacing: 3) {
                    Text("Usage notifications")
                        .font(.headline)
                    Text("Get notified when remaining usage drops below your thresholds.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer()

                Toggle("", isOn: notificationEnabledBinding)
                    .labelsHidden()
                    .toggleStyle(BrandedLoginToggleStyle())
            }

            if notificationSettings.isEnabled {
                Divider()

                HStack {
                    Text("Thresholds")
                        .font(.callout.weight(.semibold))
                    Spacer()
                    Button("Test Notification") {
                        UsageNotificationCenter.sendTestNotification()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    Button("Defaults") {
                        notificationSettings.restoreDefaults()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }

                HStack(spacing: 10) {
                    ThresholdEditorCard(title: "Early", value: notificationSettings.thresholdBinding(at: 0), style: .current)
                    ThresholdEditorCard(title: "Warn", value: notificationSettings.thresholdBinding(at: 1), style: .weekly)
                    ThresholdEditorCard(title: "Critical", value: notificationSettings.thresholdBinding(at: 2), style: .warning)
                }

                Text("Defaults are 50%, 25%, and 10%. Notifications apply to current and weekly balances for all connected providers.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .background(.background.opacity(0.42), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.separator.opacity(0.32), lineWidth: 1)
        )
    }

    private var updatesCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                .font(.system(size: 42))
                .frame(width: 42, height: 42)
                .foregroundStyle(
                    LinearGradient(
                        colors: [
                            Color(red: 0.84, green: 0.76, blue: 0.99),
                            Color(red: 0.68, green: 0.54, blue: 0.95),
                            Color(red: 0.41, green: 0.35, blue: 0.82)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

            VStack(alignment: .leading, spacing: 3) {
                Text("Software updates")
                    .font(.headline)
                Text(appUpdater.statusText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            Button("Check Now") {
                appUpdater.checkForUpdates()
            }
            .buttonStyle(.borderedProminent)
            .disabled(!appUpdater.canCheckForUpdates)
        }
        .padding(14)
        .background(.background.opacity(0.42), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.separator.opacity(0.32), lineWidth: 1)
        )
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
                    .frame(width: 24, height: 24)
                    .overlay(
                        Circle()
                            .strokeBorder(Color.white.opacity(configuration.isOn ? 0.28 : 0.18), lineWidth: 0.8)
                    )
                    .shadow(color: .black.opacity(configuration.isOn ? 0.24 : 0.08), radius: 8, y: 2)
                    .padding(3)
            }
            .frame(width: 52, height: 30)
            .animation(.spring(response: 0.25, dampingFraction: 0.82), value: configuration.isOn)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Start at login")
        .accessibilityValue(configuration.isOn ? "On" : "Off")
    }

    private func trackFill(isOn: Bool) -> AnyShapeStyle {
        if isOn {
            AnyShapeStyle(LinearGradient(
                colors: [
                    Color(red: 0.54, green: 0.78, blue: 1.00),
                    Color(red: 0.23, green: 0.57, blue: 0.98),
                    Color(red: 0.05, green: 0.37, blue: 0.88)
                ],
                startPoint: .top,
                endPoint: .bottom
            ))
        } else {
            AnyShapeStyle(Color(nsColor: .controlBackgroundColor))
        }
    }

    private func trackBorder(isOn: Bool) -> Color {
        if isOn {
            return Color.white.opacity(0.22)
        } else {
            return Color.primary.opacity(0.08)
        }
    }

    private func knobFill(isOn: Bool) -> AnyShapeStyle {
        if isOn {
            AnyShapeStyle(LinearGradient(
                colors: [
                    Color.white.opacity(0.98),
                    Color(red: 0.86, green: 0.79, blue: 0.99),
                    Color(red: 0.70, green: 0.58, blue: 0.95)
                ],
                startPoint: .top,
                endPoint: .bottom
            ))
        } else {
            AnyShapeStyle(Color.white.opacity(0.92))
        }
    }
}

struct ThresholdEditorCard: View {
    let title: String
    @Binding var value: Int
    let style: ThresholdEditorStyle

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Text("\(value)%")
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .monospacedDigit()

            Stepper("", value: $value, in: 1...99, step: 5)
                .labelsHidden()

            Capsule()
                .fill(style.fill)
                .frame(height: 10)
                .overlay(
                    Capsule()
                        .stroke(style.border, lineWidth: 1)
                )
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.opacity(0.5), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(.separator.opacity(0.28), lineWidth: 1)
        )
    }
}

enum ThresholdEditorStyle {
    case current
    case weekly
    case warning

    var fill: AnyShapeStyle {
        switch self {
        case .current:
            return AnyShapeStyle(
                LinearGradient(
                    colors: [
                        Color(red: 0.54, green: 0.91, blue: 0.94),
                        Color(red: 0.28, green: 0.77, blue: 0.85),
                        Color(red: 0.10, green: 0.47, blue: 0.62)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        case .weekly:
            return AnyShapeStyle(
                LinearGradient(
                    colors: [
                        Color(red: 0.84, green: 0.76, blue: 0.99),
                        Color(red: 0.68, green: 0.54, blue: 0.95),
                        Color(red: 0.41, green: 0.35, blue: 0.82)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        case .warning:
            return AnyShapeStyle(
                LinearGradient(
                    colors: [
                        Color(red: 0.99, green: 0.72, blue: 0.54),
                        Color(red: 0.96, green: 0.45, blue: 0.34),
                        Color(red: 0.77, green: 0.21, blue: 0.18)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        }
    }

    var border: Color {
        Color.white.opacity(0.18)
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

    private static func appAlertIcon() -> NSImage? {
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
                        Color(red: 0.54, green: 0.91, blue: 0.94),
                        Color(red: 0.28, green: 0.77, blue: 0.85),
                        Color(red: 0.10, green: 0.47, blue: 0.62)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        case .weekly:
            return AnyShapeStyle(
                LinearGradient(
                    colors: [
                        Color(red: 0.84, green: 0.76, blue: 0.99),
                        Color(red: 0.68, green: 0.54, blue: 0.95),
                        Color(red: 0.41, green: 0.35, blue: 0.82)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        }
    }

    var chipFill: AnyShapeStyle {
        switch self {
        case .current:
            return AnyShapeStyle(
                LinearGradient(
                    colors: [
                        Color(red: 0.13, green: 0.34, blue: 0.39).opacity(0.92),
                        Color(red: 0.08, green: 0.22, blue: 0.28).opacity(0.92)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        case .weekly:
            return AnyShapeStyle(
                LinearGradient(
                    colors: [
                        Color(red: 0.29, green: 0.20, blue: 0.39).opacity(0.92),
                        Color(red: 0.18, green: 0.12, blue: 0.28).opacity(0.92)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        }
    }

    var textColor: Color {
        switch self {
        case .current:
            return Color(red: 0.26, green: 0.88, blue: 0.92)
        case .weekly:
            return Color(red: 0.76, green: 0.53, blue: 0.95)
        }
    }

    var chipBorder: Color {
        Color.white.opacity(0.10)
    }

    var highlightBorder: Color {
        Color.white.opacity(0.22)
    }

    var shadowColor: Color {
        switch self {
        case .current:
            return Color(red: 0.13, green: 0.58, blue: 0.72).opacity(0.35)
        case .weekly:
            return Color(red: 0.43, green: 0.31, blue: 0.78).opacity(0.35)
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
        Color(nsColor: .windowBackgroundColor)
            .overlay(.thinMaterial.opacity(0.35))
            .ignoresSafeArea()
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
        background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(.separator.opacity(0.4), lineWidth: 1)
            )
    }
}

#Preview {
    ContentView()
        .environmentObject(LimitStore())
}
