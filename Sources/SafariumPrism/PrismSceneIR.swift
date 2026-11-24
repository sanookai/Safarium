import CryptoKit
import Foundation
import SafariumCore
import SafariumForgeCore

public enum PrismSensorFit: String, Codable, Sendable, Equatable {
    case auto = "AUTO"
    case horizontal = "HORIZONTAL"
    case vertical = "VERTICAL"

    public static func parse(_ raw: String) -> PrismSensorFit? {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
        case "AUTO": return .auto
        case "HORIZONTAL": return .horizontal
        case "VERTICAL": return .vertical
        default: return nil
        }
    }
}

public struct PrismVec3: Codable, Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var z: Double

    public init(x: Double = 0, y: Double = 0, z: Double = 0) {
        self.x = x
        self.y = y
        self.z = z
    }

    public init(array: [Double]) throws {
        guard array.count >= 3 else {
            throw SafariumError.invalidState("expected 3 elements for PrismVec3, got \(array.count)")
        }
        self.x = array[0]
        self.y = array[1]
        self.z = array[2]
    }

    public var array: [Double] { [x, y, z] }
    public var simd: SIMD3<Double> { SIMD3<Double>(x, y, z) }
}

/// Explicit quaternion representation with `(w, x, y, z)` stored fields and explicit
/// `wxyzArray` (Blender `mathutils.Quaternion`) vs `xyzwArray` (Three.js / glTF) accessors.
public struct PrismQuaternion: Codable, Sendable, Equatable {
    public var w: Double
    public var x: Double
    public var y: Double
    public var z: Double

    public static let identity = PrismQuaternion(w: 1, x: 0, y: 0, z: 0)

    public init(w: Double = 1, x: Double = 0, y: Double = 0, z: Double = 0) {
        self.w = w
        self.x = x
        self.y = y
        self.z = z
    }

    public static func fromWXYZ(_ arr: [Double]) throws -> PrismQuaternion {
        guard arr.count >= 4 else {
            throw SafariumError.invalidState("expected 4 elements for wxyz quaternion, got \(arr.count)")
        }
        return PrismQuaternion(w: arr[0], x: arr[1], y: arr[2], z: arr[3])
    }

    public static func fromXYZW(_ arr: [Double]) throws -> PrismQuaternion {
        guard arr.count >= 4 else {
            throw SafariumError.invalidState("expected 4 elements for xyzw quaternion, got \(arr.count)")
        }
        return PrismQuaternion(w: arr[3], x: arr[0], y: arr[1], z: arr[2])
    }

    public var wxyzArray: [Double] { [w, x, y, z] }
    public var xyzwArray: [Double] { [x, y, z, w] }

    public func normalized() -> PrismQuaternion {
        let len = sqrt(w * w + x * x + y * y + z * z)
        guard len > 1e-15 else { return .identity }
        let inv = 1.0 / len
        return PrismQuaternion(w: w * inv, x: x * inv, y: y * inv, z: z * inv)
    }

    public func conjugated() -> PrismQuaternion {
        PrismQuaternion(w: w, x: -x, y: -y, z: -z)
    }

    public static func * (lhs: PrismQuaternion, rhs: PrismQuaternion) -> PrismQuaternion {
        PrismQuaternion(
            w: lhs.w * rhs.w - lhs.x * rhs.x - lhs.y * rhs.y - lhs.z * rhs.z,
            x: lhs.w * rhs.x + lhs.x * rhs.w + lhs.y * rhs.z - lhs.z * rhs.y,
            y: lhs.w * rhs.y - lhs.x * rhs.z + lhs.y * rhs.w + lhs.z * rhs.x,
            z: lhs.w * rhs.z + lhs.x * rhs.y - lhs.y * rhs.x + lhs.z * rhs.w
        )
    }
}

public struct PrismDepthOfFieldIR: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var focusDistance: Double
    public var fstop: Double

    public init(enabled: Bool = false, focusDistance: Double = 5.0, fstop: Double = 2.8) {
        self.enabled = enabled
        self.focusDistance = focusDistance
        self.fstop = fstop
    }
}

