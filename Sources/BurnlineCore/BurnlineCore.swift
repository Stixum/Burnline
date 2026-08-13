// Burnline core logic.
//
// Everything in this target is pure or filesystem-only, and imports no SwiftUI.
// Time-dependent behaviour takes `now` as a parameter so it can be tested at
// any instant, which is why the window maths and projection are exercisable
// without a clock.
//
// Two deliberate exceptions read the clock directly, both at the edge rather
// than in the logic: `Snapshot.liveAge` (how old is this reading, asked at
// render time) and `ClaudeSettingsFile.write`'s default backup suffix. An
// earlier version of this comment claimed there were none at all.
