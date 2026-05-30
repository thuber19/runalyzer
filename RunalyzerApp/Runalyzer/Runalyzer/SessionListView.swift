import SwiftUI
import Charts
import HealthKit

struct SessionListView: View {
    @EnvironmentObject var sessions: SessionStore

    var body: some View {
        NavigationStack {
            Group {
                if sessions.sessions.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "figure.run")
                            .font(.system(size: 48))
                            .foregroundColor(.gray)
                        Text("No sessions yet")
                            .foregroundColor(.gray)
                        Text("Go to Live tab, connect, and hit Record")
                            .font(.caption)
                            .foregroundColor(.gray.opacity(0.7))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(sessions.sessions) { session in
                            NavigationLink(destination: SessionDetailView(session: session)) {
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(session.dateString)
                                            .font(.headline)
                                        Text("\(session.durationString) · \(session.totalSteps ?? 0) steps · \(session.sampleCount) samples")
                                            .font(.caption)
                                            .foregroundColor(.gray)
                                    }
                                    Spacer()
                                    if session.avgCadence > 0 {
                                        VStack {
                                            Text("\(session.avgCadence)")
                                                .font(.title3.bold().monospacedDigit())
                                            Text("spm")
                                                .font(.caption2)
                                                .foregroundColor(.gray)
                                        }
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                        }
                        .onDelete { indexSet in
                            for i in indexSet {
                                sessions.deleteSession(sessions.sessions[i])
                            }
                        }
                    }
                }
            }
            .background(Color(hex: 0x1a1a2e))
            .navigationTitle("History")
        }
    }
}

// MARK: - Session Detail
struct SessionDetailView: View {
    let session: RunSession
    @EnvironmentObject var sessions: SessionStore
    @EnvironmentObject var healthKit: HealthKitManager
    @State private var showShareSheet = false
    @State private var csvURL: URL?
    @State private var samples: [RecordedSample] = []
    @State private var showWorkoutPicker = false
    @State private var selectedWorkout: AppleWorkout?
    @State private var showDebug = false
    @State private var debugText = ""
    @State private var appleData: AppleRunData?
    @State private var loadingAppleData = false
    @State private var analysis: RecordingAnalysis?

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                sessionSummary

                // IMU Step Analysis
                if let a = analysis {
                    analysisView(a)
                }

