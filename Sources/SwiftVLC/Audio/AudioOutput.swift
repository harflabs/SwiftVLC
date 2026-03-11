import CLibVLC

/// An available audio output module.
public struct AudioOutput: Sendable, Identifiable, Hashable {
  /// Module identifier.
  public let name: String

  /// Human-readable description.
  public let outputDescription: String

  public var id: String {
    name
  }
}

/// An available audio output device.
public struct AudioDevice: Sendable, Identifiable, Hashable {
  /// Device identifier string.
  public let deviceId: String

  /// Human-readable description.
  public let deviceDescription: String

  public var id: String {
    deviceId
  }
}

// MARK: - VLCInstance extensions

extension VLCInstance {
  /// Lists available audio output modules.
  public func audioOutputs() -> [AudioOutput] {
    guard let list = libvlc_audio_output_list_get(pointer) else { return [] }
    defer { libvlc_audio_output_list_release(list) }

    return sequence(first: list, next: { $0.pointee.p_next }).map { node in
      AudioOutput(
        name: String(cString: node.pointee.psz_name),
        outputDescription: String(cString: node.pointee.psz_description)
      )
    }
  }
}
