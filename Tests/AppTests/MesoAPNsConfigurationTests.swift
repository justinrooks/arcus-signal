@testable import App
import Foundation
import Testing
import Vapor

@Suite("Meso APNs startup requirements", .serialized)
struct MesoAPNsConfigurationTests {
    private func workerStartupError(overrides: [String: String?]) async throws -> (any Error)? {
        try await withProcessEnvironment(overrides) {
            let app = try await Application.make(.testing)
            var capturedError: (any Error)?
            do {
                try await configure(app, mode: .worker)
            } catch {
                capturedError = error
            }
            try await app.asyncShutdown()
            return capturedError
        }
    }

    @Test("disabled meso rollout permits a single-environment APNs configuration")
    func disabledRolloutDoesNotRequireBothAPNSEnvironments() throws {
        try validateMesoAPNSReadiness(
            enabled: false,
            teamID: "team",
            topic: "com.example.app",
            sandboxKeyID: "sandbox-key",
            sandboxKeyPath: "/unused/sandbox.p8",
            productionKeyID: nil,
            productionKeyPath: nil
        )
    }

    @Test("enabled meso rollout requires both APNs credential pairs")
    func enabledRolloutRequiresBothCredentialPairs() async throws {
        let cases: [(sandboxKeyID: String?, sandboxKeyPath: String?, productionKeyID: String?, productionKeyPath: String?, missing: String)] = [
            (nil, nil, "production-key", "/production.p8", "APNS_SANDBOX_KEY_ID"),
            ("sandbox-key", "/sandbox.p8", nil, nil, "APNS_PROD_KEY_ID")
        ]

        for testCase in cases {
            let error = try await workerStartupError(overrides: [
                "MESO_NOTIFICATIONS_ENABLED": "true",
                "APNS_TEAM_ID": "test-team",
                "APNS_TOPIC": "com.example.app",
                "APNS_SANDBOX_KEY_ID": testCase.sandboxKeyID,
                "APNS_SANDBOX_PRIVATE_KEY_PATH": testCase.sandboxKeyPath,
                "APNS_PROD_KEY_ID": testCase.productionKeyID,
                "APNS_PROD_PRIVATE_KEY_PATH": testCase.productionKeyPath
            ])
            guard let abortError = error as? any AbortError else {
                Issue.record("Expected worker startup to reject incomplete APNs configuration.")
                continue
            }
            #expect(abortError.reason.contains("MESO_NOTIFICATIONS_ENABLED=true"))
            #expect(abortError.reason.contains(testCase.missing))
        }
    }

    @Test("enabled meso rollout reports invalid private key material clearly")
    func enabledRolloutReportsInvalidPrivateKeyClearly() async throws {
        let invalidKeyURL = FileManager.default.temporaryDirectory
            .appending(path: "arcus-signal-invalid-apns-\(UUID().uuidString).p8")
        try Data("not a private key".utf8).write(to: invalidKeyURL)
        defer { try? FileManager.default.removeItem(at: invalidKeyURL) }

        let overrides: [String: String?] = [
            "MESO_NOTIFICATIONS_ENABLED": "true",
            "APNS_TEAM_ID": "test-team",
            "APNS_TOPIC": "com.example.app",
            "APNS_SANDBOX_KEY_ID": "sandbox-key",
            "APNS_SANDBOX_PRIVATE_KEY_PATH": invalidKeyURL.path,
            "APNS_PROD_KEY_ID": "production-key",
            "APNS_PROD_PRIVATE_KEY_PATH": invalidKeyURL.path
        ]

        let error = try await workerStartupError(overrides: overrides)
        guard let abortError = error as? any AbortError else {
            Issue.record("Expected a configuration AbortError for invalid sandbox APNs key material.")
            return
        }
        #expect(abortError.status == .internalServerError)
        #expect(abortError.reason.contains("MESO_NOTIFICATIONS_ENABLED=true"))
        #expect(abortError.reason.contains("valid APNS sandbox credential material"))
    }

    @Test("enabled meso rollout identifies invalid key material for either APNs environment")
    func invalidCredentialMaterialNamesItsEnvironment() throws {
        let invalidKeyURL = FileManager.default.temporaryDirectory
            .appending(path: "arcus-signal-invalid-apns-\(UUID().uuidString).p8")
        try Data("not a private key".utf8).write(to: invalidKeyURL)
        defer { try? FileManager.default.removeItem(at: invalidKeyURL) }

        for environment in ["sandbox", "production"] {
            var reason: String?
            do {
                _ = try loadAuthenticationMethod(
                    keyID: "test-key",
                    teamID: "test-team",
                    privateKeyPath: invalidKeyURL.path,
                    environmentName: environment,
                    requiresMesoReadiness: true
                )
            } catch let error as any AbortError {
                reason = error.reason
            } catch {
                Issue.record("Expected an APNs configuration AbortError; received \(error).")
            }
            #expect(reason?.contains("valid APNS \(environment) credential material") == true)
        }
    }
}
