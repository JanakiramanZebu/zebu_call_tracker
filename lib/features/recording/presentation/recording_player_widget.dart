import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/widgets/ui_kit.dart';
import '../data/recording_player.dart';
import '../domain/recording_matcher.dart';

String _clock(Duration d) {
  final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  final h = d.inHours;
  return h > 0 ? '$h:$m:$s' : '$m:$s';
}

/// Full transport for one recording: play/pause, scrubber, elapsed/remaining,
/// skip and speed.
///
/// The scrubber is a real [Slider] rather than a progress bar — staff reviewing
/// a ten-minute call need to jump to the part they remember, and a bar they
/// cannot drag makes them play the whole thing.
class RecordingPlayerBar extends ConsumerWidget {
  const RecordingPlayerBar({super.key, required this.candidate});

  final RecordingCandidate candidate;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(recordingPlayerProvider);
    final player = ref.read(recordingPlayerProvider.notifier);

    final isCurrent = state.isFor(candidate.mediaStoreId);
    final error = isCurrent ? state.error : null;

    // Before this recording is loaded the bar still needs a scale, so it falls
    // back to the duration MediaStore reported for the file.
    final duration = isCurrent && state.duration > Duration.zero
        ? state.duration
        : Duration(milliseconds: candidate.durationMillis);
    final position = isCurrent ? state.position : Duration.zero;

    if (error != null) {
      return _PlaybackError(
        message: error,
        onRetry: () => player.toggle(candidate),
      );
    }

    return Column(
      children: [
        Row(
          children: [
            _PlayButton(
              playing: state.isPlaying(candidate.mediaStoreId),
              loading: state.isLoading(candidate.mediaStoreId),
              onPressed: () => player.toggle(candidate),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                children: [
                  SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 4,
                      // A slim thumb keeps the bar readable at this size while
                      // staying inside the 48dp touch target the overlay gives.
                      thumbShape: const RoundSliderThumbShape(
                        enabledThumbRadius: 7,
                      ),
                      overlayShape: const RoundSliderOverlayShape(
                        overlayRadius: 16,
                      ),
                      activeTrackColor: context.colors.primary,
                      inactiveTrackColor: context.palette.tint,
                      thumbColor: context.colors.primary,
                    ),
                    child: Slider(
                      value: position.inMilliseconds
                          .clamp(0, duration.inMilliseconds)
                          .toDouble(),
                      max: duration.inMilliseconds.toDouble().clamp(
                        1,
                        double.infinity,
                      ),
                      onChanged: isCurrent
                          ? (v) =>
                                player.seek(Duration(milliseconds: v.round()))
                          // Seeking a recording that is not loaded would have to
                          // load it first; tapping play is the clearer gesture.
                          : null,
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        _Time(_clock(position)),
                        _Time(_clock(duration)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _SkipButton(
              icon: Icons.replay_10_rounded,
              tooltip: 'Back 10 seconds',
              onPressed: isCurrent
                  ? () => player.seek(
                      position - const Duration(seconds: 10) < Duration.zero
                          ? Duration.zero
                          : position - const Duration(seconds: 10),
                    )
                  : null,
            ),
            const SizedBox(width: 8),
            _SkipButton(
              icon: Icons.forward_30_rounded,
              tooltip: 'Forward 30 seconds',
              onPressed: isCurrent
                  ? () => player.seek(
                      position + const Duration(seconds: 30) > duration
                          ? duration
                          : position + const Duration(seconds: 30),
                    )
                  : null,
            ),
            const SizedBox(width: 8),
            TextButton(
              onPressed: player.cycleSpeed,
              style: TextButton.styleFrom(
                minimumSize: const Size(56, 36),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                foregroundColor: state.speed == 1.0
                    ? context.palette.muted
                    : context.colors.primary,
              ),
              child: Text(
                '${state.speed.toStringAsFixed(state.speed == 1.0 ? 0 : 1)}×',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// Compact play control for a history row, where a full transport would
/// overwhelm the line it sits on.
class RecordingPlayButton extends ConsumerWidget {
  const RecordingPlayButton({super.key, required this.candidate, this.size = 34});

  final RecordingCandidate candidate;
  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(recordingPlayerProvider);
    return _PlayButton(
      size: size,
      playing: state.isPlaying(candidate.mediaStoreId),
      loading: state.isLoading(candidate.mediaStoreId),
      onPressed: () =>
          ref.read(recordingPlayerProvider.notifier).toggle(candidate),
    );
  }
}

class _PlayButton extends StatelessWidget {
  const _PlayButton({
    required this.playing,
    required this.loading,
    required this.onPressed,
    this.size = 48,
  });

  final bool playing;
  final bool loading;
  final VoidCallback onPressed;
  final double size;

  @override
  Widget build(BuildContext context) => Material(
    color: context.colors.primary,
    shape: const CircleBorder(),
    child: InkWell(
      customBorder: const CircleBorder(),
      onTap: onPressed,
      child: SizedBox(
        width: size,
        height: size,
        child: loading
            ? Padding(
                padding: EdgeInsets.all(size * 0.3),
                child: const CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              )
            : Icon(
                playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                color: Colors.white,
                size: size * 0.55,
              ),
      ),
    ),
  );
}

class _SkipButton extends StatelessWidget {
  const _SkipButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => IconButton(
    onPressed: onPressed,
    icon: Icon(icon, size: 22),
    tooltip: tooltip,
    color: context.palette.muted,
    visualDensity: VisualDensity.compact,
  );
}

class _Time extends StatelessWidget {
  const _Time(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: context.text.bodySmall?.copyWith(
      color: context.palette.muted,
      fontFeatures: const [FontFeature.tabularFigures()],
    ),
  );
}

class _PlaybackError extends StatelessWidget {
  const _PlaybackError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: context.palette.missed.withValues(alpha: 0.10),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          Icons.error_outline_rounded,
          size: 18,
          color: context.palette.missed,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            message,
            style: context.text.bodySmall?.copyWith(height: 1.5),
          ),
        ),
        TextButton(
          onPressed: onRetry,
          style: TextButton.styleFrom(
            minimumSize: const Size(0, 32),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          child: const Text('Retry'),
        ),
      ],
    ),
  );
}
