import CLibVLC
import CryptoKit
import Foundation

extension Player {
  // MARK: - External Tracks

  /// Adds an external subtitle or audio file to the player.
  ///
  /// libVLC loads the file asynchronously and records it on the current
  /// ``Media``, which loads it again whenever that media plays — after
  /// ``stop()``, on replay, and after ``recast(to:)``. Adding a URL that is
  /// already attached does not load a second copy.
  ///
  /// - Parameters:
  ///   - url: URL of the external track file (must use a valid scheme like `file://`).
  ///   - type: Whether this is a subtitle or audio track.
  ///   - select: If `true`, the track is selected once libVLC has loaded
  ///     it, replacing the selected track of that type. Selecting another
  ///     track of that type before the file loads cancels this.
  /// - Throws: ``VLCError/invalidState(_:)`` if the current media is awaiting
  ///   its native handle, or ``VLCError/operationFailed(_:)`` if the track
  ///   cannot be added.
  public func addExternalTrack(from url: URL, type: MediaSlaveType, select: Bool = true) throws(VLCError) {
    guard nativeHandleRepresentsCurrentMedia else {
      throw .invalidState("addExternalTrack requires a native handle for the current media")
    }
    let uri = url.absoluteString
    let trackType: TrackType = type == .subtitle ? .subtitle : .audio
    // libVLC ids an external track "<MD5 of its URI>/<category>/<n>". A
    // second copy of an attached file would repeat those ids exactly,
    // leaving one copy unselectable and duplicating list identities.
    let idPrefix = Self.externalTrackIDPrefix(forURI: uri)
    let loadedTrack = fetchTracks(type: trackType).first { $0.id.hasPrefix(idPrefix) }
    let isAttached = loadedTrack != nil
      || currentMedia?.slaves.contains { $0.uri == uri } == true
    if !isAttached {
      #if DEBUG
      _mediaSpecificNativeDispatchHookForTesting?(.addExternalTrack)
      #endif
      guard libvlc_media_player_add_slave(pointer, type.cValue, uri, select) == 0 else {
        throw .operationFailed("Add external \(type) track")
      }
    }
    guard select else { return }
    if let loadedTrack {
      setSelectedTrack(loadedTrack, type: trackType)
      return
    }
    // libVLC's own `select` flag only prefers the file over default
    // tracks; it never replaces a track the user selected. Select the
    // track explicitly once it loads, unless a newer selection of this
    // type supersedes the request first.
    let revision: UInt64
    switch trackType {
    case .audio:
      intentRevisions.audioTrackSelection &+= 1
      revision = intentRevisions.audioTrackSelection
    default:
      intentRevisions.subtitleTrackSelection &+= 1
      revision = intentRevisions.subtitleTrackSelection
    }
    pendingExternalTrackSelections[trackType] = PendingExternalTrackSelection(
      idPrefix: idPrefix,
      revision: revision,
      playbackGeneration: sessionGeneration,
      nativeHandleGeneration: eventBridge.currentNativeHandleGeneration
    )
  }

  /// An external track to select once it loads, valid only while the
  /// selection intent, playback, and native handle it was made for remain
  /// current.
  struct PendingExternalTrackSelection {
    let idPrefix: String
    let revision: UInt64
    let playbackGeneration: UInt64
    let nativeHandleGeneration: UInt64
  }

  static func externalTrackIDPrefix(forURI uri: String) -> String {
    let digest = Insecure.MD5.hash(data: Data(uri.utf8))
    return digest.map { String(format: "%02x", $0) }.joined() + "/"
  }

  /// Completes ``addExternalTrack(from:type:select:)`` requests whose track
  /// has appeared in the refreshed lists.
  func selectLoadedExternalTracks() {
    for type in [TrackType.audio, .subtitle] {
      guard let pending = pendingExternalTrackSelections[type] else { continue }
      let revision = type == .audio
        ? intentRevisions.audioTrackSelection
        : intentRevisions.subtitleTrackSelection
      guard
        pending.revision == revision,
        pending.playbackGeneration == sessionGeneration,
        pending.nativeHandleGeneration == eventBridge.currentNativeHandleGeneration
      else {
        pendingExternalTrackSelections[type] = nil
        continue
      }
      let tracks = type == .audio ? audioTracks : subtitleTracks
      guard let track = tracks.first(where: { $0.id.hasPrefix(pending.idPrefix) }) else {
        continue
      }
      pendingExternalTrackSelections[type] = nil
      setSelectedTrack(track, type: type)
    }
  }

