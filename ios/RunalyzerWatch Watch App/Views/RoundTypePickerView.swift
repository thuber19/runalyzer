import SwiftUI
import Combine
import WatchKit

/// Vertical list of round types — scrollable with Digital Crown even during Water Lock.
/// Crown rotation highlights a type; after 2 seconds of no rotation, auto-selects it.
struct RoundTypePickerView: View {
    let onSelect: (SaunaRoundType) -> Void
    let showEndSession: Bool
    let onEndSession: (() -> Void)?

    init(showEndSession: Bool = false,
         onEndSession: (() -> Void)? = nil,
         onSelect: @escaping (SaunaRoundType) -> Void) {
        self.showEndSession = showEndSession
        self.onEndSession = onEndSession
        self.onSelect = onSelect
    }

    private let allTypes = SaunaRoundType.allCases
    @State private var crownValue = 0.0
    @State private var highlightedIndex: Int? = nil
    @State private var confirmCountdown: Double = 0
    @State private var confirmTimer: Timer? = nil

    var body: some View {
        VStack(spacing: 0) {
            List {
                ForEach(Array(allTypes.enumerated()), id: \.element.id) { index, roundType in
                    let isHighlighted = highlightedIndex == index
                    Button {
                        onSelect(roundType)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: roundType.icon)
                                .foregroundStyle(roundType.color)
                                .frame(width: 24)
                            Text(roundType.label)
                                .font(.body)
                                .fontWeight(isHighlighted ? .bold : .regular)
                            Spacer()
                            if isHighlighted {
                                CountdownRing(progress: confirmCountdown)
                                    .frame(width: 20, height: 20)
                            }
                        }
                    }
                    .listRowBackground(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(roundType.color.opacity(isHighlighted ? 0.4 : 0.15))
                    )
                }

                if showEndSession {
                    Button("End Session", role: .destructive) {
                        onEndSession?()
                    }
                }
            }
        }
        .focusable()
        .digitalCrownRotation(
            $crownValue,
            from: 0,
            through: Double(allTypes.count - 1),
            by: 1,
            sensitivity: .medium,
            isContinuous: false
        )
        .onChange(of: crownValue) { _, newValue in
            let index = min(max(Int(newValue.rounded()), 0), allTypes.count - 1)
            highlightedIndex = index
            startConfirmCountdown(for: index)
        }
        .navigationTitle("Next Round")
    }

    private func startConfirmCountdown(for index: Int) {
        confirmTimer?.invalidate()
        confirmCountdown = 0

        // Animate the countdown ring over 2 seconds
        let steps = 20
        let interval = 2.0 / Double(steps)
        var tick = 0

        confirmTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { timer in
            tick += 1
            confirmCountdown = Double(tick) / Double(steps)

            if tick >= steps {
                timer.invalidate()
                // Auto-select
                if let idx = highlightedIndex, idx < allTypes.count {
                    WKInterfaceDevice.current().play(.click)
                    onSelect(allTypes[idx])
                }
            }
        }
    }
}

/// Small circular countdown indicator.
private struct CountdownRing: View {
    let progress: Double

    var body: some View {
        Circle()
            .trim(from: 0, to: progress)
            .stroke(Color.white, lineWidth: 2)
            .rotationEffect(.degrees(-90))
            .animation(.linear(duration: 0.1), value: progress)
    }
}
