//
//  ImmersiveExample.swift
//  DicyaninSceneReconstruction — minimal usage example
//
//  Not compiled as part of the package. Drop into a visionOS app target.
//
//  Architecture note (following the ImmersiveTesting scaffold): the `RealityView`
//  is a thin shell that only wires things together. All ARKit/provider work lives
//  behind `SceneReconstructionManager` (the "service" layer). Physics and contacts
//  are RealityKit's job — the manager gives every mesh chunk a static collider.
//

import SwiftUI
import RealityKit
import DicyaninSceneReconstruction

@MainActor
final class ExampleModel: ObservableObject {
    // Require ~8 m² of scanned surface before we consider the room "ready".
    let recon = SceneReconstructionManager(requiredScanArea: 8.0)
}

struct ExampleImmersiveView: View {
    @StateObject private var model = ExampleModel()

    var body: some View {
        RealityView { content in
            // Add the reconstructed-mesh root, then start the provider.
            content.add(model.recon.rootEntity)
            await model.recon.start(alsoStartHandTracking: true)
        }
        .onDisappear { model.recon.stop() }
        // Example: drop a marker on the floor directly below the origin.
        .onTapGesture {
            if let hit = model.recon.raycastToFloor(from: SIMD3<Float>(0, 1.5, 0)) {
                let marker = ModelEntity(
                    mesh: .generateSphere(radius: 0.03),
                    materials: [SimpleMaterial(color: .green, isMetallic: false)]
                )
                marker.position = hit.position
                model.recon.rootEntity.addChild(marker)
            }
        }
    }
}
