import SwiftUI
import Charts

/// Workout detail section for MeasurementDetailView.
/// Shows activity name, duration, key metrics, HR zones, HR chart, and interval table.
struct WorkoutDetailSection: View {
    let dataPoints: [DataPoint]
    @EnvironmentObject var profileProvider: UserProfileProvider

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        let activityName = dataPoints.first(where: { $0.type == DataType.workoutType })?.unit ?? "Workout"
        let duration = dataPoints.first(where: { $0.type == DataType.workoutDuration })?.value ?? 0
        let distance = dataPoints.first(where: { $0.type == DataType.workoutDistance })?.value
        let calories = dataPoints.first(where: { $0.type == DataType.workoutCalories })?.value
        let avgHR = dataPoints.first(where: { $0.type == DataType.workoutAvgHR })?.value
        let maxHR = dataPoints.first(where: { $0.type == DataType.workoutMaxHR })?.value
        let hrSamples = dataPoints.filter { $0.type == DataType.heartRateSample }

        VStack(alignment: .leading, spacing: 12) {
            // Activity + Duration
            HStack {
                Text(activityName).font(.title2.bold())
                Spacer()
                Text(formatDuration(duration)).font(.title2.bold().monospacedDigit())
            }

            // Key metrics
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

            if !hrSamples.isEmpty {
                Divider().background(Color.gray.opacity(0.3))
                hrZoneBreakdown(hrSamples)

                Divider().background(Color.gray.opacity(0.3))
                hrChart(hrSamples)

                Divider().background(Color.gray.opacity(0.3))
                intervalTable(hrSamples, duration: duration)
            }
        }
    }

    // MARK: - HR Zone Breakdown

    private func hrZoneBreakdown(_ hrSamples: [DataPoint]) -> some View {
        let profile = profileProvider.profile
        let profileZones = profile.hrZones
        let lowerBounds = profile.hrZoneLowerBounds
        let colors: [Color] = [.gray, .blue, .green, .orange, .red]

        let zoneDefs = profileZones.enumerated().map { i, zone in
            HRZoneAnalysis.ZoneDefinition(
                name: zone.name,
                range: Double(lowerBounds[i])...Double(zone.maxBPM)
            )
        }

        let zoneTimes = HRZoneAnalysis.compute(
            hrValues: hrSamples.map { (value: $0.value, timestamp: $0.timestamp) },
            zones: zoneDefs
        )

        return VStack(alignment: .leading, spacing: 4) {
            Text("HR ZONES").font(.caption2).foregroundColor(.gray)
            ForEach(Array(zoneTimes.enumerated()), id: \.offset) { i, zt in
                let color = colors[min(i, colors.count - 1)]
                HStack(spacing: 8) {
                    Text(zt.name).font(.caption).frame(width: 50, alignment: .leading)
                    GeometryReader { geo in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(color)
                            .frame(width: geo.size.width * zt.fraction)
                    }
                    .frame(height: 14)
                    Text(formatDuration(zt.seconds))
                        .font(.caption2.monospacedDigit()).foregroundColor(.gray)
                        .frame(width: 45, alignment: .trailing)
                }
            }
            Text("Max HR: \(profile.maxHR) bpm · Settings → Body Profile to customize zones")
                .font(.system(size: 9)).foregroundColor(.gray)
        }
    }

    // MARK: - HR Chart

    private func hrChart(_ hrSamples: [DataPoint]) -> some View {
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

    // MARK: - Interval Table

    private func intervalTable(_ hrSamples: [DataPoint], duration: Double) -> some View {
        let sorted = hrSamples.sorted { $0.timestamp < $1.timestamp }
        guard let firstTime = sorted.first?.timestamp else { return AnyView(EmptyView()) }

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

    // MARK: - Helpers

    private func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    private func formatOffset(_ seconds: Double) -> String {
        let m = Int(seconds) / 60, s = Int(seconds) % 60
        return String(format: "%d:%02d", m, s)
    }
}
