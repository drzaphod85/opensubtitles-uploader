import Foundation
import Observation

struct HistoryEntry: Codable, Identifiable, Hashable {
    enum Result: String, Codable { case uploaded, exists }
    var id = UUID()
    var date = Date()
    var subtitleName: String
    var videoName: String?
    var languageCode: String?
    var imdbId: String?
    var title: String?
    var result: Result
    var url: URL?
}

/// Persistent list of everything uploaded from this Mac.
/// Stored as JSON in ~/Library/Application Support/OpenSubtitles Uploader/history.json.
@MainActor
@Observable
final class UploadHistory {
    static let shared = UploadHistory()

    private(set) var entries: [HistoryEntry] = []
    let fileURL: URL

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("OpenSubtitles Uploader", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.fileURL = dir.appendingPathComponent("history.json")
        }
        load()
    }

    func add(_ entry: HistoryEntry) {
        entries.insert(entry, at: 0)
        save()
    }

    func remove(ids: Set<HistoryEntry.ID>) {
        entries.removeAll { ids.contains($0.id) }
        save()
    }

    func clear() {
        entries = []
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        entries = (try? decoder.decode([HistoryEntry].self, from: data)) ?? []
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(entries) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
