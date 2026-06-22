//
//  Views.swift
//  DicyaninSceneReconstructionExample
//
//  Thin SwiftUI shells — no ARKit/provider logic lives here; everything routes
//  through ReconModel / SceneReconstructionManager.
//

import SwiftUI
import RealityKit
import DicyaninSceneReconstruction

/// A 2D window: open the immersive space and report scan progress.
struct ControlPanel: View {
    @EnvironmentObject private var model: ReconModel
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @State private var immersive = false

    var body: some View {
        VStack(spacing: 16) {
            Text("Scene Reconstruction")
                .font(.largeTitle).bold()

            if SceneReconstructionManager.isSupported {
                Text(model.isComplete ? "Scan complete ✓"
                                      : "Scanning… \(Int(model.scannedArea)) m²")
                    .font(.title3)
                Text("\(model.anchorCount) mesh anchors")
                    .foregroundStyle(.secondary)
            } else {
                Text("Scene reconstruction isn't supported on this device.")
                    .foregroundStyle(.secondary)
            }

            Button(immersive ? "Exit Immersive Space" : "Enter Immersive Space") {
                Task {
                    if immersive {
                        await dismissImmersiveSpace()
                        immersive = false
                    } else if await openImmersiveSpace(id: "scene") == .opened {
                        immersive = true
                    }
                }
            }
            .buttonStyle(.borderedProminent)

            Button("Drop Floor Marker") {
                model.dropFloorMarker()
            }
            .disabled(!immersive)
        }
        .padding(40)
        .frame(width: 420)
    }
}

/// The immersive shell: add the reconstructed-mesh root and start the session.
struct ReconImmersiveView: View {
    @EnvironmentObject private var model: ReconModel

    var body: some View {
        RealityView { content in
            content.add(model.recon.rootEntity)
            await model.start()
        }
        // Tap anywhere on the reconstructed mesh to drop a marker on the floor below.
        .gesture(
            SpatialTapGesture()
                .targetedToAnyEntity()
                .onEnded { value in
                    model.dropFloorMarker(from: value.convert(value.location3D,
                                                              from: .local, to: .scene)
                                          + SIMD3<Float>(0, 1.0, 0))
                }
        )
        .onDisappear { model.stop() }
    }
}
