@testable import SwiftVLC
import Testing

/// Discovery services the lifecycle tests can depend on in the bundled libVLC.
///
/// Looking a service up by category and returning early when the category is
/// empty turns a test into a no-op: the bundled libVLC has no
/// `.localDirectories` or `.devices` services at all, so tests written that
/// way never reached `start()` or `stop()`. Resolve through here instead; a
/// missing service is then a failure rather than a silent pass.
enum DiscoveryTestService {
  /// A media discovery service that starts and stops without any network
  /// peer or libupnp initialisation.
  ///
  /// Bonjour only creates `NSNetServiceBrowser` objects, so starting it cannot
  /// fail for environmental reasons and stopping it joins no thread. SAP is
  /// deliberately not used: stopping it joins a listener thread that libVLC
  /// does not wake on Darwin, so `stop()` never returns.
  static func startable(
    sourceLocation: SourceLocation = #_sourceLocation
  )
    throws -> DiscoveryService {
    try #require(
      MediaDiscoverer
        .availableServices(category: .lan, instance: TestInstance.shared)
        .first { $0.name == "Bonjour" },
      "The bundled libVLC no longer ships the Bonjour discovery service these tests start",
      sourceLocation: sourceLocation
    )
  }
}
