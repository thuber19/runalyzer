import SwiftUI
import Charts
import UIKit

struct LiveDashboardView: View {
    @EnvironmentObject var coordinator: DeviceCoordinator
    @EnvironmentObject var metrics: RunMetrics

    private var imu: IMUSensorDriver? { coordinator.imuDriver }
    private var isConnected: Bool { imu != nil }

    var body: some View {
        VStack(spacing: 16) {
            connectionBanner
            recordingControls
            if isConnected && imu?.appState != .downloading {
                metricsGrid
                accelChart
                gyroChart
            } else if imu?.appState == .downloading {
                Text("Live preview paused during sync")
                    .font(.caption).foregroundColor(.gray)
                    .frame(maxWidth: .infinity).padding()
            }
        }
    }

    // MARK: - Connection
    private var connectionBanner: some View {
        HStack {
            Circle()
                .fill(isConnected ? Color.green : Color.red)
                .frame(width: 10, height: 10)
            Text(isConnected ? "Connected" : "Scanning...")
                .font(.subheadline)
            Spacer()

            if let status = imu?.deviceStatus, status.batteryPercent > 0 {
                HStack(spacing: 4) {
                    if status.isCharging {
                        Image(systemName: "bolt.fill").foregroundColor(.yellow).font(.caption)
                    }
                    Text("\(status.batteryPercent)%")
                        .font(.subheadline)
                        .foregroundColor(status.batteryPercent < 20 ? .red : .green)
                }
            }
        }
        .padding()
        .background(Color(hex: 0x16213e))
        .cornerRadius(12)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(isConnected
            ? "IMU sensor connected, battery \(imu?.deviceStatus.batteryPercent ?? 0) percent"
            : "IMU sensor not connected, scanning")
    }

    // MARK: - Recording Controls
    private var recordingControls: some View {
        VStack(spacing: 12) {
            let appState = imu?.appState ?? .disconnected

            if !isConnected && appState != .recording {
                Label("Connect sensor to start", systemImage: "antenna.radiowaves.left.and.right")
                    .frame(maxWidth: .infinity).padding()
                    .foregroundColor(.gray)
                    .background(Color(hex: 0x16213e)).cornerRadius(12)
            } else {
                switch appState {
                case .disconnected, .idle:
                    let hasUnsynced = imu?.deviceStatus.state == .hasData && (imu?.deviceStatus.sampleCount ?? 0) > 0
                    Button(action: {
                        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
                        metrics.reset()
                        imu?.startRecording()
                    }) {
                        Label("Start Recording", systemImage: "record.circle")
                            .font(.headline)
                            .frame(maxWidth: .infinity).padding()
                            .background(isConnected && !hasUnsynced ? Color(hex: 0xe94560) : Color.gray)
                            .foregroundColor(.white).cornerRadius(12)
                    }
                    .disabled(!isConnected || hasUnsynced)
                    .accessibilityLabel(hasUnsynced
                        ? "Start recording, disabled — previous session not yet synced"
                        : "Start recording")

                    if hasUnsynced {
                        Text("Previous session not synced yet. Waiting for download...")
                            .font(.caption).foregroundColor(.orange).multilineTextAlignment(.center)
                    }

                case .recording:
                    VStack(spacing: 8) {
                        HStack {
                            Circle().fill(.red).frame(width: 10, height: 10)
                            Text("REC").font(.headline.bold()).foregroundColor(.red)
                            Text(imu?.deviceStatus.durationString ?? "--")
                                .font(.headline.monospacedDigit())
                            Spacer()
                            Text("\(imu?.deviceStatus.sampleCount ?? 0) samples")
                                .font(.caption.monospacedDigit()).foregroundColor(.gray)
                        }
                        Button(action: {
                            UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
                            imu?.stopRecording()
                        }) {
                            Label("Stop Recording", systemImage: "stop.circle.fill")
                                .frame(maxWidth: .infinity).padding()
                                .background(Color.red).foregroundColor(.white).cornerRadius(12)
                        }
                        .disabled(!isConnected)
                        .accessibilityLabel("Stop recording")
                        if !isConnected {
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
                            Text("\(Int((imu?.downloadProgress ?? 0) * 100))%")
                                .font(.subheadline.monospacedDigit()).foregroundColor(.cyan)
                        }
                        ProgressView(value: imu?.downloadProgress ?? 0).tint(.cyan)
                    }
                    .padding()
                    .background(Color.cyan.opacity(0.1)).cornerRadius(12)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Syncing session, \(Int((imu?.downloadProgress ?? 0) * 100)) percent complete")

                case .error(let msg):
                    VStack(spacing: 8) {
                        Text(msg).font(.subheadline).foregroundColor(.red)
                        Text("Will retry automatically...").font(.caption).foregroundColor(.gray)
                    }
                    .padding()
                    .background(Color.red.opacity(0.1)).cornerRadius(12)
                }
            }
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(value) \(unit)")
    }
}
