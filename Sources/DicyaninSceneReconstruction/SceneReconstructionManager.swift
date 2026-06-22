//
//  SceneReconstructionManager.swift
//  DicyaninSceneReconstruction
//
//  Drives a `SceneReconstructionProvider`, maintains the tracked mesh via
//  `MeshAnchorTracker`, reports scan coverage, and exposes downward / floor
//  raycast helpers.
//
//  Reusable extraction from ZombieShooter with all game-specific coupling
//  (shaders, glitch effects, collision-group registries, hit-impact prewarm)
//  removed. ARKit is driven entirely through the shared `DicyaninARKitSession`:
//  scene reconstruction (and, optionally, hand tracking) run on that one session,
//  per Apple's single-session guidance.
//

import ARKit
import RealityKit
import Combine
import simd
import DicyaninARKitSession

/// Manages scene reconstruction on visionOS: starts/stops a
/// `SceneReconstructionProvider`, exposes the tracked mesh anchors and their
/// entities, tracks scan coverage, and provides floor/downward raycasts.
///
/// Per the immersive-app scaffold conventions this type is the *service* that
/// owns all ARKit calls; keep your `RealityView`/view-model free of provider code
/// and talk to this object instead.
@MainActor
public final class SceneReconstructionManager: ObservableObject {

    /// Whether the current device supports scene reconstruction.
    public static var isSupported: Bool { SceneReconstructionProvider.isSupported }

    /// Root entity holding every tracked mesh chunk. Add this to your `RealityView` content.
    public var rootEntity: Entity { tracker.rootEntity }

    /// Tracked mesh anchors (parallel to ``meshEntities``).
    public var anchors: [MeshAnchor] { tracker.anchors }

    /// Tracked mesh-chunk entities (parallel to ``anchors``).
    public var meshEntities: [ModelEntity] { tracker.entities }

    /// The underlying anchor tracker — exposed for surface detection, decimation
    /// knobs, throttle-phase control, and material changes.
    public let tracker: MeshAnchorTracker

    // MARK: - Scan coverage

    /// Total estimated surface area scanned so far, in m².
    @Published public private(set) var scannedSurfaceArea: Float = 0
    /// Number of mesh anchors contributing to the scan.
    @Published public private(set) var scannedAnchorCount: Int = 0
    /// `true` once ``scannedSurfaceArea`` reaches ``requiredScanArea`` (or immediately
    /// if reconstruction is unsupported / no area is required).
    @Published public private(set) var isScanComplete: Bool = false

    /// Minimum scanned area (m²) before ``isScanComplete`` flips. `0` completes immediately.
    public var requiredScanArea: Float

    /// Fraction of ``requiredScanArea`` covered so far, clamped to `0...1`.
    public var scanProgress: Double {
        guard Self.isSupported, requiredScanArea > 0 else { return 1.0 }
        return min(Double(scannedSurfaceArea / requiredScanArea), 1.0)
    }

    private var anchorSurfaceAreas: [UUID: Float] = [:]

    // MARK: - ARKit session

    private var updateTask: Task<Void, Never>?
    private var startedSharedSession = false

    // MARK: - Init

    /// - Parameters:
    ///   - rootEntity: Entity to parent mesh chunks under. Defaults to a fresh entity.
    ///   - material: Material for rendered chunks. Defaults to `OcclusionMaterial`.
    ///   - requiredScanArea: Area (m²) needed before ``isScanComplete`` flips. Default `0`.
    public init(rootEntity: Entity = Entity(),
                material: RealityKit.Material = OcclusionMaterial(),
                requiredScanArea: Float = 0) {
        self.tracker = MeshAnchorTracker(rootEntity: rootEntity, material: material)
        self.requiredScanArea = requiredScanArea
        self.isScanComplete = !Self.isSupported
    }

    // MARK: - Lifecycle

