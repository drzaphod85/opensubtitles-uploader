import Foundation

/// Turns dropped files and folders into video/subtitle pairs for the queue.
enum QueuePlanner {
    struct Pair: Equatable {
        var video: URL?
        var subtitle: URL?
    }

    /// Collects supported files from the dropped URLs; folders are searched three levels deep.
    static func collectFiles(_ urls: [URL]) -> [URL] {
        var files: [URL] = []
        var seen = Set<String>()
        func add(_ url: URL) {
            let key = url.standardizedFileURL.path
            guard !seen.contains(key), FileTypes.kind(of: url) != nil else { return }
            seen.insert(key)
            files.append(url)
        }
        func walk(_ dir: URL, depth: Int) {
            guard depth <= 3,
                  let entries = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return }
            for entry in entries.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
                if (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    walk(entry, depth: depth + 1)
                } else {
                    add(entry)
                }
            }
        }
        for url in urls {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                walk(url, depth: 1)
            } else {
                add(url)
            }
        }
        return files
    }

    /// Pairs every subtitle with the best matching video among the dropped files (or next to it on
    /// disk), and every video without a subtitle with a matching subtitle on disk. A video can
    /// serve several subtitles (one per language); each subtitle becomes its own queue item.
    static func plan(_ urls: [URL], lookOnDisk: Bool = true) -> [Pair] {
        let files = collectFiles(urls)
        let videos = files.filter { FileTypes.kind(of: $0) == .video }
        let subtitles = files.filter { FileTypes.kind(of: $0) == .subtitle }
        var pairs: [Pair] = []
        var usedVideos = Set<String>()

        for sub in subtitles {
            let sameDir = videos.filter { $0.deletingLastPathComponent().standardizedFileURL == sub.deletingLastPathComponent().standardizedFileURL }
            var video = FileTypes.matchingVideo(forSubtitle: sub, among: sameDir)
            if video == nil, lookOnDisk, sameDir.isEmpty {
                video = FileTypes.matchingVideo(forSubtitle: sub)
            }
            if let video { usedVideos.insert(video.standardizedFileURL.path) }
            pairs.append(Pair(video: video, subtitle: sub))
        }
        for video in videos where !usedVideos.contains(video.standardizedFileURL.path) {
            var subtitle: URL?
            if lookOnDisk { subtitle = FileTypes.matchingSubtitle(forVideo: video) }
            if let subtitle, subtitles.contains(where: { $0.standardizedFileURL == subtitle.standardizedFileURL }) {
                continue // already paired above
            }
            pairs.append(Pair(video: video, subtitle: subtitle))
        }
        return pairs.sorted { ($0.subtitle ?? $0.video ?? URL(fileURLWithPath: "/")).lastPathComponent.localizedStandardCompare(($1.subtitle ?? $1.video ?? URL(fileURLWithPath: "/")).lastPathComponent) == .orderedAscending }
    }
}
