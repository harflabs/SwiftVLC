import SwiftUI

/// Consistent error state for all Showcase demos. Includes an optional
/// retry action so the user can recover without leaving the screen
/// (network blips, first-load hiccups, etc.).
struct DemoErrorView: View {
  let title: String
  let message: String
  var retry: (() -> Void)?

  var body: some View {
    ContentUnavailableView {
      Label(title, systemImage: "exclamationmark.triangle")
    } description: {
      Text(message)
    } actions: {
      if let retry {
        Button {
          retry()
        } label: {
          Label("Try Again", systemImage: "arrow.clockwise")
        }
        .buttonStyle(.borderedProminent)
        .accessibilityHint("Retries loading the demo")
      }
    }
  }
}
