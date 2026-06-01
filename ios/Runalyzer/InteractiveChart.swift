import SwiftUI
import Charts

// A reusable interactive line chart with time axis, touch crosshair, and zoom
struct InteractiveLineChart: View {
    let title: String
    let series: [ChartSeries]
    let yDomain: ClosedRange<Double>?
    let height: CGFloat

    @State private var selectedX: Date?
    @State private var zoomRange: ClosedRange<Date>?

    init(title: String, series: [ChartSeries], yDomain: ClosedRange<Double>? = nil, height: CGFloat = 180) {
        self.title = title
        self.series = series
        self.yDomain = yDomain
        self.height = height
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title.uppercased()).font(.caption2).foregroundColor(.gray)
                Spacer()
                if let sel = selectedX, let info = valueAt(sel) {
                    Text(info).font(.caption2.monospacedDigit()).foregroundColor(.white)
                }
                if zoomRange != nil {
                    Button(action: { withAnimation { zoomRange = nil } }) {
                        Text("Reset").font(.caption2).foregroundColor(.cyan)
                    }
                }
            }

            // Legend
            if series.count > 1 {
                HStack(spacing: 12) {
                    ForEach(series) { s in
                        HStack(spacing: 4) {
                            Circle().fill(s.color).frame(width: 6, height: 6)
                            Text(s.name).font(.system(size: 10)).foregroundColor(.gray)
                        }
                    }
                }
            }

            Chart {
                ForEach(series) { s in
                    let visibleData = filteredData(s.data)
                    ForEach(visibleData) { point in
                        LineMark(
                            x: .value("Time", point.date),
                            y: .value(s.name, point.value)
                        )
                        .foregroundStyle(s.color)
                        .lineStyle(StrokeStyle(lineWidth: s.lineWidth))
                    }
                }

                if let sel = selectedX {
                    RuleMark(x: .value("Selected", sel))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                }
            }
            .chartYScale(domain: yDomain ?? autoYDomain)
            .chartXScale(domain: xDomain)
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { value in
                    AxisValueLabel {
                        if let date = value.as(Date.self) {
                            Text(Self.timeFmt.string(from: date))
                                .font(.system(size: 9))
                        }
                    }
                    AxisGridLine()
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                    AxisValueLabel {
                        if let v = value.as(Double.self) {
                            Text(String(format: "%.1f", v)).font(.system(size: 9))
                        }
                    }
                    AxisGridLine()
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
                                    if let date: Date = proxy.value(atX: x) {
                                        selectedX = date
                                    }
                                }
                                .onEnded { _ in
                                    // Keep selection visible
                                }
                        )
                        .gesture(
                            MagnificationGesture()
                                .onEnded { scale in
                                    zoom(by: scale)
                                }
                        )
                }
            }
            .frame(height: height)
        }
        .padding()
        .background(Color(hex: 0x16213e))
        .cornerRadius(12)
    }

    // MARK: - Helpers

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private var xDomain: ClosedRange<Date> {
        if let zoom = zoomRange { return zoom }
        let allDates = series.flatMap { $0.data.map(\.date) }
        guard let min = allDates.min(), let max = allDates.max(), min < max else {
            let now = Date()
            return now...now.addingTimeInterval(1)
        }
        return min...max
    }

    private var autoYDomain: ClosedRange<Double> {
        let visibleData = series.flatMap { filteredData($0.data) }
        let values = visibleData.map(\.value)
        guard let min = values.min(), let max = values.max(), min < max else {
            return 0...1
        }
        let padding = (max - min) * 0.1
        return (min - padding)...(max + padding)
    }

    private func filteredData(_ data: [ChartPoint]) -> [ChartPoint] {
        guard let zoom = zoomRange else { return data }
        return data.filter { $0.date >= zoom.lowerBound && $0.date <= zoom.upperBound }
    }

    private func valueAt(_ date: Date) -> String? {
        var parts: [String] = [Self.timeFmt.string(from: date)]
        for s in series {
            if let closest = s.data.min(by: { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }) {
                parts.append("\(s.name): \(String(format: "%.1f", closest.value))")
            }
        }
        return parts.joined(separator: " | ")
    }

    private func zoom(by scale: MagnificationGesture.Value) {
        let domain = xDomain
        let center = domain.lowerBound.addingTimeInterval(domain.upperBound.timeIntervalSince(domain.lowerBound) / 2)
        let halfSpan = domain.upperBound.timeIntervalSince(domain.lowerBound) / 2
        let newHalf = halfSpan / scale
        let newStart = center.addingTimeInterval(-newHalf)
        let newEnd = center.addingTimeInterval(newHalf)
        withAnimation { zoomRange = newStart...newEnd }
    }
}

// MARK: - Data Types

struct ChartPoint: Identifiable {
    let id = UUID()
    let date: Date
    let value: Double
}

struct ChartSeries: Identifiable {
    let id = UUID()
    let name: String
    let color: Color
    let data: [ChartPoint]
    var lineWidth: CGFloat = 1.5
}

// MARK: - Convenience builders

extension ChartSeries {
    /// Build from IMU samples with a session start date
    static func fromIMUSamples(_ samples: [RecordedSample], sessionStart: Date, name: String, color: Color,
                               transform: (RecordedSample) -> Double, downsampleTo: Int = 500) -> ChartSeries {
        let step = max(1, samples.count / downsampleTo)
        let firstTs = samples.first?.timestamp ?? 0
        let points = stride(from: 0, to: samples.count, by: step).map { i -> ChartPoint in
            let s = samples[i]
            let elapsed = Double(s.timestamp - firstTs) / 1000.0
            return ChartPoint(date: sessionStart.addingTimeInterval(elapsed), value: transform(s))
        }
        return ChartSeries(name: name, color: color, data: points)
    }

    /// Build from cadence windows
    static func fromCadenceWindows(_ windows: [CadenceWindow], sessionStart: Date, name: String, color: Color) -> ChartSeries {
        let points = windows.map { w -> ChartPoint in
            let midMs = Double(w.startMs + w.endMs) / 2.0 / 1000.0
            return ChartPoint(date: sessionStart.addingTimeInterval(midMs), value: Double(w.cadence))
        }
        return ChartSeries(name: name, color: color, data: points)
    }

    /// Build from HealthKit TimestampedValues
    static func fromTimestamped(_ values: [TimestampedValue], name: String, color: Color) -> ChartSeries {
        let points = values.map { ChartPoint(date: $0.date, value: $0.value) }
        return ChartSeries(name: name, color: color, data: points)
    }
}
