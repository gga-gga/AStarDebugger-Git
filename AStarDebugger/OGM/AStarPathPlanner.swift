//
//  AStarPathPlanner.swift
//  占有格子地図（OGM）— A*経路計画（[8] / 7章）
//

import Foundation

final class AStarPathPlanner {
    private let costMap: [GridCoordinate: CostCell]
    private let isTraversable: (GridCoordinate) -> Bool

    private static let neighborOffsets: [(dx: Int, dz: Int)] = [
        (1, 0), (-1, 0), (0, 1), (0, -1),
        (1, 1), (1, -1), (-1, 1), (-1, -1)
    ]

    init(costMap: [GridCoordinate: CostCell], isTraversable: @escaping (GridCoordinate) -> Bool) {
        self.costMap = costMap
        self.isTraversable = isTraversable
    }

    /// 8近傍A*。列車車両規模のグリッド（数百〜数千セル）を想定した単純な線形探索版。
    func findPath(from start: GridCoordinate, to goal: GridCoordinate) -> [GridCoordinate]? {
        guard isTraversable(start), isTraversable(goal) else { return nil }
        if start == goal { return [start] }

        var openSet: Set<GridCoordinate> = [start]
        var cameFrom: [GridCoordinate: GridCoordinate] = [:]
        var gScore: [GridCoordinate: Float] = [start: 0]
        var fScore: [GridCoordinate: Float] = [start: heuristic(start, goal)]

        while !openSet.isEmpty {
            guard let current = openSet.min(by: { (fScore[$0] ?? .infinity) < (fScore[$1] ?? .infinity) }) else {
                break
            }
            if current == goal {
                return reconstructPath(cameFrom: cameFrom, current: current)
            }
            openSet.remove(current)

            for offset in Self.neighborOffsets {
                let neighbor = GridCoordinate(x: current.x + offset.dx, z: current.z + offset.dz)
                guard isTraversable(neighbor) else { continue }

                // 移動コストはセル数で数える（メートルではない）。
                // メートル(1セル0.15)だと障害物コスト(最大β=50)と桁が合わず、
                // 障害物の隣を1セル通ることが333セル分の遠回りと同じ重みになってしまい、
                // 論文のα=3・β=50が意図した比率で効かない。
                let isDiagonal = offset.dx != 0 && offset.dz != 0
                let travelCost: Float = isDiagonal ? Float(2).squareRoot() : 1
                let obstacleCost = costMap[neighbor]?.baseCost ?? 0
                let tentativeG = (gScore[current] ?? .infinity) + travelCost + obstacleCost

                if tentativeG < (gScore[neighbor] ?? .infinity) {
                    cameFrom[neighbor] = current
                    gScore[neighbor] = tentativeG
                    fScore[neighbor] = tentativeG + heuristic(neighbor, goal)
                    openSet.insert(neighbor)
                }
            }
        }
        return nil
    }

    /// 残りセル数のユークリッド距離。移動コストと同じ「セル数」単位に揃えてあり、
    /// 障害物コストは常に0以上なので、実コストを上回らない（許容的）。
    private func heuristic(_ a: GridCoordinate, _ b: GridCoordinate) -> Float {
        let dx = Float(a.x - b.x), dz = Float(a.z - b.z)
        return (dx * dx + dz * dz).squareRoot()
    }

    private func reconstructPath(cameFrom: [GridCoordinate: GridCoordinate], current: GridCoordinate) -> [GridCoordinate] {
        var path = [current]
        var node = current
        while let prev = cameFrom[node] {
            path.append(prev)
            node = prev
        }
        return path.reversed()
    }
}
