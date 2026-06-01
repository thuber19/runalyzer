import SwiftUI

// MARK: - Data Types

struct SourceCadence {
    let sourceName: String
    let cadence: Int?
    let steps: Int
}

struct ComparisonRow: Identifiable {
    let id = UUID()
    let timeLabel: String
    let startMs: UInt32
    let endMs: UInt32
    let imuCadence: Int?
    let imuSteps: Int
    let sourceCadences: [SourceCadence]
    let heartRate: Int?
    let accelPeak: Float?
    let samples: [RecordedSample]
}

// MARK: - Main View

struct ComparisonTableView: View {
    let rows: [ComparisonRow]
    let sourceNames: [String]
    let sessionDuration: String
    @State private var selectedRow: ComparisonRow?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("TIME-SLOT COMPARISON").font(.caption2).foregroundColor(.gray)
            Text("10-second intervals").font(.system(size: 9)).foregroundColor(.gray.opacity(0.6))

            // Use a List for proper native scrolling
            List {
                ForEach(rows) { row in
                    ComparisonRowView(
                        row: row,
                        sourceNames: sourceNames,
                        isExpanded: selectedRow?.id == row.id
                    )
                    .listRowBackground(Color(hex: 0x16213e))
                    .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            selectedRow = (selectedRow?.id == row.id) ? nil : row
                        }
                    }
                }
            }
            .listStyle(.plain)
            .frame(height: 500)

            // Summary
            summaryView
        }
        .padding()
        .background(Color(hex: 0x16213e))
        .cornerRadius(12)
    }

    private var summaryView: some View {
        VStack(spacing: 8) {
            Divider().background(Color.gray.opacity(0.3))

            let totalIMUSteps = rows.map(\.imuSteps).reduce(0, +)
            let imuCadences = rows.compactMap(\.imuCadence)
            let avgIMU = imuCadences.isEmpty ? 0 : imuCadences.reduce(0, +) / imuCadences.count

            // IMU summary
            HStack(spacing: 24) {
                VStack {
                    Text("\(totalIMUSteps)").font(.title3.bold().monospacedDigit()).foregroundColor(Color(hex: 0xe94560))
                    Text("IMU steps").font(.caption2).foregroundColor(.gray)
                }
                VStack {
                    Text("\(avgIMU)").font(.title3.bold().monospacedDigit()).foregroundColor(Color(hex: 0xe94560))
                    Text("Avg IMU SPM").font(.caption2).foregroundColor(.gray)
                }
            }

            // Per-source summaries
            ForEach(sourceNames, id: \.self) { name in
                let allSC = rows.flatMap { $0.sourceCadences.filter { $0.sourceName == name } }
                let validCadences = allSC.compactMap(\.cadence)
                let avgSPM = validCadences.isEmpty ? 0 : validCadences.reduce(0, +) / validCadences.count
                let totalSteps = allSC.map(\.steps).reduce(0, +)
                let label = shortName(name)

                HStack(spacing: 24) {
                    Text(label).font(.caption.bold()).foregroundColor(.cyan)
                        .frame(width: 55, alignment: .leading)
                    VStack {
                        Text("\(totalSteps)").font(.subheadline.monospacedDigit()).foregroundColor(.pink)
                        Text("steps").font(.system(size: 9)).foregroundColor(.gray)
                    }
                    VStack {
                        Text("\(avgSPM)").font(.subheadline.monospacedDigit()).foregroundColor(.pink)
                        Text("avg SPM").font(.system(size: 9)).foregroundColor(.gray)
                    }
                }
            }
        }
    }

    private func shortName(_ name: String) -> String {
        if name.lowercased().contains("watch") { return "Watch" }
        if name.lowercased().contains("iphone") { return "iPhone" }
        return String(name.prefix(8))
    }
}

// MARK: - Row View

struct ComparisonRowView: View {
    let row: ComparisonRow
    let sourceNames: [String]
    let isExpanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Compact row
            HStack {
                Text(row.timeLabel)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(isExpanded ? .white : .gray)
                    .frame(width: 65, alignment: .leading)

                Spacer()

                // IMU
                metric(value: row.imuCadence.map { "\($0)" }, label: "IMU", color: Color(hex: 0xe94560))

                // Each source
                ForEach(Array(sourceNames.enumerated()), id: \.offset) { _, name in
                    let sc = row.sourceCadences.first(where: { $0.sourceName == name })
                    let short = name.lowercased().contains("watch") ? "⌚" :
                                name.lowercased().contains("iphone") ? "📱" : "?"
                    metric(value: sc?.cadence.map { "\($0)" }, label: short, color: .pink)
                }

                // HR
                if let hr = row.heartRate {
                    Text("\(hr)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.red)
                        .frame(width: 30)
                } else {
                    Text("—").font(.system(size: 11)).foregroundColor(.gray.opacity(0.3)).frame(width: 30)
                }

                // Peak g
                Text(row.accelPeak.map { String(format: "%.1f", $0) } ?? "—")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(row.accelPeak != nil ? .orange : .gray.opacity(0.3))
                    .frame(width: 30, alignment: .trailing)
            }

            // Expanded detail
            if isExpanded {
                IMUDetailView(row: row)
                    .padding(.top, 6)
            }
        }
    }

    private func metric(value: String?, label: String, color: Color) -> some View {
        VStack(spacing: 1) {
            Text(value ?? "—")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(value != nil ? color : .gray.opacity(0.3))
            Text(label)
                .font(.system(size: 7))
                .foregroundColor(.gray)
        }
        .frame(width: 40)
    }
}

// MARK: - IMU Detail (expanded row)

