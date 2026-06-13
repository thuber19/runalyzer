import Foundation
import Combine
import GRDB
import UserNotifications
import os

/// Tags for evening check-in — stored as individual DataPoints.
enum CheckInTag: String, CaseIterable, Sendable {
    case stress
    case sore
    case sick
    case travel
    case menstruation
    case poorSleep
    case lateNight

    var label: String {
        switch self {
        case .stress:       return "Stressed"
        case .sore:         return "Sore"
        case .sick:         return "Sick"
        case .travel:       return "Travel"
        case .menstruation: return "Menstruation"
        case .poorSleep:    return "Poor Sleep"
        case .lateNight:    return "Late Night"
        }
    }

    var icon: String {
        switch self {
        case .stress:       return "brain.head.profile"
        case .sore:         return "figure.cooldown"
        case .sick:         return "facemask"
        case .travel:       return "airplane"
        case .menstruation: return "circle.dotted"
        case .poorSleep:    return "moon.zzz"
        case .lateNight:    return "moon.stars"
        }
    }
}

/// Provider for morning/evening subjective check-ins.
/// Tracks whether today's check-ins are done and handles notification scheduling.
class CheckInProvider: ObservableObject {
    @Published var morningCheckInDoneToday = false
    @Published var eveningCheckInDoneToday = false
    @Published var todayMorningScore: Int?
    @Published var todayEveningScore: Int?

    private weak var measurementStore: MeasurementStore?
    private let db: AppDatabase
    private var cancellable: AnyDatabaseCancellable?

    // Notification identifiers
    private static let morningNotificationID = "checkin_morning"
    private static let eveningNotificationID = "checkin_evening"

    init(measurementStore: MeasurementStore, db: AppDatabase? = nil) {
        self.measurementStore = measurementStore
        self.db = db ?? AppDatabase.shared
        startObservation()
    }

    // MARK: - Reactive Observation

    private func startObservation() {
        let todayStart = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
        let tomorrowStart = todayStart + 86400

        let obs = ValueObservation.tracking { db -> (morning: Double?, evening: Double?) in
            // Check for morning readiness check-in today
            let morningRow = try Row.fetchOne(db, sql: """
                SELECT dp.value FROM data_point dp
                JOIN measurement m ON m.id = dp.measurementId
                WHERE m.type = ? AND m.date >= ? AND m.date < ? AND dp.type = ?
                LIMIT 1
                """, arguments: [MeasurementType.checkIn.rawValue, todayStart, tomorrowStart,
                                 DataType.morningReadiness])
            let morningScore = morningRow?["value"] as Double?

            // Check for evening energy check-in today
            let eveningRow = try Row.fetchOne(db, sql: """
                SELECT dp.value FROM data_point dp
                JOIN measurement m ON m.id = dp.measurementId
                WHERE m.type = ? AND m.date >= ? AND m.date < ? AND dp.type = ?
                LIMIT 1
                """, arguments: [MeasurementType.checkIn.rawValue, todayStart, tomorrowStart,
                                 DataType.eveningEnergy])
            let eveningScore = eveningRow?["value"] as Double?

            return (morning: morningScore, evening: eveningScore)
        }

        cancellable = obs.start(
            in: db.dbQueue,
            scheduling: .immediate,
            onError: { error in
                AppLogger.health.error("Check-in observation error: \(error.localizedDescription)")
            },
            onChange: { [weak self] result in
                DispatchQueue.main.async {
                    self?.morningCheckInDoneToday = result.morning != nil
                    self?.eveningCheckInDoneToday = result.evening != nil
                    self?.todayMorningScore = result.morning.map { Int($0) }
                    self?.todayEveningScore = result.evening.map { Int($0) }
                }
            }
        )
    }

    // MARK: - Save Check-ins

    @discardableResult
    func saveMorningCheckIn(readiness: Int) -> Bool {
        guard let store = measurementStore else { return false }
        let now = Date()

        let measurement = SensorMeasurement(
            id: UUID(), date: now, type: .checkIn,
            sources: [.manualEntry],
            dataPoints: [
                DataPoint(timestamp: now, endTimestamp: nil,
                          type: DataType.morningReadiness, value: Double(readiness),
                          unit: "score", source: "manual", role: .primary)
            ],
            rawDataFiles: [])

        let saved = store.save(measurement)
        if saved {
            AppLogger.health.info("Morning check-in saved: readiness=\(readiness)")
        }
        return saved
    }

    @discardableResult
    func saveEveningCheckIn(energy: Int, tags: Set<CheckInTag>) -> Bool {
        guard let store = measurementStore else { return false }
        let now = Date()

        var dataPoints: [DataPoint] = [
            DataPoint(timestamp: now, endTimestamp: nil,
                      type: DataType.eveningEnergy, value: Double(energy),
                      unit: "score", source: "manual", role: .primary)
        ]

        for tag in tags {
            dataPoints.append(DataPoint(
                timestamp: now, endTimestamp: nil,
                type: DataType.checkInTag, value: 1.0,
                unit: tag.rawValue, source: "manual", role: .detail))
        }

        let measurement = SensorMeasurement(
            id: UUID(), date: now, type: .checkIn,
            sources: [.manualEntry],
            dataPoints: dataPoints,
            rawDataFiles: [])

        let saved = store.save(measurement)
        if saved {
            AppLogger.health.info("Evening check-in saved: energy=\(energy), tags=\(tags.map(\.rawValue))")
        }
        return saved
    }

    // MARK: - Notifications

    func scheduleNotifications() {
        let center = UNUserNotificationCenter.current()

        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            guard granted else {
                if let error {
                    AppLogger.health.error("Notification permission denied: \(error.localizedDescription)")
                }
                return
            }
            self.updateScheduledNotifications()
        }
    }

    func updateScheduledNotifications() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [
            Self.morningNotificationID, Self.eveningNotificationID
        ])

        let defaults = UserDefaults.standard

        // Morning reminder
        if defaults.object(forKey: "checkin_morning_enabled") == nil || defaults.bool(forKey: "checkin_morning_enabled") {
            let hour = defaults.object(forKey: "checkin_morning_hour") != nil
                ? defaults.integer(forKey: "checkin_morning_hour") : 7
            let minute = defaults.integer(forKey: "checkin_morning_minute")

            var morningTime = DateComponents()
            morningTime.hour = hour
            morningTime.minute = minute

            let content = UNMutableNotificationContent()
            content.title = "Morning Check-in"
            content.body = "How rested do you feel today?"
            content.sound = .default

            let trigger = UNCalendarNotificationTrigger(dateMatching: morningTime, repeats: true)
            center.add(UNNotificationRequest(
                identifier: Self.morningNotificationID,
                content: content, trigger: trigger))
        }

        // Evening reminder
        if defaults.bool(forKey: "checkin_evening_enabled") {
            let hour = defaults.object(forKey: "checkin_evening_hour") != nil
                ? defaults.integer(forKey: "checkin_evening_hour") : 20
            let minute = defaults.integer(forKey: "checkin_evening_minute")

            var eveningTime = DateComponents()
            eveningTime.hour = hour
            eveningTime.minute = minute

            let content = UNMutableNotificationContent()
            content.title = "Evening Check-in"
            content.body = "How was your energy today?"
            content.sound = .default

            let trigger = UNCalendarNotificationTrigger(dateMatching: eveningTime, repeats: true)
            center.add(UNNotificationRequest(
                identifier: Self.eveningNotificationID,
                content: content, trigger: trigger))
        }
    }
}
