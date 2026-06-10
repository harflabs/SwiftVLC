@testable import SwiftVLC
import Darwin
import Foundation
import Synchronization
import Testing

extension Integration {
  struct VLCInstanceIdentityTests {
    /// Arguments mirroring `TestInstance`'s lifecycle setup: the HTTP
    /// request fires from libVLC's input thread during media open, so
    /// no audio/video output is needed and the instance stays safe on
    /// headless CI runners.
    private static let quietArguments = VLCInstance.defaultArguments + [
      "--no-video",
      "--no-audio",
      "--quiet"
    ]

    @Test(.tags(.async, .media), .timeLimit(.minutes(1)))
    @MainActor
    func `Custom HTTP user agent reaches the wire`() async throws {
      let server = try UserAgentProbeServer()
      defer { server.stop() }

      let instance = try VLCInstance(
        arguments: Self.quietArguments,
        httpUserAgent: "MyIPTV/9.9"
      )
      let player = Player(instance: instance)
      defer { player.stop() }

      do {
        try player.play(url: server.url)
      } catch {
        // The garbage payload is not meaningful media; this test is
        // about the User-Agent header sent before playback fails.
      }

      try #require(await poll(every: .milliseconds(50), timeout: .seconds(10)) {
        server.capturedUserAgent != nil
      }, "Waiting for: libVLC to request the URL with a User-Agent header")

      // libVLC appends its own product token (e.g. "LibVLC/4.0.0") after
      // the configured agent, so assert on the leading product only.
      let userAgent = try #require(server.capturedUserAgent)
      #expect(userAgent.hasPrefix("MyIPTV/9.9"))
    }

    @Test(.tags(.async, .media), .timeLimit(.minutes(1)))
    @MainActor
    func `Default HTTP user agent identifies SwiftVLC`() async throws {
      let server = try UserAgentProbeServer()
      defer { server.stop() }

      let instance = try VLCInstance(arguments: Self.quietArguments)
      let player = Player(instance: instance)
      defer { player.stop() }

      do {
        try player.play(url: server.url)
      } catch {
        // See above: only the request's User-Agent header matters here.
      }

      try #require(await poll(every: .milliseconds(50), timeout: .seconds(10)) {
        server.capturedUserAgent != nil
      }, "Waiting for: libVLC to request the URL with a User-Agent header")

      let userAgent = try #require(server.capturedUserAgent)
      #expect(userAgent.contains("SwiftVLC"))
    }

    @Test
    func `Set user agent after init does not crash`() throws {
      let instance = try VLCInstance(arguments: Self.quietArguments)
      instance.setUserAgent(name: "FooBar player 1.2.3", http: "FooBar/1.2.3")
      #expect(!instance.version.isEmpty)
    }

    @Test
    func `Set app ID does not crash`() throws {
      let instance = try VLCInstance(arguments: Self.quietArguments)
      instance.setAppID("com.acme.foobar", version: "1.2.3", icon: "foobar")
      #expect(!instance.version.isEmpty)
    }

    @Test
    func `Init without identity parameters stays source compatible`() throws {
      // A nil-free call site: the identity parameters are defaulted, so
      // the single-argument spelling must resolve unambiguously.
      let instance = try VLCInstance(arguments: Self.quietArguments)
      #expect(!instance.version.isEmpty)
    }
  }
}

/// Minimal local HTTP server that records the `User-Agent` header of
/// incoming requests and answers 200 with a few garbage bytes. Follows
/// the `BasicAuthProbeServer` pattern from `DialogHandlerNetworkTests`.
private final class UserAgentProbeServer: @unchecked Sendable {
  private let socketFD: Int32
  private let queue = DispatchQueue(label: "swiftvlc.user-agent-probe")
  private let state = StateBox()

  let url: URL

  var capturedUserAgent: String? {
    state.capturedUserAgent
  }

  init() throws {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }

    var reuse: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = 0
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

    let bindResult = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
        Darwin.bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard bindResult == 0 else {
      let error = POSIXError(.init(rawValue: errno) ?? .EIO)
      close(fd)
      throw error
    }

    guard listen(fd, 4) == 0 else {
      let error = POSIXError(.init(rawValue: errno) ?? .EIO)
      close(fd)
      throw error
    }

    var boundAddress = sockaddr_in()
    var boundLength = socklen_t(MemoryLayout<sockaddr_in>.size)
    let nameResult = withUnsafeMutablePointer(to: &boundAddress) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
        getsockname(fd, sockaddrPointer, &boundLength)
      }
    }
    guard nameResult == 0 else {
      let error = POSIXError(.init(rawValue: errno) ?? .EIO)
      close(fd)
      throw error
    }

    let port = UInt16(bigEndian: boundAddress.sin_port)
    socketFD = fd
    url = URL(string: "http://127.0.0.1:\(port)/x.ts")!

    queue.async { [fd, state] in
      Self.acceptLoop(socketFD: fd, state: state)
    }
  }

  deinit {
    stop()
  }

  func stop() {
    state.mutex.withLock { state in
      guard !state.isStopped else { return }
      state.isStopped = true
      shutdown(socketFD, SHUT_RDWR)
      close(socketFD)
    }
  }

  private static func acceptLoop(socketFD: Int32, state: StateBox) {
    while true {
      let client = accept(socketFD, nil, nil)
      if client < 0 { return }
      handle(client: client, state: state)
      close(client)
    }
  }

  private static func handle(client: Int32, state: StateBox) {
    let request = readRequest(from: client)
    if let userAgent = userAgentHeader(in: request) {
      state.mutex.withLock { $0.capturedUserAgent = userAgent }
    }

    let body = "not a transport stream"
    let response = [
      "HTTP/1.1 200 OK",
      "Content-Type: video/mp2t",
      "Content-Length: \(body.utf8.count)",
      "Connection: close"
    ].joined(separator: "\r\n") + "\r\n\r\n" + body
    response.withCString { pointer in
      _ = write(client, pointer, strlen(pointer))
    }
  }

  private static func userAgentHeader(in request: String) -> String? {
    for line in request.components(separatedBy: "\r\n") {
      let prefix = "user-agent:"
      guard line.lowercased().hasPrefix(prefix) else { continue }
      return line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
    }
    return nil
  }

  private static func readRequest(from client: Int32) -> String {
    var bytes: [UInt8] = []
    var buffer = [UInt8](repeating: 0, count: 1024)

    while bytes.count < 16 * 1024 {
      let count = recv(client, &buffer, buffer.count, 0)
      guard count > 0 else { break }
      bytes.append(contentsOf: buffer.prefix(count))
      if bytes.containsCRLFCRLF { break }
    }

    return String(bytes: bytes, encoding: .utf8) ?? ""
  }

  private struct State: @unchecked Sendable {
    var isStopped = false
    var capturedUserAgent: String?
  }

  private final class StateBox: @unchecked Sendable {
    let mutex = Mutex(State())

    var capturedUserAgent: String? {
      mutex.withLock { $0.capturedUserAgent }
    }
  }
}

extension [UInt8] {
  fileprivate var containsCRLFCRLF: Bool {
    guard count >= 4 else { return false }
    return indices.dropFirst(3).contains { index in
      self[index - 3] == 13
        && self[index - 2] == 10
        && self[index - 1] == 13
        && self[index] == 10
    }
  }
}
