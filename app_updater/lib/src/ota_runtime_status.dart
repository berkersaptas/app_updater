/// Snapshot of the local patch lifecycle state. Mirrors `OtaRuntimeStatus` on the native side.
class OtaRuntimeStatus {
  const OtaRuntimeStatus({
    required this.state,
    required this.patchNumber,
    required this.failureReason,
    required this.hasLastKnownGood,
    required this.quarantineCount,
    required this.storedPatchCount,
    required this.badPatchCount,
    required this.circuitOpen,
  });

  factory OtaRuntimeStatus.fromChannelMap(Map<Object?, Object?> map) => OtaRuntimeStatus(
    state: map['state'] as String?,
    patchNumber: map['patchNumber'] as int?,
    failureReason: map['failureReason'] as String?,
    hasLastKnownGood: map['hasLastKnownGood']! as bool,
    quarantineCount: map['quarantineCount']! as int,
    storedPatchCount: map['storedPatchCount']! as int,
    badPatchCount: map['badPatchCount']! as int,
    circuitOpen: map['circuitOpen'] as bool? ?? false,
  );

  final String? state;
  final int? patchNumber;
  final String? failureReason;
  final bool hasLastKnownGood;
  final int quarantineCount;
  final int storedPatchCount;
  final int badPatchCount;

  /// True while the cross-patch circuit breaker is open (too many consecutive patch failures) —
  /// `checkForUpdate` refuses to install a new patch until it resets. See `docs/rollback_model.md`.
  final bool circuitOpen;
}
