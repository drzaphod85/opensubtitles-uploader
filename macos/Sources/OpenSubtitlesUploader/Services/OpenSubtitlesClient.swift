import Foundation

struct OSUserInfo {
    var idUser: String?
    var rank: String?
    var nickname: String?

    init(_ value: XMLRPCValue?) {
        idUser = value?["IDUser"]?.stringValue
        rank = value?["UserRank"]?.stringValue
        nickname = value?["UserNickName"]?.stringValue
    }
}

struct IdentifyMetadata {
    var imdbid: String?      // with leading "tt"
    var title: String?
    var year: String?
    var season: String?
    var episode: String?
    var episodeTitle: String?
}

struct IMDBDetails {
    var id: String
    var title: String
    var year: String
    var kind: String
    var season: String?
    var episode: String?
    var showImdbId: String?
}

struct UploadRequest {
    var videoPath: URL?
    var subtitlePath: URL
    var imdbid: String?
    var sublanguageid: String?
    var moviereleasename: String?
    var movieaka: String?
    var moviefps: String?
    var movieframes: String?
    var movietimems: String?
    var subauthorcomment: String?
    var subtranslator: String?
    var highdefinition = false
    var hearingimpaired = false
    var automatictranslation = false
    var foreignpartsonly = false
}

enum UploadOutcome {
    case alreadyInDatabase(idSubtitle: String?, hashAdded: Bool, filenameAdded: Bool)
    case uploaded(url: URL?)
}

enum CheckOutcome {
    case exists(idSubtitle: String?)
    case new(imdbFromServer: String?)
}

enum OSError: LocalizedError {
    case unauthorized
    case offline
    case unavailable          // 503
    case maintenance          // 506
    case invalidFormat        // 402
    case missingImdb
    case wrongImdb
    case status(String)

    var errorDescription: String? {
        switch self {
        case .unauthorized: return "401 Unauthorized"
        case .offline: return "API seems offline"
        case .unavailable: return "503 Service Unavailable"
        case .maintenance: return "506 Server under maintenance"
        case .invalidFormat: return "402 Subtitles has invalid format"
        case .missingImdb: return "Matching IMDB ID cannot be found"
        case .wrongImdb: return "Wrong IMDB id"
        case .status(let s): return s
        }
    }

    static func from(status: String) -> OSError {
        if status.hasPrefix("401") { return .unauthorized }
        if status.hasPrefix("402") { return .invalidFormat }
        if status.hasPrefix("503") { return .unavailable }
        if status.hasPrefix("506") { return .maintenance }
        return .status(status)
    }
}

