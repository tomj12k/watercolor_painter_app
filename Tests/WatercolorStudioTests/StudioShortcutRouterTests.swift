import Testing
@testable import WatercolorStudio

@Suite struct StudioShortcutRouterTests {
    @Test func barePaintingShortcutsYieldWhileTextEntryIsFocused() {
        for key in ["b", "e", "w", "s", "m", "d", "[", "]"] {
            #expect(StudioShortcutRouter.allowsBarePaintingShortcut(key, textEntryIsFocused: false))
            #expect(!StudioShortcutRouter.allowsBarePaintingShortcut(key, textEntryIsFocused: true))
        }
    }

    @Test func unrelatedKeysAreNeverClaimedAsBarePaintingShortcuts() {
        #expect(!StudioShortcutRouter.allowsBarePaintingShortcut("z", textEntryIsFocused: false))
        #expect(!StudioShortcutRouter.allowsBarePaintingShortcut("", textEntryIsFocused: false))
    }
}
