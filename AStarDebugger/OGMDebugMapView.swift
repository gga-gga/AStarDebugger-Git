//
//  OGMDebugMapView.swift
//  OGMDebugViewer — 占有格子地図を黒(占有)/白(空き)/灰(未検出)の2Dマップとして描画するデバッグ用View
//
//  描画は「投影の基底ベクトル(前方・右)」を差し替えるだけで2モードを表現する：
//   - カメラ追従（既定）：基底＝カメラの前方/右。常に画面上＝進行方向になり、地図が回る
//   - ワールド固定      ：基底＝北(-Z)固定。地図は回らず、自己位置マーカーだけが回る
//  どちらも同じ投影コードを通るので、モード間で座標変換がズレる余地がない。
//  （ワールド固定は検証用に残してある。タップで切り替え）
//

import UIKit
import simd

final class OGMDebugMapView: UIView {
    struct CameraPose {
        let forwardXZ: simd_float2 // 正規化済み
        let positionXZ: simd_float2
    }

    /// 経路計画の描画内容
    struct PlanOverlay {
        /// A*が返した経路。観測済みセルのみを通るので確定区間として実線で描く。
        var path: [simd_float3] = []
        /// フロンティア目的地（観測済み領域の縁）
        var goal: simd_float3?
        /// タップで指定した最終目標。goalからここまではまだ観測できていないので
        /// 暫定区間として破線で描き分ける。
        var target: simd_float3?
    }

    /// 地図上をタップしたとき、その位置のワールド座標(X,Z)を通知する
    var onTapWorldPosition: ((simd_float2) -> Void)?

    /// 1メートルが何ポイントに相当するか（大きいほどズームイン）
    var pointsPerMeter: CGFloat = 40

    /// true=カメラ追従（進行方向が常に上）／false=ワールド固定（北が常に上）
    var rotatesWithCamera = true {
        didSet { setNeedsDisplay() }
    }

    /// 生の点群ドット表示のON/OFF（原因調査用）
    var showsRawPoints = true

    /// 空きセルをA*のコスト値で色分けするか（コストマップのデバッグ用）
    var showsCostMap = false {
        didSet { setNeedsDisplay() }
    }

    private static let occupiedColor = UIColor.black
    private static let freeColor = UIColor.white
    private static let unknownColor = UIColor.systemGray
    /// 観測上は空きだが、膨張（blockedMarginCells）で経路計画上は通行不可にされたセル
    private static let blockedColor = UIColor(red: 0.5, green: 0.0, blue: 0.1, alpha: 1)

    private var cellSnapshot: [GridCoordinate: CellState] = [:]
    private var costMap: [GridCoordinate: CostCell] = [:]
    private var cellSize: Float = OGMConfig.cellSize
    private var cameraPose: CameraPose?
    private var rawPoints: [ClassifiedPoint] = []
    private var plan = PlanOverlay()

