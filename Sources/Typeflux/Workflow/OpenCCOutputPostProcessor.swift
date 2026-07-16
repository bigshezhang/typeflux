import Foundation
import OpenCCSwift
import os

/// Post-processor that converts Chinese text using OpenCC Swift library.
final class OpenCCOutputPostProcessor: OutputPostProcessing, @unchecked Sendable {
    private static let logger = Logger(subsystem: "ai.gulu.app.typeflux", category: "OpenCCOutputPostProcessor")
    private let settingsStore: SettingsStore

    init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
    }

    func process(_ text: String) async -> String {
        // Return original text if conversion is disabled or unavailable for the current UI language.
        guard let config = settingsStore.effectiveOutputOpenCCConfig else {
            return text
        }

        // Return original text if input is empty
        guard !text.isEmpty else {
            return text
        }

        // Only process if it contains Chinese characters
        guard containsChinese(text) else {
            Self.logger.debug("OpenCC skipping: no Chinese characters detected")
            return text
        }

        Self.logger.debug("OpenCC processing start: config=\(config), textLength=\(text.count)")

        do {
            let converted = try convertWithOpenCC(text: text, config: config)
            if converted == text {
                Self.logger.debug("OpenCC conversion result is identical to input: \(config)")
            } else {
                Self.logger.debug("OpenCC conversion successful: \(config)")
            }
            return converted
        } catch {
            Self.logger
                .error(
                    "OpenCC conversion failed: \(config), error=\(error.localizedDescription, privacy: .public). Returning original text."
                )
            return text
        }
    }

    private func containsChinese(_ text: String) -> Bool {
        text.range(of: "\\p{Han}", options: .regularExpression) != nil
    }

    private func convertWithOpenCC(text: String, config: String) throws -> String {
        let converter: Converter

        switch config {
        case "s2twp":
            converter = try Presets.Cn2t.converter(from: "cn", to: "twp")
        case "s2tw":
            converter = try Presets.Cn2t.converter(from: "cn", to: "tw")
        case "s2hk":
            converter = try Presets.Cn2t.converter(from: "cn", to: "hk")
        case "t2s":
            // Use Presets.Full for t2s to ensure broader coverage of traditional variants
            converter = try Presets.Full.converter(from: "tw", to: "cn")
        default:
            throw OpenCCError.invalidConfig(config)
        }

        return converter.convert(text)
    }

    enum OpenCCError: LocalizedError {
        case invalidConfig(String)

        var errorDescription: String? {
            switch self {
            case let .invalidConfig(config):
                "Invalid OpenCC configuration: \(config)"
            }
        }
    }
}
