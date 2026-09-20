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
    static let version = "2.8.0"
    static let userAgent = "OpenSubtitles-Uploader v\(version)"
    static let homepage = URL(string: "https://github.com/vankasteelj/opensubtitles-uploader")!
    static let issues = URL(string: "https://github.com/vankasteelj/opensubtitles-uploader/issues")!
    static let releases = URL(string: "https://github.com/vankasteelj/opensubtitles-uploader/releases")!
    static let author = URL(string: "https://github.com/vankasteelj")!
    static let macAuthor = URL(string: "https://github.com/drzaphod85")!
    static let transifex = URL(string: "https://www.transifex.com/vankasteelj/opensubtitles-uploader-nwjs/")!
    static let tutorial = URL(string: "https://www.youtube.com/watch?v=jrIgL8kwBdI")!
}
