import SwiftUI

private enum DataFilter: String, CaseIterable {
    case all        = "All"
    case hkWorkout  = "Workouts"
    case imuWorkout = "IMU"
    case bodyComp   = "Body Comp"
    case metric     = "Metrics"
    case recovery   = "Recovery"
    case running    = "Running"
}

/// Unified view of ALL measurements from all sources
struct DataTab: View {
    @EnvironmentObject var measurementStore: MeasurementStore
    @State private var filter: DataFilter = .all
    @State private var selection = Set<UUID>()
    @State private var editMode: EditMode = .inactive
    @State private var showDeleteConfirmation = false
    @State private var pendingDeleteIDs = Set<UUID>()

    private var filtered: [SensorMeasurement] {
        let sorted = measurementStore.measurements.sorted { $0.date > $1.date }
        switch filter {
        case .all:        return sorted
        case .hkWorkout: return sorted.filter { $0.type == .hkWorkout }
        case .imuWorkout: return sorted.filter { $0.type == .workout }
        case .bodyComp:  return sorted.filter { $0.type == .bodyComp }
        case .metric:    return sorted.filter { $0.type == .metric }
        case .recovery:  return sorted.filter { isRecovery($0) }
        case .running:   return sorted.filter { isRunning($0) }
        }
    }

    var body: some View {
        NavigationStack {
            List(selection: $selection) {
                // Filter chips
                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(DataFilter.allCases, id: \.self) { f in
                                filterChip(f)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                .listRowBackground(Color(hex: 0x1a1a2e))
                .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12))

                // Measurements
                if filtered.isEmpty {
                    Text("No data").foregroundColor(.gray)
                        .listRowBackground(Color(hex: 0x16213e))
                } else {
                    ForEach(filtered) { m in
                        NavigationLink(destination: MeasurementDetailView(measurement: m)) {
                            HStack(spacing: 12) {
                                Image(systemName: m.icon)
                                    .foregroundColor(iconColor(m))
                                    .frame(width: 24)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(m.dateString).font(.subheadline)
                                    Text(m.summary).font(.caption).foregroundColor(.gray)
                                    Text(m.sourceLabel).font(.caption2).foregroundColor(.cyan)
                                }
                            }
                        }
                        .listRowBackground(Color(hex: 0x16213e))
                    }
                    .onDelete { indexSet in
                        pendingDeleteIDs = Set(indexSet.map { filtered[$0].id })
                        showDeleteConfirmation = true
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color(hex: 0x1a1a2e))
            .navigationTitle("Data")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    EditButton()
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if editMode == .active {
                        Button(selection.count == filtered.count ? "Deselect All" : "Select All") {
                            if selection.count == filtered.count {
                                selection.removeAll()
                            } else {
                                selection = Set(filtered.map(\.id))
                            }
                        }
                        if !selection.isEmpty {
                            Button("Delete \(selection.count)", role: .destructive) {
                                pendingDeleteIDs = selection
                                showDeleteConfirmation = true
                            }
                        }
                    }
                }
            }
            .environment(\.editMode, $editMode)
            .alert("Delete \(pendingDeleteIDs.count) measurement\(pendingDeleteIDs.count == 1 ? "" : "s")?",
                   isPresented: $showDeleteConfirmation) {
                Button("Delete", role: .destructive) {
                    measurementStore.deleteBatch(pendingDeleteIDs)
                    selection.removeAll()
                    pendingDeleteIDs.removeAll()
                    editMode = .inactive
                }
                Button("Cancel", role: .cancel) {
                    pendingDeleteIDs.removeAll()
                }
            } message: {
                Text("This cannot be undone.")
            }
        }
    }

    // MARK: - Helpers

    private func filterChip(_ f: DataFilter) -> some View {
        let active = filter == f
        return Button(action: { filter = f }) {
            Text(f.rawValue)
                .font(.caption.weight(active ? .semibold : .regular))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(active ? Color(hex: 0x5dadec) : Color(hex: 0x16213e))
                .foregroundColor(active ? .black : .gray)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func iconColor(_ m: SensorMeasurement) -> Color {
        if isRecovery(m) { return Color(hex: 0xf4a261) }
        if isRunning(m) { return Color(hex: 0x5dadec) }
        switch m.type {
        case .workout:   return Color(hex: 0xe94560)
        case .hkWorkout: return .pink
        case .derived:   return Color(hex: 0x5dadec)
        case .bodyComp:  return .green
        case .metric:    return .cyan
        }
    }

    private func isRecovery(_ m: SensorMeasurement) -> Bool {
        m.type == .derived && m.dataPoints.contains { $0.type == DataType.recoveryIndex }
    }

    private func isRunning(_ m: SensorMeasurement) -> Bool {
        m.type == .derived && m.dataPoints.contains { $0.type == DataType.pace || $0.type == DataType.distance }
    }
}
