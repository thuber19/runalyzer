import SwiftUI

/// Universal detail view for any measurement type
struct MeasurementDetailView: View {
    let measurement: SensorMeasurement
    @EnvironmentObject var measurementStore: MeasurementStore

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                sourceInfo
                dataPointsView

                if measurement.type == .workout {
                    workoutExtras
                }
                if measurement.type == .derived {
                    provenanceView
                }
            }
            .padding()
        }
        .background(Color(hex: 0x1a1a2e))
        .navigationTitle(measurement.dateString)
    }

    // MARK: - Source Info

    private var sourceInfo: some View {
        VStack(spacing: 8) {
            Text("SOURCE").font(.caption2).foregroundColor(.gray)
            ForEach(measurement.sources) { source in
                HStack {
                    Image(systemName: source.deviceType == "algorithm" ? "function" : "antenna.radiowaves.left.and.right")
                        .foregroundColor(.cyan)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(source.deviceName).font(.subheadline)
                        if let serial = source.serialNumber {
                            Text("SN: \(serial)").font(.caption2).foregroundColor(.gray)
                        }
                        if let algo = source.algorithmName {
                            Text("Algorithm: \(algo)").font(.caption2).foregroundColor(.gray)
                        }
                    }
                    Spacer()
                }
            }
        }
        .padding()
        .background(Color(hex: 0x16213e))
        .cornerRadius(12)
    }

    // MARK: - Data Points

    private var dataPointsView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("DATA").font(.caption2).foregroundColor(.gray)

            // Group by type for cleaner display
            let grouped = Dictionary(grouping: measurement.dataPoints) { $0.type }
            let sortedKeys = grouped.keys.sorted()

            ForEach(sortedKeys, id: \.self) { key in
                let points = grouped[key]!

                if points.count == 1, let p = points.first {
                    // Single value — show inline
                    dataRow(label: displayName(for: p.type), value: formatValue(p), unit: p.unit, source: shortSource(p.source))
                } else {
                    // Multiple values (time series) — show summary
                    let values = points.map(\.value)
                    let avg = values.reduce(0, +) / Double(values.count)
                    let min = values.min() ?? 0
                    let max = values.max() ?? 0
                    VStack(alignment: .leading, spacing: 2) {
                        Text(displayName(for: key)).font(.subheadline).foregroundColor(.white)
                        HStack(spacing: 16) {
                            VStack {
                                Text(String(format: "%.1f", avg)).font(.headline.monospacedDigit())
                                Text("Avg").font(.caption2).foregroundColor(.gray)
                            }
                            VStack {
                                Text(String(format: "%.1f", min)).font(.headline.monospacedDigit())
                                Text("Min").font(.caption2).foregroundColor(.gray)
                            }
                            VStack {
                                Text(String(format: "%.1f", max)).font(.headline.monospacedDigit())
                                Text("Max").font(.caption2).foregroundColor(.gray)
                            }
                            Spacer()
                            Text("\(points.count) points")
                                .font(.caption2).foregroundColor(.gray)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .padding()
        .background(Color(hex: 0x16213e))
        .cornerRadius(12)
    }

    private func dataRow(label: String, value: String, unit: String, source: String) -> some View {
        HStack {
            Text(label).font(.subheadline).foregroundColor(.gray)
            Spacer()
            Text(value).font(.subheadline.monospacedDigit())
            Text(unit).font(.caption2).foregroundColor(.gray)
            if !source.isEmpty {
                Text("· \(source)").font(.caption2).foregroundColor(.cyan)
            }
        }
    }

    // MARK: - Workout Extras

    private var workoutExtras: some View {
        VStack(spacing: 8) {
            let samples = measurementStore.loadIMUSamples(for: measurement)
            if !samples.isEmpty {
                Text("RAW IMU DATA").font(.caption2).foregroundColor(.gray)
                Text("\(samples.count) samples available")
                    .font(.caption).foregroundColor(.gray)
            }
        }
        .padding()
        .background(Color(hex: 0x16213e))
        .cornerRadius(12)
    }

    // MARK: - Derived Provenance

    private var provenanceView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ALGORITHM").font(.caption2).foregroundColor(.gray)
            ForEach(measurement.sources) { source in
                HStack(spacing: 8) {
                    Image(systemName: iconForSource(source))
                        .foregroundColor(colorForSource(source))
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(source.deviceName).font(.subheadline)
                        if let algo = source.algorithmName {
                            Text(algo).font(.caption2).foregroundColor(.gray)
                        } else if let serial = source.serialNumber {
                            Text(readableSerial(serial)).font(.caption2).foregroundColor(.gray)
                        }
                    }
                    Spacer()
                }
            }
            if let inputs = measurement.inputMeasurements, !inputs.isEmpty {
                Divider().background(Color.gray.opacity(0.3))
                Text("INPUT MEASUREMENTS").font(.caption2).foregroundColor(.gray)
                ForEach(inputs, id: \.self) { id in
                    if let m = measurementStore.measurement(byID: id) {
                        NavigationLink(destination: MeasurementDetailView(measurement: m)) {
                            HStack {
                                Image(systemName: m.icon).foregroundColor(.cyan).frame(width: 20)
                                Text(m.dateString).font(.caption)
                                Spacer()
                                Image(systemName: "chevron.right").foregroundColor(.gray).font(.caption2)
                            }
                        }
                    }
                }
            }
        }
        .padding()
        .background(Color(hex: 0x16213e))
        .cornerRadius(12)
    }

    private func iconForSource(_ source: MeasurementSource) -> String {
        switch source.deviceType {
        case "apple_watch": return "applewatch"
        case "imu_sensor":  return "waveform.path.ecg"
        case "algorithm":   return "function"
        default:            return "antenna.radiowaves.left.and.right"
        }
    }

    private func colorForSource(_ source: MeasurementSource) -> Color {
        switch source.deviceType {
        case "apple_watch": return .pink
        case "imu_sensor":  return Color(hex: 0x4ecca3)
        case "algorithm":   return Color(hex: 0x5dadec)
        default:            return .gray
        }
    }

    private func readableSerial(_ serial: String) -> String {
        if serial.hasPrefix("hk:") { return "HealthKit · \(serial.dropFirst(3).prefix(8))…" }
        if serial.hasPrefix("device:") { return "Session · \(serial.dropFirst(7).prefix(8))…" }
        return serial
    }

    // MARK: - Helpers

    private func displayName(for type: String) -> String {
        switch type {
        case DataType.weight: return "Weight"
        case DataType.impedance: return "Impedance"
        case DataType.bmi: return "BMI"
        case DataType.bodyFatPercent: return "Body Fat"
        case DataType.fatMassKg: return "Fat Mass"
        case DataType.fatFreeMassKg: return "Fat-Free Mass"
        case DataType.muscleMassKg: return "Muscle Mass"
        case DataType.musclePercent: return "Muscle %"
        case DataType.bodyWaterPercent: return "Body Water"
        case DataType.bmrKcal: return "BMR"
        case DataType.heartRate: return "Heart Rate"
        case DataType.cadence: return "Cadence"
        case DataType.totalSteps: return "Total Steps"
        case DataType.avgCadence: return "Avg Cadence"
        case DataType.peakG: return "Peak Acceleration"
        case DataType.durationSec: return "Duration"
        case DataType.distance: return "Distance"
        case DataType.activeCalories: return "Active Calories"
        case DataType.pace: return "Pace"
        case DataType.stepLength: return "Step Length"
        case DataType.runningEconomy: return "Running Economy"
        case DataType.aerobicLoad: return "Aerobic Load"
        default: return type.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    private func formatValue(_ p: DataPoint) -> String {
        switch p.type {
        case DataType.durationSec:
            let m = Int(p.value) / 60, s = Int(p.value) % 60
            return String(format: "%d:%02d", m, s)
        case DataType.pace:
            // value is min/km — display as m:ss
            let m = Int(p.value), s = Int((p.value - Double(m)) * 60)
            return String(format: "%d:%02d", m, s)
        case DataType.stepLength:
            return String(format: "%.3f", p.value)
        default:
            return String(format: "%.2f", p.value)
        }
    }

    private func shortSource(_ source: String) -> String {
        if source.hasPrefix("derived:") { return String(source.dropFirst(8)) }
        if source.hasPrefix("hk:")      { return "Watch" }
        if source.hasPrefix("device:")  { return "IMU" }
        return ""
    }
}
