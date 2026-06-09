import SwiftUI

/// Settings page showing all data types found in the store,
/// with a toggle per source for each type.
/// Toggles affect Dashboard and Analysis views; the Data tab always shows everything.
struct SourcePreferencesView: View {
    @EnvironmentObject var measurementStore: MeasurementStore
    @EnvironmentObject var sourcePrefs: SourcePreferenceStore
    @EnvironmentObject var coordinator: DeviceCoordinator

    /// A named group of one or more raw source strings that all resolve to the same display name.
    /// Multiple legacy formats for the same device collapse into one toggle.
    private struct SourceGroup: Identifiable {
        let id: String          // display name used as stable ID
        let displayName: String
        let rawSources: [String]
    }

    /// One entry per data type, with sources deduplicated by resolved display name.
    private var catalog: [(dataType: String, label: String, groups: [SourceGroup])] {
        // Query distinct (type, source) pairs from the database
        let pairs = measurementStore.queryDataPoints(
            sql: """
                SELECT DISTINCT type, source FROM data_point
                WHERE source NOT LIKE 'derived:%'
                ORDER BY type
                """
        )
        var byType: [String: Set<String>] = [:]
        for dp in pairs {
            byType[dp.type, default: []].insert(dp.source)
        }
        return byType
            .filter { !$0.value.isEmpty }
            .map { (dataType: $0.key,
                    label: prettyDataType($0.key),
                    groups: groupedSources($0.value)) }
            .sorted { $0.label < $1.label }
    }

    /// Groups raw source strings by resolved display name so that legacy formats
    /// for the same physical device collapse into a single toggle.
    private func groupedSources(_ sources: Set<String>) -> [SourceGroup] {
        var byName: [String: [String]] = [:]
        for source in sources {
            let name = prettySource(source)
            byName[name, default: []].append(source)
        }
        return byName
            .map { SourceGroup(id: $0.key, displayName: $0.key, rawSources: $0.value.sorted()) }
            .sorted { $0.displayName < $1.displayName }
    }

    var body: some View {
        List {
            if catalog.isEmpty {
                Section {
                    Text("No data imported yet. Import HealthKit data from Settings → Data.")
                        .font(.caption)
                        .foregroundColor(.gray)
                        .listRowBackground(Color.appSurface)
                }
            } else {
                Section {
                    Text("Toggle off a source to hide its data in the Dashboard and analysis views. The Data tab always shows all sources.")
                        .font(.caption)
                        .foregroundColor(.gray)
                }
                .listRowBackground(Color.appBackground)

                ForEach(catalog, id: \.dataType) { entry in
                    Section(entry.label) {
                        ForEach(entry.groups) { group in
                            Toggle(group.displayName, isOn: Binding(
                                get: {
                                    group.rawSources.allSatisfy {
                                        sourcePrefs.isEnabled(dataType: entry.dataType, source: $0)
                                    }
                                },
                                set: { enabled in
                                    group.rawSources.forEach {
                                        sourcePrefs.setEnabled(enabled, dataType: entry.dataType, source: $0)
                                    }
                                }
                            ))
                            .tint(.appTeal)
                            .listRowBackground(Color.appSurface)
                        }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.appBackground)
        .navigationTitle("Data Sources")
    }

    // MARK: - Pretty labels

    private func prettyDataType(_ type: String) -> String {
        switch type {
        case DataType.hrvSDNN:          return "HRV (SDNN)"
        case DataType.restingHeartRate: return "Resting Heart Rate"
        case DataType.heartRateSample:  return "Heart Rate"
        case DataType.heartRate:        return "Heart Rate"
        case DataType.bloodOxygen:      return "Blood Oxygen (SpO2)"
        case DataType.bodyTemperature:  return "Body Temperature"
        case DataType.vo2Max:           return "VO2 Max"
        case DataType.steps:            return "Steps"
        case DataType.sleepStage:       return "Sleep"
        case DataType.cadence:          return "Cadence"
        case DataType.workoutType:      return "Workout Type"
        case DataType.workoutDuration:  return "Workout Duration"
        case DataType.workoutDistance:  return "Workout Distance"
        case DataType.workoutAvgHR:     return "Workout Avg HR"
        case DataType.weight:           return "Weight"
        case DataType.bodyFatPercent:   return "Body Fat"
        case DataType.muscleMassKg:     return "Muscle Mass"
        default:
            return type
                .replacingOccurrences(of: "_", with: " ")
                .split(separator: " ")
                .map { $0.prefix(1).uppercased() + $0.dropFirst() }
                .joined(separator: " ")
        }
    }

    /// Resolves a raw source string to a human-readable display name.
    private func prettySource(_ source: String) -> String {
        if source.hasPrefix("hk:") { return String(source.dropFirst(3)) }
        if source.hasPrefix("device:") {
            let uuidStr = String(source.dropFirst(7))
            if let uuid = UUID(uuidString: uuidStr),
               let known = coordinator.registry.knownDevices.first(where: { $0.id == uuid }) {
                return known.displayName
            }
            return "Device \(uuidStr.prefix(8))…"
        }
        // Legacy: raw UUID stored without "device:" prefix
        if let uuid = UUID(uuidString: source) {
            if let known = coordinator.registry.knownDevices.first(where: { $0.id == uuid }) {
                return known.displayName  // same device, no "(old)" needed
            }
            return "Device \(source.prefix(8))…"
        }
        return source
    }
}
