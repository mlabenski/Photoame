import SwiftUI

/// The in-app Kept gallery of snaps both people kept. Images are read from the
/// local sandbox store; any kept snap not yet downloaded is fetched once and
/// saved locally. Nothing here can be exported to Photos.
struct GalleryView: View {
    @Bindable var session: PairSessionViewModel
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    private let columns = [GridItem(.flexible(), spacing: 3),
                           GridItem(.flexible(), spacing: 3)]

    /// The kept video currently playing full-screen, if any.
    @State private var playing: IdentifiedURL?

    private struct IdentifiedURL: Identifiable { let id = UUID(); let url: URL }

    var body: some View {
        NavigationStack {
            Group {
                if env.kept.items.isEmpty {
                    empty
                } else {
                    grid
                }
            }
            .navigationTitle("Kept")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await syncKept() }
            .fullScreenCover(item: $playing) { item in
                ZStack(alignment: .topTrailing) {
                    Color.black.ignoresSafeArea()
                    LoopingPlayerView(url: item.url, fill: false)
                        .ignoresSafeArea()
                    Button { playing = nil } label: {
                        Image(systemName: "xmark")
                            .font(.headline)
                            .padding(12)
                            .background(.black.opacity(0.5), in: Circle())
                            .foregroundStyle(.white)
                    }
                    .padding()
                    .accessibilityLabel("Close video")
                }
            }
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 3) {
                ForEach(env.kept.items) { item in
                    ZStack(alignment: .bottomLeading) {
                        Image(uiImage: item.image)
                            .resizable()
                            .scaledToFill()
                            .frame(height: 180)
                            .clipped()
                        if item.isVideo {
                            Image(systemName: "play.circle.fill")
                                .font(.largeTitle)
                                .foregroundStyle(.white.opacity(0.9))
                                .shadow(radius: 4)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                        if !item.caption.isEmpty {
                            Text(item.caption)
                                .font(.caption2)
                                .foregroundStyle(.white)
                                .padding(4)
                                .background(.black.opacity(0.4))
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if item.isVideo, let url = item.videoURL {
                            playing = IdentifiedURL(url: url)
                        }
                    }
                    .accessibilityLabel(
                        item.caption.isEmpty
                            ? (item.isVideo ? "Kept video" : "Kept photo")
                            : item.caption)
                    .accessibilityAddTraits(item.isVideo ? [.isButton] : [])
                }
            }
            .padding(3)
        }
    }

    private var empty: some View {
        ContentUnavailableView(
            "Nothing kept yet",
            systemImage: "bookmark",
            description: Text("When you both tap Keep on a snap, it lands here."))
    }

    /// Download any kept snap we don't have locally yet.
    private func syncKept() async {
        for snap in session.keptSnaps {
            guard let id = snap.id, !env.kept.contains(snapId: id) else { continue }
            let maxBytes = snap.isVideo ? 80 * 1024 * 1024 : 5 * 1024 * 1024
            if let data = try? await env.repository.downloadData(
                path: snap.storagePath, maxBytes: maxBytes) {
                env.kept.save(snapId: id, data: data,
                              mediaType: snap.isVideo ? .video : .image,
                              caption: snap.caption,
                              keptAt: snap.createdAt ?? Date())
            }
        }
    }
}
