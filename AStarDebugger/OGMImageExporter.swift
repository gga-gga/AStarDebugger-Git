//
//  OGMImageExporter.swift
//  AStarDebugger — 観測済みOGM全域を画像として書き出す（デバッグ用）
//
//  OGMDebugMapView の描画はカメラ中心・追従表示なので、これまで観測した全体像は
//  画面に一度に収まらない。これとは別に、grid.cells のバウンディングボックス全体を
//  1枚の画像に描く専用のレンダラー。
//

import UIKit
import simd

enum OGMImageExporter {
    private static let pixelsPerCell: CGFloat = 8
    private static let margin: CGFloat = 24
    private static let footerHeight: CGFloat = 28

    /// 観測済みセル全域（grid.cellsのバウンディングボックス）を1枚のUIImageに描画する。
    /// セルが1つも無ければnil。
    static func renderFullMap(cells: [GridCoordinate: CellState],
                               cellSize: Float,
                               path: [simd_float3] = [],
                               selfPosition: simd_float3? = nil) -> UIImage? {
        guard !cells.isEmpty else { return nil }

        let xs = cells.keys.map(\.x)
        let zs = cells.keys.map(\.z)
        let minX = xs.min()!, maxX = xs.max()!
        let minZ = zs.min()!, maxZ = zs.max()!

        let gridWidth = CGFloat(maxX - minX + 1) * pixelsPerCell
        let gridHeight = CGFloat(maxZ - minZ + 1) * pixelsPerCell
        let imageSize = CGSize(width: gridWidth + margin * 2,
                                height: gridHeight + margin * 2 + footerHeight)

        let renderer = UIGraphicsImageRenderer(size: imageSize)
        return renderer.image { rendererContext in
            let ctx = rendererContext.cgContext

            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: imageSize))

            let gridRect = CGRect(x: margin, y: margin, width: gridWidth, height: gridHeight)
            UIColor.systemGray5.setFill() // 未検出セルの背景色
            ctx.fill(gridRect)

            for (coord, state) in cells {
                let origin = CGPoint(x: margin + CGFloat(coord.x - minX) * pixelsPerCell,
                                      y: margin + CGFloat(coord.z - minZ) * pixelsPerCell)
                let color: UIColor = state.isOccupied ? .black : .white
                color.setFill()
                ctx.fill(CGRect(origin: origin, size: CGSize(width: pixelsPerCell, height: pixelsPerCell)))
            }

            ctx.setStrokeColor(UIColor.gray.cgColor)
            ctx.setLineWidth(1)
            ctx.stroke(gridRect)

            func imagePoint(for world: simd_float3) -> CGPoint {
                // worldCenter(of:) は (coord+0.5)*cellSize を返すので、cellSizeで割り戻すと
                // 「セル座標系での連続値」になり、セルの中心が正しく画像上の対応セル中央に来る。
                let gx = world.x / cellSize - Float(minX)
                let gz = world.z / cellSize - Float(minZ)
                return CGPoint(x: CGFloat(gx) * pixelsPerCell + margin,
                                y: CGFloat(gz) * pixelsPerCell + margin)
            }

            if path.count >= 2 {
                ctx.setStrokeColor(UIColor.systemYellow.cgColor)
                ctx.setLineWidth(3)
                ctx.setLineCap(.round)
                ctx.setLineJoin(.round)
                ctx.move(to: imagePoint(for: path[0]))
                for waypoint in path.dropFirst() {
                    ctx.addLine(to: imagePoint(for: waypoint))
                }
                ctx.strokePath()

                if let goal = path.last {
                    drawDot(imagePoint(for: goal), color: .systemYellow, in: ctx)
                }
            }

            if let selfPosition {
                drawDot(imagePoint(for: selfPosition), color: .systemBlue, in: ctx)
            }

            drawFooter(in: ctx, imageSize: imageSize, cellSize: cellSize,
                       cellCount: cells.count, occupiedCount: cells.values.filter(\.isOccupied).count)
        }
    }

    private static func drawDot(_ point: CGPoint, color: UIColor, in ctx: CGContext) {
        let radius: CGFloat = 5
        let rect = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
        color.setFill()
        ctx.fillEllipse(in: rect)
        ctx.setStrokeColor(UIColor.black.cgColor)
        ctx.setLineWidth(1)
        ctx.strokeEllipse(in: rect)
    }

    private static func drawFooter(in ctx: CGContext, imageSize: CGSize, cellSize: Float,
                                    cellCount: Int, occupiedCount: Int) {
        let barMeters: CGFloat = 1.0
        let barLength = barMeters / CGFloat(cellSize) * pixelsPerCell
        let origin = CGPoint(x: margin, y: imageSize.height - footerHeight + 6)

        ctx.setStrokeColor(UIColor.black.cgColor)
        ctx.setLineWidth(2)
        ctx.move(to: origin)
        ctx.addLine(to: CGPoint(x: origin.x + barLength, y: origin.y))
        ctx.strokePath()

        let text = "1m　北=上　cells:\(cellCount) occupied:\(occupiedCount)" as NSString
        text.draw(at: CGPoint(x: origin.x + barLength + 8, y: origin.y - 8),
                   withAttributes: [.font: UIFont.systemFont(ofSize: 12), .foregroundColor: UIColor.black])
    }
}