  private func setSelectedTrack(_ track: Track, type: TrackType) {
    if type == .audio {
      selectedAudioTrack = track
    } else {
      selectedSubtitleTrack = track
    }
  }

  // MARK: - Track Selection

  func selectTrack(_ track: Track?, type: TrackType, on pointer: OpaquePointer) {
    guard nativeHandleRepresentsCurrentMedia else { return }
    // `select_tracks_by_ids` queues behind earlier selection commands and
    // pins the choice for the rest of the session: tracks the input adds
    // later of this type stay unselected, and an empty list is a lasting
    // "off". The one-shot `select_track` cannot override libVLC's own
    // preference for an external track, and `unselect_track_type` only
    // reaches tracks the player has already mirrored as selected, so a
    // selection still queued survived it.
    let ids: String
    if let track {
      guard let current = currentTrack(matching: track) else { return }
      ids = current.id
      #if DEBUG
      recordObservableControlNativeDispatch(
        type == .audio ? .audioTrack(ids) : .subtitleTrack(ids),
        pointer: pointer
      )
      _mediaSpecificNativeDispatchHookForTesting?(.selectTrack)
      #endif
    } else {
      ids = ""
      #if DEBUG
      recordObservableControlNativeDispatch(
        type == .audio ? .audioTrack(nil) : .subtitleTrack(nil),
        pointer: pointer
      )
      _mediaSpecificNativeDispatchHookForTesting?(.unselectTrack)
      #endif
    }
    libvlc_media_player_select_tracks_by_ids(pointer, type.cValue, ids)
    // No eager refresh here. libVLC emits `ESSelected` / `ESUpdated`
    // once the new selection settles (typically <10ms), and the event
    // handler's `refreshTracks()` is the single source of truth. An
    // eager refresh would race libVLC's internal state and briefly
    // show stale `isSelected` flags.
  }

  /// The track of the current session that `track` describes.
  ///
  /// An unstable (adaptive) id goes stale whenever the demuxer recreates
  /// the stream — after every seek and selection change — so a ``Track``
  /// captured earlier is resolved by its description instead.
  func currentTrack(matching track: Track) -> Track? {
    let candidates = fetchTracks(type: track.type)
    if let exact = candidates.first(where: { $0.id == track.id }) {
      return exact
    }
    guard !track.isIDStable else { return nil }
    return Self.matchingTrack(for: track, in: candidates)
  }

  // MARK: - Video

  func applyAspectRatio() {
    applyAspectRatio(_aspectRatio, to: pointer)
  }

  func applyAspectRatio(_ aspectRatio: AspectRatio, to pointer: OpaquePointer) {
    if let ratioString = aspectRatio.vlcString {
      ratioString.withCString { cstr in
        libvlc_video_set_aspect_ratio(pointer, cstr)
      }
    } else {
      libvlc_video_set_aspect_ratio(pointer, nil)
    }

    switch aspectRatio {
    case .default:
      libvlc_video_set_scale(pointer, 0) // auto
      libvlc_video_set_display_fit(pointer, libvlc_video_fit_smaller)
    case .ratio:
      // Explicitly reset the fit mode so a prior `.fill` (cover) can't
      // override the new aspect ratio visually.
      libvlc_video_set_display_fit(pointer, libvlc_video_fit_smaller)
    case .fill:
      libvlc_video_set_display_fit(pointer, libvlc_video_fit_larger)
    }
  }

  // MARK: - Track Refresh

  /// Refreshes all observable track lists from the native player.
  ///
  /// The track arrays are asynchronously mirrored snapshots. Receiving the payload-free
  /// ``PlayerEvent/tracksChanged-enum.case`` or ``PlayerEvent/mediaChanged-enum.case`` event does not guarantee
  /// they are updated; consumers requiring an immediate native read should call this
  /// method after either event. This also invalidates selected-track observations.
  public func refreshTracks() {
    let playbackGeneration = sessionGeneration
    let nativeHandleGeneration = eventBridge.currentNativeHandleGeneration
    let audioSelectionRevision = intentRevisions.audioTrackSelection
    let subtitleSelectionRevision = intentRevisions.subtitleTrackSelection
    _ = refreshTracks(
      ifPlaybackGeneration: playbackGeneration,
      nativeHandleGeneration: nativeHandleGeneration,
      audioSelectionRevision: audioSelectionRevision,
      subtitleSelectionRevision: subtitleSelectionRevision
    )
  }

