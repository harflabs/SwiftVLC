/// A title in structured media (DVD, Blu-ray, etc.).
public struct Title: Sendable, Identifiable, Hashable {
  /// Title index.
  public let index: Int

  /// Stable identifier.
  public var id: Int {
    index
  }

  /// Title duration.
  public let duration: Duration

  /// Human-readable title name, if the container provides one.
  public let name: String?

  /// `true` when the title contains menu content (DVD menus, BD-J menus).
  public let isMenu: Bool

  /// `true` when the title responds to user input beyond playback
  /// controls (BD-J interactive titles). Seeking may be disabled
  /// inside interactive titles.
  public let isInteractive: Bool
}

/// A chapter within a title.
public struct Chapter: Sendable, Identifiable, Hashable {
  /// Chapter index.
  public let index: Int

  /// Stable identifier.
  public var id: Int {
    index
  }

  /// Time offset from the start of the title.
  public let timeOffset: Duration

  /// Chapter duration.
  public let duration: Duration

  /// Human-readable chapter name.
  public let name: String?
}
