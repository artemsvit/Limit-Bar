import SwiftUI
import Charts
import Combine
import AppKit
import UniformTypeIdentifiers

@MainActor
final class UsageHistoryStore: ObservableObject {
    static let shared = UsageHistoryStore()
    @Published private(set) var samples: [UsageHistorySample] = []
    @Published private(set) var storageError: String?
    @Published var isRecording: Bool {
        didSet { UserDefaults.standard.set(isRecording, forKey: "limit-bar.history-recording.v1") }
    }
    private let file: URL
    private let writer = DispatchQueue(label: "artsvit.limitbar.history", qos: .utility)

    init(directory: URL? = nil) {
        isRecording = UserDefaults.standard.object(forKey: "limit-bar.history-recording.v1") as? Bool ?? true
        let root = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Limit Bar", isDirectory: true)
        file = root.appendingPathComponent("usage-history-v1.json")
        if FileManager.default.fileExists(atPath: file.path) {
            do {
                samples = try JSONDecoder().decode([UsageHistorySample].self, from: Data(contentsOf: file))
                    .filter { $0.date >= Date().addingTimeInterval(-UsageHistoryPolicy.retention) && $0.date <= Date() }
            } catch {
                storageError = "Saved history could not be read. New observations will start a new history."
            }
        }
    }

    func record(_ service: ServiceLimit) {
        guard isRecording, service.isConnected else { return }
        samples = UsageHistoryPolicy.recording(
            UsageHistorySample(provider: service.id.rawValue, date: service.lastUpdated ?? Date(),
                               session: service.current?.remainingPercent, weekly: service.weekly?.remainingPercent),
            in: samples
        )
        save()
    }

    func clear() {
        samples = []
        save()
    }

    private func save() {
        let snapshot = samples
        let destination = file
        writer.async { [weak self] in
            do {
                let data = try JSONEncoder().encode(snapshot)
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: destination, options: .atomic)
                Task { @MainActor [weak self] in self?.storageError = nil }
            } catch {
                Task { @MainActor [weak self] in self?.storageError = "History could not be saved on this Mac." }
            }
        }
    }
}

@MainActor
final class UsageHistoryWindowPresenter {
    static let shared = UsageHistoryWindowPresenter()
    private var window: NSWindow?

    func open() {
        if let window {
            window.makeKeyAndOrderFront(nil)
        } else {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 940, height: 850),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "Usage History"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: UsageHistoryView())
            window.minSize = NSSize(width: 760, height: 620)
            window.center()
            window.makeKeyAndOrderFront(nil)
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
    }
}

private enum HistoryPeriod: String, CaseIterable, Identifiable {
    case hour = "1 hour", day = "24 hours", week = "7 days", month = "30 days"
    var id: String { rawValue }
    var duration: TimeInterval {
        switch self {
        case .hour: return 3_600
        case .day: return 86_400
        case .week: return 7 * 86_400
        case .month: return 30 * 86_400
        }
    }
}

struct UsageHistoryView: View {
    @ObservedObject private var history = UsageHistoryStore.shared
    @State private var provider: LimitService = .codex
    @State private var period: HistoryPeriod = .day
    @State private var window: HistoryLimitWindow = .session
    @State private var selectedDate: Date?
    @State private var showsFullPeriod = false
    @State private var confirmsClear = false
    @State private var exportError: String?
    @State private var now = Date()

    private var observations: [UsageHistorySample] {
        let cutoff = now.addingTimeInterval(-period.duration)
        return history.samples.filter { $0.provider == provider.rawValue && $0.date >= cutoff && $0.date <= now }
    }

