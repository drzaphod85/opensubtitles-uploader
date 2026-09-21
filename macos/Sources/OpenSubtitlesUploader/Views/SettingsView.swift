import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label(L("General"), systemImage: "gearshape") }
            ShortcutsSettingsView()
                .tabItem { Label(L("Shortcuts"), systemImage: "keyboard") }
            AboutSettingsView()
                .tabItem { Label(L("About"), systemImage: "info.circle") }
        }
        .frame(width: 520)
    }
}

struct GeneralSettingsView: View {
    @Environment(AppState.self) private var state
    @AppStorage(PrefKey.appearance) private var appearance = Appearance.system.rawValue
    @AppStorage(PrefKey.autoUpdate) private var autoUpdate = true
    @AppStorage(PrefKey.useSSL) private var useSSL = true
    @AppStorage(PrefKey.autoIdentify) private var autoIdentify = true
    @AppStorage(PrefKey.tmdbApiKey) private var tmdbApiKey = ""
    @ViewState private var keyCheck: TMDBClient.KeyCheck?
    @ViewState private var isVerifying = false

    var body: some View {
        Form {
            Picker(L("Appearance"), selection: $appearance) {
                ForEach(Appearance.allCases) { a in
                    Text(a.title).tag(a.rawValue)
                }
            }
            .pickerStyle(.segmented)

            Section {
                Toggle(L("Check for updates automatically"), isOn: $autoUpdate)
                    .onChange(of: autoUpdate) { _, on in
                        if on { state.checkForUpdates(force: false) }
                    }
                Button(L("Check for Updates Now")) { state.checkForUpdates(force: true) }
            }

            Section(L("Identification")) {
                Toggle(L("Look up the IMDb id automatically when a video is added"), isOn: $autoIdentify)
            }

            Section {
                TextField(L("TMDB API key"), text: $tmdbApiKey, prompt: Text("e.g. 3f2c…"))
                    .font(.system(.body, design: .monospaced))
                    .autocorrectionDisabled()
                    .onChange(of: tmdbApiKey) { _, _ in keyCheck = nil }
                HStack {
                    Button(L("Verify")) { verifyKey() }
                        .disabled(tmdbApiKey.trimmingCharacters(in: .whitespaces).isEmpty || isVerifying)
                    if isVerifying {
                        ProgressView().controlSize(.small)
                    } else if let keyCheck {
                        switch keyCheck {
                        case .valid: Label(L("The key works."), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        case .invalid: Label(L("TMDB rejected this key."), systemImage: "xmark.circle.fill").foregroundStyle(.red)
                        case .unreachable: Label(L("Could not reach TMDB."), systemImage: "wifi.exclamationmark").foregroundStyle(.orange)
                        }
                    }
                    Spacer()
                    Button(L("Get a free key…")) { state.openExternal(APIKeys.tmdbSignupURL) }
                        .buttonStyle(.link)
                }
            } header: {
                Text(L("The Movie Database (TMDB)"))
            } footer: {
                Text(L("Used for the IMDb title search and the backdrop image. TMDB asks every user to create their own free key; without one, those two features are disabled."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle(L("Use HTTPS when talking to OpenSubtitles"), isOn: $useSSL)
                    .onChange(of: useSSL) { _, on in state.setUseSSL(on) }
            }

            Section(L("Language")) {
                Text(L("The application language follows your system preference. You can choose a different language for this app in System Settings › General › Language & Region."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button(L("Open Language & Region…")) {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    Button("[" + L("help translating") + "]") { state.openExternal(AppInfo.transifex) }
                        .buttonStyle(.link)
                }
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
    }

    private func verifyKey() {
        isVerifying = true
        let key = tmdbApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            keyCheck = await TMDBClient.verify(key: key)
            isVerifying = false
        }
    }
}

struct ShortcutsSettingsView: View {
    private let shortcuts: [(String, String)] = [
        ("⌘ O", L("Import file(s)")),
        ("⇧ ⌘ ⌫", L("Clear file(s)")),
        ("⌘ ↩", L("Upload")),
        ("⌘ F", L("Search on IMDB directly")),
        ("⇧ ⌘ L", L("Auto-detect the language")),
        ("⌘ ,", L("Settings")),
        ("Esc", L("Close popup(s)")),
        ("Tab", L("Next field")),
        ("⇧ Tab", L("Previous field")),
    ]

    var body: some View {
        Form {
            ForEach(shortcuts, id: \.0) { keys, text in
                LabeledContent(text) {
                    Text(keys).font(.system(.body, design: .rounded).monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
    }
}

struct AboutSettingsView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            Text("OpenSubtitles Uploader").font(.title2.bold())
            Text(L("Version %@", AppInfo.version)).foregroundStyle(.secondary)
            VStack(spacing: 2) {
                HStack(spacing: 4) {
                    Text(L("developed by"))
                    Button("vankasteelj") { state.openExternal(AppInfo.author) }.buttonStyle(.link)
                }
                HStack(spacing: 4) {
                    Text(L("macOS version by"))
                    Button("Lasse L (drzaphod85)") { state.openExternal(AppInfo.macAuthor) }.buttonStyle(.link)
                }
            }
            .font(.callout)
            HStack(spacing: 16) {
                Button(L("Source code on GitHub")) { state.openExternal(AppInfo.homepage) }
                Button(L("Report an issue")) { state.openExternal(AppInfo.issues) }
                Button(L("Original project")) { state.openExternal(AppInfo.originalProject) }
            }
            .buttonStyle(.link)
            Text("GPL-3.0").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
    }
}
