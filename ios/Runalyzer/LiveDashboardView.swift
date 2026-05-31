import SwiftUI
import Charts

struct LiveDashboardView: View {
    @EnvironmentObject var ble: BLEManager
    @EnvironmentObject var metrics: RunMetrics

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    connectionBanner
                    recordingControls
                    if ble.connected && ble.appState != .downloading {
                        metricsGrid
                        accelChart
                        gyroChart
                    } else if ble.appState == .downloading {
                        Text("Live preview paused during sync")
                            .font(.caption).foregroundColor(.gray)
                            .frame(maxWidth: .infinity).padding()
                    }
                }
                .padding()
            }
            .background(Color(hex: 0x1a1a2e))
            .navigationTitle("Runalyzer")
        }
    }

    // MARK: - Connection
    private var connectionBanner: some View {
        HStack {
            Circle()
                .fill(ble.connected ? Color.green : Color.red)
                .frame(width: 10, height: 10)
            Text(ble.connected ? "Connected" : "Scanning...")
                .font(.subheadline)

            Spacer()

            if ble.connected && ble.deviceStatus.batteryPercent > 0 {
                HStack(spacing: 4) {
                    if ble.deviceStatus.isCharging {
                        Image(systemName: "bolt.fill").foregroundColor(.yellow).font(.caption)
                    }
                    Text("\(ble.deviceStatus.batteryPercent)%")
                        .font(.subheadline)
                        .foregroundColor(ble.deviceStatus.batteryPercent < 20 ? .red : .green)
                }
            }
        }
        .padding()
        .background(Color(hex: 0x16213e))
        .cornerRadius(12)
    }

    // MARK: - Recording Controls
    private var recordingControls: some View {
        VStack(spacing: 12) {
            if !ble.connected && ble.appState != .recording {
                // Not connected and not recording on device
                Label("Connect sensor to start", systemImage: "antenna.radiowaves.left.and.right")
                    .frame(maxWidth: .infinity).padding()
                    .foregroundColor(.gray)
                    .background(Color(hex: 0x16213e)).cornerRadius(12)
            } else {
            switch ble.appState {
            case .disconnected, .idle:
                let hasUnsyncedData = ble.deviceStatus.state == .hasData && ble.deviceStatus.sampleCount > 0
                Button(action: {
                    metrics.reset()
                    ble.startRecording()
                }) {
                    Label("Start Recording", systemImage: "record.circle")
                        .font(.headline)
                        .frame(maxWidth: .infinity).padding()
                        .background(ble.connected && !hasUnsyncedData ? Color(hex: 0xe94560) : Color.gray)
                        .foregroundColor(.white).cornerRadius(12)
                }
                .disabled(!ble.connected || hasUnsyncedData)

                if hasUnsyncedData {
                    Text("Previous session not synced yet. Waiting for download...")
                        .font(.caption).foregroundColor(.orange).multilineTextAlignment(.center)
                }

            case .recording:
                VStack(spacing: 8) {
                    HStack {
                        Circle().fill(.red).frame(width: 10, height: 10)
                        Text("REC").font(.headline.bold()).foregroundColor(.red)
                        Text(ble.deviceStatus.durationString)
                            .font(.headline.monospacedDigit())
                        Spacer()
                        Text("\(ble.deviceStatus.sampleCount) samples")
                            .font(.caption.monospacedDigit()).foregroundColor(.gray)
                    }

                    Button(action: { ble.stopRecording() }) {
                        Label("Stop Recording", systemImage: "stop.circle.fill")
                            .frame(maxWidth: .infinity).padding()
                            .background(Color.red).foregroundColor(.white).cornerRadius(12)
                    }
                    .disabled(!ble.connected)

                    if !ble.connected {
                        Text("Device recording independently. Reconnect to stop.")
                            .font(.caption).foregroundColor(.orange)
                    }
                }
                .padding()
                .background(Color(hex: 0x16213e)).cornerRadius(12)

            case .stopping:
                HStack {
                    ProgressView().tint(.orange)
                    Text("Stopping...").foregroundColor(.orange)
                }
                .frame(maxWidth: .infinity).padding()
                .background(Color.orange.opacity(0.1)).cornerRadius(12)

            case .downloading:
                VStack(spacing: 8) {
                    HStack {
                        Text("Syncing session...").font(.subheadline).foregroundColor(.cyan)
                        Spacer()
                        Text("\(Int(ble.downloadProgress * 100))%")
                            .font(.subheadline.monospacedDigit()).foregroundColor(.cyan)
                    }
                    ProgressView(value: ble.downloadProgress).tint(.cyan)

                }
                .padding()
                .background(Color.cyan.opacity(0.1)).cornerRadius(12)

            case .error(let msg):
                VStack(spacing: 8) {
                    Text(msg).font(.subheadline).foregroundColor(.red)
                    Text("Will retry automatically...").font(.caption).foregroundColor(.gray)
                }
                .padding()
                .background(Color.red.opacity(0.1)).cornerRadius(12)
            }
            } // end else (connected)
        }
    }

    // MARK: - Metrics
    private var metricsGrid: some View {
        LazyVGrid(columns: [
            GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())
        ], spacing: 12) {
            MetricCard(label: "Cadence", value: "\(metrics.cadence)", unit: "spm")
            MetricCard(label: "Bounce", value: String(format: "%.2f", metrics.bounce), unit: "g")
            MetricCard(label: "Impact", value: String(format: "%.1f", metrics.peakImpact), unit: "g")
        }
    }

    // MARK: - Charts
    private var accelChart: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("ACCELERATION").font(.caption2).foregroundColor(.gray)
            Chart {
                ForEach(Array(metrics.accelHistory.suffix(300).enumerated()), id: \.offset) { i, val in
                    LineMark(x: .value("t", i), y: .value("g", val))
                        .foregroundStyle(Color(hex: 0x4ecca3))
                }
                RuleMark(y: .value("1g", 1.0))
                    .foregroundStyle(.gray.opacity(0.3))
                    .lineStyle(StrokeStyle(dash: [4, 4]))
            }
            .chartYScale(domain: 0...3)
            .chartXAxis(.hidden)
            .frame(height: 130)
        }
        .padding()
        .background(Color(hex: 0x16213e))
        .cornerRadius(12)
    }

    private var gyroChart: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("ROTATION").font(.caption2).foregroundColor(.gray)
            Chart {
                ForEach(Array(metrics.gyroHistory.suffix(300).enumerated()), id: \.offset) { i, val in
                    LineMark(x: .value("t", i), y: .value("dps", val))
                        .foregroundStyle(Color(hex: 0x5dadec))
                }
            }
            .chartYScale(domain: 0...200)
            .chartXAxis(.hidden)
            .frame(height: 130)
        }
        .padding()
        .background(Color(hex: 0x16213e))
        .cornerRadius(12)
    }
}

// MARK: - Metric Card

struct MetricCard: View {
    let label: String
    let value: String
    let unit: String

    var body: some View {
        VStack(spacing: 4) {
            Text(label.uppercased()).font(.system(size: 10)).foregroundColor(.gray)
            Text(value).font(.title2.bold().monospacedDigit())
            Text(unit).font(.system(size: 10)).foregroundColor(.gray)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(Color(hex: 0x16213e))
        .cornerRadius(10)
    }
}

// MARK: - Hex Color

extension Color {
    init(hex: UInt, opacity: Double = 1.0) {
        self.init(.sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity)
    }
}
