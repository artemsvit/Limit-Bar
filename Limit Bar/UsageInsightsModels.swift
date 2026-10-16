import Foundation

/// Only observed percentages are stored. No account details or session contents.
struct UsageHistorySample: Codable, Identifiable, Equatable {
    let id: UUID
    let provider: String
    let date: Date
    let session: Int?
    let weekly: Int?

    init(provider: String, date: Date, session: Int?, weekly: Int?) {
        id = UUID()
        self.provider = provider
        self.date = date
        self.session = session.map { min(max($0, 0), 100) }
        self.weekly = weekly.map { min(max($0, 0), 100) }
    }
}

enum UsageHistoryPolicy {
    static let retention: TimeInterval = 30 * 86_400
    static let bucket: TimeInterval = 300

    static func recording(_ sample: UsageHistorySample, in samples: [UsageHistorySample]) -> [UsageHistorySample] {
        var kept = samples.filter { $0.date >= sample.date.addingTimeInterval(-retention) && $0.date <= sample.date }
        guard sample.session != nil || sample.weekly != nil else { return kept }
        let slot = floor(sample.date.timeIntervalSince1970 / bucket)
        kept.removeAll { $0.provider == sample.provider && floor($0.date.timeIntervalSince1970 / bucket) == slot }
        kept.append(sample)
        return kept
    }
}

/// One recovery per observed depletion. Unknown windows cannot confirm a recovery.
struct UsageRecoveryState: Codable, Equatable {
    var sessionDepleted = false
    var weeklyDepleted = false

    mutating func observe(session: Int?, weekly: Int?) -> Bool {
        let wasBlocked = sessionDepleted || weeklyDepleted
        if let session {
            if session <= 0 { sessionDepleted = true }
            else if session >= 5 { sessionDepleted = false }
        }
        if let weekly {
            if weekly <= 0 { weeklyDepleted = true }
            else if weekly >= 5 { weeklyDepleted = false }
        }
        return wasBlocked && !sessionDepleted && !weeklyDepleted
    }
}

struct NotificationPreferences: Codable, Equatable {
    var isEnabled: Bool
    var thresholds: [Int]
    // Optional so existing preferences continue to decode.
    var notifyOnRecovery: Bool? = nil

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
