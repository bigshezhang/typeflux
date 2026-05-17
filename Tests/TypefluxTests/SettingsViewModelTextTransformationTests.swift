@testable import Typeflux
import XCTest

@MainActor
final class SettingsViewModelTextTransformationTests: XCTestCase {
    func testTextTransformationIsOnlyAvailableForTraditionalChineseInterface() throws {
        let viewModel = makeViewModel(appLanguage: .traditionalChinese)

        XCTAssertTrue(viewModel.isTextTransformationAvailable)

        for language in AppLanguage.allCases where language != .traditionalChinese {
            viewModel.setAppLanguage(language)
            XCTAssertFalse(viewModel.isTextTransformationAvailable, "\(language.rawValue) should hide text transformation settings")
        }
    }

    func testTextTransformationSettersAreIgnoredWhenUnavailable() throws {
        let suiteName = "SettingsViewModelTextTransformationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let settingsStore = SettingsStore(defaults: defaults)
        settingsStore.appLanguage = .english
        settingsStore.outputOpenCCEnabled = false
        settingsStore.outputOpenCCConfig = "s2twp"
        let viewModel = StudioViewModel(
            settingsStore: settingsStore,
            historyStore: InMemoryTextTransformationHistoryStore(),
            initialSection: .settings
        )

        viewModel.setTextTransformationEnabled(true)
        viewModel.setTextTransformationRule("t2s")

        XCTAssertFalse(settingsStore.outputOpenCCEnabled)
        XCTAssertEqual(settingsStore.outputOpenCCConfig, "s2twp")
        XCTAssertFalse(settingsStore.isOutputOpenCCEffectiveEnabled)
        XCTAssertNil(settingsStore.effectiveOutputOpenCCConfig)
    }

    private func makeViewModel(appLanguage: AppLanguage) -> StudioViewModel {
        let suiteName = "SettingsViewModelTextTransformationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let settingsStore = SettingsStore(defaults: defaults)
        settingsStore.appLanguage = appLanguage
        return StudioViewModel(
            settingsStore: settingsStore,
            historyStore: InMemoryTextTransformationHistoryStore(),
            initialSection: .settings
        )
    }
}

private final class InMemoryTextTransformationHistoryStore: HistoryStore {
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
