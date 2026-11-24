import Foundation

struct FetchPattern {
    static let types: Set<String> = ["Document", "Stylesheet", "Image", "Media", "Font", "Script", "XHR", "Fetch",
                                     "Manifest", "TextTrack", "Other"]
    let glob: String, expression: String
    let resource: String?
    let response: Bool
    let origin: URL?
    private let regex: NSRegularExpression

    init(_ spec: JSON) throws {
        guard spec["urlPattern"] == nil || spec["urlPattern"] is String,
              spec["resourceType"] == nil || spec["resourceType"] is String,
              spec["requestStage"] == nil || spec["requestStage"] is String else { throw CDPError.invalidParams("Invalid Fetch pattern") }
        glob = spec["urlPattern"] as? String ?? "*"; resource = spec["resourceType"] as? String
        if let type = resource, !Self.types.contains(type) { throw CDPError.invalidParams("Unsupported renderer resourceType: \(type)") }
        let stage = spec["requestStage"] as? String ?? "Request"
        guard ["Response", "Request"].contains(stage), glob.utf8.count <= 2048 else { throw CDPError.invalidParams("Invalid Fetch requestStage or URL pattern") }
        response = stage == "Response"
        var pattern = "^", escape = false
        for ch in glob {
            if escape { pattern += NSRegularExpression.escapedPattern(for: String(ch)); escape = false }
            else if ch == "\\" { escape = true }
            else if ch == "*" { if !pattern.hasSuffix(".*") { pattern += ".*" } }
            else if ch == "?" { pattern += "." }
            else { pattern += NSRegularExpression.escapedPattern(for: String(ch)) }
        }
        if escape { pattern += "\\\\" }
        expression = pattern + "$"
        regex = try NSRegularExpression(pattern: expression)
        if let sep = glob.range(of: "://") {
            let rest = glob[sep.upperBound...], authority = rest.prefix { $0 != "/" }
            let scheme = String(glob[..<sep.lowerBound])
            guard ["http", "https", "file"].contains(scheme),
                  !authority.contains("*"), !authority.contains("?"), !authority.contains("@") else {
                throw CDPError.invalidParams("Fetch needs a literal renderer origin; HTTP(S) host wildcards are not supported")
            }
            origin = URL(string: "\(scheme)://\(authority)/")
        } else { origin = nil }
    }

    func matches(_ url: URL, _ type: String) -> Bool {
        let s = url.absoluteString.components(separatedBy: "#")[0]
        return (resource == nil || resource == type) && regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }
}

enum FetchRouting {
    static func type(_ u: URL, request: URLRequest) -> String {
        switch request.value(forHTTPHeaderField: "Sec-Fetch-Dest") {
        case "image": return "Image"; case "script": return "Script"; case "style": return "Stylesheet"
        case "font": return "Font"; case "video", "audio": return "Media"; case "document", "iframe": return "Document"
        default: break
        }
        if u.path.contains("/__hyperframes_video_frames__/") { return "Image" }
        let mime = FetchPayload.mime(u), accept = request.value(forHTTPHeaderField: "Accept") ?? ""
        if mime.hasPrefix("image/") || accept.hasPrefix("image/") { return "Image" }
        if mime.contains("javascript") { return "Script" }
        if mime == "text/css" || accept.hasPrefix("text/css") { return "Stylesheet" }
        if mime.hasPrefix("video/") || mime.hasPrefix("audio/") { return "Media" }
        if mime.hasPrefix("font/") { return "Font" }
        if mime.hasPrefix("text/html") { return "Document" }
        return "Other"
    }

