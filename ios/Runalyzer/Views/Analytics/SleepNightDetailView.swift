import SwiftUI
import Charts

/// Detail view for a single night's sleep — matches the 1D Sleep Dashboard layout.
struct SleepNightDetailView: View {
    let date: Date
    let stages: [(stage: String, start: Date, end: Date)]

    private let cal = Calendar.current

    var body: some View {
        let durations = stageDurations
        let deepMin = durations["Deep"] ?? 0
        let coreMin = durations["Core"] ?? 0
        let remMin = durations["REM"] ?? 0
        let awakeMin = durations["Awake"] ?? 0
        let asleepMin = deepMin + coreMin + remMin
        let inBedMin = asleepMin + awakeMin
        let eff = inBedMin > 0 ? asleepMin / inBedMin * 100 : 0

        let bt = stages.filter { ["Deep", "Core", "REM", "Asleep"].contains($0.stage) }
            .map(\.start).min()
        let score = SleepScore.fromStages(stages: stages)
        let scoreColor = sleepScoreColor(score.total)

        let deepPct = asleepMin > 0 ? deepMin / asleepMin * 100 : 0
        let corePct = asleepMin > 0 ? coreMin / asleepMin * 100 : 0
        let remPct = asleepMin > 0 ? remMin / asleepMin * 100 : 0

        ScrollView {
            VStack(spacing: 12) {
                // Card 1: Score + key stats
                VStack(spacing: 14) {
                    HStack(spacing: 16) {
                        scoreRing(score.total, color: scoreColor, size: 64)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(score.label).font(.headline).foregroundColor(scoreColor)
                            HStack(spacing: 12) {
                                miniStat("Duration", score.durationScore, 50)
                                miniStat("Consistency", score.consistencyScore, 30)
                                miniStat("Interruptions", score.interruptionScore, 20)
                            }
                        }
                        Spacer()
                    }
                    Divider().background(Color.gray.opacity(0.2))
                    HStack(spacing: 0) {
                        statCol(bt.map { formatTime($0) } ?? "--", "Bedtime")
                        statCol(formatMin(inBedMin), "In Bed")
                        statCol(formatMin(asleepMin), "Asleep")
                        statCol(String(format: "%.0f%%", eff), "Efficiency")
                    }
                }
                .padding()
                .background(Color(hex: 0x16213e))
                .cornerRadius(12)

                // Card 2: Stages + hypnogram
                VStack(spacing: 12) {
                    HStack(spacing: 0) {
                        stageColFull(formatMin(deepMin), String(format: "%.0f%%", deepPct), "Deep", "13–23%", .indigo)
                        stageColFull(formatMin(coreMin), String(format: "%.0f%%", corePct), "Core", "", .blue)
                        stageColFull(formatMin(remMin), String(format: "%.0f%%", remPct), "REM", "20–25%", .cyan)
                        stageColFull(formatMin(awakeMin), "", "Awake", "", .gray)
                    }

                    if !stages.isEmpty {
                        IntervalTimeline(
                            intervals: stages.map {
                                TimelineInterval(category: $0.stage, start: $0.start, end: $0.end)
                            },
                            categories: [
                                TimelineCategory(name: "Deep", color: .indigo, position: 0),
                                TimelineCategory(name: "Core", color: .blue, position: 1),
                                TimelineCategory(name: "REM", color: .cyan, position: 2),
                                TimelineCategory(name: "Awake", color: .gray, position: 3),
                            ]
                        )
                        .frame(height: 130)
                    }
                }
                .padding()
                .background(Color(hex: 0x16213e))
                .cornerRadius(12)
            }
            .padding()
        }
        .background(Color(hex: 0x1a1a2e))
        .navigationTitle(dateString(date))
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Helpers

    private var stageDurations: [String: Double] {
        var result: [String: Double] = [:]
        for s in stages {
            result[s.stage, default: 0] += s.end.timeIntervalSince(s.start) / 60
        }
        return result
    }

    private func scoreRing(_ score: Int, color: Color, size: CGFloat) -> some View {
        ZStack {
            Circle().stroke(Color.gray.opacity(0.2), lineWidth: 5).frame(width: size, height: size)
            Circle().trim(from: 0, to: CGFloat(score) / 100)
                .stroke(color, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .frame(width: size, height: size).rotationEffect(.degrees(-90))
            Text("\(score)").font(.title3.bold().monospacedDigit())
        }
    }

    private func miniStat(_ label: String, _ score: Int, _ max: Int) -> some View {
        VStack(spacing: 1) {
            Text("\(score)/\(max)").font(.caption2.bold().monospacedDigit())
            Text(label).font(.system(size: 8)).foregroundColor(.gray)
        }
    }

    private func statCol(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.subheadline.bold().monospacedDigit())
            Text(label).font(.caption2).foregroundColor(.gray)
        }
        .frame(maxWidth: .infinity)
    }

    private func stageColFull(_ duration: String, _ pct: String, _ label: String,
                              _ ref: String, _ color: Color) -> some View {
        VStack(spacing: 2) {
            Text(duration).font(.subheadline.bold().monospacedDigit())
            if !pct.isEmpty {
                Text(pct).font(.caption2.monospacedDigit()).foregroundColor(.gray)
            }
            HStack(spacing: 3) {
                Circle().fill(color).frame(width: 6, height: 6)
                Text(label).font(.caption2).foregroundColor(.gray)
            }
            if !ref.isEmpty {
                Text(ref).font(.system(size: 8)).foregroundColor(.gray.opacity(0.5))
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func sleepScoreColor(_ score: Int) -> Color {
        switch score {
        case 75...: return .green
        case 50...: return .cyan
        case 25...: return .orange
        default:    return .red
        }
    }

    private func formatMin(_ m: Double) -> String {
        let h = Int(m) / 60, min = Int(m) % 60
        return h > 0 ? "\(h)h \(String(format: "%02d", min))m" : "\(min)m"
    }

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private func formatTime(_ d: Date) -> String {
        Self.timeFmt.string(from: d)
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
