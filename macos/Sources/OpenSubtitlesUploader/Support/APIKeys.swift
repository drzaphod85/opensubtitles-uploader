import Foundation

/// Third-party API keys. The Mac app uses its own keys, separate from the HTML5 app
/// (agreed with its author in upstream issue #130).
///
/// TMDB is used for the title search behind the magnifier button and for the backdrop
/// image of the video section. Without a key those two features are simply disabled;
/// everything else works. Get a free key at https://www.themoviedb.org/settings/api
/// and put it here before building a release.
enum APIKeys {
    static let tmdb = ""

    static var hasTMDB: Bool { !tmdb.isEmpty }
}
