import Foundation

/// Read-only query layer across all measurements. Searches DataPoints by type
/// regardless of which measurement or source device they came from.
/// No storage of its own — reads directly from MeasurementStore.
struct MetricIndex {
    let store: MeasurementStore

    // MARK: - Query DataPoints

    /// All DataPoints of the given type within the date range, sorted chronologically.
    func query(type: String, from startDate: Date, to endDate: Date) -> [DataPoint] {
        store.measurements
            .flatMap { m in m.dataPoints.filter {
                $0.type == type && $0.timestamp >= startDate && $0.timestamp <= endDate
            }}
            .sorted { $0.timestamp < $1.timestamp }
    }

    /// DataPoints filtered to a specific MeasurementType (e.g., only .metric measurements).
    func query(type: String, measurementType: MeasurementType,
               from startDate: Date, to endDate: Date) -> [DataPoint] {
        store.measurements
            .filter { $0.type == measurementType }
            .flatMap { m in m.dataPoints.filter {
                $0.type == type && $0.timestamp >= startDate && $0.timestamp <= endDate
            }}
            .sorted { $0.timestamp < $1.timestamp }
    }

    // MARK: - Query Measurements

    /// All measurements containing at least one DataPoint of the given type, in date range.
    func measurements(containingType type: String,
                      from startDate: Date, to endDate: Date) -> [SensorMeasurement] {
        store.measurements
            .filter { m in
                m.date >= startDate && m.date <= endDate &&
                m.dataPoints.contains { $0.type == type }
            }
            .sorted { $0.date < $1.date }
    }

    /// Find the single .metric measurement for a given day and DataPoint type.
    /// Used by HealthKitMetricProvider for intraday upsert.
    func metricMeasurement(forDay date: Date, containingType type: String) -> SensorMeasurement? {
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: date)
        guard let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart) else { return nil }
        return store.measurements.first { m in
            m.type == .metric &&
            m.date >= dayStart && m.date < dayEnd &&
            m.dataPoints.contains { $0.type == type }
        }
    }
}
