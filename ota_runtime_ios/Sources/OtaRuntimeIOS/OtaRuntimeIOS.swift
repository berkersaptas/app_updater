import Foundation

public enum OtaRuntimeIOSStatus: Equatable {
    case unavailable
    case ready
    case rejected(reason: String)
}

public final class OtaRuntimeIOS {
    public init() {}

    public func validateContract(_ artifact: OtaPatchArtifact) -> OtaRuntimeIOSStatus {
        guard artifact.kind == .interpretedDartPatch else {
            return .rejected(reason: "Unsupported iOS artifact kind")
        }
        guard artifact.linkedCodeMetadata.satisfiesMinimumLinkPercentage else {
            return .rejected(reason: "Linked-code percentage is below the configured minimum")
        }
        return .ready
    }

    public func launchPatch(_ artifact: OtaPatchArtifact) -> OtaRuntimeIOSStatus {
        let contractStatus = validateContract(artifact)
        guard contractStatus == .ready else { return contractStatus }
        return .unavailable
    }
}