                // Workout picker button
                Button(action: {
                    healthKit.fetchRecentWorkouts()
                    showWorkoutPicker = true
                }) {
                    HStack {
                        Image(systemName: "heart.fill")
                            .foregroundColor(.pink)
                        if let w = selectedWorkout {
                            VStack(alignment: .leading) {
                                Text("Linked: \(w.activityName) — \(w.dateString)")
                                    .font(.caption)
                                Text("\(w.durationString) · \(String(format: "%.2f", w.distanceKm)) km")
                                    .font(.caption2).foregroundColor(.gray)
                            }
                        } else {
                            Text("Link Apple Health Workout")
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundColor(.gray)
                    }
                    .padding()
                    .background(Color(hex: 0x16213e))
                    .cornerRadius(12)
                }

                if loadingAppleData {
                    ProgressView("Loading Apple Health data...")
                        .padding()
                }

                // Comparison
                if let data = appleData {
                    comparisonView(data)
                    if !data.cadenceSamples.isEmpty {
                        cadenceChart(data)
                    }
                    if !data.heartRateSamples.isEmpty {
                        heartRateChart(data)
                    }
                    if !data.distanceSamples.isEmpty {
                        distanceChart(data)
                    }
                    if !data.heartRateSamples.isEmpty && !samples.isEmpty {
                        timelineChart(data)
                    }
                }

                // Accel replay
                if !samples.isEmpty {
                    replayChart
                }

                // Export
                Button(action: exportCSV) {
                    Label("Export CSV", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color(hex: 0xe94560))
                        .foregroundColor(.white)
                        .cornerRadius(12)
                }

                // Debug dump
                Button(action: {
                    let end = session.endDate ?? session.date.addingTimeInterval(session.duration)
                    debugText = "Loading..."
                    showDebug = true
                    healthKit.debugDump(from: session.date.addingTimeInterval(-1800), to: end.addingTimeInterval(1800)) { text in
                        debugText = text
                    }
                }) {
                    Label("Debug: Dump Health Data", systemImage: "ladybug")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.gray.opacity(0.2))
                        .foregroundColor(.gray)
                        .cornerRadius(12)
                }
            }
            .padding()
        }
        .background(Color(hex: 0x1a1a2e))
        .navigationTitle(session.dateString)
        .onAppear {
            samples = sessions.loadSamples(for: session)
            if !samples.isEmpty {
                analysis = RunMetrics.analyzeRecording(samples)
            }
        }
        .sheet(isPresented: $showWorkoutPicker) {
            WorkoutPickerView(session: session, selectedWorkout: $selectedWorkout) {
                if let w = selectedWorkout {
                    loadingAppleData = true
                    healthKit.fetchRunData(from: w.startDate, to: w.endDate) { data in
                        appleData = data
                        loadingAppleData = false
                    }
                }
            }
        }
        .sheet(isPresented: $showShareSheet) {
            if let url = csvURL {
                ShareSheet(items: [url])
            }
        }
        .sheet(isPresented: $showDebug) {
            NavigationStack {
                ScrollView {
                    Text(debugText)
                        .font(.system(size: 11, design: .monospaced))
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .navigationTitle("Health Data Debug")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { showDebug = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Copy") { UIPasteboard.general.string = debugText }
                    }
                }
            }
        }
    }

    // MARK: - Export
    private func exportCSV() {
        guard let url = sessions.exportCSV(session: session) else {
            print("CSV export failed")
            return
        }
        csvURL = url
        // Small delay to ensure state update before presenting sheet
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            showShareSheet = true
        }
    }

    // MARK: - IMU Step Analysis
    private func analysisView(_ a: RecordingAnalysis) -> some View {
        VStack(spacing: 12) {
            Text("IMU STEP ANALYSIS").font(.caption2).foregroundColor(.gray)

            // Stats
            HStack(spacing: 16) {
                VStack {
                    Text("\(a.totalSteps)").font(.title.bold().monospacedDigit())
                        .foregroundColor(Color(hex: 0x4ecca3))
                    Text("Steps").font(.caption2).foregroundColor(.gray)
                }
                VStack {
                    Text(String(format: "%.0f", a.avgCadence)).font(.title.bold().monospacedDigit())
                        .foregroundColor(Color(hex: 0xe94560))
                    Text("Avg SPM").font(.caption2).foregroundColor(.gray)
                }
                VStack {
                    Text(String(format: "%.2f", a.peakG)).font(.title.bold().monospacedDigit())
                        .foregroundColor(.orange)
                    Text("Peak g").font(.caption2).foregroundColor(.gray)
                }
                VStack {
                    Text(String(format: "%.2f", a.bounceG)).font(.title.bold().monospacedDigit())
                        .foregroundColor(Color(hex: 0x5dadec))
                    Text("Bounce g").font(.caption2).foregroundColor(.gray)
                }
            }

            // Filtered signal with detected steps
            VStack(alignment: .leading, spacing: 4) {
                Text("FILTERED SIGNAL + DETECTED STEPS").font(.system(size: 10)).foregroundColor(.gray)
                Text("Green = raw accel, Yellow = filtered (gravity removed), Red dots = steps, Threshold: \(String(format: "%.3fg", a.dynamicThreshold))")
                    .font(.system(size: 9)).foregroundColor(.gray.opacity(0.6))

                Canvas { context, size in
                    let w = size.width
                    let h = size.height
                    guard let firstTs = a.accelMag.first?.timestamp,
                          let lastTs = a.accelMag.last?.timestamp,
                          lastTs > firstTs else { return }
                    let timeRange = Float(lastTs - firstTs)

                    func xFor(_ ts: UInt32) -> CGFloat {
                        CGFloat(Float(ts - firstTs) / timeRange) * w
                    }

                    // --- Top half: raw accel magnitude ---
                    let rawMinY: Float = 0
                    let rawMaxY: Float = max(2.0, a.peakG * 1.1)
                    let topH = h * 0.45

                    func rawYFor(_ val: Float) -> CGFloat {
                        topH - CGFloat((val - rawMinY) / (rawMaxY - rawMinY)) * topH
                    }

                    // 1g baseline
                    let baseY = rawYFor(1.0)
                    var basePath = Path()
                    basePath.move(to: CGPoint(x: 0, y: baseY))
                    basePath.addLine(to: CGPoint(x: w, y: baseY))
                    context.stroke(basePath, with: .color(.gray.opacity(0.2)), style: StrokeStyle(dash: [2, 4]))

                    // Raw accel line
                    let step = max(1, a.accelMag.count / 1000)
                    var rawPath = Path()
                    for i in stride(from: 0, to: a.accelMag.count, by: step) {
                        let pt = a.accelMag[i]
                        let x = xFor(pt.timestamp)
                        let y = rawYFor(pt.value)
                        if i == 0 { rawPath.move(to: CGPoint(x: x, y: y)) }
                        else { rawPath.addLine(to: CGPoint(x: x, y: y)) }
                    }
                    context.stroke(rawPath, with: .color(Color(hex: 0x4ecca3).opacity(0.5)), lineWidth: 1)

                    context.draw(Text("Raw").font(.system(size: 8)).foregroundColor(Color(hex: 0x4ecca3).opacity(0.6)),
                                at: CGPoint(x: 16, y: 8))

                    // --- Bottom half: filtered signal (centered at zero) ---
                    let filtMax = max(a.dynamicThreshold * 3, a.filtered.map { abs($0.value) }.max() ?? 0.5)
                    let botTop = h * 0.55
                    let botH = h * 0.45
                    let botMid = botTop + botH / 2

                    func filtYFor(_ val: Float) -> CGFloat {
                        botMid - CGFloat(val / filtMax) * (botH / 2)
                    }

                    // Zero line
                    var zeroPath = Path()
                    zeroPath.move(to: CGPoint(x: 0, y: botMid))
                    zeroPath.addLine(to: CGPoint(x: w, y: botMid))
                    context.stroke(zeroPath, with: .color(.gray.opacity(0.3)))

                    // Dynamic threshold line
                    let threshY = filtYFor(a.dynamicThreshold)
                    var threshPath = Path()
                    threshPath.move(to: CGPoint(x: 0, y: threshY))
                    threshPath.addLine(to: CGPoint(x: w, y: threshY))
                    context.stroke(threshPath, with: .color(.red.opacity(0.4)), style: StrokeStyle(dash: [4, 4]))

                    // Filtered signal
                    var filtPath = Path()
                    for i in stride(from: 0, to: a.filtered.count, by: step) {
                        let pt = a.filtered[i]
                        let x = xFor(pt.timestamp)
                        let y = filtYFor(pt.value)
                        if i == 0 { filtPath.move(to: CGPoint(x: x, y: y)) }
                        else { filtPath.addLine(to: CGPoint(x: x, y: y)) }
                    }
                    context.stroke(filtPath, with: .color(.yellow), lineWidth: 1)

                    // Step markers — colored by side
                    for s in a.steps {
                        let x = xFor(s.timestamp)
                        let rawY = rawYFor(s.accelMag)
                        let color: Color = s.side == .sideA ? .cyan : .orange
                        let rect = CGRect(x: x - 4, y: rawY - 4, width: 8, height: 8)
                        context.fill(Path(ellipseIn: rect), with: .color(color))

                        // Vertical line
                        var vline = Path()
                        vline.move(to: CGPoint(x: x, y: rawY))
                        vline.addLine(to: CGPoint(x: x, y: botMid))
                        context.stroke(vline, with: .color(color.opacity(0.15)))
                    }

                    // Gyro signal in bottom section (faint)
                    if !a.gyroFiltered.isEmpty {
                        let gyroMax = a.gyroFiltered.map { abs($0.value) }.max() ?? 1
                        var gyroPath = Path()
                        for i in stride(from: 0, to: a.gyroFiltered.count, by: step) {
                            let pt = a.gyroFiltered[i]
                            let x = xFor(pt.timestamp)
                            let y = botMid - CGFloat(pt.value / gyroMax) * (botH / 4)
                            if i == 0 { gyroPath.move(to: CGPoint(x: x, y: y)) }
                            else { gyroPath.addLine(to: CGPoint(x: x, y: y)) }
                        }
                        context.stroke(gyroPath, with: .color(.purple.opacity(0.3)), lineWidth: 0.8)
                    }

                    // Labels
                    context.draw(Text("Filtered").font(.system(size: 8)).foregroundColor(.yellow.opacity(0.6)),
                                at: CGPoint(x: 24, y: botTop + 8))
                    context.draw(Text("thresh").font(.system(size: 7)).foregroundColor(.red.opacity(0.5)),
                                at: CGPoint(x: 22, y: threshY - 6))
                }
                .frame(height: 280)

                // Legend
                HStack(spacing: 16) {
                    HStack(spacing: 4) {
                        Circle().fill(.cyan).frame(width: 8, height: 8)
                        Text("Side A (\(a.stepsA.count))").font(.system(size: 10))
                    }
                    HStack(spacing: 4) {
                        Circle().fill(.orange).frame(width: 8, height: 8)
                        Text("Side B (\(a.stepsB.count))").font(.system(size: 10))
                    }
                    HStack(spacing: 4) {
                        Rectangle().fill(.purple.opacity(0.3)).frame(width: 12, height: 2)
                        Text("Gyro \(a.dominantGyroAxis)").font(.system(size: 10))
                    }
                }
                .foregroundColor(.gray)
            }

            // Side A vs Side B comparison
            if a.stepsA.count > 0 && a.stepsB.count > 0 {
                VStack(spacing: 8) {
                    Text("SIDE COMPARISON").font(.system(size: 10)).foregroundColor(.gray)

                    HStack(spacing: 0) {
                        // Side A
                        VStack(spacing: 4) {
                            Text("Side A").font(.caption.bold()).foregroundColor(.cyan)
                            Text("\(a.stepsA.count) steps").font(.system(size: 11)).foregroundColor(.gray)
                            Text(String(format: "%.3fg", a.avgImpactA)).font(.headline.monospacedDigit())
                            Text("avg impact").font(.system(size: 9)).foregroundColor(.gray)
                        }
                        .frame(maxWidth: .infinity)

                        // Symmetry indicator
                        VStack(spacing: 4) {
                            let diff = abs(a.avgImpactA - a.avgImpactB)
                            let avgImpact = (a.avgImpactA + a.avgImpactB) / 2
                            let pctDiff = avgImpact > 0 ? (diff / avgImpact) * 100 : 0
                            Image(systemName: pctDiff < 5 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundColor(pctDiff < 5 ? .green : (pctDiff < 15 ? .yellow : .red))
                                .font(.title2)
                            Text(String(format: "%.1f%%", pctDiff))
                                .font(.caption.monospacedDigit())
                                .foregroundColor(.gray)
                            Text("diff").font(.system(size: 9)).foregroundColor(.gray)
                        }
                        .frame(width: 60)

                        // Side B
                        VStack(spacing: 4) {
                            Text("Side B").font(.caption.bold()).foregroundColor(.orange)
                            Text("\(a.stepsB.count) steps").font(.system(size: 11)).foregroundColor(.gray)
                            Text(String(format: "%.3fg", a.avgImpactB)).font(.headline.monospacedDigit())
                            Text("avg impact").font(.system(size: 9)).foregroundColor(.gray)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }

            // Duration info
            if let first = a.accelMag.first, let last = a.accelMag.last {
                let durationSec = Float(last.timestamp - first.timestamp) / 1000
                Text("Duration: \(String(format: "%.1f", durationSec))s · \(a.accelMag.count) samples · \(a.totalSteps) steps (\(a.stepsA.count)A + \(a.stepsB.count)B)")
                    .font(.system(size: 10)).foregroundColor(.gray)
            }
        }
        .padding()
        .background(Color(hex: 0x16213e))
        .cornerRadius(12)
    }

    // MARK: - Session Summary
    private var sessionSummary: some View {
        VStack(spacing: 8) {
            Text("IMU SENSOR DATA").font(.caption2).foregroundColor(.gray)
            HStack(spacing: 20) {
                VStack {
                    Text(session.durationString).font(.title2.bold())
                    Text("Duration").font(.caption).foregroundColor(.gray)
                }
                VStack {
                    Text("\(session.sampleCount)").font(.title2.bold().monospacedDigit())
                    Text("Samples").font(.caption).foregroundColor(.gray)
                }
                if session.avgCadence > 0 {
                    VStack {
                        Text("\(session.avgCadence)").font(.title2.bold().monospacedDigit())
                        Text("IMU SPM").font(.caption).foregroundColor(.gray)
                    }
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(Color(hex: 0x16213e))
        .cornerRadius(12)
    }

    // MARK: - Comparison
    private func comparisonView(_ data: AppleRunData) -> some View {
        VStack(spacing: 12) {
            Text("APPLE HEALTH vs IMU SENSOR").font(.caption2).foregroundColor(.gray)

            HStack(spacing: 0) {
                comparisonCard(title: "IMU Cadence", value: "\(session.avgCadence)", unit: "spm", color: Color(hex: 0xe94560))
                Image(systemName: "arrow.left.arrow.right").foregroundColor(.gray).padding(.horizontal, 8)
                comparisonCard(title: "Apple Cadence", value: String(format: "%.0f", data.avgCadence), unit: "spm", color: .pink)
            }

            if session.avgCadence > 0 && data.avgCadence > 0 {
                let diff = abs(Double(session.avgCadence) - data.avgCadence)
                let pctDiff = diff / data.avgCadence * 100
                HStack {
                    Image(systemName: pctDiff < 5 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundColor(pctDiff < 5 ? .green : (pctDiff < 15 ? .yellow : .red))
                    Text(pctDiff < 5 ? "Cadence matches (±\(String(format: "%.1f", pctDiff))%)" :
                         "Cadence differs by \(String(format: "%.1f", pctDiff))%")
                        .font(.caption).foregroundColor(.gray)
                }
            }

            Divider().background(Color.gray.opacity(0.3))

            HStack(spacing: 16) {
                if data.avgHeartRate > 0 {
                    statBadge(icon: "heart.fill", color: .red, value: String(format: "%.0f", data.avgHeartRate), unit: "bpm")
                }
                if data.distanceKm > 0 {
                    statBadge(icon: "figure.run", color: .green, value: String(format: "%.2f", data.distanceKm), unit: "km")
                }
                if data.totalSteps > 0 {
                    statBadge(icon: "shoeprints.fill", color: .blue, value: "\(data.totalSteps)", unit: "steps")
                }
                if data.activeCalories > 0 {
                    statBadge(icon: "flame.fill", color: .orange, value: String(format: "%.0f", data.activeCalories), unit: "kcal")
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(Color(hex: 0x16213e))
        .cornerRadius(12)
    }

    private func comparisonCard(title: String, value: String, unit: String, color: Color) -> some View {
        VStack(spacing: 4) {
            Text(title).font(.caption2).foregroundColor(.gray)
            Text(value).font(.title.bold().monospacedDigit()).foregroundColor(color)
            Text(unit).font(.caption2).foregroundColor(.gray)
        }
        .frame(maxWidth: .infinity)
    }

    private func statBadge(icon: String, color: Color, value: String, unit: String) -> some View {
        VStack {
            Image(systemName: icon).foregroundColor(color)
            Text(value).font(.headline.monospacedDigit())
            Text(unit).font(.caption2).foregroundColor(.gray)
        }
    }

    // MARK: - Cadence Chart (from Apple step data)
    private func cadenceChart(_ data: AppleRunData) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("APPLE CADENCE (steps/min)").font(.caption2).foregroundColor(.gray)
            Chart(data.cadenceSamples) { sample in
                BarMark(x: .value("Time", sample.date), y: .value("SPM", sample.value))
                    .foregroundStyle(Color.pink)
            }
            .chartYAxis { AxisMarks(position: .leading) }
            .frame(height: 120)
        }
        .padding()
        .background(Color(hex: 0x16213e))
        .cornerRadius(12)
    }

    // MARK: - Distance Chart
    private func distanceChart(_ data: AppleRunData) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("CUMULATIVE DISTANCE (m)").font(.caption2).foregroundColor(.gray)
            Chart(data.distanceSamples) { sample in
                LineMark(x: .value("Time", sample.date), y: .value("m", sample.value))
                    .foregroundStyle(.green)
            }
            .chartYAxis { AxisMarks(position: .leading) }
            .frame(height: 120)
        }
        .padding()
        .background(Color(hex: 0x16213e))
        .cornerRadius(12)
    }

    // MARK: - Heart Rate Chart
    private func heartRateChart(_ data: AppleRunData) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("HEART RATE").font(.caption2).foregroundColor(.gray)
            Chart(data.heartRateSamples) { sample in
                LineMark(x: .value("Time", sample.date), y: .value("BPM", sample.value))
                    .foregroundStyle(.red)
            }
            .chartYAxis { AxisMarks(position: .leading) }
            .frame(height: 120)
        }
        .padding()
        .background(Color(hex: 0x16213e))
        .cornerRadius(12)
    }

    // MARK: - Timeline: Accel + HR overlaid
    private func timelineChart(_ data: AppleRunData) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("TIMELINE: IMPACT vs HEART RATE").font(.caption2).foregroundColor(.gray)
            Text("Green = accel magnitude, Red = heart rate")
                .font(.system(size: 9)).foregroundColor(.gray.opacity(0.6))

            let workoutStart = data.heartRateSamples.first?.date ?? session.date
            let sessionStart = session.date

            // Downsample accel to ~1 per second
            let step = max(1, samples.count / Int(session.duration))
            let accelPoints: [TimestampedValue] = stride(from: 0, to: samples.count, by: step).map { i in
                let s = samples[i]
                let ax = Float(s.ax) * IMUPacket.accelScale
                let ay = Float(s.ay) * IMUPacket.accelScale
                let az = Float(s.az) * IMUPacket.accelScale
                let mag = Double(sqrtf(ax*ax + ay*ay + az*az))
                let elapsed = Double(s.timestamp - samples[0].timestamp) / 1000.0
                let date = sessionStart.addingTimeInterval(elapsed)
                return TimestampedValue(date: date, value: mag)
            }

            Canvas { context, size in
                let w = size.width
                let h = size.height

                // Find common time range
                let allDates = accelPoints.map(\.date) + data.heartRateSamples.map(\.date)
                guard let minDate = allDates.min(), let maxDate = allDates.max() else { return }
                let timeRange = maxDate.timeIntervalSince(minDate)
                guard timeRange > 0 else { return }

                func xFor(_ date: Date) -> CGFloat {
                    CGFloat(date.timeIntervalSince(minDate) / timeRange) * w
                }

                // Accel (0-3g mapped to full height)
                var accelPath = Path()
                for (i, p) in accelPoints.enumerated() {
                    let x = xFor(p.date)
                    let y = h - CGFloat(p.value / 3.0) * h
                    if i == 0 { accelPath.move(to: CGPoint(x: x, y: y)) }
                    else { accelPath.addLine(to: CGPoint(x: x, y: y)) }
                }
                context.stroke(accelPath, with: .color(Color(hex: 0x4ecca3).opacity(0.7)), lineWidth: 1)

                // Heart rate (60-200 mapped to full height)
                var hrPath = Path()
                for (i, p) in data.heartRateSamples.enumerated() {
                    let x = xFor(p.date)
                    let y = h - CGFloat((p.value - 60) / 140) * h
                    if i == 0 { hrPath.move(to: CGPoint(x: x, y: y)) }
                    else { hrPath.addLine(to: CGPoint(x: x, y: y)) }
                }
                context.stroke(hrPath, with: .color(.red.opacity(0.8)), lineWidth: 1.5)
            }
            .frame(height: 150)
        }
        .padding()
        .background(Color(hex: 0x16213e))
        .cornerRadius(12)
    }

    // MARK: - Accel Replay
    private var replayChart: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("ACCELERATION MAGNITUDE").font(.caption2).foregroundColor(.gray)
            let mags: [(Int, Float)] = samples.enumerated().map { i, s in
                let ax = Float(s.ax) * IMUPacket.accelScale
                let ay = Float(s.ay) * IMUPacket.accelScale
                let az = Float(s.az) * IMUPacket.accelScale
                return (i, sqrtf(ax*ax + ay*ay + az*az))
            }
            let step = max(1, mags.count / 500)
            let downsampled = stride(from: 0, to: mags.count, by: step).map { mags[$0] }

            Canvas { context, size in
                let w = size.width; let h = size.height
                let count = CGFloat(downsampled.count)
                let baseY = h - (1.0 / 3.0) * h
                var basePath = Path()
                basePath.move(to: CGPoint(x: 0, y: baseY))
                basePath.addLine(to: CGPoint(x: w, y: baseY))
                context.stroke(basePath, with: .color(.gray.opacity(0.3)), style: StrokeStyle(dash: [4, 4]))
                var path = Path()
                for (idx, (_, val)) in downsampled.enumerated() {
                    let x = CGFloat(idx) / count * w
                    let y = h - (CGFloat(val) / 3.0) * h
                    if idx == 0 { path.move(to: CGPoint(x: x, y: y)) }
                    else { path.addLine(to: CGPoint(x: x, y: y)) }
                }
                context.stroke(path, with: .color(Color(hex: 0x4ecca3)), lineWidth: 1)
            }
            .frame(height: 150)
        }
        .padding()
        .background(Color(hex: 0x16213e))
        .cornerRadius(12)
    }
}