  @discardableResult
  func refreshTracks(
    ifPlaybackGeneration expectedPlaybackGeneration: UInt64?,
    nativeHandleGeneration expectedNativeHandleGeneration: UInt64?,
    timelineRevision expectedTimelineRevision: UInt64? = nil,
    lifecycleControlEpoch expectedLifecycleControlEpoch: UInt64? = nil,
    audioSelectionRevision expectedAudioSelectionRevision: UInt64? = nil,
    subtitleSelectionRevision expectedSubtitleSelectionRevision: UInt64? = nil
  ) -> Bool {
    let audioSelectionRevision = expectedAudioSelectionRevision
      ?? intentRevisions.audioTrackSelection
    let subtitleSelectionRevision = expectedSubtitleSelectionRevision
      ?? intentRevisions.subtitleTrackSelection

    func sourceIsCurrent() -> Bool {
      if let expectedTimelineRevision {
        guard expectedTimelineRevision == acceptedTimelineRevision else { return false }
      }
      if let expectedLifecycleControlEpoch {
        guard expectedLifecycleControlEpoch == eventBridge.currentLifecycleControlEpoch else {
          return false
        }
      }
      if let expectedNativeHandleGeneration {
        guard expectedNativeHandleGeneration == eventBridge.currentNativeHandleGeneration else {
          return false
        }
      }
      guard audioSelectionRevision == intentRevisions.audioTrackSelection else {
        return false
      }
      guard subtitleSelectionRevision == intentRevisions.subtitleTrackSelection else {
        return false
      }
      guard let expectedPlaybackGeneration else { return true }
      return ownsPlaybackMutation(expectedPlaybackGeneration)
    }

    func performRefreshMutation(
      keyPath: KeyPath<Player, some Any>,
      mutation: () -> Void
    ) -> Bool {
      var didPerform = false
      withMutation(keyPath: keyPath) {
        guard sourceIsCurrent() else { return }
        mutation()
        didPerform = true
      }
      return didPerform && sourceIsCurrent()
    }

    guard sourceIsCurrent() else { return false }
    guard nativeHandleRepresentsCurrentMedia else {
      guard
        performRefreshMutation(
          keyPath: \.audioTracks,
          mutation: {
            removeAllAudioTrackStorageWithoutNestedObservation()
          }
        ) else { return false }
      guard
        performRefreshMutation(
          keyPath: \.videoTracks,
          mutation: {
            removeAllVideoTrackStorageWithoutNestedObservation()
          }
        ) else { return false }
      guard
        performRefreshMutation(
          keyPath: \.subtitleTracks,
          mutation: {
            removeAllSubtitleTrackStorageWithoutNestedObservation()
          }
        ) else { return false }
      guard
        performRefreshMutation(
          keyPath: \.selectedAudioTrack,
          mutation: {}
        ) else { return false }
      guard
        performRefreshMutation(
          keyPath: \.selectedSubtitleTrack,
          mutation: {}
        ) else { return false }
      return sourceIsCurrent()
    }
    let refreshedAudioTracks = fetchTracks(type: .audio)
    guard
      performRefreshMutation(
        keyPath: \.audioTracks,
        mutation: {
          storeAudioTracksWithoutNestedObservation(refreshedAudioTracks)
        }
      ) else { return false }
    let refreshedVideoTracks = fetchTracks(type: .video)
    guard
      performRefreshMutation(
        keyPath: \.videoTracks,
        mutation: {
          storeVideoTracksWithoutNestedObservation(refreshedVideoTracks)
        }
      ) else { return false }
    let refreshedSubtitleTracks = fetchTracks(type: .subtitle)
    guard
      performRefreshMutation(
        keyPath: \.subtitleTracks,
        mutation: {
          storeSubtitleTracksWithoutNestedObservation(refreshedSubtitleTracks)
        }
      ) else { return false }
    guard
      performRefreshMutation(
        keyPath: \.selectedAudioTrack,
        mutation: {}
      ) else { return false }
    guard
      performRefreshMutation(
        keyPath: \.selectedSubtitleTrack,
        mutation: {}
      ) else { return false }
    return sourceIsCurrent()
  }

  private func fetchTracks(type: TrackType) -> [Track] {
    guard nativeHandleRepresentsCurrentMedia else { return [] }
    #if DEBUG
    _mediaSpecificNativeDispatchHookForTesting?(.readTracks(type))
    #endif
    guard let tracklist = libvlc_media_player_get_tracklist(pointer, type.cValue, false) else {
      return []
    }
    defer { libvlc_media_tracklist_delete(tracklist) }

    let count = libvlc_media_tracklist_count(tracklist)
    return (0..<count).compactMap { i in
      libvlc_media_tracklist_at(tracklist, i).map { Track(from: $0) }
    }
  }
}
