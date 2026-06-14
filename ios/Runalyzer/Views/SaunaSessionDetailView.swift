import SwiftUI
import Charts
import HealthKit

/// A parsed round from DataPoints for display.
private struct SaunaRoundInfo: Identifiable {
    let id: Int
    let type: SaunaRoundType
    let start: Date
    let end: Date
    let duration: TimeInterval
}

/// A heart rate sample for charting.
private struct HRSample: Identifiable {
    let id: Date
    let bpm: Double
    var date: Date { id }
}

/// Detail view for a sauna session showing round timeline and heart rate chart.
struct SaunaSessionDetailView: View {
    let measurement: SensorMeasurement
    @EnvironmentObject var healthKit: HealthKitManager

    @State private var hrSamples: [HRSample] = []
    @State private var isLoadingHR = true
    @State private var scrubSample: HRSample?

    private var rounds: [SaunaRoundInfo] {
        measurement.dataPoints
            .filter { $0.type == DataType.saunaRound }
            .compactMap { dp -> (SaunaRoundType, Date, Date, TimeInterval)? in
                guard let roundType = SaunaRoundType(rawValue: dp.unit),
                      let end = dp.endTimestamp else { return nil }
                return (roundType, dp.timestamp, end, dp.value)
            }
            .sorted { $0.1 < $1.1 }
            .enumerated()
            .map { SaunaRoundInfo(id: $0.offset, type: $0.element.0, start: $0.element.1, end: $0.element.2, duration: $0.element.3) }
    }

