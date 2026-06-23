import SwiftUI

/// Body composition dashboard with latest readings and trends.
struct BodyCompDashboardView: View {
    @EnvironmentObject var measurementStore: MeasurementStore

    @State private var timeRange: CategoryDashboardView.CategoryRange = .day

    private let cal = Calendar.current

    /// All body comp readings (scale + HealthKit), sorted by date.
    /// Both sources are stored as .bodyComp measurements with unified data point structure.
    private var allReadings: [BodyReading] {
        measurementStore.measurements(ofType: .bodyComp)
            .compactMap { m -> BodyReading? in
                let dp = measurementStore.dataPoints(for: m.id)
                guard let w = dp.first(where: { $0.type == DataType.weight })?.value else { return nil }
                return BodyReading(
                    date: m.date,
                    weight: w,
                    bodyFatPct: dp.first(where: { $0.type == DataType.bodyFatPercent })?.value,
                    muscleMassKg: dp.first(where: { $0.type == DataType.muscleMassKg })?.value,
                    musclePct: dp.first(where: { $0.type == DataType.musclePercent })?.value,
                    fatMassKg: dp.first(where: { $0.type == DataType.fatMassKg })?.value,
                    fatFreeMassKg: dp.first(where: { $0.type == DataType.fatFreeMassKg })?.value,
                    bodyWaterPct: dp.first(where: { $0.type == DataType.bodyWaterPercent })?.value,
                    bmi: dp.first(where: { $0.type == DataType.bmi })?.value,
                    bmrKcal: dp.first(where: { $0.type == DataType.bmrKcal })?.value
                )
            }
            .sorted(by: { $0.date < $1.date })
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                rangePicker
                if timeRange.isDaily {
                    dailyView
                } else {
                    periodView
                }
            }
            .padding()
        }
        .background(Color(hex: 0x1a1a2e))
        .navigationTitle("Body")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - 1D: Latest Reading

    private var dailyView: some View {
        let readings = allReadings
        guard let latest = readings.last else {
            return AnyView(noDataCard)
        }

        let dateStr = Self.dateFmt.string(from: latest.date)

        return AnyView(VStack(spacing: 12) {
            // Primary: Weight
            VStack(spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(String(format: "%.1f", latest.weight))
                        .font(.system(size: 42, weight: .bold, design: .rounded).monospacedDigit())
                    Text("kg").font(.title3).foregroundColor(.gray)
                }
                Text(dateStr).font(.caption2).foregroundColor(.gray)
            }
            .frame(maxWidth: .infinity)
            .padding()
            .background(Color(hex: 0x16213e))
            .cornerRadius(12)

            // Composition breakdown (if available from scale)
            if latest.bodyFatPct != nil || latest.muscleMassKg != nil {
                HStack(spacing: 0) {
                    if let bf = latest.bodyFatPct {
                        statCol(String(format: "%.1f%%", bf), "Body Fat", bodyFatColor(bf))
                    }
                    if let mm = latest.muscleMassKg {
                        statCol(String(format: "%.1f kg", mm), "Muscle")
                    }
                    if let bw = latest.bodyWaterPct {
                        statCol(String(format: "%.1f%%", bw), "Water")
                    }
                    if let bmi = latest.bmi {
                        statCol(String(format: "%.1f", bmi), "BMI", bmiColor(bmi))
                    }
                }
                .padding()
                .background(Color(hex: 0x16213e))
                .cornerRadius(12)
            }

            // Additional details
            if latest.fatMassKg != nil || latest.bmrKcal != nil {
                VStack(alignment: .leading, spacing: 8) {
                    if let fm = latest.fatMassKg {
                        detailRow("Fat Mass", String(format: "%.1f kg", fm))
                    }
                    if let ffm = latest.fatFreeMassKg {
                        detailRow("Lean Mass", String(format: "%.1f kg", ffm))
                    }
                    if let mp = latest.musclePct {
                        detailRow("Muscle %", String(format: "%.1f%%", mp))
                    }
                    if let bmr = latest.bmrKcal {
                        detailRow("BMR", String(format: "%.0f kcal", bmr))
                    }
                }
                .padding()
                .background(Color(hex: 0x16213e))
                .cornerRadius(12)
            }

            // Weight trend sparkline (30D)
            let last30 = readings.suffix(30)
            if last30.count > 1 {
                VStack(alignment: .leading, spacing: 8) {
                    Text("WEIGHT TREND (30D)").font(.caption2).foregroundColor(.gray)
                    Sparkline(values: last30.map(\.weight), color: .cyan)
                        .frame(height: 60)
                }
                .padding()
                .background(Color(hex: 0x16213e))
                .cornerRadius(12)
            }
        })
    }

    // MARK: - Period View

    private var periodView: some View {
        let readings = allReadings
        let lookback = cal.date(byAdding: .day, value: -timeRange.days, to: Date()) ?? Date()
        let periodReadings = readings.filter { $0.date >= lookback }

        guard !periodReadings.isEmpty else {
            return AnyView(noDataCard)
        }

        let latestWeight = periodReadings.last?.weight
        let firstWeight = periodReadings.first?.weight
        let weightChange = (latestWeight != nil && firstWeight != nil && firstWeight! > 0)
            ? latestWeight! - firstWeight! : nil

        return AnyView(VStack(spacing: 12) {
            // Weight summary
            HStack(spacing: 0) {
                VStack(spacing: 4) {
                    Text(latestWeight.map { String(format: "%.1f", $0) } ?? "--")
                        .font(.title.bold().monospacedDigit())
                    Text("kg").font(.caption2).foregroundColor(.gray)
                    Text("Latest").font(.caption2).foregroundColor(.cyan)
                }
                .frame(maxWidth: .infinity)

                if let change = weightChange {
                    VStack(spacing: 4) {
                        Text(String(format: "%+.1f", change))
                            .font(.title.bold().monospacedDigit())
                            .foregroundColor(change > 0.1 ? .orange : (change < -0.1 ? .green : .gray))
                        Text("kg").font(.caption2).foregroundColor(.gray)
                        Text("Change").font(.caption2).foregroundColor(.gray)
                    }
                    .frame(maxWidth: .infinity)
                }

                VStack(spacing: 4) {
                    Text("\(periodReadings.count)")
                        .font(.title.bold().monospacedDigit())
                    Text("readings").font(.caption2).foregroundColor(.gray)
                }
                .frame(maxWidth: .infinity)
            }
            .padding()
            .background(Color(hex: 0x16213e))
            .cornerRadius(12)

            // Weight chart
            if periodReadings.count > 1 {
                VStack(alignment: .leading, spacing: 8) {
                    Text("WEIGHT").font(.caption2).foregroundColor(.gray)
                    ScrubbingLineChart(
                        data: periodReadings.map { ChartDataPoint(date: $0.date, avg: $0.weight) },
                        color: .cyan, unit: "kg", showBand: false
                    )
                    .frame(height: 160)
                }
                .padding()
                .background(Color(hex: 0x16213e))
                .cornerRadius(12)
            }

            // Body fat trend (if available)
            let fatReadings = periodReadings.filter { $0.bodyFatPct != nil }
            if fatReadings.count > 1 {
                VStack(alignment: .leading, spacing: 8) {
                    Text("BODY FAT %").font(.caption2).foregroundColor(.gray)
                    ScrubbingLineChart(
                        data: fatReadings.map { ChartDataPoint(date: $0.date, avg: $0.bodyFatPct!) },
                        color: .orange, unit: "%", showBand: false
                    )
                    .frame(height: 160)
                }
                .padding()
                .background(Color(hex: 0x16213e))
                .cornerRadius(12)
            }

            // Muscle mass trend (if available)
            let muscleReadings = periodReadings.filter { $0.muscleMassKg != nil }
            if muscleReadings.count > 1 {
                VStack(alignment: .leading, spacing: 8) {
                    Text("MUSCLE MASS").font(.caption2).foregroundColor(.gray)
                    ScrubbingLineChart(
                        data: muscleReadings.map { ChartDataPoint(date: $0.date, avg: $0.muscleMassKg!) },
                        color: .green, unit: "kg", showBand: false
                    )
                    .frame(height: 160)
                }
                .padding()
                .background(Color(hex: 0x16213e))
                .cornerRadius(12)
            }
        })
    }

    // MARK: - Helpers

    private var rangePicker: some View {
        Picker("Range", selection: $timeRange) {
            ForEach(CategoryDashboardView.CategoryRange.allCases, id: \.self) { r in
                Text(r.rawValue).tag(r)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal)
    }

    private var noDataCard: some View {
        Text("No body composition data").font(.caption).foregroundColor(.gray)
            .frame(maxWidth: .infinity).padding()
            .background(Color(hex: 0x16213e)).cornerRadius(12)
    }

    private func statCol(_ value: String, _ label: String, _ color: Color = .white) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.subheadline.bold().monospacedDigit()).foregroundColor(color)
            Text(label).font(.caption2).foregroundColor(.gray)
        }
        .frame(maxWidth: .infinity)
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.subheadline).foregroundColor(.gray)
            Spacer()
            Text(value).font(.subheadline.bold().monospacedDigit())
        }
    }

    private func bodyFatColor(_ pct: Double) -> Color {
        // Rough healthy ranges (adult male)
        if pct < 10 { return .blue }
        if pct <= 20 { return .green }
        if pct <= 25 { return .yellow }
        return .orange
    }

    private func bmiColor(_ bmi: Double) -> Color {
        if bmi < 18.5 { return .blue }
        if bmi <= 24.9 { return .green }
        if bmi <= 29.9 { return .yellow }
        return .orange
    }

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
}

// MARK: - Data Model

extension BodyCompDashboardView {
    struct BodyReading {
        let date: Date
        var weight: Double
        var bodyFatPct: Double?
        var muscleMassKg: Double?
        var musclePct: Double?
        var fatMassKg: Double?
        var fatFreeMassKg: Double?
        var bodyWaterPct: Double?
        var bmi: Double?
        var bmrKcal: Double?
    }
}
