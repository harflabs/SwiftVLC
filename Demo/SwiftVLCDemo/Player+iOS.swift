#if os(iOS)
    import SwiftUI
    import SwiftVLC

    // MARK: - iOS Player View

    struct iOSPlayerView: View {
        @State private var player: Player?
        @State private var pipController: PiPController?
        @State private var urlString = "https://pub-79c73cda2d324e97b277e8a2f351acac.r2.dev/media/TOS.mkv"
        @State private var errorMessage: String?
        @State private var didAutoLoad = false

        @State private var showControls = true
        @State private var hideTask: Task<Void, Never>?
        @State private var seekPosition: Double?

        @State private var showSettings = false
        @State private var showURLInput = false

        @State private var selectedPreset: Int = 0

        @State private var listPlayer: MediaListPlayer?
        @State private var mediaList = MediaList()
        @State private var playlistURLs: [String] = []
        @State private var abPointA: Duration?

        @State private var parsedMetadata: Metadata?

        @Environment(\.scenePhase) private var scenePhase
        @Environment(\.dismiss) private var dismiss

        var body: some View {
            ZStack {
                Color.black.ignoresSafeArea()

                if let player {
                    PiPVideoView(player, controller: $pipController)
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .onAppear {
                            if !didAutoLoad {
                                didAutoLoad = true
                                loadMedia(player: player)
                            }
                        }

                    gestureLayer(player: player)

                    if showControls {
                        controlsOverlay(player: player)
                            .transition(.opacity)
                    }

                    if let errorMessage {
                        VStack {
                            Text(errorMessage)
                                .font(.footnote.weight(.medium))
                                .foregroundStyle(.white)
                                .padding(.horizontal)
                                .padding(.vertical, 6)
                                .background(.red, in: Capsule())
                                .onTapGesture { self.errorMessage = nil }
                            Spacer()
                        }
                        .safeAreaPadding(.top)
                        .allowsHitTesting(true)
                    }
                } else {
                    ProgressView().tint(.white)
                }
            }
            .preferredColorScheme(.dark)
            .statusBarHidden(!showControls)
            .persistentSystemOverlays(.hidden)
            .task {
                if player == nil {
                    do { player = try Player() }
                    catch { errorMessage = "Failed to create player: \(error)" }
                }
            }
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .background,
                   let player, player.isActive,
                   let pipController, pipController.isPossible, !pipController.isActive
                {
                    pipController.start()
                }
            }
            .onChange(of: player?.state) { _, newState in
                guard let player else { return }
                if newState == .playing {
                    scheduleHideControls(player: player)
                } else {
                    hideTask?.cancel()
                    withAnimation(.easeInOut(duration: 0.25)) { showControls = true }
                }
            }
            .sheet(isPresented: $showSettings) {
                if let player {
                    iOSSettingsSheet(
                        player: player,
                        selectedPreset: $selectedPreset,
                        listPlayer: $listPlayer, mediaList: $mediaList, playlistURLs: $playlistURLs,
                        abPointA: $abPointA,
                        parsedMetadata: $parsedMetadata,
                        errorMessage: $errorMessage, urlString: urlString
                    )
                }
            }
            .sheet(isPresented: $showURLInput) {
                if let player {
                    iOSURLInputSheet(urlString: $urlString) { loadMedia(player: player) }
                }
            }
            .gesture(
                MagnifyGesture()
                    .onEnded { value in
                        guard let player else { return }
                        player.aspectRatio = value.magnification > 1 ? .fill : .default
                    }
            )
        }

        // MARK: - Gesture Layer

        private func gestureLayer(player: Player) -> some View {
            GeometryReader { geo in
                HStack(spacing: 0) {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { player.seek(by: .seconds(-15)) }
                        .onTapGesture { toggleControls(player: player) }
                        .frame(width: geo.size.width / 3)

                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { toggleControls(player: player) }
                        .frame(width: geo.size.width / 3)

                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { player.seek(by: .seconds(15)) }
                        .onTapGesture { toggleControls(player: player) }
                        .frame(width: geo.size.width / 3)
                }
            }
            .ignoresSafeArea()
        }

        // MARK: - Controls Overlay

        private func controlsOverlay(player: Player) -> some View {
            GeometryReader { geo in
                VStack {
                    topBar(player: player)
                        .padding(.horizontal)
                    Spacer()
                    bottomBar(player: player)
                        .padding(.horizontal)
                }
                .background(alignment: .top) {
                    LinearGradient(colors: [.black.opacity(0.6), .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: geo.size.height * 0.25)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                }
                .background(alignment: .bottom) {
                    LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom)
                        .frame(height: geo.size.height * 0.35)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                }
            }
        }

        private func topBar(player: Player) -> some View {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.body.weight(.semibold))
                        .padding(10)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .buttonStyle(.plain)

                Text(player.state.description)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.ultraThinMaterial, in: Capsule())

                Spacer()

                HStack(spacing: 12) {
                    Button { showURLInput = true } label: {
                        Image(systemName: "link")
                    }

                    if let pipController {
                        Button { pipController.toggle() } label: {
                            Image(systemName: pipController.isActive ? "pip.exit" : "pip.enter")
                        }
                    }

                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape")
                    }
                }
                .font(.body)
                .buttonStyle(.plain)
            }
        }

        private func bottomBar(player: Player) -> some View {
            VStack(spacing: 10) {
                iOSSeekBar(player: player, seekPosition: $seekPosition)
                    .onChange(of: seekPosition) { _, newValue in
                        if newValue != nil { hideTask?.cancel() }
                        else { scheduleHideControls(player: player) }
                    }

                HStack {
                    HStack(spacing: 20) {
                        Button { player.seek(by: .seconds(-15)) } label: {
                            Image(systemName: "gobackward.15")
                                .font(.title3)
                        }
                        .disabled(!player.isSeekable)

                        Button {
                            if player.isPlaying { player.pause() }
                            else if player.currentMedia != nil { try? player.play() }
                        } label: {
                            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                                .font(.title)
                                .contentTransition(.symbolEffect(.replace))
                        }
                        .disabled(player.currentMedia == nil)

                        Button { player.seek(by: .seconds(15)) } label: {
                            Image(systemName: "goforward.15")
                                .font(.title3)
                        }
                        .disabled(!player.isSeekable)
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    HStack(spacing: 8) {
                        Button { player.isMuted.toggle() } label: {
                            Image(systemName: player.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                                .font(.footnote)
                                .contentTransition(.symbolEffect(.replace))
                        }
                        .buttonStyle(.plain)

                        Slider(value: Binding(get: { player.volume }, set: { player.volume = $0 }), in: 0 ... 1)
                            .tint(.white)
                            .frame(maxWidth: 120)
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

        private func toggleControls(player: Player) {
            withAnimation(.easeInOut(duration: 0.25)) { showControls.toggle() }
            if showControls { scheduleHideControls(player: player) }
        }

        private func scheduleHideControls(player: Player) {
            hideTask?.cancel()
            hideTask = Task {
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled else { return }
                if player.isPlaying && seekPosition == nil {
                    withAnimation(.easeOut(duration: 0.3)) { showControls = false }
                }
            }
        }
    }

    // MARK: - Seek Bar

    private struct iOSSeekBar: View {
        let player: Player
        @Binding var seekPosition: Double?

        private var displayPosition: Double {
            seekPosition ?? player.position
        }

        private var displayTime: Duration {
            if let seekPosition, let duration = player.duration {
                return .milliseconds(Int64(seekPosition * Double(duration.milliseconds)))
            }
            return player.currentTime
        }

        var body: some View {
            VStack(spacing: 6) {
                Slider(
                    value: Binding(
                        get: { displayPosition },
                        set: { seekPosition = $0 }
                    ),
                    in: 0 ... 1
                ) { editing in
                    if editing {
                        seekPosition = player.position
                    } else {
                        if let pos = seekPosition { player.position = pos }
                        seekPosition = nil
                    }
                }
                .tint(.white)

                HStack {
                    Text(formatDuration(displayTime))
                    Spacer()
                    if let duration = player.duration {
                        let remaining = Duration.milliseconds(max(0, duration.milliseconds - displayTime.milliseconds))
                        Text("-\(formatDuration(remaining))")
                    }
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Settings Sheet

    private struct iOSSettingsSheet: View {
        let player: Player
        @Binding var selectedPreset: Int
        @Binding var listPlayer: MediaListPlayer?
        @Binding var mediaList: MediaList
        @Binding var playlistURLs: [String]
        @Binding var abPointA: Duration?
        @Binding var parsedMetadata: Metadata?
        @Binding var errorMessage: String?
        let urlString: String
        @Environment(\.dismiss) private var dismiss

        var body: some View {
            NavigationStack {
                List {
                    NavigationLink { iOSPlaybackSettings(player: player) }
                        label: { Label("Playback", systemImage: "play.circle") }
                    NavigationLink { iOSAudioSettings(player: player, selectedPreset: $selectedPreset) }
                        label: { Label("Audio", systemImage: "speaker.wave.3") }
                    NavigationLink { iOSVideoSettings(player: player) }
                        label: { Label("Video", systemImage: "tv") }
                    NavigationLink { iOSOverlaysSettings(player: player) }
                        label: { Label("Overlays", systemImage: "text.bubble") }
                    NavigationLink { iOSAdvancedSettings(player: player, abPointA: $abPointA, errorMessage: $errorMessage) }
                        label: { Label("Advanced", systemImage: "gearshape.2") }
                    NavigationLink { iOSInfoSettings(player: player, parsedMetadata: $parsedMetadata, errorMessage: $errorMessage) }
                        label: { Label("Info", systemImage: "info.circle") }
                    NavigationLink { iOSNetworkSettings(player: player, listPlayer: $listPlayer, mediaList: $mediaList, playlistURLs: $playlistURLs, errorMessage: $errorMessage, urlString: urlString) }
                        label: { Label("Network", systemImage: "network") }
                }
                .navigationTitle("Settings")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }

    // MARK: - Settings: Playback

    private struct iOSPlaybackSettings: View {
        let player: Player

        @State private var rate: Float = 1.0
        @State private var selectedAudioTrackId: String?
        @State private var selectedSubtitleTrackId: String?

        var body: some View {
            List {
                Section("Speed") {
                    Picker("Speed", selection: $rate) {
                        Text("0.25x").tag(Float(0.25))
                        Text("0.5x").tag(Float(0.5))
                        Text("0.75x").tag(Float(0.75))
                        Text("1x").tag(Float(1.0))
                        Text("1.25x").tag(Float(1.25))
                        Text("1.5x").tag(Float(1.5))
                        Text("2x").tag(Float(2.0))
                        Text("3x").tag(Float(3.0))
                    }
                    .pickerStyle(.menu)
                    .onChange(of: rate) { _, val in player.rate = val }
                }

                Section("Audio Track") {
                    if player.audioTracks.isEmpty {
                        Text("No audio tracks").foregroundStyle(.secondary)
                    } else {
                        Picker("Audio", selection: $selectedAudioTrackId) {
                            ForEach(player.audioTracks, id: \.id) { track in
                                Text(track.name).tag(Optional(track.id))
                            }
                        }
                        .pickerStyle(.menu)
                        .onChange(of: selectedAudioTrackId) { _, id in
                            player.selectedAudioTrack = player.audioTracks.first { $0.id == id }
                        }
                    }
                }

                Section("Subtitle Track") {
                    if player.subtitleTracks.isEmpty {
                        Text("No subtitle tracks").foregroundStyle(.secondary)
                    } else {
                        Picker("Subtitle", selection: $selectedSubtitleTrackId) {
                            Text("Off").tag(String?.none)
                            ForEach(player.subtitleTracks, id: \.id) { track in
                                Text(track.name).tag(Optional(track.id))
                            }
                        }
                        .pickerStyle(.menu)
                        .onChange(of: selectedSubtitleTrackId) { _, id in
                            if let id {
                                player.selectedSubtitleTrack = player.subtitleTracks.first { $0.id == id }
                            } else {
                                player.selectedSubtitleTrack = nil
                            }
                        }
                    }
                }

                Section("Actions") {
                    Button { player.nextFrame() } label: {
                        Label("Next Frame", systemImage: "forward.frame")
                    }
                    .disabled(!player.isPausable)

                    Button(role: .destructive) { player.stop() } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .disabled(player.currentMedia == nil)
                }
            }
            .navigationTitle("Playback")
            .onAppear {
                rate = player.rate
                selectedAudioTrackId = player.selectedAudioTrack?.id
                selectedSubtitleTrackId = player.selectedSubtitleTrack?.id
            }
        }
    }

    // MARK: - Settings: Audio

    private struct iOSAudioSettings: View {
        let player: Player
        @Binding var selectedPreset: Int

        @State private var stereoMode: StereoMode = .unset
        @State private var mixMode: MixMode = .unset
        @State private var audioDelayMs: Int = 0
        @State private var selectedAudioOutput = ""
        @State private var selectedAudioDevice = ""
        @State private var role: PlayerRole = .none
        @State private var preamp: Float = 0
        @State private var bandAmps: [Float] = Array(repeating: 0, count: Equalizer.bandCount)

        var body: some View {
            List {
                Section("Equalizer") {
                    Toggle("Enable Equalizer", isOn: Binding(
                        get: { player.equalizer != nil },
                        set: { enabled in
                            if enabled {
                                player.equalizer = Equalizer(preset: selectedPreset)
                                syncEQState()
                            } else {
                                player.equalizer = nil
                            }
                        }
                    ))

                    if player.equalizer != nil {
                        Picker("Preset", selection: $selectedPreset) {
                            ForEach(0 ..< Equalizer.presetCount, id: \.self) { i in
                                Text(Equalizer.presetName(at: i) ?? "Preset \(i)").tag(i)
                            }
                        }
                        .pickerStyle(.navigationLink)
                        .onChange(of: selectedPreset) { _, preset in
                            player.equalizer = Equalizer(preset: preset)
                            syncEQState()
                        }

                        if player.equalizer != nil {
                            VStack(spacing: 4) {
                                HStack {
                                    Text("Preamp")
                                    Spacer()
                                    Text(String(format: "%.1f dB", preamp)).monospacedDigit()
                                }
                                .font(.caption)
                                Slider(value: $preamp, in: -20 ... 20)
                                    .onChange(of: preamp) { _, val in
                                        player.equalizer?.preamp = val
                                        player.equalizer = player.equalizer
                                    }
                            }

                            ForEach(0 ..< Equalizer.bandCount, id: \.self) { band in
                                VStack(spacing: 4) {
                                    HStack {
                                        Text(String(format: "%.0f Hz", Equalizer.bandFrequency(at: band)))
                                        Spacer()
                                        Text(String(format: "%.1f dB", bandAmps[band])).monospacedDigit()
                                    }
                                    .font(.caption)
                                    Slider(value: $bandAmps[band], in: -20 ... 20)
                                        .onChange(of: bandAmps[band]) { _, val in
                                            try? player.equalizer?.setAmplification(val, forBand: band)
                                            player.equalizer = player.equalizer
                                        }
                                }
                            }
                        }
                    }
                }

                Section("Stereo Mode") {
                    Picker("Stereo Mode", selection: $stereoMode) {
                        Text("Unset").tag(StereoMode.unset)
                        Text("Stereo").tag(StereoMode.stereo)
                        Text("Reverse Stereo").tag(StereoMode.reverseStereo)
                        Text("Left").tag(StereoMode.left)
                        Text("Right").tag(StereoMode.right)
                        Text("Dolby Surround").tag(StereoMode.dolbySurround)
                        Text("Mono").tag(StereoMode.mono)
                    }
                    .pickerStyle(.menu)
                    .onChange(of: stereoMode) { _, val in player.stereoMode = val }
                }

                Section("Mix Mode") {
                    Picker("Mix Mode", selection: $mixMode) {
                        Text("Unset").tag(MixMode.unset)
                        Text("Stereo").tag(MixMode.stereo)
                        Text("Binaural").tag(MixMode.binaural)
                        Text("4.0").tag(MixMode.fourPointZero)
                        Text("5.1").tag(MixMode.fivePointOne)
                        Text("7.1").tag(MixMode.sevenPointOne)
                    }
                    .pickerStyle(.menu)
                    .onChange(of: mixMode) { _, val in player.mixMode = val }
                }

                Section("Audio Delay") {
                    HStack {
                        Text("Delay")
                        Spacer()
                        Text("\(audioDelayMs) ms").monospacedDigit()
                        Stepper("", value: $audioDelayMs, step: 50)
                            .labelsHidden()
                            .onChange(of: audioDelayMs) { _, val in
                                player.audioDelay = .milliseconds(val)
                            }
                    }
                }

                Section("Audio Output") {
                    let outputs = VLCInstance.shared.audioOutputs()
                    if !outputs.isEmpty {
                        Picker("Output", selection: $selectedAudioOutput) {
                            ForEach(outputs) { output in
                                Text(output.outputDescription).tag(output.name)
                            }
                        }
                        .pickerStyle(.menu)
                        .onChange(of: selectedAudioOutput) { _, name in
                            try? player.setAudioOutput(name)
                        }
                    } else {
                        Text("No audio outputs").foregroundStyle(.secondary)
                    }

                    let devices = player.audioDevices()
                    if !devices.isEmpty {
                        Picker("Device", selection: $selectedAudioDevice) {
                            ForEach(devices) { device in
                                Text(device.deviceDescription).tag(device.deviceId)
                            }
                        }
                        .pickerStyle(.menu)
                        .onChange(of: selectedAudioDevice) { _, deviceId in
                            try? player.setAudioDevice(deviceId)
                        }
                    }
                }

                Section("Player Role") {
                    Picker("Role", selection: $role) {
                        Text("None").tag(PlayerRole.none)
                        Text("Music").tag(PlayerRole.music)
                        Text("Video").tag(PlayerRole.video)
                        Text("Communication").tag(PlayerRole.communication)
                        Text("Game").tag(PlayerRole.game)
                        Text("Notification").tag(PlayerRole.notification)
                        Text("Animation").tag(PlayerRole.animation)
                        Text("Production").tag(PlayerRole.production)
                        Text("Accessibility").tag(PlayerRole.accessibility)
                        Text("Test").tag(PlayerRole.test)
                    }
                    .pickerStyle(.menu)
                    .onChange(of: role) { _, val in player.role = val }
                }
            }
            .navigationTitle("Audio")
            .onAppear {
                stereoMode = player.stereoMode
                mixMode = player.mixMode
                audioDelayMs = Int(player.audioDelay.milliseconds)
                let outputs = VLCInstance.shared.audioOutputs()
                selectedAudioOutput = outputs.first?.name ?? ""
                selectedAudioDevice = player.currentAudioDevice ?? ""
                role = player.role
                syncEQState()
            }
        }

        private func syncEQState() {
            guard let eq = player.equalizer else { return }
            preamp = eq.preamp
            for i in 0 ..< Equalizer.bandCount {
                bandAmps[i] = eq.amplification(forBand: i)
            }
        }
    }

    // MARK: - Settings: Video

    private struct iOSVideoSettings: View {
        let player: Player

        @State private var adjustmentsEnabled = false
        @State private var contrast: Float = 1
        @State private var brightness: Float = 1
        @State private var hue: Float = 0
        @State private var saturation: Float = 1
        @State private var gamma: Float = 1
        @State private var aspectRatio: iOSAspectRatioOption = .default
        @State private var subtitleScale: Float = 1
        @State private var subtitleDelayMs: Int = 0
        @State private var deinterlace: iOSDeinterlaceOption = .auto

        var body: some View {
            List {
                Section("Adjustments") {
                    Toggle("Enable Adjustments", isOn: $adjustmentsEnabled)
                        .onChange(of: adjustmentsEnabled) { _, val in
                            player.adjustments.isEnabled = val
                        }

                    if adjustmentsEnabled {
                        sliderRow("Contrast", value: $contrast, range: 0 ... 2)
                            .onChange(of: contrast) { _, val in player.adjustments.contrast = val }
                        sliderRow("Brightness", value: $brightness, range: 0 ... 2)
                            .onChange(of: brightness) { _, val in player.adjustments.brightness = val }
                        sliderRow("Hue", value: $hue, range: 0 ... 360)
                            .onChange(of: hue) { _, val in player.adjustments.hue = val }
                        sliderRow("Saturation", value: $saturation, range: 0 ... 3)
                            .onChange(of: saturation) { _, val in player.adjustments.saturation = val }
                        sliderRow("Gamma", value: $gamma, range: 0.01 ... 10)
                            .onChange(of: gamma) { _, val in player.adjustments.gamma = val }
                    }
                }

                Section("Aspect Ratio") {
                    Picker("Aspect Ratio", selection: $aspectRatio) {
                        Text("Default").tag(iOSAspectRatioOption.default)
                        Text("4:3").tag(iOSAspectRatioOption.fourThree)
                        Text("16:9").tag(iOSAspectRatioOption.sixteenNine)
                        Text("16:10").tag(iOSAspectRatioOption.sixteenTen)
                        Text("21:9").tag(iOSAspectRatioOption.twentyOneNine)
                        Text("Fill").tag(iOSAspectRatioOption.fill)
                    }
                    .pickerStyle(.menu)
                    .onChange(of: aspectRatio) { _, val in player.aspectRatio = val.value }
                }

                Section("Subtitles") {
                    sliderRow("Text Scale", value: $subtitleScale, range: 0.5 ... 3, format: "%.1fx")
                        .onChange(of: subtitleScale) { _, val in player.subtitleTextScale = val }

                    HStack {
                        Text("Subtitle Delay")
                        Spacer()
                        Text("\(subtitleDelayMs) ms").monospacedDigit()
                        Stepper("", value: $subtitleDelayMs, step: 50)
                            .labelsHidden()
                            .onChange(of: subtitleDelayMs) { _, val in
                                player.subtitleDelay = .milliseconds(val)
                            }
                    }
                }

                Section("Deinterlace") {
                    Picker("Mode", selection: $deinterlace) {
                        Text("Auto").tag(iOSDeinterlaceOption.auto)
                        Text("Off").tag(iOSDeinterlaceOption.off)
                        Text("Blend").tag(iOSDeinterlaceOption.blend)
                        Text("Bob").tag(iOSDeinterlaceOption.bob)
                        Text("X").tag(iOSDeinterlaceOption.x)
                        Text("Yadif").tag(iOSDeinterlaceOption.yadif)
                    }
                    .pickerStyle(.menu)
                    .onChange(of: deinterlace) { _, option in
                        switch option {
                        case .auto: try? player.setDeinterlace(state: -1)
                        case .off: try? player.setDeinterlace(state: 0)
                        case .blend: try? player.setDeinterlace(state: 1, mode: "blend")
                        case .bob: try? player.setDeinterlace(state: 1, mode: "bob")
                        case .x: try? player.setDeinterlace(state: 1, mode: "x")
                        case .yadif: try? player.setDeinterlace(state: 1, mode: "yadif")
                        }
                    }
                }
            }
            .navigationTitle("Video")
            .onAppear {
                adjustmentsEnabled = player.adjustments.isEnabled
                contrast = player.adjustments.contrast
                brightness = player.adjustments.brightness
                hue = player.adjustments.hue
                saturation = player.adjustments.saturation
                gamma = player.adjustments.gamma
                aspectRatio = iOSAspectRatioOption(player.aspectRatio)
                subtitleScale = player.subtitleTextScale
                subtitleDelayMs = Int(player.subtitleDelay.milliseconds)
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

    // MARK: - Settings: Overlays

    private struct iOSOverlaysSettings: View {
        let player: Player
        @State private var marqueeEnabled = false
        @State private var marqueeText = "SwiftVLC Demo"
        @State private var marqueeOpacity: Double = 255
        @State private var marqueeFontSize: Int = 24
        @State private var logoEnabled = false
        @State private var logoPath = ""
        @State private var logoOpacity: Double = 255

        var body: some View {
            List {
                Section("Marquee") {
                    Toggle("Enable Marquee", isOn: $marqueeEnabled)
                        .onChange(of: marqueeEnabled) { _, val in player.marquee.isEnabled = val }

                    if marqueeEnabled {
                        HStack {
                            TextField("Text", text: $marqueeText)
                                .textFieldStyle(.roundedBorder)
                            Button("Set") { player.marquee.text = marqueeText }
                                .buttonStyle(.bordered)
                        }

                        VStack(spacing: 4) {
                            HStack {
                                Text("Opacity")
                                Spacer()
                                Text("\(Int(marqueeOpacity))").monospacedDigit()
                            }
                            .font(.caption)
                            Slider(value: $marqueeOpacity, in: 0 ... 255)
                                .onChange(of: marqueeOpacity) { _, val in player.marquee.opacity = Int(val) }
                        }

                        HStack {
                            Text("Font Size")
                            Spacer()
                            Text("\(marqueeFontSize)").monospacedDigit()
                            Stepper("", value: $marqueeFontSize, in: 8 ... 72, step: 2)
                                .labelsHidden()
                                .onChange(of: marqueeFontSize) { _, val in player.marquee.fontSize = val }
                        }
                    }
                }

                Section("Logo") {
                    Toggle("Enable Logo", isOn: $logoEnabled)
                        .onChange(of: logoEnabled) { _, val in player.logo.isEnabled = val }

                    if logoEnabled {
                        HStack {
                            TextField("Image file path", text: $logoPath)
                                .textFieldStyle(.roundedBorder)
                            Button("Set") { player.logo.file = logoPath }
                                .buttonStyle(.bordered)
                        }

                        VStack(spacing: 4) {
                            HStack {
                                Text("Opacity")
                                Spacer()
                                Text("\(Int(logoOpacity))").monospacedDigit()
                            }
                            .font(.caption)
                            Slider(value: $logoOpacity, in: 0 ... 255)
                                .onChange(of: logoOpacity) { _, val in player.logo.opacity = Int(val) }
                        }
                    }
                }
            }
            .navigationTitle("Overlays")
            .onAppear {
                marqueeEnabled = player.marquee.isEnabled
                marqueeOpacity = Double(player.marquee.opacity)
                marqueeFontSize = player.marquee.fontSize
                logoEnabled = player.logo.isEnabled
                logoOpacity = Double(player.logo.opacity)
            }
        }
    }

    // MARK: - Settings: Advanced

    private struct iOSAdvancedSettings: View {
        let player: Player
        @Binding var abPointA: Duration?
        @Binding var errorMessage: String?
        @State private var recordingDirectory = ""
        @State private var snapshotPath = ""
        @State private var snapshotStatus = ""
        @State private var viewpoint = Viewpoint()
        @State private var currentTitle: Int = 0
        @State private var currentChapter: Int = 0
        @State private var teletextPage: Int = 0

        var body: some View {
            List {
                Section("A-B Loop") {
                    HStack {
                        Text("State")
                        Spacer()
                        Text(player.abLoopState.description).foregroundStyle(.secondary)
                    }
                    if let a = abPointA {
                        Text("Point A: \(formatDuration(a))").font(.caption).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 12) {
                        Button("Set A") { abPointA = player.currentTime }
                            .buttonStyle(.bordered)
                        Button("Set B") {
                            guard let a = abPointA else { return }
                            try? player.setABLoop(a: a, b: player.currentTime)
                        }
                        .buttonStyle(.bordered)
                        .disabled(abPointA == nil)
                        Button("Reset") {
                            try? player.resetABLoop()
                            abPointA = nil
                        }
                        .buttonStyle(.bordered)
                    }
                }

                Section("Chapters & Titles") {
                    LabeledContent("Titles", value: "\(player.titleCount)")
                    if player.titleCount > 0 {
                        Picker("Title", selection: $currentTitle) {
                            ForEach(player.titles) { title in
                                Text(title.name ?? "Title \(title.index)").tag(title.index)
                            }
                        }
                        .pickerStyle(.menu)
                        .onChange(of: currentTitle) { _, val in player.currentTitle = val }
                    }

                    LabeledContent("Chapters", value: "\(player.chapterCount)")
                    if player.chapterCount > 0 {
                        Picker("Chapter", selection: $currentChapter) {
                            ForEach(player.chapters()) { chapter in
                                Text(chapter.name ?? "Chapter \(chapter.index)").tag(chapter.index)
                            }
                        }
                        .pickerStyle(.menu)
                        .onChange(of: currentChapter) { _, val in player.currentChapter = val }
                        HStack(spacing: 12) {
                            Button { player.previousChapter() } label: { Label("Prev", systemImage: "chevron.left") }
                                .buttonStyle(.bordered)
                            Button { player.nextChapter() } label: { Label("Next", systemImage: "chevron.right") }
                                .buttonStyle(.bordered)
                        }
                    }
                }

                Section("Recording") {
                    TextField("Recording directory", text: $recordingDirectory)
                        .textFieldStyle(.roundedBorder)
                    HStack(spacing: 12) {
                        Button("Start") { player.startRecording(to: recordingDirectory.isEmpty ? nil : recordingDirectory) }
                            .buttonStyle(.bordered)
                        Button("Stop") { player.stopRecording() }
                            .buttonStyle(.bordered)
                    }
                }

                Section("Snapshot") {
                    TextField("Snapshot file path", text: $snapshotPath)
                        .textFieldStyle(.roundedBorder)
                    Button("Take Snapshot") {
                        let path = snapshotPath.isEmpty ? NSTemporaryDirectory() + "snapshot.png" : snapshotPath
                        do {
                            try player.takeSnapshot(to: path)
                            snapshotStatus = "Saved to \(path)"
                        } catch {
                            snapshotStatus = "Failed"
                        }
                    }
                    .buttonStyle(.bordered)
                    if !snapshotStatus.isEmpty {
                        Text(snapshotStatus).font(.caption).foregroundStyle(.secondary)
                    }
                }

                Section("360/VR Viewpoint") {
                    sliderRow("Yaw", value: $viewpoint.yaw, range: -180 ... 180)
                    sliderRow("Pitch", value: $viewpoint.pitch, range: -90 ... 90)
                    sliderRow("Roll", value: $viewpoint.roll, range: -180 ... 180)
                    sliderRow("FOV", value: $viewpoint.fieldOfView, range: 1 ... 180)
                    HStack(spacing: 12) {
                        Button("Apply") { try? player.updateViewpoint(viewpoint) }
                            .buttonStyle(.bordered)
                        Button("Reset") {
                            viewpoint = Viewpoint()
                            try? player.updateViewpoint(viewpoint)
                        }
                        .buttonStyle(.bordered)
                    }
                }

                Section("Teletext") {
                    HStack {
                        Text("Page")
                        Spacer()
                        Text("\(teletextPage)").monospacedDigit()
                        Stepper("", value: $teletextPage, in: 0 ... 999)
                            .labelsHidden()
                            .onChange(of: teletextPage) { _, val in player.teletextPage = val }
                    }
                }
            }
            .navigationTitle("Advanced")
            .onAppear {
                currentTitle = player.currentTitle
                currentChapter = player.currentChapter
                teletextPage = player.teletextPage
            }
        }

        private func sliderRow(_ label: String, value: Binding<Float>, range: ClosedRange<Float>) -> some View {
            VStack(spacing: 4) {
                HStack {
                    Text(label)
                    Spacer()
                    Text(String(format: "%.1f", value.wrappedValue)).monospacedDigit()
                }
                .font(.caption)
                Slider(value: value, in: range)
            }
        }
    }

    // MARK: - Settings: Info

    private struct iOSInfoSettings: View {
        let player: Player
        @Binding var parsedMetadata: Metadata?
        @Binding var errorMessage: String?
        @State private var liveStats: MediaStatistics?

        var body: some View {
            List {
                Section("Media") {
                    if let media = player.currentMedia {
                        LabeledContent("MRL", value: media.mrl ?? "---")
                        if let duration = media.duration {
                            LabeledContent("Duration", value: formatDuration(duration))
                        }
                    } else {
                        Text("No media loaded").foregroundStyle(.secondary)
                    }
                }

                Section("Metadata") {
                    if let meta = parsedMetadata {
                        metadataRow("Title", meta.title)
                        metadataRow("Artist", meta.artist)
                        metadataRow("Album", meta.album)
                        metadataRow("Album Artist", meta.albumArtist)
                        metadataRow("Genre", meta.genre)
                        metadataRow("Date", meta.date)
                        metadataRow("Track #", meta.trackNumber.map { "\($0)" })
                        metadataRow("Disc #", meta.discNumber.map { "\($0)" })
                        metadataRow("Description", meta.description)
                        metadataRow("Show Name", meta.showName)
                        metadataRow("Season", meta.season.map { "\($0)" })
                        metadataRow("Episode", meta.episode.map { "\($0)" })
                        metadataRow("Copyright", meta.copyright)
                        metadataRow("Publisher", meta.publisher)
                        metadataRow("Language", meta.language)
                        if let url = meta.artworkURL {
                            LabeledContent("Artwork", value: url.absoluteString)
                        }
                    } else {
                        Button("Parse Metadata") {
                            guard let media = player.currentMedia else { return }
                            Task {
                                do { parsedMetadata = try await media.parse() }
                                catch { errorMessage = "Parse failed: \(error)" }
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                }

                Section("All Tracks") {
                    let allTracks = player.audioTracks + player.videoTracks + player.subtitleTracks
                    if allTracks.isEmpty {
                        Text("No tracks").foregroundStyle(.secondary)
                    } else {
                        ForEach(allTracks, id: \.id) { track in
                            HStack {
                                Image(systemName: trackIcon(track.type))
                                    .foregroundStyle(.secondary)
                                    .imageScale(.small)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(track.name).font(.subheadline)
                                    HStack(spacing: 6) {
                                        Text("Codec: \(codecString(track.codec))")
                                        if let lang = track.language { Text(lang) }
                                        if track.bitrate > 0 { Text("\(track.bitrate / 1000) kbps") }
                                        if let w = track.width, let h = track.height { Text("\(w)x\(h)") }
                                        if let ch = track.channels { Text("\(ch)ch") }
                                        if let sr = track.sampleRate { Text("\(sr) Hz") }
                                    }
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                }

                                Spacer()

                                if track.isSelected {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                        .imageScale(.small)
                                }
                            }
                        }
                    }
                }

                Section("Statistics") {
                    if let stats = liveStats {
                        LabeledContent("Read Bytes", value: formatBytes(stats.readBytes))
                        LabeledContent("Input Bitrate", value: String(format: "%.2f kb/s", stats.inputBitrate))
                        LabeledContent("Demux Read", value: formatBytes(stats.demuxReadBytes))
                        LabeledContent("Demux Bitrate", value: String(format: "%.2f kb/s", stats.demuxBitrate))
                        LabeledContent("Demux Corrupted", value: "\(stats.demuxCorrupted)")
                        LabeledContent("Demux Discontinuity", value: "\(stats.demuxDiscontinuity)")
                        LabeledContent("Decoded Video", value: "\(stats.decodedVideo)")
                        LabeledContent("Decoded Audio", value: "\(stats.decodedAudio)")
                        LabeledContent("Displayed Pictures", value: "\(stats.displayedPictures)")
                        LabeledContent("Late Pictures", value: "\(stats.latePictures)")
                        LabeledContent("Lost Pictures", value: "\(stats.lostPictures)")
                        LabeledContent("Played Audio", value: "\(stats.playedAudioBuffers)")
                        LabeledContent("Lost Audio", value: "\(stats.lostAudioBuffers)")
                    } else {
                        Text("No statistics yet").foregroundStyle(.secondary)
                    }
                }

                Section("Programs") {
                    let programs = player.programs
                    if programs.isEmpty {
                        Text("No programs").foregroundStyle(.secondary)
                    } else {
                        ForEach(programs) { program in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(program.name).font(.subheadline)
                                    if program.isScrambled {
                                        Text("Scrambled").font(.caption2).foregroundStyle(.orange)
                                    }
                                }
                                Spacer()
                                if program.isSelected {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                } else {
                                    Button("Select") { player.selectProgram(id: program.id) }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                }
                            }
                        }
                    }
                }

                Section("VLC Info") {
                    LabeledContent("Version", value: VLCInstance.shared.version)
                    LabeledContent("ABI Version", value: "\(VLCInstance.shared.abiVersion)")
                    LabeledContent("Compiler", value: VLCInstance.shared.compiler)
                }
            }
            .navigationTitle("Info")
            .task {
                while !Task.isCancelled {
                    if let media = player.currentMedia {
                        liveStats = media.statistics()
                    }
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        }

        @ViewBuilder
        private func metadataRow(_ label: String, _ value: String?) -> some View {
            if let value, !value.isEmpty {
                LabeledContent(label, value: value)
            }
        }
    }

    // MARK: - Settings: Network

    private struct iOSNetworkSettings: View {
        let player: Player
        @Binding var listPlayer: MediaListPlayer?
        @Binding var mediaList: MediaList
        @Binding var playlistURLs: [String]
        @Binding var errorMessage: String?
        let urlString: String

        @State private var selectedPlaybackMode: PlaybackMode = .default
        @State private var selectedDiscoveryCategory: DiscoveryCategory = .lan
        @State private var discoveryServices: [DiscoveryService] = []
        @State private var activeDiscoverer: MediaDiscoverer?
        @State private var rendererServices: [RendererService] = []
        @State private var activeRendererDiscoverer: RendererDiscoverer?
        @State private var discoveredRenderers: [RendererItem] = []

        var body: some View {
            List {
                Section("Playlist") {
                    HStack {
                        Button("Add Current URL") {
                            guard let url = URL(string: urlString) else { return }
                            do {
                                let media = try Media(url: url)
                                try mediaList.append(media)
                                playlistURLs.append(urlString)
                            } catch { errorMessage = "Failed to add: \(error)" }
                        }
                        .buttonStyle(.bordered)
                        Spacer()
                        Text("\(mediaList.count) items").foregroundStyle(.secondary)
                    }

                    ForEach(Array(playlistURLs.enumerated()), id: \.offset) { idx, url in
                        LabeledContent {
                            Text(url).font(.caption).lineLimit(1).truncationMode(.middle)
                        } label: {
                            Text("\(idx + 1).")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }

                    HStack(spacing: 12) {
                        Button("Play") {
                            if listPlayer == nil {
                                listPlayer = try? MediaListPlayer()
                                listPlayer?.mediaPlayer = player
                            }
                            listPlayer?.mediaList = mediaList
                            listPlayer?.play()
                        }
                        .buttonStyle(.bordered)
                        .disabled(mediaList.count == 0)

                        Button { try? listPlayer?.previous() } label: { Image(systemName: "backward.fill") }
                            .buttonStyle(.bordered).disabled(listPlayer == nil)
                        Button { try? listPlayer?.next() } label: { Image(systemName: "forward.fill") }
                            .buttonStyle(.bordered).disabled(listPlayer == nil)

                        Spacer()

                        Button("Clear") {
                            listPlayer?.stop()
                            mediaList = MediaList()
                            playlistURLs = []
                        }
                        .buttonStyle(.bordered)
                    }

                    Picker("Playback Mode", selection: $selectedPlaybackMode) {
                        Text("Default").tag(PlaybackMode.default)
                        Text("Loop").tag(PlaybackMode.loop)
                        Text("Repeat").tag(PlaybackMode.repeat)
                    }
                    .pickerStyle(.menu)
                    .onChange(of: selectedPlaybackMode) { _, mode in listPlayer?.playbackMode = mode }
                }

                Section("Media Discovery") {
                    Picker("Category", selection: $selectedDiscoveryCategory) {
                        Text("Devices").tag(DiscoveryCategory.devices)
                        Text("LAN").tag(DiscoveryCategory.lan)
                        Text("Podcasts").tag(DiscoveryCategory.podcasts)
                        Text("Local").tag(DiscoveryCategory.localDirectories)
                    }
                    .pickerStyle(.segmented)

                    Button("List Services") {
                        discoveryServices = MediaDiscoverer.availableServices(category: selectedDiscoveryCategory)
                    }
                    .buttonStyle(.bordered)

                    ForEach(discoveryServices, id: \.name) { service in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(service.longName).font(.subheadline)
                                Text(service.name).font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(activeDiscoverer != nil ? "Stop" : "Start") {
                                if activeDiscoverer != nil {
                                    activeDiscoverer?.stop()
                                    activeDiscoverer = nil
                                } else {
                                    do {
                                        let discoverer = try MediaDiscoverer(name: service.name)
                                        try discoverer.start()
                                        activeDiscoverer = discoverer
                                    } catch { errorMessage = "Discovery error: \(error)" }
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }

                    if activeDiscoverer != nil {
                        Text("Discovered: \(activeDiscoverer?.mediaList?.count ?? 0) items")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                Section("Renderer Discovery") {
                    Button("List Renderer Services") {
                        rendererServices = RendererDiscoverer.availableServices()
                    }
                    .buttonStyle(.bordered)

                    ForEach(rendererServices, id: \.name) { service in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(service.longName).font(.subheadline)
                                Text(service.name).font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(activeRendererDiscoverer != nil ? "Stop" : "Start") {
                                if activeRendererDiscoverer != nil {
                                    activeRendererDiscoverer?.stop()
                                    activeRendererDiscoverer = nil
                                    discoveredRenderers = []
                                } else {
                                    do {
                                        let discoverer = try RendererDiscoverer(name: service.name)
                                        try discoverer.start()
                                        activeRendererDiscoverer = discoverer
                                        Task {
                                            for await event in discoverer.events {
                                                switch event {
                                                case let .itemAdded(item): discoveredRenderers.append(item)
                                                case let .itemDeleted(item): discoveredRenderers.removeAll { $0.name == item.name }
                                                }
                                            }
                                        }
                                    } catch { errorMessage = "Renderer error: \(error)" }
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }

                    ForEach(discoveredRenderers, id: \.name) { renderer in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(renderer.name).font(.subheadline)
                                HStack(spacing: 8) {
                                    Text(renderer.type)
                                    if renderer.canVideo { Text("Video") }
                                    if renderer.canAudio { Text("Audio") }
                                }
                                .font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Cast") { try? player.setRenderer(renderer) }
                                .buttonStyle(.bordered).controlSize(.small)
                        }
                    }

                    if !discoveredRenderers.isEmpty {
                        Button("Stop Casting") { try? player.setRenderer(nil) }
                            .buttonStyle(.bordered)
                    }
                }

                Section("DVD Navigation") {
                    VStack {
                        Button { player.navigate(.up) } label: {
                            Image(systemName: "chevron.up")
                        }
                        .buttonStyle(.bordered)

                        HStack {
                            Button { player.navigate(.left) } label: {
                                Image(systemName: "chevron.left")
                            }
                            .buttonStyle(.bordered)

                            Button { player.navigate(.activate) } label: {
                                Text("OK")
                            }
                            .buttonStyle(.borderedProminent)

                            Button { player.navigate(.right) } label: {
                                Image(systemName: "chevron.right")
                            }
                            .buttonStyle(.bordered)
                        }

                        Button { player.navigate(.down) } label: {
                            Image(systemName: "chevron.down")
                        }
                        .buttonStyle(.bordered)

                        Button { player.navigate(.popup) } label: {
                            Label("Popup Menu", systemImage: "list.bullet")
                        }
                        .buttonStyle(.bordered)
                    }
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("Network")
        }
    }

    // MARK: - URL Input Sheet

    private struct iOSURLInputSheet: View {
        @Binding var urlString: String
        let onLoad: () -> Void
        @Environment(\.dismiss) private var dismiss

        var body: some View {
            NavigationStack {
                Form {
                    Section("Media URL") {
                        TextField("Enter URL", text: $urlString)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                            .onSubmit {
                                onLoad()
                                dismiss()
                            }
                    }

                    Section {
                        Button("Load") {
                            onLoad()
                            dismiss()
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .navigationTitle("Open URL")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
            }
            .presentationDetents([.medium])
        }
    }

    // MARK: - Helpers

    private enum iOSAspectRatioOption: Hashable {
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

    private enum iOSDeinterlaceOption: Hashable {
        case auto, off, blend, bob, x, yadif
    }

    private func trackIcon(_ type: TrackType) -> String {
        switch type {
        case .audio: "speaker.wave.2"
        case .video: "film"
        case .subtitle: "captions.bubble"
        case .unknown: "questionmark"
        }
    }

    private func codecString(_ fourcc: Int) -> String {
        guard fourcc != 0 else { return "---" }
        let v = UInt32(fourcc)
        let bytes = [
            UInt8((v >> 24) & 0xFF),
            UInt8((v >> 16) & 0xFF),
            UInt8((v >> 8) & 0xFF),
            UInt8(v & 0xFF),
        ]
        return String(bytes.map { $0 >= 0x20 && $0 < 0x7F ? Character(UnicodeScalar($0)) : Character("?") })
            .trimmingCharacters(in: .whitespaces)
    }

    private func formatDuration(_ duration: Duration) -> String {
        let totalSeconds = Int(duration.milliseconds / 1000)
        let h = totalSeconds / 3600
        let m = (totalSeconds % 3600) / 60
        let s = totalSeconds % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        return formatter.string(fromByteCount: Int64(bytes))
    }

#endif
