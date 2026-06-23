import SwiftUI
import Combine
import WatchKit

/// Crown-scrollable round type picker. Hovering on a type for 2 seconds auto-confirms it.
/// Works entirely without touching the screen (Water Lock compatible).
struct RoundTypePickerView: View {
    let onSelect: (SaunaRoundType) -> Void
    let onEndSession: (() -> Void)?
    let restStartDate: Date?

    private let allTypes = SaunaRoundType.allCases
    /// All items: round types + "End Session" sentinel
    private var itemCount: Int { allTypes.count + 1 }

    @State private var crownValue = 0.0
    @State private var highlightedIndex = 0
    @State private var confirmProgress: Double = 0
    @State private var confirmTimer: Timer? = nil
    @State private var restElapsed: TimeInterval = 0
    private let restTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    init(restStartDate: Date? = nil,
         onEndSession: (() -> Void)? = nil,
         onSelect: @escaping (SaunaRoundType) -> Void) {
        self.restStartDate = restStartDate
        self.onEndSession = onEndSession
        self.onSelect = onSelect
    }

    var body: some View {
        VStack(spacing: 0) {
            // Rest timer
            if restStartDate != nil {
                HStack(spacing: 4) {
                    Image(systemName: "pause.circle")
                        .foregroundStyle(.gray)
                        .font(.caption2)
                    Text("Rest \(formatDuration(restElapsed))")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 4)
                .padding(.bottom, 2)
            }

            // Type list
            ScrollViewReader { proxy in
                List {
                    ForEach(Array(allTypes.enumerated()), id: \.element.id) { index, roundType in
                        let isHighlighted = highlightedIndex == index
                        HStack(spacing: 10) {
                            Image(systemName: roundType.icon)
                                .foregroundStyle(roundType.color)
                                .frame(width: 24)
                            Text(roundType.label)
                                .font(.body)
                                .fontWeight(isHighlighted ? .bold : .regular)
                            Spacer()
                            if isHighlighted {
                                CountdownRing(progress: confirmProgress)
                                    .frame(width: 20, height: 20)
                            }
                        }
                        .id(index)
                        .listRowBackground(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(roundType.color.opacity(isHighlighted ? 0.4 : 0.15))
                        )
                    }

                    // End Session item
                    let isEndHighlighted = highlightedIndex == allTypes.count
                    HStack(spacing: 10) {
                        Image(systemName: "xmark.circle")
                            .foregroundStyle(.red)
                            .frame(width: 24)
                        Text("End Session")
                            .font(.body)
                            .fontWeight(isEndHighlighted ? .bold : .regular)
                            .foregroundStyle(.red)
                        Spacer()
                        if isEndHighlighted {
                            CountdownRing(progress: confirmProgress)
                                .frame(width: 20, height: 20)
                        }
                    }
                    .id(allTypes.count)
                    .listRowBackground(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.red.opacity(isEndHighlighted ? 0.4 : 0.15))
                    )
                }
                .onChange(of: highlightedIndex) { _, newIndex in
                    withAnimation {
                        proxy.scrollTo(newIndex, anchor: .center)
                    }
                }
            }
        }
        .focusable()
        .digitalCrownRotation(
            $crownValue,
            from: 0,
            through: Double(itemCount - 1),
            by: 1,
            sensitivity: .medium,
            isContinuous: false
        )
        .onChange(of: crownValue) { _, newValue in
            let index = min(max(Int(newValue.rounded()), 0), itemCount - 1)
            if index != highlightedIndex {
                highlightedIndex = index
                WKInterfaceDevice.current().play(.click)
                startConfirmCountdown(for: index)
            }
        }
        .onReceive(restTimer) { _ in
            if let start = restStartDate {
                restElapsed = Date().timeIntervalSince(start)
            }
        }
        .onAppear {
            highlightedIndex = 0
            crownValue = 0
            startConfirmCountdown(for: 0)
        }
        .navigationTitle("Next Round")
        .navigationBarBackButtonHidden(true)
    }

    private func startConfirmCountdown(for index: Int) {
        confirmTimer?.invalidate()
        confirmProgress = 0

        let steps = 20
        let interval = 2.0 / Double(steps)
        var tick = 0

        confirmTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { timer in
            tick += 1
            confirmProgress = Double(tick) / Double(steps)

            if tick >= steps {
                timer.invalidate()
                WKInterfaceDevice.current().play(.start)
                if index < allTypes.count {
                    onSelect(allTypes[index])
                } else {
                    onEndSession?()
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
