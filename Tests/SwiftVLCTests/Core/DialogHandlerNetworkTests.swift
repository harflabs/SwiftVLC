@testable import SwiftVLC
import Darwin
import Foundation
import Synchronization
import Testing

extension Integration {
  struct DialogHandlerNetworkTests {
    @Test(.tags(.async, .media), .timeLimit(.minutes(1)))
    @MainActor
    func `HTTP auth emits login dialog`() async throws {
      let server = try BasicAuthProbeServer()
      defer { server.stop() }

      let instance = TestInstance.shared
      let handler = DialogHandler(instance: instance)
      let media = try Media(url: server.url)
      let player = Player(instance: instance)
      defer { player.stop() }

      do {
        try player.play(media)
      } catch {
        // The zero-byte response is not meaningful media; this test is
        // about the auth dialog surfaced before playback fails.
      }

      let event = try #require(
        await firstDialog(from: handler.dialogs, timeout: .seconds(8)),
        "Expected libVLC to emit a login dialog for the HTTP auth challenge"
      )

      guard case .login(let request) = event else {
        Issue.record("Expected login dialog, got \(event)")
        return
      }

      #expect(request.title.isEmpty == false)
      #expect(request.defaultUsername.isEmpty)
      #expect(request.post(username: "swift", password: "vlc"))

      try #require(await poll(every: .milliseconds(10), timeout: .seconds(3)) {
        server.sawAuthorizedRequest
      }, "Expected libVLC to retry the request with posted credentials")
    }

    @Test(.tags(.async, .media), .timeLimit(.minutes(1)))
    @MainActor
    func `HTTP auth login dialog can be dismissed`() async throws {
      let server = try BasicAuthProbeServer()
      defer { server.stop() }

      let instance = TestInstance.shared
      let handler = DialogHandler(instance: instance)
      let media = try Media(url: server.url)
      let player = Player(instance: instance)
      defer { player.stop() }

      do {
        try player.play(media)
      } catch {
        // The challenge should be delivered before playback ultimately fails.
      }

      let event = try #require(
        await firstDialog(from: handler.dialogs, timeout: .seconds(8)),
        "Expected libVLC to emit a login dialog for the HTTP auth challenge"
      )

      guard case .login(let request) = event else {
        Issue.record("Expected login dialog, got \(event)")
        return
      }

      #expect(request.dismiss())
    }
  }
}

private func firstDialog(
  from stream: AsyncStream<DialogEvent>,
  timeout: Duration
)
  async -> DialogEvent? {
  await withTaskGroup(of: DialogEvent?.self) { group in
    group.addTask {
      var iterator = stream.makeAsyncIterator()
      return await iterator.next()
    }
    group.addTask {
      try? await Task.sleep(for: timeout)
      return nil
    }

    let result = await group.next() ?? nil
    group.cancelAll()
    return result
  }
}

private final class BasicAuthProbeServer: @unchecked Sendable {
  private static let expectedAuthorization = "Authorization: Basic c3dpZnQ6dmxj"

  private let socketFD: Int32
  private let queue = DispatchQueue(label: "swiftvlc.basic-auth-probe")
  private let state = StateBox()

  let url: URL

  var sawAuthorizedRequest: Bool {
    state.sawAuthorizedRequest
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
    url = URL(string: "http://127.0.0.1:\(port)/protected.mp4")!

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
      if client < 0 {
        return
      }
      handle(client: client, state: state)
      close(client)
    }
  }

  private static func handle(client: Int32, state: StateBox) {
    let request = readRequest(from: client)
    let authorized = request.localizedCaseInsensitiveContains(expectedAuthorization)
    if authorized {
      state.mutex.withLock { $0.sawAuthorizedRequest = true }
    }

    let response = authorized
      ? httpResponse(
        status: "HTTP/1.1 200 OK",
        headers: [
          "Content-Type: video/mp4",
          "Content-Length: 0",
          "Connection: close"
        ]
      )
      : httpResponse(
        status: "HTTP/1.1 401 Unauthorized",
        headers: [
          "WWW-Authenticate: Basic realm=\"SwiftVLC\"",
          "Content-Length: 0",
          "Connection: close"
        ]
      )
    response.withCString { pointer in
      _ = write(client, pointer, strlen(pointer))
    }
  }

  private static func httpResponse(status: String, headers: [String]) -> String {
    ([status] + headers).joined(separator: "\r\n") + "\r\n\r\n"
  }

  private static func readRequest(from client: Int32) -> String {
    var bytes: [UInt8] = []
    var buffer = [UInt8](repeating: 0, count: 1024)

    while bytes.count < 16 * 1024 {
      let count = recv(client, &buffer, buffer.count, 0)
      guard count > 0 else { break }
      bytes.append(contentsOf: buffer.prefix(count))
      if bytes.containsCRLFCRLF {
        break
      }
    }

    return String(bytes: bytes, encoding: .utf8) ?? ""
  }

  private struct State: @unchecked Sendable {
    var isStopped = false
    var sawAuthorizedRequest = false
  }

  private final class StateBox: @unchecked Sendable {
    let mutex = Mutex(State())

    var sawAuthorizedRequest: Bool {
      mutex.withLock { $0.sawAuthorizedRequest }
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
