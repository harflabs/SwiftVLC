import SwiftUI

@main
struct VisionShowcaseApp: App {
  @AppStorage(TestStreamURL.revisionDefaultsKey) private var testStreamRevision = ""

  init() {
    TestStreamURL.startSession()
  }

  var body: some Scene {
    WindowGroup {
      SimplePlaybackView()
        .id(testStreamRevision)
        .tint(.orange)
    }
    .defaultSize(width: 960, height: 640)
  }
}
