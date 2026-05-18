@testable import Typeflux
import XCTest

final class AliCloudFunASRRequestConfigurationTests: XCTestCase {
    func testParaformerRealtimeV2EnablesDisfluencyRemoval() {
        let parameters = AliCloudFunASRRequestConfiguration.parameters(for: "paraformer-realtime-v2")

        XCTAssertEqual(parameters["format"] as? String, "pcm")
        XCTAssertEqual(parameters["sample_rate"] as? Int, 16000)
        XCTAssertEqual(parameters["disfluency_removal_enabled"] as? Bool, true)
        XCTAssertEqual(parameters["semantic_punctuation_enabled"] as? Bool, false)
        XCTAssertEqual(parameters["max_sentence_silence"] as? Int, 800)
        XCTAssertEqual(parameters["punctuation_prediction_enabled"] as? Bool, true)
        XCTAssertEqual(parameters["heartbeat"] as? Bool, false)
        XCTAssertNil(parameters["language_hints"])
    }

    func testLegacyFunASRModelKeepsExistingParameters() {
        let parameters = AliCloudFunASRRequestConfiguration.parameters(for: AliCloudASRDefaults.legacyModel)

        XCTAssertEqual(parameters["format"] as? String, "pcm")
        XCTAssertEqual(parameters["sample_rate"] as? Int, 16000)
        XCTAssertEqual(parameters["semantic_punctuation_enabled"] as? Bool, true)
        XCTAssertEqual(parameters["max_sentence_silence"] as? Int, 800)
        XCTAssertEqual(parameters["heartbeat"] as? Bool, false)
        XCTAssertNil(parameters["disfluency_removal_enabled"])
        XCTAssertNil(parameters["punctuation_prediction_enabled"])
    }
}
