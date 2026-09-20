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
            HStack(spacing: 4) {
                Text(L("developed by"))
                Button("vankasteelj") { state.openExternal(AppInfo.author) }.buttonStyle(.link)
            }
            .font(.callout)
            HStack(spacing: 16) {
                Button(L("Source code on GitHub")) { state.openExternal(AppInfo.homepage) }
                Button(L("Report an issue")) { state.openExternal(AppInfo.issues) }
            }
            .buttonStyle(.link)
            Text("GPL-3.0").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
    }
}
