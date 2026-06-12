import SwiftUI

/// Detail view for a single habit showing a calendar heat-map of completions and stats.
struct HabitDetailView: View {
    @EnvironmentObject var habitStore: HabitStore
    @EnvironmentObject var appWiring: AppWiring

    let habit: Habit

    @State private var logs: [HabitLog] = []
    @State private var stats: HabitStats?
    @State private var displayedMonth = Date()

    private let cal = Calendar.current
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)
    private let dayLabels = ["M", "T", "W", "T", "F", "S", "S"]

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                headerCard
                calendarCard
                statsCard
            }
            .padding()
        }
        .background(Color(hex: 0x1a1a2e))
        .navigationTitle(habit.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { loadData() }
    }

    // MARK: - Header

    private var headerCard: some View {
        HStack(spacing: 14) {
            Image(systemName: habit.icon)
                .font(.title)
                .foregroundColor(Color(hex: habit.color))

            VStack(alignment: .leading, spacing: 4) {
                Text(habit.name).font(.headline)
                Text(habit.scheduleDescription)
                    .font(.caption).foregroundColor(.gray)
                if habit.category == .supplement {
                    Text("Supplement")
                        .font(.caption2).foregroundColor(Color(hex: habit.color))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color(hex: habit.color).opacity(0.2))
                        .cornerRadius(4)
                }
            }

            Spacer()

            if let s = stats, s.currentStreak > 0 {
                VStack(spacing: 2) {
                    Image(systemName: "flame.fill")
                        .font(.title2).foregroundColor(.orange)
                    Text("\(s.currentStreak)")
                        .font(.title3.bold().monospacedDigit())
                        .foregroundColor(.orange)
                }
            }
        }
        .padding()
        .background(Color(hex: 0x16213e))
        .cornerRadius(12)
    }

    // MARK: - Calendar Grid

    private var calendarCard: some View {
        VStack(spacing: 12) {
            // Month navigation
            HStack {
                Button { shiftMonth(-1) } label: {
                    Image(systemName: "chevron.left")
                }
                Spacer()
                Text(monthYearString(displayedMonth))
                    .font(.subheadline.bold())
                Spacer()
                Button { shiftMonth(1) } label: {
                    Image(systemName: "chevron.right")
                }
                .disabled(cal.isDate(displayedMonth, equalTo: Date(), toGranularity: .month))
            }
            .foregroundColor(.white)

            // Day-of-week header
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(dayLabels, id: \.self) { label in
                    Text(label)
                        .font(.caption2.bold())
                        .foregroundColor(.gray)
                        .frame(maxWidth: .infinity)
                }
            }

            // Calendar cells
            let cells = calendarCells(for: displayedMonth)
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(cells) { cell in
                    calendarCell(cell)
                }
            }
        }
        .padding()
        .background(Color(hex: 0x16213e))
        .cornerRadius(12)
    }

    private func calendarCell(_ cell: CalendarCell) -> some View {
        Group {
            if let day = cell.day {
                let completed = cell.completed
                let scheduled = cell.scheduled
                let isFuture = cell.isFuture

                Text("\(day)")
                    .font(.caption2.monospacedDigit())
                    .frame(width: 32, height: 32)
                    .foregroundColor(isFuture ? .gray.opacity(0.3) : completed ? .white : .gray)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(cellColor(completed: completed, scheduled: scheduled, isFuture: isFuture))
                    )
            } else {
                Text("")
                    .frame(width: 32, height: 32)
            }
        }
    }

    private func cellColor(completed: Bool, scheduled: Bool, isFuture: Bool) -> Color {
        if isFuture { return .clear }
        if completed { return Color(hex: habit.color) }
        if scheduled { return Color(hex: habit.color).opacity(0.15) }
        return .clear
    }

    // MARK: - Stats Card

    private var statsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("STATISTICS").font(.caption2).foregroundColor(.gray)

            if let s = stats {
                HStack(spacing: 20) {
                    statItem(label: "Current", value: "\(s.currentStreak)", icon: "flame.fill")
                    statItem(label: "Longest", value: "\(s.longestStreak)", icon: "trophy.fill")
                }

                HStack(spacing: 16) {
                    complianceBar(label: "This week", value: s.weeklyCompliance)
                    complianceBar(label: "This month", value: s.monthlyCompliance)
                }
            } else {
                Text("No data yet").font(.caption).foregroundColor(.gray)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(hex: 0x16213e))
        .cornerRadius(12)
    }

    private func statItem(label: String, value: String, icon: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon).foregroundColor(.orange)
            Text(value).font(.title2.bold().monospacedDigit())
            Text(label).font(.caption2).foregroundColor(.gray)
        }
        .frame(maxWidth: .infinity)
    }

    private func complianceBar(label: String, value: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption2).foregroundColor(.gray)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.gray.opacity(0.2))
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color(hex: habit.color))
                        .frame(width: geo.size.width * CGFloat(value))
                }
            }
            .frame(height: 6)
            Text(String(format: "%.0f%%", value * 100))
                .font(.caption2.monospacedDigit()).foregroundColor(.gray)
        }
    }

    // MARK: - Data

    private func loadData() {
        let lookback = cal.date(byAdding: .day, value: -90, to: Date()) ?? Date()
        logs = habitStore.logs(for: habit.id, from: lookback, to: Date())
        stats = appWiring.habitProvider?.computeAllStats()[habit.id]
    }

    private func shiftMonth(_ delta: Int) {
        if let newMonth = cal.date(byAdding: .month, value: delta, to: displayedMonth) {
            displayedMonth = newMonth
        }
    }

    private func monthYearString(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MMMM yyyy"
        return f.string(from: date)
    }

    // MARK: - Calendar Cell Model

    private struct CalendarCell: Identifiable {
        let id: Int // position index
        let day: Int?
        let completed: Bool
        let scheduled: Bool
        let isFuture: Bool
    }

    private func calendarCells(for month: Date) -> [CalendarCell] {
        let comps = cal.dateComponents([.year, .month], from: month)
        guard let monthStart = cal.date(from: comps),
              let range = cal.range(of: .day, in: .month, for: monthStart) else { return [] }

        // Monday=0 offset
        let firstWeekday = cal.component(.weekday, from: monthStart)
        let offset = (firstWeekday + 5) % 7 // Mon=0, Tue=1, ..., Sun=6

        let completedDates = Set(
            logs.filter(\.isCompleted).map { cal.startOfDay(for: $0.date) }
        )
        let today = cal.startOfDay(for: Date())

        var cells: [CalendarCell] = []

        // Leading blanks
        for i in 0..<offset {
            cells.append(CalendarCell(id: i, day: nil, completed: false, scheduled: false, isFuture: false))
        }

        // Day cells
        for day in range {
            let index = cells.count
            guard let date = cal.date(bySetting: .day, value: day, of: monthStart) else { continue }
            let dayStart = cal.startOfDay(for: date)
            let completed = completedDates.contains(dayStart)
            let scheduled = habit.isScheduled(on: dayStart)
            let isFuture = dayStart > today
            cells.append(CalendarCell(id: index, day: day, completed: completed,
                                       scheduled: scheduled, isFuture: isFuture))
        }

        return cells
    }
}
