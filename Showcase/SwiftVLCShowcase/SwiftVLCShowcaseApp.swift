import SwiftUI

@main
struct SwiftVLCShowcaseApp: App {
  var body: some Scene {
    WindowGroup {
      ShowcaseHub()
        .preferredColorScheme(.dark)
    }
  }
}
