// A/V ground-truth harness for SwiftVLC on macOS.
//
// Plays a fixture whose frames carry a 20-bit frame-index barcode, renders it
// through the real macOS output (VLC samplebufferdisplay in an NSWindow), and
// samples at ~250 Hz:
//   * the frame actually on screen (AVSampleBufferVideoRenderer
//     copyDisplayedPixelBuffer, decoded barcode)
//   * VLC's audio-master player time (libvlc_media_player_get_time)
// plus periodic VLC statistics, renderer state, libVLC events and a full
// debug log.  Output: JSON lines (one object per line).
//
// Modes:  --mode swiftvlc   SwiftVLC Player + VideoView/PiPVideoView (prod path)
//         --mode raw        bare libVLC C API + NSView drawable (no wrapper)

import AppKit
import AVFoundation
import CLibVLC
import CoreVideo
import SwiftUI
@_spi(PrivateMacOSPiP) @testable import SwiftVLC

// MARK: - Configuration

struct Config {
  var mode = "swiftvlc"
  var url = ""
  var scenario = "pauses"
  var out = "/dev/stdout"
  var log = ""
  var tracer = ""
  var pauses: [Double] = [0.5, 2, 5, 15]
  var cycles = 2
  var settle = 6.0
  var after = 6.0
  var duration = 60.0
  var view = "pip"
  var extraArgs: [String] = []
  var hiddenSecs = 10.0
  var sampleHz = 250.0
  var frames: [Int] = []
  var pauseDur = 3.0
  var pauseDurs: [Double] = []
  var attachDelay = 0.0

  static func parse() -> Config {
    var c = Config()
    var it = CommandLine.arguments.dropFirst().makeIterator()
    while let a = it.next() {
      func v() -> String { it.next() ?? "" }
      switch a {
      case "--mode": c.mode = v()
      case "--url": c.url = v()
      case "--scenario": c.scenario = v()
      case "--out": c.out = v()
      case "--log": c.log = v()
      case "--tracer": c.tracer = v()
      case "--pauses": c.pauses = v().split(separator: ",").compactMap { Double($0) }
      case "--cycles": c.cycles = Int(v()) ?? 2
      case "--settle": c.settle = Double(v()) ?? 6
      case "--after": c.after = Double(v()) ?? 6
      case "--duration": c.duration = Double(v()) ?? 60
      case "--view": c.view = v()
      case "--arg": c.extraArgs.append(v())
      case "--hidden": c.hiddenSecs = Double(v()) ?? 10
      case "--hz": c.sampleHz = Double(v()) ?? 250
      case "--frames": c.frames = v().split(separator: ",").compactMap { Int($0) }
      case "--pausedur": c.pauseDur = Double(v()) ?? 3
      case "--attach-delay": c.attachDelay = Double(v()) ?? 0
      case "--pausedurs": c.pauseDurs = v().split(separator: ",").compactMap { Double($0) }
      default: fputs("unknown arg \(a)\n", stderr); exit(2)
      }
    }
    return c
  }
}

let config = Config.parse()

// MARK: - Recorder

final class Recorder: @unchecked Sendable {
  private let fh: FileHandle
  private let lock = NSLock()
  private var buffer = Data()

  init(path: String) {
    if path == "/dev/stdout" {
      fh = FileHandle.standardOutput
    } else {
      FileManager.default.createFile(atPath: path, contents: nil)
      fh = FileHandle(forWritingAtPath: path)!
    }
  }

  func write(_ obj: [String: Any]) {
    guard let d = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return }
    lock.lock()
    buffer.append(d)
    buffer.append(0x0A)
    if buffer.count > 256 * 1024 { fh.write(buffer); buffer.removeAll(keepingCapacity: true) }
    lock.unlock()
  }

  func flush() {
    lock.lock()
    if !buffer.isEmpty { fh.write(buffer); buffer.removeAll(keepingCapacity: true) }
    lock.unlock()
  }
}

let rec = Recorder(path: config.out)
@inline(__always) func now() -> Int64 { libvlc_clock() }  // µs, same base as VLC's vlc_tick_now()

func mark(_ name: String, _ extra: [String: Any] = [:]) {
  var o: [String: Any] = ["k": "m", "t": now(), "n": name]
  for (k, v) in extra { o[k] = v }
  rec.write(o)
  fputs("[\(String(format: "%.3f", Double(now()) / 1e6))] \(name) \(extra)\n", stderr)
}

