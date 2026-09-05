import Testing
@testable import BurnlineCore

// What the Launch-at-login toggle shows is the SYSTEM's answer, not the stored
// flag. The flag records what the user asked for; `SMAppService.status` records
// what macOS did with it, and a user can switch the item off in System Settings
// without the app ever hearing about it.

@Test func onlyAnEnabledLoginItemShowsTheToggleOn() {
    #expect(LoginItemRegistration.enabled.isOn)
    #expect(!LoginItemRegistration.notRegistered.isOn)
    #expect(!LoginItemRegistration.requiresApproval.isOn)
    #expect(!LoginItemRegistration.notFound.isOn)
}

/// Exceptions only: the one state the user can do something about is the one
/// that carries a note, and it says where to go.
@Test func onlyAnItemAwaitingApprovalCarriesANote() {
    #expect(LoginItemRegistration.enabled.note == nil)
    #expect(LoginItemRegistration.notRegistered.note == nil)
    #expect(LoginItemRegistration.notFound.note == nil)
    #expect(LoginItemRegistration.requiresApproval.note?.contains("System Settings") == true)
}
