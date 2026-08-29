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
  final bool essential;
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
        'status. Without this, nothing is tracked.',
    icon: Icons.phone_outlined,
    granted: perms.readCallLog && perms.readPhoneState,
    essential: true,
  ),
  PermissionAsk(
    id: 'background',
    kind: AskKind.backgroundActivity,
    title: 'Background activity',
    why:
        'Lets tracking run when the app is closed. Without it Android delays '
        'the check for hours, by which time your dialer may have deleted the '
        "call's recording.",
    icon: Icons.battery_saver_rounded,
    granted: background?.ignoringBatteryOptimizations ?? false,
  ),
  PermissionAsk(
    id: 'contacts',
    permission: Permission.contacts,
    title: 'Contacts',
    why:
        'Shows a name instead of a bare number. Declining keeps the number; '
        'only the name is missing.',
    icon: Icons.contacts_outlined,
    granted: perms.readContacts,
  ),
  PermissionAsk(
    id: 'recordings',
    permission: Permission.audio,
    title: 'Recordings on this device',
    why:
        "Finds call recordings your phone's own dialer already made, so they "
        'can be filed against the right call. The app never records anything '
        'itself.',
    icon: Icons.graphic_eq_rounded,
    granted: perms.readMediaAudio,
  ),
  PermissionAsk(
    id: 'notifications',
    permission: Permission.notification,
    title: 'Notifications',
    why:
        'Tells you when an upload fails, so calls do not sit unsynced without '
        'you noticing.',
    icon: Icons.notifications_none_rounded,
    granted: perms.notifications,
  ),
  PermissionAsk(
    id: 'overlay',
    kind: AskKind.overlayWindow,
    title: 'Post-call card',
    why:
        'Shows a summary card immediately after each call — the contact name, '
        'duration, and whether a recording was found. Works like the Truecaller '
        'overlay. You can disable it here at any time.',
    icon: Icons.picture_in_picture_rounded,
    granted: perms.overlayWindow,
  ),
];

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