// MARK: - libVLC log capture (pre-formatted via SwiftVLC's C shim)

final class LogSink: @unchecked Sendable {
  let fh: FileHandle
  let lock = NSLock()
  init?(path: String) {
    guard !path.isEmpty else { return nil }
    FileManager.default.createFile(atPath: path, contents: nil)
    guard let h = FileHandle(forWritingAtPath: path) else { return nil }
    fh = h
  }
  func write(_ s: String) {
    lock.lock(); fh.write(s.data(using: .utf8)!); lock.unlock()
  }
}

let logSink = LogSink(path: config.log)
let logCallback: swiftvlc_log_cb = { data, level, module, message in
  guard let logSink else { return }
  let m = module.map { String(cString: $0) } ?? "-"
  let msg = message.map { String(cString: $0) } ?? ""
  logSink.write("\(libvlc_clock()) L\(level) [\(m)] \(msg)\n")
}

// MARK: - Barcode decoding from the displayed pixel buffer

func decodeFrameIndex(_ pb: CVPixelBuffer) -> Int {
  CVPixelBufferLockBaseAddress(pb, .readOnly)
  defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
  let fmt = CVPixelBufferGetPixelFormatType(pb)
  let planar = CVPixelBufferIsPlanar(pb)
  let w = planar ? CVPixelBufferGetWidthOfPlane(pb, 0) : CVPixelBufferGetWidth(pb)
  let h = planar ? CVPixelBufferGetHeightOfPlane(pb, 0) : CVPixelBufferGetHeight(pb)
  guard let base = planar ? CVPixelBufferGetBaseAddressOfPlane(pb, 0) : CVPixelBufferGetBaseAddress(pb) else { return -3 }
  let bpr = planar ? CVPixelBufferGetBytesPerRowOfPlane(pb, 0) : CVPixelBufferGetBytesPerRow(pb)
  let y = h * 36 / 360
  var value = 0
  for bit in 0..<20 {
    let x = (bit * 32 + 16) * w / 640
    var luma: Int
    switch fmt {
    case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
         kCVPixelFormatType_420YpCbCr8Planar, kCVPixelFormatType_420YpCbCr8PlanarFullRange:
      luma = Int(base.load(fromByteOffset: y * bpr + x, as: UInt8.self))
    case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr10BiPlanarFullRange:
      luma = Int(base.load(fromByteOffset: y * bpr + x * 2, as: UInt16.self)) >> 8
    case kCVPixelFormatType_32BGRA:
      luma = Int(base.load(fromByteOffset: y * bpr + x * 4 + 1, as: UInt8.self))
    default:
      return -4
    }
    if luma > 128 { value |= 1 << bit }
  }
  return value
}

// MARK: - Display layer discovery

final class RendererBox: @unchecked Sendable {
  private let lock = NSLock()
  private weak var _layer: AVSampleBufferDisplayLayer?
  var layer: AVSampleBufferDisplayLayer? {
    get { lock.lock(); defer { lock.unlock() }; return _layer }
    set { lock.lock(); _layer = newValue; lock.unlock() }
  }
}

let rendererBox = RendererBox()

final class FrameBox: @unchecked Sendable {
  private let lock = NSLock()
  private var _f = -9
  var value: Int {
    get { lock.lock(); defer { lock.unlock() }; return _f }
    set { lock.lock(); _f = newValue; lock.unlock() }
  }
}
let latestFrame = FrameBox()

func findSampleBufferLayer(_ view: NSView) -> AVSampleBufferDisplayLayer? {
  if let l = view.layer as? AVSampleBufferDisplayLayer { return l }
  if let sl = view.layer?.sublayers {
    for s in sl { if let l = s as? AVSampleBufferDisplayLayer { return l } }
  }
  for sv in view.subviews { if let l = findSampleBufferLayer(sv) { return l } }
  return nil
}

// MARK: - Engine abstraction (raw libVLC vs SwiftVLC)

let vlcArgs: [String] = [
  "--no-video-title-show", "--no-snapshot-preview",
  "--http-reconnect", "--network-caching=1500", "--live-caching=1500", "--drop-late-frames",
  "--verbose=2"
] + (config.tracer.isEmpty ? [] : ["--tracer=json", "--json-tracer-file=\(config.tracer)"]) + config.extraArgs

