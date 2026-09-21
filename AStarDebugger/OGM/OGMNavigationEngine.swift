//
//  OGMNavigationEngine.swift
//  占有格子地図（OGM）ナビゲーション — パイプライン全体のオーケストレーション
//
//  呼び出し側（ViewController等）は `update(frame:timestamp:)` を
//  OGMConfig.depthCaptureInterval 相当の間隔（目標10fps）で呼び出し、
//  目標が決まったら `planPath(from:toward:)` で経路を取得する。
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

    /// 経路計画の結果。デバッグ表示のため、失敗時もどの段階で止まったかを返す。
    enum PlanningResult {
        case success(path: [simd_float3], goal: GridCoordinate)
        /// 床面が未推定。観測がまだ足りない。
        case noFloorEstimate
        /// 現在地から到達できる観測済みセルが無い（足元も周囲も未観測など）。
        case noReachableArea
        /// 目的地は決まったがA*が経路を見つけられなかった。
        /// 到達可能性を確認した上で選んだ目的地なので、本来ここには来ないはず。
        case noPath(goal: GridCoordinate)

        var debugDescription: String {
            switch self {
            case .success(let path, _): return "path: \(path.count) cells"
            case .noFloorEstimate: return "path: no floor estimate"
            case .noReachableArea: return "path: no reachable area"
            case .noPath: return "path: goal found but unreachable"
            }
        }
    }

    /// [7]〜[8]：目標（座席など）へ向かう経路を計画する。
    /// 目標がまだ観測範囲外でも、到達可能な観測済みセルのうち目標に最も近いもの
    /// （フロンティア）を目的地にするため、経路は出る。
    @discardableResult
    func planPath(from currentPosition: simd_float3, toward target: simd_float3) -> PlanningResult {
        guard let floorY else { return .noFloorEstimate }

        let costMap = CostMapGenerator(grid: grid).generateCostMap(occupiedCoordinates: grid.cells)
        let startCoord = grid.coordinate(forWorld: currentPosition)
        // 目的地選択とA*で通行可否の判定を共有する（ズレると経路だけ出ない失敗になる）。
        // 足元は未観測になりやすいので、現在地だけは通行可能とみなす。
        let traversability = TraversabilityPolicy(grid: grid,
                                                   costMap: costMap,
                                                   assumedTraversable: [startCoord])

        let selector = FrontierGoalSelector(grid: grid, traversability: traversability)
        guard let goal = selector.selectGoal(from: startCoord, towards: target) else {
            return .noReachableArea
        }

        let planner = AStarPathPlanner(costMap: costMap, isTraversable: traversability.isTraversable)
        guard let cellPath = planner.findPath(from: startCoord, to: goal) else {
            return .noPath(goal: goal)
        }

        let worldPath = cellPath.map { coord -> simd_float3 in
            let center = grid.worldCenter(of: coord)
            return simd_float3(center.x, floorY, center.z)
        }
        currentPath = worldPath
        pathStartPosition = currentPosition
        return .success(path: worldPath, goal: goal)
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
