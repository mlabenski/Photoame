import SwiftUI
import UIKit
import AVKit
import AVFoundation

/// A chrome-free video player that autoplays and loops seamlessly — used to
/// review a just-recorded clip and to play a received video snap. No scrubber or
/// controls: snaps are short and meant to just play.
struct LoopingPlayerView: UIViewRepresentable {
    let url: URL
    /// Fill the bounds (cropping) like the live camera preview, vs. fit the whole
    /// frame letterboxed.
    var fill: Bool = true

    func makeUIView(context: Context) -> LoopingPlayerUIView {
        let view = LoopingPlayerUIView()
        view.configure(url: url, fill: fill)
        return view
    }

    func updateUIView(_ uiView: LoopingPlayerUIView, context: Context) {}

    static func dismantleUIView(_ uiView: LoopingPlayerUIView, coordinator: ()) {
        uiView.teardown()
    }
}

/// Backing `UIView` whose layer is an `AVPlayerLayer`. Loops with
/// `AVPlayerLooper` and routes audio to the `.playback` category so a snap's
/// sound is audible even with the ring/silent switch off.
final class LoopingPlayerUIView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    private var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    private var queuePlayer: AVQueuePlayer?
    private var looper: AVPlayerLooper?

    func configure(url: URL, fill: Bool) {
        try? AVAudioSession.sharedInstance().setCategory(.playback, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)

        let item = AVPlayerItem(url: url)
        let player = AVQueuePlayer()
        looper = AVPlayerLooper(player: player, templateItem: item)
        playerLayer.player = player
        playerLayer.videoGravity = fill ? .resizeAspectFill : .resizeAspect
        queuePlayer = player
        player.play()
    }

    func teardown() {
        queuePlayer?.pause()
        queuePlayer = nil
        looper = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }
}
