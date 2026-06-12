import SwiftUI
import Charts

/// Reusable dashboard tile with consistent design language.
///
/// Layout:
/// ```
/// TITLE                    [badge]
/// 42           [sparkline]
/// unit/detail
/// Period
/// ```
///
/// Usage:
/// ```
/// DashboardTile(title: "RESTING HR", value: "64", unit: "bpm", period: "7D") {
///     MetricTrendView(...)
/// } sparkline: {
///     DashboardTile.sparklineData(values, color: .red)
/// }
/// ```
struct DashboardTile<Destination: View>: View {
    let title: String
    let value: String
    let unit: String?
    let detail: String?
    let period: String
    let valueColor: Color
    let destination: () -> Destination
    let badge: Badge?
    let sparklineValues: [Double]?
    let sparklineColor: Color?

    struct Badge {
        let text: String
        let color: Color
    }

    init(
        title: String,
        value: String,
        unit: String? = nil,
        detail: String? = nil,
        period: String,
        valueColor: Color = .white,
        badge: Badge? = nil,
        sparklineValues: [Double]? = nil,
        sparklineColor: Color? = nil,
        @ViewBuilder destination: @escaping () -> Destination
    ) {
        self.title = title
        self.value = value
        self.unit = unit
        self.detail = detail
        self.period = period
        self.valueColor = valueColor
        self.badge = badge
        self.sparklineValues = sparklineValues
        self.sparklineColor = sparklineColor
        self.destination = destination
    }

    var body: some View {
        NavigationLink(destination: destination()) {
            tileContent
        }
        .buttonStyle(.plain)
    }

    private var tileContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Header row
            HStack {
                Text(title).font(.caption2).foregroundColor(.gray)
                Spacer()
                if let badge {
                    Text(badge.text).font(.caption2).foregroundColor(badge.color)
                }
            }

            // Value + sparkline row
            if let values = sparklineValues, let color = sparklineColor, values.count > 1 {
                HStack(spacing: 12) {
                    valueView
                    Sparkline(values: values, color: color)
                        .frame(height: 24)
                }
            } else {
                valueView
            }

            // Detail line
            if let detail {
                Text(detail).font(.caption2).foregroundColor(.gray)
            }

            // Period label
            Text(period).font(.caption2).foregroundColor(.gray.opacity(0.6))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(hex: 0x16213e))
        .cornerRadius(12)
    }

    private var valueView: some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text(value).font(.title.bold().monospacedDigit())
                .foregroundColor(valueColor)
            if let unit {
                Text(unit).font(.caption2).foregroundColor(.gray)
            }
        }
    }
}

// MARK: - Sparkline

/// Minimal sparkline chart for dashboard tiles.
struct Sparkline: View {
    let values: [Double]
    let color: Color

    var body: some View {
        Chart {
            ForEach(Array(values.enumerated()), id: \.offset) { i, v in
                LineMark(x: .value("", i), y: .value("", v))
                    .foregroundStyle(color)
                AreaMark(x: .value("", i), y: .value("", v))
                    .foregroundStyle(color.opacity(0.1))
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
    }
}

// MARK: - Tile wrapper for custom content

/// A tile with fully custom content but consistent styling (background, padding, corner radius).
/// Use this for tiles that don't fit the standard value+unit pattern (e.g., habits, recovery).
struct CustomTile<Destination: View, Content: View>: View {
    let destination: () -> Destination
    let content: () -> Content

    init(
        @ViewBuilder destination: @escaping () -> Destination,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.destination = destination
        self.content = content
    }

    var body: some View {
        NavigationLink(destination: destination()) {
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(Color(hex: 0x16213e))
                .cornerRadius(12)
        }
        .buttonStyle(.plain)
    }
}
