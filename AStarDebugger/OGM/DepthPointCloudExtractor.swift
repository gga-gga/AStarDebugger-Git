//
//  DepthPointCloudExtractor.swift
//  占有格子地図（OGM）— 深度取得〜ワールド座標変換＋法線ベクトル推定
//

import ARKit
import simd

/// ワールド座標系での1点と、その点における法線ベクトル（正規化済み）
struct DepthPoint {
    let worldPosition: simd_float3
    let worldNormal: simd_float3
}

final class DepthPointCloudExtractor {
    /// 画素間引き幅（全画素を使うと重いため）
    let pixelStride: Int
    /// 法線推定に使う近傍画素までのオフセット
    private let normalSampleOffset: Int = 2

    init(pixelStride: Int = 4) {
        self.pixelStride = pixelStride
    }

    /// 深度マップ + 信頼度マップからワールド座標点群＋法線を抽出する。
    /// confidenceMap が `.high` 未満の画素は破棄する（[1]）。
    ///
    /// smoothedSceneDepth（空間・時間平滑化あり）は壁のシルエット等の深度エッジで
    /// 手前と奥の深度を混ぜた「浮遊画素」を生成しやすいため、生の sceneDepth を優先する。
    func extractPoints(from frame: ARFrame) -> [DepthPoint] {
        guard let depthData = frame.sceneDepth ?? frame.smoothedSceneDepth else { return [] }
        let depthMap = depthData.depthMap
        let confidenceMap = depthData.confidenceMap

        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)

        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }
        guard let depthBase = CVPixelBufferGetBaseAddress(depthMap) else { return [] }
        let depthRowStride = CVPixelBufferGetBytesPerRow(depthMap) / MemoryLayout<Float32>.size
        let depthBuf = depthBase.assumingMemoryBound(to: Float32.self)

        var confidenceBuf: UnsafeMutablePointer<UInt8>?
        var confidenceRowStride = 0
        if let confidenceMap {
            CVPixelBufferLockBaseAddress(confidenceMap, .readOnly)
            confidenceRowStride = CVPixelBufferGetBytesPerRow(confidenceMap)
            confidenceBuf = CVPixelBufferGetBaseAddress(confidenceMap)?.assumingMemoryBound(to: UInt8.self)
        }
        defer {
            if confidenceMap != nil { CVPixelBufferUnlockBaseAddress(confidenceMap!, .readOnly) }
        }

        // カメラ内部パラメータは capturedImage(RGB) 基準のため、深度マップ解像度へスケーリングする
        let intr = frame.camera.intrinsics
        let imageW = Float(CVPixelBufferGetWidth(frame.capturedImage))
        let imageH = Float(CVPixelBufferGetHeight(frame.capturedImage))
        guard imageW > 0, imageH > 0 else { return [] }
        let sx = Float(width) / imageW
        let sy = Float(height) / imageH
        let fx = intr.columns.0.x * sx
        let fy = intr.columns.1.y * sy
        let cx = intr.columns.2.x * sx
        let cy = intr.columns.2.y * sy

        let cameraToWorld = frame.camera.transform
        let rotation = simd_float3x3(
            simd_float3(cameraToWorld.columns.0.x, cameraToWorld.columns.0.y, cameraToWorld.columns.0.z),
            simd_float3(cameraToWorld.columns.1.x, cameraToWorld.columns.1.y, cameraToWorld.columns.1.z),
            simd_float3(cameraToWorld.columns.2.x, cameraToWorld.columns.2.y, cameraToWorld.columns.2.z)
        )

        func cameraSpacePoint(_ px: Int, _ py: Int) -> simd_float3? {
            guard px >= 0, px < width, py >= 0, py < height else { return nil }
            let d = depthBuf[py * depthRowStride + px]
            guard d.isFinite, d > 0 else { return nil }
            let u = Float(px), v = Float(py)
            // 画像座標(vは下向きに増える) → ARKitカメラ座標(Yは上向き)なので、
            // ZだけでなくYも符号反転が必要（Apple公式点群サンプルのflipYZに相当）。
            // Yの反転が欠けていたことが、縦持ち時にカメラYが左右方向を向くために
            // 「地図が左右鏡映になる」バグの根本原因だった。
            return simd_float3((u - cx) / fx * d, -(v - cy) / fy * d, -d)
        }

        var points: [DepthPoint] = []
        points.reserveCapacity((width / pixelStride) * (height / pixelStride))

        var y = 0
        while y < height {
            var x = 0
            while x < width {
                if let confidenceBuf {
                    let confidence = confidenceBuf[y * confidenceRowStride + x]
                    if confidence < UInt8(ARConfidenceLevel.high.rawValue) {
                        x += pixelStride
                        continue
                    }
                }

                let depth = depthBuf[y * depthRowStride + x]
                let isValidRange = depth.isFinite
                    && depth >= OGMConfig.minValidRangeMeters
                    && depth <= OGMConfig.maxValidRangeMeters

                // 深度エッジの浮遊画素対策：隣接画素と深度が大きく飛んでいる場合は、
                // 手前と奥の面が混ざった実在しない中間距離の点とみなして破棄する
                var isDiscontinuous = false
                if isValidRange, x + 1 < width {
                    let neighborDepth = depthBuf[y * depthRowStride + (x + 1)]
                    if neighborDepth.isFinite,
                       abs(neighborDepth - depth) > OGMConfig.maxDepthDiscontinuityMeters {
                        isDiscontinuous = true
                    }
                }

                if isValidRange, !isDiscontinuous,
                   let center = cameraSpacePoint(x, y),
                   let right = cameraSpacePoint(x + normalSampleOffset, y),
                   let down = cameraSpacePoint(x, y + normalSampleOffset) {
                    // 法線計算に使う近傍画素自体が深度エッジ（壁の縁など）をまたいでいると、
                    // 手前と奥の面が混ざった出鱈目な法線になり、実際は壁の奥にある点の
                    // 法線が誤ってwalkable/non-walkable判定を誤らせる（壁の奥数セルが
                    // 誤って占有になる不具合の原因）。近傍画素の深度差もチェックして、
                    // 断絶をまたぐ場合はこの点自体を破棄する。
                    let rightJump = abs(abs(right.z) - abs(center.z)) > OGMConfig.maxDepthDiscontinuityMeters
                    let downJump = abs(abs(down.z) - abs(center.z)) > OGMConfig.maxDepthDiscontinuityMeters

                    // 深度画像の近傍画素から法線を推定する（構造化点群向けの簡易手法）[30]
                    let tangentRight = right - center
                    let tangentDown = down - center
                    let normalCamera = simd_cross(tangentRight, tangentDown)
                    let normalLength = simd_length(normalCamera)

                    if !rightJump, !downJump, normalLength > 1e-6 {
                        let worldPoint = cameraToWorld * simd_float4(center.x, center.y, center.z, 1.0)
                        let worldNormal = simd_normalize(rotation * (normalCamera / normalLength))
                        points.append(DepthPoint(
                            worldPosition: simd_float3(worldPoint.x, worldPoint.y, worldPoint.z),
                            worldNormal: worldNormal
                        ))
                    }
                }
                x += pixelStride
            }
            y += pixelStride
        }
        return points
    }
}
