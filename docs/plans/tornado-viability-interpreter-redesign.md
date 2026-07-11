# Tornado Viability Interpreter Redesign Investigation

## Executive Summary

The current `TornadoIngredientInterpreter` is close to the right product direction, but its internal model is still a flat ingredient assessment rather than a localized tornado formation viability diagnosis. It already avoids deterministic tornado prediction language, prioritizes 0-1 km SRH, uses 3CAPE as low-level stretching support, treats CIN as a realization limiter, and avoids double-raising Anvil-backed canonical values. The biggest remaining design flaw is that `compositeSignal` currently maxes SCP, fixed STP, and effective STP together as though they measure the same thing. They do not.

The recommended path is internal refactoring, not public API churn:

- Keep returning `TornadoIngredientAssessment` from the existing storm setup response.
- Add a private/internal diagnosis layer that separates storm viability, supercell viability, tornado efficiency, realization, failure mode, composite confirmation, and confidence.
- Split composite interpretation into supercell composite support from SCP and tornado composite support from STP fixed/effective.
- Map the internal diagnosis back into the existing public fields until the app needs a richer `TornadoViabilityReport`.
- Reuse the existing H3-first `StormSetupProviding.currentSnapshot(for:)` boundary for any future any-cell endpoint.

This should be delivered in small slices. Do not combine composite cleanup, diagnosis model introduction, limiter precision, copy rewrite, test matrix, and endpoint prep into one diff. That would be a beautiful way to make future review miserable for no reason.

## Current-State Analysis

### Files and Entry Points Inspected

- `Sources/App/StormSetup/TornadoIngredientInterpreter.swift`
- `Sources/App/StormSetup/TornadoIngredientAssessment.swift`
- `Sources/App/StormSetup/StormSetupModels.swift`
- `Sources/App/StormSetup/StormSetupProvider.swift`
- `Sources/App/StormSetup/TornadoIngredientNormalizer.swift`
- `Sources/App/StormSetup/AnvilIngredientEvidence.swift`
- `Sources/App/StormSetup/StormSetupCurrentResponse.swift`
- `Sources/App/Controllers/StormSetupController.swift`
- `Sources/App/Models/API/AnvilAnalyzeProfileResponse.swift`
- `Tests/AppTests/TornadoIngredientInterpreterTests.swift`
- `Tests/AppTests/StormSetupProviderTests.swift`
- `Tests/AppTests/StormSetupCurrentResponseDTOTests.swift`
- `Tests/AppTests/AnvilIngredientEvidenceTests.swift`
- `docs/architecture.md`
- `docs/epics-stories.md`

### Public Response Shape Today

`StormSetupController` exposes `GET /api/v1/storm-setup/current?h3=...` and parses the query as a signed `Int64` H3 cell. That matches the repo lesson that Storm Setup must use signed `Int64` H3 cells end-to-end.

`StormSetupProviding` already has the future-friendly core boundary:

```swift
func currentSnapshot(for h3Cell: Int64) async throws -> TornadoIngredientSnapshot
func currentResponse(for h3Cell: Int64) async throws -> StormSetupCurrentResponse
```

`StormSetupCurrentResponse` returns:

- `setup`: H3 cell, centroid, source metadata, surface height, freshness.
- `ingredients`: canonical ingredients plus diagnostics.
- `profileAnalysis`: exact Anvil response when accepted.
- `assessment`: the current `TornadoIngredientAssessment`.

This shape should remain unchanged for the current redesign.

### Interpreter Flow Today

`TornadoIngredientInterpreter.assess(raw:freshness:evidence:)` computes:

- `instability`
- `moisture`
- `cloudBase`
- `capInhibition`
- `deepShear`
- `lowLevelRotation`
- `compositeSignal`
- `stormMode`
- `knownCorePillars`
- `limitingFactors`
- baseline `overall`
- baseline `confidence`
- Anvil-adjusted `overall` and `confidence`
- public drivers, limiting factors, and summary

The public `TornadoIngredientAssessment` currently contains:

- `overall`
- ingredient pillars
- `compositeSignal`
- `confidence`
- `trend`
- `stormModeHint`
- string `primaryDrivers`
- public `TornadoLimitingFactor` values
- `summary`

### Field Usage

Used directly today:

- Instability: `mlcapeJkg`, `mucapeJkg`, fallback `sbcapeJkg`.
- Moisture/cloud base: `mllclM`, fallback `tempDewPtDeltaF`.
- CIN: `mlcinJkg`.
- Deep shear: canonical `effectiveBulkShearMs`, fallback `effectiveShearKt` and `shear06kmKt`.
- Low-level rotation/tornado ingredient blend: `srh01kmM2s2`, fallback `effectiveSrhM2s2`, fallback `srh03kmM2s2`, plus `threeCapeJkg` and cloud-base support.
- Composite: `supercellComposite`, `significantTornadoFixed`, `significantTornadoEffective`.
- Anvil confidence/adjustment: `AnvilIngredientEvidence`.
- Freshness: `IngredientFreshness`.

Underused or ignored:

- `dcapeJkg`: not currently used. Reasonable to leave as future context, not tornado viability core.
- `lclLfcSeparationM`: not used. Could help convective depth/realization later, but do not block redesign on it.
- `lapseRate03kmCkm`: canonicalized from Anvil, not used directly except indirectly through 3CAPE if Anvil provides it.
- `lapseRate700500mbCkm`: not used.
- `shear03kmKt`, `shear01kmKt`: not used. Could support low-level shear diagnostics later, but SRH is currently more directly aligned with tornado-focused rotation.
- `bulkShear06kmMs`: exists in Anvil response but is not currently mapped; only `effectiveBulkShearMs` is mapped.
- `significantHail`/SHIP: carried through Anvil evidence and raw parameters but not relevant to tornado viability except as broader severe-storm context.
- `bunkersLeftMotion`, `stormRelativeWind46km`, `meanWind850300mb`: carried but not interpreted. Useful future diagnostics for storm mode/cold-pool tendencies, not current slice.
- `effectiveLayer`, `stormMotion`: used as markers that raw values are Anvil-backed to avoid double-counting Anvil evidence.
- `diagnostics`: available for data quality/context but not interpreted beyond provider/evidence pathways.

### Overall Computation

`overall` requires at least four known core pillars from instability, deep shear, low-level rotation, cloud base, and composite signal. It returns:

- `unknown` when fewer than four core pillars are known.
- `weak` when instability, deep shear, or cloud base is weak.
- `strong` when instability, deep shear, low-level rotation, cloud base, and composite signal are supportive, with at least three strong pillars.
- `conditional` when ingredients are present but low-level ingredients or CIN limit realization.
- `supportive` when the main pillars align without strong/conditional gates.

This is usable but mixes several concepts:

- Storm viability and supercell viability are not separate.
- Tornado efficiency is represented mostly through `lowLevelRotation`, but that field actually combines rotation, low-level stretching, and cloud-base efficiency.
- Realization is represented by `capInhibition` and copy branches rather than an explicit internal result.
- `compositeSignal` can boost or confirm the wrong domain because SCP and STP are combined.

### Low-Level Rotation Computation

`lowLevelRotation` currently chooses:

1. `srh01kmM2s2` when available.
2. `effectiveSrhM2s2` fallback.
3. `srh03kmM2s2` fallback.

Then it combines that rotation support with:

- `threeCapeJkg` as low-level stretching support.
- cloud-base support from `mllclM` or temperature/dewpoint spread.

The final value is the minimum of available rotation/stretching supports, then capped by cloud-base support when known.

The meteorological intent is good. The naming is now misleading: `lowLevelRotation` is no longer just rotation. It is low-level tornado ingredient efficiency. The public field can remain for compatibility, but the internal model should split:

- `lowLevelRotation`
- `lowLevelStretching`
- `cloudBaseEfficiency`
- `tornadoEfficiency`

### Composite Signal Computation

`assessCompositeSignal` currently takes:

```swift
max(supercellComposite, significantTornadoFixed, significantTornadoEffective)
```

and maps the strongest value on one threshold ladder:

- `< 1`: weak
- `< 2`: conditional
- `< 4`: supportive
- otherwise strong

This is the main bug/design smell. SCP answers "can storms organize as supercells?" STP answers "does the tornado-specific composite agree?" Fixed STP and effective/CIN STP also mean different things when they diverge. High SCP with low STP should not look like strong tornado support. High fixed STP with much lower effective STP should mean "ingredients exist, realization is conditional", not "composite strong."

### Anvil Evidence Usage

`StormSetupProvider` composes Anvil evidence after loading or caching the sampled surface snapshot.

Important behavior:

- Surface/2D normalized fields are used first to create a sampled snapshot.
- If Anvil is configured, the provider calls `analyzeProfile(for: h3Cell)`.
- Exact Anvil profile analysis is accepted only when request/debug/selected-surface valid times align.
- Stale pressure artifacts can produce degraded evidence with retained metric support, but exact `profileAnalysis` is omitted from the public response when stale.
- `makeCanonicalIngredients` maps Anvil/profile-derived fields over diagnostics when available.
- The interpreter receives canonical ingredients and Anvil evidence.
- The interpreter detects Anvil-backed canonical values via `effectiveLayer != nil || stormMotion != nil` and avoids using Anvil evidence to raise the already-canonical assessment a second time.

That canonical rule is correct and should be preserved.

Current caveat: `AnvilIngredientEvidence.strongestSupport` also considers SHIP. For tornado viability, SHIP should not raise tornado formation viability. It can remain in evidence diagnostics, but the tornado interpreter should prefer SCP/STP-specific evidence instead of `strongestSupport` when changing tornado viability. This can be handled in a later low-risk cleanup or included in the composite split if tests show current behavior is misleading.

### Primary Drivers and Limiting Factors

`primaryDrivers` are short strings, capped to three. They currently include broad statements like "Composite signals are supportive." Once composites split internally, that string should become more precise:

- "Supercell organization is supported."
- "Tornado composite guidance agrees."
- "Low-level tornado ingredients are supportive."

`TornadoLimitingFactor` currently includes:

- `weakInstability`
- `weakDeepShear`
- `weakLowLevelRotation`
- `elevatedCloudBases`
- `strongCap`
- `weakLift`
- `messyStormMode`
- `poorMoisture`
- `unknown`

This is barely adequate publicly, but inadequate internally. `weakLowLevelRotation` can now mean weak SRH, weak 3CAPE, or high cloud bases. Do not expand the public enum in the first slices. Add internal failure modes first, then decide whether any deserve public exposure.

### Summary Generation

The current summary is cautious and already avoids probability/prediction wording. It has good branches for:

- fixed STP stronger than effective STP
- CIN/initialization conditionality
- supercell ingredients present but low-level rotation/stretching limited
- unknown composite
- degraded/unavailable Anvil analysis

Weaknesses:

- "The setup is supportive" is broad and less clear than "The nearby environment can support..."
- The summary talks about "tornado potential" in one branch. That is not awful, but "tornado-capable storms" is better aligned with product direction.
- It does not consistently answer all four questions: what the environment can support, what helps, what limits, and how conditional it is.
- It still depends on the overloaded `compositeSignal`.

## Target Design

The target mental model should be internal first:

1. Storm viability: can storms matter at all?
2. Supercell viability: can storms organize and rotate?
3. Tornado efficiency: if a storm exists, are low-level tornado ingredients favorable?
4. Realization/failure mode: what is holding the setup back?
5. Composite confirmation: do SCP/STP agree with the ingredient diagnosis?
6. Confidence: how much should the diagnosis be trusted?

The product framing should be:

- Environmental viability.
- Tornado formation viability.
- Capability vs realization.
- Localized H3 diagnosis.
- Conditional setup.
- Primary limiter/failure mode.

Avoid:

- Tornado risk score.
- Tornado probability.
- Tornado prediction.
- Warning replacement.

## Recommended Internal Diagnosis Model

Start smaller than the full ideal model. The first implementation should be enough to remove the composite flaw and make limiter/copy decisions explicit without exploding the diff.

