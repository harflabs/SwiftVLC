@testable import SwiftVLC
import Darwin
import Foundation
import Synchronization
import Testing

extension Integration {
  @Suite(
    .tags(.mainActor, .async, .media),
    .serialized,
    .enabled(if: TestCondition.canPlayMedia, "Requires the rebuilt release XCFramework")
  )
  @MainActor struct RemoteMP4SeekTests {
    @Test(.timeLimit(.minutes(1)))
    func `Remote MP4 seek requests the target range and resumes near the target`() async throws {
      let fixtureURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Showcase/UITests/iOS/Fixtures/test.mp4")
      let fixture = try Data(contentsOf: fixtureURL)
      let server = try MP4RangeProbeServer(data: fixture)
      defer { server.stop() }

      let instance = try VLCInstance(
        arguments: VLCInstance.defaultArguments + [
          "--vout=dummy",
          "--aout=dummy",
          "--no-hw-dec",
          "--quiet"
        ]
      )
      let player = Player(instance: instance)
      defer { player.stop() }

      try player.play(url: server.url)
      try #require(
        await poll(every: .milliseconds(50), timeout: .seconds(10)) {
          player.state == .playing && player.isSeekable
        },
        "Waiting for remote MP4 playback to become seekable"
      )

      let nativeLanding = subscribeAndAwaitTime(atLeast: .seconds(34), on: player)
      try player.seek(to: .seconds(36), fast: false)
      let landedTime = try #require(
        await nativeLanding.value,
        "Waiting for a native time event near the 36 second seek target"
      )

      let targetRangeThreshold = fixture.count / 3
      try #require(
        await poll(every: .milliseconds(50), timeout: .seconds(5)) {
          server.rangeStarts.contains { $0 > targetRangeThreshold }
        },
        "Expected a discontinuous HTTP range request after seeking, observed starts: \(server.rangeStarts)"
      )
      #expect(landedTime >= .seconds(34))
    }

    private func subscribeAndAwaitTime(
      atLeast minimum: Duration,
      on player: Player,
      timeout: Duration = .seconds(8)
    ) -> Task<Duration?, Never> {
      let events = player.events
      return Task.detached { @Sendable in
        await withTaskGroup(of: Duration?.self) { group in
          group.addTask {
            for await event in events {
              if case .timeChanged(let time) = event, time >= minimum {
                return time
              }
            }
            return nil
          }
          group.addTask {
            try? await Task.sleep(for: timeout)
            return nil
          }
          let first = await group.next() ?? nil
          group.cancelAll()
          return first
        }
      }
    }
  }
}

private final class MP4RangeProbeServer: Sendable {
  private let socketFD: Int32
  private let acceptQueue = DispatchQueue(label: "swiftvlc.mp4-range.accept")
  private let clientQueue = DispatchQueue(
    label: "swiftvlc.mp4-range.clients",
    attributes: .concurrent
  )
  private let state = StateBox()
  private let data: Data

  let url: URL

  var rangeStarts: [Int] {
    state.mutex.withLock { $0.rangeStarts }
  }

