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
    /// Which measurement type to query. Defaults to `.metric` (HealthKit imports).
    var queryMeasurementType: MeasurementType = .metric

    @EnvironmentObject var measurementStore: MeasurementStore
    @EnvironmentObject var sourcePrefs: SourcePreferenceStore
    @State private var timeRange: CategoryRange = .day

    enum CategoryRange: String, CaseIterable {
        case day = "1D", week = "7D", month = "30D", quarter = "90D", year = "1Y"
        var days: Int {
            switch self {
            case .day: return 1
            case .week: return 7
            case .month: return 30
            case .quarter: return 90
            case .year: return 365
            }
        }
        var isDaily: Bool { self == .day }
    }

    private var metricIndex: MetricIndex { MetricIndex(store: measurementStore) }
    private let cal = Calendar.current

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                rangePicker
                if timeRange.isDaily {
                    dailyTiles
                } else {
                    trendHeader
                    periodTiles
                }
            }
            .padding()
        }
        .background(Color(hex: 0x1a1a2e))
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - 1D: Full-width tiles with today's value + vs 7-day avg

    private var dailyTiles: some View {
        let today = cal.startOfDay(for: Date())
        let weekAgo = cal.date(byAdding: .day, value: -7, to: today) ?? today
        let monthAgo = cal.date(byAdding: .day, value: -30, to: today) ?? today

        return ForEach(metrics) { metric in
            let todayPoints = metricIndex.query(type: metric.id, measurementType: queryMeasurementType,
                                                from: today, to: Date(), filter: sourcePrefs)
            let todayVal = dailyValue(todayPoints, metric: metric)

            // 7-day average for comparison badge
            let weekPoints = metricIndex.query(type: metric.id, measurementType: queryMeasurementType,
                                               from: weekAgo, to: today, filter: sourcePrefs)
            let weekDaily = toDailyValues(weekPoints, metric: metric)
            let weekAvg = weekDaily.isEmpty ? nil :
                weekDaily.map(\.value).reduce(0, +) / Double(weekDaily.count)

            // 30-day sparkline
            let monthPoints = metricIndex.query(type: metric.id, measurementType: queryMeasurementType,
                                                from: monthAgo, to: Date(), filter: sourcePrefs)
            let monthDaily = toDailyValues(monthPoints, metric: metric)
            let sparkline = monthDaily.map(\.value)

            let badge: DashboardTile<MetricTrendView>.Badge? = {
                guard let today = todayVal, let avg = weekAvg, avg > 0 else { return nil }
                let pct = ((today - avg) / avg) * 100
                let isHealthy: Bool
                switch metric.direction {
                case .higherIsBetter: isHealthy = pct >= 0
                case .lowerIsBetter:  isHealthy = pct <= 0
                }
                let color: Color = abs(pct) < 1 ? .gray : (isHealthy ? .green : .orange)
                return .init(text: String(format: "%+.0f%% vs 7D avg", pct), color: color)
            }()

            DashboardTile(
                title: metric.title.uppercased(),
                value: formatValue(todayVal, metric: metric),
                unit: formatUnit(metric),
                period: "Today",
                badge: badge,
                sparklineValues: sparkline.count > 1 ? sparkline : nil,
                sparklineColor: metric.color
            ) {
                MetricTrendView(metricType: metric.id, title: metric.title,
                                unit: metric.unit, color: metric.color)
            }
        }
    }

    // MARK: - Period: Trend header + full-width tiles with averages

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

    private var periodTiles: some View {
        let lookback = cal.date(byAdding: .day, value: -timeRange.days, to: Date()) ?? Date()

        return ForEach(metrics) { metric in
            let points = metricIndex.query(type: metric.id, measurementType: queryMeasurementType,
                                           from: lookback, to: Date(), filter: sourcePrefs)
            let daily = toDailyValues(points, metric: metric)
            let sparkline = daily.map(\.value)
            let avg = daily.isEmpty ? nil :
                daily.map(\.value).reduce(0, +) / Double(daily.count)

            let change = percentChange(sparkline)
            let badge: DashboardTile<MetricTrendView>.Badge? = change.map { pct in
                let isHealthy: Bool
                switch metric.direction {
                case .higherIsBetter: isHealthy = pct >= 0
                case .lowerIsBetter:  isHealthy = pct <= 0
                }
                let color: Color = abs(pct) < 1 ? .gray : (isHealthy ? .green : .orange)
                return .init(text: String(format: "%+.1f%%", pct), color: color)
            }

            DashboardTile(
                title: metric.title.uppercased(),
                value: formatValue(avg, metric: metric),
                unit: formatUnit(metric),
                detail: "avg/day",
                period: timeRange.rawValue,
                badge: badge,
                sparklineValues: sparkline.count > 1 ? sparkline : nil,
                sparklineColor: metric.color
            ) {
                MetricTrendView(metricType: metric.id, title: metric.title,
                                unit: metric.unit, color: metric.color)
            }
        }
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
            let points = metricIndex.query(type: metric.id, measurementType: queryMeasurementType,
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

    /// Get today's single value for a metric.
    private func dailyValue(_ points: [DataPoint], metric: MetricDefinition) -> Double? {
        guard !points.isEmpty else { return nil }
        let vals = points.map(\.value)
        switch metric.aggregation {
        case .max:          return vals.max()
        case .dailyAverage: return vals.reduce(0, +) / Double(vals.count)
        case .latest:       return vals.last
        }
    }

    // MARK: - Formatting

    private func formatValue(_ value: Double?, metric: MetricDefinition) -> String {
        guard let v = value else { return "--" }
        switch metric.id {
        case DataType.distance:
            if v >= 1000 {
                return String(format: "%.1f", v / 1000)
            }
            return String(format: "%.0f", v)
        case DataType.bloodOxygen:
            return String(format: "%.0f", v * 100)
        case DataType.vo2Max:
            return String(format: "%.1f", v)
        case DataType.respiratoryRate:
            return String(format: "%.1f", v)
        case DataType.wristTemperature:
            return String(format: "%+.1f", v)
        default:
            return String(format: "%.0f", v)
        }
    }

    /// Unit string — adjusts for distance (m vs km).
    private func formatUnit(_ metric: MetricDefinition) -> String {
        if metric.id == DataType.distance {
            let lookback: Date
            if timeRange.isDaily {
                lookback = cal.startOfDay(for: Date())
            } else {
                lookback = cal.date(byAdding: .day, value: -timeRange.days, to: Date()) ?? Date()
            }
            let points = metricIndex.query(type: metric.id, measurementType: queryMeasurementType,
                                           from: lookback, to: Date(), filter: sourcePrefs)
            let val: Double
            if timeRange.isDaily {
                val = dailyValue(points, metric: metric) ?? 0
            } else {
                let daily = toDailyValues(points, metric: metric)
                val = daily.isEmpty ? 0 : daily.map(\.value).reduce(0, +) / Double(daily.count)
            }
            return val >= 1000 ? "km" : "m"
        }
        return metric.unit
    }

    // MARK: - Range Picker

    private var rangePicker: some View {
        Picker("Range", selection: $timeRange) {
            ForEach(CategoryRange.allCases, id: \.self) { r in
                Text(r.rawValue).tag(r)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal)
    }

    // MARK: - Helpers

    private func percentChange(_ values: [Double]) -> Double? {
        guard values.count >= 4 else { return nil }
        return HealthScore.regressionPercentChange(values)
    }
}

// MARK: - Predefined Categories

extension CategoryDashboardView {

    /// Heart category: RHR, HRV, SpO2, VO2 Max, Respiratory Rate, Walking HR
    static func heart() -> CategoryDashboardView {
        CategoryDashboardView(
            title: "Heart",
            icon: "heart.fill",
            color: .red,
            metrics: [
                MetricDefinition(id: DataType.restingHeartRate, title: "Resting HR",
                                 unit: "bpm", color: .red, aggregation: .latest,
                                 direction: .lowerIsBetter, weight: 0.25),
                MetricDefinition(id: DataType.hrvSDNN, title: "HRV (SDNN)",
                                 unit: "ms", color: .purple, aggregation: .dailyAverage,
                                 direction: .higherIsBetter, weight: 0.25),
                MetricDefinition(id: DataType.bloodOxygen, title: "Blood Oxygen",
                                 unit: "%", color: .blue, aggregation: .latest,
                                 direction: .higherIsBetter, weight: 0.10),
                MetricDefinition(id: DataType.vo2Max, title: "VO₂ Max",
                                 unit: "mL/kg/min", color: .green, aggregation: .latest,
                                 direction: .higherIsBetter, weight: 0.15),
                MetricDefinition(id: DataType.respiratoryRate, title: "Resp. Rate",
                                 unit: "br/min", color: .cyan, aggregation: .dailyAverage,
                                 direction: .lowerIsBetter, weight: 0.15),
                MetricDefinition(id: DataType.walkingHeartRateAvg, title: "Walking HR",
                                 unit: "bpm", color: .orange, aggregation: .latest,
                                 direction: .lowerIsBetter, weight: 0.10),
            ]
        )
    }

    /// Blood work / lab results category
    static func bloodWork() -> CategoryDashboardView {
        CategoryDashboardView(
            title: "Blood Work",
            icon: "cross.case",
            color: .red,
            metrics: [
                MetricDefinition(id: DataType.glucose, title: "Glucose",
                                 unit: "mg/dL", color: .orange, aggregation: .latest,
                                 direction: .lowerIsBetter, weight: 0.15),
                MetricDefinition(id: DataType.hemoglobinA1C, title: "HbA1C",
                                 unit: "%", color: .red, aggregation: .latest,
                                 direction: .lowerIsBetter, weight: 0.15),
                MetricDefinition(id: DataType.ldlCholesterol, title: "LDL",
                                 unit: "mg/dL", color: .red, aggregation: .latest,
                                 direction: .lowerIsBetter, weight: 0.15),
                MetricDefinition(id: DataType.hdlCholesterol, title: "HDL",
                                 unit: "mg/dL", color: .green, aggregation: .latest,
                                 direction: .higherIsBetter, weight: 0.10),
                MetricDefinition(id: DataType.triglycerides, title: "Triglycerides",
                                 unit: "mg/dL", color: .yellow, aggregation: .latest,
                                 direction: .lowerIsBetter, weight: 0.10),
                MetricDefinition(id: DataType.totalCholesterol, title: "Total Chol.",
                                 unit: "mg/dL", color: .orange, aggregation: .latest,
                                 direction: .lowerIsBetter, weight: 0.05),
                MetricDefinition(id: DataType.ferritin, title: "Ferritin",
                                 unit: "ng/mL", color: .brown, aggregation: .latest,
                                 direction: .higherIsBetter, weight: 0.05),
                MetricDefinition(id: DataType.vitaminD, title: "Vitamin D",
                                 unit: "ng/mL", color: .yellow, aggregation: .latest,
                                 direction: .higherIsBetter, weight: 0.05),
                MetricDefinition(id: DataType.hemoglobin, title: "Hemoglobin",
                                 unit: "g/dL", color: .red, aggregation: .latest,
                                 direction: .higherIsBetter, weight: 0.05),
                MetricDefinition(id: DataType.creatinine, title: "Creatinine",
                                 unit: "mg/dL", color: .purple, aggregation: .latest,
                                 direction: .lowerIsBetter, weight: 0.05),
                MetricDefinition(id: DataType.tsh, title: "TSH",
                                 unit: "mIU/L", color: .cyan, aggregation: .latest,
                                 weight: 0.05),
                MetricDefinition(id: DataType.crp, title: "CRP",
                                 unit: "mg/L", color: .pink, aggregation: .latest,
                                 direction: .lowerIsBetter, weight: 0.05),
            ],
            queryMeasurementType: .labResults
        )
    }

    /// Activity category: Steps, Distance, Active Energy
    static func activity() -> CategoryDashboardView {
        CategoryDashboardView(
            title: "Activity",
            icon: "figure.run",
            color: .green,
            metrics: [
                MetricDefinition(id: DataType.steps, title: "Steps",
                                 unit: "steps", color: .green, aggregation: .max,
                                 direction: .higherIsBetter, weight: 0.40),
                MetricDefinition(id: DataType.distance, title: "Distance",
                                 unit: "m", color: .orange, aggregation: .max,
                                 direction: .higherIsBetter, weight: 0.30),
                MetricDefinition(id: DataType.activeEnergy, title: "Active Energy",
                                 unit: "kcal", color: .red, aggregation: .max,
                                 direction: .higherIsBetter, weight: 0.30),
            ]
        )
    }
}
