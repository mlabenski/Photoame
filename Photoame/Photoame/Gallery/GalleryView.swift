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
                        if !item.caption.isEmpty {
                            Text(item.caption)
                                .font(.caption2)
                                .foregroundStyle(.white)
                                .padding(4)
                                .background(.black.opacity(0.4))
                        }
                    }
                    .accessibilityLabel(item.caption.isEmpty ? "Kept photo" : item.caption)
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
            if let data = try? await env.repository.downloadImage(path: snap.storagePath) {
                env.kept.save(snapId: id, imageData: data,
                              caption: snap.caption,
                              keptAt: snap.createdAt ?? Date())
            }
        }
    }
}
