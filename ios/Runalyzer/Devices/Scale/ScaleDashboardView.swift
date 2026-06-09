import SwiftUI

struct ScaleDashboardView: View {
    @EnvironmentObject var coordinator: DeviceCoordinator
    @EnvironmentObject var measurementStore: MeasurementStore
    @EnvironmentObject var appWiring: AppWiring

    private var scale: QNScaleDriver? { coordinator.scaleDriver }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    connectionStatus
                    liveReading
                    if let m = appWiring.scaleProvider?.lastMeasurement {
                        bodyCompCard(m)
                    }
                    recentMeasurements
                }
                .padding()
            }
            .background(Color(hex: 0x1a1a2e))
            .navigationTitle("Body Scale")
        }
    }

    // MARK: - Connection

    private var connectionStatus: some View {
        HStack {
            Circle()
                .fill(scale != nil ? Color.green : Color.red)
                .frame(width: 10, height: 10)
            Text(scale?.scaleState.rawValue ?? "Not connected")
                .font(.subheadline)
            Spacer()
        }
        .padding()
        .background(Color(hex: 0x16213e))
        .cornerRadius(12)
    }

    // MARK: - Live Reading

    private var liveReading: some View {
        VStack(spacing: 8) {
            if let s = scale {
                Text(s.liveWeight > 0 ? String(format: "%.2f", s.liveWeight) : "--:--")
                    .font(.system(size: 64, weight: .bold, design: .rounded))
                    .foregroundColor(s.isStable ? Color(hex: 0x4ecca3) : .white)
                Text("kg")
                    .font(.title3).foregroundColor(.gray)
                if s.isStable {
                    Label("Stable", systemImage: "checkmark.circle.fill")
                        .font(.caption).foregroundColor(.green)
                }
            } else {
                Text("--:--")
                    .font(.system(size: 64, weight: .bold, design: .rounded))
                    .foregroundColor(.gray)
                Text("kg")
                    .font(.title3).foregroundColor(.gray)
                Text("Connect scale to measure")
                    .font(.caption).foregroundColor(.gray)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .background(Color(hex: 0x16213e))
        .cornerRadius(12)
    }

    // MARK: - Body Composition Card

    private func bodyCompCard(_ m: ScaleMeasurement) -> some View {
        VStack(spacing: 12) {
            Text("BODY COMPOSITION").font(.caption2).foregroundColor(.gray)

            if !m.hasImpedance {
                Text("Weight only — bare feet required for body composition")                                                                                                                                                                                               
                    .font(.caption).foregroundColor(.orange).multilineTextAlignment(.center)
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                compMetric(label: "Body Fat", value: m.bodyFatPercent.map { String(format: "%.2f%%", $0) } ?? "N/A",
                          icon: "flame.fill", color: .orange)
                compMetric(label: "Muscle", value: m.muscleMassKg.map { String(format: "%.2f kg", $0) } ?? "N/A",
                          icon: "figure.strengthtraining.traditional", color: .blue)
                compMetric(label: "BMI", value: String(format: "%.2f", m.bmi),
                          icon: "heart.text.square", color: .pink)
                compMetric(label: "Body Water", value: m.bodyWaterPercent.map { String(format: "%.2f%%", $0) } ?? "N/A",
                          icon: "drop.fill", color: .cyan)
                compMetric(label: "Fat-Free Mass", value: m.fatFreeMassKg.map { String(format: "%.2f kg", $0) } ?? "N/A",
                          icon: "figure.run", color: .green)
                compMetric(label: "BMR", value: m.bmrKcal.map { String(format: "%.0f kcal", $0) } ?? "N/A",
                          icon: "bolt.fill", color: .yellow)
            }

            Text("Impedance: \(Int(m.impedanceOhm)) Ω")
                .font(.caption2).foregroundColor(.gray)
        }
        .padding()
        .background(Color(hex: 0x16213e))
        .cornerRadius(12)
    }

    private func compMetric(label: String, value: String, icon: String, color: Color) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon).foregroundColor(color)
            Text(value).font(.headline.monospacedDigit())
            Text(label).font(.caption2).foregroundColor(.gray)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(Color(hex: 0x1a1a2e))
        .cornerRadius(8)
    }

    // MARK: - Recent Measurements

    private var recentMeasurements: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("RECENT MEASUREMENTS").font(.caption2).foregroundColor(.gray)

            let scaleEntries = measurementStore.measurements(ofType: .bodyComp)
            if scaleEntries.isEmpty {
                Text("No measurements yet").font(.caption).foregroundColor(.gray).padding()
            } else {
                ForEach(scaleEntries.prefix(10)) { entry in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.dateString).font(.subheadline)
                            Text(entry.summary).font(.caption).foregroundColor(.gray)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .padding()
        .background(Color(hex: 0x16213e))
        .cornerRadius(12)
    }
}