public struct PrismCameraIR: Codable, Sendable, Equatable {
    public var name: String
    public var positionThree: PrismVec3
    public var quaternionThree: PrismQuaternion
    public var lensMM: Double
    public var sensorWidthMM: Double
    public var sensorHeightMM: Double
    public var sensorFit: PrismSensorFit
    public var width: Int
    public var height: Int
    public var pixelAspectX: Double
    public var pixelAspectY: Double
    public var fovYDeg: Double
    public var aspect: Double
    public var near: Double
    public var far: Double
    public var shiftX: Double
    public var shiftY: Double
    public var dof: PrismDepthOfFieldIR?
    public var match2DZoom: Double?

    public init(
        name: String = "Camera",
        positionThree: PrismVec3,
        quaternionThree: PrismQuaternion,
        lensMM: Double = 35.0,
        sensorWidthMM: Double = 36.0,
        sensorHeightMM: Double = 24.0,
        sensorFit: PrismSensorFit = .auto,
        width: Int = 1080,
        height: Int = 1920,
        pixelAspectX: Double = 1.0,
        pixelAspectY: Double = 1.0,
        fovYDeg: Double? = nil,
        aspect: Double? = nil,
        near: Double = 0.1,
        far: Double = 100.0,
        shiftX: Double = 0.0,
        shiftY: Double = 0.0,
        dof: PrismDepthOfFieldIR? = nil,
        match2DZoom: Double? = nil
    ) {
        self.name = name
        self.positionThree = positionThree
        self.quaternionThree = quaternionThree.normalized()
        self.lensMM = lensMM
        self.sensorWidthMM = sensorWidthMM
        self.sensorHeightMM = sensorHeightMM
        self.sensorFit = sensorFit
        self.width = max(1, width)
        self.height = max(1, height)
        self.pixelAspectX = pixelAspectX
        self.pixelAspectY = pixelAspectY
        let computed = PrismCameraTransform.blenderToThreeFOVYDeg(
            lensMM: lensMM,
            sensorWidthMM: sensorWidthMM,
            sensorHeightMM: sensorHeightMM,
            sensorFit: sensorFit,
            width: self.width,
            height: self.height,
            pixelAspectX: pixelAspectX,
            pixelAspectY: pixelAspectY
        )
        self.fovYDeg = fovYDeg ?? computed.fovYDeg
        self.aspect = aspect ?? computed.aspect
        self.near = near
        self.far = far
        self.shiftX = shiftX
        self.shiftY = shiftY
        self.dof = dof
        self.match2DZoom = match2DZoom
    }

    public var positionBlender: PrismVec3 {
        PrismCameraTransform.threePointToBlender(positionThree)
    }

    public var quaternionBlender: PrismQuaternion {
        PrismCameraTransform.threeQuatToBlender(quaternionThree)
    }

    public var blenderLensMM: Double {
        PrismCameraTransform.threeFOVYDegToBlenderLensMM(
            fovYDeg: fovYDeg,
            sensorWidthMM: sensorWidthMM,
            sensorHeightMM: sensorHeightMM,
            sensorFit: sensorFit,
            width: width,
            height: height,
            pixelAspectX: pixelAspectX,
            pixelAspectY: pixelAspectY
        )
    }

    public static func fromBlender(
        name: String = "Camera",
        positionBlender: PrismVec3,
        quaternionBlender: PrismQuaternion,
        lensMM: Double = 35.0,
        sensorWidthMM: Double = 36.0,
        sensorHeightMM: Double = 24.0,
        sensorFit: PrismSensorFit = .auto,
        width: Int = 1080,
        height: Int = 1920,
        pixelAspectX: Double = 1.0,
        pixelAspectY: Double = 1.0,
        near: Double = 0.1,
        far: Double = 100.0,
        shiftX: Double = 0.0,
        shiftY: Double = 0.0,
        dof: PrismDepthOfFieldIR? = nil,
        match2DZoom: Double? = nil
    ) -> PrismCameraIR {
        let pT = PrismCameraTransform.blenderPointToThree(positionBlender)
        let qT = PrismCameraTransform.blenderQuatToThree(quaternionBlender)
        let (fovY, aspect) = PrismCameraTransform.blenderToThreeFOVYDeg(
            lensMM: lensMM,
            sensorWidthMM: sensorWidthMM,
            sensorHeightMM: sensorHeightMM,
            sensorFit: sensorFit,
            width: width,
            height: height,
            pixelAspectX: pixelAspectX,
            pixelAspectY: pixelAspectY
        )
        return PrismCameraIR(
            name: name,
            positionThree: pT,
            quaternionThree: qT,
            lensMM: lensMM,
            sensorWidthMM: sensorWidthMM,
            sensorHeightMM: sensorHeightMM,
            sensorFit: sensorFit,
            width: width,
            height: height,
            pixelAspectX: pixelAspectX,
            pixelAspectY: pixelAspectY,
            fovYDeg: fovY,
            aspect: aspect,
            near: near,
            far: far,
            shiftX: shiftX,
            shiftY: shiftY,
            dof: dof,
            match2DZoom: match2DZoom
        )
    }

