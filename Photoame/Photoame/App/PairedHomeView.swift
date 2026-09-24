import SwiftUI

/// The home experience when paired: live camera, a pull-up inbox, and a viewer
/// presented full-screen either from an inbox tap or a tapped push notification.
struct PairedHomeView: View {
    let pairId: String
    @Environment(AppEnvironment.self) private var env

    @State private var camera: CameraViewModel?
    @State private var session: PairSessionViewModel?
    @State private var showInbox = false
    @State private var showSettings = false
    @State private var showGallery = false
    @State private var openedSnapId: String?

    var body: some View {
        Group {
            if let camera, let session {
                content(camera: camera, session: session)
            } else {
                Color.black.ignoresSafeArea()
                    .overlay(ProgressView().controlSize(.large))
            }
        }
        .task { setup() }
        .onDisappear { session?.stop() }
    }

    private func content(camera: CameraViewModel, session: PairSessionViewModel) -> some View {
        ZStack(alignment: .top) {
            CameraView(model: camera)
                .ignoresSafeArea()

            topBar(session: session)

            VStack {
                Spacer()
                inboxHandle(session: session)
            }
        }
        .sheet(isPresented: $showInbox) {
            InboxView(session: session) { snapId in
                showInbox = false
                openedSnapId = snapId
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .sheet(isPresented: $showGallery) {
            GalleryView(session: session)
        }
        .fullScreenCover(item: Binding(
            get: { openedSnapId.map(IdentifiedString.init) },
            set: { openedSnapId = $0?.value })
        ) { identified in
            ViewerView(pairId: pairId, snapId: identified.value, session: session)
        }
        // Deep-link from a tapped "New snap" push opens the viewer directly.
        .onChange(of: env.push.pendingDeepLink) { _, link in
            if let link, link.pairId == pairId {
                openedSnapId = link.snapId
                env.push.pendingDeepLink = nil
            }
        }
    }

    private func topBar(session: PairSessionViewModel) -> some View {
        HStack {
            Button { showSettings = true } label: {
                Image(systemName: "gearshape.fill")
                    .font(.title3)
                    .padding(10)
                    .background(.black.opacity(0.4), in: Circle())
            }
            .accessibilityLabel("Settings")

            Spacer()

            Text(session.partnerName)
                .font(.headline)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(.black.opacity(0.4), in: Capsule())

            Spacer()

            Button { showGallery = true } label: {
                Image(systemName: "heart.fill")
                    .font(.title3)
                    .padding(10)
                    .background(.black.opacity(0.4), in: Circle())
            }
            .accessibilityLabel("Us gallery")
        }
        .foregroundStyle(.white)
        .padding(.horizontal)
    }

    private func inboxHandle(session: PairSessionViewModel) -> some View {
        Button { showInbox = true } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.up")
                let count = session.unopenedReceived.count
                Text(count > 0 ? "\(count) new snap\(count == 1 ? "" : "s")" : "Inbox")
                    .font(.subheadline.bold())
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 20).padding(.vertical, 12)
            .background(.black.opacity(0.5), in: Capsule())
        }
        .padding(.bottom, 8)
        .accessibilityLabel("Open inbox")
        .accessibilityValue("\(session.unopenedReceived.count) new snaps")
        .gesture(
            DragGesture(minimumDistance: 20).onEnded { value in
                if value.translation.height < -30 { showInbox = true }
            }
        )
    }

    private func setup() {
        guard let uid = env.auth.uid else { return }
        if camera == nil {
            camera = CameraViewModel(pairId: pairId, senderUid: uid, repository: env.repository)
        }
        if session == nil {
            let s = PairSessionViewModel(pairId: pairId, uid: uid, repository: env.repository)
            s.start()
            session = s
        }
    }
}

/// Wraps a snapId so it can drive an item-based fullScreenCover.
private struct IdentifiedString: Identifiable {
    let value: String
    var id: String { value }
}
