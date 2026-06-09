import Foundation
import Combine

/// Persists per-source enable/disable preferences for each data type.
/// Default: all sources are enabled (returns true for keys never explicitly set).
/// Inject as @EnvironmentObject — call objectWillChange.send() after mutations
/// so SwiftUI views re-render.
class SourcePreferenceStore: ObservableObject {
    private let defaults = UserDefaults.standard
    private static let keyPrefix = "srcpref::"

    private static func key(dataType: String, source: String) -> String {
        "\(keyPrefix)\(dataType)::\(source)"
    }

    func isEnabled(dataType: String, source: String) -> Bool {
        let key = Self.key(dataType: dataType, source: source)
        guard defaults.object(forKey: key) != nil else { return true }
        return defaults.bool(forKey: key)
    }

    func setEnabled(_ enabled: Bool, dataType: String, source: String) {
        defaults.set(enabled, forKey: Self.key(dataType: dataType, source: source))
        objectWillChange.send()
    }

    /// Filters a list of DataPoints to only those from enabled sources.
    func apply(to points: [DataPoint], dataType: String) -> [DataPoint] {
        points.filter { isEnabled(dataType: dataType, source: $0.source) }
    }
}
