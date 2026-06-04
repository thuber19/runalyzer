import SwiftUI
import Charts
import HealthKit

struct HealthView: View {
    @EnvironmentObject var healthKit: HealthKitManager
    @State private var summary: HealthSummary?
    @State private var showDebug = false
    @State private var debugText = ""
    @State private var debugRange: DebugRange = .today

    enum DebugRange: String, CaseIterable {
        case today = "Today"
        case week = "Past 7 Days"
        case month = "Past 30 Days"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    todaySummary
                    sleepCard
                    workoutList
                    #if DEBUG
                    debugSection
                    #endif
                }
                .padding()
            }
            .refreshable {
                // L6: pull-to-refresh reloads workouts, summary, and sleep
                healthKit.fetchRecentWorkouts(force: true)
                healthKit.fetchTodaySummary { s in summary = s }
                healthKit.fetchLastNightSleep()
            }
            .background(Color(hex: 0x1a1a2e))
            .navigationTitle("Apple Health")
            .onAppear {
                healthKit.fetchRecentWorkouts()
                healthKit.fetchTodaySummary { s in summary = s }
                healthKit.fetchLastNightSleep()
            }
            .sheet(isPresented: $showDebug) {
                debugSheet
            }
        }
    }

    // MARK: - Today Summary
    private var todaySummary: some View {
        VStack(spacing: 12) {
            HStack {
                Text("TODAY").font(.caption2).foregroundColor(.gray)
                Spacer()
                Button(action: {
                    healthKit.fetchTodaySummary { s in summary = s }
                }) {
                    Image(systemName: "arrow.clockwise").font(.caption)
                }
            }

            if let s = summary {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    summaryCard(icon: "shoeprints.fill", color: .blue,
                               value: "\(s.steps)", label: "Steps")
                    summaryCard(icon: "figure.run", color: .green,
                               value: String(format: "%.2f km", s.distanceKm), label: "Distance")
                    summaryCard(icon: "flame.fill", color: .orange,
                               value: String(format: "%.0f kcal", s.calories), label: "Calories")
                    summaryCard(icon: "heart.fill", color: .red,
                               value: s.latestHR > 0 ? String(format: "%.0f bpm", s.latestHR) : "--",
                               label: "Heart Rate")
                }

                if s.avgHR > 0 {
                    HStack(spacing: 16) {
                        HStack(spacing: 4) {
                            Text("Avg").font(.caption2).foregroundColor(.gray)
                            Text(String(format: "%.0f", s.avgHR)).font(.caption.monospacedDigit())
                        }
                        HStack(spacing: 4) {
                            Text("Min").font(.caption2).foregroundColor(.gray)
                            Text(String(format: "%.0f", s.minHR)).font(.caption.monospacedDigit())
                        }
                        HStack(spacing: 4) {
                            Text("Max").font(.caption2).foregroundColor(.gray)
                            Text(String(format: "%.0f", s.maxHR)).font(.caption.monospacedDigit())
                        }
                    }
                    .foregroundColor(.red.opacity(0.8))
                }
            } else {
                ProgressView().padding()
            }
        }
        .padding()
        .background(Color(hex: 0x16213e))
        .cornerRadius(12)
    }

    private func summaryCard(icon: String, color: Color, value: String, label: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon).foregroundColor(color)
            Text(value).font(.headline.monospacedDigit())
            Text(label).font(.caption2).foregroundColor(.gray)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(Color(hex: 0x1a1a2e))
        .cornerRadius(10)
    }

    // MARK: - Sleep
    private var sleepCard: some View {
        VStack(spacing: 12) {
            HStack {
                Text("LAST NIGHT").font(.caption2).foregroundColor(.gray)
                Spacer()
                Button(action: { healthKit.fetchLastNightSleep() }) {
                    Image(systemName: "arrow.clockwise").font(.caption)
                }
            }

            if let s = healthKit.sleepSummary {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    summaryCard(icon: "bed.double.fill", color: .indigo,
                               value: s.totalAsleepString, label: "Asleep")
                    summaryCard(icon: "moon.fill", color: .purple,
                               value: s.totalInBedString, label: "In Bed")
                }

                if s.hasStages {
                    Divider().background(Color.gray.opacity(0.3))
                    Text("SLEEP STAGES").font(.system(size: 9)).foregroundColor(.gray)

                    sleepStageBar(summary: s)

                    HStack(spacing: 16) {
                        sleepLegend("Deep", minutes: s.deepMinutes, color: .indigo)
                        sleepLegend("Core", minutes: s.coreMinutes, color: .blue)
                        sleepLegend("REM",  minutes: s.remMinutes,  color: .cyan)
                    }
                }

                let effPct = Int(s.efficiency * 100)
                if effPct > 0 {
                    HStack {
                        Text("Sleep efficiency")
                            .font(.caption2).foregroundColor(.gray)
                        Spacer()
                        Text("\(effPct)%")
                            .font(.caption.monospacedDigit())
                            .foregroundColor(effPct >= 85 ? .green : effPct >= 70 ? .yellow : .red)
                    }
                }
            } else {
                EmptyStateView(
                    icon: "bed.double",
                    title: "No sleep data",
                    message: "Sleep tracked by Apple Watch or other devices will appear here"
                )
                .frame(height: 80)
            }
        }
        .padding()
        .background(Color(hex: 0x16213e))
        .cornerRadius(12)
    }

    private func sleepStageBar(summary s: SleepSummary) -> some View {
        let total = max(1, s.totalAsleepMinutes)
        return GeometryReader { proxy in
            HStack(spacing: 0) {
                Rectangle().fill(Color.indigo)
                    .frame(width: proxy.size.width * CGFloat(s.deepMinutes) / CGFloat(total))
                Rectangle().fill(Color.blue)
                    .frame(width: proxy.size.width * CGFloat(s.coreMinutes) / CGFloat(total))
                Rectangle().fill(Color.cyan)
                    .frame(width: proxy.size.width * CGFloat(s.remMinutes) / CGFloat(total))
                if s.awakeMinutes > 0 {
                    Rectangle().fill(Color.orange)
                        .frame(width: proxy.size.width * CGFloat(s.awakeMinutes) / CGFloat(total))
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: 28)
        .cornerRadius(6)
    }

    private func sleepLegend(_ label: String, minutes: Int, color: Color) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .frame(width: 10, height: 10)
            Text("\(label) \(minutes / 60)h\(minutes % 60)m")
                .font(.system(size: 9)).foregroundColor(.gray)
        }
    }

    // MARK: - Workouts
    private var workoutList: some View {
        VStack(spacing: 12) {
            HStack {
                Text("RECENT WORKOUTS").font(.caption2).foregroundColor(.gray)
                Spacer()
                Text("\(healthKit.workouts.count)").font(.caption).foregroundColor(.gray)
            }

            if healthKit.isLoadingWorkouts {
                ProgressView("Loading workouts...")
                    .padding()
                    .foregroundColor(.gray)
            } else if healthKit.workouts.isEmpty {
                EmptyStateView(
                    icon: "heart.slash",
                    title: "No workouts found",
                    message: "Workouts from Apple Health will appear here"
                )
                .frame(height: 140)
            } else {
                ForEach(healthKit.workouts.prefix(20)) { workout in
                    workoutRow(workout)
                }
            }
        }
        .padding()
        .background(Color(hex: 0x16213e))
        .cornerRadius(12)
    }

    private func workoutRow(_ w: AppleWorkout) -> some View {
        HStack {
            Image(systemName: iconFor(w.activityType))
                .foregroundColor(.pink)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(w.activityName).font(.subheadline.bold())
                Text(w.dateString).font(.caption).foregroundColor(.gray)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(w.durationString).font(.subheadline.monospacedDigit())
                if w.distanceKm > 0 {
                    Text(String(format: "%.2f km", w.distanceKm))
                        .font(.caption).foregroundColor(.gray)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func iconFor(_ type: HKWorkoutActivityType) -> String {
        switch type {
        case .running: return "figure.run"
        case .walking: return "figure.walk"
        case .cycling: return "figure.outdoor.cycle"
        case .hiking: return "figure.hiking"
        case .swimming: return "figure.pool.swim"
        default: return "figure.mixed.cardio"
        }
    }

    // MARK: - Debug
    private var debugSection: some View {
        VStack(spacing: 12) {
            HStack {
                Text("DEBUG").font(.caption2).foregroundColor(.gray)
                Spacer()
            }

            Picker("Range", selection: $debugRange) {
                ForEach(DebugRange.allCases, id: \.self) { r in
                    Text(r.rawValue).tag(r)
                }
            }
            .pickerStyle(.segmented)

            Button(action: {
                let end = Date()
                let start: Date
                switch debugRange {
                case .today: start = Calendar.current.startOfDay(for: end)
                case .week: start = end.addingTimeInterval(-7 * 86400)
                case .month: start = end.addingTimeInterval(-30 * 86400)
                }
                debugText = "Loading..."
                showDebug = true
                healthKit.debugDump(from: start, to: end) { text in
                    debugText = text
                }
            }) {
                Label("Dump Raw Health Data", systemImage: "ladybug")
                    .frame(maxWidth: .infinity).padding()
                    .background(Color.gray.opacity(0.2))
                    .foregroundColor(.gray).cornerRadius(10)
            }
        }
        .padding()
        .background(Color(hex: 0x16213e))
        .cornerRadius(12)
    }

    private var debugSheet: some View {
        NavigationStack {
            ScrollView {
                Text(debugText)
                    .font(.system(size: 11, design: .monospaced))
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .background(Color(hex: 0x1a1a2e))
            .navigationTitle("Health Data")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { showDebug = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Copy") { UIPasteboard.general.string = debugText }
                }
            }
        }
    }
}
