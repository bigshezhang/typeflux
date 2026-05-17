@testable import Typeflux
import XCTest

final class OpenCCOutputPostProcessorTests: XCTestCase {
    func testDisabledReturnsOriginalText() async {
        let store = makeStore()
        store.outputOpenCCEnabled = false
        let processor = OpenCCOutputPostProcessor(settingsStore: store)

        let result = await processor.process("简体中文 ")
        XCTAssertEqual(result, "简体中文 ")
    }

    func testEmptyStringReturnsEmpty() async {
        let store = makeStore()
        store.outputOpenCCEnabled = true
        let processor = OpenCCOutputPostProcessor(settingsStore: store)

        let result = await processor.process("")
        XCTAssertEqual(result, "")
    }

    func testS2TWPConversion() async {
        let store = makeStore()
        store.outputOpenCCEnabled = true
        store.outputOpenCCConfig = "s2twp"
        let processor = OpenCCOutputPostProcessor(settingsStore: store)

        // 簡體 -> 台灣繁體（包含詞彙轉換）
        let input = "内存和硬盘都很便宜，我的电脑运行速度很快。"
        let result = await processor.process(input)

        XCTAssertTrue(result.contains("記憶體"), "Expected '記憶體' (TW phrase) for '内存': \(result)")
        XCTAssertTrue(result.contains("硬碟"), "Expected '硬碟' (TW phrase) for '硬盘': \(result)")
        XCTAssertTrue(result.contains("電腦"), "Expected '電腦' for '电脑': \(result)")
    }

    func testS2TWConversion() async {
        let store = makeStore()
        store.outputOpenCCEnabled = true
        store.outputOpenCCConfig = "s2tw"
        let processor = OpenCCOutputPostProcessor(settingsStore: store)

        let input = "内存和硬盘都很便宜。"
        let result = await processor.process(input)

        // s2tw 只換字，不換詞
        XCTAssertTrue(result.contains("內存"), "Expected '內存' (standard traditional) for '内存': \(result)")
        XCTAssertTrue(result.contains("硬盤"), "Expected '硬盤' (standard traditional) for '硬盘': \(result)")
    }

    func testS2HKConversion() async {
        let store = makeStore()
        store.outputOpenCCEnabled = true
        store.outputOpenCCConfig = "s2hk"
        let processor = OpenCCOutputPostProcessor(settingsStore: store)

        let input = "通过简体中文转换到香港繁体。"
        let result = await processor.process(input)

        XCTAssertTrue(result.contains("通過"), "Expected '通過' for '通过': \(result)")
        XCTAssertTrue(result.contains("簡體"), "Expected '簡體' for '简体': \(result)")
        XCTAssertTrue(result.contains("香港"), "Expected '香港': \(result)")
    }

    func testT2SConversion() async {
        let store = makeStore()
        store.outputOpenCCEnabled = true
        store.outputOpenCCConfig = "t2s"
        let processor = OpenCCOutputPostProcessor(settingsStore: store)

        // 測試不同的繁體來源與複雜字集
        let cases = [
            (input: "繁體中文測試", expected: "繁体中文测试"),
            (input: "以後、皇后、乾淨、乾隆", expected: "以后、皇后、干净、乾隆"),
            (input: "記憶體和硬碟", expected: "记忆体和硬碟"),
            (input: "香港繁體字：通過、裏面、這裡", expected: "香港繁体字：通过、里面、这里"),
            (input: "台灣繁體字：透過、裡面、這裏", expected: "台湾繁体字：透过、里面、这里"),
            (input: "髮型、發展", expected: "发型、发展"),
            (input: "聯繫、關係", expected: "联系、关系")
        ]

        for c in cases {
            let result = await processor.process(c.input)
            XCTAssertEqual(result, c.expected, "T2S failed for input: \(c.input). Got: \(result)")
        }
    }

    func testT2SWithAllVariants() async {
        let store = makeStore()
        store.outputOpenCCEnabled = true
        store.outputOpenCCConfig = "t2s"
        let processor = OpenCCOutputPostProcessor(settingsStore: store)

        // 涵蓋多種繁體變體
        let input = "處、裏、裡、彙、彙、衛、衛"
        let result = await processor.process(input)
        
        XCTAssertFalse(result.contains("處"), "Should convert '處'")
        XCTAssertFalse(result.contains("裏"), "Should convert '裏'")
        XCTAssertFalse(result.contains("裡"), "Should convert '裡'")
        XCTAssertTrue(result.contains("处"), "Should contain '处'")
        XCTAssertTrue(result.contains("里"), "Should contain '里'")
    }

    func testAllSupportedConfigurations() async {
        let store = makeStore()
        store.outputOpenCCEnabled = true
        let processor = OpenCCOutputPostProcessor(settingsStore: store)

        // 1. s2twp: 簡體 -> 台灣繁體（包含詞彙轉換）
        store.outputOpenCCConfig = "s2twp"
        let s2twpResult = await processor.process("内存和硬盘")
        XCTAssertEqual(s2twpResult, "記憶體和硬碟")

        // 2. s2tw: 簡體 -> 台灣繁體（不包含詞彙轉換）
        store.outputOpenCCConfig = "s2tw"
        let s2twResult = await processor.process("内存和硬盘")
        XCTAssertEqual(s2twResult, "內存和硬盤")

        // 3. s2hk: 簡體 -> 香港繁體
        store.outputOpenCCConfig = "s2hk"
        let s2hkResult = await processor.process("通过简体中文转换到香港繁体")
        XCTAssertTrue(s2hkResult.contains("通過"))
        XCTAssertTrue(s2hkResult.contains("香港"))

        // 4. t2s: 繁體 -> 簡體
        store.outputOpenCCConfig = "t2s"
        let t2sResult = await processor.process("這是一個繁體中文測試")
        XCTAssertEqual(t2sResult, "这是一个繁体中文测试")
    }

    func testT2SWithVariousSources() async {
        let store = makeStore()
        store.outputOpenCCEnabled = true
        store.outputOpenCCConfig = "t2s"
        let processor = OpenCCOutputPostProcessor(settingsStore: store)

        // 測試台灣繁體字轉簡體
        let twResult = await processor.process("裡面的記憶體")
        XCTAssertEqual(twResult, "里面的记忆体")
        
        // 測試香港繁體字轉簡體
        let hkResult = await processor.process("裏面的記憶體")
        XCTAssertEqual(hkResult, "里面的记忆体")
        
        // 測試混合繁體字
        let mixedResult = await processor.process("髮型、發言、聯繫、關係")
        XCTAssertEqual(mixedResult, "发型、发言、联系、关系")
    }

    func testEnabledReturnsOriginalTextWhenInterfaceLanguageIsNotTraditionalChinese() async {
        let store = makeStore(appLanguage: .english)
        store.outputOpenCCEnabled = true
        store.outputOpenCCConfig = "s2twp"
        let processor = OpenCCOutputPostProcessor(settingsStore: store)

        let input = "内存和硬盘"
        let result = await processor.process(input)

        XCTAssertEqual(result, input)
        XCTAssertFalse(store.isOutputOpenCCEffectiveEnabled)
        XCTAssertNil(store.effectiveOutputOpenCCConfig)
    }

    private func makeStore(appLanguage: AppLanguage = .traditionalChinese) -> SettingsStore {
        let suiteName = "OpenCCOutputPostProcessorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let store = SettingsStore(defaults: defaults)
        store.appLanguage = appLanguage
        return store
    }
}

// Made with Bob
