import SwiftUI

/// Animated ambient gradient hero that encodes overall health state through color.
/// Color driven by a "vibe score" = recovery * 0.6 + sleep * 0.4.
struct AuraHeroView: View {
    let vibeScore: Double?      // 0-100 composite, nil if no data
    let headline: String
    let recoveryScore: Double?
    let sleepScore: Double?

    var body: some View {
        ZStack {
            // Animated gradient background
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { context in
                Canvas { ctx, size in
                    let t = context.date.timeIntervalSinceReferenceDate
                    let color = auraColor

                    // Three soft ellipses drifting on sine waves
                    let configs: [(phaseX: Double, phaseY: Double, freqX: Double, freqY: Double, opacity: Double, scale: Double)] = [
                        (0,     0.5, 0.25, 0.35, 0.5,  1.0),
                        (1.2,   2.0, 0.30, 0.20, 0.35, 0.8),
                        (2.5,   3.5, 0.20, 0.30, 0.25, 0.6),
                    ]

                    for c in configs {
                        let cx = size.width * 0.5 + sin(t * c.freqX + c.phaseX) * size.width * 0.15
                        let cy = size.height * 0.45 + sin(t * c.freqY + c.phaseY) * size.height * 0.1
                        let w = size.width * 0.7 * c.scale
                        let h = size.height * 0.6 * c.scale

                        let rect = CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h)
                        let ellipse = Ellipse().path(in: rect)

                        ctx.fill(ellipse, with: .color(color.opacity(c.opacity)))
                    }
                }
                .blur(radius: 60)
            }
            .clipped()

            // Vignette overlay to blend edges into background
            LinearGradient(
                colors: [.clear, Color(hex: 0x1a1a2e).opacity(0.3), Color(hex: 0x1a1a2e)],
                startPoint: .top,
                endPoint: .bottom
            )

            // Content overlay
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

                // Sub-scores
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

                Spacer()
                    .frame(height: 20)
            }
        }
        .frame(height: 280)
        .background(Color(hex: 0x1a1a2e))
    }

    // MARK: - Color Mapping

    private var auraColor: Color {
        guard let score = vibeScore else { return .gray }
        switch score {
        case 75...:  return Color(hex: 0x4ecca3) // emerald green
        case 50...:  return Color(hex: 0x45b7d1) // teal/cyan
        case 30...:  return Color(hex: 0xd4a447) // amber/gold
        default:     return Color(hex: 0xd47847) // warm coral
        }
    }
}
