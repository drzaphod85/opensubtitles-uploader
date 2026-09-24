import Foundation
import AppKit
import Observation

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

    /// The upload queue. There is always at least one item: the one the detail form shows.
    var items: [QueueItem] = [QueueItem()]
    var selectedItemID: UUID?

    /// The item the detail form edits (selected item, or the last one).
    var current: QueueItem {
        if let selectedItemID, let item = items.first(where: { $0.id == selectedItemID }) { return item }
        return items.last!
    }

    // Proxies so the detail views keep reading `state.video` / `state.subtitle`.
    var video: VideoForm {
        get { current.video }
        set { current.video = newValue }
    }
    var subtitle: SubtitleForm {
        get { current.subtitle }
        set { current.subtitle = newValue }
    }
    var isAnalyzingVideo: Bool { current.isAnalyzingVideo }
    var isLookingUpImdb: Bool { current.isLookingUpImdb }
    var isDetectingLanguage: Bool { current.isDetectingLanguage }
    var showsQueue: Bool { items.count > 1 }

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
    var isUploading = false
    var isBatchRunning = false
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
    let history = UploadHistory.shared
    private var snackTask: Task<Void, Never>?
    private var mediaToolHintShown = false
    private var uploadAfterLogin = false
    private var credentialsTask: Task<Bool, Never>?

    private init() {
        let defaults = UserDefaults.standard
        client = OpenSubtitlesClient(userAgent: AppInfo.userAgent, useSSL: defaults.bool(forKey: PrefKey.useSSL))
        restoreLocks(into: current)
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

    // MARK: Queue management

    func item(_ id: UUID) -> QueueItem? { items.first { $0.id == id } }

    func select(_ id: UUID?) {
        selectedItemID = id
    }

    @discardableResult
    private func appendItem() -> QueueItem {
        let item = QueueItem()
        restoreLocks(into: item)
        items.append(item)
        return item
    }

    func removeItems(_ ids: Set<UUID>) {
        items.removeAll { ids.contains($0.id) && !$0.status.isBusy }
        if items.isEmpty { appendItem() }
        if let selectedItemID, !items.contains(where: { $0.id == selectedItemID }) {
            self.selectedItemID = items.last?.id
        }
    }

    func removeFinishedItems() {
        removeItems(Set(items.filter { $0.status == .uploaded }.map(\.id)))
    }

    var queueSummary: String {
        let uploaded = items.filter { $0.status == .uploaded }.count
        return L("%@ of %@ uploaded", String(uploaded), String(items.count))
    }

    // MARK: Files in / out

    func handleDropped(_ urls: [URL]) {
        dragHighlight = []
        isDragTargeted = false
        let files = QueuePlanner.collectFiles(urls)
        if files.isEmpty {
            showSnack(L("Dropped file is not supported"))
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        showSearchSheet = false
        alert = nil

        // the previous upload is done; start from a clean sheet (upstream issue #108)
        if !showsQueue, uploadButtonState == .success || uploadButtonState == .partial {
            reset(.all)
        }

        let videos = files.filter { FileTypes.kind(of: $0) == .video }
        let subtitles = files.filter { FileTypes.kind(of: $0) == .subtitle }

        // A single file, or one pair, goes into the current item like the original app did.
        if videos.count <= 1, subtitles.count <= 1, urls.allSatisfy({ (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true }) {
            let target = current
            let multidrop = videos.count == 1 && subtitles.count == 1
            if let v = videos.first { addVideo(v, to: target, multidrop: multidrop) }
            if let s = subtitles.first { addSubtitle(s, to: target, multidrop: multidrop) }
            return
        }

        // Several files or a folder: plan pairs and add them to the queue.
        let pairs = QueuePlanner.plan(files)
        var added: [QueueItem] = []
        for pair in pairs {
            // reuse the current item if it is still empty
            let target = (added.isEmpty && current.isEmpty) ? current : appendItem()
            added.append(target)
            if let v = pair.video { addVideo(v, to: target, multidrop: true) }
            if let s = pair.subtitle { addSubtitle(s, to: target, multidrop: true) }
        }
        if let first = added.first { selectedItemID = first.id }
        showSnack(L("Added %@ items to the queue", String(added.count)))
    }

    func browse(_ kind: FileKind?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = kind == nil
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

    func addVideo(_ url: URL, to item: QueueItem? = nil, multidrop: Bool) {
        let target = item ?? current
        Task { await importVideo(url, into: target, multidrop: multidrop) }
    }

    /// Imports a video. Local metadata (hash, size, duration, fps) is always filled in; the
    /// OpenSubtitles identification is best effort so the file stays loaded when the API is
    /// unreachable (upstream issues #41, #107). A locked IMDb id is never overwritten (#116)
    /// and a manual id entered meanwhile wins over the background lookup (#63).
    private func importVideo(_ url: URL, into item: QueueItem, multidrop: Bool) async {
        item.isAnalyzingVideo = true
        let hash: OSHash.MovieHash
        do {
            hash = try await Task.detached { try OSHash.movieHash(of: url) }.value
        } catch {
            item.isAnalyzingVideo = false
            showSnack(L("Dropped file is not supported"))
            AppLog.error("movieHash failed: \(error)")
            return
        }
        if hash.moviehash == item.video.hash, !item.video.hash.isEmpty {
            item.isAnalyzingVideo = false
            return // already loaded
        }

        let media = await MediaInfoService.analyze(url)

        resetVideo(of: item)
        item.video.path = url
        item.video.fileName = url.lastPathComponent
        item.video.byteSize = hash.moviebytesize
        item.video.hash = hash.moviehash
        item.video.timeMs = media.durationMs.map(String.init) ?? ""
        item.video.fps = media.frameRateString ?? ""
        item.video.frames = media.frameCount.map(String.init) ?? ""
        let hdByName = FileTypes.extractQuality(url.lastPathComponent) != nil
        item.video.highDefinition = media.isHighDefinition || (media.height == nil && hdByName)
        item.isAnalyzingVideo = false
        if item.status == .idle, item.subtitle.path != nil { item.status = .ready }

        if media.durationMs == nil, media.frameRate == nil, !mediaToolHintShown, !MediaInfoService.hasExternalTool {
            mediaToolHintShown = true
            showSnack(L("Install mediainfo or ffprobe (e.g. with Homebrew) to read duration and frame rate from this file type."), duration: 6)
        }

        if !multidrop, let match = FileTypes.matchingSubtitle(forVideo: url) {
            proposeCompanion(match, kind: .subtitle, for: item)
        }

        guard UserDefaults.standard.bool(forKey: PrefKey.autoIdentify) else { return }
        await identifyVideo(url: url, hash: hash.moviehash, item: item)
    }

    /// Asks OpenSubtitles who this video is and fills the IMDb id (unless locked).
    private func identifyVideo(url: URL, hash: String, item: QueueItem) async {
        item.imdbLookupGeneration += 1
        let generation = item.imdbLookupGeneration
        let locked = locks.contains(.imdbId)
        item.isLookingUpImdb = true
        defer { if generation == item.imdbLookupGeneration { item.isLookingUpImdb = false } }

        do {
            let identified = try await client.identify(moviehash: hash)
            guard generation == item.imdbLookupGeneration, item.video.hash == hash else { return }

            if let meta = identified, let imdb = meta.imdbid, let title = meta.title {
                let text: String
                if let epTitle = meta.episodeTitle {
                    text = "\(title) S\(pad(meta.season))E\(pad(meta.episode)), \(epTitle) (\(meta.year ?? ""))"
                } else {
                    text = "\(title) (\(meta.year ?? ""))"
                }
                if locked {
                    if item === current { showSnack(L("IMDb id is locked and was kept. Detected: %@", text), duration: 5) }
                    await lookupImdbMetadata(item.video.imdbId, item: item, generation: generation)
                } else {
                    await applyImdb(id: imdb, title: text, showId: nil, fallbackTitle: meta.episodeTitle != nil ? title : nil, item: item, generation: generation)
                }
            } else if locked {
                await lookupImdbMetadata(item.video.imdbId, item: item, generation: generation)
            } else if let imdb = identified?.imdbid {
                await lookupImdbMetadata(imdb, item: item, generation: generation)
            } else if let guess = try await client.guessMovie(fromFilename: url.lastPathComponent) {
                guard generation == item.imdbLookupGeneration else { return }
                // GetIMDBMovieDetails does not know recent 8-digit ids; fall back to the guess' own title
                await lookupImdbMetadata(guess.imdbid, item: item, generation: generation, fallbackTitle: guess.displayTitle)
            } else if item === current {
                showSnack(L("Video could not be identified by OpenSubtitles. Metadata was read from the file; set the IMDb id manually."), duration: 5)
            }
        } catch {
            guard generation == item.imdbLookupGeneration else { return }
            AppLog.error("identifyVideo failed: \(error)")
            if locked {
                await lookupImdbMetadata(item.video.imdbId, item: item, generation: generation)
            } else if item === current {
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
    private func proposeCompanion(_ url: URL, kind: FileKind, for item: QueueItem) {
        let existing = kind == .subtitle ? item.subtitle.path : item.video.path
        if let existing, existing.lastPathComponent != url.lastPathComponent {
            guard item === current else { return }
            alert = AppAlert(
                title: kind == .subtitle ? L("Subtitle file") : L("Video file"),
                message: L("Replace the currently loaded file with the detected one: %@", url.lastPathComponent),
                buttons: [
                    AlertButton(title: L("YES")) {
                        if kind == .subtitle { self.addSubtitle(url, to: item, multidrop: true) } else { self.addVideo(url, to: item, multidrop: true) }
                    },
                    AlertButton(title: L("NO"), role: .cancel) {},
                ])
        } else if existing == nil {
            if kind == .subtitle { addSubtitle(url, to: item, multidrop: true) } else { addVideo(url, to: item, multidrop: true) }
        }
    }

    // MARK: IMDb

    /// Sets the IMDb id, title, and fetches a backdrop (Interface.imdbFromSearch in the original).
    private func applyImdb(id rawId: String, title: String, showId: String?, fallbackTitle: String?, item: QueueItem, generation: Int) async {
        guard generation == item.imdbLookupGeneration else { return }
        let digits = rawId.replacingOccurrences(of: "tt", with: "")
        let id = (Int(digits) ?? 0) > 99_999_999 ? digits : "tt" + digits
        if !locks.contains(.imdbId) { item.video.imdbId = id }
        item.video.imdbStatus = .verified(title: title)
        item.video.detectedTitle = title
        item.isLookingUpImdb = false
        showSearchSheet = false

        let url = await TMDBClient.backdrop(imdbId: showId ?? id, fallbackTitle: fallbackTitle)
        if generation == item.imdbLookupGeneration {
            item.video.backdropURL = url
        }
    }

    /// Verifies an IMDb id with OpenSubtitles and fills the title (OsActions.imdbMetadata in the original).
    /// Pass `generation` when called from a background lookup, so a newer manual edit cancels it.
    func lookupImdbMetadata(_ rawId: String, item: QueueItem? = nil, generation: Int? = nil, fallbackTitle: String? = nil) async {
        let item = item ?? current
        showSearchSheet = false
        item.video.backdropURL = nil

        let trimmed = rawId.trimmingCharacters(in: .whitespaces)
        if let n = Int(trimmed), n > 99_999_999 {
            // custom OpenSubtitles id, cannot be checked against IMDb
            if !locks.contains(.imdbId) { item.video.imdbId = trimmed }
            item.video.imdbStatus = .none
            item.isLookingUpImdb = false
            return
        }
        guard let imdbNumber = Int(trimmed.replacingOccurrences(of: "tt", with: "")) else {
            item.video.imdbStatus = .warning
            item.isLookingUpImdb = false
            if item === current { showSnack(L("Wrong IMDB id"), duration: 3.5) }
            return
        }

        let gen: Int
        if let generation {
            gen = generation
        } else {
            item.imdbLookupGeneration += 1
            gen = item.imdbLookupGeneration
        }
        item.isLookingUpImdb = true
        if !locks.contains(.imdbId) { item.video.imdbId = "tt" + String(imdbNumber) }

        do {
            let details = try await client.imdbDetails(imdbid: imdbNumber)
            guard gen == item.imdbLookupGeneration else { return }
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
            await applyImdb(id: details.id, title: text, showId: details.showImdbId, fallbackTitle: fallback, item: item, generation: gen)
        } catch {
            guard gen == item.imdbLookupGeneration else { return }
            if let fallbackTitle, case OSError.wrongImdb = error {
                // the id came from OpenSubtitles itself, only the title lookup failed
                await applyImdb(id: "tt" + String(imdbNumber), title: fallbackTitle, showId: nil, fallbackTitle: fallbackTitle, item: item, generation: gen)
                return
            }
            item.isLookingUpImdb = false
            item.video.imdbStatus = .warning
            guard item === current else { return }
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
        let item = current
        let value = item.video.imdbId.trimmingCharacters(in: .whitespaces)
        guard value != previous else { return }
        item.imdbLookupGeneration += 1
        item.isLookingUpImdb = false
        if value.isEmpty {
            item.video.imdbStatus = .none
            item.video.detectedTitle = ""
            item.video.backdropURL = nil
            return
        }
        Task { await lookupImdbMetadata(value, item: item) }
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
        let item = current
        showSearchSheet = false
        item.isLookingUpImdb = true
        Task {
            if let imdb = await TMDBClient.imdbId(for: result) {
                await lookupImdbMetadata(imdb, item: item, fallbackTitle: result.title)
            } else {
                item.isLookingUpImdb = false
                showSnack(L("Not found"))
            }
        }
    }

    // MARK: Subtitle

    func addSubtitle(_ url: URL, to item: QueueItem? = nil, multidrop: Bool) {
        let item = item ?? current
        resetSubtitle(of: item)
        item.subtitle.path = url
        item.subtitle.fileName = url.lastPathComponent
        item.status = .ready
        highlightMissingSubtitle = false

        Task.detached {
            let md5 = (try? OSHash.md5(of: url)) ?? ""
            let content = LanguageDetector.readText(url)
            let machine = FileTypes.looksMachineTranslated(filename: url.lastPathComponent, content: content)
            let hi = FileTypes.looksHearingImpaired(content: content)
            let foreign = FileTypes.looksForeignPartsOnly(url: url)
            await self.applySubtitleAnalysis(item: item, url: url, md5: md5, machine: machine, hearingImpaired: hi, foreign: foreign)
        }
        detectSubtitleLanguage(item: item, interactive: false)

        if !multidrop, let match = FileTypes.matchingVideo(forSubtitle: url) {
            proposeCompanion(match, kind: .video, for: item)
        }
    }

    private func applySubtitleAnalysis(item: QueueItem, url: URL, md5: String, machine: Bool, hearingImpaired: Bool, foreign: Bool) {
        guard item.subtitle.path == url else { return }
        item.subtitle.md5 = md5
        if machine { item.subtitle.autoTranslated = true }
        if hearingImpaired { item.subtitle.hearingImpaired = true }
        if foreign { item.subtitle.foreignPartsOnly = true }
    }

    private func applyDetectedLanguage(item: QueueItem, url: URL, code: String?) {
        item.isDetectingLanguage = false
        guard item.subtitle.path == url else { return }
        if let code {
            item.subtitle.languageCode = code
        } else if item === current {
            showSnack(L("Language testing unconclusive, automatic detection failed"), duration: 3.8)
        }
    }

    func detectSubtitleLanguage(item: QueueItem? = nil, interactive: Bool = true) {
        let item = item ?? current
        guard !locks.contains(.language) else { return }
        guard let url = item.subtitle.path else {
            if interactive { highlightMissingSubtitle = true; showSnack(L("Drop a subtitle file or select one")) }
            return
        }
        item.isDetectingLanguage = true
        Task.detached {
            let detected = LanguageDetector.bestLanguage(for: url)
            await self.applyDetectedLanguage(item: item, url: url, code: detected)
        }
    }

    // MARK: Reset

    enum ResetScope { case video, subtitle, all }

    private func resetVideo(of item: QueueItem) {
        item.imdbLookupGeneration += 1
        item.video = VideoForm()
        item.isLookingUpImdb = false
        item.isAnalyzingVideo = false
        restoreLocks(into: item, fields: [.imdbId, .movieAka])
        if item.subtitle.path == nil { item.status = .idle }
    }

    private func resetSubtitle(of item: QueueItem) {
        item.subtitle = SubtitleForm()
        item.isDetectingLanguage = false
        item.status = .idle
        item.uploadedURL = nil
        item.existingSubtitleURL = nil
        restoreLocks(into: item, fields: [.language, .translator, .comment])
    }

    func reset(_ scope: ResetScope) {
        switch scope {
        case .video:
            resetVideo(of: current)
        case .subtitle:
            resetSubtitle(of: current)
        case .all:
            items = []
            appendItem()
            selectedItemID = nil
            uploadButtonState = .idle
            alert = nil
            showSearchSheet = false
        }
    }

    // MARK: Locks ("Save between sessions")

    private func restoreLocks(into item: QueueItem, fields: [LockField] = LockField.allCases) {
        let defaults = UserDefaults.standard
        for field in fields {
            guard let value = defaults.string(forKey: field.prefKey) else {
                locks.remove(field)
                continue
            }
            locks.insert(field)
            setLockedValue(field, value, on: item)
        }
    }

    private func setLockedValue(_ field: LockField, _ value: String, on item: QueueItem) {
        switch field {
        case .imdbId: item.video.imdbId = value
        case .movieAka: item.video.movieAka = value
        case .language: item.subtitle.languageCode = value
        case .translator: item.subtitle.translator = value
        case .comment: item.subtitle.comment = value
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
            // a locked value applies to every item in the queue
            for item in items where item !== current { setLockedValue(field, value, on: item) }
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

    private func uploadRequest(for item: QueueItem) -> UploadRequest? {
        guard let subPath = item.subtitle.path else { return nil }
        var request = UploadRequest(videoPath: item.video.path, subtitlePath: subPath)
        request.imdbid = item.video.imdbId.nilIfEmpty
        request.sublanguageid = item.subtitle.languageCode.nilIfEmpty
        request.moviereleasename = item.video.releaseName.nilIfEmpty
        request.movieaka = item.video.movieAka.nilIfEmpty
        request.moviefps = item.video.fps.nilIfEmpty
        request.movieframes = item.video.frames.nilIfEmpty
        request.movietimems = item.video.timeMs.nilIfEmpty
        request.subauthorcomment = item.subtitle.comment.nilIfEmpty
        request.subtranslator = item.subtitle.translator.nilIfEmpty
        request.highdefinition = item.video.highDefinition
        request.hearingimpaired = item.subtitle.hearingImpaired
        request.automatictranslation = item.subtitle.autoTranslated
        request.foreignpartsonly = item.subtitle.foreignPartsOnly
        return request
    }

    private func subtitleURL(forId id: String?) -> URL? {
        id.flatMap { URL(string: "https://www.opensubtitles.org/subtitles/\($0)") }
    }

    /// Checks prerequisites before uploading the current item (OsActions.verify in the original).
    func verifyAndUpload() {
        guard !isUploading, !isBatchRunning else { return }
        alert = nil
        guard isLoggedIn else {
            // OpenSubtitles does not accept anonymous uploads: sign in first, then continue
            uploadAfterLogin = true
            showLoginSheet = true
            return
        }
        guard current.subtitle.path != nil else {
            highlightMissingSubtitle = true
            showSnack(L("Drop a subtitle file or select one"))
            return
        }
        if current.video.imdbId.trimmingCharacters(in: .whitespaces).isEmpty {
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

    /// Uploads the current item and shows the result as an alert.
    func upload() {
        guard !isUploading, !isBatchRunning else { return }
        let item = current
        guard let request = uploadRequest(for: item) else { return }
        alert = nil
        uploadButtonState = .idle
        isUploading = true
        Task {
            defer { isUploading = false }
            let result = await performUpload(request, item: item)
            switch result {
            case .exists(let url):
                uploadButtonState = .partial
                var lines = [L("Subtitle was already present in the database") + "."]
                lines.append("• " + item.existsDetails.0)
                lines.append("• " + item.existsDetails.1)
                var buttons = [AlertButton(title: L("OK")) { self.reset(.all) }]
                if let url { buttons.append(AlertButton(title: L("OPEN IN BROWSER")) { self.openExternal(url) }) }
                alert = AppAlert(title: L("Upload"), message: lines.joined(separator: "\n"), tone: .partial, buttons: buttons)
                NotificationService.post(title: L("Subtitle was already present in the database"), body: item.displayName, url: url)
            case .uploaded(let url):
                uploadButtonState = .success
                var buttons = [AlertButton(title: L("OK")) { self.reset(.all) }]
                if let url { buttons.append(AlertButton(title: L("OPEN IN BROWSER")) { self.openExternal(url); self.reset(.all) }) }
                alert = AppAlert(title: L("Upload"), message: L("Subtitle was successfully uploaded!"), tone: .success, buttons: buttons)
                NotificationService.post(title: L("Subtitle was successfully uploaded!"), body: item.displayName, url: url)
            case .failed(let message):
                uploadButtonState = .failure
                alert = AppAlert(title: L("Upload"), message: message, tone: .failure, buttons: [
                    AlertButton(title: L("RETRY")) { self.upload() },
                    AlertButton(title: L("OK"), role: .cancel) { self.uploadButtonState = .idle },
                ])
                NotificationService.post(title: L("Something went wrong :("), body: item.displayName)
            }
            requestAttentionIfNeeded()
        }
    }

    private enum UploadResult {
        case uploaded(URL?)
        case exists(URL?)
        case failed(String)
    }

    /// Runs one upload, updates the item's status and the history.
    private func performUpload(_ request: UploadRequest, item: QueueItem) async -> UploadResult {
        item.status = .uploading
        _ = await credentialsLoaded()
        do {
            let outcome = try await client.upload(request)
            switch outcome {
            case .alreadyInDatabase(let idSubtitle, let hashAdded, let filenameAdded):
                let url = subtitleURL(forId: idSubtitle)
                item.status = .exists
                item.existingSubtitleURL = url
                item.existsDetails = (
                    hashAdded ? L("The hash has been added!") : L("The hash too..."),
                    filenameAdded ? L("The file name has been added!") : L("The file name too...")
                )
                history.add(historyEntry(for: item, result: .exists, url: url))
                return .exists(url)
            case .uploaded(let url):
                item.status = .uploaded
                item.uploadedURL = url
                history.add(historyEntry(for: item, result: .uploaded, url: url))
                return .uploaded(url)
            }
        } catch {
            AppLog.error("Upload failed: \(error)")
            let message = friendlyUploadError(error)
            item.status = .failed(message)
            return .failed(message)
        }
    }

    private func friendlyUploadError(_ error: Error) -> String {
        if let e = error as? OSError {
            switch e {
            case .unavailable, .offline: return L("OpenSubtitles is temporarily unavailable, please retry in a little while")
            case .maintenance: return L("OpenSubtitles is under maintenance, please retry in a few hours")
            case .invalidFormat: return L("The subtitle has invalid format, review it before uploading to OpenSubtitles (try removing URL that might be considered as advertising for a third party website)")
            case .missingImdb: return L("You haven't specified an IMDB id for the video file. It is highly recommended to do so, to correctly categorize the subtitle and make it easy to download.")
            case .unauthorized: return L("Wrong username or password")
            default: return L("Something went wrong :(")
            }
        }
        if let urlError = error as? URLError, urlError.code == .timedOut {
            return L("OpenSubtitles is temporarily unavailable, please retry in a little while")
        }
        return L("Something went wrong :(")
    }

    private func historyEntry(for item: QueueItem, result: HistoryEntry.Result, url: URL?) -> HistoryEntry {
        HistoryEntry(subtitleName: item.subtitle.fileName,
                     videoName: item.video.fileName.nilIfEmpty,
                     languageCode: item.subtitle.languageCode.nilIfEmpty,
                     imdbId: item.video.imdbId.nilIfEmpty,
                     title: item.video.detectedTitle.nilIfEmpty,
                     result: result,
                     url: url)
    }

    // MARK: Batch upload / check

    /// Items that can still be uploaded, in queue order.
    var uploadableItems: [QueueItem] { items.filter { $0.canUpload } }

    /// Uploads every item that has a subtitle and is not uploaded yet, one after the other.
    func uploadAll() {
        guard !isUploading, !isBatchRunning else { return }
        guard isLoggedIn else {
            uploadAfterLogin = false
            showLoginSheet = true
            return
        }
        let todo = uploadableItems
        guard !todo.isEmpty else { return }
        alert = nil
        isBatchRunning = true
        Task {
            defer { isBatchRunning = false }
            var uploaded = 0, exists = 0, failed = 0
            for item in todo {
                guard let request = uploadRequest(for: item) else { continue }
                switch await performUpload(request, item: item) {
                case .uploaded: uploaded += 1
                case .exists: exists += 1
                case .failed: failed += 1
                }
            }
            let summary = L("Batch upload finished: %@ uploaded, %@ already in the database, %@ failed.", String(uploaded), String(exists), String(failed))
            alert = AppAlert(title: L("Upload All"), message: summary, tone: failed > 0 ? .failure : (exists > 0 ? .partial : .success), buttons: [
                AlertButton(title: L("OK")) {},
                AlertButton(title: L("Remove uploaded items")) { self.removeFinishedItems() },
            ])
            NotificationService.post(title: L("Upload All"), body: summary)
            requestAttentionIfNeeded()
        }
    }

    /// Dry run for one item: does OpenSubtitles already have this subtitle?
    func check(_ item: QueueItem? = nil) {
        let item = item ?? current
        guard let request = uploadRequest(for: item), !item.status.isBusy, item.status != .uploaded else {
            if item.subtitle.path == nil { highlightMissingSubtitle = true; showSnack(L("Drop a subtitle file or select one")) }
            return
        }
        item.status = .checking
        Task {
            do {
                switch try await client.check(request) {
                case .exists(let idSubtitle):
                    item.status = .exists
                    item.existingSubtitleURL = subtitleURL(forId: idSubtitle)
                    if item === current { showSnack(L("Subtitle was already present in the database"), duration: 4) }
                case .new:
                    item.status = .ready
                    if item === current { showSnack(L("Not in the database yet, ready to upload."), duration: 3) }
                }
            } catch {
                item.status = .ready
                if item === current { showSnack(friendlyUploadError(error), duration: 4) }
            }
        }
    }

    func checkAll() {
        for item in items where item.subtitle.path != nil && !item.status.isBusy && item.status != .uploaded {
            check(item)
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
