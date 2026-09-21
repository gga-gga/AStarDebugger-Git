//
//  CellState.swift
//  占有格子地図（OGM）— セルごとのwalkable/non-walkable観測を1つのスコアに集約
//
//  先行研究（Corridor-Walker, Section 4.1）の「walkable票がnon-walkable票より多い時だけ
//  walkable、同数含めそれ以外はnon-walkable」という多数決を、2つの独立したカウンタではなく
//  1つの符号付きスコアで表現する。
//
//  2カウンタ方式（walkableCount/nonWalkableCountを別々にクランプ）には構造的な欠陥があった：
//  両方に同じ上限をかけると、片方が上限に張り付いた状態でもう片方も同じ上限までしか
//  追いつけず、N対N（同数=占有）で永久に固定されてしまう。緑（walkable）がいくら多く
//  観測されても占有のまま戻らない不具合として実機で確認された。
//
//  1つのスコアなら、どれだけ占有側に振れていても、反対方向の観測が続けば必ず0を
//  跨いで反転できる。
//

import Foundation

struct CellState {
    /// walkable観測で+1、non-walkable観測で-1。範囲はOGMConfig.cellScoreMin...cellScoreMaxでクランプ。
    var score: Int = 0

    /// スコアが0以下（同数含む）ならtrue（占有）。安全側に倒す設計。
    /// 一度も観測されていないセルはこの値に関わらず「未検出」として扱うこと（辞書に不在で判定）。
    var isOccupied: Bool { score <= 0 }
}