    public static func fromThree(
        name: String = "Camera",
        positionThree: PrismVec3,
        quaternionThree: PrismQuaternion,
        fovYDeg: Double,
        width: Int = 1080,
        height: Int = 1920,
        sensorWidthMM: Double = 36.0,
        sensorHeightMM: Double = 24.0,
        sensorFit: PrismSensorFit = .auto,
        near: Double = 0.1,
        far: Double = 100.0,
        shiftX: Double = 0.0,
        shiftY: Double = 0.0,
        dof: PrismDepthOfFieldIR? = nil,
        match2DZoom: Double? = nil
    ) -> PrismCameraIR {
        let lens = PrismCameraTransform.threeFOVYDegToBlenderLensMM(
            fovYDeg: fovYDeg,
            sensorWidthMM: sensorWidthMM,
            sensorHeightMM: sensorHeightMM,
            sensorFit: sensorFit,
            width: width,
            height: height
        )
        let aspect = Double(max(1, width)) / Double(max(1, height))
        return PrismCameraIR(
            name: name,
            positionThree: positionThree,
            quaternionThree: quaternionThree,
            lensMM: lens,
            sensorWidthMM: sensorWidthMM,
            sensorHeightMM: sensorHeightMM,
            sensorFit: sensorFit,
            width: width,
            height: height,
            fovYDeg: fovYDeg,
            aspect: aspect,
            near: near,
            far: far,
            shiftX: shiftX,
            shiftY: shiftY,
            dof: dof,
            match2DZoom: match2DZoom
        )
    }
}

public struct PrismTimelineIR: Codable, Sendable, Equatable {
    public var fps: Double
    public var frameStart: Int
    public var frameEnd: Int
    public var durationSeconds: Double
    public var cuts: [Double]
    public var hitstopFrames: [Int]
    public var storyToVideoTimeScale: Double

    public init(
        fps: Double = 30.0,
        frameStart: Int = 1,
        frameEnd: Int = 30,
        durationSeconds: Double? = nil,
        cuts: [Double] = [],
        hitstopFrames: [Int] = [],
        storyToVideoTimeScale: Double = 1.0
    ) {
        self.fps = max(1.0, fps)
        self.frameStart = frameStart
        self.frameEnd = max(frameStart, frameEnd)
        let count = max(1, self.frameEnd - self.frameStart + 1)
        self.durationSeconds = durationSeconds ?? (Double(count) / self.fps)
        self.cuts = cuts
        self.hitstopFrames = hitstopFrames
        self.storyToVideoTimeScale = storyToVideoTimeScale
    }

    /// Returns `true` when any hard-cut barrier lies in `(min(t0, t1), max(t0, t1)]`.
    public func hasCutBetween(_ t0: Double, _ t1: Double) -> Bool {
        let lo = min(t0, t1)
        let hi = max(t0, t1)
        guard hi > lo else { return false }
        return cuts.contains { $0 > lo + 1e-9 && $0 <= hi + 1e-9 }
    }
}

public struct PrismAnchor2D: Codable, Sendable, Equatable {
    public var name: String
    public var worldPositionThree: PrismVec3
    public var ndcX: Double
    public var ndcY: Double
    public var ndcZ: Double
    public var pixelX: Double
    public var pixelY: Double
    public var visible: Bool

