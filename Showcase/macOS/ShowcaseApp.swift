import SwiftUI

@main
struct MacOSShowcaseApp: App {
  var body: some Scene {
    WindowGroup {
      MacShowcaseRootView()
        .frame(minWidth: 980, minHeight: 660)
    }
    .windowResizability(.contentMinSize)
  }
}
