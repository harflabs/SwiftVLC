#if os(macOS)
import AppKit
import SwiftUI
import SwiftVLC

// MARK: - macOS Player View

struct MacOSPlayerView: View {
  @State private var player: Player?
  @State private var pipController: PiPController?
  @State private var urlString = "https://pub-79c73cda2d324e97b277e8a2f351acac.r2.dev/media/TOS.mkv"
  @State private var errorMessage: String?
  @State private var didAutoLoad = false

  @State private var showControls = true
  @State private var hideTask: Task<Void, Never>?
  @State private var seekPosition: Double?
  @State private var isHovering = false

  @State private var showURLPopover = false
  @State private var showSettings = false
  @State private var flashIcon: String?

  @State private var selectedPreset: Int = 0

  @State private var listPlayer: MediaListPlayer?
  @State private var mediaList = MediaList()
  @State private var playlistURLs: [String] = []
  @State private var abPointA: Duration?

  @State private var parsedMetadata: Metadata?

  var body: some View {
    ZStack {
      Color.black

      if let player {
        PiPVideoView(player, controller: $pipController)
          .onAppear {
            if !didAutoLoad {
              didAutoLoad = true
              loadMedia(player: player)
            }
          }

        if showControls {
          controlsOverlay(player: player)
            .transition(.opacity)
        }

        if let flashIcon {
          Image(systemName: flashIcon)
            .font(.system(size: 60))
            .foregroundStyle(.white)
            .padding(30)
            .background(.black.opacity(0.5), in: Circle())
            .transition(.opacity)
        }

        if let errorMessage {
          VStack {
            Text(errorMessage)
              .font(.caption)
              .foregroundStyle(.white)
              .padding(8)
              .background(.red.opacity(0.85), in: RoundedRectangle(cornerRadius: 6))
              .onTapGesture { self.errorMessage = nil }
              .padding(.top, 16)
            Spacer()
          }
        }
      } else {
        ProgressView().controlSize(.large)
      }
    }
    .frame(minWidth: 640, minHeight: 360)
    .focusable()
    .onContinuousHover { phase in
      switch phase {
      case .active:
        isHovering = true
        if !showControls { withAnimation(.easeIn(duration: 0.2)) { showControls = true } }
        scheduleHideControls()
      case .ended:
        isHovering = false
        if seekPosition == nil, let player, player.isPlaying {
          withAnimation(.easeOut(duration: 0.3)) { showControls = false }
        }
      }
    }
    .onChange(of: showControls) { _, show in
      if !show { NSCursor.setHiddenUntilMouseMoves(true) }
    }
    .onKeyPress(.space) {
      guard let player else { return .ignored }
      player.togglePlayPause()
      flashPlayPause(player: player)
      return .handled
    }
    .onKeyPress(.leftArrow) {
      player?.seek(by: .seconds(-5)); return .handled
    }
    .onKeyPress(.rightArrow) {
      player?.seek(by: .seconds(5)); return .handled
    }
    .onKeyPress(.upArrow) {
      guard let player else { return .ignored }
      player.volume = min(1.0, player.volume + 0.05); return .handled
    }
    .onKeyPress(.downArrow) {
      guard let player else { return .ignored }
      player.volume = max(0.0, player.volume - 0.05); return .handled
    }
    .onKeyPress("m") {
      player?.isMuted.toggle(); return .handled
    }
    .onKeyPress("[") {
      guard let player else { return .ignored }
      player.rate = max(0.25, player.rate - 0.25); return .handled
    }
    .onKeyPress("]") {
      guard let player else { return .ignored }
      player.rate = min(4.0, player.rate + 0.25); return .handled
    }
    .onKeyPress(",") {
      player?.nextFrame(); return .handled
    }
    .contextMenu { contextMenuContent }
    .task {
      if player == nil {
        do { player = try Player() }
        catch { errorMessage = "Failed to create player: \(error)" }
      }
    }
    .popover(isPresented: $showURLPopover) {
      if let player {
        macOSURLInput(urlString: $urlString, player: player, errorMessage: $errorMessage, parsedMetadata: $parsedMetadata)
      }
    }
    .sheet(isPresented: $showSettings) {
      if let player {
        macOSSettingsPanel(
          player: player,
          selectedPreset: $selectedPreset,
          listPlayer: $listPlayer, mediaList: $mediaList, playlistURLs: $playlistURLs,
          abPointA: $abPointA,
          parsedMetadata: $parsedMetadata,
          errorMessage: $errorMessage, urlString: urlString
        )
      }
    }
  }

