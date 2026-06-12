import SwiftUI
import GRDB

/// Database browser view — shows all data grouped by day.
/// Each row is a data type for that day (HR, HRV, Steps, Sleep, etc.)
/// or a workout. Tap → intraday detail or workout detail.
private enum DataFilter: String, CaseIterable {
    case all        = "All"
    case workouts   = "Workouts"
    case bodyComp   = "Body Comp"
    case metrics    = "Metrics"
    case recovery   = "Recovery"
}

struct DataTab: View {
    @EnvironmentObject var measurementStore: MeasurementStore
    @EnvironmentObject var workoutStore: WorkoutStore
    @State private var filter: DataFilter = .all
    @State private var showDeleteAll = false

    private let cal = Calendar.current

    /// A row in the data browser — either a metric type for a day, or a workout.
    fileprivate enum DataRow: Identifiable {
        case metric(date: Date, type: String, count: Int, summary: String)
        case workout(Workout)
        case bodyComp(SensorMeasurement)
        case derived(SensorMeasurement)

        var id: String {
            switch self {
            case .metric(let date, let type, _, _):
                return "m-\(Int(date.timeIntervalSince1970))-\(type)"
            case .workout(let w): return "w-\(w.id.uuidString)"
            case .bodyComp(let m): return "bc-\(m.id.uuidString)"
            case .derived(let m): return "d-\(m.id.uuidString)"
            }
        }

        var date: Date {
            switch self {
            case .metric(let date, _, _, _): return date
            case .workout(let w): return w.startDate
            case .bodyComp(let m): return m.date
            case .derived(let m): return m.date
            }
        }
    }

    /// All rows grouped by day, sorted newest first, filtered by current filter.
    private var sections: [(date: Date, label: String, rows: [DataRow])] {
        var rowsByDay: [Date: [DataRow]] = [:]

        if filter == .all || filter == .metrics {
            for row in buildMetricRows() {
                let day = cal.startOfDay(for: row.date)
                rowsByDay[day, default: []].append(row)
            }
        }

        if filter == .all || filter == .workouts {
            for w in workoutStore.workouts {
                let day = cal.startOfDay(for: w.startDate)
                rowsByDay[day, default: []].append(.workout(w))
            }
        }

        if filter == .all || filter == .bodyComp {
            for m in measurementStore.measurements(ofType: .bodyComp) {
                let day = cal.startOfDay(for: m.date)
                rowsByDay[day, default: []].append(.bodyComp(m))
            }
        }

        if filter == .all || filter == .recovery {
            for m in measurementStore.measurements(ofType: .derived) {
                let day = cal.startOfDay(for: m.date)
                rowsByDay[day, default: []].append(.derived(m))
            }
        }

        return rowsByDay.keys.sorted(by: >).map { day in
            let rows = rowsByDay[day]!.sorted(by: { (a: DataRow, b: DataRow) in a.sortOrder < b.sortOrder })
            return (date: day, label: dayLabel(day), rows: rows)
        }
    }

