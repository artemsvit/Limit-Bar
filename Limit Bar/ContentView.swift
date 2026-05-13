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

    var id: String { rawValue }

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

@MainActor
final class LimitStore: ObservableObject {
    @Published var services: [ServiceLimit] {
        didSet { save() }
    }

    private let storageKey = "limit-bar.services.v4"

    init() {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([ServiceLimit].self, from: data) {
            services = LimitService.allCases.map { service in
                decoded.first(where: { $0.id == service }) ?? ServiceLimit.placeholder(for: service)
            }
        } else {
            services = LimitService.allCases.map(ServiceLimit.placeholder)
        }
    }

    var allConnected: Bool { services.allSatisfy(\.isConnected) }
    var connectedCount: Int { services.filter(\.isConnected).count }

    var lowestRemaining: Int? {
        services
            .filter(\.isConnected)
            .flatMap { [$0.current?.remainingPercent, $0.weekly?.remainingPercent] }
            .compactMap { $0 }
            .min()
    }

    var nextReset: Date? {
        services
            .filter(\.isConnected)
            .flatMap { [$0.current?.resetsAt, $0.weekly?.resetsAt] }
            .compactMap { $0 }
            .filter { $0 > Date() }
            .min()
    }

    func connect(_ service: LimitService) {
        setState(.connecting, for: service, error: nil)

        Task {
            do {
                let snapshot = try await ProviderConnector.fetch(service)
                apply(snapshot, to: service)
            } catch {
                setState(.failed, for: service, error: error.localizedDescription)
                ErrorAlertPresenter.show(message: error.localizedDescription)
            }
        }
    }

    func refreshConnected() {
        for service in services where service.isConnected {
            connect(service.id)
        }
    }

    func resetSetup() {
        services = LimitService.allCases.map(ServiceLimit.placeholder)
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
        services[index].errorMessage = nil
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

        if state == .failed { clearError(for: service) }
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

        throw ConnectorError.message("Could not parse Claude Code usage. Open Claude Code and run `/usage`; if it shows balances there, retry here.")
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
        let binary = try await resolveBinary()
        let result = try await ProcessRunner.run(
            executable: "/usr/bin/env",
            arguments: [binary, "auth", "status"],
            input: nil,
            timeout: 8
        )

        let authOutput = [result.stdout, result.stderr].joined(separator: "\n")
        if result.status != 0 || authOutput.localizedCaseInsensitiveContains("not logged") || authOutput.localizedCaseInsensitiveContains("login") {
            throw ConnectorError.message("Gemini CLI is not authenticated. Sign in with the Gemini CLI, then retry.")
        }

        let usage = try await ProcessRunner.run(
            executable: "/usr/bin/env",
            arguments: [binary, "usage"],
            input: nil,
            timeout: 10
        )

        let output = [usage.stdout, usage.stderr].joined(separator: "\n")
        return try parseUsage(output)
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

    private static func normalizePercent(_ value: Int, _ text: String) -> Int {
        if text.localizedCaseInsensitiveContains("% used") {
            return clampPercent(100 - value)
        }
        return value
    }
}

struct ProcessRunner {
    struct Result {
        let stdout: String
        let stderr: String
        let status: Int32
    }

    static func run(executable: String, arguments: [String], input: String?, timeout: TimeInterval) async throws -> Result {
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
            process.environment = mergedEnvironment()

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

    private static func mergedEnvironment() -> [String: String] {
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
                Text("\(store.connectedCount)/2 connected")
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
                    ForEach(store.services) { service in
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
                ProgressView()
                    .controlSize(.small)
            } else if service.isConnected {
                Label("Connected", systemImage: "checkmark.circle.fill")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.green)
            } else {
                Button(service.state == .failed ? "Retry" : "Connect") {
                    store.connect(service.id)
                }
                .buttonStyle(.borderedProminent)
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
                ForEach(store.services.filter(\.isConnected)) { service in
                    ServiceBalanceCard(service: service)
                }
            }

            if store.connectedCount < LimitService.allCases.count {
                VStack(spacing: 10) {
                    ForEach(store.services.filter { !$0.isConnected }) { service in
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

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(balance?.title ?? "Usage limit")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text(kind)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(kindColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(kindColor.opacity(0.18), in: Capsule())
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

            LimitProgressBar(percent: balance?.remainingPercent ?? 0, fillColor: kindColor)
                .frame(height: 8)

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

    private var kindColor: Color {
        kind.localizedCaseInsensitiveContains("weekly")
            ? Color(red: 0.75, green: 0.45, blue: 0.88)
            : Color(red: 0.04, green: 0.81, blue: 0.78)
    }
}

struct LimitProgressBar: View {
    let percent: Int
    let fillColor: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.quaternary)

                Capsule()
                    .fill(progressColor)
                    .frame(width: max(proxy.size.width * CGFloat(percent) / 100, percent > 0 ? 7 : 0))
            }
        }
    }

    private var progressColor: Color {
        if percent < 20 { return .red }
        if percent < 45 { return .orange }
        return fillColor
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
        store.services
            .filter(\.isConnected)
            .compactMap { $0.current?.remainingPercent }
            .min() ?? 0
    }

    private var weeklyPercent: Int {
        store.services
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
                ForEach(store.services) { service in
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

            if let nextReset = store.nextReset {
                HStack(spacing: 8) {
                    Image(systemName: "clock")
                    Text("Next reset")
                    Spacer()
                    Text(relativeResetText(for: nextReset))
                        .monospacedDigit()
                }
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 9)
                .background(.background.opacity(0.45), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            ForEach(store.services.filter(\.isConnected)) { service in
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

    private func relativeResetText(for date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
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
                ProgressView()
                    .controlSize(.small)
            } else if service.isConnected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Button(service.state == .failed ? "Retry" : "Connect") {
                    store.connect(service.id)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
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
    @State private var startsAtLogin = LaunchAtLoginController.isEnabled

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Settings")
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                Text("Connect local providers used by AI Usage Limits.")
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 12) {
                ForEach(store.services) { service in
                    ConnectServiceRow(service: service)
                }
            }

            Divider()

            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Start at login")
                        .font(.callout.weight(.semibold))
                    Text("Launch Limit Bar automatically when you sign in.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Toggle("", isOn: $startsAtLogin)
                    .labelsHidden()
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

            Spacer(minLength: 0)
        }
        .padding(28)
        .frame(width: 620, height: 460, alignment: .topLeading)
        .background(AppSurfaceBackground())
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
        alert.icon = NSImage(named: "AppLogo")
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

struct CompactBalanceRow: View {
    let kind: String
    let balance: LimitBalance?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(balance.map { "\($0.remainingPercent)%" } ?? "--")
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                Spacer()
                Text(kind)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(kindColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(kindColor.opacity(0.18), in: Capsule())
            }

            LimitProgressBar(percent: balance?.remainingPercent ?? 0, fillColor: kindColor)
                .frame(height: 7)

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

    private var kindColor: Color {
        kind.localizedCaseInsensitiveContains("weekly")
            ? Color(red: 0.75, green: 0.45, blue: 0.88)
            : Color(red: 0.04, green: 0.81, blue: 0.78)
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
