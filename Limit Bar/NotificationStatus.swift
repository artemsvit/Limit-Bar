import SwiftUI
import Combine
import UserNotifications
import AppKit

@MainActor
final class NotificationStatusStore: ObservableObject {
    static let shared = NotificationStatusStore()
    enum Status {
        case checking, notRequested, denied, quiet, allowed, unavailable
    }
    @Published private(set) var status: Status = .checking
    @Published private(set) var deliveryMessage: String?
    @Published private(set) var isRequesting = false

    func refresh() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined: status = .notRequested
        case .denied: status = .denied
        case .authorized, .provisional, .ephemeral:
            status = settings.alertSetting == .enabled ? .allowed : .quiet
        @unknown default: status = .unavailable
        }
    }

    func requestAuthorization() {
        guard !isRequesting else { return }
        isRequesting = true
        Task {
            defer { isRequesting = false }
            do {
                _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])
                deliveryMessage = nil
            } catch {
                deliveryMessage = "Notification permission could not be requested. Try System Settings."
            }
            await refresh()
        }
    }

    func reportDelivery(error: Error?, isTest: Bool = false) {
        if error != nil {
            deliveryMessage = "The notification could not be sent. Check System Settings and try again."
        } else if isTest {
            deliveryMessage = "Test sent to macOS. Focus and your notification settings control when it appears."
        }
    }

    func openSettings() {
        let identifier = Bundle.main.bundleIdentifier ?? "artsvit.apps.Limit-Bar"
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(identifier)") {
            NSWorkspace.shared.open(url)
        }
    }
}

struct NotificationStatusView: View {
    @ObservedObject private var status = NotificationStatusStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: status.status == .allowed ? "checkmark.circle" : "bell.badge")
                    .foregroundStyle(status.status == .allowed ? Color.secondary : Color.orange)
                    .accessibilityHidden(true)
                Text(message).font(.caption).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if status.status == .notRequested {
                    Button("Allow alerts") { status.requestAuthorization() }
                        .disabled(status.isRequesting)
                } else {
                    Button("System Settings") { status.openSettings() }
                }
            }
            if let deliveryMessage = status.deliveryMessage {
                Text(deliveryMessage).font(.caption).foregroundStyle(.secondary)
            }
        }
        .task { await status.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await status.refresh() }
        }
    }

    private var message: String {
        switch status.status {
        case .checking: return "Checking macOS notification permission…"
        case .notRequested: return "macOS permission is required to show alerts."
        case .denied: return "Notifications are blocked by macOS. Enable them in System Settings."
        case .quiet: return "Banner alerts are off in macOS. Check your notification settings."
        case .allowed: return "macOS allows alerts. Focus can still silence or delay them."
        case .unavailable: return "Notification status is unavailable. Check System Settings."
        }
    }
}

struct ProviderRecoveryView: View {
    @EnvironmentObject private var store: LimitStore
    let service: ServiceLimit

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if service.isShowingStaleData {
                Label("Couldn’t refresh \(service.id.shortName)", systemImage: "exclamationmark.triangle")
                    .font(.caption.weight(.medium))
                Text("Showing the last successful usage values.").font(.caption).foregroundStyle(.secondary)
            }
            Text(guidance).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if service.isShowingStaleData {
                Button(store.isRefreshing(for: service.id) ? "Reconnecting…" : "Reconnect \(service.id.shortName)") {
                    store.reconnect(service.id)
                }
                .disabled(store.isRefreshing(for: service.id))
                .font(.caption.weight(.medium))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    private var guidance: String {
        let message = (service.errorMessage ?? "").lowercased()
        if message.contains("not found") || message.contains("no such file") {
            return "Install the \(service.id.shortName) CLI, then reconnect."
        }
        if message.contains("updat") || message.contains("no longer supported") {
            return "Update the \(service.id.shortName) CLI, then reconnect."
        }
        if message.contains("login") || message.contains("logged") || message.contains("sign in") || message.contains("auth") || message.contains("401") || message.contains("403") {
            switch service.id {
            case .codex: return "Open Codex and sign in to your account, then reconnect."
            case .claude: return "Open Claude Code and run /login, then reconnect."
            case .antigravity, .gemini: return "Open \(service.id.shortName) and sign in to your Google account, then reconnect."
            }
        }
        if message.contains("timed out") || message.contains("network") || message.contains("offline") {
            return "Check your connection and that \(service.id.shortName) responds, then reconnect."
        }
        return "Open \(service.id.shortName) and check that usage is available, then reconnect."
    }
}
