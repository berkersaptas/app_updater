# OTA lifecycle contract

Every platform adapter uses the same logical patch states:

- `none`: no patch is configured.
- `pending`: a patch was installed and will be attempted on the next process start.
- `pending_boot`: the runtime selected the patch for this process, but Dart has not reported a
  successful boot yet.
- `active`: the patch rendered successfully and is the current last-known-good patch.
- `failed`: the patch was rejected or failed to confirm boot.
- `disabled`: a patch was administratively disabled.

The conservative transition model is:

```text
pending -> pending_boot -> active
pending -> failed
pending_boot -> failed
active -> pending
active -> disabled
```

If a process starts and sees `pending_boot`, the previous patched process did not confirm success.
The adapter must select the packaged/base artifact and mark the patch `failed`.

Any signature, key, artifact hash, compatibility, path, or load preflight failure must select the
packaged/base artifact.