struct IMUDetailView: View {
    let row: ComparisonRow

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(row.samples.count) samples · \(row.imuSteps) steps")
                .font(.caption2).foregroundColor(.cyan)

            if !row.samples.isEmpty {
                // Mini accel chart
                Canvas { context, size in
                    let w = size.width
                    let h = size.height
                    guard let first = row.samples.first?.timestamp else { return }
                    let last = row.samples.last?.timestamp ?? first
                    let range = max(1, Float(last - first))

                    var path = Path()
                    for (i, s) in row.samples.enumerated() {
                        let ax = Float(s.ax) * IMUPacket.accelScale
                        let ay = Float(s.ay) * IMUPacket.accelScale
                        let az = Float(s.az) * IMUPacket.accelScale
                        let mag = sqrtf(ax*ax + ay*ay + az*az)
                        let x = CGFloat(Float(s.timestamp - first) / range) * w
                        let y = h - CGFloat(mag / 4.0) * h
                        if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                        else { path.addLine(to: CGPoint(x: x, y: y)) }
                    }
                    context.stroke(path, with: .color(Color(hex: 0x4ecca3)), lineWidth: 1)
                }
                .frame(height: 60)
                .background(Color(hex: 0x0a1628))
                .cornerRadius(4)

                // First few raw samples
                let preview = Array(row.samples.prefix(10))
                VStack(spacing: 0) {
                    ForEach(Array(preview.enumerated()), id: \.offset) { _, s in
                        HStack(spacing: 0) {
                            Text("\(s.timestamp)ms").frame(width: 60, alignment: .leading)
                            Text("a[\(s.ax),\(s.ay),\(s.az)]").frame(maxWidth: .infinity, alignment: .leading)
                            Text("g[\(s.gx),\(s.gy),\(s.gz)]").frame(maxWidth: .infinity, alignment: .trailing)
                        }
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundColor(.white.opacity(0.5))
                    }
                    if row.samples.count > 10 {
                        Text("+ \(row.samples.count - 10) more")
                            .font(.system(size: 8)).foregroundColor(.gray).padding(.top, 2)
                    }
                }
            }
        }
        .padding(8)
        .background(Color(hex: 0x0a1628))
        .cornerRadius(6)
    }
}

// MARK: - Builder

extension ComparisonTableView {
    static func build(
        session: RunSession,
        analysis: RecordingAnalysis?,
        samples: [RecordedSample],
        appleData: AppleRunData?
    ) -> ComparisonTableView {
        let windowSec: Double = 10
        let duration = session.duration
        let windowCount = max(1, Int(ceil(duration / windowSec)))
        let sessionStart = session.date

        var rows: [ComparisonRow] = []

        for i in 0..<windowCount {
            let startSec = Double(i) * windowSec
            let endSec = min(startSec + windowSec, duration)
            let startMin = Int(startSec) / 60
            let startS = Int(startSec) % 60
            let endMin = Int(endSec) / 60
            let endS = Int(endSec) % 60
            let label = String(format: "%d:%02d-%d:%02d", startMin, startS, endMin, endS)

            let startMs = UInt32(startSec * 1000)
            let endMs = UInt32(endSec * 1000)

            // IMU
            var imuSteps = 0
            var imuCadence: Int? = nil
            var peakAccel: Float? = nil

            if let a = analysis {
                let stepsInWindow = a.steps.filter { $0.timestamp >= startMs && $0.timestamp < endMs }
                imuSteps = stepsInWindow.count
                let durMin = Float(endSec - startSec) / 60.0
                if durMin > 0 && imuSteps > 0 {
                    imuCadence = Int(Float(imuSteps) / durMin)
                }
                let accelInWindow = a.accelMag.filter { $0.timestamp >= startMs && $0.timestamp < endMs }
                peakAccel = accelInWindow.map(\.value).max()
            }

            // Apple per-source
            let windowStart = sessionStart.addingTimeInterval(startSec)
            let windowEnd = sessionStart.addingTimeInterval(endSec)
            let durMin = Float(endSec - startSec) / 60.0
            var sourceCadences: [SourceCadence] = []
            var heartRate: Int? = nil

            if let data = appleData {
                for source in data.sources {
                    let cInWindow = source.cadenceSamples.filter { $0.date >= windowStart && $0.date < windowEnd }
                    var cadence: Int? = nil
                    var steps = 0
                    if !cInWindow.isEmpty {
                        let avg = cInWindow.map(\.value).reduce(0, +) / Double(cInWindow.count)
                        cadence = Int(avg)
                        steps = Int(avg * Double(durMin))
                    }
                    sourceCadences.append(SourceCadence(sourceName: source.sourceName, cadence: cadence, steps: steps))
                }
                let hrInWindow = data.heartRateSamples.filter { $0.date >= windowStart && $0.date < windowEnd }
                if !hrInWindow.isEmpty {
                    heartRate = Int(hrInWindow.map(\.value).reduce(0, +) / Double(hrInWindow.count))
                }
            }

            let samplesInWindow = samples.filter { $0.timestamp >= startMs && $0.timestamp < endMs }

            rows.append(ComparisonRow(
                timeLabel: label, startMs: startMs, endMs: endMs,
                imuCadence: imuCadence, imuSteps: imuSteps,
                sourceCadences: sourceCadences,
                heartRate: heartRate, accelPeak: peakAccel,
                samples: samplesInWindow
            ))
        }

        let allSourceNames = appleData?.sources.map(\.sourceName) ?? []
        let m = Int(duration) / 60
        let s = Int(duration) % 60
        return ComparisonTableView(rows: rows, sourceNames: allSourceNames, sessionDuration: String(format: "%d:%02d", m, s))
    }
}
