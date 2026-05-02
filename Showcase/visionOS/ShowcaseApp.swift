import SwiftUI

@main
struct VisionShowcaseApp: App {
  var body: some Scene {
    WindowGroup {
      SimplePlaybackView()
        .tint(.orange)
    }
    .defaultSize(width: 960, height: 640)
  }
}
