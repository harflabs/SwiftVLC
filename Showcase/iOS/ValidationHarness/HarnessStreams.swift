import Foundation

/// Operator-supplied stream configuration for the device-validation
/// harness. The repository documents the shape but never ships URLs.
///
/// To configure, either:
/// 1. Copy `streams.local.example.json` (committed next to this file,
///    placeholder hosts only) to `streams.local.json` in the same
///    folder before building. The copy is gitignored and bundled into
///    the app automatically.
/// 2. Drop a `streams.local.json` into the app's Documents folder via
///    the Files app on a device that already has the harness
///    installed — no rebuild needed.
///
/// The bundled file wins when both exist. Missing or malformed keys
/// simply disable the dependent screens, so a partial config still
/// runs.
struct HarnessStreams {
  enum Key: String, CodingKey, CaseIterable {
    case liveTS
    case hlsLive
    case vod
    case catchup
    case subtitled
    case adaptive
    case audioOnly
  }

  enum Source {
    case bundle
    case documents

    var label: String {
      switch self {
      case .bundle: "bundled streams.local.json"
      case .documents: "Documents/streams.local.json"
      }
    }
  }

  let liveTS: URL?
  let hlsLive: URL?
  let vod: URL?
  let catchup: URL?
  let subtitled: URL?
  let adaptive: URL?
  let audioOnly: URL?

  func url(for key: Key) -> URL? {
    switch key {
    case .liveTS: liveTS
    case .hlsLive: hlsLive
    case .vod: vod
    case .catchup: catchup
    case .subtitled: subtitled
    case .adaptive: adaptive
    case .audioOnly: audioOnly
    }
  }

  var configured: [(key: Key, url: URL)] {
    Key.allCases.compactMap { key in
      url(for: key).map { (key, $0) }
    }
  }

  var missingKeys: [Key] {
    Key.allCases.filter { url(for: $0) == nil }
  }
}

extension HarnessStreams: Decodable {
  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: Key.self)
    liveTS = Self.url(in: container, for: .liveTS)
    hlsLive = Self.url(in: container, for: .hlsLive)
    vod = Self.url(in: container, for: .vod)
    catchup = Self.url(in: container, for: .catchup)
    subtitled = Self.url(in: container, for: .subtitled)
    adaptive = Self.url(in: container, for: .adaptive)
    audioOnly = Self.url(in: container, for: .audioOnly)
  }

  private static func url(in container: KeyedDecodingContainer<Key>, for key: Key) -> URL? {
    guard let raw = try? container.decodeIfPresent(String.self, forKey: key) else { return nil }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard
      !trimmed.isEmpty,
      !trimmed.contains("<"),
      let url = URL(string: trimmed),
      url.scheme != nil
    else { return nil }
    return url
  }
}

extension HarnessStreams {
  static func load() -> (streams: HarnessStreams, source: Source)? {
    if
      let bundled = Bundle.main.url(forResource: "streams.local", withExtension: "json"),
      let streams = decode(contentsOf: bundled) {
      return (streams, .bundle)
    }

    if
      let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
      let streams = decode(contentsOf: documents.appendingPathComponent("streams.local.json")) {
      return (streams, .documents)
    }

    return nil
  }

  private static func decode(contentsOf url: URL) -> HarnessStreams? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return try? JSONDecoder().decode(HarnessStreams.self, from: data)
  }
}
