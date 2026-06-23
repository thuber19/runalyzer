import Foundation
import Combine
import os

/// Receives wellness session payloads from the watchOS companion app
/// and saves them as SensorMeasurements.
///
/// Provider pattern: trigger (WCSession receive) → data (decode JSON) → save (MeasurementStore).
class WellnessSyncProvider: ObservableObject {
    private weak var measurementStore: MeasurementStore?

    init(measurementStore: MeasurementStore) {
        self.measurementStore = measurementStore
    }

    /// Called by WatchConnectivityManager when a wellness_session payload arrives.
    func handleWatchPayload(_ payload: [String: Any]) {
        guard let sessionDict = payload["session"] as? [String: Any],
              let idString = sessionDict["id"] as? String,
              let sessionID = UUID(uuidString: idString),
              let dateInterval = sessionDict["date"] as? TimeInterval,
              let roundsArray = sessionDict["rounds"] as? [[String: Any]] else {
            AppLogger.watch.error("Invalid wellness session payload")
            return
        }

        let sessionDate = Date(timeIntervalSince1970: dateInterval)

        // Build DataPoints from rounds
        var dataPoints: [DataPoint] = []
        for roundDict in roundsArray {
            guard let typeString = roundDict["type"] as? String,
                  let startInterval = roundDict["startDate"] as? TimeInterval,
                  let endInterval = roundDict["endDate"] as? TimeInterval else { continue }

            let start = Date(timeIntervalSince1970: startInterval)
            let end = Date(timeIntervalSince1970: endInterval)
            let durationSec = end.timeIntervalSince(start)

            dataPoints.append(DataPoint(
                timestamp: start,
                endTimestamp: end,
                type: DataType.saunaRound,
                value: durationSec,
                unit: typeString,
                source: "watch:apple_watch",
                role: .primary
            ))
        }

        // Summary data points
        let totalDuration = dataPoints.reduce(0) { $0 + $1.value }
        dataPoints.append(DataPoint(
            timestamp: sessionDate, endTimestamp: nil,
            type: DataType.saunaTotalRounds, value: Double(roundsArray.count),
            unit: "count", source: "watch:apple_watch", role: .detail
        ))
        dataPoints.append(DataPoint(
            timestamp: sessionDate, endTimestamp: nil,
            type: DataType.saunaTotalDuration, value: totalDuration,
            unit: "sec", source: "watch:apple_watch", role: .detail
        ))

        // Cold exposure: sum duration of cold_plunge rounds
        let coldSec = dataPoints
            .filter { $0.type == DataType.saunaRound && $0.unit == WellnessRoundType.coldPlunge.rawValue }
            .reduce(0) { $0 + $1.value }
        if coldSec > 0 {
            dataPoints.append(DataPoint(
                timestamp: sessionDate, endTimestamp: nil,
                type: DataType.coldExposureDuration, value: coldSec,
                unit: "sec", source: "watch:apple_watch", role: .detail
            ))
        }

        let measurement = SensorMeasurement(
            id: sessionID,
            date: sessionDate,
            type: .wellnessSession,
            sources: [.watchApp],
            dataPoints: dataPoints,
            rawDataFiles: []
        )

        measurementStore?.save(measurement)
        AppLogger.watch.info("Saved wellness session \(sessionID) with \(roundsArray.count) rounds")
    }
}
