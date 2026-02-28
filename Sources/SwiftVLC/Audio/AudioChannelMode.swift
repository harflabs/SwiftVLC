import CLibVLC

/// Audio stereo output mode.
public enum StereoMode: Sendable, Hashable, CustomStringConvertible {
    case unset
    case stereo
    case reverseStereo
    case left
    case right
    case dolbySurround
    case mono

    public var description: String {
        switch self {
        case .unset: "unset"
        case .stereo: "stereo"
        case .reverseStereo: "reverse stereo"
        case .left: "left"
        case .right: "right"
        case .dolbySurround: "Dolby Surround"
        case .mono: "mono"
        }
    }

    var cValue: libvlc_audio_output_stereomode_t {
        switch self {
        case .unset: libvlc_AudioStereoMode_Unset
        case .stereo: libvlc_AudioStereoMode_Stereo
        case .reverseStereo: libvlc_AudioStereoMode_RStereo
        case .left: libvlc_AudioStereoMode_Left
        case .right: libvlc_AudioStereoMode_Right
        case .dolbySurround: libvlc_AudioStereoMode_Dolbys
        case .mono: libvlc_AudioStereoMode_Mono
        }
    }

    init(from cValue: libvlc_audio_output_stereomode_t) {
        switch cValue {
        case libvlc_AudioStereoMode_Stereo: self = .stereo
        case libvlc_AudioStereoMode_RStereo: self = .reverseStereo
        case libvlc_AudioStereoMode_Left: self = .left
        case libvlc_AudioStereoMode_Right: self = .right
        case libvlc_AudioStereoMode_Dolbys: self = .dolbySurround
        case libvlc_AudioStereoMode_Mono: self = .mono
        default: self = .unset
        }
    }
}

/// Audio mix/channel mode for output.
public enum MixMode: Sendable, Hashable, CustomStringConvertible {
    case unset
    case stereo
    case binaural
    case fourPointZero
    case fivePointOne
    case sevenPointOne

    public var description: String {
        switch self {
        case .unset: "unset"
        case .stereo: "stereo"
        case .binaural: "binaural"
        case .fourPointZero: "4.0"
        case .fivePointOne: "5.1"
        case .sevenPointOne: "7.1"
        }
    }

    var cValue: libvlc_audio_output_mixmode_t {
        switch self {
        case .unset: libvlc_AudioMixMode_Unset
        case .stereo: libvlc_AudioMixMode_Stereo
        case .binaural: libvlc_AudioMixMode_Binaural
        case .fourPointZero: libvlc_AudioMixMode_4_0
        case .fivePointOne: libvlc_AudioMixMode_5_1
        case .sevenPointOne: libvlc_AudioMixMode_7_1
        }
    }

    init(from cValue: libvlc_audio_output_mixmode_t) {
        switch cValue {
        case libvlc_AudioMixMode_Stereo: self = .stereo
        case libvlc_AudioMixMode_Binaural: self = .binaural
        case libvlc_AudioMixMode_4_0: self = .fourPointZero
        case libvlc_AudioMixMode_5_1: self = .fivePointOne
        case libvlc_AudioMixMode_7_1: self = .sevenPointOne
        default: self = .unset
        }
    }
}
