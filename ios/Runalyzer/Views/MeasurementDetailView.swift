import SwiftUI
import Charts

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
            Text(displayName(for: type).uppercased()).font(.caption2).foregroundColor(.gray)
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
        // Prefer Watch staged data (Core/REM/Deep) over generic iPhone data (Asleep/InBed)
        // If Watch stages exist, only count Watch source data to avoid double-counting
        let hasStages = sleepPoints.contains { ["Core", "Deep", "REM"].contains($0.unit) }
        let filtered: [DataPoint]
        if hasStages {
            // Use only staged sources (Watch) + Awake from any source
            let stagedSources = Set(sleepPoints.filter { ["Core", "Deep", "REM"].contains($0.unit) }
                .map { $0.source })
            filtered = sleepPoints.filter { stagedSources.contains($0.source) || $0.unit == "Awake" }
        } else {
            filtered = sleepPoints
        }

        let stages = filtered.compactMap { p -> (stage: String, minutes: Double)? in
            guard let end = p.endTimestamp else { return nil }
            return (stage: p.unit, minutes: end.timeIntervalSince(p.timestamp) / 60)
        }

        let stageNames = ["Deep", "Core", "REM", "Awake", "InBed", "Asleep"]
        let stageMinutes: [(String, Double)] = stageNames.compactMap { name in
            let mins = stages.filter { $0.stage == name }.reduce(0) { $0 + $1.minutes }
            return mins > 0 ? (name, mins) : nil
        }

        let sleepMin = stages.filter { ["Deep", "Core", "REM", "Asleep"].contains($0.stage) }
            .reduce(0) { $0 + $1.minutes }
        let deepMin = stages.filter { $0.stage == "Deep" }.reduce(0) { $0 + $1.minutes }
        let remMin = stages.filter { $0.stage == "REM" }.reduce(0) { $0 + $1.minutes }

        return VStack(alignment: .leading, spacing: 8) {
            Text("SLEEP").font(.caption2).foregroundColor(.gray)

            HStack(spacing: 20) {
                VStack {
                    Text(formatMinutes(sleepMin)).font(.title2.bold().monospacedDigit())
                    Text("Asleep").font(.caption2).foregroundColor(.gray)
                }
                VStack {
                    Text(formatMinutes(deepMin)).font(.title2.bold().monospacedDigit())
                    Text("Deep").font(.caption2).foregroundColor(.indigo)
                }
                VStack {
                    Text(formatMinutes(remMin)).font(.title2.bold().monospacedDigit())
                    Text("REM").font(.caption2).foregroundColor(.cyan)
                }
            }

            Divider().background(Color.gray.opacity(0.3))
            Text("TIME PER STAGE").font(.caption2).foregroundColor(.gray)

            ForEach(stageMinutes, id: \.0) { (name, mins) in
                HStack {
                    Circle().fill(sleepStageColor(name)).frame(width: 10, height: 10)
                    Text(name).font(.caption)
                    Spacer()
                    Text(formatMinutes(mins)).font(.caption.monospacedDigit())
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

    // MARK: - HK Workout Summary

    private var workoutSummary: some View {
        let dp = dataPoints
        let activityName = dp.first(where: { $0.type == DataType.workoutType })?.unit ?? "Workout"
        let duration = dp.first(where: { $0.type == DataType.workoutDuration })?.value ?? 0
        let distance = dp.first(where: { $0.type == DataType.workoutDistance })?.value
        let calories = dp.first(where: { $0.type == DataType.workoutCalories })?.value
        let avgHR = dp.first(where: { $0.type == DataType.workoutAvgHR })?.value
        let maxHR = dp.first(where: { $0.type == DataType.workoutMaxHR })?.value
        let hrSamples = dp.filter { $0.type == DataType.heartRateSample }

        return VStack(alignment: .leading, spacing: 12) {
            // Activity + Duration
            HStack {
                Text(activityName).font(.title2.bold())
                Spacer()
                Text(formatDuration(duration)).font(.title2.bold().monospacedDigit())
            }

            // Key metrics — only show distance for distance-based activities
            let distanceActivities = Set(["Run", "Walk", "Cycle", "Hike", "Swim", "Rowing", "Elliptical", "Skating", "Cross Training"])
            HStack(spacing: 16) {
                if let d = distance, d > 0.1, distanceActivities.contains(activityName) {
                    VStack {
                        Text(String(format: "%.2f", d)).font(.headline.monospacedDigit())
                        Text("km").font(.caption2).foregroundColor(.gray)
                    }
                }
                if let c = calories, c > 0 {
                    VStack {
                        Text(String(format: "%.0f", c)).font(.headline.monospacedDigit())
                        Text("kcal").font(.caption2).foregroundColor(.gray)
                    }
                }
                if let avg = avgHR, avg > 0 {
                    VStack {
                        Text(String(format: "%.0f", avg)).font(.headline.monospacedDigit())
                        Text("avg bpm").font(.caption2).foregroundColor(.gray)
                    }
                }
                if let max = maxHR, max > 0 {
                    VStack {
                        Text(String(format: "%.0f", max)).font(.headline.monospacedDigit())
                        Text("max bpm").font(.caption2).foregroundColor(.gray)
                    }
                }
            }

            // HR Zone breakdown
            if !hrSamples.isEmpty {
                Divider().background(Color.gray.opacity(0.3))
                hrZoneBreakdown(hrSamples)

                // HR over time chart
                Divider().background(Color.gray.opacity(0.3))
                workoutHRChart(hrSamples)

                // Interval table (5-min averages)
                Divider().background(Color.gray.opacity(0.3))
                workoutIntervalTable(hrSamples, duration: duration)
            }

            sourceRow
        }
        .padding()
        .background(Color(hex: 0x16213e))
        .cornerRadius(12)
    }

    private func hrZoneBreakdown(_ hrSamples: [DataPoint]) -> some View {
        let profile = profileProvider.profile
        let profileZones = profile.hrZones
        let colors: [Color] = [.gray, .blue, .green, .orange, .red]

        // Build ranges from zone boundaries (Zone 1 starts at 50% of max HR)
        let lowerBounds = profile.hrZoneLowerBounds
        var ranges: [(String, ClosedRange<Double>, Color)] = []
        for (i, zone) in profileZones.enumerated() {
            let lower = Double(lowerBounds[i])
            let upper = Double(zone.maxBPM)
            ranges.append((zone.name, lower...upper, colors[min(i, colors.count - 1)]))
        }

        // Calculate time per zone using actual intervals between consecutive samples
        let sortedHR = hrSamples.sorted { $0.timestamp < $1.timestamp }
        var zoneSeconds: [Int: Double] = [:]  // zone index → seconds

        for i in 0..<sortedHR.count {
            let hr = sortedHR[i].value
            // Each sample represents time until the next sample (or avg interval for the last)
            let interval: Double
            if i < sortedHR.count - 1 {
                interval = sortedHR[i + 1].timestamp.timeIntervalSince(sortedHR[i].timestamp)
            } else if sortedHR.count > 1 {
                // Last sample: use average interval
                let total = sortedHR.last!.timestamp.timeIntervalSince(sortedHR.first!.timestamp)
                interval = total / Double(sortedHR.count - 1)
            } else {
                interval = 0
            }
            // Find which zone this HR falls into
            for (j, (_, range, _)) in ranges.enumerated() {
                if range.contains(hr) {
                    zoneSeconds[j, default: 0] += interval
                    break
                }
            }
        }

        let totalDurationSec = zoneSeconds.values.reduce(0, +)
        let zoneTimes: [(String, Double, Color)] = ranges.enumerated().map { (i, zone) in
            (zone.0, zoneSeconds[i] ?? 0, zone.2)
        }

        return VStack(alignment: .leading, spacing: 4) {
            Text("HR ZONES").font(.caption2).foregroundColor(.gray)
            ForEach(zoneTimes, id: \.0) { (name, seconds, color) in
                let pct = totalDurationSec > 0 ? seconds / totalDurationSec : 0
                HStack(spacing: 8) {
                    Text(name).font(.caption).frame(width: 50, alignment: .leading)
                    GeometryReader { geo in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(color)
                            .frame(width: geo.size.width * pct)
                    }
                    .frame(height: 14)
                    Text(formatDuration(seconds))
                        .font(.caption2.monospacedDigit()).foregroundColor(.gray)
                        .frame(width: 45, alignment: .trailing)
                }
            }
            Text("Max HR: \(profile.maxHR) bpm · Settings → Body Profile to customize zones")
                .font(.system(size: 9)).foregroundColor(.gray)
        }
    }

    // MARK: - Workout HR Chart

    private func workoutHRChart(_ hrSamples: [DataPoint]) -> some View {
        let sorted = hrSamples.sorted { $0.timestamp < $1.timestamp }

        return VStack(alignment: .leading, spacing: 4) {
            Text("HEART RATE OVER TIME").font(.caption2).foregroundColor(.gray)
            Chart {
                ForEach(Array(sorted.enumerated()), id: \.offset) { _, p in
                    LineMark(x: .value("Time", p.timestamp), y: .value("BPM", p.value))
                        .foregroundStyle(.red)
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisValueLabel { if let v = value.as(Double.self) {
                        Text(String(format: "%.0f", v)).font(.caption2).foregroundColor(.gray)
                    }}
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [4]))
                        .foregroundStyle(Color.gray.opacity(0.3))
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 5)) { value in
                    AxisValueLabel { if let d = value.as(Date.self) {
                        Text(Self.timeFmt.string(from: d)).font(.caption2).foregroundColor(.gray)
                    }}
                }
            }
            .frame(height: 150)
        }
    }

    // MARK: - Workout Interval Table

    private func workoutIntervalTable(_ hrSamples: [DataPoint], duration: Double) -> some View {
        let sorted = hrSamples.sorted { $0.timestamp < $1.timestamp }
        guard let firstTime = sorted.first?.timestamp else { return AnyView(EmptyView()) }

        // Choose interval: 1-min for workouts < 20min, 5-min otherwise
        let intervalSec: Double = duration < 1200 ? 60 : 300
        let intervalLabel = duration < 1200 ? "1 min" : "5 min"

        struct Interval: Identifiable {
            let id: Int
            let startOffset: Double
            let avg: Double, min: Double, max: Double, count: Int
        }

        var intervals: [Interval] = []
        let numIntervals = Int(ceil(duration / intervalSec))
        for i in 0..<numIntervals {
            let iStart = firstTime.addingTimeInterval(Double(i) * intervalSec)
            let iEnd = firstTime.addingTimeInterval(Double(i + 1) * intervalSec)
            let inRange = sorted.filter { $0.timestamp >= iStart && $0.timestamp < iEnd }
            let values = inRange.map(\.value)
            if !values.isEmpty {
                intervals.append(Interval(
                    id: i,
                    startOffset: Double(i) * intervalSec,
                    avg: values.reduce(0, +) / Double(values.count),
                    min: values.min() ?? 0,
                    max: values.max() ?? 0,
                    count: values.count
                ))
            }
        }

        return AnyView(VStack(alignment: .leading, spacing: 4) {
            Text("HR INTERVALS (\(intervalLabel))").font(.caption2).foregroundColor(.gray)

            // Header
            HStack {
                Text("Time").font(.caption2.bold()).frame(width: 50, alignment: .leading)
                Text("Avg").font(.caption2.bold()).frame(width: 40)
                Text("Min").font(.caption2.bold()).frame(width: 40)
                Text("Max").font(.caption2.bold()).frame(width: 40)
                Spacer()
            }
            .foregroundColor(.gray)
            .padding(.top, 4)

            ForEach(intervals) { iv in
                HStack {
                    Text(formatOffset(iv.startOffset))
                        .font(.caption.monospacedDigit()).foregroundColor(.gray)
                        .frame(width: 50, alignment: .leading)
                    Text(String(format: "%.0f", iv.avg))
                        .font(.caption.monospacedDigit()).frame(width: 40)
                    Text(String(format: "%.0f", iv.min))
                        .font(.caption.monospacedDigit()).foregroundColor(.gray).frame(width: 40)
                    Text(String(format: "%.0f", iv.max))
                        .font(.caption.monospacedDigit()).foregroundColor(.gray).frame(width: 40)
                    Spacer()
                }
            }
        })
    }

    private func formatOffset(_ seconds: Double) -> String {
        let m = Int(seconds) / 60, s = Int(seconds) % 60
        return String(format: "%d:%02d", m, s)
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
        let dp = dataPoints
        let primary = dp.filter { $0.role == .primary }
        let detail = dp.filter { $0.role == .detail }

        return VStack(alignment: .leading, spacing: 8) {
            Text("BODY COMPOSITION").font(.caption2).foregroundColor(.gray)
            ForEach(primary) { p in
                dataRow(label: displayName(for: p.type), value: formatValue(p), unit: p.unit, source: "")
            }
            if !detail.isEmpty {
                DisclosureGroup {
                    ForEach(detail) { p in
                        dataRow(label: displayName(for: p.type), value: formatValue(p), unit: p.unit, source: "")
                    }
                } label: {
                    Text("MORE").font(.caption2).foregroundColor(.gray)
                }
                .tint(.gray)
            }
            sourceRow
        }
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
                dataRow(label: displayName(for: p.type), value: formatValue(p), unit: p.unit, source: "")
            }
            if !detail.isEmpty {
                DisclosureGroup {
                    ForEach(detail) { p in
                        dataRow(label: displayName(for: p.type), value: formatValue(p), unit: p.unit, source: "")
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
                        Text(displayName(for: dp.type))
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
        case DataType.peakG: return "Peak g"
        case DataType.durationSec: return "Duration"
        case DataType.distance: return "Distance"
        case DataType.activeCalories: return "Active Calories"
        case DataType.pace: return "Pace"
        case DataType.stepLength: return "Step Length"
        case DataType.runningEconomy: return "Running Economy"
        case DataType.aerobicLoad: return "Aerobic Load"
        case DataType.hrvSDNN: return "HRV (SDNN)"
        case DataType.restingHeartRate: return "Resting HR"
        case DataType.bloodOxygen: return "SpO2"
        case DataType.bodyTemperature: return "Temperature"
        case DataType.vo2Max: return "VO2 Max"
        case DataType.steps: return "Steps"
        case DataType.sleepStage: return "Sleep"
        case DataType.heartRateSample: return "Heart Rate"
        case DataType.workoutType: return "Activity"
        case DataType.workoutDuration: return "Duration"
        case DataType.workoutDistance: return "Distance"
        case DataType.workoutCalories: return "Calories"
        case DataType.workoutAvgHR: return "Avg HR"
        case DataType.workoutMaxHR: return "Max HR"
        case DataType.recoveryIndex: return "Recovery"
        case DataType.recoveryHRVComponent: return "HRV Recovery"
        case DataType.recoveryRHRComponent: return "RHR Recovery"
        case DataType.recoveryBaselineSDNN: return "30d Avg SDNN"
        case DataType.recoveryBaselineRHR: return "30d Avg RHR"
        case DataType.recoveryConfidence: return "Confidence"
        default: return type.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

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
