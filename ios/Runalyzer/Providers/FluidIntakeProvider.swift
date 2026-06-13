import Foundation
import Combine
import GRDB
import os

/// Provider for fluid/drink intake logging.
/// Handles creating measurements from drink templates and tracking daily totals.
class FluidIntakeProvider: ObservableObject {
    @Published var todayDrinks: [SensorMeasurement] = []

    private weak var measurementStore: MeasurementStore?
    private let db: AppDatabase
    private var cancellable: AnyDatabaseCancellable?

    init(measurementStore: MeasurementStore, db: AppDatabase? = nil) {
        self.measurementStore = measurementStore
        self.db = db ?? AppDatabase.shared
        startObservation()
    }

    // MARK: - Reactive Observation

    private func startObservation() {
        let todayStart = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
        let tomorrowStart = todayStart + 86400

        let obs = ValueObservation.tracking { db -> [SensorMeasurement] in
            let records = try MeasurementRecord
                .filter(Column("type") == MeasurementType.fluidIntake.rawValue)
                .filter(Column("date") >= todayStart && Column("date") < tomorrowStart)
                .order(Column("date").desc)
                .fetchAll(db)

            // Load data points for each drink to display category/volume
            var result: [SensorMeasurement] = []
            for record in records {
                let sources = try MeasurementSourceRecord
                    .filter(Column("measurementId") == record.id)
                    .fetchAll(db)
                    .map { $0.toModel() }
                let dps = try DataPointRecord
                    .filter(Column("measurementId") == record.id)
                    .fetchAll(db)
                    .map { $0.toModel() }
                result.append(record.toModel(sources: sources, dataPoints: dps))
            }
            return result
        }

        cancellable = obs.start(
            in: db.dbQueue,
            scheduling: .immediate,
            onError: { error in
                AppLogger.health.error("Fluid intake observation error: \(error.localizedDescription)")
            },
            onChange: { [weak self] drinks in
                DispatchQueue.main.async { self?.todayDrinks = drinks }
            }
        )
    }

    // MARK: - Computed Totals

    var todayTotalMl: Double {
        todayDrinks.flatMap(\.dataPoints)
            .filter { $0.type == DataType.fluidVolume }
            .reduce(0) { $0 + $1.value }
    }

    var todayAlcoholUnits: Double {
        todayDrinks.flatMap(\.dataPoints)
            .filter { $0.type == DataType.alcoholUnits }
            .reduce(0) { $0 + $1.value }
    }

    var todayCaffeineTotal: Double {
        todayDrinks.flatMap(\.dataPoints)
            .filter { $0.type == DataType.caffeineContent }
            .reduce(0) { $0 + $1.value }
    }

    // MARK: - Log Drink

    @discardableResult
    func logDrink(template: DrinkTemplate, volumeMl: Int? = nil, timestamp: Date = Date()) -> Bool {
        guard let store = measurementStore else { return false }

        let volume = Double(volumeMl ?? template.defaultVolumeMl)
        let volumeRatio = volume / Double(template.defaultVolumeMl)

        var dataPoints: [DataPoint] = [
            DataPoint(timestamp: timestamp, endTimestamp: nil,
                      type: DataType.fluidVolume, value: volume,
                      unit: "mL", source: "manual", role: .primary),
            DataPoint(timestamp: timestamp, endTimestamp: nil,
                      type: DataType.fluidCategory, value: 0,
                      unit: template.category.rawValue, source: "manual", role: .detail),
        ]

        if template.caffeineContentMg > 0 {
            dataPoints.append(DataPoint(
                timestamp: timestamp, endTimestamp: nil,
                type: DataType.caffeineContent,
                value: Double(template.caffeineContentMg) * volumeRatio,
                unit: "mg", source: "manual", role: .detail))
        }

        if template.alcoholPercent > 0 {
            let units = volume * (template.alcoholPercent / 100.0) * 0.789 / 10.0
            dataPoints.append(DataPoint(
                timestamp: timestamp, endTimestamp: nil,
                type: DataType.alcoholUnits, value: units,
                unit: "drinks", source: "manual", role: .detail))
        }

        let measurement = SensorMeasurement(
            id: UUID(), date: timestamp, type: .fluidIntake,
            sources: [.manualEntry],
            dataPoints: dataPoints,
            rawDataFiles: [])

        let saved = store.save(measurement)
        if saved {
            AppLogger.health.info("Logged drink: \(template.name) \(Int(volume)) mL")
        }
        return saved
    }

    @discardableResult
    func deleteDrink(_ id: UUID) -> Bool {
        guard let store = measurementStore else { return false }
        return store.delete(id)
    }
}
