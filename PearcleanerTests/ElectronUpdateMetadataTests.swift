import XCTest
@testable import Pearcleaner

final class ElectronUpdateMetadataTests: XCTestCase {
    func testParsesPublicDigitalOceanSpacesFeed() throws {
        let source = """
        provider: spaces
        name: example-releases
        region: nyc3
        path: desktop/stable
        channel: beta
        """

        let configuration = try ElectronUpdateMetadataParser.parseConfiguration(source)

        XCTAssertEqual(
            configuration.provider,
            .spaces(baseURL: try XCTUnwrap(URL(string: "https://example-releases.nyc3.digitaloceanspaces.com/desktop/stable/")))
        )
        XCTAssertEqual(
            configuration.manifestURL?.absoluteString,
            "https://example-releases.nyc3.digitaloceanspaces.com/desktop/stable/beta-mac.yml"
        )
        XCTAssertTrue(configuration.isCheckable)
    }

    func testPrivateDigitalOceanSpacesFeedRemainsUnsupported() throws {
        let configuration = try ElectronUpdateMetadataParser.parseConfiguration("""
        provider: spaces
        name: example-releases
        region: nyc3
        acl: private
        """)

        XCTAssertEqual(configuration.provider, .unsupported(name: "spaces"))
        XCTAssertFalse(configuration.isCheckable)
    }

    func testRejectsInvalidDigitalOceanSpacesHostComponents() {
        XCTAssertThrowsError(try ElectronUpdateMetadataParser.parseConfiguration("""
        provider: spaces
        name: example.releases
        region: nyc3.example.com
        """))
    }

    func testRejectsIncompleteDigitalOceanSpacesConfiguration() {
        XCTAssertThrowsError(try ElectronUpdateMetadataParser.parseConfiguration("""
        provider: spaces
        name: example-releases
        """))
    }

    func testPublicBitbucketFeedUsesTheDownloadsAPIAndConfiguredChannel() throws {
        let configuration = try ElectronUpdateMetadataParser.parseConfiguration("""
        provider: bitbucket
        owner: publisher-team
        slug: desktop.app
        channel: beta
        """)

        XCTAssertTrue(configuration.isCheckable)
        XCTAssertEqual(configuration.manifestURL?.absoluteString, "https://api.bitbucket.org/2.0/repositories/publisher-team/desktop.app/downloads/beta-mac.yml")
        XCTAssertEqual(configuration.fallbackExternalURL?.absoluteString, "https://bitbucket.org/publisher-team/desktop.app/downloads/")
    }

    func testRejectsBitbucketPathInjectionInsteadOfCheckingAnotherRepository() {
        for value in ["../other", "publisher/repo", "publisher%2Frepo", "publisher?token=value", "publisher#fragment", ".."] {
            XCTAssertThrowsError(try ElectronUpdateMetadataParser.parseConfiguration("""
            provider: bitbucket
            owner: \(value)
            slug: desktop
            """))
            XCTAssertThrowsError(try ElectronUpdateMetadataParser.parseConfiguration("""
            provider: bitbucket
            owner: publisher
            slug: \(value)
            """))
        }
    }

    func testPublicGitLabProjectConfigurationIsCheckable() throws {
        let configuration = try ElectronUpdateMetadataParser.parseConfiguration("""
        provider: gitlab
        projectId: publisher/subgroup/desktop
        host: gitlab.example.com:8443
        """)
        XCTAssertTrue(configuration.isCheckable)
        XCTAssertEqual(configuration.channel, "latest")
    }

    func testR2UsesExplicitPublicURLAndNeverTheAuthenticatedS3Endpoint() throws {
        let configuration = try ElectronUpdateMetadataParser.parseConfiguration("""
        provider: r2
        accountId: example-account
        bucket: desktop-releases
        publicUrl: https://releases.example.com/desktop
        path: stable
        """)
        XCTAssertTrue(configuration.isCheckable)
        XCTAssertEqual(configuration.manifestURL?.absoluteString, "https://releases.example.com/desktop/stable/latest-mac.yml")

        for extra in ["", "publicUrl: https://example-account.r2.cloudflarestorage.com/desktop-releases"] {
            let privateConfiguration = try ElectronUpdateMetadataParser.parseConfiguration("""
            provider: r2
            accountId: example-account
            bucket: desktop-releases
            \(extra)
            """)
            XCTAssertFalse(privateConfiguration.isCheckable)
            XCTAssertNil(privateConfiguration.manifestURL)
        }
    }