    public init(
        name: String,
        worldPositionThree: PrismVec3,
        ndcX: Double,
        ndcY: Double,
        ndcZ: Double,
        pixelX: Double,
        pixelY: Double,
        visible: Bool
    ) {
        self.name = name
        self.worldPositionThree = worldPositionThree
        self.ndcX = ndcX
        self.ndcY = ndcY
        self.ndcZ = ndcZ
        self.pixelX = pixelX
        self.pixelY = pixelY
        self.visible = visible
    }
}

public struct PrismQualityPolicy: Codable, Sendable, Equatable {
    public var useMetalFX: Bool
    public var scaleFactor: Double
    public var autoVerifyMetalFX: Bool
    public var verifyEveryNFrames: Int
    public var minPQScore: Double
    public var minMSSSIM: Double
    public var maxDeltaE00P95: Double
    public var checkThaiOCR: Bool
    public var expectedThaiText: String?
    public var thaiShield1xOverlay: Bool

    public init(
        useMetalFX: Bool = false,
        scaleFactor: Double = 0.67,
        autoVerifyMetalFX: Bool = true,
        verifyEveryNFrames: Int = 15,
        minPQScore: Double = 85.0,
        minMSSSIM: Double = 0.97,
        maxDeltaE00P95: Double = 2.0,
        checkThaiOCR: Bool = false,
        expectedThaiText: String? = nil,
        thaiShield1xOverlay: Bool = true
    ) {
        self.useMetalFX = useMetalFX
        self.scaleFactor = max(0.25, min(1.0, scaleFactor))
        self.autoVerifyMetalFX = autoVerifyMetalFX
        self.verifyEveryNFrames = max(1, verifyEveryNFrames)
        self.minPQScore = minPQScore
        self.minMSSSIM = minMSSSIM
        self.maxDeltaE00P95 = maxDeltaE00P95
        self.checkThaiOCR = checkThaiOCR
        self.expectedThaiText = expectedThaiText
        self.thaiShield1xOverlay = thaiShield1xOverlay
    }
}

public struct PrismCompositeIR: Codable, Sendable, Equatable {
    public var width: Int
    public var height: Int
    public var fps: Double
    public var backgroundTier: String
    public var heroTransparent: Bool
    public var overlay1xHTMLPath: String?

    public init(
        width: Int = 1080,
        height: Int = 1920,
        fps: Double = 30.0,
        backgroundTier: String = "threejs",
        heroTransparent: Bool = true,
        overlay1xHTMLPath: String? = nil
    ) {
        self.width = width
        self.height = height
        self.fps = fps
        self.backgroundTier = backgroundTier
        self.heroTransparent = heroTransparent
        self.overlay1xHTMLPath = overlay1xHTMLPath
    }
}

public struct PrismSceneIR: Codable, Sendable, Equatable {
    public var schema: String
    public var sceneName: String
    public var blendFilePath: String?
    public var glbFilePath: String?
    public var engine: String
    public var frame: Int
    public var camera: PrismCameraIR
    public var timeline: PrismTimelineIR
    public var anchors: [PrismAnchor2D]
    public var composite: PrismCompositeIR?
    public var qualityPolicy: PrismQualityPolicy

    public init(
        schema: String = SafariumPrismModuleInfo.schema,
        sceneName: String = "Scene",
        blendFilePath: String? = nil,
        glbFilePath: String? = nil,
        engine: String = "BLENDER_EEVEE",
        frame: Int = 1,
        camera: PrismCameraIR,
        timeline: PrismTimelineIR = PrismTimelineIR(),
        anchors: [PrismAnchor2D] = [],
        composite: PrismCompositeIR? = nil,
        qualityPolicy: PrismQualityPolicy = PrismQualityPolicy()
    ) {
        self.schema = schema
        self.sceneName = sceneName
        self.blendFilePath = blendFilePath
        self.glbFilePath = glbFilePath
        self.engine = engine
        self.frame = frame
        self.camera = camera
        self.timeline = timeline
        self.anchors = anchors
        self.composite = composite
        self.qualityPolicy = qualityPolicy
    }

