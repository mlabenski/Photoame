import SwiftUI

/// A single list under the camera: unopened received snaps (tap to open) and
/// recent sent snaps with their delivery state. Supports Dynamic Type.
struct InboxView: View {
    @Bindable var session: PairSessionViewModel
    /// Called with a snapId when the user taps an unopened received snap.
    let onOpen: (String) -> Void

    var body: some View {
        NavigationStack {
            List {
                if !session.unopenedReceived.isEmpty {
                    Section("New from \(session.partnerName)") {
                        ForEach(session.unopenedReceived) { snap in
                            Button { if let id = snap.id { onOpen(id) } } label: {
                                receivedRow(snap)
                            }
                        }
                    }
                }

                Section("Sent") {
                    if session.recentSent.isEmpty {
                        Text("No sent snaps yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(session.recentSent) { snap in
                            sentRow(snap)
                        }
                    }
                }
            }
            .navigationTitle("Inbox")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func receivedRow(_ snap: Snap) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "envelope.badge.fill")
                .foregroundStyle(.yellow)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text("Tap to open")
                    .font(.headline)
                if let created = snap.createdAt {
                    Text(created, format: .relative(presentation: .named))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if snap.timerSeconds > 0 {
                Text("\(snap.timerSeconds)s")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("New snap. Tap to open.")
    }

    private func sentRow(_ snap: Snap) -> some View {
        let display = SentDisplayState.forSnap(snap)
        return HStack {
            Image(systemName: icon(for: display))
                .foregroundStyle(color(for: display))
            VStack(alignment: .leading, spacing: 2) {
                Text(display.rawValue)
                    .font(.subheadline.weight(.medium))
                if let created = snap.createdAt {
                    Text(created, format: .relative(presentation: .named))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if snap.state == .kept {
                Image(systemName: "heart.fill").foregroundStyle(.pink)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Sent snap. \(display.rawValue).")
    }

    private func icon(for state: SentDisplayState) -> String {
        switch state {
        case .sending: return "arrow.up.circle"
        case .delivered: return "checkmark.circle"
        case .opened: return "eye.fill"
        case .replayed: return "arrow.clockwise.circle.fill"
        case .kept: return "heart.fill"
        case .screenshotted: return "camera.viewfinder"
        }
    }

    private func color(for state: SentDisplayState) -> Color {
        switch state {
        case .screenshotted: return .red
        case .kept: return .pink
        case .opened, .replayed: return .green
        default: return .secondary
        }
    }
}
