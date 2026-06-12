import Foundation

/// A recurring health habit (e.g. "Run 3x/week", "Take vitamins daily").
struct Habit: Identifiable, Sendable {
    let id: UUID
    var name: String
    var icon: String
    var color: String
    var scheduleType: ScheduleType
    var scheduleParam: Int
    var category: Category
    var linkedActivityType: String?   // matches Workout.activityType for auto-fulfillment; nil = manual
    var createdAt: Date
    var archivedAt: Date?
    var sortOrder: Int

    enum Category: String, Codable, CaseIterable {
        case general
        case supplement

        var label: String {
            switch self {
            case .general: return "General"
            case .supplement: return "Supplement"
            }
        }
    }

    enum ScheduleType: String, Codable, CaseIterable {
        case daily
        case everyNDays
        case xPerWeek
        case specificDays

        var label: String {
            switch self {
            case .daily: return "Daily"
            case .everyNDays: return "Every N Days"
            case .xPerWeek: return "X Times per Week"
            case .specificDays: return "Specific Days"
            }
        }
    }

    /// Weekday bitmask constants for specificDays schedule.
    /// Calendar weekday: Sun=1..Sat=7. Bitmask: Mon=1, Tue=2, Wed=4, Thu=8, Fri=16, Sat=32, Sun=64.
    static let weekdayBits: [(name: String, short: String, bit: Int)] = [
        ("Monday", "M", 1), ("Tuesday", "T", 2), ("Wednesday", "W", 4),
        ("Thursday", "T", 8), ("Friday", "F", 16), ("Saturday", "S", 32), ("Sunday", "S", 64)
    ]

    var isAutoFulfilled: Bool { linkedActivityType != nil }
    var isArchived: Bool { archivedAt != nil }

    /// Returns true if this habit is scheduled for `date`.
    func isScheduled(on date: Date, calendar: Calendar = .current) -> Bool {
        switch scheduleType {
        case .daily:
            return true
        case .everyNDays:
            guard scheduleParam > 0 else { return true }
            let daysSinceCreation = calendar.dateComponents([.day],
                from: calendar.startOfDay(for: createdAt),
                to: calendar.startOfDay(for: date)).day ?? 0
            return daysSinceCreation >= 0 && daysSinceCreation % scheduleParam == 0
        case .xPerWeek:
            // xPerWeek habits show every day; compliance is checked at the week level
            return true
        case .specificDays:
            let weekday = calendar.component(.weekday, from: date) // Sun=1..Sat=7
            // Map calendar weekday to our bitmask: Mon=1..Sun=64
            let bitIndex = (weekday + 5) % 7  // Sun=6, Mon=0, Tue=1, ..., Sat=5
            let bit = 1 << bitIndex
            return scheduleParam & bit != 0
        }
    }

    /// Human-readable schedule description.
    var scheduleDescription: String {
        switch scheduleType {
        case .daily:
            return "Every day"
        case .everyNDays:
            return scheduleParam == 2 ? "Every other day" : "Every \(scheduleParam) days"
        case .xPerWeek:
            return "\(scheduleParam)× per week"
        case .specificDays:
            let dayNames = Self.weekdayBits.filter { scheduleParam & $0.bit != 0 }.map(\.short)
            return dayNames.joined(separator: ", ")
        }
    }
}

/// A single day's log entry for a habit.
struct HabitLog: Identifiable, Sendable {
    let id: Int64
    let habitId: UUID
    let date: Date           // start of day
    var completedAt: Date?
    var autoFulfilled: Bool
    var workoutId: UUID?
    var source: Source

    enum Source: String, Codable {
        case manual
        case auto
    }

    var isCompleted: Bool { completedAt != nil }
}