    func testPublicKeygenFeedKeepsTheProductScopeAndDefaultsToStable() throws {
        let configuration = try ElectronUpdateMetadataParser.parseConfiguration("""
        provider: keygen
        account: publisher-account
        product: desktop-product
        """)

        XCTAssertTrue(configuration.isCheckable)
        XCTAssertEqual(configuration.channel, "stable")
        XCTAssertEqual(configuration.manifestURL?.absoluteString, "https://api.keygen.sh/v1/accounts/publisher-account/artifacts/stable-mac.yml?product=desktop-product")
    }

    func testExplicitCredentialAndLicenseRequirementsRemainManaged() throws {
        let providers = [
            "provider: github\nowner: publisher\nrepo: desktop",
            "provider: gitlab\nprojectId: publisher/desktop",
            "provider: bitbucket\nowner: publisher\nslug: desktop",
            "provider: keygen\naccount: publisher\nproduct: desktop",
            "provider: r2\npublicUrl: https://releases.example.com"
        ]
        for provider in providers {
            for requirement in ["private: true", "token: required-in-app", "licenseKey: required-in-app", "requestHeaders:\n  Authorization: required-in-app", "distributionStrategy: LICENSED"] {
                let configuration = try ElectronUpdateMetadataParser.parseConfiguration(provider + "\n" + requirement)
                XCTAssertFalse(configuration.isCheckable)
                XCTAssertNil(configuration.manifestURL)
            }
        }
    }

    func testAnAbsentTokenDoesNotDisablePublicProviders() throws {
        let configuration = try ElectronUpdateMetadataParser.parseConfiguration("""
        provider: keygen
        account: publisher
        product: desktop
        token: null
        private: false
        distributionStrategy: OPEN
        """)
        XCTAssertTrue(configuration.isCheckable)
    }

    func testNullCredentialOptionsDoNotMakeAPublicFeedManaged() throws {
        let configuration = try ElectronUpdateMetadataParser.parseConfiguration("""
        provider: keygen
        account: publisher
        product: desktop
        requestHeaders: null
        awsCredentials: null
        distributionStrategy: null
        """)
        XCTAssertTrue(configuration.isCheckable)
    }

    func testRejectsInvalidCustomHostsAndKeygenIdentifiers() {
        for host in ["http://gitlab.example.com", "gitlab.example.com/path", "gitlab.example.com?query=1", "gitlab.example.com#fragment"] {
            XCTAssertThrowsError(try ElectronUpdateMetadataParser.parseConfiguration("""
            provider: gitlab
            projectId: publisher/desktop
            host: \(host)
            """))
            XCTAssertThrowsError(try ElectronUpdateMetadataParser.parseConfiguration("""
            provider: keygen
            account: publisher
            product: desktop
            host: \(host)
            """))
        }
        for identifier in ["../other", "publisher/product", "publisher%2Fproduct", "product?scope=other"] {
            XCTAssertThrowsError(try ElectronUpdateMetadataParser.parseConfiguration("""
            provider: keygen
            account: publisher
            product: \(identifier)
            """))
        }
    }

    func testRejectsCredentialsEmbeddedInManifestDownloadURLs() throws {
        var components = URLComponents(string: "https://publisher.example/Desktop.dmg")!
        components.user = "fixture-user"
        components.password = "fixture-password"
        let metadata = try ElectronUpdateMetadataParser.parseManifest("""
        version: 2.0.0
        path: \(components.url!.absoluteString)
        """, baseURL: URL(string: "https://publisher.example/")!)
        XCTAssertNil(metadata.downloadURL)
    }

    func testGitLabEncodesTheFullNamespaceAsOneProjectIdentifier() throws {
        let configuration = try gitLabConfiguration()
        XCTAssertEqual(configuration.releaseAPIURL?.absoluteString, "https://gitlab.example.com/api/v4/projects/publisher%2Fsubgroup%2Fdesktop/releases/permalink/latest")

        let numericConfiguration = try ElectronUpdateMetadataParser.parseConfiguration("provider: gitlab\nprojectId: 12345")
        XCTAssertEqual(numericConfiguration.releaseAPIURL?.absoluteString, "https://gitlab.com/api/v4/projects/12345/releases/permalink/latest")
    }

