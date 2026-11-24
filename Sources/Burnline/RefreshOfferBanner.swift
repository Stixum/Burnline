import SwiftUI
import BurnlineCore

/// The popover's offer to turn on automatic refresh. Every word is
/// `RefreshOffer`'s; this only draws it.
///
/// **Accent violet, not amber.** Amber in this app is a state that is wrong
/// with a remedy on offer, and the amber line directly above this one already
/// says the figure is being carried forward. This is a question, and violet is
/// the colour of the things the user can act on. Symbol + words, never colour
/// alone.
///
/// The buttons sit on their own row. Beside the title they would squeeze it,
/// and the row would resolve that by wrapping a button, which is the one part
/// that has to stay whole (`AuthBanner` records the same lesson).
///
/// ⚠️ Takes no store, like `AuthBanner`, so it can be rendered through
/// `ImageRenderer` without a running app.
struct RefreshOfferBanner: View {

    let offer: RefreshOffer
    let accept: () -> Void
    let decline: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Image(systemName: "arrow.clockwise.circle.fill").font(.system(size: 9))
                Text(offer.title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .fixedSize()
            }
            .foregroundStyle(Theme.accent)
            Text(offer.detail)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 14) {
                Button(RefreshOffer.acceptLabel, action: accept)
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .fixedSize()
                    .foregroundStyle(Theme.accent)
                    .help(RefreshOffer.acceptHelp)
                Button(RefreshOffer.declineLabel, action: decline)
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .fixedSize()
                    .foregroundStyle(Theme.textMuted)
                    .help(RefreshOffer.declineHelp)
            }
            .padding(.top, 1)
        }
        .padding(.top, 7)
    }
}
