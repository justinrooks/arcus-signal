# Storm Setup Anvil Canonical Ingredients Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Anvil profile analysis the canonical source for tornado ingredients in storm setup responses while preserving the native HRRR surface/2D GRIB values as diagnostics and fallback data.

**Architecture:** Keep the current storm-setup pipeline intact. Add a narrow canonical-vs-diagnostics split in the storm setup response models, teach the provider to derive canonical ingredient values from Anvil when available, and keep the raw GRIB-derived values available for fallback and diagnostics. The interpreter should continue to operate on a single ingredient view, but that view should now prefer the Anvil-backed canonical values.

**Tech Stack:** Swift, Vapor, Fluent, XCTest/Testing.

---

### Task 1: Extend the storm setup ingredient models

**Files:**
- Modify: `Sources/App/StormSetup/StormSetupModels.swift`
- Modify: `Sources/App/StormSetup/StormSetupCurrentResponse.swift`

- [ ] **Step 1: Write the failing test**

Add assertions to `Tests/AppTests/StormSetupCurrentResponseDTOTests.swift` that the encoded response now exposes `ingredients.canonical` and `ingredients.diagnostics`.

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter StormSetupCurrentResponseDTOTests`
Expected: fails because the split ingredient payload does not exist yet.

- [ ] **Step 3: Write minimal implementation**

Add a small ingredient wrapper type with `canonical` and `diagnostics` sections, and add the minimal canonical fields needed for Anvil-backed tornado ingredients.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter StormSetupCurrentResponseDTOTests`
Expected: passes once the response shape is updated.

### Task 2: Preserve native GRIB diagnostics and prefer Anvil canonicals

**Files:**
- Modify: `Sources/App/StormSetup/TornadoIngredientNormalizer.swift`
- Modify: `Sources/App/StormSetup/GribInventoryFieldMap.swift`
- Modify: `Sources/App/StormSetup/StormSetupProvider.swift`

- [ ] **Step 1: Write the failing test**

Add focused provider tests that prove Anvil values win for canonical tornado ingredients when analysis is present, and that fallback still uses native GRIB values when it is absent.

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter StormSetupProviderTests`
Expected: fails until the provider composes canonical and diagnostic ingredient views correctly.

- [ ] **Step 3: Write minimal implementation**

Populate the canonical ingredient view from Anvil response values, keep native HRRR values in the diagnostics view, and keep the existing fallback path for Anvil-unavailable cases.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter StormSetupProviderTests`
Expected: passes with the precedence and fallback rules intact.

### Task 3: Add focused normalization coverage

**Files:**
- Modify: `Tests/AppTests/StormSetupIngredientNormalizationTests.swift`

- [ ] **Step 1: Write the failing test**

Add checks for surface pressure and 10m wind preservation in the native GRIB diagnostic path.

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter StormSetupIngredientNormalizationTests`
Expected: fails until the normalizer keeps the extra surface diagnostics.

- [ ] **Step 3: Write minimal implementation**

Update the normalizer to retain the extra surface diagnostics without changing the existing CAPE/CIN/SRH/shear behavior.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter StormSetupIngredientNormalizationTests`
Expected: passes.

