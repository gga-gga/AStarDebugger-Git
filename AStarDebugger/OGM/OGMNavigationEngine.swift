//
//  OGMNavigationEngine.swift
//  占有格子地図（OGM）ナビゲーション — パイプライン全体のオーケストレーション
//
//  呼び出し側（ViewController等）は `update(frame:timestamp:)` を
//  OGMConfig.depthCaptureInterval 相当の間隔（目標10fps）で呼び出し、
//  空席が定まったら `planPath(from:toSeatAt:)` で経路を取得する。
//

import ARKit
import simd

final class OGMNavigationEngine {
    private let pointCloudExtractor = DepthPointCloudExtractor()
    private(set) var grid = OccupancyGridMap()

    /// 直近フレームで分類された生の点群（デバッグ表示用）
    private(set) var lastClassifiedPoints: [ClassifiedPoint] = []

    private var floorY: Float?
    private var lastFloorEstimateTime: TimeInterval = 0

    private(set) var currentPath: [simd_float3] = []
    private var pathStartPosition: simd_float3?

    /// [1]〜[6]：深度観測を取得しOGMへ反映する。目標10fps相当で呼び出すこと。
    func update(frame: ARFrame, timestamp: TimeInterval) {
        let depthPoints = pointCloudExtractor.extractPoints(from: frame)
        guard !depthPoints.isEmpty else { return }

        if floorY == nil || timestamp - lastFloorEstimateTime >= OGMConfig.floorReestimateIntervalSeconds {
            let positions = depthPoints.map { $0.worldPosition }
            if let estimatedFloorY = FloorPlaneEstimator.estimateFloorY(from: positions) {
                floorY = estimatedFloorY
                lastFloorEstimateTime = timestamp
            }
        }
        guard let floorY else { return }

        let classified = WalkabilityClassifier(floorY: floorY).classify(depthPoints)
        lastClassifiedPoints = classified
        grid.integrate(classifiedPoints: classified)
    }

    /// [7]〜[8]：空席のワールド座標を目的地として、通路側セルまでのA*経路を計画する。
    /// - Parameter aisleDirection: 座席→通路方向のヒント（水平面）。分かる場合に渡すと目的地選定の精度が上がる。
    @discardableResult
    func planPath(from currentPosition: simd_float3,
                  toSeatAt seatWorldPosition: simd_float3,
                  aisleDirection: simd_float3? = nil) -> [simd_float3]? {
        guard let floorY else { return nil }

        let costMap = CostMapGenerator(grid: grid).generateCostMap(occupiedCoordinates: grid.cells)
        let resolver = SeatTargetResolver(grid: grid, costMap: costMap)
        guard let destination = resolver.resolveDestination(seatWorldPosition: seatWorldPosition,
                                                              preferredDirection: aisleDirection) else {
            return nil
        }

        let planner = AStarPathPlanner(costMap: costMap, cellSize: grid.cellSize) { [grid] coord in
            if costMap[coord]?.isBlocked == true { return false }
            if let state = grid.state(at: coord), state.isOccupied { return false }
            return true
        }

        let startCoord = grid.coordinate(forWorld: currentPosition)
        guard let cellPath = planner.findPath(from: startCoord, to: destination) else { return nil }

        let worldPath = cellPath.map { coord -> simd_float3 in
            let center = grid.worldCenter(of: coord)
            return simd_float3(center.x, floorY, center.z)
        }
        currentPath = worldPath
        pathStartPosition = currentPosition
        return worldPath
    }

    /// 計画済み経路の半分を歩いたら再計画する（7章の初期方針）
    func shouldReplan(currentPosition: simd_float3) -> Bool {
        guard let start = pathStartPosition, let goal = currentPath.last else { return false }
        let totalDistance = simd_length(goal - start)
        guard totalDistance > 0 else { return false }
        let traveled = simd_length(currentPosition - start)
        return traveled >= totalDistance * OGMConfig.replanAtPathFractionWalked
    }
}
