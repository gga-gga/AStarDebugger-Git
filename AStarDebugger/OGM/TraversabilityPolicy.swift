//
//  TraversabilityPolicy.swift
//  占有格子地図（OGM）— セルを通行可能とみなすかの判定
//
//  目的地選択（SeatTargetResolver）とA*（AStarPathPlanner）で判定がズレると、
//  「目的地は返ってくるのに経路だけ出ない」という原因の分かりにくい失敗になる。
//  実際、A*だけを保守的（未観測=通行不可）に変更した際に両者がズレていたため、
//  判定はここ1箇所に集約する。
//

struct TraversabilityPolicy {
    let grid: OccupancyGridMap
    let costMap: [GridCoordinate: CostCell]

    /// 未観測セルは通行不可として扱う（保守的方式）。
    ///  ・未観測の壁を突き抜ける経路を提示しない（安全）
    ///  ・探索範囲が観測済みセル（有限集合）に限定され、到達不能な目的地を指定されたときに
    ///    未観測空間へ無限展開してハングするのが構造的に消える
    func isTraversable(_ coord: GridCoordinate) -> Bool {
        guard let state = grid.state(at: coord), !state.isOccupied else { return false }
        return costMap[coord]?.isBlocked != true
    }
}
