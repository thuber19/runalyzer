import SwiftUI

/// Vertical list of round types — scrollable with Digital Crown even during Water Lock.
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

    var body: some View {
        List {
            ForEach(SaunaRoundType.allCases) { roundType in
                Button {
                    onSelect(roundType)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: roundType.icon)
                            .foregroundStyle(roundType.color)
                            .frame(width: 24)
                        Text(roundType.label)
                            .font(.body)
                    }
                }
                .listRowBackground(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(roundType.color.opacity(0.15))
                )
            }

            if showEndSession {
                Button("End Session", role: .destructive) {
                    onEndSession?()
                }
            }
        }
        .navigationTitle("Next Round")
    }
}
