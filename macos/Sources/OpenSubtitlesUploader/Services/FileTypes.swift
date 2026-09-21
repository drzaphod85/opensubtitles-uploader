import Foundation
import UniformTypeIdentifiers

enum FileKind: String, CaseIterable {
    case video, subtitle
}

/// File type detection and the file-name heuristics of the original `Files` module.
enum FileTypes {
    static let videoExtensions: [String] = [
        "3g2", "3gp", "3gp2", "3gpp", "60d", "ajp", "asf", "asx", "avchd", "avi", "bik", "bix", "box", "cam", "dat", "divx", "dmf", "dv", "dvr-ms", "evo", "flc", "fli", "flic", "flv", "flx", "gvi", "gvp", "h264", "m1v", "m2p", "m2ts", "m2v", "m4e", "m4v", "mjp", "mjpeg", "mjpg", "mkv", "moov", "mov", "movhd", "movie", "movx", "mp4", "mpe", "mpeg", "mpg", "mpv", "mpv2", "mxf", "nsv", "nut", "ogg", "ogm", "omf", "ps", "qt", "ram", "rm", "rmvb", "swf", "ts", "vfw", "vid", "video", "viv", "vivo", "vob", "vro", "wm", "wmv", "wmx", "wrap", "wvx", "wx", "x264", "xvid",
    ]
    static let subtitleExtensions: [String] = ["srt", "sub", "smi", "txt", "ssa", "ass", "mpl"]

    static func kind(of url: URL) -> FileKind? {
        let ext = url.pathExtension.lowercased()
        if videoExtensions.contains(ext) { return .video }
        if subtitleExtensions.contains(ext) { return .subtitle }
        return nil
    }

    static func contentTypes(for kind: FileKind?) -> [UTType] {
        let exts: [String]
        switch kind {
        case .video: exts = videoExtensions
        case .subtitle: exts = subtitleExtensions
        case nil: exts = videoExtensions + subtitleExtensions
        }
        var types = exts.compactMap { UTType(filenameExtension: $0) }
        if kind != .subtitle { types.append(contentsOf: [.movie, .video, .mpeg4Movie, .quickTimeMovie, .avi]) }
        if kind != .video { types.append(contentsOf: [.plainText, .text]) }
        return types
    }

    /// Picks the first video and the first subtitle from a list of files.
    static func analyze(_ urls: [URL]) -> [FileKind: URL] {
        var result: [FileKind: URL] = [:]
        for url in urls {
            guard let k = kind(of: url) else { continue }
            if result[k] == nil { result[k] = url }
            if result.count == 2 { break }
        }
        return result
    }

    // MARK: Name heuristics

