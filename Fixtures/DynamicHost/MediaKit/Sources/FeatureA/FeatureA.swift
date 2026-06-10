import MediaCore

public enum FeatureA {
  public static func instanceID() -> ObjectIdentifier {
    MediaCore.sharedInstanceID
  }

  @MainActor
  public static func makePlayer() -> Player {
    Player()
  }
}
