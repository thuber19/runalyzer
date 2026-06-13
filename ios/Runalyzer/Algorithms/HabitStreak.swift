import Foundation

/// Statistics for a single habit computed from its log history.
struct HabitStats {
    let currentStreak: Int
    let longestStreak: Int
    let weeklyCompliance: Double    // 0.0–1.0
    let monthlyCompliance: Double   // 0.0–1.0
}

/// Pure computation of habit streaks and compliance. No state, no I/O.
enum HabitStreak {

    /// Compute stats for a single habit from its logs.
    static func computeStats(habit: Habit, logs: [HabitLog],
                             referenceDate: Date = Date(),
                             calendar: Calendar = .current) -> HabitStats {
        let completedDates = Set(logs.filter(\.isCompleted).map { calendar.startOfDay(for: $0.date) })

        let current = currentStreak(habit: habit, completedDates: completedDates,
                                    referenceDate: referenceDate, calendar: calendar)
        let longest = longestStreak(habit: habit, completedDates: completedDates, calendar: calendar)
        let weekly = weeklyCompliance(habit: habit, completedDates: completedDates,
                                      referenceDate: referenceDate, calendar: calendar)
        let monthly = monthlyCompliance(habit: habit, completedDates: completedDates,
                                         referenceDate: referenceDate, calendar: calendar)

        return HabitStats(currentStreak: current, longestStreak: longest,
                          weeklyCompliance: weekly, monthlyCompliance: monthly)
    }

    // MARK: - Streak

    /// Current streak: consecutive scheduled-and-completed days ending at referenceDate.
    /// For xPerWeek, counts whole weeks where the target was met.
    static func currentStreak(habit: Habit, completedDates: Set<Date>,
                              referenceDate: Date, calendar: Calendar = .current) -> Int {
        if habit.scheduleType == .xPerWeek {
            return weekStreak(habit: habit, completedDates: completedDates,
                              referenceDate: referenceDate, calendar: calendar)
        }

        var streak = 0
        var cursor = calendar.startOfDay(for: referenceDate)
        let earliest = calendar.startOfDay(for: habit.createdAt)

        while cursor >= earliest {
            if habit.isScheduled(on: cursor, calendar: calendar) {
                if completedDates.contains(cursor) {
                    streak += 1
                } else {
                    break
                }
            }
            guard let prev = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = prev
        }
        return streak
    }

    /// Longest streak ever achieved.
    static func longestStreak(habit: Habit, completedDates: Set<Date>,
                              calendar: Calendar = .current) -> Int {
        guard !completedDates.isEmpty else { return 0 }
        let sorted = completedDates.sorted()

        if habit.scheduleType == .xPerWeek {
            return longestWeekStreak(habit: habit, completedDates: completedDates, calendar: calendar)
        }

        var longest = 0
        var current = 0
        guard let first = sorted.first, let last = sorted.last else { return 0 }
        var cursor = first

        while cursor <= last {
            if habit.isScheduled(on: cursor, calendar: calendar) {
                if completedDates.contains(cursor) {
                    current += 1
                    longest = max(longest, current)
                } else {
                    current = 0
                }
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return longest
    }

    // MARK: - Week-based streaks (for xPerWeek)

    private static func weekStreak(habit: Habit, completedDates: Set<Date>,
                                   referenceDate: Date, calendar: Calendar) -> Int {
        var streak = 0
        var weekStart = startOfWeek(for: referenceDate, calendar: calendar)
        let target = habit.scheduleParam

        while true {
            guard let weekEnd = calendar.date(byAdding: .day, value: 6, to: weekStart) else { break }
            let count = completedDates.filter { $0 >= weekStart && $0 <= weekEnd }.count
            if count >= target {
                streak += 1
            } else {
                break
            }
            guard let prev = calendar.date(byAdding: .day, value: -7, to: weekStart) else { break }
            weekStart = prev
        }
        return streak
    }

    private static func longestWeekStreak(habit: Habit, completedDates: Set<Date>,
                                          calendar: Calendar) -> Int {
        guard let earliest = completedDates.min(), let latest = completedDates.max() else { return 0 }
        let target = habit.scheduleParam
        var longest = 0, current = 0
        var weekStart = startOfWeek(for: earliest, calendar: calendar)

        while weekStart <= latest {
            guard let weekEnd = calendar.date(byAdding: .day, value: 6, to: weekStart) else { break }
            let count = completedDates.filter { $0 >= weekStart && $0 <= weekEnd }.count
            if count >= target {
                current += 1
                longest = max(longest, current)
            } else {
                current = 0
            }
            guard let next = calendar.date(byAdding: .day, value: 7, to: weekStart) else { break }
            weekStart = next
        }
        return longest
    }

    private static func startOfWeek(for date: Date, calendar: Calendar) -> Date {
        var cal = calendar
        cal.firstWeekday = 2 // Monday
        let comps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return cal.date(from: comps) ?? date
    }

    // MARK: - Compliance

    /// Compliance this week: completed / scheduled (or completed / target for xPerWeek).
    static func weeklyCompliance(habit: Habit, completedDates: Set<Date>,
                                 referenceDate: Date, calendar: Calendar = .current) -> Double {
        let weekStart = startOfWeek(for: referenceDate, calendar: calendar)
        guard let weekEnd = calendar.date(byAdding: .day, value: 6, to: weekStart) else { return 0 }

        if habit.scheduleType == .xPerWeek {
            let count = completedDates.filter { $0 >= weekStart && $0 <= weekEnd }.count
            return habit.scheduleParam > 0 ? min(1.0, Double(count) / Double(habit.scheduleParam)) : 1.0
        }

        var scheduled = 0, completed = 0
        var cursor = weekStart
        while cursor <= min(weekEnd, calendar.startOfDay(for: referenceDate)) {
            if habit.isScheduled(on: cursor, calendar: calendar) {
                scheduled += 1
                if completedDates.contains(cursor) { completed += 1 }
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return scheduled > 0 ? Double(completed) / Double(scheduled) : 1.0
    }

    /// Compliance this month.
    static func monthlyCompliance(habit: Habit, completedDates: Set<Date>,
                                  referenceDate: Date, calendar: Calendar = .current) -> Double {
        let comps = calendar.dateComponents([.year, .month], from: referenceDate)
        guard let monthStart = calendar.date(from: comps) else { return 0 }

        if habit.scheduleType == .xPerWeek {
            // Count full weeks in the month and total completions
            let weeksInMonth = 4 // approximate
            let count = completedDates.filter { $0 >= monthStart && $0 <= referenceDate }.count
            let target = habit.scheduleParam * weeksInMonth
            return target > 0 ? min(1.0, Double(count) / Double(target)) : 1.0
        }

        var scheduled = 0, completed = 0
        var cursor = monthStart
        let today = calendar.startOfDay(for: referenceDate)
        while cursor <= today {
            if habit.isScheduled(on: cursor, calendar: calendar) {
                scheduled += 1
                if completedDates.contains(cursor) { completed += 1 }
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return scheduled > 0 ? Double(completed) / Double(scheduled) : 1.0
    }
}