    public func deterministicSHA256() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    public static func load(from url: URL) throws -> PrismSceneIR {
        try SafeFilePublisher.assertRegularReadableFile(url)
        let data = try Data(contentsOf: url)
        let ir = try JSONDecoder().decode(PrismSceneIR.self, from: data)
        guard ir.schema == SafariumPrismModuleInfo.schema else {
            throw SafariumError.invalidState("unexpected PrismSceneIR schema '\(ir.schema)' (expected '\(SafariumPrismModuleInfo.schema)')")
        }
        return ir
    }

    public func save(to url: URL, overwrite: Bool = false) throws {
        let stage = try APFSAutoStage.makeSession(for: url, overwrite: overwrite)
        defer { stage.cleanup() }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(self)
        data.append(0x0A)
        let staged = stage.fileURL("scene-ir.json")
        try data.write(to: staged)
        try stage.commit(stagedFile: staged, to: url, overwrite: overwrite)
    }
}

// MARK: - Bidirectional Blender (Z-up) <-> Three.js / glTF (Y-up) Camera Math

public enum PrismCameraTransform {
    /// Proper SO(3) rotation R_x(-90 deg) in (w, x, y, z): `(cos(-45°), sin(-45°), 0, 0)`.
    public static let qBlenderToThree = PrismQuaternion(w: sqrt(0.5), x: -sqrt(0.5), y: 0, z: 0)
    /// Inverse proper SO(3) rotation R_x(+90 deg) in (w, x, y, z): `(cos(+45°), sin(+45°), 0, 0)`.
    public static let qThreeToBlender = PrismQuaternion(w: sqrt(0.5), x: sqrt(0.5), y: 0, z: 0)

    public static func blenderPointToThree(_ p: PrismVec3) -> PrismVec3 {
        PrismVec3(x: p.x, y: p.z, z: -p.y)
    }

    public static func threePointToBlender(_ p: PrismVec3) -> PrismVec3 {
        PrismVec3(x: p.x, y: -p.z, z: p.y)
    }

    public static func blenderQuatToThree(_ qBlender: PrismQuaternion) -> PrismQuaternion {
        (qBlenderToThree * qBlender.normalized()).normalized()
    }

    public static func threeQuatToBlender(_ qThree: PrismQuaternion) -> PrismQuaternion {
        (qThreeToBlender * qThree.normalized()).normalized()
    }

    public static func eulerXYZToQuat(rx: Double, ry: Double, rz: Double) -> PrismQuaternion {
        let cx = cos(rx * 0.5), sx = sin(rx * 0.5)
        let cy = cos(ry * 0.5), sy = sin(ry * 0.5)
        let cz = cos(rz * 0.5), sz = sin(rz * 0.5)
        return PrismQuaternion(
            w: cx * cy * cz + sx * sy * sz,
            x: sx * cy * cz - cx * sy * sz,
            y: cx * sy * cz + sx * cy * sz,
            z: cx * cy * sz - sx * sy * cz
        ).normalized()
    }

    public static func quatToMat3(_ q: PrismQuaternion) -> [[Double]] {
        let n = q.normalized()
        let w = n.w, x = n.x, y = n.y, z = n.z
        return [
            [1.0 - 2.0 * (y * y + z * z), 2.0 * (x * y - w * z), 2.0 * (x * z + w * y)],
            [2.0 * (x * y + w * z), 1.0 - 2.0 * (x * x + z * z), 2.0 * (y * z - w * x)],
            [2.0 * (x * z - w * y), 2.0 * (y * z + w * x), 1.0 - 2.0 * (x * x + y * y)],
        ]
    }

    public static func quatToEulerXYZ(_ q: PrismQuaternion) -> (rx: Double, ry: Double, rz: Double) {
        let m = quatToMat3(q)
        let sy = max(-1.0, min(1.0, -m[2][0]))
        let ry = asin(sy)
        if abs(abs(sy) - 1.0) > 1e-9 {
            let rx = atan2(m[2][1], m[2][2])
            let rz = atan2(m[1][0], m[0][0])
            return (rx, ry, rz)
        } else {
            let rx = atan2(-m[1][2], m[1][1])
            return (rx, ry, 0.0)
        }
    }