    var body: some View {
        let analysis = HistoryAnalysis(samples: observations, window: window)
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                providerSelector
                HStack(spacing: 20) {
                    Picker("Period", selection: $period) {
                        ForEach(HistoryPeriod.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 410)
                    Spacer(minLength: 8)
                    Picker("Usage window", selection: $window) {
                        ForEach(HistoryLimitWindow.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 200)
                }
                summaries(analysis)
                HistoryChartCard(analysis: analysis, provider: provider, window: window, now: now,
                                 duration: period.duration, showsFullPeriod: $showsFullPeriod, selectedDate: $selectedDate)
                HistoryReadingsTable(analysis: analysis, window: window, selectedDate: $selectedDate)
                footer
            }
            .padding(24)
        }
        .frame(minWidth: 710, minHeight: 550)
        .background(AppSurfaceBackground())
        .confirmationDialog("Clear all usage history?", isPresented: $confirmsClear) {
            Button("Clear history", role: .destructive) { history.clear(); selectedDate = nil }
        } message: {
            Text("This removes recorded usage for every provider from this Mac.")
        }
        .alert("Could not export history", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
            Button("OK") { exportError = nil }
        } message: { Text(exportError ?? "") }
        .onChange(of: provider) { selectedDate = nil }
        .onChange(of: period) { selectedDate = nil }
        .onChange(of: window) { selectedDate = nil }
        .onChange(of: history.samples) { now = Date() }
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { now = $0 }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 16) {
                Text("Usage history")
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                Spacer(minLength: 16)
                HStack(spacing: 8) {
                    Button { export() } label: {
                        Label("Export CSV", systemImage: "square.and.arrow.up")
                            .font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 12)
                            .frame(height: 32)
                            .historyActionSurface()
                    }
                    .buttonStyle(.plain)
                    .disabled(observations.isEmpty)
                    .help("Export the selected provider and period")

                    Menu {
                        Button("Clear all history…", systemImage: "trash", role: .destructive) { confirmsClear = true }
                            .disabled(history.samples.isEmpty)
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 14, weight: .semibold))
                            .frame(width: 32, height: 32)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .frame(width: 32, height: 32)
                    .historyActionSurface()
                    .accessibilityLabel("History actions")
                    .help("History actions")
                }
            }
            Text("See how your available usage changes over time.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private var providerSelector: some View {
        HStack(spacing: 10) {
            ForEach(LimitService.activeCases) { service in
                let latest = history.samples.last { $0.provider == service.rawValue }
                let value = latest.flatMap { window.value(in: $0) }
                Button { provider = service } label: {
                    HStack(spacing: 10) {
                        ServiceIcon(service: service, size: 28)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(service.shortName).font(.callout.weight(.semibold))
                            Text(value.map { "\($0)% · \(window.rawValue.lowercased())" } ?? "No readings yet")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        if provider == service {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(Color(nsColor: service.markerColor))
                        }
                    }
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(provider == service ? Color(nsColor: service.markerColor).opacity(0.1) : .primary.opacity(0.025),
                                in: RoundedRectangle(cornerRadius: 13))
                    .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(
                        provider == service ? Color(nsColor: service.markerColor).opacity(0.5) : .primary.opacity(0.08), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help("Latest recorded balance across saved history")
                .accessibilityLabel("\(service.shortName), \(value.map { "\($0) percent remaining" } ?? "no readings")")
                .accessibilityAddTraits(provider == service ? .isSelected : [])
            }
        }
    }

    private func summaries(_ analysis: HistoryAnalysis) -> some View {
        HStack(spacing: 10) {
            HistoryStat(title: "LATEST REMAINING", value: analysis.latest?.value.map { "\($0)%" } ?? "—",
                        detail: analysis.latest.map { $0.sample.date.formatted(date: .omitted, time: .shortened) } ?? "Waiting for a reading",
                        color: Color(nsColor: provider.markerColor))
            HistoryStat(title: "LOWEST REMAINING", value: analysis.lowest?.value.map { "\($0)%" } ?? "—",
                        detail: analysis.lowest.map { $0.sample.date.formatted(date: .abbreviated, time: .shortened) } ?? "No data in this period")
            HistoryStat(title: "OBSERVED DROP", value: analysis.comparableIntervals > 0 ? "\(analysis.observedDrop) pp" : "—",
                        detail: "Between nearby readings")
            HistoryStat(title: "READINGS", value: "\(analysis.readings.count)",
                        detail: analysis.balanceIncreases == 1 ? "1 balance increase" : "\(analysis.balanceIncreases) balance increases")
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = history.storageError {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.caption)
            }
            HStack {
                Toggle("Record usage history on this Mac", isOn: $history.isRecording).font(.callout)
                Spacer(minLength: 12)
                Label(history.isRecording ? "Recording" : "Paused",
                      systemImage: history.isRecording ? "record.circle" : "pause.circle")
                    .font(.caption)
                    .foregroundStyle(history.isRecording ? Color.secondary : Color.orange)
            }
            Text("Stored locally for 30 days, with up to one reading per provider every 5 minutes. No account details or session content are saved. History starts when recording is enabled.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func export() {
        let csv = HistoryAnalysis(samples: observations, window: window).csv
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "Limit-Bar-\(provider.shortName)-history.csv"
        panel.message = "Export \(provider.shortName) readings from the last \(period.rawValue), including session and weekly balances."
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do { try csv.write(to: url, atomically: true, encoding: .utf8) }
            catch { exportError = error.localizedDescription }
        }
    }
}

private struct HistoryStat: View {
    let title: String
    let value: String
    let detail: String
    var color: Color = .primary
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 10, weight: .semibold)).tracking(0.6).foregroundStyle(.secondary)
            Text(value).font(.system(size: 30, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(color)
            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).help(detail)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(14).historySurface()
        .accessibilityElement(children: .combine)
    }
}

