import Foundation

@main
struct UsageInsightsTests {
    static func main() throws {
        let legacyPreferences = Data(#"{"isEnabled":true,"thresholds":[50,25,10]}"#.utf8)
        let preferences = try JSONDecoder().decode(NotificationPreferences.self, from: legacyPreferences)
        expect(preferences.isEnabled && preferences.thresholds == [50, 25, 10], "Existing notification preferences are preserved")
        expect(preferences.notifyOnRecovery ?? true, "Recovery defaults to enabled for existing preferences")
        var disabledRecovery = preferences
        disabledRecovery.notifyOnRecovery = false
        expect(try JSONDecoder().decode(NotificationPreferences.self, from: JSONEncoder().encode(disabledRecovery)).notifyOnRecovery == false,
               "Recovery preference persists when disabled")
        print("PASS preferences: existing settings migrate and recovery choice persists")

        var state = UsageRecoveryState()
        expect(!state.observe(session: 80, weekly: 60), "First observation must not alert")
        expect(!state.observe(session: 0, weekly: 60), "Depletion arms recovery")
        expect(!state.observe(session: nil, weekly: 60), "Missing data cannot confirm recovery")
        expect(!state.observe(session: 1, weekly: 60), "A small fluctuation must not alert")
        let saved = try JSONEncoder().encode(state)
        state = try JSONDecoder().decode(UsageRecoveryState.self, from: saved)
        expect(state.observe(session: 5, weekly: 60), "Recovery survives relaunch and alerts at 5 percent")
        expect(!state.observe(session: 90, weekly: 60), "Recovery alerts only once")
        expect(!state.observe(session: 0, weekly: 0), "Both windows depleted")
        expect(!state.observe(session: 80, weekly: 0), "Weekly depletion still prevents use")
        expect(!state.observe(session: 80, weekly: nil), "Unknown weekly data cannot clear depletion")
        expect(state.observe(session: 80, weekly: 25), "Alert once both depleted windows recover")
        expect(!state.observe(session: 80, weekly: 25), "Repeated refresh does not duplicate alert")
        var weeklyOnly = UsageRecoveryState()
        expect(!weeklyOnly.observe(session: nil, weekly: 0), "Weekly-only provider can arm")
        expect(weeklyOnly.observe(session: nil, weekly: 100), "Weekly-only provider can recover")
        print("PASS recovery: depletion, jitter, missing windows, relaunch, repeated refresh, and weekly blocking")

        let now = Date(timeIntervalSince1970: 1_800_000_010)
        let old = UsageHistorySample(provider: "Codex", date: now.addingTimeInterval(-31 * 86_400), session: 40, weekly: 70)
        let first = UsageHistorySample(provider: "Codex", date: now, session: 80, weekly: 70)
        var samples = UsageHistoryPolicy.recording(first, in: [old])
        expect(samples.count == 1, "Old history expires")
        let sameBucket = UsageHistorySample(provider: "Codex", date: now.addingTimeInterval(10), session: 75, weekly: nil)
        samples = UsageHistoryPolicy.recording(sameBucket, in: samples)
        expect(samples.count == 1 && samples[0].session == 75, "Keep the latest observation in each five-minute bucket")
        samples = UsageHistoryPolicy.recording(.init(provider: "Claude Code", date: now.addingTimeInterval(10), session: 90, weekly: 50), in: samples)
        expect(samples.count == 2, "Provider observations are independent")
        samples = UsageHistoryPolicy.recording(.init(provider: "Codex", date: now.addingTimeInterval(310), session: 60, weekly: 40), in: samples)
        expect(samples.count == 3, "The next bucket keeps a new observation")
        samples = UsageHistoryPolicy.recording(.init(provider: "Codex", date: now.addingTimeInterval(311), session: nil, weekly: nil), in: samples)
        expect(samples.count == 3, "Unavailable limits do not invent observations")
        let roundTrip = try JSONDecoder().decode([UsageHistorySample].self, from: JSONEncoder().encode(samples))
        expect(roundTrip == samples, "History preserves values and stable IDs on disk")
        let bounded = UsageHistorySample(provider: "Codex", date: now, session: -10, weekly: 110)
        expect(bounded.session == 0 && bounded.weekly == 100, "Percentages stay in range")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("history.json")
        try JSONEncoder().encode(samples).write(to: file, options: .atomic)
        expect(try JSONDecoder().decode([UsageHistorySample].self, from: Data(contentsOf: file)) == samples, "Atomic disk save reloads history")
        try JSONEncoder().encode([UsageHistorySample]()).write(to: file, options: .atomic)
        expect(try JSONDecoder().decode([UsageHistorySample].self, from: Data(contentsOf: file)).isEmpty, "Clearing history persists")
        print("PASS history: retention, sampling, provider separation, unknown data, clamping, disk persistence, and clearing")

        let timeline: [(TimeInterval, Int?)] = [(0, 80), (300, 60), (600, 100), (900, 90),
                                               (3_600, 20), (3_900, nil), (4_200, 10)]
        let readings = timeline.map { offset, remaining in
            UsageHistorySample(provider: "Codex", date: now.addingTimeInterval(offset), session: remaining, weekly: 50)
        }
        let analysis = HistoryAnalysis(samples: readings.reversed(), window: .session)
        expect(analysis.observedDrop == 30, "Drops exclude reset increases, long gaps, and unavailable data")
        expect(analysis.balanceIncreases == 1, "Balance increases are counted independently of drops")
        expect(analysis.latest?.value == 10 && analysis.lowest?.value == 10, "Summary uses the selected window")
        expect(analysis.readings[4].followsGap && analysis.readings[4].change == nil, "A recording gap is explicit")
        expect(analysis.readings[5].segment != analysis.readings[6].segment, "Unknown readings split the chart")
        expect(analysis.nearest(to: now.addingTimeInterval(299))?.value == 60, "Selection resolves to a real observation")
        let weeklyAnalysis = HistoryAnalysis(samples: readings, window: .weekly)
        expect(weeklyAnalysis.observedDrop == 0 && weeklyAnalysis.latest?.value == 50, "Weekly analysis does not use session values")
        let dense = (0..<1_000).map { index in
            UsageHistorySample(provider: "Codex", date: now.addingTimeInterval(Double(index) * 300),
                               session: index == 501 ? 0 : (index == 502 ? 100 : 60), weekly: nil)
        }
        let compressed = HistoryAnalysis(samples: dense, window: .session).chartReadings()
        expect(compressed.contains { $0.value == 0 } && compressed.contains { $0.value == 100 }, "Chart sampling preserves brief depletion and recovery")
        expect(compressed.first?.id == dense.first?.id && compressed.last?.id == dense.last?.id, "Chart sampling preserves the endpoints")
        expect(compressed.count < dense.count, "Dense histories use fewer chart marks")
        let csv = HistoryAnalysis(samples: [UsageHistorySample(provider: "Provider, \"test\"", date: now, session: 50, weekly: nil)], window: .session).csv
        expect(csv.contains("\"Provider, \"\"test\"\"\""), "CSV escapes commas and quotes")
        expect(csv.contains(",50,\r\n"), "CSV leaves unknown balances empty")
        print("PASS analysis: gaps, resets, exact selection, window separation, extrema preservation, and CSV export")
    }

    private static func expect(_ condition: Bool, _ message: String) {
        precondition(condition, message)
    }
}