  // MARK: - Controls Overlay

  private func controlsOverlay(player: Player) -> some View {
    VStack(spacing: 0) {
      topOverlay(player: player)
        .padding(.horizontal, 16)
        .padding(.top, 12)

      Spacer()

      bottomOverlay(player: player)
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }
    .background(alignment: .top) {
      LinearGradient(colors: [.black.opacity(0.5), .clear], startPoint: .top, endPoint: .bottom)
        .frame(height: 80)
        .allowsHitTesting(false)
    }
    .background(alignment: .bottom) {
      LinearGradient(colors: [.clear, .black.opacity(0.5)], startPoint: .top, endPoint: .bottom)
        .frame(height: 120)
        .allowsHitTesting(false)
    }
  }

  private func topOverlay(player: Player) -> some View {
    HStack(spacing: 12) {
      if let media = player.currentMedia, let mrl = media.mrl {
        Text(URL(string: mrl)?.lastPathComponent ?? mrl)
          .font(.headline)
          .foregroundStyle(.white)
          .lineLimit(1)
      }

      Spacer()

      Button { showURLPopover = true } label: {
        Image(systemName: "link").font(.title3)
      }
      .buttonStyle(.plain)
      .foregroundStyle(.white)

      if let pipController {
        Button { pipController.toggle() } label: {
          Image(systemName: pipController.isActive ? "pip.exit" : "pip.enter").font(.title3)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
      }

      Button { showSettings = true } label: {
        Image(systemName: "gearshape").font(.title3)
      }
      .buttonStyle(.plain)
      .foregroundStyle(.white)
    }
  }

  private func bottomOverlay(player: Player) -> some View {
    VStack(spacing: 8) {
      macOSSeekBar(player: player, seekPosition: $seekPosition)
        .onChange(of: seekPosition) { _, val in
          if val != nil { hideTask?.cancel() }
          else { scheduleHideControls() }
        }

      HStack(spacing: 16) {
        let displayTime = seekDisplayTime(player: player)
        Text(formatDuration(displayTime))
          .font(.system(.caption, design: .monospaced))
          .foregroundStyle(.white.opacity(0.8))

        Spacer()

        Button { player.seek(by: .seconds(-15)) } label: {
          Image(systemName: "gobackward.15").font(.title3)
        }
        .buttonStyle(.plain).foregroundStyle(.white)
        .disabled(!player.isSeekable)

        Button {
          if player.isPlaying { player.pause() }
          else if player.currentMedia != nil { try? player.play() }
          flashPlayPause(player: player)
        } label: {
          Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.title2)
        }
        .buttonStyle(.plain).foregroundStyle(.white)
        .disabled(player.currentMedia == nil)

        Button { player.seek(by: .seconds(15)) } label: {
          Image(systemName: "goforward.15").font(.title3)
        }
        .buttonStyle(.plain).foregroundStyle(.white)
        .disabled(!player.isSeekable)

        Spacer()

        HStack(spacing: 6) {
          Button { player.isMuted.toggle() } label: {
            Image(systemName: player.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
              .font(.callout)
          }
          .buttonStyle(.plain).foregroundStyle(.white)

          Slider(value: Binding(get: { player.volume }, set: { player.volume = $0 }), in: 0...1)
            .frame(width: 80)
            .tint(.white)
        }

        if player.rate != 1.0 {
          Text(String(format: "%gx", player.rate))
            .font(.caption.weight(.medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.white.opacity(0.2), in: Capsule())
        }

        if let duration = player.duration {
          let remaining = Duration.milliseconds(max(0, duration.milliseconds - displayTime.milliseconds))
          Text("-" + formatDuration(remaining))
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.white.opacity(0.8))
        }
      }
    }
  }

  // MARK: - Context Menu

  @ViewBuilder
  private var contextMenuContent: some View {
    if let player {
      Picker("Playback Speed", selection: Binding(
        get: { player.rate },
        set: { player.rate = $0 }
      )) {
        Text("0.25x").tag(Float(0.25))
        Text("0.5x").tag(Float(0.5))
        Text("0.75x").tag(Float(0.75))
        Text("1x").tag(Float(1.0))
        Text("1.25x").tag(Float(1.25))
        Text("1.5x").tag(Float(1.5))
        Text("2x").tag(Float(2.0))
        Text("3x").tag(Float(3.0))
      }

      if !player.audioTracks.isEmpty {
        Picker("Audio Track", selection: Binding(
          get: { player.selectedAudioTrack?.id },
          set: { id in player.selectedAudioTrack = player.audioTracks.first { $0.id == id } }
        )) {
          ForEach(player.audioTracks, id: \.id) { track in
            Text(track.name).tag(Optional(track.id))
          }
        }
      }

      if !player.subtitleTracks.isEmpty {
        Picker("Subtitles", selection: Binding(
          get: { player.selectedSubtitleTrack?.id },
          set: { id in
            if let id { player.selectedSubtitleTrack = player.subtitleTracks.first { $0.id == id } }
            else { player.selectedSubtitleTrack = nil }
          }
        )) {
          Text("Off").tag(String?.none)
          ForEach(player.subtitleTracks, id: \.id) { track in
            Text(track.name).tag(Optional(track.id))
          }
        }
      }

      Picker("Aspect Ratio", selection: Binding(
        get: { macOSAspectRatioOption(player.aspectRatio) },
        set: { player.aspectRatio = $0.value }
      )) {
        Text("Default").tag(macOSAspectRatioOption.default)
        Text("4:3").tag(macOSAspectRatioOption.fourThree)
        Text("16:9").tag(macOSAspectRatioOption.sixteenNine)
        Text("16:10").tag(macOSAspectRatioOption.sixteenTen)
        Text("21:9").tag(macOSAspectRatioOption.twentyOneNine)
        Text("Fill").tag(macOSAspectRatioOption.fill)
      }

      Divider()

      Menu("Audio") {
        Picker("Stereo Mode", selection: Binding(
          get: { player.stereoMode },
          set: { player.stereoMode = $0 }
        )) {
          Text("Stereo").tag(StereoMode.stereo)
          Text("Mono").tag(StereoMode.mono)
          Text("Reverse Stereo").tag(StereoMode.reverseStereo)
          Text("Left").tag(StereoMode.left)
          Text("Right").tag(StereoMode.right)
        }
        Picker("Mix Mode", selection: Binding(
          get: { player.mixMode },
          set: { player.mixMode = $0 }
        )) {
          Text("Stereo").tag(MixMode.stereo)
          Text("Binaural").tag(MixMode.binaural)
          Text("5.1").tag(MixMode.fivePointOne)
          Text("7.1").tag(MixMode.sevenPointOne)
        }
        Divider()
        Button("Equalizer...") { showSettings = true }
      }

      Menu("Video Adjustments") {
        Toggle("Enable", isOn: Binding(
          get: { player.adjustments.isEnabled },
          set: { player.adjustments.isEnabled = $0 }
        ))
        Divider()
        Button("Open Settings...") { showSettings = true }
      }

      Menu("Advanced") {
        Button(abPointA == nil ? "Set Point A" : "Set Point B") {
          if let a = abPointA {
            try? player.setABLoop(a: a, b: player.currentTime)
            abPointA = nil
          } else {
            abPointA = player.currentTime
          }
        }
        Button("Reset A-B Loop") {
          try? player.resetABLoop()
          abPointA = nil
        }
        Divider()
        if player.chapterCount > 0 {
          Button("Previous Chapter") { player.previousChapter() }
          Button("Next Chapter") { player.nextChapter() }
          Divider()
        }
        Button("Take Snapshot") {
          let path = NSTemporaryDirectory() + "snapshot.png"
          try? player.takeSnapshot(to: path)
        }
        Button("Next Frame") { player.nextFrame() }
      }

      Menu("Info") {
        Button("Parse Metadata") {
          guard let media = player.currentMedia else { return }
          Task {
            do { parsedMetadata = try await media.parse() }
            catch { errorMessage = "Parse failed: \(error)" }
          }
        }
        Button("Show Statistics...") { showSettings = true }
      }

      Divider()

      Button("Open URL...") { showURLPopover = true }

      if let pipController {
        Button(pipController.isActive ? "Exit PiP" : "Enter PiP") {
          pipController.toggle()
        }
      }
    }
  }

  // MARK: - Actions

  private func loadMedia(player: Player) {
    guard let url = URL(string: urlString) else { errorMessage = "Invalid URL"; return }
    do {
      let media = try Media(url: url)
      player.load(media)
      try player.play()
      errorMessage = nil
      parsedMetadata = nil
    } catch {
      errorMessage = "Error: \(error)"
    }
  }

  private func scheduleHideControls() {
    hideTask?.cancel()
    guard let player, player.isPlaying else { return }
    let p = player
    hideTask = Task {
      try? await Task.sleep(for: .seconds(3))
      guard !Task.isCancelled else { return }
      if p.isPlaying && seekPosition == nil && !isHovering {
        withAnimation(.easeOut(duration: 0.3)) { showControls = false }
      }
    }
  }

  private func flashPlayPause(player: Player) {
    withAnimation(.easeIn(duration: 0.1)) { flashIcon = player.isPlaying ? "pause.fill" : "play.fill" }
    Task {
      try? await Task.sleep(for: .milliseconds(600))
      withAnimation(.easeOut(duration: 0.3)) { flashIcon = nil }
    }
  }

  private func seekDisplayTime(player: Player) -> Duration {
    if let seekPosition, let duration = player.duration {
      return .milliseconds(Int64(seekPosition * Double(duration.milliseconds)))
    }
    return player.currentTime
  }
}

// MARK: - Seek Bar

private struct macOSSeekBar: View {
  let player: Player
  @Binding var seekPosition: Double?
  @State private var isHovering = false

