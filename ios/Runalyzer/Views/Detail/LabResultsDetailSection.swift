import SwiftUI

/// Lab results detail section for MeasurementDetailView.
struct LabResultsDetailSection: View {
    let dataPoints: [DataPoint]
    let sourceLabel: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("LAB RESULTS").font(.caption2).foregroundColor(.gray)
            ForEach(dataPoints.filter { $0.role == .primary }) { p in
                HStack {
                    Text(DataType.labDisplayName(p.type))
                        .font(.subheadline).foregroundColor(.gray)
                    Spacer()
                    Text(String(format: p.value == p.value.rounded() ? "%.0f" : "%.1f", p.value))
                        .font(.subheadline.bold().monospacedDigit())
                    Text(p.unit)
                        .font(.caption2).foregroundColor(.gray)
                }
            }
            HStack(spacing: 4) {
                Image(systemName: "antenna.radiowaves.left.and.right").font(.caption2)
                Text(sourceLabel).font(.caption2)
            }
            .foregroundColor(.gray)
        }
    }
}
