import SwiftUI
import Charts

/// Detail view for a single night's sleep showing stage timeline and duration breakdown.
struct SleepNightDetailView: View {
    let date: Date
    let stages: [(stage: String, start: Date, end: Date)]

    @State private var scrubDate: Date?

    private let cal = Calendar.current

    // Bottom to top: Deep=0, Core=1, REM=2, Awake=3 (matches Apple Health layout)
    private let stageYPosition: [String: Int] = ["Deep": 0, "Core": 1, "REM": 2, "Awake": 3]
    private let stageLabels = ["Deep", "Core", "REM", "Awake"] // index 0..3, bottom to top
    private let stageColors: [String: Color] = [
        "Deep": .indigo, "Core": .blue, "REM": .cyan, "Awake": .gray
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                summaryCard
                if !stages.isEmpty {
                    timelineChart
                        .frame(height: 160)
                        .padding(.horizontal)
                    stageBreakdownCard
                }
            }
            .padding(.vertical)
        }
        .background(Color(hex: 0x1a1a2e))
        .navigationTitle(dateString(date))
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Summary

    private var summaryCard: some View {
        let durations = stageDurations
        let asleep = (durations["Deep"] ?? 0) + (durations["Core"] ?? 0) + (durations["REM"] ?? 0)
        let awake = durations["Awake"] ?? 0
        let inBed = asleep + awake

        return HStack(spacing: 0) {
            statCol(formatMin(inBed), "In Bed")
            statCol(formatMin(asleep), "Asleep")
            statCol(formatMin(durations["Deep"] ?? 0), "Deep", .indigo)
            statCol(formatMin(durations["REM"] ?? 0), "REM", .cyan)
        }
        .padding()
        .background(Color(hex: 0x16213e))
        .cornerRadius(12)
        .padding(.horizontal)
    }

    // MARK: - Hypnogram Timeline

    private var nightRange: (start: Date, end: Date) {
        guard let first = stages.first?.start, let last = stages.last?.end else {
            return (Date(), Date())
        }
        // Round down to the previous hour, round up to the next hour
        let startHour = cal.dateInterval(of: .hour, for: first)?.start ?? first
        let endHour: Date = {
            let interval = cal.dateInterval(of: .hour, for: last)
            if let s = interval?.start, s == last { return last }
            return cal.date(byAdding: .hour, value: 1, to: interval?.start ?? last) ?? last
        }()
        return (startHour, endHour)
    }

    private var hourlyMarks: [Date] {
        let range = nightRange
        var marks: [Date] = []
        var cursor = range.start
        while cursor <= range.end {
            marks.append(cursor)
            guard let next = cal.date(byAdding: .hour, value: 1, to: cursor) else { break }
            cursor = next
        }
        return marks
    }

    /// Stage at a given time for scrubbing display.
    private func stageAt(_ date: Date) -> String? {
        stages.first { date >= $0.start && date < $0.end }?.stage
    }

    private var timelineChart: some View {
        let range = nightRange

        return VStack(spacing: 4) {
            // Scrub indicator
            if let scrub = scrubDate, let stage = stageAt(scrub) {
                HStack(spacing: 6) {
                    Circle().fill(stageColors[stage] ?? .gray).frame(width: 8, height: 8)
                    Text(stage).font(.caption.bold())
                    Text(timeString(scrub)).font(.caption.monospacedDigit()).foregroundColor(.gray)
                }
                .frame(maxWidth: .infinity)
                .transition(.opacity)
            }

            Chart(stages.indices, id: \.self) { i in
                let s = stages[i]
                let y = stageYPosition[s.stage] ?? 0
                RectangleMark(
                    xStart: .value("Start", s.start),
                    xEnd: .value("End", s.end),
                    yStart: .value("Stage", y),
                    yEnd: .value("StageTop", y + 1)
                )
                .foregroundStyle(stageColors[s.stage] ?? .gray)

                // Scrub rule line
                if let scrub = scrubDate {
                    RuleMark(x: .value("Scrub", scrub))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                }
            }
            .chartYScale(domain: 0...4)
            .chartYAxis {
                AxisMarks(position: .leading, values: [0.5, 1.5, 2.5, 3.5]) { value in
                    AxisValueLabel {
                        if let v = value.as(Double.self) {
                            let idx = Int(v - 0.5)
                            if idx >= 0 && idx < stageLabels.count {
                                Text(stageLabels[idx]).font(.caption2).foregroundColor(.gray)
                            }
                        }
                    }
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3]))
                        .foregroundStyle(Color.gray.opacity(0.3))
                }
            }
            .chartXScale(domain: range.start...range.end)
            .chartXAxis {
                AxisMarks(values: hourlyMarks) { value in
                    AxisValueLabel {
                        if let d = value.as(Date.self) {
                            Text(timeString(d)).font(.caption2).foregroundColor(.gray)
                        }
                    }
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3]))
                        .foregroundStyle(Color.gray.opacity(0.2))
                }
            }
            .chartOverlay { proxy in
                GeometryReader { geo in
                    Rectangle()
                        .fill(Color.clear)
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { drag in
                                    let x = drag.location.x - geo[proxy.plotAreaFrame].origin.x
                                    if let d: Date = proxy.value(atX: x) {
                                        scrubDate = d
                                    }
                                }
                                .onEnded { _ in
                                    scrubDate = nil
                                }
                        )
                }
            }
        }
    }

    // MARK: - Stage Breakdown

    private var stageBreakdownCard: some View {
        let durations = stageDurations
        let total = durations.values.reduce(0, +)

        return VStack(alignment: .leading, spacing: 12) {
            Text("STAGE BREAKDOWN").font(.caption2).foregroundColor(.gray)

            ForEach(["Deep", "Core", "REM", "Awake"], id: \.self) { stage in
                let minutes = durations[stage] ?? 0
                let pct = total > 0 ? minutes / total : 0

                HStack {
                    Circle().fill(stageColors[stage] ?? .gray).frame(width: 8, height: 8)
                    Text(stage).font(.subheadline)
                    Spacer()
                    Text(formatMin(minutes))
                        .font(.subheadline.monospacedDigit()).foregroundColor(.gray)
                    Text(String(format: "%.0f%%", pct * 100))
                        .font(.caption.monospacedDigit()).foregroundColor(.gray)
                        .frame(width: 40, alignment: .trailing)
                }

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.gray.opacity(0.2))
                        RoundedRectangle(cornerRadius: 3)
                            .fill(stageColors[stage] ?? .gray)
                            .frame(width: geo.size.width * CGFloat(pct))
                    }
                }
                .frame(height: 6)
            }
        }
        .padding()
        .background(Color(hex: 0x16213e))
        .cornerRadius(12)
        .padding(.horizontal)
    }

    // MARK: - Helpers

    private var stageDurations: [String: Double] {
        var result: [String: Double] = [:]
        for s in stages {
            result[s.stage, default: 0] += s.end.timeIntervalSince(s.start) / 60
        }
        return result
    }

    private func statCol(_ value: String, _ label: String, _ color: Color = .white) -> some View {
        VStack(spacing: 4) {
            Text(value).font(.headline.monospacedDigit())
            Text(label).font(.caption2).foregroundColor(color == .white ? .gray : color)
        }
        .frame(maxWidth: .infinity)
    }

    private func formatMin(_ m: Double) -> String {
        let h = Int(m) / 60, min = Int(m) % 60
        return h > 0 ? "\(h)h \(String(format: "%02d", min))m" : "\(min)m"
    }

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "E, d MMM yyyy"
        return f
    }()

    private func dateString(_ d: Date) -> String {
        Self.dateFmt.string(from: d)
    }

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private func timeString(_ d: Date) -> String {
        Self.timeFmt.string(from: d)
    }
}