  private var displayPosition: Double {
    seekPosition ?? player.position
  }

  var body: some View {
    GeometryReader { geo in
      let barHeight: CGFloat = isHovering || seekPosition != nil ? 6 : 3
      ZStack(alignment: .leading) {
        Capsule()
          .fill(.white.opacity(0.3))
          .frame(height: barHeight)

        Capsule()
          .fill(.white)
          .frame(width: max(0, geo.size.width * displayPosition), height: barHeight)

        if isHovering || seekPosition != nil {
          Circle()
            .fill(.white)
            .frame(width: 12, height: 12)
            .offset(x: max(0, min(geo.size.width - 12, geo.size.width * displayPosition - 6)))
        }
      }
      .frame(maxHeight: .infinity)
      .contentShape(Rectangle())
      .gesture(
        DragGesture(minimumDistance: 0)
          .onChanged { value in
            let fraction = max(0, min(1, value.location.x / geo.size.width))
            seekPosition = fraction
          }
          .onEnded { _ in
            if let pos = seekPosition { player.position = pos }
            seekPosition = nil
          }
      )
      .onHover { hovering in isHovering = hovering }
    }
    .frame(height: 16)
  }
}

// MARK: - URL Input Popover

private struct macOSURLInput: View {
  @Binding var urlString: String
  let player: Player
  @Binding var errorMessage: String?
  @Binding var parsedMetadata: Metadata?
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(spacing: 12) {
      TextField("Media URL", text: $urlString)
        .textFieldStyle(.roundedBorder)
        .frame(width: 400)
        .onSubmit { load() }

      HStack {
        Button("Open File...") { openFile() }
          .buttonStyle(.bordered)
        Spacer()
        Button("Cancel") { dismiss() }
          .buttonStyle(.bordered)
        Button("Load") { load() }
          .buttonStyle(.borderedProminent)
      }
    }
    .padding()
  }