private struct HistoryChartCard: View {
    let analysis: HistoryAnalysis
    let provider: LimitService
    let window: HistoryLimitWindow
    let now: Date
    let duration: TimeInterval
    @Binding var showsFullPeriod: Bool
    @Binding var selectedDate: Date?

    private var color: Color { Color(nsColor: provider.markerColor) }
    private var domain: ClosedRange<Date> {
        let fullStart = now.addingTimeInterval(-duration)
        guard !showsFullPeriod, let first = analysis.readings.first?.sample.date,
              let last = analysis.readings.last?.sample.date else { return fullStart...now }
        let span = max(last.timeIntervalSince(first), 600)
        let padding = span * 0.04
        return max(fullStart, first.addingTimeInterval(-padding))...min(now, max(last.addingTimeInterval(padding), first.addingTimeInterval(600)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(window.rawValue) remaining").font(.headline)
                    Text(showsFullPeriod ? "Full period · Gaps mean no readings were recorded" : "Recorded span · Select a time or a reading below")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Picker("Chart range", selection: $showsFullPeriod) {
                    Text("Recorded span").tag(false)
                    Text("Full period").tag(true)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 230)
            }
            if analysis.latest == nil {
                ContentUnavailableView("No \(window.rawValue.lowercased()) readings", systemImage: "chart.xyaxis.line",
                    description: Text("Readings appear after a provider reports usage. Try another provider or period, and keep recording on."))
                    .frame(height: 240)
            } else {
                chart
                selectedReading
            }
            Text("Observed drop adds decreases between readings no more than 30 minutes apart. Values use percentage points (pp), not token counts. Increases may reflect resets or provider corrections.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(18).historySurface()
    }

    private var chart: some View {
        Chart {
            ForEach(analysis.chartReadings()) { reading in
                if let value = reading.value {
                    LineMark(x: .value("Recorded time", reading.sample.date), y: .value("Remaining percent", value),
                             series: .value("Recording period", reading.segment))
                        .foregroundStyle(color).lineStyle(StrokeStyle(lineWidth: 2.5))
                    PointMark(x: .value("Recorded time", reading.sample.date), y: .value("Remaining percent", value))
                        .foregroundStyle(color).symbolSize(14)
                        .accessibilityLabel(reading.sample.date.formatted())
                        .accessibilityValue("\(value) percent remaining")
                }
            }
            if let selectedDate, let reading = analysis.nearest(to: selectedDate), let value = reading.value {
                RuleMark(x: .value("Selected time", reading.sample.date))
                    .foregroundStyle(.secondary.opacity(0.5)).lineStyle(StrokeStyle(dash: [4, 4]))
                PointMark(x: .value("Selected reading", reading.sample.date), y: .value("Selected remaining percent", value))
                    .foregroundStyle(color).symbolSize(65)
            }
        }
        .chartYScale(domain: 0...100)
        .chartXScale(domain: domain)
        .chartYAxis { AxisMarks(position: .leading, values: [0, 25, 50, 75, 100]) { value in
            AxisGridLine().foregroundStyle(.primary.opacity(0.07))
            AxisValueLabel { if let percent = value.as(Int.self) { Text("\(percent)%") } }
        } }
        .chartXAxis { AxisMarks(values: .automatic(desiredCount: 5)) }
        .chartXSelection(value: $selectedDate)
        .frame(height: 240)
        .accessibilityLabel("\(provider.shortName) \(window.rawValue.lowercased()) remaining usage over time")
    }

    private var selectedReading: some View {
        HStack(spacing: 20) {
            if let reading = analysis.nearest(to: selectedDate) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(selectedDate == nil ? "LATEST READING" : "SELECTED READING")
                        .font(.system(size: 9, weight: .semibold)).tracking(0.7).foregroundStyle(.secondary)
                    Text(reading.sample.date.formatted(date: .abbreviated, time: .shortened)).font(.callout.weight(.medium))
                }
                Spacer(minLength: 8)
                readingValue("Session", value: reading.sample.session)
                readingValue("Weekly", value: reading.sample.weekly)
                if selectedDate != nil {
                    Button("Latest") { selectedDate = nil }.font(.caption)
                }
            }
        }
        .padding(12).background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
    }

