//
//  CostMapGenerator.swift
//  占有格子地図（OGM）— 適応的マージン → コストマップ生成（[7] / 5.3）
//

import Foundation

struct CostCell {
    /// A*計画時の追加コスト（Corridor-Walker 4.2形式: cost_i = β * (1 - (δ_i - 1) / α)）
    var baseCost: Float = 0
    /// マージン内で通行不可
    var isBlocked: Bool = false
}

final class CostMapGenerator {
    let grid: OccupancyGridMap

    init(grid: OccupancyGridMap) {
        self.grid = grid
    }

    /// 占有セルを膨張させ、コストマップを生成する。
    func generateCostMap(occupiedCoordinates: [GridCoordinate: CellState]) -> [GridCoordinate: CostCell] {
        var costMap: [GridCoordinate: CostCell] = [:]

        for (coord, state) in occupiedCoordinates where state.isOccupied {
            inflate(around: coord, into: &costMap)
        }
        return costMap
    }

    /// 障害物セルの周囲に、通行不可フラグ（人体半幅相当の近傍のみ）と
    /// コスト勾配（論文4.2.1）をそれぞれの半径で書き込む。
    private func inflate(around center: GridCoordinate, into costMap: inout [GridCoordinate: CostCell]) {
        let blockedRadius = OGMConfig.blockedMarginCells
        let costRadius = OGMConfig.costMarginCells
        let radius = max(blockedRadius, costRadius)

        for dz in -radius...radius {
            for dx in -radius...radius {
                // δ = 障害物セルからの距離。Chebyshevだと膨張が角張るのでユークリッドを使う。
                let delta = (Float(dx * dx + dz * dz)).squareRoot()

                let blocked = delta <= Float(blockedRadius)
                // cost = β(1 - (δ-1)/α)（1 ≤ δ ≤ α）、δ > α では 0。
                // 以前は delta に +1 していたため1セル分ずれており、
                // 障害物の隣（δ=1）が最大コストになるべきところが33.3になっていた。
                // δ=0（障害物セル自身）はβを超えるのでクランプする。
                // そのセル自体は通行不可なのでA*からは参照されないが、値としては0〜βに収める。
                let cost = delta <= OGMConfig.costAlpha
                    ? min(OGMConfig.costBeta,
                          max(0, OGMConfig.costBeta * (1 - (delta - 1) / OGMConfig.costAlpha)))
                    : 0
                guard blocked || cost > 0 else { continue }

                let coord = GridCoordinate(x: center.x + dx, z: center.z + dz)
                var existing = costMap[coord] ?? CostCell()
                existing.baseCost = max(existing.baseCost, cost)
                existing.isBlocked = existing.isBlocked || blocked
                costMap[coord] = existing
            }
        }
    }
}
