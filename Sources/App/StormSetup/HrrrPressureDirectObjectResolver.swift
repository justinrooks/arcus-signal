import Foundation

struct HrrrPressureDirectObjectURLBuilder: Sendable {
    private static let baseHost = "noaa-hrrr-bdp-pds.s3.amazonaws.com"

    func makeSourceMetadata(for candidate: HrrrRunCandidate) -> StormSetupSourceMetadata {
        StormSetupSourceMetadata(
            sourceKind: .directObject,
            model: candidate.model,
            product: .wrfprsf,
            domain: candidate.domain,
            runTime: candidate.runTime,
            forecastHour: candidate.forecastHour,
            validTime: candidate.validTime,
            fieldSetVersion: candidate.fieldSetVersion,
            primaryDownloadURL: makeGribURL(for: candidate),
            idxURL: makeIdxURL(for: candidate)
        )
    }

    func makeGribURL(for candidate: HrrrRunCandidate) -> URL {
        makeURL(for: candidate, fileName: candidate.fileName)
    }

    func makeIdxURL(for candidate: HrrrRunCandidate) -> URL {
        makeURL(for: candidate, fileName: candidate.fileName + ".idx")
    }

    private func makeURL(for candidate: HrrrRunCandidate, fileName: String) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = Self.baseHost
        components.path = candidate.directoryPath + "/" + fileName

        guard let url = components.url else {
            preconditionFailure("Unable to construct HRRR pressure direct-object URL.")
        }

        return url
    }
}

struct HrrrRemoteObjectProbeResult: Sendable, Equatable {
    let url: URL
    let available: Bool
    let status: Int?
}

protocol HrrrRemoteObjectChecking: Sendable {
    func probe(url: URL) async -> HrrrRemoteObjectProbeResult
}

struct HTTPHrrrRemoteObjectChecker: HrrrRemoteObjectChecking {
    private let httpClient: any HTTPClient

    init(httpClient: any HTTPClient) {
        self.httpClient = httpClient
    }

    func probe(url: URL) async -> HrrrRemoteObjectProbeResult {
        do {
            let response = try await httpClient.head(url, headers: [:])
            let available = (200...399).contains(response.status)
            return HrrrRemoteObjectProbeResult(url: url, available: available, status: response.status)
        } catch {
            return HrrrRemoteObjectProbeResult(url: url, available: false, status: nil)
        }
    }
}

struct HrrrPressureDirectObjectResolution: Sendable {
    let candidate: HrrrRunCandidate
    let source: StormSetupSourceMetadata
    let idxProbe: HrrrRemoteObjectProbeResult
    let gribProbe: HrrrRemoteObjectProbeResult?
}

struct HrrrPressureDirectObjectFailure: Sendable {
    let source: StormSetupSourceMetadata
    let reason: String
}

enum HrrrPressureDirectObjectResolverError: Error, Sendable, CustomStringConvertible {
    case noCandidatesProvided
    case noAvailableCandidate([HrrrPressureDirectObjectFailure])

    var description: String {
        switch self {
        case .noCandidatesProvided:
            return "No HRRR pressure direct-object candidates were provided."
        case .noAvailableCandidate(let failures):
            let summaries = failures.map { failure in
                "\(failure.source): \(failure.reason)"
            }
            .joined(separator: "; ")
            return "No usable HRRR pressure direct-object candidate was available. \(summaries)"
        }
    }
}

protocol HrrrPressureDirectObjectResolving: Sendable {
    func resolveSource(for resolution: HrrrRunResolution) async throws -> HrrrPressureDirectObjectResolution
}

struct DefaultHrrrPressureDirectObjectResolver: HrrrPressureDirectObjectResolving {
    private let urlBuilder: HrrrPressureDirectObjectURLBuilder
    private let remoteObjectChecker: any HrrrRemoteObjectChecking

    init(
        remoteObjectChecker: any HrrrRemoteObjectChecking,
        urlBuilder: HrrrPressureDirectObjectURLBuilder = HrrrPressureDirectObjectURLBuilder()
    ) {
        self.remoteObjectChecker = remoteObjectChecker
        self.urlBuilder = urlBuilder
    }

    init(
        checker: any HrrrRemoteObjectChecking,
        urlBuilder: HrrrPressureDirectObjectURLBuilder = HrrrPressureDirectObjectURLBuilder()
    ) {
        self.init(remoteObjectChecker: checker, urlBuilder: urlBuilder)
    }

    init(
        httpClient: any HTTPClient,
        urlBuilder: HrrrPressureDirectObjectURLBuilder = HrrrPressureDirectObjectURLBuilder()
    ) {
        self.init(
            remoteObjectChecker: HTTPHrrrRemoteObjectChecker(httpClient: httpClient),
            urlBuilder: urlBuilder
        )
    }

    func resolveSource(for resolution: HrrrRunResolution) async throws -> HrrrPressureDirectObjectResolution {
        guard !resolution.candidates.isEmpty else {
            throw HrrrPressureDirectObjectResolverError.noCandidatesProvided
        }

        var failures: [HrrrPressureDirectObjectFailure] = []

        for candidate in resolution.candidates {
            let pressureCandidate = makePressureCandidate(from: candidate)
            let source = urlBuilder.makeSourceMetadata(for: pressureCandidate)

            let idxProbe = await remoteObjectChecker.probe(url: source.idxURL ?? urlBuilder.makeIdxURL(for: pressureCandidate))
            if idxProbe.available {
                return HrrrPressureDirectObjectResolution(
                    candidate: pressureCandidate,
                    source: source,
                    idxProbe: idxProbe,
                    gribProbe: nil
                )
            }

            let gribProbe = await remoteObjectChecker.probe(url: source.primaryDownloadURL ?? urlBuilder.makeGribURL(for: pressureCandidate))
            let idxSummary = probeSummary(for: idxProbe)
            let gribSummary = probeSummary(for: gribProbe)
            failures.append(
                HrrrPressureDirectObjectFailure(
                    source: source,
                    reason: gribProbe.available
                        ? "IDX \(idxSummary); GRIB available"
                        : "IDX \(idxSummary); GRIB \(gribSummary)"
                )
            )
        }

        throw HrrrPressureDirectObjectResolverError.noAvailableCandidate(failures)
    }

    private func makePressureCandidate(from candidate: HrrrRunCandidate) -> HrrrRunCandidate {
        let runTime = StormSetupUTC.calendar.date(byAdding: .hour, value: -1, to: candidate.runTime) ?? candidate.runTime
        return HrrrRunCandidate(
            model: candidate.model,
            product: .wrfprsf,
            domain: candidate.domain,
            runTime: runTime,
            forecastHour: candidate.forecastHour + 1,
            fieldSetVersion: HrrrProduct.wrfprsf.defaultFieldSetVersion
        )
    }

    private func probeSummary(for probe: HrrrRemoteObjectProbeResult) -> String {
        if probe.available {
            return "available"
        }

        if let status = probe.status {
            return "unavailable (status \(status))"
        }

        return "unavailable"
    }
}
