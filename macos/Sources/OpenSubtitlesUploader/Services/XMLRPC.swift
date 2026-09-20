import Foundation

/// A tiny XML-RPC implementation, enough for the OpenSubtitles.org API.
indirect enum XMLRPCValue {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case base64(Data)
    case array([XMLRPCValue])
    case dict([String: XMLRPCValue])
    case null

    // MARK: Accessors

    var stringValue: String? {
        switch self {
        case .string(let s): return s
        case .int(let i): return String(i)
        case .double(let d): return String(d)
        case .bool(let b): return b ? "1" : "0"
        default: return nil
        }
    }

    var intValue: Int? {
        switch self {
        case .int(let i): return i
        case .double(let d): return Int(d)
        case .string(let s): return Int(s.trimmingCharacters(in: .whitespaces))
        case .bool(let b): return b ? 1 : 0
        default: return nil
        }
    }

    var dictValue: [String: XMLRPCValue]? {
        if case .dict(let d) = self { return d }
        return nil
    }

    var arrayValue: [XMLRPCValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    /// True for empty strings / empty arrays / empty dicts (OpenSubtitles uses "" for "nothing").
    var isEmpty: Bool {
        switch self {
        case .string(let s): return s.isEmpty
        case .array(let a): return a.isEmpty
        case .dict(let d): return d.isEmpty
        case .null: return true
        default: return false
        }
    }

    subscript(key: String) -> XMLRPCValue? { dictValue?[key] }

    // MARK: Encoding

    func encoded() -> String {
        switch self {
        case .string(let s): return "<value><string>\(XMLRPC.escape(s))</string></value>"
        case .int(let i): return "<value><int>\(i)</int></value>"
        case .double(let d): return "<value><double>\(d)</double></value>"
        case .bool(let b): return "<value><boolean>\(b ? 1 : 0)</boolean></value>"
        case .base64(let d): return "<value><base64>\(d.base64EncodedString())</base64></value>"
        case .null: return "<value><nil/></value>"
        case .array(let a):
            return "<value><array><data>" + a.map { $0.encoded() }.joined() + "</data></array></value>"
        case .dict(let d):
            let members = d.keys.sorted().map { key in
                "<member><name>\(XMLRPC.escape(key))</name>\(d[key]!.encoded())</member>"
            }.joined()
            return "<value><struct>\(members)</struct></value>"
        }
    }
}

extension XMLRPCValue: ExpressibleByStringLiteral {
    init(stringLiteral value: String) { self = .string(value) }
}

struct XMLRPCFault: LocalizedError {
    let code: Int
    let message: String
    var errorDescription: String? { "XML-RPC fault \(code): \(message)" }
}

enum XMLRPCError: LocalizedError {
    case notXML
    case malformed(String)
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .notXML: return "API seems offline"
        case .malformed(let s): return "Malformed XML-RPC response: \(s)"
        case .http(let code): return "HTTP \(code)"
        }
    }
}

enum XMLRPC {
    static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.utf8.count)
        for ch in s {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            default: out.append(ch)
            }
        }
        return out
    }

    static func request(method: String, params: [XMLRPCValue]) -> Data {
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><methodCall><methodName>\(escape(method))</methodName><params>"
        for p in params { xml += "<param>\(p.encoded())</param>" }
        xml += "</params></methodCall>"
        return Data(xml.utf8)
    }

    /// Parses a methodResponse. Throws XMLRPCFault for <fault>.
    static func parseResponse(_ data: Data) throws -> XMLRPCValue {
        // OpenSubtitles returns HTML pages when it is down; detect that early.
        let head = String(decoding: data.prefix(256), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard head.hasPrefix("<?xml") || head.hasPrefix("<methodResponse") else { throw XMLRPCError.notXML }

        let tree = try XMLTreeParser.parse(data)
        guard tree.name == "methodResponse" else { throw XMLRPCError.malformed("root is \(tree.name)") }

        if let fault = tree.child("fault"), let value = fault.child("value") {
            let v = try convert(value)
            let code = v["faultCode"]?.intValue ?? 0
            let msg = v["faultString"]?.stringValue ?? "unknown fault"
            throw XMLRPCFault(code: code, message: msg)
        }
        guard let value = tree.child("params")?.child("param")?.child("value") else {
            throw XMLRPCError.malformed("missing params")
        }
        return try convert(value)
    }

    private static func convert(_ valueNode: XMLNode) throws -> XMLRPCValue {
        // <value>text</value> without a type element means string
        guard let typed = valueNode.children.first else { return .string(valueNode.text) }
        switch typed.name {
        case "string": return .string(typed.text)
        case "int", "i4", "i8": return .int(Int(typed.text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0)
        case "double": return .double(Double(typed.text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0)
        case "boolean": return .bool(typed.text.trimmingCharacters(in: .whitespacesAndNewlines) == "1")
        case "base64": return .base64(Data(base64Encoded: typed.text, options: .ignoreUnknownCharacters) ?? Data())
        case "nil": return .null
        case "dateTime.iso8601": return .string(typed.text)
        case "array":
            let values = typed.child("data")?.children.filter { $0.name == "value" } ?? []
            return .array(try values.map(convert))
        case "struct":
            var dict: [String: XMLRPCValue] = [:]
            for member in typed.children where member.name == "member" {
                guard let name = member.child("name")?.text, let v = member.child("value") else { continue }
                dict[name] = try convert(v)
            }
            return .dict(dict)
        default:
            throw XMLRPCError.malformed("Unknown XML-RPC tag '\(typed.name)'")
        }
    }
}

// MARK: - Generic XML tree

final class XMLNode {
    let name: String
    var text: String = ""
    var children: [XMLNode] = []
    weak var parent: XMLNode?

    init(name: String, parent: XMLNode?) {
        self.name = name
        self.parent = parent
    }

    func child(_ name: String) -> XMLNode? { children.first { $0.name == name } }
}

final class XMLTreeParser: NSObject, XMLParserDelegate {
    private var root: XMLNode?
    private var current: XMLNode?
    private var error: Error?

    static func parse(_ data: Data) throws -> XMLNode {
        let delegate = XMLTreeParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        if !parser.parse() {
            throw XMLRPCError.malformed(parser.parserError?.localizedDescription ?? "parse error")
        }
        guard let root = delegate.root else { throw XMLRPCError.malformed("empty document") }
        return root
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let node = XMLNode(name: elementName, parent: current)
        if let current { current.children.append(node) } else { root = node }
        current = node
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        current?.text += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        current?.text += String(decoding: CDATABlock, as: UTF8.self)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        current = current?.parent
    }
}

// MARK: - Client

final class XMLRPCClient {
    let url: URL
    let userAgent: String
    private let session: URLSession

    init(url: URL, userAgent: String) {
        self.url = url
        self.userAgent = userAgent
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 300
        config.httpAdditionalHeaders = ["User-Agent": userAgent]
        session = URLSession(configuration: config)
    }

    func call(_ method: String, _ params: [XMLRPCValue]) async throws -> XMLRPCValue {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("text/xml", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = XMLRPC.request(method: method, params: params)

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw XMLRPCError.http(http.statusCode)
        }
        return try XMLRPC.parseResponse(data)
    }
}
