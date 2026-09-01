/// What the app needs to tell the user about its own state.
///
/// The app already knew all of this and said none of it. `SyncResultSummary`
/// carried a `clockSkewWarning` and a `deviceRevoked` flag that no widget ever
/// read; `NativeSyncStatus.isBlocked` was written, documented, and referenced
/// nowhere. A handset could be revoked by an administrator, or have a clock
/// wrong enough that the server permanently rejected every call, and the only
/// visible symptom was that calls quietly stopped arriving.
///
/// Everything that can stop synchronisation now resolves to a [SyncAlert] here,
/// so a screen renders alerts rather than each screen inventing its own opinion
/// about what is wrong.
library;

enum SyncAlertSeverity {
  /// Synchronisation has stopped and will not resume on its own.
  critical,

  /// Still working, but degraded or at risk.
  warning,

  /// Worth knowing; nothing is broken.
  info,
}

/// What the user can do about an alert. The screen maps this onto navigation;
/// the model deliberately knows nothing about widgets.
enum SyncAlertAction {
  none,
  openPermissions,
  signIn,
  openDateSettings,
  openBatterySettings,
  retrySync,
}

class SyncAlert {
  const SyncAlert({
    required this.id,
    required this.severity,
    required this.title,
    required this.message,
    this.action = SyncAlertAction.none,
    this.actionLabel,
  });

  /// Stable identity, so a list of alerts can be keyed and de-duplicated.
  final String id;

  final SyncAlertSeverity severity;

  /// Short, plain, and about the user's situation — not the subsystem's.
  final String title;

  /// One or two sentences: what is happening, and what it means for them.
  final String message;

  final SyncAlertAction action;
  final String? actionLabel;

  bool get isCritical => severity == SyncAlertSeverity.critical;
}

/// The inputs, gathered in one place so the rules below read as rules.
class SyncHealthInputs {
  const SyncHealthInputs({
    required this.configProblemMessage,
    required this.sessionRevoked,
    required this.nativeStatus,
    required this.clockSkewMinutes,
    required this.canTrackCalls,
    required this.isOnline,
    required this.waitingCount,
    required this.failedCount,
    required this.lastErrorDetail,
    required this.ignoringBatteryOptimizations,
  });

  /// Non-null when the build itself cannot reach a server.
  final String? configProblemMessage;

  final bool sessionRevoked;

  /// `OK`, `PARTIAL`, `BLOCKED`, `SKIPPED_NO_AUTH`, `ALREADY_RUNNING`, or null.
  final String? nativeStatus;

  /// Non-null when the handset clock is outside the server's tolerance.
  final int? clockSkewMinutes;

  /// READ_CALL_LOG — without it nothing is captured at all.
  final bool canTrackCalls;

  final bool isOnline;
  final int waitingCount;
  final int failedCount;
  final String? lastErrorDetail;
  final bool ignoringBatteryOptimizations;
}

/// Turns the current state into the list of things worth saying, worst first.
///
/// Ordering matters more than it looks: a revoked device and an empty queue are
/// both true at once, and showing "all synced" above "this device was removed"
/// is how a broken handset reads as a healthy one.
List<SyncAlert> resolveSyncAlerts(SyncHealthInputs input) {
  final alerts = <SyncAlert>[];

  // ---------------------------------------------------------------- critical

  final configProblem = input.configProblemMessage;
  if (configProblem != null) {
    alerts.add(SyncAlert(
      id: 'config',
      severity: SyncAlertSeverity.critical,
      title: 'This app cannot reach a server',
      message: configProblem,
    ));
    // Nothing below this can be diagnosed until the build is fixed, and listing
    // six consequences of one cause is noise.
    return alerts;
  }

  if (input.sessionRevoked || input.nativeStatus == 'SKIPPED_NO_AUTH') {
    alerts.add(const SyncAlert(
      id: 'signed-out',
      severity: SyncAlertSeverity.critical,
      title: 'Not signed in',
      message: 'Calls are still being recorded on this phone, but nothing can '
          'be sent until you register this device again.',
      action: SyncAlertAction.signIn,
      actionLabel: 'Register device',
    ));
    return alerts;
  }

  if (input.nativeStatus == 'BLOCKED') {
    alerts.add(SyncAlert(
      id: 'blocked',
      severity: SyncAlertSeverity.critical,
      title: 'The server has stopped accepting this phone',
      message: input.lastErrorDetail == null
          ? 'Your calls are being saved but cannot be uploaded. Contact your '
              'administrator.'
          : 'Your calls are being saved but cannot be uploaded. Contact your '
              'administrator and quote: ${input.lastErrorDetail}',
    ));
  }

  if (!input.canTrackCalls) {
    alerts.add(const SyncAlert(
      id: 'no-call-log',
      severity: SyncAlertSeverity.critical,
      title: 'Call access was turned off',
      message: 'Without permission to read the call log, no new calls are '
          'being recorded at all.',
      action: SyncAlertAction.openPermissions,
      actionLabel: 'Fix permissions',
    ));
  }

  // The server rejects out-of-window calls permanently, so this silently
  // destroys data rather than delaying it — which is why it outranks a warning.
  final skew = input.clockSkewMinutes;
  if (skew != null) {
    alerts.add(SyncAlert(
      id: 'clock',
      severity: SyncAlertSeverity.critical,
      title: "This phone's clock is wrong",
      message: 'It is about $skew minutes off. Calls are being rejected and '
          'cannot be recovered afterwards. Turn on automatic date and time.',
      action: SyncAlertAction.openDateSettings,
      actionLabel: 'Open date & time',
    ));
  }

  // ---------------------------------------------------------------- warning

  if (!input.isOnline && input.waitingCount > 0) {
    alerts.add(SyncAlert(
      id: 'offline-backlog',
      severity: SyncAlertSeverity.warning,
      title: 'Waiting for a connection',
      message: '${input.waitingCount} '
          '${input.waitingCount == 1 ? 'call is' : 'calls are'} saved on this '
          'phone and will be sent automatically once you are back online.',
    ));
  }

  if (input.failedCount > 0) {
    alerts.add(SyncAlert(
      id: 'failed',
      severity: SyncAlertSeverity.warning,
      title: '${input.failedCount} '
          '${input.failedCount == 1 ? 'call' : 'calls'} could not be sent',
      message: 'These will be retried automatically. If the number does not go '
          'down over a day or so, tell your administrator.',
      action: SyncAlertAction.retrySync,
      actionLabel: 'Try again now',
    ));
  }

  if (!input.ignoringBatteryOptimizations) {
    alerts.add(const SyncAlert(
      id: 'battery',
      severity: SyncAlertSeverity.warning,
      title: 'Battery saver may delay syncing',
      message: 'Android can hold back background uploads for hours while this '
          'phone is idle. Allowing background activity keeps calls current.',
      action: SyncAlertAction.openBatterySettings,
      actionLabel: 'Allow background activity',
    ));
  }

  return alerts;
}
