import XCTest
@testable import Macget

final class MediaFormatTests: XCTestCase {

    func test_decodesYtDlpJSON_andSortsVideoFormats() throws {
        let json = """
        {
          "title": "My Clip",
          "ext": "mp4",
          "is_live": false,
          "formats": [
            {"format_id": "140", "ext": "m4a", "acodec": "mp4a", "vcodec": "none", "filesize": 4000000},
            {"format_id": "137", "ext": "mp4", "height": 1080, "vcodec": "avc1", "acodec": "none", "filesize": 148000000, "tbr": 4500.0},
            {"format_id": "136", "ext": "mp4", "height": 720, "vcodec": "avc1", "acodec": "none", "filesize_approx": 82000000, "tbr": 2500.0}
          ]
        }
        """.data(using: .utf8)!

        let info = try JSONDecoder().decode(MediaInfo.self, from: json)
        XCTAssertEqual(info.title, "My Clip")
        XCTAssertEqual(info.formats?.count, 3)

        let videos = info.videoFormats
        XCTAssertEqual(videos.map(\.formatID), ["137", "136"], "audio-only dropped, sorted by height desc")
        XCTAssertEqual(videos.first?.estimatedBytes, 148_000_000)
        XCTAssertTrue(videos.first!.displayLabel.contains("1080p"))
    }

    func test_pickerOptions_dedupesByResolution_andBuildsSelectors() throws {
        let json = """
        {
          "title": "Clip", "ext": "mp4",
          "formats": [
            {"format_id": "137", "ext": "mp4", "height": 1080, "vcodec": "avc1", "acodec": "none", "tbr": 4500.0, "filesize": 148000000},
            {"format_id": "248", "ext": "webm", "height": 1080, "vcodec": "vp9", "acodec": "none", "tbr": 3000.0},
            {"format_id": "136", "ext": "mp4", "height": 720, "vcodec": "avc1", "acodec": "none", "tbr": 2500.0},
            {"format_id": "18",  "ext": "mp4", "height": 360, "vcodec": "avc1", "acodec": "mp4a", "tbr": 700.0},
            {"format_id": "140", "ext": "m4a", "height": null, "vcodec": "none", "acodec": "mp4a"}
          ]
        }
        """.data(using: .utf8)!
        let info = try JSONDecoder().decode(MediaInfo.self, from: json)
        let opts = info.pickerOptions

        // One per distinct height (1080 kept the higher-bitrate 137, not 248) + audio.
        XCTAssertEqual(opts.map(\.id), ["137", "136", "18", "audio"])
        // Adaptive (video-only) merges bestaudio; progressive (18) and audio don't.
        XCTAssertEqual(opts[0].selector, "137+bestaudio/137")
        XCTAssertEqual(opts[1].selector, "136+bestaudio/136")
        XCTAssertEqual(opts[2].selector, "18")
        XCTAssertEqual(opts[3].selector, "bestaudio/best")
        XCTAssertTrue(opts[0].label.contains("1080p"))
    }

    func test_audioOnlyFormat_flags() throws {
        let f = MediaFormat(formatID: "140", ext: "m4a", height: nil, width: nil, fps: nil, tbr: nil,
                            vcodec: "none", acodec: "mp4a", filesize: 4_000_000, filesizeApprox: nil, formatNote: nil)
        XCTAssertFalse(f.hasVideo)
        XCTAssertTrue(f.hasAudio)
        XCTAssertTrue(f.displayLabel.contains("audio only"))
    }
}

final class YtDlpProgressParserTests: XCTestCase {

    func test_parsesProgressLine() {
        let line = "macget-progress:1048576/10485760/10485760/524288.0/18.0"
        let p = YtDlpRunner.parseProgress(line)
        XCTAssertEqual(p?.downloaded, 1_048_576)
        XCTAssertEqual(p?.total, 10_485_760)
        XCTAssertEqual(p?.speed, 524_288.0)
        XCTAssertEqual(p?.eta, 18.0)
    }

    func test_fallsBackToEstimateWhenTotalNA() {
        let line = "macget-progress:500/NA/2048/NA/NA"
        let p = YtDlpRunner.parseProgress(line)
        XCTAssertEqual(p?.downloaded, 500)
        XCTAssertEqual(p?.total, 2048, "uses total_bytes_estimate when total_bytes is NA")
        XCTAssertNil(p?.speed)
        XCTAssertNil(p?.eta)
    }

    func test_nonProgressLineIgnored() {
        XCTAssertNil(YtDlpRunner.parseProgress("/Users/me/Downloads/clip.mp4"))
        XCTAssertNil(YtDlpRunner.parseProgress("[download] Destination: clip.mp4"))
    }

