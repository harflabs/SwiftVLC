import SwiftUI

@main
struct TVOSShowcaseApp: App {
  @AppStorage(TestStreamURL.defaultsKey) private var testStreamURL = ""

  var body: some Scene {
    WindowGroup {
      TVShowcaseRootView()
        .id(testStreamURL)
    }
  }
}
