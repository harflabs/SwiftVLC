@testable import SwiftVLC
import CLibVLC
import Darwin
import Foundation
import Synchronization
import Testing

final class SeekVideoSink: @unchecked Sendable {
  struct Sample: Sendable {
    let pts: Int64
    let frame: Int
    let wall: TimeInterval
  }

  let samples = Mutex<[Sample]>([])
  var latest: Sample? {
    samples.withLock { $0.last }
  }

  var count: Int {
    samples.withLock { $0.count }
  }

  func record(_ pts: Int64, surface: SeekVideoSurface) {
    let (pitch, width, height) = (surface.pitch, surface.width, surface.height)
    let bytes = surface.pixels.assumingMemoryBound(to: UInt8.self)
    var frame = 0
    for bit in 0..<16 {
      let offset = min(32, height - 1) * pitch + ((bit * 2 + 1) * width / 32) * 4
      let sum = Int(bytes[offset]) + Int(bytes[offset + 1]) + Int(bytes[offset + 2])
      if sum > 384 {
        frame |= 1 << bit
      }
    }
    samples.withLock { $0.append(Sample(pts: pts, frame: frame, wall: Date.timeIntervalSinceReferenceDate)) }
  }
}

final class SeekVideoSurface {
  let sink: SeekVideoSink
  let pixels: UnsafeMutableRawPointer
  let pitch: Int
  let width: Int
  let height: Int
  init(sink: SeekVideoSink, pitch: Int, width: Int, height: Int) {
    self.sink = sink; self.pitch = pitch; self.width = width; self.height = height
    pixels = .allocate(byteCount: pitch * height, alignment: 64)
  }

  deinit { pixels.deallocate() }
}

func seekVideoLock(_ opaque: UnsafeMutableRawPointer?, _ planes: UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> UnsafeMutableRawPointer? {
  guard let opaque else { return nil }
  let surface = Unmanaged<SeekVideoSurface>.fromOpaque(opaque).takeUnretainedValue()
  planes?[0] = surface.pixels
  return opaque
}

func seekVideoSetup(_ opaque: UnsafeMutablePointer<UnsafeMutableRawPointer?>?, _ chroma: UnsafeMutablePointer<CChar>?, _ geometry: UnsafePointer<swiftvlc_video_format_geometry_t>?, _ width: UnsafeMutablePointer<UInt32>?, _ height: UnsafeMutablePointer<UInt32>?, _ pitches: UnsafeMutablePointer<UInt32>?, _ lines: UnsafeMutablePointer<UInt32>?) -> UInt32 {
  guard let raw = opaque?.pointee, let geometry, let width, let height, let chroma, let pitches, let lines else { return 0 }
  let sink = Unmanaged<SeekVideoSink>.fromOpaque(raw).takeUnretainedValue()
  width.pointee = geometry.pointee.visible_width
  height.pointee = geometry.pointee.visible_height
  pitches[0] = (width.pointee * 4 + 63) & ~63
  lines[0] = height.pointee
  for (i, c) in "RV32".utf8.enumerated() {
    chroma[i] = CChar(c)
  }
  let surface = SeekVideoSurface(sink: sink, pitch: Int(pitches[0]), width: Int(width.pointee), height: Int(height.pointee))
  opaque?.pointee = Unmanaged.passRetained(surface).toOpaque()
  return 1
}

func seekVideoCleanup(_ opaque: UnsafeMutableRawPointer?) {
  guard let opaque else { return }
  Unmanaged<SeekVideoSurface>.fromOpaque(opaque).release()
}

func seekVideoDisplay(_ opaque: UnsafeMutableRawPointer?, _ picture: UnsafeMutableRawPointer?, _ pts: Int64) -> Int32 {
  guard let opaque, opaque == picture else { return -22 }
  let surface = Unmanaged<SeekVideoSurface>.fromOpaque(opaque).takeUnretainedValue()
  surface.sink.record(pts, surface: surface)
  return 0
}

@MainActor
func installSeekVideoSink(_ sink: SeekVideoSink, on player: Player) throws {
  let raw = Unmanaged.passUnretained(sink).toOpaque()
  try #require(swiftvlc_libvlc_video_set_callbacks_atomic_v2(
    player.pointer, seekVideoLock, nil, nil, seekVideoDisplay,
    seekVideoSetup, seekVideoCleanup, raw
  ) == 0)
}
