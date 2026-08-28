import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';

import '../../call_tracking/data/call_feed.dart';
import '../domain/recording_matcher.dart';

/// What the player is doing, as one value the UI can render without reaching
/// into three separate streams.
class PlaybackState {
  const PlaybackState({
    this.mediaStoreId,
    this.playing = false,
    this.loading = false,
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.speed = 1.0,
    this.error,
  });

  /// Which recording is loaded. Null when nothing has been played yet.
  final int? mediaStoreId;

  final bool playing;

  /// True between the tap and the first frame of audio — opening a MediaStore
  /// URI is not instant on a cold cache.
  final bool loading;

  final Duration position;
  final Duration duration;
  final double speed;

  /// Set when the file could not be opened. The commonest cause by far is that
  /// the dialer has since deleted its own recording, which is why the message
  /// says that rather than showing a platform error code.
  final String? error;

  bool isFor(int id) => mediaStoreId == id;
  bool isPlaying(int id) => isFor(id) && playing;
  bool isLoading(int id) => isFor(id) && loading;

  /// 0..1, safe when duration is not yet known.
  double get progress {
    if (duration.inMilliseconds <= 0) return 0;
    return (position.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0);
  }

  PlaybackState copyWith({
    int? mediaStoreId,
    bool? playing,
    bool? loading,
    Duration? position,
    Duration? duration,
    double? speed,
    String? error,
    bool clearError = false,
  }) => PlaybackState(
    mediaStoreId: mediaStoreId ?? this.mediaStoreId,
    playing: playing ?? this.playing,
    loading: loading ?? this.loading,
    position: position ?? this.position,
    duration: duration ?? this.duration,
    speed: speed ?? this.speed,
    error: clearError ? null : (error ?? this.error),
  );
}

/// Plays the recordings the device's own dialer made.
///
/// One player for the whole app, deliberately: starting a second recording must
/// stop the first, and a detail screen left in the background must not keep
/// audio running. Riverpod disposes it with the provider, so a screen cannot
/// leak a player.
///
/// Audio is streamed straight from the MediaStore `content://` URI. Nothing is
/// copied to app storage — the app is not entitled to a second copy of a call
/// recording, and a temp file would outlive the screen that made it.
class RecordingPlayer extends Notifier<PlaybackState> {
  AudioPlayer? _player;
  final _subscriptions = <StreamSubscription<Object?>>[];

  @override
  PlaybackState build() {
    ref.onDispose(_disposePlayer);
    return const PlaybackState();
  }

  AudioPlayer _ensurePlayer() {
    final existing = _player;
    if (existing != null) return existing;

    final player = AudioPlayer();
    _player = player;

    _subscriptions.addAll([
      player.positionStream.listen((p) {
        state = state.copyWith(position: p);
      }),
      player.durationStream.listen((d) {
        // MediaStore's DURATION column and the container's real duration
        // disagree on some OEM recorders; the decoded value wins because it is
        // what the scrubber is actually seeking within.
        if (d != null) state = state.copyWith(duration: d);
      }),
      player.playerStateStream.listen((s) {
        final finished = s.processingState == ProcessingState.completed;
        state = state.copyWith(
          playing: s.playing && !finished,
          loading:
              s.processingState == ProcessingState.loading ||
              s.processingState == ProcessingState.buffering,
        );
        if (finished) _rewind();
      }),
    ]);

    return player;
  }

  Future<void> _rewind() async {
    // Leaving the head at the end means the next tap plays nothing, which
    // reads as a broken player.
    await _player?.seek(Duration.zero);
    await _player?.pause();
    state = state.copyWith(position: Duration.zero, playing: false);
  }

  /// Plays [candidate], replacing whatever was loaded before.
  ///
  /// Tapping the recording that is already playing pauses it; tapping a paused
  /// one resumes from where it stopped.
  Future<void> toggle(RecordingCandidate candidate) async {
    final player = _ensurePlayer();

    if (state.isFor(candidate.mediaStoreId) && state.error == null) {
      if (state.playing) {
        await player.pause();
      } else {
        await player.play();
      }
      return;
    }

    state = PlaybackState(
      mediaStoreId: candidate.mediaStoreId,
      loading: true,
      speed: state.speed,
      // The scanned duration is shown immediately so the scrubber has a scale
      // before the decoder reports the real one.
      duration: Duration(milliseconds: candidate.durationMillis),
    );

    try {
      final uri = await ref
          .read(nativeBridgeProvider)
          .getRecordingUri(candidate.mediaStoreId);

      await player.setUrl(uri);
      await player.setSpeed(state.speed);
      await player.play();
    } on Object {
      state = state.copyWith(
        loading: false,
        playing: false,
        error:
            'This recording could not be opened. Your phone may have deleted '
            'it, or moved it somewhere the app cannot read.',
      );
    }
  }

  Future<void> pause() async {
    await _player?.pause();
  }

  Future<void> seek(Duration to) async {
    // Optimistic, so dragging the scrubber tracks the thumb instead of
    // snapping back while the decoder catches up.
    state = state.copyWith(position: to);
    await _player?.seek(to);
  }

  /// Cycles 1x → 1.5x → 2x → 1x. Staff scrubbing a long call want this more
  /// than they want a slider.
  Future<void> cycleSpeed() async {
    final next = switch (state.speed) {
      1.0 => 1.5,
      1.5 => 2.0,
      _ => 1.0,
    };
    state = state.copyWith(speed: next);
    await _player?.setSpeed(next);
  }

  /// Stops and unloads. Called when a detail screen goes away, so audio never
  /// outlives the screen that started it.
  Future<void> stop() async {
    await _player?.stop();
    state = PlaybackState(speed: state.speed);
  }

  void _disposePlayer() {
    for (final s in _subscriptions) {
      s.cancel();
    }
    _subscriptions.clear();
    _player?.dispose();
    _player = null;
  }
}

final recordingPlayerProvider = NotifierProvider<RecordingPlayer, PlaybackState>(
  RecordingPlayer.new,
);
