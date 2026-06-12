import SwiftUI

/// Full habit management view: today's checklist, stats, and add/edit.
struct HabitsView: View {
    @EnvironmentObject var habitStore: HabitStore
    @EnvironmentObject var workoutStore: WorkoutStore
    @EnvironmentObject var appWiring: AppWiring
    @State private var showAddHabit = false
    @State private var stats: [UUID: HabitStats] = [:]

    private let cal = Calendar.current

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                todaySection
                statsSection
            }
            .padding()
        }
        .background(Color(hex: 0x1a1a2e))
        .navigationTitle("Habits")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: { showAddHabit = true }) {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showAddHabit) {
            AddHabitView()
        }
        .onAppear {
            stats = appWiring.habitProvider?.computeAllStats() ?? [:]
        }
    }

    // MARK: - Today's Habits

    private var todaySection: some View {
        let today = cal.startOfDay(for: Date())
        let scheduled = habitStore.habits.filter { $0.isScheduled(on: today) }

        return VStack(alignment: .leading, spacing: 12) {
            Text("TODAY").font(.caption2).foregroundColor(.gray)

            if scheduled.isEmpty {
                Text("No habits scheduled today")
                    .font(.caption).foregroundColor(.gray)
                    .padding()
            } else {
                ForEach(scheduled) { habit in
                    NavigationLink(destination: HabitDetailView(habit: habit)) {
                        habitRow(habit)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(hex: 0x16213e))
        .cornerRadius(12)
    }

    private func habitRow(_ habit: Habit) -> some View {
        let log = habitStore.todayLogs.first(where: { $0.habitId == habit.id })
        let completed = log?.isCompleted ?? false
        let isAuto = log?.autoFulfilled ?? false

        return HStack(spacing: 12) {
            Button {
                if !isAuto {
                    habitStore.toggleCompletion(habitId: habit.id)
                }
            } label: {
                Image(systemName: completed ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundColor(completed ? Color(hex: habit.color) : .gray)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text(habit.name).font(.subheadline)
                    .strikethrough(completed, color: .gray)
                Text(habit.scheduleDescription)
                    .font(.caption2).foregroundColor(.gray)
            }

            Spacer()

            if isAuto {
                Image(systemName: "bolt.fill")
                    .font(.caption2).foregroundColor(.orange)
            }

            if let s = stats[habit.id], s.currentStreak > 0 {
                HStack(spacing: 2) {
                    Image(systemName: "flame.fill")
                        .font(.caption2).foregroundColor(.orange)
                    Text("\(s.currentStreak)")
                        .font(.caption2.monospacedDigit()).foregroundColor(.orange)
                }
            }
        }
    }

    // MARK: - Stats

    private var statsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("STREAKS & COMPLIANCE").font(.caption2).foregroundColor(.gray)

            ForEach(habitStore.habits) { habit in
                if let s = stats[habit.id] {
                    NavigationLink(destination: HabitDetailView(habit: habit)) {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Image(systemName: habit.icon)
                                    .foregroundColor(Color(hex: habit.color))
                                Text(habit.name).font(.subheadline)
                                Spacer()
                                HStack(spacing: 2) {
                                    Image(systemName: "flame.fill").foregroundColor(.orange)
                                    Text("\(s.currentStreak)").font(.subheadline.bold().monospacedDigit())
                                }
                            }

                            HStack(spacing: 16) {
                                complianceBar(label: "This week", value: s.weeklyCompliance,
                                              color: Color(hex: habit.color))
                                complianceBar(label: "This month", value: s.monthlyCompliance,
                                              color: Color(hex: habit.color))
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(hex: 0x16213e))
        .cornerRadius(12)
    }

    private func complianceBar(label: String, value: Double, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption2).foregroundColor(.gray)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.gray.opacity(0.2))
                    RoundedRectangle(cornerRadius: 3)
                        .fill(color)
                        .frame(width: geo.size.width * CGFloat(value))
                }
            }
            .frame(height: 6)
            Text(String(format: "%.0f%%", value * 100))
                .font(.caption2.monospacedDigit()).foregroundColor(.gray)
        }
    }
}

// MARK: - Add Habit Sheet

struct AddHabitView: View {
    @EnvironmentObject var habitStore: HabitStore
    @Environment(\.dismiss) var dismiss

    @State private var name = ""
    @State private var icon = "checkmark.circle"
    @State private var color = "4CAF50"
    @State private var category: Habit.Category = .general
    @State private var scheduleType: Habit.ScheduleType = .daily
    @State private var scheduleParam = 1
    @State private var linkedActivityType: String?
    @State private var weekdayBitmask = 0

    private let activityTypes = ["Run", "Walk", "Cycle", "Hike", "Swim", "Strength",
                                  "HIIT", "Yoga", "Core", "Flexibility"]
    private let iconOptions = ["checkmark.circle", "figure.run", "pill", "drop",
                                "bed.double", "brain.head.profile", "heart",
                                "dumbbell", "flame", "leaf"]
    private let colorOptions = ["4CAF50", "2196F3", "FF9800", "E91E63",
                                 "9C27B0", "00BCD4", "FF5722", "607D8B"]

