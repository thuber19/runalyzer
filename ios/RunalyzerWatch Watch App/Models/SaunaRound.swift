import Foundation

/// A single round within a sauna session (e.g. one 10-minute Finnish sauna stint).
struct SaunaRound: Codable, Identifiable {
    let id: UUID
    let type: SaunaRoundType
    let startDate: Date
    var endDate: Date?

    var isActive: Bool { endDate == nil }

    var durationSec: TimeInterval {
        let end = endDate ?? Date()
        return end.timeIntervalSince(startDate)
    }

    init(type: SaunaRoundType) {
        self.id = UUID()
        self.type = type
        self.startDate = Date()
        self.endDate = nil
    }
}
