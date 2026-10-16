import Foundation

enum HistoryLimitWindow: String, CaseIterable, Identifiable {
    case session = "Session"
    case weekly = "Weekly"
    var id: String { rawValue }
    func value(in sample: UsageHistorySample) -> Int? {
        self == .session ? sample.session : sample.weekly
    }
}

struct HistoryReading: Identifiable {
    let sample: UsageHistorySample
    let value: Int?
    /// A change is meaningful only between nearby, known observations.
    let change: Int?
    let followsGap: Bool
    let segment: Int
    var id: UUID { sample.id }
}

struct HistoryAnalysis {
    static let maximumGap: TimeInterval = 1_800
    let readings: [HistoryReading]

    init(samples: [UsageHistorySample], window: HistoryLimitWindow) {
        let ordered = samples.sorted { $0.date < $1.date }
        var previous: UsageHistorySample?
        var segment = 0
        var result: [HistoryReading] = []
        for sample in ordered {
            let value = window.value(in: sample)
            let gap = previous.map { sample.date.timeIntervalSince($0.date) > Self.maximumGap } ?? false
            let previousValue = previous.flatMap { window.value(in: $0) }
            if gap || value == nil || previousValue == nil { segment += 1 }
            let change: Int? = !gap ? value.flatMap { current in previousValue.map { current - $0 } } : nil
            result.append(HistoryReading(sample: sample, value: value, change: change, followsGap: gap, segment: segment))
            previous = sample
        }
        readings = result
    }

    var latest: HistoryReading? { readings.last { $0.value != nil } }
    var lowest: HistoryReading? {
        readings.filter { $0.value != nil }.min { ($0.value ?? 100) < ($1.value ?? 100) }
    }
    var observedDrop: Int {
        readings.compactMap(\.change).filter { $0 < 0 }.reduce(0) { $0 - $1 }
    }
    var comparableIntervals: Int { readings.filter { $0.change != nil }.count }
    var balanceIncreases: Int { readings.filter { ($0.change ?? 0) > 0 }.count }

    func nearest(to date: Date?) -> HistoryReading? {
        guard let date else { return readings.last }
        return readings.min { abs($0.sample.date.timeIntervalSince(date)) < abs($1.sample.date.timeIntervalSince(date)) }
    }

    /// Preserve first/last readings and the extrema in each bucket, including brief
    /// depletion and recovery. Never merge disconnected recording periods.
    func chartReadings() -> [HistoryReading] {
        let valid = readings.filter { $0.value != nil }
        guard valid.count > 600, let first = valid.first, let last = valid.last else { return valid }
        let interval = max(300, last.sample.date.timeIntervalSince(first.sample.date) / 240)
        var result: [HistoryReading] = []
        var bucket: [HistoryReading] = []
        var previousSlot: Double?
        var previousSegment: Int?
        func flush() {
            let candidates = [bucket.first, bucket.min { ($0.value ?? 100) < ($1.value ?? 100) },
                              bucket.max { ($0.value ?? 0) < ($1.value ?? 0) }, bucket.last].compactMap { $0 }
            var seen = Set<UUID>()
            result += candidates.filter { seen.insert($0.id).inserted }.sorted { $0.sample.date < $1.sample.date }
            bucket.removeAll(keepingCapacity: true)
        }
        for reading in valid {
            let slot = floor(reading.sample.date.timeIntervalSince1970 / interval)
            if slot != previousSlot || reading.segment != previousSegment { flush() }
            bucket.append(reading)
            previousSlot = slot
            previousSegment = reading.segment
        }
        flush()
        return result
    }

    var csv: String {
        let formatter = ISO8601DateFormatter()
        func field(_ value: String) -> String { "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        let header = "provider,recorded_at,session_remaining_percent,weekly_remaining_percent"
        let lines = readings.map { reading in
            let sample = reading.sample
            return [field(sample.provider), formatter.string(from: sample.date), sample.session.map(String.init) ?? "",
                    sample.weekly.map(String.init) ?? ""].joined(separator: ",")
        }
        return ([header] + lines).joined(separator: "\r\n") + "\r\n"
    }
}
