import SwiftUI

/// Database browser view — shows all data grouped by day.
/// Each row is a data type for that day (HR, HRV, Steps, Sleep, etc.)
/// or a workout. Tap → intraday detail or workout detail.
private enum DataFilter: String, CaseIterable {
    case all        = "All"
    case workouts   = "Workouts"
    case bodyComp   = "Body Comp"
    case metrics    = "Metrics"
    case recovery   = "Recovery"
    case sleep      = "Sleep"
    case labs       = "Labs"
    case fluid      = "Fluid"
    case checkIns   = "Check-ins"
    case sauna      = "Sauna"
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
        case labResults(SensorMeasurement)
        case fluidIntake(SensorMeasurement)
        case checkIn(SensorMeasurement)
        case saunaSession(SensorMeasurement)

        var id: String {
            switch self {
            case .metric(let date, let type, _, _):
                return "m-\(Int(date.timeIntervalSince1970))-\(type)"
            case .workout(let w): return "w-\(w.id.uuidString)"
            case .bodyComp(let m): return "bc-\(m.id.uuidString)"
            case .derived(let m): return "d-\(m.id.uuidString)"
            case .labResults(let m): return "lr-\(m.id.uuidString)"
            case .fluidIntake(let m): return "fl-\(m.id.uuidString)"
            case .checkIn(let m): return "ci-\(m.id.uuidString)"
            case .saunaSession(let m): return "sa-\(m.id.uuidString)"
            }
        }

        var date: Date {
            switch self {
            case .metric(let date, _, _, _): return date
            case .workout(let w): return w.startDate
            case .bodyComp(let m): return m.date
            case .derived(let m): return m.date
            case .labResults(let m): return m.date
            case .fluidIntake(let m): return m.date
            case .checkIn(let m): return m.date
            case .saunaSession(let m): return m.date
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

        if filter == .all || filter == .recovery || filter == .sleep {
            for m in measurementStore.measurements(ofType: .derived) {
                let isSleep = m.sources.contains { $0.algorithmName == SleepMeasurementProvider.algorithmID }
                if filter == .recovery && isSleep { continue }
                if filter == .sleep && !isSleep { continue }
                let day = cal.startOfDay(for: m.date)
                rowsByDay[day, default: []].append(.derived(m))
            }
        }

        if filter == .all || filter == .labs {
            for m in measurementStore.measurements(ofType: .labResults) {
                let day = cal.startOfDay(for: m.date)
                rowsByDay[day, default: []].append(.labResults(m))
            }
        }

        if filter == .all || filter == .fluid {
            for m in measurementStore.measurements(ofType: .fluidIntake) {
                let day = cal.startOfDay(for: m.date)
                rowsByDay[day, default: []].append(.fluidIntake(m))
            }
        }

        if filter == .all || filter == .checkIns {
            for m in measurementStore.measurements(ofType: .checkIn) {
                let day = cal.startOfDay(for: m.date)
                rowsByDay[day, default: []].append(.checkIn(m))
            }
        }

        if filter == .all || filter == .sauna {
            for m in measurementStore.measurements(ofType: .saunaSession) {
                let day = cal.startOfDay(for: m.date)
                rowsByDay[day, default: []].append(.saunaSession(m))
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
        case .bodyComp(let m), .derived(let m), .labResults(let m),
             .fluidIntake(let m), .checkIn(let m), .saunaSession(let m):
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
            let ids = Set(measurementStore.measurements(ofType: .derived)
                .filter { !$0.sources.contains { $0.algorithmName == SleepMeasurementProvider.algorithmID } }
                .map(\.id))
            if !ids.isEmpty { measurementStore.deleteBatch(ids) }
        case .sleep:
            let ids = Set(measurementStore.measurements(ofType: .derived)
                .filter { $0.sources.contains { $0.algorithmName == SleepMeasurementProvider.algorithmID } }
                .map(\.id))
            if !ids.isEmpty { measurementStore.deleteBatch(ids) }
        case .labs:
            let ids = Set(measurementStore.measurements(ofType: .labResults).map(\.id))
            if !ids.isEmpty { measurementStore.deleteBatch(ids) }
        case .fluid:
            let ids = Set(measurementStore.measurements(ofType: .fluidIntake).map(\.id))
            if !ids.isEmpty { measurementStore.deleteBatch(ids) }
        case .checkIns:
            let ids = Set(measurementStore.measurements(ofType: .checkIn).map(\.id))
            if !ids.isEmpty { measurementStore.deleteBatch(ids) }
        case .sauna:
            let ids = Set(measurementStore.measurements(ofType: .saunaSession).map(\.id))
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
                    derivedIcon(for: m)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(derivedTitle(for: m)).font(.subheadline)
                        Text(derivedSubtitle(for: m)).font(.caption2).foregroundColor(.gray)
                    }
                }
            }

        case .labResults(let m):
            NavigationLink(destination: MeasurementDetailView(measurement: m)) {
                HStack(spacing: 12) {
                    Image(systemName: "cross.case")
                        .foregroundColor(.red)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Lab Results").font(.subheadline)
                        Text(m.summary).font(.caption).foregroundColor(.gray)
                    }
                }
            }

