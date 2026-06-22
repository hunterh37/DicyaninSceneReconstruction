//
//  MeshAnchorTracker.swift
//  DicyaninSceneReconstruction
//
//  Tracks `MeshAnchor` updates from a `SceneReconstructionProvider` and maintains
//  a matching set of `ModelEntity` instances with collision + (optional) render
//  geometry. Throttles geometry rebuilds so large rooms don't flood the GPU.
//
//  Reusable extraction from ZombieShooter — all game-specific coupling
//  (collision groups, shaders, game registries) removed.
//

import ARKit
import RealityKit
import Foundation
import simd

/// Maintains `ModelEntity` representations of tracked scene-reconstruction mesh anchors.
///
/// Each tracked anchor produces one `ModelEntity` parented under ``rootEntity`` with:
/// - a static `PhysicsBodyComponent` + `CollisionComponent` built from the anchor
///   geometry (so RealityKit can resolve contacts and raycasts against the real room), and
/// - a `ModelComponent` rendered with ``material`` (defaults to `OcclusionMaterial`,
///   which makes real-world geometry occlude virtual content).
///
/// All access is `@MainActor` — ARKit geometry buffers must be read on the main queue.
@MainActor
public final class MeshAnchorTracker {

    /// Root entity that all generated mesh chunks are parented under.
    /// Add this to your `RealityView` content to place the tracked mesh in the scene.
    public let rootEntity: Entity

    /// Material applied to the rendered mesh of every chunk.
    /// Defaults to `OcclusionMaterial()`. Changing this affects chunks created afterwards.
    public var material: RealityKit.Material

    /// Anchors currently tracked, parallel to ``entities``.
    public private(set) var anchors: [MeshAnchor] = []

    /// Mesh-chunk entities currently tracked, parallel to ``anchors``.
    public private(set) var entities: [ModelEntity] = []

    // MARK: - Render-mesh decimation (optional perf knob)
    //
    // Apple's immersive-scene triangle ceiling is ~500k; a fully scanned room mesh can
    // approach that. When `decimateSceneMesh` is true, the *render* mesh keeps only every
    // `meshDecimationStride`-th face. The COLLISION shape is always built from the full,
    // untouched anchor — hit detection and occlusion fidelity are never reduced.

    /// When `true`, the rendered mesh is thinned by ``meshDecimationStride``. Default `false`.
    public var decimateSceneMesh = false

    /// Keep 1 of every N faces when ``decimateSceneMesh`` is enabled. Default `2`.
    public var meshDecimationStride = 2

    // MARK: - Throttle phases

    /// Controls how aggressively geometry rebuilds are rate-limited.
    public enum ThrottlePhase {
        /// Initial scan — updates processed promptly (short cooldown).
        case scanning
        /// Scan settled — rebuilds throttled per anchor and gated on face-count delta.
        case postScan
        /// Locked-in — very long cooldown; only large changes pass.
        case gameplay
    }

    public private(set) var throttlePhase: ThrottlePhase = .scanning

    private let faceChangeFraction: Float = 0.08
    private let scanningCooldown: TimeInterval = 0.5
    private let postScanCooldown: TimeInterval = 4.0
    private let gameplayCooldown: TimeInterval = 20.0
    private var lastGeometryUpdate: [UUID: Date] = [:]

    // MARK: - Init

    public init(rootEntity: Entity = Entity(),
                material: RealityKit.Material = OcclusionMaterial()) {
        self.rootEntity = rootEntity
        self.material = material
    }

    // MARK: - Phase control

    /// Move into the post-scan throttle once the room is roughly mapped.
    public func enterPostScanPhase() {
        guard throttlePhase == .scanning else { return }
        throttlePhase = .postScan
    }

    /// Move into the most aggressive throttle once the environment should be considered locked.
    public func enterGameplayPhase() {
        guard throttlePhase != .gameplay else { return }
        throttlePhase = .gameplay
    }

    // MARK: - Lifecycle

    /// Removes all tracked anchors/entities and resets throttle state.
    public func reset() {
        anchors = []
        for entity in entities { entity.removeFromParent() }
        entities = []
        lastGeometryUpdate.removeAll()
        throttlePhase = .scanning
    }

