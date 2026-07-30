@testable import App
import Foundation
import Testing
import Vapor
import ArcusCore

@Suite("API dependency composition", .serialized)
struct APIDependencyCompositionTests {
    @Test("API bootstrap installs and stores the default request providers")
    func apiBootstrapInstallsDefaultRequestProviders() async throws {
        try await withApplication { app in
            #expect(app.configuredAnvilProfilePreviewProvider == nil)
            #expect(app.configuredAnvilProfileAnalysisProvider == nil)
            #expect(app.configuredStormSetupProvider == nil)

            try await configure(app, mode: .api)

            #expect(app.configuredAnvilProfilePreviewProvider is DefaultAnvilProfilePreviewProvider)
            #expect(app.configuredAnvilProfileAnalysisProvider is DefaultAnvilProfileAnalysisProvider)
            #expect(app.configuredStormSetupProvider is DefaultStormSetupProvider)

            _ = app.anvilProfilePreviewProvider
            _ = app.anvilProfileAnalysisProvider
            _ = app.stormSetupProvider

            #expect(app.configuredAnvilProfilePreviewProvider is DefaultAnvilProfilePreviewProvider)
            #expect(app.configuredAnvilProfileAnalysisProvider is DefaultAnvilProfileAnalysisProvider)
            #expect(app.configuredStormSetupProvider is DefaultStormSetupProvider)
        }
    }

    @Test("API bootstrap preserves all preconfigured request providers")
    func apiBootstrapPreservesPreconfiguredRequestProviders() async throws {
        try await withApplication { app in
            let previewProvider = SentinelAnvilProfilePreviewProvider()
            let analysisProvider = SentinelAnvilProfileAnalysisProvider()
            let stormSetupProvider = SentinelAPIStormSetupProvider()

            app.anvilProfilePreviewProvider = previewProvider
            app.anvilProfileAnalysisProvider = analysisProvider
            app.stormSetupProvider = stormSetupProvider

            try await configure(app, mode: .api)

            #expect(app.configuredAnvilProfilePreviewProvider as AnyObject === previewProvider)
            #expect(app.configuredAnvilProfileAnalysisProvider as AnyObject === analysisProvider)
            #expect(app.configuredStormSetupProvider as AnyObject === stormSetupProvider)
            #expect(app.anvilProfilePreviewProvider as AnyObject === previewProvider)
            #expect(app.anvilProfileAnalysisProvider as AnyObject === analysisProvider)
            #expect(app.stormSetupProvider as AnyObject === stormSetupProvider)
            #expect(app.anvilProfilePreviewProvider as AnyObject === previewProvider)
            #expect(app.anvilProfileAnalysisProvider as AnyObject === analysisProvider)
            #expect(app.stormSetupProvider as AnyObject === stormSetupProvider)
        }
    }

    @Test("A preview override participates in downstream default composition")
    func previewOverrideParticipatesInDownstreamDefaultComposition() async throws {
        try await withApplication { app in
            let previewProvider = SentinelAnvilProfilePreviewProvider()
            app.stormSetupConfiguration = makeAnvilEnabledConfiguration()
            app.anvilProfilePreviewProvider = previewProvider

            try await configure(app, mode: .api)

            #expect(app.configuredAnvilProfilePreviewProvider as AnyObject === previewProvider)
            #expect(app.configuredAnvilProfileAnalysisProvider is DefaultAnvilProfileAnalysisProvider)
            #expect(app.configuredStormSetupProvider is DefaultStormSetupProvider)

            do {
                _ = try await app.anvilProfileAnalysisProvider.analyzeProfile(for: 0)
                Issue.record("Expected the injected preview provider to stop downstream analysis.")
            } catch let error as AnvilProfileAnalysisError {
                guard case .unusableProfile(let reason) = error else {
                    Issue.record("Expected unusableProfile, got \(error).")
                    return
                }
                #expect(reason == SentinelAnvilProfilePreviewProvider.reason)
            }
        }
    }

