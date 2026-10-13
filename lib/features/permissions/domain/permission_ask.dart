import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../../core/platform/native_call_bridge.dart';
import '../../call_tracking/data/call_feed.dart';

/// How an ask is granted.
///
/// [backgroundActivity] is a settings screen the user has to complete themselves.
/// [overlayWindow] also goes to a settings screen (ACTION_MANAGE_OVERLAY_PERMISSION)
/// rather than an Android runtime-permission dialog.
enum AskKind {
  runtime,
  backgroundActivity,
  overlayWindow,

  /// Android's "Notification access" — for the WhatsApp call listener.
  notificationListener,

  /// The maker's Auto-start screen. No API reports it, so it counts as done
  /// once the user has been there.
  autostart,
}

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
    this.why,
    required this.icon,
    required this.granted,
    this.permission,
    this.kind = AskKind.runtime,
    this.essential = false,
    this.howTo,
  });

  /// Stable identity, used to track per-ask busy/blocked state without relying
  /// on [permission] being non-null.
  final String id;

  final String title;

  /// One short line under the name, only where the name alone would not say
  /// what the grant is used for.
  final String? why;
  final IconData icon;
  final bool granted;

  /// Null for every kind but [AskKind.runtime].
  final Permission? permission;

  final AskKind kind;

  /// Gates the onboarding button until granted. Every ask is essential: a
  /// settings-page grant the OS refuses keeps the user in the walkthrough
  /// until they set it by hand.
  final bool essential;

  /// What to do on the screen the button opens, when that is not obvious.
  /// Shown only until the ask is granted.
  final String? howTo;
}

/// The full ask list, resolved against the current grants.
///
/// Ordered by how much the app loses without each one, so the walkthrough asks
/// for the indispensable permission first and the optional ones after — a user
/// who quits half way through still has a working app.
///
/// [background] may be null while its first read is in flight; the background
/// card is simply reported as not-yet-granted until it arrives.
///
/// [includeNotifications] defaults to true, and the first-run walkthrough now
/// asks for it too. Leaving it out there meant the user finished setup, went
/// into the app, and was then sent to Settings for a permission the
/// walkthrough could have asked for in one tap.
List<PermissionAsk> permissionAsks(
  PermissionSnapshot perms, {
  BackgroundStatus? background,
  bool includeNotifications = true,
}) => [
  PermissionAsk(
    id: 'phone',
    permission: Permission.phone,
    title: 'Phone & call log',
    icon: Icons.phone_outlined,
    granted: perms.canTrack,
    essential: true,
  ),
  // WhatsApp calls never reach the call log; their notifications are the only
  // way the app sees them. Shown under Android's own name for the permission,
  // with one line saying what it is used for: notification access reads every
  // notification on the phone, and the employee is entitled to know why it is
  // asked for (Mobile API Guide §12). Hidden on a phone without WhatsApp.
  if (perms.whatsappInstalled)
    PermissionAsk(
      id: 'whatsapp',
      kind: AskKind.notificationListener,
      title: 'Special access',
      // why: 'Used to log your WhatsApp calls.',
      icon: Icons.notifications_active_outlined,
      granted: perms.whatsappCalls,
      essential: true,
      // Android 13+ greys the switch out for apps installed outside the Play
      // Store until this is allowed.
      howTo: 'Greyed out? App info › ⋮ › Allow restricted settings',
    ),
  PermissionAsk(
    id: 'background',
    kind: AskKind.backgroundActivity,
    title: 'Background activity',
    icon: Icons.battery_saver_rounded,
    granted: background?.ignoringBatteryOptimizations ?? false,
    essential: true,
  ),
  // Only on the makers that stop an app swiped out of Recents unless this is
  // on. No API reports the switch, so it counts as done once the user has
  // been taken to it.
  if (background?.autostartRelevant ?? false)
    PermissionAsk(
      id: 'autostart',
      kind: AskKind.autostart,
      title: 'Auto-start',
      icon: Icons.restart_alt_rounded,
      granted: background?.autostartOpened ?? false,
      essential: true,
    ),
  PermissionAsk(
    id: 'contacts',
    permission: Permission.contacts,
    title: 'Contacts',
    icon: Icons.contacts_outlined,
    granted: perms.readContacts,
    essential: true,
  ),
  PermissionAsk(
    id: 'recordings',
    // Chosen from what the native side says this handset needs. Permission
    // .audio is READ_MEDIA_AUDIO, which only exists from API 33: below that
    // it reports denied without ever showing a dialog, so on Android 7–12
    // this card could not be granted at all.
    permission: perms.recordingPermission.endsWith('READ_EXTERNAL_STORAGE')
        ? Permission.storage
        : Permission.audio,
    title: 'Call recordings',
    icon: Icons.graphic_eq_rounded,
    granted: perms.readRecordings,
    essential: true,
  ),
  if (includeNotifications)
    PermissionAsk(
      id: 'notifications',
      permission: Permission.notification,
      title: 'Notifications',
      icon: Icons.notifications_none_rounded,
      granted: perms.notifications,
      essential: true,
    ),
  PermissionAsk(
    id: 'overlay',
    kind: AskKind.overlayWindow,
    title: 'Display over other apps',
    icon: Icons.picture_in_picture_rounded,
    granted: perms.overlayWindow,
    essential: true,
  ),
];

/// Whether the ask list as a whole clears the bar for entering the app.
extension PermissionAskList on List<PermissionAsk> {
  Iterable<PermissionAsk> get missing => where((a) => !a.granted);

  Iterable<PermissionAsk> get missingEssential =>
      missing.where((a) => a.essential);

  int get grantedCount => where((a) => a.granted).length;

  /// The gate. Tracking works the moment the essentials are in place; the rest
  /// change how much detail is captured, not whether capture happens.
  bool get canProceed => missingEssential.isEmpty;

  bool get allGranted => missing.isEmpty;
}

/// Outcome of a single request, so the caller can react without inspecting
/// [PermissionStatus] in the widget layer.
///
/// [permanentlyDenied] means the user refused in the dialog just shown, and
/// Android will not show it again. [openedSettings] means no dialog could be
/// shown at all, so app settings was opened instead.
enum AskOutcome { granted, denied, permanentlyDenied, openedSettings }

/// Requests one runtime permission and reports what happened.
///
/// A permanently-denied permission cannot be re-requested — Android silently
/// drops the dialog — so in that state this opens app settings in the same tap
/// instead of firing a request that looks like it did nothing. It is checked
/// before requesting because the state lives in the OS, not in any screen:
/// after a restart the first tap used to return "permanently denied" with no
/// dialog, and only a second tap reached Settings.
///
/// A refusal in a dialog that was actually shown does NOT jump to Settings.
/// The user just said no; the card says how to change it later instead.
Future<AskOutcome> requestAsk(Permission permission) async {
  if (await permission.status.isPermanentlyDenied) {
    await openAppSettings();
    return AskOutcome.openedSettings;
  }

  final status = await permission.request();
  if (status.isGranted || status.isLimited) return AskOutcome.granted;
  if (status.isPermanentlyDenied) return AskOutcome.permanentlyDenied;
  return AskOutcome.denied;
}
