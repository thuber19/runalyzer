import SwiftUI
import Charts

/// Detail view for a Workout entity. Shows summary stats, HR/pace/cadence charts,
/// and a 1-minute interval breakdown table.
///
/// All data comes from the SQLite data_point table — no on-demand HealthKit fetches.
/// HR, distance, cadence are imported at sync time.
struct WorkoutDetailView: View {
    let workout: Workout
    @EnvironmentObject var workoutStore: WorkoutStore

    @State private var hrSamples: [DataPoint] = []
    @State private var cadenceSamples: [DataPoint] = []
    @State private var speedSamples: [DataPoint] = []  // m/s — Apple's pre-calculated
    @State private var workoutDataPoints: [DataPoint] = []
    @State private var isLoading = true

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                heroHeader
                metricsGrid

                if !hrSamples.isEmpty { hrSection }
                if !speedSamples.isEmpty { paceSection }
                if !cadenceSamples.isEmpty { cadenceSection }

                if !intervals.isEmpty { splitsSection }

                if !workoutDataPoints.isEmpty { workoutDataSection }

                if isLoading {
                    ProgressView("Loading workout data…").padding()
                }
            }
            .padding()
        }
        .background(Color.appBackground)
        .navigationTitle(workout.activityType)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { loadData() }
    }

    // MARK: - Hero Header

    private var heroHeader: some View {
        VStack(spacing: 8) {
            Image(systemName: workout.icon)
                .font(.system(size: 40))
                .foregroundStyle(Color.appTeal)
                .frame(width: 72, height: 72)
                .background(Color.appTeal.opacity(0.15))
                .clipShape(Circle())

            Text(workout.activityType)
                .font(.title2.bold())

            Text(workout.dateString)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if let dur = workout.durationSec {
                Text(formatDuration(dur))
                    .font(.system(.title, design: .rounded).bold().monospacedDigit())
                    .foregroundStyle(Color.appTeal)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    // MARK: - Metrics Grid

    private var metricsGrid: some View {
        let cells = metricCells
        return LazyVGrid(columns: [
            GridItem(.flexible(), spacing: 12),
            GridItem(.flexible(), spacing: 12),
            GridItem(.flexible(), spacing: 12)
        ], spacing: 12) {
            ForEach(cells, id: \.label) { cell in
                VStack(spacing: 4) {
                    Image(systemName: cell.icon)
                        .font(.caption)
                        .foregroundStyle(cell.color)
                    Text(cell.value)
                        .font(.headline.monospacedDigit())
                    Text(cell.label)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(Color.appSurface)
                .cornerRadius(10)
            }
        }
    }

    private struct MetricCell {
        let icon: String
        let value: String
        let label: String
        let color: Color
    }

    private var metricCells: [MetricCell] {
        var cells: [MetricCell] = []
        if let dist = workout.distanceKm {
            cells.append(MetricCell(icon: "point.topleft.down.to.point.bottomright.curvepath",
                                    value: String(format: "%.2f km", dist), label: "Distance", color: .appTeal))
        }
        if let hr = workout.avgHR {
            cells.append(MetricCell(icon: "heart.fill",
                                    value: String(format: "%.0f bpm", hr), label: "Avg HR", color: .appRed))
        }
        if let maxHR = workout.maxHR {
            cells.append(MetricCell(icon: "heart.fill",
                                    value: String(format: "%.0f bpm", maxHR), label: "Max HR", color: .red))
        }
        if let cal = workout.calories {
            cells.append(MetricCell(icon: "flame.fill",
                                    value: String(format: "%.0f", cal), label: "kcal", color: .orange))
        }
        if !speedSamples.isEmpty {
            let speeds = speedSamples.map(\.value).filter { $0 > 0 }
            let avgSpeed = speeds.isEmpty ? 0 : speeds.reduce(0, +) / Double(speeds.count)
            let avgPace = avgSpeed > 0 ? speedToPace(avgSpeed) : 0
            if avgPace > 0 && avgPace < 20 {
                cells.append(MetricCell(icon: "speedometer",
                                        value: formatPace(avgPace), label: "Avg Pace", color: .appTeal))
            }
        }
        if !cadenceSamples.isEmpty {
            let avg = cadenceSamples.map(\.value).reduce(0, +) / Double(cadenceSamples.count)
            cells.append(MetricCell(icon: "figure.run",
                                    value: String(format: "%.0f spm", avg), label: "Cadence", color: .green))
        }
        return cells
    }

    // MARK: - Heart Rate Section

    private var hrSection: some View {
        chartSection(title: "Heart Rate", color: .red, samples: hrSamples, unit: "bpm") {
            let vals = hrSamples.map(\.value)
            let avg = vals.reduce(0, +) / Double(vals.count)
            return [
                ("Avg", String(format: "%.0f", avg)),
                ("Min", String(format: "%.0f", vals.min() ?? 0)),
                ("Max", String(format: "%.0f", vals.max() ?? 0)),
            ]
        }
    }

    // MARK: - Pace Section

    private var paceSection: some View {
        let paces = speedSamples.map { speedToPace($0.value) }.filter { $0 > 0 && $0 < 20 }
        let avgPace = paces.isEmpty ? 0 : paces.reduce(0, +) / Double(paces.count)
        let speeds = speedSamples.map { speedToKmh($0.value) }
        let avgSpeed = speeds.isEmpty ? 0 : speeds.reduce(0, +) / Double(speeds.count)

        // Convert speed → pace for the chart
        let chartData = speedSamples.compactMap { dp -> ChartDataPoint? in
            let pace = speedToPace(dp.value)
            guard pace > 0 && pace < 20 else { return nil }
            return ChartDataPoint(date: dp.timestamp, avg: pace)
        }

        return VStack(alignment: .leading, spacing: 8) {
            Text("Pace / Speed")
                .font(.headline)

            HStack(spacing: 24) {
                VStack {
                    Text(formatPace(avgPace)).font(.title3.bold().monospacedDigit())
                    Text("avg min/km").font(.caption2).foregroundStyle(.secondary)
                }
                VStack {
                    Text(String(format: "%.1f", avgSpeed)).font(.title3.bold().monospacedDigit())
                    Text("avg km/h").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            ScrubbingLineChart(data: chartData, color: .appTeal, unit: "min/km",
                               dateFormat: "HH:mm", showBand: false)
                .frame(height: 160)
        }
        .padding()
        .background(Color.appSurface)
        .cornerRadius(12)
    }

    // MARK: - Cadence Section

    private var cadenceSection: some View {
        chartSection(title: "Cadence", color: .green, samples: cadenceSamples, unit: "spm") {
            let avg = cadenceSamples.map(\.value).reduce(0, +) / Double(cadenceSamples.count)
            return [("Avg", String(format: "%.0f spm", avg))]
        }
    }

    // MARK: - Chart Section Builder

    private func chartSection(title: String, color: Color, samples: [DataPoint], unit: String,
                               stats: () -> [(String, String)]) -> some View {
        let chartData = samples.map { ChartDataPoint(date: $0.timestamp, avg: $0.value) }
        let statValues = stats()

        return VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)

            HStack(spacing: 16) {
                ForEach(statValues, id: \.0) { label, value in
                    VStack {
                        Text(value).font(.title3.bold().monospacedDigit())
                        Text(label).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }

            ScrubbingLineChart(data: chartData, color: color, unit: unit,
                               dateFormat: "HH:mm", showBand: false)
                .frame(height: 160)
        }
        .padding()
        .background(Color.appSurface)
        .cornerRadius(12)
    }

    // MARK: - Splits Section

    private var splitsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Splits")
                .font(.headline)
                .padding(.horizontal).padding(.top, 12).padding(.bottom, 8)

            // Header
            HStack {
                Text("Min").frame(width: 36, alignment: .leading)
                Spacer()
                Text("HR").frame(width: 40, alignment: .trailing)
                Text("Cadence").frame(width: 60, alignment: .trailing)
                Text("Pace").frame(width: 50, alignment: .trailing)
                Text("Dist").frame(width: 50, alignment: .trailing)
            }
            .font(.caption2.bold())
            .foregroundStyle(.secondary)
            .padding(.horizontal)
            .padding(.bottom, 6)

            Divider().overlay(Color.gray.opacity(0.3))

            ForEach(intervals) { interval in
                HStack {
                    Text(interval.label)
                        .font(.subheadline.monospacedDigit())
                        .frame(width: 36, alignment: .leading)
                    Spacer()
                    Text(interval.avgHR.map { String(format: "%.0f", $0) } ?? "–")
                        .frame(width: 40, alignment: .trailing)
                    Text(interval.avgCadence.map { String(format: "%.0f", $0) } ?? "–")
                        .frame(width: 60, alignment: .trailing)
                    Text(interval.pace.map { formatPace($0) } ?? "–")
                        .frame(width: 50, alignment: .trailing)
                    Text(interval.cumulativeKm.map { String(format: "%.2f", $0) } ?? "–")
                        .frame(width: 50, alignment: .trailing)
                }
                .font(.subheadline.monospacedDigit())
                .padding(.horizontal)
                .padding(.vertical, 8)

                if interval.id != intervals.last?.id {
                    Divider().overlay(Color.gray.opacity(0.15)).padding(.leading)
                }
            }
        }
        .background(Color.appSurface)
        .cornerRadius(12)
    }

    // MARK: - Workout Data Section

    private var workoutDataSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Workout Data")
                .font(.headline)
                .padding(.horizontal).padding(.top, 12).padding(.bottom, 8)

            ForEach(Array(workoutDataPoints.enumerated()), id: \.offset) { _, dp in
                HStack {
                    Text(dp.type.replacingOccurrences(of: "_", with: " ").capitalized)
                        .font(.subheadline)
                    Spacer()
                    Text(String(format: "%.2f", dp.value))
                        .font(.subheadline.monospacedDigit())
                    Text(dp.unit)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal).padding(.vertical, 8)

                if dp.type != workoutDataPoints.last?.type {
                    Divider().overlay(Color.gray.opacity(0.15)).padding(.leading)
                }
            }
        }
        .background(Color.appSurface)
        .cornerRadius(12)
    }

    // MARK: - Data Loading

    private func loadData() {
        // All data from the shared data_point table — imported at sync time, not on-demand.
        hrSamples = workoutStore.sharedDataPoints(for: workout, type: DataType.heartRateSample)
        cadenceSamples = workoutStore.sharedDataPoints(for: workout, type: DataType.cadence)
        speedSamples = workoutStore.sharedDataPoints(for: workout, type: DataType.runningSpeed)

        // Workout-specific DataPoints (IMU cadence windows, peak G)
        workoutDataPoints = workoutStore.workoutDataPoints(for: workout)
        isLoading = false
    }

    // MARK: - Intervals

    private struct Interval: Identifiable {
        let id: Int  // minute index
        let label: String
        let avgHR: Double?
        let avgCadence: Double?
        let pace: Double?      // min/km
        let speedKmh: Double?  // km/h
        let cumulativeKm: Double?
    }

    private var intervals: [Interval] {
        guard let dur = workout.durationSec, dur > 0 else { return [] }
        let minuteCount = Int(ceil(dur / 60))
        var result: [Interval] = []
        var cumulativeKm: Double = 0

        for i in 0..<minuteCount {
            let windowStart = workout.startDate.addingTimeInterval(Double(i) * 60)
            let windowEnd = workout.startDate.addingTimeInterval(Double(i + 1) * 60)

            let hrInWindow = hrSamples.filter { $0.timestamp >= windowStart && $0.timestamp < windowEnd }
            let avgHR = hrInWindow.isEmpty ? nil : hrInWindow.map(\.value).reduce(0, +) / Double(hrInWindow.count)

            let cadInWindow = cadenceSamples.filter { $0.timestamp >= windowStart && $0.timestamp < windowEnd }
            let avgCad = cadInWindow.isEmpty ? nil : cadInWindow.map(\.value).reduce(0, +) / Double(cadInWindow.count)

            let speedInWindow = speedSamples.filter { $0.timestamp >= windowStart && $0.timestamp < windowEnd }
            let avgSpeed = speedInWindow.isEmpty ? nil :
                speedInWindow.map(\.value).reduce(0, +) / Double(speedInWindow.count)
            let pace = avgSpeed.flatMap { $0 > 0 ? speedToPace($0) : nil }
            let distInMinute = (avgSpeed ?? 0) * 60 / 1000  // m/s × 60s → km
            cumulativeKm += distInMinute

            let label = "\(i + 1)"
            let speedKmh = avgSpeed.map { speedToKmh($0) }
            result.append(Interval(id: i, label: label, avgHR: avgHR,
                                   avgCadence: avgCad, pace: pace, speedKmh: speedKmh,
                                   cumulativeKm: cumulativeKm > 0 ? cumulativeKm : nil))
        }
        return result
    }

    // MARK: - Helpers

    private func formatDuration(_ seconds: Double) -> String {
        let h = Int(seconds) / 3600
        let m = (Int(seconds) % 3600) / 60
        let s = Int(seconds) % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }

    private func speedToPace(_ mps: Double) -> Double {
        guard mps > 0 else { return 0 }
        return 1000 / (mps * 60)
    }

    private func speedToKmh(_ mps: Double) -> Double { mps * 3.6 }

    private func formatPace(_ minPerKm: Double) -> String {
        guard minPerKm > 0 && minPerKm < 60 else { return "–" }
        let m = Int(minPerKm)
        let s = Int((minPerKm - Double(m)) * 60)
        return String(format: "%d:%02d", m, s)
    }
}