  private func load() {
    guard let url = URL(string: urlString) else { errorMessage = "Invalid URL"; return }
    do {
      let media = try Media(url: url)
      player.load(media)
      try player.play()
      errorMessage = nil
      parsedMetadata = nil
      dismiss()
    } catch {
      errorMessage = "Error: \(error)"
    }
  }

  private func openFile() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.movie, .audio, .mpeg4Movie, .quickTimeMovie, .avi, .mpeg2TransportStream]
    panel.allowsMultipleSelection = false
    if panel.runModal() == .OK, let url = panel.url {
      urlString = url.absoluteString
      load()
    }
  }
}

// MARK: - Settings Panel

private struct macOSSettingsPanel: View {
  let player: Player
  @Binding var selectedPreset: Int
  @Binding var listPlayer: MediaListPlayer?
  @Binding var mediaList: MediaList
  @Binding var playlistURLs: [String]
  @Binding var abPointA: Duration?
  @Binding var parsedMetadata: Metadata?
  @Binding var errorMessage: String?
  let urlString: String
  @State private var liveStats: MediaStatistics?
  @Environment(\.dismiss) private var dismiss

  @State private var selectedTab = 0

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text("Settings").font(.headline)
        Spacer()
        Button("Done") { dismiss() }
      }
      .padding()

      Picker("", selection: $selectedTab) {
        Text("Equalizer").tag(0)
        Text("Video").tag(1)
        Text("Audio").tag(2)
        Text("Info").tag(3)
      }
      .pickerStyle(.segmented)
      .padding(.horizontal)

      Divider().padding(.top, 8)

      ScrollView {
        Group {
          switch selectedTab {
          case 0: equalizerTab
          case 1: videoTab
          case 2: audioTab
          case 3: infoTab
          default: EmptyView()
          }
        }
        .padding()
      }
    }
    .frame(width: 500, height: 550)
  }

  // MARK: - Equalizer Tab

  private var equalizerTab: some View {
    VStack(spacing: 12) {
      Toggle("Enable Equalizer", isOn: Binding(
        get: { player.equalizer != nil },
        set: { enabled in
          if enabled {
            player.equalizer = Equalizer(preset: selectedPreset)
          } else {
            player.equalizer = nil
          }
        }
      ))

      if player.equalizer != nil {
        Picker("Preset", selection: $selectedPreset) {
          ForEach(0..<Equalizer.presetCount, id: \.self) { i in
            Text(Equalizer.presetName(at: i) ?? "Preset \(i)").tag(i)
          }
        }
        .onChange(of: selectedPreset) { _, preset in
          player.equalizer = Equalizer(preset: preset)
        }

        if let equalizer = player.equalizer {
          sliderRow("Preamp", value: Binding(
            get: { equalizer.preamp },
            set: { equalizer.preamp = $0; player.equalizer = player.equalizer }
          ), range: -20...20, format: "%.1f dB")

          ForEach(0..<Equalizer.bandCount, id: \.self) { band in
            sliderRow(
              String(format: "%.0f Hz", Equalizer.bandFrequency(at: band)),
              value: Binding(
                get: { equalizer.amplification(forBand: band) },
                set: { try? equalizer.setAmplification($0, forBand: band); player.equalizer = player.equalizer }
              ),
              range: -20...20,
              format: "%.1f dB"
            )
          }
        }
      }
    }
  }

  // MARK: - Video Tab

  private var videoTab: some View {
    VStack(spacing: 12) {
      Toggle("Enable Adjustments", isOn: Binding(
        get: { player.adjustments.isEnabled },
        set: { player.adjustments.isEnabled = $0 }
      ))

      if player.adjustments.isEnabled {
        sliderRow("Contrast", value: Binding(
          get: { player.adjustments.contrast },
          set: { player.adjustments.contrast = $0 }
        ), range: 0...2)
        sliderRow("Brightness", value: Binding(
          get: { player.adjustments.brightness },
          set: { player.adjustments.brightness = $0 }
        ), range: 0...2)
        sliderRow("Hue", value: Binding(
          get: { player.adjustments.hue },
          set: { player.adjustments.hue = $0 }
        ), range: 0...360)
        sliderRow("Saturation", value: Binding(
          get: { player.adjustments.saturation },
          set: { player.adjustments.saturation = $0 }
        ), range: 0...3)
        sliderRow("Gamma", value: Binding(
          get: { player.adjustments.gamma },
          set: { player.adjustments.gamma = $0 }
        ), range: 0.01...10)
      }
    }
  }

  // MARK: - Audio Tab

  private var audioTab: some View {
    VStack(spacing: 12) {
      Picker("Stereo Mode", selection: Binding(
        get: { player.stereoMode },
        set: { player.stereoMode = $0 }
      )) {
        Text("Unset").tag(StereoMode.unset)
        Text("Stereo").tag(StereoMode.stereo)
        Text("Reverse Stereo").tag(StereoMode.reverseStereo)
        Text("Left").tag(StereoMode.left)
        Text("Right").tag(StereoMode.right)
        Text("Dolby Surround").tag(StereoMode.dolbySurround)
        Text("Mono").tag(StereoMode.mono)
      }

      Picker("Mix Mode", selection: Binding(
        get: { player.mixMode },
        set: { player.mixMode = $0 }
      )) {
        Text("Unset").tag(MixMode.unset)
        Text("Stereo").tag(MixMode.stereo)
        Text("Binaural").tag(MixMode.binaural)
        Text("4.0").tag(MixMode.fourPointZero)
        Text("5.1").tag(MixMode.fivePointOne)
        Text("7.1").tag(MixMode.sevenPointOne)
      }

      HStack {
        Text("Audio Delay")
        Spacer()
        Text("\(player.audioDelay.milliseconds) ms").monospacedDigit()
        Stepper("", value: Binding(
          get: { Int(player.audioDelay.milliseconds) },
          set: { player.audioDelay = .milliseconds($0) }
        ), step: 50)
          .labelsHidden()
      }

      let outputs = VLCInstance.shared.audioOutputs()
      if !outputs.isEmpty {
        Picker("Output", selection: Binding(
          get: { outputs.first?.name ?? "" },
          set: { try? player.setAudioOutput($0) }
        )) {
          ForEach(outputs) { output in
            Text(output.outputDescription).tag(output.name)
          }
        }
      }

      let devices = player.audioDevices()
      if !devices.isEmpty {
        Picker("Device", selection: Binding(
          get: { player.currentAudioDevice ?? "" },
          set: { try? player.setAudioDevice($0) }
        )) {
          ForEach(devices) { device in
            Text(device.deviceDescription).tag(device.deviceId)
          }
        }
      }
    }
  }

  // MARK: - Info Tab

  private var infoTab: some View {
    VStack(alignment: .leading, spacing: 12) {
      if let media = player.currentMedia {
        LabeledContent("MRL", value: media.mrl ?? "---")
        if let duration = media.duration {
          LabeledContent("Duration", value: formatDuration(duration))
        }
      }

      Divider()

      if let meta = parsedMetadata {
        Group {
          if let t = meta.title, !t.isEmpty { LabeledContent("Title", value: t) }
          if let a = meta.artist, !a.isEmpty { LabeledContent("Artist", value: a) }
          if let a = meta.album, !a.isEmpty { LabeledContent("Album", value: a) }
          if let g = meta.genre, !g.isEmpty { LabeledContent("Genre", value: g) }
        }
      } else {
        Button("Parse Metadata") {
          guard let media = player.currentMedia else { return }
          Task {
            do { parsedMetadata = try await media.parse() }
            catch { errorMessage = "Parse failed: \(error)" }
          }
        }
      }

      Divider()

      Text("Tracks").font(.subheadline.weight(.medium))
      let allTracks = player.audioTracks + player.videoTracks + player.subtitleTracks
      if allTracks.isEmpty {
        Text("No tracks").foregroundStyle(.secondary)
      } else {
        ForEach(allTracks, id: \.id) { track in
          HStack {
            Image(systemName: trackIcon(track.type))
              .foregroundStyle(.secondary).frame(width: 16)
            Text(track.name).font(.caption)
            Spacer()
            if track.isSelected {
              Image(systemName: "checkmark").foregroundStyle(.green).font(.caption)
            }
          }
        }
      }

      Divider()

      if let stats = liveStats {
        Text("Statistics").font(.subheadline.weight(.medium))
        LabeledContent("Input Bitrate", value: String(format: "%.2f kb/s", stats.inputBitrate))
        LabeledContent("Decoded Video", value: "\(stats.decodedVideo)")
        LabeledContent("Decoded Audio", value: "\(stats.decodedAudio)")
        LabeledContent("Displayed", value: "\(stats.displayedPictures)")
        LabeledContent("Late", value: "\(stats.latePictures)")
        LabeledContent("Lost", value: "\(stats.lostPictures)")
      }

      Divider()

      LabeledContent("VLC Version", value: VLCInstance.shared.version)
      LabeledContent("Compiler", value: VLCInstance.shared.compiler)
    }
    .task {
      while !Task.isCancelled {
        if let media = player.currentMedia { liveStats = media.statistics() }
        try? await Task.sleep(for: .seconds(1))
      }
    }
  }

  private func sliderRow(_ label: String, value: Binding<Float>, range: ClosedRange<Float>, format: String = "%.2f") -> some View {
    VStack(spacing: 4) {
      HStack {
        Text(label)
        Spacer()
        Text(String(format: format, value.wrappedValue)).monospacedDigit()
      }
      .font(.caption)
      Slider(value: value, in: range)
    }
  }
}

