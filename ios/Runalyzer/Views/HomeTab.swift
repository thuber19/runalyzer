import SwiftUI
import Charts

/// Dashboard home page with health overview tiles.
struct HomeTab: View {
    @EnvironmentObject var measurementStore: MeasurementStore
    @EnvironmentObject var sourcePrefs: SourcePreferenceStore
    @EnvironmentObject var workoutStore: WorkoutStore
    @EnvironmentObject var habitStore: HabitStore
    @EnvironmentObject var fluidIntakeProvider: FluidIntakeProvider
    @EnvironmentObject var checkInProvider: CheckInProvider

    var metricIndex: MetricIndex { MetricIndex(store: measurementStore) }
    let cal = Calendar.current

    @State var showLabEntry = false
    @State var showDrinkLog = false
    @State var showEveningCheckIn = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    // Evening check-in banner (shows after 6 PM if not done)
                    if isEveningAndCheckInPending {
                        eveningCheckInBanner
                    }

                    // Today
                    Text("TODAY").font(.caption2.bold()).foregroundColor(.gray)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    HStack(spacing: 12) { recoveryTile; sleepTile }

                    HStack(spacing: 12) { habitsTile; hydrationTile }

                    // Trends
                    Text("TRENDS").font(.caption2.bold()).foregroundColor(.gray)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 4)

                    HStack(spacing: 12) { heartTile; activityTile }

                    HStack(spacing: 12) { recoveryActivitiesTile; bodyCompTile }

                    HStack(spacing: 12) { workoutsTile; labResultsTile }
                }
                .padding()
            }
            .background(Color(hex: 0x1a1a2e))
            .navigationTitle("Home")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 12) {
                        Button { showDrinkLog = true } label: {
                            Image(systemName: "drop.fill")
                        }
                        Button { showLabEntry = true } label: {
                            Image(systemName: "cross.case")
                        }
                    }
                }
            }
            .sheet(isPresented: $showLabEntry) {
                LabResultsEntrySheet()
            }
            .sheet(isPresented: $showDrinkLog) {
                DrinkLogSheet()
            }
            .sheet(isPresented: $showEveningCheckIn) {
                EveningCheckInSheet()
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
