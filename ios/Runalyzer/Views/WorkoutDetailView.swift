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
            VStack(spacing: 16) {
                summaryCard

                if !hrSamples.isEmpty { hrChart }
                if !speedSamples.isEmpty { paceChart }
                if !cadenceSamples.isEmpty { cadenceChart }

                if !intervals.isEmpty { intervalTable }

                if !workoutDataPoints.isEmpty { dataPointsList }

                if isLoading {
                    ProgressView("Loading workout data…").padding()
                }
            }
            .padding()
        }
        .background(Color.appBackground)
        .navigationTitle(workout.activityType)
        .onAppear { loadData() }
    }

    // MARK: - Summary Card

    private var summaryCard: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: workout.icon).font(.title2).foregroundColor(.pink)
                Text(workout.activityType).font(.title2.bold())
                Spacer()
            }
            Text(workout.dateString).font(.subheadline).foregroundColor(.gray)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 0) {
                if workout.durationSec != nil {
                    statCol(workout.durationString, "Duration")
                }
                if let dist = workout.distanceKm {
                    statCol(String(format: "%.2f", dist), "km")
                }
                if let hr = workout.avgHR {
                    statCol(String(format: "%.0f", hr), "Avg HR")
                }
                if let maxHR = workout.maxHR {
                    statCol(String(format: "%.0f", maxHR), "Max HR")
                }
                if let cal = workout.calories {
                    statCol(String(format: "%.0f", cal), "kcal")
                }
            }
        }
        .padding()
        .background(Color.appSurface)
        .cornerRadius(12)
    }

    // MARK: - HR Chart

    private var hrChart: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("HEART RATE").font(.caption2).foregroundColor(.gray)
            let vals = hrSamples.map(\.value)
            let avg = vals.isEmpty ? 0 : vals.reduce(0, +) / Double(vals.count)
            HStack(spacing: 0) {
                statCol(String(format: "%.0f", avg), "Avg")
                statCol(String(format: "%.0f", vals.min() ?? 0), "Min")
                statCol(String(format: "%.0f", vals.max() ?? 0), "Max")
            }
            .padding(.bottom, 4)

            Chart {
                ForEach(Array(hrSamples.enumerated()), id: \.offset) { _, dp in
                    LineMark(x: .value("Time", dp.timestamp), y: .value("HR", dp.value))
                        .foregroundStyle(Color.red)
                }
            }
            .chartXAxis { timeAxis }
            .chartYAxis { valueAxis }
            .frame(height: 160)
        }
        .padding()
        .background(Color.appSurface)
        .cornerRadius(12)
    }

    // MARK: - Pace Chart

    /// Convert speed (m/s) to pace (min/km).
    private func speedToPace(_ mps: Double) -> Double {
        guard mps > 0 else { return 0 }
        return 1000 / (mps * 60)  // (1 km / speed_m_per_s) / 60 = min/km
    }

    /// Convert speed (m/s) to km/h.
    private func speedToKmh(_ mps: Double) -> Double { mps * 3.6 }

    private var paceChart: some View {
        let paces = speedSamples.map { speedToPace($0.value) }.filter { $0 > 0 && $0 < 20 }
        let avgPace = paces.isEmpty ? 0 : paces.reduce(0, +) / Double(paces.count)
        let speeds = speedSamples.map { speedToKmh($0.value) }
        let avgSpeed = speeds.isEmpty ? 0 : speeds.reduce(0, +) / Double(speeds.count)

        return VStack(alignment: .leading, spacing: 4) {
            Text("PACE / SPEED").font(.caption2).foregroundColor(.gray)
            HStack(spacing: 16) {
                VStack {
                    Text(formatPace(avgPace)).font(.headline.monospacedDigit())
                    Text("avg min/km").font(.caption2).foregroundColor(.gray)
                }
                VStack {
                    Text(String(format: "%.1f", avgSpeed)).font(.headline.monospacedDigit())
                    Text("avg km/h").font(.caption2).foregroundColor(.gray)
                }
            }

            Chart {
                ForEach(Array(speedSamples.enumerated()), id: \.offset) { _, dp in
                    let pace = speedToPace(dp.value)
                    if pace > 0 && pace < 20 {
                        LineMark(x: .value("Time", dp.timestamp), y: .value("Pace", pace))
                            .foregroundStyle(Color.appTeal)
                    }
                }
            }
            .chartXAxis { timeAxis }
            .chartYScale(domain: .automatic(includesZero: false))
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisValueLabel {
                        if let v = value.as(Double.self) {
                            Text(formatPace(v)).font(.caption2).foregroundColor(.gray)
                        }
                    }
                }
            }
            .frame(height: 140)
        }
        .padding()
        .background(Color.appSurface)
        .cornerRadius(12)
    }

    // MARK: - Cadence Chart

    private var cadenceChart: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("CADENCE").font(.caption2).foregroundColor(.gray)
            let vals = cadenceSamples.map(\.value)
            let avg = vals.isEmpty ? 0 : vals.reduce(0, +) / Double(vals.count)
            Text(String(format: "%.0f spm avg", avg)).font(.headline.monospacedDigit())

            Chart {
                ForEach(Array(cadenceSamples.enumerated()), id: \.offset) { _, s in
                    LineMark(x: .value("Time", s.timestamp), y: .value("SPM", s.value))
                        .foregroundStyle(Color.green)
                }
            }
            .chartXAxis { timeAxis }
            .chartYAxis { valueAxis }
            .frame(height: 140)
        }
        .padding()
        .background(Color.appSurface)
        .cornerRadius(12)
    }

    // MARK: - 1-Minute Interval Table

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

            // Avg HR in this minute
            let hrInWindow = hrSamples.filter { $0.timestamp >= windowStart && $0.timestamp < windowEnd }
            let avgHR = hrInWindow.isEmpty ? nil : hrInWindow.map(\.value).reduce(0, +) / Double(hrInWindow.count)

            // Avg cadence in this minute
            let cadInWindow = cadenceSamples.filter { $0.timestamp >= windowStart && $0.timestamp < windowEnd }
            let avgCad = cadInWindow.isEmpty ? nil : cadInWindow.map(\.value).reduce(0, +) / Double(cadInWindow.count)

            // Pace from Apple's pre-calculated running speed in this minute
            let speedInWindow = speedSamples.filter { $0.timestamp >= windowStart && $0.timestamp < windowEnd }
            let avgSpeed = speedInWindow.isEmpty ? nil :
                speedInWindow.map(\.value).reduce(0, +) / Double(speedInWindow.count)
            let pace = avgSpeed.flatMap { $0 > 0 ? speedToPace($0) : nil }
            let distInMinute = (avgSpeed ?? 0) * 60 / 1000  // m/s × 60s → km
            cumulativeKm += distInMinute

            let label = String(format: "%d:%02d", (i * 60) / 60, (i * 60) % 60)
            let speedKmh = avgSpeed.map { speedToKmh($0) }
            result.append(Interval(id: i, label: label, avgHR: avgHR,
                                   avgCadence: avgCad, pace: pace, speedKmh: speedKmh,
                                   cumulativeKm: cumulativeKm > 0 ? cumulativeKm : nil))
        }
        return result
    }

    private var intervalTable: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("INTERVALS (1 MIN)").font(.caption2).foregroundColor(.gray)
                .padding(.horizontal).padding(.top, 12).padding(.bottom, 4)

            // Header
            HStack {
                Text("Time").frame(width: 50, alignment: .leading)
                Text("HR").frame(width: 45, alignment: .trailing)
                Text("Cadence").frame(width: 60, alignment: .trailing)
                Text("Pace").frame(width: 55, alignment: .trailing)
                Text("Dist").frame(width: 50, alignment: .trailing)
            }
            .font(.caption2.bold()).foregroundColor(.gray)
            .padding(.horizontal).padding(.vertical, 4)

            Divider().background(Color.gray.opacity(0.3))

            ForEach(intervals) { interval in
                HStack {
                    Text(interval.label)
                        .frame(width: 50, alignment: .leading)
                    Text(interval.avgHR.map { String(format: "%.0f", $0) } ?? "–")
                        .frame(width: 45, alignment: .trailing)
                    Text(interval.avgCadence.map { String(format: "%.0f", $0) } ?? "–")
                        .frame(width: 60, alignment: .trailing)
                    Text(interval.pace.map { formatPace($0) } ?? "–")
                        .frame(width: 55, alignment: .trailing)
                    Text(interval.cumulativeKm.map { String(format: "%.2f", $0) } ?? "–")
                        .frame(width: 50, alignment: .trailing)
                }
                .font(.system(size: 12, design: .monospaced))
                .padding(.horizontal).padding(.vertical, 3)

                if interval.id != intervals.last?.id {
                    Divider().background(Color.gray.opacity(0.15)).padding(.leading)
                }
            }
        }
        .background(Color.appSurface)
        .cornerRadius(12)
    }

    // MARK: - Workout DataPoints

    private var dataPointsList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("WORKOUT DATA").font(.caption2).foregroundColor(.gray)
                .padding(.horizontal).padding(.top, 12).padding(.bottom, 4)

            ForEach(Array(workoutDataPoints.enumerated()), id: \.offset) { _, dp in
                HStack {
                    Text(dp.type.replacingOccurrences(of: "_", with: " ").capitalized)
                        .font(.caption)
                    Spacer()
                    Text(String(format: "%.2f", dp.value)).font(.caption.monospacedDigit())
                    Text(dp.unit).font(.caption2).foregroundColor(.gray)
                }
                .padding(.horizontal).padding(.vertical, 6)
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

    // MARK: - Helpers

    private func statCol(_ value: String, _ label: String) -> some View {
        VStack {
            Text(value).font(.headline.monospacedDigit())
            Text(label).font(.caption2).foregroundColor(.gray)
        }
        .frame(maxWidth: .infinity)
    }

    private func formatPace(_ minPerKm: Double) -> String {
        guard minPerKm > 0 && minPerKm < 60 else { return "–" }
        let m = Int(minPerKm)
        let s = Int((minPerKm - Double(m)) * 60)
        return String(format: "%d:%02d", m, s)
    }

    private var timeAxis: some AxisContent {
        AxisMarks(values: .automatic(desiredCount: 5)) { value in
            AxisValueLabel {
                if let date = value.as(Date.self) {
                    Text(Self.timeFmt.string(from: date)).font(.caption2).foregroundColor(.gray)
                }
            }
        }
    }

    private var valueAxis: some AxisContent {
        AxisMarks(position: .leading) { value in
            AxisValueLabel {
                if let v = value.as(Double.self) {
                    Text(String(format: "%.0f", v)).font(.caption2).foregroundColor(.gray)
                }
            }
            AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [4]))
                .foregroundStyle(Color.gray.opacity(0.3))
        }
    }

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()
}
