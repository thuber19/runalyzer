import SwiftUI

/// Combined live dashboard + workout history
struct RunalyzerTab: View {
    @EnvironmentObject var coordinator: DeviceCoordinator
    @EnvironmentObject var metrics: RunMetrics
    @EnvironmentObject var workoutStore: WorkoutStore

    private var imu: IMUSensorDriver? { coordinator.imuDriver }
    private var isConnected: Bool { imu != nil }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    // Live section
                    LiveDashboardView()

                    // Workout history (IMU recordings)
                    workoutHistory
                }
                .padding()
            }
            .background(Color(hex: 0x1a1a2e))
            .navigationTitle("Runalyzer")
        }
    }

    private var workoutHistory: some View {
        let imuWorkouts = workoutStore.workouts.filter { $0.activityType == "IMU Recording" }

        return VStack(alignment: .leading, spacing: 0) {
            if imuWorkouts.isEmpty {
                Text("No recordings yet. Connect your sensor and start recording.")
                    .foregroundColor(.gray)
                    .padding()
            } else {
                ForEach(imuWorkouts) { w in
                    HStack(spacing: 12) {
                        Image(systemName: w.icon).foregroundColor(Color(hex: 0xe94560)).frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(w.dateString).font(.subheadline)
                            Text(w.summary).font(.caption).foregroundColor(.gray)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").foregroundColor(.gray).font(.caption2)
                    }
                    .padding(.horizontal).padding(.vertical, 10)

                    if w.id != imuWorkouts.last?.id {
                        Divider().background(Color.gray.opacity(0.2)).padding(.leading, 48)
                    }
                }
            }
        }
        .background(Color(hex: 0x16213e))
        .cornerRadius(12)
    }
}