Recommended internal types, initially private to `TornadoIngredientInterpreter.swift`:

```swift
private struct TornadoViabilityDiagnosis: Sendable {
    let stormViability: IngredientSupport
    let supercellViability: IngredientSupport
    let lowLevelRotation: IngredientSupport
    let lowLevelStretching: IngredientSupport
    let cloudBaseEfficiency: IngredientSupport
    let tornadoEfficiency: IngredientSupport
    let inhibition: IngredientSupport
    let supercellComposite: IngredientSupport
    let tornadoComposite: TornadoCompositeDiagnosis
    let realization: TornadoRealizationMode
    let primaryFailureMode: TornadoFailureMode
    let confidence: SnapshotConfidence
}

private struct TornadoCompositeDiagnosis: Sendable {
    let fixedLayer: IngredientSupport
    let effectiveLayer: IngredientSupport
    let combined: IngredientSupport
    let fixedStrongerThanEffective: Bool
}

private enum TornadoRealizationMode: Sendable {
    case unlikely
    case conditional
    case possible
    case favorable
}

private enum TornadoFailureMode: Sendable {
    case insufficientInstability
    case weakStormOrganization
    case weakLowLevelRotation
    case weakLowLevelStretching
    case elevatedCloudBases
    case strongCap
    case conditionalInitiation
    case tornadoSignalLimited
    case stormModeUnknown
    case unknown
}
```

Recommended mapping:

- `stormViability`: mainly instability, moisture, cloud base, and CIN. Weak instability or very poor moisture should dominate.
- `supercellViability`: deep/effective shear plus instability, confirmed by SCP when available.
- `lowLevelRotation`: SRH-only ladder, preserving 0-1 km SRH priority and effective/0-3 km fallback.
- `lowLevelStretching`: 3CAPE-only ladder.
- `cloudBaseEfficiency`: MLLCL or temp/dewpoint spread support.
- `tornadoEfficiency`: minimum of low-level rotation, low-level stretching when known, and cloud-base efficiency when known.
- `inhibition`: current CIN support ladder.
- `supercellComposite`: SCP-only support.
- `tornadoComposite`: fixed STP and effective/CIN STP separately.
- `realization`: derived from storm/supercell viability, inhibition, STP fixed/effective disagreement, and missing storm-mode data.
- `primaryFailureMode`: one internal best explanation, not a grab bag.
- `confidence`: current freshness/core-pillar logic plus Anvil status/warnings/fallback use.

Do not expose these types publicly until the app has a concrete consumer. Internal-first keeps the API stable and gives tests a stable behavior target through the existing `TornadoIngredientAssessment`.

## API Compatibility Plan

Keep the current public response shape for now:

- Continue returning `StormSetupCurrentResponse`.
- Continue returning `TornadoIngredientAssessment`.
- Do not rename `lowLevelRotation` or `compositeSignal` publicly in this redesign.
- Populate `lowLevelRotation` from internal `tornadoEfficiency` or a compatibility blend that preserves current app behavior.
- Populate `compositeSignal` from a conservative compatibility result, likely `min(supercellComposite, tornadoComposite.combined)` when both are known, or the known value when only one domain is known.

Future-facing shape only, not for this pass:

```swift
struct TornadoViabilityReport: Content, Sendable {
    let h3Cell: Int64
    let centroid: StormSetupCentroid
    let source: StormSetupSourceMetadata
    let validTime: Date?
    let freshness: IngredientFreshness
    let overall: IngredientSupport
    let realization: String
    let primaryFailureMode: String
    let summary: String
    let details: TornadoViabilityDetails
    let confidence: SnapshotConfidence
}

struct TornadoViabilityDetails: Content, Sendable {
    let stormViability: IngredientSupport
    let supercellViability: IngredientSupport
    let tornadoEfficiency: IngredientSupport
    let inhibition: IngredientSupport
    let supercellComposite: IngredientSupport
    let tornadoComposite: IngredientSupport
    let limitingFactors: [String]
}
```

This should not be implemented until the app needs it.

## Composite Cleanup Recommendation

Replace the single max-based composite interpretation with separate internal functions:

