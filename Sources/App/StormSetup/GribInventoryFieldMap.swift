import Foundation
import ArcusCore

struct GribInventoryFieldMap: Sendable {
    func match(for sample: Wgrib2PointSample) -> GribInventoryFieldMatch? {
        guard let descriptor = sample.inventoryDescriptor else {
            return nil
        }

        let variable = normalizedToken(descriptor.variable)
        let level = normalizedLevel(descriptor.level)

        switch variable {
        case "CAPE":
            return capeMatch(for: level)
        case "CIN":
            return cinMatch(for: level)
        case "PRES":
            return pressureMatch(for: level)
        case "TMP":
            return temperatureMatch(for: level)
        case "DPT":
            return dewpointMatch(for: level)
        case "HLCY":
            return helicityMatch(for: level)
        case "VUCSH", "VVCSH", "UGRD", "VGRD":
            return shearComponentMatch(for: variable, level: level)
        case "HGT":
            return hgtMatch(for: level)
        default:
            return nil
        }
    }

    private func capeMatch(for level: String) -> GribInventoryFieldMatch? {
        switch level {
        case "surface":
            return .direct(.sbcapeJkg, priority: 0)
        case "90-0 mb above ground":
            return .direct(.mlcapeJkg, priority: 0)
        case "255-0 mb above ground":
            return .direct(.mucapeJkg, priority: 0)
        case "0-3000 m above ground":
            return .direct(.threeCapeJkg, priority: 0)
        default:
            return nil
        }
    }

    private func temperatureMatch(for level: String) -> GribInventoryFieldMatch? {
        guard level == "2 m above ground" else {
            return nil
        }

        return .direct(.temperature2mK, priority: 0)
    }

    private func dewpointMatch(for level: String) -> GribInventoryFieldMatch? {
        guard level == "2 m above ground" else {
            return nil
        }

        return .direct(.dewpoint2mK, priority: 0)
    }

    private func pressureMatch(for level: String) -> GribInventoryFieldMatch? {
        guard level == "surface" else {
            return nil
        }

        return .direct(.surfacePressurePa, priority: 0)
    }

    private func cinMatch(for level: String) -> GribInventoryFieldMatch? {
        switch level {
        case "90-0 mb above ground":
            return .direct(.mlcinJkg, priority: 0)
        case "surface":
            return .direct(.mlcinJkg, priority: 10)
        default:
            return nil
        }
    }

    private func helicityMatch(for level: String) -> GribInventoryFieldMatch? {
        switch level {
        case "1000-0 m above ground", "0-1 km above ground":
            return .direct(.srh01kmM2s2, priority: 0)
        case "3000-0 m above ground", "0-3 km above ground":
            return .direct(.srh03kmM2s2, priority: 0)
        default:
            return nil
        }
    }

    private func shearComponentMatch(for variable: String, level: String) -> GribInventoryFieldMatch? {
        switch level {
        case "0-6000 m above ground", "0-6 km above ground":
            let component: VectorComponent = variable == "VUCSH" ? .u : .v
            return .vectorComponent(.shear06kmKt, component, priority: 0)
        case "10 m above ground":
            let component: VectorComponent = variable == "UGRD" ? .u : .v
            return .vectorComponent(.wind10m, component, priority: 0)
        default:
            return nil
        }
    }

    private func hgtMatch(for level: String) -> GribInventoryFieldMatch? {
        guard level == "level of adiabatic condensation from sfc" || level == "level of adiabatic condensation from surface" else {
            return nil
        }

        return .direct(.mllclM, priority: 0)
    }

    private func normalizedToken(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
    }

    private func normalizedLevel(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "  ", with: " ")
    }
}

enum GribInventoryFieldMatch: Sendable, Equatable {
    case direct(TornadoRawParameterKey, priority: Int)
    case vectorComponent(TornadoRawParameterKey, VectorComponent, priority: Int)

    var rawParameterKey: TornadoRawParameterKey {
        switch self {
        case .direct(let key, _):
            return key
        case .vectorComponent(let key, _, _):
            return key
        }
    }

    var priority: Int {
        switch self {
        case .direct(_, let priority), .vectorComponent(_, _, let priority):
            return priority
        }
    }
}

enum VectorComponent: Sendable, Equatable {
    case u
    case v
}
