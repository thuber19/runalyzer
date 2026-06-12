import SwiftUI
import Charts

/// Detail view for a single night's sleep showing stage timeline and duration breakdown.
struct SleepNightDetailView: View {
    let date: Date
    let stages: [(stage: String, start: Date, end: Date)]

    private let cal = Calendar.current

    private let stageOrder = ["Awake", "REM", "Core", "Deep"]
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

    private var timelineChart: some View {
        Chart(stages.indices, id: \.self) { i in
            let s = stages[i]
            let yValue = stageOrder.firstIndex(of: s.stage) ?? 0
            RectangleMark(
                xStart: .value("Start", s.start),
                xEnd: .value("End", s.end),
                yStart: .value("Stage", yValue),
                yEnd: .value("StageTop", yValue + 1)
            )
            .foregroundStyle(stageColors[s.stage] ?? .gray)
        }
        .chartYAxis {
            AxisMarks(values: [0, 1, 2, 3]) { value in
                AxisValueLabel {
                    if let idx = value.as(Int.self), idx < stageOrder.count {
                        Text(stageOrder[idx]).font(.caption2).foregroundColor(.gray)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { value in
                AxisValueLabel {
                    if let d = value.as(Date.self) {
                        Text(timeString(d)).font(.caption2).foregroundColor(.gray)
                    }
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