    private func readingValue(_ title: String, value: Int?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value.map { "\($0)%" } ?? "Unavailable").font(.callout.weight(.semibold)).monospacedDigit()
        }
    }
}

private struct HistoryReadingsTable: View {
    let analysis: HistoryAnalysis
    let window: HistoryLimitWindow
    @Binding var selectedDate: Date?

    private var selection: Binding<UUID?> {
        Binding(get: { selectedDate == nil ? nil : analysis.nearest(to: selectedDate)?.id },
                set: { id in selectedDate = analysis.readings.first { $0.id == id }?.sample.date })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Recorded readings").font(.headline)
                Spacer()
                Text("\(analysis.readings.count) readings · Newest first").font(.caption).foregroundStyle(.secondary)
            }
            if analysis.readings.isEmpty {
                Text("No readings in this period. History will build as providers refresh.")
                    .font(.callout).foregroundStyle(.secondary).padding(.vertical, 16)
            } else {
                Table(Array(analysis.readings.reversed()), selection: selection) {
                    TableColumn("Recorded") { reading in
                        Text(reading.sample.date.formatted(date: .abbreviated, time: .shortened)).monospacedDigit()
                    }.width(min: 175, ideal: 240)
                    TableColumn("Session") { reading in Text(percent(reading.sample.session)).monospacedDigit() }
                    TableColumn("Weekly") { reading in Text(percent(reading.sample.weekly)).monospacedDigit() }
                    TableColumn("\(window.rawValue) change") { reading in
                        Text(change(reading)).monospacedDigit()
                            .foregroundStyle((reading.change ?? 0) > 0 ? Color.green : Color.secondary)
                    }
                }
                .tableStyle(.inset(alternatesRowBackgrounds: true))
                .frame(height: min(230, CGFloat(analysis.readings.count) * 28 + 36))
                .accessibilityLabel("Recorded usage readings. Select a row to inspect it on the chart.")
            }
        }
        .padding(18).historySurface()
    }

    private func percent(_ value: Int?) -> String { value.map { "\($0)%" } ?? "—" }
    private func change(_ reading: HistoryReading) -> String {
        if reading.followsGap { return "Recording gap" }
        guard let change = reading.change else { return "—" }
        if change == 0 { return "No change" }
        return "\(change > 0 ? "+" : "−")\(abs(change)) pp"
    }
}

private extension View {
    func historyActionSurface() -> some View {
        background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.primary.opacity(0.08), lineWidth: 1))
    }

    func historySurface() -> some View {
        background(.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.primary.opacity(0.075), lineWidth: 1))
    }
}

