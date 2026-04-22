import SwiftUI

#if canImport(UIKit)
import UIKit

typealias PlatformImage = UIImage

extension Image {
  init(platformImage: PlatformImage) {
    self.init(uiImage: platformImage)
  }
}
#else
import AppKit

typealias PlatformImage = NSImage

extension Image {
  init(platformImage: PlatformImage) {
    self.init(nsImage: platformImage)
  }
}
#endif