    private var sessionStart: Date? { rounds.first?.start }
    private var sessionEnd: Date? { rounds.last?.end }
    private var totalDuration: TimeInterval { rounds.reduce(0) { $0 + $1.duration } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headerSection
                if !rounds.isEmpty { roundTimelineSection }
                if !hrSamples.isEmpty { heartRateSection }
                if !rounds.isEmpty { roundDetailsSection }
            }
            .padding()
        }
        .navigationTitle("Sauna Session")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { loadHeartRate() }
    }

    // MARK: - Sections

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(measurement.date.formatted(date: .long, time: .shortened))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack(spacing: 16) {
                Label("\(rounds.count) rounds", systemImage: "flame.fill")
                Label(formatDuration(totalDuration), systemImage: "clock")
            }
            .font(.headline)
        }
    }

    private var roundTimelineSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Timeline")
                .font(.caption)
                .foregroundStyle(.secondary)

            GeometryReader { geo in
                timelineBar(width: geo.size.width)
            }
            .frame(height: 28)

            // Legend
            HStack(spacing: 12) {
                ForEach(uniqueRoundTypes, id: \.rawValue) { type in
                    HStack(spacing: 4) {
                        Circle().fill(type.color).frame(width: 8, height: 8)
                        Text(type.label).font(.caption2)
                    }
                }
            }
            .foregroundStyle(.secondary)
        }
    }

    private var heartRateSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Scrub label or title
            if let sample = scrubSample {
                let roundName = roundAt(date: sample.date)?.type.label ?? ""
                HStack {
                    Text("\(Int(sample.bpm)) bpm")
                        .font(.headline)
                        .foregroundStyle(.red)
                    if !roundName.isEmpty {
                        Text("· \(roundName)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(sample.date.formatted(date: .omitted, time: .standard))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Heart Rate")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            hrChart
                .frame(height: 200)

            HStack(spacing: 20) {
                statLabel("Avg", value: "\(Int(hrAvg)) bpm")
                statLabel("Min", value: "\(Int(hrMin)) bpm")
                statLabel("Max", value: "\(Int(hrMax)) bpm")
            }
        }
    }

    private var hrChart: some View {
        let minBPM = hrMin
        let maxBPM = hrMax
        return Chart {
            ForEach(rounds) { round in
                RectangleMark(
                    xStart: .value("S", round.start),
                    xEnd: .value("E", round.end),
                    yStart: .value("Lo", minBPM),
                    yEnd: .value("Hi", maxBPM)
                )
                .foregroundStyle(round.type.color.opacity(0.12))
            }

            ForEach(hrSamples) { sample in
                LineMark(
                    x: .value("Time", sample.date),
                    y: .value("BPM", sample.bpm)
                )
                .foregroundStyle(.red)
                .lineStyle(StrokeStyle(lineWidth: 1.5))
            }

            if let scrub = scrubSample {
                RuleMark(x: .value("Scrub", scrub.date))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                PointMark(x: .value("Scrub", scrub.date), y: .value("BPM", scrub.bpm))
                    .foregroundStyle(.white)
                    .symbolSize(50)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading)
        }
        .chartXAxis {
            AxisMarks { _ in
                AxisValueLabel(format: .dateTime.hour().minute())
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
                                guard let plotFrame = proxy.plotFrame else { return }
                                let x = drag.location.x - geo[plotFrame].origin.x
                                guard let date: Date = proxy.value(atX: x) else { return }
                                scrubSample = hrSamples.min(by: {
                                    abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date))
                                })
                            }
                            .onEnded { _ in
                                scrubSample = nil
                            }
                    )
            }
        }
    }

    private func roundAt(date: Date) -> SaunaRoundInfo? {
        rounds.first { $0.start <= date && date <= $0.end }
    }

    private var roundDetailsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Rounds")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(rounds) { round in
                roundRow(round)
            }
        }
    }

    private func roundRow(_ round: SaunaRoundInfo) -> some View {
        let avgHR = hrForRound(start: round.start, end: round.end)
        return HStack {
            Image(systemName: round.type.icon)
                .foregroundStyle(round.type.color)
                .frame(width: 24)
            Text(round.type.label)
                .font(.subheadline)
            Spacer()
            Text(formatDuration(round.duration))
                .font(.subheadline.monospaced())
                .foregroundStyle(.secondary)
            if let hr = avgHR {
                Text("\(Int(hr)) bpm")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(width: 60, alignment: .trailing)
            }
        }
    }

    // MARK: - Timeline

    private func timelineBar(width: CGFloat) -> some View {
        let totalWidth = width - CGFloat(max(rounds.count - 1, 0)) * 2
        return HStack(spacing: 2) {
            ForEach(rounds) { round in
                let fraction = totalDuration > 0 ? round.duration / totalDuration : 0
                let segmentWidth = max(4, totalWidth * fraction)
                RoundedRectangle(cornerRadius: 4)
                    .fill(round.type.color)
                    .frame(width: segmentWidth)
                    .overlay {
                        if fraction > 0.15 {
                            Text(formatShortDuration(round.duration))
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(.white)
                        }
                    }
            }
        }
    }

    // MARK: - Helpers

    private var uniqueRoundTypes: [SaunaRoundType] {
        var seen = Set<String>()
        return rounds.compactMap { round in
            guard seen.insert(round.type.rawValue).inserted else { return nil }
            return round.type
        }
    }

    private var hrAvg: Double {
        guard !hrSamples.isEmpty else { return 0 }
        return hrSamples.map(\.bpm).reduce(0, +) / Double(hrSamples.count)
    }

    private var hrMin: Double { hrSamples.map(\.bpm).min() ?? 0 }
    private var hrMax: Double { hrSamples.map(\.bpm).max() ?? 0 }

    private func hrForRound(start: Date, end: Date) -> Double? {
        let samples = hrSamples.filter { $0.date >= start && $0.date <= end }
        guard !samples.isEmpty else { return nil }
        return samples.map(\.bpm).reduce(0, +) / Double(samples.count)
    }

    private func loadHeartRate() {
        guard let start = sessionStart, let end = sessionEnd else {
            isLoadingHR = false
            return
        }
        let paddedStart = start.addingTimeInterval(-60)
        let paddedEnd = end.addingTimeInterval(60)

        healthKit.fetchMetricSamples(
            identifier: .heartRate,
            unit: HKUnit.count().unitDivided(by: .minute()),
            from: paddedStart, to: paddedEnd
        ) { samples in
            DispatchQueue.main.async {
                self.hrSamples = samples.map { HRSample(id: $0.timestamp, bpm: $0.value) }
                self.isLoadingHR = false
            }
        }
    }

    private func statLabel(_ title: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.caption.bold())
        }
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return String(format: "%d:%02d", m, s)
    }

    private func formatShortDuration(_ seconds: TimeInterval) -> String {
        "\(Int(seconds) / 60)m"
    }
}