    var body: some View {
        NavigationStack {
            List {
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
                .listRowBackground(Color.appBackground)
                .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12))

                if sections.isEmpty {
                    Text("No data").foregroundColor(.gray)
                        .listRowBackground(Color.appSurface)
                } else {
                    ForEach(sections, id: \.date) { section in
                        Section(section.label) {
                            ForEach(section.rows) { row in
                                rowView(row)
                                    .listRowBackground(Color.appSurface)
                                    .swipeActions(edge: .trailing) {
                                        Button(role: .destructive) { deleteRow(row) } label: {
                                            Label("Delete", systemImage: "trash")
                                        }
                                    }
                            }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.appBackground)
            .navigationTitle("Data")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Delete All", role: .destructive) {
                        showDeleteAll = true
                    }
                    .foregroundColor(.red)
                }
            }
            .alert("Delete all data?", isPresented: $showDeleteAll) {
                Button("Delete All", role: .destructive) {
                    deleteAllVisible()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will delete all \(filter.rawValue.lowercased()) data. This cannot be undone.")
            }
        }
    }

    private func filterChip(_ f: DataFilter) -> some View {
        let active = filter == f
        return Button(action: { filter = f }) {
            Text(f.rawValue)
                .font(.caption.weight(active ? .semibold : .regular))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(active ? Color.appBlue : Color.appSurface)
                .foregroundColor(active ? .black : .gray)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func deleteRow(_ row: DataRow) {
        switch row {
        case .workout(let w):
            workoutStore.delete(w.id)
        case .bodyComp(let m), .derived(let m):
            measurementStore.delete(m.id)
        case .metric(_, _, _, _):
            break  // Metric rows are aggregates — delete via Delete All
        }
    }

    private func deleteAllVisible() {
        // Delete all items matching the current filter
        switch filter {
        case .all:
            let mIDs = Set(measurementStore.measurements.map(\.id))
            let wIDs = Set(workoutStore.workouts.map(\.id))
            if !mIDs.isEmpty { measurementStore.deleteBatch(mIDs) }
            if !wIDs.isEmpty { workoutStore.deleteBatch(wIDs) }
        case .workouts:
            let ids = Set(workoutStore.workouts.map(\.id))
            if !ids.isEmpty { workoutStore.deleteBatch(ids) }
        case .bodyComp:
            let ids = Set(measurementStore.measurements(ofType: .bodyComp).map(\.id))
            if !ids.isEmpty { measurementStore.deleteBatch(ids) }
        case .metrics:
            let ids = Set(measurementStore.measurements(ofType: .metric).map(\.id))
            if !ids.isEmpty { measurementStore.deleteBatch(ids) }
        case .recovery:
            let ids = Set(measurementStore.measurements(ofType: .derived).map(\.id))
            if !ids.isEmpty { measurementStore.deleteBatch(ids) }
        }
    }

    // MARK: - Row Views

    @ViewBuilder
    private func rowView(_ row: DataRow) -> some View {
        switch row {
        case .metric(let date, let type, let count, let summary):
            NavigationLink(destination: IntradayView(
                metricType: type, title: prettyType(type),
                unit: unitFor(type), color: colorFor(type), date: date
            )) {
                HStack(spacing: 12) {
                    Image(systemName: iconFor(type))
                        .foregroundColor(colorFor(type))
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(prettyType(type)).font(.subheadline)
                        Text(summary).font(.caption).foregroundColor(.gray)
                    }
                    Spacer()
                    Text("\(count)").font(.caption2).foregroundColor(.gray)
                }
            }

        case .workout(let w):
            NavigationLink(destination: WorkoutDetailView(workout: w)) {
                HStack(spacing: 12) {
                    Image(systemName: w.icon)
                        .foregroundColor(.pink)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(w.activityType).font(.subheadline)
                        Text(w.summary).font(.caption).foregroundColor(.gray)
                    }
                }
            }

        case .bodyComp(let m):
            NavigationLink(destination: MeasurementDetailView(measurement: m)) {
                HStack(spacing: 12) {
                    Image(systemName: "scalemass")
                        .foregroundColor(.green)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Body Composition").font(.subheadline)
                        Text(m.sourceLabel).font(.caption2).foregroundColor(.cyan)
                    }
                }
            }

        case .derived(let m):
            NavigationLink(destination: MeasurementDetailView(measurement: m)) {
                HStack(spacing: 12) {
                    Image(systemName: "function")
                        .foregroundColor(Color.appBlue)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Recovery").font(.subheadline)
                        Text(m.sourceLabel).font(.caption2).foregroundColor(.cyan)
                    }
                }
            }
        }
    }

    // MARK: - Metric Row Builder

    /// Query the DB for distinct (day, type, count) — only from .metric measurements.
    /// Body comp and derived DataPoints have their own dedicated row types.
    private func buildMetricRows() -> [DataRow] {
        let sql = """
            SELECT
                CAST(dp.timestamp / 86400 AS INTEGER) * 86400 AS dayEpoch,
                dp.type,
                COUNT(*) AS cnt,
                AVG(dp.value) AS avgVal,
                MIN(dp.value) AS minVal,
                MAX(dp.value) AS maxVal,
                dp.unit
            FROM data_point dp
            JOIN measurement m ON dp.measurementId = m.id
            WHERE m.type = 'metric'
            GROUP BY dayEpoch, dp.type
            ORDER BY dayEpoch DESC, dp.type
            """

        do {
            return try AppDatabase.shared.dbQueue.read { db in
                let rows = try Row.fetchAll(db, sql: sql)
                return rows.map { row in
                    let dayEpoch: Double = row["dayEpoch"]
                    let type: String = row["type"]
                    let count: Int = row["cnt"]
                    let avg: Double = row["avgVal"]
                    let min: Double = row["minVal"]
                    let max: Double = row["maxVal"]
                    let unit: String = row["unit"]
                    let date = Date(timeIntervalSince1970: dayEpoch)

                    let summary = formatMetricSummary(type: type, count: count,
                                                      avg: avg, min: min, max: max, unit: unit)
                    return DataRow.metric(date: date, type: type, count: count, summary: summary)
                }
            }
        } catch {
            return []
        }
    }

    // MARK: - Helpers

    private static let dayLabelFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "E, d MMM yyyy"
        return f
    }()

    private func dayLabel(_ date: Date) -> String {
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        return Self.dayLabelFormatter.string(from: date)
    }

    private func formatMetricSummary(type: String, count: Int, avg: Double,
                                      min: Double, max: Double, unit: String) -> String {
        switch type {
        case DataType.heartRateSample:
            return String(format: "%.0f avg · %.0f–%.0f bpm · %d samples", avg, min, max, count)
        case DataType.hrvSDNN:
            return String(format: "%.0f ms avg · %d readings", avg, count)
        case DataType.restingHeartRate:
            return String(format: "%.0f bpm · %d readings", min, count)
        case DataType.steps:
            return String(format: "%.0f steps", max)
        case DataType.distance:
            if max >= 1000 {
                return String(format: "%.1f km", max / 1000)
            }
            return String(format: "%.0f m", max)
        case DataType.bloodOxygen:
            return String(format: "%.0f%% · %d readings", avg * 100, count)
        case DataType.vo2Max:
            return String(format: "%.1f mL/kg/min", avg)
        case DataType.bodyTemperature:
            return String(format: "%.1f°C", avg)
        case DataType.sleepStage:
            return String(format: "%d stages", count)
        case DataType.respiratoryRate:
            return String(format: "%.1f br/min avg · %d readings", avg, count)
        case DataType.walkingHeartRateAvg:
            return String(format: "%.0f bpm", avg)
        case DataType.activeEnergy:
            return String(format: "%.0f kcal", max)
        case DataType.wristTemperature:
            return String(format: "%+.1f°C deviation", avg)
        case DataType.weight:
            return String(format: "%.1f kg", max)
        case DataType.bodyFatPercent:
            return String(format: "%.1f%%", max * 100)
        case DataType.fatFreeMassKg:
            return String(format: "%.1f kg", max)
        default:
            return String(format: "%.1f %@ avg · %d pts", avg, unit, count)
        }
    }

    private func prettyType(_ type: String) -> String {
        switch type {
        case DataType.heartRateSample:  return "Heart Rate"
        case DataType.hrvSDNN:          return "HRV (SDNN)"
        case DataType.restingHeartRate: return "Resting Heart Rate"
        case DataType.steps:            return "Steps"
        case DataType.distance:         return "Distance"
        case DataType.bloodOxygen:      return "Blood Oxygen"
        case DataType.vo2Max:           return "VO2 Max"
        case DataType.bodyTemperature:  return "Body Temperature"
        case DataType.sleepStage:       return "Sleep"
        case DataType.cadence:          return "Cadence"
        case DataType.respiratoryRate:  return "Respiratory Rate"
        case DataType.walkingHeartRateAvg: return "Walking Heart Rate"
        case DataType.activeEnergy:     return "Active Energy"
        case DataType.wristTemperature: return "Wrist Temperature"
        case DataType.weight:           return "Weight"
        case DataType.bodyFatPercent:   return "Body Fat"
        case DataType.fatFreeMassKg:    return "Lean Body Mass"
        default:
            return type.replacingOccurrences(of: "_", with: " ")
                .split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }
                .joined(separator: " ")
        }
    }

    private func iconFor(_ type: String) -> String {
        switch type {
        case DataType.heartRateSample:  return "heart.fill"
        case DataType.hrvSDNN:          return "waveform.path.ecg"
        case DataType.restingHeartRate: return "heart"
        case DataType.steps:            return "figure.walk"
        case DataType.distance:         return "figure.walk.motion"
        case DataType.bloodOxygen:      return "lungs"
        case DataType.vo2Max:           return "wind"
        case DataType.bodyTemperature:  return "thermometer"
        case DataType.sleepStage:       return "bed.double"
        case DataType.cadence:          return "metronome"
        case DataType.respiratoryRate:  return "lungs.fill"
        case DataType.walkingHeartRateAvg: return "figure.walk.circle"
        case DataType.activeEnergy:     return "flame"
        case DataType.wristTemperature: return "thermometer.low"
        case DataType.weight:           return "scalemass"
        case DataType.bodyFatPercent:   return "figure.arms.open"
        case DataType.fatFreeMassKg:    return "figure.strengthtraining.traditional"
        default:                        return "chart.bar"
        }
    }

    private func colorFor(_ type: String) -> Color {
        switch type {
        case DataType.heartRateSample:  return .red
        case DataType.hrvSDNN:          return .purple
        case DataType.restingHeartRate: return .red
        case DataType.steps:            return .green
        case DataType.distance:         return .orange
        case DataType.bloodOxygen:      return .blue
        case DataType.vo2Max:           return .orange
        case DataType.bodyTemperature:  return .yellow
        case DataType.sleepStage:       return .indigo
        case DataType.cadence:          return .mint
        case DataType.respiratoryRate:  return .cyan
        case DataType.walkingHeartRateAvg: return .orange
        case DataType.activeEnergy:     return .red
        case DataType.wristTemperature: return .indigo
        case DataType.weight:           return .cyan
        case DataType.bodyFatPercent:   return .orange
        case DataType.fatFreeMassKg:    return .green
        default:                        return .cyan
        }
    }

    private func unitFor(_ type: String) -> String {
        switch type {
        case DataType.heartRateSample, DataType.restingHeartRate: return "bpm"
        case DataType.hrvSDNN:          return "ms"
        case DataType.steps:            return "steps"
        case DataType.distance:         return "m"
        case DataType.bloodOxygen:      return "%"
        case DataType.vo2Max:           return "mL/kg/min"
        case DataType.bodyTemperature:  return "°C"
        case DataType.cadence:          return "spm"
        case DataType.respiratoryRate:  return "br/min"
        case DataType.walkingHeartRateAvg: return "bpm"
        case DataType.activeEnergy:     return "kcal"
        case DataType.wristTemperature: return "°C"
        case DataType.weight:           return "kg"
        case DataType.bodyFatPercent:   return "%"
        case DataType.fatFreeMassKg:    return "kg"
        default:                        return ""
        }
    }
}

// MARK: - Sort order for rows within a day

fileprivate extension DataTab.DataRow {
    var sortOrder: Int {
        switch self {
        case .workout:  return 0
        case .metric:   return 1
        case .bodyComp: return 2
        case .derived:  return 3
        }
    }
}
