import Foundation

public enum OtaPatchArtifactKind: String, Codable, Equatable {
    case interpretedDartPatch = "interpreted_dart_patch"
}

public struct OtaPatchArtifact: Codable, Equatable {
    public let patchNumber: Int
    public let kind: OtaPatchArtifactKind
    public let manifestURL: URL
    public let payloadURL: URL
    public let linkedCodeMetadata: OtaLinkedCodeMetadata

    public init(
        patchNumber: Int,
        kind: OtaPatchArtifactKind,
        manifestURL: URL,
        payloadURL: URL,
        linkedCodeMetadata: OtaLinkedCodeMetadata
    ) {
        self.patchNumber = patchNumber
        self.kind = kind
        self.manifestURL = manifestURL
        self.payloadURL = payloadURL
        self.linkedCodeMetadata = linkedCodeMetadata
    }
}
