import Foundation
import NaturalLanguage

struct OSLanguage: Identifiable, Hashable {
    let name: String
    let code: String        // OpenSubtitles 3-letter code, e.g. "eng"
    let native: String?
    let iso6391: String?
    var id: String { code }

    var displayName: String {
        if let native, !native.isEmpty { return "\(name) (\(native))" }
        return name
    }
}

/// The subtitle language list (os-lang.json from the original app).
enum OSLanguages {
    static let all: [OSLanguage] = {
        guard let url = Bundle.module.url(forResource: "os-lang", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: [String: String]] else {
            return []
        }
        return dict.keys.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }.compactMap { name in
            guard let entry = dict[name], let code = entry["code"] else { return nil }
            return OSLanguage(name: name, code: code, native: entry["native"], iso6391: entry["iso6391"])
        }
    }()

    static func language(code: String) -> OSLanguage? { all.first { $0.code == code } }

    /// Maps a BCP-47 tag from NaturalLanguage to an OpenSubtitles code.
    static func code(forBCP47 tag: String) -> String? {
        let lower = tag.lowercased()
        let special: [String: String] = [
            "zh-hans": "chi", "zh-hant": "zht", "zh": "chi",
            "nb": "nor", "nn": "nor", "no": "nor",
            "pt-br": "pob", "pt": "por",
            "he": "heb", "iw": "heb",
        ]
        if let s = special[lower] { return s }
        if let match = all.first(where: { $0.iso6391 == lower }) { return match.code }
        let base = String(lower.split(separator: "-").first ?? Substring(lower))
        return all.first(where: { $0.iso6391 == base })?.code
    }
}

/// Native replacement for the `detect-lang` npm module, powered by NaturalLanguage.
enum LanguageDetector {
    struct Detection {
        let code: String
        let probability: Double
    }

    static func detect(subtitle url: URL) -> Detection? {
        guard let text = readText(url) else { return nil }
        let cleaned = cleanSubtitleText(text)
        guard cleaned.count > 20 else { return nil }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(cleaned.prefix(40_000)))
        let hypotheses = recognizer.languageHypotheses(withMaximum: 3)
        guard let best = hypotheses.max(by: { $0.value < $1.value }) else { return nil }
        // like the original app, accept anything above 25 % probability
        guard best.value > 0.25, let code = OSLanguages.code(forBCP47: best.key.rawValue) else { return nil }
        return Detection(code: code, probability: best.value)
    }

    /// Language tag at the end of a file name: "movie.eng.srt", "movie.en.srt", "movie.pt-BR.srt",
    /// "movie.zh-Hant.srt", "movie.es-419.srt" (upstream issue #56). "forced"/"sdh" suffixes are skipped.
    static func detectFromFilename(_ url: URL) -> String? {
        let name = url.deletingPathExtension().lastPathComponent
        var parts = name.split(whereSeparator: { $0 == "." || $0 == "_" }).map { String($0).lowercased() }
        while let last = parts.last, ["forced", "sdh", "hi", "cc", "default"].contains(last) { parts.removeLast() }
        guard parts.count > 1, let tag = parts.last, (2...7).contains(tag.count) else { return nil }
        return code(forTag: tag)
    }

    private static let ietfAliases: [String: String] = [
        "pt-br": "pob", "pt-pt": "por", "pt-mz": "pom",
        "zh-cn": "chi", "zh-hans": "chi", "zh-sg": "chi", "zh-tw": "zht", "zh-hant": "zht", "zh-hk": "zht", "zh-yue": "zhc", "yue": "zhc",
        "es-419": "spl", "es-mx": "spl", "es-ar": "spl", "es-es": "spn", "es-la": "spl",
        "nb": "nor", "nn": "nor", "nb-no": "nor",
        "sr-latn": "scc", "sr-cyrl": "scc",
    ]

    static func code(forTag rawTag: String) -> String? {
        let tag = rawTag.lowercased().replacingOccurrences(of: "_", with: "-")
        if let alias = ietfAliases[tag] { return alias }
        if tag.count == 3, let lang = OSLanguages.all.first(where: { $0.code == tag }) { return lang.code }
        if let byIso = OSLanguages.code(forBCP47: tag) { return byIso }
        // "eng" style 3-letter ISO 639-2/B codes that differ from the OpenSubtitles code are rare; try the base part of "xx-YY"
        let base = String(tag.split(separator: "-").first ?? Substring(tag))
        if base != tag { return code(forTag: base) }
        return nil
    }

    /// Combines content detection and the file-name tag: an explicit tag is trusted when the
    /// recognizer found nothing, or when it only refines the detected language (pt → pt-BR, zh
    /// variants, Spanish LA). Otherwise the content wins (upstream issue #97).
    static func bestLanguage(for url: URL) -> String? {
        let fromContent = detect(subtitle: url)?.code
        let fromName = detectFromFilename(url)
        guard let fromName else { return fromContent }
        guard let fromContent else { return fromName }
        if fromName == fromContent { return fromContent }
        let families: [Set<String>] = [["por", "pob", "pom"], ["chi", "zht", "zhe", "zhc"], ["spa", "spn", "spl"], ["nor"], ["scc", "srp"]]
        if families.contains(where: { $0.contains(fromName) && $0.contains(fromContent) }) { return fromName }
        return fromContent
    }

    static func readText(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        if let s = String(data: data, encoding: .utf8) { return s }
        var nsString: NSString?
        var usedLossy: ObjCBool = false
        let encoding = NSString.stringEncoding(for: data, encodingOptions: [.suggestedEncodingsKey: [NSUTF8StringEncoding, NSWindowsCP1252StringEncoding, NSISOLatin1StringEncoding]], convertedString: &nsString, usedLossyConversion: &usedLossy)
        if encoding != 0, let nsString { return nsString as String }
        return String(data: data, encoding: .windowsCP1252) ?? String(data: data, encoding: .isoLatin1)
    }

    /// Removes cue numbers, timestamps and markup so the recognizer sees only dialogue.
    static func cleanSubtitleText(_ text: String) -> String {
        let patterns = [
            #"\d{1,2}:\d{2}:\d{2}[,.]\d{1,3}\s*-->\s*\d{1,2}:\d{2}:\d{2}[,.]\d{1,3}.*"#, // srt/vtt times
            #"^\s*\d+\s*$"#,                     // cue numbers
            #"\{[^}]*\}"#,                       // ass/ssa tags, sub timing
            #"<[^>]+>"#,                         // html tags
            #"^(Dialogue|Style|Format|\[.*\]|ScriptType|PlayRes[XY]|Title|Original).*?,,"#, // ass headers (partial)
        ]
        var out = text
        for p in patterns {
            guard let regex = try? NSRegularExpression(pattern: p, options: [.anchorsMatchLines, .caseInsensitive]) else { continue }
            out = regex.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: " ")
        }
        return out.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }
}
