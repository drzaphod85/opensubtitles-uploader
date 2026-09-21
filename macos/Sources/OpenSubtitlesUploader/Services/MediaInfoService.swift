import Foundation
import AVFoundation

struct MediaInfo {
    var durationMs: Int?
    var frameRate: Double?
    var frameCount: Int?
    var width: Int?
    var height: Int?

    var frameRateString: String? {
        guard let frameRate else { return nil }
        var s = String(format: "%.3f", frameRate)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }

    /// Same heuristic as the original: 720p or more, or a wide-screen picture with a cropped cinebar.
    var isHighDefinition: Bool {
        if let height, height >= 720 { return true }
        if let width, let height, width >= 1280, height >= 536 { return true }
        return false
    }
}

/// Replacement for the `mediainfo` binaries bundled with the HTML5 version.
/// Uses AVFoundation (native) and falls back to `mediainfo` / `ffprobe` when they are
/// installed (e.g. through Homebrew), which covers containers AVFoundation can't open such as MKV.
enum MediaInfoService {
    static func analyze(_ url: URL) async -> MediaInfo {
        var info = await analyzeWithAVFoundation(url)
        if info.durationMs == nil || info.frameRate == nil {
            if let external = analyzeWithExternalTool(url) {
                info = external
            }
        }
        if info.frameCount == nil, let fps = info.frameRate, let ms = info.durationMs {
            info.frameCount = Int((Double(ms) / 1000 * fps).rounded())
        }
        return info
    }

    private static func analyzeWithAVFoundation(_ url: URL) async -> MediaInfo {
        var info = MediaInfo()
        let asset = AVURLAsset(url: url)
        do {
            let duration = try await asset.load(.duration)
            if duration.isNumeric, duration.seconds.isFinite {
                info.durationMs = Int(duration.seconds * 1000)
            }
            if let track = try await asset.loadTracks(withMediaType: .video).first {
                let (fps, size) = try await track.load(.nominalFrameRate, .naturalSize)
                if fps > 0 { info.frameRate = Double(fps) }
                if size.width > 0 { info.width = Int(size.width) }
                if size.height > 0 { info.height = Int(size.height) }
            }
        } catch {
            AppLog.error("AVFoundation could not read \(url.lastPathComponent): \(error.localizedDescription)")
        }
        return info
    }

    // MARK: External tools

    static var hasExternalTool: Bool { findTool("mediainfo") != nil || findTool("ffprobe") != nil }

    private static func findTool(_ name: String) -> String? {
        let candidates = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin", "/usr/bin"].map { "\($0)/\(name)" }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func run(_ tool: String, _ args: [String]) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return process.terminationStatus == 0 ? data : nil
        } catch {
            return nil
        }
    }

    private static func analyzeWithExternalTool(_ url: URL) -> MediaInfo? {
        if let mi = findTool("mediainfo"), let data = run(mi, ["--Output=JSON", url.path]), let info = parseMediaInfo(data) {
            return info
        }
        if let ffprobe = findTool("ffprobe"),
           let data = run(ffprobe, ["-v", "quiet", "-print_format", "json", "-show_streams", "-show_format", url.path]),
           let info = parseFFProbe(data) {
            return info
        }
        return nil
    }

    private static func parseMediaInfo(_ data: Data) -> MediaInfo? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let media = json["media"] as? [String: Any],
              let tracks = media["track"] as? [[String: Any]] else { return nil }
        var info = MediaInfo()
        for track in tracks {
            let type = track["@type"] as? String
            if type == "General", let d = (track["Duration"] as? String).flatMap(Double.init) {
                info.durationMs = Int(d * 1000)
            }
            if type == "Video" {
                if let fps = (track["FrameRate"] as? String).flatMap(Double.init) { info.frameRate = fps }
                if let count = (track["FrameCount"] as? String).flatMap(Int.init) { info.frameCount = count }
                if let w = (track["Width"] as? String).flatMap(Int.init) { info.width = w }
                if let h = (track["Height"] as? String).flatMap(Int.init) { info.height = h }
                if info.durationMs == nil, let d = (track["Duration"] as? String).flatMap(Double.init) {
                    info.durationMs = Int(d * 1000)
                }
            }
        }
        return info.frameRate == nil && info.durationMs == nil ? nil : info
    }

    private static func parseFFProbe(_ data: Data) -> MediaInfo? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var info = MediaInfo()
        if let format = json["format"] as? [String: Any], let d = (format["duration"] as? String).flatMap(Double.init) {
            info.durationMs = Int(d * 1000)
        }
        if let streams = json["streams"] as? [[String: Any]],
           let video = streams.first(where: { ($0["codec_type"] as? String) == "video" }) {
            if let rate = video["r_frame_rate"] as? String {
                let parts = rate.split(separator: "/").compactMap { Double($0) }
                if parts.count == 2, parts[1] > 0 { info.frameRate = parts[0] / parts[1] }
                else if parts.count == 1 { info.frameRate = parts[0] }
            }
            if let count = (video["nb_frames"] as? String).flatMap(Int.init) { info.frameCount = count }
            if let w = video["width"] as? Int { info.width = w }
            if let h = video["height"] as? Int { info.height = h }
        }
        return info.frameRate == nil && info.durationMs == nil ? nil : info
    }
}
