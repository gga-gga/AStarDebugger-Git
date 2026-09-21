//
//  OccupancyGridMap.swift
//  占有格子地図（OGM）— グリッド更新: 各点が投影されたセルへの直接投票による多数決管理
//
//  先行研究（Corridor-Walker Section 4.1）に合わせ、レイキャストによる中間セルの
//  空き推定は行わない。各点は「その点が実際に投影される1セル」にのみ投票する。
//

import Foundation
import simd

final class OccupancyGridMap {
    private(set) var cells: [GridCoordinate: CellState] = [:]
    let cellSize: Float

    init(cellSize: Float = OGMConfig.cellSize) {
        self.cellSize = cellSize
    }

    func coordinate(forWorld position: simd_float3) -> GridCoordinate {
        GridCoordinate(x: Int(floor(position.x / cellSize)), z: Int(floor(position.z / cellSize)))
    }

    func worldCenter(of coord: GridCoordinate) -> simd_float3 {
        simd_float3((Float(coord.x) + 0.5) * cellSize, 0, (Float(coord.z) + 0.5) * cellSize)
    }

    func state(at coord: GridCoordinate) -> CellState? {
        cells[coord]
    }

    /// 各点が投影されるセルに、walkable/non-walkableの票を1つ入れる。
    /// 視野外・未観測のセルは触れられず、直近の値を保持し続ける。
    /// 票数には上限があり（OGMConfig.maxVoteCountPerCell）、過去の観測が無制限に
    /// 積み上がって後からの訂正を不可能にしてしまうのを防ぐ。
    func integrate(classifiedPoints: [ClassifiedPoint]) {
        let maxVotes = OGMConfig.maxVoteCountPerCell
        for point in classifiedPoints {
            let coord = coordinate(forWorld: point.worldPosition)
            var state = cells[coord] ?? CellState()
            switch point.walkability {
            case .walkable:
                state.walkableCount = min(state.walkableCount + 1, maxVotes)
            case .nonWalkable:
                state.nonWalkableCount = min(state.nonWalkableCount + 1, maxVotes)
            }
            cells[coord] = state
        }
    }
}
