import SwiftUI
import Charts

/// A single interval for the timeline chart.
struct TimelineInterval {
    let category: String
    let start: Date
    let end: Date
}

/// Configuration for an interval category (label position, color).
struct TimelineCategory {
    let name: String
    let color: Color
    /// Y position (0 = bottom). Categories are stacked bottom-to-top.
    let position: Int
}

/// Interactive stacked-interval timeline chart with drag-to-scrub.
///
/// Used for sleep hypnograms, HR zone timelines, activity timelines, etc.
/// Each interval is a colored rectangle at a fixed Y position, spanning a time range.
///
/// Usage:
/// ```
/// IntervalTimeline(
///     intervals: stages.map { TimelineInterval(category: $0.stage, start: $0.start, end: $0.end) },
///     categories: [
///         TimelineCategory(name: "Deep", color: .indigo, position: 0),
///         TimelineCategory(name: "Core", color: .blue, position: 1),
///         TimelineCategory(name: "REM", color: .cyan, position: 2),
///         TimelineCategory(name: "Awake", color: .gray, position: 3),
///     ]
/// )
/// .frame(height: 160)
/// ```
struct IntervalTimeline: View {
    let intervals: [TimelineInterval]
    let categories: [TimelineCategory]

    @State private var scrubDate: Date?

    private let cal = Calendar.current

    private var categoryMap: [String: TimelineCategory] {
        Dictionary(uniqueKeysWithValues: categories.map { ($0.name, $0) })
    }

    private var totalRows: Int { categories.count }

    // MARK: - Time Range

    private var timeRange: (start: Date, end: Date) {
        guard let first = intervals.map(\.start).min(),
              let last = intervals.map(\.end).max() else {
            return (Date(), Date())
        }
        let startHour = cal.dateInterval(of: .hour, for: first)?.start ?? first
        let endHour: Date = {
            let interval = cal.dateInterval(of: .hour, for: last)
            if let s = interval?.start, s == last { return last }
            return cal.date(byAdding: .hour, value: 1, to: interval?.start ?? last) ?? last
        }()
        return (startHour, endHour)
    }

    private var hourlyMarks: [Date] {
        let range = timeRange
        var marks: [Date] = []
        var cursor = range.start
        while cursor <= range.end {
            marks.append(cursor)
            guard let next = cal.date(byAdding: .hour, value: 1, to: cursor) else { break }
            cursor = next
        }
        return marks
    }

    // MARK: - Body

    var body: some View {
        let range = timeRange

        VStack(spacing: 4) {
            // Scrub indicator
            if let scrub = scrubDate, let cat = categoryAt(scrub) {
                HStack(spacing: 6) {
                    Circle().fill(cat.color).frame(width: 8, height: 8)
                    Text(cat.name).font(.caption.bold())
                    Text(timeString(scrub)).font(.caption.monospacedDigit()).foregroundColor(.gray)
                }
                .frame(maxWidth: .infinity)
                .transition(.opacity)
            }

            Chart(intervals.indices, id: \.self) { i in
                let iv = intervals[i]
                let y = categoryMap[iv.category]?.position ?? 0
                let color = categoryMap[iv.category]?.color ?? .gray
                RectangleMark(
                    xStart: .value("Start", iv.start),
                    xEnd: .value("End", iv.end),
                    yStart: .value("Cat", y),
                    yEnd: .value("CatTop", y + 1)
                )
                .foregroundStyle(color)

                if let scrub = scrubDate {
                    RuleMark(x: .value("Scrub", scrub))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                }
            }
            .chartYScale(domain: 0...totalRows)
            .chartYAxis {
                AxisMarks(position: .leading,
                          values: categories.map { Double($0.position) + 0.5 }) { value in
                    AxisValueLabel {
                        if let v = value.as(Double.self) {
                            let idx = Int(v - 0.5)
                            if let cat = categories.first(where: { $0.position == idx }) {
                                Text(cat.name).font(.caption2).foregroundColor(.gray)
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
                                    guard let frame = proxy.plotFrame else { return }
                                    let x = drag.location.x - geo[frame].origin.x
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

    // MARK: - Helpers

    private func categoryAt(_ date: Date) -> TimelineCategory? {
        guard let iv = intervals.first(where: { date >= $0.start && date < $0.end }) else { return nil }
        return categoryMap[iv.category]
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