    /// Computes effective vertical sensor size in mm, resolving Blender's portrait `AUTO` trap
    /// (where `AUTO` fits `sensor_width` along height whenever `aspect < 1.0`).
    public static func effectiveVerticalSensorMM(
        sensorWidthMM: Double,
        sensorHeightMM: Double,
        sensorFit: PrismSensorFit,
        width: Int,
        height: Int,
        pixelAspectX: Double = 1.0,
        pixelAspectY: Double = 1.0
    ) -> (sensorVerticalMM: Double, aspect: Double) {
        let safeW = max(1.0, Double(width) * max(1e-6, pixelAspectX))
        let safeH = max(1.0, Double(height) * max(1e-6, pixelAspectY))
        let aspect = safeW / safeH
        switch sensorFit {
        case .vertical:
            return (sensorHeightMM, aspect)
        case .horizontal:
            return (sensorWidthMM / aspect, aspect)
        case .auto:
            if aspect >= 1.0 {
                return (sensorWidthMM / aspect, aspect)
            } else {
                return (sensorWidthMM, aspect)
            }
        }
    }

    public static func blenderToThreeFOVYDeg(
        lensMM: Double,
        sensorWidthMM: Double,
        sensorHeightMM: Double,
        sensorFit: PrismSensorFit,
        width: Int,
        height: Int,
        pixelAspectX: Double = 1.0,
        pixelAspectY: Double = 1.0
    ) -> (fovYDeg: Double, aspect: Double) {
        let (sensorV, aspect) = effectiveVerticalSensorMM(
            sensorWidthMM: sensorWidthMM,
            sensorHeightMM: sensorHeightMM,
            sensorFit: sensorFit,
            width: width,
            height: height,
            pixelAspectX: pixelAspectX,
            pixelAspectY: pixelAspectY
        )
        let safeLens = max(1e-6, lensMM)
        let fovRad = 2.0 * atan(sensorV / (2.0 * safeLens))
        return (fovRad * 180.0 / Double.pi, aspect)
    }

    public static func threeFOVYDegToBlenderLensMM(
        fovYDeg: Double,
        sensorWidthMM: Double,
        sensorHeightMM: Double,
        sensorFit: PrismSensorFit,
        width: Int,
        height: Int,
        pixelAspectX: Double = 1.0,
        pixelAspectY: Double = 1.0
    ) -> Double {
        let (sensorV, _) = effectiveVerticalSensorMM(
            sensorWidthMM: sensorWidthMM,
            sensorHeightMM: sensorHeightMM,
            sensorFit: sensorFit,
            width: width,
            height: height,
            pixelAspectX: pixelAspectX,
            pixelAspectY: pixelAspectY
        )
        let clampedFOV = max(1.0, min(179.0, fovYDeg))
        let halfRad = (clampedFOV * Double.pi / 180.0) * 0.5
        return sensorV / (2.0 * tan(halfRad))
    }

    public static func threeViewMatrix(positionThree: PrismVec3, quaternionThree: PrismQuaternion) -> [[Double]] {
        let r = quatToMat3(quaternionThree)
        // Transpose of R (since R is orthonormal)
        let rt = [
            [r[0][0], r[1][0], r[2][0]],
            [r[0][1], r[1][1], r[2][1]],
            [r[0][2], r[1][2], r[2][2]],
        ]
        let tInvX = -(rt[0][0] * positionThree.x + rt[0][1] * positionThree.y + rt[0][2] * positionThree.z)
        let tInvY = -(rt[1][0] * positionThree.x + rt[1][1] * positionThree.y + rt[1][2] * positionThree.z)
        let tInvZ = -(rt[2][0] * positionThree.x + rt[2][1] * positionThree.y + rt[2][2] * positionThree.z)
        return [
            [rt[0][0], rt[0][1], rt[0][2], tInvX],
            [rt[1][0], rt[1][1], rt[1][2], tInvY],
            [rt[2][0], rt[2][1], rt[2][2], tInvZ],
            [0.0, 0.0, 0.0, 1.0],
        ]
    }