- `assessSupercellComposite(_ raw) -> IngredientSupport`
  - Use `supercellComposite` only.
  - Keep Anvil/SCP evidence as confirmation of supercell viability.
- `assessTornadoComposite(_ raw) -> TornadoCompositeDiagnosis`
  - Interpret `significantTornadoFixed` and `significantTornadoEffective` separately.
  - Use STP-specific thresholds, not the old SCP/STP shared ladder.
  - Treat fixed STP stronger than effective STP as conditional realization.

Behavior rules:

- High SCP + low STP: supercell support exists, tornado-specific signal is limited.
- Low SCP + high STP: do not let STP alone imply strong storm organization.
- High fixed STP + lower effective STP: ingredients exist, but realization is conditional.
- High effective STP: tornado composite agrees with ingredient diagnosis.
- Public `compositeSignal`: compatibility field only; it should no longer be a max of SCP/STP.

Use thresholds already present in `AnvilIngredientEvidence` as a starting point for consistency:

- SCP: `<0.5 weak`, `<1.5 conditional`, `<3 supportive`, otherwise strong.
- STP: `<0.5 weak`, `<1.25 conditional`, `<2.5 supportive`, otherwise strong.

## Summary and Copy Guidance

Tone requirements:

- Calm.
- Clear.
- Useful.
- Trustworthy.
- Not dramatic.
- Capability vs realization, not prediction.

Recommended patterns:

- Weak: "The nearby environment does not currently support tornado-capable storms well. Instability, storm organization, or low-level tornado ingredients are limited."
- Conditional: "The nearby environment has some ingredients for tornado-capable storms, but realization is conditional. [Limiter] is the main question."
- Supercell-supportive/tornado-limited: "The environment can support organized rotating storms, but tornado-specific low-level ingredients are limited."
- Supportive: "The environment can support organized rotating storms, and low-level tornado ingredients are favorable. Stay weather-aware if storms can form."
- Strong: "The environment strongly supports organized rotating storms, and low-level tornado ingredients are aligned. This still describes environmental capability, not a guarantee storms will occur."
- Unknown: "There is not enough current ingredient data to judge tornado formation viability confidently."

Limiter clauses:

- Strong cap: "CIN may keep the setup from realizing."
- Conditional initiation: "Storm initiation remains the main question."
- High cloud bases: "Elevated cloud bases reduce tornado efficiency."
- Weak 3CAPE: "Weak low-level buoyancy limits stretching near the ground."
- Weak SRH: "Low-level rotation is limited."
- Weak organization: "Storm organization support is limited."
- Fixed/effective STP mismatch: "The fixed-layer signal is stronger than the effective-layer signal, so the setup remains conditional."
- Unknown storm mode: "Storm mode is not resolved from the current data."

Avoid:

- "Tornadoes are likely."
- "Tornadoes will occur."
- "Tornado risk is..."
- "Prediction."
- Probability language.

## Implementation Slices for 5.4 Mini

### Slice 1: Composite Signal Cleanup

**Objective**

Split SCP and STP interpretation internally without changing the public response shape.

**Files likely touched**

- `Sources/App/StormSetup/TornadoIngredientInterpreter.swift`
- `Tests/AppTests/TornadoIngredientInterpreterTests.swift`

**Exact constraints**

- Do not change `TornadoIngredientAssessment`.
- Do not change endpoint response models.
- Do not introduce new public enums.
- Keep `compositeSignal` public field but stop maxing SCP/STP together.
- Preserve existing Sendable behavior.

**Expected behavior change**

- High SCP with weak STP no longer produces a strong tornado-compatible `compositeSignal`.
- High fixed STP with much lower effective STP produces conditional realization behavior.
- High effective STP can still confirm tornado-specific viability when ingredients agree.

**Tests to add/update**

- Add a test where `supercellComposite` is strong, both STP fields are weak, and `overall` stays conditional/supportive based on ingredients rather than strong composite.
- Add a test where fixed STP is supportive/strong and effective STP is weak/conditional; summary remains conditional.
- Update any tests expecting old `compositeSignal` max behavior.

**Acceptance criteria**

