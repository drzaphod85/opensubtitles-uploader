import Foundation

struct SearchResult: Identifiable, Hashable {
    enum Kind { case movie, show, episode }
    let kind: Kind
    let tmdbId: Int
    let title: String
    var season: Int?
    var episode: Int?
    var imdbId: String?
    var id: String { "\(kind)-\(tmdbId)-\(season ?? 0)-\(episode ?? 0)" }
}

/// The Movie Database. Used for the title search (the Trakt.tv key of the HTML5 version has
/// been revoked and answers 403) and for the backdrop image of the video section.
enum TMDBClient {
    static var apiKey: String { APIKeys.tmdb }
    static let imageBase = "https://image.tmdb.org/t/p/w1280"

    private static func url(_ path: String, _ query: [String: String] = [:]) -> URL {
        var components = URLComponents(string: "https://api.themoviedb.org/3/" + path)!
        var items = [URLQueryItem(name: "api_key", value: apiKey)]
        for (k, v) in query.sorted(by: { $0.key < $1.key }) { items.append(URLQueryItem(name: k, value: v)) }
        // URLComponents leaves "&" and "+" unescaped inside values; encode them explicitly
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?")
        components.percentEncodedQueryItems = items.map {
            URLQueryItem(name: $0.name, value: $0.value?.addingPercentEncoding(withAllowedCharacters: allowed))
        }
        return components.url!
    }

    private static func fetchJSON(_ url: URL) async -> [String: Any]? {
        var request = URLRequest(url: url)
        request.setValue(AppInfo.userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    // MARK: Search

    /// Searches movies and TV shows. When a season/episode is known (from the video file name),
    /// the matching episode of each show is offered as well, with its own IMDb id.
    static func search(_ query: String, seasonEpisode: (season: Int, episode: Int)? = nil) async -> [SearchResult] {
        guard APIKeys.hasTMDB else { return [] }
        guard let json = await fetchJSON(url("search/multi", ["query": query, "include_adult": "false"])),
              let items = json["results"] as? [[String: Any]] else { return [] }

        var results: [SearchResult] = []
        var episodeLookups = 0
        for item in items {
            guard let id = item["id"] as? Int else { continue }
            switch item["media_type"] as? String {
            case "movie":
                guard let title = item["title"] as? String else { continue }
                let year = String((item["release_date"] as? String ?? "").prefix(4))
                results.append(SearchResult(kind: .movie, tmdbId: id, title: year.isEmpty ? title : "\(title) (\(year))"))
            case "tv":
                guard let name = item["name"] as? String else { continue }
                let year = String((item["first_air_date"] as? String ?? "").prefix(4))
                let showTitle = year.isEmpty ? name : "\(name) (\(year))"
                results.append(SearchResult(kind: .show, tmdbId: id, title: showTitle))
                if let se = seasonEpisode, episodeLookups < 5 {
                    episodeLookups += 1
                    if let ep = await episode(show: id, season: se.season, episode: se.episode) {
                        results.append(SearchResult(kind: .episode, tmdbId: id, title: "\(showTitle) - \(se.season)x\(String(format: "%02d", se.episode)) - \(ep.name)",
                                                    season: se.season, episode: se.episode, imdbId: ep.imdbId))
                    }
                }
            default:
                continue
            }
        }
        return results
    }

    private static func episode(show: Int, season: Int, episode: Int) async -> (name: String, imdbId: String?)? {
        let path = "tv/\(show)/season/\(season)/episode/\(episode)"
        guard let details = await fetchJSON(url(path)), let name = details["name"] as? String else { return nil }
        let ids = await fetchJSON(url(path + "/external_ids"))
        return (name, ids?["imdb_id"] as? String)
    }

    /// Resolves the IMDb id of a search result (movies and shows need one extra request).
    static func imdbId(for result: SearchResult) async -> String? {
        if let imdbId = result.imdbId, !imdbId.isEmpty { return imdbId }
        let path = result.kind == .movie ? "movie/\(result.tmdbId)/external_ids" : "tv/\(result.tmdbId)/external_ids"
        guard let ids = await fetchJSON(url(path)), let imdb = ids["imdb_id"] as? String, !imdb.isEmpty else { return nil }
        return imdb
    }

    // MARK: Backdrop

    static func backdrop(imdbId: String, fallbackTitle: String?) async -> URL? {
        guard APIKeys.hasTMDB else { return nil }
        if let url = await find(imdbId: imdbId) { return url }
        if let title = fallbackTitle { return await search(title: title) }
        return nil
    }

    private static func find(imdbId: String) async -> URL? {
        guard let json = await fetchJSON(url("find/\(imdbId)", ["external_source": "imdb_id"])) else { return nil }
        for key in ["movie_results", "tv_results", "tv_episode_results"] {
            if let first = (json[key] as? [[String: Any]])?.first,
               let path = first["backdrop_path"] as? String ?? first["still_path"] as? String {
                return URL(string: imageBase + path)
            }
        }
        return nil
    }

    private static func search(title: String) async -> URL? {
        let clean = title.replacingOccurrences(of: #"\W"#, with: " ", options: .regularExpression)
        guard let json = await fetchJSON(url("search/multi", ["query": clean])),
              let first = (json["results"] as? [[String: Any]])?.first,
              let path = first["backdrop_path"] as? String else { return nil }
        return URL(string: imageBase + path)
    }
}

/// Checks the latest GitHub release of the Mac app, at most once a week.
enum UpdateChecker {
    struct Update {
        let version: String
        let url: URL
    }

    static func fetchLatest() async throws -> Update? {
        var request = URLRequest(url: AppInfo.latestReleaseAPI)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue(AppInfo.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode == 404 { return nil } // no release yet
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String else { return nil }
        let version = tag.replacingOccurrences(of: #"^[^\d]*"#, with: "", options: .regularExpression) // "v1.2.0" / "mac-1.2.0" → "1.2.0"
        let url = (json["html_url"] as? String).flatMap(URL.init(string:)) ?? AppInfo.releases
        return isNewer(version, than: AppInfo.version) ? Update(version: version, url: url) : nil
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
