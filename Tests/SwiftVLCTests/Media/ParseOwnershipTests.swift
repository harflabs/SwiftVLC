@testable import SwiftVLC
import CLibVLC
import Foundation
import Network
import Synchronization
import Testing

extension Integration {
  @Suite(.tags(.media, .async), .timeLimit(.minutes(1)))
  @MainActor struct ParseOwnershipTests {
    @Test
    func `A pre-cancelled caller does not stop the active native parse`() async throws {
      let server = try DelayedParseServer(body: Data(contentsOf: TestMedia.twosecURL))
      defer { server.stop() }
      let media = try Media(url: server.url)
      let instance = TestInstance.makeAudioOnly()
      let first = Task { try await media.parse(timeout: .seconds(10), instance: instance) }
      let deadline = ContinuousClock.now + .seconds(5)
      while !server.hasRequest && ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
      }
      try #require(server.hasRequest)
      #expect(libvlc_media_get_parsed_status(media.pointer) == libvlc_media_parsed_status_pending)
      // The task inherits MainActor, so cancellation precedes its first step.
      let second = Task { try await media.parse(timeout: .seconds(10), instance: instance) }
      second.cancel()
      if case .success = await second.result {
        Issue.record("Expected cancellation")
      }
      #expect(libvlc_media_get_parsed_status(media.pointer) == libvlc_media_parsed_status_pending)
      server.releaseResponse()
      _ = try await first.value
      #expect(libvlc_media_get_parsed_status(media.pointer) == libvlc_media_parsed_status_done)
    }
  }
}

/// A loopback HTTP fixture whose response is explicitly released by the test.
private final class DelayedParseServer: @unchecked Sendable {
  private let listener: NWListener
  private let queue = DispatchQueue(label: "swiftvlc.delayed-parse-fixture")
  private let received = Mutex(false)
  private let response: Data
  // Only queue accesses these fields.
  private var pending: [NWConnection] = []
  private var released = false
  var url: URL {
    URL(string: "http://127.0.0.1:\(listener.port!.rawValue)/twosec.mp4")!
  }

  var hasRequest: Bool {
    received.withLock { $0 }
  }

  init(body: Data) throws {
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
    listener = try NWListener(using: parameters)
    let ready = DispatchSemaphore(value: 0)
    listener.stateUpdateHandler = { state in
      if case .ready = state {
        ready.signal()
      }
      if case .failed = state {
        ready.signal()
      }
    }
    response = Data("HTTP/1.1 200 OK\r\nContent-Type: video/mp4\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8) + body
    listener.newConnectionHandler = { [weak self] connection in
      guard let self else { connection.cancel(); return }
      connection.start(queue: queue)
      connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, _, _ in
        guard let self, data?.isEmpty == false else { connection.cancel(); return }
        received.withLock { $0 = true }
        if released {
          send(to: connection)
        } else {
          pending.append(connection)
        }
      }
    }
    listener.start(queue: queue)
    guard ready.wait(timeout: .now() + 5) == .success, listener.port != nil else {
      listener.cancel()
      throw VLCError.operationFailed("Start loopback parse fixture")
    }
  }

  func releaseResponse() {
    queue.async {
      self.released = true
      for connection in self.pending {
        self.send(to: connection)
      }
      self.pending.removeAll()
    }
  }

  func stop() {
    listener.cancel()
    queue.async {
      for connection in self.pending {
        connection.cancel()
      }
      self.pending.removeAll()
    }
  }

  private func send(to connection: NWConnection) {
    connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
  }
}
