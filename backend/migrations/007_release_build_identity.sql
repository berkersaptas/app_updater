alter table release_artifacts
  add column ota_protocol_version int,
  add column base_sha256 text,
  add column build_fingerprint text;

alter table release_artifacts
  add constraint release_artifacts_protocol_check
    check (ota_protocol_version is null or ota_protocol_version = 2),
  add constraint release_artifacts_base_sha_check
    check (base_sha256 is null or base_sha256 ~ '^[0-9a-f]{64}$'),
  add constraint release_artifacts_fingerprint_check
    check (build_fingerprint is null or build_fingerprint ~ '^[0-9a-f]{64}$');
