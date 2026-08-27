# iOS OTA runtime skeleton

Status: contract skeleton only.

This module exists to keep the project aligned with Shorebird's iOS architecture direction. It does
not implement runtime patch execution yet.

The iOS adapter must not copy Android's `libapp.so` replacement model. The intended direction is a
Shorebird-style interpreted Dart patch payload with linker metadata that allows unchanged code to
continue running from the signed store binary.

Shared pieces:

- `ota_core/manifest.schema.json`
- `ota_core/ios_interpreted_patch.schema.json`
- `ota_core/signing_payload_v2.txt`
- `ota_core/lifecycle.md`
- keyring and revocation semantics
- bad-patch quarantine semantics

Not implemented:

- interpreter payload format
- linker metadata format
- modified engine/runtime hooks
- patch execution
- performance threshold enforcement

Next step: connect this schema to generated/validated fixtures before adding Swift/Objective-C
runtime code.

## Contract skeleton

The current Swift sources define only contract-level models:

- `OtaPatchArtifact`
- `OtaPatchArtifactKind.interpretedDartPatch`
- `OtaLinkedCodeMetadata`
- `OtaRuntimeIOS.validateContract`
- `ota_core/ios_interpreted_patch.schema.json`

`launchPatch` intentionally returns `unavailable`; runtime execution must wait for the
interpreter/linker artifact format.
