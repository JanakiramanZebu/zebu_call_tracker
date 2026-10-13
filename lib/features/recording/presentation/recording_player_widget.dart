import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/design_tokens.dart';
import '../../../core/utils/formatters.dart';
import '../../../shared/widgets/ui_kit.dart';
import '../data/recording_player.dart';
import '../domain/recording_matcher.dart';

/// Full transport for one recording: play/pause, a waveform scrubber,
/// elapsed/total, skip and speed.
///
/// The waveform is a real seek control rather than a progress picture — staff
/// reviewing a ten-minute call need to jump to the part they remember, and a
/// bar they cannot drag makes them play the whole thing. Tap or drag anywhere
/// on it to seek; screen readers get it as a slider.
///
/// Only [_Scrubber] follows the playback position. The player publishes it
/// several times a second, and when the whole bar — and every play button on
/// the screen — watched the full state, each tick rebuilt all of them.
class RecordingPlayerBar extends ConsumerWidget {
  const RecordingPlayerBar({super.key, required this.candidate});

  final RecordingCandidate candidate;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = candidate.mediaStoreId;
    final (:isCurrent, :error, :speed) = ref.watch(
      recordingPlayerProvider.select(
        (s) => (
          isCurrent: s.isFor(id),
          error: s.isFor(id) ? s.error : null,
          speed: s.speed,
        ),
      ),
    );
    final player = ref.read(recordingPlayerProvider.notifier);

    if (error != null) {
      return _PlaybackError(
        message: error,
        onRetry: () => player.toggle(candidate),
      );
    }

    // Read at the moment of the tap, so the buttons need not rebuild with
    // every position tick to know where "ten seconds back" is.
    void skip(Duration by) {
      final s = ref.read(recordingPlayerProvider);
      final target = s.position + by;
      player.seek(
        target < Duration.zero
            ? Duration.zero
            : (target > s.duration ? s.duration : target),
      );
    }