    func testGitLabSelectsThePublicMacManifestAndReleaseNotes() throws {
        let configuration = try gitLabConfiguration()
        let release = try ElectronUpdateMetadataParser.parseGitLabRelease(gitLabRelease(), configuration: configuration)

        XCTAssertEqual(release.manifestURL.absoluteString, "https://gitlab.example.com/publisher/subgroup/desktop/-/releases/v2.0.0/downloads/latest-mac.yml")
        XCTAssertEqual(release.releasePageURL?.absoluteString, "https://gitlab.example.com/publisher/subgroup/desktop/-/releases/v2.0.0")
        XCTAssertEqual(release.releaseNotes, "Release notes")
        XCTAssertEqual(release.releaseDate, "2026-11-15T00:00:00Z")
    }

    func testGitLabRejectsUntrustedAssetAndReleasePageOrigins() throws {
        let configuration = try gitLabConfiguration()
        for assetURL in ["https://untrusted.example/latest-mac.yml", "http://gitlab.example.com/latest-mac.yml", "https://gitlab.example.com:8443/latest-mac.yml"] {
            XCTAssertThrowsError(try ElectronUpdateMetadataParser.parseGitLabRelease(gitLabRelease(assetURL: assetURL), configuration: configuration))
        }
        XCTAssertThrowsError(try ElectronUpdateMetadataParser.parseGitLabRelease(gitLabRelease(releasePage: "https://untrusted.example/release"), configuration: configuration))
    }

    func testGitLabRejectsUpcomingAndPrereleaseReleasesOnTheStableChannel() throws {
        let configuration = try gitLabConfiguration()
        XCTAssertThrowsError(try ElectronUpdateMetadataParser.parseGitLabRelease(gitLabRelease(upcoming: true), configuration: configuration))
        XCTAssertThrowsError(try ElectronUpdateMetadataParser.parseGitLabRelease(gitLabRelease(tag: "v2.0.0-beta.1"), configuration: configuration))
        XCTAssertThrowsError(try ElectronUpdateMetadataParser.parseGitLabRelease(gitLabRelease(prerelease: true), configuration: configuration))
    }

    func testGitLabBetaChannelUsesItsManifestAndAllowsStableFallback() throws {
        let configuration = try gitLabConfiguration(channel: "beta")
        let beta = try ElectronUpdateMetadataParser.parseGitLabRelease(gitLabRelease(tag: "v2.0.0-beta.1", manifestName: "beta-mac.yml"), configuration: configuration)
        XCTAssertEqual(beta.manifestURL.lastPathComponent, "beta-mac.yml")

        let stable = try ElectronUpdateMetadataParser.parseGitLabRelease(gitLabRelease(), configuration: configuration)
        XCTAssertEqual(stable.manifestURL.lastPathComponent, "latest-mac.yml")
        XCTAssertThrowsError(try ElectronUpdateMetadataParser.parseGitLabRelease(gitLabRelease(tag: "v2.0.0-alpha.1"), configuration: configuration))
    }

    func testKeygenUsesItsProtocolHeadersAndKeepsProductScopeForDownloads() throws {
        let configuration = try ElectronUpdateMetadataParser.parseConfiguration("""
        provider: keygen
        account: publisher
        product: desktop
        host: distribution.example.com:8443
        channel: beta
        """)
        let request = try XCTUnwrap(configuration.manifestRequest)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/vnd.api+json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Keygen-Version"), "1.1")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(request.url?.absoluteString, "https://distribution.example.com:8443/v1/accounts/publisher/artifacts/beta-mac.yml?product=desktop")

        let metadata = try ElectronUpdateMetadataParser.parseManifest("version: 2.0.0-beta.1\npath: Desktop.zip", baseURL: try XCTUnwrap(request.url).deletingLastPathComponent())
        XCTAssertEqual(metadata.downloadURL?.absoluteString, "https://distribution.example.com:8443/v1/accounts/publisher/artifacts/Desktop.zip?product=desktop")
    }

    func testStableProviderChannelsRejectPrereleaseManifestVersions() throws {
        let stable = try ElectronUpdateMetadataParser.parseConfiguration("provider: generic\nurl: https://publisher.example")
        XCTAssertTrue(stable.acceptsReleaseVersion("2.0.0"))
        XCTAssertFalse(stable.acceptsReleaseVersion("2.0.0-beta.1"))

        let beta = try gitLabConfiguration(channel: "beta")
        XCTAssertTrue(beta.acceptsReleaseVersion("2.0.0-beta.2"))
        XCTAssertTrue(beta.acceptsReleaseVersion("2.0.0"))
        XCTAssertFalse(beta.acceptsReleaseVersion("2.0.0-alpha.1"))
        XCTAssertFalse(beta.acceptsReleaseVersion("unknown"))
    }

