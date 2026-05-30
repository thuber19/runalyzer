import SwiftUI
import Charts

struct LiveDashboardView: View {
    @EnvironmentObject var ble: BLEManager
    @EnvironmentObject var metrics: RunMetrics
    @EnvironmentObject var sessions: SessionStore
    @EnvironmentObject var healthKit: HealthKitManager
    @EnvironmentObject var location: LocationKeepAlive

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    connectionBanner
                    metricsGrid
                    accelChart
                    gyroChart
                    symmetryBar
                    stepIntervalChart
                    recordingButton
                }
                .padding()
            }
            .background(Color(hex: 0x1a1a2e))
            .navigationTitle("Runalyzer")
        }
    }

    // MARK: - Connection Banner
    private var connectionBanner: some View {
        HStack {
            Circle()
                .fill(ble.state == .connected ? Color.green : Color.red)
                .frame(width: 10, height: 10)
            Text(ble.state.rawValue)
                .font(.subheadline)

            Spacer()

            if metrics.batteryLevel >= 0 {
                Label("\(metrics.batteryLevel)%", systemImage: batteryIcon)
                    .font(.subheadline)
                    .foregroundColor(metrics.batteryLevel < 20 ? .red : .green)
            }

            if ble.state == .disconnected {
                Button("Scan") { ble.startScanning() }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .controlSize(.small)
            } else if ble.state == .connected {
                Button("Disconnect") { ble.disconnect() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding()
        .background(Color(hex: 0x16213e))
        .cornerRadius(12)
    }

    private var batteryIcon: String {
        let l = metrics.batteryLevel
        if l > 75 { return "battery.100" }
        if l > 50 { return "battery.75" }
        if l > 25 { return "battery.50" }
        if l > 0 { return "battery.25" }
        return "battery.0"
    }

    // MARK: - Metrics Grid
    private var metricsGrid: some View {
        LazyVGrid(columns: [
            GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())
        ], spacing: 12) {
            MetricCard(label: "Cadence", value: "\(metrics.cadence)", unit: "spm")
            MetricCard(label: "Bounce", value: String(format: "%.2f", metrics.bounce), unit: "g pk-pk")
            MetricCard(label: "Impact", value: String(format: "%.1f", metrics.peakImpact), unit: "g")
        }
    }

    // MARK: - Accel Chart
    private var accelChart: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("TOTAL ACCELERATION")
                .font(.caption2)
                .foregroundColor(.gray)
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

    // MARK: - Gyro Chart
    private var gyroChart: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("TOTAL ROTATION")
                .font(.caption2)
                .foregroundColor(.gray)
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

    // MARK: - Symmetry
    private var symmetryBar: some View {
        VStack(spacing: 8) {
            Text("L/R SYMMETRY")
                .font(.caption2)
                .foregroundColor(.gray)

            HStack {
                Text("\(Int(metrics.symmetryLeft))%")
                    .font(.caption.monospacedDigit())
                    .foregroundColor(Color(hex: 0x5dadec))
                    .frame(width: 40)

                Text("L")
                    .font(.caption2)
                    .foregroundColor(.gray)

                GeometryReader { geo in
                    ZStack {
                        Capsule().fill(Color(hex: 0x0f3460))
                        HStack(spacing: 0) {
                            Spacer()
                            Rectangle()
                                .fill(Color(hex: 0x5dadec))
                                .frame(width: geo.size.width * CGFloat(metrics.symmetryLeft) / 200)
                            Rectangle()
                                .fill(Color(hex: 0xe94560))
                                .frame(width: geo.size.width * CGFloat(metrics.symmetryRight) / 200)
                            Spacer()
                        }
                        Rectangle()
                            .fill(Color.gray)
                            .frame(width: 2)
                    }
                    .clipShape(Capsule())
                }
                .frame(height: 20)

                Text("R")
                    .font(.caption2)
                    .foregroundColor(.gray)

                Text("\(Int(metrics.symmetryRight))%")
                    .font(.caption.monospacedDigit())
                    .foregroundColor(Color(hex: 0xe94560))
                    .frame(width: 40)
            }

            Text(metrics.symmetryVerdict)
                .font(.caption)
                .foregroundColor(
                    metrics.symmetryVerdict.contains("Symmetric") ? .green :
                    metrics.symmetryVerdict.contains("Slight") ? .yellow : .red
                )
        }
        .padding()
        .background(Color(hex: 0x16213e))
        .cornerRadius(12)
    }

    // MARK: - Step Intervals
    private var stepIntervalChart: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("STEP INTERVALS")
                .font(.caption2)
                .foregroundColor(.gray)

            if metrics.stepIntervals.isEmpty {
                Text("Start running to see step intervals")
                    .font(.caption)
                    .foregroundColor(.gray)
                    .frame(height: 100)
                    .frame(maxWidth: .infinity)
            } else {
                Chart {
                    // Target zone
                    RectangleMark(
                        xStart: .value("", 0),
                        xEnd: .value("", metrics.stepIntervals.count),
                        yStart: .value("", 300),
                        yEnd: .value("", 400)
                    )
                    .foregroundStyle(Color.green.opacity(0.1))

                    ForEach(Array(metrics.stepIntervals.suffix(40).enumerated()), id: \.offset) { i, val in
                        BarMark(x: .value("step", i), y: .value("ms", val))
                            .foregroundStyle(val >= 300 && val <= 400 ? Color.green : Color.blue)
                    }
                }
                .chartYScale(domain: 200...800)
                .chartXAxis(.hidden)
                .frame(height: 100)
            }
        }
        .padding()
        .background(Color(hex: 0x16213e))
        .cornerRadius(12)
    }

    // MARK: - Recording
    private var recordingButton: some View {
        Button(action: {
            if sessions.isRecording {
                sessions.stopRecording(metrics: metrics, healthKit: healthKit)
                location.stopTracking()
            } else {
                metrics.reset()
                sessions.startRecording(healthKit: healthKit)
                location.startTracking()
            }
        }) {
            HStack {
                Image(systemName: sessions.isRecording ? "stop.circle.fill" : "record.circle")
                    .font(.title2)
                Text(sessions.isRecording ? "Stop Recording" : "Start Recording")
                    .fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
            .padding()
            .background(sessions.isRecording ? Color.red : Color(hex: 0xe94560))
            .foregroundColor(.white)
            .cornerRadius(12)
        }
    }
}

// MARK: - Metric Card
struct MetricCard: View {
    let label: String
    let value: String
    let unit: String

    var body: some View {
        VStack(spacing: 4) {
            Text(label.uppercased())
                .font(.system(size: 10))
                .foregroundColor(.gray)
            Text(value)
                .font(.title2.bold().monospacedDigit())
            Text(unit)
                .font(.system(size: 10))
                .foregroundColor(.gray)
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
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}
