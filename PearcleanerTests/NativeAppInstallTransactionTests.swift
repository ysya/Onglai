import XCTest
@testable import Pearcleaner

final class NativeAppInstallTransactionTests: XCTestCase {
    func testRejectsInvalidRequestURLsBeforeFilesystemAccessAndDuringDecode() throws {
        for value in ["file:///missing%00.app", "file:///missing%0A.app", "file:///missing%7F.app", "file://remote/missing.app", "file:///missing.app?query=1", "file:///missing.app#fragment", "https://example.invalid/missing.app"] {
            let request = NativeInstallRequest(targetURL: URL(string: value)!, candidateURL: URL(fileURLWithPath: "/missing-candidate.app"), bundleIdentifier: "example", installedVersion: "1", installedBuild: nil, expectedVersion: "2", expectedBuild: nil)
            do { _ = try NativeAppInstallTransaction().install(request); XCTFail("Unsafe URL accepted") }
            catch NativeInstallError.invalidPayload(let reason) { XCTAssertTrue(reason.contains("file URL")) }
            let data = try JSONEncoder().encode(request)
            XCTAssertThrowsError(try JSONDecoder().decode(NativeInstallRequest.self, from: data))
            let badCandidate = NativeInstallRequest(targetURL: URL(fileURLWithPath: "/missing-target.app"), candidateURL: URL(string: value)!, bundleIdentifier: "example", installedVersion: "1", installedBuild: nil, expectedVersion: "2", expectedBuild: nil)
            XCTAssertThrowsError(try badCandidate.validateURLs())
        }
    }

    func testAtomicInstallReplacesBytesAndRemovesRecoveryAfterVerification() throws {
        let fixture = try NativeTransactionFixture()
        defer { fixture.clean() }
        let result = try NativeAppInstallTransaction(signatureCheck: { _, _ in }, runningCheck: { _ in false }).install(fixture.request)
        guard case .installed(nil) = result else { return XCTFail("Expected installation without recovery") }
        XCTAssertEqual(try String(contentsOf: fixture.target.appendingPathComponent("Contents/Resources/marker"), encoding: .utf8), "new")
    }

    func testFailedPostInstallVerificationRestoresOldBytes() throws {
        let fixture = try NativeTransactionFixture()
        defer { fixture.clean() }
        let transaction = NativeAppInstallTransaction(signatureCheck: { candidate, _ in
            if candidate.resolvingSymlinksInPath().path == fixture.target.resolvingSymlinksInPath().path,
               (try? String(contentsOf: candidate.appendingPathComponent("Contents/Resources/marker"), encoding: .utf8)) == "new" {
                throw NativeInstallError.invalidPayload("Post-install verification failed")
            }
        }, runningCheck: { _ in false })
        XCTAssertThrowsError(try transaction.install(fixture.request))
        XCTAssertEqual(try String(contentsOf: fixture.target.appendingPathComponent("Contents/Resources/marker"), encoding: .utf8), "old")
    }

    func testUnrelatedSiblingCreatedDuringPreparationDoesNotInvalidateParent() throws {
        let fixture = try NativeTransactionFixture()
        defer { fixture.clean() }
        var createdSibling = false
        let transaction = NativeAppInstallTransaction(signatureCheck: { candidate, _ in
            if candidate.deletingLastPathComponent().lastPathComponent.hasPrefix(".native-update-"), !createdSibling {
                try FileManager.default.createDirectory(at: fixture.root.appendingPathComponent("Unrelated.app"), withIntermediateDirectories: false)
                createdSibling = true
            }
        }, runningCheck: { _ in false })
        let result = try transaction.install(fixture.request)
        XCTAssertTrue(createdSibling)
        guard case .installed(nil) = result else { return XCTFail("Expected installation without recovery") }
        XCTAssertEqual(try String(contentsOf: fixture.target.appendingPathComponent("Contents/Resources/marker"), encoding: .utf8), "new")
    }