    func testProductScopeStaysOnTheKeygenOriginIncludingAbsoluteArtifactPaths() throws {
        let baseURL = URL(string: "https://api.keygen.sh/v1/accounts/publisher/artifacts/?product=desktop")!
        let sameOrigin = try ElectronUpdateMetadataParser.parseManifest("version: 2.0.0\npath: https://api.keygen.sh/v1/accounts/publisher/artifacts/Desktop.zip", baseURL: baseURL)
        XCTAssertEqual(sameOrigin.downloadURL?.query, "product=desktop")

        let otherOrigin = try ElectronUpdateMetadataParser.parseManifest("version: 2.0.0\npath: https://cdn.example.com/Desktop.zip", baseURL: baseURL)
        XCTAssertNil(otherOrigin.downloadURL?.query)
    }

    func testConfiguredLatestSuffixIsComparableAndRetainsPublisherVersion() throws {
        let configuration = try ElectronUpdateMetadataParser.parseConfiguration("provider: generic\nurl: https://downloads.k8slens.dev/ide\nchannel: latest")
        XCTAssertEqual(configuration.comparisonVersion(for: "2026.10.121159-latest"), "2026.10.121159")
        XCTAssertTrue(configuration.acceptsReleaseVersion("2026.11.91422-latest"))
        let metadata = try ElectronUpdateMetadataParser.parseManifest(
            "version: 2026.11.91422-latest\npath: Lens-2026.11.91422-latest-mac.zip",
            baseURL: URL(string: "https://downloads.k8slens.dev/ide/")!, configuration: configuration
        )
        XCTAssertEqual(metadata.version, "2026.11.91422-latest")
        XCTAssertEqual(UpdateVersionComparator.compare(installed: configuration.comparisonVersion(for: "2026.10.121159-latest") ?? "",
                                                       available: configuration.comparisonVersion(for: metadata.version) ?? ""), .orderedAscending)
    }

    func testChannelSuffixCannotCrossConfiguredChannelOrRelaxGeneralParser() throws {
        let beta = try ElectronUpdateMetadataParser.parseConfiguration("provider: generic\nurl: https://example.com/updates\nchannel: beta")
        XCTAssertNil(beta.comparisonVersion(for: "2026.10.121159-latest"))
        XCTAssertFalse(beta.acceptsReleaseVersion("2026.11.91422-latest"))
        XCTAssertThrowsError(try ElectronUpdateMetadataParser.parseManifest("version: 2026.11.91422-latest", baseURL: URL(string: "https://example.com/")!))
        XCTAssertNil(UpdateVersionComparator.compare(installed: "2026.10.121159-latest", available: "2026.11.91422"))
    }

    func testMissingPublicManifestIsManualCheckButServiceAndNetworkErrorsRemainErrors() {
        XCTAssertEqual(ElectronUpdateChecker.issueKind(for: UpdateHTTPClient.Error.httpStatus(404)), .unavailable)
        XCTAssertEqual(ElectronUpdateChecker.issueKind(for: UpdateHTTPClient.Error.httpStatus(500)), .failed)
        XCTAssertEqual(ElectronUpdateChecker.issueKind(for: URLError(.notConnectedToInternet)), .failed)
    }

    private func gitLabConfiguration(channel: String = "latest") throws -> ElectronUpdateConfiguration {
        try ElectronUpdateMetadataParser.parseConfiguration("""
        provider: gitlab
        projectId: publisher/subgroup/desktop
        host: gitlab.example.com
        channel: \(channel)
        """)
    }

    private func gitLabRelease(
        tag: String = "v2.0.0",
        manifestName: String = "latest-mac.yml",
        assetURL: String? = nil,
        releasePage: String = "https://gitlab.example.com/publisher/subgroup/desktop/-/releases/v2.0.0",
        upcoming: Bool = false,
        prerelease: Bool = false
    ) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "tag_name": tag,
            "description": "Release notes",
            "released_at": "2026-11-15T00:00:00Z",
            "upcoming_release": upcoming,
            "prerelease": prerelease,
            "_links": ["self": releasePage],
            "assets": ["links": [[
                "name": manifestName,
                "direct_asset_url": assetURL ?? "https://gitlab.example.com/publisher/subgroup/desktop/-/releases/\(tag)/downloads/\(manifestName)"
            ]]]
        ])
    }
}
