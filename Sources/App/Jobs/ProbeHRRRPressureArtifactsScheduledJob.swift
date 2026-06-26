import Queues
import Vapor

public struct ProbeHRRRPressureArtifactsScheduledJob: AsyncScheduledJob {
    private let makeProbeService: @Sendable (Application) -> any HRRRPressureArtifactProbing

    init(
        makeProbeService: @escaping @Sendable (Application) -> any HRRRPressureArtifactProbing = { application in
            HRRRPressureArtifactProbeService.makeDefault(application: application)
        }
    ) {
        self.makeProbeService = makeProbeService
    }

    init(probeService: any HRRRPressureArtifactProbing) {
        self.init { _ in probeService }
    }

    public func run(context: QueueContext) async throws {
        context.logger.info("Scheduler probing HRRR pressure artifacts.")
        let probeService = makeProbeService(context.application)
        try await probeService.probe(on: context.application, logger: context.logger)
    }
}
