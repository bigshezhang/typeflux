@testable import Typeflux
import XCTest

@MainActor
final class SettingsViewModelHotkeyTests: XCTestCase {
    func testHotkeysRefreshWhenSettingsStoreChangesExternally() async throws {
        let suiteName = "SettingsViewModelHotkeyTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let settingsStore = SettingsStore(defaults: defaults)
        let viewModel = StudioViewModel(
            settingsStore: settingsStore,
            historyStore: HotkeyTestHistoryStore(),
            initialSection: .settings
        )

        XCTAssertEqual(
            viewModel.activationHotkey?.signature,
            HotkeyBinding.defaultActivation.signature
        )
        XCTAssertEqual(
            viewModel.askHotkey?.signature,
            HotkeyBinding.defaultAsk.signature
        )
        XCTAssertFalse(viewModel.quickInputEnabled)

        settingsStore.activationHotkey = .rightCommandActivation
        settingsStore.askHotkey = .rightCommandAsk

        try await waitForHotkeys(
            in: viewModel,
            activation: .rightCommandActivation,
            ask: .rightCommandAsk
        )
    }

    func testQuickInputPersistsThroughViewModel() throws {
        let suiteName = "SettingsViewModelHotkeyTests.quickInput.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let settingsStore = SettingsStore(defaults: defaults)
        let viewModel = StudioViewModel(
            settingsStore: settingsStore,
            historyStore: HotkeyTestHistoryStore(),
            initialSection: .settings
        )

        viewModel.setQuickInputEnabled(true)

        XCTAssertTrue(viewModel.quickInputEnabled)
        XCTAssertTrue(settingsStore.quickInputEnabled)
    }

    private func waitForHotkeys(
        in viewModel: StudioViewModel,
        activation: HotkeyBinding,
        ask: HotkeyBinding
    ) async throws {
        for _ in 0 ..< 50 {
            if viewModel.activationHotkey?.signature == activation.signature,
               viewModel.askHotkey?.signature == ask.signature {
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Timed out waiting for hotkey settings to refresh")
    }
}

private final class HotkeyTestHistoryStore: HistoryStore {
    func save(record _: HistoryRecord) {}
    func list() -> [HistoryRecord] {
        []
    }

    func list(limit _: Int, offset _: Int, searchQuery _: String?) -> [HistoryRecord] {
        []
    }

    func record(id _: UUID) -> HistoryRecord? {
        nil
    }

    func delete(id _: UUID) {}
    func purge(olderThanDays _: Int) {}
    func clear() {}
    func exportMarkdown() throws -> URL {
        URL(fileURLWithPath: "/tmp/typeflux-history.md")
    }
}
