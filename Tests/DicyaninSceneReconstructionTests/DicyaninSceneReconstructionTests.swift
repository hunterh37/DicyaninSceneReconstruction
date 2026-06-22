import XCTest
import RealityKit
@testable import DicyaninSceneReconstruction

@MainActor
final class DicyaninSceneReconstructionTests: XCTestCase {

    func testScanProgressCompletesImmediatelyWhenNoAreaRequired() {
        let manager = SceneReconstructionManager(requiredScanArea: 0)
        // With no required area, progress is full regardless of support.
        XCTAssertEqual(manager.scanProgress, 1.0, accuracy: 0.0001)
    }

    func testResetScanProgressClearsCounts() {
        let manager = SceneReconstructionManager(requiredScanArea: 10)
        manager.resetScanProgress()
        XCTAssertEqual(manager.scannedAnchorCount, 0)
        XCTAssertEqual(manager.scannedSurfaceArea, 0)
    }

    func testTrackerStartsEmptyAndResetsCleanly() {
        let tracker = MeshAnchorTracker()
        XCTAssertTrue(tracker.anchors.isEmpty)
        XCTAssertTrue(tracker.entities.isEmpty)
        XCTAssertEqual(tracker.throttlePhase, .scanning)

        tracker.enterPostScanPhase()
        XCTAssertEqual(tracker.throttlePhase, .postScan)

        tracker.reset()
        XCTAssertEqual(tracker.throttlePhase, .scanning)
    }

    func testRootEntityIsShared() {
        let root = Entity()
        let manager = SceneReconstructionManager(rootEntity: root)
        XCTAssertEqual(ObjectIdentifier(manager.rootEntity), ObjectIdentifier(root))
    }
}
