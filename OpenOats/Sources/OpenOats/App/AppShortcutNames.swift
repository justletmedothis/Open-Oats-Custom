import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    // Initial values match the previously hard-coded hotkeys so existing
    // users keep the same shortcuts until they customize them in Settings.
    static let toggleMeeting = Self(
        "toggleMeeting",
        initial: .init(.l, modifiers: [.command, .shift])
    )
    static let toggleSuggestionPanel = Self(
        "toggleSuggestionPanel",
        initial: .init(.o, modifiers: [.command, .shift])
    )
}
