import CLibVLC

/// 360/VR video viewpoint.
public struct Viewpoint: Sendable, Hashable {
  /// Yaw in degrees (-180 to 180).
  public var yaw: Float

  /// Pitch in degrees (-90 to 90).
  public var pitch: Float

  /// Roll in degrees (-180 to 180).
  public var roll: Float

  /// Field of view in degrees (0 to 180, default 80).
  public var fieldOfView: Float

  /// Creates a viewpoint with the given orientation.
  public init(yaw: Float = 0, pitch: Float = 0, roll: Float = 0, fieldOfView: Float = 80) {
    self.yaw = yaw
    self.pitch = pitch
    self.roll = roll
    self.fieldOfView = fieldOfView
  }
}
