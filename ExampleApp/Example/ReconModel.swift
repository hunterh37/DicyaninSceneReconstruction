//
//  ReconModel.swift
//  DicyaninSceneReconstructionExample
//
//  The single "service" object that owns all reconstruction state, keeping the
//  views as thin shells (per the ImmersiveTesting layering conventions).
//

import SwiftUI
import RealityKit
import Combine
import DicyaninSceneReconstruction

@MainActor
final class ReconModel: ObservableObject {
    /// Require ~8 m² scanned before we consider the room "ready".
    let recon = SceneReconstructionManager(requiredScanArea: 8.0)

    // Mirror the manager's @Published values so SwiftUI views update.
    @Published var scannedArea: Float = 0
    @Published var anchorCount: Int = 0
    @Published var isComplete = false

    private var bag = Set<AnyCancellable>()

    init() {
        recon.$scannedSurfaceArea.receive(on: RunLoop.main)
            .assign(to: &$scannedArea)
        recon.$scannedAnchorCount.receive(on: RunLoop.main)
            .assign(to: &$anchorCount)
        recon.$isScanComplete.receive(on: RunLoop.main)
            .assign(to: &$isComplete)
    }

    func start() async { await recon.start(alsoStartHandTracking: false) }
    func stop() { recon.stop() }

    /// Drops a small marker where a ray straight down from `origin` meets the floor.
    @discardableResult
    func dropFloorMarker(from origin: SIMD3<Float> = SIMD3(0, 1.5, 0)) -> Bool {
        guard let hit = recon.raycastToFloor(from: origin) else { return false }
        let marker = ModelEntity(
            mesh: .generateSphere(radius: 0.03),
            materials: [SimpleMaterial(color: .green, isMetallic: false)]
        )
        marker.position = hit.position
        recon.rootEntity.addChild(marker)
        return true
    }
}