- `swift test --filter TornadoIngredientInterpreterTests` passes.
- Public encoded DTO shape is unchanged.
- Existing Anvil-backed double-counting test still passes.

### Slice 2: Internal Viability Diagnosis

**Objective**

Introduce a private/internal diagnosis object and map it back to `TornadoIngredientAssessment`.

**Files likely touched**

- `Sources/App/StormSetup/TornadoIngredientInterpreter.swift`
- `Tests/AppTests/TornadoIngredientInterpreterTests.swift`

**Exact constraints**

- Diagnosis types remain private to the interpreter file unless Swift test visibility forces `fileprivate`.
- Existing public assessment fields remain unchanged.
- Preserve current thresholds unless a test explicitly documents the change.
- Do not move provider, controller, or DTO code.

**Expected behavior change**

- No major public behavior shift beyond cleaner internal source of truth.
- `overall`, `primaryDrivers`, `limitingFactors`, and `summary` should be derived from diagnosis instead of scattered pillar values.

**Tests to add/update**

- Refactor tests only as needed.
- Add a test that low-level SRH, 3CAPE, and LCL can produce distinct diagnosis outcomes through public fields/summary.
- Keep current tests for weak, conditional, supportive, strong, missing fields, Anvil evidence, and fallback behavior.

**Acceptance criteria**

- `swift test --filter TornadoIngredientInterpreterTests` passes.
- No public model or route test changes are required.
- The interpreter reads as diagnosis first, response mapping second.

### Slice 3: Failure Mode / Limiter Precision

**Objective**

Improve limiter precision using current inputs, especially 3CAPE, SRH, LCL, CIN, and STP fixed/effective disagreement.

**Files likely touched**

- `Sources/App/StormSetup/TornadoIngredientInterpreter.swift`
- `Tests/AppTests/TornadoIngredientInterpreterTests.swift`
- Optional only if justified: `Sources/App/StormSetup/TornadoIngredientAssessment.swift`

**Exact constraints**

- Prefer internal `TornadoFailureMode` over public enum changes.
- Do not add public limiting factors unless a current app need exists.
- Keep existing public limiting factors backward compatible.
- If public enum additions are made, add DTO encoding coverage and document why internal-only was insufficient.

**Expected behavior change**

- Weak SRH and weak 3CAPE are internally distinguishable.
- Elevated cloud bases are not hidden inside `weakLowLevelRotation`.
- CIN and fixed/effective STP disagreement can produce a conditional initiation/realization diagnosis.
- Public limiting factors remain stable unless explicitly changed.

**Tests to add/update**

- Weak SRH with adequate 3CAPE -> public summary points at low-level rotation.
- Adequate SRH with weak 3CAPE -> public summary points at low-level buoyancy/stretching.
- High MLLCL -> public summary points at elevated cloud bases.
- CIN below strong-cap threshold but still meaningful -> conditional initiation copy, not strong cap.
- Fixed STP stronger than effective STP -> conditional realization copy.

**Acceptance criteria**

- `swift test --filter TornadoIngredientInterpreterTests` passes.
- Public limiter array does not become noisier than today.
- Summary identifies one primary limiter in each targeted case.

### Slice 4: Summary Copy Rewrite

**Objective**

Rewrite summaries around environmental capability vs realization in SkyAware language.

**Files likely touched**

- `Sources/App/StormSetup/TornadoIngredientInterpreter.swift`
- `Tests/AppTests/TornadoIngredientInterpreterTests.swift`

**Exact constraints**

- No public model changes.
- No deterministic tornado claims.
- No "risk score", "probability", or warning replacement framing.
- Summaries should mention raw values only if existing public behavior already does, which today it does not.

**Expected behavior change**

- Summaries consistently answer:
  - what the environment can support
  - what is helping
  - what is limiting
  - how conditional it is
- Copy uses "tornado-capable storms" and "environment can support" framing.

**Tests to add/update**

- Update prohibited-language test with the expanded banned phrase list.
- Add copy assertions for weak, conditional, supportive, strong, unknown.
- Add targeted assertions for:
  - supercell-supportive but tornado-limited
  - conditional initiation/CIN
  - fixed/effective STP mismatch
  - degraded Anvil evidence