@MainActor protocol Engine: AnyObject {
  var mp: OpaquePointer { get }
  func start(window: NSWindow) throws
  func pause()
  func resume()
  func seek(ms: Int64)
}

@MainActor final class RawEngine: Engine {
  let instance: OpaquePointer
  let mp: OpaquePointer
  var view: NSView!
  var logCtx: UnsafeMutableRawPointer?

  init() {
    var cargs = vlcArgs.map { strdup($0) }
    let inst = cargs.withUnsafeMutableBufferPointer { buf -> OpaquePointer? in
      buf.baseAddress!.withMemoryRebound(to: UnsafePointer<CChar>?.self, capacity: buf.count) {
        libvlc_new(Int32(buf.count), $0)
      }
    }
    cargs.forEach { free($0) }
    guard let inst else { fatalError("libvlc_new failed") }
    instance = inst
    if logSink != nil { logCtx = swiftvlc_log_set(inst, logCallback, nil) }
    mp = libvlc_media_player_new(inst)!
  }

  func start(window: NSWindow) throws {
    let v = NSView(frame: window.contentView!.bounds)
    v.wantsLayer = true
    v.autoresizingMask = [.width, .height]
    window.contentView!.addSubview(v)
    view = v
    libvlc_media_player_set_nsobject(mp, Unmanaged.passUnretained(v).toOpaque())
    let media: OpaquePointer
    if config.url.hasPrefix("/") {
      media = libvlc_media_new_path(config.url)!
    } else {
      media = libvlc_media_new_location(config.url)!
    }
    libvlc_media_player_set_media(mp, media)
    libvlc_media_release(media)
    attachEvents(mp)
    libvlc_media_player_play(mp)
  }

  func pause() { libvlc_media_player_set_pause(mp, 1) }
  func resume() { libvlc_media_player_set_pause(mp, 0) }
  func seek(ms: Int64) { libvlc_media_player_set_time(mp, ms, false) }
}

@MainActor final class SwiftVLCEngine: Engine {
  let instance: VLCInstance
  let player: Player
  var mp: OpaquePointer { player.pointer }

  init() throws {
    instance = try VLCInstance(
      arguments: vlcArgs, applicationName: "avh", httpUserAgent: "VLC/4.0.0 LibVLC/4.0.0",
      appleAudioSessionPolicy: .applicationManaged)
    if logSink != nil { _ = swiftvlc_log_set(instance.pointer, logCallback, nil) }
    player = Player(instance: instance)
    player.role = .video
  }

  func start(window: NSWindow) throws {
    let p = player
    let attachView = {
      if config.view == "pip" {
        PiPController.allowsPrivateMacOSAPI = true
        window.contentView = NSHostingView(rootView: PiPHost(player: p))
      } else {
        window.contentView = NSHostingView(rootView: VideoView(p))
      }
      mark("view_attached", ["view": config.view])
    }
    if config.attachDelay <= 0 {
      attachView()
      // Avoid the play-before-drawable race: wait for SwiftVLC to mount the surface.
      window.contentView?.layoutSubtreeIfNeeded()
      var spins = 0
      func drawableInWindow() -> Bool {
        guard let raw = libvlc_media_player_get_nsobject(p.pointer) else { return false }
        let obj = Unmanaged<AnyObject>.fromOpaque(raw).takeUnretainedValue()
        return (obj as? NSView)?.window != nil
      }
      let inWindowAtStart = drawableInWindow()
      while !drawableInWindow() && spins < 200 {
        RunLoop.main.run(until: Date().addingTimeInterval(0.01)); spins += 1
      }
      mark("drawable_ready", ["spins": spins, "in_window_at_start": inWindowAtStart, "ready": drawableInWindow()])
    }
    let media = config.url.hasPrefix("/") ? try Media(url: URL(fileURLWithPath: config.url)) : try Media(url: URL(string: config.url)!)
    attachEvents(mp)
    try player.play(media)
    if config.attachDelay > 0 {
      DispatchQueue.main.asyncAfter(deadline: .now() + config.attachDelay) { attachView() }
    }
  }

  // Mirrors tilfaz VLCPlayerClient.pause()/play().
  func pause() { player.pause() }
  func resume() {
    switch player.nativePlaybackState {
    case .paused: player.resume()
    case .playing, .opening, .buffering: if !player.isPlaying { player.resume() }
    default: try? player.play()
    }
  }
  // Mirrors tilfaz VLCPlayerClient.seek(to:) precise path (strict position seek).
  func seek(ms: Int64) {
    guard let d = player.duration else { return }
    let pos = max(0, min(1, Double(ms) / (Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15)))
    _ = try? player.requestSeek(to: PlaybackPosition(pos), fast: false)
  }
}

