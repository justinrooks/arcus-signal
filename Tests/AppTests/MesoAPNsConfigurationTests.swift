@testable import App
import Foundation
import Testing
import Vapor

@Suite("Meso APNs startup requirements")
struct MesoAPNsConfigurationTests {
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
    func enabledRolloutRequiresBothCredentialPairs() throws {
        let cases: [(sandboxKeyID: String?, sandboxKeyPath: String?, productionKeyID: String?, productionKeyPath: String?, missing: String)] = [
            (nil, nil, "production-key", "/production.p8", "APNS_SANDBOX_KEY_ID"),
            ("sandbox-key", "/sandbox.p8", nil, nil, "APNS_PROD_KEY_ID")
        ]

        for testCase in cases {
            do {
                try validateMesoAPNSReadiness(
                    enabled: true,
                    teamID: "test-team",
                    topic: "com.example.app",
                    sandboxKeyID: testCase.sandboxKeyID,
                    sandboxKeyPath: testCase.sandboxKeyPath,
                    productionKeyID: testCase.productionKeyID,
                    productionKeyPath: testCase.productionKeyPath
                )
                Issue.record("Expected enabled meso readiness to reject incomplete APNs configuration.")
            } catch let abortError as any AbortError {
                #expect(abortError.reason.contains("MESO_NOTIFICATIONS_ENABLED=true"))
                #expect(abortError.reason.contains(testCase.missing))
            } catch {
                Issue.record("Expected a configuration AbortError; received \(error).")
            }
        }
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
