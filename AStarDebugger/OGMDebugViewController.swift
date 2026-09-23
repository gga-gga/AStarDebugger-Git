//
//  OGMDebugViewController.swift
//  OGMDebugViewer — カメラパススルー上に占有格子地図をリアルタイム表示する
//

import ARKit
import SceneKit
import UIKit
import simd

final class OGMDebugViewController: UIViewController, ARSCNViewDelegate {
    private let sceneView = ARSCNView()
    private let mapView = OGMDebugMapView()
    private let statsLabel = UILabel()

    private let exportButton = UIButton(type: .system)

    private let ogmEngine = OGMNavigationEngine()
    private var lastOGMUpdateTime: TimeInterval = 0
    private var lastMapRefreshTime: TimeInterval = 0
    private let mapRefreshInterval: TimeInterval = 0.2 // 表示は5Hzで十分

    /// 地図タップで指定した目標（座席に相当）。指定されている間は毎回再計画する。
    private var targetWorldPosition: simd_float3?
    private var lastPlanningStatus = "path: no target"

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupSceneView()
        setupMapView()
        setupStatsLabel()
        setupExportButton()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        let config = ARWorldTrackingConfiguration()
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
            config.frameSemantics.insert(.smoothedSceneDepth)
        } else if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            config.frameSemantics.insert(.sceneDepth)
        }
        // 水平面（床）を認識させることで、ARKit内部のトラッキング補正が効きやすくなることを期待した軽減策。
        // 直進時に数セル分ドリフトする問題への対策として試験的に追加（劇的な改善は期待していない）。
        config.planeDetection = [.horizontal]
        sceneView.session.run(config)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        sceneView.session.pause()
    }

    /// 画面を上下半分に分割する：上＝ARカメラパススルー、下＝OGMの2Dマップ（黒/白/灰）
    private func setupSceneView() {
        sceneView.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: view.bounds.height / 2)
        sceneView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        sceneView.delegate = self
        sceneView.scene = SCNScene()
        view.addSubview(sceneView)
    }

    private func setupMapView() {
        mapView.frame = CGRect(x: 0, y: view.bounds.height / 2, width: view.bounds.width, height: view.bounds.height / 2)
        mapView.autoresizingMask = [.flexibleWidth, .flexibleTopMargin, .flexibleHeight]
        mapView.onTapWorldPosition = { [weak self] worldXZ in
            // 高さは経路計画では使わないので0で良い（床面はエンジン側が持っている）
            self?.targetWorldPosition = simd_float3(worldXZ.x, 0, worldXZ.y)
        }
        view.addSubview(mapView)
    }

    private func setupStatsLabel() {
        statsLabel.numberOfLines = 0
        statsLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        statsLabel.textColor = .white
        statsLabel.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        statsLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statsLabel)
        NSLayoutConstraint.activate([
            statsLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            statsLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            statsLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -8)
        ])
    }

    /// 観測済みOGM全域を画像として書き出し、共有シートで取り出せるようにするボタン。
    private func setupExportButton() {
        var config = UIButton.Configuration.filled()
        config.title = "OGMを書き出し"
        config.baseBackgroundColor = UIColor.black.withAlphaComponent(0.6)
        config.baseForegroundColor = .white
        config.cornerStyle = .medium
        exportButton.configuration = config
        exportButton.addTarget(self, action: #selector(exportOGMImage), for: .touchUpInside)
        exportButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(exportButton)
        NSLayoutConstraint.activate([
            exportButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            exportButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8)
        ])
    }

    @objc private func exportOGMImage() {
        let selfPosition = sceneView.session.currentFrame.map { frame -> simd_float3 in
            let m = frame.camera.transform
            return simd_float3(m.columns.3.x, m.columns.3.y, m.columns.3.z)
        }

        guard let image = OGMImageExporter.renderFullMap(cells: ogmEngine.grid.cells,
                                                          cellSize: ogmEngine.grid.cellSize,
                                                          path: ogmEngine.currentPath,
                                                          selfPosition: selfPosition) else {
            let alert = UIAlertController(title: "書き出し不可", message: "まだ観測されたセルがありません",
                                          preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
            return
        }

        let activityController = UIActivityViewController(activityItems: [image], applicationActivities: nil)
        if let popover = activityController.popoverPresentationController {
            popover.sourceView = exportButton
            popover.sourceRect = exportButton.bounds
        }
        present(activityController, animated: true)
    }

    // MARK: - ARSCNViewDelegate

    func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        guard let frame = sceneView.session.currentFrame else { return }

        if time - lastOGMUpdateTime >= OGMConfig.depthCaptureInterval {
            lastOGMUpdateTime = time
            ogmEngine.update(frame: frame, timestamp: time)
        }

        guard time - lastMapRefreshTime >= mapRefreshInterval else { return }
        lastMapRefreshTime = time

        let pose = cameraPose(from: frame)
        let cells = ogmEngine.grid.cells
        let cellSize = ogmEngine.grid.cellSize
        let rawPoints = ogmEngine.lastClassifiedPoints
        let plan = replanIfNeeded(frame: frame)
        let statsText = self.statsText(cells: cells, rawPoints: rawPoints, pose: pose)

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.mapView.update(cells: cells, cellSize: cellSize, cameraPose: pose,
                                rawPoints: rawPoints, plan: plan)
            self.statsLabel.text = statsText
        }
    }

    /// 目標が指定されていれば毎回（5Hz）計画し直す。地図が広がるにつれて経路が
    /// どう伸びるかを見たいので、まずは「半分歩いたら再計画」ではなく常時更新する。
    private func replanIfNeeded(frame: ARFrame) -> OGMDebugMapView.PlanOverlay {
        guard let target = targetWorldPosition else {
            lastPlanningStatus = "path: no target (地図をタップ)"
            return OGMDebugMapView.PlanOverlay()
        }

        let m = frame.camera.transform
        let currentPosition = simd_float3(m.columns.3.x, m.columns.3.y, m.columns.3.z)
        let result = ogmEngine.planPath(from: currentPosition, toward: target)
        lastPlanningStatus = result.debugDescription

        var overlay = OGMDebugMapView.PlanOverlay()
        overlay.target = target
        if case .success(let path, let goal) = result {
            overlay.path = path
            let goalCenter = ogmEngine.grid.worldCenter(of: goal)
            overlay.goal = simd_float3(goalCenter.x, 0, goalCenter.z)
        }
        return overlay
    }

    /// カメラの水平（Yaw）成分だけを取り出す。ロール/ピッチは無視する。
    /// マップ自体はワールド固定（回転なし）なので、ここではパン位置(positionXZ)と
    /// 自己位置マーカーの向き表示用のforwardXZだけを渡せばよい。
    private func cameraPose(from frame: ARFrame) -> OGMDebugMapView.CameraPose {
        let m = frame.camera.transform
        let position = simd_float2(m.columns.3.x, m.columns.3.z)

        let back = simd_float3(m.columns.2.x, m.columns.2.y, m.columns.2.z)
        let forward = -back
        let forwardH = simd_normalize(simd_float3(forward.x, 0, forward.z))

        return OGMDebugMapView.CameraPose(
            forwardXZ: simd_float2(forwardH.x, forwardH.z),
            positionXZ: position
        )
    }

    private func statsText(cells: [GridCoordinate: CellState], rawPoints: [ClassifiedPoint],
                            pose: OGMDebugMapView.CameraPose) -> String {
        let occupiedCount = cells.values.filter { $0.isOccupied }.count
        let freeCount = cells.count - occupiedCount
        let nonWalkablePts = rawPoints.filter { $0.walkability == .nonWalkable }.count
        let walkablePts = rawPoints.filter { $0.walkability == .walkable }.count

        // 原因調査用：最も近い non-walkable 点の「カメラ位置からの相対X・相対Z」を生の数値で表示する。
        // 目視でのドット位置判断ではなく、符号そのもので左右反転の有無を確認するため。
        let debugLine: String
        if let nearest = rawPoints
            .filter({ $0.walkability == .nonWalkable })
            .min(by: {
                simd_length(simd_float2($0.worldPosition.x, $0.worldPosition.z) - pose.positionXZ) <
                simd_length(simd_float2($1.worldPosition.x, $1.worldPosition.z) - pose.positionXZ)
            }) {
            let rel = simd_float2(nearest.worldPosition.x, nearest.worldPosition.z) - pose.positionXZ
            debugLine = String(format: "nearest non-walkable: relX=%.2f relZ=%.2f | forward=(%.2f,%.2f)",
                                rel.x, rel.y, pose.forwardXZ.x, pose.forwardXZ.y)
        } else {
            debugLine = "nearest non-walkable: (none)"
        }

        return """
        A* Debug
        observed cells: \(cells.count)
        occupied: \(occupiedCount)
        free: \(freeCount)
        raw pts: \(rawPoints.count) (walkable:\(walkablePts) nonWalkable:\(nonWalkablePts))
        \(debugLine)
        \(lastPlanningStatus)
        """
    }
}
