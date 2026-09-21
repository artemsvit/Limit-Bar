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

    /// Background update checks. Sparkle persists this itself; `SUEnableAutomaticChecks`
    /// in Info.plist only supplies the default for someone who has never changed it.
    var automaticallyChecksForUpdates: Bool {
        get { isConfigured && updaterController.updater.automaticallyChecksForUpdates }
        set {
            guard isConfigured else { return }
            objectWillChange.send()
            updaterController.updater.automaticallyChecksForUpdates = newValue
        }
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
            // Opening the menu is the one moment freshness actually matters.
            store.refreshCoordinator.popoverWillShow()
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
        iconView.update(
            services: connected,
            layout: (displayMode ?? displayPreferences.mode) == .currentPercent ? .percent : .bars
        )
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

        // Both modes are drawn by iconView now, so the status item never resizes from a
        // measured string - the width comes from fixed slots instead.
        let layout: UsageStatusIconView.Layout = displayMode == .currentPercent ? .percent : .bars

        button.title = ""
        button.attributedTitle = NSAttributedString()
        iconView.isHidden = false

        statusItem.length = UsageStatusIconView.width(for: connectedServices, layout: layout)
        iconView.frame = button.bounds

        let summary = connectedServices.map { service in
            let current = service.current.map { "\($0.remainingPercent)%" } ?? "unavailable"
            let weekly = service.weekly.map { "\($0.remainingPercent)%" } ?? "unavailable"
            return "\(service.id.shortName): session \(current), week \(weekly) remaining"
        }.joined(separator: ". ")

        button.setAccessibilityLabel(
            summary.isEmpty
                ? "Limit Bar. No provider connected."
                : "Limit Bar. \(summary)"
        )
        _ = currentPercent
        _ = hasConnection
    }
}

/// The menu bar content: one segment per connected provider, each a brand-coloured dot
/// plus the current remaining percentage.
///
/// Percentages live in fixed-width slots. Sizing the status item from the measured string
/// made the whole menu bar shift sideways whenever a value crossed a digit boundary
/// (100% -> 7%), which is distracting when it happens on its own every refresh.
final class UsageStatusIconView: NSView, NSViewToolTipOwner {
    enum Layout {
        /// Two vertical bars per provider: current and weekly.
        case bars
        /// Coloured dot plus current percentage per provider.
        case percent
    }

    private var services: [ServiceLimit] = []
    /// Named to avoid colliding with NSView.layout().
    private var segmentLayout: Layout = .bars
    private var hasConnection: Bool { !services.isEmpty }

    /// Widest value we ever draw, so the slot never resizes.
    private static let percentSlotText = "100"
    private static let dotDiameter: CGFloat = 6
    private static let dotTextGap: CGFloat = 4
    private static let segmentGap: CGFloat = 8
    /// Breathing room at the ends of the status item.
    private static let horizontalInset: CGFloat = 8
    private static let barGroupWidth: CGFloat = 24

    override var isFlipped: Bool { true }

