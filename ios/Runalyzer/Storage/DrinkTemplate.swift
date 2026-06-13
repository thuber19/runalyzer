import Foundation

/// Category of fluid/drink for intake tracking.
enum DrinkCategory: String, Codable, CaseIterable, Sendable {
    case water, coffee, tea, beer, wine, spirit, juice, other

    var label: String {
        switch self {
        case .water:  return "Water"
        case .coffee: return "Coffee"
        case .tea:    return "Tea"
        case .beer:   return "Beer"
        case .wine:   return "Wine"
        case .spirit: return "Spirit"
        case .juice:  return "Juice"
        case .other:  return "Other"
        }
    }

    var icon: String {
        switch self {
        case .water:  return "drop.fill"
        case .coffee: return "cup.and.saucer.fill"
        case .tea:    return "leaf.fill"
        case .beer:   return "mug.fill"
        case .wine:   return "wineglass.fill"
        case .spirit: return "wineglass"
        case .juice:  return "carrot.fill"
        case .other:  return "bubbles.and.sparkles"
        }
    }

    var isAlcoholic: Bool { self == .beer || self == .wine || self == .spirit }
}

/// A drink template for quick fluid logging.
/// Stores default volume, caffeine/alcohol content for one-tap logging.
struct DrinkTemplate: Identifiable, Sendable {
    let id: UUID
    var name: String
    var category: DrinkCategory
    var defaultVolumeMl: Int
    var caffeineContentMg: Int
    var alcoholPercent: Double
    var icon: String
    var isFavorite: Bool
    var isCustom: Bool
    var sortOrder: Int

    /// Estimated standard alcohol units (10g pure alcohol = 1 unit).
    var standardDrinks: Double {
        guard alcoholPercent > 0 else { return 0 }
        return Double(defaultVolumeMl) * (alcoholPercent / 100.0) * 0.789 / 10.0
    }
}