    final normalSpeed = speed == 1.0;
    final speedLabel = '${speed.toStringAsFixed(normalSpeed ? 0 : 1)}×';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            RecordingPlayButton(candidate: candidate, size: 48),
            const SizedBox(width: 14),
            Expanded(child: _Scrubber(candidate: candidate)),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            ZButton(
              label: 'Back 10s',
              semanticLabel: 'Back 10 seconds',
              variant: ZButtonVariant.secondary,
              size: ZButtonSize.small,
              expand: false,
              onPressed: isCurrent
                  ? () => skip(const Duration(seconds: -10))
                  : null,
            ),
            const SizedBox(width: 8),
            ZButton(
              label: 'Forward 30s',
              semanticLabel: 'Forward 30 seconds',
              variant: ZButtonVariant.secondary,
              size: ZButtonSize.small,
              expand: false,
              onPressed: isCurrent
                  ? () => skip(const Duration(seconds: 30))
                  : null,
            ),
            const Spacer(),
            ConstrainedBox(
              constraints: const BoxConstraints(minWidth: 52),
              child: ZButton(
                label: speedLabel,
                semanticLabel: 'Playback speed $speedLabel',
                variant: ZButtonVariant.outline,
                size: ZButtonSize.small,
                expand: false,
                onPressed: player.cycleSpeed,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// The waveform and elapsed/total labels — the only part of the bar that
/// follows the playback position, and only for the recording that is loaded.
class _Scrubber extends ConsumerWidget {
  const _Scrubber({required this.candidate});

  final RecordingCandidate candidate;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final z = context.z;
    final id = candidate.mediaStoreId;
    // Null for every bar but the loaded one, so those never rebuild on a tick.
    final live = ref.watch(
      recordingPlayerProvider.select(
        (s) => s.isFor(id) ? (s.position, s.duration) : null,
      ),
    );

    // Before this recording is loaded the bar still needs a scale, so it falls
    // back to the duration MediaStore reported for the file.
    final duration = live != null && live.$2 > Duration.zero
        ? live.$2
        : Duration(milliseconds: candidate.durationMillis);
    final position = live?.$1 ?? Duration.zero;
    final totalMs = duration.inMilliseconds;
    final fraction = totalMs <= 0
        ? 0.0
        : (position.inMilliseconds / totalMs).clamp(0.0, 1.0);

    // Seeking a recording that is not loaded would have to load it first;
    // tapping play is the clearer gesture, so the waveform is inert until then.
    final canSeek = live != null && totalMs > 0;
    final player = ref.read(recordingPlayerProvider.notifier);

    void seekTo(Duration d) => player.seek(
      d < Duration.zero ? Duration.zero : (d > duration ? duration : d),
    );

    void seekToX(double dx, double width) {
      if (width <= 0) return;
      final f = (dx / width).clamp(0.0, 1.0);
      seekTo(Duration(milliseconds: (totalMs * f).round()));
    }

    final elapsed = Fmt.stopwatch(position.inSeconds);
    final total = Fmt.stopwatch(duration.inSeconds);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          slider: true,
          enabled: canSeek,
          label: 'Playback position',
          value: '$elapsed of $total',
          increasedValue: canSeek
              ? Fmt.stopwatch(
                  math.min(position.inSeconds + 10, duration.inSeconds),
                )
              : null,
          decreasedValue: canSeek
              ? Fmt.stopwatch(math.max(position.inSeconds - 10, 0))
              : null,
          onIncrease: canSeek
              ? () => seekTo(position + const Duration(seconds: 10))
              : null,
          onDecrease: canSeek
              ? () => seekTo(position - const Duration(seconds: 10))
              : null,
          excludeSemantics: true,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.maxWidth;
              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapDown: canSeek
                    ? (d) => seekToX(d.localPosition.dx, width)
                    : null,
                onHorizontalDragStart: canSeek
                    ? (d) => seekToX(d.localPosition.dx, width)
                    : null,
                onHorizontalDragUpdate: canSeek
                    ? (d) => seekToX(d.localPosition.dx, width)
                    : null,
                // 44 tall for the touch target; the bars sit in the middle 36.
                child: SizedBox(
                  height: AppTokens.minTap,
                  child: Center(
                    child: SizedBox(
                      height: 36,
                      width: double.infinity,
                      child: RepaintBoundary(
                        child: CustomPaint(
                          painter: _WavePainter(
                            seed: id,
                            fraction: fraction,
                            played: z.accent,
                            rest: z.lineStrong,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 2),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            _Time(elapsed, emphasised: live != null),
            _Time(total),
          ],
        ),
      ],
    );
  }
}

/// Forty-eight thin bars, played portion in the accent.
///
/// The heights are not the audio's: decoding the file to draw its envelope
/// would cost far more than the picture is worth. They are derived from the
/// bar index and the file's id, so a recording always draws the same shape
/// and two recordings on one screen look different.
class _WavePainter extends CustomPainter {
  const _WavePainter({
    required this.seed,
    required this.fraction,
    required this.played,
    required this.rest,
  });

  static const _bars = 48;
  static const _gap = 2.0;

  final int seed;
  final double fraction;
  final Color played;
  final Color rest;

  @override
  void paint(Canvas canvas, Size size) {
    final barWidth = (size.width - _gap * (_bars - 1)) / _bars;
    if (barWidth <= 0) return;
    final phase = (seed % 97) * 0.61;
    final paint = Paint()..isAntiAlias = true;

    for (var i = 0; i < _bars; i++) {
      final wave =
          (math.sin(i * 1.7 + phase) + math.sin(i * 0.37 + phase * 0.5) * 0.8)
              .abs();
      final h = (6 + wave * 14).clamp(4.0, size.height);
      final x = i * (barWidth + _gap);
      final top = (size.height - h) / 2;
      paint.color = i / _bars < fraction ? played : rest;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, top, barWidth, h),
          const Radius.circular(1),
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_WavePainter old) =>
      old.fraction != fraction ||
      old.seed != seed ||
      old.played != played ||
      old.rest != rest;
}

/// Compact play control for a history row, where a full transport would
/// overwhelm the line it sits on.
///
/// Selects only this recording's playing/loading flags: a list of thirty rows
/// each watching the whole player state rebuilt all thirty on every position
/// tick of whichever one was playing.
class RecordingPlayButton extends ConsumerWidget {
  const RecordingPlayButton({super.key, required this.candidate, this.size = 34});

  final RecordingCandidate candidate;
  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = candidate.mediaStoreId;
    final (playing, loading) = ref.watch(
      recordingPlayerProvider.select((s) => (s.isPlaying(id), s.isLoading(id))),
    );
    return _PlayButton(
      size: size,
      playing: playing,
      loading: loading,
      onPressed: () =>
          ref.read(recordingPlayerProvider.notifier).toggle(candidate),
    );
  }
}

/// A solid primary disc with a circular ripple and no pressed overlay.
class _PlayButton extends StatelessWidget {
  const _PlayButton({
    required this.playing,
    required this.loading,
    required this.onPressed,
    required this.size,
  });

  final bool playing;
  final bool loading;
  final VoidCallback onPressed;
  final double size;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    return Semantics(
      button: true,
      label: playing ? 'Pause recording' : 'Play recording',
      excludeSemantics: true,
      child: SizedBox(
        width: size,
        height: size,
        child: Material(
          color: z.primary,
          shape: const CircleBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkResponse(
            onTap: onPressed,
            containedInkWell: true,
            customBorder: const CircleBorder(),
            highlightColor: Colors.transparent,
            splashColor: z.onPrimary.withValues(alpha: 0.16),
            child: Center(
              child: loading
                  ? SizedBox(
                      width: size * 0.4,
                      height: size * 0.4,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: z.onPrimary,
                      ),
                    )
                  : Icon(
                      playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                      color: z.onPrimary,
                      size: size * 0.5,
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Time extends StatelessWidget {
  const _Time(this.text, {this.emphasised = false});

  final String text;
  final bool emphasised;

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: AppType.tabular(AppType.caption).copyWith(
      color: emphasised ? context.z.ink2 : context.z.ink3,
    ),
  );
}

class _PlaybackError extends StatelessWidget {
  const _PlaybackError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => InfoBanner(
    message: message,
    tone: BannerTone.danger,
    action: ZButton(
      label: 'Retry',
      variant: ZButtonVariant.text,
      size: ZButtonSize.small,
      expand: false,
      onPressed: onRetry,
    ),
  );
}
