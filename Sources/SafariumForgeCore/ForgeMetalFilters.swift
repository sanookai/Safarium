import CoreGraphics
import CoreVideo
import Foundation
import Metal
import MetalFX
import SafariumCore
import VideoToolbox

// MARK: - Deterministic Time Math Expression Compiler (overlay/kenBurns/enable)

public struct ForgeExprContext: Sendable {
    public var t: Double
    public var frame: Double
    public var fps: Double
    public var duration: Double
    public var canvasWidth: Double
    public var canvasHeight: Double
    public var overlayWidth: Double
    public var overlayHeight: Double

    public init(
        t: Double = 0,
        frame: Double = 0,
        fps: Double = 30,
        duration: Double = 1,
        canvasWidth: Double = 1080,
        canvasHeight: Double = 1920,
        overlayWidth: Double = 1080,
        overlayHeight: Double = 1920
    ) {
        self.t = t
        self.frame = frame
        self.fps = fps
        self.duration = duration
        self.canvasWidth = canvasWidth
        self.canvasHeight = canvasHeight
        self.overlayWidth = overlayWidth
        self.overlayHeight = overlayHeight
    }
}

public indirect enum ForgeExprNode: Sendable, Equatable {
    case constant(Double)
    case variable(String)
    case unaryNeg(ForgeExprNode)
    case unaryNot(ForgeExprNode)
    case binary(String, ForgeExprNode, ForgeExprNode)
    case ternary(ForgeExprNode, ForgeExprNode, ForgeExprNode)
    case call(String, [ForgeExprNode])

    public func evaluate(_ ctx: ForgeExprContext) -> Double {
        let val: Double
        switch self {
        case .constant(let v):
            val = v
        case .variable(let name):
            switch name {
            case "t", "time": val = ctx.t
            case "n", "frame": val = ctx.frame
            case "fps": val = ctx.fps
            case "dur", "duration", "T": val = ctx.duration
            case "W", "canvasW", "main_w": val = ctx.canvasWidth
            case "H", "canvasH", "main_h": val = ctx.canvasHeight
            case "w", "ovW", "overlay_w": val = ctx.overlayWidth
            case "h", "ovH", "overlay_h": val = ctx.overlayHeight
            case "pi", "PI": val = Double.pi
            case "e", "E": val = M_E
            default: val = 0.0
            }
        case .unaryNeg(let inner):
            val = -inner.evaluate(ctx)
        case .unaryNot(let inner):
            val = inner.evaluate(ctx) == 0 ? 1.0 : 0.0
        case .binary(let op, let lhs, let rhs):
            let a = lhs.evaluate(ctx)
            if op == "&&" { return (a != 0 && rhs.evaluate(ctx) != 0) ? 1.0 : 0.0 }
            if op == "||" { return (a != 0 || rhs.evaluate(ctx) != 0) ? 1.0 : 0.0 }
            let b = rhs.evaluate(ctx)
            switch op {
            case "+": val = a + b
            case "-": val = a - b
            case "*": val = a * b
            case "/": val = abs(b) > 1e-12 ? (a / b) : 0.0
            case "%": val = abs(b) > 1e-12 ? a.truncatingRemainder(dividingBy: b) : 0.0
            case "^": val = pow(a, b)
            case "<": val = a < b ? 1.0 : 0.0
            case "<=": val = a <= b ? 1.0 : 0.0
            case ">": val = a > b ? 1.0 : 0.0
            case ">=": val = a >= b ? 1.0 : 0.0
            case "==": val = abs(a - b) < 1e-9 ? 1.0 : 0.0
            case "!=": val = abs(a - b) >= 1e-9 ? 1.0 : 0.0
            default: val = 0.0
            }
        case .ternary(let cond, let a, let b):
            val = cond.evaluate(ctx) != 0 ? a.evaluate(ctx) : b.evaluate(ctx)
        case .call(let fn, let args):
            let v = args.map { $0.evaluate(ctx) }
            switch fn {
            case "between":
                guard v.count >= 3 else { return 0.0 }
                val = (v[0] >= v[1] && v[0] <= v[2]) ? 1.0 : 0.0
            case "if":
                guard v.count >= 2 else { return 0.0 }
                val = v[0] != 0 ? v[1] : (v.count >= 3 ? v[2] : 0.0)
            case "ifnot":
                guard v.count >= 2 else { return 0.0 }
                val = v[0] == 0 ? v[1] : (v.count >= 3 ? v[2] : 0.0)
            case "lt":
                guard v.count >= 2 else { return 0.0 }
                val = v[0] < v[1] ? 1.0 : 0.0
            case "lte":
                guard v.count >= 2 else { return 0.0 }
                val = v[0] <= v[1] ? 1.0 : 0.0
            case "gt":
                guard v.count >= 2 else { return 0.0 }
                val = v[0] > v[1] ? 1.0 : 0.0
            case "gte":
                guard v.count >= 2 else { return 0.0 }
                val = v[0] >= v[1] ? 1.0 : 0.0
            case "eq":
                guard v.count >= 2 else { return 0.0 }
                val = abs(v[0] - v[1]) < 1e-9 ? 1.0 : 0.0
            case "min":
                val = v.min() ?? 0.0
            case "max":
                val = v.max() ?? 0.0
            case "clamp":
                guard v.count >= 3 else { return v.first ?? 0.0 }
                val = Swift.min(v[2], Swift.max(v[1], v[0]))
            case "sin": val = v.first.map(Darwin.sin) ?? 0.0
            case "cos": val = v.first.map(Darwin.cos) ?? 0.0
            case "tan": val = v.first.map(Darwin.tan) ?? 0.0
            case "abs": val = v.first.map(Swift.abs) ?? 0.0
            case "sqrt": val = v.first.map { Darwin.sqrt(Swift.max(0.0, $0)) } ?? 0.0
            case "pow": val = v.count >= 2 ? Darwin.pow(v[0], v[1]) : 0.0
            case "exp": val = v.first.map(Darwin.exp) ?? 0.0
            case "log": val = v.first.map { Darwin.log(Swift.max(1e-12, $0)) } ?? 0.0
            case "floor": val = v.first.map(Foundation.floor) ?? 0.0
            case "ceil": val = v.first.map(Foundation.ceil) ?? 0.0
            case "round": val = v.first.map { $0.rounded() } ?? 0.0
            case "mod": val = (v.count >= 2 && abs(v[1]) > 1e-12) ? v[0].truncatingRemainder(dividingBy: v[1]) : 0.0
            case "lerp", "mix":
                guard v.count >= 3 else { return 0.0 }
                val = v[0] + (v[1] - v[0]) * v[2]
            case "smoothstep":
                guard v.count >= 3 else { return 0.0 }
                let span = v[1] - v[0]
                let u = abs(span) > 1e-12 ? Swift.min(1.0, Swift.max(0.0, (v[2] - v[0]) / span)) : 0.0
                val = u * u * (3.0 - 2.0 * u)
            case "easeInOut":
                let u = Swift.min(1.0, Swift.max(0.0, v.first ?? 0.0))
                val = u < 0.5 ? 2.0 * u * u : 1.0 - pow(-2.0 * u + 2.0, 2.0) / 2.0
            default:
                val = 0.0
            }
        }
        return val.isFinite ? val : 0.0
    }
}

public enum ForgeTimeExprParser {
    private enum Token: Equatable {
        case number(Double)
        case ident(String)
        case op(String)
        case lparen
        case rparen
        case comma
        case question
        case colon
    }

    public static func compile(_ source: String) throws -> ForgeExprNode {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            throw SafariumError.invalidState("empty math expression")
        }
        if let literal = Double(trimmed), literal.isFinite {
            return .constant(literal)
        }
        let tokens = try tokenize(trimmed)
        var cursor = 0
        let node = try parseTernary(tokens, &cursor)
        guard cursor == tokens.count else {
            throw SafariumError.invalidState("unexpected trailing token in expression '\(source)'")
        }
        return node
    }

    private static func tokenize(_ s: String) throws -> [Token] {
        var out: [Token] = []
        let chars = Array(s)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c.isWhitespace { i += 1; continue }
            if c.isNumber || (c == "." && i + 1 < chars.count && chars[i + 1].isNumber) {
                var j = i
                var hasDot = false
                while j < chars.count {
                    let ch = chars[j]
                    if ch.isNumber { j += 1 }
                    else if ch == "." && !hasDot { hasDot = true; j += 1 }
                    else if (ch == "e" || ch == "E"), j + 1 < chars.count {
                        j += 1
                        if j < chars.count && (chars[j] == "+" || chars[j] == "-") { j += 1 }
                    } else { break }
                }
                let word = String(chars[i..<j])
                guard let d = Double(word), d.isFinite else {
                    throw SafariumError.invalidState("invalid numeric literal '\(word)' in '\(s)'")
                }
                out.append(.number(d))
                i = j
                continue
            }
            if c.isLetter || c == "_" {
                var j = i + 1
                while j < chars.count && (chars[j].isLetter || chars[j].isNumber || chars[j] == "_") { j += 1 }
                out.append(.ident(String(chars[i..<j])))
                i = j
                continue
            }
            if i + 1 < chars.count {
                let two = String([c, chars[i + 1]])
                if ["<=", ">=", "==", "!=", "&&", "||"].contains(two) {
                    out.append(.op(two))
                    i += 2
                    continue
                }
            }
            switch c {
            case "+", "-", "*", "/", "%", "^", "<", ">", "!":
                out.append(.op(String(c)))
            case "(": out.append(.lparen)
            case ")": out.append(.rparen)
            case ",": out.append(.comma)
            case "?": out.append(.question)
            case ":": out.append(.colon)
            default:
                throw SafariumError.invalidState("unexpected character '\(c)' in expression '\(s)'")
            }
            i += 1
        }
        return out
    }

    private static func parseTernary(_ tokens: [Token], _ idx: inout Int) throws -> ForgeExprNode {
        let cond = try parseOr(tokens, &idx)
        if idx < tokens.count && tokens[idx] == .question {
            idx += 1
            let a = try parseTernary(tokens, &idx)
            guard idx < tokens.count && tokens[idx] == .colon else {
                throw SafariumError.invalidState("expected ':' in ternary expression")
            }
            idx += 1
            let b = try parseTernary(tokens, &idx)
            return .ternary(cond, a, b)
        }
        return cond
    }

    private static func parseOr(_ tokens: [Token], _ idx: inout Int) throws -> ForgeExprNode {
        var node = try parseAnd(tokens, &idx)
        while idx < tokens.count, tokens[idx] == .op("||") {
            idx += 1
            node = .binary("||", node, try parseAnd(tokens, &idx))
        }
        return node
    }

    private static func parseAnd(_ tokens: [Token], _ idx: inout Int) throws -> ForgeExprNode {
        var node = try parseEquality(tokens, &idx)
        while idx < tokens.count, tokens[idx] == .op("&&") {
            idx += 1
            node = .binary("&&", node, try parseEquality(tokens, &idx))
        }
        return node
    }

    private static func parseEquality(_ tokens: [Token], _ idx: inout Int) throws -> ForgeExprNode {
        var node = try parseCompare(tokens, &idx)
        while idx < tokens.count, case .op(let op) = tokens[idx], op == "==" || op == "!=" {
            idx += 1
            node = .binary(op, node, try parseCompare(tokens, &idx))
        }
        return node
    }

    private static func parseCompare(_ tokens: [Token], _ idx: inout Int) throws -> ForgeExprNode {
        var node = try parseAddSub(tokens, &idx)
        while idx < tokens.count, case .op(let op) = tokens[idx], ["<", "<=", ">", ">="].contains(op) {
            idx += 1
            node = .binary(op, node, try parseAddSub(tokens, &idx))
        }
        return node
    }

    private static func parseAddSub(_ tokens: [Token], _ idx: inout Int) throws -> ForgeExprNode {
        var node = try parseMulDiv(tokens, &idx)
        while idx < tokens.count, case .op(let op) = tokens[idx], op == "+" || op == "-" {
            idx += 1
            node = .binary(op, node, try parseMulDiv(tokens, &idx))
        }
        return node
    }

    private static func parseMulDiv(_ tokens: [Token], _ idx: inout Int) throws -> ForgeExprNode {
        var node = try parsePower(tokens, &idx)
        while idx < tokens.count, case .op(let op) = tokens[idx], op == "*" || op == "/" || op == "%" {
            idx += 1
            node = .binary(op, node, try parsePower(tokens, &idx))
        }
        return node
    }

    private static func parsePower(_ tokens: [Token], _ idx: inout Int) throws -> ForgeExprNode {
        let base = try parseUnary(tokens, &idx)
        if idx < tokens.count, tokens[idx] == .op("^") {
            idx += 1
            return .binary("^", base, try parsePower(tokens, &idx))
        }
        return base
    }

    private static func parseUnary(_ tokens: [Token], _ idx: inout Int) throws -> ForgeExprNode {
        if idx < tokens.count {
            if tokens[idx] == .op("-") {
                idx += 1
                return .unaryNeg(try parseUnary(tokens, &idx))
            }
            if tokens[idx] == .op("+") {
                idx += 1
                return try parseUnary(tokens, &idx)
            }
            if tokens[idx] == .op("!") {
                idx += 1
                return .unaryNot(try parseUnary(tokens, &idx))
            }
        }
        return try parsePrimary(tokens, &idx)
    }

    private static func parsePrimary(_ tokens: [Token], _ idx: inout Int) throws -> ForgeExprNode {
        guard idx < tokens.count else {
            throw SafariumError.invalidState("unexpected end of math expression")
        }
        switch tokens[idx] {
        case .number(let v):
            idx += 1
            return .constant(v)
        case .ident(let name):
            idx += 1
            if idx < tokens.count && tokens[idx] == .lparen {
                idx += 1
                var args: [ForgeExprNode] = []
                if idx < tokens.count && tokens[idx] != .rparen {
                    while true {
                        args.append(try parseTernary(tokens, &idx))
                        if idx < tokens.count && tokens[idx] == .comma {
                            idx += 1
                            continue
                        }
                        break
                    }
                }
                guard idx < tokens.count && tokens[idx] == .rparen else {
                    throw SafariumError.invalidState("missing ')' after arguments to '\(name)'")
                }
                idx += 1
                return .call(name, args)
            }
            return .variable(name)
        case .lparen:
            idx += 1
            let inner = try parseTernary(tokens, &idx)
            guard idx < tokens.count && tokens[idx] == .rparen else {
                throw SafariumError.invalidState("missing ')' in math expression")
            }
            idx += 1
            return inner
        default:
            throw SafariumError.invalidState("unexpected token in math expression")
        }
    }
}

// MARK: - .cube 3D LUT Parser

public struct ForgeCubeLUT: Sendable {
    public let title: String
    public let size: Int
    public let domainMin: SIMD3<Float>
    public let domainMax: SIMD3<Float>
    /// Row-major `N * N * N` Float RGBA entries (R fastest, then G, then B).
    public let entriesRGBA: [Float]

    public static func parse(url: URL) throws -> ForgeCubeLUT {
        try SafeFilePublisher.assertRegularReadableFile(url)
        let text = try String(contentsOf: url, encoding: .utf8)
        return try parse(string: text)
    }

    public static func parse(string: String) throws -> ForgeCubeLUT {
        var title = "LUT"
        var size3D: Int?
        var size1D: Int?
        var domMin = SIMD3<Float>(0, 0, 0)
        var domMax = SIMD3<Float>(1, 1, 1)
        var triplets: [SIMD3<Float>] = []

        for rawLine in string.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("TITLE") {
                title = line.dropFirst("TITLE".count).trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                continue
            }
            if line.hasPrefix("LUT_3D_SIZE") {
                let parts = line.split(whereSeparator: \.isWhitespace)
                if parts.count >= 2, let n = Int(parts[1]), (2...128).contains(n) {
                    size3D = n
                } else {
                    throw SafariumError.invalidState("invalid LUT_3D_SIZE in .cube: \(line)")
                }
                continue
            }
            if line.hasPrefix("LUT_1D_SIZE") {
                let parts = line.split(whereSeparator: \.isWhitespace)
                if parts.count >= 2, let n = Int(parts[1]), (2...4096).contains(n) {
                    size1D = n
                }
                continue
            }
            if line.hasPrefix("DOMAIN_MIN") {
                let parts = line.split(whereSeparator: \.isWhitespace)
                if parts.count >= 4, let r = Float(parts[1]), let g = Float(parts[2]), let b = Float(parts[3]) {
                    domMin = SIMD3<Float>(r, g, b)
                }
                continue
            }
            if line.hasPrefix("DOMAIN_MAX") {
                let parts = line.split(whereSeparator: \.isWhitespace)
                if parts.count >= 4, let r = Float(parts[1]), let g = Float(parts[2]), let b = Float(parts[3]) {
                    domMax = SIMD3<Float>(r, g, b)
                }
                continue
            }
            let parts = line.split(whereSeparator: \.isWhitespace)
            if parts.count >= 3,
               let r = Float(parts[0]), let g = Float(parts[1]), let b = Float(parts[2]) {
                triplets.append(SIMD3<Float>(r, g, b))
            }
        }

