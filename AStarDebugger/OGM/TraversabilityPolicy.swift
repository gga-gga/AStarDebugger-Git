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

    /// 観測に依らず通行可能とみなすセル（現在地など）。
    /// LiDARの最小距離(0.25m)の制約で足元は未観測になりやすく、これが無いと
    /// 出発点が通行不可と判定されて経路探索が必ず失敗する。実際に立てている場所は
    /// 歩けるはず、という根拠のある仮定。
    ///
    /// グリッドには書き込まず、この判定の中だけで扱う。OccupancyGridMap.integrateは
    /// 加算のみで撤回機構が無いため、仮の票を書くと本物の観測と混ざって永久に残ってしまう。
    /// 判定内に留めておけば、実際の観測が入った時点で自動的にそちらへ置き換わる。
    var assumedTraversable: Set<GridCoordinate> = []

    /// 未観測セルは通行不可として扱う（保守的方式）。
    ///  ・未観測の壁を突き抜ける経路を提示しない（安全）
    ///  ・探索範囲が観測済みセル（有限集合）に限定され、到達不能な目的地を指定されたときに
    ///    未観測空間へ無限展開してハングするのが構造的に消える
    func isTraversable(_ coord: GridCoordinate) -> Bool {
        if assumedTraversable.contains(coord) { return true }
        guard let state = grid.state(at: coord), !state.isOccupied else { return false }
        return costMap[coord]?.isBlocked != true
    }
}
