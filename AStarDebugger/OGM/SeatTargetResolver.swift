//
//  SeatTargetResolver.swift
//  占有格子地図（OGM）— 目的地の定義：空席正面の通路セルを解決する（6章）
//
//  座面セル自体は占有として保持したまま、目的地を座席エリアに隣接する
//  通路側のFreeセルに変換する。空席の3D位置自体は別モジュール（既存のraycast検出等）から得る想定。
//

import simd

struct SeatTargetResolver {
    let grid: OccupancyGridMap
    let costMap: [GridCoordinate: CostCell]

    /// - Parameters:
    ///   - seatWorldPosition: 空席検出で得られたワールド座標（座面付近）
    ///   - preferredDirection: 座席→通路方向のヒント（水平面）。nilなら全方向から最短のFreeセルを探索
    ///   - searchRadiusCells: 探索半径（セル数）
    func resolveDestination(seatWorldPosition: simd_float3,
                             preferredDirection: simd_float3? = nil,
                             searchRadiusCells: Int = 6) -> GridCoordinate? {
        let seatCell = grid.coordinate(forWorld: seatWorldPosition)

        var best: (coord: GridCoordinate, score: Float)?
        for dz in -searchRadiusCells...searchRadiusCells {
            for dx in -searchRadiusCells...searchRadiusCells {
                guard dx != 0 || dz != 0 else { continue }
                let coord = GridCoordinate(x: seatCell.x + dx, z: seatCell.z + dz)
                guard isFreeAndTraversable(coord) else { continue }

                let cellsAway = Float(max(abs(dx), abs(dz)))
                var score = cellsAway // 近いほど良い（スコアが小さいほど優先）

                if let preferredDirection {
                    let toCell = simd_float3(Float(dx), 0, Float(dz))
                    let horizontalDirection = simd_float3(preferredDirection.x, 0, preferredDirection.z)
                    if simd_length(horizontalDirection) > 1e-6 {
                        let alignment = simd_dot(simd_normalize(toCell), simd_normalize(horizontalDirection))
                        score -= alignment * 2 // 通路方向と一致するほど優先度を上げる
                    }
                }

                if best == nil || score < best!.score {
                    best = (coord, score)
                }
            }
        }
        return best?.coord
    }

    private func isFreeAndTraversable(_ coord: GridCoordinate) -> Bool {
        if costMap[coord]?.isBlocked == true { return false }
        if let state = grid.state(at: coord), state.isOccupied { return false }
        return true
    }
}
