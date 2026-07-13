import SwiftUI

@main
struct VisionShowcaseApp: App {
  @AppStorage(TestStreamURL.defaultsKey) private var testStreamURL = ""

  var body: some Scene {
    WindowGroup {
      SimplePlaybackView()
        .id(testStreamURL)
        .tint(.orange)
    }
    .defaultSize(width: 960, height: 640)
  }
}
