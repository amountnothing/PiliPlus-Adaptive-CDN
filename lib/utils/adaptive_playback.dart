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
