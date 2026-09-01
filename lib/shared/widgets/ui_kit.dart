import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/platform/native_call_bridge.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/design_tokens.dart';
import '../../core/utils/formatters.dart';
import '../../features/call_tracking/domain/call_entry.dart';
import '../../features/recording/domain/recording_matcher.dart';
import '../../features/recording/presentation/recording_player_widget.dart';

/// Convenience accessors on BuildContext.
extension ThemeX on BuildContext {
  ColorScheme get colors => Theme.of(this).colorScheme;
  TextTheme get text => Theme.of(this).textTheme;
  AppPalette get palette =>
      Theme.of(this).extension<AppPalette>() ?? AppPalette.dark;
  bool get isDark => Theme.of(this).brightness == Brightness.dark;
}

/// A rounded, tinted icon container with semantic glow wash.
class IconChip extends StatelessWidget {
  const IconChip({
    super.key,
    required this.icon,
    required this.color,
    this.size = 36,
    this.iconSize = 18,
    this.roundedRadius,
  });

  final IconData icon;
  final Color color;
  final double size;
  final double iconSize;
  final double? roundedRadius;

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(roundedRadius ?? (size / 3.4)),
          border: Border.all(
            color: color.withValues(alpha: 0.22),
            width: 1,
          ),
        ),
        alignment: Alignment.center,
        child: Icon(icon, size: iconSize, color: color),
      );
}

/// A compact, status badge pill with optional glow and icon.
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
      height: 24,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: filled ? color : color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: color.withValues(alpha: filled ? 0.0 : 0.25),
          width: 1,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 12, color: fg),
            const SizedBox(width: 4),
          ],
          Text(
            label,
            style: TextStyle(
              color: fg,
              fontWeight: FontWeight.w600,
              fontSize: 11.5,
              letterSpacing: -0.2,
            ),
          ),
        ],
      ),
    );
  }
}

/// Section header with uppercase tracking label and optional trailing action.
class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key, this.trailing});

  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(2, 6, 2, 2),
        child: Row(
          children: [
            Expanded(
              child: Text(
                text.toUpperCase(),
                style: const TextStyle(
                  color: AppTokens.textMuted,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.8,
                  fontSize: 11.5,
                ),
              ),
            ),
            ?trailing,
          ],
        ),
      );
}

/// Glass-morphic surface with layered dark background and hairline borders.
class AppCard extends StatelessWidget {
  const AppCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.borderColor,
    this.backgroundColor,
    this.onTap,
    this.borderRadius = AppTokens.r16,
  });

  final Widget child;
  final EdgeInsets padding;
  final Color? borderColor;
  final Color? backgroundColor;
  final VoidCallback? onTap;
  final double borderRadius;

  @override
  Widget build(BuildContext context) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    final bg = backgroundColor ??
        (isLight ? Colors.white : AppTokens.surface1);
    final border = borderColor ??
        (isLight ? const Color(0xFFE2E8F0) : AppTokens.borderDefault);

    final content = Padding(padding: padding, child: child);

    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(borderRadius),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(borderRadius),
        child: Ink(
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(borderRadius),
            border: Border.all(color: border, width: 1),
            boxShadow: isLight
                ? [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.03),
                      blurRadius: 10,
                      offset: const Offset(0, 3),
                    ),
                  ]
                : [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.25),
                      blurRadius: 12,
                      offset: const Offset(0, 4),
                    ),
                  ],
          ),
          child: content,
        ),
      ),
    );
  }
}

/// Compact Metric Tile for analytics dashboards (2x3 or 3x2 grid).
class MetricTile extends StatelessWidget {
  const MetricTile({
    super.key,
    required this.title,
    required this.count,
    required this.icon,
    required this.color,
    this.trend,
    this.higherIsWorse = false,
    this.duration,
    this.onTap,
  });

  final String title;
  final String count;
  final IconData icon;
  final Color color;
  final String? trend;

