import SwiftUI
import SwiftVLC
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Demonstrates ``Player/takeSnapshot(to:width:height:)`` and the A-B loop
/// APIs (``Player/setABLoop(a:b:)`` / ``Player/resetABLoop()``).
///
/// Two independent tools in one page:
/// - **Snapshot** captures the current frame to disk, then loads it back into
///   a `SwiftUI.Image` for preview.
/// - **A-B Loop** records the current playback time as point A, then as
///   point B, and the player plays that segment on repeat until cleared.
struct SnapshotAndLoopDemo: View {
  @State private var player: Player?
  @State private var error: Error?
  @State private var lastSnapshot: PlatformImage?
  @State private var snapshotError: String?
  @State private var aTime: Duration?
  @State private var bTime: Duration?
  @State private var loopError: String?

  var body: some View {
    content
      .navigationTitle("Snapshot & A-B Loop")
    #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
    #endif
      .task { await setUp() }
      .onDisappear { player?.stop() }
  }

  @ViewBuilder
  private var content: some View {
    if error != nil {
      DemoErrorView(
        title: "Playback Failed",
        message: "Could not set up the player.",
        retry: { Task { await setUp() } }
      )
    } else if let player {
      loaded(player)
    } else {
      ProgressView("Loading player...")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  private func loaded(_ player: Player) -> some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        videoSection(player)
        controlsSection(player)
        snapshotSection(player)
        loopSection(player)
      }
      .padding()
      .frame(maxWidth: 720)
      .frame(maxWidth: .infinity)
    }
  }

  // MARK: - Video

  private func videoSection(_ player: Player) -> some View {
    VStack(spacing: 8) {
      VideoView(player)
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipShape(.rect(cornerRadius: 12))
        .overlay(alignment: .topTrailing) { loopStatePill }
      PlayerStatusBar(player: player)
    }
  }

  @ViewBuilder
  private var loopStatePill: some View {
    if aTime != nil || bTime != nil {
      HStack(spacing: 4) {
        Image(systemName: "repeat")
        Text(loopPillText)
      }
      .font(.caption2)
      .monospacedDigit()
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .background(.ultraThinMaterial, in: .capsule)
      .padding(8)
    }
  }

  private var loopPillText: String {
    switch (aTime, bTime) {
    case (let a?, let b?): "\(a.formatted) → \(b.formatted)"
    case (let a?, nil): "A = \(a.formatted)"
    case (nil, let b?): "B = \(b.formatted)"
    default: ""
    }
  }

  // MARK: - Transport

  private func controlsSection(_ player: Player) -> some View {
    VStack(spacing: 8) {
      #if !os(tvOS)
      SeekBar(player: player)
      #endif
      TransportControls(player: player)
        .frame(maxWidth: .infinity)
    }
  }

  // MARK: - Snapshot

  private func snapshotSection(_ player: Player) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      sectionHeader("Snapshot", systemImage: "camera.viewfinder")

      Button {
        captureSnapshot(player)
      } label: {
        Label("Capture current frame", systemImage: "camera")
          .frame(maxWidth: .infinity)
      }
      .buttonStyle(.borderedProminent)
      .disabled(!canSnapshot(player))
      .accessibilityHint("Saves the current video frame to disk and previews it below")

      if let error = snapshotError {
        Text(error)
          .font(.caption)
          .foregroundStyle(.red)
      }

      if let image = lastSnapshot {
        #if canImport(UIKit)
        Image(uiImage: image)
          .resizable()
          .aspectRatio(contentMode: .fit)
          .frame(maxHeight: 200)
          .clipShape(.rect(cornerRadius: 8))
          .accessibilityLabel("Last captured frame")
        #elseif canImport(AppKit)
        Image(nsImage: image)
          .resizable()
          .aspectRatio(contentMode: .fit)
          .frame(maxHeight: 200)
          .clipShape(.rect(cornerRadius: 8))
          .accessibilityLabel("Last captured frame")
        #endif
      }
    }
  }

  // MARK: - A-B Loop

  private func loopSection(_ player: Player) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      sectionHeader("A-B Loop", systemImage: "repeat")

      HStack(spacing: 12) {
        Button {
          setA(player)
        } label: {
          Label("Set A", systemImage: "a.circle")
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .disabled(!canSetLoopPoint(player))

        Button {
          setB(player)
        } label: {
          Label("Set B", systemImage: "b.circle")
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .disabled(!canSetLoopPoint(player) || aTime == nil)

        Button(role: .destructive) {
          resetLoop(player)
        } label: {
          Label("Clear", systemImage: "xmark.circle")
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .disabled(aTime == nil && bTime == nil)
      }

      loopStatusRow

      if let error = loopError {
        Text(error)
          .font(.caption)
          .foregroundStyle(.red)
      }
    }
  }

  private var loopStatusRow: some View {
    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
      GridRow {
        Text("A")
          .foregroundStyle(.secondary)
          .gridColumnAlignment(.trailing)
        Text(aTime?.formatted ?? "—")
          .monospacedDigit()
      }
      GridRow {
        Text("B")
          .foregroundStyle(.secondary)
        Text(bTime?.formatted ?? "—")
          .monospacedDigit()
      }
    }
    .font(.callout)
  }

  // MARK: - Helpers

  private func sectionHeader(_ text: String, systemImage: String) -> some View {
    Label(text, systemImage: systemImage)
      .font(.headline)
      .foregroundStyle(.secondary)
  }

  private func canSnapshot(_ player: Player) -> Bool {
    switch player.state {
    case .playing, .paused: true
    default: false
    }
  }

  private func canSetLoopPoint(_ player: Player) -> Bool {
    player.duration != nil && canSnapshot(player)
  }

  // MARK: - Actions

  private func setUp() async {
    // Stop and clear the previous attempt so a retry doesn't leave an
    // orphaned Player decoding in the background or keep stale A/B /
    // snapshot state from the prior run.
    player?.stop()
    player = nil
    aTime = nil
    bTime = nil
    lastSnapshot = nil
    snapshotError = nil
    loopError = nil
    error = nil

    do {
      let p = Player()
      player = p
      try p.play(url: TestMedia.bigBuckBunny)
    } catch {
      self.error = error
    }
  }

  private func captureSnapshot(_ player: Player) {
    snapshotError = nil
    let path = NSTemporaryDirectory() + "swiftvlc-snapshot-\(UUID().uuidString).png"
    do {
      try player.takeSnapshot(to: path, width: 640)
      if let image = PlatformImage(contentsOfFile: path) {
        lastSnapshot = image
      } else {
        snapshotError = "Snapshot saved but could not be loaded from \(path)."
      }
    } catch {
      snapshotError = "Snapshot failed: \(error.localizedDescription)"
    }
  }

  private func setA(_ player: Player) {
    loopError = nil
    aTime = player.currentTime
    bTime = nil
  }

  private func setB(_ player: Player) {
    loopError = nil
    guard let a = aTime else { return }
    let b = player.currentTime
    guard b > a else {
      loopError = "Point B must be after point A."
      return
    }
    bTime = b
    do {
      try player.setABLoop(a: a, b: b)
    } catch {
      loopError = "Could not arm the loop: \(error.localizedDescription)"
    }
  }

  private func resetLoop(_ player: Player) {
    loopError = nil
    aTime = nil
    bTime = nil
    try? player.resetABLoop()
  }
}

// MARK: - Cross-platform image type

#if canImport(UIKit)
private typealias PlatformImage = UIImage
#elseif canImport(AppKit)
private typealias PlatformImage = NSImage
#endif
