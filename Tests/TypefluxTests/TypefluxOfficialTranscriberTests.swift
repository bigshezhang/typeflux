@testable import Typeflux
import XCTest

final class TypefluxOfficialTranscriberTests: XCTestCase {
    func testWebSocketRequestIncludesScenarioHeader() throws {
        let request = try TypefluxOfficialASRRequestFactory.makeWebSocketRequest(
            apiBaseURL: "https://cloud.typeflux.dev",
            token: "token-123",
            scenario: .voiceInput
        )

        XCTAssertEqual(request.url?.absoluteString, "wss://cloud.typeflux.dev/api/v1/asr/ws/default")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token-123")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: TypefluxCloudRequestHeaders.scenarioField),
            TypefluxCloudScenario.voiceInput.rawValue
        )
        XCTAssertNotNil(request.value(forHTTPHeaderField: "User-Agent"))
        XCTAssertNotNil(request.value(forHTTPHeaderField: TypefluxCloudRequestHeaders.clientIDField))
    }

    func testWebSocketRequestConvertsHTTPPrefixToWS() throws {
        let request = try TypefluxOfficialASRRequestFactory.makeWebSocketRequest(
            apiBaseURL: "http://asr-2.example.com/",
            token: "token-123",
            scenario: .voiceInput
        )

        XCTAssertEqual(request.url?.absoluteString, "ws://asr-2.example.com/api/v1/asr/ws/default")
    }

    func testWebSocketRequestIncludesPersonaIDHeaderWhenProvided() throws {
        let personaID = SettingsStore.defaultPersonaID

        let request = try TypefluxOfficialASRRequestFactory.makeWebSocketRequest(
            apiBaseURL: "https://cloud.typeflux.dev",
            token: "token-123",
            scenario: .voiceInput,
            personaID: personaID
        )

        XCTAssertEqual(
            request.value(forHTTPHeaderField: TypefluxCloudRequestHeaders.personaIDField),
            personaID.uuidString
        )
    }

    func testReceiveFailureIsUnexpectedBeforeCompletionWithoutFinalSegments() {
        XCTAssertTrue(
            TypefluxOfficialASRClosePolicy.shouldTreatReceiveFailureAsUnexpectedClose(
                completed: false,
                finalSegments: []
            )
        )
    }

    func testReceiveFailureIsAcceptedAfterFinalSegmentWithoutCompletedEvent() {
        XCTAssertFalse(
            TypefluxOfficialASRClosePolicy.shouldTreatReceiveFailureAsUnexpectedClose(
                completed: false,
                finalSegments: ["hello world"]
            )
        )
    }

    func testReceiveFailureIsAcceptedAfterExplicitCompletionEvent() {
        XCTAssertFalse(
            TypefluxOfficialASRClosePolicy.shouldTreatReceiveFailureAsUnexpectedClose(
                completed: true,
                finalSegments: []
            )
        )
    }
}
