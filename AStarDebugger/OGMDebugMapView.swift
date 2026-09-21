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

    /// 1メートルが何ポイントに相当するか（大きいほどズームイン）
    var pointsPerMeter: CGFloat = 40

    /// true=カメラ追従（進行方向が常に上）／false=ワールド固定（北が常に上）
    var rotatesWithCamera = true {
        didSet { setNeedsDisplay() }
    }

    /// 生の点群ドット表示のON/OFF（原因調査用）
    var showsRawPoints = true

    private static let occupiedColor = UIColor.black
    private static let freeColor = UIColor.white
    private static let unknownColor = UIColor.systemGray

    private var cellSnapshot: [GridCoordinate: CellState] = [:]
    private var cellSize: Float = OGMConfig.cellSize
    private var cameraPose: CameraPose?
    private var rawPoints: [ClassifiedPoint] = []

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
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(toggleRotationMode)))
        isUserInteractionEnabled = true
    }

    @objc private func toggleRotationMode() {
        rotatesWithCamera.toggle()
    }

    func update(cells: [GridCoordinate: CellState], cellSize: Float, cameraPose: CameraPose,
                rawPoints: [ClassifiedPoint] = []) {
        self.cellSnapshot = cells
        self.cellSize = cellSize
        self.cameraPose = cameraPose
        self.rawPoints = rawPoints
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

    // MARK: - 描画

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext(), let pose = cameraPose else { return }

        let anchorFraction = self.anchorFraction
        let anchor = CGPoint(x: rect.width * anchorFraction.x, y: rect.height * anchorFraction.y)
        let visibleRect = rect.insetBy(dx: -32, dy: -32)
        let halfCellPt = CGFloat(cellSize) * pointsPerMeter / 2

        guard let gridRange = gridRange(for: visibleRect, anchor: anchor, pose: pose) else { return }

        for gz in gridRange.minZ...gridRange.maxZ {
            for gx in gridRange.minX...gridRange.maxX {
                let coord = GridCoordinate(x: gx, z: gz)

                let cellCenterWorld = simd_float2((Float(coord.x) + 0.5) * cellSize,
                                                   (Float(coord.z) + 0.5) * cellSize)
                let screenPoint = worldToScreen(cellCenterWorld, anchor: anchor, pose: pose)
                guard visibleRect.contains(screenPoint) else { continue }

                ctx.setFillColor(color(for: coord).cgColor)
                ctx.fill(CGRect(x: screenPoint.x - halfCellPt, y: screenPoint.y - halfCellPt,
                                 width: halfCellPt * 2, height: halfCellPt * 2))
            }
        }

        if showsRawPoints {
            drawRawPoints(in: ctx, anchor: anchor, visibleRect: visibleRect, pose: pose)
        }

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

        let forward = basisForward(for: pose)
        let right = basisRight(for: pose)
        let corners = [
            CGPoint(x: visibleRect.minX, y: visibleRect.minY),
            CGPoint(x: visibleRect.maxX, y: visibleRect.minY),
            CGPoint(x: visibleRect.minX, y: visibleRect.maxY),
            CGPoint(x: visibleRect.maxX, y: visibleRect.maxY)
        ]

        var minWorldX = Float.greatestFiniteMagnitude, maxWorldX = -Float.greatestFiniteMagnitude
        var minWorldZ = Float.greatestFiniteMagnitude, maxWorldZ = -Float.greatestFiniteMagnitude

        for corner in corners {
            let rightComponent = Float((corner.x - anchor.x) / pointsPerMeter)
            let forwardComponent = Float((anchor.y - corner.y) / pointsPerMeter)
            let world = pose.positionXZ + forward * forwardComponent + right * rightComponent
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
        return state.isOccupied ? Self.occupiedColor : Self.freeColor
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

        let modeLabel = (rotatesWithCamera ? "1m  [進行方向が上] タップで切替" : "1m  [北が上] タップで切替") as NSString
        modeLabel.draw(at: CGPoint(x: origin.x, y: origin.y - 16),
                       withAttributes: [.font: UIFont.boldSystemFont(ofSize: 11), .foregroundColor: UIColor.systemBlue])
    }
}
