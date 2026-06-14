import SwiftUI
import Combine
import WatchKit

/// Shows a live timer for the current round with a stop button.
/// Digital Crown rotation past threshold stops the round (Water Lock friendly).
struct ActiveRoundView: View {
    let round: SaunaRound
    let roundNumber: Int
    let onStop: () -> Void

    @EnvironmentObject var workoutManager: WorkoutManager
    @State private var elapsed: TimeInterval = 0
    @State private var crownValue = 0.0
    @State private var didTriggerStop = false
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 8) {
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

            // Heart rate
            if let hr = workoutManager.heartRate {
                HStack(spacing: 4) {
                    Image(systemName: "heart.fill")
                        .foregroundStyle(.red)
                        .font(.caption)
                    Text("\(Int(hr))")
                        .font(.system(.title3, design: .rounded).bold())
                    Text("bpm")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

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

            // Crown hint
            Text("Turn crown to stop")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
        .focusable()
        .digitalCrownRotation($crownValue, from: 0, through: 1.0, sensitivity: .low)
        .onChange(of: crownValue) { _, newValue in
            if newValue >= 0.8 && !didTriggerStop {
                didTriggerStop = true
                WKInterfaceDevice.current().play(.stop)
                onStop()
            }
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
