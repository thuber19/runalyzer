import SwiftUI

/// Device-specific settings for a connected IMU sensor
struct IMUSettingsView: View {
    @EnvironmentObject var coordinator: DeviceCoordinator
    @State private var selectedRate: Double = 25
    @State private var showEraseConfirm = false

    private var imu: IMUSensorDriver? { coordinator.imuDriver }

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .medium
        return f
    }()

    var body: some View {
        List {
            if let imu = imu, let status = Optional(imu.deviceStatus) {
                // Sample Rate
                Section("Sample Rate") {
                    VStack(spacing: 8) {
                        HStack {
                            Text("\(Int(selectedRate)) Hz").font(.headline.monospacedDigit())
                            Spacer()
                            Text("Max: \(status.maxDurationAtRate)").font(.caption).foregroundColor(.gray)
                        }
                        Slider(value: $selectedRate, in: 10...100, step: 5) { editing in
                            if !editing { imu.setSampleRate(UInt8(selectedRate)) }
                        }
                        .tint(Color(hex: 0xe94560))
                        .disabled(imu.appState != .idle)
                    }
                    .listRowBackground(Color(hex: 0x16213e))
                }

                // Device Info
                Section("Device Info") {
                    infoRow("Protocol", "v\(status.protocolVersion)")
                    infoRow("Flash", "2 MB")
                    infoRow("Max Samples", "\(status.maxSamples)")
                    infoRow("Stored Samples", "\(status.sampleCount)")

                    let capPct = status.maxSamples > 0
                        ? Float(status.sampleCount) / Float(status.maxSamples) * 100 : 0
                    infoRow("Flash Usage", String(format: "%.1f%%", capPct))

                    HStack {
                        Text("Battery")
                        Spacer()
                        if status.isCharging {
                            Image(systemName: "bolt.fill").foregroundColor(.yellow)
                        }
                        Text("\(status.batteryPercent)%")
                            .foregroundColor(status.batteryPercent < 20 ? .red : .green)
                    }
                    .listRowBackground(Color(hex: 0x16213e))

                    infoRow("Time Synced", status.isTimeSynced ? "Yes" : "No")
                }

                // Unsynced Data
                if status.sampleCount > 0 {
                    Section("Unsynced Session") {
                        infoRow("Samples", "\(status.sampleCount)")
                        infoRow("Duration", status.durationString)
                        if let startDate = status.recordingStartDate {
                            infoRow("Started", Self.dateFmt.string(from: startDate))
                        }
                    }
                }

                // Erase
                Section {
                    Button(role: .destructive, action: { showEraseConfirm = true }) {
                        Label("Erase Device Data", systemImage: "trash")
                    }
                    .disabled(imu.appState == .recording || imu.appState == .downloading)
                    .listRowBackground(Color(hex: 0x16213e))
                } footer: {
                    Text("Permanently deletes all recorded data from the device flash.")
                }
            } else {
                Section {
                    Text("IMU sensor not connected").foregroundColor(.gray)
                        .listRowBackground(Color(hex: 0x16213e))
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color(hex: 0x1a1a2e))
        .navigationTitle("IMU Settings")
        .onAppear {
            selectedRate = Double(imu?.deviceStatus.sampleRateHz ?? 25)
        }
        .alert("Erase Device Data?", isPresented: $showEraseConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Erase", role: .destructive) { imu?.eraseData() }
        } message: {
            Text("This will permanently delete all recorded data on the device.")
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).foregroundColor(.gray)
        }
        .listRowBackground(Color(hex: 0x16213e))
    }
}
