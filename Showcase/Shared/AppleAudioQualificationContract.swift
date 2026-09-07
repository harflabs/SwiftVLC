import Foundation

/// Stable, JSON-safe projection of SwiftVLC's native v8 recovery snapshot.
///
/// The showcase app records these values and the separately signed XCTest
/// runner validates them before attaching release evidence. Keeping the
/// projection in Shared makes missing native fields a compile-time break on
/// both sides of the device harness.
struct AppleAudioNativeRecoveryRecord: Codable, Equatable {
  let version: UInt32
  let brokerPhase: String
  let commandOrigin: String
  let brokerEpoch: UInt64
  let brokerResetEpoch: UInt64
  let commandGeneration: UInt64
  let commandResetEpoch: UInt64
  let acknowledgedResetEpoch: UInt64
  let outputIncarnationCount: UInt64
  let successfulRebuildCount: UInt64
  let explicitResumeAttemptCount: UInt64
  let explicitResumeFailureCount: UInt64
  let commandWasDispatched: Bool
  let liveOutputCount: UInt32
  let brokerActiveOwnerCount: UInt32
  let brokerLiveLeaseCount: UInt32
  let brokerSuccessfulDeactivationCount: UInt64
  let brokerFailedDeactivationCount: UInt64
}

struct AppleAudioPlaybackCounterRecord: Codable, Equatable {
  let mediaTimeMilliseconds: Int64
  let decodedAudio: UInt64
  let playedAudioBuffers: UInt64
  let lostAudioBuffers: UInt64
  let decodedVideo: UInt64
  let displayedPictures: UInt64
  let lostPictures: UInt64
}

struct AppleAudioRecoveryCheckpoint: Codable, Equatable {
  let systemUptime: TimeInterval
  let playerState: String
  let playbackRequestedActive: Bool
  let native: AppleAudioNativeRecoveryRecord
  let playback: AppleAudioPlaybackCounterRecord
}

struct AppleAudioResetPlayerRecord: Codable, Equatable {
  let role: String
  let forcedAudioOutputModule: String
  let readinessStart: AppleAudioRecoveryCheckpoint
  let baseline: AppleAudioRecoveryCheckpoint
  let quarantineStart: AppleAudioRecoveryCheckpoint
  let quarantineEnd: AppleAudioRecoveryCheckpoint
  let recovered: AppleAudioRecoveryCheckpoint
}

struct AppleAudioMediaServicesNotificationRecord: Codable, Equatable {
  let kind: String
  let systemUptime: TimeInterval
}

struct MediaServicesResetQualificationRawResult: Codable, Equatable {
  let formatVersion: Int
  let trigger: String
  let syntheticNotificationsPosted: Bool
  let mediaServicesLostNotificationCount: Int
  let mediaServicesResetNotificationCount: Int
  let mediaServicesNotificationSequence: [AppleAudioMediaServicesNotificationRecord]
  let quarantineObservationMilliseconds: Int64
  let pictureInPictureActiveBeforeReset: Bool
  let pictureInPictureActiveAfterRecovery: Bool
  let players: [AppleAudioResetPlayerRecord]
}

struct AppleAudioSessionConfigurationRecord: Codable, Equatable {
  let category: String
  let mode: String
  let categoryOptionsRawValue: UInt
  let routeSharingPolicyRawValue: UInt
  let preferredSampleRate: Double
  let preferredIOBufferDuration: TimeInterval
  let preferredInputNumberOfChannels: Int
  let preferredOutputNumberOfChannels: Int
}

struct AppleAudioLibraryManagedOwnershipCycleRecord: Codable, Equatable {
  let forcedModuleOrder: [String]
  let firstOutputActive: AppleAudioRecoveryCheckpoint
  let bothOutputsActive: AppleAudioRecoveryCheckpoint
  let afterFirstOutputRelease: AppleAudioRecoveryCheckpoint
  let afterFinalOutputRelease: AppleAudioRecoveryCheckpoint
  let firstOutputPlaybackStart: AppleAudioPlaybackCounterRecord
  let firstOutputPlaybackEnd: AppleAudioPlaybackCounterRecord
  let secondOutputPlaybackStart: AppleAudioPlaybackCounterRecord
  let secondOutputPlaybackEnd: AppleAudioPlaybackCounterRecord
}

struct AppleAudioHostRecoveryRecord: Codable, Equatable {
  let reactivationBeganSystemUptime: TimeInterval
  let reactivationCompletedSystemUptime: TimeInterval
  let sessionAfterReactivation: AppleAudioSessionConfigurationRecord
  let playbackStart: AppleAudioRecoveryCheckpoint
  let playbackEnd: AppleAudioRecoveryCheckpoint
  let brokerAfterShutdown: AppleAudioNativeRecoveryRecord
  let sessionAfterShutdown: AppleAudioSessionConfigurationRecord
}

struct AppleAudioApplicationManagedOwnershipCycleRecord: Codable, Equatable {
  let forcedAudioOutputModule: String
  let sessionBeforePlayback: AppleAudioSessionConfigurationRecord
  let sessionDuringPlayback: AppleAudioSessionConfigurationRecord
  let sessionAfterPlayback: AppleAudioSessionConfigurationRecord
  let brokerBeforePlayback: AppleAudioNativeRecoveryRecord
  let brokerDuringPlayback: AppleAudioNativeRecoveryRecord
  let brokerAfterPlayback: AppleAudioNativeRecoveryRecord
  let playbackStart: AppleAudioPlaybackCounterRecord
  let playbackEnd: AppleAudioPlaybackCounterRecord
  let hostRecovery: AppleAudioHostRecoveryRecord
}

struct AppleAudioInterruptionNotificationRecord: Codable, Equatable {
  let kind: String
  let systemUptime: TimeInterval
  let reasonRawValue: UInt
}

struct AudioSessionOwnershipQualificationRawResult: Codable, Equatable {
  let formatVersion: Int
  let libraryManagedForcedModules: [String]
  let applicationManagedForcedModules: [String]
  let idleSessionBeforePlayerConstruction: AppleAudioSessionConfigurationRecord
  let idleSessionAfterPlayerConstruction: AppleAudioSessionConfigurationRecord
  let idleBrokerBeforePlayerConstruction: AppleAudioNativeRecoveryRecord
  let idleBrokerAfterPlayerConstruction: AppleAudioNativeRecoveryRecord
  let libraryManagedCycles: [AppleAudioLibraryManagedOwnershipCycleRecord]
  let applicationManagedCycles: [AppleAudioApplicationManagedOwnershipCycleRecord]
  let interruptionNotificationSequence: [AppleAudioInterruptionNotificationRecord]
  let notificationCaptureSystemUptime: TimeInterval
}

/// Captured synchronously in the candidate app, so AX delivery latency cannot
/// bind an older counter value to a newer runner timestamp.
struct AppleAudioInterruptionCounterSnapshot: Codable {
  let id: String
  let began: Int
  let ended: Int
  let systemUptime: Double
}
