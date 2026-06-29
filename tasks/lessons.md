# Lessons

- Storm Setup must use signed `Int64` H3 cells end-to-end because the rest of the server already stores and reasons about H3 that way.
- Do not introduce string or hex H3 identifiers in the contract unless the feature explicitly needs a presentation-only layer.
- When a user corrects a finished slice, update the lesson log immediately so the next issue does not repeat the same mismatch.
- Production bootstrap tests must set every earlier fail-fast prerequisite explicitly, or the assertion will drift to the wrong config gate and stop proving the intended behavior.
- For one-value handoffs, prefer threading the value through the existing explicit call boundary over ambient state or a broader request-shape rewrite. If the bug is "missing input," do not solve it by inventing a new pipeline.