@MainActor final class PiPBox { static var controller: PiPController? }

struct PiPHost: View {
  let player: Player
  var body: some View {
    PiPVideoView(player, controller: Binding(get: { PiPBox.controller }, set: { PiPBox.controller = $0 }))
  }
}

// MARK: - libVLC events (an extra observer alongside SwiftVLC's own)

let eventCallback: libvlc_callback_t = { eventPtr, _ in
  guard let e = eventPtr?.pointee else { return }
  var o: [String: Any] = ["k": "e", "t": libvlc_clock(), "type": Int(e.type)]
  switch libvlc_event_e(rawValue: UInt32(e.type)) {
  case libvlc_MediaPlayerBuffering: o["name"] = "buffering"; o["cache"] = Double(e.u.media_player_buffering.new_cache)
  case libvlc_MediaPlayerPlaying: o["name"] = "playing"
  case libvlc_MediaPlayerPaused: o["name"] = "paused"
  case libvlc_MediaPlayerStopped: o["name"] = "stopped"
  case libvlc_MediaPlayerEncounteredError: o["name"] = "error"
  case libvlc_MediaPlayerVout: o["name"] = "vout"; o["count"] = Int(e.u.media_player_vout.new_count)
  case libvlc_MediaPlayerESSelected: o["name"] = "es_selected"
  case libvlc_MediaPlayerESAdded: o["name"] = "es_added"
  case libvlc_MediaPlayerCorked: o["name"] = "corked"
  case libvlc_MediaPlayerUncorked: o["name"] = "uncorked"
  case libvlc_MediaPlayerAudioDevice: o["name"] = "audio_device"
  case libvlc_MediaPlayerSeekableChanged: o["name"] = "seekable"
  default: return
  }
  rec.write(o)
}

func attachEvents(_ mp: OpaquePointer) {
  guard let em = libvlc_media_player_event_manager(mp) else { return }
  for t in [libvlc_MediaPlayerBuffering, libvlc_MediaPlayerPlaying, libvlc_MediaPlayerPaused,
            libvlc_MediaPlayerStopped, libvlc_MediaPlayerEncounteredError, libvlc_MediaPlayerVout,
            libvlc_MediaPlayerESSelected, libvlc_MediaPlayerESAdded, libvlc_MediaPlayerCorked,
            libvlc_MediaPlayerUncorked, libvlc_MediaPlayerAudioDevice, libvlc_MediaPlayerSeekableChanged] {
    libvlc_event_attach(em, Int32(t.rawValue), eventCallback, nil)
  }
}

// MARK: - Sampler

final class Sampler: @unchecked Sendable {
  let mp: OpaquePointer
  var running = true
  var thread: Thread?

  init(mp: OpaquePointer) { self.mp = mp }

  func start() {
    let t = Thread { [self] in self.loop() }
    t.qualityOfService = .userInteractive
    t.name = "avh.sampler"
    thread = t
    t.start()
  }

  func loop() {
    let period = UInt32(1_000_000 / config.sampleHz)
    var lastStats: Int64 = 0
    var lastFrame = -9
    var lastPB: UnsafeMutableRawPointer?
    while running {
      autoreleasepool {
        let t = now()
        var frame = -2
        var pbAddr: UnsafeMutableRawPointer?
        if let layer = rendererBox.layer {
          let renderer = layer.sampleBufferRenderer
          if let pb = renderer.displayedPixelBuffer() {
            frame = decodeFrameIndex(pb)
            pbAddr = Unmanaged.passUnretained(pb).toOpaque()
          } else {
            frame = -1
          }
        }
        let at = libvlc_media_player_get_time(mp)
        let st = Int(libvlc_media_player_get_state(mp).rawValue)
        // Always record at least 25 Hz; at full rate only when something changed.
        let changed = frame != lastFrame || pbAddr != lastPB
        if changed || t - lastStats >= 40_000 || true {
          rec.write(["k": "s", "t": t, "f": frame, "a": at, "st": st, "nb": pbAddr != lastPB ? 1 : 0])
        }
        lastFrame = frame
        lastPB = pbAddr
        if frame >= 0 { latestFrame.value = frame }
        if t - lastStats >= 500_000 {
          lastStats = t
          writeStats(t)
        }
      }
      usleep(period)
    }
  }

