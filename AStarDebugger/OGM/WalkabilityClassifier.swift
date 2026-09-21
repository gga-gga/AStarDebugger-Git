//
//  WalkabilityClassifier.swift
//  占有格子地図（OGM）— walkable/non-walkable判定（先行研究 Corridor-Walker Section 4.1準拠）
//
//  高さが床から一定範囲内、かつ法線ベクトルが重力方向とほぼ平行な点だけをwalkableとする。
//  どちらか一方でも満たさない点は全てnon-walkable（うちの旧実装にあった「頭上構造物」の
//  別カテゴリは論文には無い）。
//

import simd

enum Walkability: Equatable {
    case walkable
    case nonWalkable
}

struct ClassifiedPoint {
    let worldPosition: simd_float3
    let walkability: Walkability
}

struct WalkabilityClassifier {
    let floorY: Float

    func classify(_ points: [DepthPoint]) -> [ClassifiedPoint] {
        points.map { point in
            let heightOK = abs(point.worldPosition.y - floorY) <= OGMConfig.walkableHeightToleranceMeters
            let normalOK = abs(point.worldNormal.y) >= OGMConfig.walkableNormalAlignmentThreshold
            let walkability: Walkability = (heightOK && normalOK) ? .walkable : .nonWalkable
            return ClassifiedPoint(worldPosition: point.worldPosition, walkability: walkability)
        }
    }
}
