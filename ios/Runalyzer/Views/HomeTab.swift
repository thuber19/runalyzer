import SwiftUI
import Charts

/// Dashboard home page with Aura hero, action strip, and editorial feed.
struct HomeTab: View {
    @EnvironmentObject var measurementStore: MeasurementStore
    @EnvironmentObject var sourcePrefs: SourcePreferenceStore
    @EnvironmentObject var workoutStore: WorkoutStore
    @EnvironmentObject var habitStore: HabitStore
    @EnvironmentObject var fluidIntakeProvider: FluidIntakeProvider
    @EnvironmentObject var checkInProvider: CheckInProvider

    var metricIndex: MetricIndex { MetricIndex(store: measurementStore) }
    let cal = Calendar.current

    @State var showDrinkLog = false
    @State var showEveningCheckIn = false
    @State private var navigateToHabits = false
    @State private var navigateToHydration = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    // Zone 1: Aura Hero
                    let today = cal.startOfDay(for: Date())
                    let recovery = latestRecoveryScore(on: today)
                    let weekAgo = cal.date(byAdding: .day, value: -7, to: today)!
                    let sleepPoints = metricIndex.query(type: DataType.sleepScore,
                                                        measurementType: .derived,
                                                        from: weekAgo, to: Date())
                    let sleep = sleepPoints.last.map { $0.value }

                    let heartDef = CategoryDashboardView.heart()
                    let heartTrend = CategoryDashboardView.computeTrend(
                        metrics: heartDef.metrics, days: 30,
                        metricIndex: metricIndex, sourcePrefs: sourcePrefs)

                    let vibeScore = computeVibeScore(recovery: recovery, sleep: sleep)
                    let headline = generateHeadline(recovery: recovery, sleep: sleep,
                                                     heartTrend: heartTrend.direction)

                    NavigationLink {
                        RecoveryDashboardView()
                    } label: {
                        AuraHeroView(
                            vibeScore: vibeScore,
                            headline: headline,
                            recoveryScore: recovery,
                            sleepScore: sleep
                        )
                    }
                    .buttonStyle(.plain)

                    // Zone 2: Action Strip
                    let scheduled = habitStore.habits.filter { $0.isScheduled(on: today) }
                    let storedGoal = UserDefaults.standard.integer(forKey: "hydration_goal_ml")
                    let hydrationGoal = Double(storedGoal > 0 ? storedGoal : 2500)

                    ActionStripView(
                        habits: scheduled,
                        todayLogs: habitStore.todayLogs,
                        hydrationMl: fluidIntakeProvider.todayTotalMl,
                        hydrationGoal: hydrationGoal,
                        onToggleHabit: { habit in
                            _ = habitStore.toggleCompletion(habitId: habit.id)
                        },
                        onDrinkTap: { showDrinkLog = true },
                        onHabitsLongPress: { navigateToHabits = true },
                        onHydrationLongPress: { navigateToHydration = true }
                    )
                    .padding(.top, 16)

                    // Evening check-in banner
                    if isEveningAndCheckInPending {
                        eveningCheckInBanner
                            .padding(.horizontal, 16)
                            .padding(.top, 16)
                    }

                    // Zone 3: Editorial Feed
                    let insights = buildInsights()

                    EditorialFeedView(insights: insights)
                        .padding(.horizontal, 16)
                        .padding(.top, 16)
                        .padding(.bottom, 20)
                }
            }
            .background(Color(hex: 0x1a1a2e))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showDrinkLog = true } label: {
                        Image(systemName: "drop.fill")
                    }
                }
            }
            .sheet(isPresented: $showDrinkLog) {
                DrinkLogSheet()
            }
            .sheet(isPresented: $showEveningCheckIn) {
                EveningCheckInSheet()
            }
            .navigationDestination(isPresented: $navigateToHabits) {
                HabitsView()
            }
            .navigationDestination(isPresented: $navigateToHydration) {
                FluidDashboardView()
            }
        }
    }

    // MARK: - Helpers (used by HomeTiles extension)

    var isEveningAndCheckInPending: Bool {
        let hour = cal.component(.hour, from: Date())
        return hour >= 18 && !checkInProvider.eveningCheckInDoneToday
    }

    func recoveryColor(_ score: Double) -> Color {
        switch score {
        case 75...: return .green
        case 50...: return .cyan
        case 25...: return .orange
        default:    return .red
        }
    }

    func recoveryLabel(_ score: Double) -> String {
        switch score {
        case 75...: return "Excellent"
        case 50...: return "Good"
        case 25...: return "Fair"
        default:    return "Poor"
        }
    }

    func latestRecoveryScore(on day: Date) -> Double? {
        let dayStart = cal.startOfDay(for: day)
        guard let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart) else { return nil }
        return metricIndex.query(type: DataType.recoveryIndex, from: dayStart, to: dayEnd).first?.value
    }

    static func relativeDateLabel(_ date: Date) -> String {
        let days = Calendar.current.dateComponents([.day], from: date, to: Date()).day ?? 0
        if days == 0 { return "Today" }
        if days == 1 { return "Yesterday" }
        if days < 30 { return "\(days)d ago" }
        let months = days / 30
        return months == 1 ? "1 month ago" : "\(months) months ago"
    }

    func sleepScoreColor(_ score: Int) -> Color {
        switch score {
        case 75...: return .green
        case 50...: return .cyan
        case 25...: return .orange
        default:    return .red
        }
    }

    func formatMinutes(_ m: Double) -> String {
        let h = Int(m) / 60, min = Int(m) % 60
        return h > 0 ? String(format: "%dh %02dm", h, min) : String(format: "%dm", min)
    }
}
