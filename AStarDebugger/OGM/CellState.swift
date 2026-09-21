//
//  CellState.swift
//  占有格子地図（OGM）— セルごとのwalkable/non-walkable観測カウント
//
//  先行研究（Corridor-Walker, Section 4.1）の方式に合わせる：
//  「そのセルに実際に投影された点」だけを集計し、walkable点がnon-walkable点より
//  多い時だけwalkable(空き)、それ以外（同数含む）はnon-walkable(占有)とする。
//

import Foundation

struct CellState {
    var walkableCount: Int = 0
    var nonWalkableCount: Int = 0

    var totalCount: Int { walkableCount + nonWalkableCount }

    /// walkable票が上回った時だけfalse（空き）。同数を含め、それ以外はtrue（占有）。
    /// 一度も観測されていないセルはこの値に関わらず「未検出」として扱うこと（辞書に不在で判定）。
    var isOccupied: Bool { !(walkableCount > nonWalkableCount) }
}
