import SwiftUI
import Charts
import HealthKit

struct SessionListView: View {
    @EnvironmentObject var sessions: SessionStore
    @EnvironmentObject var coordinator: DeviceCoordinator

    private var imu: IMUSensorDriver? { coordinator.imuDriver }

    var body: some View {
        NavigationStack {
            Group {
                if sessions.sessions.isEmpty && imu?.appState != .downloading {
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
                        // Show active download at top of list
                        if imu?.appState == .downloading {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Downloading session...")
                                        .font(.headline)
                                    ProgressView(value: imu?.downloadProgress ?? 0)
                                        .tint(.cyan)
                                }
                                Spacer()
                                Text("\(Int(imu?.downloadProgress ?? 0 * 100))%")
                                    .font(.title3.monospacedDigit())
                                    .foregroundColor(.cyan)
                            }
                            .padding(.vertical, 4)
                            .listRowBackground(Color(hex: 0x16213e))
                        }
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
                            .listRowBackground(Color(hex: 0x16213e))
                        }
                        .onDelete { indexSet in
                            let toDelete = indexSet.map { sessions.sessions[$0] }
                            for session in toDelete {
                                sessions.deleteSession(session)
                            }
                        }
                    }
                    .scrollContentBackground(.hidden)
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
    @State private var shareURL: ShareableURL?

    private static let eventFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .medium
        return f
    }()
    @State private var samples: [RecordedSample] = []
    @State private var showWorkoutPicker = false
    @State private var selectedWorkout: AppleWorkout?
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

                // Comparison table (IMU vs Apple Health in 10s intervals)
                ComparisonTableView.build(
                    session: session,
                    analysis: analysis,
                    samples: samples,
                    appleData: appleData
                )

                // Apple Health comparison cards
                if let data = appleData {
                    comparisonView(data)

                    // Heart rate chart (standalone, always useful)
                    if !data.heartRateSamples.isEmpty {
                        InteractiveLineChart(
                            title: "Heart Rate",
                            series: [.fromTimestamped(data.heartRateSamples, name: "BPM", color: .red)],
                            yDomain: 40...200
                        )
                    }

                    // Distance
                    if !data.distanceSamples.isEmpty {
                        InteractiveLineChart(
                            title: "Cumulative Distance (m)",
                            series: [.fromTimestamped(data.distanceSamples, name: "Distance", color: .green)]
                        )
                    }
                }

                // Acceleration magnitude
                if !samples.isEmpty {
                    let accelSeries = ChartSeries.fromIMUSamples(samples, sessionStart: session.date,
                        name: "Accel (g)", color: Color(hex: 0x4ecca3)) { s in
                        let ax = Float(s.ax) * IMUPacket.accelScale
                        let ay = Float(s.ay) * IMUPacket.accelScale
                        let az = Float(s.az) * IMUPacket.accelScale
                        return Double(sqrtf(ax*ax + ay*ay + az*az))
                    }
                    InteractiveLineChart(
                        title: "Acceleration Magnitude",
                        series: [accelSeries],
                        yDomain: 0...4
                    )
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
            // Reload linked workout if saved
            if let wid = session.linkedWorkoutID, selectedWorkout == nil {
                healthKit.fetchWorkout(byID: wid) { workout in
                    selectedWorkout = workout
                    if let w = workout {
                        loadingAppleData = true
                        healthKit.fetchRunData(from: w.startDate, to: w.endDate) { data in
                            appleData = data
                            loadingAppleData = false
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showWorkoutPicker) {
            WorkoutPickerView(session: session, selectedWorkout: $selectedWorkout) {
                if let w = selectedWorkout {
                    // Persist the link
                    sessions.linkWorkout(w.id.uuidString, to: session.id)
                    loadingAppleData = true
                    healthKit.fetchRunData(from: w.startDate, to: w.endDate) { data in
                        appleData = data
                        loadingAppleData = false
                    }
                }
            }
        }
        .sheet(item: $shareURL) { item in
            ShareSheet(items: [item.url])
        }
    }

    // MARK: - Export
    private func exportCSV() {
        guard let url = sessions.exportCSV(session: session) else {
            print("CSV export failed: no samples")
            return
        }
        shareURL = ShareableURL(url: url)
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

            if let events = session.events, !events.isEmpty {
                Divider().background(Color.gray.opacity(0.3))
                VStack(alignment: .leading, spacing: 4) {
                    Text("DEVICE LOG").font(.caption2).foregroundColor(.gray)
                    ForEach(events) { event in
                        HStack(spacing: 8) {
                            Image(systemName: event.icon)
                                .font(.caption).foregroundColor(.gray)
                                .frame(width: 16)
                            Text(event.reasonString).font(.caption)
                            Spacer()
                            // H7: show as offset from session start
                            let secs = event.offsetMs / 1000
                            Text("+\(secs / 60):\(String(format: "%02d", secs % 60))")
                                .font(.caption2.monospacedDigit()).foregroundColor(.gray)
                        }
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
            Text("APPLE HEALTH WORKOUT").font(.caption2).foregroundColor(.gray)

            // Global stats
            HStack(spacing: 16) {
                if data.avgHeartRate > 0 {
                    statBadge(icon: "heart.fill", color: .red, value: String(format: "%.0f", data.avgHeartRate), unit: "bpm")
                }
                if data.activeCalories > 0 {
                    statBadge(icon: "flame.fill", color: .orange, value: String(format: "%.0f", data.activeCalories), unit: "kcal")
                }
            }

            // Per-source breakdown
            if !data.sources.isEmpty {
                Divider().background(Color.gray.opacity(0.3))
                Text("DATA SOURCES").font(.system(size: 9)).foregroundColor(.gray)

                ForEach(data.sources) { source in
                    HStack {
                        Text(source.sourceName)
                            .font(.caption).foregroundColor(.cyan)
                            .lineLimit(1)
                        Spacer()
                        if source.totalSteps > 0 {
                            VStack(alignment: .trailing) {
                                Text("\(source.totalSteps) steps").font(.caption2.monospacedDigit())
                                Text(String(format: "%.0f spm", source.avgCadence))
                                    .font(.system(size: 9).monospacedDigit()).foregroundColor(.gray)
                            }
                        }
                        if source.distanceKm > 0 {
                            Text(String(format: "%.2f km", source.distanceKm))
                                .font(.caption2.monospacedDigit()).foregroundColor(.green)
                                .padding(.leading, 8)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(Color(hex: 0x16213e))
        .cornerRadius(12)
    }

    private func statBadge(icon: String, color: Color, value: String, unit: String) -> some View {
        VStack {
            Image(systemName: icon).foregroundColor(color)
            Text(value).font(.headline.monospacedDigit())
            Text(unit).font(.caption2).foregroundColor(.gray)
        }
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
            .scrollContentBackground(.hidden)
            .background(Color(hex: 0x1a1a2e))
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
        .listRowBackground(Color(hex: 0x16213e))
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

struct ShareableURL: Identifiable {
    let id = UUID()
    let url: URL
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
