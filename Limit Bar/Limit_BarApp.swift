//
//  Limit_BarApp.swift
//  Limit Bar
//
//  Created by Artem Svitelskyi on 13.05.2026.
//

import SwiftUI
import AppKit
import Combine
import UserNotifications
import Sparkle
import QuartzCore

@main
struct Limit_BarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private let store = LimitStore()
    private let appUpdater = AppUpdater.shared
    private var statusController: StatusBarController?

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.applicationIconImage = NSImage(named: "AppLogo")
        UNUserNotificationCenter.current().delegate = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if NotificationPreferencesStore.shared.preferences.isEnabled {
            UsageNotificationCenter.requestAuthorizationIfNeeded()
        }
        statusController = StatusBarController(store: store)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}

@MainActor
final class AppUpdater: ObservableObject {
    static let shared = AppUpdater()

    let isConfigured: Bool

    private let updaterController: SPUStandardUpdaterController

    private init() {
        isConfigured = Self.hasRequiredConfiguration
        updaterController = SPUStandardUpdaterController(
            startingUpdater: isConfigured,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    var canCheckForUpdates: Bool {
        isConfigured && updaterController.updater.canCheckForUpdates
    }

    var statusText: String {
        if isConfigured {
            return "Sparkle is configured for signed appcast updates."
        }
        return "Update feed is not configured for this build."
    }

    func checkForUpdates() {
        guard isConfigured else {
            ErrorAlertPresenter.show(message: "Sparkle needs SPARKLE_FEED_URL and SPARKLE_PUBLIC_ED_KEY build settings before updates can run.")
            return
        }

        updaterController.checkForUpdates(nil)
    }

    private static var hasRequiredConfiguration: Bool {
        guard
            let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
            let publicKey = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
        else {
            return false
        }

        let trimmedFeed = feed.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedKey = publicKey.trimmingCharacters(in: .whitespacesAndNewlines)

        return URL(string: trimmedFeed)?.scheme != nil &&
            !trimmedFeed.contains("$(") &&
            !trimmedKey.isEmpty &&
            !trimmedKey.contains("$(")
    }
}

@MainActor
final class StatusBarController: NSObject {
    private let store: LimitStore
    private let displayPreferences = MenuBarDisplayPreferencesStore.shared
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let iconView = UsageStatusIconView(frame: NSRect(x: 0, y: 0, width: 24, height: 22))
    private var cancellables = Set<AnyCancellable>()

    init(store: LimitStore) {
        self.store = store
        self.statusItem = NSStatusBar.system.statusItem(withLength: 24)
        super.init()

        popover.behavior = .transient
        popover.contentSize = NSSize(width: 340, height: 520)
        popover.contentViewController = NSHostingController(
            rootView: MenuBarView()
                .environmentObject(store)
        )

        if let button = statusItem.button {
            button.frame = NSRect(x: 0, y: 0, width: 24, height: 22)
            button.addSubview(iconView)
            iconView.frame = button.bounds
            iconView.autoresizingMask = [.width, .height]
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        refreshIcon()
        store.objectWillChange
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.refreshIcon()
                }
            }
            .store(in: &cancellables)

        displayPreferences.$mode
            .sink { [weak self] mode in
                self?.refreshIcon(displayMode: mode)
            }
            .store(in: &cancellables)
    }

    @objc private func togglePopover(_ sender: AnyObject?) {
        guard let button = statusItem.button else { return }

        if popover.isShown {
            popover.performClose(sender)
        } else {
            refreshIcon()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    private func refreshIcon(displayMode: MenuBarDisplayMode? = nil) {
        let preferredOrder: [LimitService] = [.claude, .codex, .antigravity]
        let connected = preferredOrder.compactMap { id in
            store.activeServices.first { $0.id == id && $0.isConnected }
        }
        let current = connected.compactMap { $0.current?.remainingPercent }.min() ?? 0
        let hasConnection = !connected.isEmpty
        iconView.update(services: connected)
        updateStatusButton(
            currentPercent: current,
            hasConnection: hasConnection,
            connectedServices: connected,
            displayMode: displayMode ?? displayPreferences.mode
        )
    }

    private func updateStatusButton(
        currentPercent: Int,
        hasConnection: Bool,
        connectedServices: [ServiceLimit],
        displayMode: MenuBarDisplayMode
    ) {
        guard let button = statusItem.button else { return }

        switch displayMode {
        case .bars:
            statusItem.length = CGFloat(max(connectedServices.count, 1)) * 24
            button.title = ""
            button.attributedTitle = NSAttributedString()
            let summary = connectedServices.map { service in
                let current = service.current.map { "\($0.remainingPercent)%" } ?? "unavailable"
                let weekly = service.weekly.map { "\($0.remainingPercent)%" } ?? "unavailable"
                return "\(service.id.shortName): current \(current), weekly \(weekly) remaining"
            }.joined(separator: "\n")
            button.toolTip = summary.isEmpty ? "Limit Bar" : summary
            button.setAccessibilityLabel(summary.isEmpty ? "Limit Bar" : "Limit Bar. \(summary)")
            iconView.isHidden = false
            iconView.frame = button.bounds

        case .currentPercent:
            button.setAccessibilityLabel("Limit Bar")
            iconView.isHidden = true
            let title: String
            if connectedServices.count > 1 {
                let preferredOrder: [LimitService] = [.claude, .codex, .antigravity, .gemini]
                let orderedServices = connectedServices.sorted {
                    (preferredOrder.firstIndex(of: $0.id) ?? .max) <
                    (preferredOrder.firstIndex(of: $1.id) ?? .max)
                }
                title = orderedServices.map { service in
                    let percent = service.current.map { "\($0.remainingPercent)%" } ?? "--"
                    return "\(service.id.menuBarAbbreviation):\(percent)"
                }.joined(separator: " ")
            } else {
                title = hasConnection ? "\(currentPercent)%" : "--%"
            }
            let attributedTitle = NSAttributedString(
                string: title,
                attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .semibold),
                    .foregroundColor: NSColor.labelColor
                ]
            )
            statusItem.length = ceil(attributedTitle.size().width) + 12
            button.attributedTitle = attributedTitle
            button.toolTip = connectedServices.count > 1
                ? connectedServices
                    .sorted { $0.id.shortName < $1.id.shortName }
                    .map { service in
                        let percent = service.current.map { "\($0.remainingPercent)%" } ?? "--"
                        return "\(service.id.shortName): \(percent) remaining"
                    }
                    .joined(separator: " · ")
                : (hasConnection ? "Current usage remaining: \(currentPercent)%" : "Limit Bar")
        }
    }
}

final class UsageStatusIconView: NSView {
    private var services: [ServiceLimit] = []
    private var hasConnection: Bool { !services.isEmpty }

