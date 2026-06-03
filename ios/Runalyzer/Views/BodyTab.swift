import SwiftUI
import UIKit

/// Scale measurement + body composition history
struct BodyTab: View {
    @EnvironmentObject var coordinator: DeviceCoordinator
    @EnvironmentObject var measurementStore: MeasurementStore

    private var scale: QNScaleDriver? { coordinator.scaleDriver }

    @State private var showMeasuring = false
    @State private var measureComplete = false

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
            .overlay {
                if showMeasuring { measurementOverlay }
            }
            .onChange(of: scale?.scaleState) { _, newState in
                if newState == .measuring || newState == .stable {
                    withAnimation { showMeasuring = true; measureComplete = false }
                }
                if newState == .complete {
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    withAnimation { measureComplete = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                        withAnimation { showMeasuring = false }
                    }
                }
                if newState == .idle || newState == nil {
                    showMeasuring = false
                }
            }
        }
    }

    // MARK: - Measurement Overlay

    private var measurementOverlay: some View {
        VStack(spacing: 20) {
            if measureComplete {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 64))
                    .foregroundColor(.green)
                    .transition(.scale.combined(with: .opacity))
                Text("Done!")
                    .font(.title2.bold())
                    .foregroundColor(.green)
                if let w = scale?.lastMeasurement?.weightKg {
                    Text(String(format: "%.2f kg", w))
                        .font(.title3.monospacedDigit())
                }
            } else {
                ZStack {
                    Circle()
                        .stroke(Color.gray.opacity(0.2), lineWidth: 6)
                        .frame(width: 80, height: 80)
                    Circle()
                        .trim(from: 0, to: scale?.isStable == true ? 0.9 : 0.3)
                        .stroke(
                            scale?.isStable == true ? Color(hex: 0x4ecca3) : Color.cyan,
                            style: StrokeStyle(lineWidth: 6, lineCap: .round)
                        )
                        .frame(width: 80, height: 80)
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: showMeasuring)
                }

                Text(scale?.liveWeight ?? 0 > 0 ? String(format: "%.1f kg", scale?.liveWeight ?? 0) : "Measuring...")
                    .font(.title2.bold().monospacedDigit())

                Text(scale?.isStable == true ? "Locking in..." : "Hold still...")
                    .font(.caption)
                    .foregroundColor(.gray)
            }
        }
        .frame(width: 220, height: 220)
        .background(.ultraThinMaterial)
        .cornerRadius(24)
        .shadow(radius: 20)
        .transition(.scale.combined(with: .opacity))
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
                Text(s.liveWeight > 0 ? String(format: "%.2f", s.liveWeight) : "--:--")
                    .font(.system(size: 64, weight: .bold, design: .rounded))
                    .foregroundColor(s.isStable ? Color(hex: 0x4ecca3) : .white)
                Text("kg").font(.title3).foregroundColor(.gray)
                if s.isStable {
                    Label("Stable", systemImage: "checkmark.circle.fill")
                        .font(.caption).foregroundColor(.green)
                }
            } else {
                Text("--:--")
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
        List {
            let bodyMeasurements = measurementStore.measurements(ofType: .bodyComp)
            if bodyMeasurements.isEmpty {
                Text("No measurements yet").foregroundColor(.gray)
                    .listRowBackground(Color(hex: 0x16213e))
            } else {
                ForEach(bodyMeasurements) { m in
                    NavigationLink(destination: MeasurementDetailView(measurement: m)) {
                        HStack(spacing: 12) {
                            Image(systemName: "scalemass").foregroundColor(.green).frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(m.dateString).font(.subheadline)
                                Text(m.summary).font(.caption).foregroundColor(.gray)
                                Text(m.sourceLabel).font(.caption2).foregroundColor(.cyan)
                            }
                        }
                    }
                    .listRowBackground(Color(hex: 0x16213e))
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color(hex: 0x1a1a2e))
        .frame(minHeight: 200)
    }
}