        case .fluidIntake(let m):
            HStack(spacing: 12) {
                Image(systemName: "drop.fill")
                    .foregroundColor(.cyan)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Drink").font(.subheadline)
                    Text(m.summary).font(.caption).foregroundColor(.gray)
                }
                Spacer()
                Text(m.date.formatted(date: .omitted, time: .shortened))
                    .font(.caption2).foregroundColor(.gray)
            }

        case .checkIn(let m):
            HStack(spacing: 12) {
                Image(systemName: "face.smiling")
                    .foregroundColor(.purple)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Check-in").font(.subheadline)
                    Text(m.summary).font(.caption).foregroundColor(.gray)
                }
                Spacer()
                Text(m.date.formatted(date: .omitted, time: .shortened))
                    .font(.caption2).foregroundColor(.gray)
            }

        case .saunaSession(let m):
            NavigationLink(destination: SaunaSessionDetailView(measurement: m)) {
                HStack(spacing: 12) {
                    Image(systemName: "flame.fill")
                        .foregroundColor(.orange)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Sauna").font(.subheadline)
                        Text(m.summary).font(.caption).foregroundColor(.gray)
                    }
                    Spacer()
                    Text(m.date.formatted(date: .omitted, time: .shortened))
                        .font(.caption2).foregroundColor(.gray)
                }
            }
        }
    }

    // MARK: - Derived Row Helpers

    private func isSleepScore(_ m: SensorMeasurement) -> Bool {
        m.sources.contains { $0.algorithmName == SleepMeasurementProvider.algorithmID }
    }

    private func derivedIcon(for m: SensorMeasurement) -> some View {
        if isSleepScore(m) {
            return Image(systemName: "moon.zzz.fill")
                .foregroundColor(.purple)
        } else {
            return Image(systemName: "heart.circle.fill")
                .foregroundColor(.red)
        }
    }

    private func derivedTitle(for m: SensorMeasurement) -> String {
        isSleepScore(m) ? "Sleep Score" : "Recovery Score"
    }

    private func derivedSubtitle(for m: SensorMeasurement) -> String {
        if isSleepScore(m) {
            if let score = m.dataPoints.first(where: { $0.type == DataType.sleepScore }) {
                return "\(Int(score.value.rounded()))/100"
            }
        } else {
            if let score = m.dataPoints.first(where: { $0.type == DataType.recoveryIndex }) {
                let level = Int(score.value.rounded())
                let label: String
                switch score.value {
                case 75...: label = "Excellent"
                case 50...: label = "Good"
                case 25...: label = "Fair"
                default:    label = "Poor"
                }
                return "\(level)/100 · \(label)"
            }
        }
        return ""
    }

    // MARK: - Metric Row Builder

    /// Build metric rows from daily aggregates via MetricIndex.
    private func buildMetricRows() -> [DataRow] {
        let metricIndex = MetricIndex(store: measurementStore)
        return metricIndex.dailyMetricSummaries().map { s in
            let summary = formatMetricSummary(type: s.type, count: s.count,
                                              avg: s.avg, min: s.min, max: s.max, unit: s.unit)
            return DataRow.metric(date: s.date, type: s.type, count: s.count, summary: summary)
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
        case .workout:     return 0
        case .metric:      return 1
        case .bodyComp:    return 2
        case .derived:     return 3
        case .labResults:  return 4
        case .fluidIntake:    return 5
        case .checkIn:        return 6
        case .saunaSession:   return 7
        }
    }
}
