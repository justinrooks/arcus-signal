# Lessons

- Storm Setup must use signed `Int64` H3 cells end-to-end because the rest of the server already stores and reasons about H3 that way.
- Do not introduce string or hex H3 identifiers in the contract unless the feature explicitly needs a presentation-only layer.
- When a user corrects a finished slice, update the lesson log immediately so the next issue does not repeat the same mismatch.
- Production bootstrap tests must set every earlier fail-fast prerequisite explicitly, or the assertion will drift to the wrong config gate and stop proving the intended behavior.
- For one-value handoffs, prefer threading the value through the existing explicit call boundary over ambient state or a broader request-shape rewrite. If the bug is "missing input," do not solve it by inventing a new pipeline.
- When a provider intentionally shifts HRRR pressure candidates before lookup, tests must derive their expected lookup keys from the same shifted helper. Comparing against the unshifted surface candidate just hides the bug behind a broken assertion.
- If the warmed pressure-key mapping changes in one consumer, audit the other consumer paths that use `PressureArtifactCatalogLookupProviding` immediately. Preview and dashboard code can drift independently even when they share the same catalog service.
- For Docker cache storage, keep the host bind-source path separate from the container runtime path. Verify the resolved environment and mount first; prefer matching ownership and `0770` over using `0777` to mask a path that was never mounted.
- For the production Storm Setup contract, preserve `AnvilAnalyzeProfileResponse` only; keep Anvil request/profile-preview debug envelopes on the dev diagnostics endpoint unless a story explicitly promotes them.
