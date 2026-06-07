# Lessons

- Storm Setup must use signed `Int64` H3 cells end-to-end because the rest of the server already stores and reasons about H3 that way.
- Do not introduce string or hex H3 identifiers in the contract unless the feature explicitly needs a presentation-only layer.
- When a user corrects a finished slice, update the lesson log immediately so the next issue does not repeat the same mismatch.
