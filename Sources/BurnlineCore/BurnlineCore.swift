// Burnline core logic.
// See docs/superpowers/specs/2026-08-11-burnline-design.md
//
// Everything in this target is pure or filesystem-only — no SwiftUI, and no
// calls to Date(). `now` is always injected, which is what makes the
// time-dependent behaviour testable.
