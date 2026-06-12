import SwiftUI
import Charts

/// Detail view for a single night's sleep showing stage timeline and duration breakdown.
struct SleepNightDetailView: View {
    let date: Date
    let stages: [(stage: String, start: Date, end: Date)]

    private let cal = Calendar.current

    private let stageColors: [String: Color] = [
        "Deep": .indigo, "Core": .blue, "REM": .cyan, "Awake": .gray
    ]

    private static let sleepCategories: [TimelineCategory] = [
        TimelineCategory(name: "Deep", color: .indigo, position: 0),
        TimelineCategory(name: "Core", color: .blue, position: 1),
        TimelineCategory(name: "REM", color: .cyan, position: 2),
        TimelineCategory(name: "Awake", color: .gray, position: 3),
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                scoreCard
                summaryCard
                if !stages.isEmpty {
                    IntervalTimeline(
                        intervals: stages.map {
                            TimelineInterval(category: $0.stage, start: $0.start, end: $0.end)
                        },
                        categories: Self.sleepCategories
                    )
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

    // MARK: - Sleep Score

    private var scoreCard: some View {
        let result = SleepScore.fromStages(stages: stages)
        let scoreColor: Color = {
            switch result.total {
            case 75...: return .green
            case 50...: return .cyan
            case 25...: return .orange
            default:    return .red
            }
        }()

        return HStack(spacing: 16) {
            // Score ring
            ZStack {
                Circle()
                    .stroke(Color.gray.opacity(0.2), lineWidth: 5)
                    .frame(width: 56, height: 56)
                Circle()
                    .trim(from: 0, to: CGFloat(result.total) / 100)
                    .stroke(scoreColor, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .frame(width: 56, height: 56)
                    .rotationEffect(.degrees(-90))
                Text("\(result.total)")
                    .font(.title3.bold().monospacedDigit())
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(result.label).font(.headline).foregroundColor(scoreColor)
                HStack(spacing: 12) {
                    scoreComponent("Duration", result.durationScore, 50)
                    scoreComponent("Consistency", result.consistencyScore, 30)
                    scoreComponent("Interruptions", result.interruptionScore, 20)
                }
            }
            Spacer()
        }
        .padding()
        .background(Color(hex: 0x16213e))
        .cornerRadius(12)
        .padding(.horizontal)
    }

    private func scoreComponent(_ label: String, _ score: Int, _ max: Int) -> some View {
        VStack(spacing: 2) {
            Text("\(score)/\(max)").font(.caption.bold().monospacedDigit())
            Text(label).font(.system(size: 9)).foregroundColor(.gray)
        }
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
}