  /// True when a RISE in this metric is bad news — missed calls, rejections,
  /// unanswered outgoing. Without it a worsening figure renders in the same
  /// green as an improving one, which reads as the opposite of what happened.
  final bool higherIsWorse;
  final String? duration;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppTokens.r16),
        child: Ink(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
          decoration: BoxDecoration(
            color: AppTokens.surface1,
            borderRadius: BorderRadius.circular(AppTokens.r16),
            border: Border.all(color: AppTokens.borderDefault, width: 1),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.2),
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              // Header: Icon + Title + (Trend if any)
              Row(
                children: [
                  IconChip(
                    icon: icon,
                    color: color,
                    size: 30,
                    iconSize: 16,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      title,
                      style: const TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: AppTokens.textSecondary,
                        letterSpacing: -0.2,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (trend != null) ...[
                    const SizedBox(width: 4),
                    Text(
                      trend!,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: switch (trend![0]) {
                          '+' =>
                            higherIsWorse ? AppTokens.danger : AppTokens.success,
                          '-' =>
                            higherIsWorse ? AppTokens.success : AppTokens.danger,
                          _ => AppTokens.textMuted,
                        },
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 12),

              // Metric Count
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text(
                    count,
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                      color: Colors.white,
                      letterSpacing: -0.4,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                  if (duration != null) ...[
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        duration!,
                        style: const TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w500,
                          color: AppTokens.textMuted,
                          fontFeatures: [FontFeature.tabularFigures()],
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Segmented Control with animated active pill selector.
class ModernSegmentedControl<T> extends StatelessWidget {
  const ModernSegmentedControl({
    super.key,
    required this.segments,
    required this.selected,
    required this.onSelected,
  });

  final Map<T, String> segments;
  final T selected;
  final ValueChanged<T> onSelected;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 40,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: const Color(0xFF101827),
        borderRadius: BorderRadius.circular(AppTokens.r12),
        border: Border.all(color: AppTokens.borderDefault, width: 1),
      ),
      child: Row(
        children: segments.entries.map((entry) {
          final isSelected = entry.key == selected;
          return Expanded(
            child: GestureDetector(
              onTap: () => onSelected(entry.key),
              behavior: HitTestBehavior.opaque,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeInOut,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: isSelected
                      ? AppTokens.brandElectric
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(AppTokens.r8),
                  boxShadow: isSelected
                      ? [
                          BoxShadow(
                            color: AppTokens.brandElectric
                                .withValues(alpha: 0.35),
                            blurRadius: 8,
                            offset: const Offset(0, 2),
                          ),
                        ]
                      : null,
                ),
                child: Text(
                  entry.value,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                    color: isSelected
                        ? Colors.white
                        : const Color(0xFF94A3B8),
                  ),
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}

/// Visual style mapping for call directions.
({IconData icon, Color color, String label}) directionStyle(
  BuildContext context,
  CallDirection direction,
) {
  return switch (direction) {
    CallDirection.incoming => (
        icon: Icons.call_received_rounded,
        color: AppTokens.callIncoming,
        label: 'Incoming',
      ),
    CallDirection.outgoing => (
        icon: Icons.call_made_rounded,
        color: AppTokens.callOutgoing,
        label: 'Outgoing',
      ),
    CallDirection.missed => (
        icon: Icons.call_missed_rounded,
        color: AppTokens.callMissed,
        label: 'Missed',
      ),
    CallDirection.rejected => (
        icon: Icons.phone_disabled_rounded,
        color: AppTokens.callRejected,
        label: 'Rejected',
      ),
    CallDirection.blocked => (
        icon: Icons.block_rounded,
        color: AppTokens.callMissed,
        label: 'Blocked',
      ),
    CallDirection.voicemail => (
        icon: Icons.voicemail_rounded,
        color: AppTokens.textMuted,
        label: 'Voicemail',
      ),
    CallDirection.unknown => (
        icon: Icons.call_rounded,
        color: AppTokens.textMuted,
        label: 'Unknown',
      ),
  };
}

/// Visual style mapping for sync/upload state.
({IconData icon, Color color, String label}) uploadStyle(
  BuildContext context,
  UploadState state,
) {
  return switch (state) {
    UploadState.uploaded => (
        icon: Icons.check_circle_rounded,
        color: AppTokens.success,
        label: 'Uploaded',
      ),
    UploadState.uploading => (
        icon: Icons.cloud_upload_rounded,
        color: AppTokens.brandElectric,
        label: 'Uploading',
      ),
    UploadState.pending => (
        icon: Icons.schedule_rounded,
        color: AppTokens.warning,
        label: 'Waiting',
      ),
    UploadState.failed => (
        icon: Icons.error_rounded,
        color: AppTokens.danger,
        label: 'Failed',
      ),
  };
}

/// Recording match status helper.
({IconData icon, Color color, String label}) recordingStyle(
  BuildContext context,
  RecordingMatchStatus status,
) {
  return switch (status) {
    RecordingMatchStatus.matched => (
        icon: Icons.graphic_eq_rounded,
        color: AppTokens.success,
        label: 'Matched',
      ),
    RecordingMatchStatus.ambiguous => (
        icon: Icons.help_outline_rounded,
        color: AppTokens.warning,
        label: 'Needs review',
      ),
    RecordingMatchStatus.unmatched => (
        icon: Icons.link_off_rounded,
        color: AppTokens.textMuted,
        label: 'No match',
      ),
    RecordingMatchStatus.notFound => (
        icon: Icons.mic_off_outlined,
        color: AppTokens.textMuted,
        label: 'No recording',
      ),
  };
}

/// Timeline call row widget for Call History and Recent Calls.
class CallRowTile extends ConsumerWidget {
  const CallRowTile({
    super.key,
    required this.entry,
    this.onTap,
  });

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
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            // Direction Icon Chip
            IconChip(
              icon: dir.icon,
              color: dir.color,
              size: 36,
              iconSize: 18,
            ),
            const SizedBox(width: 14),

            // Call Information (Title & Subtitle)
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    entry.displayTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 15,
                      letterSpacing: -0.2,
                      color: entry.hasName
                          ? Colors.white
                          : AppTokens.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12.5,
                      color: AppTokens.textMuted,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),

            // Play button if recording is matched
            if (entry.recording case final rec?) ...[
              RecordingPlayButton(candidate: rec, size: 34),
              const SizedBox(width: 10),
            ],

            // Timestamp + Sync Indicator
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  entry.startedAtUtc != null
                      ? Fmt.clock(entry.startedAtUtc!)
                      : '--:--',
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: AppTokens.textMuted,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
                const SizedBox(height: 5),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (entry.needsReview) ...[
                      const Icon(
                        Icons.help_outline_rounded,
                        size: 14,
                        color: AppTokens.warning,
                      ),
                      const SizedBox(width: 4),
                    ],
                    Icon(up.icon, size: 13.5, color: up.color),
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

/// Rich Empty State widget with modern iconography.
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
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  color: AppTokens.surface2,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: AppTokens.borderDefault,
                    width: 1.5,
                  ),
                ),
                alignment: Alignment.center,
                child: Icon(icon, size: 30, color: AppTokens.textMuted),
              ),
              const SizedBox(height: 20),
              Text(
                title,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                  letterSpacing: -0.3,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                message,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 13.5,
                  color: AppTokens.textSecondary,
                  height: 1.5,
                ),
              ),
              if (actionLabel case final labelText?) ...[
                const SizedBox(height: 24),
                SizedBox(
                  width: 200,
                  height: 44,
                  child: FilledButton(
                    onPressed: onAction,
                    child: Text(labelText),
                  ),
                ),
              ],
            ],
          ),
        ),
      );
}
