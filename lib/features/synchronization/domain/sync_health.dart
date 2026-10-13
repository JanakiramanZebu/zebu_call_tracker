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
  openBackgroundSettings,
  openOutbox,
  retrySync,
  enableNotifications,

  /// Dismisses a one-time notice.
  acknowledgeForceStop,
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

  // Value equality, so a rebuilt list saying the same thing compares equal and
  // the banner does not repaint on every counter tick.
  @override
  bool operator ==(Object other) =>
      other is SyncAlert &&
      other.id == id &&
      other.severity == severity &&
      other.title == title &&
      other.message == message &&
      other.action == action &&
      other.actionLabel == actionLabel;

  @override
  int get hashCode =>
      Object.hash(id, severity, title, message, action, actionLabel);
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
    this.notificationsAllowed = true,
    this.serverDeviceStatus,
    this.canReadRecordings = true,
    this.captureStaleSince,
    this.forceStoppedAt,
  });

  /// Non-null when the build itself cannot reach a server.
  final String? configProblemMessage;

  final bool sessionRevoked;

  /// `OK`, `PARTIAL`, `BLOCKED`, `SKIPPED_NO_AUTH`, `ALREADY_RUNNING`, or null.
  final String? nativeStatus;

  /// Non-null when the handset clock is outside the server's tolerance.
  final int? clockSkewMinutes;

  /// READ_CALL_LOG and READ_PHONE_STATE — without both nothing is captured.
  final bool canTrackCalls;

  final bool isOnline;
  final int waitingCount;
  final int failedCount;
  final String? lastErrorDetail;
  final bool ignoringBatteryOptimizations;

  /// POST_NOTIFICATIONS. Not asked for during setup; it is offered here, at
  /// the moment it would have helped. Defaults to true so unknown never nags.
  final bool notificationsAllowed;

  /// `device_status` from the last `GET /sync/status`, or null before the
  /// first answer. Anything but ACTIVE means the server refuses this phone.
  final String? serverDeviceStatus;

  /// READ_MEDIA_AUDIO (or storage below 13). Without it calls still go, but
  /// with no recordings — and nothing else says so.
  final bool canReadRecordings;

  /// When background capture last ran, if that was so long ago that the
  /// phone is evidently stopping it. Null when capture is keeping up.
  final DateTime? captureStaleSince;

  /// When someone force-stopped the app, if they have not been told yet.
  final DateTime? forceStoppedAt;
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
      title: "This app can't send calls",
      message: configProblem,
    ));
    // Nothing below this can be diagnosed until the build is fixed, and listing
    // six consequences of one cause is noise.
    return alerts;
  }

  // BLOCKED_AUTH belongs here rather than with the generic BLOCKED alert
  // below: the queue is intact and the only thing missing is a credential the
  // user can replace themselves.
  if (input.sessionRevoked ||
      input.nativeStatus == 'SKIPPED_NO_AUTH' ||
      input.nativeStatus == 'BLOCKED_AUTH') {
    alerts.add(const SyncAlert(
      id: 'signed-out',
      severity: SyncAlertSeverity.critical,
      title: 'Not signed in',
      message: 'Calls are still being saved on this phone, but nothing can '
          'be sent until you sign in again.',
      action: SyncAlertAction.signIn,
      actionLabel: 'Sign in again',
    ));
    return alerts;
  }

  // The server's own word on this device, not just an upload that happened
  // to be refused: a revoked phone with nothing queued never uploads, and so
  // used to look healthy for as long as nobody made a call.
  final serverStatus = input.serverDeviceStatus;
  final serverRefuses = serverStatus != null && serverStatus != 'ACTIVE';
  if (input.nativeStatus == 'BLOCKED' || serverRefuses) {
    final cause = serverRefuses
        ? 'DEVICE_$serverStatus'
        : (input.lastErrorDetail ?? '');
    final reference = _referenceCode(serverRefuses ? cause : input.lastErrorDetail);
    final (title, why) = switch (cause) {
      final c when c.contains('REVOKED') => (
          'This phone was removed – contact your admin',
          'Your admin has removed this phone from call tracking.',
        ),
      final c when c.contains('ACCOUNT_INACTIVE') => (
          'Your account is turned off – contact your admin',
          'Your account has been deactivated.',
        ),
      final c when c.contains('OWNED_BY_ANOTHER_USER') => (
          'Phone linked to someone else – contact your admin',
          'This phone is registered to another employee.',
        ),
      _ => (
          'Access removed – contact your admin',
          'The server is not accepting calls from this phone.',
        ),
    };
    alerts.add(SyncAlert(
      id: 'blocked',
      severity: SyncAlertSeverity.critical,
      title: title,
      message: reference == null
          ? '$why Your calls are kept on this phone and will be sent once '
              'access is restored.'
          : '$why Your calls are kept on this phone and will be sent once '
              'access is restored. Reference code: $reference',
    ));
  }

  if (!input.canTrackCalls) {
    alerts.add(const SyncAlert(
      id: 'no-call-log',
      severity: SyncAlertSeverity.critical,
      title: 'Call access was turned off',
      message: 'Without phone and call log access, no new calls are being '
          'recorded at all.',
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
      // The offline reminder is the only thing notifications are for, so this
      // is when to ask: the user can see why it would help.
      action: input.notificationsAllowed
          ? SyncAlertAction.none
          : SyncAlertAction.enableNotifications,
      actionLabel: input.notificationsAllowed ? null : 'Turn on reminders',
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
      action: SyncAlertAction.openOutbox,
      actionLabel: 'See why',
    ));
  }

  // A force-stopped app hears nothing from Android, a push included, until it
  // is opened again. Nothing can wake it, so the user has to know not to.
  final stoppedAt = input.forceStoppedAt;
  if (stoppedAt != null) {
    alerts.add(SyncAlert(
      id: 'force-stopped',
      severity: SyncAlertSeverity.warning,
      title: 'Call tracking was stopped',
      message: 'This app was force-stopped ${_since(stoppedAt)}, so it '
          'could not track or send calls until you opened it. Those calls '
          "are being collected now. Please don't force-stop this app.",
      action: SyncAlertAction.acknowledgeForceStop,
      actionLabel: 'OK',
    ));
  }

  // Capture runs at least hourly — the safety net, the tracking service, and
  // every call. Half a day without a run means the phone is stopping the app,
  // which no other signal shows: calls simply stop arriving.
  final staleSince = input.captureStaleSince;
  if (input.canTrackCalls && staleSince != null) {
    alerts.add(SyncAlert(
      id: 'capture-paused',
      severity: SyncAlertSeverity.warning,
      title: 'Call tracking was paused by this phone',
      message: 'No calls were checked since ${_since(staleSince)}. The phone '
          'may be closing this app in the background. Allow it to run in the '
          'background so calls go out on their own.',
      action: input.ignoringBatteryOptimizations
          ? SyncAlertAction.openBackgroundSettings
          : SyncAlertAction.openBatterySettings,
      actionLabel: 'Allow background activity',
    ));
  }

  if (input.canTrackCalls && !input.canReadRecordings) {
    alerts.add(const SyncAlert(
      id: 'no-recordings',
      severity: SyncAlertSeverity.warning,
      title: 'Call recordings are not being sent',
      message: 'Calls are still sent, but without their recordings. Allow '
          'access to audio files so recordings go with them.',
      action: SyncAlertAction.openPermissions,
      actionLabel: 'Allow access',
    ));
  }

  if (!input.ignoringBatteryOptimizations) {
    alerts.add(const SyncAlert(
      id: 'battery',
      severity: SyncAlertSeverity.warning,
      title: 'Battery saver may delay sending',
      message: 'Android can hold calls back for hours while this phone is '
          'idle. Allow background activity so they go out on time.',
      action: SyncAlertAction.openBatterySettings,
      actionLabel: 'Allow background activity',
    ));
  }

  return alerts;
}

/// "14:05 today", "yesterday 18:30", "3 Oct 09:12" — local time.
String _since(DateTime at) {
  final local = at.toLocal();
  final now = DateTime.now();
  String two(int n) => n.toString().padLeft(2, '0');
  final clock = '${two(local.hour)}:${two(local.minute)}';
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(local.year, local.month, local.day);
  final diff = today.difference(day).inDays;
  if (diff == 0) return '$clock today';
  if (diff == 1) return 'yesterday $clock';
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  return '${local.day} ${months[local.month - 1]} $clock';
}

/// The native error, cut down to something a person can read out over the
/// phone. The full text stays on Technical details for support.
String? _referenceCode(String? detail) {
  final text = detail?.trim().split(RegExp(r'\s+')).join(' ');
  if (text == null || text.isEmpty) return null;
  return text.length <= 40 ? text : '${text.substring(0, 40)}…';
}