    /// Whether an anchor with the given id is already tracked.
    public func contains(_ anchor: MeshAnchor) -> Bool {
        anchors.contains { $0.id == anchor.id }
    }

    // MARK: - Anchor handling

    /// Creates a new tracked entity for a previously unseen anchor.
    public func createNewModel(anchor: MeshAnchor) async {
        let entity = ModelEntity()
        entity.name = "\(anchor.id)"

        anchors.append(anchor)
        entities.append(entity)

        entity.components.set(SceneUnderstandingComponent(entityType: .meshChunk))
        rootEntity.addChild(entity)

        await updateMeshAndCollision(anchor: anchor, entity: entity)
        lastGeometryUpdate[anchor.id] = Date()
    }

    /// Updates an existing tracked entity, or creates one if not yet tracked.
    public func updateAnchor(anchor: MeshAnchor) async {
        guard let index = anchors.firstIndex(where: { $0.id == anchor.id }) else {
            await createNewModel(anchor: anchor)
            return
        }
        guard index < entities.count else { return }
        let entity = entities[index]

        // Transform updates are cheap — always apply.
        entity.transform = Transform(matrix: anchor.originFromAnchorTransform)

        let oldFaces = anchors[index].geometry.faces.count
        let newFaces = anchor.geometry.faces.count
        guard shouldRebuildGeometry(anchorID: anchor.id, oldFaces: oldFaces, newFaces: newFaces) else { return }

        anchors[index] = anchor
        await updateMeshAndCollision(anchor: anchor, entity: entity)
        lastGeometryUpdate[anchor.id] = Date()
    }

    private func shouldRebuildGeometry(anchorID: UUID, oldFaces: Int, newFaces: Int) -> Bool {
        guard newFaces != oldFaces else { return false }

        switch throttlePhase {
        case .scanning:
            if let last = lastGeometryUpdate[anchorID],
               Date().timeIntervalSince(last) < scanningCooldown {
                return false
            }
            return true
        case .postScan, .gameplay:
            let cooldown = throttlePhase == .postScan ? postScanCooldown : gameplayCooldown
            if let last = lastGeometryUpdate[anchorID],
               Date().timeIntervalSince(last) < cooldown {
                return false
            }
            let base = max(oldFaces, 1)
            let delta = abs(newFaces - oldFaces)
            return Float(delta) / Float(base) >= faceChangeFraction
        }
    }

    private func updateMeshAndCollision(anchor: MeshAnchor, entity: ModelEntity) async {
        entity.transform = Transform(matrix: anchor.originFromAnchorTransform)

        // 1. Collision shape — always full fidelity, straight from the anchor.
        if let shape = try? await ShapeResource.generateStaticMesh(from: anchor) {
            var collision = CollisionComponent(shapes: [shape], mode: .colliding)
            collision.collisionOptions = .fullContactInformation
            entity.components.set(collision)

            if entity.components[PhysicsBodyComponent.self] == nil {
                entity.components.set(PhysicsBodyComponent(
                    massProperties: .default,
                    material: .default,
                    mode: .static
                ))
            }
        }

        // 2. Render mesh (optionally decimated).
        let geom = anchor.geometry
        var desc = MeshDescriptor()
        desc.positions = .init(geom.vertices.asSIMD3(ofType: Float.self))
        desc.normals = .init(geom.normals.asSIMD3(ofType: Float.self))

        let faceCount = geom.faces.count
        let indexCountPerFace = geom.faces.primitive.indexCount
        let bytesPerIndex = geom.faces.bytesPerIndex
        let indexBufferPtr = geom.faces.buffer.contents()

        let stride = max(1, decimateSceneMesh ? meshDecimationStride : 1)
        let faceIndicesToKeep: [Int] = stride == 1
            ? Array(0..<faceCount)
            : Array(Swift.stride(from: 0, to: faceCount, by: stride))

        var indices: [UInt32] = []
        indices.reserveCapacity(faceIndicesToKeep.count * indexCountPerFace)
        for f in faceIndicesToKeep {
            for k in 0..<indexCountPerFace {
                let byteOffset = (f * indexCountPerFace + k) * bytesPerIndex
                if bytesPerIndex == 2 {
                    indices.append(UInt32(indexBufferPtr.advanced(by: byteOffset)
                        .assumingMemoryBound(to: UInt16.self).pointee))
                } else {
                    indices.append(indexBufferPtr.advanced(by: byteOffset)
                        .assumingMemoryBound(to: UInt32.self).pointee)
                }
            }
        }
        desc.primitives = .triangles(indices)

        if let meshResource = try? await MeshResource(from: [desc]) {
            entity.components.set(ModelComponent(mesh: meshResource, materials: [material]))
        }
    }
}