        if let n = size3D {
            let expected = n * n * n
            guard triplets.count == expected else {
                throw SafariumError.invalidState(".cube expected \(expected) RGB triplets for size \(n), got \(triplets.count)")
            }
            var rgba = [Float](repeating: 1.0, count: expected * 4)
            for i in 0..<expected {
                rgba[i * 4] = triplets[i].x
                rgba[i * 4 + 1] = triplets[i].y
                rgba[i * 4 + 2] = triplets[i].z
                rgba[i * 4 + 3] = 1.0
            }
            return ForgeCubeLUT(title: title, size: n, domainMin: domMin, domainMax: domMax, entriesRGBA: rgba)
        } else if let n1 = size1D, triplets.count == n1 {
            // Convert 1D LUT to compact 17^3 3D LUT by per-channel linear interpolation.
            let n = 17
            let expected = n * n * n
            var rgba = [Float](repeating: 1.0, count: expected * 4)
            func sample1D(_ u: Float, _ ch: Int) -> Float {
                let pos = max(0, min(Float(n1 - 1), u * Float(n1 - 1)))
                let lo = Int(floor(pos))
                let hi = min(n1 - 1, lo + 1)
                let f = pos - Float(lo)
                let a = triplets[lo][ch], b = triplets[hi][ch]
                return a + (b - a) * f
            }
            var idx = 0
            for bi in 0..<n {
                for gi in 0..<n {
                    for ri in 0..<n {
                        rgba[idx * 4] = sample1D(Float(ri) / Float(n - 1), 0)
                        rgba[idx * 4 + 1] = sample1D(Float(gi) / Float(n - 1), 1)
                        rgba[idx * 4 + 2] = sample1D(Float(bi) / Float(n - 1), 2)
                        rgba[idx * 4 + 3] = 1.0
                        idx += 1
                    }
                }
            }
            return ForgeCubeLUT(title: title, size: n, domainMin: domMin, domainMax: domMax, entriesRGBA: rgba)
        } else {
            throw SafariumError.invalidState("invalid .cube file: missing LUT_3D_SIZE or mismatched entry count")
        }
    }

    public func makeMTLTexture3D(device: MTLDevice) throws -> MTLTexture {
        let desc = MTLTextureDescriptor()
        desc.textureType = .type3D
        desc.pixelFormat = .rgba16Float
        desc.width = size
        desc.height = size
        desc.depth = size
        desc.mipmapLevelCount = 1
        desc.storageMode = .shared
        desc.usage = [.shaderRead]
        guard let tex = device.makeTexture(descriptor: desc) else {
            throw SafariumError.encode("failed to create 3D LUT MTLTexture (\(size)^3)")
        }
        var halfData = [Float16](repeating: 0, count: entriesRGBA.count)
        for i in 0..<entriesRGBA.count {
            halfData[i] = Float16(entriesRGBA[i])
        }
        let bpr = size * 4 * MemoryLayout<Float16>.size
        let bpi = bpr * size
        halfData.withUnsafeBytes { raw in
            tex.replace(
                region: MTLRegionMake3D(0, 0, 0, size, size, size),
                mipmapLevel: 0,
                slice: 0,
                withBytes: raw.baseAddress!,
                bytesPerRow: bpr,
                bytesPerImage: bpi
            )
        }
        return tex
    }
}

// MARK: - Bounded LRU <= 4 Texture Cache

public final class ForgeTextureLRU {
    public let capacity: Int
    private var order: [String] = []
    private var table: [String: MTLTexture] = [:]

    public init(capacity: Int = 4) {
        self.capacity = max(1, min(4, capacity))
    }

    public var count: Int { table.count }

    public func get(_ key: String) -> MTLTexture? {
        guard let tex = table[key] else { return nil }
        if let idx = order.firstIndex(of: key) {
            order.remove(at: idx)
            order.append(key)
        }
        return tex
    }

    public func insert(_ key: String, texture: MTLTexture) {
        if table[key] != nil {
            if let idx = order.firstIndex(of: key) { order.remove(at: idx) }
        } else if order.count >= capacity {
            let evict = order.removeFirst()
            table.removeValue(forKey: evict)
        }
        order.append(key)
        table[key] = texture
    }

    public func removeAll() {
        order.removeAll()
        table.removeAll()
    }
}

// MARK: - Filter Parameter Types & Color Parsing

public enum ForgeColorHex {
    public static func parseRGBA(_ hex: String?) -> SIMD4<Float> {
        guard let raw = hex?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return SIMD4<Float>(0, 0, 0, 1)
        }
        let clean = raw.hasPrefix("#") ? String(raw.dropFirst()) : raw
        guard let num = UInt64(clean, radix: 16) else {
            return SIMD4<Float>(0, 0, 0, 1)
        }
        switch clean.count {
        case 6:
            let r = Float((num >> 16) & 0xFF) / 255.0
            let g = Float((num >> 8) & 0xFF) / 255.0
            let b = Float(num & 0xFF) / 255.0
            return SIMD4<Float>(r, g, b, 1.0)
        case 8:
            let r = Float((num >> 24) & 0xFF) / 255.0
            let g = Float((num >> 16) & 0xFF) / 255.0
            let b = Float((num >> 8) & 0xFF) / 255.0
            let a = Float(num & 0xFF) / 255.0
            return SIMD4<Float>(r, g, b, a)
        default:
            return SIMD4<Float>(0, 0, 0, 1)
        }
    }
}

public enum ForgeBlendMode: UInt32, Sendable {
    case normal = 0
    case multiply = 1
    case screen = 2
    case add = 3
    case overlay = 4

    public static func parse(_ s: String?) -> ForgeBlendMode {
        switch s?.lowercased() {
        case "multiply": return .multiply
        case "screen": return .screen
        case "add", "plus": return .add
        case "overlay": return .overlay
        default: return .normal
        }
    }
}

public enum ForgeXfadeTransition: UInt32, Sendable {
    case fade = 0
    case wipeLeft = 1
    case wipeRight = 2
    case wipeUp = 3
    case wipeDown = 4
    case slideLeft = 5
    case slideRight = 6

    public static func parse(_ s: String?) -> ForgeXfadeTransition {
        switch s?.lowercased() {
        case "wipeleft": return .wipeLeft
        case "wiperight": return .wipeRight
        case "wipeup": return .wipeUp
        case "wipedown": return .wipeDown
        case "slideleft": return .slideLeft
        case "slideright": return .slideRight
        default: return .fade
        }
    }
}

public enum ForgeFieldOrder: UInt32, Sendable {
    case topFirst = 0
    case bottomFirst = 1

    public static func parse(_ s: String?) -> ForgeFieldOrder {
        (s?.lowercased() == "bff" || s?.lowercased() == "bottom") ? .bottomFirst : .topFirst
    }
}

// MARK: - Metal Uniform Structs (16-byte aligned)

private struct GeomUniforms {
    var srcSize: SIMD2<UInt32>
    var dstSize: SIMD2<UInt32>
    var cropOrigin: SIMD2<Float>
    var cropSize: SIMD2<Float>
    var dstOrigin: SIMD2<Float>
    var dstRectSize: SIMD2<Float>
    var cosTheta: Float
    var sinTheta: Float
    var hflip: UInt32
    var vflip: UInt32
    var bgColor: SIMD4<Float>
}

private struct DeinterlaceUniforms {
    var size: SIMD2<UInt32>
    var fieldOrder: UInt32
    var parity: UInt32
    var motionThreshold: Float
    var _pad0: UInt32 = 0
    var _pad1: UInt32 = 0
    var _pad2: UInt32 = 0
}

private struct KenBurnsUniforms {
    var srcSize: SIMD2<UInt32>
    var dstSize: SIMD2<UInt32>
    var centerNorm: SIMD2<Float>
    var zoom: Float
    var bicubic: UInt32
}

private struct ChromaKeyUniforms {
    var size: SIMD2<UInt32>
    var keyRGB: SIMD4<Float>
    var similarity: Float
    var smoothness: Float
    var despillStrength: Float
    var erodeRadius: Int32
}

private struct BlurUniforms {
    var size: SIMD2<UInt32>
    var radius: Int32
    var inv2Sigma2: Float
}

private struct ColorGradeUniforms {
    var size: SIMD2<UInt32>
    var brightness: Float
    var contrast: Float
    var saturation: Float
    var gamma: Float
    var grayscale: Float
    var _pad0: UInt32 = 0
}

private struct LUT3DUniforms {
    var size: SIMD2<UInt32>
    var intensity: Float
    var lutSize: Float
    var domainMin: SIMD4<Float>
    var domainMax: SIMD4<Float>
}

private struct VignetteUniforms {
    var size: SIMD2<UInt32>
    var intensity: Float
    var radius: Float
    var softness: Float
    var _pad0: UInt32 = 0
    var _pad1: UInt32 = 0
    var _pad2: UInt32 = 0
}

private struct GrainUniforms {
    var size: SIMD2<UInt32>
    var amount: Float
    var grainSize: Float
    var frameSeed: UInt32
    var _pad0: UInt32 = 0
    var _pad1: UInt32 = 0
    var _pad2: UInt32 = 0
}

private struct OverlayBlendUniforms {
    var canvasSize: SIMD2<UInt32>
    var ovSize: SIMD2<UInt32>
    var origin: SIMD2<Float>
    var scale: Float
    var opacity: Float
    var blendMode: UInt32
    var _pad0: UInt32 = 0
    var _pad1: UInt32 = 0
    var _pad2: UInt32 = 0
}

private struct XfadeUniforms {
    var size: SIMD2<UInt32>
    var progress: Float
    var transition: UInt32
}

private struct MatteCompositeUniforms {
    var size: SIMD2<UInt32>
    var emaAlpha: Float
    var hasPrevMask: UInt32
    var hasBgTex: UInt32
    var maskOnly: UInt32
    var bgColor: SIMD4<Float>
}

private struct TMixUniforms {
    var size: SIMD2<UInt32>
    var weight: Float
    var isFirst: UInt32
    var isFinal: UInt32
    var _pad0: UInt32 = 0
    var _pad1: UInt32 = 0
    var _pad2: UInt32 = 0
}

public struct ForgeKGriefConfig: Sendable, Equatable {
    public var saturation: Float
    public var brightness: Float
    public var temporalBlend: Float
    public var motionRejection: Float
    public var flowScale: Float

    public init(
        saturation: Float = 0.10,
        brightness: Float = 0.92,
        temporalBlend: Float = 0.25,
        motionRejection: Float = 6.0,
        flowScale: Float = 1.0
    ) {
        self.saturation = saturation
        self.brightness = brightness
        self.temporalBlend = temporalBlend
        self.motionRejection = motionRejection
        self.flowScale = flowScale
    }

    public static let griefOn = ForgeKGriefConfig(
        saturation: 0.10, brightness: 0.92, temporalBlend: 0.25, motionRejection: 6.0, flowScale: 1.0
    )
    public static let griefOff = ForgeKGriefConfig(
        saturation: 1.0, brightness: 1.0, temporalBlend: 0.0, motionRejection: 6.0, flowScale: 1.0
    )
}

private struct KGriefUniforms {
    var size: SIMD2<UInt32>
    var saturation: Float
    var brightness: Float
    var temporalBlend: Float
    var motionRejection: Float
    var flowScale: Float
    var hasPrev: UInt32
    var hasFlow: UInt32
    var hasHud: UInt32
    var _pad0: UInt32 = 0
    var _pad1: UInt32 = 0
}

// MARK: - ForgeMetalFilterEngine

public final class ForgeMetalFilterEngine {
    public let device: MTLDevice
    public let commandQueue: MTLCommandQueue
    public let textureCache: CVMetalTextureCache
    public let textureLRU = ForgeTextureLRU(capacity: 4)
    public private(set) var wave2Effects: Wave2MetalEffectsEngine?

    private let pSolidFill: MTLComputePipelineState
    private let pGeom: MTLComputePipelineState
    private let pDeinterlace: MTLComputePipelineState
    private let pKenBurns: MTLComputePipelineState
    private let pChromaMatte: MTLComputePipelineState
    private let pDiskErodeAlpha: MTLComputePipelineState
    private let pChromaDespill: MTLComputePipelineState
    private let pGBlurH: MTLComputePipelineState
    private let pGBlurV: MTLComputePipelineState
    private let pColorGrade: MTLComputePipelineState
    private let pLUT3D: MTLComputePipelineState
    private let pVignette: MTLComputePipelineState
    private let pGrain: MTLComputePipelineState
    private let pOverlayBlend: MTLComputePipelineState
    private let pXfade: MTLComputePipelineState
    private let pMatteEMAAndComposite: MTLComputePipelineState
    private let pTMixAccum: MTLComputePipelineState
    private let pKGrief: MTLComputePipelineState
    private let pBGRAToNV12: MTLComputePipelineState
    private let pNV12ToBGRA: MTLComputePipelineState

    private var scratchRGBA16Tex: MTLTexture?
    private var scratchBGRA8TexA: MTLTexture?
    private var scratchBGRA8TexB: MTLTexture?
    private var scratchW = 0
    private var scratchH = 0
    private var tmixRGBA16TexA: MTLTexture?
    private var tmixRGBA16TexB: MTLTexture?
    private var tmixW = 0
    private var tmixH = 0

    private static let shaderSource: String = #"""
    #include <metal_stdlib>
    using namespace metal;

    struct GeomUniforms {
        uint2  srcSize;
        uint2  dstSize;
        float2 cropOrigin;
        float2 cropSize;
        float2 dstOrigin;
        float2 dstRectSize;
        float  cosTheta;
        float  sinTheta;
        uint   hflip;
        uint   vflip;
        float4 bgColor;
    };

