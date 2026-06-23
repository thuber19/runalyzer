import SwiftUI

/// Round types for wellness sessions. Raw values match the DataPoint `unit` strings on the iOS side.
enum WellnessRoundType: String, Codable, CaseIterable, Identifiable, Sendable {
    case finnish
    case bioMild = "bio_mild"
    case steam
    case coldPlunge = "cold_plunge"
    case whirlpool
    case rest

    var id: String { rawValue }

    var label: String {
        switch self {
        case .finnish:    return "Finnish"
        case .bioMild:    return "Bio / Mild"
        case .steam:      return "Steam"
        case .coldPlunge: return "Cold Plunge"
        case .whirlpool:  return "Whirlpool"
        case .rest:       return "Rest"
        }
    }

    var icon: String {
        switch self {
        case .finnish:    return "flame.fill"
        case .bioMild:    return "flame"
        case .steam:      return "cloud.fill"
        case .coldPlunge: return "snowflake"
        case .whirlpool:  return "drop.circle.fill"
        case .rest:       return "pause.circle"
        }
    }

    var color: Color {
        switch self {
        case .finnish:    return .red
        case .bioMild:    return .orange
        case .steam:      return .purple
        case .coldPlunge: return .cyan
        case .whirlpool:  return .blue
        case .rest:       return .gray
        }
    }

    /// Whether this is a heat-type round (vs cold or rest).
    var isHeat: Bool {
        switch self {
        case .finnish, .bioMild, .steam: return true
        default: return false
        }
    }
}