    /// Starts scene reconstruction on the shared `DicyaninARKitSession` and begins
    /// consuming mesh anchor updates. Safe to call repeatedly — restarts cleanly.
    ///
    /// - Parameter alsoStartHandTracking: When `true`, also enables hand tracking on the
    ///   shared session (both run on the one `ARKitSession`).
    public func start(alsoStartHandTracking: Bool = false) async {
        guard Self.isSupported else {
            resetScanProgress()
            isScanComplete = true
            return
        }

        stop()
        resetScanProgress()
        tracker.reset()

        // Consume the shared scene-reconstruction stream on the main actor.
        updateTask = Task { @MainActor [weak self] in
            for await update in ARKitSessionManager.shared.sceneReconstructionUpdates {
                if Task.isCancelled { break }
                await self?.handle(update)
            }
        }

        do {
            try await ARKitSessionManager.shared.start(handTracking: alsoStartHandTracking,
                                                       sceneReconstruction: true)
            startedSharedSession = true
        } catch {
            srLog.error("Shared ARKit session failed to start: \(error.localizedDescription)")
        }
    }

    /// Stops consuming updates and releases this manager's hold on the shared session.
    public func stop() {
        updateTask?.cancel()
        updateTask = nil
        if startedSharedSession {
            ARKitSessionManager.shared.stop()
            startedSharedSession = false
        }
    }

    /// Clears scan-coverage state. Does not stop the session.
    public func resetScanProgress() {
        anchorSurfaceAreas.removeAll()
        scannedSurfaceArea = 0
        scannedAnchorCount = 0
        isScanComplete = !Self.isSupported
    }

    // MARK: - Raycasting

    /// Casts straight down from `origin` and returns the nearest floor-like surface.
    public func raycastToFloor(from origin: SIMD3<Float>,
                               maxDistance: Float = 20,
                               minUpwardDot: Float = 0.7) -> MeshRaycastHit? {
        guard let scene = rootEntity.scene else { return nil }
        return SceneMeshRaycaster.raycastToFloor(from: origin,
                                                 in: scene,
                                                 meshEntities: meshEntities,
                                                 maxDistance: maxDistance,
                                                 minUpwardDot: minUpwardDot)
    }

    /// Casts a ray in an arbitrary direction and returns the nearest scene-mesh hit.
    public func raycast(from origin: SIMD3<Float>,
                        direction: SIMD3<Float>,
                        maxDistance: Float = 20) -> MeshRaycastHit? {
        guard let scene = rootEntity.scene else { return nil }
        return SceneMeshRaycaster.raycast(from: origin,
                                          direction: direction,
                                          in: scene,
                                          meshEntities: meshEntities,
                                          maxDistance: maxDistance)
    }

    // MARK: - Anchor updates

    private func handle(_ update: AnchorUpdate<MeshAnchor>) async {
        updateScanCoverage(for: update)

        if tracker.contains(update.anchor) {
            await tracker.updateAnchor(anchor: update.anchor)
        } else {
            await tracker.createNewModel(anchor: update.anchor)
        }
    }

    private func updateScanCoverage(for update: AnchorUpdate<MeshAnchor>) {
        switch update.event {
        case .added, .updated:
            anchorSurfaceAreas[update.anchor.id] = estimatedSurfaceArea(for: update.anchor)
        case .removed:
            anchorSurfaceAreas.removeValue(forKey: update.anchor.id)
        }

        scannedAnchorCount = anchorSurfaceAreas.count
        scannedSurfaceArea = anchorSurfaceAreas.values.reduce(0, +)

        let wasComplete = isScanComplete
        isScanComplete = requiredScanArea <= 0 || scannedSurfaceArea >= requiredScanArea
        if !wasComplete && isScanComplete {
            tracker.enterPostScanPhase()
        }
    }

    private func estimatedSurfaceArea(for anchor: MeshAnchor) -> Float {
        let extents = anchor.boundingBox.extents
        let sorted = [abs(extents.x), abs(extents.y), abs(extents.z)].sorted(by: >)
        guard sorted.count >= 2 else { return 0 }
        let area = sorted[0] * sorted[1]
        return area.isFinite ? max(area, 0) : 0
    }
}
