import SwiftUI

/// Scale measurement + body composition history
struct BodyTab: View {
    @EnvironmentObject var coordinator: DeviceCoordinator
    @EnvironmentObject var measurementStore: MeasurementStore

    private var scale: QNScaleDriver? { coordinator.scaleDriver }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    connectionStatus
                    liveReading
                    bodyHistory
                }
                .padding()
            }
            .background(Color(hex: 0x1a1a2e))
            .navigationTitle("Body")
        }
    }

    // MARK: - Connection

    private var connectionStatus: some View {
        HStack {
            Circle()
                .fill(scale != nil ? Color.green : Color.red)
                .frame(width: 10, height: 10)
            Text(scale?.scaleState.rawValue ?? "Scale not connected")
                .font(.subheadline)
            Spacer()
        }
        .padding()
        .background(Color(hex: 0x16213e))
        .cornerRadius(12)
    }

    // MARK: - Live

    private var liveReading: some View {
        VStack(spacing: 8) {
            if let s = scale {
                Text(s.liveWeight > 0 ? String(format: "%.1f", s.liveWeight) : "--.-")
                    .font(.system(size: 64, weight: .bold, design: .rounded))
                    .foregroundColor(s.isStable ? Color(hex: 0x4ecca3) : .white)
                Text("kg").font(.title3).foregroundColor(.gray)
                if s.isStable {
                    Label("Stable", systemImage: "checkmark.circle.fill")
                        .font(.caption).foregroundColor(.green)
                }
            } else {
                Text("--.-")
                    .font(.system(size: 64, weight: .bold, design: .rounded))
                    .foregroundColor(.gray)
                Text("kg").font(.title3).foregroundColor(.gray)
                Text("Step on the scale to measure")
                    .font(.caption).foregroundColor(.gray)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .background(Color(hex: 0x16213e))
        .cornerRadius(12)
    }

    // MARK: - History

    private var bodyHistory: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("BODY MEASUREMENTS").font(.caption2).foregroundColor(.gray)

            let bodyMeasurements = measurementStore.measurements(ofType: .bodyComp)
            if bodyMeasurements.isEmpty {
                Text("No measurements yet").font(.caption).foregroundColor(.gray).padding()
            } else {
                ForEach(bodyMeasurements) { m in
                    NavigationLink(destination: MeasurementDetailView(measurement: m)) {
                        HStack {
                            Image(systemName: "scalemass").foregroundColor(.green)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(m.dateString).font(.subheadline)
                                Text(m.summary).font(.caption).foregroundColor(.gray)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").foregroundColor(.gray)
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
