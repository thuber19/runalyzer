import SwiftUI

/// Universal detail view for any measurement type.
/// Structure: type-specific summary → expandable data points → expandable raw JSON.
struct MeasurementDetailView: View {
    let measurement: SensorMeasurement
    @EnvironmentObject var measurementStore: MeasurementStore
    @EnvironmentObject var profileProvider: UserProfileProvider
    @State private var loadedDataPoints: [DataPoint]?

    /// DataPoints loaded on demand from SQLite.
    private var dataPoints: [DataPoint] {
        loadedDataPoints ?? []
    }

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Type-specific summary
                summarySection

                // Always: expandable data points list
                dataPointsList

                // Always: expandable raw JSON
                rawDataSection
            }
            .padding()
        }
        .background(Color(hex: 0x1a1a2e))
        .navigationTitle(measurement.dateString)
        .onAppear {
            if loadedDataPoints == nil {
                loadedDataPoints = measurementStore.dataPoints(for: measurement.id)
            }
        }
    }

    // MARK: - Type-Specific Summary

    @ViewBuilder
    private var summarySection: some View {
        switch measurement.type {
        case .metric:       metricSummary
        case .bodyComp:     bodyCompSummary
        case .derived:      derivedSummary
        case .labResults:   labResultsSummary
        default:            EmptyView()
        }
    }

    // MARK: - Metric Summary (HR, HRV, RHR, SpO2, steps, sleep, etc.)

    private var metricSummary: some View {
        VStack(spacing: 12) {
            // Detect which metric type this is
            let sleepPoints = dataPoints.filter { $0.type == DataType.sleepStage }

            if !sleepPoints.isEmpty {
                sleepSummaryView(sleepPoints)
            } else {
                // Generic metric: show stats per type
                let grouped = Dictionary(grouping: dataPoints) { $0.type }
                ForEach(grouped.keys.sorted(), id: \.self) { key in
                    let pts = grouped[key] ?? []
                    metricStatCard(type: key, points: pts)
                }
            }

            sourceRow
        }
        .padding()
        .background(Color(hex: 0x16213e))
        .cornerRadius(12)
    }

    private func metricStatCard(type: String, points: [DataPoint]) -> some View {
        let values = points.map(\.value)
        let showStats = [DataType.heartRateSample, DataType.hrvSDNN, DataType.restingHeartRate,
                         DataType.cadence, DataType.bloodOxygen].contains(type)

        return VStack(alignment: .leading, spacing: 4) {
            Text(DataType.displayName( type).uppercased()).font(.caption2).foregroundColor(.gray)
            if points.count == 1, let p = points.first {
                HStack {
                    Text(formatValue(p)).font(.title2.bold().monospacedDigit())
                    Text(p.unit).font(.caption).foregroundColor(.gray)
                }
            } else if showStats && !values.isEmpty {
                HStack(spacing: 20) {
                    statColumn(String(format: "%.0f", values.reduce(0, +) / Double(values.count)), label: "Avg")
                    statColumn(String(format: "%.0f", values.min() ?? 0), label: "Min")
                    statColumn(String(format: "%.0f", values.max() ?? 0), label: "Max")
                    Spacer()
                    Text("\(points.count)").font(.caption).foregroundColor(.gray)
                    Text(points.first?.unit ?? "").font(.caption2).foregroundColor(.gray)
                }
            } else {
                Text("\(points.count) data points").font(.caption).foregroundColor(.gray)
            }
        }
    }

    // MARK: - Sleep Summary

    private func sleepSummaryView(_ sleepPoints: [DataPoint]) -> some View {
        let summary = SleepScore.stageSummary(from: sleepPoints)

        return VStack(alignment: .leading, spacing: 8) {
            Text("SLEEP").font(.caption2).foregroundColor(.gray)

            HStack(spacing: 20) {
                VStack {
                    Text(formatMinutes(summary.asleepMinutes)).font(.title2.bold().monospacedDigit())
                    Text("Asleep").font(.caption2).foregroundColor(.gray)
                }
                VStack {
                    Text(formatMinutes(summary.deepMinutes)).font(.title2.bold().monospacedDigit())
                    Text("Deep").font(.caption2).foregroundColor(.indigo)
                }
                VStack {
                    Text(formatMinutes(summary.remMinutes)).font(.title2.bold().monospacedDigit())
                    Text("REM").font(.caption2).foregroundColor(.cyan)
                }
            }

            Divider().background(Color.gray.opacity(0.3))
            Text("TIME PER STAGE").font(.caption2).foregroundColor(.gray)

            ForEach(summary.stageBreakdown, id: \.name) { item in
                HStack {
                    Circle().fill(sleepStageColor(item.name)).frame(width: 10, height: 10)
                    Text(item.name).font(.caption)
                    Spacer()
                    Text(formatMinutes(item.minutes)).font(.caption.monospacedDigit())
                }
            }
        }
    }

    private func sleepStageColor(_ stage: String) -> Color {
        switch stage {
        case "Deep": return .indigo
        case "Core": return .blue
        case "REM":  return .cyan
        case "Awake": return .orange
        case "InBed": return .gray
        default:      return .purple
        }
    }

    // MARK: - Lab Results Summary

    private var labResultsSummary: some View {
        LabResultsDetailSection(dataPoints: dataPoints, sourceLabel: measurement.sourceLabel)
            .padding()
            .background(Color(hex: 0x16213e))
            .cornerRadius(12)
    }

    // MARK: - HK Workout Summary

    private var workoutSummary: some View {
        VStack(alignment: .leading, spacing: 12) {
            WorkoutDetailSection(dataPoints: dataPoints)
            sourceRow
        }
        .padding()
        .background(Color(hex: 0x16213e))
        .cornerRadius(12)
    }

    // MARK: - IMU Workout Summary

    private var imuWorkoutSummary: some View {
        let dp = dataPoints
        return VStack(spacing: 8) {
            Text("IMU WORKOUT").font(.caption2).foregroundColor(.gray)
            HStack(spacing: 20) {
                if let dur = dp.first(where: { $0.type == DataType.durationSec }) {
                    statColumn(formatValue(dur), label: "Duration")
                }
                if let steps = dp.first(where: { $0.type == DataType.totalSteps }) {
                    statColumn(formatValue(steps), label: "Steps")
                }
                if let cad = dp.first(where: { $0.type == DataType.avgCadence }) {
                    statColumn(formatValue(cad), label: "Cadence")
                }
                if let g = dp.first(where: { $0.type == DataType.peakG }) {
                    statColumn(formatValue(g), label: "Peak g")
                }
            }
            sourceRow
        }
        .padding()
        .background(Color(hex: 0x16213e))
        .cornerRadius(12)
    }

    // MARK: - Body Comp Summary

    private var bodyCompSummary: some View {
        BodyCompDetailSection(dataPoints: dataPoints, sourceLabel: measurement.sourceLabel)
            .padding()
            .background(Color(hex: 0x16213e))
            .cornerRadius(12)
    }

    // MARK: - Derived Summary (Recovery, Enrichment)

    private var derivedSummary: some View {
        let dp = dataPoints
        let primary = dp.filter { $0.role == .primary }
        let detail = dp.filter { $0.role == .detail }

        return VStack(alignment: .leading, spacing: 8) {
            Text("DERIVED").font(.caption2).foregroundColor(.gray)
            ForEach(primary) { p in
                dataRow(label: DataType.displayName(p.type), value: formatValue(p), unit: p.unit, source: "")
            }
            if !detail.isEmpty {
                DisclosureGroup {
                    ForEach(detail) { p in
                        dataRow(label: DataType.displayName(p.type), value: formatValue(p), unit: p.unit, source: "")
                    }
                } label: {
                    Text("DETAILS").font(.caption2).foregroundColor(.gray)
                }
                .tint(.gray)
            }
            sourceRow
        }
        .padding()
        .background(Color(hex: 0x16213e))
        .cornerRadius(12)
    }

    // MARK: - Expandable Data Points List

    @State private var showAllDataPoints = false

    private var dataPointsList: some View {
        VStack(alignment: .leading, spacing: 0) {
            DisclosureGroup {
                let sorted = dataPoints.sorted { $0.timestamp < $1.timestamp }
                let limit = showAllDataPoints ? sorted.count : min(100, sorted.count)
                let visible = Array(sorted.prefix(limit))
                ForEach(Array(visible.enumerated()), id: \.offset) { _, dp in
                    HStack(spacing: 6) {
                        Text(Self.timeFmt.string(from: dp.timestamp))
                            .font(.system(size: 10, design: .monospaced)).foregroundColor(.gray)
                            .frame(width: 55, alignment: .leading)
                        Text(DataType.displayName( dp.type))
                            .font(.system(size: 10)).foregroundColor(.cyan)
                            .lineLimit(1)
                        Spacer()
                        Text(formatValue(dp))
                            .font(.system(size: 10, design: .monospaced))
                        Text(dp.unit)
                            .font(.system(size: 9)).foregroundColor(.gray)
                            .frame(width: 30, alignment: .leading)
                    }
                    .padding(.vertical, 2)
                }
                if sorted.count > limit {
                    Button("Show all \(sorted.count) data points") {
                        showAllDataPoints = true
                    }
                    .font(.caption).foregroundColor(.cyan).padding(.top, 4)
                }
            } label: {
                HStack {
                    Text("DATA POINTS").font(.caption2).foregroundColor(.gray)
                    Spacer()
                    Text("\(dataPoints.count)").font(.caption2).foregroundColor(.gray)
                }
            }
            .tint(.gray)
        }
        .padding()
        .background(Color(hex: 0x16213e))
        .cornerRadius(12)
    }

    // MARK: - Raw JSON

    @State private var showRawJSON = false

    private var rawDataSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: { withAnimation { showRawJSON.toggle() } }) {
                HStack {
                    Text("RAW DATA").font(.caption2).foregroundColor(.gray)
                    Spacer()
                    Image(systemName: showRawJSON ? "chevron.up" : "chevron.down")
                        .foregroundColor(.gray).font(.caption2)
                }
            }
            .buttonStyle(.plain)

            if showRawJSON {
                ScrollView([.horizontal, .vertical], showsIndicators: true) {
                    Text(rawJSON)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.green.opacity(0.8))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: true, vertical: true)
                }
                .frame(maxHeight: 500)

                if !showFullRawJSON && dataPoints.count > 100 {
                    Button("Show full JSON (\(dataPoints.count) data points)") {
                        showFullRawJSON = true
                    }
                    .font(.caption).foregroundColor(.cyan)
                }
            }
        }
        .padding()
        .background(Color(hex: 0x16213e))
        .cornerRadius(12)
    }

    @State private var showFullRawJSON = false

    private var rawJSON: String {
        let maxPoints = showFullRawJSON ? dataPoints.count : 100
        var limited = measurement
        let truncated = limited.dataPoints.count > maxPoints
        if truncated {
            limited.dataPoints = Array(limited.dataPoints.prefix(maxPoints))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(limited),
              let json = String(data: data, encoding: .utf8) else {
            return "{ \"error\": \"encoding failed\" }"
        }
        if truncated {
            return json + "\n\n... \(dataPoints.count - maxPoints) more data points truncated\nTap 'Show Full' below"
        }
        return json
    }

    // MARK: - Shared Components

    private var sourceRow: some View {
        HStack(spacing: 4) {
            Image(systemName: "antenna.radiowaves.left.and.right").font(.caption2)
            Text(measurement.sourceLabel).font(.caption2)
        }
        .foregroundColor(.gray)
    }

    private func statColumn(_ value: String, label: String) -> some View {
        VStack {
            Text(value).font(.title3.bold().monospacedDigit())
            Text(label).font(.caption2).foregroundColor(.gray)
        }
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

    private func formatMinutes(_ m: Double) -> String {
        let h = Int(m) / 60, min = Int(m) % 60
        return h > 0 ? String(format: "%dh %02dm", h, min) : String(format: "%dm", min)
    }

    /// Format seconds as m:ss or h:mm:ss
    private func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    // MARK: - Display Helpers

    private func formatValue(_ p: DataPoint) -> String {
        switch p.type {
        case DataType.durationSec, DataType.workoutDuration:
            let m = Int(p.value) / 60, s = Int(p.value) % 60
            return String(format: "%d:%02d", m, s)
        case DataType.pace:
            let m = Int(p.value), s = Int((p.value - Double(m)) * 60)
            return String(format: "%d:%02d", m, s)
        case DataType.workoutType:
            return p.unit
        case DataType.recoveryIndex, DataType.recoveryHRVComponent, DataType.recoveryRHRComponent:
            return String(Int(p.value.rounded()))
        case DataType.recoveryConfidence:
            return String(format: "%.0f%%", p.value * 100)
        case DataType.bloodOxygen:
            return String(format: "%.0f%%", p.value * 100)
        case DataType.sleepStage:
            return p.unit  // stage name
        default:
            return String(format: "%.2f", p.value)
        }
    }
}
