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
        VStack(alignment: .leading, spacing: 0) {
            let workouts = measurementStore.measurements(ofType: .workout)
            if workouts.isEmpty {
                Text("No recordings yet. Connect your sensor and start recording.")
                    .foregroundColor(.gray)
                    .padding()
            } else {
                ForEach(workouts) { m in
                    NavigationLink(destination: MeasurementDetailView(measurement: m)) {
                        HStack(spacing: 12) {
                            Image(systemName: m.icon).foregroundColor(Color(hex: 0xe94560)).frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(m.dateString).font(.subheadline)
                                Text(m.summary).font(.caption).foregroundColor(.gray)
                                Text(m.sourceLabel).font(.caption2).foregroundColor(.cyan)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").foregroundColor(.gray).font(.caption2)
                        }
                        .padding(.horizontal).padding(.vertical, 10)
                    }
                    .buttonStyle(.plain)
                    if m.id != workouts.last?.id {
                        Divider().background(Color.gray.opacity(0.2)).padding(.leading, 48)
                    }
                }
            }
        }
        .background(Color(hex: 0x16213e))
        .cornerRadius(12)
    }
}
