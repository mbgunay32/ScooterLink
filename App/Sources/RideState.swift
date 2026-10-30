import AVFoundation
import Foundation

/// What the dash shows: only whether audio is playing. No GPS, no timers of our own;
/// it is refreshed on Bluetooth events, which is all iOS wakes us for in the background.
final class RideState: ObservableObject {
    @Published private(set) var isAudioPlaying = false

    /// Public API: true while another app (Spotify, YouTube, Music…) is playing audio.
    func refresh() {
        let playing = AVAudioSession.sharedInstance().isOtherAudioPlaying
        if playing != isAudioPlaying { isAudioPlaying = playing }
    }

    func rideScreen(colors: ScreenColors) -> LiveScreen {
        LiveScreen(header: "Müzik",
                   line1: isAudioPlaying ? "Çalıyor" : "Duraklatıldı",
                   line2: nil,
                   leftAction: isAudioPlaying ? DashIcon.pause : DashIcon.play,
                   rightAction: DashIcon.next,
                   colors: colors)
    }
}
