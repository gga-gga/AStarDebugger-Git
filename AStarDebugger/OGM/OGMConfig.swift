//
//  OGMConfig.swift
//  占有格子地図（OGM）ナビゲーション — チューニングパラメータ
//
//  値は仕様書 9章「未確定・要実測パラメータ一覧」の仮値。実車両での実測により確定させること。
//

import Foundation

enum OGMConfig {
    // 深度取得
    static let depthCaptureInterval: TimeInterval = 1.0 / 10.0 // 10fps目標（歩行速度との整合は要実測）

    // グリッド
    static let cellSize: Float = 0.15 // m（Corridor-Walker準拠の仮値）

    // walkable判定（先行研究 Corridor-Walker Section 4.1 準拠）
    // 高さが床から±この範囲以内、かつ法線ベクトルが重力方向とほぼ平行な点だけをwalkableとする。
    // 論文の値そのまま（ε=0.1m）。オーバーヘッド構造物の別カテゴリは論文には無いため廃止：
    // 高さ+法線どちらかの条件を満たさない点は全てnon-walkable扱いになる。
    static let walkableHeightToleranceMeters: Float = 0.1
    // 法線とワールドUp(0,1,0)の内積の絶対値がこれ以上なら「重力方向とほぼ平行」とみなす
    static let walkableNormalAlignmentThreshold: Float = 0.85

    // 深度取得の有効距離レンジ（3章の関連対策）
    // カメラ直近・浅い入射角の床は特にノイズが大きく、誤って占有候補になりやすいため、
    // 極端に近い点は最初から除外する
    static let minValidRangeMeters: Float = 0.25
    // LiDAR(ARKit sceneDepth)は3.5mを超えるあたりから精度が落ちるとされるため、
    // それより遠い点は「未検出」として扱い、誤検出のリスクを避ける（仮値、要実測調整）
    static let maxValidRangeMeters: Float = 3.5

    // 深度エッジ（壁のシルエット等）でのスムージングにより生じる「浮遊画素」対策。
    // 隣接画素との深度差がこれを超える場合は、実在しない中間距離の点とみなして破棄する
    static let maxDepthDiscontinuityMeters: Float = 0.5

    // コスト関数（Corridor-Walker Section 4.2.1）
    // cost = β(1 - (δ-1)/α)  （1 ≤ δ ≤ α）、δ > α では 0。δ=障害物までのセル距離。
    // δ=1→50, 2→33.3, 3→16.7, 4→0
    static let costAlpha: Float = 3.0
    static let costBeta: Float = 50.0

    // 経路計画時の占有膨張。「通行不可にする半径」と「コストを付ける半径」は別物なので分ける。
    // 以前は1つの値が両方を兼ねており、膨張範囲内が常に通行不可になっていたため、
    // コスト勾配がA*に一度も届いていなかった（論文4.2.1は膨張で塞がずコストのみを付ける）。
    //
    // 通行不可にする半径：人体半幅相当の2セル=0.30m（仮値、車内で実測して確定）。
    // ロングシート車の通路幅1.94mに対し、両側0.30mずつ塞いでも1.34m残る。
    static let blockedMarginCells: Int = 2
    // コストを付ける半径：δ > α で0になるので、αセルまで正のコストが付く。
    static let costMarginCells: Int = Int(costAlpha)

    // セルの占有判定は、そのセルに直接投影されたwalkable/non-walkable点を
    // 1つの符号付きスコア（CellState.score）に集約し、0以下なら占有とする
    // （CellState.isOccupied参照）。walkable/nonWalkableそれぞれを独立にカウントして
    // 別々に上限クランプする方式は撤廃した：両側に同じ上限をかけると、片方が上限に
    // 張り付いた状態でもう片方も同じ上限までしか追いつけず、N対N（同数=占有）で
    // 永久に固定されてしまう欠陥があった（実機で確認済み。緑=walkableが明らかに
    // 多く観測されても占有のまま戻らない不具合として現れた）。
    // レイキャストによる中間セルの空き推定（Bresenham）は先行研究の記述に無いため撤廃した。
    // log-odds加算＋連続一致ゲート方式も、壁際が白黒まだらになる問題が
    // 解消しなかったため撤廃した。

    // セルスコアの上下限。無制限だと、誤って占有側に大きく振れたセルは、
    // それを上回る回数の反対観測がない限り訂正できず実質固定されてしまう
    // （障害物が移動した後に空きへ戻らないのも同じ理由）。上下限を設けることで
    // 「反対方向の観測が続けば必ず0を跨いで反転できる」ことを保証する。
    // 対称（±10）にしているので、空き・占有どちらの極端な状態からでも、
    // 反対方向の観測11回で必ず反転できる。値は仮値、実機での訂正速度・ちらつきを見ながら調整する。
    static let cellScoreMax: Int = 10
    static let cellScoreMin: Int = -10

    // 再計画（7章）
    static let replanAtPathFractionWalked: Float = 0.5

    // 床面再推定の頻度（3.1：毎フレームは重いため低頻度再推定）
    static let floorReestimateIntervalSeconds: TimeInterval = 5.0
}
