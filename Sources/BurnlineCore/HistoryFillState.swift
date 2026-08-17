import Foundation

/// What the launch fill is doing, for a UI that has to sit through it.
///
/// 🔴 `.idle` is not a cosmetic case. Without it, "first launch, the archive is
/// still filling" and "the archive is genuinely empty" render identically while
/// meaning opposite things — and the fill is a measured 20.4 seconds over a real
/// corpus, which is long enough for someone to reach the wrong conclusion and
/// act on it.
///
/// Lives in the library rather than beside `UsageStore` in the app target so the
/// two rules below can be tested. Both were wrong in a shipped build: the window
/// never reloaded when the fill finished, and told a first-time user there was
/// nothing archived while six weeks were being written behind it.
public enum HistoryFillState: Equatable, Sendable {
    /// No fill has run this launch.
    case idle
    /// In flight — the 20.4-second case, and the whole reason for the callback.
    case filling(HistoryFill.Progress)
    case complete
    /// At least one range could not be read. It claimed no coverage, so the
    /// next launch retries it; this only says the launch was incomplete.
    case failed(String)
}

extension HistoryFillState {
    /// The coarse phase a reload keys on.
    ///
    /// 🔴 **Progress is deliberately collapsed.** The fill publishes ~100
    /// reports across its 20 seconds, and none of them changes what is on disk —
    /// only the commit at the end of a range does. Keying a reload on the state
    /// itself would re-read the whole archive a hundred times to learn nothing;
    /// keying it on this re-reads on the transitions that can actually have
    /// moved the archive underneath the window.
    ///
    /// 🔴 **`.idle` and `.complete` are separate phases and must stay separate.**
    /// Folding them together — they are both "not filling" — is what removes the
    /// idle → complete transition, and that transition is the entire fix: a fill
    /// that found nothing uncovered to read goes straight from one to the other
    /// without ever publishing progress.
    public enum ReloadPhase: Equatable, Sendable {
        case idle
        case filling
        /// `.complete` or `.failed`. Past this point an empty archive means
        /// empty rather than "not yet", which is the claim the window branches on.
        case finished
    }

    public var reloadPhase: ReloadPhase {
        switch self {
        case .idle: .idle
        case .filling: .filling
        case .complete, .failed: .finished
        }
    }

    /// What the History window draws in its main region.
    ///
    /// - Parameter archiveIsEmpty: `nil` when the archive has not been read yet,
    ///   which is a third answer and not the same as empty.
    public func display(archiveIsEmpty: Bool?) -> HistoryDisplay {
        // A populated archive is drawn whatever the fill is doing. A gap fill on
        // a later launch has real weeks to show while it runs, and hiding them
        // behind a progress bar would just be a second way of saying "nothing
        // here" — the exact claim this rule exists to stop making.
        if archiveIsEmpty == false { return .content }

        switch self {
        case .filling(let progress):
            return .filling(progress)

        // 🔴 `.idle` is NOT `.complete`. It means no fill has reported yet, so
        // "nothing archived" is not a claim the app can make — and rendering it
        // as a fill would be the opposite lie. It resolves within a second or
        // two of launch and cannot stick: the fill publishes a terminal state
        // even when it finds nothing uncovered to read.
        case .idle:
            return .loading

        case .complete, .failed:
            return archiveIsEmpty == nil ? .loading : .empty
        }
    }
}

/// The one region under the History window's header, resolved from the fill
/// state and whether the archive has been read.
public enum HistoryDisplay: Equatable, Sendable {
    /// The archive is being read, or the fill has not reported yet. Says nothing
    /// about whether there is anything in it.
    case loading
    /// The one-time build of the archive, with a real denominator.
    case filling(HistoryFill.Progress)
    /// Genuinely nothing, and the fill has finished saying so.
    case empty
    case content
}
