import Foundation

struct AnvilSurfaceProfileNormalizer: Sendable {
    func normalize(samples: [HrrrFieldSample]) throws -> StormSetupSurfaceProfileLevel {
        struct Draft {
            var pressurePa: Double?
            var heightMslM: Double?
            var temperatureK: Double?
            var dewpointK: Double?
            var uWindMs: Double?
            var vWindMs: Double?
        }

        var draft = Draft()

        for sample in samples {
            guard let descriptor = sample.point.inventoryDescriptor,
                  let value = sample.point.value else {
                continue
            }

            let variable = descriptor.variable.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            let level = descriptor.level.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

            switch (variable, level) {
            case ("PRES", "surface") where draft.pressurePa == nil:
                draft.pressurePa = value
            case ("HGT", "surface") where draft.heightMslM == nil:
                draft.heightMslM = value
            case ("TMP", "2 m above ground") where draft.temperatureK == nil:
                draft.temperatureK = value
            case ("DPT", "2 m above ground") where draft.dewpointK == nil:
                draft.dewpointK = value
            case ("UGRD", "10 m above ground") where draft.uWindMs == nil:
                draft.uWindMs = value
            case ("VGRD", "10 m above ground") where draft.vWindMs == nil:
                draft.vWindMs = value
            default:
                continue
            }
        }

        let invalidFields = [
            field(.pressure, value: draft.pressurePa, isValid: { $0 > 0 && $0 <= 200_000 }),
            field(.height, value: draft.heightMslM),
            field(.temperature, value: draft.temperatureK),
            field(.dewpoint, value: draft.dewpointK),
            field(.uWind, value: draft.uWindMs),
            field(.vWind, value: draft.vWindMs)
        ].compactMap { $0 }

        guard invalidFields.isEmpty,
              let pressurePa = draft.pressurePa,
              let heightMslM = draft.heightMslM,
              let temperatureK = draft.temperatureK,
              let dewpointK = draft.dewpointK,
              let uWindMs = draft.uWindMs,
              let vWindMs = draft.vWindMs else {
            throw AnvilSurfaceProfileNormalizationError(invalidFields: invalidFields)
        }

        return StormSetupSurfaceProfileLevel(
            pressureMb: pressurePa / 100,
            heightMslM: heightMslM,
            temperatureC: temperatureK - 273.15,
            dewpointC: dewpointK - 273.15,
            uWindMs: uWindMs,
            vWindMs: vWindMs
        )
    }

    private func field(
        _ field: AnvilSurfaceProfileField,
        value: Double?,
        isValid: (Double) -> Bool = { _ in true }
    ) -> AnvilSurfaceProfileField? {
        guard let value, value.isFinite, isValid(value) else {
            return field
        }
        return nil
    }
}
