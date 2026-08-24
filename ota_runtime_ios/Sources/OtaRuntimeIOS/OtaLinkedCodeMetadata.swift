import Foundation

public struct OtaLinkedCodeMetadata: Codable, Equatable {
    public let linkedFunctionCount: Int
    public let interpretedFunctionCount: Int
    public let minimumLinkPercentage: Double

    public var linkPercentage: Double {
        let total = linkedFunctionCount + interpretedFunctionCount
        guard total > 0 else { return 0 }
        return Double(linkedFunctionCount) / Double(total) * 100
    }

    public var satisfiesMinimumLinkPercentage: Bool {
        linkPercentage >= minimumLinkPercentage
    }

    public init(
        linkedFunctionCount: Int,
        interpretedFunctionCount: Int,
        minimumLinkPercentage: Double
    ) {
        self.linkedFunctionCount = linkedFunctionCount
        self.interpretedFunctionCount = interpretedFunctionCount
        self.minimumLinkPercentage = minimumLinkPercentage
    }
}
