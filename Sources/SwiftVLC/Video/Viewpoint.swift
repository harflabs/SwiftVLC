import CLibVLC

/// Orientation and field of view for 360°/VR video.
///
/// Pass to ``Player/updateViewpoint(_:absolute:)`` to look around
/// equirectangular or cubemap content. All angles are in degrees.
///
/// ```swift
/// try player.updateViewpoint(Viewpoint(yaw: 90, pitch: 0))
/// ```
public struct Viewpoint: Sendable, Hashable {
  /// Horizontal look direction in degrees, where `0` faces forward.
  /// Range: `-180` to `180`.
  public var yaw: Float

  /// Vertical look direction in degrees, where `0` is level.
  /// Range: `-90` (straight down) to `90` (straight up).
  public var pitch: Float

  /// Camera-roll rotation in degrees. Range: `-180` to `180`.
  public var roll: Float

  /// Field of view in degrees. Range: `0` to `180`; default is `80`.
  /// Smaller values zoom in, larger values zoom out.
  public var fieldOfView: Float

  /// Creates a viewpoint with the given orientation and field of view.
  public init(yaw: Float = 0, pitch: Float = 0, roll: Float = 0, fieldOfView: Float = 80) {
    self.yaw = yaw
    self.pitch = pitch
    self.roll = roll
    self.fieldOfView = fieldOfView
  }
}
