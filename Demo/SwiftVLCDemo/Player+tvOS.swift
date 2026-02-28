#if os(tvOS)
    import SwiftUI
    import SwiftVLC

    // MARK: - tvOS Player View

    struct TVPlayerView: View {
        @State private var player: Player?
        @State private var urlString = "https://pub-79c73cda2d324e97b277e8a2f351acac.r2.dev/media/TOS.mkv"
        @State private var errorMessage: String?
        @State private var didAutoLoad = false

        @State private var uiState = TVPlayerUIState()

        @State private var equalizer: Equalizer?
        @State private var eqEnabled = false
        @State private var selectedPreset: UInt32 = 0
        @State private var abPointA: Duration?

        var body: some View {
            ZStack {
                Color.black.ignoresSafeArea()

                if let player {
                    VideoView(player)
                        .ignoresSafeArea()
                        .onAppear {
                            if !didAutoLoad {
                                didAutoLoad = true
                                loadMedia(player: player)
                            }
                        }

                    if case .buffering = player.state {
                        ProgressView()
                            .scaleEffect(1.5)
                            .tint(.white)
                    }

                    if uiState.overlay == .transport {
                        transportOverlay(player: player)
                            .transition(.opacity)
                    }

                    if uiState.overlay == .infoPanel {
                        infoPanelOverlay(player: player)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }

                    if let errorMessage {
                        VStack {
                            Text(errorMessage)
                                .font(.headline)
                                .foregroundStyle(.white)
                                .padding()
                                .background(.red.opacity(0.8), in: RoundedRectangle(cornerRadius: 12))
                                .padding(.top, 80)
                            Spacer()
                        }
                    }
                } else {
                    ProgressView().scaleEffect(1.5).tint(.white)
                }
            }
            .onPlayPauseCommand {
                guard let player else { return }
                player.togglePlayPause()
                showTransport()
            }
            .onExitCommand {
                withAnimation {
                    switch uiState.overlay {
                    case .infoPanel: uiState.overlay = .transport
                    case .transport: uiState.overlay = .hidden
                    case .hidden: break
                    }
                }
            }
            .onMoveCommand { direction in
                guard let player else { return }
                switch direction {
                case .down:
                    if uiState.overlay == .transport {
                        withAnimation { uiState.overlay = .infoPanel }
                    } else if uiState.overlay == .hidden {
                        showTransport()
                    }
                case .up:
                    if uiState.overlay == .infoPanel {
                        withAnimation { uiState.overlay = .transport }
                    } else if uiState.overlay == .hidden {
                        showTransport()
                    }
                case .left:
                    if uiState.overlay == .hidden || uiState.overlay == .transport {
                        player.seek(by: .seconds(-15))
                        showTransport()
                    }
                case .right:
                    if uiState.overlay == .hidden || uiState.overlay == .transport {
                        player.seek(by: .seconds(15))
                        showTransport()
                    }
                @unknown default: break
                }
            }
            .task {
                if player == nil {
                    do { player = try Player() }
                    catch { errorMessage = "Failed to create player: \(error)" }
                }
            }
        }

        // MARK: - Transport Overlay

        private func transportOverlay(player: Player) -> some View {
            VStack {
                HStack {
                    if let media = player.currentMedia, let mrl = media.mrl {
                        Text(URL(string: mrl)?.lastPathComponent ?? mrl)
                            .font(.title3.weight(.medium))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                    }
                    Spacer()
                    Text(player.state.description)
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.7))
                }
                .padding(.horizontal, 80)
                .padding(.top, 60)

                Spacer()

                VStack(spacing: 16) {
                    tvProgressBar(player: player)
                        .padding(.horizontal, 80)

                    HStack {
                        Text(formatDuration(player.currentTime))
                        Spacer()
                        if player.rate != 1.0 {
                            Text(String(format: "%gx", player.rate))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(.white.opacity(0.2), in: Capsule())
                        }
                        Spacer()
                        if let duration = player.duration {
                            let remaining = Duration.milliseconds(max(0, duration.milliseconds - player.currentTime.milliseconds))
                            Text("-" + formatDuration(remaining))
                        }
                    }
                    .font(.system(.title3, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(.horizontal, 80)
                }
                .padding(.bottom, 60)
            }
            .background(alignment: .top) {
                LinearGradient(colors: [.black.opacity(0.6), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: 200)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }
            .background(alignment: .bottom) {
                LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 250)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }
        }

        private func tvProgressBar(player: Player) -> some View {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.white.opacity(0.3))
                        .frame(height: 6)

                    Capsule()
                        .fill(.white)
                        .frame(width: max(0, geo.size.width * player.position), height: 6)

                    if player.chapterCount > 1 {
                        ForEach(player.chapters(), id: \.index) { chapter in
                            if let duration = player.duration, duration.milliseconds > 0 {
                                let pos = Double(chapter.timeOffset.milliseconds) / Double(duration.milliseconds)
                                Rectangle()
                                    .fill(.white.opacity(0.5))
                                    .frame(width: 2, height: 10)
                                    .offset(x: geo.size.width * pos)
                            }
                        }
                    }
                }
                .frame(maxHeight: .infinity)
            }
            .frame(height: 20)
        }

        // MARK: - Info Panel

        private func infoPanelOverlay(player: Player) -> some View {
            VStack(spacing: 0) {
                Spacer()

                VStack(spacing: 0) {
                    tvTabBar

                    Divider().background(.white.opacity(0.2))

                    ScrollView {
                        Group {
                            switch uiState.selectedTab {
                            case .audio: audioPanel(player: player)
                            case .subtitles: subtitlesPanel(player: player)
                            case .speed: speedPanel(player: player)
                            case .video: videoPanel(player: player)
                            case .advanced: advancedPanel(player: player)
                            }
                        }
                        .padding(40)
                    }
                }
                .frame(height: 500)
                .background(.ultraThinMaterial)
            }
            .ignoresSafeArea()
        }

        private var tvTabBar: some View {
            HStack(spacing: 24) {
                ForEach(TVInfoTab.allCases, id: \.self) { tab in
                    Button {
                        withAnimation { uiState.selectedTab = tab }
                    } label: {
                        Text(tab.rawValue)
                            .font(.title3.weight(uiState.selectedTab == tab ? .semibold : .regular))
                            .foregroundStyle(uiState.selectedTab == tab ? .white : .white.opacity(0.6))
                            .padding(.horizontal, 20)
                            .padding(.vertical, 10)
                            .background(uiState.selectedTab == tab ? Color.blue : Color.clear, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 16)
        }

        // MARK: - Audio Panel

        private func audioPanel(player: Player) -> some View {
            VStack(alignment: .leading, spacing: 16) {
                Text("Audio Tracks").font(.title3.weight(.medium)).foregroundStyle(.white)
                if player.audioTracks.isEmpty {
                    Text("No audio tracks").font(.title3).foregroundStyle(.secondary)
                } else {
                    ForEach(player.audioTracks, id: \.id) { track in
                        Button {
                            player.selectedAudioTrack = track
                        } label: {
                            HStack {
                                Text(track.name).font(.title3)
                                Spacer()
                                if track.isSelected {
                                    Image(systemName: "checkmark").foregroundStyle(.blue)
                                }
                            }
                            .padding(.vertical, 8)
                            .padding(.horizontal, 16)
                        }
                        .buttonStyle(TVListRowStyle())
                    }
                }
            }
        }

        // MARK: - Subtitles Panel

        private func subtitlesPanel(player: Player) -> some View {
            VStack(alignment: .leading, spacing: 16) {
                Text("Subtitles").font(.title3.weight(.medium)).foregroundStyle(.white)

                Button {
                    player.selectedSubtitleTrack = nil
                } label: {
                    HStack {
                        Text("Off").font(.title3)
                        Spacer()
                        if player.selectedSubtitleTrack == nil {
                            Image(systemName: "checkmark").foregroundStyle(.blue)
                        }
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 16)
                }
                .buttonStyle(TVListRowStyle())

                ForEach(player.subtitleTracks, id: \.id) { track in
                    Button {
                        player.selectedSubtitleTrack = track
                    } label: {
                        HStack {
                            Text(track.name).font(.title3)
                            Spacer()
                            if track.isSelected {
                                Image(systemName: "checkmark").foregroundStyle(.blue)
                            }
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 16)
                    }
                    .buttonStyle(TVListRowStyle())
                }
            }
        }

        // MARK: - Speed Panel

        private func speedPanel(player: Player) -> some View {
            VStack(alignment: .leading, spacing: 16) {
                Text("Playback Speed").font(.title3.weight(.medium)).foregroundStyle(.white)

                let speeds: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 16)], spacing: 16) {
                    ForEach(speeds, id: \.self) { speed in
                        Button {
                            player.rate = speed
                        } label: {
                            Text(speed == 1.0 ? "Normal" : String(format: "%gx", speed))
                                .font(.title3.weight(.medium))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 16)
                        }
                        .buttonStyle(TVSelectionButtonStyle(isSelected: player.rate == speed))
                    }
                }
            }
        }

        // MARK: - Video Panel

        private func videoPanel(player: Player) -> some View {
            VStack(alignment: .leading, spacing: 24) {
                Text("Aspect Ratio").font(.title3.weight(.medium)).foregroundStyle(.white)

                let ratios: [(String, AspectRatio)] = [
                    ("Default", .default), ("4:3", .ratio(4, 3)), ("16:9", .ratio(16, 9)),
                    ("16:10", .ratio(16, 10)), ("21:9", .ratio(21, 9)), ("Fill", .fill),
                ]
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 16)], spacing: 16) {
                    ForEach(ratios, id: \.0) { name, ratio in
                        Button {
                            player.aspectRatio = ratio
                        } label: {
                            Text(name)
                                .font(.title3.weight(.medium))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 16)
                        }
                        .buttonStyle(TVSelectionButtonStyle(isSelected: player.aspectRatio == ratio))
                    }
                }

                Divider().background(.white.opacity(0.2))

                Text("Adjustments").font(.title3.weight(.medium)).foregroundStyle(.white)

                Toggle("Enable Adjustments", isOn: Binding(
                    get: { player.adjustments.isEnabled },
                    set: { player.adjustments.isEnabled = $0 }
                ))
                .font(.title3)

                if player.adjustments.isEnabled {
                    TVStepperRow(title: "Contrast", value: Binding(
                        get: { player.adjustments.contrast },
                        set: { player.adjustments.contrast = $0 }
                    ), range: 0 ... 2, step: 0.1, format: "%.2f")

                    TVStepperRow(title: "Brightness", value: Binding(
                        get: { player.adjustments.brightness },
                        set: { player.adjustments.brightness = $0 }
                    ), range: 0 ... 2, step: 0.1, format: "%.2f")

                    TVStepperRow(title: "Hue", value: Binding(
                        get: { player.adjustments.hue },
                        set: { player.adjustments.hue = $0 }
                    ), range: 0 ... 360, step: 10, format: "%.0f")

                    TVStepperRow(title: "Saturation", value: Binding(
                        get: { player.adjustments.saturation },
                        set: { player.adjustments.saturation = $0 }
                    ), range: 0 ... 3, step: 0.1, format: "%.2f")

                    TVStepperRow(title: "Gamma", value: Binding(
                        get: { player.adjustments.gamma },
                        set: { player.adjustments.gamma = $0 }
                    ), range: 0.01 ... 10, step: 0.1, format: "%.2f")
                }
            }
        }

        // MARK: - Advanced Panel

        private func advancedPanel(player: Player) -> some View {
            VStack(alignment: .leading, spacing: 24) {
                // EQ Presets
                Text("Equalizer").font(.title3.weight(.medium)).foregroundStyle(.white)

                Toggle("Enable Equalizer", isOn: $eqEnabled)
                    .font(.title3)
                    .onChange(of: eqEnabled) { _, enabled in
                        if enabled {
                            if equalizer == nil { equalizer = Equalizer(preset: selectedPreset) }
                            _ = player.setEqualizer(equalizer)
                        } else {
                            _ = player.setEqualizer(nil)
                        }
                    }

                if eqEnabled {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 12)], spacing: 12) {
                        ForEach(0 ..< Equalizer.presetCount, id: \.self) { i in
                            Button {
                                selectedPreset = i
                                equalizer = Equalizer(preset: i)
                                _ = player.setEqualizer(equalizer)
                            } label: {
                                Text(Equalizer.presetName(at: i) ?? "Preset \(i)")
                                    .font(.callout)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 10)
                            }
                            .buttonStyle(TVSelectionButtonStyle(isSelected: selectedPreset == i))
                        }
                    }
                }

                Divider().background(.white.opacity(0.2))

                // Stereo & Mix
                Text("Audio Modes").font(.title3.weight(.medium)).foregroundStyle(.white)
                HStack(spacing: 12) {
                    ForEach([
                        ("Stereo", StereoMode.stereo), ("Mono", StereoMode.mono),
                        ("Left", StereoMode.left), ("Right", StereoMode.right),
                    ], id: \.0) { name, mode in
                        Button {
                            player.stereoMode = mode
                        } label: {
                            Text(name).font(.callout).frame(maxWidth: .infinity).padding(.vertical, 10)
                        }
                        .buttonStyle(TVSelectionButtonStyle(isSelected: player.stereoMode == mode))
                    }
                }

                Divider().background(.white.opacity(0.2))

                // Chapters
                if player.chapterCount > 0 {
                    Text("Chapters").font(.title3.weight(.medium)).foregroundStyle(.white)
                    HStack(spacing: 16) {
                        Button { player.previousChapter() } label: {
                            Label("Previous", systemImage: "chevron.left").font(.title3)
                        }
                        Button { player.nextChapter() } label: {
                            Label("Next", systemImage: "chevron.right").font(.title3)
                        }
                    }
                    ForEach(player.chapters(), id: \.index) { chapter in
                        Button {
                            player.currentChapter = chapter.index
                        } label: {
                            HStack {
                                Text(chapter.name ?? "Chapter \(chapter.index)").font(.title3)
                                Spacer()
                                Text(formatDuration(chapter.timeOffset)).font(.caption).foregroundStyle(.secondary)
                                if player.currentChapter == chapter.index {
                                    Image(systemName: "checkmark").foregroundStyle(.blue)
                                }
                            }
                            .padding(.vertical, 6)
                            .padding(.horizontal, 16)
                        }
                        .buttonStyle(TVListRowStyle())
                    }

                    Divider().background(.white.opacity(0.2))
                }

                // A-B Loop
                Text("A-B Loop").font(.title3.weight(.medium)).foregroundStyle(.white)
                Text("State: \(player.abLoopState.description)").font(.title3).foregroundStyle(.secondary)
                HStack(spacing: 16) {
                    Button(abPointA == nil ? "Set A" : "Set B") {
                        if let a = abPointA {
                            _ = player.setABLoop(a: a, b: player.currentTime)
                            abPointA = nil
                        } else {
                            abPointA = player.currentTime
                        }
                    }
                    .font(.title3)

                    Button("Clear") {
                        _ = player.resetABLoop()
                        abPointA = nil
                    }
                    .font(.title3)
                }

                Divider().background(.white.opacity(0.2))

                // Deinterlace
                Text("Deinterlace").font(.title3.weight(.medium)).foregroundStyle(.white)
                let deinterlaceOptions = [("Auto", -1, nil as String?), ("Off", 0, nil), ("Blend", 1, "blend"), ("Bob", 1, "bob"), ("Yadif", 1, "yadif")]
                HStack(spacing: 12) {
                    ForEach(deinterlaceOptions, id: \.0) { name, state, mode in
                        Button {
                            _ = player.setDeinterlace(state: state, mode: mode)
                        } label: {
                            Text(name).font(.callout).frame(maxWidth: .infinity).padding(.vertical, 10)
                        }
                        .buttonStyle(.bordered)
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
            } catch {
                errorMessage = "Error: \(error)"
            }
        }

        private func showTransport() {
            withAnimation(.easeIn(duration: 0.25)) { uiState.overlay = .transport }
            scheduleHideTransport()
        }

        private func scheduleHideTransport() {
            uiState.hideTask?.cancel()
            guard let player, player.isPlaying else { return }
            let p = player
            uiState.hideTask = Task {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                if p.isPlaying {
                    withAnimation(.easeOut(duration: 0.3)) { uiState.overlay = .hidden }
                }
            }
        }
    }

    // MARK: - UI State

    @Observable
    final class TVPlayerUIState: @unchecked Sendable {
        var overlay: TVOverlayState = .hidden
        var selectedTab: TVInfoTab = .audio
        var hideTask: Task<Void, Never>?
    }

    enum TVOverlayState {
        case hidden, transport, infoPanel
    }

    enum TVInfoTab: String, CaseIterable {
        case audio = "Audio"
        case subtitles = "Subtitles"
        case speed = "Speed"
        case video = "Video"
        case advanced = "Advanced"
    }

    // MARK: - Custom Controls

    private struct TVStepperRow: View {
        let title: String
        @Binding var value: Float
        let range: ClosedRange<Float>
        let step: Float
        let format: String

        var body: some View {
            HStack(spacing: 16) {
                Text(title).font(.title3).frame(width: 140, alignment: .leading)

                Button {
                    value = max(range.lowerBound, value - step)
                } label: {
                    Image(systemName: "minus.circle.fill").font(.title2)
                }
                .buttonStyle(.plain)

                Text(String(format: format, value))
                    .font(.title3.monospacedDigit())
                    .frame(width: 80)

                Button {
                    value = min(range.upperBound, value + step)
                } label: {
                    Image(systemName: "plus.circle.fill").font(.title2)
                }
                .buttonStyle(.plain)

                Spacer()

                Button("Reset") {
                    let mid = (range.lowerBound + range.upperBound) / 2
                    value = title == "Hue" ? 0 : (title == "Gamma" ? 1 : mid <= 1 ? 1 : mid)
                }
                .font(.callout)
            }
        }
    }

    private struct TVSelectionButtonStyle: ButtonStyle {
        let isSelected: Bool

        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .background(isSelected ? Color.blue : Color.white.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
                .foregroundStyle(isSelected ? .white : .white.opacity(0.8))
                .scaleEffect(configuration.isPressed ? 1.05 : 1.0)
        }
    }

    private struct TVListRowStyle: ButtonStyle {
        @Environment(\.isFocused) private var isFocused

        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(isFocused ? Color.white.opacity(0.15) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    // MARK: - Helpers

    private func formatDuration(_ duration: Duration) -> String {
        let totalSeconds = Int(duration.milliseconds / 1000)
        let h = totalSeconds / 3600
        let m = (totalSeconds % 3600) / 60
        let s = totalSeconds % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

#endif
