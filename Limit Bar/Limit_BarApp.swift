//
//  Limit_BarApp.swift
//  Limit Bar
//
//  Created by Artem Svitelskyi on 13.05.2026.
//

import SwiftUI
import AppKit
import Combine

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
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = LimitStore()
    private var statusController: StatusBarController?

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.applicationIconImage = NSImage(named: "AppLogo")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusController = StatusBarController(store: store)
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
            percent: currentPercent,
            highColor: NSColor(red: 0.04, green: 0.81, blue: 0.78, alpha: 1)
        )
        drawBar(
            x: originX + barWidth + gap,
            y: originY,
            width: barWidth,
            height: maxHeight,
            percent: weeklyPercent,
            highColor: NSColor(red: 0.75, green: 0.45, blue: 0.88, alpha: 1)
        )
    }

    private func drawBar(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, percent: Int, highColor: NSColor) {
        let railRect = NSRect(x: x, y: y, width: width, height: height)
        let rail = NSBezierPath(roundedRect: railRect, xRadius: width / 2, yRadius: width / 2)
        NSColor.labelColor.withAlphaComponent(hasConnection ? 0.22 : 0.16).setFill()
        rail.fill()

        guard hasConnection, percent > 0 else { return }

        let fillHeight = max(height * CGFloat(percent) / 100, 3)
        let fillRect = NSRect(x: x, y: y + height - fillHeight, width: width, height: fillHeight)
        let fill = NSBezierPath(roundedRect: fillRect, xRadius: width / 2, yRadius: width / 2)
        color(for: percent, highColor: highColor).setFill()
        fill.fill()
    }

    private func color(for percent: Int, highColor: NSColor) -> NSColor {
        if percent < 20 { return .systemRed }
        if percent < 45 { return .systemOrange }
        return highColor
    }
}

@MainActor
final class SettingsWindowPresenter {
    static let shared = SettingsWindowPresenter()

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
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 460),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.window = window
    }
}
