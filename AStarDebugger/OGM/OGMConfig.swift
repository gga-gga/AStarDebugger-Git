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

    // 経路計画時の占有膨張マージン（5.3）
    // 安定/不安定の区別は行わないため、安全側の値（旧unstableMarginCellsの上限）を一律採用
    static let occupiedMarginCells: Int = 3

    // コスト関数（5.3, Corridor-Walker Section 4.2準拠）
    static let costAlpha: Float = 3.0
    static let costBeta: Float = 50.0

    // セルの占有判定は、そのセルに直接投影されたwalkable/non-walkable点の
    // 累積カウントの多数決で確定させる（CellState.isOccupied参照）。
    // レイキャストによる中間セルの空き推定（Bresenham）は先行研究の記述に無いため撤廃した。
    // log-odds加算＋連続一致ゲート方式も、壁際が白黒まだらになる問題が
    // 解消しなかったため撤廃した。

    // 1セルが片側の判定に対して覚えておく票数の上限。
    // 上限が無いと、誤って占有と判定されて票が溜まったセルは、その票数を上回る回数だけ
    // 空きと観測されない限り占有のままになり、実質的に訂正不能になる
    // （実機で確認済み。障害物が移動した後に空きへ戻らないのも同じ理由）。
    // 上限を設けることで「上限+1回の反対観測があれば必ず覆せる」ことを保証する。
    // 小さくすると訂正は速いがちらつきやすく、大きくすると安定するが訂正が遅い（仮値）。
    static let maxVoteCountPerCell: Int = 10

    // 再計画（7章）
    static let replanAtPathFractionWalked: Float = 0.5

    // 床面再推定の頻度（3.1：毎フレームは重いため低頻度再推定）
    static let floorReestimateIntervalSeconds: TimeInterval = 5.0
}