    kernel void solid_fill(
        texture2d<float, access::write> dst [[texture(0)]],
        constant float4& color [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        float4 premul = float4(color.rgb * color.a, color.a);
        dst.write(premul, gid);
    }

    kernel void geom_transform(
        texture2d<float, access::sample> src [[texture(0)]],
        texture2d<float, access::write>  dst [[texture(1)]],
        constant GeomUniforms& u [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= u.dstSize.x || gid.y >= u.dstSize.y) return;
        constexpr sampler lin(coord::normalized, address::clamp_to_edge, filter::linear);

        float2 p = float2(gid) + 0.5f;
        if (p.x < u.dstOrigin.x || p.y < u.dstOrigin.y ||
            p.x >= u.dstOrigin.x + u.dstRectSize.x || p.y >= u.dstOrigin.y + u.dstRectSize.y) {
            dst.write(float4(u.bgColor.rgb * u.bgColor.a, u.bgColor.a), gid);
            return;
        }
        float2 rectCenter = u.dstOrigin + 0.5f * u.dstRectSize;
        float2 rel = p - rectCenter;
        float2 rotBox = float2(
            fabs(u.cosTheta) * u.cropSize.x + fabs(u.sinTheta) * u.cropSize.y,
            fabs(u.sinTheta) * u.cropSize.x + fabs(u.cosTheta) * u.cropSize.y
        );
        float2 srcRel = rel * (rotBox / max(u.dstRectSize, float2(1.0f)));
        float2 unrot = float2(
            srcRel.x * u.cosTheta + srcRel.y * u.sinTheta,
            -srcRel.x * u.sinTheta + srcRel.y * u.cosTheta
        );
        float2 normInCrop = (unrot / max(u.cropSize, float2(1.0f))) + 0.5f;
        if (normInCrop.x < 0.0f || normInCrop.x > 1.0f || normInCrop.y < 0.0f || normInCrop.y > 1.0f) {
            dst.write(float4(u.bgColor.rgb * u.bgColor.a, u.bgColor.a), gid);
            return;
        }
        if (u.hflip != 0u) normInCrop.x = 1.0f - normInCrop.x;
        if (u.vflip != 0u) normInCrop.y = 1.0f - normInCrop.y;

        float2 srcPx = u.cropOrigin + normInCrop * u.cropSize;
        float2 uv = srcPx / float2(u.srcSize);
        dst.write(src.sample(lin, uv), gid);
    }

    struct DeinterlaceUniforms {
        uint2 size;
        uint  fieldOrder;
        uint  parity;
        float motionThreshold;
        uint  _pad0;
        uint  _pad1;
        uint  _pad2;
    };

    kernel void deinterlace_motion_adaptive(
        texture2d<float, access::read>  prevTex [[texture(0)]],
        texture2d<float, access::read>  currTex [[texture(1)]],
        texture2d<float, access::read>  nextTex [[texture(2)]],
        texture2d<float, access::write> dstTex  [[texture(3)]],
        constant DeinterlaceUniforms&   u       [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= u.size.x || gid.y >= u.size.y) return;
        uint keepMod = (u.fieldOrder ^ u.parity) & 1u;
        float4 c = currTex.read(gid);
        if ((gid.y & 1u) == keepMod) {
            dstTex.write(c, gid);
            return;
        }
        uint yAbove = gid.y > 0 ? gid.y - 1 : 0;
        uint yBelow = min(u.size.y - 1, gid.y + 1);
        float4 up = currTex.read(uint2(gid.x, yAbove));
        float4 dn = currTex.read(uint2(gid.x, yBelow));

        // Edge-directed spatial interpolation clamped inside [min(up,dn), max(up,dn)]
        uint xL = gid.x > 0 ? gid.x - 1 : 0;
        uint xR = min(u.size.x - 1, gid.x + 1);
        float4 upL = currTex.read(uint2(xL, yAbove));
        float4 dnR = currTex.read(uint2(xR, yBelow));
        float4 upR = currTex.read(uint2(xR, yAbove));
        float4 dnL = currTex.read(uint2(xL, yBelow));

        float dVert = length(up.rgb - dn.rgb);
        float dDiag1 = length(upL.rgb - dnR.rgb);
        float dDiag2 = length(upR.rgb - dnL.rgb);
        float4 spatial = 0.5f * (up + dn);
        if (dDiag1 + 0.05f < dVert && dDiag1 < dDiag2) {
            spatial = 0.5f * (upL + dnR);
        } else if (dDiag2 + 0.05f < dVert && dDiag2 < dDiag1) {
            spatial = 0.5f * (upR + dnL);
        }
        spatial = clamp(spatial, min(up, dn), max(up, dn));

        // Motion-adaptive temporal blend between prev and next field/frame
        float4 p = prevTex.read(gid);
        float4 n = nextTex.read(gid);
        float4 temporal = 0.5f * (p + n);
        float diffSame = length(p.rgb - n.rgb);
        float diffSpatial = length(c.rgb - spatial.rgb);
        float motion = max(diffSame, diffSpatial * 0.7f);
        float alphaSpatial = smoothstep(u.motionThreshold * 0.5f, u.motionThreshold * 1.5f, motion);
        dstTex.write(mix(temporal, spatial, alphaSpatial), gid);
    }

    struct KenBurnsUniforms {
        uint2  srcSize;
        uint2  dstSize;
        float2 centerNorm;
        float  zoom;
        uint   bicubic;
    };

    inline float4 cubicWeight(float x) {
        float x2 = x * x;
        float x3 = x2 * x;
        return float4(
            -0.5f * x3 + x2 - 0.5f * x,
            1.5f * x3 - 2.5f * x2 + 1.0f,
            -1.5f * x3 + 2.0f * x2 + 0.5f * x,
            0.5f * x3 - 0.5f * x2
        );
    }

    kernel void ken_burns(
        texture2d<float, access::sample> src [[texture(0)]],
        texture2d<float, access::write>  dst [[texture(1)]],
        constant KenBurnsUniforms& u [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= u.dstSize.x || gid.y >= u.dstSize.y) return;
        constexpr sampler lin(coord::normalized, address::clamp_to_edge, filter::linear);
        float z = max(1.0f, u.zoom);
        float2 uvDst = (float2(gid) + 0.5f) / float2(u.dstSize);
        float2 winSize = float2(1.0f / z);
        float2 halfWin = 0.5f * winSize;
        float2 clampedCenter = clamp(u.centerNorm, halfWin, 1.0f - halfWin);
        float2 uvSrc = clampedCenter + (uvDst - 0.5f) * winSize;

        if (u.bicubic == 0u) {
            dst.write(src.sample(lin, uvSrc), gid);
            return;
        }
        float2 pos = uvSrc * float2(u.srcSize) - 0.5f;
        float2 f = fract(pos);
        int2 ip = int2(floor(pos));
        float4 wx = cubicWeight(f.x);
        float4 wy = cubicWeight(f.y);
        constexpr sampler nearClamp(coord::pixel, address::clamp_to_edge, filter::nearest);
        float4 acc = float4(0.0f);
        for (int j = -1; j <= 2; ++j) {
            float4 rowAcc = float4(0.0f);
            for (int i = -1; i <= 2; ++i) {
                rowAcc += wx[i + 1] * src.sample(nearClamp, float2(ip + int2(i, j)) + 0.5f);
            }
            acc += wy[j + 1] * rowAcc;
        }
        dst.write(clamp(acc, 0.0f, 1.0f), gid);
    }

    struct ChromaKeyUniforms {
        uint2  size;
        float4 keyRGB;
        float  similarity;
        float  smoothness;
        float  despillStrength;
        int    erodeRadius;
    };

    inline float2 rgbToCbCr(float3 c) {
        float cb = -0.168736f * c.r - 0.331264f * c.g + 0.5f * c.b;
        float cr =  0.5f * c.r - 0.418688f * c.g - 0.081312f * c.b;
        return float2(cb, cr);
    }

    kernel void chroma_key_matte(
        texture2d<float, access::read>  src [[texture(0)]],
        texture2d<float, access::write> dst [[texture(1)]],
        constant ChromaKeyUniforms& u [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= u.size.x || gid.y >= u.size.y) return;
        float4 c = src.read(gid);
        float aSafe = max(c.a, 1e-5f);
        float3 rgb = c.rgb / aSafe;
        float2 pixCC = rgbToCbCr(rgb);
        float2 keyCC = rgbToCbCr(u.keyRGB.rgb);
        float dist = length(pixCC - keyCC);
        float lo = max(0.001f, u.similarity);
        float hi = lo + max(0.001f, u.smoothness);
        float keyMask = smoothstep(lo, hi, dist);
        float outA = c.a * keyMask;
        dst.write(float4(rgb, outA), gid);
    }

    kernel void disk_erode_alpha(
        texture2d<float, access::read>  src [[texture(0)]],
        texture2d<float, access::write> dst [[texture(1)]],
        constant ChromaKeyUniforms& u [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= u.size.x || gid.y >= u.size.y) return;
        float4 c = src.read(gid);
        int r = clamp(u.erodeRadius, 0, 8);
        if (r <= 0) {
            dst.write(c, gid);
            return;
        }
        float minA = c.a;
        int r2 = r * r;
        int x0 = max(0, int(gid.x) - r), x1 = min(int(u.size.x) - 1, int(gid.x) + r);
        int y0 = max(0, int(gid.y) - r), y1 = min(int(u.size.y) - 1, int(gid.y) + r);
        for (int y = y0; y <= y1; ++y) {
            int dy = y - int(gid.y);
            for (int x = x0; x <= x1; ++x) {
                int dx = x - int(gid.x);
                if (dx * dx + dy * dy <= r2) {
                    minA = min(minA, src.read(uint2(x, y)).a);
                }
            }
        }
        dst.write(float4(c.rgb, minA), gid);
    }

    kernel void chroma_despill(
        texture2d<float, access::read>  src [[texture(0)]],
        texture2d<float, access::write> dst [[texture(1)]],
        constant ChromaKeyUniforms& u [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= u.size.x || gid.y >= u.size.y) return;
        float4 c = src.read(gid);
        float3 rgb = c.rgb;
        if (u.despillStrength > 0.001f) {
            bool isBlueScreen = (u.keyRGB.b > u.keyRGB.g && u.keyRGB.b > u.keyRGB.r);
            if (isBlueScreen) {
                float limit = 0.5f * (rgb.r + rgb.g);
                if (rgb.b > limit) {
                    float spill = (rgb.b - limit) * u.despillStrength;
                    rgb.b -= spill;
                    rgb.r += spill * 0.20f;
                    rgb.g += spill * 0.15f;
                }
            } else {
                float limit = max(rgb.r, rgb.b) * 0.55f + 0.45f * 0.5f * (rgb.r + rgb.b);
                if (rgb.g > limit) {
                    float spill = (rgb.g - limit) * u.despillStrength;
                    rgb.g -= spill;
                    // Preserve luma naturally into red & blue
                    rgb.r += spill * 0.45f;
                    rgb.b += spill * 0.35f;
                }
            }
        }
        rgb = clamp(rgb, 0.0f, 1.0f);
        dst.write(float4(rgb * c.a, c.a), gid);
    }

    struct BlurUniforms {
        uint2 size;
        int   radius;
        float inv2Sigma2;
    };

    kernel void gblur_h(
        texture2d<float, access::read>  src [[texture(0)]],
        texture2d<float, access::write> dst [[texture(1)]],
        constant BlurUniforms& u [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= u.size.x || gid.y >= u.size.y) return;
        float4 sum = float4(0.0f);
        float wsum = 0.0f;
        int w = int(u.size.x);
        for (int k = -u.radius; k <= u.radius; ++k) {
            int sx = clamp(int(gid.x) + k, 0, w - 1);
            float wt = exp(-float(k * k) * u.inv2Sigma2);
            sum += src.read(uint2(sx, gid.y)) * wt;
            wsum += wt;
        }
        dst.write(sum / max(wsum, 1e-6f), gid);
    }

    kernel void gblur_v(
        texture2d<float, access::read>  src [[texture(0)]],
        texture2d<float, access::write> dst [[texture(1)]],
        constant BlurUniforms& u [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= u.size.x || gid.y >= u.size.y) return;
        float4 sum = float4(0.0f);
        float wsum = 0.0f;
        int h = int(u.size.y);
        for (int k = -u.radius; k <= u.radius; ++k) {
            int sy = clamp(int(gid.y) + k, 0, h - 1);
            float wt = exp(-float(k * k) * u.inv2Sigma2);
            sum += src.read(uint2(gid.x, sy)) * wt;
            wsum += wt;
        }
        dst.write(sum / max(wsum, 1e-6f), gid);
    }

    struct ColorGradeUniforms {
        uint2 size;
        float brightness;
        float contrast;
        float saturation;
        float gamma;
        float grayscale;
        uint  _pad0;
    };

    kernel void color_grade(
        texture2d<float, access::read>  src [[texture(0)]],
        texture2d<float, access::write> dst [[texture(1)]],
        constant ColorGradeUniforms& u [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= u.size.x || gid.y >= u.size.y) return;
        float4 c = src.read(gid);
        float aSafe = max(c.a, 1e-5f);
        float3 rgb = c.rgb / aSafe;

        rgb += u.brightness;
        rgb = (rgb - 0.5f) * u.contrast + 0.5f;
        float luma = dot(rgb, float3(0.2126f, 0.7152f, 0.0722f));
        rgb = mix(float3(luma), rgb, u.saturation);
        rgb = clamp(rgb, 0.0f, 1.0f);
        if (abs(u.gamma - 1.0f) > 1e-4f) {
            rgb = pow(rgb, float3(1.0f / max(0.05f, u.gamma)));
        }
        if (u.grayscale > 0.001f) {
            float g = dot(rgb, float3(0.2126f, 0.7152f, 0.0722f));
            rgb = mix(rgb, float3(g), clamp(u.grayscale, 0.0f, 1.0f));
        }
        rgb = clamp(rgb, 0.0f, 1.0f);
        dst.write(float4(rgb * c.a, c.a), gid);
    }

    struct LUT3DUniforms {
        uint2  size;
        float  intensity;
        float  lutSize;
        float4 domainMin;
        float4 domainMax;
    };

    kernel void lut3d_apply(
        texture2d<float, access::read>   src [[texture(0)]],
        texture3d<float, access::sample> lut [[texture(1)]],
        texture2d<float, access::write>  dst [[texture(2)]],
        constant LUT3DUniforms& u [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= u.size.x || gid.y >= u.size.y) return;
        constexpr sampler s3d(coord::normalized, address::clamp_to_edge, filter::linear);
        float4 c = src.read(gid);
        float aSafe = max(c.a, 1e-5f);
        float3 rgb = c.rgb / aSafe;
        float3 norm = clamp((rgb - u.domainMin.rgb) / max(u.domainMax.rgb - u.domainMin.rgb, float3(1e-5f)), 0.0f, 1.0f);
        float3 coord = (norm * (u.lutSize - 1.0f) + 0.5f) / u.lutSize;
        float3 graded = lut.sample(s3d, coord).rgb;
        float3 outRGB = clamp(mix(rgb, graded, clamp(u.intensity, 0.0f, 1.0f)), 0.0f, 1.0f);
        dst.write(float4(outRGB * c.a, c.a), gid);
    }

    struct VignetteUniforms {
        uint2 size;
        float intensity;
        float radius;
        float softness;
        uint  _pad0;
        uint  _pad1;
        uint  _pad2;
    };

    kernel void vignette_apply(
        texture2d<float, access::read>  src [[texture(0)]],
        texture2d<float, access::write> dst [[texture(1)]],
        constant VignetteUniforms& u [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= u.size.x || gid.y >= u.size.y) return;
        float4 c = src.read(gid);
        float2 uv = (float2(gid) + 0.5f) / float2(u.size);
        float d = length((uv - 0.5f) * 2.0f);
        float edge = smoothstep(u.radius, u.radius + max(0.01f, u.softness), d);
        float factor = 1.0f - clamp(u.intensity, 0.0f, 1.0f) * edge;
        dst.write(float4(c.rgb * factor, c.a), gid);
    }

    struct GrainUniforms {
        uint2 size;
        float amount;
        float grainSize;
        uint  frameSeed;
        uint  _pad0;
        uint  _pad1;
        uint  _pad2;
    };

    inline uint hash_u32(uint x) {
        x ^= x >> 16;
        x *= 0x7feb352du;
        x ^= x >> 15;
        x *= 0x846ca68bu;
        x ^= x >> 16;
        return x;
    }

    kernel void grain_apply(
        texture2d<float, access::read>  src [[texture(0)]],
        texture2d<float, access::write> dst [[texture(1)]],
        constant GrainUniforms& u [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= u.size.x || gid.y >= u.size.y) return;
        float4 c = src.read(gid);
        float aSafe = max(c.a, 1e-5f);
        float3 rgb = c.rgb / aSafe;
        uint2 cell = uint2(float2(gid) / max(1.0f, u.grainSize));
        uint h = hash_u32(cell.x * 374761393u + cell.y * 668265263u + u.frameSeed * 1442695041u);
        float n1 = float(h & 0xFFFFu) / 65535.0f;
        float n2 = float((h >> 16) & 0xFFFFu) / 65535.0f;
        float noise = (n1 + n2 - 1.0f) * u.amount;
        float3 outRGB = clamp(rgb + noise, 0.0f, 1.0f);
        dst.write(float4(outRGB * c.a, c.a), gid);
    }

    struct OverlayBlendUniforms {
        uint2  canvasSize;
        uint2  ovSize;
        float2 origin;
        float  scale;
        float  opacity;
        uint   blendMode;
        uint   _pad0;
        uint   _pad1;
        uint   _pad2;
    };

    inline float3 blend_rgb(float3 bg, float3 fg, uint mode) {
        if (mode == 1u) return bg * fg; // multiply
        if (mode == 2u) return 1.0f - (1.0f - bg) * (1.0f - fg); // screen
        if (mode == 3u) return clamp(bg + fg, 0.0f, 1.0f); // add
        if (mode == 4u) { // overlay
            float3 lo = 2.0f * bg * fg;
            float3 hi = 1.0f - 2.0f * (1.0f - bg) * (1.0f - fg);
            return select(hi, lo, bg < 0.5f);
        }
        return fg; // normal
    }

    kernel void overlay_blend(
        texture2d<float, access::read>   baseTex [[texture(0)]],
        texture2d<float, access::sample> overTex [[texture(1)]],
        texture2d<float, access::write>  dstTex  [[texture(2)]],
        constant OverlayBlendUniforms& u [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= u.canvasSize.x || gid.y >= u.canvasSize.y) return;
        constexpr sampler lin(coord::normalized, address::clamp_to_edge, filter::linear);
        float4 bg = baseTex.read(gid);
        float2 dstRect = float2(u.ovSize) * max(0.001f, u.scale);
        float2 p = float2(gid) + 0.5f;
        if (p.x < u.origin.x || p.y < u.origin.y ||
            p.x >= u.origin.x + dstRect.x || p.y >= u.origin.y + dstRect.y) {
            dstTex.write(bg, gid);
            return;
        }
        float2 uv = (p - u.origin) / dstRect;
        float4 fg = overTex.sample(lin, uv) * clamp(u.opacity, 0.0f, 1.0f);
        if (u.blendMode == 0u) {
            float4 out = fg + bg * (1.0f - fg.a);
            dstTex.write(clamp(out, 0.0f, 1.0f), gid);
            return;
        }
        float fgA = max(fg.a, 1e-5f);
        float bgA = max(bg.a, 1e-5f);
        float3 fgUn = fg.rgb / fgA;
        float3 bgUn = bg.rgb / bgA;
        float3 mixed = blend_rgb(bgUn, fgUn, u.blendMode);
        float3 compRGB = mixed * fg.a * bg.a + fg.rgb * (1.0f - bg.a) + bg.rgb * (1.0f - fg.a);
        float compA = fg.a + bg.a * (1.0f - fg.a);
        dstTex.write(clamp(float4(compRGB, compA), 0.0f, 1.0f), gid);
    }

    struct XfadeUniforms {
        uint2 size;
        float progress;
        uint  transition;
    };

    kernel void xfade_compose(
        texture2d<float, access::sample> texA [[texture(0)]],
        texture2d<float, access::sample> texB [[texture(1)]],
        texture2d<float, access::write>  dst  [[texture(2)]],
        constant XfadeUniforms& u [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= u.size.x || gid.y >= u.size.y) return;
        constexpr sampler lin(coord::normalized, address::clamp_to_edge, filter::linear);
        float2 uv = (float2(gid) + 0.5f) / float2(u.size);
        float p = clamp(u.progress, 0.0f, 1.0f);
        float4 a = texA.sample(lin, uv);
        float4 b = texB.sample(lin, uv);

        if (u.transition == 1u) { // wipeLeft
            dst.write(uv.x >= (1.0f - p) ? b : a, gid);
        } else if (u.transition == 2u) { // wipeRight
            dst.write(uv.x <= p ? b : a, gid);
        } else if (u.transition == 3u) { // wipeUp
            dst.write(uv.y >= (1.0f - p) ? b : a, gid);
        } else if (u.transition == 4u) { // wipeDown
            dst.write(uv.y <= p ? b : a, gid);
        } else if (u.transition == 5u) { // slideLeft
            if (uv.x >= (1.0f - p)) {
                dst.write(texB.sample(lin, float2(uv.x - (1.0f - p), uv.y)), gid);
            } else {
                dst.write(texA.sample(lin, float2(uv.x + p, uv.y)), gid);
            }
        } else if (u.transition == 6u) { // slideRight
            if (uv.x <= p) {
                dst.write(texB.sample(lin, float2(uv.x + (1.0f - p), uv.y)), gid);
            } else {
                dst.write(texA.sample(lin, float2(uv.x - p, uv.y)), gid);
            }
        } else { // fade / dissolve
            dst.write(mix(a, b, p), gid);
        }
    }

    struct MatteCompositeUniforms {
        uint2  size;
        float  emaAlpha;
        uint   hasPrevMask;
        uint   hasBgTex;
        uint   maskOnly;
        float4 bgColor;
    };

    kernel void matte_ema_and_composite(
        texture2d<float, access::read>   srcTex      [[texture(0)]],
        texture2d<float, access::sample> rawMaskTex  [[texture(1)]],
        texture2d<float, access::read>   prevMaskTex [[texture(2)]],
        texture2d<float, access::sample> bgTex       [[texture(3)]],
        texture2d<float, access::write>  outMaskTex  [[texture(4)]],
        texture2d<float, access::write>  dstTex      [[texture(5)]],
        constant MatteCompositeUniforms& u [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= u.size.x || gid.y >= u.size.y) return;
        constexpr sampler lin(coord::normalized, address::clamp_to_edge, filter::linear);
        float2 uv = (float2(gid) + 0.5f) / float2(u.size);
        float mNow = clamp(rawMaskTex.sample(lin, uv).r, 0.0f, 1.0f);
        float mSmooth = mNow;
        if (u.hasPrevMask != 0u) {
            float mPrev = prevMaskTex.read(gid).r;
            mSmooth = mix(mPrev, mNow, clamp(u.emaAlpha, 0.01f, 1.0f));
        }
        outMaskTex.write(float4(mSmooth, 0, 0, 1), gid);
        if (u.maskOnly != 0u) {
            dstTex.write(float4(mSmooth, mSmooth, mSmooth, 1.0f), gid);
            return;
        }
        float4 src = srcTex.read(gid);
        float4 fg = float4(src.rgb * mSmooth, mSmooth);
        if (u.hasBgTex != 0u) {
            float4 bg = bgTex.sample(lin, uv);
            dstTex.write(clamp(fg + bg * (1.0f - fg.a), 0.0f, 1.0f), gid);
        } else if (u.bgColor.a > 0.001f) {
            float4 bg = float4(u.bgColor.rgb * u.bgColor.a, u.bgColor.a);
            dstTex.write(clamp(fg + bg * (1.0f - fg.a), 0.0f, 1.0f), gid);
        } else {
            // Transparent alpha output (ProRes 4444 / HEVCWithAlpha)
            dstTex.write(clamp(fg, 0.0f, 1.0f), gid);
        }
    }

    struct TMixUniforms {
        uint2 size;
        float weight;
        uint  isFirst;
        uint  isFinal;
        uint  _pad0;
        uint  _pad1;
        uint  _pad2;
    };

    kernel void tmix_accumulate_rgba16f(
        texture2d<float, access::read>  srcTex [[texture(0)]],
        texture2d<float, access::read>  accIn  [[texture(1)]],
        texture2d<float, access::write> accOut [[texture(2)]],
        texture2d<float, access::write> dstOut [[texture(3)]],
        constant TMixUniforms& u [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= u.size.x || gid.y >= u.size.y) return;
        float4 src = srcTex.read(gid);
        float4 prev = (u.isFirst != 0u) ? float4(0.0f) : accIn.read(gid);
        float4 nextAcc = prev + src * u.weight;
        accOut.write(nextAcc, gid);
        if (u.isFinal != 0u) {
            dstOut.write(clamp(nextAcc, 0.0f, 1.0f), gid);
        }
    }

    struct KGriefUniforms {
        uint2 size;
        float saturation;
        float brightness;
        float temporalBlend;
        float motionRejection;
        float flowScale;
        uint  hasPrev;
        uint  hasFlow;
        uint  hasHud;
        uint  _pad0;
        uint  _pad1;
    };

    kernel void k_grief_unified(
        texture2d<float, access::sample> currTex [[texture(0)]],
        texture2d<float, access::sample> prevTex [[texture(1)]],
        texture2d<float, access::sample> flowTex [[texture(2)]],
        texture2d<float, access::sample> hudTex  [[texture(3)]],
        texture2d<float, access::write>  dstTex  [[texture(4)]],
        constant KGriefUniforms& u [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= u.size.x || gid.y >= u.size.y) return;
        constexpr sampler lin(coord::normalized, address::clamp_to_edge, filter::linear);
        float2 fSize = float2(u.size);
        float2 uv = (float2(gid) + 0.5f) / fSize;

        float4 curr = currTex.sample(lin, uv);
        float aSafe = max(curr.a, 1e-5f);
        float3 currRGB = curr.rgb / aSafe;

        float3 smoothedRGB = currRGB;
        if (u.hasPrev != 0u && u.temporalBlend > 1e-4f) {
            float2 flowPx = (u.hasFlow != 0u) ? (flowTex.sample(lin, uv).xy * u.flowScale) : float2(0.0f);
            float2 prevUV = clamp((float2(gid) + 0.5f - flowPx) / fSize, float2(0.0f), float2(1.0f));
            float4 prev = prevTex.sample(lin, prevUV);
            float3 prevRGB = prev.rgb / max(prev.a, 1e-5f);
            float diff = length(currRGB - prevRGB);
            float wPrev = clamp(u.temporalBlend * exp(-u.motionRejection * diff * diff), 0.0f, 0.95f);
            smoothedRGB = mix(currRGB, prevRGB, wPrev);
        }

        float luma = dot(smoothedRGB, float3(0.2126f, 0.7152f, 0.0722f));
        float3 gradedRGB = clamp(mix(float3(luma), smoothedRGB, u.saturation) * u.brightness, 0.0f, 1.0f);
        float4 outPremul = float4(gradedRGB * curr.a, curr.a);

        if (u.hasHud != 0u) {
            float4 hud = hudTex.sample(lin, uv);
            outPremul = clamp(hud + outPremul * (1.0f - hud.a), 0.0f, 1.0f);
        }
        dstTex.write(clamp(outPremul, 0.0f, 1.0f), gid);
    }

    inline float rgbToY_bt709(float3 rgb) {
        float y = 0.2126f * rgb.r + 0.7152f * rgb.g + 0.0722f * rgb.b;
        return (16.0f + 219.0f * y) / 255.0f;
    }

    kernel void bgra_to_nv12_bt709(
        texture2d<float, access::read>  src    [[texture(0)]],
        texture2d<float, access::write> yPlane [[texture(1)]],
        texture2d<float, access::write> uvPlane [[texture(2)]],
        uint2 gid [[thread_position_in_grid]])
    {
        uint w = src.get_width();
        uint h = src.get_height();
        uint2 base = gid * 2;
        if (base.x >= w || base.y >= h) return;

        float3 c00 = src.read(base).rgb;
        float3 c10 = (base.x + 1 < w) ? src.read(base + uint2(1, 0)).rgb : c00;
        float3 c01 = (base.y + 1 < h) ? src.read(base + uint2(0, 1)).rgb : c00;
        float3 c11 = (base.x + 1 < w && base.y + 1 < h) ? src.read(base + uint2(1, 1)).rgb : c01;

        yPlane.write(float4(rgbToY_bt709(c00), 0, 0, 1), base);
        if (base.x + 1 < w) yPlane.write(float4(rgbToY_bt709(c10), 0, 0, 1), base + uint2(1, 0));
        if (base.y + 1 < h) yPlane.write(float4(rgbToY_bt709(c01), 0, 0, 1), base + uint2(0, 1));
        if (base.x + 1 < w && base.y + 1 < h) yPlane.write(float4(rgbToY_bt709(c11), 0, 0, 1), base + uint2(1, 1));

        float3 chromaRGB = 0.5f * (c00 + c01);
        float cb = (-0.114572f * chromaRGB.r - 0.385428f * chromaRGB.g + 0.5f * chromaRGB.b) * 224.0f + 128.0f;
        float cr = (0.5f * chromaRGB.r - 0.454153f * chromaRGB.g - 0.045847f * chromaRGB.b) * 224.0f + 128.0f;
        uvPlane.write(float4(clamp(cb / 255.0f, 0.0f, 1.0f), clamp(cr / 255.0f, 0.0f, 1.0f), 0, 1), gid);
    }

    kernel void nv12_to_bgra_bt709(
        texture2d<float, access::read>   yTex    [[texture(0)]],
        texture2d<float, access::sample> uvTex   [[texture(1)]],
        texture2d<float, access::write>  dstBGRA [[texture(2)]],
        uint2 gid [[thread_position_in_grid]])
    {
        uint w = dstBGRA.get_width();
        uint h = dstBGRA.get_height();
        if (gid.x >= w || gid.y >= h) return;
        constexpr sampler uvSamp(coord::pixel, address::clamp_to_edge, filter::linear);
        float yRaw = yTex.read(gid).r * 255.0f;
        float2 uvCoord = float2(float(gid.x) * 0.5f + 0.5f, (float(gid.y) - 0.5f) * 0.5f + 0.5f);
        float2 uvRaw = uvTex.sample(uvSamp, uvCoord).rg * 255.0f;
        float Y = (yRaw - 16.0f) / 219.0f;
        float Cb = (uvRaw.x - 128.0f) / 224.0f;
        float Cr = (uvRaw.y - 128.0f) / 224.0f;
        float r = Y + 1.5748f * Cr;
        float g = Y - 0.187324f * Cb - 0.468124f * Cr;
        float b = Y + 1.8556f * Cb;
        dstBGRA.write(float4(clamp(float3(r, g, b), 0.0f, 1.0f), 1.0f), gid);
    }
    """#

    public static func defaultBinaryArchiveURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/Safarium/forge-filters.metallib-archive")
    }

    public init(
        binaryArchiveURL: URL? = ForgeMetalFilterEngine.defaultBinaryArchiveURL(),
        bakeArchive: Bool = true,
        initWave2Engine: Bool = true
    ) throws {
        guard let ctx = SafariumMetalContext.shared else {
            throw SafariumError.encode("Metal context unavailable for ForgeMetalFilterEngine")
        }
        let dev = ctx.device
        self.device = dev
        self.commandQueue = ctx.commandQueue
        self.textureCache = ctx.textureCache
        if initWave2Engine {
            self.wave2Effects = try? Wave2MetalEffectsEngine()
        }

        let lib = try dev.makeLibrary(source: Self.shaderSource, options: nil)
        var archive: MTLBinaryArchive?
        if let archURL = binaryArchiveURL {
            try? FileManager.default.createDirectory(at: archURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let archDesc = MTLBinaryArchiveDescriptor()
            if FileManager.default.fileExists(atPath: archURL.path) {
                archDesc.url = archURL
            }
            archive = try? dev.makeBinaryArchive(descriptor: archDesc)
        }

        func makePipe(_ name: String) throws -> MTLComputePipelineState {
            guard let fn = lib.makeFunction(name: name) else {
                throw SafariumError.encode("missing ForgeMetal kernel '\(name)'")
            }
            let desc = MTLComputePipelineDescriptor()
            desc.computeFunction = fn
            if let arch = archive {
                desc.binaryArchives = [arch]
                if bakeArchive {
                    try? arch.addComputePipelineFunctions(descriptor: desc)
                }
            }
            return try dev.makeComputePipelineState(descriptor: desc, options: [], reflection: nil)
        }

        self.pSolidFill = try makePipe("solid_fill")
        self.pGeom = try makePipe("geom_transform")
        self.pDeinterlace = try makePipe("deinterlace_motion_adaptive")
        self.pKenBurns = try makePipe("ken_burns")
        self.pChromaMatte = try makePipe("chroma_key_matte")
        self.pDiskErodeAlpha = try makePipe("disk_erode_alpha")
        self.pChromaDespill = try makePipe("chroma_despill")
        self.pGBlurH = try makePipe("gblur_h")
        self.pGBlurV = try makePipe("gblur_v")
        self.pColorGrade = try makePipe("color_grade")
        self.pLUT3D = try makePipe("lut3d_apply")
        self.pVignette = try makePipe("vignette_apply")
        self.pGrain = try makePipe("grain_apply")
        self.pOverlayBlend = try makePipe("overlay_blend")
        self.pXfade = try makePipe("xfade_compose")
        self.pMatteEMAAndComposite = try makePipe("matte_ema_and_composite")
        self.pTMixAccum = try makePipe("tmix_accumulate_rgba16f")
        self.pKGrief = try makePipe("k_grief_unified")
        self.pBGRAToNV12 = try makePipe("bgra_to_nv12_bt709")
        self.pNV12ToBGRA = try makePipe("nv12_to_bgra_bt709")

        if bakeArchive, let arch = archive, let archURL = binaryArchiveURL {
            try? arch.serialize(to: archURL)
        }
    }

    public func flushCaches() {
        CVMetalTextureCacheFlush(textureCache, 0)
    }

    private func bindTexture2D(
        _ pb: CVPixelBuffer,
        pixelFormat: MTLPixelFormat,
        planeIndex: Int = 0,
        width: Int? = nil,
        height: Int? = nil,
        label: String
    ) throws -> (CVMetalTexture, MTLTexture) {
        let w = width ?? CVPixelBufferGetWidthOfPlane(pb, planeIndex)
        let h = height ?? CVPixelBufferGetHeightOfPlane(pb, planeIndex)
        let resolvedW = w > 0 ? w : CVPixelBufferGetWidth(pb)
        let resolvedH = h > 0 ? h : CVPixelBufferGetHeight(pb)
        var cvTex: CVMetalTexture?
        let st = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, pb, nil, pixelFormat, resolvedW, resolvedH, planeIndex, &cvTex
        )
        guard st == kCVReturnSuccess, let cvTex, let tex = CVMetalTextureGetTexture(cvTex) else {
            throw SafariumError.encode("CVMetalTextureCacheCreateTextureFromImage \(label) failed (\(st))")
        }
        return (cvTex, tex)
    }

    public func bindBGRA8(_ pb: CVPixelBuffer) throws -> (CVMetalTexture, MTLTexture) {
        try bindTexture2D(
            pb, pixelFormat: .bgra8Unorm, planeIndex: 0,
            width: CVPixelBufferGetWidth(pb), height: CVPixelBufferGetHeight(pb), label: "BGRA8"
        )
    }

    public func bindColor(_ pb: CVPixelBuffer) throws -> (CVMetalTexture, MTLTexture) {
        let fmt = CVPixelBufferGetPixelFormatType(pb)
        let mtlFmt: MTLPixelFormat = (fmt == kCVPixelFormatType_64RGBAHalf) ? .rgba16Float : .bgra8Unorm
        return try bindTexture2D(
            pb, pixelFormat: mtlFmt, planeIndex: 0,
            width: CVPixelBufferGetWidth(pb), height: CVPixelBufferGetHeight(pb), label: "color"
        )
    }

    public func bindR8(_ pb: CVPixelBuffer) throws -> (CVMetalTexture, MTLTexture) {
        let fmt = CVPixelBufferGetPixelFormatType(pb)
        let mtlFmt: MTLPixelFormat = (fmt == kCVPixelFormatType_OneComponent32Float) ? .r32Float : .r8Unorm
        return try bindTexture2D(
            pb, pixelFormat: mtlFmt, planeIndex: 0,
            width: CVPixelBufferGetWidth(pb), height: CVPixelBufferGetHeight(pb), label: "mask"
        )
    }

    public func bindFlow(_ pb: CVPixelBuffer) throws -> (CVMetalTexture, MTLTexture) {
        let fmt = CVPixelBufferGetPixelFormatType(pb)
        let mtlFmt: MTLPixelFormat
        switch fmt {
        case kCVPixelFormatType_TwoComponent32Float: mtlFmt = .rg32Float
        case kCVPixelFormatType_TwoComponent16Half: mtlFmt = .rg16Float
        default: mtlFmt = .bgra8Unorm
        }
        return try bindTexture2D(
            pb, pixelFormat: mtlFmt, planeIndex: 0,
            width: CVPixelBufferGetWidth(pb), height: CVPixelBufferGetHeight(pb), label: "flow"
        )
    }

    public func bindNV12Planes(_ pb: CVPixelBuffer) throws -> (yCV: CVMetalTexture, yTex: MTLTexture, uvCV: CVMetalTexture, uvTex: MTLTexture) {
        let w = CVPixelBufferGetWidth(pb)
        let h = CVPixelBufferGetHeight(pb)
        let (yCV, yTex) = try bindTexture2D(pb, pixelFormat: .r8Unorm, planeIndex: 0, width: w, height: h, label: "NV12_Y")
        let (uvCV, uvTex) = try bindTexture2D(pb, pixelFormat: .rg8Unorm, planeIndex: 1, width: max(1, w / 2), height: max(1, h / 2), label: "NV12_UV")
        return (yCV, yTex, uvCV, uvTex)
    }

    public func uploadCGImageToTexture(_ cg: CGImage) throws -> MTLTexture {
        let w = cg.width, h = cg.height
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        desc.storageMode = .shared
        desc.usage = [.shaderRead]
        guard let tex = device.makeTexture(descriptor: desc) else {
            throw SafariumError.encode("makeTexture \(w)x\(h) failed")
        }
        var raw = [UInt8](repeating: 0, count: w * h * 4)
        try raw.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(
                data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                space: Snapshot.colorSpace, bitmapInfo: Snapshot.bitmapInfo
            ) else {
                throw SafariumError.snapshot("CGContext upload failed")
            }
            ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            tex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: buf.baseAddress!, bytesPerRow: w * 4)
        }
        return tex
    }

    private func threadgroups(for pipeline: MTLComputePipelineState, width: Int, height: Int) -> (MTLSize, MTLSize) {
        let tw = max(1, pipeline.threadExecutionWidth)
        let th = max(1, pipeline.maxTotalThreadsPerThreadgroup / tw)
        return (
            MTLSize(width: (width + tw - 1) / tw, height: (height + th - 1) / th, depth: 1),
            MTLSize(width: tw, height: th, depth: 1)
        )
    }

    private func ensureScratch(width: Int, height: Int, needRGBA16: Bool = false) throws {
        if scratchW != width || scratchH != height || scratchBGRA8TexA == nil || scratchBGRA8TexB == nil {
            func mk(_ fmt: MTLPixelFormat) throws -> MTLTexture {
                let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: fmt, width: width, height: height, mipmapped: false)
                d.storageMode = .private
                d.usage = [.shaderRead, .shaderWrite]
                guard let t = device.makeTexture(descriptor: d) else {
                    throw SafariumError.encode("scratch MTLTexture \(width)x\(height) alloc failed")
                }
                return t
            }
            scratchBGRA8TexA = try mk(.bgra8Unorm)
            scratchBGRA8TexB = try mk(.bgra8Unorm)
            scratchRGBA16Tex = needRGBA16 ? try mk(.rgba16Float) : nil
            scratchW = width
            scratchH = height
        } else if needRGBA16 && scratchRGBA16Tex == nil {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
            d.storageMode = .private
            d.usage = [.shaderRead, .shaderWrite]
            scratchRGBA16Tex = device.makeTexture(descriptor: d)
        }
    }

    private func runSingleCommand(_ encode: (MTLCommandBuffer) throws -> Void) throws {
        guard let cmd = commandQueue.makeCommandBuffer() else {
            throw SafariumError.encode("MTLCommandBuffer creation failed")
        }
        try encode(cmd)
        cmd.commit()
        cmd.waitUntilCompleted()
        flushCaches()
        if let err = cmd.error {
            throw SafariumError.encode("Metal filter execution failed: \(err)")
        }
    }

    // MARK: - Filter Entrypoints (CVPixelBuffer -> CVPixelBuffer)

    public func fillSolid(colorRGBA: SIMD4<Float>, into dstPB: CVPixelBuffer) throws {
        let w = CVPixelBufferGetWidth(dstPB), h = CVPixelBufferGetHeight(dstPB)
        let (dstCV, dstTex) = try bindBGRA8(dstPB)
        try runSingleCommand { cmd in
            guard let enc = cmd.makeComputeCommandEncoder() else {
                throw SafariumError.encode("compute encoder failed")
            }
            var c = colorRGBA
            let (g, t) = threadgroups(for: pSolidFill, width: w, height: h)
            enc.setComputePipelineState(pSolidFill)
            enc.setTexture(dstTex, index: 0)
            enc.setBytes(&c, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
            enc.dispatchThreadgroups(g, threadsPerThreadgroup: t)
            enc.endEncoding()
        }
        _ = dstCV
    }

    public func applyGeom(
        srcPB: CVPixelBuffer,
        into dstPB: CVPixelBuffer,
        cropRect: CGRect? = nil,
        dstRect: CGRect? = nil,
        rotateDegrees: Double = 0,
        hflip: Bool = false,
        vflip: Bool = false,
        bgColor: SIMD4<Float> = SIMD4<Float>(0, 0, 0, 1)
    ) throws {
        let sw = CVPixelBufferGetWidth(srcPB), sh = CVPixelBufferGetHeight(srcPB)
        let dw = CVPixelBufferGetWidth(dstPB), dh = CVPixelBufferGetHeight(dstPB)
        let crop = cropRect ?? CGRect(x: 0, y: 0, width: sw, height: sh)
        let dst = dstRect ?? CGRect(x: 0, y: 0, width: dw, height: dh)
        let rad = Float(rotateDegrees * .pi / 180.0)
        var uni = GeomUniforms(
            srcSize: SIMD2<UInt32>(UInt32(sw), UInt32(sh)),
            dstSize: SIMD2<UInt32>(UInt32(dw), UInt32(dh)),
            cropOrigin: SIMD2<Float>(Float(crop.origin.x), Float(crop.origin.y)),
            cropSize: SIMD2<Float>(Float(max(1, crop.width)), Float(max(1, crop.height))),
            dstOrigin: SIMD2<Float>(Float(dst.origin.x), Float(dst.origin.y)),
            dstRectSize: SIMD2<Float>(Float(max(1, dst.width)), Float(max(1, dst.height))),
            cosTheta: cosf(rad),
            sinTheta: sinf(rad),
            hflip: hflip ? 1 : 0,
            vflip: vflip ? 1 : 0,
            bgColor: bgColor
        )
        let (srcCV, srcTex) = try bindBGRA8(srcPB)
        let (dstCV, dstTex) = try bindBGRA8(dstPB)
        try runSingleCommand { cmd in
            guard let enc = cmd.makeComputeCommandEncoder() else { throw SafariumError.encode("encoder failed") }
            let (g, t) = threadgroups(for: pGeom, width: dw, height: dh)
            enc.setComputePipelineState(pGeom)
            enc.setTexture(srcTex, index: 0)
            enc.setTexture(dstTex, index: 1)
            enc.setBytes(&uni, length: MemoryLayout<GeomUniforms>.stride, index: 0)
            enc.dispatchThreadgroups(g, threadsPerThreadgroup: t)
            enc.endEncoding()
        }
        _ = (srcCV, dstCV)
    }

    public func applyDeinterlace(
        prevPB: CVPixelBuffer?,
        currPB: CVPixelBuffer,
        nextPB: CVPixelBuffer?,
        into dstPB: CVPixelBuffer,
        fieldOrder: ForgeFieldOrder = .topFirst,
        parity: Int = 0,
        motionThreshold: Float = 0.08
    ) throws {
        let w = CVPixelBufferGetWidth(currPB), h = CVPixelBufferGetHeight(currPB)
        let (currCV, currTex) = try bindBGRA8(currPB)
        let prevBind = try prevPB.map { try bindBGRA8($0) }
        let nextBind = try nextPB.map { try bindBGRA8($0) }
        let (dstCV, dstTex) = try bindBGRA8(dstPB)
        var uni = DeinterlaceUniforms(
            size: SIMD2<UInt32>(UInt32(w), UInt32(h)),
            fieldOrder: fieldOrder.rawValue,
            parity: UInt32(parity & 1),
            motionThreshold: max(0.01, motionThreshold)
        )
        try runSingleCommand { cmd in
            guard let enc = cmd.makeComputeCommandEncoder() else { throw SafariumError.encode("encoder failed") }
            let (g, t) = threadgroups(for: pDeinterlace, width: w, height: h)
            enc.setComputePipelineState(pDeinterlace)
            enc.setTexture(prevBind?.1 ?? currTex, index: 0)
            enc.setTexture(currTex, index: 1)
            enc.setTexture(nextBind?.1 ?? currTex, index: 2)
            enc.setTexture(dstTex, index: 3)
            enc.setBytes(&uni, length: MemoryLayout<DeinterlaceUniforms>.stride, index: 0)
            enc.dispatchThreadgroups(g, threadsPerThreadgroup: t)
            enc.endEncoding()
        }
        _ = (currCV, prevBind, nextBind, dstCV)
    }

    public func applyKenBurns(
        srcPB: CVPixelBuffer,
        into dstPB: CVPixelBuffer,
        centerNorm: SIMD2<Float>,
        zoom: Float,
        bicubic: Bool = true
    ) throws {
        let sw = CVPixelBufferGetWidth(srcPB), sh = CVPixelBufferGetHeight(srcPB)
        let dw = CVPixelBufferGetWidth(dstPB), dh = CVPixelBufferGetHeight(dstPB)
        let (srcCV, srcTex) = try bindBGRA8(srcPB)
        let (dstCV, dstTex) = try bindBGRA8(dstPB)
        var uni = KenBurnsUniforms(
            srcSize: SIMD2<UInt32>(UInt32(sw), UInt32(sh)),
            dstSize: SIMD2<UInt32>(UInt32(dw), UInt32(dh)),
            centerNorm: centerNorm,
            zoom: max(1.0, zoom),
            bicubic: bicubic ? 1 : 0
        )
        try runSingleCommand { cmd in
            guard let enc = cmd.makeComputeCommandEncoder() else { throw SafariumError.encode("encoder failed") }
            let (g, t) = threadgroups(for: pKenBurns, width: dw, height: dh)
            enc.setComputePipelineState(pKenBurns)
            enc.setTexture(srcTex, index: 0)
            enc.setTexture(dstTex, index: 1)
            enc.setBytes(&uni, length: MemoryLayout<KenBurnsUniforms>.stride, index: 0)
            enc.dispatchThreadgroups(g, threadsPerThreadgroup: t)
            enc.endEncoding()
        }
        _ = (srcCV, dstCV)
    }

    public func applyChromaKey(
        srcPB: CVPixelBuffer,
        into dstPB: CVPixelBuffer,
        keyRGB: SIMD3<Float> = SIMD3<Float>(0, 1, 0),
        similarity: Float = 0.14,
        smoothness: Float = 0.08,
        despillStrength: Float = 0.85,
        erodeRadius: Int = 1
    ) throws {
        let w = CVPixelBufferGetWidth(srcPB), h = CVPixelBufferGetHeight(srcPB)
        try ensureScratch(width: w, height: h, needRGBA16: true)
        guard let tmpA = scratchRGBA16Tex, let tmpB = scratchBGRA8TexB else {
            throw SafariumError.encode("chromaKey scratch unavailable")
        }
        let (srcCV, srcTex) = try bindBGRA8(srcPB)
        let (dstCV, dstTex) = try bindBGRA8(dstPB)
        var uni = ChromaKeyUniforms(
            size: SIMD2<UInt32>(UInt32(w), UInt32(h)),
            keyRGB: SIMD4<Float>(keyRGB.x, keyRGB.y, keyRGB.z, 1.0),
            similarity: max(0.005, similarity),
            smoothness: max(0.005, smoothness),
            despillStrength: max(0.0, min(1.5, despillStrength)),
            erodeRadius: Int32(max(0, min(8, erodeRadius)))
        )
        try runSingleCommand { cmd in
            guard let enc = cmd.makeComputeCommandEncoder() else { throw SafariumError.encode("encoder failed") }
            let (g, t) = threadgroups(for: pChromaMatte, width: w, height: h)
            enc.setComputePipelineState(pChromaMatte)
            enc.setTexture(srcTex, index: 0)
            enc.setTexture(tmpA, index: 1)
            enc.setBytes(&uni, length: MemoryLayout<ChromaKeyUniforms>.stride, index: 0)
            enc.dispatchThreadgroups(g, threadsPerThreadgroup: t)
            enc.memoryBarrier(scope: .textures)

            enc.setComputePipelineState(pDiskErodeAlpha)
            enc.setTexture(tmpA, index: 0)
            enc.setTexture(tmpB, index: 1)
            enc.setBytes(&uni, length: MemoryLayout<ChromaKeyUniforms>.stride, index: 0)
            enc.dispatchThreadgroups(g, threadsPerThreadgroup: t)
            enc.memoryBarrier(scope: .textures)

            enc.setComputePipelineState(pChromaDespill)
            enc.setTexture(tmpB, index: 0)
            enc.setTexture(dstTex, index: 1)
            enc.setBytes(&uni, length: MemoryLayout<ChromaKeyUniforms>.stride, index: 0)
            enc.dispatchThreadgroups(g, threadsPerThreadgroup: t)
            enc.endEncoding()
        }
        _ = (srcCV, dstCV)
    }

    public func applyGaussianBlur(srcPB: CVPixelBuffer, into dstPB: CVPixelBuffer, sigma: Float) throws {
        let w = CVPixelBufferGetWidth(srcPB), h = CVPixelBufferGetHeight(srcPB)
        if sigma < 0.05 {
            try applyGeom(srcPB: srcPB, into: dstPB)
            return
        }
        try ensureScratch(width: w, height: h)
        guard let tmpA = scratchBGRA8TexA else { throw SafariumError.encode("gblur scratch unavailable") }
        let (srcCV, srcTex) = try bindBGRA8(srcPB)
        let (dstCV, dstTex) = try bindBGRA8(dstPB)
        let clampedSigma = min(40.0, max(0.1, sigma))
        let radius = Int32(min(64, max(1, Int(ceil(3.0 * clampedSigma)))))
        var uni = BlurUniforms(
            size: SIMD2<UInt32>(UInt32(w), UInt32(h)),
            radius: radius,
            inv2Sigma2: 0.5 / (clampedSigma * clampedSigma)
        )
        try runSingleCommand { cmd in
            guard let enc = cmd.makeComputeCommandEncoder() else { throw SafariumError.encode("encoder failed") }
            let (g, t) = threadgroups(for: pGBlurH, width: w, height: h)
            enc.setComputePipelineState(pGBlurH)
            enc.setTexture(srcTex, index: 0)
            enc.setTexture(tmpA, index: 1)
            enc.setBytes(&uni, length: MemoryLayout<BlurUniforms>.stride, index: 0)
            enc.dispatchThreadgroups(g, threadsPerThreadgroup: t)
            enc.memoryBarrier(scope: .textures)

            enc.setComputePipelineState(pGBlurV)
            enc.setTexture(tmpA, index: 0)
            enc.setTexture(dstTex, index: 1)
            enc.setBytes(&uni, length: MemoryLayout<BlurUniforms>.stride, index: 0)
            enc.dispatchThreadgroups(g, threadsPerThreadgroup: t)
            enc.endEncoding()
        }
        _ = (srcCV, dstCV)
    }

    public func applyColorGrade(
        srcPB: CVPixelBuffer,
        into dstPB: CVPixelBuffer,
        brightness: Float = 0,
        contrast: Float = 1,
        saturation: Float = 1,
        gamma: Float = 1,
        grayscale: Float = 0
    ) throws {
        let w = CVPixelBufferGetWidth(srcPB), h = CVPixelBufferGetHeight(srcPB)
        let (srcCV, srcTex) = try bindBGRA8(srcPB)
        let (dstCV, dstTex) = try bindBGRA8(dstPB)
        var uni = ColorGradeUniforms(
            size: SIMD2<UInt32>(UInt32(w), UInt32(h)),
            brightness: brightness,
            contrast: contrast,
            saturation: saturation,
            gamma: max(0.05, gamma),
            grayscale: max(0.0, min(1.0, grayscale))
        )
        try runSingleCommand { cmd in
            guard let enc = cmd.makeComputeCommandEncoder() else { throw SafariumError.encode("encoder failed") }
            let (g, t) = threadgroups(for: pColorGrade, width: w, height: h)
            enc.setComputePipelineState(pColorGrade)
            enc.setTexture(srcTex, index: 0)
            enc.setTexture(dstTex, index: 1)
            enc.setBytes(&uni, length: MemoryLayout<ColorGradeUniforms>.stride, index: 0)
            enc.dispatchThreadgroups(g, threadsPerThreadgroup: t)
            enc.endEncoding()
        }
        _ = (srcCV, dstCV)
    }

    public func applyLUT3D(
        srcPB: CVPixelBuffer,
        into dstPB: CVPixelBuffer,
        lutTexture: MTLTexture,
        lut: ForgeCubeLUT,
        intensity: Float = 1.0
    ) throws {
        let w = CVPixelBufferGetWidth(srcPB), h = CVPixelBufferGetHeight(srcPB)
        let (srcCV, srcTex) = try bindBGRA8(srcPB)
        let (dstCV, dstTex) = try bindBGRA8(dstPB)
        var uni = LUT3DUniforms(
            size: SIMD2<UInt32>(UInt32(w), UInt32(h)),
            intensity: max(0.0, min(1.0, intensity)),
            lutSize: Float(lut.size),
            domainMin: SIMD4<Float>(lut.domainMin.x, lut.domainMin.y, lut.domainMin.z, 0),
            domainMax: SIMD4<Float>(lut.domainMax.x, lut.domainMax.y, lut.domainMax.z, 1)
        )
        try runSingleCommand { cmd in
            guard let enc = cmd.makeComputeCommandEncoder() else { throw SafariumError.encode("encoder failed") }
            let (g, t) = threadgroups(for: pLUT3D, width: w, height: h)
            enc.setComputePipelineState(pLUT3D)
            enc.setTexture(srcTex, index: 0)
            enc.setTexture(lutTexture, index: 1)
            enc.setTexture(dstTex, index: 2)
            enc.setBytes(&uni, length: MemoryLayout<LUT3DUniforms>.stride, index: 0)
            enc.dispatchThreadgroups(g, threadsPerThreadgroup: t)
            enc.endEncoding()
        }
        _ = (srcCV, dstCV)
    }

    public func applyVignette(
        srcPB: CVPixelBuffer,
        into dstPB: CVPixelBuffer,
        intensity: Float = 0.5,
        radius: Float = 0.75,
        softness: Float = 0.55
    ) throws {
        let w = CVPixelBufferGetWidth(srcPB), h = CVPixelBufferGetHeight(srcPB)
        let (srcCV, srcTex) = try bindBGRA8(srcPB)
        let (dstCV, dstTex) = try bindBGRA8(dstPB)
        var uni = VignetteUniforms(
            size: SIMD2<UInt32>(UInt32(w), UInt32(h)),
            intensity: intensity,
            radius: radius,
            softness: softness
        )
        try runSingleCommand { cmd in
            guard let enc = cmd.makeComputeCommandEncoder() else { throw SafariumError.encode("encoder failed") }
            let (g, t) = threadgroups(for: pVignette, width: w, height: h)
            enc.setComputePipelineState(pVignette)
            enc.setTexture(srcTex, index: 0)
            enc.setTexture(dstTex, index: 1)
            enc.setBytes(&uni, length: MemoryLayout<VignetteUniforms>.stride, index: 0)
            enc.dispatchThreadgroups(g, threadsPerThreadgroup: t)
            enc.endEncoding()
        }
        _ = (srcCV, dstCV)
    }

    public func applyGrain(
        srcPB: CVPixelBuffer,
        into dstPB: CVPixelBuffer,
        amount: Float = 0.04,
        grainSize: Float = 1.0,
        frameSeed: UInt32 = 0
    ) throws {
        let w = CVPixelBufferGetWidth(srcPB), h = CVPixelBufferGetHeight(srcPB)
        let (srcCV, srcTex) = try bindBGRA8(srcPB)
        let (dstCV, dstTex) = try bindBGRA8(dstPB)
        var uni = GrainUniforms(
            size: SIMD2<UInt32>(UInt32(w), UInt32(h)),
            amount: max(0, amount),
            grainSize: max(1, grainSize),
            frameSeed: frameSeed
        )
        try runSingleCommand { cmd in
            guard let enc = cmd.makeComputeCommandEncoder() else { throw SafariumError.encode("encoder failed") }
            let (g, t) = threadgroups(for: pGrain, width: w, height: h)
            enc.setComputePipelineState(pGrain)
            enc.setTexture(srcTex, index: 0)
            enc.setTexture(dstTex, index: 1)
            enc.setBytes(&uni, length: MemoryLayout<GrainUniforms>.stride, index: 0)
            enc.dispatchThreadgroups(g, threadsPerThreadgroup: t)
            enc.endEncoding()
        }
        _ = (srcCV, dstCV)
    }

    public func applyOverlay(
        basePB: CVPixelBuffer,
        overTex: MTLTexture,
        into dstPB: CVPixelBuffer,
        origin: SIMD2<Float> = .zero,
        scale: Float = 1.0,
        opacity: Float = 1.0,
        blendMode: ForgeBlendMode = .normal
    ) throws {
        let w = CVPixelBufferGetWidth(basePB), h = CVPixelBufferGetHeight(basePB)
        let (baseCV, baseTex) = try bindBGRA8(basePB)
        let (dstCV, dstTex) = try bindBGRA8(dstPB)
        var uni = OverlayBlendUniforms(
            canvasSize: SIMD2<UInt32>(UInt32(w), UInt32(h)),
            ovSize: SIMD2<UInt32>(UInt32(overTex.width), UInt32(overTex.height)),
            origin: origin,
            scale: scale,
            opacity: max(0.0, min(1.0, opacity)),
            blendMode: blendMode.rawValue
        )
        try runSingleCommand { cmd in
            guard let enc = cmd.makeComputeCommandEncoder() else { throw SafariumError.encode("encoder failed") }
            let (g, t) = threadgroups(for: pOverlayBlend, width: w, height: h)
            enc.setComputePipelineState(pOverlayBlend)
            enc.setTexture(baseTex, index: 0)
            enc.setTexture(overTex, index: 1)
            enc.setTexture(dstTex, index: 2)
            enc.setBytes(&uni, length: MemoryLayout<OverlayBlendUniforms>.stride, index: 0)
            enc.dispatchThreadgroups(g, threadsPerThreadgroup: t)
            enc.endEncoding()
        }
        _ = (baseCV, dstCV)
    }

    public func applyOverlay(
        basePB: CVPixelBuffer,
        overPB: CVPixelBuffer,
        into dstPB: CVPixelBuffer,
        origin: SIMD2<Float> = .zero,
        scale: Float = 1.0,
        opacity: Float = 1.0,
        blendMode: ForgeBlendMode = .normal
    ) throws {
        let (overCV, overTex) = try bindBGRA8(overPB)
        try applyOverlay(basePB: basePB, overTex: overTex, into: dstPB, origin: origin, scale: scale, opacity: opacity, blendMode: blendMode)
        _ = overCV
    }

    public func applyXfade(
        pbA: CVPixelBuffer,
        pbB: CVPixelBuffer,
        into dstPB: CVPixelBuffer,
        progress: Float,
        transition: ForgeXfadeTransition = .fade
    ) throws {
        let w = CVPixelBufferGetWidth(dstPB), h = CVPixelBufferGetHeight(dstPB)
        let (aCV, aTex) = try bindBGRA8(pbA)
        let (bCV, bTex) = try bindBGRA8(pbB)
        let (dstCV, dstTex) = try bindBGRA8(dstPB)
        var uni = XfadeUniforms(
            size: SIMD2<UInt32>(UInt32(w), UInt32(h)),
            progress: max(0.0, min(1.0, progress)),
            transition: transition.rawValue
        )
        try runSingleCommand { cmd in
            guard let enc = cmd.makeComputeCommandEncoder() else { throw SafariumError.encode("encoder failed") }
            let (g, t) = threadgroups(for: pXfade, width: w, height: h)
            enc.setComputePipelineState(pXfade)
            enc.setTexture(aTex, index: 0)
            enc.setTexture(bTex, index: 1)
            enc.setTexture(dstTex, index: 2)
            enc.setBytes(&uni, length: MemoryLayout<XfadeUniforms>.stride, index: 0)
            enc.dispatchThreadgroups(g, threadsPerThreadgroup: t)
            enc.endEncoding()
        }
        _ = (aCV, bCV, dstCV)
    }

    public func applyStack(
        inputs: [CVPixelBuffer],
        into dstPB: CVPixelBuffer,
        horizontal: Bool,
        padding: Int = 0,
        bgColor: SIMD4<Float> = SIMD4<Float>(0, 0, 0, 1)
    ) throws {
        guard !inputs.isEmpty else {
            throw SafariumError.invalidState("stack requires at least 1 input")
        }
        let dw = CVPixelBufferGetWidth(dstPB), dh = CVPixelBufferGetHeight(dstPB)
        let pad = max(0, padding)
        let count = inputs.count

        try ensureScratch(width: dw, height: dh)
        guard let scratchA = scratchBGRA8TexA, let scratchB = scratchBGRA8TexB else {
            throw SafariumError.encode("stack scratch textures unavailable")
        }

        let (dstCV, dstTex) = try bindBGRA8(dstPB)

        let cellW = horizontal ? max(1, (dw - pad * (count + 1)) / count) : max(1, dw - 2 * pad)
        let cellH = horizontal ? max(1, dh - 2 * pad) : max(1, (dh - pad * (count + 1)) / count)

        try runSingleCommand { cmd in
            guard let enc = cmd.makeComputeCommandEncoder() else { throw SafariumError.encode("encoder failed") }
            var currentBase: MTLTexture = (count % 2 == 0) ? dstTex : scratchA
            var bg = bgColor
            let (fg, ft) = threadgroups(for: pSolidFill, width: dw, height: dh)
            enc.setComputePipelineState(pSolidFill)
            enc.setTexture(currentBase, index: 0)
            enc.setBytes(&bg, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
            enc.dispatchThreadgroups(fg, threadsPerThreadgroup: ft)
            enc.memoryBarrier(scope: .textures)

            for (idx, inPB) in inputs.enumerated() {
                let sw = CVPixelBufferGetWidth(inPB), sh = CVPixelBufferGetHeight(inPB)
                let (inCV, inTex) = try bindBGRA8(inPB)
                let isLast = (idx == count - 1)
                let nextDst: MTLTexture = isLast ? dstTex : (currentBase === scratchA ? scratchB : scratchA)

                let ox = horizontal ? (pad + idx * (cellW + pad)) : pad
                let oy = horizontal ? pad : (pad + idx * (cellH + pad))

                let scale = min(Float(cellW) / Float(max(1, sw)), Float(cellH) / Float(max(1, sh)))
                let drawW = Float(sw) * scale
                let drawH = Float(sh) * scale
                let posX = Float(ox) + 0.5 * (Float(cellW) - drawW)
                let posY = Float(oy) + 0.5 * (Float(cellH) - drawH)

                var uni = OverlayBlendUniforms(
                    canvasSize: SIMD2<UInt32>(UInt32(dw), UInt32(dh)),
                    ovSize: SIMD2<UInt32>(UInt32(sw), UInt32(sh)),
                    origin: SIMD2<Float>(posX, posY),
                    scale: scale,
                    opacity: 1.0,
                    blendMode: ForgeBlendMode.normal.rawValue
                )
                let (g, t) = threadgroups(for: pOverlayBlend, width: dw, height: dh)
                enc.setComputePipelineState(pOverlayBlend)
                enc.setTexture(currentBase, index: 0)
                enc.setTexture(inTex, index: 1)
                enc.setTexture(nextDst, index: 2)
                enc.setBytes(&uni, length: MemoryLayout<OverlayBlendUniforms>.stride, index: 0)
                enc.dispatchThreadgroups(g, threadsPerThreadgroup: t)
                enc.memoryBarrier(scope: .textures)
                currentBase = nextDst
                _ = inCV
            }
            enc.endEncoding()
        }
        _ = dstCV
    }

    public func applyMatteEMAAndComposite(
        srcPB: CVPixelBuffer,
        rawMaskPB: CVPixelBuffer,
        prevMaskTex: MTLTexture?,
        outMaskTex: MTLTexture,
        bgTex: MTLTexture? = nil,
        bgColor: SIMD4<Float> = SIMD4<Float>(0, 0, 0, 0),
        emaAlpha: Float = 0.35,
        maskOnly: Bool = false,
        into dstPB: CVPixelBuffer
    ) throws {
        let w = CVPixelBufferGetWidth(dstPB), h = CVPixelBufferGetHeight(dstPB)
        let (srcCV, srcTex) = try bindBGRA8(srcPB)
        let (maskCV, maskTex) = try bindR8(rawMaskPB)
        let (dstCV, dstTex) = try bindBGRA8(dstPB)
        var uni = MatteCompositeUniforms(
            size: SIMD2<UInt32>(UInt32(w), UInt32(h)),
            emaAlpha: emaAlpha,
            hasPrevMask: prevMaskTex != nil ? 1 : 0,
            hasBgTex: bgTex != nil ? 1 : 0,
            maskOnly: maskOnly ? 1 : 0,
            bgColor: bgColor
        )
        try runSingleCommand { cmd in
            guard let enc = cmd.makeComputeCommandEncoder() else { throw SafariumError.encode("encoder failed") }
            let (g, t) = threadgroups(for: pMatteEMAAndComposite, width: w, height: h)
            enc.setComputePipelineState(pMatteEMAAndComposite)
            enc.setTexture(srcTex, index: 0)
            enc.setTexture(maskTex, index: 1)
            enc.setTexture(prevMaskTex ?? outMaskTex, index: 2)
            enc.setTexture(bgTex ?? srcTex, index: 3)
            enc.setTexture(outMaskTex, index: 4)
            enc.setTexture(dstTex, index: 5)
            enc.setBytes(&uni, length: MemoryLayout<MatteCompositeUniforms>.stride, index: 0)
            enc.dispatchThreadgroups(g, threadsPerThreadgroup: t)
            enc.endEncoding()
        }
        _ = (srcCV, maskCV, dstCV)
    }

    // MARK: - Wave2MetalEffectsEngine Bridge (with 1x Thai Shield)

    public func applyWave2Effect(_ effect: Wave2EffectKind, srcPB: CVPixelBuffer, into dstPB: CVPixelBuffer) throws {
        guard let w2 = wave2Effects else {
            throw SafariumError.encode("Wave2MetalEffectsEngine unavailable")
        }
        _ = try w2.applyEffect(effect, to: srcPB, into: dstPB)
    }

    public func applySplitMetalFX(backgroundLowResPB: CVPixelBuffer, overlay1xPB: CVPixelBuffer, into dstPB: CVPixelBuffer) throws {
        guard let w2 = wave2Effects else {
            throw SafariumError.encode("Wave2MetalEffectsEngine unavailable")
        }
        try w2.applySplitMetalFX(backgroundHalfRes: backgroundLowResPB, overlay1x: overlay1xPB, into: dstPB)
    }

    // MARK: - Wave 6 Metal Filters: RGBA16F tmix, K.grief, BT.709 NV12 helpers

    private func ensureTMixScratch(width: Int, height: Int) throws -> (MTLTexture, MTLTexture) {
        if tmixW != width || tmixH != height || tmixRGBA16TexA == nil || tmixRGBA16TexB == nil {
            func mk() throws -> MTLTexture {
                let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
                d.storageMode = .private
                d.usage = [.shaderRead, .shaderWrite]
                guard let t = device.makeTexture(descriptor: d) else {
                    throw SafariumError.encode("tmix RGBA16F scratch alloc failed for \(width)x\(height)")
                }
                return t
            }
            tmixRGBA16TexA = try mk()
            tmixRGBA16TexB = try mk()
            tmixW = width
            tmixH = height
        }
        return (tmixRGBA16TexA!, tmixRGBA16TexB!)
    }

    public func encodeSolidFill(colorRGBA: SIMD4<Float>, into dstTex: MTLTexture, commandBuffer: MTLCommandBuffer) throws {
        guard let enc = commandBuffer.makeComputeCommandEncoder() else {
            throw SafariumError.encode("compute encoder failed")
        }
        var c = colorRGBA
        let (g, t) = threadgroups(for: pSolidFill, width: dstTex.width, height: dstTex.height)
        enc.setComputePipelineState(pSolidFill)
        enc.setTexture(dstTex, index: 0)
        enc.setBytes(&c, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        enc.dispatchThreadgroups(g, threadsPerThreadgroup: t)
        enc.endEncoding()
    }

    /// `RGBA16F` multi-frame temporal blending (`tmix` with arbitrary weight window).
    public func applyTMix(
        frames: [CVPixelBuffer],
        weights: [Float]? = nil,
        normalizeWeights: Bool = true,
        into dstPB: CVPixelBuffer
    ) throws {
        guard !frames.isEmpty else {
            throw SafariumError.invalidState("tmix requires at least 1 input frame")
        }
        let w = CVPixelBufferGetWidth(dstPB)
        let h = CVPixelBufferGetHeight(dstPB)
        guard w > 0, h > 0 else {
            throw SafariumError.invalidState("tmix destination has invalid dimensions \(w)x\(h)")
        }
        for (idx, pb) in frames.enumerated() {
            let fw = CVPixelBufferGetWidth(pb), fh = CVPixelBufferGetHeight(pb)
            guard fw == w, fh == h else {
                throw SafariumError.invalidState("tmix frame \(idx) dimensions \(fw)x\(fh) do not match destination \(w)x\(h)")
            }
        }

        let resolvedWeights: [Float]
        if let weights {
            guard weights.count == frames.count else {
                throw SafariumError.invalidState("tmix weights count \(weights.count) != frames count \(frames.count)")
            }
            for wt in weights where !wt.isFinite {
                throw SafariumError.invalidState("tmix weights must be finite")
            }
            if normalizeWeights {
                let sum = weights.reduce(Float(0), +)
                guard abs(sum) > 1e-6 else {
                    throw SafariumError.invalidState("tmix weight sum must be non-zero when normalizeWeights=true")
                }
                resolvedWeights = weights.map { $0 / sum }
            } else {
                resolvedWeights = weights
            }
        } else {
            let uniform = 1.0 / Float(frames.count)
            resolvedWeights = Array(repeating: uniform, count: frames.count)
        }

        let (accA, accB) = try ensureTMixScratch(width: w, height: h)
        let boundInputs = try frames.map { try bindColor($0) }
        let (dstCV, dstTex) = try bindColor(dstPB)

        try runSingleCommand { cmd in
            guard let enc = cmd.makeComputeCommandEncoder() else {
                throw SafariumError.encode("tmix compute encoder failed")
            }
            let (g, t) = threadgroups(for: pTMixAccum, width: w, height: h)
            enc.setComputePipelineState(pTMixAccum)
            for idx in 0..<boundInputs.count {
                let accIn = (idx % 2 == 0) ? accA : accB
                let accOut = (idx % 2 == 0) ? accB : accA
                var uni = TMixUniforms(
                    size: SIMD2<UInt32>(UInt32(w), UInt32(h)),
                    weight: resolvedWeights[idx],
                    isFirst: idx == 0 ? 1 : 0,
                    isFinal: idx + 1 == boundInputs.count ? 1 : 0
                )
                enc.setTexture(boundInputs[idx].1, index: 0)
                enc.setTexture(accIn, index: 1)
                enc.setTexture(accOut, index: 2)
                enc.setTexture(dstTex, index: 3)
                enc.setBytes(&uni, length: MemoryLayout<TMixUniforms>.stride, index: 0)
                enc.dispatchThreadgroups(g, threadsPerThreadgroup: t)
                if idx + 1 < boundInputs.count {
                    enc.memoryBarrier(scope: .textures)
                }
            }
            enc.endEncoding()
        }
        _ = (boundInputs, dstCV)
    }

    /// Unified `K.grief` Metal pass: optional optical-flow motion-compensated temporal smoothing + sRGB desaturation/brightness + optional 1x HUD overlay shield.
    public func applyKGrief(
        currPB: CVPixelBuffer,
        prevPB: CVPixelBuffer? = nil,
        flowPB: CVPixelBuffer? = nil,
        hudOverlayPB: CVPixelBuffer? = nil,
        config: ForgeKGriefConfig = .griefOn,
        into dstPB: CVPixelBuffer
    ) throws {
        let w = CVPixelBufferGetWidth(dstPB)
        let h = CVPixelBufferGetHeight(dstPB)
        guard w > 0, h > 0 else {
            throw SafariumError.invalidState("K.grief destination has invalid dimensions \(w)x\(h)")
        }
        let (currCV, currTex) = try bindBGRA8(currPB)
        let prevBind = try prevPB.map { try bindBGRA8($0) }
        let flowBind = try flowPB.map { try bindFlow($0) }
        let hudBind = try hudOverlayPB.map { try bindBGRA8($0) }
        let (dstCV, dstTex) = try bindBGRA8(dstPB)

        var uni = KGriefUniforms(
            size: SIMD2<UInt32>(UInt32(w), UInt32(h)),
            saturation: max(0.0, config.saturation),
            brightness: max(0.0, config.brightness),
            temporalBlend: max(0.0, min(0.95, config.temporalBlend)),
            motionRejection: max(0.0, config.motionRejection),
            flowScale: config.flowScale,
            hasPrev: prevBind != nil ? 1 : 0,
            hasFlow: flowBind != nil ? 1 : 0,
            hasHud: hudBind != nil ? 1 : 0
        )

        try runSingleCommand { cmd in
            guard let enc = cmd.makeComputeCommandEncoder() else {
                throw SafariumError.encode("K.grief compute encoder failed")
            }
            let (g, t) = threadgroups(for: pKGrief, width: w, height: h)
            enc.setComputePipelineState(pKGrief)
            enc.setTexture(currTex, index: 0)
            enc.setTexture(prevBind?.1 ?? currTex, index: 1)
            enc.setTexture(flowBind?.1 ?? currTex, index: 2)
            enc.setTexture(hudBind?.1 ?? currTex, index: 3)
            enc.setTexture(dstTex, index: 4)
            enc.setBytes(&uni, length: MemoryLayout<KGriefUniforms>.stride, index: 0)
            enc.dispatchThreadgroups(g, threadsPerThreadgroup: t)
            enc.endEncoding()
        }
        _ = (currCV, prevBind, flowBind, hudBind, dstCV)
    }

    public func convertBGRAToNV12(_ srcPB: CVPixelBuffer, into nv12PB: CVPixelBuffer) throws {
        let w = CVPixelBufferGetWidth(srcPB), h = CVPixelBufferGetHeight(srcPB)
        let (srcCV, srcTex) = try bindBGRA8(srcPB)
        let planes = try bindNV12Planes(nv12PB)
        try runSingleCommand { cmd in
            guard let enc = cmd.makeComputeCommandEncoder() else {
                throw SafariumError.encode("bgra_to_nv12 encoder failed")
            }
            let (g, t) = threadgroups(for: pBGRAToNV12, width: max(1, (w + 1) / 2), height: max(1, (h + 1) / 2))
            enc.setComputePipelineState(pBGRAToNV12)
            enc.setTexture(srcTex, index: 0)
            enc.setTexture(planes.yTex, index: 1)
            enc.setTexture(planes.uvTex, index: 2)
            enc.dispatchThreadgroups(g, threadsPerThreadgroup: t)
            enc.endEncoding()
        }
        _ = (srcCV, planes)
    }

    public func convertNV12ToBGRA(_ nv12PB: CVPixelBuffer, into dstPB: CVPixelBuffer) throws {
        let w = CVPixelBufferGetWidth(dstPB), h = CVPixelBufferGetHeight(dstPB)
        let planes = try bindNV12Planes(nv12PB)
        let (dstCV, dstTex) = try bindBGRA8(dstPB)
        try runSingleCommand { cmd in
            guard let enc = cmd.makeComputeCommandEncoder() else {
                throw SafariumError.encode("nv12_to_bgra encoder failed")
            }
            let (g, t) = threadgroups(for: pNV12ToBGRA, width: w, height: h)
            enc.setComputePipelineState(pNV12ToBGRA)
            enc.setTexture(planes.yTex, index: 0)
            enc.setTexture(planes.uvTex, index: 1)
            enc.setTexture(dstTex, index: 2)
            enc.dispatchThreadgroups(g, threadsPerThreadgroup: t)
            enc.endEncoding()
        }
        _ = (planes, dstCV)
    }
}

// MARK: - Double/Triple-Buffered Async Metal Execution Helper

private struct ForgeUncheckedSendable<Value>: @unchecked Sendable {
    let value: Value
}

private final class ForgeLockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value
    init(_ value: Value) { self.storage = value }
    func set(_ newValue: Value) { lock.withLock { storage = newValue } }
    func get() -> Value { lock.withLock { storage } }
}

/// Bounded 2..3 slot async Metal command-buffer pipeline overlapping GPU compute/blit with ordered CPU writes.
public final class DoubleBufferedMetalPipeline: @unchecked Sendable {
    public let engine: ForgeMetalFilterEngine
    public let width: Int
    public let height: Int
    public let slotCount: Int

    private let slotBuffers: [CVPixelBuffer]
    private var freeSlots: [Int]
    private let slotSemaphore: DispatchSemaphore
    private let stateLock = NSLock()
    private let consumeQueue = DispatchQueue(label: "safarium.forge.double-buffered-metal")
    private let group = DispatchGroup()
    private let onFrameReady: @Sendable (Int, CVPixelBuffer) throws -> Void

    private var pendingByIndex: [Int: (slotIdx: Int, cvTex: CVMetalTexture, error: Error?)] = [:]
    private var nextDeliverIndex = 0
    private var asyncError: Error?

    public private(set) var framesSubmitted = 0
    public private(set) var framesCompleted = 0
    public private(set) var maxObservedInFlight = 0

    public init(
        engine: ForgeMetalFilterEngine,
        width: Int,
        height: Int,
        slotCount: Int = 2,
        onFrameReady: @escaping @Sendable (Int, CVPixelBuffer) throws -> Void
    ) throws {
        guard width > 0, height > 0 else {
            throw SafariumError.invalidState("DoubleBufferedMetalPipeline requires positive dimensions")
        }
        let clampedSlots = max(2, min(3, slotCount))
        self.engine = engine
        self.width = width
        self.height = height
        self.slotCount = clampedSlots
        self.onFrameReady = onFrameReady
        self.slotSemaphore = DispatchSemaphore(value: clampedSlots)

        var buffers: [CVPixelBuffer] = []
        buffers.reserveCapacity(clampedSlots)
        for _ in 0..<clampedSlots {
            buffers.append(try AVAssetWriterSink.allocateStandalonePixelBuffer(width: width, height: height, pixelFormat: .bgra))
        }
        self.slotBuffers = buffers
        self.freeSlots = Array((0..<clampedSlots).reversed())
    }

    deinit {
        group.wait()
    }

    public func submitFrame(
        index: Int,
        encode: (_ commandBuffer: MTLCommandBuffer, _ dstTexture: MTLTexture) throws -> Void
    ) throws {
        if let err = stateLock.withLock({ asyncError }) { throw err }
        slotSemaphore.wait()

        let slotIdx: Int = stateLock.withLock {
            let idx = freeSlots.removeLast()
            let active = slotCount - freeSlots.count
            if active > maxObservedInFlight { maxObservedInFlight = active }
            return idx
        }
        let pb = slotBuffers[slotIdx]
        let cvTex: CVMetalTexture
        let dstTex: MTLTexture
        let cmd: MTLCommandBuffer
        do {
            (cvTex, dstTex) = try engine.bindBGRA8(pb)
            guard let c = engine.commandQueue.makeCommandBuffer() else {
                throw SafariumError.encode("DoubleBufferedMetalPipeline command buffer creation failed")
            }
            cmd = c
            try encode(cmd, dstTex)
        } catch {
            stateLock.withLock { freeSlots.append(slotIdx) }
            slotSemaphore.signal()
            throw error
        }

        stateLock.withLock { framesSubmitted += 1 }
        group.enter()

        let boxedCV = ForgeUncheckedSendable(value: cvTex)
        let boxedSelf = ForgeUncheckedSendable(value: self)
        cmd.addCompletedHandler { finishedCmd in
            let me = boxedSelf.value
            let err = finishedCmd.error
            me.stateLock.withLock {
                me.pendingByIndex[index] = (slotIdx, boxedCV.value, err)
            }
            me.consumeQueue.async {
                while true {
                    let ready: (Int, Int, CVMetalTexture, Error?)? = me.stateLock.withLock {
                        let expected = me.nextDeliverIndex
                        guard let entry = me.pendingByIndex.removeValue(forKey: expected) else { return nil }
                        me.nextDeliverIndex = expected + 1
                        return (expected, entry.slotIdx, entry.cvTex, entry.error)
                    }
                    guard let (frameIdx, sIdx, holdCV, cmdErr) = ready else { break }
                    defer {
                        _ = holdCV
                        me.stateLock.withLock { me.freeSlots.append(sIdx) }
                        me.slotSemaphore.signal()
                        me.group.leave()
                    }
                    let existingErr = me.stateLock.withLock { me.asyncError }
                    if existingErr != nil { continue }
                    if let cmdErr {
                        me.stateLock.withLock { me.asyncError = cmdErr }
                        continue
                    }
                    do {
                        try me.onFrameReady(frameIdx, me.slotBuffers[sIdx])
                        me.stateLock.withLock { me.framesCompleted += 1 }
                    } catch {
                        me.stateLock.withLock {
                            if me.asyncError == nil { me.asyncError = error }
                        }
                    }
                }
            }
        }
        cmd.commit()
    }

    public func finish() throws {
        group.wait()
        engine.flushCaches()
        if let err = stateLock.withLock({ asyncError }) {
            throw err
        }
    }
}

// MARK: - Opt-In Apple-Silicon LLSR Upscaler + MetalFX Fallback + SafariumPQ 1x Safeguard

public struct ForgeLLSRPolicy: Sendable {
    public var enabled: Bool
    public var minPQScore: Double
    public var minMSSSIM: Double
    public var maxDeltaE00P95: Double
    public var checkThaiOCR: Bool
    public var expectedThaiText: String?

    public init(
        enabled: Bool = false,
        minPQScore: Double = 85.0,
        minMSSSIM: Double = 0.97,
        maxDeltaE00P95: Double = 2.0,
        checkThaiOCR: Bool = false,
        expectedThaiText: String? = nil
    ) {
        self.enabled = enabled
        self.minPQScore = minPQScore
        self.minMSSSIM = minMSSSIM
        self.maxDeltaE00P95 = maxDeltaE00P95
        self.checkThaiOCR = checkThaiOCR
        self.expectedThaiText = expectedThaiText
    }
}

public struct ForgeLLSRUpscaleResult: @unchecked Sendable {
    public let outputPB: CVPixelBuffer
    public let backend: String
    public let usedLLSR: Bool
    public let usedMetalFXFallback: Bool
    public let didFallbackTo1x: Bool
    public let pqReport: SafariumPQReport?
    public let wallMs: Double
}

public final class ForgeLLSRUpscaler {
    private struct LLSRSessionKey: Equatable {
        let inW: Int
        let inH: Int
        let targetW: Int
        let targetH: Int
        let matchedScale: Float
    }

    public let engine: ForgeMetalFilterEngine
    private var pqEngine: SafariumPQEngine?
    private var spatialScaler: MTLFXSpatialScaler?
    private var scalerDims: (inW: Int, inH: Int, outW: Int, outH: Int) = (0, 0, 0, 0)
    private var scalerPrivTex: MTLTexture?

    private var cachedLLSRSession: AnyObject?
    private var endCachedLLSRSession: (() -> Void)?
    public private(set) var llsrSessionCreationCount: Int = 0
    public private(set) var llsrSessionEndCount: Int = 0
    public var hasCachedLLSRSession: Bool { cachedLLSRSession != nil }

    public init(engine: ForgeMetalFilterEngine) throws {
        self.engine = engine
    }

    deinit {
        resetLLSRSession()
    }

    public func resetLLSRSession() {
        if cachedLLSRSession != nil {
            endCachedLLSRSession?()
            llsrSessionEndCount += 1
        }
        cachedLLSRSession = nil
        endCachedLLSRSession = nil
    }

    public static func isHardwareLLSRSupported() -> Bool {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            return VTLowLatencySuperResolutionScalerConfiguration.isSupported
        }
        #endif
        return false
    }

    public static func supportedScaleFactors(frameWidth: Int, frameHeight: Int) -> [Float] {
        guard frameWidth > 0, frameHeight > 0 else { return [] }
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            guard VTLowLatencySuperResolutionScalerConfiguration.isSupported else { return [] }
            return VTLowLatencySuperResolutionScalerConfiguration.supportedScaleFactors(
                frameWidth: frameWidth,
                frameHeight: frameHeight
            )
        }
        #endif
        return []
    }

    private func getPQEngine() throws -> SafariumPQEngine {
        if let pqEngine { return pqEngine }
        let created = try SafariumPQEngine()
        self.pqEngine = created
        return created
    }

    private static func tagBT709Left(_ pb: CVPixelBuffer) {
        CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(pb, kCVImageBufferChromaLocationTopFieldKey, kCVImageBufferChromaLocation_Left, .shouldPropagate)
    }

    #if compiler(>=6.2)
    @available(macOS 26.0, *)
    private final class CachedVTLLSRSession {
        let key: LLSRSessionKey
        let processor: VTFrameProcessor
        let nv12Src: CVPixelBuffer
        let nv12Dst: CVPixelBuffer
        private var ended = false

        init(key: LLSRSessionKey, processor: VTFrameProcessor, nv12Src: CVPixelBuffer, nv12Dst: CVPixelBuffer) {
            self.key = key
            self.processor = processor
            self.nv12Src = nv12Src
            self.nv12Dst = nv12Dst
        }

        func end() {
            guard !ended else { return }
            ended = true
            processor.endSession()
        }

        deinit {
            end()
        }
    }

    @available(macOS 26.0, *)
    private func ensureVTLLSRSession(key: LLSRSessionKey) -> CachedVTLLSRSession? {
        if let existing = cachedLLSRSession as? CachedVTLLSRSession, existing.key == key {
            return existing
        }
        resetLLSRSession()

        let cfg = VTLowLatencySuperResolutionScalerConfiguration(
            frameWidth: key.inW,
            frameHeight: key.inH,
            scaleFactor: key.matchedScale
        )
        let proc = VTFrameProcessor()
        do {
            try proc.startSession(configuration: cfg)
        } catch {
            return nil
        }

        let srcBase: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey as String: key.inW,
            kCVPixelBufferHeightKey as String: key.inH,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        let dstBase: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey as String: key.targetW,
            kCVPixelBufferHeightKey as String: key.targetH,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        var resSrc: CFDictionary?
        var resDst: CFDictionary?
        guard CVPixelBufferCreateResolvedAttributesDictionary(
            kCFAllocatorDefault, [cfg.sourcePixelBufferAttributes as CFDictionary, srcBase as CFDictionary] as CFArray, &resSrc
        ) == kCVReturnSuccess,
              CVPixelBufferCreateResolvedAttributesDictionary(
            kCFAllocatorDefault, [cfg.destinationPixelBufferAttributes as CFDictionary, dstBase as CFDictionary] as CFArray, &resDst
        ) == kCVReturnSuccess else {
            proc.endSession()
            return nil
        }

        var nv12SrcOpt: CVPixelBuffer?
        var nv12DstOpt: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, key.inW, key.inH, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, resSrc, &nv12SrcOpt) == kCVReturnSuccess,
              CVPixelBufferCreate(kCFAllocatorDefault, key.targetW, key.targetH, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, resDst, &nv12DstOpt) == kCVReturnSuccess,
              let nv12Src = nv12SrcOpt, let nv12Dst = nv12DstOpt else {
            proc.endSession()
            return nil
        }
        Self.tagBT709Left(nv12Src)
        Self.tagBT709Left(nv12Dst)

        let session = CachedVTLLSRSession(key: key, processor: proc, nv12Src: nv12Src, nv12Dst: nv12Dst)
        self.cachedLLSRSession = session
        self.endCachedLLSRSession = { [weak session] in session?.end() }
        self.llsrSessionCreationCount += 1
        return session
    }

    @available(macOS 26.0, *)
    private func tryRunVTLLSR(lowResPB: CVPixelBuffer, targetWidth: Int, targetHeight: Int, into outBGRA: CVPixelBuffer) -> Bool {
        guard VTLowLatencySuperResolutionScalerConfiguration.isSupported else { return false }
        let inW = CVPixelBufferGetWidth(lowResPB)
        let inH = CVPixelBufferGetHeight(lowResPB)
        if let minDim = VTLowLatencySuperResolutionScalerConfiguration.minimumDimensions {
            guard inW >= Int(minDim.width), inH >= Int(minDim.height) else { return false }
        }
        if let maxDim = VTLowLatencySuperResolutionScalerConfiguration.maximumDimensions {
            guard inW <= Int(maxDim.width), inH <= Int(maxDim.height) else { return false }
        }

        let scaleX = Float(targetWidth) / Float(max(1, inW))
        let scaleY = Float(targetHeight) / Float(max(1, inH))
        guard abs(scaleX - scaleY) < 0.02 else { return false }
        let scales = VTLowLatencySuperResolutionScalerConfiguration.supportedScaleFactors(frameWidth: inW, frameHeight: inH)
        guard let matchedScale = scales.first(where: { abs($0 - scaleX) < 0.02 }) else {
            return false
        }

        let key = LLSRSessionKey(inW: inW, inH: inH, targetW: targetWidth, targetH: targetHeight, matchedScale: matchedScale)
        guard let session = ensureVTLLSRSession(key: key) else {
            return false
        }

        do {
            try engine.convertBGRAToNV12(lowResPB, into: session.nv12Src)
            let pts = CMTime.zero
            guard let fSrc = VTFrameProcessorFrame(buffer: session.nv12Src, presentationTimeStamp: pts),
                  let fDst = VTFrameProcessorFrame(buffer: session.nv12Dst, presentationTimeStamp: pts) else {
                resetLLSRSession()
                return false
            }
            let params = VTLowLatencySuperResolutionScalerParameters(sourceFrame: fSrc, destinationFrame: fDst)
            let sem = DispatchSemaphore(value: 0)
            let errBox = ForgeLockedBox<Error?>(nil)
            session.processor.process(parameters: params) { _, err in
                errBox.set(err)
                sem.signal()
            }
            sem.wait()
            if errBox.get() != nil {
                resetLLSRSession()
                return false
            }
            try engine.convertNV12ToBGRA(session.nv12Dst, into: outBGRA)
            return true
        } catch {
            resetLLSRSession()
            return false
        }
    }
    #endif

    private func runMetalFXSpatialFallback(lowResPB: CVPixelBuffer, targetWidth: Int, targetHeight: Int, into outBGRA: CVPixelBuffer) throws -> Bool {
        guard MTLFXSpatialScalerDescriptor.supportsDevice(engine.device) else { return false }
        let inW = CVPixelBufferGetWidth(lowResPB)
        let inH = CVPixelBufferGetHeight(lowResPB)
        if spatialScaler == nil || scalerDims != (inW, inH, targetWidth, targetHeight) {
            let sd = MTLFXSpatialScalerDescriptor()
            sd.colorTextureFormat = .bgra8Unorm
            sd.outputTextureFormat = .bgra8Unorm
            sd.inputWidth = inW
            sd.inputHeight = inH
            sd.outputWidth = targetWidth
            sd.outputHeight = targetHeight
            sd.colorProcessingMode = .perceptual
            guard let sc = sd.makeSpatialScaler(device: engine.device) else {
                return false
            }
            let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: targetWidth, height: targetHeight, mipmapped: false)
            td.storageMode = .private
            td.usage = [.shaderRead, .shaderWrite, .renderTarget]
            guard let pTex = engine.device.makeTexture(descriptor: td) else {
                return false
            }
            self.spatialScaler = sc
            self.scalerPrivTex = pTex
            self.scalerDims = (inW, inH, targetWidth, targetHeight)
        }
        guard let sc = spatialScaler, let privTex = scalerPrivTex else { return false }
        let (inCV, inTex) = try engine.bindBGRA8(lowResPB)
        let (outCV, outTex) = try engine.bindBGRA8(outBGRA)
        guard let cmd = engine.commandQueue.makeCommandBuffer() else {
            throw SafariumError.encode("MetalFX fallback command buffer creation failed")
        }
        sc.colorTexture = inTex
        sc.inputContentWidth = inW
        sc.inputContentHeight = inH
        sc.outputTexture = privTex
        sc.encode(commandBuffer: cmd)

        guard let blit = cmd.makeBlitCommandEncoder() else {
            throw SafariumError.encode("MetalFX fallback blit encoder failed")
        }
        blit.copy(
            from: privTex, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: targetWidth, height: targetHeight, depth: 1),
            to: outTex, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )
        blit.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
        _ = (inCV, outCV)
        engine.flushCaches()
        if let err = cmd.error {
            throw SafariumError.encode("MTLFXSpatialScaler fallback execution failed: \(err)")
        }
        return true
    }

    public func upscale(
        lowResPB: CVPixelBuffer,
        targetWidth: Int,
        targetHeight: Int,
        reference1xPB: CVPixelBuffer? = nil,
        overlay1xPB: CVPixelBuffer? = nil,
        policy: ForgeLLSRPolicy = ForgeLLSRPolicy(enabled: true),
        forceFallbackMetalFX: Bool = false
    ) throws -> ForgeLLSRUpscaleResult {
        let t0 = DispatchTime.now().uptimeNanoseconds
        guard targetWidth > 0, targetHeight > 0 else {
            throw SafariumError.invalidState("LLSR target dimensions must be positive")
        }
        let inW = CVPixelBufferGetWidth(lowResPB)
        let inH = CVPixelBufferGetHeight(lowResPB)

        // Opt-in disabled or already >= 1x: never degrade crisp UI/Thai text below 1x.
        if !policy.enabled || (inW >= targetWidth && inH >= targetHeight) {
            let outPB = reference1xPB ?? lowResPB
            let wallMs = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
            return ForgeLLSRUpscaleResult(
                outputPB: outPB, backend: "1x_passthrough",
                usedLLSR: false, usedMetalFXFallback: false, didFallbackTo1x: true,
                pqReport: nil, wallMs: wallMs
            )
        }

        let upscaledPB = try AVAssetWriterSink.allocateStandalonePixelBuffer(width: targetWidth, height: targetHeight, pixelFormat: .bgra)
        var usedLLSR = false
        var usedMetalFX = false
        var backend = "bicubic_fallback"

        #if compiler(>=6.2)
        if !forceFallbackMetalFX, #available(macOS 26.0, *) {
            if tryRunVTLLSR(lowResPB: lowResPB, targetWidth: targetWidth, targetHeight: targetHeight, into: upscaledPB) {
                usedLLSR = true
                backend = "llsr"
            }
        }
        #endif
        if !usedLLSR {
            if try runMetalFXSpatialFallback(lowResPB: lowResPB, targetWidth: targetWidth, targetHeight: targetHeight, into: upscaledPB) {
                usedMetalFX = true
                backend = "metalfx_fallback"
            } else {
                try engine.applyGeom(srcPB: lowResPB, into: upscaledPB)
            }
        }

        var candidatePB = upscaledPB
        if let ovPB = overlay1xPB {
            let compPB = try AVAssetWriterSink.allocateStandalonePixelBuffer(width: targetWidth, height: targetHeight, pixelFormat: .bgra)
            try engine.applyOverlay(basePB: upscaledPB, overPB: ovPB, into: compPB)
            candidatePB = compPB
        }

        var pqReport: SafariumPQReport?
        if let ref1x = reference1xPB {
            let pq = try getPQEngine()
            let rep = try pq.evaluatePair(
                reference: ref1x,
                candidate: candidatePB,
                checkThaiOCR: policy.checkThaiOCR,
                expectedThaiText: policy.expectedThaiText,
                minScore: policy.minPQScore,
                maxDeltaE00P95: policy.maxDeltaE00P95,
                minMSSSIM: policy.minMSSSIM
            )
            pqReport = rep
            if !rep.passed {
                let wallMs = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
                return ForgeLLSRUpscaleResult(
                    outputPB: ref1x, backend: "1x_safeguard_fallback",
                    usedLLSR: usedLLSR, usedMetalFXFallback: usedMetalFX, didFallbackTo1x: true,
                    pqReport: rep, wallMs: wallMs
                )
            }
        }

        let wallMs = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
        return ForgeLLSRUpscaleResult(
            outputPB: candidatePB, backend: backend,
            usedLLSR: usedLLSR, usedMetalFXFallback: usedMetalFX, didFallbackTo1x: false,
            pqReport: pqReport, wallMs: wallMs
        )
    }
}

// MARK: - Bounded Animated WebP / HEICS Pixel Budget Cap Helper

@discardableResult
public func enforceAnimatedImageBudget(
    frameCount: Int,
    width: Int,
    height: Int,
    maxBytes: Int64 = 256 * 1024 * 1024
) throws -> Int64 {
    guard frameCount > 0, width > 0, height > 0, maxBytes > 0 else {
        throw SafariumError.invalidState(
            "animated image budget requires positive frameCount (\(frameCount)), width (\(width)), height (\(height)), and maxBytes (\(maxBytes))"
        )
    }
    let (px, ov1) = Int64(width).multipliedReportingOverflow(by: Int64(height))
    let (perFrameBytes, ov2) = px.multipliedReportingOverflow(by: 4)
    let (totalBytes, ov3) = perFrameBytes.multipliedReportingOverflow(by: Int64(frameCount))
    if ov1 || ov2 || ov3 || totalBytes > maxBytes {
        let estDesc = (ov1 || ov2 || ov3) ? "> Int64.max" : "\(totalBytes)"
        throw SafariumError.invalidState(
            "animated image pixel budget exceeded: \(frameCount) frames x \(width)x\(height) RGBA (~\(estDesc) bytes) > maxBytes \(maxBytes); stream to MP4/MOV or reduce dimensions/frameCount"
        )
    }
    return totalBytes
}

public final class ForgeBoundedAnimatedFrameBudget {
    public let maxBytes: Int64
    public private(set) var accumulatedFrames: Int = 0
    public private(set) var accumulatedBytes: Int64 = 0

    public init(maxBytes: Int64 = 256 * 1024 * 1024) throws {
        guard maxBytes > 0 else {
            throw SafariumError.invalidState("animated image maxBytes budget must be > 0")
        }
        self.maxBytes = maxBytes
    }

    @discardableResult
    public func recordFrame(width: Int, height: Int) throws -> Int64 {
        let frameBytes = try enforceAnimatedImageBudget(frameCount: 1, width: width, height: height, maxBytes: maxBytes)
        let (nextTotal, ov) = accumulatedBytes.addingReportingOverflow(frameBytes)
        if ov || nextTotal > maxBytes {
            throw SafariumError.invalidState(
                "animated image pixel budget exceeded at frame \(accumulatedFrames + 1): accumulated \(nextTotal) bytes > maxBytes \(maxBytes)"
            )
        }
        accumulatedFrames += 1
        accumulatedBytes = nextTotal
        return nextTotal
    }
}
