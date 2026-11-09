@testable import SwiftVLC
import Testing

/// `recast` carries the audio/subtitle selection into the new session.
/// Track ids are session-scoped, so carry-over prefers exact id and then only
/// unique language/name metadata — `Player.matchingTrack(for:in:)` owns that
/// ambiguity-safe policy.
extension Integration {
  @Suite(.tags(.mainActor))
  @MainActor struct PlayerRecastTrackMatchTests {
    private func track(
      id: String,
      type: TrackType = .subtitle,
      name: String = "Track",
      language: String? = nil,
      codec: Int = 0,
      isIDStable: Bool = true
    ) -> Track {
      Track(
        id: id,
        isIDStable: isIDStable,
        type: type,
        name: name,
        codec: codec,
        language: language,
        trackDescription: nil,
        isSelected: false,
        bitrate: 0,
        channels: nil,
        sampleRate: nil,
        width: nil,
        height: nil,
        frameRate: nil,
        frameRateRatio: nil,
        encoding: nil
      )
    }

    @Test
    func `an unstable id is not trusted to name the same track`() {
      let prior = track(id: "spu/auto/4", name: "English", language: "en", isIDStable: false)
      let candidates = [
        track(id: "spu/auto/4", name: "French", language: "fr", isIDStable: false),
        track(id: "spu/auto/9", name: "English", language: "en", isIDStable: false)
      ]
      #expect(Player.matchingTrack(for: prior, in: candidates)?.id == "spu/auto/9")
    }

    @Test
    func `a different codec or type is never a match`() {
      let aac = 0x6134_706D // 'mp4a'
      let ac3 = 0x2033_6361 // 'ac3 '
      let prior = track(id: "audio/auto/0", type: .audio, name: "English", language: "en", codec: aac)
      let candidates = [
        track(id: "audio/auto/5", type: .audio, name: "English", language: "en", codec: ac3),
        track(id: "spu/auto/6", type: .subtitle, name: "English", language: "en", codec: aac)
      ]
      #expect(Player.matchingTrack(for: prior, in: candidates) == nil)
    }

    @Test
    func `an unknown codec does not prevent a match`() {
      let prior = track(id: "audio/auto/0", type: .audio, name: "English", language: "en", codec: 0)
      let candidates = [
        track(id: "audio/auto/5", type: .audio, name: "English", language: "en", codec: 0x6134_706D)
      ]
      #expect(Player.matchingTrack(for: prior, in: candidates)?.id == "audio/auto/5")
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

    @Test
    func `duplicate exact language and name metadata is ambiguous`() {
      let prior = track(id: "spu/old", name: "English", language: "en")
      let candidates = [
        track(id: "spu/new-1", name: "English", language: "EN"),
        track(id: "spu/new-2", name: "English", language: "en")
      ]

      #expect(Player.matchingTrack(for: prior, in: candidates) == nil)
    }

    @Test
    func `ambiguous language does not hide one unique exact metadata match`() {
      let prior = track(id: "spu/old", name: "Commentary", language: "en")
      let candidates = [
        track(id: "spu/new-1", name: "Main", language: "en"),
        track(id: "spu/new-2", name: "Commentary", language: "EN")
      ]

      #expect(Player.matchingTrack(for: prior, in: candidates)?.id == "spu/new-2")
    }
  }
}
