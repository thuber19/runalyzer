import SwiftUI

/// Evening check-in sheet for energy level and tags.
/// Presented as a sheet from HomeTab or via notification.
struct EveningCheckInSheet: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var checkInProvider: CheckInProvider
    @EnvironmentObject var fluidIntakeProvider: FluidIntakeProvider

    @State private var selectedEnergy: Int?
    @State private var selectedTags: Set<CheckInTag> = []
    @State private var showDrinkLog = false

    private let energyLevels: [(score: Int, label: String, icon: String, color: Color)] = [
        (1, "Very Low", "battery.0percent", .red),
        (2, "Low",      "battery.25percent", .orange),
        (3, "OK",       "battery.50percent", .yellow),
        (4, "Good",     "battery.75percent", .green),
        (5, "Great",    "battery.100percent", .cyan),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    // Energy level
                    VStack(alignment: .leading, spacing: 12) {
                        Text("How was your energy today?")
                            .font(.title3.bold())
                            .foregroundStyle(.white)

                        HStack(spacing: 12) {
                            ForEach(energyLevels, id: \.score) { level in
                                Button {
                                    withAnimation(.spring(response: 0.3)) {
                                        selectedEnergy = level.score
                                    }
                                } label: {
                                    VStack(spacing: 6) {
                                        Image(systemName: level.icon)
                                            .font(.system(size: 22))
                                            .foregroundStyle(selectedEnergy == level.score ? level.color : .gray)
                                        Text(level.label)
                                            .font(.caption2)
                                            .foregroundStyle(selectedEnergy == level.score ? .white : .gray)
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                                    .background(
                                        RoundedRectangle(cornerRadius: 10)
                                            .fill(selectedEnergy == level.score
                                                  ? level.color.opacity(0.2)
                                                  : Color.white.opacity(0.05))
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 10)
                                            .stroke(selectedEnergy == level.score ? level.color : .clear, lineWidth: 2)
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    // Tags
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Any tags for today?")
                            .font(.headline)
                            .foregroundStyle(.white)

                        LazyVGrid(columns: [
                            GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())
                        ], spacing: 10) {
                            ForEach(CheckInTag.allCases, id: \.self) { tag in
                                let isSelected = selectedTags.contains(tag)
                                Button {
                                    withAnimation(.spring(response: 0.3)) {
                                        if isSelected { selectedTags.remove(tag) }
                                        else { selectedTags.insert(tag) }
                                    }
                                } label: {
                                    VStack(spacing: 4) {
                                        Image(systemName: tag.icon)
                                            .font(.system(size: 18))
                                        Text(tag.label)
                                            .font(.caption2)
                                    }
                                    .foregroundStyle(isSelected ? .white : .gray)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 10)
                                    .background(
                                        RoundedRectangle(cornerRadius: 10)
                                            .fill(isSelected ? Color.blue.opacity(0.3) : Color.white.opacity(0.05))
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 10)
                                            .stroke(isSelected ? Color.blue : .clear, lineWidth: 1.5)
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    // Alcohol summary
                    if fluidIntakeProvider.todayAlcoholUnits > 0 {
                        HStack {
                            Image(systemName: "wineglass.fill")
                                .foregroundStyle(.orange)
                            Text(String(format: "%.1f drinks logged today", fluidIntakeProvider.todayAlcoholUnits))
                                .foregroundStyle(.white)
                            Spacer()
                        }
                        .padding()
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color.orange.opacity(0.15)))
                    }

                    // Save button
                    Button {
                        if let energy = selectedEnergy {
                            checkInProvider.saveEveningCheckIn(energy: energy, tags: selectedTags)
                            dismiss()
                        }
                    } label: {
                        Text("Save")
                            .font(.headline)
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(
                                RoundedRectangle(cornerRadius: 14)
                                    .fill(selectedEnergy != nil ? Color.cyan : Color.gray.opacity(0.3))
                            )
                    }
                    .disabled(selectedEnergy == nil)
                }
                .padding()
            }
            .background(Color.appBackground)
            .navigationTitle("Evening Check-in")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
            .sheet(isPresented: $showDrinkLog) {
                DrinkLogSheet()
            }
        }
    }
}
