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
  /// timers must require both playback intent and an actually playing player.
  static bool shouldAccumulateCdnStall({
    required bool playbackRequested,
    required bool isPlaying,
  }) => playbackRequested && isPlaying;

  static bool shouldShowLoading({
    required bool dataLoading,
    required bool playbackRequested,
    required bool isBuffering,
    required bool presentationStalled,
  }) =>
      dataLoading || presentationStalled || (playbackRequested && isBuffering);

  static Duration? rebuildResumePosition({
    required int? checkpointCid,
    required int? targetCid,
    required Duration? checkpoint,
    required Duration? requested,
  }) =>
      checkpointCid == targetCid &&
          checkpoint != null &&
          checkpoint > Duration.zero
      ? checkpoint
      : requested;

  static bool shouldSwitchForStalledBuffer({
    required Duration forwardBuffer,
    required Duration refillThreshold,
    required Duration observedFor,
    required Duration observationWindow,
    required Duration bufferGrowth,
    required Duration minGrowth,
  }) =>
      forwardBuffer <= refillThreshold &&
      observedFor >= observationWindow &&
      bufferGrowth < minGrowth;

  static bool isExpectedRelayInterruptionError(String event) {
    final lower = event.toLowerCase();
    return lower.contains('stream ends prematurely') ||
        (lower.contains('seek failed') && lower.contains('size -'));
  }

  static bool shouldRecoverFrozenTrack({
    required Duration? trackPts,
    required Duration? lastTrackPts,
    required Duration forwardBuffer,
    required Duration minForwardBuffer,
    required Duration noFrameProgressFor,
    required Duration freezeTimeout,
    required bool isPlaying,
    required bool trackExpected,
  }) {
    if (!isPlaying ||
        !trackExpected ||
        trackPts == null ||
        lastTrackPts == null) {
      return false;
    }
    if (forwardBuffer < minForwardBuffer) return false;

    final trackAdvanced =
        trackPts - lastTrackPts >= const Duration(milliseconds: 250);
    return !trackAdvanced && noFrameProgressFor >= freezeTimeout;
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
