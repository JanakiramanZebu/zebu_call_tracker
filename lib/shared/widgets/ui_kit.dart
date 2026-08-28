import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/platform/native_call_bridge.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/formatters.dart';
import '../../features/call_tracking/domain/call_entry.dart';
import '../../features/recording/domain/recording_matcher.dart';
import '../../features/recording/presentation/recording_player_widget.dart';

/// Convenience accessors so widgets stop repeating `Theme.of(context)`.
extension ThemeX on BuildContext {
  ColorScheme get colors => Theme.of(this).colorScheme;
  TextTheme get text => Theme.of(this).textTheme;
  AppPalette get palette => Theme.of(this).extension<AppPalette>()!;
}

/// A rounded, tinted icon container — the app's one repeated visual motif.
class IconChip extends StatelessWidget {
  const IconChip({
    super.key,
    required this.icon,
    required this.color,
    this.size = 38,
    this.iconSize = 20,
  });

  final IconData icon;
  final Color color;
  final double size;
  final double iconSize;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      // A 12%-alpha wash of the semantic colour, so the chip reads as the
      // same family in both themes without a second token per colour.
      color: color.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(size / 3.4),
    ),
    child: Icon(icon, size: iconSize, color: color),
  );
}

class StatusPill extends StatelessWidget {
  const StatusPill({
    super.key,
    required this.label,
    required this.color,
    this.icon,
    this.filled = false,
  });

  final String label;
  final Color color;
  final IconData? icon;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final fg = filled ? Colors.white : color;
    return Container(
      height: 26,
      padding: const EdgeInsets.symmetric(horizontal: 9),
      decoration: BoxDecoration(
        color: filled ? color : color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ?(icon == null ? null : Icon(icon, size: 13, color: fg)),
          ?(icon == null ? null : const SizedBox(width: 5)),
          Text(
            label,
            style: context.text.labelSmall?.copyWith(
              color: fg,
              fontWeight: FontWeight.w600,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }
}

class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key, this.trailing});

  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(2, 4, 2, 0),
    child: Row(
      children: [
        Expanded(
          child: Text(
            text.toUpperCase(),
            style: context.text.labelSmall?.copyWith(
              color: context.palette.muted,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.6,
              fontSize: 12,
            ),
          ),
        ),
        ?trailing,
      ],
    ),
  );
}

/// Card with the standard 12px radius and hairline outline, plus optional
/// padding — used everywhere instead of raw [Card] so spacing stays uniform.
class AppCard extends StatelessWidget {
  const AppCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.borderColor,
    this.onTap,
  });

  final Widget child;
  final EdgeInsets padding;
  final Color? borderColor;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final content = Padding(padding: padding, child: child);
    return Material(
      color: context.colors.surface,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Ink(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: borderColor ?? context.colors.outlineVariant,
            ),
          ),
          child: content,
        ),
      ),
    );
  }
}

/// Visual vocabulary for a call direction, resolved once so the list, the
/// detail screen and the stats grid can never disagree about what "missed"
/// looks like.
({IconData icon, Color color, String label}) directionStyle(
  BuildContext context,
  CallDirection direction,
) {
  final p = context.palette;
  return switch (direction) {
    CallDirection.incoming => (
      icon: Icons.call_received_rounded,
      color: p.answered,
      label: 'Incoming',
    ),
    CallDirection.outgoing => (
      icon: Icons.call_made_rounded,
      color: context.colors.primary,
      label: 'Outgoing',
    ),
    CallDirection.missed => (
      icon: Icons.call_missed_rounded,
      color: p.missed,
      label: 'Missed',
    ),
    CallDirection.rejected => (
      icon: Icons.do_not_disturb_on_outlined,
      color: p.missed,
      label: 'Rejected',
    ),
    CallDirection.blocked => (
      icon: Icons.block_rounded,
      color: p.missed,
      label: 'Blocked',
    ),
    CallDirection.voicemail => (
      icon: Icons.voicemail_rounded,
      color: p.muted,
      label: 'Voicemail',
    ),
    CallDirection.unknown => (
      icon: Icons.call_rounded,
      color: p.muted,
      label: 'Unknown',
    ),
  };
}

