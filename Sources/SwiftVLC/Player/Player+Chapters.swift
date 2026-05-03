import CLibVLC

/// Chapter, title, and DVD/Blu-ray menu navigation.
extension Player {
  // MARK: - Navigation (DVD menus)

  /// Navigates through DVD/Blu-ray menus.
  public func navigate(_ action: NavigationAction) {
    libvlc_media_player_navigate(pointer, action.cValue)
  }

  // MARK: - Chapters

  /// Number of chapters in the current title.
  public var chapterCount: Int {
    Int(libvlc_media_player_get_chapter_count(pointer))
  }

  /// Current chapter index, zero-based.
  ///
  /// Returns `-1` when no media is loaded (libVLC's documented contract).
  /// Always check ``chapterCount`` before trusting this value: a non-DVD
  /// stream legitimately reports `0` chapters and `currentChapter == -1`.
  public var currentChapter: Int {
    get {
      access(keyPath: \.currentChapter)
      return Int(libvlc_media_player_get_chapter(pointer))
    }
    set {
      withMutation(keyPath: \.currentChapter) {
        libvlc_media_player_set_chapter(pointer, Int32(newValue))
      }
    }
  }

  /// Navigates to the next chapter.
  public func nextChapter() {
    libvlc_media_player_next_chapter(pointer)
  }

  /// Navigates to the previous chapter.
  public func previousChapter() {
    libvlc_media_player_previous_chapter(pointer)
  }

  // MARK: - Titles

  /// Number of titles.
  public var titleCount: Int {
    Int(libvlc_media_player_get_title_count(pointer))
  }

  /// Current title index, zero-based.
  ///
  /// Returns `-1` when no media is loaded (libVLC's documented contract).
  /// Always check ``titleCount`` before trusting this value: a single-
  /// title stream legitimately reports `0` titles and
  /// `currentTitle == -1`.
  public var currentTitle: Int {
    get {
      access(keyPath: \.currentTitle)
      return Int(libvlc_media_player_get_title(pointer))
    }
    set {
      withMutation(keyPath: \.currentTitle) {
        libvlc_media_player_set_title(pointer, Int32(newValue))
      }
    }
  }

  /// Full title descriptions for the current media.
  public var titles: [Title] {
    var cTitles: UnsafeMutablePointer<UnsafeMutablePointer<libvlc_title_description_t>?>?
    let count = libvlc_media_player_get_full_title_descriptions(pointer, &cTitles)
    guard count > 0, let cTitles else { return [] }
    defer { libvlc_title_descriptions_release(cTitles, UInt32(count)) }

    return (0..<Int(count)).compactMap { i -> Title? in
      guard let desc = cTitles[i]?.pointee else { return nil }
      return Title(
        index: i,
        duration: .milliseconds(desc.i_duration),
        name: desc.psz_name.map { String(cString: $0) },
        isMenu: desc.i_flags & UInt32(libvlc_title_menu) != 0,
        isInteractive: desc.i_flags & UInt32(libvlc_title_interactive) != 0
      )
    }
  }

  /// Full chapter descriptions for a title.
  /// - Parameter titleIndex: Zero-based title index, or `-1` for the current title.
  public func chapters(forTitle titleIndex: Int = -1) -> [Chapter] {
    var cChapters: UnsafeMutablePointer<UnsafeMutablePointer<libvlc_chapter_description_t>?>?
    let count = libvlc_media_player_get_full_chapter_descriptions(
      pointer, Int32(titleIndex), &cChapters
    )
    guard count > 0, let cChapters else { return [] }
    defer { libvlc_chapter_descriptions_release(cChapters, UInt32(count)) }

    return (0..<Int(count)).compactMap { i -> Chapter? in
      guard let desc = cChapters[i]?.pointee else { return nil }
      return Chapter(
        index: i,
        timeOffset: .milliseconds(desc.i_time_offset),
        duration: .milliseconds(desc.i_duration),
        name: desc.psz_name.map { String(cString: $0) }
      )
    }
  }
}
