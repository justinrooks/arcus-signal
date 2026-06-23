import Foundation

protocol HrrrPressureProfileLoading: Sendable {
    func loadPressureProfile(
        for sourceResolution: HrrrPressureDirectObjectResolution,
        centroid: StormSetupCentroid
    ) async throws -> HrrrPressureProfileLoadResult
}

struct HrrrPressureProfileLoadResult: Sendable {
    let sourceResolution: HrrrPressureDirectObjectResolution
    let inventory: HrrrPressureIdxInventory
    let selection: HrrrPressureProfileMessageSelectionResult
    let byteRangePlan: HrrrGribByteRangePlan
    let subsetCacheResult: HrrrPressureSubsetGribCacheResult
    let samples: [HrrrFieldSample]
    let groupedProfile: StormSetupPressureProfileGroupingResult
}

struct DefaultHrrrPressureProfileLoader: HrrrPressureProfileLoading {
    private static let previewPressureLevels: [StormSetupPressureLevel] = [
        .mb1000,
        .mb925,
        .mb850,
        .mb700,
        .mb500
    ]

    private let httpClient: any HTTPClient
    private let subsetCache: HrrrPressureSubsetGribCache
    private let fieldSampler: any StormSetupFieldSampling
    private let pressureGrouper: StormSetupPressureProfileGrouper

    init(
        httpClient: any HTTPClient,
        subsetCache: HrrrPressureSubsetGribCache,
        fieldSampler: any StormSetupFieldSampling,
        pressureGrouper: StormSetupPressureProfileGrouper = StormSetupPressureProfileGrouper()
    ) {
        self.httpClient = httpClient
        self.subsetCache = subsetCache
        self.fieldSampler = fieldSampler
        self.pressureGrouper = pressureGrouper
    }

    func loadPressureProfile(
        for sourceResolution: HrrrPressureDirectObjectResolution,
        centroid: StormSetupCentroid
    ) async throws -> HrrrPressureProfileLoadResult {
        let inventory = try await loadInventory(for: sourceResolution)
        let selection = HrrrPressureProfileMessageSelector(
            preferredLevels: Self.previewPressureLevels
        ).select(inventory: inventory)

        guard !selection.selectedMessages.isEmpty else {
            throw AnvilProfilePreviewError.unusableProfile(
                reason: makeMissingSelectionReason(from: selection)
            )
        }

        let byteRangePlan = HrrrGribByteRangePlanner().plan(
            inventory: inventory,
            selectedMessages: selection.selectedMessages
        )

        let subsetCacheResult: HrrrPressureSubsetGribCacheResult
        do {
            subsetCacheResult = try await subsetCache.loadOrFetch(
                sourceMetadata: sourceResolution.source,
                byteRangePlan: byteRangePlan
            )
        } catch let error as HrrrPressureSubsetGribCacheError {
            switch error {
            case .unableToCreateDirectory, .unableToWriteCache:
                throw AnvilProfilePreviewError.internalExecutionFailure(reason: String(describing: error))
            default:
                throw AnvilProfilePreviewError.upstreamUnavailable(reason: String(describing: error))
            }
        } catch {
            throw AnvilProfilePreviewError.upstreamUnavailable(reason: String(describing: error))
        }

        let samples = try await samplePressureFile(subset: subsetCacheResult, centroid: centroid)
        let groupedProfile = pressureGrouper.group(samples: samples)

        return HrrrPressureProfileLoadResult(
            sourceResolution: sourceResolution,
            inventory: inventory,
            selection: selection,
            byteRangePlan: byteRangePlan,
            subsetCacheResult: subsetCacheResult,
            samples: samples,
            groupedProfile: groupedProfile
        )
    }

    private func loadInventory(
        for sourceResolution: HrrrPressureDirectObjectResolution
    ) async throws -> HrrrPressureIdxInventory {
        guard sourceResolution.idxProbe.available else {
            throw AnvilProfilePreviewError.upstreamUnavailable(
                reason: "Pressure inventory was unavailable for \(sourceResolution.source)."
            )
        }

        guard let idxURL = sourceResolution.source.idxURL else {
            throw AnvilProfilePreviewError.upstreamUnavailable(
                reason: "Missing pressure inventory URL for \(sourceResolution.source)."
            )
        }

        let response: HTTPResponse
        do {
            response = try await httpClient.get(idxURL, headers: requestHeaders)
        } catch {
            throw AnvilProfilePreviewError.upstreamUnavailable(reason: String(describing: error))
        }

        guard (200...299).contains(response.status) else {
            throw AnvilProfilePreviewError.upstreamUnavailable(
                reason: "Pressure inventory returned HTTP \(response.status) for \(sourceResolution.source)."
            )
        }

        guard let body = response.data, !body.isEmpty else {
            throw AnvilProfilePreviewError.upstreamUnavailable(
                reason: "Pressure inventory response was empty for \(sourceResolution.source)."
            )
        }

        guard let text = String(data: body, encoding: .utf8) else {
            throw AnvilProfilePreviewError.upstreamUnavailable(
                reason: "Pressure inventory response was not valid UTF-8 for \(sourceResolution.source)."
            )
        }

        let inventory = HrrrPressureIdxInventory.parse(text)
        guard !inventory.records.isEmpty else {
            throw AnvilProfilePreviewError.unusableProfile(
                reason: "Pressure inventory did not contain any selectable messages for \(sourceResolution.source)."
            )
        }

        return inventory
    }

    private func samplePressureFile(
        subset: HrrrPressureSubsetGribCacheResult,
        centroid: StormSetupCentroid
    ) async throws -> [HrrrFieldSample] {
        do {
            return try await fieldSampler.sample(
                from: GribSubsetCacheResult(
                    source: subset.source,
                    localFileURL: subset.localFileURL,
                    byteSize: subset.byteSize,
                    fetchedAt: subset.fetchedAt,
                    expiresAt: subset.expiresAt,
                    cacheHit: subset.cacheHit
                ),
                around: centroid
            )
        } catch let error as Wgrib2ClientError {
            throw AnvilProfilePreviewError.internalExecutionFailure(reason: String(describing: error))
        } catch let error as ProcessRunnerError {
            throw AnvilProfilePreviewError.internalExecutionFailure(reason: String(describing: error))
        } catch {
            throw AnvilProfilePreviewError.internalExecutionFailure(reason: String(describing: error))
        }
    }

    private var requestHeaders: [String: String] {
        [
            "User-Agent": HTTPRequestHeaders.userAgent(),
            "Accept": "text/plain, application/octet-stream, */*"
        ]
    }

    private func makeMissingSelectionReason(
        from selection: HrrrPressureProfileMessageSelectionResult
    ) -> String {
        if selection.missingLevels.isEmpty {
            return "No complete pressure profile levels were selected."
        }

        let details = selection.missingLevels.map { level in
            "\(level.pressureMb) mb missing \(level.missingVariables.map(\.rawValue).joined(separator: ", "))"
        }
        .joined(separator: "; ")

        return "No complete pressure profile levels were selected. Missing or incomplete levels: \(details)."
    }
}
