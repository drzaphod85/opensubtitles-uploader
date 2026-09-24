# OpenSubtitles Uploader for Mac

A native macOS app for uploading subtitles to [OpenSubtitles.org](https://www.opensubtitles.org),
written in Swift and SwiftUI. It is based on Jean van Kasteel's
[OpenSubtitles Uploader](https://github.com/vankasteelj/opensubtitles-uploader) (HTML5/NW.js)
and offers the same workflow — drop a video and a subtitle, check the detected metadata,
press **Upload** — but behaves like a proper Mac app: standard menu bar and keyboard
shortcuts, Finder drag & drop (including onto the Dock icon and *Open With…*), native
open panels, a Settings window (⌘,), system light/dark appearance, per-app language
selection in *System Settings › Language & Region*, password stored in the Keychain,
and native alerts and notifications.

As agreed with the original author ([issue #130](https://github.com/vankasteelj/opensubtitles-uploader/issues/130)),
the Mac app is maintained here, in this fork, with its own version numbers, its own
OpenSubtitles user agent (`OpenSubtitles-Uploader-Mac`) and its own API keys. The
HTML5 app is not affected by anything in the `macos/` folder.

Requires macOS 14 (Sonoma) or later. Universal binary (Apple silicon + Intel).

Original application by [Jean van Kasteel (vankasteelj)](https://github.com/vankasteelj).
macOS version by [Lasse L (drzaphod85)](https://github.com/drzaphod85). Both are
licensed under the GPL-3.0, see [LICENSE](../LICENSE).

## What is reused from the original

- The OpenSubtitles XML-RPC protocol (`LogIn`, `CheckMovieHash`,
  `GetIMDBMovieDetails`, `GuessMovieFromString`, `TryUploadSubtitles`,
  `UploadSubtitles`) is a direct port of the `opensubtitles-api` module,
  including the OSDb hash, MD5 and the zlib+base64 subtitle payload.
- TMDB for the title search and the backdrop image (the Trakt.tv key used by the
  HTML5 version has been revoked and answers 403 Forbidden). Updates are checked
  against the GitHub releases of this fork.
- All translations (`app/localization/*.json`) are converted to
  `.lproj/Localizable.strings` with `Scripts/generate-strings.py`.
- The subtitle language list (`os-lang.json`) and the app icon.
- All file-name heuristics (HD detection, machine translation / hearing
  impaired / foreign-parts detection, companion file matching, IMDb search
  query clean-up).

Native replacements: `mediainfo` → AVFoundation (falls back to `mediainfo` or
`ffprobe` if installed via Homebrew, e.g. for MKV files), `detect-lang` →
NaturalLanguage framework, localStorage → UserDefaults + Keychain.

## Queue, check, history

- **Queue.** Drop several files or a whole folder and the app pairs every subtitle with
  its video (same name, same `S01E02` tag; one video can serve several languages). The
  queue table appears above the form; select a row to edit it. **Upload All** (⇧⌘↩)
  uploads the queue one item after the other and shows a summary. This is the batch
  upload asked for in upstream issue #14.
- **Check** (⇧⌘K) asks OpenSubtitles whether a subtitle is already in the database
  without uploading it, for one item or the whole queue (File › Check All).
- **Upload History** (Window › Upload History, ⇧⌘H) lists everything uploaded from this
  Mac with links to the subtitle pages. Stored in
  `~/Library/Application Support/OpenSubtitles Uploader/history.json`.
- A Notification Center banner reports finished uploads when the app is in the background.

## Fixes for known issues of the HTML5 version

The macOS version addresses several long-standing reports from the
[issue tracker](https://github.com/vankasteelj/opensubtitles-uploader/issues):

| Issue | What the Mac version does |
| --- | --- |
| #116 IMDb id padlock ignored | A locked IMDb id is never overwritten by the automatic identification; the detected title is shown as a notice instead. |
| #63 manual IMDb id overwritten by the background search | A manual edit always wins; any lookup still in flight is discarded. A new setting also lets you turn the automatic lookup off. |
| #108 / #14 fields not cleared after upload | Dropping a new file after a successful upload starts from a clean form. |
| #41 / #107 fields erased on network failure | Hash, size, duration and fps are read locally first; the video stays loaded if OpenSubtitles cannot identify it, and an upload error never clears the form. |
| #94 / #103 empty video fields (broken mediainfo binaries) | AVFoundation is used, with `mediainfo`/`ffprobe` from Homebrew as a fallback for MKV and friends; a hint is shown when neither is installed. |
| #56 / #97 language detection | IETF tags in file names (`.pt-BR.srt`, `.zh-Hant.srt`, `.es-419.srt`, `.en.srt`) are understood and refine the content detection, which is done by Apple's NaturalLanguage framework. |
| #115 ordinary subtitles flagged as hearing impaired | Sound descriptions must also make up a noticeable share of the cues, not just exceed a fixed count. |
| #127 quotes in text fields | All text is XML-escaped; quotes and non-ASCII characters are covered by tests. |
| #129 missing languages (Spanish LA, …) | The subtitle language list is the full OpenSubtitles list (113 languages, `Scripts/merge-languages.py`). |
| IMDb search always "Not found" | The Trakt.tv key is revoked; the search now uses TMDB and can pick the exact episode when the file name carries S07E01. |
| #110 / #80 long IMDb ids | 8-digit ids are accepted; an id the server cannot verify is flagged but still uploadable. |
| #124 / #126 app does not start, "API seems offline" | Not applicable: no NW.js runtime, HTTPS on by default, native networking. |

Batch upload of several subtitles at once (#14) is covered by the queue, see above.

## Languages

All translations of the HTML5 version are reused (converted by
`Scripts/generate-strings.py`). The Mac version also ships Swedish, Danish,
Norwegian (Bokmål) and Icelandic; those four JSON files are proposed for
`app/localization/` in a separate pull request so the HTML5 version can use
them too. The strings that only exist in the Mac UI are translated in
`macos/Localization/`.

## API keys and user agent

- **TMDB.** The title search and the backdrop image need a TMDB API key. TMDB's terms
  ask every user to create their own free key, so the app does not ship one: get a key
  at https://www.themoviedb.org/settings/api and paste it into *Settings › General ›
  The Movie Database*, where a **Verify** button checks it. Without a key the app works,
  but the search sheet explains what is missing and no backdrop is shown.
- **OpenSubtitles user agent.** The app identifies itself as
  `OpenSubtitles-Uploader-Mac v<version>` (`AppInfo.userAgent`). OpenSubtitles asks
  developers to register user agents; see their
  [developer page](https://trac.opensubtitles.org/projects/opensubtitles/wiki/DevReadFirst).

## Building

With Xcode: open `Package.swift` and run the `OpenSubtitlesUploader` scheme,
or build the app bundle from the terminal (only the Command Line Tools are
required):

```bash
cd macos
Scripts/build-app.sh          # → build/OpenSubtitles Uploader.app
Scripts/build-app.sh --dmg    # → build/OpenSubtitles-Uploader-2.8.0-macOS.dmg
swift test                    # unit tests
```

Note for builds without Xcode.app: the Command Line Tools ship the Swift Testing
framework outside the default search path, so run the tests with

```bash
swift test --build-system native \
  -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks
```

`@State` is written as `@ViewState` (a typealias of the same property wrapper)
for the same reason: the SwiftUI macro plugin is only bundled with Xcode.

The bundle is assembled and signed in a temporary folder because iCloud Drive
and Finder add extended attributes to folders under `~/Documents`, which makes
`codesign` refuse a bundle ("Finder information … not allowed"). If you keep
the checkout in such a folder, use the `.dmg` for distribution and testing of
the signature.

The app is ad-hoc signed. For distribution outside the App Store it should be
signed with a Developer ID certificate and notarized:

```bash
codesign --force --deep --options runtime --sign "Developer ID Application: …" "build/OpenSubtitles Uploader.app"
xcrun notarytool submit build/OpenSubtitles-Uploader-2.8.0-macOS.dmg --keychain-profile … --wait
```

## Troubleshooting

- The app writes a log to `~/Library/Logs/OpenSubtitles Uploader/app.log`
  (also visible in Console.app under the subsystem `io.github.drzaphod85.opensubtitles-uploader`).
  Attach it when reporting an issue.
- The first launch of a freshly built, unnotarized bundle can take 15–30 s while
  macOS verifies the binary; later launches are instant. An ad hoc signed build
  also triggers the Keychain permission prompt for the stored password on every
  new build; a Developer ID signed release does not.

## Keyboard shortcuts

| Shortcut | Action |
| --- | --- |
| ⌘ O | Import file(s) |
| ⇧ ⌘ ⌫ | Clear file(s) |
| ⌘ ↩ | Upload |
| ⇧ ⌘ ↩ | Upload All |
| ⇧ ⌘ K | Check |
| ⇧ ⌘ H | Upload History |
| ⌘ F | Search on IMDb |
| ⇧ ⌘ L | Auto-detect subtitle language |
| ⌘ , | Settings |
| Esc | Close sheet |

## Project layout

```
macos/
├── Package.swift
├── Info.plist                      # bundle metadata, document types
├── Scripts/build-app.sh            # builds the .app / .dmg
├── Scripts/generate-strings.py     # converts app/localization/*.json → .lproj
├── Sources/OpenSubtitlesUploader/
│   ├── App/        entry point, menu commands, app delegate
│   ├── Model/      AppState — the application logic
│   ├── Services/   XML-RPC, OpenSubtitles API, hashing, media info, language detection, Trakt/TMDB
│   ├── Support/    localization, Keychain, preferences
│   ├── Views/      SwiftUI views
│   └── Resources/  icon, os-lang.json, *.lproj
└── Tests/
```
