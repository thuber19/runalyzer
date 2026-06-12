import SwiftUI

/// A metric definition for a category dashboard tile.
struct MetricDefinition: Identifiable {
    let id: String  // DataType constant
    let title: String
    let unit: String
    let color: Color
    let aggregation: Aggregation

    enum Aggregation {
        case latest       // show most recent value (RHR, SpO2)
        case dailyAverage // average per day, show latest day's avg (HRV)
        case max          // max value (steps — dedups sources)
    }
}

/// Generic category dashboard showing metric tiles for a health domain.
///
/// Provides the middle layer in the 3-level drill-down:
/// Home (summary scores) → **Category dashboard** → Metric detail (MetricTrendView)
///
/// Usage:
/// ```
/// CategoryDashboardView(
///     title: "Heart",
///     icon: "heart.fill",
///     color: .red,
///     metrics: [
///         MetricDefinition(id: DataType.restingHeartRate, title: "Resting HR", unit: "bpm", color: .red, aggregation: .latest),
///         MetricDefinition(id: DataType.hrvSDNN, title: "HRV (SDNN)", unit: "ms", color: .purple, aggregation: .dailyAverage),
///     ]
/// )
/// ```
struct CategoryDashboardView: View {
    let title: String
    let icon: String
    let color: Color
    let metrics: [MetricDefinition]

    @EnvironmentObject var measurementStore: MeasurementStore
    @EnvironmentObject var sourcePrefs: SourcePreferenceStore
    @State private var timeRange: MetricTrendView.TimeRange = .month

    private var metricIndex: MetricIndex { MetricIndex(store: measurementStore) }
    private let cal = Calendar.current

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                rangePicker
                metricGrid
            }
            .padding()
        }
        .background(Color(hex: 0x1a1a2e))
        .navigationTitle(title)
    }

    private var rangePicker: some View {
        Picker("Range", selection: $timeRange) {
            ForEach(MetricTrendView.TimeRange.allCases, id: \.self) { r in
                Text(r.rawValue).tag(r)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal)
    }

    private var metricGrid: some View {
        let rows = stride(from: 0, to: metrics.count, by: 2).map { Array(metrics[$0..<min($0 + 2, metrics.count)]) }
        return ForEach(rows, id: \.first!.id) { row in
            HStack(spacing: 12) {
                metricTile(row[0])
                if row.count > 1 {
                    metricTile(row[1])
                } else {
                    Spacer().frame(maxWidth: .infinity)
                }
            }
        }
    }

    // MARK: - Metric Tile

    private struct MetricResult {
        let value: String?
        let sparkline: [Double]
        let change: Double? // percentage change (first half → second half of period)
    }

    private func metricTile(_ metric: MetricDefinition) -> some View {
        let lookback = cal.date(byAdding: .day, value: -timeRange.days, to: Date()) ?? Date()
        let points = metricIndex.query(type: metric.id, measurementType: .metric,
                                       from: lookback, to: Date(), filter: sourcePrefs)

        let result = computeValue(points: points, metric: metric)

        let badge: DashboardTile<MetricTrendView>.Badge? = result.change.map { pct in
            let text = String(format: "%+.1f%%", pct)
            let color: Color = abs(pct) < 1 ? .gray : (pct >= 0 ? .green : .orange)
            return .init(text: text, color: color)
        }

        return DashboardTile(
            title: metric.title.uppercased(),
            value: result.value ?? "--",
            unit: metric.unit,
            period: timeRange.rawValue,
            badge: badge,
            sparklineValues: result.sparkline.count > 1 ? result.sparkline : nil,
            sparklineColor: metric.color
        ) {
            MetricTrendView(metricType: metric.id, title: metric.title,
                            unit: metric.unit, color: metric.color)
        }
    }

    private func computeValue(points: [DataPoint],
                               metric: MetricDefinition) -> MetricResult {
        let sparkline: [Double]
        let value: String?

        switch metric.aggregation {
        case .latest:
            value = points.last.map { String(Int($0.value)) }
            sparkline = points.map(\.value)

        case .dailyAverage:
            var byDay: [Date: [Double]] = [:]
            for p in points {
                let day = cal.startOfDay(for: p.timestamp)
                byDay[day, default: []].append(p.value)
            }
            let dailyAvgs = byDay.keys.sorted().map { day in
                let vals = byDay[day]!
                return vals.reduce(0, +) / Double(vals.count)
            }
            value = dailyAvgs.last.map { String(Int($0)) }
            sparkline = dailyAvgs

        case .max:
            let maxVal = points.map(\.value).max()
            value = maxVal.map { String(format: "%.0f", $0) }
            sparkline = points.map(\.value)
        }

        // Compute % change: average of second half vs first half of the sparkline
        let change = percentChange(sparkline)
        return MetricResult(value: value, sparkline: sparkline, change: change)
    }

    /// Compare average of second half to first half of values.
    private func percentChange(_ values: [Double]) -> Double? {
        guard values.count >= 4 else { return nil }
        let mid = values.count / 2
        let firstHalf = Array(values[..<mid])
        let secondHalf = Array(values[mid...])
        let avgFirst = firstHalf.reduce(0, +) / Double(firstHalf.count)
        let avgSecond = secondHalf.reduce(0, +) / Double(secondHalf.count)
        guard avgFirst != 0 else { return nil }
        return ((avgSecond - avgFirst) / avgFirst) * 100
    }
}

// MARK: - Predefined Categories

extension CategoryDashboardView {

    /// Heart category: RHR, HRV, HR, SpO2
    static func heart() -> CategoryDashboardView {
        CategoryDashboardView(
            title: "Heart",
            icon: "heart.fill",
            color: .red,
            metrics: [
                MetricDefinition(id: DataType.restingHeartRate, title: "Resting HR",
                                 unit: "bpm", color: .red, aggregation: .latest),
                MetricDefinition(id: DataType.hrvSDNN, title: "HRV (SDNN)",
                                 unit: "ms", color: .purple, aggregation: .dailyAverage),
                MetricDefinition(id: DataType.bloodOxygen, title: "Blood Oxygen",
                                 unit: "%", color: .blue, aggregation: .latest),
                MetricDefinition(id: DataType.vo2Max, title: "VO₂ Max",
                                 unit: "mL/kg/min", color: .green, aggregation: .latest),
            ]
        )
    }

    /// Activity category: Steps, Distance, Calories
    static func activity() -> CategoryDashboardView {
        CategoryDashboardView(
            title: "Activity",
            icon: "figure.run",
            color: .green,
            metrics: [
                MetricDefinition(id: DataType.steps, title: "Steps",
                                 unit: "steps", color: .green, aggregation: .max),
                MetricDefinition(id: DataType.distance, title: "Distance",
                                 unit: "m", color: .orange, aggregation: .max),
            ]
        )
    }
}