// MARK: - Helpers

private enum macOSAspectRatioOption: Hashable {
  case `default`, fourThree, sixteenNine, sixteenTen, twentyOneNine, fill

  init(_ ratio: AspectRatio) {
    switch ratio {
    case .default: self = .default
    case .ratio(4, 3): self = .fourThree
    case .ratio(16, 9): self = .sixteenNine
    case .ratio(16, 10): self = .sixteenTen
    case .ratio(21, 9): self = .twentyOneNine
    case .fill: self = .fill
    default: self = .default
    }
  }

  var value: AspectRatio {
    switch self {
    case .default: .default
    case .fourThree: .ratio(4, 3)
    case .sixteenNine: .ratio(16, 9)
    case .sixteenTen: .ratio(16, 10)
    case .twentyOneNine: .ratio(21, 9)
    case .fill: .fill
    }
  }
}

private func trackIcon(_ type: TrackType) -> String {
  switch type {
  case .audio: "speaker.wave.2"
  case .video: "film"
  case .subtitle: "captions.bubble"
  case .unknown: "questionmark"
  }
}

private func formatDuration(_ duration: Duration) -> String {
  let totalSeconds = Int(duration.milliseconds / 1000)
  let h = totalSeconds / 3600
  let m = (totalSeconds % 3600) / 60
  let s = totalSeconds % 60
  return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
}

#endif
