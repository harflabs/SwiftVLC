import Foundation

/// Downloads a remote video to the app's caches directory once, then
/// returns the local file URL on subsequent calls. libVLC's thumbnail
/// generation is CPU-bound on local files (~200 ms per precise decode)
/// but network-bound on remote HTTP sources (~3-8 s per decode with
/// range requests on slow CDNs). For any case that exercises seek /
/// thumbnail APIs, materializing the file locally is the difference
/// between "usable" and "broken."
///
/// Cache key is the URL's `lastPathComponent`; override via the init
/// `cacheName` if the URL is ambiguous or needs a stable name across
/// different remote hosts.
@MainActor
final class RemoteMediaCache {
  enum State: Equatable {
    case idle
    case downloading(received: Int64, total: Int64?)
    case ready(URL)
    case failed(String)
  }

  private(set) var state: State = .idle
  private let session: URLSession
  private let observer: DownloadDelegate

  init() {
    observer = DownloadDelegate()
    session = URLSession(
      configuration: .default,
      delegate: observer,
      delegateQueue: .main
    )
    observer.onProgress = { [weak self] received, total in
      self?.state = .downloading(received: received, total: total)
    }
  }

  /// Returns the cached local URL for `remote` if it exists; otherwise
  /// starts a download and updates `state` as it progresses. Returns
  /// the local URL once complete, or throws on failure.
  func materialize(_ remote: URL, cacheName: String? = nil) async throws -> URL {
    let name = cacheName ?? remote.lastPathComponent
    let local = Self.cacheDirectory.appendingPathComponent(name)

    if FileManager.default.fileExists(atPath: local.path) {
      state = .ready(local)
      return local
    }

    state = .downloading(received: 0, total: nil)

    do {
      let (tmp, _) = try await session.download(from: remote, delegate: observer)
      try? FileManager.default.removeItem(at: local) // in case of race
      try FileManager.default.moveItem(at: tmp, to: local)
      state = .ready(local)
      return local
    } catch is CancellationError {
      state = .idle
      throw CancellationError()
    } catch {
      state = .failed(error.localizedDescription)
      throw error
    }
  }

  private static var cacheDirectory: URL {
    let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
    let dir = base.appendingPathComponent("SwiftVLCShowcase-RemoteMedia", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }
}

/// `URLSession` download delegate that forwards progress to the cache
/// owner on the main actor. Separated out so `RemoteMediaCache` itself
/// can stay `@MainActor`-isolated — delegates must be `Sendable` /
/// cross-actor, and wrapping the callback handoff here keeps the
/// public API clean.
private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
  var onProgress: (@MainActor @Sendable (Int64, Int64?) -> Void)?

  func urlSession(
    _: URLSession,
    downloadTask _: URLSessionDownloadTask,
    didWriteData _: Int64,
    totalBytesWritten: Int64,
    totalBytesExpectedToWrite: Int64
  ) {
    let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil
    Task { @MainActor [onProgress] in
      onProgress?(totalBytesWritten, total)
    }
  }

  func urlSession(
    _: URLSession,
    downloadTask _: URLSessionDownloadTask,
    didFinishDownloadingTo _: URL
  ) {
    // Handled by the `await session.download(from:)` result — this
    // delegate exists only to observe progress, not to move the file.
  }
}
