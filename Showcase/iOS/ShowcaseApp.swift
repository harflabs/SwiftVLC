import AVFoundation
import SwiftUI

@main
struct ShowcaseApp: App {
  init() {
    try? AVAudioSession.sharedInstance().setCategory(.playback)
    try? AVAudioSession.sharedInstance().setActive(true)
    UITestSupport.startLogMirrorIfRequested()
  }

  var body: some Scene {
    WindowGroup {
      RootView()
        .tint(.orange)
    }
  }
}
