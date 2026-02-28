#if os(iOS) || os(macOS)
import SwiftUI
import SwiftVLC

/// Music/podcast player demonstrating SwiftVLC as an audio engine
/// with 10-band equalizer, playback rate, and stereo/mix modes.
struct AudioPlayerDemo: View {
  @State private var player: Player?
  @State private var metadata: Metadata?
  @State private var equalizer: Equalizer?
  @State private var selectedPreset = 0
  @State private var error: Error?

  var body: some View {
    List {
      if error != nil {
        ContentUnavailableView(
          "Playback Failed",
          systemImage: "exclamationmark.triangle",
          description: Text("Could not set up the audio player.")
        )
      } else if let player {
        nowPlayingSection
        playerControlsSection(player)
        speedSection(player)
        equalizerSection
        audioModeSection(player)
      } else {
        ProgressView("Loading...")
          .frame(maxWidth: .infinity)
          .frame(height: 200)
          .listRowBackground(Color.clear)
      }
    }
    #if os(iOS)
    .listStyle(.insetGrouped)
    #endif
    .navigationTitle("Audio Player")
    #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
    #endif
      .task {
        do {
          let p = try Player()
          player = p

          let media = try Media(url: TestMedia.bigBuckBunny)
          metadata = try await media.parse()
          try p.play(media)

          let eq = Equalizer()
          equalizer = eq
          p.equalizer = eq
        } catch {
          self.error = error
        }
      }
      .onDisappear {
        player?.stop()
      }
  }

  // MARK: - Re-apply Equalizer

  /// Must be called after any change to the equalizer object,
  /// because libVLC caches a snapshot — mutations aren't live.
  private func applyEqualizer() {
    guard let equalizer else { return }
    player?.equalizer = equalizer
  }

  // MARK: - Now Playing

  private var nowPlayingSection: some View {
    Section {
      VStack(spacing: 12) {
        artworkView
        metadataView
      }
      .frame(maxWidth: .infinity)
      .padding(.vertical)
    }
    .listRowBackground(Color.clear)
  }

  private var artworkView: some View {
    Group {
      if let artworkURL = metadata?.artworkURL {
        AsyncImage(url: artworkURL) { image in
          image
            .resizable()
            .aspectRatio(contentMode: .fit)
        } placeholder: {
          artworkPlaceholder
        }
      } else {
        artworkPlaceholder
      }
    }
    .frame(maxWidth: 280, maxHeight: 280)
    .clipShape(.rect(cornerRadius: 16))
    .shadow(radius: 8)
  }

  private var artworkPlaceholder: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 16)
        .fill(.quaternary)
      Image(systemName: "music.note")
        .font(.largeTitle)
        .imageScale(.large)
        .foregroundStyle(.secondary)
    }
  }

  private var metadataView: some View {
    VStack(spacing: 4) {
      Text(metadata?.title ?? "Big Buck Bunny")
        .font(.title3)
        .fontWeight(.semibold)
      if let artist = metadata?.artist {
        Text(artist)
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
      if let album = metadata?.album {
        Text(album)
          .font(.caption)
          .foregroundStyle(.tertiary)
      }
    }
    .multilineTextAlignment(.center)
  }

  // MARK: - Player Controls

  private func playerControlsSection(_ player: Player) -> some View {
    Section {
      VStack(spacing: 8) {
        SeekBar(player: player)
        TransportControls(player: player)
      }
      .padding(.vertical, 4)
    }
    .listRowBackground(Color.clear)
  }

  // MARK: - Speed

  private func speedSection(_ player: Player) -> some View {
    Section("Speed") {
      HStack {
        ForEach([0.5, 1.0, 1.5, 2.0], id: \.self) { rate in
          Button {
            player.rate = Float(rate)
          } label: {
            Text("\(rate, specifier: "%.2g")x")
              .font(.subheadline)
              .frame(maxWidth: .infinity)
          }
          .buttonStyle(.bordered)
          .tint(abs(player.rate - Float(rate)) < 0.01 ? .accentColor : .secondary)
        }
      }
    }
  }

  // MARK: - Equalizer

  private var equalizerSection: some View {
    Section {
      Picker("Preset", selection: $selectedPreset) {
        ForEach(Array(Equalizer.presetNames.enumerated()), id: \.offset) { index, name in
          Text(name).tag(index)
        }
      }
      #if os(iOS)
      .pickerStyle(.menu)
      #endif
      .onChange(of: selectedPreset) { _, preset in
        let eq = Equalizer(preset: preset)
        equalizer = eq
        player?.equalizer = eq
      }

      if let equalizer {
        LabeledContent("Preamp") {
          Text("\(equalizer.preamp, specifier: "%.1f") dB")
            .monospacedDigit()
            .contentTransition(.numericText())
        }
        Slider(
          value: Binding(
            get: { Double(equalizer.preamp) },
            set: {
              equalizer.preamp = Float($0)
              applyEqualizer()
            }
          ),
          in: -20...20
        )

        VStack(spacing: 2) {
          HStack(alignment: .bottom, spacing: 4) {
            ForEach(0..<Equalizer.bandCount, id: \.self) { band in
              VStack(spacing: 2) {
                bandSlider(band: band)
                Text(bandLabel(band))
                  .font(.caption2)
                  .foregroundStyle(.tertiary)
              }
            }
          }
          .frame(height: 140)
        }
        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
      }
    } header: {
      Text("Equalizer")
    }
  }

  private func bandSlider(band: Int) -> some View {
    Slider(
      value: Binding(
        get: { Double(equalizer?.amplification(forBand: band) ?? 0) },
        set: {
          try? equalizer?.setAmplification(Float($0), forBand: band)
          applyEqualizer()
        }
      ),
      in: -20...20
    )
    .rotationEffect(.degrees(-90))
    .frame(width: 20, height: 100)
  }

  private func bandLabel(_ band: Int) -> String {
    let freq = Equalizer.bandFrequency(at: band)
    if freq >= 1000 {
      return "\(Int(freq / 1000))k"
    }
    return "\(Int(freq))"
  }

  // MARK: - Audio Mode

  private func audioModeSection(_ player: Player) -> some View {
    Section("Audio") {
      Picker("Stereo", selection: Binding(
        get: { player.stereoMode },
        set: { player.stereoMode = $0 }
      )) {
        Text("Default").tag(StereoMode.unset)
        Text("Stereo").tag(StereoMode.stereo)
        Text("Mono").tag(StereoMode.mono)
        Text("Reverse").tag(StereoMode.reverseStereo)
        Text("Left").tag(StereoMode.left)
        Text("Right").tag(StereoMode.right)
      }
      #if os(iOS)
      .pickerStyle(.menu)
      #endif

      Picker("Mix", selection: Binding(
        get: { player.mixMode },
        set: { player.mixMode = $0 }
      )) {
        Text("Default").tag(MixMode.unset)
        Text("Stereo").tag(MixMode.stereo)
        Text("Binaural").tag(MixMode.binaural)
        Text("5.1").tag(MixMode.fivePointOne)
        Text("7.1").tag(MixMode.sevenPointOne)
      }
      #if os(iOS)
      .pickerStyle(.menu)
      #endif

      LabeledContent("Volume") {
        Text("\(Int(player.volume * 100))%")
          .monospacedDigit()
          .contentTransition(.numericText())
      }
      Slider(
        value: Binding(
          get: { Double(player.volume) },
          set: { player.volume = Float($0) }
        ),
        in: 0...1.25
      )

      Toggle("Muted", isOn: Binding(
        get: { player.isMuted },
        set: { player.isMuted = $0 }
      ))
    }
  }
}
#endif
