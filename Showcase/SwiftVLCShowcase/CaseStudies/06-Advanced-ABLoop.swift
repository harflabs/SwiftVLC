import SwiftUI
import SwiftVLC

private let readMe = """
Mark point A, mark point B, and the player loops between them. `abLoopState` tells \
you whether A is set, the loop is active, or it's off.
"""

struct ABLoopCase: View {
  @State private var player = Player()
  @State private var aTime: Duration?
  @State private var bTime: Duration?

  var body: some View {
    Form {
      Section { AboutView(readMe: readMe) }

      Section {
        VideoView(player)
          .aspectRatio(16 / 9, contentMode: .fit)
          .listRowInsets(EdgeInsets())
          .accessibilityIdentifier(AccessibilityID.ABLoop.videoView)
      } footer: {
        PlayPauseFooter(player: player)
          .accessibilityIdentifier(AccessibilityID.ABLoop.playPauseButton)
      }

      Section("Loop") {
        infoRow("State", value: stateLabel, identifier: AccessibilityID.ABLoop.stateLabel)
        infoRow("A", value: aTime.map(format) ?? "—", identifier: AccessibilityID.ABLoop.aLabel)
        infoRow("B", value: bTime.map(format) ?? "—", identifier: AccessibilityID.ABLoop.bLabel)
        infoRow("Now", value: format(player.currentTime), identifier: AccessibilityID.ABLoop.currentTimeLabel)

        HStack {
          Button("Mark A") { aTime = player.currentTime }
            .accessibilityIdentifier(AccessibilityID.ABLoop.markAButton)
          Spacer()
          Button("Mark B") { markB() }
            .disabled(aTime == nil)
            .accessibilityIdentifier(AccessibilityID.ABLoop.markBButton)
          Spacer()
          Button("Reset") { reset() }
            .tint(.red)
            .accessibilityIdentifier(AccessibilityID.ABLoop.resetButton)
        }
        // SwiftUI Form rows with multiple buttons route taps through the
        // cell's tap area unless each button opts out with an explicit
        // style. `.borderless` makes each button its own hit target —
        // required so XCUITest can fire them individually.
        .buttonStyle(.borderless)
      }
    }
    .showcaseFormStyle()
    .navigationTitle("A-B loop")
    .task { try? player.play(url: TestMedia.bigBuckBunny) }
    .onDisappear { player.stop() }
  }

  /// `LabeledContent` aggregates label + value into one accessibility
  /// element, preventing XCUITest from querying the value independently.
  /// Plain HStack + Text keeps `XCUIElement.label` identical to the visible
  /// string.
  private func infoRow(_ title: String, value: String, identifier: String) -> some View {
    HStack {
      Text(title)
      Spacer()
      Text(value)
        .foregroundStyle(.secondary)
        .accessibilityIdentifier(identifier)
    }
  }

  private func markB() {
    guard let a = aTime else { return }
    let b = player.currentTime
    try? player.setABLoop(a: a, b: b)
    bTime = b
  }

  private func reset() {
    aTime = nil
    bTime = nil
    try? player.resetABLoop()
  }

  private var stateLabel: String {
    switch player.abLoopState {
    case .none: "off"
    case .pointASet: "A set"
    case .active: "active"
    }
  }

  private func format(_ duration: Duration) -> String {
    let seconds = Int(duration.components.seconds)
    return String(format: "%d:%02d", seconds / 60, seconds % 60)
  }
}
