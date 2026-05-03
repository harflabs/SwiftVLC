import CLibVLC
import Darwin

/// Audio output, devices, equalizer, stereo/mix mode.
extension Player {
  // MARK: - Equalizer

  /// The audio equalizer applied to this player. Set `nil` to disable.
  ///
  /// Subsequent mutations on the assigned `Equalizer` are re-applied
  /// to the audio output automatically through an installed change
  /// handler. libVLC copies settings on each
  /// `libvlc_media_player_set_equalizer` call and does not retain the
  /// reference.
  public var equalizer: Equalizer? {
    get { _equalizer }
    set {
      _equalizer?.onChange = nil
      _equalizer = newValue
      libvlc_media_player_set_equalizer(pointer, newValue?.pointer)
      newValue?.onChange = { [weak self, weak newValue] in
        guard let self, let newValue else { return }
        libvlc_media_player_set_equalizer(pointer, newValue.pointer)
      }
    }
  }

  // MARK: - Audio Output & Devices

  /// Sets the audio output module.
  /// - Throws: `VLCError.operationFailed` if the module cannot be set.
  public func setAudioOutput(_ name: String) throws(VLCError) {
    guard libvlc_audio_output_set(pointer, name) == 0 else {
      throw .operationFailed("Set audio output '\(name)'")
    }
  }

  /// Lists available audio output devices for the current output.
  public func audioDevices() -> [AudioDevice] {
    guard let list = libvlc_audio_output_device_enum(pointer) else { return [] }
    defer { libvlc_audio_output_device_list_release(list) }

    return sequence(first: list, next: { $0.pointee.p_next }).map { node in
      AudioDevice(
        deviceId: String(cString: node.pointee.psz_device),
        deviceDescription: String(cString: node.pointee.psz_description)
      )
    }
  }

  /// Sets the audio output device.
  /// - Throws: `VLCError.operationFailed` if the device cannot be set.
  public func setAudioDevice(_ deviceId: String) throws(VLCError) {
    guard libvlc_audio_output_device_set(pointer, deviceId) == 0 else {
      throw .operationFailed("Set audio device '\(deviceId)'")
    }
  }

  /// Current audio output device identifier.
  public var currentAudioDevice: String? {
    access(keyPath: \.currentAudioDevice)
    guard let cstr = libvlc_audio_output_device_get(pointer) else { return nil }
    defer { free(cstr) }
    return String(cString: cstr)
  }

  // MARK: - Stereo & Mix Mode

  /// Audio stereo mode.
  public var stereoMode: StereoMode {
    get {
      access(keyPath: \.stereoMode)
      return StereoMode(from: libvlc_audio_get_stereomode(pointer))
    }
    set {
      _ = withMutation(keyPath: \.stereoMode) {
        libvlc_audio_set_stereomode(pointer, newValue.cValue)
      }
    }
  }

  /// Audio mix/channel mode.
  public var mixMode: MixMode {
    get {
      access(keyPath: \.mixMode)
      return MixMode(from: libvlc_audio_get_mixmode(pointer))
    }
    set {
      _ = withMutation(keyPath: \.mixMode) {
        libvlc_audio_set_mixmode(pointer, newValue.cValue)
      }
    }
  }
}
