import SwiftUI

@main
struct TVOSShowcaseApp: App {
  @AppStorage(TestStreamURL.revisionDefaultsKey) private var testStreamRevision = ""

  init() {
    TestStreamURL.startSession()
  }

  var body: some Scene {
    WindowGroup {
      TVShowcaseRootView()
        .id(testStreamRevision)
    }
  }
}