// MARK: - Surface detection

public extension MeshAnchorTracker {

    /// A spatially-clustered surface detected from scene-mesh face classifications.
    struct DetectedSurface {
        /// World-space centroid of the cluster.
        public var center: SIMD3<Float>
        /// World-space outward normal (un-oriented).
        public var normal: SIMD3<Float>
        /// Number of faces in the cluster — a rough proxy for area.
        public var faceCount: Int
    }

    /// Finds faces matching `target` (e.g. `.window`, `.floor`), converts them to world
    /// space and greedily clusters them into distinct surfaces, largest first.
    ///
    /// - Important: Must be called on the main queue (geometry buffer access).
    func detectSurfaces(matching target: MeshAnchor.MeshClassification,
                        clusterRadius: Float = 0.8,
                        minFaces: Int = 4) -> [DetectedSurface] {
        var faceCenters: [SIMD3<Float>] = []
        var faceNormals: [SIMD3<Float>] = []

        for anchor in anchors {
            let geom = anchor.geometry
            guard geom.classifications != nil else { continue }

            let verts = geom.vertices.asSIMD3(ofType: Float.self)
            let faceCount = geom.faces.count
            let indexCount = geom.faces.primitive.indexCount
            guard indexCount >= 3 else { continue }
            let bytesPerIndex = geom.faces.bytesPerIndex
            let buf = geom.faces.buffer.contents()
            let xform = anchor.originFromAnchorTransform

            for f in 0..<faceCount {
                guard geom.classificationOf(faceWithIndex: f) == target else { continue }

                var idxs: [Int] = []
                idxs.reserveCapacity(indexCount)
                for k in 0..<indexCount {
                    let byteOffset = (f * indexCount + k) * bytesPerIndex
                    let vi = Int(buf.advanced(by: byteOffset)
                        .assumingMemoryBound(to: UInt32.self).pointee)
                    guard vi < verts.count else { continue }
                    idxs.append(vi)
                }
                guard idxs.count >= 3 else { continue }

                let localSum = idxs.reduce(SIMD3<Float>(repeating: 0)) { $0 + verts[$1] }
                let localCentroid = localSum / Float(idxs.count)
                let world4 = xform * SIMD4<Float>(localCentroid, 1)
                faceCenters.append(SIMD3<Float>(world4.x, world4.y, world4.z))

                let a = verts[idxs[0]], b = verts[idxs[1]], c = verts[idxs[2]]
                let localNormal = simd_cross(b - a, c - a)
                let worldN4 = xform * SIMD4<Float>(localNormal, 0)
                let worldN = SIMD3<Float>(worldN4.x, worldN4.y, worldN4.z)
                let len = simd_length(worldN)
                faceNormals.append(len > 1e-5 ? worldN / len : SIMD3<Float>(0, 0, 1))
            }
        }

        struct Cluster { var sum: SIMD3<Float>; var nSum: SIMD3<Float>; var count: Int }
        var clusters: [Cluster] = []
        for i in 0..<faceCenters.count {
            let p = faceCenters[i]
            if let ci = clusters.firstIndex(where: {
                simd_distance($0.sum / Float($0.count), p) < clusterRadius
            }) {
                clusters[ci].sum += p
                clusters[ci].nSum += faceNormals[i]
                clusters[ci].count += 1
            } else {
                clusters.append(Cluster(sum: p, nSum: faceNormals[i], count: 1))
            }
        }

        return clusters
            .filter { $0.count >= minFaces }
            .map { c in
                let n = simd_length(c.nSum) > 1e-5 ? simd_normalize(c.nSum) : SIMD3<Float>(0, 1, 0)
                return DetectedSurface(center: c.sum / Float(c.count),
                                       normal: n,
                                       faceCount: c.count)
            }
            .sorted { $0.faceCount > $1.faceCount }
    }
}