/// Swift port of the `opensubtitles-api` npm module used by the HTML5 version.
/// Talks XML-RPC to api.opensubtitles.org.
actor OpenSubtitlesClient {
    var username = ""
    var password = ""
    let userAgent: String
    private(set) var useSSL: Bool
    private var client: XMLRPCClient

    private var token: String?
    private var tokenExpiry = Date.distantPast
    private var tokenUser = ""
    private(set) var userinfo = OSUserInfo(nil)

    init(userAgent: String, useSSL: Bool) {
        self.userAgent = userAgent
        self.useSSL = useSSL
        client = XMLRPCClient(url: Self.endpoint(ssl: useSSL), userAgent: userAgent)
    }

    private static func endpoint(ssl: Bool) -> URL {
        URL(string: ssl ? "https://api.opensubtitles.org:443/xml-rpc" : "http://api.opensubtitles.org:80/xml-rpc")!
    }

    func setSSL(_ ssl: Bool) {
        guard ssl != useSSL else { return }
        useSSL = ssl
        client = XMLRPCClient(url: Self.endpoint(ssl: ssl), userAgent: userAgent)
        token = nil
    }

    func setCredentials(username: String, password: String) {
        self.username = username
        self.password = password
        token = nil
    }

    // MARK: Low level

    private func call(_ method: String, _ params: [XMLRPCValue]) async throws -> XMLRPCValue {
        do {
            return try await client.call(method, params)
        } catch XMLRPCError.notXML {
            throw OSError.offline
        } catch let error as XMLRPCError {
            if case .http(let code) = error {
                if code == 503 { throw OSError.unavailable }
                if code == 506 { throw OSError.maintenance }
            }
            throw error
        }
    }

    private func status(of response: XMLRPCValue) -> String {
        response["status"]?.stringValue ?? ""
    }

    private func ensureOK(_ response: XMLRPCValue, fallback: String) throws {
        let s = status(of: response)
        guard s.contains("200") else { throw OSError.from(status: s.isEmpty ? fallback : s) }
    }

    // MARK: API

    @discardableResult
    func login() async throws -> (token: String, userinfo: OSUserInfo) {
        if let token, tokenUser == username, tokenExpiry > Date() {
            return (token, userinfo)
        }
        let response = try await call("LogIn", [.string(username), .string(password), .string("en"), .string(userAgent)])
        let s = status(of: response)
        guard let t = response["token"]?.stringValue, s.contains("200") else {
            token = nil
            userinfo = OSUserInfo(nil)
            throw OSError.from(status: s.isEmpty ? "LogIn unknown error" : s)
        }
        token = t
        tokenExpiry = Date().addingTimeInterval(895) // ~15 minutes, like the original
        tokenUser = username
        userinfo = OSUserInfo(response["data"])
        return (t, userinfo)
    }

    /// CheckMovieHash: finds IMDb information for a video hash.
    func identify(moviehash: String) async throws -> IdentifyMetadata? {
        let (token, _) = try await login()
        let response = try await call("CheckMovieHash", [.string(token), .array([.string(moviehash)])])
        try ensureOK(response, fallback: "OpenSubtitles unknown error")
        guard let entry = response["data"]?[moviehash]?.dictValue, !entry.isEmpty else { return nil }

        var meta = IdentifyMetadata()
        let imdb = entry["MovieImdbID"]?.stringValue ?? "0"
        meta.imdbid = imdb != "0" && !imdb.isEmpty ? "tt" + imdb : nil
        meta.title = entry["MovieName"]?.stringValue
        meta.year = entry["MovieYear"]?.stringValue
        let season = entry["SeriesSeason"]?.stringValue ?? "0"
        let episode = entry["SeriesEpisode"]?.stringValue ?? "0"
        if season + episode != "00", let name = meta.title {
            meta.season = season
            meta.episode = episode
            let parts = name.split(separator: "\"", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count >= 3 {
                meta.title = parts[1]
                meta.episodeTitle = parts[2]
            }
        }
        return meta
    }

    func imdbDetails(imdbid: Int) async throws -> IMDBDetails {
        let (token, _) = try await login()
        let response = try await call("GetIMDBMovieDetails", [.string(token), .int(imdbid)])
        // Historically the answer was {status, data: {...}}; as of 2025 the server returns the
        // movie struct directly (and {status: "408 Invalid parameters"} for unknown ids).
        let data: [String: XMLRPCValue]
        if let wrapped = response["data"]?.dictValue {
            try ensureOK(response, fallback: "GetIMDBMovieDetails unknown error")
            data = wrapped
        } else if let direct = response.dictValue, direct["id"] != nil {
            data = direct
        } else {
            let s = status(of: response)
            if s.hasPrefix("408") || s.isEmpty { throw OSError.wrongImdb }
            throw OSError.from(status: s)
        }
        guard let id = data["id"]?.stringValue, !id.isEmpty else { throw OSError.wrongImdb }
        var showId: String?
        if let episodeOf = data["episodeof"]?.dictValue, let key = episodeOf.keys.sorted().first {
            showId = key.replacingOccurrences(of: "_", with: "tt")
        }
        return IMDBDetails(
            id: id,
            title: data["title"]?.stringValue ?? "",
            year: data["year"]?.stringValue ?? "",
            kind: data["kind"]?.stringValue ?? "",
            season: data["season"]?.stringValue,
            episode: data["episode"]?.stringValue,
            showImdbId: showId
        )
    }

    struct MovieGuess {
        var imdbid: String          // episode id when available, else the movie/show id
        var title: String
        var year: String?
        var season: String?
        var episode: String?

        /// "Show S07E01 (2025)" or "Movie (1999)"
        var displayTitle: String {
            func pad(_ s: String?) -> String { guard let s, let n = Int(s) else { return s ?? "" }; return n < 10 ? "0\(n)" : "\(n)" }
            var text = title
            if let season, let episode, season != "0" || episode != "0" { text += " S\(pad(season))E\(pad(episode))" }
            if let year, !year.isEmpty { text += " (\(year))" }
            return text
        }
    }

    /// GuessMovieFromString: OpenSubtitles' best guess for a file name, if any.
    func guessMovie(fromFilename filename: String) async throws -> MovieGuess? {
        let (token, _) = try await login()
        let response = try await call("GuessMovieFromString", [.string(token), .array([.string(filename)])])
        try ensureOK(response, fallback: "GuessMovieFromString unknown error")
        guard let best = response["data"]?[filename]?["BestGuess"]?.dictValue,
              let id = best["IMDBEpisode"]?.stringValue ?? best["IDMovieIMDB"]?.stringValue, !id.isEmpty,
              let title = best["MovieName"]?.stringValue else { return nil }
        return MovieGuess(imdbid: id, title: title, year: best["MovieYear"]?.stringValue,
                          season: best["Season"]?.stringValue, episode: best["Episode"]?.stringValue)
    }

    /// Builds the cd1 struct shared by TryUploadSubtitles and UploadSubtitles.
    private func tryData(for req: UploadRequest) throws -> (cd1: [String: XMLRPCValue], idmovieimdb: String?) {
        var cd1: [String: XMLRPCValue] = [:]
        if let video = req.videoPath {
            let h = try OSHash.movieHash(of: video)
            cd1["moviehash"] = .string(h.moviehash)
            cd1["moviebytesize"] = .string(h.moviebytesize)
            cd1["moviefilename"] = .string(video.lastPathComponent)
        }
        cd1["subhash"] = .string(try OSHash.md5(of: req.subtitlePath))
        cd1["subfilename"] = .string(req.subtitlePath.lastPathComponent)

        var idmovieimdb: String? = req.imdbid.flatMap { id in
            let clean = id.replacingOccurrences(of: "tt", with: "")
            return clean.isEmpty ? nil : clean
        }
        if let v = idmovieimdb { cd1["idmovieimdb"] = .string(v) }
        if let v = req.sublanguageid, !v.isEmpty { cd1["sublanguageid"] = .string(v) }
        if let v = req.moviefps, !v.isEmpty { cd1["moviefps"] = .string(v) }
        if let v = req.movieframes, !v.isEmpty { cd1["movieframes"] = .string(v) }
        if let v = req.movietimems, !v.isEmpty { cd1["movietimems"] = .string(v) }
        if let v = req.subauthorcomment, !v.isEmpty { cd1["subauthorcomment"] = .string(v) }
        if let v = req.subtranslator, !v.isEmpty { cd1["subtranslator"] = .string(v) }
        if let v = req.moviereleasename, !v.isEmpty { cd1["moviereleasename"] = .string(v) }
        if let v = req.movieaka, !v.isEmpty { cd1["movieaka"] = .string(v) }
        if req.hearingimpaired { cd1["hearingimpaired"] = .string("1") }
        if req.highdefinition { cd1["highdefinition"] = .string("1") }
        if req.automatictranslation { cd1["automatictranslation"] = .string("1") }
        if req.foreignpartsonly { cd1["foreignpartsonly"] = .string("1") }
        return (cd1, idmovieimdb)
    }

    /// Dry run: asks OpenSubtitles whether this subtitle is already known, without uploading.
    func check(_ req: UploadRequest) async throws -> CheckOutcome {
        let (token, _) = try await login()
        let (cd1, _) = try tryData(for: req)
        let tryResponse = try await call("TryUploadSubtitles", [.string(token), .dict(["cd1": .dict(cd1)])])
        try ensureOK(tryResponse, fallback: "TryUploadSubtitles unknown error")
        if tryResponse["alreadyindb"]?.intValue == 1 {
            let d = tryResponse["data"]?.dictValue ?? tryResponse["data"]?.arrayValue?.first?.dictValue
            return .exists(idSubtitle: d?["IDSubtitle"]?.stringValue)
        }
        return .new(imdbFromServer: tryResponse["data"]?.arrayValue?.first?["IDMovieImdb"]?.stringValue)
    }

    func upload(_ req: UploadRequest) async throws -> UploadOutcome {
        let (token, _) = try await login()

        // 1. TryUploadSubtitles
        let (cd1, initialImdb) = try tryData(for: req)
        var idmovieimdb = initialImdb
        let tryResponse = try await call("TryUploadSubtitles", [.string(token), .dict(["cd1": .dict(cd1)])])
        try ensureOK(tryResponse, fallback: "TryUploadSubtitles unknown error")

        if tryResponse["alreadyindb"]?.intValue == 1 {
            let d = tryResponse["data"]?.dictValue ?? tryResponse["data"]?.arrayValue?.first?.dictValue
            return .alreadyInDatabase(
                idSubtitle: d?["IDSubtitle"]?.stringValue,
                hashAdded: (d?["HashWasAlreadyInDb"]?.intValue ?? 1) == 0,
                filenameAdded: (d?["MoviefilenameWasAlreadyInDb"]?.intValue ?? 1) == 0
            )
        }

        // 2. Resolve the IMDb id from the server's answer, like libupload.parseResponse
        if let first = tryResponse["data"]?.arrayValue?.first,
           let serverImdb = first["IDMovieImdb"]?.stringValue, !serverImdb.isEmpty {
            idmovieimdb = serverImdb
        }
        guard let finalImdb = idmovieimdb else { throw OSError.missingImdb }

        // 3. UploadSubtitles
        var baseinfo: [String: XMLRPCValue] = ["idmovieimdb": .string(finalImdb)]
        for key in ["moviereleasename", "movieaka", "sublanguageid", "subauthorcomment", "hearingimpaired",
                    "highdefinition", "automatictranslation", "subtranslator", "foreignpartsonly"] {
            if let v = cd1[key] { baseinfo[key] = v }
        }
        var uploadCd1: [String: XMLRPCValue] = [
            "subhash": cd1["subhash"]!,
            "subfilename": cd1["subfilename"]!,
            "subcontent": .string(try OSHash.subtitleContent(of: req.subtitlePath)),
        ]
        for key in ["moviebytesize", "moviehash", "moviefilename", "moviefps", "movieframes", "movietimems"] {
            if let v = cd1[key] { uploadCd1[key] = v }
        }

        let response = try await call("UploadSubtitles", [.string(token), .dict(["baseinfo": .dict(baseinfo), "cd1": .dict(uploadCd1)])])
        let s = status(of: response)
        let data = response["data"]?.stringValue ?? ""
        guard s.contains("200"), !data.isEmpty else {
            throw OSError.from(status: s.isEmpty ? "UploadSubtitles unknown error" : s)
        }
        return .uploaded(url: URL(string: data))
    }
}
