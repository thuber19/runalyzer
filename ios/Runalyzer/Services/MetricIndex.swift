import Foundation
import GRDB

/// Read-only query layer across all measurements. Uses SQL queries for
/// indexed lookups instead of in-memory array scanning.
struct MetricIndex {
    let store: MeasurementStore

    // MARK: - Query DataPoints

    /// All DataPoints of the given type within the date range, sorted chronologically.
    func query(type: String, from startDate: Date, to endDate: Date) -> [DataPoint] {
        store.queryDataPoints(
            sql: """
                SELECT * FROM data_point
                WHERE type = ? AND timestamp >= ? AND timestamp <= ?
                ORDER BY timestamp
                """,
            arguments: [type, startDate.timeIntervalSince1970, endDate.timeIntervalSince1970]
        )
    }

    /// DataPoints filtered to a specific MeasurementType (e.g., only .metric measurements).
    func query(type: String, measurementType: MeasurementType,
               from startDate: Date, to endDate: Date) -> [DataPoint] {
        store.queryDataPoints(
            sql: """
                SELECT dp.* FROM data_point dp
                JOIN measurement m ON dp.measurementId = m.id
                WHERE dp.type = ? AND m.type = ?
                  AND dp.timestamp >= ? AND dp.timestamp <= ?
                ORDER BY dp.timestamp
                """,
            arguments: [
                type, measurementType.rawValue,
                startDate.timeIntervalSince1970, endDate.timeIntervalSince1970
            ]
        )
    }

    // MARK: - Source-filtered Query (dashboard / analysis)

    /// DataPoints filtered to enabled sources only.
    func query(type: String, from startDate: Date, to endDate: Date,
               filter sourcePrefs: SourcePreferenceStore) -> [DataPoint] {
        sourcePrefs.apply(to: query(type: type, from: startDate, to: endDate), dataType: type)
    }

    /// DataPoints filtered to a specific MeasurementType AND enabled sources only.
    func query(type: String, measurementType: MeasurementType,
               from startDate: Date, to endDate: Date,
               filter sourcePrefs: SourcePreferenceStore) -> [DataPoint] {
        sourcePrefs.apply(
            to: query(type: type, measurementType: measurementType, from: startDate, to: endDate),
            dataType: type
        )
    }

    // MARK: - Query Measurements

    /// All measurements containing at least one DataPoint of the given type, in date range.
    func measurements(containingType type: String,
                      from startDate: Date, to endDate: Date) -> [SensorMeasurement] {
        store.measurements
            .filter { m in m.date >= startDate && m.date <= endDate }
            .filter { m in
                // Check via SQL whether this measurement has DataPoints of the given type
                let count = store.queryDataPoints(
                    sql: "SELECT * FROM data_point WHERE measurementId = ? AND type = ? LIMIT 1",
                    arguments: [m.id.uuidString, type]
                ).count
                return count > 0
            }
            .sorted { $0.date < $1.date }
    }

    /// Find the single .metric measurement for a given day and DataPoint type.
    /// Used by HealthKitMetricProvider for intraday upsert.
    func metricMeasurement(forDay date: Date, containingType type: String) -> SensorMeasurement? {
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: date)
        guard let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart) else { return nil }

        // Find a .metric measurement for this day that has DataPoints of the given type
        let candidates = store.measurements.filter { m in
            m.type == .metric && m.date >= dayStart && m.date < dayEnd
        }
        for m in candidates {
            let hasType = !store.queryDataPoints(
                sql: "SELECT * FROM data_point WHERE measurementId = ? AND type = ? LIMIT 1",
                arguments: [m.id.uuidString, type]
            ).isEmpty
            if hasType {
                // Return full measurement with DataPoints loaded
                return store.fullMeasurement(byID: m.id)
            }
        }
        return nil
    }
}
