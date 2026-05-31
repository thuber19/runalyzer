import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var ble: BLEManager
    @EnvironmentObject var sessions: SessionStore
    @State private var selectedRate: Double = 25
    @State private var showEraseConfirm = false
    @State private var showClearHistoryConfirm = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    sampleRateSection
                    deviceInfoSection
                    dataManagementSection
                    aboutSection
                }
                .padding()
            }
            .background(Color(hex: 0x1a1a2e))
            .navigationTitle("Settings")
        }
        .onAppear {
            selectedRate = Double(ble.deviceStatus.sampleRateHz)
        }
    }

    // MARK: - Sample Rate
    private var sampleRateSection: some View {
        VStack(spacing: 12) {
            HStack {
                Text("SAMPLE RATE").font(.caption2).foregroundColor(.gray)
                Spacer()
            }

            VStack(spacing: 8) {
                HStack {
                    Text("\(Int(selectedRate)) Hz")
                        .font(.title2.bold().monospacedDigit())
                    Spacer()
                    if !ble.connected {
                        Text("Connect to change")
                            .font(.caption).foregroundColor(.gray)
                    }
                }

                Slider(value: $selectedRate, in: 10...100, step: 5) { editing in
                    if !editing {
                        ble.setSampleRate(UInt8(selectedRate))
                    }
                }
                .tint(Color(hex: 0xe94560))
                .disabled(!ble.connected || ble.appState != .idle)

                HStack {
                    Text("10 Hz").font(.caption2).foregroundColor(.gray)
                    Spacer()
                    Text("100 Hz").font(.caption2).foregroundColor(.gray)
                }

                if ble.connected {
                    Text("Max recording: \(ble.deviceStatus.maxDurationAtRate)")
                        .font(.caption).foregroundColor(.gray)
                }
            }
        }
        .padding()
        .background(Color(hex: 0x16213e))
        .cornerRadius(12)
    }

    // MARK: - Device Info
    private var deviceInfoSection: some View {
        VStack(spacing: 12) {
            HStack {
                Text("DEVICE INFO").font(.caption2).foregroundColor(.gray)
                Spacer()
                Circle()
                    .fill(ble.connected ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
                Text(ble.connected ? "Connected" : "Disconnected")
                    .font(.caption)
                    .foregroundColor(ble.connected ? .green : .red)
            }

            if ble.connected {
                VStack(spacing: 8) {
                    infoRow(label: "Firmware", value: "v3.0")
                    infoRow(label: "Flash", value: "2 MB")
                    infoRow(label: "Max Samples", value: "\(ble.deviceStatus.maxSamples)")
                    infoRow(label: "Stored", value: "\(ble.deviceStatus.sampleCount)")

                    let capPct = ble.deviceStatus.maxSamples > 0
                        ? Float(ble.deviceStatus.sampleCount) / Float(ble.deviceStatus.maxSamples) * 100 : 0
                    infoRow(label: "Flash Usage", value: String(format: "%.1f%%", capPct))

                    HStack {
                        Text("Battery").font(.subheadline).foregroundColor(.gray)
                        Spacer()
                        HStack(spacing: 4) {
                            if ble.deviceStatus.isCharging {
                                Image(systemName: "bolt.fill").foregroundColor(.yellow).font(.caption)
                            }
                            Text("\(ble.deviceStatus.batteryPercent)%")
                                .font(.subheadline.monospacedDigit())
                                .foregroundColor(ble.deviceStatus.batteryPercent < 20 ? .red : .green)
                        }
                    }
                }
            } else {
                VStack(spacing: 8) {
                    Text("No device connected").font(.subheadline).foregroundColor(.gray)
                    Button(action: { ble.startScanning() }) {
                        Label("Scan for Device", systemImage: "antenna.radiowaves.left.and.right")
                            .frame(maxWidth: .infinity).padding()
                            .background(Color(hex: 0xe94560)).foregroundColor(.white).cornerRadius(10)
                    }
                }
            }
        }
        .padding()
        .background(Color(hex: 0x16213e))
        .cornerRadius(12)
    }

    private func infoRow(label: String, value: String) -> some View {
        HStack {
            Text(label).font(.subheadline).foregroundColor(.gray)
            Spacer()
            Text(value).font(.subheadline.monospacedDigit())
        }
    }

    // MARK: - Data Management
    private var dataManagementSection: some View {
        VStack(spacing: 12) {
            HStack {
                Text("DATA MANAGEMENT").font(.caption2).foregroundColor(.gray)
                Spacer()
            }

            Button(action: { showEraseConfirm = true }) {
                HStack {
                    Image(systemName: "externaldrive.badge.xmark").foregroundColor(.red)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Erase Device Data").font(.subheadline)
                        Text("Remove all data from device flash").font(.caption2).foregroundColor(.gray)
                    }
                    Spacer()
                }
                .padding()
                .background(Color.red.opacity(0.1))
                .cornerRadius(10)
            }
            .disabled(!ble.connected)
            .opacity(!ble.connected ? 0.5 : 1)
            .alert("Erase Device Data?", isPresented: $showEraseConfirm) {
                Button("Cancel", role: .cancel) {}
                Button("Erase", role: .destructive) { ble.eraseData() }
            } message: {
                Text("This will permanently delete all recorded data on the device.")
            }

            Button(action: { showClearHistoryConfirm = true }) {
                HStack {
                    Image(systemName: "trash").foregroundColor(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Clear Session History").font(.subheadline)
                        Text("Remove all \(sessions.sessions.count) sessions").font(.caption2).foregroundColor(.gray)
                    }
                    Spacer()
                }
                .padding()
                .background(Color.orange.opacity(0.1))
                .cornerRadius(10)
            }
            .disabled(sessions.sessions.isEmpty)
            .opacity(sessions.sessions.isEmpty ? 0.5 : 1)
            .alert("Clear Session History?", isPresented: $showClearHistoryConfirm) {
                Button("Cancel", role: .cancel) {}
                Button("Clear All", role: .destructive) { sessions.clearAllSessions() }
            } message: {
                Text("This will delete all \(sessions.sessions.count) sessions from this app.")
            }
        }
        .padding()
        .background(Color(hex: 0x16213e))
        .cornerRadius(12)
    }

    // MARK: - About
    private var aboutSection: some View {
        VStack(spacing: 12) {
            HStack {
                Text("ABOUT").font(.caption2).foregroundColor(.gray)
                Spacer()
            }

            VStack(spacing: 8) {
                Image(systemName: "figure.run")
                    .font(.system(size: 36))
                    .foregroundColor(Color(hex: 0xe94560))
                Text("Runalyzer").font(.title2.bold())
                Text("BLE IMU Sensor for Running Analysis").font(.caption).foregroundColor(.gray)
                Text("v1.0").font(.caption2).foregroundColor(.gray)
            }
        }
        .padding()
        .background(Color(hex: 0x16213e))
        .cornerRadius(12)
    }
}
