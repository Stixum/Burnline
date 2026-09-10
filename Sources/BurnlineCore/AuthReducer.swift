import Foundation

/// One thing Burnline has learned about Claude Code's ability to reach
/// Anthropic.
///
/// Evidence is applied one piece at a time so the order is explicit and
/// testable. `UsageStore` gathers it; nothing here touches a file or a clock.
public enum AuthEvidence: Equatable, Sendable {

    /// A probe answered.
    ///
    /// `discoveredByPoll` marks a probe run **after** a poll that completed
    /// without moving the utilization cache — the sequence that distinguishes a
    /// credential the user retired from one that simply lapsed. It is the only
    /// thing separating `.signInExpired` from `.signedOut`, because by the time
    /// either exists the CLI reports both identically.
    ///
    /// ⚠️ The caller owns the flag's honesty: pass `true` only when the probe
    /// immediately before that poll answered `.credentialPresent`.
    case probe(AuthProbeResult, discoveredByPoll: Bool)

    /// A poll completed **and** the utilization cache moved.
    ///
    /// Proof the API call succeeded, which no amount of local reasoning can
    /// match. ⚠️ Its absence proves nothing — the CLI throttles that write to
    /// five minutes, and every non-auth failure (network, 429, 5xx, timeout)
    /// leaves it unmoved too. Only the positive is evidence, which is why there
    /// is no `pollDidNotRefreshCache` case: "unmoved" is a reason to re-probe,
    /// and it reaches the reducer as `discoveredByPoll` on that probe.
    case pollRefreshedCache

    /// A capture that can be **proven** minted at this instant.
    ///
    /// ⚠️ `provenAt`, never `capturedAt`. The latter is a conservative upper
    /// bound, so an undated replay carrying it could clear a real block. Same
    /// distinction, same reason, as the high-water mark's demotion rule.
    case captureProven(at: Date)
}

public extension AuthEvidence {

    /// The proof, if any, carried by this cycle's capture candidates.
    ///
    /// 🔴 **Taken across the DATED CANDIDATES, before selection — not off the
    /// capture the store ends up holding.** `RateLimitHighWater.reconcile`
    /// rebuilds the trusted capture as `RateLimitCapture(version:capturedAt:
    /// sevenDay:fiveHour:)`, and `provenAt` is not among those fields: it comes
    /// back nil every time. An implementation that read it there would compile,
    /// pass a hand-built test, and never clear a block — silently, and only for
    /// the users this feature exists for.
    ///
    /// Taking the maximum across candidates is also right on its own terms: an
    /// API success is proof the CLI reached Anthropic whether or not that
    /// particular reading went on to win selection.
    static func fromCaptures(_ candidates: [RateLimitCapture]) -> AuthEvidence? {
        guard let newest = candidates.compactMap(\.provenAt).max() else { return nil }
        return .captureProven(at: Date(timeIntervalSince1970: newest))
    }
}

/// Folds evidence into the standing `AuthBlock`.
///
/// Pure, because `UsageStore` has no test target and this is where the subtle
/// rules live — the same reason `PollDecision`, `NotificationDecision` and
/// `CaptureSelection` exist.
public enum AuthReducer {

    public static func reduce(_ block: AuthBlock?,
                              _ evidence: AuthEvidence,
                              now: Date) -> AuthBlock? {
        switch evidence {

        // Outranks everything, and deliberately cannot set a block: a refreshed
        // cache is proof the API call succeeded, so no other signal gathered in
        // the same cycle can outweigh it.
        case .pollRefreshedCache:
            return nil

        case let .captureProven(at: provenAt):
            guard let block else { return nil }
            // Proof the CLI reached Anthropic *after* the block was observed.
            // Not before: a capture older than the block describes a period the
            // block already accounts for.
            return provenAt > block.detectedAt ? nil : block

        case let .probe(result, discoveredByPoll):
            switch result {

            // A presence finding refutes an absence finding. Worst case the
            // credential is merely dead-but-undiscovered, and the next poll's
            // re-probe says so — which is strictly better than a block with no
            // way out for a user whose sessions never publish a capture.
            case .credentialPresent:
                return nil

            // ⚠️ Not `nil`. A probe that could not run is not evidence in either
            // direction, and must neither set a block nor clear one.
            case .noAnswer:
                return block

            case let .blocked(kind):
                // A lapse the poll discovered, rather than a sign-out the user
                // performed. Only `.signedOut` converts: a locked keychain is
                // not an expiry however it was found.
                let resolved: AuthBlock.Kind =
                    (discoveredByPoll && kind == .signedOut) ? .signInExpired : kind

                // 🔴 `detectedAt` MUST NOT advance while the same block stands.
                // It is re-derived on a timer, so refreshing the date every
                // cycle would push it permanently ahead of any capture's
                // `provenAt` — and the capture-clearing rule above could then
                // never fire. The block would be unclearable by the one signal
                // that works for a user who never opens a terminal.
                if let block, block.kind == resolved { return block }
                return AuthBlock(kind: resolved, detectedAt: now)
            }
        }
    }
}
