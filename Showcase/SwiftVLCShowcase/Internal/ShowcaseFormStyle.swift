import SwiftUI

extension View {
  /// Pins forms in this subtree to the grouped layout.
  ///
  /// iOS is grouped by default; macOS defaults to `.columns`, which lays
  /// sections out as a two-column table and does not clip `NSView`-backed
  /// rows to the scroll bounds — both wrong for the showcase's section-heavy
  /// case studies with an `NSViewRepresentable` `VideoView`. tvOS has no
  /// `FormStyle` API and keeps its stacked layout.
  @ViewBuilder
  func showcaseFormStyle() -> some View {
    #if os(tvOS)
    self
    #else
    formStyle(.grouped)
    #endif
  }
}
