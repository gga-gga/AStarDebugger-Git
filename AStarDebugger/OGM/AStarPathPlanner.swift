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
    /// 8方向移動＋同コストの経路が複数ある開けた領域では、最適だが見た目にくねくねした
    /// 経路が出やすいため、タイブレークと後処理の間引きの両方で見た目を整える。
    func findPath(from start: GridCoordinate, to goal: GridCoordinate) -> [GridCoordinate]? {
        guard isTraversable(start), isTraversable(goal) else { return nil }
        if start == goal { return [start] }

        var openSet: Set<GridCoordinate> = [start]
        var cameFrom: [GridCoordinate: GridCoordinate] = [:]
        var gScore: [GridCoordinate: Float] = [start: 0]
        var fScore: [GridCoordinate: Float] = [start: heuristic(start, goal, start: start)]

        while !openSet.isEmpty {
            guard let current = openSet.min(by: { (fScore[$0] ?? .infinity) < (fScore[$1] ?? .infinity) }) else {
                break
            }
            if current == goal {
                let rawPath = reconstructPath(cameFrom: cameFrom, current: current)
                return simplifyPath(rawPath)
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
                    fScore[neighbor] = tentativeG + heuristic(neighbor, goal, start: start)
                    openSet.insert(neighbor)
                }
            }
        }
        return nil
    }

    /// 残りセル数のユークリッド距離に、始点→終点の直線からのズレ（外積の絶対値）を
    /// 極小の係数で加えたタイブレーク付きヒューリスティック。
    /// 開けた領域では同コストの経路が多数存在し、素の距離だけでは
    /// どれが選ばれるか実質不定でジグザグの原因になるため、直線に近い経路を弱く優先する。
    /// 係数は移動コスト(1セルあたり最小1)よりずっと小さくしてあり、探索の最適性への
    /// 影響はごくわずか（純粋な許容性は理論上わずかに崩れるが、実用上は無視できる）。
    private func heuristic(_ a: GridCoordinate, _ goal: GridCoordinate, start: GridCoordinate) -> Float {
        let dx = Float(a.x - goal.x), dz = Float(a.z - goal.z)
        let straightLineDistance = (dx * dx + dz * dz).squareRoot()

        let startToGoalX = Float(start.x - goal.x), startToGoalZ = Float(start.z - goal.z)
        let cross = abs(dx * startToGoalZ - startToGoalX * dz)
        return straightLineDistance + cross * 0.001
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

    /// 経路の間引き（string pulling）。A*が返す8方向グリッドの経路は、45°の倍数から
    /// ズレた方向へ向かう区間で「直進+斜め移動の組み合わせ」による階段状のジグザグに
    /// なりやすい。2点間が障害物のコストの影響を受けないセルだけを通って直接見通せるなら、
    /// 間の通過点を省いて直線でつなぐ。
    ///
    /// 見通し判定はisTraversableだけでなくコスト0のセルだけを対象にする。コストが乗って
    /// いる（＝障害物に近い）区間は、A*が意図的に距離を取っている可能性があるため、
    /// 間引きで壁際に経路を寄せ直してしまわないようにするため。
    private func simplifyPath(_ path: [GridCoordinate]) -> [GridCoordinate] {
        guard path.count > 2 else { return path }

        var simplified: [GridCoordinate] = [path[0]]
        var anchorIndex = 0

        var candidateIndex = 2
        while candidateIndex < path.count {
            if !hasOpenLineOfSight(from: path[anchorIndex], to: path[candidateIndex]) {
                simplified.append(path[candidateIndex - 1])
                anchorIndex = candidateIndex - 1
            }
            candidateIndex += 1
        }
        simplified.append(path[path.count - 1])
        return simplified
    }

    /// Bresenhamで2点間の通過セルを列挙し、すべて通行可能かつコスト0であればtrue。
    private func hasOpenLineOfSight(from a: GridCoordinate, to b: GridCoordinate) -> Bool {
        var x0 = a.x, z0 = a.z
        let x1 = b.x, z1 = b.z
        let dx = abs(x1 - x0), dz = abs(z1 - z0)
        let sx = x0 < x1 ? 1 : -1
        let sz = z0 < z1 ? 1 : -1
        var err = dx - dz

        while true {
            let coord = GridCoordinate(x: x0, z: z0)
            guard isTraversable(coord), (costMap[coord]?.baseCost ?? 0) == 0 else { return false }
            if x0 == x1 && z0 == z1 { break }
            let e2 = 2 * err
            if e2 > -dz { err -= dz; x0 += sx }
            if e2 < dx { err += dx; z0 += sz }
        }
        return true
    }
}