    func test_extractsOutputPathFromStdout() {
        let stdout = """
        macget-progress:10/100/100/5.0/1.0
        macget-progress:100/100/100/5.0/0.0
        /Users/me/Downloads/My_Clip.mp4
        """
        XCTAssertEqual(YtDlpRunner.outputPath(fromStdout: stdout), "/Users/me/Downloads/My_Clip.mp4")
    }
}

final class MediaToolLocatorTests: XCTestCase {

    private func makeExecutable(_ name: String, in dir: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        fm.createFile(atPath: url.path, contents: Data("#!/bin/sh\n".utf8))
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    func test_prefersFirstDirectoryWithYtDlp_andFindsFfmpegAcrossDirs() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mtl-\(UUID().uuidString)")
        let dirA = root.appendingPathComponent("a")
        let dirB = root.appendingPathComponent("b")
        defer { try? FileManager.default.removeItem(at: root) }

        try makeExecutable("yt-dlp", in: dirA)
        try makeExecutable("ffmpeg", in: dirB)   // ffmpeg only in the second dir

        let tools = MediaToolLocator.resolve(in: [dirA, dirB])
        XCTAssertEqual(tools?.ytDlp.path, dirA.appendingPathComponent("yt-dlp").path)
        XCTAssertEqual(tools?.ffmpegDir?.path, dirB.path)
    }

    func test_returnsNilWhenNoYtDlp() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mtl-\(UUID().uuidString)")
        let dir = root.appendingPathComponent("a")
        defer { try? FileManager.default.removeItem(at: root) }
        try makeExecutable("ffmpeg", in: dir)   // no yt-dlp
        XCTAssertNil(MediaToolLocator.resolve(in: [dir]))
    }
}

final class CaptureRequestRoutingTests: XCTestCase {

    func test_oldPayloadWithoutKind_decodesAsFile() throws {
        let json = #"{"url":"https://example.com/a.zip","filename":"a.zip"}"#.data(using: .utf8)!
        let req = try JSONDecoder().decode(CaptureRequest.self, from: json)
        XCTAssertNil(req.kind)                          // absent → treated as .file downstream
        XCTAssertEqual(req.kind ?? .file, .file)
        XCTAssertEqual(req.url, "https://example.com/a.zip")
    }

    func test_mediaPayload_decodesWithFields() throws {
        let json = #"""
        {"url":"https://youtube.com/watch?v=abc","kind":"media","pageURL":"https://youtube.com/watch?v=abc","title":"Clip","manifestURLs":["https://cdn/x.m3u8"]}
        """#.data(using: .utf8)!
        let req = try JSONDecoder().decode(CaptureRequest.self, from: json)
        XCTAssertEqual(req.kind, .media)
        XCTAssertEqual(req.pageURL, "https://youtube.com/watch?v=abc")
        XCTAssertEqual(req.title, "Clip")
        XCTAssertEqual(req.manifestURLs, ["https://cdn/x.m3u8"])
    }
}

final class DownloadMediaCodableTests: XCTestCase {

    func test_mediaDownloadRoundTrips() throws {
        let d = Download(
            url: URL(string: "https://youtube.com/watch?v=abc")!,
            destinationFolder: URL(fileURLWithPath: "/tmp"),
            filename: "clip.mp4",
            kind: .media,
            pageURL: URL(string: "https://youtube.com/watch?v=abc")!,
            formatSelector: "bestvideo+bestaudio"
        )
        let data = try JSONEncoder().encode(d)
        let back = try JSONDecoder().decode(Download.self, from: data)
        XCTAssertEqual(back.kind, .media)
        XCTAssertEqual(back.pageURL, d.pageURL)
        XCTAssertEqual(back.formatSelector, "bestvideo+bestaudio")
    }

    func test_legacyJSONWithoutKind_decodesAsHttpFile() throws {
        // A queue.json entry written before `kind` existed (minimal required keys).
        let json = """
        {
          "id": "\(UUID().uuidString)",
          "url": "https://example.com/a.zip",
          "destinationFolder": "file:///tmp/",
          "filename": "a.zip",
          "status": "completed",
          "threadCount": 8,
          "supportsRange": true,
          "chunks": [],
          "createdAt": 0
        }
        """.data(using: .utf8)!
        let back = try JSONDecoder().decode(Download.self, from: json)
        XCTAssertEqual(back.kind, .httpFile)
        XCTAssertNil(back.pageURL)
    }
}