  func writeStats(_ t: Int64) {
    var o: [String: Any] = ["k": "x", "t": t]
    if let media = libvlc_media_player_get_media(mp) {
      var s = libvlc_media_stats_t()
      if libvlc_media_get_stats(media, &s) {
        o["dec_v"] = s.i_decoded_video; o["disp"] = s.i_displayed_pictures
        o["late"] = s.i_late_pictures; o["lost"] = s.i_lost_pictures
        o["dec_a"] = s.i_decoded_audio; o["play_a"] = s.i_played_abuffers; o["lost_a"] = s.i_lost_abuffers
        o["disc"] = s.i_demux_discontinuity; o["corrupt"] = s.i_demux_corrupted
        o["rd"] = s.i_read_bytes; o["drd"] = s.i_demux_read_bytes
      }
      libvlc_media_release(media)
    }
    o["rate"] = libvlc_media_player_get_rate(mp)
    o["pos"] = libvlc_media_player_get_position(mp)
    if let layer = rendererBox.layer {
      let r = layer.sampleBufferRenderer
      o["r_status"] = r.status.rawValue
      o["r_ready"] = r.isReadyForMoreMediaData
      o["r_flush"] = r.requiresFlushToResumeDecoding
      if let err = r.error as NSError? { o["r_err"] = err.code }
      o["layer_hidden"] = layer.isHidden
    } else {
      o["r_status"] = -1
    }
    rec.write(o)
  }
}

// MARK: - App + scenarios

@MainActor final class Harness: NSObject, NSApplicationDelegate {
  var window: NSWindow!
  var engine: Engine!
  var sampler: Sampler!

