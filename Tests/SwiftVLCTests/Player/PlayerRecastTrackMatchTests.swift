@testable import SwiftVLC
import Testing

/// `recast` carries the audio/subtitle selection into the new session.
/// Track ids are session-scoped, so the carry-over matches by id, then
/// language, then name — `Player.matchingTrack(for:in:)` is that fallback.
extension Integration {
  @Suite(.tags(.mainActor))
  @MainActor struct PlayerRecastTrackMatchTests {
    private func track(
      id: String,
      name: String = "Track",
      language: String? = nil
    ) -> Track {
      Track(
        id: id,
        type: .subtitle,
        name: name,
        codec: 0,
        language: language,
        trackDescription: nil,
        isSelected: false,
        bitrate: 0,
        channels: nil,
        sampleRate: nil,
        width: nil,
        height: nil,
        frameRate: nil,
        encoding: nil
      )
    }

    @Test
    func `an exact id match wins over language and name`() {
      let prior = track(id: "spu/auto/4", name: "English", language: "en")
      let candidates = [
        track(id: "spu/auto/4", name: "Different", language: "fr"),
        track(id: "spu/auto/9", name: "English", language: "en")
      ]
      #expect(Player.matchingTrack(for: prior, in: candidates)?.id == "spu/auto/4")
    }

    @Test
    func `a changed id falls back to the same language`() {
      let prior = track(id: "spu/auto/4", name: "English", language: "en")
      let candidates = [
        track(id: "spu/auto/9", name: "Anglais", language: "EN"),
        track(id: "spu/auto/10", name: "French", language: "fr")
      ]
      let match = Player.matchingTrack(for: prior, in: candidates)
      #expect(match?.id == "spu/auto/9", "case-insensitive language match expected")
    }

    @Test
    func `with no language it falls back to the same name`() {
      let prior = track(id: "spu/auto/4", name: "Commentary", language: nil)
      let candidates = [
        track(id: "spu/auto/9", name: "Forced", language: nil),
        track(id: "spu/auto/10", name: "Commentary", language: nil)
      ]
      #expect(Player.matchingTrack(for: prior, in: candidates)?.id == "spu/auto/10")
    }

    @Test
    func `no correspondence yields nil so the default selection stands`() {
      let prior = track(id: "spu/auto/4", name: "English", language: "en")
      let candidates = [
        track(id: "spu/auto/9", name: "French", language: "fr"),
        track(id: "spu/auto/10", name: "German", language: "de")
      ]
      #expect(Player.matchingTrack(for: prior, in: candidates) == nil)
    }

    @Test
    func `an empty prior language does not match an empty candidate language`() {
      let prior = track(id: "spu/auto/4", name: "One", language: "")
      let candidates = [track(id: "spu/auto/9", name: "Two", language: "")]
      #expect(
        Player.matchingTrack(for: prior, in: candidates) == nil,
        "empty language must not be treated as a match key"
      )
    }
  }
}
