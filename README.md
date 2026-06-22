# DicyaninSceneReconstruction

A small, reusable visionOS package that wraps Apple's `SceneReconstructionProvider`
into a clean service: start/stop scene reconstruction, get the tracked mesh anchors
and their `ModelEntity` chunks (with real static colliders for RealityKit physics),
track scan coverage, and raycast down to the floor.

Extracted from the ZombieShooter app's scene-mesh tracking and stripped of all
game-specific coupling — no shaders, glitch effects, collision-group registries, or
game managers.

- visionOS 2+
- swift-tools 6.0
- Public library, `@MainActor` throughout (ARKit geometry buffers require the main queue)

## Design

This package follows the layered immersive-app conventions from
[ImmersiveTesting](https://github.com/hunterh37/ImmersiveTesting): anything that
imports `ARKit` or touches a session lives in the **services layer** behind a single
owning object — here, `SceneReconstructionManager`. Keep your `RealityView` and
view-models free of provider code and talk to the manager instead.

It also leans on **real RealityKit physics** rather than hand-rolled math: every mesh
chunk gets a `.static` `PhysicsBodyComponent` + `CollisionComponent` built from the
untouched anchor geometry, so contacts and raycasts resolve against the real room at
full fidelity.

### Relationship to DicyaninARKitSession

[DicyaninARKitSession](https://github.com/hunterh37/DicyaninARKitSession) (1.1.0+) owns
the **single shared `ARKitSession`** and now hosts both the hand-tracking and
scene-reconstruction providers on it — Apple's recommended single-session pattern. This
package does **not** create its own `ARKitSession`; it enables scene reconstruction on
the shared one and consumes its `sceneReconstructionUpdates` stream. Pass
`alsoStartHandTracking: true` to `start(...)` to bring up hand tracking on the same
session at the same time.

## Install

```swift
.package(url: "https://github.com/hunterh37/DicyaninSceneReconstruction.git", from: "0.0.1")
// requires DicyaninARKitSession 1.1.0+ (resolved transitively)
```

Then add `"DicyaninSceneReconstruction"` to your target's dependencies.

## API

```swift
let recon = SceneReconstructionManager(
    rootEntity: Entity(),            // parent for mesh chunks; add to RealityView content
    material: OcclusionMaterial(),   // render material per chunk (occludes by default)
    requiredScanArea: 8.0            // m² before isScanComplete flips (0 = immediate)
)

// Lifecycle (runs on the shared DicyaninARKitSession)
await recon.start(alsoStartHandTracking: true)
recon.stop()

// Tracked state (Combine @Published)
recon.anchors            // [MeshAnchor]
recon.meshEntities       // [ModelEntity] (parallel to anchors)
recon.scannedSurfaceArea // Float, m²
recon.scanProgress       // 0...1
recon.isScanComplete     // Bool

// Raycasting
recon.raycastToFloor(from: SIMD3<Float>(0, 1.5, 0))      // -> MeshRaycastHit?
recon.raycast(from: origin, direction: SIMD3(0,-1,0))    // arbitrary direction

// Surface detection & perf knobs (via the tracker)
recon.tracker.detectSurfaces(matching: .floor)           // [DetectedSurface]
recon.tracker.decimateSceneMesh = true                   // thin render mesh only
recon.tracker.material = OcclusionMaterial()             // swap chunk material
```

`SceneReconstructionManager.isSupported` reports device support; on unsupported
devices `start()` no-ops and `isScanComplete` is `true`.

## Minimal usage

See [`Examples/ImmersiveExample.swift`](Examples/ImmersiveExample.swift) for a complete
thin-shell `RealityView` that starts reconstruction and drops a marker where a downward
ray meets the floor.

## License

Copyright © 2025 Dicyanin Labs. All rights reserved.
