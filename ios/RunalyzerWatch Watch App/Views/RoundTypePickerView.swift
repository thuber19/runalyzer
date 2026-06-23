import SwiftUI
import Combine
import WatchKit

/// Crown-driven round type picker. Single static view — crown changes which item is shown.
/// Hovering on a type for 2 seconds auto-confirms it.
/// No ScrollView, no TabView, no List — just a single VStack that swaps content.
struct RoundTypePickerView: View {
    let onSelect: (WellnessRoundType) -> Void
    let onEndSession: (() -> Void)?
    let restStartDate: Date?

    private let allTypes = WellnessRoundType.allCases
    /// Index 0 = rest/landing, 1..N = round types, N+1 = end session
    private var maxIndex: Int { allTypes.count + 1 }

    @State private var crownValue = 0.0
    @State private var selectedIndex = 0
    @State private var confirmProgress: Double = 0
    @State private var confirmTimer: Timer? = nil
    @State private var restElapsed: TimeInterval = 0
    @State private var dismissed = false
    private let restTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    init(restStartDate: Date? = nil,
         onEndSession: (() -> Void)? = nil,
         onSelect: @escaping (WellnessRoundType) -> Void) {
        self.restStartDate = restStartDate
        self.onEndSession = onEndSession
        self.onSelect = onSelect
    }

    var body: some View {
        VStack(spacing: 8) {
            Spacer()

            if selectedIndex == 0 {
                // Rest / landing page
                Image(systemName: "pause.circle.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(.gray)
                if restStartDate != nil {
                    Text("Rest")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text(formatDuration(restElapsed))
                        .font(.system(.title2, design: .monospaced))
                        .foregroundStyle(.secondary)
                } else {
                    Text("Select Round")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
                Text("Scroll to choose")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 4)
            } else if selectedIndex <= allTypes.count {
                // Round type
                let roundType = allTypes[selectedIndex - 1]
                Image(systemName: roundType.icon)
                    .font(.system(size: 44))
                    .foregroundStyle(roundType.color)
                Text(roundType.label)
                    .font(.title3.bold())
                CountdownBar(progress: confirmProgress, color: roundType.color)
                    .frame(height: 4)
                    .padding(.horizontal, 30)
            } else {
                // End Session
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.red)
                Text("End Session")
                    .font(.title3.bold())
                    .foregroundStyle(.red)
                CountdownBar(progress: confirmProgress, color: .red)
                    .frame(height: 4)
                    .padding(.horizontal, 30)
            }

            Spacer()

            // Position dots
            HStack(spacing: 4) {
                ForEach(0...maxIndex, id: \.self) { i in
                    Circle()
                        .fill(i == selectedIndex ? Color.white : Color.white.opacity(0.3))
                        .frame(width: 5, height: 5)
                }
            }
            .padding(.bottom, 4)
        }
        .focusable()
        .digitalCrownRotation(
            $crownValue,
            from: 0,
            through: Double(maxIndex),
            by: 1,
            sensitivity: .medium,
            isContinuous: false
        )
        .onChange(of: crownValue) { _, newValue in
            guard !dismissed else { return }
            let index = min(max(Int(newValue.rounded()), 0), maxIndex)
            if index != selectedIndex {
                selectedIndex = index
                WKInterfaceDevice.current().play(.click)
                if index == 0 {
                    cancelConfirmCountdown()
                } else {
                    startConfirmCountdown(for: index)
                }
            }
        }
        .onReceive(restTimer) { _ in
            if let start = restStartDate {
                restElapsed = Date().timeIntervalSince(start)
            }
        }
        .onAppear {
            selectedIndex = 0
            crownValue = 0
            confirmProgress = 0
            dismissed = false
        }
        .onDisappear {
            confirmTimer?.invalidate()
        }
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
                guard !dismissed else { return }
                dismissed = true
                WKInterfaceDevice.current().play(.start)

                let typeIndex = index - 1
                if typeIndex >= 0 && typeIndex < allTypes.count {
                    onSelect(allTypes[typeIndex])
                } else {
                    onEndSession?()
                }
            }
        }
    }

    private func cancelConfirmCountdown() {
        confirmTimer?.invalidate()
        confirmProgress = 0
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return String(format: "%d:%02d", m, s)
    }
}

/// Horizontal bar showing countdown progress.
private struct CountdownBar: View {
    let progress: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(color.opacity(0.2))
                Capsule()
                    .fill(color)
                    .frame(width: geo.size.width * min(max(progress, 0), 1.0))
                    .animation(.linear(duration: 0.1), value: progress)
            }
        }
    }
}
