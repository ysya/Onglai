import XCTest
@testable import Pearcleaner

@MainActor
final class NativeUpdateCoordinatorTests: XCTestCase {
    func testRefusingToQuitNeverStartsTheInstaller() async {
        let coordinator = NativeUpdateCoordinator(
            isRunning: { _ in true }, confirmQuit: { _ in false },
            terminate: { _ in XCTFail("Must not terminate without consent") },
            install: { _, _, _ in XCTFail("Must not install a running app"); return NativeInstallResult() }
        )
        do {
            _ = try await coordinator.install(target: target, artifact: artifact, progress: { _ in })
            XCTFail("Expected cancellation")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
    }

    func testGracefulQuitRequiresConsentAndRechecksBeforeInstallation() async throws {
        let state = RunningState()
        let coordinator = NativeUpdateCoordinator(
            isRunning: { _ in state.running },
            confirmQuit: { _ in state.consented = true; return true },
            terminate: { _ in
                XCTAssertTrue(state.consented)
                state.running = false
            },
            install: { _, _, _ in
                await MainActor.run { XCTAssertFalse(state.running) }
                return NativeInstallResult()
            }
        )
        _ = try await coordinator.install(target: target, artifact: artifact, progress: { _ in })
        XCTAssertTrue(state.consented)
        XCTAssertFalse(state.running)
    }

    func testRunningDetectionMatchesOnlyTheSelectedCanonicalAppPath() {
        let selected = URL(fileURLWithPath: "/fixture/Selected.app")
        let other = URL(fileURLWithPath: "/fixture/Other.app")
        XCTAssertTrue(NativeUpdateCoordinator.matchesRunningApplication(bundleURL: selected, executableURL: nil, targetURL: selected))
        XCTAssertFalse(NativeUpdateCoordinator.matchesRunningApplication(bundleURL: other, executableURL: selected.appendingPathComponent("Contents/MacOS/App"), targetURL: selected))
        XCTAssertTrue(NativeUpdateCoordinator.matchesRunningApplication(bundleURL: nil, executableURL: selected.appendingPathComponent("Contents/MacOS/App"), targetURL: selected))
        XCTAssertFalse(NativeUpdateCoordinator.matchesRunningApplication(bundleURL: nil, executableURL: URL(fileURLWithPath: "/fixture/Selected.app-other/Contents/MacOS/App"), targetURL: selected))
    }

    private var target: NativeInstallTarget {
        NativeInstallTarget(url: URL(fileURLWithPath: "/fixture/Native.app"), bundleIdentifier: "test.native", version: "1.0", build: nil)
    }
    private var artifact: NativeUpdateArtifact {
        NativeUpdateArtifact(url: URL(string: "https://publisher.example.com/app.zip")!, version: "2.0")!
    }
}

@MainActor
private final class RunningState {
    var running = true
    var consented = false
}
