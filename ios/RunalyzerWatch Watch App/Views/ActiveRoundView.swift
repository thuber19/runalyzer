import SwiftUI
import Combine

/// Shows a live timer for the current round with a stop button.
struct ActiveRoundView: View {
    let round: SaunaRound
    let roundNumber: Int
    let onStop: () -> Void

    @State private var elapsed: TimeInterval = 0
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 12) {
            // Round type indicator
            HStack(spacing: 6) {
                Image(systemName: round.type.icon)
                    .foregroundStyle(round.type.color)
                Text(round.type.label)
                    .font(.caption)
            }

            // Large timer
            Text(formatDuration(elapsed))
                .font(.system(size: 44, weight: .medium, design: .monospaced))
                .foregroundStyle(round.type.color)

            Text("Round \(roundNumber)")
                .font(.caption2)
                .foregroundStyle(.secondary)

            // Stop button
            Button {
                onStop()
            } label: {
                Image(systemName: "stop.fill")
                    .font(.title2)
            }
            .buttonStyle(.bordered)
            .tint(round.type.color)
        }
        .onReceive(timer) { _ in
            elapsed = round.durationSec
        }
        .onAppear {
            elapsed = round.durationSec
        }
        .navigationBarBackButtonHidden(true)
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return String(format: "%d:%02d", m, s)
    }
}
