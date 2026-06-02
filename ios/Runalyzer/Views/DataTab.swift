import SwiftUI

/// Unified view of ALL measurements from all sources
struct DataTab: View {
    @EnvironmentObject var measurementStore: MeasurementStore

    var body: some View {
        NavigationStack {
            List {
                if measurementStore.measurements.isEmpty {
                    Text("No data yet").foregroundColor(.gray)
                } else {
                    ForEach(measurementStore.measurements) { m in
                        NavigationLink(destination: MeasurementDetailView(measurement: m)) {
                            HStack(spacing: 12) {
                                Image(systemName: m.icon)
                                    .foregroundColor(m.type == .workout ? Color(hex: 0xe94560) : .green)
                                    .frame(width: 24)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(m.dateString).font(.subheadline)
                                    Text(m.summary).font(.caption).foregroundColor(.gray)
                                    Text(m.sourceLabel).font(.caption2).foregroundColor(.cyan)
                                }
                            }
                        }
                    }
                    .onDelete { indexSet in
                        let ids = indexSet.map { measurementStore.measurements[$0].id }
                        for id in ids { measurementStore.delete(id) }
                    }
                }
            }
            .navigationTitle("Data")
        }
    }
}