    func testTargetEntryChangedDuringPreparationIsRejected() throws {
        let fixture = try NativeTransactionFixture()
        defer { fixture.clean() }
        let transaction = NativeAppInstallTransaction(signatureCheck: { candidate, _ in
            if candidate.deletingLastPathComponent().lastPathComponent.hasPrefix(".native-update-") {
                try Data("unexpected".utf8).write(to: fixture.target.appendingPathComponent("unexpected-entry"))
            }
        }, runningCheck: { _ in false })
        XCTAssertThrowsError(try transaction.install(fixture.request)) { error in
            guard case NativeInstallError.invalidPayload(let reason) = error else { return XCTFail("Expected changed-target rejection") }
            XCTAssertTrue(reason.contains("changed while preparing"))
        }
        XCTAssertEqual(try String(contentsOf: fixture.target.appendingPathComponent("Contents/Resources/marker"), encoding: .utf8), "old")
    }

    func testTargetReplacedDuringPreparationIsRejected() throws {
        let fixture = try NativeTransactionFixture()
        defer { fixture.clean() }
        let previous = fixture.root.appendingPathComponent("Previous.app")
        let transaction = NativeAppInstallTransaction(signatureCheck: { candidate, _ in
            if candidate.deletingLastPathComponent().lastPathComponent.hasPrefix(".native-update-") {
                try FileManager.default.moveItem(at: fixture.target, to: previous)
                try FileManager.default.copyItem(at: previous, to: fixture.target)
            }
        }, runningCheck: { _ in false })
        XCTAssertThrowsError(try transaction.install(fixture.request)) { error in
            guard case NativeInstallError.invalidPayload(let reason) = error else { return XCTFail("Expected replaced-target rejection") }
            XCTAssertTrue(reason.contains("changed while preparing"))
        }
        XCTAssertEqual(try String(contentsOf: fixture.target.appendingPathComponent("Contents/Resources/marker"), encoding: .utf8), "old")
    }

    func testRunningAppNeverModifiesTarget() throws {
        let fixture = try NativeTransactionFixture()
        defer { fixture.clean() }
        XCTAssertThrowsError(try NativeAppInstallTransaction(signatureCheck: { _, _ in }, runningCheck: { _ in true }).install(fixture.request))
        XCTAssertEqual(try String(contentsOf: fixture.target.appendingPathComponent("Contents/Resources/marker"), encoding: .utf8), "old")
    }

