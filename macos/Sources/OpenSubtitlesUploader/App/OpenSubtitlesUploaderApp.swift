import SwiftUI
import AppKit

@main
struct OpenSubtitlesUploaderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ViewState private var state = AppState.shared
    @AppStorage(PrefKey.appearance) private var appearance = Appearance.system.rawValue

    init() {
        UserDefaults.registerAppDefaults()
    }

    var body: some Scene {
        Window("OpenSubtitles Uploader", id: "main") {
            ContentView()
                .environment(state)
                .frame(minWidth: 900, minHeight: 560)
                .onAppear {
                    AppearanceManager.apply(Appearance(rawValue: appearance) ?? .system)
                    state.start()
                }
                .onChange(of: appearance) { _, new in
                    AppearanceManager.apply(Appearance(rawValue: new) ?? .system)
                }
        }
        .defaultSize(width: 1024, height: 640)
        .commands { AppCommands(state: state) }

        Settings {
            SettingsView()
                .environment(state)
        }
    }
}

enum AppearanceManager {
    static func apply(_ appearance: Appearance) {
        switch appearance {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
        AppLog.info("Launched OpenSubtitles Uploader \(AppInfo.version)")
    }

    /// "Open With…" in Finder, files dropped on the Dock icon, or `open -a`.
    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in AppState.shared.handleDropped(urls) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct AppCommands: Commands {
    let state: AppState

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(L("Open…")) { state.browse(nil) }
                .keyboardShortcut("o", modifiers: .command)
        }
        CommandGroup(after: .newItem) {
            Divider()
            Button(L("Upload")) { state.verifyAndUpload() }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(state.isUploading)
            Button(L("Clear Files")) { state.reset(.all) }
                .keyboardShortcut(.delete, modifiers: [.command, .shift])
        }
        CommandGroup(after: .textEditing) {
            Divider()
            Button(L("Search IMDb…")) { state.openSearch() }
                .keyboardShortcut("f", modifiers: .command)
            Button(L("Auto-detect the language")) { state.detectSubtitleLanguage() }
                .keyboardShortcut("l", modifiers: [.command, .shift])
        }
        CommandMenu(L("Account")) {
            if state.isLoggedIn {
                Text(L("Logged in as %@", state.username))
                Button(L("Open Profile")) { state.openProfile() }
                    .disabled(state.userId == nil)
                Divider()
                Button(L("Sign Out")) { state.logout() }
            } else {
                Button(L("Sign In…")) { state.showLoginSheet = true }
            }
        }
        CommandGroup(replacing: .help) {
            Button("OpenSubtitles Uploader Help") { state.openExternal(AppInfo.homepage) }
            Button(L("Report an issue")) { state.openExternal(AppInfo.issues) }
            Button(L("help translating")) { state.openExternal(AppInfo.transifex) }
            Divider()
            Button(L("Check for Updates Now")) { state.checkForUpdates(force: true) }
        }
    }
}
