import SwiftUI
import Charts

/// Dashboard showing today's fluid intake, breakdown by category, and history.
struct FluidDashboardView: View {
    @EnvironmentObject var fluidIntakeProvider: FluidIntakeProvider
    @EnvironmentObject var drinkTemplateStore: DrinkTemplateStore

    @State private var showDrinkLog = false

    private let hydrationGoal: Double = {
        let goal = UserDefaults.standard.integer(forKey: "hydration_goal_ml")
        return goal > 0 ? Double(goal) : 2500
    }()

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Today's total with progress ring
                todaySummary

                // Category breakdown
                if !fluidIntakeProvider.todayDrinks.isEmpty {
                    categoryBreakdown
                }

                // Caffeine & alcohol
                if fluidIntakeProvider.todayCaffeineTotal > 0 || fluidIntakeProvider.todayAlcoholUnits > 0 {
                    substanceSummary
                }

                // Drink history
                if !fluidIntakeProvider.todayDrinks.isEmpty {
                    drinkHistory
                }
            }
            .padding()
        }
        .background(Color.appBackground)
        .navigationTitle("Hydration")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showDrinkLog = true } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showDrinkLog) {
            DrinkLogSheet()
        }
    }

    // MARK: - Today Summary

    private var todaySummary: some View {
        let total = fluidIntakeProvider.todayTotalMl
        let progress = min(total / hydrationGoal, 1.0)

        return VStack(spacing: 8) {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.1), lineWidth: 12)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(Color.cyan, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.5), value: progress)
                VStack {
                    Text(String(format: "%.0f", total))
                        .font(.system(size: 36, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text("/ \(Int(hydrationGoal)) mL")
                        .font(.caption)
                        .foregroundStyle(.gray)
                }
            }
            .frame(width: 160, height: 160)

            Text("\(fluidIntakeProvider.todayDrinks.count) drinks today")
                .font(.subheadline)
                .foregroundStyle(.gray)
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.05)))
    }

    // MARK: - Category Breakdown

    private var categoryBreakdown: some View {
        let categories = Dictionary(grouping: fluidIntakeProvider.todayDrinks) { drink -> String in
            drink.dataPoints.first(where: { $0.type == DataType.fluidCategory })?.unit ?? "other"
        }
        let breakdown = categories.map { (category: $0.key, total: $0.value.flatMap(\.dataPoints)
            .filter { $0.type == DataType.fluidVolume }.reduce(0) { $0 + $1.value }) }
            .sorted { $0.total > $1.total }

        return VStack(alignment: .leading, spacing: 8) {
            Text("BREAKDOWN")
                .font(.caption.bold())
                .foregroundStyle(.gray)

            ForEach(breakdown, id: \.category) { item in
                let cat = DrinkCategory(rawValue: item.category) ?? .other
                HStack {
                    Image(systemName: cat.icon)
                        .foregroundStyle(.cyan)
                        .frame(width: 24)
                    Text(cat.label)
                        .foregroundStyle(.white)
                    Spacer()
                    Text(String(format: "%.0f mL", item.total))
                        .foregroundStyle(.gray)
                }
            }
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.05)))
    }

    // MARK: - Substance Summary

    private var substanceSummary: some View {
        HStack(spacing: 16) {
            if fluidIntakeProvider.todayCaffeineTotal > 0 {
                VStack {
                    Image(systemName: "cup.and.saucer.fill")
                        .foregroundStyle(.brown)
                    Text(String(format: "%.0f mg", fluidIntakeProvider.todayCaffeineTotal))
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text("Caffeine")
                        .font(.caption)
                        .foregroundStyle(.gray)
                }
                .frame(maxWidth: .infinity)
            }

            if fluidIntakeProvider.todayAlcoholUnits > 0 {
                VStack {
                    Image(systemName: "wineglass.fill")
                        .foregroundStyle(.orange)
                    Text(String(format: "%.1f", fluidIntakeProvider.todayAlcoholUnits))
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text("Drinks")
                        .font(.caption)
                        .foregroundStyle(.gray)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.05)))
    }

    // MARK: - Drink History

    private var drinkHistory: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("TODAY'S DRINKS")
                .font(.caption.bold())
                .foregroundStyle(.gray)

            ForEach(fluidIntakeProvider.todayDrinks) { drink in
                let volume = drink.dataPoints.first(where: { $0.type == DataType.fluidVolume })?.value ?? 0
                let category = drink.dataPoints.first(where: { $0.type == DataType.fluidCategory })?.unit ?? "other"
                let cat = DrinkCategory(rawValue: category) ?? .other
                let time = drink.date.formatted(date: .omitted, time: .shortened)

                HStack {
                    Image(systemName: cat.icon)
                        .foregroundStyle(.cyan)
                        .frame(width: 24)
                    VStack(alignment: .leading) {
                        Text(cat.label)
                            .foregroundStyle(.white)
                        Text("\(Int(volume)) mL")
                            .font(.caption)
                            .foregroundStyle(.gray)
                    }
                    Spacer()
                    Text(time)
                        .font(.caption)
                        .foregroundStyle(.gray)
                }
                .padding(.vertical, 4)
            }
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.05)))
    }
}