    public static func threeProjectionMatrix(
        fovYDeg: Double,
        aspect: Double,
        near: Double,
        far: Double,
        shiftX: Double = 0.0,
        shiftY: Double = 0.0,
        sensorFit: PrismSensorFit = .auto
    ) -> [[Double]] {
        let f = 1.0 / tan((fovYDeg * Double.pi / 180.0) * 0.5)
        let nf = 1.0 / (near - far)
        let fitToWidth = (sensorFit == .horizontal) || (sensorFit == .auto && aspect >= 1.0)
        let p02 = fitToWidth ? (2.0 * shiftX) : (2.0 * shiftX / max(1e-6, aspect))
        let p12 = fitToWidth ? (2.0 * shiftY * aspect) : (2.0 * shiftY)
        return [
            [f / max(1e-6, aspect), 0.0, p02, 0.0],
            [0.0, f, p12, 0.0],
            [0.0, 0.0, (far + near) * nf, 2.0 * far * near * nf],
            [0.0, 0.0, -1.0, 0.0],
        ]
    }

    public static func projectPointToNDC(
        worldPointThree p: PrismVec3,
        camera: PrismCameraIR
    ) -> (ndcX: Double, ndcY: Double, ndcZ: Double) {
        let v = threeViewMatrix(positionThree: camera.positionThree, quaternionThree: camera.quaternionThree)
        let pr = threeProjectionMatrix(
            fovYDeg: camera.fovYDeg,
            aspect: camera.aspect,
            near: camera.near,
            far: camera.far,
            shiftX: camera.shiftX,
            shiftY: camera.shiftY,
            sensorFit: camera.sensorFit
        )
        let camV = [
            v[0][0] * p.x + v[0][1] * p.y + v[0][2] * p.z + v[0][3],
            v[1][0] * p.x + v[1][1] * p.y + v[1][2] * p.z + v[1][3],
            v[2][0] * p.x + v[2][1] * p.y + v[2][2] * p.z + v[2][3],
            v[3][0] * p.x + v[3][1] * p.y + v[3][2] * p.z + v[3][3],
        ]
        let clip = [
            pr[0][0] * camV[0] + pr[0][1] * camV[1] + pr[0][2] * camV[2] + pr[0][3] * camV[3],
            pr[1][0] * camV[0] + pr[1][1] * camV[1] + pr[1][2] * camV[2] + pr[1][3] * camV[3],
            pr[2][0] * camV[0] + pr[2][1] * camV[1] + pr[2][2] * camV[2] + pr[2][3] * camV[3],
            pr[3][0] * camV[0] + pr[3][1] * camV[1] + pr[3][2] * camV[2] + pr[3][3] * camV[3],
        ]
        let w = abs(clip[3]) > 1e-12 ? clip[3] : (clip[3] >= 0 ? 1e-12 : -1e-12)
        return (clip[0] / w, clip[1] / w, clip[2] / w)
    }

    public static func projectPointToAnchor(
        name: String,
        worldPointThree p: PrismVec3,
        camera: PrismCameraIR
    ) -> PrismAnchor2D {
        let (nx, ny, nz) = projectPointToNDC(worldPointThree: p, camera: camera)
        let px = (nx * 0.5 + 0.5) * Double(camera.width)
        let py = (0.5 - ny * 0.5) * Double(camera.height)
        let visible = (-1.0...1.0).contains(nx) && (-1.0...1.0).contains(ny) && (-1.0...1.0).contains(nz)
        return PrismAnchor2D(
            name: name,
            worldPositionThree: p,
            ndcX: nx,
            ndcY: ny,
            ndcZ: nz,
            pixelX: px,
            pixelY: py,
            visible: visible
        )
    }

    /// Computes camera distance locking 3D perspective framing to a 2D map viewport zoom/scale (`distForZoom`).
    public static func distanceForWebMercatorZoom(
        zoom: Double,
        viewportHeight: Double,
        fovYDeg: Double
    ) -> Double {
        let worldSpan = max(1e-6, viewportHeight) / pow(2.0, zoom)
        let halfTan = max(1e-6, tan((fovYDeg * Double.pi / 180.0) * 0.5))
        return (worldSpan * 0.5) / halfTan
    }
}
