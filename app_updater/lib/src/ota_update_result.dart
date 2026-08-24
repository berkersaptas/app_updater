/// Result of a single [AppUpdater.checkForUpdate] call.
sealed class OtaUpdateResult {
  const OtaUpdateResult();

  factory OtaUpdateResult.fromChannelMap(Map<Object?, Object?> map) {
    switch (map['status']) {
      case 'installed':
        return OtaUpdateInstalled(map['patchNumber']! as int);
      case 'failed':
        return OtaUpdateFailed(map['reason']! as String);
      case 'noUpdateAvailable':
      default:
        return const OtaNoUpdateAvailable();
    }
  }
}

/// No patch newer than the currently installed one is available.
final class OtaNoUpdateAvailable extends OtaUpdateResult {
  const OtaNoUpdateAvailable();

  @override
  String toString() => 'OtaNoUpdateAvailable()';
}

/// A patch was found, downloaded, verified, and staged as `pending` for the next launch. It does
/// not affect the current boot.
final class OtaUpdateInstalled extends OtaUpdateResult {
  const OtaUpdateInstalled(this.patchNumber);

  final int patchNumber;

  @override
  String toString() => 'OtaUpdateInstalled(patchNumber: $patchNumber)';
}

/// The check, download, or install failed. The app should keep running normally — this must never
/// be treated as a fatal error (see docs/production_installer_contract.md's "must tolerate
/// backend/CDN unavailability" requirement).
final class OtaUpdateFailed extends OtaUpdateResult {
  const OtaUpdateFailed(this.reason);

  final String reason;

  @override
  String toString() => 'OtaUpdateFailed(reason: $reason)';
}
