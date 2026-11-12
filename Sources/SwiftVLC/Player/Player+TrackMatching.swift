extension Player {
  /// Finds the track in `candidates` that best corresponds to `track` from a
  /// previous session, or from before its unstable id was recreated.
  /// Ambiguous metadata never chooses whichever rendition happened to arrive
  /// first.
  static func matchingTrack(for track: Track, in candidates: [Track]) -> Track? {
    // An unstable id is a per-session counter: the same string can name a
    // different rendition in another session.
    if track.isIDStable, let exact = candidates.first(where: { $0.id == track.id }) {
      return exact
    }
    let candidates = candidates.filter {
      $0.type == track.type
        && ($0.codec == track.codec || $0.codec == 0 || track.codec == 0)
    }
    let language = track.language?.lowercased()
    if let language, !language.isEmpty {
      let exactMetadataMatches = candidates.filter {
        $0.language?.lowercased() == language && $0.name == track.name
      }
      if exactMetadataMatches.count == 1 {
        return exactMetadataMatches[0]
      }
    }
    if let language, !language.isEmpty {
      let languageMatches = candidates.filter {
        $0.language?.lowercased() == language
      }
      if languageMatches.count == 1 {
        return languageMatches[0]
      }
    }
    let nameMatches = candidates.filter { $0.name == track.name }
    return nameMatches.count == 1 ? nameMatches[0] : nil
  }
}
