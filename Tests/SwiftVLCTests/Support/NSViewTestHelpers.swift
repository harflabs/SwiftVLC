#if canImport(AppKit)
import AppKit

extension NSView {
  func firstDescendant<T: NSView>(ofType type: T.Type) -> T? {
    if let match = self as? T {
      return match
    }
    for subview in subviews {
      if let match = subview.firstDescendant(ofType: type) {
        return match
      }
    }
    return nil
  }
}
#endif