    private static var percentFont: NSFont {
        .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize - 0.5, weight: .semibold)
    }

    private static var percentSlotWidth: CGFloat {
        ceil(NSAttributedString(
            string: percentSlotText,
            attributes: [.font: percentFont]
        ).size().width)
    }

    /// Width the status item should reserve for the given providers.
    static func width(for services: [ServiceLimit], layout: Layout) -> CGFloat {
        let count = max(services.count, 1)
        switch layout {
        case .bars:
            return CGFloat(count) * barGroupWidth
        case .percent:
            let segment = dotDiameter + dotTextGap + percentSlotWidth
            return CGFloat(count) * segment + CGFloat(count - 1) * segmentGap + horizontalInset
        }
    }

    func update(services: [ServiceLimit], layout: Layout) {
        self.services = services
        self.segmentLayout = layout
        needsDisplay = true
        rebuildToolTips()
    }

    // MARK: - Tooltips

    /// A tooltip rect per segment, so hovering one provider explains that provider.
    private func rebuildToolTips() {
        removeAllToolTips()

        guard segmentLayout == .percent, hasConnection else {
            toolTip = summaryToolTip()
            return
        }

        toolTip = nil
        let segment = Self.dotDiameter + Self.dotTextGap + Self.percentSlotWidth
        var x = (bounds.width - Self.width(for: services, layout: .percent) + Self.horizontalInset) / 2

        for index in services.indices {
            addToolTip(
                NSRect(x: x - Self.segmentGap / 2, y: 0, width: segment + Self.segmentGap, height: bounds.height),
                owner: self,
                userData: nil
            )
            x += segment + Self.segmentGap
            _ = index
        }
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        // AppKit delivers tooltip callbacks on the main thread; assert that rather than
        // making the helpers nonisolated, which would be a claim that is not true.
        MainActor.assumeIsolated {
            guard let service = service(at: point) else { return summaryToolTip() ?? "Limit Bar" }
            return Self.toolTipText(for: service)
        }
    }

    private func service(at point: NSPoint) -> ServiceLimit? {
        guard segmentLayout == .percent, hasConnection else { return nil }

        let segment = Self.dotDiameter + Self.dotTextGap + Self.percentSlotWidth
        let originX = (bounds.width - Self.width(for: services, layout: .percent) + Self.horizontalInset) / 2
        let stride = segment + Self.segmentGap
        let index = Int(floor((point.x - originX + Self.segmentGap / 2) / stride))

        guard services.indices.contains(index) else { return nil }
        return services[index]
    }

    /// Pure over value types, so it can be used as a function value from `map` without
    /// dragging main actor isolation along.
    private nonisolated static func toolTipText(for service: ServiceLimit) -> String {
        let current = service.current.map { "\($0.remainingPercent)%" } ?? "unavailable"
        let weekly = service.weekly.map { "\($0.remainingPercent)%" } ?? "unavailable"
        return "\(service.id.shortName)\nSession: \(current) left\nWeek: \(weekly) left"
    }

    private func summaryToolTip() -> String? {
        guard hasConnection else { return "Limit Bar" }
        return services.map(Self.toolTipText).joined(separator: "\n\n")
    }

    override func layout() {
        super.layout()
        rebuildToolTips()
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        switch segmentLayout {
        case .bars:
            drawBars()
        case .percent:
            drawPercentSegments()
        }
    }

    private func drawPercentSegments() {
        guard hasConnection else {
            drawPlaceholder()
            return
        }

        let slotWidth = Self.percentSlotWidth
        let segment = Self.dotDiameter + Self.dotTextGap + slotWidth
        var x = (bounds.width - Self.width(for: services, layout: .percent) + Self.horizontalInset) / 2

        for service in services {
            let dotRect = NSRect(
                x: x,
                y: (bounds.height - Self.dotDiameter) / 2,
                width: Self.dotDiameter,
                height: Self.dotDiameter
            )
            service.id.markerColor.setFill()
            NSBezierPath(ovalIn: dotRect).fill()

            let text = service.current.map { "\($0.remainingPercent)" } ?? "--"
            let attributed = NSAttributedString(
                string: text,
                attributes: [
                    .font: Self.percentFont,
                    .foregroundColor: NSColor.labelColor
                ]
            )
            // Right-align inside the fixed slot so digits stay put as values change.
            let textSize = attributed.size()
            let textX = x + Self.dotDiameter + Self.dotTextGap + (slotWidth - ceil(textSize.width))
            attributed.draw(at: NSPoint(x: textX, y: (bounds.height - textSize.height) / 2))

            x += segment + Self.segmentGap
        }
    }

    private func drawPlaceholder() {
        let attributed = NSAttributedString(
            string: "--",
            attributes: [
                .font: Self.percentFont,
                .foregroundColor: NSColor.labelColor.withAlphaComponent(0.55)
            ]
        )
        let size = attributed.size()
        attributed.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
    }

    private func drawBars() {
        let barWidth: CGFloat = 5
        let gap: CGFloat = 4
        let totalWidth = barWidth * 2 + gap
        let maxHeight: CGFloat = 15
        let count = max(services.count, 1)
        let originX = (bounds.width - CGFloat(count) * Self.barGroupWidth) / 2 + (Self.barGroupWidth - totalWidth) / 2
        let originY = (bounds.height - maxHeight) / 2

        for index in 0..<count {
            let service = services.isEmpty ? nil : services[index]
            let x = originX + CGFloat(index) * Self.barGroupWidth
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

    private let windowWidth: CGFloat = 580
    private var window: NSWindow?
    private let windowDelegate = TopAnchoredWindowDelegate()

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
        // Let the window track the SwiftUI content height instead of padding a fixed
        // frame, so no empty band is left below the footer.
        hostingView.sizingOptions = [.preferredContentSize]

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: windowWidth, height: hostingView.fittingSize.height),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        window.delegate = windowDelegate
        window.center()
        windowDelegate.captureTop(of: window)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.window = window
    }
}

/// When the notifications accordion opens or closes, AppKit resizes the window from its
/// bottom-left origin, which makes the title bar jump. Pin the top edge instead.
@MainActor
private final class TopAnchoredWindowDelegate: NSObject, NSWindowDelegate {
    private var topEdge: CGFloat?
    private var isAdjusting = false

    func captureTop(of window: NSWindow) {
        topEdge = window.frame.maxY
    }

    func windowDidMove(_ notification: Notification) {
        guard !isAdjusting, let window = notification.object as? NSWindow else { return }
        topEdge = window.frame.maxY
    }

    func windowDidResize(_ notification: Notification) {
        guard !isAdjusting, let window = notification.object as? NSWindow else { return }

        guard let topEdge else {
            self.topEdge = window.frame.maxY
            return
        }

        let drift = window.frame.maxY - topEdge
        guard abs(drift) > 0.5 else { return }

        isAdjusting = true
        var frame = window.frame
        frame.origin.y = topEdge - frame.height
        window.setFrame(frame, display: true)
        isAdjusting = false
    }
}
