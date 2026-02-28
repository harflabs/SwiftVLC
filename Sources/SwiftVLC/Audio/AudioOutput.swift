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

public extension VLCInstance {
    /// Lists available audio output modules.
    func audioOutputs() -> [AudioOutput] {
        guard let list = libvlc_audio_output_list_get(pointer) else { return [] }
        defer { libvlc_audio_output_list_release(list) }

        var results: [AudioOutput] = []
        var current: UnsafeMutablePointer<libvlc_audio_output_t>? = list
        while let node = current {
            let p = node.pointee
            results.append(AudioOutput(
                name: String(cString: p.psz_name),
                outputDescription: String(cString: p.psz_description)
            ))
            current = p.p_next
        }
        return results
    }
}
