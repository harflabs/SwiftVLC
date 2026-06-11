import AVFoundation
import SwiftUI
import SwiftVLC

@main
struct ShowcaseApp: App {
  init() {
    VLCInstance.prewarmShared()
    try? AVAudioSession.sharedInstance().setCategory(.playback)
    try? AVAudioSession.sharedInstance().setActive(true)
    UITestSupport.startLogMirrorIfRequested()
    CastTrustResponder.shared.start()
  }

  var body: some Scene {
    WindowGroup {
      RootView()
        .tint(.orange)
    }
  }
}
