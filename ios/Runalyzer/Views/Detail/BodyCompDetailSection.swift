import SwiftUI

/// Body composition detail section for MeasurementDetailView.
struct BodyCompDetailSection: View {
    let dataPoints: [DataPoint]
    let sourceLabel: String

    var body: some View {
        let primary = dataPoints.filter { $0.role == .primary }
        let detail = dataPoints.filter { $0.role == .detail }

        VStack(alignment: .leading, spacing: 8) {
            Text("BODY COMPOSITION").font(.caption2).foregroundColor(.gray)
            ForEach(primary) { p in
                dataRow(label: DataType.displayName(p.type), value: formatValue(p), unit: p.unit)
            }
            if !detail.isEmpty {
                DisclosureGroup {
                    ForEach(detail) { p in
                        dataRow(label: DataType.displayName(p.type), value: formatValue(p), unit: p.unit)
                    }
                } label: {
                    Text("MORE").font(.caption2).foregroundColor(.gray)
                }
                .tint(.gray)
            }
            HStack(spacing: 4) {
                Image(systemName: "antenna.radiowaves.left.and.right").font(.caption2)
                Text(sourceLabel).font(.caption2)
            }
            .foregroundColor(.gray)
        }
    }

    private func dataRow(label: String, value: String, unit: String) -> some View {
        HStack {
            Text(label).font(.subheadline).foregroundColor(.gray)
            Spacer()
            Text(value).font(.subheadline.monospacedDigit())
            Text(unit).font(.caption2).foregroundColor(.gray)
        }
    }

    private func formatValue(_ p: DataPoint) -> String {
        String(format: "%.2f", p.value)
    }
}
