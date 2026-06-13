import SwiftUI

/// Full-screen morning gate that asks how rested the user feels.
/// Shown before the dashboard on first app open of the day to avoid anchoring bias.
struct MorningCheckInView: View {
    @EnvironmentObject var checkInProvider: CheckInProvider
    @State private var selectedScore: Int?

    private let levels: [(score: Int, label: String, icon: String, color: Color)] = [
        (1, "Exhausted", "battery.0percent", .red),
        (2, "Tired",     "battery.25percent", .orange),
        (3, "OK",        "battery.50percent", .yellow),
        (4, "Good",      "battery.75percent", .green),
        (5, "Great",     "battery.100percent", .cyan),
    ]

    var body: some View {
        ZStack {
            Color.appBackground.ignoresSafeArea()

            VStack(spacing: 32) {
                Spacer()

                VStack(spacing: 8) {
                    Text("Good Morning")
                        .font(.largeTitle.bold())
                        .foregroundStyle(.white)
                    Text("How rested do you feel?")
                        .font(.title3)
                        .foregroundStyle(.gray)
                }

                HStack(spacing: 16) {
                    ForEach(levels, id: \.score) { level in
                        Button {
                            withAnimation(.spring(response: 0.3)) {
                                selectedScore = level.score
                            }
                        } label: {
                            VStack(spacing: 8) {
                                Image(systemName: level.icon)
                                    .font(.system(size: 28))
                                    .foregroundStyle(selectedScore == level.score ? level.color : .gray)
                                Text(level.label)
                                    .font(.caption)
                                    .foregroundStyle(selectedScore == level.score ? .white : .gray)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(selectedScore == level.score
                                          ? level.color.opacity(0.2)
                                          : Color.white.opacity(0.05))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(selectedScore == level.score ? level.color : .clear, lineWidth: 2)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)

                Button {
                    if let score = selectedScore {
                        checkInProvider.saveMorningCheckIn(readiness: score)
                    }
                } label: {
                    Text("Confirm")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(
                            RoundedRectangle(cornerRadius: 14)
                                .fill(selectedScore != nil ? Color.cyan : Color.gray.opacity(0.3))
                        )
                }
                .disabled(selectedScore == nil)
                .padding(.horizontal)

                Spacer()

                Button("Skip") {
                    // Save with score 0 to mark as skipped (won't show gate again today)
                    checkInProvider.saveMorningCheckIn(readiness: 0)
                }
                .font(.subheadline)
                .foregroundStyle(.gray)
                .padding(.bottom, 32)
            }
        }
    }
}
