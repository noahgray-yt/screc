import Foundation

/// Voice processing of the microphone (Phase 5 item 6): Standard, or noise reduction with Apple's Voice
/// Isolation, on this Mac.
public struct VoiceSettings: Codable, Equatable, Sendable {
    public var noiseReduction = false
    /// How much of the cleaned voice is used, 0…1 (1 = only the cleaned voice).
    public var amount = 1.0

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        noiseReduction = try c.decodeIfPresent(Bool.self, forKey: .noiseReduction) ?? false
        amount = try c.decodeIfPresent(Double.self, forKey: .amount) ?? 1
    }
}