({IconData icon, Color color, String label}) uploadStyle(
  BuildContext context,
  UploadState state,
) {
  final p = context.palette;
  return switch (state) {
    UploadState.uploaded => (
      icon: Icons.check_rounded,
      color: p.answered,
      label: 'Uploaded',
    ),
    UploadState.uploading => (
      icon: Icons.arrow_upward_rounded,
      color: context.colors.primary,
      label: 'Uploading',
    ),
    UploadState.pending => (
      icon: Icons.schedule_rounded,
      color: p.waiting,
      label: 'Waiting',
    ),
    UploadState.failed => (
      icon: Icons.error_outline_rounded,
      color: p.missed,
      label: 'Failed',
    ),
  };
}

/// One row in the call list.
///
/// A [ConsumerWidget] so the recording can be played from the list itself. The
/// alternative — opening the detail screen to hear thirty seconds of a call —
/// is enough friction that staff stop checking their recordings at all.
class CallRowTile extends ConsumerWidget {
  const CallRowTile({super.key, required this.entry, this.onTap});

  final CallEntry entry;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dir = directionStyle(context, entry.row.direction);
    final up = uploadStyle(context, entry.uploadState);

    final subtitle = entry.isConnected
        ? '${Fmt.maskNumber(entry.row.number)} · ${Fmt.duration(entry.durationSeconds)}'
        : '${Fmt.maskNumber(entry.row.number)} · ${dir.label}';

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Row(
          children: [
            IconChip(icon: dir.icon, color: dir.color, iconSize: 18),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    entry.displayTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.text.bodyLarge?.copyWith(
                      fontWeight: FontWeight.w600,
                      fontSize: 15,
                      // An unnamed caller is real information, not an error —
                      // muted rather than styled like a warning.
                      color: entry.hasName
                          ? context.colors.onSurface
                          : context.palette.muted,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.text.bodySmall?.copyWith(
                      color: context.palette.muted,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            // The play control sits outside the row's InkWell so tapping it
            // starts audio instead of opening the detail screen.
            if (entry.recording != null) ...[
              RecordingPlayButton(candidate: entry.recording!, size: 32),
              const SizedBox(width: 10),
            ],
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  entry.startedAtUtc == null
                      ? '--:--'
                      : Fmt.clock(entry.startedAtUtc!),
                  style: context.text.bodySmall?.copyWith(
                    color: context.palette.muted,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                const SizedBox(height: 5),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (entry.needsReview) ...[
                      Icon(
                        Icons.help_outline_rounded,
                        size: 15,
                        color: context.palette.waiting,
                      ),
                      const SizedBox(width: 4),
                    ],
                    Icon(up.icon, size: 14, color: up.color),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Empty/blocked state with one clear action, used instead of a bare spinner or
/// a blank list — both of which read as "broken" to a user.
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          IconChip(
            icon: icon,
            color: context.palette.muted,
            size: 56,
            iconSize: 28,
          ),
          const SizedBox(height: 20),
          Text(
            title,
            textAlign: TextAlign.center,
            style: context.text.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            message,
            textAlign: TextAlign.center,
            style: context.text.bodyMedium?.copyWith(
              color: context.palette.muted,
              height: 1.5,
            ),
          ),
          if (actionLabel != null) ...[
            const SizedBox(height: 24),
            SizedBox(
              width: 220,
              child: FilledButton(
                onPressed: onAction,
                child: Text(actionLabel!),
              ),
            ),
          ],
        ],
      ),
    ),
  );
}

/// Recording match state rendered as a chip. Kept beside the other status
/// helpers so "needs review" always looks the same wherever it appears.
({IconData icon, Color color, String label}) recordingStyle(
  BuildContext context,
  RecordingMatchStatus status,
) {
  final p = context.palette;
  return switch (status) {
    RecordingMatchStatus.matched => (
      icon: Icons.graphic_eq_rounded,
      color: p.answered,
      label: 'Matched',
    ),
    RecordingMatchStatus.ambiguous => (
      icon: Icons.help_outline_rounded,
      color: p.waiting,
      label: 'Needs review',
    ),
    RecordingMatchStatus.unmatched => (
      icon: Icons.link_off_rounded,
      color: p.muted,
      label: 'No match',
    ),
    RecordingMatchStatus.notFound => (
      icon: Icons.mic_off_outlined,
      color: p.muted,
      label: 'No recording',
    ),
  };
}
