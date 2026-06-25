import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:flutter/foundation.dart';

abstract final class AdaptivePlayback {
  static const endOfMediaTolerance = Duration(seconds: 2);

  static final ValueNotifier<bool> enabled = ValueNotifier(
    Pref.adaptivePlayback,
  );
  static final ValueNotifier<bool> manualControlsEnabled = ValueNotifier(
    !Pref.adaptivePlayback,
  );

  static void setEnabled(bool value) {
    enabled.value = value;
    manualControlsEnabled.value = !value;
  }

  /// Buffering can remain true briefly after a manual pause. CDN health
  /// timers must follow the user's playback intent instead of that stale flag.
  static bool shouldAccumulateCdnStall({
    required bool isPlaying,
    required bool isBuffering,
  }) => isPlaying;

  static bool shouldRecoverFrozenVideo({
    required Duration? videoPts,
    required Duration? lastVideoPts,
    required Duration position,
    required Duration lastPlaybackPosition,
    required Duration forwardBuffer,
    required Duration minForwardBuffer,
    required Duration noFrameProgressFor,
    required Duration freezeTimeout,
    required bool isPlaying,
    required bool isOnlyAudio,
  }) {
    if (!isPlaying || isOnlyAudio || videoPts == null || lastVideoPts == null) {
      return false;
    }
    if (forwardBuffer < minForwardBuffer) return false;

    final playbackAdvanced =
        (position - lastPlaybackPosition).inMilliseconds.abs() >= 250;
    final videoAdvanced =
        videoPts - lastVideoPts >= const Duration(milliseconds: 250);
    return playbackAdvanced &&
        !videoAdvanced &&
        noFrameProgressFor >= freezeTimeout;
  }

  /// Whether the player has already downloaded or reached the media tail.
  /// A small tolerance covers container duration and segment boundary drift.
  static bool hasReachedContentEnd({
    required Duration duration,
    required Duration position,
    required Duration buffered,
    Duration tolerance = endOfMediaTolerance,
  }) {
    if (duration <= Duration.zero) return false;
    final contentEdge = buffered > position ? buffered : position;
    return contentEdge + tolerance >= duration;
  }
}
