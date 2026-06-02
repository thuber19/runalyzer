import SwiftUI

/// Combined live dashboard + workout history
struct RunalyzerTab: View {
    @EnvironmentObject var coordinator: DeviceCoordinator
    @EnvironmentObject var metrics: RunMetrics
    @EnvironmentObject var measurementStore: MeasurementStore

    private var imu: IMUSensorDriver? { coordinator.imuDriver }
    private var isConnected: Bool { imu != nil }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    // Live section
                    LiveDashboardView()

                    // Workout history
                    workoutHistory
                }
                .padding()
            }
            .background(Color(hex: 0x1a1a2e))
            .navigationTitle("Runalyzer")
        }
    }

    private var workoutHistory: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("WORKOUT HISTORY").font(.caption2).foregroundColor(.gray)

            let workouts = measurementStore.measurements(ofType: .workout)
            if workouts.isEmpty {
                Text("No recordings yet. Connect your sensor and start recording.")
                    .font(.caption).foregroundColor(.gray)
                    .padding()
            } else {
                ForEach(workouts) { m in
                    NavigationLink(destination: MeasurementDetailView(measurement: m)) {
                        HStack {
                            Image(systemName: m.icon).foregroundColor(Color(hex: 0xe94560))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(m.dateString).font(.subheadline)
                                Text(m.summary).font(.caption).foregroundColor(.gray)
                            }
                            Spacer()
                            Text(m.sourceLabel).font(.caption2).foregroundColor(.gray)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .padding()
        .background(Color(hex: 0x16213e))
        .cornerRadius(12)
    }
}
