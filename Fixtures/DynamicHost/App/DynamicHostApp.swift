import FeatureA
import FeatureB
import SwiftUI

@main
struct DynamicHostApp: App {
  private let single: Bool

  init() {
    let single = FeatureA.instanceID() == FeatureB.instanceID()
    print("DYNAMICHOST-SINGLE-INSTANCE: \(single)")
    self.single = single
  }

  var body: some Scene {
    WindowGroup {
      Text(single ? "Single shared VLCInstance" : "Multiple VLCInstance copies")
    }
  }
}