  func applicationDidFinishLaunching(_ notification: Notification) {
    window = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 960, height: 540),
                      styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
    window.title = "avh \(config.mode) \(config.scenario)"
    window.contentView = NSView(frame: window.contentRect(forFrameRect: window.frame))
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    do {
      engine = config.mode == "raw" ? RawEngine() : try SwiftVLCEngine()
      mark("config", ["mode": config.mode, "url": config.url, "scenario": config.scenario, "view": config.view,
                      "args": vlcArgs, "native": swiftvlc_libvlc_pip_extensions_version()])
      try engine.start(window: window)
    } catch {
      fputs("start failed: \(error)\n", stderr); exit(1)
    }
    sampler = Sampler(mp: engine.mp)
    sampler.start()
    // Re-scan for VLC's display layer periodically (it can be recreated).
    Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, let cv = self.window.contentView else { return }
        let found = findSampleBufferLayer(cv)
        if found !== rendererBox.layer {
          rendererBox.layer = found
          mark("layer", ["found": found != nil])
        }
      }
    }
    Task { @MainActor in
      await self.runScenario()
      self.finish()
    }
  }

  func sleep(_ s: Double) async { try? await Task.sleep(for: .milliseconds(Int(s * 1000))) }

  func waitPlaying(timeout: Double = 20) async {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if libvlc_media_player_get_state(engine.mp) == libvlc_Playing, rendererBox.layer != nil { return }
      await sleep(0.05)
    }
    mark("wait_playing_timeout")
  }

  func runScenario() async {
    await waitPlaying()
    mark("playing_ready")
    await sleep(config.settle)
    switch config.scenario {
    case "pauses":
      for d in config.pauses {
        for c in 0..<config.cycles {
          mark("pause_req", ["d": d, "cycle": c]); engine.pause()
          await sleep(d)
          mark("resume_req", ["d": d, "cycle": c]); engine.resume()
          await sleep(config.after)
        }
      }
    case "run":
      await sleep(config.duration)
    case "miniaturize":
      for c in 0..<config.cycles {
        mark("hide_req", ["how": "miniaturize", "cycle": c]); window.miniaturize(nil)
        await sleep(config.hiddenSecs)
        mark("show_req", ["how": "miniaturize", "cycle": c]); window.deminiaturize(nil)
        await sleep(config.after)
      }
    case "orderout":
      for c in 0..<config.cycles {
        mark("hide_req", ["how": "orderout", "cycle": c]); window.orderOut(nil)
        await sleep(config.hiddenSecs)
        mark("show_req", ["how": "orderout", "cycle": c]); window.makeKeyAndOrderFront(nil)
        await sleep(config.after)
      }
    case "occlude":
      for c in 0..<config.cycles {
        let cover = NSWindow(contentRect: window.frame.insetBy(dx: -40, dy: -40), styleMask: [.borderless], backing: .buffered, defer: false)
        cover.backgroundColor = .black; cover.isOpaque = true; cover.level = .floating
        mark("hide_req", ["how": "occlude", "cycle": c]); cover.orderFrontRegardless()
        await sleep(config.hiddenSecs)
        mark("show_req", ["how": "occlude", "cycle": c]); cover.orderOut(nil)
        await sleep(config.after)
      }
    case "audiodev":
      // Alternate VLC's own output device selection (no system setting change).
      var ids: [String] = []
      if let list = libvlc_audio_output_device_enum(engine.mp) {
        var p: UnsafeMutablePointer<libvlc_audio_output_device_t>? = list
        while let d = p {
          let id = String(cString: d.pointee.psz_device)
          let desc = String(cString: d.pointee.psz_description)
          mark("audio_device_listed", ["id": id, "desc": desc])
          ids.append(id)
          p = d.pointee.p_next
        }
        libvlc_audio_output_device_list_release(list)
      }
      let real = ids.filter { !$0.isEmpty && $0 != "0" }
      guard real.count >= 2 else { mark("audiodev_insufficient_devices", ["n": ids.count]); return }
      for c in 0..<config.cycles {
        for id in [real[1], real[0]] {
          mark("resume_req", ["how": "audiodev", "cycle": c, "id": id])
          libvlc_audio_output_device_set(engine.mp, id)
          await sleep(config.after)
        }
      }
    case "pause_hidden":
      // Pause, hide the window while paused, show again, resume.
      for d in config.pauses {
        for c in 0..<config.cycles {
          mark("pause_req", ["d": d, "cycle": c]); engine.pause()
          await sleep(0.5)
          window.miniaturize(nil)
          await sleep(d)
          window.deminiaturize(nil)
          await sleep(1.0)
          mark("resume_req", ["d": d, "cycle": c, "how": "pause_hidden"]); engine.resume()
          await sleep(config.after)
        }
      }
    case "hidden_pause":
      // Hide while playing, pause while hidden, resume while hidden, then show.
      for c in 0..<config.cycles {
        mark("hide_req", ["how": "hidden_pause", "cycle": c]); window.miniaturize(nil)
        await sleep(3)
        engine.pause()
        await sleep(config.hiddenSecs)
        engine.resume()
        await sleep(3)
        mark("show_req", ["how": "hidden_pause", "cycle": c]); window.deminiaturize(nil)
        await sleep(config.after)
      }
    case "pause_at_frames":
      for (i, target) in config.frames.enumerated() {
        let deadline = Date().addingTimeInterval(120)
        while latestFrame.value < target && Date() < deadline { await sleep(0.004) }
        let pd = config.pauseDurs.isEmpty ? config.pauseDur : config.pauseDurs[i % config.pauseDurs.count]
        mark("pause_req", ["d": pd, "cycle": i, "target": target, "frame": latestFrame.value]); engine.pause()
        await sleep(pd)
        mark("resume_req", ["d": pd, "cycle": i, "target": target]); engine.resume()
        await sleep(1.0)
      }
      await sleep(config.after)
    case "pseek_resume":
      // Paused seek, quick resume (before the bootstrap frame), later a long pause.
      for c in 0..<config.cycles {
        engine.pause(); await sleep(1.0)
        let now = libvlc_media_player_get_time(engine.mp)
        mark("pseek", ["cycle": c, "to": now + 8000]); engine.seek(ms: now + 8000)
        await sleep(0.1)
        mark("resume_req", ["cycle": c, "how": "after_pseek"]); engine.resume()
        await sleep(6)
        mark("pause_req", ["d": config.pauseDur, "cycle": c]); engine.pause()
        await sleep(config.pauseDur)
        mark("resume_req", ["d": config.pauseDur, "cycle": c, "how": "long_pause"]); engine.resume()
        await sleep(config.after)
      }
    case "resume_seek":
      // tilfaz local-file path: resume after >2 s pause, then resynchronizing precise seek to current time.
      for c in 0..<config.cycles {
        mark("pause_req", ["d": 5.0, "cycle": c]); engine.pause(); await sleep(5)
        mark("resume_req", ["d": 5.0, "cycle": c, "how": "resume_resync"]); engine.resume()
        engine.seek(ms: libvlc_media_player_get_time(engine.mp))
        await sleep(6)
        mark("pause_req", ["d": config.pauseDur, "cycle": c]); engine.pause()
        await sleep(config.pauseDur)
        mark("resume_req", ["d": config.pauseDur, "cycle": c, "how": "long_pause"]); engine.resume()
        await sleep(config.after)
      }
    case "reattach":
      // Remove the video view while playing, then attach a brand-new one.
      for c in 0..<config.cycles {
        mark("hide_req", ["how": "detach_view", "cycle": c])
        window.contentView = NSView(frame: window.contentRect(forFrameRect: window.frame))
        await sleep(config.hiddenSecs)
        mark("show_req", ["how": "new_view", "cycle": c])
        if let e = engine as? SwiftVLCEngine {
          let p = e.player
          if config.view == "pip" { window.contentView = NSHostingView(rootView: PiPHost(player: p)) }
          else { window.contentView = NSHostingView(rootView: VideoView(p)) }
        }
        await sleep(config.after)
      }
    case "inject":
      // Amplifier test: enqueue a few far-future-dated copies of the current frame
      // into VLC's own renderer (simulating one mis-dated output burst), then observe.
      for c in 0..<config.cycles {
        guard let layer = rendererBox.layer else { mark("inject_no_layer"); break }
        let renderer = layer.sampleBufferRenderer
        guard let pb = renderer.displayedPixelBuffer() else { mark("inject_no_pb"); break }
        var fmt: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pb, formatDescriptionOut: &fmt)
        let future = CACurrentMediaTime() + config.hiddenSecs
        var injected = 0
        for i in 0..<6 {
          var timing = CMSampleTimingInfo(duration: .invalid,
                                          presentationTimeStamp: CMTime(seconds: future + Double(i) / 30, preferredTimescale: 1_000_000),
                                          decodeTimeStamp: .invalid)
          var sb: CMSampleBuffer?
          if let fmt, CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pb, formatDescription: fmt,
                                                               sampleTiming: &timing, sampleBufferOut: &sb) == noErr, let sb {
            renderer.enqueue(sb); injected += 1
          }
        }
        mark("show_req", ["how": "inject", "cycle": c, "future_s": config.hiddenSecs, "n": injected,
                          "ready_after": renderer.isReadyForMoreMediaData])
        await sleep(config.hiddenSecs + config.after)
      }
    case "seeks":
      // Absolute seeks to each --pauses value (seconds), e.g. across HLS discontinuity sequences.
      for target in config.pauses {
        mark("seek", ["to": Int(target * 1000)]); engine.seek(ms: Int64(target * 1000))
        await sleep(config.after)
        mark("seek_settled", ["to": Int(target * 1000), "time": libvlc_media_player_get_time(engine.mp),
                              "frame": latestFrame.value])
      }
    case "pip":
      // Open and close macOS PiP while playing, then while paused.
      for c in 0..<config.cycles {
        for paused in [false, true] {
          guard let pip = PiPBox.controller else { mark("pip_no_controller"); break }
          if paused { engine.pause(); mark("pause_req", ["how": "pip", "cycle": c]); await sleep(1) }
          pip.start()
          await sleep(config.hiddenSecs)
          mark("pip_open", ["active": pip.isActive, "cycle": c, "paused": paused])
          pip.stop()
          mark("show_req", ["how": paused ? "pip_close_paused" : "pip_close", "cycle": c])
          await sleep(config.after)
          if paused { engine.resume(); mark("resume_req", ["how": "pip", "cycle": c]); await sleep(config.after) }
        }
      }
    case "rate":
      for c in 0..<config.cycles {
        for r in [1.5, 1.0, 2.0, 1.0, 0.5, 1.0] as [Float] {
          mark("resume_req", ["how": "rate", "cycle": c, "rate": Double(r)])
          libvlc_media_player_set_rate(engine.mp, r)
          await sleep(config.after)
        }
      }
    default:
      mark("unknown_scenario")
    }
  }

  func finish() {
    mark("done")
    sampler.running = false
    usleep(50_000)
    rec.flush()
    exit(0)
  }
}

MainActor.assumeIsolated {
  let app = NSApplication.shared
  app.setActivationPolicy(.regular)
  let harness = Harness()
  app.delegate = harness
  withExtendedLifetime(harness) { app.run() }
}
