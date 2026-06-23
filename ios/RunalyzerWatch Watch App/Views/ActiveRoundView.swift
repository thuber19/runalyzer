import SwiftUI
import Combine
import WatchKit

/// Shows a live timer for the current round.
/// Digital Crown rotation past threshold stops the round (Water Lock friendly).
/// Crown progress decays back to zero when the user stops turning.
struct ActiveRoundView: View {
    let round: WellnessRound
    let roundNumber: Int
    let onStop: () -> Void

    @EnvironmentObject var workoutManager: WorkoutManager
    @State private var elapsed: TimeInterval = 0
    @State private var crownValue = 0.0
    @State private var displayProgress = 0.0
    @State private var didTriggerStop = false
    @State private var decayTimer: Timer?
    @State private var lastCrownChange = Date()
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    /// Crown must reach this value to trigger stop
    private let stopThreshold = 1.5

    var body: some View {
        VStack(spacing: 6) {
            // Round type indicator
            HStack(spacing: 6) {
                Image(systemName: round.type.icon)
                    .foregroundStyle(round.type.color)
                Text(round.type.label)
                    .font(.caption)
            }

            // Large timer
            Text(formatDuration(elapsed))
                .font(.system(size: 48, weight: .medium, design: .monospaced))
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

            Spacer()

            // Crown stop indicator
            CrownStopIndicator(progress: displayProgress / stopThreshold)
                .frame(height: 4)
                .padding(.horizontal, 20)

            Text("Turn crown to stop")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
        .focusable()
        .digitalCrownRotation($crownValue, from: 0, through: stopThreshold, sensitivity: .low)
        .onChange(of: crownValue) { _, newValue in
            lastCrownChange = Date()
            displayProgress = newValue
            scheduleDecay()

            if newValue >= stopThreshold && !didTriggerStop {
                didTriggerStop = true
                decayTimer?.invalidate()
                WKInterfaceDevice.current().play(.stop)
                onStop()
            }
        }
        .onReceive(timer) { _ in
            elapsed = round.durationSec
        }
        .onAppear {
            elapsed = round.durationSec
            crownValue = 0
            displayProgress = 0
            didTriggerStop = false
        }
        .onDisappear {
            decayTimer?.invalidate()
        }
        .navigationBarBackButtonHidden(true)
    }

    /// After 1 second of no crown input, decay progress back to zero.
    private func scheduleDecay() {
        decayTimer?.invalidate()
        decayTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { _ in
            DispatchQueue.main.async {
                withAnimation(.easeOut(duration: 0.4)) {
                    crownValue = 0
                    displayProgress = 0
                }
            }
        }
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return String(format: "%d:%02d", m, s)
    }
}

/// Horizontal bar showing crown rotation progress toward stop threshold.
private struct CrownStopIndicator: View {
    let progress: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.15))
                Capsule()
                    .fill(Color.white.opacity(0.6))
                    .frame(width: geo.size.width * min(max(progress, 0), 1.0))
                    .animation(.easeOut(duration: 0.15), value: progress)
            }
        }
    }
}
