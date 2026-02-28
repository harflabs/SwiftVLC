import Foundation

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

  /// Human-readable title name.
  public let name: String?

  /// Whether this title is a menu.
  public let isMenu: Bool

  /// Whether this title is interactive.
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
