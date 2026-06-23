import SwiftUI
import Charts

/// Renders a list of HomeInsights as attention cards (full-width) and confirmation lines (compact).
struct EditorialFeedView: View {
    let insights: [HomeInsight]

    private var attentionInsights: [HomeInsight] {
        insights.filter { $0.priority == .urgent || $0.priority == .attention }
    }

    private var positiveInsights: [HomeInsight] {
        insights.filter { $0.priority == .positive }
    }

    private var confirmationInsights: [HomeInsight] {
        insights.filter { $0.priority == .neutral }
    }

    var body: some View {
        VStack(spacing: 12) {
            // Attention cards — full-width, prominent
            ForEach(attentionInsights) { insight in
                AttentionCardView(insight: insight)
            }

            // Positive cards — brief celebration, slightly subdued
            ForEach(positiveInsights) { insight in
                AttentionCardView(insight: insight)
            }

            // Confirmation lines — compact, grouped in one card
            if !confirmationInsights.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(confirmationInsights.enumerated()), id: \.element.id) { index, insight in
                        ConfirmationLineView(insight: insight)
                        if index < confirmationInsights.count - 1 {
                            Divider()
                                .background(Color.gray.opacity(0.2))
                                .padding(.leading, 46)
                        }
                    }
                }
                .background(Color(hex: 0x16213e))
                .clipShape(RoundedRectangle(cornerRadius: 16))
            }
        }
    }
}

// MARK: - Attention Card

/// Full-width card for urgent/attention/positive insights.
struct AttentionCardView: View {
    let insight: HomeInsight

    var body: some View {
        NavigationLink(destination: insight.destination) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: insight.icon)
                        .font(.system(size: 14))
                        .foregroundStyle(insight.iconColor)
                    Text(insight.title)
                        .font(.caption2.bold())
                        .foregroundStyle(.gray)
                    Spacer()
                    if let values = insight.sparklineValues, values.count > 1 {
                        Sparkline(values: values, color: insight.sparklineColor ?? .cyan)
                            .frame(width: 80, height: 24)
                    }
                }

                Text(insight.headline)
                    .font(.title3.bold())
                    .foregroundStyle(insight.iconColor)

                if let detail = insight.detail {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.gray)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(insight.iconColor.opacity(0.08))
            )
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color(hex: 0x16213e))
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Confirmation Line

/// Compact single-line row for neutral insights.
struct ConfirmationLineView: View {
    let insight: HomeInsight

    var body: some View {
        NavigationLink(destination: insight.destination) {
            HStack(spacing: 10) {
                Image(systemName: insight.icon)
                    .font(.system(size: 14))
                    .foregroundStyle(insight.iconColor)
                    .frame(width: 20)
                Text(insight.title)
                    .font(.subheadline)
                    .foregroundStyle(.white)
                Spacer()
                Text(insight.headline)
                    .font(.subheadline)
                    .foregroundStyle(.gray)
                    .lineLimit(1)
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.gray.opacity(0.5))
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 16)
        }
        .buttonStyle(.plain)
    }
}