    override var isFlipped: Bool { true }

    func update(services: [ServiceLimit]) {
        self.services = services
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let barWidth: CGFloat = 5
        let gap: CGFloat = 4
        let totalWidth = barWidth * 2 + gap
        let maxHeight: CGFloat = 15
        let count = max(services.count, 1)
        let groupWidth: CGFloat = 24
        let originX = (bounds.width - CGFloat(count) * groupWidth) / 2 + (groupWidth - totalWidth) / 2
        let originY = (bounds.height - maxHeight) / 2

        for index in 0..<count {
        let service = services.isEmpty ? nil : services[index]
        let x = originX + CGFloat(index) * groupWidth
        drawBar(
            x: x,
            y: originY,
            width: barWidth,
            height: maxHeight,
            percent: service?.current?.remainingPercent ?? 0
        )
        drawBar(
            x: x + barWidth + gap,
            y: originY,
            width: barWidth,
            height: maxHeight,
            percent: service?.weekly?.remainingPercent ?? 0
        )
        }
    }

    private func drawBar(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, percent: Int) {
        let percent = min(max(percent, 0), 100)
        let railRect = NSRect(x: x, y: y, width: width, height: height)
        let rail = NSBezierPath(roundedRect: railRect, xRadius: width / 2, yRadius: width / 2)
        NSColor.labelColor.withAlphaComponent(hasConnection ? 0.22 : 0.16).setFill()
        rail.fill()

        guard hasConnection, percent > 0 else { return }

        let fillHeight = max(height * CGFloat(percent) / 100, 3)
        let fillRect = NSRect(x: x, y: y + height - fillHeight, width: width, height: fillHeight)
        let fill = NSBezierPath(roundedRect: fillRect, xRadius: width / 2, yRadius: width / 2)
        fillColor(for: percent).setFill()
        fill.fill()
    }

    private func fillColor(for percent: Int) -> NSColor {
        if percent < 20 { return NSColor.labelColor.withAlphaComponent(0.95) }
        if percent < 45 { return NSColor.labelColor.withAlphaComponent(0.82) }
        return NSColor.labelColor.withAlphaComponent(0.72)
    }
}

@MainActor
final class SettingsWindowPresenter {
    static let shared = SettingsWindowPresenter()

    private let windowHeight: CGFloat = 740
    private let windowWidth: CGFloat = 580
    private var window: NSWindow?

    func open(store: LimitStore) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hostingView = NSHostingView(
            rootView: SettingsWindowView()
                .environmentObject(store)
        )

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: windowWidth, height: windowHeight)
        window.contentView = hostingView
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.window = window
    }

    func updateHeight(showingNotificationsDetails: Bool, animated: Bool = true) {
        // Settings uses a fixed-height window so accordions never shake the window frame.
    }
}
