import Foundation

/// A complete sauna visit consisting of multiple rounds.
struct SaunaSession: Codable, Identifiable {
    let id: UUID
    let date: Date
    var rounds: [SaunaRound]
    var synced: Bool

    var totalDurationSec: TimeInterval {
        rounds.reduce(0) { $0 + $1.durationSec }
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
