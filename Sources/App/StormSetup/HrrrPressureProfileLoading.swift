import Foundation

protocol HrrrPressureProfileLoading: Sendable {
    func loadPressureProfile(
        for sourceResolution: HrrrPressureDirectObjectResolution,
        centroid: StormSetupCentroid,
        surfaceHeightMslM: Double?
    ) async throws -> HrrrPressureProfileLoadResult

    func loadPressureProfile(
        for readyArtifact: PressureArtifactCatalogReadyArtifact,
        centroid: StormSetupCentroid,
        surfaceHeightMslM: Double?
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
        centroid: StormSetupCentroid,
        surfaceHeightMslM: Double?
    ) async throws -> HrrrPressureProfileLoadResult {
        let inventory = try await loadInventory(for: sourceResolution)
        let selection = HrrrPressureProfileMessageSelector(
            preferredLevels: StormSetupPressureLevel.preferredDescending
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
        let groupedProfile = pressureGrouper.group(
            samples: samples,
            surfaceHeightMslM: surfaceHeightMslM
        )

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

    func loadPressureProfile(
        for readyArtifact: PressureArtifactCatalogReadyArtifact,
        centroid: StormSetupCentroid,
        surfaceHeightMslM: Double?
    ) async throws -> HrrrPressureProfileLoadResult {
        let now = Date()
        let samples = try await samplePressureFile(
            localFileURL: readyArtifact.localFileURL,
            centroid: centroid
        )
        let groupedProfile = pressureGrouper.group(
            samples: samples,
            surfaceHeightMslM: surfaceHeightMslM
        )

        let sourceResolution = makeSourceResolution(for: readyArtifact)
        let selection = makeSelection(from: groupedProfile)
        let inventory = makeInventory(from: selection)
        let byteRangePlan = HrrrGribByteRangePlanner().plan(
            inventory: inventory,
            selectedMessages: selection.selectedMessages
        )
        let subsetCacheResult = HrrrPressureSubsetGribCacheResult(
            source: sourceResolution.source,
            localFileURL: readyArtifact.localFileURL,
            byteSize: readyArtifact.byteSize,
            checksumSHA256: "",
            fetchedAt: now,
            expiresAt: now.addingTimeInterval(15 * 60),
            cacheHit: true
        )

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

    private func samplePressureFile(
        localFileURL: URL,
        centroid: StormSetupCentroid
    ) async throws -> [HrrrFieldSample] {
        do {
            return try await fieldSampler.sample(
                localFileURL: localFileURL,
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

    private func makeSourceResolution(
        for readyArtifact: PressureArtifactCatalogReadyArtifact
    ) -> HrrrPressureDirectObjectResolution {
        let candidate = HrrrRunCandidate(
            product: readyArtifact.product,
            runTime: readyArtifact.runTime,
            forecastHour: readyArtifact.forecastHour,
            fieldSetVersion: readyArtifact.fieldSetVersion
        )
        let source = StormSetupSourceMetadata(
            sourceKind: .directObject,
            model: candidate.model,
            product: candidate.product,
            domain: candidate.domain,
            runTime: candidate.runTime,
            forecastHour: candidate.forecastHour,
            validTime: readyArtifact.validTime,
            fieldSetVersion: candidate.fieldSetVersion,
            primaryDownloadURL: readyArtifact.localFileURL
        )

        return HrrrPressureDirectObjectResolution(
            candidate: candidate,
            source: source,
            idxProbe: HrrrRemoteObjectProbeResult(
                url: readyArtifact.localFileURL,
                available: false,
                status: nil
            ),
            gribProbe: nil
        )
    }

    private func makeSelection(
        from groupedProfile: StormSetupPressureProfileGroupingResult
    ) -> HrrrPressureProfileMessageSelectionResult {
        let requestedLevels = StormSetupPressureLevel.preferredDescending
        let variables = StormSetupPressureProfileVariable.allCases
        let selectedMessages = groupedProfile.retainedLevels.enumerated().flatMap { levelIndex, level in
            variables.enumerated().map { variableIndex, variable in
                HrrrPressureProfileSelectedMessage(
                    inventoryIndex: levelIndex * variables.count + variableIndex,
                    record: HrrrPressureIdxInventoryRecord(
                        messageNumber: levelIndex * variables.count + variableIndex + 1,
                        byteOffset: Int64((levelIndex * variables.count + variableIndex) * 1_024),
                        dateRunToken: nil,
                        variableToken: variable.rawValue,
                        levelText: "\(level.pressureMb) mb",
                        forecastLabel: "ready artifact",
                        rawLine: "\(level.pressureMb) mb"
                    ),
                    pressureLevel: StormSetupPressureLevel(rawValue: level.pressureMb) ?? .mb1000,
                    variable: variable
                )
            }
        }

        return HrrrPressureProfileMessageSelectionResult(
            requestedLevels: requestedLevels,
            selectedMessages: selectedMessages,
            missingLevels: groupedProfile.missingLevels,
            ignoredRecords: []
        )
    }

    private func makeInventory(
        from selection: HrrrPressureProfileMessageSelectionResult
    ) -> HrrrPressureIdxInventory {
        HrrrPressureIdxInventory(
            records: selection.selectedMessages.map { selectedMessage in
                selectedMessage.record
            }
        )
    }
}
