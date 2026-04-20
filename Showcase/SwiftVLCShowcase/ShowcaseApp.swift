import SwiftUI
#if os(iOS) || os(tvOS)
import AVFoundation
#endif

@main
struct ShowcaseApp: App {
  init() {
    #if os(iOS) || os(tvOS)
    try? AVAudioSession.sharedInstance().setCategory(.playback)
    try? AVAudioSession.sharedInstance().setActive(true)
    #endif
  }

  var body: some Scene {
    WindowGroup {
      RootView()
    }
  }
}
