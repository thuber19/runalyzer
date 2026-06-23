import SwiftUI

/// Horizontal scroll of interactive habit and hydration pills.
struct ActionStripView: View {
    let habits: [Habit]
    let todayLogs: [HabitLog]
    let hydrationMl: Double
    let hydrationGoal: Double
    let onToggleHabit: (Habit) -> Void
    let onDrinkTap: () -> Void
    let onHabitsLongPress: () -> Void
    let onHydrationLongPress: () -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                // Hydration pill
                Button {
                    onDrinkTap()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "drop.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.cyan)
                        Text("\(Int(hydrationMl))")
                            .font(.subheadline.bold().monospacedDigit())
                            .foregroundStyle(hydrationMl >= hydrationGoal ? .cyan : .white)
                        Text("/ \(Int(hydrationGoal))")
                            .font(.caption2)
                            .foregroundStyle(.gray)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color(hex: 0x16213e))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .onLongPressGesture { onHydrationLongPress() }

                // Habit pills
                ForEach(habits) { habit in
                    let done = todayLogs.contains { $0.habitId == habit.id && $0.isCompleted }
                    Button {
                        onToggleHabit(habit)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 12))
                                .foregroundStyle(done ? Color(hex: habit.color) : .gray)
                            Text(habit.name)
                                .font(.caption)
                                .foregroundStyle(done ? .white : .gray)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(done
                            ? Color(hex: habit.color).opacity(0.15)
                            : Color(hex: 0x16213e))
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .onLongPressGesture { onHabitsLongPress() }
                }
            }
            .padding(.horizontal, 16)
        }
    }
}
