import Foundation

/// Shared aggregation helpers for trend views.
enum MetricAggregator {

    struct DailyAggregate: Identifiable {
        let id: Date
        let date: Date
        let avg: Double
        let min: Double
        let max: Double
        let count: Int

        init(date: Date, values: [Double]) {
            self.id = date
            self.date = date
            self.avg = values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
            self.min = values.min() ?? 0
            self.max = values.max() ?? 0
            self.count = values.count
        }
    }

    struct PeriodStats {
        let avg: Double
        let min: Double
        let max: Double
        let trend: Double  // % change: positive = improving (context-dependent)
        let count: Int
    }

    // MARK: - Aggregation

    /// Group DataPoints by calendar day → daily avg/min/max.
    static func dailyAggregates(_ points: [DataPoint]) -> [DailyAggregate] {
        let cal = Calendar.current
        var byDay: [Date: [Double]] = [:]
        for p in points {
            let day = cal.startOfDay(for: p.timestamp)
            byDay[day, default: []].append(p.value)
        }
        return byDay.keys.sorted().map { day in
            DailyAggregate(date: day, values: byDay[day] ?? [])
        }
    }

    /// Group DataPoints by ISO week → weekly avg/min/max.
    static func weeklyAggregates(_ points: [DataPoint]) -> [DailyAggregate] {
        let cal = Calendar.current
        var byWeek: [Date: [Double]] = [:]
        for p in points {
            // Start of week (Monday)
            let comps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: p.timestamp)
            if let weekStart = cal.date(from: comps) {
                byWeek[weekStart, default: []].append(p.value)
            }
        }
        return byWeek.keys.sorted().map { week in
            DailyAggregate(date: week, values: byWeek[week] ?? [])
        }
    }

    /// Compute period stats + trend direction.
    /// Trend = % change from first half avg to second half avg.
    static func periodStats(_ points: [DataPoint]) -> PeriodStats {
        let values = points.map(\.value)
        guard !values.isEmpty else {
            return PeriodStats(avg: 0, min: 0, max: 0, trend: 0, count: 0)
        }

        let avg = values.reduce(0, +) / Double(values.count)
        let mid = values.count / 2
        let firstHalf = Array(values.prefix(mid))
        let secondHalf = Array(values.suffix(values.count - mid))
        let firstAvg = firstHalf.isEmpty ? avg : firstHalf.reduce(0, +) / Double(firstHalf.count)
        let secondAvg = secondHalf.isEmpty ? avg : secondHalf.reduce(0, +) / Double(secondHalf.count)
        let trend = firstAvg > 0 ? ((secondAvg - firstAvg) / firstAvg) * 100 : 0

        return PeriodStats(
            avg: avg,
            min: values.min() ?? 0,
            max: values.max() ?? 0,
            trend: trend,
            count: values.count
        )
    }

    // MARK: - Formatting

    private static let dayFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "E, d MMM"
        return f
    }()

    private static let weekFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "d MMM"
        return f
    }()

    static func formatDay(_ date: Date) -> String { dayFmt.string(from: date) }
    static func formatWeek(_ date: Date) -> String { "w/o \(weekFmt.string(from: date))" }
}
