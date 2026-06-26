import XCTest
@testable import Macget

final class MediaURLClassifierTests: XCTestCase {

    private func isMedia(_ s: String) -> Bool {
        MediaURLClassifier.isMediaURL(URL(string: s)!)
    }

    func test_youtubeHosts() {
        XCTAssertTrue(isMedia("https://www.youtube.com/watch?v=dQw4w9WgXcQ"))
        XCTAssertTrue(isMedia("https://youtube.com/watch?v=abc"))
        XCTAssertTrue(isMedia("https://m.youtube.com/watch?v=abc"))
        XCTAssertTrue(isMedia("https://youtu.be/abc"))
        XCTAssertTrue(isMedia("https://www.youtube-nocookie.com/embed/abc"))
    }

    func test_otherMediaHosts() {
        XCTAssertTrue(isMedia("https://vimeo.com/123456"))
        XCTAssertTrue(isMedia("https://clips.twitch.tv/SomeClip"))
        XCTAssertTrue(isMedia("https://www.dailymotion.com/video/x123"))
        XCTAssertTrue(isMedia("https://dai.ly/x123"))
        XCTAssertTrue(isMedia("https://www.tiktok.com/@user/video/123"))
        XCTAssertTrue(isMedia("https://soundcloud.com/artist/track"))
    }

    func test_nonMediaHosts() {
        XCTAssertFalse(isMedia("https://example.com/file.zip"))
        XCTAssertFalse(isMedia("https://github.com/owner/repo/releases/download/v1/app.dmg"))
        XCTAssertFalse(isMedia("https://cdn.example.com/video.mp4"))
    }

    func test_doesNotMatchLookalikeSuffix() {
        // A host that merely *contains* an allow-listed name must not match.
        XCTAssertFalse(isMedia("https://youtube.com.evil.example/watch?v=abc"))
        XCTAssertFalse(isMedia("https://notyoutube.com/watch?v=abc"))
        XCTAssertFalse(isMedia("https://myyoutu.be/abc"))
    }

    func test_caseInsensitiveHost() {
        XCTAssertTrue(isMedia("https://WWW.YouTube.com/watch?v=abc"))
    }

    private func isPlaylist(_ s: String) -> Bool {
        MediaURLClassifier.isLikelyPlaylist(URL(string: s)!)
    }

    func test_playlistDetection_youtube() {
        XCTAssertTrue(isPlaylist("https://www.youtube.com/playlist?list=PL123"))
        XCTAssertTrue(isPlaylist("https://www.youtube.com/feed?list=PL123"), "list with no v is a playlist")
        // A video that merely sits in a playlist is treated as a single video.
        XCTAssertFalse(isPlaylist("https://www.youtube.com/watch?v=abc&list=PL123"))
        XCTAssertFalse(isPlaylist("https://www.youtube.com/watch?v=abc"))
    }

    func test_playlistDetection_otherHosts() {
        XCTAssertTrue(isPlaylist("https://soundcloud.com/artist/sets/my-mix"))
        XCTAssertFalse(isPlaylist("https://soundcloud.com/artist/track"))
        XCTAssertTrue(isPlaylist("https://example.com/playlist/123"))
        XCTAssertFalse(isPlaylist("https://example.com/video/123"))
    }
}
