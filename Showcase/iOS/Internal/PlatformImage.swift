import SwiftUI
import UIKit

typealias PlatformImage = UIImage

extension Image {
  init(platformImage: PlatformImage) {
    self.init(uiImage: platformImage)
  }
}
