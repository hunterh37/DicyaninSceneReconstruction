//
//  Logging.swift
//  DicyaninSceneReconstruction
//
//  Lightweight internal logging. No game/app coupling.
//

import OSLog

/// Internal logger for the scene-reconstruction package.
let srLog = Logger(subsystem: "com.dicyanin.scenereconstruction",
                   category: "SceneReconstruction")
