# App Updater acceptance sample

This application exercises release, patch staging, cold-start activation, boot confirmation, and
rollback behavior against the local backend. It is used by the repository's device-acceptance
scripts; it is not a template for production branding or signing configuration.

For the developer-facing integration flow, start with the [root guide](../README.md). To build this
sample against the local service:

```bash
docker compose up -d
cd sample_app
flutter pub get
flutter run
```
