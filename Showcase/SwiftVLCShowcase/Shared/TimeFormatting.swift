import Foundation
import SwiftVLC

// Duration.formatted and Duration.milliseconds are already provided by SwiftVLC.
// Only add what the library doesn't provide.

extension Duration {
  /// Formats as "-3:18" showing remaining time.
  var remainingFormatted: String {
    "-\(formatted)"
  }
}

extension Duration? {
  /// Formats duration or returns "--:--" when nil.
  var formatted: String {
    self?.formatted ?? "--:--"
  }
}
