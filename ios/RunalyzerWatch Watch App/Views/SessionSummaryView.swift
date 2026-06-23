import SwiftUI

/// Post-session summary showing all rounds, rest periods, and totals.
struct SessionSummaryView: View {
    let session: WellnessSession
    let onDone: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                // Headline
                Text("Session Complete")
                    .font(.headline)

                // Summary stats
                HStack(spacing: 16) {
                    VStack {
                        Text("\(session.rounds.count)")
                            .font(.title2.bold())
                        Text("Rounds")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    VStack {
                        Text(formatDuration(session.totalDurationSec))
                            .font(.title2.bold())
                        Text("Total")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()

                // Round list with rest periods interleaved
                let restPeriods = session.restPeriods
                ForEach(Array(session.rounds.enumerated()), id: \.element.id) { index, round in
                    // Rest period before this round (if any)
                    if let rest = restPeriods.first(where: { $0.after == index - 1 }) {
                        HStack {
                            Image(systemName: "pause.circle")
                                .foregroundStyle(.gray)
                                .frame(width: 20)
                            Text("Rest")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(formatDuration(rest.duration))
                                .font(.caption.monospaced())
                                .foregroundStyle(.tertiary)
                        }
                    }

                    HStack {
                        Image(systemName: round.type.icon)
                            .foregroundStyle(round.type.color)
                            .frame(width: 20)
                        Text(round.type.label)
                            .font(.caption)
                        Spacer()
                        Text(formatDuration(round.durationSec))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }

                Button("Done") {
                    onDone()
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 8)
            }
            .padding(.horizontal, 4)
        }
        .navigationBarBackButtonHidden(true)
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return String(format: "%d:%02d", m, s)
    }
}