  init(data: Data) throws {
    self.data = data

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

    guard listen(fd, 8) == 0 else {
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
    url = URL(string: "http://127.0.0.1:\(port)/seek-fixture.mp4")!

    acceptQueue.async { [fd, data, state, clientQueue] in
      Self.acceptLoop(socketFD: fd, data: data, state: state, clientQueue: clientQueue)
    }
  }

  deinit {
    stop()
  }

  func stop() {
    let clients = state.mutex.withLock { state -> [Int32]? in
      guard !state.isStopped else { return nil }
      state.isStopped = true
      return Array(state.clients)
    }
    guard let clients else { return }
    shutdown(socketFD, SHUT_RDWR)
    close(socketFD)
    for client in clients {
      shutdown(client, SHUT_RDWR)
    }
  }

  private static func acceptLoop(
    socketFD: Int32,
    data: Data,
    state: StateBox,
    clientQueue: DispatchQueue
  ) {
    while true {
      let client = accept(socketFD, nil, nil)
      if client < 0 {
        return
      }

      var noSignal: Int32 = 1
      setsockopt(
        client,
        SOL_SOCKET,
        SO_NOSIGPIPE,
        &noSignal,
        socklen_t(MemoryLayout<Int32>.size)
      )

      let accepted = state.mutex.withLock { state -> Bool in
        guard !state.isStopped else { return false }
        state.clients.insert(client)
        return true
      }
      guard accepted else {
        close(client)
        return
      }

      clientQueue.async {
        handle(client: client, data: data, state: state)
        _ = state.mutex.withLock { $0.clients.remove(client) }
        shutdown(client, SHUT_RDWR)
        close(client)
      }
    }
  }

  private static func handle(client: Int32, data: Data, state: StateBox) {
    let request = readRequest(from: client)
    let method = request.prefix { !$0.isWhitespace }
    let requested = requestedRange(in: request, length: data.count)
    let start = requested?.lowerBound ?? 0
    let end = requested?.upperBound ?? (data.count - 1)
    state.mutex.withLock { $0.rangeStarts.append(start) }

    guard start >= 0, start < data.count, end >= start else {
      _ = sendAll(Data("HTTP/1.1 416 Range Not Satisfiable\r\nConnection: close\r\n\r\n".utf8), to: client)
      return
    }

    let responseLength = end - start + 1
    var headers = [
      requested == nil ? "HTTP/1.1 200 OK" : "HTTP/1.1 206 Partial Content",
      "Accept-Ranges: bytes",
      "Content-Type: video/mp4",
      "Content-Length: \(responseLength)",
      "Connection: close"
    ]
    if requested != nil {
      headers.append("Content-Range: bytes \(start)-\(end)/\(data.count)")
    }
    let headerData = Data((headers.joined(separator: "\r\n") + "\r\n\r\n").utf8)
    guard sendAll(headerData, to: client), method != "HEAD" else { return }

    let chunkSize = 4 * 1024
    var offset = start
    while offset <= end {
      if state.mutex.withLock({ $0.isStopped }) {
        return
      }
      let chunkEnd = min(offset + chunkSize - 1, end)
      guard sendRange(data, range: offset...chunkEnd, to: client) else { return }
      offset = chunkEnd + 1
      usleep(20000)
    }
  }

  private static func requestedRange(in request: String, length: Int) -> ClosedRange<Int>? {
    for line in request.components(separatedBy: "\r\n") {
      guard line.lowercased().hasPrefix("range:") else { continue }
      let value = line.dropFirst("range:".count).trimmingCharacters(in: .whitespaces)
      guard value.lowercased().hasPrefix("bytes=") else { return nil }
      let bounds = value.dropFirst("bytes=".count).split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
      guard let first = bounds.first, let start = Int(first), start < length else { return nil }
      let requestedEnd = bounds.count == 2 ? Int(bounds[1]) : nil
      return start...min(requestedEnd ?? (length - 1), length - 1)
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
      if bytes.containsMP4ProbeHeaderTerminator {
        break
      }
    }
    return String(bytes: bytes, encoding: .utf8) ?? ""
  }

  private static func sendAll(_ data: Data, to client: Int32) -> Bool {
    data.withUnsafeBytes { bytes in
      guard let baseAddress = bytes.baseAddress else { return true }
      var sent = 0
      while sent < bytes.count {
        let result = Darwin.send(client, baseAddress.advanced(by: sent), bytes.count - sent, 0)
        if result < 0, errno == EINTR {
          continue
        }
        guard result > 0 else { return false }
        sent += result
      }
      return true
    }
  }

  private static func sendRange(_ data: Data, range: ClosedRange<Int>, to client: Int32) -> Bool {
    data.withUnsafeBytes { bytes in
      guard let baseAddress = bytes.baseAddress else { return true }
      var sent = 0
      let count = range.count
      while sent < count {
        let result = Darwin.send(
          client,
          baseAddress.advanced(by: range.lowerBound + sent),
          count - sent,
          0
        )
        if result < 0, errno == EINTR {
          continue
        }
        guard result > 0 else { return false }
        sent += result
      }
      return true
    }
  }

  private struct State: Sendable {
    var isStopped = false
    var clients: Set<Int32> = []
    var rangeStarts: [Int] = []
  }

  private final class StateBox: Sendable {
    let mutex = Mutex(State())
  }
}

extension [UInt8] {
  fileprivate var containsMP4ProbeHeaderTerminator: Bool {
    guard count >= 4 else { return false }
    return indices.dropFirst(3).contains { index in
      self[index - 3] == 13
        && self[index - 2] == 10
        && self[index - 1] == 13
        && self[index] == 10
    }
  }
}