**Acceptance criteria**

- `swift test --filter TornadoIngredientInterpreterTests` passes.
- No summary contains deterministic tornado occurrence language.
- Summaries remain short enough for app display.

### Slice 5: Test Matrix and Golden Fixtures

**Objective**

Add focused coverage for representative environments and prevent regression in canonical Anvil behavior.

**Files likely touched**

- `Tests/AppTests/TornadoIngredientInterpreterTests.swift`
- `Tests/AppTests/StormSetupProviderTests.swift`
- Optional: test helper extraction if the file becomes unwieldy.

**Exact constraints**

- Keep fixtures inline unless repeated setup becomes genuinely hard to review.
- Do not add live network dependencies.
- Do not add brittle full JSON snapshots unless a DTO contract is being changed.
- Keep each test named around the meteorological pattern it protects.

**Expected behavior change**

- None intended beyond test coverage.

**Tests to add/update**

- Weak setup.
- Supercell-supportive but tornado-limited setup.
- Conditional initiation/capped setup.
- Low-level-tornado-efficient setup.
- Strong supportive setup.
- Missing-field fallback.
- Degraded Anvil evidence.
- Anvil-backed canonical values not double-counted.

**Acceptance criteria**

- `swift test --filter TornadoIngredientInterpreterTests` passes.
- `swift test --filter StormSetupProviderTests` passes if provider assertions are touched.
- Tests document expected behavior without relying on private implementation details.

### Slice 6: Future H3 Viability Endpoint Investigation / Prep

**Objective**

Document and, only if explicitly requested later, prepare service boundaries for an any-cell tornado viability endpoint.

**Files likely touched**

- Documentation only for this slice unless separately authorized.
- Future implementation may touch:
  - `Sources/App/Controllers/StormSetupController.swift`
  - `Sources/App/StormSetup/StormSetupProvider.swift`
  - new `Sources/App/StormSetup/TornadoViabilityReport.swift`
  - `Tests/AppTests/StormSetupControllerTests.swift`
  - `Tests/AppTests/StormSetupCurrentResponseDTOTests.swift`

**Exact constraints**

- Do not implement the endpoint in this redesign.
- Preserve signed `Int64` H3 contract.
- Do not introduce server-side lat/lon storage.
- Reuse `StormSetupProviding.currentSnapshot(for:)`.
- Return source metadata and freshness if a future endpoint is added.

**Expected behavior change**

- None in this investigation/prep slice.

**Tests to add/update**

- None for documentation-only prep.
- Future endpoint implementation should add route tests for:
  - missing `h3Cell`
  - invalid signed `Int64`
  - invalid H3 cell
  - successful response
  - provider error mapping

**Acceptance criteria**

- Future endpoint path is clear and does not duplicate provider logic.
- Implementation remains optional and explicitly out of current scope.

## Test Plan

Focused commands per slice:

```bash
swift test --filter TornadoIngredientInterpreterTests
swift test --filter AnvilIngredientEvidenceTests
swift test --filter StormSetupProviderTests
swift test --filter StormSetupCurrentResponseDTOTests
swift test --filter StormSetupControllerTests
```

Broader final verification for implementation work:

```bash
swift test
```

Testing principles:

- Use deterministic raw parameter fixtures.
- Keep Anvil/profile tests synthetic and local.
- Avoid live HRRR, NOMADS, Anvil, Redis, or Postgres dependencies.
- Keep DTO contract tests unchanged unless a public response shape is intentionally changed.
- Assert copy for meaning and prohibited language, not every punctuation mark.

## Risks / Edge Cases

