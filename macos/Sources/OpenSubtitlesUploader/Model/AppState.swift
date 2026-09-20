import Foundation
import AppKit
import Observation

// MARK: - Form models

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

/// Fields whose value can be kept between sessions ("lock" icons in the original UI).
enum LockField: String, CaseIterable {
    case imdbId = "imdbid"
    case movieAka = "movieaka"
    case language = "sublanguageid"
    case translator = "subtranslator"
    case comment = "subauthorcomment"

    var prefKey: String { PrefKey.lockPrefix + rawValue }
}

enum UploadButtonState {
    case idle, success, partial, failure
}

struct AlertButton: Identifiable {
    enum Role { case normal, cancel, destructive }
    let id = UUID()
    let title: String
    var role: Role = .normal
    let action: () -> Void
}

struct AppAlert: Identifiable {
    enum Tone { case neutral, success, partial, failure }
    let id = UUID()
    var title: String
    var message: String
    var tone: Tone = .neutral
    var buttons: [AlertButton]
}

// MARK: - App state

@MainActor
@Observable
final class AppState {
    static let shared = AppState()

    var video = VideoForm()
    var subtitle = SubtitleForm()
    var locks: Set<LockField> = []

    // authentication
    var username = ""
    var isLoggedIn = false
    var userId: String?
    var userRank: String?
    var isLoggingIn = false
    var loginError: String?
    var showLoginSheet = false

    // busy states
    var isAnalyzingVideo = false
    var isLookingUpImdb = false
    var isUploading = false
    var isDetectingLanguage = false
    var isSearching = false
    var uploadButtonState: UploadButtonState = .idle

    // ui
    var alert: AppAlert?
    var snack: String?
    var showSearchSheet = false
    var searchQuery = ""
    var searchResults: [SearchResult] = []
    var searchPerformed = false
    var dragHighlight: Set<FileKind> = []
    var isDragTargeted = false
    var highlightMissingSubtitle = false

    let client: OpenSubtitlesClient
    private var snackTask: Task<Void, Never>?
    private var imdbLookupGeneration = 0
    private var mediaToolHintShown = false
    private var uploadAfterLogin = false
    private var credentialsTask: Task<Bool, Never>?

    private init() {
        let defaults = UserDefaults.standard
        client = OpenSubtitlesClient(userAgent: AppInfo.userAgent, useSSL: defaults.bool(forKey: PrefKey.useSSL))
        restoreLocks()
    }

    // MARK: Startup

    func start() {
        verifyLogin()
        checkForUpdates(force: false)
    }

    func setUseSSL(_ ssl: Bool) {
        Task {
            await client.setSSL(ssl)
            verifyLogin()
        }
    }

    // MARK: Notifications

    func showSnack(_ message: String, duration: TimeInterval = 3) {
        snackTask?.cancel()
        snack = message
        snackTask = Task {
            try? await Task.sleep(for: .seconds(duration))
            if !Task.isCancelled { snack = nil }
        }
    }

    func requestAttentionIfNeeded() {
        if !NSApp.isActive {
            NSApp.requestUserAttention(.informationalRequest)
        }
    }

