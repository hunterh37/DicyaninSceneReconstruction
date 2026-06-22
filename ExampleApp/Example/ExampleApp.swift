//
//  ExampleApp.swift
//  DicyaninSceneReconstructionExample
//
//  Minimal, fully-buildable visionOS app demonstrating DicyaninSceneReconstruction.
//  Open ExampleApp/DicyaninSceneReconstructionExample.xcodeproj and run on a
//  Vision Pro (scene reconstruction only produces mesh on a real device).
//

import SwiftUI

@main
struct ExampleApp: App {
    @StateObject private var model = ReconModel()

    var body: some Scene {
        WindowGroup(id: "control") {
            ControlPanel()
                .environmentObject(model)
        }
        .windowStyle(.plain)

        ImmersiveSpace(id: "scene") {
            ReconImmersiveView()
                .environmentObject(model)
        }
    }
}
