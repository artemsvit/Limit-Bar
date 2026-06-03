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
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let iconView = UsageStatusIconView(frame: NSRect(x: 0, y: 0, width: 24, height: 22))
    private var cancellable: AnyCancellable?

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
        cancellable = store.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in
                self?.refreshIcon()
            }
        }
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

    private func refreshIcon() {
        let connected = store.services.filter(\.isConnected)
        let current = connected.compactMap { $0.current?.remainingPercent }.min() ?? 0
        let weekly = connected.compactMap { $0.weekly?.remainingPercent }.min() ?? 0
        iconView.update(currentPercent: current, weeklyPercent: weekly, hasConnection: !connected.isEmpty)
    }
}

final class UsageStatusIconView: NSView {
    private var currentPercent = 0
    private var weeklyPercent = 0
    private var hasConnection = false

    override var isFlipped: Bool { true }

    func update(currentPercent: Int, weeklyPercent: Int, hasConnection: Bool) {
        self.currentPercent = min(max(currentPercent, 0), 100)
        self.weeklyPercent = min(max(weeklyPercent, 0), 100)
        self.hasConnection = hasConnection
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let barWidth: CGFloat = 5
        let gap: CGFloat = 4
        let totalWidth = barWidth * 2 + gap
        let maxHeight: CGFloat = 15
        let originX = (bounds.width - totalWidth) / 2
        let originY = (bounds.height - maxHeight) / 2

        drawBar(
            x: originX,
            y: originY,
            width: barWidth,
            height: maxHeight,
            percent: currentPercent
        )
        drawBar(
            x: originX + barWidth + gap,
            y: originY,
            width: barWidth,
            height: maxHeight,
            percent: weeklyPercent
        )
    }

    private func drawBar(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, percent: Int) {
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

    private let compactHeight: CGFloat = 650
    private let expandedHeight: CGFloat = 830
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
            contentRect: NSRect(x: 0, y: 0, width: 620, height: compactHeight),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 620, height: compactHeight)
        window.contentView = hostingView
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.window = window
    }

    func updateHeight(showingNotificationsDetails: Bool) {
        guard let window else { return }

        let targetHeight = showingNotificationsDetails ? expandedHeight : compactHeight
        guard abs(window.frame.height - targetHeight) > 0.5 else { return }

        DispatchQueue.main.async {
            guard let window = self.window else { return }
            var frame = window.frame
            frame.origin.y += frame.height - targetHeight
            frame.size.height = targetHeight

            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                context.allowsImplicitAnimation = false
                window.animator().setFrame(frame, display: true)
            }
        }
    }
}
