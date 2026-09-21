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

    /// 占有セルを固定マージン幅で膨張させ、コストマップを生成する。
    func generateCostMap(occupiedCoordinates: [GridCoordinate: CellState]) -> [GridCoordinate: CostCell] {
        var costMap: [GridCoordinate: CostCell] = [:]

        for (coord, state) in occupiedCoordinates where state.isOccupied {
            inflate(around: coord, marginCells: OGMConfig.occupiedMarginCells, into: &costMap)
        }
        return costMap
    }

    private func inflate(around center: GridCoordinate, marginCells: Int, into costMap: inout [GridCoordinate: CostCell]) {
        for dz in -marginCells...marginCells {
            for dx in -marginCells...marginCells {
                let coord = GridCoordinate(x: center.x + dx, z: center.z + dz)
                let cellDistance = Float(max(abs(dx), abs(dz))) // Chebyshev距離
                let blocked = cellDistance <= Float(marginCells)
                let delta = cellDistance + 1 // 占有セル自体をδ=1として扱う
                let cost = max(0, OGMConfig.costBeta * (1 - (delta - 1) / OGMConfig.costAlpha))

                var existing = costMap[coord] ?? CostCell()
                existing.baseCost = max(existing.baseCost, cost)
                existing.isBlocked = existing.isBlocked || blocked
                costMap[coord] = existing
            }
        }
    }
}
