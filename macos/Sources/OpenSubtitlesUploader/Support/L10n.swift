import Foundation

/// Localization helper. Keys are the original English strings, exactly like the
/// i18n keys used by the HTML5 version, so the existing translations can be reused.
///
/// The strings are looked up in the main bundle first (the .app produced by
/// Scripts/build-app.sh copies the .lproj folders there, which also lets macOS
/// users pick a per-app language in System Settings), then in the SwiftPM
/// resource bundle (used when running with `swift run` during development).
enum L10n {
    private static let missing = "\u{1}__missing__"

    static func tr(_ key: String) -> String {
        let main = Bundle.main.localizedString(forKey: key, value: missing, table: nil)
        if main != missing { return main }
        return Bundle.module.localizedString(forKey: key, value: key, table: nil)
    }

    static func tr(_ key: String, _ args: CVarArg...) -> String {
        String(format: tr(key), locale: Locale.current, arguments: args)
    }
}

@inline(__always) func L(_ key: String) -> String { L10n.tr(key) }
@inline(__always) func L(_ key: String, _ args: CVarArg...) -> String {
    String(format: L10n.tr(key), locale: Locale.current, arguments: args)
}
