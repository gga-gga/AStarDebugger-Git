//
//  FrontierGoalSelector.swift
//  占有格子地図（OGM）— 目的地（フロンティア）の選択
//
//  保守的方式（未観測=通行不可）では、まだ見えていない遠くの座席をそのまま目的地に
//  指定しても経路が出ない。そこで目的地を「現在地から到達可能な観測済みセルのうち、
//  座席に最も近いもの」＝観測済み領域の縁（フロンティア）に置く。
//
//  これは副次的に「通路侵入口」も兼ねる。通路が空いていれば観測範囲の先端(3.5m程度)を、
//  人が立っていればその手前を返すため、侵入口という概念を別に実装する必要がない。
//  座席が近くまで観測できている場合は、座面自体は非walkableなので、その正面の
//  通路セルが「最も近い到達可能セル」として自然に選ばれる。
//

import simd

struct FrontierGoalSelector {
    let grid: OccupancyGridMap
    let traversability: TraversabilityPolicy

    private static let neighborOffsets: [(dx: Int, dz: Int)] = [
        (1, 0), (-1, 0), (0, 1), (0, -1),
        (1, 1), (1, -1), (-1, 1), (-1, -1)
    ]

    /// 現在地から到達可能なセルを幅優先で洗い出し、その中で目標に最も近いセルを返す。
    /// 到達可能性を先に確かめてから返すので、この結果に対するA*は必ず経路を見つけられる
    /// （候補を変えながらA*を試し直すループが不要になる）。
    func selectGoal(from start: GridCoordinate, towards target: simd_float3) -> GridCoordinate? {
        let reachable = reachableCells(from: start)
        guard !reachable.isEmpty else { return nil }

        let targetCell = grid.coordinate(forWorld: target)
        return reachable.min { lhs, rhs in
            squaredCellDistance(lhs, targetCell) < squaredCellDistance(rhs, targetCell)
        }
    }

    /// 到達可能セルの列挙。通行判定が観測済みセルに限定されているため、
    /// 探索は有限集合で必ず停止する。
    func reachableCells(from start: GridCoordinate) -> Set<GridCoordinate> {
        guard traversability.isTraversable(start) else { return [] }

        var visited: Set<GridCoordinate> = [start]
        var queue: [GridCoordinate] = [start]
        var head = 0

        while head < queue.count {
            let current = queue[head]
            head += 1

            for offset in Self.neighborOffsets {
                let neighbor = GridCoordinate(x: current.x + offset.dx, z: current.z + offset.dz)
                guard !visited.contains(neighbor), traversability.isTraversable(neighbor) else { continue }
                visited.insert(neighbor)
                queue.append(neighbor)
            }
        }
        return visited
    }

    private func squaredCellDistance(_ a: GridCoordinate, _ b: GridCoordinate) -> Int {
        let dx = a.x - b.x, dz = a.z - b.z
        return dx * dx + dz * dz
    }
}