// MARK: - Workout Picker
struct WorkoutPickerView: View {
    let session: RunSession
    @Binding var selectedWorkout: AppleWorkout?
    let onSelect: () -> Void
    @EnvironmentObject var healthKit: HealthKitManager
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            List {
                if healthKit.workouts.isEmpty {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Loading workouts from Apple Health...")
                            .foregroundColor(.gray)
                            .font(.caption)
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .onAppear {
                        healthKit.fetchRecentWorkouts()
                    }
                } else {
                    // Show workouts near the session time first
                    Section("Matching Time Range") {
                        ForEach(nearbyWorkouts) { workout in
                            workoutRow(workout, highlighted: true)
                        }
                    }
                    if !otherWorkouts.isEmpty {
                        Section("Other Recent Workouts") {
                            ForEach(otherWorkouts) { workout in
                                workoutRow(workout, highlighted: false)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Select Workout")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    // Workouts that overlap with the session time
    private var nearbyWorkouts: [AppleWorkout] {
        let margin: TimeInterval = 600 // 10 min tolerance
        let sessionStart = session.date
        let sessionEnd = session.endDate ?? sessionStart.addingTimeInterval(session.duration)
        return healthKit.workouts.filter { w in
            w.startDate < sessionEnd.addingTimeInterval(margin) &&
            w.endDate > sessionStart.addingTimeInterval(-margin)
        }
    }

    private var otherWorkouts: [AppleWorkout] {
        let nearbyIDs = Set(nearbyWorkouts.map(\.id))
        return healthKit.workouts.filter { !nearbyIDs.contains($0.id) }
    }

    private func workoutRow(_ workout: AppleWorkout, highlighted: Bool) -> some View {
        Button(action: {
            selectedWorkout = workout
            dismiss()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                onSelect()
            }
        }) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Image(systemName: iconFor(workout.activityType))
                            .foregroundColor(highlighted ? .pink : .gray)
                        Text(workout.activityName)
                            .font(.headline)
                        if highlighted {
                            Text("MATCH")
                                .font(.system(size: 9, weight: .bold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.green.opacity(0.2))
                                .foregroundColor(.green)
                                .cornerRadius(4)
                        }
                    }
                    Text(workout.dateString)
                        .font(.subheadline).foregroundColor(.gray)
                    HStack(spacing: 12) {
                        Text(workout.durationString).font(.caption).foregroundColor(.gray)
                        if workout.distanceKm > 0 {
                            Text(String(format: "%.2f km", workout.distanceKm))
                                .font(.caption).foregroundColor(.gray)
                        }
                        if workout.calories > 0 {
                            Text(String(format: "%.0f kcal", workout.calories))
                                .font(.caption).foregroundColor(.gray)
                        }
                    }
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundColor(.gray)
            }
            .padding(.vertical, 4)
        }
    }

    private func iconFor(_ type: HKWorkoutActivityType) -> String {
        switch type {
        case .running: return "figure.run"
        case .walking: return "figure.walk"
        case .cycling: return "figure.outdoor.cycle"
        case .hiking: return "figure.hiking"
        default: return "figure.mixed.cardio"
        }
    }
}

// MARK: - Share Sheet
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