- Composite scale drift: SCP and STP thresholds must not be silently treated as interchangeable again.
- Public field naming: `lowLevelRotation` will remain public but internally represent broader tornado efficiency. This is acceptable for compatibility, but document it in code comments if needed.
- SHIP leakage: `AnvilIngredientEvidence.strongestSupport` can include SHIP. The tornado interpreter should avoid using hail composite evidence to raise tornado viability.
- Missing 3CAPE: current fallback allows SRH-only low-level support. Preserve this fallback but keep confidence honest.
- Missing SRH: 3CAPE-only support should not imply rotation; it should produce limited confidence or conditional diagnosis.
- High LCL: elevated cloud bases should reduce tornado efficiency even when SRH/STP are favorable.
- CIN sign conventions: current logic expects negative `mlcinJkg`; tests should pin thresholds around `-150`, `-75`, and `-25`.
- Stale Anvil: stale evidence can retain metric support but should degrade confidence and should not expose exact `profileAnalysis`.
- Cached snapshots: cached surface snapshots should refresh Anvil evidence when provider is configured.
- H3 contract: keep signed `Int64`; do not introduce string/hex H3 IDs except presentation-only future work.

## Future H3 Endpoint Path

Current code already accepts H3 cells:

- `StormSetupController.current` parses `h3` as signed `Int64`.
- `DefaultStormSetupH3Resolver` validates the H3 cell and resolves centroid.
- `StormSetupProviding.currentSnapshot(for:)` loads the localized snapshot.
- `StormSetupProvider` resolves HRRR source metadata, samples diagnostics, overlays Anvil canonical fields when available, and assesses the result.

Future endpoint concept:

```http
GET /api/v1/storm-setup/tornado-viability?h3Cell=617700169958293503
```

or folded into existing:

```http
GET /api/v1/storm-setup/current?h3=617700169958293503
```

Recommended future path:

1. Keep the existing `current` endpoint as the app-compatible source for now.
2. If a richer report is needed, add a `TornadoViabilityReporting` mapper that converts `TornadoIngredientSnapshot` plus internal diagnosis into `TornadoViabilityReport`.
3. Reuse `currentSnapshot(for:)`; do not duplicate HRRR/Anvil/cache orchestration.
4. Return:
   - `h3Cell`
   - `centroid`
   - `source` metadata
   - `validTime`
   - `forecastHour`
   - `freshness`
   - `confidence`
   - `summary`
   - `overall`
   - `realization`
   - `primaryFailureMode`
   - `details`
5. Preserve `ingredients.canonical` and diagnostics only if the consumer needs raw values; casual app users should see meaning first.

Caching concerns:

- Existing `StormSetupSnapshotCacheKey` includes H3, source metadata, and rules version.
- If internal diagnosis rules change materially, bump `StormSetupRulesVersion` so cached assessments do not mix old rules with new copy/thresholds.
- Future report-level caching should be avoided at first; cache sampled/canonical ingredients and derive reports cheaply.

## Missing Data / Future Enhancements

These would improve realization and storm-mode diagnosis but should not be prerequisites for this redesign:

- HRRR simulated reflectivity for initiation/storm mode hints.
- HRRR updraft helicity for rotating updraft signal.
- Model storm-mode classification.
- Observed radar for realized storms and mode.
- Watches, warnings, and mesoscale discussions for official context.
- Boundaries/fronts/dryline/outflow proxies.
- Surface observations for mesoanalysis correction.
- Time-window trends across multiple valid times.

These should be treated as future inputs that refine realization/storm mode, not as blockers for environmental viability.

## Open Questions

- Should public `TornadoLimitingFactor` eventually add `weakLowLevelBuoyancy`, `conditionalInitiation`, `tornadoSignalConditional`, and `stormModeUnknown`, or should those remain internal until the app requests structured detail?
- Should `compositeSignal` compatibility map to the minimum of supercell and tornado composite support, the tornado composite support only, or a documented combined confirmation value?
- Should SHIP be removed from `AnvilIngredientEvidence.strongestSupport` for tornado interpreter adjustments, or should the interpreter simply use more specific SCP/STP evidence and leave `strongestSupport` generic?
- Should `bulkShear06kmMs` from Anvil be mapped into `shear06kmKt` when `effectiveBulkShearMs` is unavailable?
- Should missing SRH with present 3CAPE produce `unknown` rotation and conditional tornado efficiency rather than a known low-level field?
- What exact app copy length is acceptable for summaries on the target SkyAware surfaces?

