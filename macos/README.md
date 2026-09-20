# OpenSubtitles Uploader for macOS

A native macOS version of OpenSubtitles Uploader, written in Swift and SwiftUI.
It offers the same workflow as the HTML5/NW.js application — drop a video and a
subtitle, check the detected metadata, press **Upload** — but behaves like a
proper Mac app: standard menu bar and keyboard shortcuts, Finder drag & drop
(including onto the Dock icon and *Open With…*), native open panels, a
Settings window (⌘,), system light/dark appearance, per-app language selection
in *System Settings › Language & Region*, password stored in the Keychain,
and native alerts and notifications.

Requires macOS 14 (Sonoma) or later. Universal binary (Apple silicon + Intel).

## What is reused from the original

- The OpenSubtitles XML-RPC protocol (`LogIn`, `CheckMovieHash`,
  `GetIMDBMovieDetails`, `GuessMovieFromString`, `TryUploadSubtitles`,
  `UploadSubtitles`) is a direct port of the `opensubtitles-api` module,
  including the OSDb hash, MD5 and the zlib+base64 subtitle payload. The same
  registered user agent (`OpenSubtitles-Uploader v2.8.0`) is used.
- TMDB for the title search and the backdrop image (the Trakt.tv key used by the
  HTML5 version has been revoked and answers 403 Forbidden), GitHub
  `package.json` for the weekly update check.
- All translations (`app/localization/*.json`) are converted to
  `.lproj/Localizable.strings` with `Scripts/generate-strings.py`.
- The subtitle language list (`os-lang.json`) and the app icon.
- All file-name heuristics (HD detection, machine translation / hearing
  impaired / foreign-parts detection, companion file matching, IMDb search
  query clean-up).

Native replacements: `mediainfo` → AVFoundation (falls back to `mediainfo` or
`ffprobe` if installed via Homebrew, e.g. for MKV files), `detect-lang` →
NaturalLanguage framework, localStorage → UserDefaults + Keychain.

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

Not addressed (yet): batch upload of several subtitles at once (#14).

## Languages

All translations of the HTML5 version are reused (converted by
`Scripts/generate-strings.py`). The Mac version also ships Swedish, Danish,
Norwegian (Bokmål) and Icelandic; those four JSON files are proposed for
`app/localization/` in a separate pull request so the HTML5 version can use
them too. The strings that only exist in the Mac UI are translated in
`macos/Localization/`.

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
  (also visible in Console.app under the subsystem `org.opensubtitles.uploader`).
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