    @Test("An analysis override participates in downstream default composition")
    func analysisOverrideParticipatesInDownstreamDefaultComposition() async throws {
        try await withApplication { app in
            let analysisProvider = SentinelAnvilProfileAnalysisProvider()
            app.anvilProfileAnalysisProvider = analysisProvider

            try await configure(app, mode: .api)

            #expect(app.configuredAnvilProfilePreviewProvider is DefaultAnvilProfilePreviewProvider)
            #expect(app.configuredAnvilProfileAnalysisProvider as AnyObject === analysisProvider)

            let stormSetupProvider = try #require(
                app.configuredStormSetupProvider as? DefaultStormSetupProvider
            )
            #expect(stormSetupProvider.anvilProfileAnalysisProvider as AnyObject === analysisProvider)
        }
    }

    @Test("Worker bootstrap leaves API request providers unconfigured")
    func workerBootstrapLeavesRequestProvidersUnconfigured() async throws {
        try await withApplication { app in
            try await configure(app, mode: .worker)

            #expect(app.configuredAnvilProfilePreviewProvider == nil)
            #expect(app.configuredAnvilProfileAnalysisProvider == nil)
            #expect(app.configuredStormSetupProvider == nil)
        }
    }

    @Test("Missing request providers fail explicitly without installing defaults")
    func missingRequestProvidersFailExplicitly() async throws {
        try await withApplication { app in
            do {
                _ = try await app.anvilProfilePreviewProvider.previewProfile(for: 0)
                Issue.record("Expected missing preview provider access to fail.")
            } catch let error as AnvilProfilePreviewError {
                guard case .internalExecutionFailure(let reason) = error else {
                    Issue.record("Expected internalExecutionFailure, got \(error).")
                    return
                }
                #expect(reason.contains("Anvil preview provider is not configured."))
            }

            do {
                _ = try await app.anvilProfileAnalysisProvider.analyzeProfile(for: 0)
                Issue.record("Expected missing analysis provider access to fail.")
            } catch let error as AnvilProfileAnalysisError {
                guard case .internalExecutionFailure(let reason) = error else {
                    Issue.record("Expected internalExecutionFailure, got \(error).")
                    return
                }
                #expect(reason.contains("Anvil analysis provider is not configured."))
            }

            do {
                _ = try await app.stormSetupProvider.currentSnapshot(for: 0)
                Issue.record("Expected missing Storm Setup provider access to fail.")
            } catch let error as Abort {
                #expect(error.status == .internalServerError)
                #expect(error.reason.contains("Storm Setup provider is not configured."))
            }

            #expect(app.configuredAnvilProfilePreviewProvider == nil)
            #expect(app.configuredAnvilProfileAnalysisProvider == nil)
            #expect(app.configuredStormSetupProvider == nil)
        }
    }

    private func withApplication(
        test: (Application) async throws -> Void
    ) async throws {
        let app = try await Application.make(.testing)
        do {
            try await test(app)
        } catch {
            try? await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }

    private func makeAnvilEnabledConfiguration() -> StormSetupConfiguration {
        StormSetupConfiguration(
            gribSubsetCacheRootURL: URL(fileURLWithPath: "/tmp/grib-subsets"),
            pressureGribSubsetCacheRootURL: URL(fileURLWithPath: "/tmp/pressure-grib-subsets"),
            sampledSnapshotCacheRootURL: URL(fileURLWithPath: "/tmp/sampled-snapshots"),
            gribSubsetCacheRetentionSeconds: 12 * 60 * 60,
            gribSubsetMaximumByteCount: 200 * 1024 * 1024,
            pressureArtifactProbeIntervalSeconds: 5 * 60,
            pressureArtifactMaxStaleAgeSeconds: 2 * 60 * 60,
            pressureArtifactDeleteGraceSeconds: 60 * 60,
            pressureArtifactCleanupIntervalSeconds: 15 * 60,
            pressureArtifactRecoveryTimeoutSeconds: 30 * 60,
            wgrib2ExecutableURL: URL(fileURLWithPath: "/usr/local/bin/wgrib2"),
            wgrib2TimeoutSeconds: 15,
            anvilProfileAnalysisBaseURL: URL(string: "https://anvil.example.test"),
            anvilProfileAnalysisTimeoutSeconds: 5
        )
    }
}

private actor SentinelAnvilProfilePreviewProvider: AnvilProfilePreviewProviding {
    static let reason = "Injected preview provider reached."

    func previewProfile(for h3Cell: Int64) async throws -> AnvilAnalyzeProfilePreviewResponse {
        _ = h3Cell
        throw AnvilProfilePreviewError.unusableProfile(reason: Self.reason)
    }
}

private actor SentinelAnvilProfileAnalysisProvider: AnvilProfileAnalysisProviding {
    func analyzeProfile(for h3Cell: Int64) async throws -> AnvilAnalyzeProfileAnalysisResponse {
        _ = h3Cell
        throw AnvilProfileAnalysisError.internalExecutionFailure(reason: "Sentinel provider should never be called.")
    }
}

private actor SentinelAPIStormSetupProvider: StormSetupProviding {
    func currentSnapshot(for h3Cell: Int64) async throws -> TornadoIngredientSnapshot {
        _ = h3Cell
        throw Abort(.internalServerError, reason: "Sentinel provider should never be called.")
    }
}
