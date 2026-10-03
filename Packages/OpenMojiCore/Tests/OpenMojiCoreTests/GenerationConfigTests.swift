import Foundation
import Testing
@testable import OpenMojiCore

@Suite struct GenerationConfigTests {
    private let defaultModel = "gpt-image-2.5-flare"
    private let defaultQuality = "medium"

    // MARK: Default behavior

    @Test func usesDefaultModelWhenKeyIsMissing() {
        let config = GenerationConfig(infoDictionary: [:]
        )
        #expect(config.model == defaultModel)
    }

    @Test func usesDefaultQualityWhenKeyIsMissing() {
        let config = GenerationConfig(infoDictionary: [:]
        )
        #expect(config.quality == defaultQuality)
    }

    @Test func usesDefaultsWhenInfoDictionaryIsNil() {
        let config = GenerationConfig(infoDictionary: nil)
        #expect(config.model == defaultModel)
        #expect(config.quality == defaultQuality)
    }

    // MARK: Override behavior

    @Test func usesModelValueWhenKeyIsPresent() {
        let customModel = "gpt-image-2"
        let config = GenerationConfig(infoDictionary: ["OpenMojiImageModel": customModel])
        #expect(config.model == customModel)
    }

    @Test func usesQualityValueWhenKeyIsPresent() {
        let customQuality = "hd"
        let config = GenerationConfig(infoDictionary: ["OpenMojiImageQuality": customQuality])
        #expect(config.quality == customQuality)
    }

    @Test func usesAllProvidedValues() {
        let customModel = "custom-model"
        let customQuality = "ultra"
        let config = GenerationConfig(infoDictionary: [
            "OpenMojiImageModel": customModel,
            "OpenMojiImageQuality": customQuality,
        ])
        #expect(config.model == customModel)
        #expect(config.quality == customQuality)
    }

    // MARK: Empty string handling

    @Test func fallsBackWhenModelIsEmptyString() {
        let config = GenerationConfig(infoDictionary: ["OpenMojiImageModel": ""])
        #expect(config.model == defaultModel)
    }

    @Test func fallsBackWhenQualityIsEmptyString() {
        let config = GenerationConfig(infoDictionary: ["OpenMojiImageQuality": ""])
        #expect(config.quality == defaultQuality)
    }

    @Test func fallsBackWhenModelIsOnlyWhitespace() {
        let config = GenerationConfig(infoDictionary: ["OpenMojiImageModel": "   "])
        #expect(config.model == defaultModel)
    }

    @Test func fallsBackWhenQualityIsOnlyWhitespace() {
        let config = GenerationConfig(infoDictionary: ["OpenMojiImageQuality": "  \t "])
        #expect(config.quality == defaultQuality)
    }

    // MARK: Type coercion

    @Test func fallsBackWhenModelIsNotAString() {
        let config = GenerationConfig(infoDictionary: ["OpenMojiImageModel": 123])
        #expect(config.model == defaultModel)
    }

    @Test func fallsBackWhenQualityIsNotAString() {
        let config = GenerationConfig(infoDictionary: ["OpenMojiImageQuality": true])
        #expect(config.quality == defaultQuality)
    }

    @Test func fallsBackWhenModelIsNullValue() {
        let config = GenerationConfig(infoDictionary: ["OpenMojiImageModel": NSNull()])
        #expect(config.model == defaultModel)
    }

    // MARK: Default parameter behavior

    @Test func buildsWithDefaultDictionaryParameter() {
        // This test verifies the initializer can be called with no argument
        // when Bundle.main.infoDictionary is available. We test with explicit
        // nil to verify the default parameter behavior.
        let config = GenerationConfig()
        // The config should use Bundle values or fall back to defaults
        #expect(!config.model.isEmpty)
        #expect(!config.quality.isEmpty)
    }

    // MARK: Extra keys ignored

    @Test func ignoresExtraKeysInDictionary() {
        let config = GenerationConfig(infoDictionary: [
            "OpenMojiImageModel": "test-model",
            "OpenMojiImageQuality": "test-quality",
            "SomeOtherKey": "value",
            "AnotherUnrelatedKey": 42,
        ])
        #expect(config.model == "test-model")
        #expect(config.quality == "test-quality")
    }
}
