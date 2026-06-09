import SwiftUI

extension Color {
    init(hex: UInt, opacity: Double = 1.0) {
        self.init(.sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity)
    }

    /// Initialize from a hex string (e.g. "4CAF50" or "#4CAF50").
    init(hex string: String, opacity: Double = 1.0) {
        let clean = string.trimmingCharacters(in: .init(charactersIn: "#"))
        let value = UInt(clean, radix: 16) ?? 0
        self.init(hex: value, opacity: opacity)
    }

    // MARK: - App Palette (L2)
    /// Deep navy — main screen background
    static let appBackground  = Color(hex: 0x1a1a2e)
    /// Mid navy — card / row backgrounds
    static let appSurface     = Color(hex: 0x16213e)
    /// Teal accent — primary action / charts
    static let appTeal        = Color(hex: 0x4ecca3)
    /// Red accent — recording / destructive
    static let appRed         = Color(hex: 0xe94560)
    /// Blue accent — secondary charts
    static let appBlue        = Color(hex: 0x5dadec)
}

// MARK: - Reusable empty state view (L5)
struct EmptyStateView: View {
    let icon: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 48))
                .foregroundColor(.gray)
            Text(title)
                .font(.headline)
                .foregroundColor(.gray)
            Text(message)
                .font(.caption)
                .foregroundColor(.gray.opacity(0.7))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Shared Date Formatters

enum DateFormatters {
    static let mediumDateTime: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    static let timeOnly: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .medium
        return f
    }()
}
