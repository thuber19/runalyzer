import Foundation
import os

/// Self-contained provider for habit auto-fulfillment and stats computation.
/// Trigger: app foreground (after HealthKit import completes).
/// Pipeline: check workouts → match to linked habits → auto-fulfill → compute stats.
class HabitProvider {
    private weak var habitStore: HabitStore?
    private weak var workoutStore: WorkoutStore?

    init(habitStore: HabitStore, workoutStore: WorkoutStore) {
        self.habitStore = habitStore
        self.workoutStore = workoutStore
    }

    // MARK: - Auto-Fulfillment

    /// For each habit with a linkedActivityType, check if a matching workout exists
    /// for the relevant period and auto-mark the habit as fulfilled.
    func processAutoFulfillment() {
        guard let habitStore, let workoutStore else { return }
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())

        let autoHabits = habitStore.habits.filter { $0.isAutoFulfilled && !$0.isArchived }
        guard !autoHabits.isEmpty else { return }

        for habit in autoHabits {
            guard let activityType = habit.linkedActivityType else { continue }

            // Determine which dates to check
            let datesToCheck: [Date]
            switch habit.scheduleType {
            case .xPerWeek:
                // Check all days this week
                var dates: [Date] = []
                let weekStart = startOfWeek(for: today, calendar: cal)
                for i in 0..<7 {
                    if let d = cal.date(byAdding: .day, value: i, to: weekStart), d <= today {
                        dates.append(d)
                    }
                }
                datesToCheck = dates
            default:
                // Just today
                datesToCheck = habit.isScheduled(on: today) ? [today] : []
            }

            for date in datesToCheck {
                // Skip if already completed
                let existingLogs = habitStore.logs(for: habit.id, from: date,
                    to: cal.date(byAdding: .day, value: 1, to: date) ?? date)
                if existingLogs.contains(where: { $0.isCompleted }) { continue }

                // Find matching workout on this date
                let dayEnd = cal.date(byAdding: .day, value: 1, to: date) ?? date
                let matchingWorkout = workoutStore.workouts.first { w in
                    w.activityType == activityType &&
                    w.startDate >= date && w.startDate < dayEnd
                }

                if let workout = matchingWorkout {
                    habitStore.markAutoFulfilled(habitId: habit.id, date: date, workoutId: workout.id)
                    AppLogger.health.info("Auto-fulfilled '\(habit.name)' from \(activityType) workout")
                }
            }
        }
    }

    // MARK: - Stats

    /// Compute stats for all active habits.
    func computeAllStats() -> [UUID: HabitStats] {
        guard let habitStore else { return [:] }
        let cal = Calendar.current
        // Fetch 90 days of logs for streak computation
        let lookback = cal.date(byAdding: .day, value: -90, to: Date()) ?? Date()
        let allLogs = habitStore.allLogs(from: lookback, to: Date())

        var result: [UUID: HabitStats] = [:]
        for habit in habitStore.habits {
            let habitLogs = allLogs.filter { $0.habitId == habit.id }
            result[habit.id] = HabitStreak.computeStats(habit: habit, logs: habitLogs)
        }
        return result
    }

    // MARK: - Helpers

    private func startOfWeek(for date: Date, calendar: Calendar) -> Date {
        var cal = calendar
        cal.firstWeekday = 2 // Monday
        let comps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return cal.date(from: comps) ?? date
    }
}
