import Foundation
@testable import SwiftVLC
import Testing

@Suite("VLCInstance")
struct VLCInstanceTests {
    @Test("Shared instance returns non-empty version")
    func version() {
        let version = VLCInstance.shared.version
        #expect(!version.isEmpty)
        #expect(version.contains("."))
    }

    @Test("ABI version is positive")
    func abiVersion() {
        #expect(VLCInstance.shared.abiVersion > 0)
    }

    @Test("Compiler info is available")
    func compiler() {
        #expect(!VLCInstance.shared.compiler.isEmpty)
    }

    @Test("Custom instance can be created")
    func customInstance() throws {
        let instance = try VLCInstance(arguments: ["--no-video-title-show"])
        #expect(!instance.version.isEmpty)
    }
}

@Suite("Media")
struct MediaTests {
    @Test("Create media from file path")
    func createFromPath() throws {
        // This tests that the Media initializer works with the C API.
        // With the stub binary this will link-fail, but the types compile.
        let media = try Media(path: "/dev/null")
        #expect(media.mrl != nil)
    }

    @Test("Create media from URL")
    func createFromURL() throws {
        let url = try #require(URL(string: "file:///dev/null"))
        let media = try Media(url: url)
        #expect(media.mrl != nil)
    }
}

@Suite("PlayerState")
struct PlayerStateTests {
    @Test("State descriptions")
    func descriptions() {
        #expect(PlayerState.idle.description == "idle")
        #expect(PlayerState.playing.description == "playing")
        #expect(PlayerState.buffering(0.5).description == "buffering(50%)")
        #expect(PlayerState.ended.description == "ended")
    }
}

@Suite("Track")
struct TrackTests {
    @Test("TrackType descriptions")
    func trackTypeDescriptions() {
        #expect(TrackType.audio.description == "audio")
        #expect(TrackType.video.description == "video")
        #expect(TrackType.subtitle.description == "subtitle")
    }
}

@Suite("AspectRatio")
struct AspectRatioTests {
    @Test("VLC string representation")
    func vlcString() {
        #expect(AspectRatio.default.vlcString == nil)
        #expect(AspectRatio.ratio(16, 9).vlcString == "16:9")
        #expect(AspectRatio.ratio(4, 3).vlcString == "4:3")
        #expect(AspectRatio.fill.vlcString == nil)
    }
}
