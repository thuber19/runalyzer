import SwiftUI
import Charts

/// Recovery dashboard with today's score breakdown, component analysis, and trends.
struct RecoveryDashboardView: View {
    @EnvironmentObject var measurementStore: MeasurementStore
    @EnvironmentObject var sourcePrefs: SourcePreferenceStore

    @State private var timeRange: RecoveryRange = .day

    private var metricIndex: MetricIndex { MetricIndex(store: measurementStore) }
    private let cal = Calendar.current

    private enum RecoveryRange: String, CaseIterable {
        case day = "1D", week = "7D", month = "30D", quarter = "90D"
        var isDaily: Bool { self == .day }
        var days: Int {
            switch self {
            case .day: return 1
            case .week: return 7
            case .month: return 30
            case .quarter: return 90
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                rangePicker
                if timeRange.isDaily {
                    dailyView
                } else {
                    periodView
                }
            }
            .padding()
        }
        .background(Color(hex: 0x1a1a2e))
        .navigationTitle("Recovery")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - 1D: Today's Recovery

    private var dailyView: some View {
        let today = cal.startOfDay(for: Date())
        guard let dayEnd = cal.date(byAdding: .day, value: 1, to: today) else {
            return AnyView(noDataCard)
        }

        let scorePoint = metricIndex.query(type: DataType.recoveryIndex, from: today, to: dayEnd).first
        let hrvComp = metricIndex.query(type: DataType.recoveryHRVComponent, from: today, to: dayEnd).first?.value
        let rhrComp = metricIndex.query(type: DataType.recoveryRHRComponent, from: today, to: dayEnd).first?.value
        let confidence = metricIndex.query(type: DataType.recoveryConfidence, from: today, to: dayEnd).first?.value
        let baselineSDNN = metricIndex.query(type: DataType.recoveryBaselineSDNN, from: today, to: dayEnd).first?.value
        let baselineRHR = metricIndex.query(type: DataType.recoveryBaselineRHR, from: today, to: dayEnd).first?.value

        guard let score = scorePoint else {
            return AnyView(noDataCard)
        }

        let scoreInt = Int(score.value.rounded())
        let color = scoreColor(scoreInt)

        // Today's raw overnight HRV and RHR
        let overnightStart = cal.date(bySettingHour: 0, minute: 0, second: 0, of: Date())!
        let overnightEnd = cal.date(bySettingHour: 6, minute: 0, second: 0, of: Date())!
        let hrvPoints = metricIndex.query(type: DataType.hrvSDNN, measurementType: .metric,
                                           from: overnightStart, to: overnightEnd)
        let rhrPoints = metricIndex.query(type: DataType.restingHeartRate, measurementType: .metric,
                                           from: overnightStart, to: overnightEnd)
        let overnightSDNN = hrvPoints.isEmpty ? nil : hrvPoints.map(\.value).reduce(0, +) / Double(hrvPoints.count)
        let overnightRHR = rhrPoints.map(\.value).min()

        // Yesterday's score for comparison
        let yesterday = cal.date(byAdding: .day, value: -1, to: today)!
        let yesterdayScore = metricIndex.query(type: DataType.recoveryIndex, from: yesterday, to: today).first?.value

        // 7D sparkline
        let weekAgo = cal.date(byAdding: .day, value: -7, to: today)!
        let weekScores = metricIndex.query(type: DataType.recoveryIndex, from: weekAgo, to: dayEnd)

        return AnyView(VStack(spacing: 12) {
            // Card 1: Score + components
            VStack(spacing: 14) {
                HStack(spacing: 16) {
                    scoreRing(scoreInt, color: color, size: 72)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 4) {
                            Text(scoreLabel(scoreInt))
                                .font(.headline).foregroundColor(color)
                            if let y = yesterdayScore {
                                let diff = score.value - y
                                Text(String(format: "%+.0f", diff))
                                    .font(.caption.bold().monospacedDigit())
                                    .foregroundColor(diff >= 0 ? .green : .orange)
                            }
                        }
                        HStack(spacing: 16) {
                            componentStat("HRV", hrvComp, color: .cyan)
                            componentStat("RHR", rhrComp, color: .purple)
                        }
                    }
                    Spacer()
                }

                if weekScores.count > 1 {
                    ScrubbingLineChart(
                        data: weekScores.map { ChartDataPoint(date: $0.timestamp, avg: $0.value) },
                        color: color, unit: "", dateFormat: "EEE", showBand: false
                    )
                    .frame(height: 100)
                }
            }
            .padding()
            .background(Color(hex: 0x16213e))
            .cornerRadius(12)

            // Card 2: Overnight inputs
            VStack(alignment: .leading, spacing: 10) {
                Text("OVERNIGHT VITALS").font(.caption2).foregroundColor(.gray)
                HStack(spacing: 0) {
                    if let sdnn = overnightSDNN {
                        statCol(String(format: "%.0f ms", sdnn), "HRV (SDNN)")
                    }
                    if let rhr = overnightRHR {
                        statCol(String(format: "%.0f bpm", rhr), "Resting HR")
                    }
                }

                if baselineSDNN != nil || baselineRHR != nil {
                    Divider().background(Color.gray.opacity(0.2))
                    Text("30-DAY BASELINE").font(.system(size: 9)).foregroundColor(.gray.opacity(0.6))
                    HStack(spacing: 0) {
                        if let bs = baselineSDNN {
                            statCol(String(format: "%.0f ms", bs), "Avg SDNN")
                        }
                        if let br = baselineRHR {
                            statCol(String(format: "%.0f bpm", br), "Avg RHR")
                        }
                    }
                }
            }
            .padding()
            .background(Color(hex: 0x16213e))
            .cornerRadius(12)

            // Card 3: Confidence
            if let conf = confidence {
                HStack {
                    Image(systemName: conf >= 0.7 ? "checkmark.shield.fill" : "exclamationmark.triangle.fill")
                        .foregroundColor(conf >= 0.7 ? .green : .orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Data Confidence: \(Int(conf * 100))%")
                            .font(.subheadline.bold())
                        Text(confidenceDescription(conf))
                            .font(.caption).foregroundColor(.gray)
                    }
                    Spacer()
                }
                .padding()
                .background(Color(hex: 0x16213e))
                .cornerRadius(12)
            }

            // Card 4: Insights
            dailyInsights(score: scoreInt, hrvComp: hrvComp, rhrComp: rhrComp,
                           overnightSDNN: overnightSDNN, baselineSDNN: baselineSDNN,
                           confidence: confidence)
        })
    }

    // MARK: - Period View

    private var periodView: some View {
        let today = cal.startOfDay(for: Date())
        let lookback = cal.date(byAdding: .day, value: -timeRange.days, to: today)!
        let dayEnd = cal.date(byAdding: .day, value: 1, to: today) ?? today

        let scores = metricIndex.query(type: DataType.recoveryIndex, from: lookback, to: dayEnd)
        let hrvComps = metricIndex.query(type: DataType.recoveryHRVComponent, from: lookback, to: dayEnd)
        let rhrComps = metricIndex.query(type: DataType.recoveryRHRComponent, from: lookback, to: dayEnd)

        guard !scores.isEmpty else {
            return AnyView(noDataCard)
        }

        let values = scores.map(\.value)
        let avg = values.reduce(0, +) / Double(values.count)
        let minVal = values.min() ?? 0
        let maxVal = values.max() ?? 0
        let avgInt = Int(avg.rounded())
        let color = scoreColor(avgInt)

        let hrvAvg = hrvComps.isEmpty ? nil : hrvComps.map(\.value).reduce(0, +) / Double(hrvComps.count)
        let rhrAvg = rhrComps.isEmpty ? nil : rhrComps.map(\.value).reduce(0, +) / Double(rhrComps.count)

        // Trend direction
        let trend: String
        let trendIcon: String
        let trendColor: Color
        if scores.count >= 3 {
            let firstHalf = Array(scores.prefix(scores.count / 2)).map(\.value)
            let secondHalf = Array(scores.suffix(scores.count / 2)).map(\.value)
            let firstAvg = firstHalf.reduce(0, +) / Double(firstHalf.count)
            let secondAvg = secondHalf.reduce(0, +) / Double(secondHalf.count)
            let diff = secondAvg - firstAvg
            if diff > 3 {
                trend = "Improving"; trendIcon = "arrow.up.right"; trendColor = .green
            } else if diff < -3 {
                trend = "Declining"; trendIcon = "arrow.down.right"; trendColor = .orange
            } else {
                trend = "Stable"; trendIcon = "arrow.right"; trendColor = .gray
            }
        } else {
            trend = "Stable"; trendIcon = "arrow.right"; trendColor = .gray
        }

        return AnyView(VStack(spacing: 12) {
            // Trend header
            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: trendIcon).font(.title2)
                    Text(trend).font(.title2.weight(.semibold))
                }
                .foregroundColor(trendColor)

                HStack(spacing: 0) {
                    statCol("\(avgInt)", "Avg", color)
                    statCol("\(Int(minVal.rounded()))", "Low")
                    statCol("\(Int(maxVal.rounded()))", "High")
                    statCol("\(scores.count)", "Days")
                }
            }
            .padding()
            .background(Color(hex: 0x16213e))
            .cornerRadius(12)

            // Score trend chart
            if scores.count > 1 {
                VStack(alignment: .leading, spacing: 8) {
                    Text("RECOVERY TREND").font(.caption2).foregroundColor(.gray)
                    ScrubbingLineChart(
                        data: scores.map { ChartDataPoint(date: $0.timestamp, avg: $0.value) },
                        color: color, unit: "", showBand: false
                    )
                    .frame(height: 160)
                }
                .padding()
                .background(Color(hex: 0x16213e))
                .cornerRadius(12)
            }

            // Component averages
            if hrvAvg != nil || rhrAvg != nil {
                VStack(alignment: .leading, spacing: 10) {
                    Text("COMPONENT AVERAGES").font(.caption2).foregroundColor(.gray)
                    HStack(spacing: 0) {
                        if let h = hrvAvg {
                            VStack(spacing: 4) {
                                Text(String(format: "%.0f", h)).font(.title3.bold().monospacedDigit())
                                    .foregroundColor(.cyan)
                                Text("/ 100").font(.caption2).foregroundColor(.gray)
                                Text("HRV Component").font(.caption2).foregroundColor(.gray)
                            }
                            .frame(maxWidth: .infinity)
                        }
                        if let r = rhrAvg {
                            VStack(spacing: 4) {
                                Text(String(format: "%.0f", r)).font(.title3.bold().monospacedDigit())
                                    .foregroundColor(.purple)
                                Text("/ 100").font(.caption2).foregroundColor(.gray)
                                Text("RHR Component").font(.caption2).foregroundColor(.gray)
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                }
                .padding()
                .background(Color(hex: 0x16213e))
                .cornerRadius(12)
            }

            // Period insights
            periodInsights(avg: avg, minVal: minVal, trend: trend, scores: scores)
        })
    }

    // MARK: - Insights

    private func dailyInsights(score: Int, hrvComp: Double?, rhrComp: Double?,
                                overnightSDNN: Double?, baselineSDNN: Double?,
                                confidence: Double?) -> some View {
        var insights: [(icon: String, text: String, color: Color)] = []

        if score >= 75 {
            insights.append(("checkmark.circle", "Well recovered. Good day for intense training.", .green))
        } else if score >= 50 {
            insights.append(("info.circle", "Moderate recovery. Listen to your body during training.", .cyan))
        } else {
            insights.append(("exclamationmark.triangle", "Low recovery. Consider rest or light activity today.", .orange))
        }

        if let h = hrvComp, let r = rhrComp {
            if h < 40 && r >= 60 {
                insights.append(("waveform.path.ecg", "HRV is low while RHR looks fine. Stress or poor sleep quality may be a factor.", .orange))
            } else if r < 40 && h >= 60 {
                insights.append(("heart", "Elevated resting HR. Could indicate illness onset, dehydration, or overtraining.", .orange))
            }
        }

        if let sdnn = overnightSDNN, let baseline = baselineSDNN, baseline > 0 {
            let pctDiff = (sdnn - baseline) / baseline * 100
            if pctDiff > 20 {
                insights.append(("arrow.up.circle", String(format: "Overnight HRV is %.0f%% above your baseline. Strong recovery signal.", pctDiff), .green))
            } else if pctDiff < -20 {
                insights.append(("arrow.down.circle", String(format: "Overnight HRV is %.0f%% below baseline. Your body may need more rest.", abs(pctDiff)), .orange))
            }
        }

        if let conf = confidence, conf < 0.5 {
            insights.append(("questionmark.circle", "Limited data available. Wear your watch overnight for more accurate scores.", .gray))
        }

        guard !insights.isEmpty else { return AnyView(EmptyView()) }
        return AnyView(insightsCardView(insights))
    }

    private func periodInsights(avg: Double, minVal: Double, trend: String,
                                 scores: [DataPoint]) -> some View {
        var insights: [(icon: String, text: String, color: Color)] = []

        if trend == "Improving" {
            insights.append(("arrow.up.right.circle", "Recovery is trending upward. Your training and rest balance is working.", .green))
        } else if trend == "Declining" {
            insights.append(("arrow.down.right.circle", "Recovery has been declining. Consider reducing training load or improving sleep.", .orange))
        }

        if avg >= 70 {
            insights.append(("checkmark.circle", String(format: "Average recovery of %.0f is strong. You're managing stress and rest well.", avg), .green))
        } else if avg < 45 {
            insights.append(("exclamationmark.triangle", String(format: "Average recovery of %.0f is low. Review your sleep, nutrition, and training load.", avg), .orange))
        }

        if minVal < 25 {
            insights.append(("exclamationmark.circle", String(format: "Recovery dropped as low as %.0f. Identify what caused the dip.", minVal), .orange))
        }

        // Consistency check
        let values = scores.map(\.value)
        if values.count >= 5 {
            let mean = values.reduce(0, +) / Double(values.count)
            let variance = values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(values.count)
            let sd = sqrt(variance)
            if sd > 20 {
                insights.append(("arrow.up.and.down", "Recovery is highly variable. Consistent sleep and habits help stabilize it.", .orange))
            } else if sd < 8 {
                insights.append(("equal.circle", "Very consistent recovery. Your routine is well dialed in.", .green))
            }
        }

        guard !insights.isEmpty else { return AnyView(EmptyView()) }
        return AnyView(insightsCardView(insights))
    }

    // MARK: - Components

    private func componentStat(_ label: String, _ value: Double?, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundColor(.gray)
            if let v = value {
                Text("\(Int(v.rounded()))/100")
                    .font(.subheadline.bold().monospacedDigit())
                    .foregroundColor(color)
            } else {
                Text("--").font(.subheadline.bold()).foregroundColor(.gray)
            }
        }
    }

    private func scoreRing(_ score: Int, color: Color, size: CGFloat) -> some View {
        ZStack {
            Circle().stroke(Color.gray.opacity(0.2), lineWidth: 5)
                .frame(width: size, height: size)
            Circle().trim(from: 0, to: CGFloat(score) / 100)
                .stroke(color, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .frame(width: size, height: size).rotationEffect(.degrees(-90))
            Text("\(score)").font(.title2.bold().monospacedDigit())
        }
    }

    private func statCol(_ value: String, _ label: String, _ color: Color = .white) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.subheadline.bold().monospacedDigit()).foregroundColor(color)
            Text(label).font(.caption2).foregroundColor(.gray)
        }
        .frame(maxWidth: .infinity)
    }

    private func insightsCardView(_ insights: [(icon: String, text: String, color: Color)]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("INSIGHTS").font(.caption2).foregroundColor(.gray)
            ForEach(insights.indices, id: \.self) { i in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: insights[i].icon)
                        .font(.caption).foregroundColor(insights[i].color).frame(width: 16)
                    Text(insights[i].text)
                        .font(.caption).foregroundColor(.white.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if i < insights.count - 1 {
                    Divider().background(Color.gray.opacity(0.2))
                }
            }
        }
        .padding()
        .background(Color(hex: 0x16213e))
        .cornerRadius(12)
    }

    private var noDataCard: some View {
        Text("No recovery data").font(.caption).foregroundColor(.gray)
            .frame(maxWidth: .infinity).padding()
            .background(Color(hex: 0x16213e)).cornerRadius(12)
    }

    private var rangePicker: some View {
        Picker("Range", selection: $timeRange) {
            ForEach(RecoveryRange.allCases, id: \.self) { r in
                Text(r.rawValue).tag(r)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal)
    }

    private func scoreColor(_ score: Int) -> Color {
        switch score {
        case 75...: return .green
        case 50...: return .cyan
        case 25...: return .orange
        default:    return .red
        }
    }

    private func scoreLabel(_ score: Int) -> String {
        switch score {
        case 75...: return "Excellent"
        case 50...: return "Good"
        case 25...: return "Fair"
        default:    return "Poor"
        }
    }

    private func confidenceDescription(_ conf: Double) -> String {
        if conf >= 0.9 { return "Excellent data quality — full overnight HRV and RHR readings." }
        if conf >= 0.7 { return "Good data quality — most overnight readings captured." }
        if conf >= 0.5 { return "Moderate data quality — some readings missing." }
        return "Limited data — wear your watch overnight for better accuracy."
    }
}
