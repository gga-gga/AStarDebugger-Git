//
//  FloorPlaneEstimator.swift
//  占有格子地図（OGM）— RANSACによる床平面推定（3.1）
//

import Foundation
import simd

enum FloorPlaneEstimator {
    private static let maxIterations = 60
    private static let inlierDistanceThreshold: Float = 0.03 // m
    // 重力方向(+Y)とのなす角を制限し、座席背もたれ等の垂直面が床平面として誤検出されるのを防ぐ
    private static let minNormalUpAlignment: Float = 0.85

    /// 点群からRANSACで床平面を推定し、そのY座標（Y_floor）を返す。
    /// 車内は平坦なので定数として扱ってよいが、傾斜対策として毎フレームまたは低頻度で再推定する。
    static func estimateFloorY(from points: [simd_float3]) -> Float? {
        guard points.count >= 3 else { return nil }

        let sample = subsample(points, maxCount: 600)
        guard sample.count >= 3 else { return nil }

        var bestInlierCount = 0
        var bestInlierYs: [Float] = []

        for _ in 0..<maxIterations {
            guard let p0 = sample.randomElement(),
                  let p1 = sample.randomElement(),
                  let p2 = sample.randomElement() else { continue }

            let v1 = p1 - p0
            let v2 = p2 - p0
            var normal = simd_cross(v1, v2)
            let length = simd_length(normal)
            guard length > 1e-6 else { continue }
            normal /= length

            if abs(normal.y) < minNormalUpAlignment { continue }

            let d = -simd_dot(normal, p0)
            var inlierYs: [Float] = []
            inlierYs.reserveCapacity(sample.count)
            for p in sample {
                let distance = abs(simd_dot(normal, p) + d)
                if distance < inlierDistanceThreshold {
                    inlierYs.append(p.y)
                }
            }
            if inlierYs.count > bestInlierCount {
                bestInlierCount = inlierYs.count
                bestInlierYs = inlierYs
            }
        }

        guard !bestInlierYs.isEmpty else { return nil }
        return bestInlierYs.reduce(0, +) / Float(bestInlierYs.count)
    }

    private static func subsample(_ points: [simd_float3], maxCount: Int) -> [simd_float3] {
        guard points.count > maxCount else { return points }
        let step = max(1, points.count / maxCount)
        return Swift.stride(from: 0, to: points.count, by: step).map { points[$0] }
    }
}