    func testEscapingSymlinkIsRejected() throws {
        let fixture = try NativeTransactionFixture()
        defer { fixture.clean() }
        try FileManager.default.createSymbolicLink(at: fixture.candidate.appendingPathComponent("escape"), withDestinationURL: URL(fileURLWithPath: "/etc"))
        XCTAssertThrowsError(try NativeAppInstallTransaction(signatureCheck: { _, _ in }, runningCheck: { _ in false }).install(fixture.request))
        XCTAssertEqual(try String(contentsOf: fixture.target.appendingPathComponent("Contents/Resources/marker"), encoding: .utf8), "old")
    }
    func testRollbackFailureRetainsThePreviousApplication() throws {
        let fixture = try NativeTransactionFixture()
        defer { fixture.clean() }
        var swaps = 0
        let transaction = NativeAppInstallTransaction(signatureCheck: { candidate, _ in
            if candidate.resolvingSymlinksInPath().path == fixture.target.resolvingSymlinksInPath().path,
               (try? String(contentsOf: candidate.appendingPathComponent("Contents/Resources/marker"), encoding: .utf8)) == "new" {
                throw NativeInstallError.invalidPayload("Post-install verification failed")
            }
        }, runningCheck: { _ in false }, swap: { fromFD, from, toFD, to in
            swaps += 1
            if swaps == 2 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO)) }
            guard renameatx_np(fromFD, from, toFD, to, UInt32(RENAME_SWAP)) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
        })
        do { _ = try transaction.install(fixture.request); XCTFail("Expected recovery-required failure") }
        catch NativeInstallError.recoveryRequired(let recovery) {
            XCTAssertEqual(try String(contentsOf: recovery.appendingPathComponent("Contents/Resources/marker"), encoding: .utf8), "old")
            XCTAssertEqual(try String(contentsOf: fixture.target.appendingPathComponent("Contents/Resources/marker"), encoding: .utf8), "new")
        }
    }

    func testCleanupFailureReturnsRecoveryWithoutUndoingSuccessfulInstall() throws {
        let fixture = try NativeTransactionFixture()
        defer { fixture.clean() }
        let transaction = NativeAppInstallTransaction(signatureCheck: { _, _ in }, runningCheck: { _ in false }, remove: { _ in
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
        })
        let result = try transaction.install(fixture.request)
        guard case .installed(let recoveryURL) = result else { return XCTFail("Expected installation with recovery") }
        let recovery = try XCTUnwrap(recoveryURL)
        XCTAssertEqual(try String(contentsOf: recovery.appendingPathComponent("Contents/Resources/marker"), encoding: .utf8), "old")
        XCTAssertEqual(try String(contentsOf: fixture.target.appendingPathComponent("Contents/Resources/marker"), encoding: .utf8), "new")
    }

    func testCompatibleAppleSignatureAndRejectsOtherIdentityAndTampering() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-signature-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let installed = root.appendingPathComponent("installed")
        let candidate = root.appendingPathComponent("candidate")
        let other = root.appendingPathComponent("other")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: installed)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: candidate)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/false"), to: other)
        XCTAssertNoThrow(try NativeAppValidation.checkSignature(candidate, installed: installed))
        XCTAssertThrowsError(try NativeAppValidation.checkSignature(other, installed: installed))
        let file = try FileHandle(forWritingTo: candidate)
        try file.seek(toOffset: 128)
        try file.write(contentsOf: Data(repeating: 0xff, count: 16))
        try file.close()
        XCTAssertThrowsError(try NativeAppValidation.checkSignature(candidate, installed: installed))
    }

    func testUnsignedAndAdHocApplicationsFailRealSignatureValidation() throws {
        let fixture = try NativeTransactionFixture()
        defer { fixture.clean() }
        XCTAssertThrowsError(try NativeAppValidation.checkSignature(fixture.candidate, installed: fixture.target))
        _ = try NativeSystemTool.run("/usr/bin/codesign", ["--force", "--sign", "-", fixture.target.path])
        _ = try NativeSystemTool.run("/usr/bin/codesign", ["--force", "--sign", "-", fixture.candidate.path])
        XCTAssertThrowsError(try NativeAppValidation.checkSignature(fixture.candidate, installed: fixture.target))
    }

    func testStaleVersionAndEqualVersionDoNotModifyTarget() throws {
        let fixture = try NativeTransactionFixture()
        defer { fixture.clean() }
        let transaction = NativeAppInstallTransaction(signatureCheck: { _, _ in }, runningCheck: { _ in false })
        let stale = NativeInstallRequest(targetURL: fixture.target, candidateURL: fixture.candidate, bundleIdentifier: "org.example.native-fixture", installedVersion: "0.9", installedBuild: "1", expectedVersion: "2.0", expectedBuild: "2")
        XCTAssertThrowsError(try transaction.install(stale))
        let info = fixture.candidate.appendingPathComponent("Contents/Info.plist")
        var metadata = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: info), format: nil) as? [String: Any])
        metadata["CFBundleShortVersionString"] = "1.0"
        metadata["CFBundleVersion"] = "1"
        try PropertyListSerialization.data(fromPropertyList: metadata, format: .xml, options: 0).write(to: info)
        let equal = NativeInstallRequest(targetURL: fixture.target, candidateURL: fixture.candidate, bundleIdentifier: "org.example.native-fixture", installedVersion: "1.0", installedBuild: "1", expectedVersion: "1.0", expectedBuild: "1")
        XCTAssertThrowsError(try transaction.install(equal))
        XCTAssertEqual(try String(contentsOf: fixture.target.appendingPathComponent("Contents/Resources/marker"), encoding: .utf8), "old")
    }

    func testDownloadedBuildCanBeCurrentOnlyAfterVerifyingThePublisher() throws {
        let fixture = try NativeTransactionFixture()
        defer { fixture.clean() }
        let installed = try NativeAppValidation.metadata(fixture.target)
        let request = fixture.request
        var signatureChecked = false
        let requiresReplacement = try NativeAppValidation.requiresReplacement(request, installed: installed, candidate: installed) { candidate, target in
            XCTAssertEqual(candidate, request.candidateURL)
            XCTAssertEqual(target, request.targetURL)
            signatureChecked = true
        }
        XCTAssertTrue(signatureChecked)
        XCTAssertFalse(requiresReplacement)
        XCTAssertThrowsError(try NativeAppValidation.requiresReplacement(request, installed: installed, candidate: installed))
        XCTAssertThrowsError(try NativeAppValidation.checkVersions(request, installed: installed, candidate: installed))
    }

    func testDifferentBuildRequiresTheExactAdvertisedRelease() throws {
        let fixture = try NativeTransactionFixture()
        defer { fixture.clean() }
        let installed = try NativeAppValidation.metadata(fixture.target)
        let request = fixture.request
        let candidate = try NativeAppValidation.metadata(fixture.candidate)
        XCTAssertTrue(try NativeAppValidation.requiresReplacement(request, installed: installed, candidate: candidate) { _, _ in })

        let wrongBuild = NativeAppValidation.Metadata(identifier: candidate.identifier, version: candidate.version, build: "3")
        XCTAssertThrowsError(try NativeAppValidation.requiresReplacement(request, installed: installed, candidate: wrongBuild) { _, _ in }) { error in
            guard case NativeInstallError.releaseMismatch = error else { return XCTFail("Expected a release mismatch") }
        }
        let differentApp = NativeAppValidation.Metadata(identifier: "org.example.different", version: installed.version, build: installed.build)
        XCTAssertThrowsError(try NativeAppValidation.requiresReplacement(request, installed: installed, candidate: differentApp) { _, _ in
            XCTFail("An unrelated bundle must be rejected before checking its signature")
        })
    }
}

