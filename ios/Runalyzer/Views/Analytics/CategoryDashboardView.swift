import SwiftUI

/// A metric definition for a category dashboard tile.
struct MetricDefinition: Identifiable {
    let id: String  // DataType constant
    let title: String
    let unit: String
    let color: Color
    let aggregation: Aggregation
    let direction: MetricTrend.MetricDirection
    let weight: Double

    enum Aggregation {
        case latest       // show most recent value (RHR, SpO2)
        case dailyAverage // average per day, show latest day's avg (HRV)
        case max          // max value (steps — dedups sources)
    }

    init(id: String, title: String, unit: String, color: Color,
         aggregation: Aggregation,
         direction: MetricTrend.MetricDirection = .higherIsBetter,
         weight: Double = 1.0) {
        self.id = id; self.title = title; self.unit = unit
        self.color = color; self.aggregation = aggregation
        self.direction = direction; self.weight = weight
    }
}

/// Generic category dashboard showing metric tiles for a health domain.
///
/// Provides the middle layer in the 3-level drill-down:
/// Home (composite trend) → **Category dashboard** → Metric detail (MetricTrendView)
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
                trendHeader
                metricGrid
            }
            .padding()
        }
        .background(Color(hex: 0x1a1a2e))
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Trend Header

    private var trendHeader: some View {
        let trend = computeTrend()
        let trendIcon: String
        let trendColor: Color
        switch trend.direction {
        case .improving: trendIcon = "arrow.up.right"; trendColor = .green
        case .stable:    trendIcon = "arrow.right";    trendColor = .gray
        case .declining: trendIcon = "arrow.down.right"; trendColor = .orange
        }

        return VStack(spacing: 12) {
            // Direction + label
            HStack(spacing: 10) {
                Image(systemName: trendIcon)
                    .font(.title2.bold())
                    .foregroundColor(trendColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(trend.direction.rawValue)
                        .font(.headline).foregroundColor(trendColor)
                    Text("Over the last \(timeRange.rawValue)")
                        .font(.caption2).foregroundColor(.gray)
                }
                Spacer()
            }

            // Per-metric breakdown
            if !trend.metricTrends.isEmpty {
                Divider().background(Color.gray.opacity(0.3))
                HStack(spacing: 0) {
                    ForEach(trend.metricTrends, id: \.metricId) { mt in
                        let pctText = String(format: "%+.1f%%", mt.percentChange)
                        let pctColor = metricTrendColor(mt)
                        VStack(spacing: 2) {
                            Text(pctText).font(.caption.bold().monospacedDigit())
                                .foregroundColor(pctColor)
                            Text(mt.name).font(.caption2).foregroundColor(.gray)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .padding()
        .background(Color(hex: 0x16213e))
        .cornerRadius(12)
    }

    /// Color for a metric trend: green if moving in the healthy direction, orange if not.
    private func metricTrendColor(_ mt: MetricTrend) -> Color {
        let isHealthy: Bool
        switch mt.direction {
        case .higherIsBetter: isHealthy = mt.percentChange >= 0
        case .lowerIsBetter:  isHealthy = mt.percentChange <= 0
        }
        if abs(mt.percentChange) < 1 { return .gray }
        return isHealthy ? .green : .orange
    }

    // MARK: - Trend Computation

    private func computeTrend() -> CategoryTrend {
        let historyStart = cal.date(byAdding: .day, value: -timeRange.days, to: Date()) ?? Date()

        var inputs: [HealthScore.MetricInput] = []
        for metric in metrics {
            let points = metricIndex.query(type: metric.id, measurementType: .metric,
                                           from: historyStart, to: Date(), filter: sourcePrefs)
            let dailyValues = toDailyValues(points, metric: metric)
            guard !dailyValues.isEmpty else { continue }

            inputs.append(HealthScore.MetricInput(
                id: metric.id, name: metric.title,
                direction: metric.direction, weight: metric.weight,
                dailyValues: dailyValues
            ))
        }

        return HealthScore.compute(metrics: inputs)
    }

    /// Aggregate raw data points into one value per day.
    private func toDailyValues(_ points: [DataPoint],
                                metric: MetricDefinition) -> [(date: Date, value: Double)] {
        var byDay: [Date: [Double]] = [:]
        for p in points {
            let day = cal.startOfDay(for: p.timestamp)
            byDay[day, default: []].append(p.value)
        }
        return byDay.keys.sorted().map { day in
            let vals = byDay[day]!
            let value: Double
            switch metric.aggregation {
            case .dailyAverage: value = vals.reduce(0, +) / Double(vals.count)
            case .max:          value = vals.max() ?? 0
            case .latest:       value = vals.last ?? 0
            }
            return (date: day, value: value)
        }
    }

    // MARK: - Range Picker

    private var rangePicker: some View {
        Picker("Range", selection: $timeRange) {
            ForEach(MetricTrendView.TimeRange.allCases, id: \.self) { r in
                Text(r.rawValue).tag(r)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal)
    }

    // MARK: - Metric Grid

    private var metricGrid: some View {
        let rows = stride(from: 0, to: metrics.count, by: 2).map {
            Array(metrics[$0..<min($0 + 2, metrics.count)])
        }
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
        let change: Double?
    }

    private func metricTile(_ metric: MetricDefinition) -> some View {
        let lookback = cal.date(byAdding: .day, value: -timeRange.days, to: Date()) ?? Date()
        let points = metricIndex.query(type: metric.id, measurementType: .metric,
                                       from: lookback, to: Date(), filter: sourcePrefs)

        let result = computeValue(points: points, metric: metric)

        let badge: DashboardTile<MetricTrendView>.Badge? = result.change.map { pct in
            let text = String(format: "%+.1f%%", pct)
            let isHealthy: Bool
            switch metric.direction {
            case .higherIsBetter: isHealthy = pct >= 0
            case .lowerIsBetter:  isHealthy = pct <= 0
            }
            let color: Color = abs(pct) < 1 ? .gray : (isHealthy ? .green : .orange)
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
        // Always aggregate to daily values — ensures % change is consistent
        // with the trend header (which also uses daily values)
        let daily = toDailyValues(points, metric: metric)
        let sparkline = daily.map(\.value)
        let value: String? = sparkline.last.map {
            metric.aggregation == .max ? String(format: "%.0f", $0) : String(Int($0))
        }

        let change = percentChange(sparkline)
        return MetricResult(value: value, sparkline: sparkline, change: change)
    }

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

    /// Heart category: RHR, HRV, SpO2, VO2 Max
    static func heart() -> CategoryDashboardView {
        CategoryDashboardView(
            title: "Heart",
            icon: "heart.fill",
            color: .red,
            metrics: [
                MetricDefinition(id: DataType.restingHeartRate, title: "Resting HR",
                                 unit: "bpm", color: .red, aggregation: .latest,
                                 direction: .lowerIsBetter, weight: 0.30),
                MetricDefinition(id: DataType.hrvSDNN, title: "HRV (SDNN)",
                                 unit: "ms", color: .purple, aggregation: .dailyAverage,
                                 direction: .higherIsBetter, weight: 0.30),
                MetricDefinition(id: DataType.bloodOxygen, title: "Blood Oxygen",
                                 unit: "%", color: .blue, aggregation: .latest,
                                 direction: .higherIsBetter, weight: 0.15),
                MetricDefinition(id: DataType.vo2Max, title: "VO₂ Max",
                                 unit: "mL/kg/min", color: .green, aggregation: .latest,
                                 direction: .higherIsBetter, weight: 0.25),
            ]
        )
    }

    /// Activity category: Steps, Distance
    static func activity() -> CategoryDashboardView {
        CategoryDashboardView(
            title: "Activity",
            icon: "figure.run",
            color: .green,
            metrics: [
                MetricDefinition(id: DataType.steps, title: "Steps",
                                 unit: "steps", color: .green, aggregation: .max,
                                 direction: .higherIsBetter, weight: 0.6),
                MetricDefinition(id: DataType.distance, title: "Distance",
                                 unit: "m", color: .orange, aggregation: .max,
                                 direction: .higherIsBetter, weight: 0.4),
            ]
        )
    }
}
