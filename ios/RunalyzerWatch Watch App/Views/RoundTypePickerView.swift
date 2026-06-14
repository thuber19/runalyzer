import SwiftUI

/// Grid of round types to pick from when starting a new round or beginning a session.
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

    private let columns = [
        GridItem(.flexible()),
        GridItem(.flexible())
    ]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(SaunaRoundType.allCases) { roundType in
                    Button {
                        onSelect(roundType)
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: roundType.icon)
                                .font(.title3)
                                .foregroundStyle(roundType.color)
                            Text(roundType.label)
                                .font(.caption2)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                    }
                    .buttonStyle(.bordered)
                    .tint(roundType.color)
                }
            }
            .padding(.horizontal, 4)

            if showEndSession {
                Button("End Session", role: .destructive) {
                    onEndSession?()
                }
                .padding(.top, 8)
            }
        }
        .navigationTitle("Next Round")
    }
}
