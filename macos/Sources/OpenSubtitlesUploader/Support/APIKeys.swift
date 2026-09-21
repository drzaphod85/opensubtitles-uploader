import Foundation

/// Third-party API keys. TMDB requires every application (and its users) to use their own
/// key, so the key is not part of the app: the user enters it in Settings › General.
///
/// TMDB is used for the title search behind the magnifier button and for the backdrop
/// image of the video section. Without a key those two features are disabled; everything
/// else works.
enum APIKeys {
    static var tmdb: String {
        UserDefaults.standard.string(forKey: PrefKey.tmdbApiKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    static var hasTMDB: Bool { !tmdb.isEmpty }

    static let tmdbSignupURL = URL(string: "https://www.themoviedb.org/settings/api")!
}
