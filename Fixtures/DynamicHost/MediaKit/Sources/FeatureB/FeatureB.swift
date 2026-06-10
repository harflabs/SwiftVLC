import MediaCore

public enum FeatureB {
  public static func instanceID() -> ObjectIdentifier {
    MediaCore.sharedInstanceID
  }

  @MainActor
  public static func makePlayer() -> Player {
    Player()
  }
}
