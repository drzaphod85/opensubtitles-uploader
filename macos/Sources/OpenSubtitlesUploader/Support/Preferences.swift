import Foundation

/// UserDefaults keys. Names mirror the localStorage keys of the HTML5 version.
enum PrefKey {
    static let useSSL = "ssl"
    static let autoUpdate = "autoUpdate"
    static let appearance = "theme"          // system | light | dark
    static let autoIdentify = "autoIdentify"  // look up the IMDb id when a video is added
    static let username = "os_user"
    static let userId = "os_id"
    static let userRank = "os_rank"
    static let userRefreshed = "os_refreshed"
    static let lastUpdateCheck = "lastUpdateCheck"
    static let availableUpdate = "availableUpdate"
    static let availableUpdateUrl = "availableUpdateUrl"
    static let lockPrefix = "lock-"
}

enum Appearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return L("System")
        case .light: return L("Light")
        case .dark: return L("Dark")
        }
    }
}

extension UserDefaults {
    static func registerAppDefaults() {
        standard.register(defaults: [
            PrefKey.useSSL: true,
            PrefKey.autoUpdate: true,
            PrefKey.appearance: Appearance.system.rawValue,
            PrefKey.autoIdentify: true,
        ])
    }
}

enum AppInfo {
    /// Version of the Mac app. Numbered independently of the HTML5 app, as agreed with its author.
    static let version = "1.0.0"
    /// Own user agent, so OpenSubtitles can tell the two apps apart (see upstream issue #130).
    static let userAgent = "OpenSubtitles-Uploader-Mac v\(version)"
    static let bundleIdentifier = "io.github.drzaphod85.opensubtitles-uploader"

    static let homepage = URL(string: "https://github.com/drzaphod85/opensubtitles-uploader")!
    static let issues = URL(string: "https://github.com/drzaphod85/opensubtitles-uploader/issues")!
    static let releases = URL(string: "https://github.com/drzaphod85/opensubtitles-uploader/releases")!
    static let latestReleaseAPI = URL(string: "https://api.github.com/repos/drzaphod85/opensubtitles-uploader/releases/latest")!
    static let macAuthor = URL(string: "https://github.com/drzaphod85")!

    static let originalProject = URL(string: "https://github.com/vankasteelj/opensubtitles-uploader")!
    static let author = URL(string: "https://github.com/vankasteelj")!
    static let transifex = URL(string: "https://www.transifex.com/vankasteelj/opensubtitles-uploader-nwjs/")!
    static let tutorial = URL(string: "https://www.youtube.com/watch?v=jrIgL8kwBdI")!
}
