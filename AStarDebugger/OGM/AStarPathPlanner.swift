//
//  AStarPathPlanner.swift
//  占有格子地図（OGM）— A*経路計画（[8] / 7章）
//

import Foundation

final class AStarPathPlanner {
    private let costMap: [GridCoordinate: CostCell]
    private let cellSize: Float
    private let isTraversable: (GridCoordinate) -> Bool

    private static let neighborOffsets: [(dx: Int, dz: Int)] = [
        (1, 0), (-1, 0), (0, 1), (0, -1),
        (1, 1), (1, -1), (-1, 1), (-1, -1)
    ]

    init(costMap: [GridCoordinate: CostCell], cellSize: Float, isTraversable: @escaping (GridCoordinate) -> Bool) {
        self.costMap = costMap
        self.cellSize = cellSize
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

                let isDiagonal = offset.dx != 0 && offset.dz != 0
                let stepDistance: Float = isDiagonal ? Float(2).squareRoot() : 1
                let travelCost = stepDistance * cellSize
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

    private func heuristic(_ a: GridCoordinate, _ b: GridCoordinate) -> Float {
        let dx = Float(a.x - b.x), dz = Float(a.z - b.z)
        return (dx * dx + dz * dz).squareRoot() * cellSize
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
