import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class AuthManagerTests: XCTestCase {
    override func tearDown() {
        unsetenv("CMUX_API_BASE_URL")
        unsetenv("CMUX_WWW_ORIGIN")
        unsetenv("CMUX_AUTH_WWW_ORIGIN")
        super.tearDown()
    }

    func testSignedOutStateDoesNotGateLocalApp() {
        let manager = AuthManager(
            client: StubAuthClient(user: nil, teams: []),
            tokenStore: StubStackTokenStore(),
            settingsStore: AuthSettingsStore(userDefaults: UserDefaults(suiteName: "AuthManagerTests.signedOut.\(UUID().uuidString)")!)
        )

        XCTAssertFalse(manager.isAuthenticated)
        XCTAssertFalse(manager.requiresAuthenticationGate)
    }

    func testHandleCallbackSeedsTokensAndDefaultsToFirstTeamMembership() async throws {
        let tokenStore = StubStackTokenStore()
        let manager = AuthManager(
            client: StubAuthClient(
                user: CMUXAuthUser(id: "user_123", primaryEmail: "lawrence@cmux.dev", displayName: "Lawrence"),
                teams: [
                    AuthTeamSummary(id: "team_alpha", displayName: "Alpha"),
                    AuthTeamSummary(id: "team_beta", displayName: "Beta"),
                ]
            ),
            tokenStore: tokenStore,
            settingsStore: AuthSettingsStore(userDefaults: UserDefaults(suiteName: "AuthManagerTests.callback.\(UUID().uuidString)")!)
        )

        let callbackURL = try XCTUnwrap(
            URL(
                string: "cmux://auth-callback?stack_refresh=refresh-123&stack_access=%5B%22refresh-123%22,%22access-456%22%5D"
            )
        )

        try await manager.handleCallbackURL(callbackURL)

        let refreshToken = await tokenStore.currentRefreshToken()
        let accessToken = await tokenStore.currentAccessToken()

        XCTAssertEqual(refreshToken, "refresh-123")
        XCTAssertEqual(accessToken, "access-456")
        XCTAssertEqual(manager.selectedTeamID, "team_alpha")
        XCTAssertTrue(manager.didCompleteBrowserSignIn)
    }

    func testSignOutClearsBrowserSignInCompletionFlag() async throws {
        let manager = AuthManager(
            client: StubAuthClient(
                user: CMUXAuthUser(id: "user_123", primaryEmail: "lawrence@cmux.dev", displayName: "Lawrence"),
                teams: [AuthTeamSummary(id: "team_alpha", displayName: "Alpha")]
            ),
            tokenStore: StubStackTokenStore(),
            settingsStore: AuthSettingsStore(userDefaults: UserDefaults(suiteName: "AuthManagerTests.signOut.\(UUID().uuidString)")!)
        )

        let callbackURL = try XCTUnwrap(
            URL(
                string: "cmux://auth-callback?stack_refresh=refresh-123&stack_access=%5B%22refresh-123%22,%22access-456%22%5D"
            )
        )

        try await manager.handleCallbackURL(callbackURL)
        XCTAssertTrue(manager.didCompleteBrowserSignIn)

        await manager.signOut()

        XCTAssertFalse(manager.didCompleteBrowserSignIn)
    }

    func testSignInURLDefaultsToCmuxDotDevEvenWhenGeneralWebsiteOriginIsLocalhost() throws {
        setenv("CMUX_WWW_ORIGIN", "http://localhost:9779", 1)
        unsetenv("CMUX_AUTH_WWW_ORIGIN")

        let signInURL = AuthEnvironment.signInURL()
        let components = URLComponents(url: signInURL, resolvingAgainstBaseURL: false)
        let afterAuthReturnTo = try XCTUnwrap(
            components?.queryItems?.first(where: { $0.name == "after_auth_return_to" })?.value
        )
        let nestedURL = try XCTUnwrap(URL(string: afterAuthReturnTo))

        XCTAssertEqual(signInURL.scheme, "https")
        XCTAssertEqual(signInURL.host, "cmux.dev")
        XCTAssertEqual(signInURL.path, "/handler/sign-in")
        XCTAssertEqual(
            nestedURL.absoluteString,
            "https://cmux.dev/handler/after-sign-in?native_app_return_to=cmux-dev://auth-callback"
        )
    }

    func testSignInURLCanonicalizesDedicatedLoopbackAuthOriginToLocalhost() throws {
        setenv("CMUX_WWW_ORIGIN", "http://localhost:9779", 1)
        setenv("CMUX_AUTH_WWW_ORIGIN", "http://127.0.0.1:4010", 1)

        let signInURL = AuthEnvironment.signInURL()
        let components = URLComponents(url: signInURL, resolvingAgainstBaseURL: false)
        let afterAuthReturnTo = try XCTUnwrap(
            components?.queryItems?.first(where: { $0.name == "after_auth_return_to" })?.value
        )
        let nestedURL = try XCTUnwrap(URL(string: afterAuthReturnTo))

        XCTAssertEqual(signInURL.scheme, "http")
        XCTAssertEqual(signInURL.host, "localhost")
        XCTAssertEqual(signInURL.port, 4010)
        XCTAssertEqual(signInURL.path, "/handler/sign-in")
        XCTAssertEqual(
            nestedURL.absoluteString,
            "http://localhost:4010/handler/after-sign-in?native_app_return_to=cmux-dev://auth-callback"
        )
    }

    func testAPIBaseURLCanonicalizesLoopbackHostToLocalhost() {
        setenv("CMUX_API_BASE_URL", "http://0.0.0.0:9779", 1)

        let apiBaseURL = AuthEnvironment.apiBaseURL

        XCTAssertEqual(apiBaseURL.scheme, "http")
        XCTAssertEqual(apiBaseURL.host, "localhost")
        XCTAssertEqual(apiBaseURL.port, 9779)
    }

    func testKeychainServiceNameUsesBundleIdentifierNamespace() {
        XCTAssertEqual(
            AuthKeychainServiceName.make(bundleIdentifier: "com.cmuxterm.app"),
            "com.cmuxterm.app.auth"
        )
        XCTAssertEqual(
            AuthKeychainServiceName.make(bundleIdentifier: "com.cmuxterm.app.debug.desktop.mobile.e2e"),
            "com.cmuxterm.app.debug.desktop.mobile.e2e.auth"
        )
        XCTAssertEqual(
            AuthKeychainServiceName.make(bundleIdentifier: nil),
            "com.cmuxterm.app.auth"
        )
    }

    func testMissingTokensClearCachedSignedInState() async throws {
        let suiteName = "AuthManagerTests.missingTokens.\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        userDefaults.removePersistentDomain(forName: suiteName)
        let settingsStore = AuthSettingsStore(userDefaults: userDefaults)
        settingsStore.saveCachedUser(
            CMUXAuthUser(
                id: "user_123",
                primaryEmail: "lawrence@cmux.dev",
                displayName: "Lawrence"
            )
        )
        settingsStore.selectedTeamID = "team_alpha"

        let manager = AuthManager(
            client: StubAuthClient(
                user: CMUXAuthUser(id: "user_123", primaryEmail: "lawrence@cmux.dev", displayName: "Lawrence"),
                teams: [AuthTeamSummary(id: "team_alpha", displayName: "Alpha")]
            ),
            tokenStore: StubStackTokenStore(),
            settingsStore: settingsStore
        )

        await waitUntil("stale cached auth state clears without tokens") {
            manager.currentUser == nil && !manager.isAuthenticated && manager.selectedTeamID == nil
        }

        XCTAssertNil(manager.currentUser)
        XCTAssertFalse(manager.isAuthenticated)
        XCTAssertNil(manager.selectedTeamID)
        XCTAssertNil(settingsStore.cachedUser())
        XCTAssertNil(settingsStore.selectedTeamID)
    }

    private func waitUntil(
        _ description: String,
        timeout: TimeInterval = 1.0,
        condition: @escaping @MainActor () -> Bool
    ) async {
        let expectation = expectation(description: description)
        Task { @MainActor in
            while !condition() {
                await Task.yield()
            }
            expectation.fulfill()
        }
        await fulfillment(of: [expectation], timeout: timeout)
    }

}

private actor StubStackTokenStore: StackAuthTokenStoreProtocol {
    private(set) var accessToken: String?
    private(set) var refreshToken: String?

    func getStoredAccessToken() async -> String? {
        accessToken
    }

    func getStoredRefreshToken() async -> String? {
        refreshToken
    }

    func setTokens(accessToken: String?, refreshToken: String?) async {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
    }

    func clearTokens() async {
        accessToken = nil
        refreshToken = nil
    }

    func compareAndSet(compareRefreshToken: String, newRefreshToken: String?, newAccessToken: String?) async {
        guard refreshToken == compareRefreshToken else { return }
        accessToken = newAccessToken
        refreshToken = newRefreshToken
    }
}

private struct StubAuthClient: AuthClientProtocol {
    let user: CMUXAuthUser?
    let teams: [AuthTeamSummary]

    func currentUser() async throws -> CMUXAuthUser? {
        user
    }

    func listTeams() async throws -> [AuthTeamSummary] {
        teams
    }
}