    private struct SupplementPreset: Identifiable {
        let id = UUID()
        let name: String
        let icon: String
        let color: String
    }

    private let supplementPresets: [SupplementPreset] = [
        .init(name: "Creatine", icon: "pill", color: "2196F3"),
        .init(name: "Vitamin D", icon: "pill", color: "FF9800"),
        .init(name: "Omega-3", icon: "pill", color: "00BCD4"),
        .init(name: "Magnesium", icon: "pill", color: "9C27B0"),
        .init(name: "Protein Shake", icon: "drop", color: "4CAF50"),
        .init(name: "Multivitamin", icon: "pill", color: "E91E63"),
        .init(name: "Iron", icon: "pill", color: "FF5722"),
        .init(name: "B12", icon: "pill", color: "607D8B"),
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section("Category") {
                    Picker("Type", selection: $category) {
                        ForEach(Habit.Category.allCases, id: \.self) { c in
                            Text(c.label).tag(c)
                        }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color(hex: 0x16213e))
                }

                if category == .supplement {
                    Section("Quick Add") {
                        ForEach(supplementPresets) { preset in
                            Button {
                                name = preset.name
                                icon = preset.icon
                                color = preset.color
                                scheduleType = .daily
                                scheduleParam = 1
                                linkedActivityType = nil
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: preset.icon)
                                        .foregroundColor(Color(hex: preset.color))
                                    Text(preset.name).foregroundColor(.white)
                                }
                            }
                            .listRowBackground(Color(hex: 0x16213e))
                        }
                    }
                }

                Section("Habit") {
                    TextField("Name", text: $name)
                        .listRowBackground(Color(hex: 0x16213e))

                    // Icon picker
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(iconOptions, id: \.self) { ic in
                                Image(systemName: ic)
                                    .font(.title3)
                                    .foregroundColor(ic == icon ? Color(hex: color) : .gray)
                                    .onTapGesture { icon = ic }
                            }
                        }
                    }
                    .listRowBackground(Color(hex: 0x16213e))

                    // Color picker
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(colorOptions, id: \.self) { c in
                                Circle()
                                    .fill(Color(hex: c))
                                    .frame(width: 28, height: 28)
                                    .overlay(c == color ? Circle().stroke(.white, lineWidth: 2) : nil)
                                    .onTapGesture { color = c }
                            }
                        }
                    }
                    .listRowBackground(Color(hex: 0x16213e))
                }

                Section("Schedule") {
                    Picker("Type", selection: $scheduleType) {
                        ForEach(Habit.ScheduleType.allCases, id: \.self) { t in
                            Text(t.label).tag(t)
                        }
                    }
                    .listRowBackground(Color(hex: 0x16213e))

                    switch scheduleType {
                    case .daily:
                        EmptyView()
                    case .everyNDays:
                        Stepper("Every \(scheduleParam) days", value: $scheduleParam, in: 2...30)
                            .listRowBackground(Color(hex: 0x16213e))
                    case .xPerWeek:
                        Stepper("\(scheduleParam)× per week", value: $scheduleParam, in: 1...7)
                            .listRowBackground(Color(hex: 0x16213e))
                    case .specificDays:
                        HStack {
                            ForEach(Habit.weekdayBits, id: \.bit) { day in
                                let active = weekdayBitmask & day.bit != 0
                                Text(day.short)
                                    .font(.caption.bold())
                                    .frame(width: 32, height: 32)
                                    .background(active ? Color(hex: color) : Color.gray.opacity(0.2))
                                    .foregroundColor(active ? .white : .gray)
                                    .clipShape(Circle())
                                    .onTapGesture { weekdayBitmask ^= day.bit }
                            }
                        }
                        .listRowBackground(Color(hex: 0x16213e))
                    }
                }

                Section("Auto-Fulfillment") {
                    Picker("Link to workout", selection: $linkedActivityType) {
                        Text("Manual").tag(String?.none)
                        ForEach(activityTypes, id: \.self) { type in
                            Text(type).tag(Optional(type))
                        }
                    }
                    .listRowBackground(Color(hex: 0x16213e))

                    if linkedActivityType != nil {
                        Text("Auto-checked when a matching workout is recorded")
                            .font(.caption2).foregroundColor(.gray)
                            .listRowBackground(Color(hex: 0x16213e))
                    }
                }

                Section {
                    Button("Save Habit") {
                        let param: Int
                        switch scheduleType {
                        case .daily: param = 1
                        case .everyNDays, .xPerWeek: param = scheduleParam
                        case .specificDays: param = weekdayBitmask
                        }

                        let habit = Habit(
                            id: UUID(), name: name, icon: icon, color: color,
                            scheduleType: scheduleType, scheduleParam: param,
                            category: category,
                            linkedActivityType: linkedActivityType,
                            createdAt: Date(), archivedAt: nil, sortOrder: habitStore.habits.count
                        )
                        habitStore.save(habit)
                        dismiss()
                    }
                    .disabled(name.isEmpty)
                    .listRowBackground(Color(hex: 0x16213e))
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color(hex: 0x1a1a2e))
            .navigationTitle("New Habit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
