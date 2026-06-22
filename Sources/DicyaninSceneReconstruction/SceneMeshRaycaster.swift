//
//  SceneMeshRaycaster.swift
//  DicyaninSceneReconstruction
//
//  Downward / arbitrary-direction raycasts against the reconstructed scene mesh.
//  Uses RealityKit's collision raycast against the static colliders that
//  `MeshAnchorTracker` builds for each chunk — no hand-rolled geometry math.
//

import RealityKit
import simd

/// A hit produced by raycasting against the reconstructed scene mesh.
public struct MeshRaycastHit: Sendable {
    /// World-space position of the hit.
    public let position: SIMD3<Float>
    /// World-space surface normal at the hit.
    public let normal: SIMD3<Float>
    /// Distance from the ray origin to the hit.
    public let distance: Float

    public init(position: SIMD3<Float>, normal: SIMD3<Float>, distance: Float) {
        self.position = position
        self.normal = normal
        self.distance = distance
    }
}

@MainActor
public enum SceneMeshRaycaster {

    /// Casts a ray in an arbitrary direction and returns the nearest hit against
    /// `meshEntities` (the chunks produced by ``MeshAnchorTracker``).
    ///
    /// - Parameters:
    ///   - origin: World-space ray origin.
    ///   - direction: Ray direction (need not be normalized).
    ///   - scene: The RealityKit scene to query (e.g. `rootEntity.scene`).
    ///   - meshEntities: The set of scene-mesh entities to restrict hits to.
    ///   - maxDistance: Maximum ray length, in meters.
    public static func raycast(from origin: SIMD3<Float>,
                               direction: SIMD3<Float>,
                               in scene: Scene,
                               meshEntities: [Entity],
                               maxDistance: Float = 20) -> MeshRaycastHit? {
        let dirLen = simd_length(direction)
        guard dirLen > 1e-6 else { return nil }
        let dir = direction / dirLen

        let allowed = Set(meshEntities.map { ObjectIdentifier($0) })
        let hits = scene.raycast(origin: origin,
                                 direction: dir,
                                 length: maxDistance,
                                 query: .nearest,
                                 mask: .all)

        for hit in hits where allowed.contains(ObjectIdentifier(hit.entity)) {
            return MeshRaycastHit(position: hit.position,
                                  normal: hit.normal,
                                  distance: hit.distance)
        }
        return nil
    }

    /// Casts a ray straight down (−Y) and returns the nearest near-horizontal,
    /// upward-facing surface — i.e. the floor beneath `origin`.
    ///
    /// - Parameter minUpwardDot: Minimum dot product between the hit normal and world-up
    ///   for the surface to count as floor-like. Default `0.7` (~45°).
    public static func raycastToFloor(from origin: SIMD3<Float>,
                                      in scene: Scene,
                                      meshEntities: [Entity],
                                      maxDistance: Float = 20,
                                      minUpwardDot: Float = 0.7) -> MeshRaycastHit? {
        let up = SIMD3<Float>(0, 1, 0)
        let allowed = Set(meshEntities.map { ObjectIdentifier($0) })
        let hits = scene.raycast(origin: origin,
                                 direction: SIMD3<Float>(0, -1, 0),
                                 length: maxDistance,
                                 query: .all,
                                 mask: .all)

        // hits are sorted nearest-first; take the first floor-like mesh hit.
        for hit in hits
        where allowed.contains(ObjectIdentifier(hit.entity))
            && simd_dot(simd_normalize(hit.normal), up) >= minUpwardDot {
            return MeshRaycastHit(position: hit.position,
                                  normal: hit.normal,
                                  distance: hit.distance)
        }
        return nil
    }
}