    // Relative CSS URLs, module imports, ordinary parser requests etc. are resolved by WebKit
    // itself inside the local document's virtual origin. Only URL-valued HTML attributes need
    // translation for absolute addresses and destination hints. Leave script/style text alone.
    private static let tags = try! NSRegularExpression(pattern: #"(?is)<!--.*?(?:-->|$)|<(/?)([a-z][a-z0-9:-]*)(?:\s+(?:[^"'>]|"[^"]*"|'[^']*')*)?\s*/?>"#)
    private static let attrs = try! NSRegularExpression(pattern: #"(?is)\s+([^\s"'<>/=]+)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+)))?"#)
    private static let rawText: Set<String> = ["script", "style", "textarea", "title", "xmp", "iframe", "noembed", "noframes"]

    /// These policies constrain framing/sandboxing, not the scheme of an asset. They can be
    /// kept verbatim, including the framing header on every HyperFrames local response.
    static func safeCSP(_ policy: String) -> Bool {
        policy.split(whereSeparator: { $0 == ";" || $0 == "," }).allSatisfy { directive in
            let tokens = directive.lowercased().split(whereSeparator: \.isWhitespace)
            return tokens.isEmpty || tokens.first == "sandbox" ||
                (tokens.count == 2 && (tokens[0] == "frame-src" || tokens[0] == "object-src") && tokens[1] == "'none'") ||
                (tokens.first == "frame-ancestors" && tokens.dropFirst().allSatisfy { $0 == "'none'" || $0 == "'self'" })
        }
    }

    // Additional policy, intersected by WebKit with (never substituted for) the author's
    // CSP. A cold intercepted document has no reason to create another browsing context.
    static func singleFrameHeaders(_ original: [String: String]) -> [String: String] {
        var result = original
        let key = original.keys.first { $0.lowercased() == "content-security-policy" } ?? "Content-Security-Policy"
        let fence = "frame-src 'none'; object-src 'none'"
        if let previous = original[key], !previous.isEmpty { result[key] = previous + ", " + fence }
        else { result[key] = fence }
        return result
    }

    static func unsafeMetaPolicy(_ bytes: Data) -> Bool {
        guard let html = String(data: bytes, encoding: .utf8), !html.utf8.contains(0) else { return true }
        guard html.range(of: "http-equiv", options: .caseInsensitive) != nil else { return false }
        let input = html as NSString
        return tags.matches(in: html, range: NSRange(location: 0, length: input.length)).contains { tag in
            guard tag.range(at: 2).location != NSNotFound, input.substring(with: tag.range(at: 2)).lowercased() == "meta" else { return false }
            let text = input.substring(with: tag.range), ns = text as NSString
            for a in attrs.matches(in: text, range: NSRange(location: 0, length: ns.length))
                where ns.substring(with: a.range(at: 1)).lowercased() == "http-equiv" {
                guard let r = (2...4).map({ a.range(at: $0) }).first(where: { $0.location != NSNotFound }) else { return true }
                // Avoid interpreting character references differently from WebKit.
                return !["content-type","x-ua-compatible","content-language","x-dns-prefetch-control"].contains(ns.substring(with: r).lowercased())
            }
            return false
        }
    }

    static func html(_ data: Data, at document: URL, scope: FetchScope, patterns: [FetchPattern], virtualDocument: Bool = true) -> Data {
        guard let text = String(data: data, encoding: .utf8) else { return data }
        let input = text as NSString, out = NSMutableString(capacity: input.length)
        var base = document, sawBase = false, skip: String?, end = 0
        tags.enumerateMatches(in: text, range: NSRange(location: 0, length: input.length)) { m, _, _ in
            guard let m, m.range(at: 2).location != NSNotFound else { return }
            let tag = input.substring(with: m.range(at: 2)).lowercased()
            let closing = m.range(at: 1).length > 0
            if let raw = skip { if tag == raw && closing { skip = nil }; return }
            if closing { return }
            if rawText.contains(tag) { skip = tag }
            let token = input.substring(with: m.range), source = token as NSString
            let attributes = attrs.matches(in: token, range: NSRange(location: 0, length: source.length))
            var fields: [String: (String, NSRange)] = [:]
            for a in attributes {
                let name = source.substring(with: a.range(at: 1)).lowercased()
                guard fields[name] == nil, let range = (2...4).map({ a.range(at: $0) }).first(where: { $0.location != NSNotFound }) else { continue }
                fields[name] = (source.substring(with: range).replacingOccurrences(of: "&amp;", with: "&"), range)
            }
            let field: String, type: String?
            switch tag {
            case "script": field = "src"; type = "Script"
            case "img", "input": field = "src"; type = "Image"
            case "video", "audio", "source": field = "src"; type = "Media"
            case "track": field = "src"; type = "TextTrack"
            case "iframe", "frame": field = "src"; type = "Document"
            case "link":
                field = "href"
                let rel = fields["rel"]?.0.lowercased() ?? "", dest = fields["as"]?.0.lowercased() ?? ""
                type = (["script":"Script","image":"Image","style":"Stylesheet","font":"Font","fetch":"Fetch"][dest]) ??
                    (rel.contains("stylesheet") ? "Stylesheet" : rel.contains("icon") ? "Image" : rel.contains("modulepreload") ? "Script" : rel == "manifest" ? "Manifest" : "Other")
            case "base" where !sawBase: field = "href"; type = nil
            default: return
            }
            guard let (value, r) = fields[field], !value.isEmpty, !value.hasPrefix("#"),
                  let real = URL(string: value, relativeTo: base)?.absoluteURL else { return }
            if tag == "base" { base = real; sawBase = true }
            let isLocal = real.isFileURL || (!document.isFileURL && FetchScope.origin(real) == FetchScope.origin(scope.document))
            guard (isLocal && virtualDocument) || ((isLocal || type != "Document") && patterns.contains { $0.matches(real, type ?? "Other") }),
                  let mapped = scope.map(real, type: type) else { return }
            let pos = m.range.location + r.location
            out.append(input.substring(with: NSRange(location: end, length: pos - end)))
            out.append(mapped.absoluteString.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "'", with: "&#39;").replacingOccurrences(of: "\"", with: "&quot;"))
            end = pos + r.length
        }
        guard end > 0 else { return data }
        out.append(input.substring(from: end)); return Data((out as String).utf8)
    }

    /// Only renderer-owned documents receive this hook. WebKit still performs the actual scheme
    /// request, decoding, SRI and CORS checks. Hot enable does not reload/destroy a running page.
    /// Remote pages get neither a file/network bridge nor a script message handler for Fetch.
    static func script(scope: FetchScope, patterns: [FetchPattern]) -> String {
        let routes = scope.external.map { ["origin": $0.value.absoluteString, "host": $0.key] }
        let spec: JSON = ["doc": scope.document.absoluteString, "host": scope.host, "routes": routes, "scheme": FetchScope.scheme,
                          "typeKey": scope.typeKey, "patterns": patterns.map { ["re": $0.expression, "type": $0.resource ?? ""] }]
        let data = try! JSONSerialization.data(withJSONObject: spec)
        return "(function(c){" + #"""
          const key=Symbol.for('safarium.fetch.routing'), state=globalThis[key];
          const doc=new URL(c.doc), loc=new URL(location.href);
          const same=(u,v)=>u.protocol===v.protocol && (u.protocol==='file:' ?
            ['', 'localhost'].includes(u.hostname) && !u.port : u.origin===v.origin);
          const virtual=loc.protocol===c.scheme+':' && loc.hostname===c.host;
          if (!virtual && loc.href.split('#')[0]!==doc.href.split('#')[0]) return;
          if (state) { state.update(c); return; }
          let config, rules, hosts, originals;
          function update(v) {
            config=v; rules=v.patterns.map(p=>[new RegExp(p.re),p.type]);
            hosts=new Map(v.routes.map(r=>[new URL(r.origin).origin,r.host]));
            originals=new Map(v.routes.map(r=>[r.host,r.origin]));
          }
          update(c);
          Object.defineProperty(globalThis,key,{value:{update}});
          function route(value,type) {
            try {
              const raw=String(value), base=new URL(document.baseURI);
              let currentBase=base;
              if (base.protocol===config.scheme+':') {
                const owner=base.hostname===config.host ? config.doc : originals.get(base.hostname);
                if (!owner || base.username || base.password || base.port) return value;
                currentBase=new URL(owner);
                currentBase.pathname=base.pathname; currentBase.search=base.search; currentBase.hash=base.hash;
              }
              const u=new URL(raw,currentBase);
              if (u.protocol===config.scheme+':' || u.username || u.password || !['http:','https:','file:'].includes(u.protocol)) return value;
              const local=same(u,doc);
              if ((!virtual || !local) && !rules.some(([r,t])=>(!t||t===type)&&r.test(u.href.split('#')[0]))) return value;
              const h=local?config.host:hosts.get(u.origin); if (!h) return value;
              const q=u.search ? u.search+'&' : '?';
              return config.scheme+'://'+h+u.pathname+q+config.typeKey+'='+type+u.hash;
            } catch (_) { return value; }
          }
          function dest(el,name) {
            const tag=el.localName;
            if(name==='src') return ({img:'Image',script:'Script',video:'Media',audio:'Media',source:'Media',track:'TextTrack',input:'Image'})[tag];
            if(name==='poster' && tag==='video') return 'Image';
            if(name==='href' && tag==='link') return el.rel==='manifest'?'Manifest':el.rel==='stylesheet'?'Stylesheet':({font:'Font',image:'Image',script:'Script',style:'Stylesheet'})[el.as]||'Other';
          }
          for (const [C,n] of [[HTMLImageElement,'src'],[HTMLScriptElement,'src'],[HTMLMediaElement,'src'],[HTMLSourceElement,'src'],[HTMLTrackElement,'src'],[HTMLVideoElement,'poster'],[HTMLLinkElement,'href']]) {
            const d=Object.getOwnPropertyDescriptor(C.prototype,n); if(!d?.set) continue;
            Object.defineProperty(C.prototype,n,{...d,set(v){return d.set.call(this,route(v,dest(this,n)))}});
          }
          const attr=Element.prototype.setAttribute;
          Element.prototype.setAttribute=function(n,v){const t=dest(this,String(n).toLowerCase());return attr.call(this,n,t?route(v,t):v)};
          const f=globalThis.fetch;
          globalThis.fetch=function(input,init){
            if(input instanceof Request) {
              const mapped=route(input.url,'Fetch');
              if(mapped!==input.url) input=new Request(mapped,input);
            } else input=route(input,'Fetch');
            return f.call(this,input,init);
          };
          const open=XMLHttpRequest.prototype.open;
          XMLHttpRequest.prototype.open=function(method,url,...rest){ return open.call(this,method,route(url,'XHR'),...rest) };
        """# + "})(\(String(decoding: data, as: UTF8.self)));"
    }
}
