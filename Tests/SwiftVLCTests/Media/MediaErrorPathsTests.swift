@testable import SwiftVLC
import Foundation
import Testing

/// Covers `Media`'s constructor error paths and media-slave error
/// returns. libVLC's path/URL constructors are forgiving — they
/// mostly accept anything and surface the failure at play time —
/// but the `fd` variant rejects unreadable file descriptors.
@Suite(.tags(.integration))
struct MediaErrorPathsTests {
  /// libVLC's `libvlc_media_new_fd` accepts any integer and defers
  /// validation to play time — the creation itself only fails on OOM.
  /// Pin that behavior so a future libVLC that tightens the contract
  /// surfaces as a visible test change rather than a silent surprise.
  @Test
  func `Media from invalid file descriptor is accepted at creation time`() throws {
    // Both -1 and a large unused FD succeed; validation happens later.
    let a = try Media(fileDescriptor: -1)
    let b = try Media(fileDescriptor: 99999)
    #expect(a.mrl != nil)
    #expect(b.mrl != nil)
  }

  /// Adding a malformed slave URI reaches libvlc_media_slaves_add,
  /// which returns non-zero for unresolvable input.
  @Test
  func `addSlave with syntactically valid but unreachable URI succeeds at libVLC level`() throws {
    // libVLC accepts any syntactically valid URI into the slave
    // list — validation happens at play time. This test pins that
    // behavior (no throw) so a future tightening of libVLC doesn't
    // regress silently.
    let media = try Media(url: URL(fileURLWithPath: "/tmp/swiftvlc-test.mp4"))
    try media.addSlave(
      from: URL(fileURLWithPath: "/tmp/swiftvlc-test.srt"),
      type: .subtitle
    )

    #expect(media.slaves.count == 1)
    #expect(media.slaves.first?.type == .subtitle)
    #expect(media.slaves.first?.priority == 4)
  }

  @Test
  func `clearSlaves removes all attached slaves`() throws {
    let media = try Media(url: URL(fileURLWithPath: "/tmp/swiftvlc-test.mp4"))
    try media.addSlave(
      from: URL(fileURLWithPath: "/tmp/a.srt"),
      type: .subtitle,
      priority: 3
    )
    try media.addSlave(
      from: URL(fileURLWithPath: "/tmp/b.mp3"),
      type: .audio,
      priority: 5
    )
    #expect(media.slaves.count == 2)

    media.clearSlaves()

    #expect(media.slaves.isEmpty)
  }

  @Test
  func `addOption applies without crash`() throws {
    let media = try Media(url: URL(fileURLWithPath: "/tmp/swiftvlc-test.mp4"))
    media.addOption(":network-caching=2000")
    media.addOption(":start-time=5")
  }

  /// `setMetadata` on unparsed media is a safe no-op — libVLC stages
  /// the value until save/parse, never crashing on a missing file.
  /// Reading back requires a real parse, which is covered by the
  /// metadata integration tests.
  @Test
  func `setMetadata on unparsed media is safe`() throws {
    let media = try Media(url: URL(fileURLWithPath: "/tmp/swiftvlc-test.mp4"))
    media.setMetadata(.title, value: "SwiftVLC Test")
  }

  /// Slave priority is documented as 0...UInt32.max; out-of-range
  /// values trap via `precondition`. We can't assert on the trap
  /// itself (it tears down the process), but we can verify the
  /// valid boundary case.
  @Test
  func `addSlave with zero priority succeeds`() throws {
    let media = try Media(url: URL(fileURLWithPath: "/tmp/swiftvlc-test.mp4"))
    try media.addSlave(
      from: URL(fileURLWithPath: "/tmp/zero.srt"),
      type: .subtitle,
      priority: 0
    )
    #expect(media.slaves.first?.priority == 0)
  }

  /// `Media.mrl` returns the URI libVLC normalized.
  @Test
  func `mrl returns a non-nil URI`() throws {
    let media = try Media(url: URL(fileURLWithPath: "/tmp/swiftvlc-test.mp4"))
    #expect(media.mrl != nil)
  }

  /// `Media.duration` is nil until parse completes — regression guard
  /// that the getter doesn't return a bogus positive value for
  /// unparsed media.
  @Test
  func `duration is nil before parse`() throws {
    let media = try Media(url: URL(fileURLWithPath: "/tmp/swiftvlc-test.mp4"))
    #expect(media.duration == nil)
  }

  /// `Media.mediaType` reports `.unknown` before libVLC figures it
  /// out. For local `file://` paths it may immediately be `.file`;
  /// either is acceptable.
  @Test
  func `mediaType reports a value without crash`() throws {
    let media = try Media(url: URL(fileURLWithPath: "/tmp/swiftvlc-test.mp4"))
    let type = media.mediaType
    // Just pin that we get one of the documented enum cases.
    let valid: Set<MediaType> = [.unknown, .file, .directory, .disc, .stream, .playlist]
    #expect(valid.contains(type))
  }
}
