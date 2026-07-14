import SwiftUI
@_spi(PrivateMacOSPiP) import SwiftVLC

@main
struct MacOSShowcaseApp: App {
  @AppStorage(TestStreamURL.revisionDefaultsKey) private var testStreamRevision = ""

  init() {
    TestStreamURL.startSession()
    // The macOS Showcase is a local demo app, not App Store sample code.
    // Opt into SwiftVLC's private macOS PiP backend so the PiP case can run.
    PiPController.allowsPrivateMacOSAPI = true
  }

  var body: some Scene {
    WindowGroup {
      MacShowcaseRootView()
        .id(testStreamRevision)
        .frame(minWidth: 980, minHeight: 660)
    }
    .windowResizability(.contentMinSize)
  }
}
