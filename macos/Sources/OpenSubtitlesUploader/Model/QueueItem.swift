import Foundation
import Observation

enum ImdbStatus: Equatable {
    case none
    case verified(title: String)
    case warning
}

struct VideoForm {
    var path: URL?
    var fileName = ""
    var hash = ""
    var byteSize = ""
    var imdbId = ""
    var movieAka = ""
    var releaseName = ""
    var fps = ""
    var timeMs = ""
    var frames = ""
    var highDefinition = false
    var detectedTitle = ""
    var imdbStatus: ImdbStatus = .none
    var backdropURL: URL?
}

struct SubtitleForm {
    var path: URL?
    var fileName = ""
    var md5 = ""
    var languageCode = ""
    var translator = ""
    var comment = ""
    var hearingImpaired = false
    var autoTranslated = false
    var foreignPartsOnly = false
}

/// What has happened to a queue item so far.
enum ItemStatus: Equatable {
    case idle               // nothing loaded yet
    case ready              // files loaded and analyzed
    case checking           // TryUploadSubtitles in progress
    case exists             // OpenSubtitles already has this subtitle
    case uploading
    case uploaded
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .checking, .uploading: return true
        default: return false
        }
    }
}

/// One video/subtitle pair in the upload queue. The detail form in the window edits the
/// selected item; every item carries the same data the single-file version had.
@MainActor
@Observable
final class QueueItem: Identifiable {
    let id = UUID()
    var video = VideoForm()
    var subtitle = SubtitleForm()
    var status: ItemStatus = .idle
    var uploadedURL: URL?
    var existingSubtitleURL: URL?
    /// The two "hash / file name was added" lines of an "already in database" answer.
    var existsDetails: (String, String) = ("", "")

    // transient analysis state (spinners in the detail view)
    var isAnalyzingVideo = false
    var isLookingUpImdb = false
    var isDetectingLanguage = false
    var imdbLookupGeneration = 0

    var isEmpty: Bool { video.path == nil && subtitle.path == nil }
    var canUpload: Bool { subtitle.path != nil && !status.isBusy && status != .uploaded }

    /// Short text for the queue table.
    var displayName: String {
        subtitle.path?.lastPathComponent ?? video.path?.lastPathComponent ?? ""
    }

    var statusText: String {
        switch status {
        case .idle: return subtitle.path == nil ? L("No subtitle file") : L("Not checked")
        case .ready: return isAnalyzingVideo || isLookingUpImdb ? L("Analyzing…") : L("Ready")
        case .checking: return L("Checking…")
        case .exists: return L("Already in database")
        case .uploading: return L("Uploading…")
        case .uploaded: return L("Uploaded")
        case .failed(let message): return L("Failed") + ": " + message
        }
    }

    var statusSymbol: String {
        switch status {
        case .idle: return subtitle.path == nil ? "questionmark.circle" : "circle"
        case .ready: return "checkmark.circle"
        case .checking, .uploading: return "arrow.triangle.2.circlepath"
        case .exists: return "quote.opening"
        case .uploaded: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        }
    }
}