    static func extractQuality(_ title: String) -> String? {
        if title.range(of: #"720[pix]"#, options: [.regularExpression, .caseInsensitive]) != nil,
           title.range(of: #"dvdrip|dvd\Wrip"#, options: [.regularExpression, .caseInsensitive]) == nil {
            return "720p"
        }
        if title.range(of: #"1080[pix]"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return "1080p"
        }
        return nil
    }

    /// Clears a file name of common release-name noise, to prefill the IMDb search.
    static func clearName(_ name: String) -> String {
        var title = (name as NSString).deletingPathExtension
        let replacements: [(String, String)] = [
            (#"(400|480|720|1080)[pix]"#, ""),
            (#"[xh]26\d|hevc|xvid|divx"#, ""),
            (#"bluray|bdrip|brrip|dsr|dvdrip|dvd\Wrip|hdtv|\Wts\W|telesync|\Wcam\W"#, ""),
            (#"\Wextended\W|\Wproper"#, ""),
            (#"[\.]"#, " "),
            (#"^\[.*\]"#, ""),
            (#"\[(\w|\d)+\]"#, ""),
            (#"\((\w|\d)+\)"#, ""),
            (#"_"#, " "),
            (#"-"#, " "),
            (#"\-$"#, ""),
            (#"\s.$"#, ""),
            (#"^\."#, ""),
            (#"^\-"#, ""),
            (#" +"#, " "),
        ]
        for (pattern, replacement) in replacements {
            title = title.replacingOccurrences(of: pattern, with: replacement, options: [.regularExpression, .caseInsensitive])
        }
        return title.trimmingCharacters(in: .whitespaces)
    }

    /// The query the original prefills in the IMDb search popup.
    static func searchQuery(fromFilename name: String) -> String {
        let words = clearName(name).split(separator: " ").map(String.init)
        let clean = words.filter { $0.range(of: #"^(the|an|19\d{2}|20\d{2}|a|of|in)$"#, options: [.regularExpression, .caseInsensitive]) == nil }
        let limit = clean.count > 5 ? 4 : max(clean.count - 1, 0)
        return clean.prefix(limit).joined(separator: " ")
    }

    private static func containsAll(_ text: String, _ words: [String]) -> Bool {
        words.allSatisfy { text.range(of: $0, options: .caseInsensitive) != nil }
    }

    static func looksMachineTranslated(filename: String, content: String?) -> Bool {
        let groups = [["auto", "translated"], ["babel", "fish"], ["google", "translate"], ["bing", "translation"]]
        if groups.contains(where: { containsAll(filename, $0) }) { return true }
        if let content { return groups.contains(where: { containsAll(content, $0) }) }
        return false
    }

    /// Sound descriptions such as "(door slams)" or "[MUSIC]" are typical for hearing-impaired
    /// subtitles. The original flagged any file with more than 10 parenthesised fragments, which
    /// mis-flagged ordinary subtitles (upstream issue #115); we also require them to make up a
    /// noticeable share of the cues.
    static func looksHearingImpaired(content: String?) -> Bool {
        guard let content else { return false }
        let descriptions = content.matches(of: #/[\(\[][^\)\]\n]{2,80}[\)\]]/#).count
        guard descriptions > 10 else { return false }
        let cues = max(content.matches(of: #/-->/#).count, content.split(separator: "\n").count / 3, 1)
        return Double(descriptions) / Double(cues) >= 0.05
    }

    static func looksForeignPartsOnly(url: URL) -> Bool {
        let filename = url.lastPathComponent
        if filename.range(of: #"\Wforced\W"#, options: [.regularExpression, .caseInsensitive]) != nil { return true }
        if filename.range(of: #"\Wparts"#, options: [.regularExpression, .caseInsensitive]) != nil,
           filename.range(of: #"non\W|foreign"#, options: [.regularExpression, .caseInsensitive]) != nil { return true }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? Int.max
        return size < 5000
    }

    // MARK: Matching companion files in the same folder

    private static func baseName(_ url: URL) -> String { url.deletingPathExtension().lastPathComponent }

    /// Finds a subtitle next to a video with the same base name (e.g. movie.mkv → movie.eng.srt).
    static func matchingSubtitle(forVideo video: URL) -> URL? {
        let dir = video.deletingLastPathComponent()
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return nil }
        let base = baseName(video)
        let match = files.sorted { $0.lastPathComponent < $1.lastPathComponent }.first { f in
            kind(of: f) == .subtitle && baseName(f).range(of: base, options: .caseInsensitive) != nil
        }
        // build the URL from the original directory so it compares equal even when /var → /private/var
        return match.map { dir.appendingPathComponent($0.lastPathComponent) }
    }

    /// "S07E01" or "7x01" in a file name.
    static func seasonEpisode(_ s: String) -> (season: Int, episode: Int)? {
        if let m = s.firstMatch(of: #/S(\d{1,2})E(\d{2})/#.ignoresCase()) {
            return (Int(m.1)!, Int(m.2)!)
        }
        if let m = s.firstMatch(of: #/(\d\d?)x(\d\d?)/#.ignoresCase()) {
            return (Int(m.1)!, Int(m.2)!)
        }
        return nil
    }

    /// Finds a video next to a subtitle: matching name (ignoring a language suffix) and the same SxxExx tag if any.
    static func matchingVideo(forSubtitle subtitle: URL) -> URL? {
        let dir = subtitle.deletingLastPathComponent()
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return nil }
        let dropped = subtitle.lastPathComponent
        let droppedExt = subtitle.pathExtension
        // the original strips the extension plus up to 10 characters (".eng.forced")
        let cut = min(dropped.count, droppedExt.count + 10 + (droppedExt.isEmpty ? 0 : 1))
        let droppedName = String(dropped.dropLast(cut))
        guard !droppedName.isEmpty else { return nil }
        let droppedSxE = seasonEpisode(dropped)

        for f in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where kind(of: f) == .video {
            let name = baseName(f)
            guard name.range(of: droppedName, options: .caseInsensitive) != nil else { continue }
            let foundSxE = seasonEpisode(f.lastPathComponent)
            let result = dir.appendingPathComponent(f.lastPathComponent)
            if let foundSxE, let droppedSxE {
                if foundSxE == droppedSxE { return result }
                continue
            }
            return result
        }
        return nil
    }
}
