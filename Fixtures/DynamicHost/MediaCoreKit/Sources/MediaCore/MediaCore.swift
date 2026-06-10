@_exported import SwiftVLC

public enum MediaCore {
  public static var sharedInstanceID: ObjectIdentifier {
    ObjectIdentifier(VLCInstance.shared)
  }
}
