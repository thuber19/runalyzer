import Foundation

/// A complete sauna visit consisting of multiple rounds.
struct SaunaSession: Codable, Identifiable {
    let id: UUID
    let date: Date
    var rounds: [SaunaRound]
    var synced: Bool

    var totalRoundDurationSec: TimeInterval {
        rounds.reduce(0) { $0 + $1.durationSec }
    }

    /// Rest periods between consecutive rounds (time from round N end to round N+1 start).
    var restPeriods: [(duration: TimeInterval, after: Int)] {
        var periods: [(TimeInterval, Int)] = []
        for i in 1..<rounds.count {
            let prevEnd = rounds[i - 1].endDate ?? rounds[i].startDate
            let gap = rounds[i].startDate.timeIntervalSince(prevEnd)
            if gap > 0 {
                periods.append((gap, i - 1))
            }
        }
        return periods
    }

    var totalRestDurationSec: TimeInterval {
        restPeriods.reduce(0) { $0 + $1.duration }
    }

    var totalDurationSec: TimeInterval {
        totalRoundDurationSec + totalRestDurationSec
    }

    var activeRound: SaunaRound? {
        rounds.last(where: { $0.isActive })
    }

    var isActive: Bool {
        activeRound != nil
    }

    init() {
        self.id = UUID()
        self.date = Date()
        self.rounds = []
        self.synced = false
    }

    mutating func startRound(type: SaunaRoundType) {
        rounds.append(SaunaRound(type: type))
    }

    mutating func stopCurrentRound() {
        guard let index = rounds.lastIndex(where: { $0.isActive }) else { return }
        rounds[index].endDate = Date()
    }
}