private struct NativeTransactionFixture {
    let root: URL
    let target: URL
    let candidate: URL
    var request: NativeInstallRequest {
        NativeInstallRequest(targetURL: target, candidateURL: candidate, bundleIdentifier: "org.example.native-fixture", installedVersion: "1.0", installedBuild: "1", expectedVersion: "2.0", expectedBuild: "2")
    }
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("native-transaction-tests-\(UUID().uuidString)").resolvingSymlinksInPath()
        target = root.appendingPathComponent("Installed.app")
        candidate = root.appendingPathComponent("Candidate.app")
        for (url, version, marker) in [(target, "1", "old"), (candidate, "2", "new")] {
            try FileManager.default.createDirectory(at: url.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
            let plist: [String: Any] = ["CFBundleIdentifier": "org.example.native-fixture", "CFBundleShortVersionString": "\(version).0", "CFBundleVersion": version, "CFBundleExecutable": "app", "CFBundlePackageType": "APPL", "LSMinimumSystemVersion": "13.0"]
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: url.appendingPathComponent("Contents/Info.plist"))
            try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: url.appendingPathComponent("Contents/MacOS/app"))
            try FileManager.default.createDirectory(at: url.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
            try Data(marker.utf8).write(to: url.appendingPathComponent("Contents/Resources/marker"))
        }
    }
    func clean() { try? FileManager.default.removeItem(at: root) }
}