    /// 自己位置を画面のどこに置くか。カメラ追従時は前方を広く見せたいので下寄りにする。
    private var anchorFraction: CGPoint {
        rotatesWithCamera ? CGPoint(x: 0.5, y: 0.72) : CGPoint(x: 0.5, y: 0.5)
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        backgroundColor = Self.unknownColor
        isOpaque = true
        // タップは目標指定に使うので、表示モードの切替は長押しへ移した
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTap(_:))))
        addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:))))
        isUserInteractionEnabled = true
    }

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        guard let pose = cameraPose else { return }
        let anchorFraction = self.anchorFraction
        let anchor = CGPoint(x: bounds.width * anchorFraction.x, y: bounds.height * anchorFraction.y)
        let worldXZ = screenToWorld(recognizer.location(in: self), anchor: anchor, pose: pose)
        onTapWorldPosition?(worldXZ)
    }

    @objc private func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began else { return }
        rotatesWithCamera.toggle()
    }

    func update(cells: [GridCoordinate: CellState], cellSize: Float, cameraPose: CameraPose,
                rawPoints: [ClassifiedPoint] = [], plan: PlanOverlay = PlanOverlay(),
                costMap: [GridCoordinate: CostCell] = [:]) {
        self.cellSnapshot = cells
        self.costMap = costMap
        self.cellSize = cellSize
        self.cameraPose = cameraPose
        self.rawPoints = rawPoints
        self.plan = plan
        setNeedsDisplay()
    }

    // MARK: - 投影の基底

    /// 画面の「上」に対応させるワールド方向。カメラ追従ならカメラ前方、固定なら北(-Z)。
    private func basisForward(for pose: CameraPose) -> simd_float2 {
        rotatesWithCamera ? pose.forwardXZ : simd_float2(0, -1)
    }

    /// 画面の「右」に対応させるワールド方向。
    /// forward=(fx,fz) に対する水平右ベクトルは cross(forward, worldUp) = (-fz, fx)。
    /// 例：forward=(0,-1)（北向き）なら right=(1,0)=+X で、ワールド固定時と一致する。
    private func basisRight(for pose: CameraPose) -> simd_float2 {
        let forward = basisForward(for: pose)
        return simd_float2(-forward.y, forward.x)
    }

    /// ワールド座標(X,Z)を画面座標へ変換する。基底へ射影してから画面へ写すだけ。
    private func worldToScreen(_ worldXZ: simd_float2, anchor: CGPoint, pose: CameraPose) -> CGPoint {
        let relative = worldXZ - pose.positionXZ
        let forwardComponent = simd_dot(relative, basisForward(for: pose)) // 前方距離
        let rightComponent = simd_dot(relative, basisRight(for: pose))     // 右方向距離
        return CGPoint(x: anchor.x + CGFloat(rightComponent) * pointsPerMeter,
                        y: anchor.y - CGFloat(forwardComponent) * pointsPerMeter)
    }

    /// worldToScreen の逆変換。タップ位置と、描画範囲の算出に使う。
    private func screenToWorld(_ point: CGPoint, anchor: CGPoint, pose: CameraPose) -> simd_float2 {
        let rightComponent = Float((point.x - anchor.x) / pointsPerMeter)
        let forwardComponent = Float((anchor.y - point.y) / pointsPerMeter)
        return pose.positionXZ
            + basisForward(for: pose) * forwardComponent
            + basisRight(for: pose) * rightComponent
    }

    // MARK: - 描画

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext(), let pose = cameraPose else { return }

        let anchorFraction = self.anchorFraction
        let anchor = CGPoint(x: rect.width * anchorFraction.x, y: rect.height * anchorFraction.y)
        let visibleRect = rect.insetBy(dx: -32, dy: -32)

        guard let gridRange = gridRange(for: visibleRect, anchor: anchor, pose: pose) else { return }

        // セルは地図と一緒に回転させる（先行研究と同じく、地図全体を1枚の画像として回す）。
        // 以前は中心だけを投影して正方形は画面の縦横に沿ったまま描いていたため、
        // 地図が回ると隣のセル同士が重なったり隙間ができたりして格子が崩れていた。
        // 投影は線形なので、セルの半辺（ワールドの+X方向・+Z方向）を画面へ写したベクトルは
        // 全セル共通。各セルは「中心 ± 2本の半辺ベクトル」の四角形として描く。
        // ワールド固定モードでは基底が(1,0)/(0,-1)なので、従来と同じ軸に沿った正方形になる。
        let halfCellMeters = cellSize / 2
        let right = basisRight(for: pose)
        let forward = basisForward(for: pose)
        // アンチエイリアスで隣接セルの境目に背景色の細い線が出ないよう、0.5ptだけ重ねて描く
        let halfCellPt = CGFloat(halfCellMeters) * pointsPerMeter
        let overlap = (halfCellPt + 0.5) / halfCellPt
        let halfEdgeX = CGPoint(x: CGFloat(halfCellMeters * right.x) * pointsPerMeter * overlap,
                                 y: -CGFloat(halfCellMeters * forward.x) * pointsPerMeter * overlap)
        let halfEdgeZ = CGPoint(x: CGFloat(halfCellMeters * right.y) * pointsPerMeter * overlap,
                                 y: -CGFloat(halfCellMeters * forward.y) * pointsPerMeter * overlap)

        for gz in gridRange.minZ...gridRange.maxZ {
            for gx in gridRange.minX...gridRange.maxX {
                let coord = GridCoordinate(x: gx, z: gz)

                let cellCenterWorld = simd_float2((Float(coord.x) + 0.5) * cellSize,
                                                   (Float(coord.z) + 0.5) * cellSize)
                let c = worldToScreen(cellCenterWorld, anchor: anchor, pose: pose)
                guard visibleRect.contains(c) else { continue }

                ctx.setFillColor(color(for: coord).cgColor)
                ctx.move(to: CGPoint(x: c.x + halfEdgeX.x + halfEdgeZ.x, y: c.y + halfEdgeX.y + halfEdgeZ.y))
                ctx.addLine(to: CGPoint(x: c.x + halfEdgeX.x - halfEdgeZ.x, y: c.y + halfEdgeX.y - halfEdgeZ.y))
                ctx.addLine(to: CGPoint(x: c.x - halfEdgeX.x - halfEdgeZ.x, y: c.y - halfEdgeX.y - halfEdgeZ.y))
                ctx.addLine(to: CGPoint(x: c.x - halfEdgeX.x + halfEdgeZ.x, y: c.y - halfEdgeX.y + halfEdgeZ.y))
                ctx.closePath()
                ctx.fillPath()
            }
        }

        // コスト表示中は生の点群を描かない（赤/緑のドットがコストの色分けと重なって読めなくなるため）
        if showsRawPoints && !showsCostMap {
            drawRawPoints(in: ctx, anchor: anchor, visibleRect: visibleRect, pose: pose)
        }

        drawPlan(in: ctx, anchor: anchor, pose: pose)
        drawSelfMarker(in: ctx, at: anchor, pose: pose)
        drawScaleBar(in: ctx, rect: rect)
    }

    /// 原因調査用：分類済みの生の点群をそのままドットで描く。
    /// non-walkable=赤 / walkable=緑。「グリッドは空きだが実際の点はここに無い」
    /// といったズレを目視確認するためのもの。
    private func drawRawPoints(in ctx: CGContext, anchor: CGPoint, visibleRect: CGRect, pose: CameraPose) {
        let dotRadius: CGFloat = 2.0
        for point in rawPoints {
            let worldXZ = simd_float2(point.worldPosition.x, point.worldPosition.z)
            let screenPoint = worldToScreen(worldXZ, anchor: anchor, pose: pose)
            guard visibleRect.contains(screenPoint) else { continue }

            ctx.setFillColor(rawPointColor(for: point.walkability).cgColor)
            ctx.fillEllipse(in: CGRect(x: screenPoint.x - dotRadius, y: screenPoint.y - dotRadius,
                                        width: dotRadius * 2, height: dotRadius * 2))
        }
    }

    /// A*の経路（実線）と、目的地から最終目標までの未観測区間（破線）を描く。
    private func drawPlan(in ctx: CGContext, anchor: CGPoint, pose: CameraPose) {
        func screenPoint(_ world: simd_float3) -> CGPoint {
            worldToScreen(simd_float2(world.x, world.z), anchor: anchor, pose: pose)
        }

        // 確定区間：観測済みセルだけを通るA*の経路
        if plan.path.count >= 2 {
            ctx.setStrokeColor(UIColor.systemYellow.cgColor)
            ctx.setLineWidth(3)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.setLineDash(phase: 0, lengths: [])
            ctx.move(to: screenPoint(plan.path[0]))
            for waypoint in plan.path.dropFirst() {
                ctx.addLine(to: screenPoint(waypoint))
            }
            ctx.strokePath()
        }

        // 暫定区間：フロンティア目的地から先はまだ観測できていないので破線
        if let goal = plan.goal, let target = plan.target {
            ctx.setStrokeColor(UIColor.systemPurple.cgColor)
            ctx.setLineWidth(2)
            ctx.setLineDash(phase: 0, lengths: [6, 4])
            ctx.move(to: screenPoint(goal))
            ctx.addLine(to: screenPoint(target))
            ctx.strokePath()
            ctx.setLineDash(phase: 0, lengths: [])
        }

        if let goal = plan.goal {
            let point = screenPoint(goal)
            ctx.setFillColor(UIColor.systemYellow.cgColor)
            ctx.fillEllipse(in: CGRect(x: point.x - 5, y: point.y - 5, width: 10, height: 10))
            ctx.setStrokeColor(UIColor.black.cgColor)
            ctx.setLineWidth(1)
            ctx.strokeEllipse(in: CGRect(x: point.x - 5, y: point.y - 5, width: 10, height: 10))
        }

        // タップで指定した最終目標
        if let target = plan.target {
            let point = screenPoint(target)
            ctx.setStrokeColor(UIColor.systemPurple.cgColor)
            ctx.setLineWidth(3)
            ctx.move(to: CGPoint(x: point.x - 7, y: point.y - 7))
            ctx.addLine(to: CGPoint(x: point.x + 7, y: point.y + 7))
            ctx.move(to: CGPoint(x: point.x + 7, y: point.y - 7))
            ctx.addLine(to: CGPoint(x: point.x - 7, y: point.y + 7))
            ctx.strokePath()
        }
    }

    private func rawPointColor(for walkability: Walkability) -> UIColor {
        switch walkability {
        case .nonWalkable: return .systemRed
        case .walkable: return .systemGreen
        }
    }

    private struct GridRange {
        let minX: Int, maxX: Int
        let minZ: Int, maxZ: Int
    }

    /// 画面に映りうる範囲を、画面隅4点を逆変換して求める（回転を考慮した外接矩形）。
    private func gridRange(for visibleRect: CGRect, anchor: CGPoint, pose: CameraPose) -> GridRange? {
        guard pointsPerMeter > 0, cellSize > 0 else { return nil }

        let corners = [
            CGPoint(x: visibleRect.minX, y: visibleRect.minY),
            CGPoint(x: visibleRect.maxX, y: visibleRect.minY),
            CGPoint(x: visibleRect.minX, y: visibleRect.maxY),
            CGPoint(x: visibleRect.maxX, y: visibleRect.maxY)
        ]

        var minWorldX = Float.greatestFiniteMagnitude, maxWorldX = -Float.greatestFiniteMagnitude
        var minWorldZ = Float.greatestFiniteMagnitude, maxWorldZ = -Float.greatestFiniteMagnitude

        for corner in corners {
            let world = screenToWorld(corner, anchor: anchor, pose: pose)
            minWorldX = min(minWorldX, world.x)
            maxWorldX = max(maxWorldX, world.x)
            minWorldZ = min(minWorldZ, world.y)
            maxWorldZ = max(maxWorldZ, world.y)
        }

        let minX = Int(floor(minWorldX / cellSize))
        let maxX = Int(floor(maxWorldX / cellSize))
        let minZ = Int(floor(minWorldZ / cellSize))
        let maxZ = Int(floor(maxWorldZ / cellSize))
        guard minX <= maxX, minZ <= maxZ else { return nil }

        return GridRange(minX: minX, maxX: maxX, minZ: minZ, maxZ: maxZ)
    }

    private func color(for coord: GridCoordinate) -> UIColor {
        guard let state = cellSnapshot[coord] else { return Self.unknownColor } // 未検出
        if state.isOccupied { return Self.occupiedColor }

        // 未検出セルにもコストは付くが、経路計画上どのみち通行不可なので灰のまま塗らない。
        // 色分けするのは観測済みの空きセルだけ。
        guard showsCostMap, let cost = costMap[coord] else { return Self.freeColor }
        if cost.isBlocked { return Self.blockedColor }
        return Self.costColor(cost.baseCost)
    }

    /// コスト0（白）→ β（赤寄りのオレンジ）のグラデーション。
    /// 通行不可セル（濃い赤）とは明度で区別できるようにしてある。
    private static func costColor(_ cost: Float) -> UIColor {
        let t = CGFloat(max(0, min(1, cost / OGMConfig.costBeta)))
        return UIColor(red: 1, green: 1 - 0.7 * t, blue: 1 - 0.85 * t, alpha: 1)
    }

    /// 自己位置マーカー。カメラ追従時は地図の方が回るため、この矢印は常に真上を向く
    /// （基底へ射影した結果が自動的に(0,-1)になるので、モードで場合分けする必要はない）。
    private func drawSelfMarker(in ctx: CGContext, at point: CGPoint, pose: CameraPose) {
        let forwardScreen = CGPoint(x: CGFloat(simd_dot(pose.forwardXZ, basisRight(for: pose))),
                                     y: -CGFloat(simd_dot(pose.forwardXZ, basisForward(for: pose))))
        let rightScreen = CGPoint(x: -forwardScreen.y, y: forwardScreen.x)

        func offset(forwardAmount: CGFloat, rightAmount: CGFloat) -> CGPoint {
            CGPoint(x: point.x + forwardScreen.x * forwardAmount + rightScreen.x * rightAmount,
                    y: point.y + forwardScreen.y * forwardAmount + rightScreen.y * rightAmount)
        }

        let path = CGMutablePath()
        path.move(to: offset(forwardAmount: 11, rightAmount: 0))
        path.addLine(to: offset(forwardAmount: -8, rightAmount: -8))
        path.addLine(to: offset(forwardAmount: -8, rightAmount: 8))
        path.closeSubpath()
        ctx.setFillColor(UIColor.systemBlue.cgColor)
        ctx.addPath(path)
        ctx.fillPath()
        ctx.setStrokeColor(UIColor.white.cgColor)
        ctx.setLineWidth(1.5)
        ctx.addPath(path)
        ctx.strokePath()
    }

    private func drawScaleBar(in ctx: CGContext, rect: CGRect) {
        let barMeters: CGFloat = 1.0
        let barLength = barMeters * pointsPerMeter
        let origin = CGPoint(x: 16, y: rect.height - 28)

        ctx.setStrokeColor(UIColor.systemBlue.cgColor)
        ctx.setLineWidth(3)
        ctx.move(to: origin)
        ctx.addLine(to: CGPoint(x: origin.x + barLength, y: origin.y))
        ctx.strokePath()

        let modeLabel = (rotatesWithCamera ? "1m  [進行方向が上] タップ=目標 長押し=切替"
                                           : "1m  [北が上] タップ=目標 長押し=切替") as NSString
        modeLabel.draw(at: CGPoint(x: origin.x, y: origin.y - 16),
                       withAttributes: [.font: UIFont.boldSystemFont(ofSize: 11), .foregroundColor: UIColor.systemBlue])

        if showsCostMap {
            drawCostLegend(in: ctx, at: CGPoint(x: origin.x, y: origin.y - 40))
        }
    }

    /// コスト表示中の凡例：通行不可の色見本と、コスト0→βのグラデーション帯
    private func drawCostLegend(in ctx: CGContext, at origin: CGPoint) {
        let swatch: CGFloat = 12
        let font = UIFont.boldSystemFont(ofSize: 11)
        var x = origin.x

        Self.blockedColor.setFill()
        ctx.fill(CGRect(x: x, y: origin.y, width: swatch, height: swatch))
        x += swatch + 4
        ("通行不可" as NSString).draw(at: CGPoint(x: x, y: origin.y - 1),
                                   withAttributes: [.font: font, .foregroundColor: UIColor.white])
        x += 60

        ("コスト0" as NSString).draw(at: CGPoint(x: x, y: origin.y - 1),
                                  withAttributes: [.font: font, .foregroundColor: UIColor.white])
        x += 46
        let steps = 10
        let stepWidth: CGFloat = 6
        for i in 0...steps {
            let cost = OGMConfig.costBeta * Float(i) / Float(steps)
            Self.costColor(cost).setFill()
            ctx.fill(CGRect(x: x + CGFloat(i) * stepWidth, y: origin.y, width: stepWidth, height: swatch))
        }
        x += CGFloat(steps + 1) * stepWidth + 4
        ("\(Int(OGMConfig.costBeta))" as NSString).draw(at: CGPoint(x: x, y: origin.y - 1),
                                                          withAttributes: [.font: font, .foregroundColor: UIColor.white])
    }
}
