import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../../core/platform/native_call_bridge.dart';
import '../../call_tracking/data/call_feed.dart';

/// How an ask is granted.
///
/// [backgroundActivity] is a settings screen the user has to complete themselves.
/// [overlayWindow] also goes to a settings screen (ACTION_MANAGE_OVERLAY_PERMISSION)
/// rather than an Android runtime-permission dialog.
enum AskKind { runtime, backgroundActivity, overlayWindow }

/// One thing the app asks for, with the reason the user is being asked.
///
/// The rationale is part of the data, not decoration: the brief requires the
/// app to explain WHY before requesting, and keeping the copy beside the
/// permission makes it impossible to add one without writing the other.
///
/// Defined once here so the first-run walkthrough and the Settings screen can
/// never disagree about what is asked for or how it is justified.
class PermissionAsk {
  const PermissionAsk({
    required this.id,
    required this.title,
    required this.why,
    required this.icon,
    required this.granted,
    this.permission,
    this.kind = AskKind.runtime,
    this.essential = false,
    this.costIfSkipped,
  });

  /// Stable identity, used to track per-ask busy/blocked state without relying
  /// on [permission] being non-null.
  final String id;

  final String title;
  final String why;
  final IconData icon;
  final bool granted;

  /// Null for [AskKind.backgroundActivity].
  final Permission? permission;

  final AskKind kind;

  /// Essential permissions block tracking entirely when denied; the rest only
  /// reduce detail.
  ///
  /// Only mark an ask essential when the app genuinely cannot do its job
  /// without it. Everything essential gates the onboarding button, and two of
  /// these asks are settings-page grants the app cannot force — marking those
  /// essential (as an earlier revision marked all six) means a user who
  /// declines one can never leave the walkthrough.
  final bool essential;

  /// What the user loses by skipping this. Shown on optional asks so "Optional"
  /// is an informed choice rather than a shrug.
  final String? costIfSkipped;
}

/// The full ask list, resolved against the current grants.
///
/// Ordered by how much the app loses without each one, so the walkthrough asks
/// for the indispensable permission first and the optional ones after — a user
/// who quits half way through still has a working app.
///
/// [background] may be null while its first read is in flight; the background
/// card is simply reported as not-yet-granted until it arrives.
List<PermissionAsk> permissionAsks(
  PermissionSnapshot perms, {
  BackgroundStatus? background,
}) => [
  PermissionAsk(
    id: 'phone',
    permission: Permission.phone,
    title: 'Phone & call log',
    why:
        'Detects when a call starts and ends, and reads its final duration and '
        'status. Required for core call tracking.',
    icon: Icons.phone_outlined,
    granted: perms.readCallLog && perms.readPhoneState,
    essential: true,
  ),
  PermissionAsk(
    id: 'background',
    kind: AskKind.backgroundActivity,
    title: 'Background activity',
    why:
        'Lets syncing and tracking run reliably when the app is closed. '
        'Required to prevent the OS from pausing upload jobs.',
    icon: Icons.battery_saver_rounded,
    granted: background?.ignoringBatteryOptimizations ?? false,
    // Cannot be forced: it is a system settings page, and the OS may refuse.
    // Strongly recommended, never blocking — the app degrades to whatever
    // scheduling the OS allows.
    costIfSkipped:
        'Sync may be delayed by hours when the phone is idle.',
  ),
  PermissionAsk(
    id: 'contacts',
    permission: Permission.contacts,
    title: 'Contacts',
    why:
        'Resolves client names against phone numbers in call logs and reports. '
        'Required for accurate caller identification.',
    icon: Icons.contacts_outlined,
    granted: perms.readContacts,
    costIfSkipped: 'Calls are logged by number, without a client name.',
  ),
  PermissionAsk(
    id: 'recordings',
    permission: Permission.audio,
    title: 'Recordings on this device',
    why:
        'Discovers audio files saved by the system dialer to sync them alongside '
        'the call records. Required for recording uploads.',
    icon: Icons.graphic_eq_rounded,
    granted: perms.readMediaAudio,
    costIfSkipped: 'Call records still sync, but without their audio.',
  ),
  PermissionAsk(
    id: 'notifications',
    permission: Permission.notification,
    title: 'Notifications',
    why:
        'Displays real-time upload progress, sync status, and remaining calls. '
        'Required to keep you informed of sync activity.',
    icon: Icons.notifications_none_rounded,
    granted: perms.notifications,
    costIfSkipped: 'Sync runs silently, with no progress shown.',
  ),
  PermissionAsk(
    id: 'overlay',
    kind: AskKind.overlayWindow,
    title: 'Post-call card',
    why:
        'Shows a summary card immediately after each call for instant logging '
        'and verification. Required for immediate post-call action.',
    icon: Icons.picture_in_picture_rounded,
    granted: perms.overlayWindow,
    costIfSkipped: 'No summary card appears after a call.',
  ),
];

/// Whether the ask list as a whole clears the bar for entering the app.
extension PermissionAskList on List<PermissionAsk> {
  Iterable<PermissionAsk> get missing => where((a) => !a.granted);

  Iterable<PermissionAsk> get missingEssential =>
      missing.where((a) => a.essential);

  Iterable<PermissionAsk> get missingOptional =>
      missing.where((a) => !a.essential);

  int get grantedCount => where((a) => a.granted).length;

  /// The gate. Tracking works the moment the essentials are in place; the rest
  /// change how much detail is captured, not whether capture happens.
  bool get canProceed => missingEssential.isEmpty;

  bool get allGranted => missing.isEmpty;
}

/// Outcome of a single request, so the caller can react without inspecting
/// [PermissionStatus] in the widget layer.
enum AskOutcome { granted, denied, permanentlyDenied }

/// Requests one runtime permission and reports what happened.
///
/// A permanently-denied permission cannot be re-requested — Android silently
/// drops the dialog — so the caller is told to send the user to app settings
/// rather than firing a request that looks like it did nothing.
Future<AskOutcome> requestAsk(PermissionAsk ask) async {
  final permission = ask.permission;
  if (permission == null) return AskOutcome.denied;

  final status = await permission.request();
  if (status.isGranted || status.isLimited) return AskOutcome.granted;
  if (status.isPermanentlyDenied) return AskOutcome.permanentlyDenied;
  return AskOutcome.denied;
}