    func openExternal(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    func openImdb() {
        let id = video.imdbId.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty, let url = URL(string: "https://www.imdb.com/title/\(id)") else { return }
        openExternal(url)
    }

    // MARK: Files in / out

    func handleDropped(_ urls: [URL]) {
        dragHighlight = []
        isDragTargeted = false
        let files = FileTypes.analyze(urls)
        if files.isEmpty {
            showSnack(L("Dropped file is not supported"))
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        showSearchSheet = false
        alert = nil
        if uploadButtonState == .success || uploadButtonState == .partial {
            // the previous subtitle is done; start from a clean sheet (upstream issue #108)
            reset(.all)
        }
        let multidrop = files.count == 2
        if let v = files[.video] { addVideo(v, multidrop: multidrop) }
        if let s = files[.subtitle] { addSubtitle(s, multidrop: multidrop) }
    }

    func browse(_ kind: FileKind?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = kind == nil
        panel.allowedContentTypes = FileTypes.contentTypes(for: kind)
        switch kind {
        case .video: panel.message = L("Drop a video file or select one")
        case .subtitle: panel.message = L("Drop a subtitle file or select one")
        case nil: panel.message = L("Import file(s)")
        }
        panel.begin { response in
            guard response == .OK else { return }
            self.handleDropped(panel.urls)
        }
    }

    // MARK: Video

    func addVideo(_ url: URL, multidrop: Bool) {
        Task { await importVideo(url, multidrop: multidrop) }
    }

    /// Imports a video. Local metadata (hash, size, duration, fps) is always filled in; the
    /// OpenSubtitles identification is best effort so the file stays loaded when the API is
    /// unreachable (upstream issues #41, #107). A locked IMDb id is never overwritten (#116)
    /// and a manual id entered meanwhile wins over the background lookup (#63).
    private func importVideo(_ url: URL, multidrop: Bool) async {
        isAnalyzingVideo = true
        let hash: OSHash.MovieHash
        do {
            hash = try OSHash.movieHash(of: url)
        } catch {
            isAnalyzingVideo = false
            showSnack(L("Dropped file is not supported"))
            AppLog.error("movieHash failed: \(String(describing: error))")
            return
        }
        if hash.moviehash == video.hash, !video.hash.isEmpty {
            isAnalyzingVideo = false
            return // already loaded
        }

        let media = await MediaInfoService.analyze(url)

        reset(.video)
        video.path = url
        video.fileName = url.lastPathComponent
        video.byteSize = hash.moviebytesize
        video.hash = hash.moviehash
        video.timeMs = media.durationMs.map(String.init) ?? ""
        video.fps = media.frameRateString ?? ""
        video.frames = media.frameCount.map(String.init) ?? ""
        let hdByName = FileTypes.extractQuality(url.lastPathComponent) != nil
        video.highDefinition = media.isHighDefinition || (media.height == nil && hdByName)
        isAnalyzingVideo = false

        if media.durationMs == nil, media.frameRate == nil, !mediaToolHintShown, !MediaInfoService.hasExternalTool {
            mediaToolHintShown = true
            showSnack(L("Install mediainfo or ffprobe (e.g. with Homebrew) to read duration and frame rate from this file type."), duration: 6)
        }

        if !multidrop, let match = FileTypes.matchingSubtitle(forVideo: url) {
            proposeCompanion(match, kind: .subtitle)
        }

        guard UserDefaults.standard.bool(forKey: PrefKey.autoIdentify) else { return }
        await identifyVideo(url: url, hash: hash.moviehash)
    }

    /// Asks OpenSubtitles who this video is and fills the IMDb id (unless locked).
    private func identifyVideo(url: URL, hash: String) async {
        imdbLookupGeneration += 1
        let generation = imdbLookupGeneration
        let locked = locks.contains(.imdbId)
        isLookingUpImdb = true
        defer { if generation == imdbLookupGeneration { isLookingUpImdb = false } }

        do {
            let identified = try await client.identify(moviehash: hash)
            guard generation == imdbLookupGeneration, video.hash == hash else { return }

            if let meta = identified, let imdb = meta.imdbid, let title = meta.title {
                let text: String
                if let epTitle = meta.episodeTitle {
                    text = "\(title) S\(pad(meta.season))E\(pad(meta.episode)), \(epTitle) (\(meta.year ?? ""))"
                } else {
                    text = "\(title) (\(meta.year ?? ""))"
                }
                if locked {
                    showSnack(L("IMDb id is locked and was kept. Detected: %@", text), duration: 5)
                    await lookupImdbMetadata(video.imdbId, generation: generation)
                } else {
                    await applyImdb(id: imdb, title: text, showId: nil, fallbackTitle: meta.episodeTitle != nil ? title : nil, generation: generation)
                }
            } else if locked {
                await lookupImdbMetadata(video.imdbId, generation: generation)
            } else if let imdb = identified?.imdbid {
                await lookupImdbMetadata(imdb, generation: generation)
            } else if let guess = try await client.guessMovie(fromFilename: url.lastPathComponent) {
                guard generation == imdbLookupGeneration else { return }
                // GetIMDBMovieDetails does not know recent 8-digit ids; fall back to the guess' own title
                await lookupImdbMetadata(guess.imdbid, generation: generation, fallbackTitle: guess.displayTitle)
            } else {
                showSnack(L("Video could not be identified by OpenSubtitles. Metadata was read from the file; set the IMDb id manually."), duration: 5)
            }
        } catch {
            guard generation == imdbLookupGeneration else { return }
            AppLog.error("identifyVideo failed: \(String(describing: error))")
            if locked {
                await lookupImdbMetadata(video.imdbId, generation: generation)
            } else {
                showSnack(friendlyImportError(error), duration: 5)
            }
        }
    }

    private func friendlyImportError(_ error: Error) -> String {
        if let e = error as? OSError {
            switch e {
            case .unavailable, .offline: return L("Video cannot be imported because OpenSubtitles could not be reached. Is it online?")
            case .maintenance: return L("OpenSubtitles is under maintenance, please retry in a few hours")
            default: break
            }
        }
        if (error as? URLError) != nil {
            return L("Video cannot be imported because OpenSubtitles could not be reached. Is it online?")
        }
        return L("Video could not be identified by OpenSubtitles. Metadata was read from the file; set the IMDb id manually.")
    }

    private func pad(_ s: String?) -> String {
        guard let s, let n = Int(s) else { return s ?? "" }
        return n < 10 ? "0\(n)" : "\(n)"
    }

    /// Ask the user whether to replace the currently loaded companion file, or just load it.
    private func proposeCompanion(_ url: URL, kind: FileKind) {
        let existing = kind == .subtitle ? subtitle.path : video.path
        if let existing, existing.lastPathComponent != url.lastPathComponent {
            alert = AppAlert(
                title: kind == .subtitle ? L("Subtitle file") : L("Video file"),
                message: L("Replace the currently loaded file with the detected one: %@", url.lastPathComponent),
                buttons: [
                    AlertButton(title: L("YES")) {
                        if kind == .subtitle { self.addSubtitle(url, multidrop: true) } else { self.addVideo(url, multidrop: true) }
                    },
                    AlertButton(title: L("NO"), role: .cancel) {},
                ])
        } else if existing == nil {
            if kind == .subtitle { addSubtitle(url, multidrop: true) } else { addVideo(url, multidrop: true) }
        }
    }

    // MARK: IMDb

    /// Sets the IMDb id, title, and fetches a backdrop (Interface.imdbFromSearch in the original).
    private func applyImdb(id rawId: String, title: String, showId: String?, fallbackTitle: String?, generation: Int) async {
        guard generation == imdbLookupGeneration else { return }
        let digits = rawId.replacingOccurrences(of: "tt", with: "")
        let id = (Int(digits) ?? 0) > 99_999_999 ? digits : "tt" + digits
        if !locks.contains(.imdbId) { video.imdbId = id }
        video.imdbStatus = .verified(title: title)
        video.detectedTitle = title
        isLookingUpImdb = false
        showSearchSheet = false

        let url = await TMDBClient.backdrop(imdbId: showId ?? id, fallbackTitle: fallbackTitle)
        if generation == imdbLookupGeneration {
            video.backdropURL = url
        }
    }

    /// Verifies an IMDb id with OpenSubtitles and fills the title (OsActions.imdbMetadata in the original).
    /// Pass `generation` when called from a background lookup, so a newer manual edit cancels it.
    func lookupImdbMetadata(_ rawId: String, generation: Int? = nil, fallbackTitle: String? = nil) async {
        showSearchSheet = false
        video.backdropURL = nil

        let trimmed = rawId.trimmingCharacters(in: .whitespaces)
        if let n = Int(trimmed), n > 99_999_999 {
            // custom OpenSubtitles id, cannot be checked against IMDb
            if !locks.contains(.imdbId) { video.imdbId = trimmed }
            video.imdbStatus = .none
            isLookingUpImdb = false
            return
        }
        guard let imdbNumber = Int(trimmed.replacingOccurrences(of: "tt", with: "")) else {
            video.imdbStatus = .warning
            isLookingUpImdb = false
            showSnack(L("Wrong IMDB id"), duration: 3.5)
            return
        }

        let gen: Int
        if let generation {
            gen = generation
        } else {
            imdbLookupGeneration += 1
            gen = imdbLookupGeneration
        }
        isLookingUpImdb = true
        if !locks.contains(.imdbId) { video.imdbId = "tt" + String(imdbNumber) }

        do {
            let details = try await client.imdbDetails(imdbid: imdbNumber)
            guard gen == imdbLookupGeneration else { return }
            var text: String
            var fallback: String?
            if details.kind == "episode" {
                let parts = details.title.split(separator: "\"", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
                let show = parts.count > 1 ? parts[1] : details.title
                let ep = parts.count > 2 ? parts[2] : ""
                text = "\(show) S\(pad(details.season))E\(pad(details.episode)) - \(ep) (\(details.year))"
                fallback = show
            } else {
                text = "\(details.title) (\(details.year))"
            }
            await applyImdb(id: details.id, title: text, showId: details.showImdbId, fallbackTitle: fallback, generation: gen)
        } catch {
            guard gen == imdbLookupGeneration else { return }
            if let fallbackTitle, case OSError.wrongImdb = error {
                // the id came from OpenSubtitles itself, only the title lookup failed
                await applyImdb(id: "tt" + String(imdbNumber), title: fallbackTitle, showId: nil, fallbackTitle: fallbackTitle, generation: gen)
                return
            }
            isLookingUpImdb = false
            video.imdbStatus = .warning
            let message: String
            if let e = error as? OSError {
                switch e {
                case .offline, .unavailable: message = L("OpenSubtitles is temporarily unavailable, please retry in a little while")
                case .wrongImdb: message = L("Wrong IMDB id")
                default: message = L("Something went wrong :(")
                }
            } else {
                message = L("Something went wrong :(")
            }
            showSnack(message, duration: 3.5)
        }
    }

    /// Called when the IMDb field loses focus with a changed value. A manual edit always wins
    /// over any background identification still in flight (upstream issue #63).
    func imdbFieldCommitted(previous: String) {
        let value = video.imdbId.trimmingCharacters(in: .whitespaces)
        guard value != previous else { return }
        imdbLookupGeneration += 1
        isLookingUpImdb = false
        if value.isEmpty {
            video.imdbStatus = .none
            video.detectedTitle = ""
            video.backdropURL = nil
            return
        }
        Task { await lookupImdbMetadata(value) }
    }

    // MARK: IMDb search sheet

    func openSearch() {
        searchResults = []
        searchPerformed = false
        searchQuery = video.fileName.isEmpty ? "" : FileTypes.searchQuery(fromFilename: video.fileName)
        showSearchSheet = true
    }

    func runSearch() {
        let query = searchQuery.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty, !isSearching else { return }
        isSearching = true
        searchResults = []
        let seasonEpisode = video.fileName.isEmpty ? nil : FileTypes.seasonEpisode(video.fileName)
        Task {
            defer { isSearching = false; searchPerformed = true }
            searchResults = await TMDBClient.search(query, seasonEpisode: seasonEpisode)
        }
    }

    func selectSearchResult(_ result: SearchResult) {
        showSearchSheet = false
        isLookingUpImdb = true
        Task {
            if let imdb = await TMDBClient.imdbId(for: result) {
                await lookupImdbMetadata(imdb, fallbackTitle: result.title)
            } else {
                isLookingUpImdb = false
                showSnack(L("Not found"))
            }
        }
    }

    // MARK: Subtitle

    func addSubtitle(_ url: URL, multidrop: Bool) {
        reset(.subtitle)
        subtitle.path = url
        subtitle.fileName = url.lastPathComponent
        highlightMissingSubtitle = false

        Task.detached {
            let md5 = (try? OSHash.md5(of: url)) ?? ""
            let content = LanguageDetector.readText(url)
            let machine = FileTypes.looksMachineTranslated(filename: url.lastPathComponent, content: content)
            let hi = FileTypes.looksHearingImpaired(content: content)
            let foreign = FileTypes.looksForeignPartsOnly(url: url)
            await self.applySubtitleAnalysis(url: url, md5: md5, machine: machine, hearingImpaired: hi, foreign: foreign)
        }
        detectSubtitleLanguage(interactive: false)

        if !multidrop, let match = FileTypes.matchingVideo(forSubtitle: url) {
            proposeCompanion(match, kind: .video)
        }
    }

    private func applySubtitleAnalysis(url: URL, md5: String, machine: Bool, hearingImpaired: Bool, foreign: Bool) {
        guard subtitle.path == url else { return }
        subtitle.md5 = md5
        if machine { subtitle.autoTranslated = true }
        if hearingImpaired { subtitle.hearingImpaired = true }
        if foreign { subtitle.foreignPartsOnly = true }
    }

    private func applyDetectedLanguage(url: URL, code: String?) {
        isDetectingLanguage = false
        guard subtitle.path == url else { return }
        if let code {
            subtitle.languageCode = code
        } else {
            showSnack(L("Language testing unconclusive, automatic detection failed"), duration: 3.8)
        }
    }

    func detectSubtitleLanguage(interactive: Bool = true) {
        guard !locks.contains(.language) else { return }
        guard let url = subtitle.path else {
            if interactive { highlightMissingSubtitle = true; showSnack(L("Drop a subtitle file or select one")) }
            return
        }
        isDetectingLanguage = true
        Task.detached {
            let detected = LanguageDetector.bestLanguage(for: url)
            await self.applyDetectedLanguage(url: url, code: detected)
        }
    }

    // MARK: Reset

    enum ResetScope { case video, subtitle, all }

    func reset(_ scope: ResetScope) {
        switch scope {
        case .video:
            imdbLookupGeneration += 1
            video = VideoForm()
            isLookingUpImdb = false
            isAnalyzingVideo = false
            restoreLocks(fields: [.imdbId, .movieAka])
        case .subtitle:
            subtitle = SubtitleForm()
            isDetectingLanguage = false
            restoreLocks(fields: [.language, .translator, .comment])
        case .all:
            reset(.video)
            reset(.subtitle)
            uploadButtonState = .idle
            alert = nil
            showSearchSheet = false
        }
    }

    // MARK: Locks ("Save between sessions")

    private func restoreLocks(fields: [LockField] = LockField.allCases) {
        let defaults = UserDefaults.standard
        for field in fields {
            guard let value = defaults.string(forKey: field.prefKey) else {
                locks.remove(field)
                continue
            }
            locks.insert(field)
            setLockedValue(field, value)
        }
    }

    private func setLockedValue(_ field: LockField, _ value: String) {
        switch field {
        case .imdbId: video.imdbId = value
        case .movieAka: video.movieAka = value
        case .language: subtitle.languageCode = value
        case .translator: subtitle.translator = value
        case .comment: subtitle.comment = value
        }
    }

    private func currentValue(_ field: LockField) -> String {
        switch field {
        case .imdbId: return video.imdbId
        case .movieAka: return video.movieAka
        case .language: return subtitle.languageCode
        case .translator: return subtitle.translator
        case .comment: return subtitle.comment
        }
    }

    func toggleLock(_ field: LockField) {
        let defaults = UserDefaults.standard
        if locks.contains(field) {
            locks.remove(field)
            defaults.removeObject(forKey: field.prefKey)
        } else {
            let value = currentValue(field)
            guard !value.isEmpty else { return }
            locks.insert(field)
            defaults.set(value, forKey: field.prefKey)
        }
    }

    // MARK: Authentication

    /// Loads the stored account. The Keychain is read off the main thread: macOS may show a
    /// permission dialog for it (always for ad hoc signed builds), and that must not block the
    /// window from appearing.
    private func verifyLogin() {
        let defaults = UserDefaults.standard
        guard let user = defaults.string(forKey: PrefKey.username), !user.isEmpty else {
            isLoggedIn = false
            return
        }
        username = user
        let refreshed = defaults.double(forKey: PrefKey.userRefreshed)
        let isFresh = refreshed > 0 && refreshed + 604_800 > Date().timeIntervalSince1970
        if isFresh {
            userId = defaults.string(forKey: PrefKey.userId)
            userRank = defaults.string(forKey: PrefKey.userRank)
            isLoggedIn = true
        }
        credentialsTask = Task.detached { [client] in
            let password = Keychain.password(account: user)
            await client.setCredentials(username: user, password: password ?? "")
            return password != nil
        }
        Task {
            guard await credentialsLoaded() else {
                logout()
                return
            }
            if !isFresh { await refreshUserInfo() }
        }
    }

    /// Waits for the stored password to be loaded into the API client (see verifyLogin).
    private func credentialsLoaded() async -> Bool {
        guard let credentialsTask else { return isLoggedIn }
        return await credentialsTask.value
    }

    private func refreshUserInfo() async {
        do {
            let (_, info) = try await client.login()
            storeUserInfo(info)
            isLoggedIn = true
        } catch {
            AppLog.error("Unable to refresh user information: \(error.localizedDescription)")
            logout()
        }
    }

    private func storeUserInfo(_ info: OSUserInfo) {
        let defaults = UserDefaults.standard
        userId = info.idUser
        userRank = info.rank
        defaults.set(info.idUser, forKey: PrefKey.userId)
        defaults.set(info.rank, forKey: PrefKey.userRank)
        defaults.set(Date().timeIntervalSince1970, forKey: PrefKey.userRefreshed)
    }

    func login(username user: String, password: String) {
        let user = user.trimmingCharacters(in: .whitespaces)
        guard !user.isEmpty, !password.isEmpty else {
            loginError = L("Wrong username or password")
            return
        }
        isLoggingIn = true
        loginError = nil
        Task {
            defer { isLoggingIn = false }
            await client.setCredentials(username: user, password: password)
            do {
                let (_, info) = try await client.login()
                username = user
                credentialsTask = nil
                UserDefaults.standard.set(user, forKey: PrefKey.username)
                Task.detached { Keychain.save(password: password, account: user) }
                storeUserInfo(info)
                isLoggedIn = true
                showLoginSheet = false
                if uploadAfterLogin {
                    uploadAfterLogin = false
                    verifyAndUpload()
                }
            } catch {
                if case OSError.unauthorized = error {
                    loginError = L("Wrong username or password")
                } else {
                    loginError = error.localizedDescription
                }
            }
        }
    }

    func loginCancelled() {
        uploadAfterLogin = false
        loginError = nil
    }

    func logout() {
        let defaults = UserDefaults.standard
        credentialsTask = nil
        if let user = defaults.string(forKey: PrefKey.username) { Task.detached { Keychain.delete(account: user) } }
        defaults.removeObject(forKey: PrefKey.username)
        defaults.removeObject(forKey: PrefKey.userId)
        defaults.removeObject(forKey: PrefKey.userRank)
        defaults.removeObject(forKey: PrefKey.userRefreshed)
        isLoggedIn = false
        userId = nil
        userRank = nil
        Task { await client.setCredentials(username: "", password: "") }
    }

    func openProfile() {
        guard let userId, let url = URL(string: "https://www.opensubtitles.org/profile/iduser-\(userId)") else { return }
        openExternal(url)
    }

    // MARK: Upload

    /// Checks prerequisites before uploading (OsActions.verify in the original).
    func verifyAndUpload() {
        guard !isUploading else { return }
        alert = nil
        guard isLoggedIn else {
            // OpenSubtitles does not accept anonymous uploads: sign in first, then continue
            uploadAfterLogin = true
            showLoginSheet = true
            return
        }
        guard subtitle.path != nil else {
            highlightMissingSubtitle = true
            showSnack(L("Drop a subtitle file or select one"))
            return
        }
        if video.imdbId.trimmingCharacters(in: .whitespaces).isEmpty {
            alert = AppAlert(
                title: L("Upload"),
                message: L("You haven't specified an IMDB id for the video file. It is highly recommended to do so, to correctly categorize the subtitle and make it easy to download."),
                buttons: [
                    AlertButton(title: L("UPLOAD")) { self.upload() },
                    AlertButton(title: L("EDIT"), role: .cancel) {},
                ])
        } else {
            upload()
        }
    }

    func upload() {
        guard !isUploading, let subPath = subtitle.path else { return }
        alert = nil
        uploadButtonState = .idle

        var request = UploadRequest(videoPath: video.path, subtitlePath: subPath)
        request.imdbid = video.imdbId.nilIfEmpty
        request.sublanguageid = subtitle.languageCode.nilIfEmpty
        request.moviereleasename = video.releaseName.nilIfEmpty
        request.movieaka = video.movieAka.nilIfEmpty
        request.moviefps = video.fps.nilIfEmpty
        request.movieframes = video.frames.nilIfEmpty
        request.movietimems = video.timeMs.nilIfEmpty
        request.subauthorcomment = subtitle.comment.nilIfEmpty
        request.subtranslator = subtitle.translator.nilIfEmpty
        request.highdefinition = video.highDefinition
        request.hearingimpaired = subtitle.hearingImpaired
        request.automatictranslation = subtitle.autoTranslated
        request.foreignpartsonly = subtitle.foreignPartsOnly

        isUploading = true
        Task {
            defer { isUploading = false }
            do {
                _ = await credentialsLoaded()
                let outcome = try await client.upload(request)
                switch outcome {
                case .alreadyInDatabase(let idSubtitle, let hashAdded, let filenameAdded):
                    uploadButtonState = .partial
                    var lines = [L("Subtitle was already present in the database") + "."]
                    lines.append("• " + (hashAdded ? L("The hash has been added!") : L("The hash too...")))
                    lines.append("• " + (filenameAdded ? L("The file name has been added!") : L("The file name too...")))
                    var buttons = [AlertButton(title: L("OK")) { self.reset(.all) }]
                    if let idSubtitle, let url = URL(string: "https://www.opensubtitles.org/subtitles/\(idSubtitle)") {
                        buttons.append(AlertButton(title: L("OPEN IN BROWSER")) { self.openExternal(url) })
                    }
                    alert = AppAlert(title: L("Upload"), message: lines.joined(separator: "\n"), tone: .partial, buttons: buttons)
                case .uploaded(let url):
                    uploadButtonState = .success
                    var buttons = [AlertButton(title: L("OK")) { self.reset(.all) }]
                    if let url {
                        buttons.append(AlertButton(title: L("OPEN IN BROWSER")) { self.openExternal(url); self.reset(.all) })
                    }
                    alert = AppAlert(title: L("Upload"), message: L("Subtitle was successfully uploaded!"), tone: .success, buttons: buttons)
                }
            } catch {
                AppLog.error("Upload failed: \(String(describing: error))")
                uploadButtonState = .failure
                let message: String
                if let e = error as? OSError {
                    switch e {
                    case .unavailable, .offline: message = L("OpenSubtitles is temporarily unavailable, please retry in a little while")
                    case .maintenance: message = L("OpenSubtitles is under maintenance, please retry in a few hours")
                    case .invalidFormat: message = L("The subtitle has invalid format, review it before uploading to OpenSubtitles (try removing URL that might be considered as advertising for a third party website)")
                    case .missingImdb: message = L("You haven't specified an IMDB id for the video file. It is highly recommended to do so, to correctly categorize the subtitle and make it easy to download.")
                    default: message = L("Something went wrong :(")
                    }
                } else if let urlError = error as? URLError, urlError.code == .timedOut {
                    message = L("OpenSubtitles is temporarily unavailable, please retry in a little while")
                } else {
                    message = L("Something went wrong :(")
                }
                alert = AppAlert(title: L("Upload"), message: message, tone: .failure, buttons: [
                    AlertButton(title: L("RETRY")) { self.upload() },
                    AlertButton(title: L("OK"), role: .cancel) { self.uploadButtonState = .idle },
                ])
            }
            requestAttentionIfNeeded()
        }
    }

    // MARK: Updates

    func checkForUpdates(force: Bool) {
        let defaults = UserDefaults.standard
        if !force {
            guard defaults.bool(forKey: PrefKey.autoUpdate) else { return }
            if let pending = defaults.string(forKey: PrefKey.availableUpdate),
               UpdateChecker.isNewer(pending, than: AppInfo.version),
               let url = defaults.string(forKey: PrefKey.availableUpdateUrl).flatMap(URL.init(string:)) {
                presentUpdate(UpdateChecker.Update(version: pending, url: url))
            }
            let last = defaults.double(forKey: PrefKey.lastUpdateCheck)
            if last + 604_800 > Date().timeIntervalSince1970 { return }
        }
        defaults.set(Date().timeIntervalSince1970, forKey: PrefKey.lastUpdateCheck)
        Task {
            do {
                if let update = try await UpdateChecker.fetchLatest() {
                    defaults.set(update.version, forKey: PrefKey.availableUpdate)
                    defaults.set(update.url.absoluteString, forKey: PrefKey.availableUpdateUrl)
                    presentUpdate(update)
                } else {
                    defaults.removeObject(forKey: PrefKey.availableUpdate)
                    defaults.removeObject(forKey: PrefKey.availableUpdateUrl)
                    if force { showSnack(L("You are up to date.")) }
                }
            } catch {
                if force { showSnack(L("Unable to check for updates.")) }
            }
        }
    }

    private func presentUpdate(_ update: UpdateChecker.Update) {
        alert = AppAlert(
            title: L("Check for updates"),
            message: L("New version available, download %@ now!", "v" + update.version),
            buttons: [
                AlertButton(title: L("Download")) { self.openExternal(update.url) },
                AlertButton(title: L("Later"), role: .cancel) {},
            ])
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
