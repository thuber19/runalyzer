import SwiftUI

/// Ambient gradient hero encoding overall health state through color.
/// Uses a simple RadialGradient — no Canvas, no blur, no IOSurface allocation per frame.
/// Color animates via Core Animation's native color interpolation when vibeScore changes.
struct AuraHeroView: View {
    let vibeScore: Double?
    let headline: String
    let recoveryScore: Double?
    let sleepScore: Double?

    var body: some View {
        ZStack {
            // Background: radial gradient, no off-screen render targets
            auraColor.opacity(0.25)
                .background(
                    RadialGradient(
                        colors: [auraColor.opacity(0.55), auraColor.opacity(0.15), .clear],
                        center: UnitPoint(x: 0.5, y: 0.4),
                        startRadius: 0,
                        endRadius: 200
                    )
                )
                .animation(.easeInOut(duration: 1.5), value: auraColor)

            // Vignette overlay
            LinearGradient(
                colors: [.clear, Color(hex: 0x1a1a2e).opacity(0.4), Color(hex: 0x1a1a2e)],
                startPoint: .top,
                endPoint: .bottom
            )

            // Content
            VStack(spacing: 10) {
                Spacer()

                Text(headline)
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                if let vibe = vibeScore {
                    Text("\(Int(vibe.rounded()))")
                        .font(.system(size: 72, weight: .thin, design: .rounded))
                        .foregroundStyle(.white)
                        .contentTransition(.numericText())
                }

                HStack(spacing: 16) {
                    if let r = recoveryScore {
                        Label("\(Int(r.rounded()))", systemImage: "bolt.fill")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    if let s = sleepScore {
                        Label("\(Int(s.rounded()))", systemImage: "moon.fill")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }

                Spacer().frame(height: 20)
            }
        }
        .frame(height: 280)
        .background(Color(hex: 0x1a1a2e))
    }

    private var auraColor: Color {
        guard let score = vibeScore else { return .gray }
        switch score {
        case 75...:  return Color(hex: 0x4ecca3)
        case 50...:  return Color(hex: 0x45b7d1)
        case 30...:  return Color(hex: 0xd4a447)
        default:     return Color(hex: 0xd47847)
        }
    }
}
