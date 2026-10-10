import SwiftUI

/// A circular profile picture. Loads `url` asynchronously and, while loading or
/// when no photo is set, falls back to the user's initials on a color derived
/// from their name — so every user has a stable, recognizable avatar.
///
/// Used anywhere a user is surfaced: the paired home top bar, Settings, and the
/// in-app snap banner (the foreground twin of the push notification).
struct AvatarView: View {
    let url: String?
    let name: String
    var size: CGFloat = 40

    private var initials: String {
        let parts = name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ")
        let letters = parts.prefix(2).compactMap { $0.first }
        let joined = String(letters).uppercased()
        return joined.isEmpty ? "?" : joined
    }

    /// Deterministic hue so the same name always gets the same fallback color.
    /// `String.hashValue` is seeded per-process, so we fold the scalars by hand
    /// to stay stable across launches.
    private var fallbackColor: Color {
        let hash = name.unicodeScalars.reduce(UInt32(5381)) { ($0 &* 33) &+ $1.value }
        return Color(hue: Double(hash % 360) / 360.0, saturation: 0.45, brightness: 0.75)
    }

    var body: some View {
        Group {
            if let url, let parsed = URL(string: url), !url.isEmpty {
                AsyncImage(url: parsed) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    case .failure:
                        placeholder
                    default:
                        placeholder.overlay(ProgressView().controlSize(.small).tint(.white))
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 1))
        .accessibilityHidden(true)
    }

    private var placeholder: some View {
        fallbackColor.overlay(
            Text(initials)
                .font(.system(size: size * 0.4, weight: .semibold))
                .foregroundStyle(.white)
        )
    }
}
