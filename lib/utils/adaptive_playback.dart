import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:flutter/foundation.dart';

abstract final class AdaptivePlayback {
  static const endOfMediaTolerance = Duration(seconds: 5);
  static const endOfBufferTolerance = Duration(seconds: 2);

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
    required bool temporarilyPaused,
    required bool hasStartedPlayback,
  }) => playbackRequested && !temporarilyPaused && hasStartedPlayback;

  static bool shouldRecoverPlayerError({
    required bool playbackRequested,
    required bool onlyPlayAudio,
    required bool isLocalRelayFailure,
  }) => playbackRequested && (isLocalRelayFailure || !onlyPlayAudio);

  static bool shouldAutoplayAfterAsyncOperation({
    required bool autoplay,
    required bool playbackRequested,
    required int pauseGenerationAtStart,
    required int currentPauseGeneration,
  }) =>
      autoplay &&
      playbackRequested &&
      pauseGenerationAtStart == currentPauseGeneration;

  static bool shouldAcceptNativePlayingEvent({
    required bool playbackRequested,
  }) => playbackRequested;

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

  static bool isVideoBitstreamCorruption(String event) {
    final lower = event.toLowerCase();
    return lower.contains('invalid obu length') ||
        (lower.contains('invalid obu') &&
            lower.contains('fragment too short')) ||
        lower.contains('failed to parse temporal unit') ||
        lower.contains('zero_bit out of range') ||
        lower.contains('invalid nal unit size') ||
        lower.contains('missing picture in access unit') ||
        lower.contains('failed to recognize file format');
  }

  static bool isUnrecognizedFormat(String event) =>
      event.toLowerCase().contains('failed to recognize file format');

  static bool isLoopbackRelayConnectionFailure(String event) {
    final lower = event.toLowerCase();
    final targetsLoopback =
        lower.contains('tcp://127.0.0.1:') ||
        lower.contains('tcp://localhost:');
    return targetsLoopback &&
        (lower.contains('failed') || lower.contains('timed out'));
  }

  static bool isDetachedAudioPadNoise(String event) {
    final lower = event.toLowerCase();
    return lower.contains('pad aid') && lower.contains('not connected');
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
    bool peerTrackAdvanced = false,
  }) {
    if (!isPlaying || !trackExpected) {
      return false;
    }
    // Some MPV/device combinations do not expose one of these properties at
    // all. A missing initial PTS therefore cannot prove that a track froze;
    // only recover after that track has produced at least one valid sample.
    if (trackPts == null) return false;
    if (lastTrackPts == null) return false;
    // Low buffer normally means a network stall, not a decoder/PTS freeze.
    // If the other track is still advancing, however, the split is proven and
    // both tracks must be recovered together even after a brief outage.
    if (forwardBuffer < minForwardBuffer && !peerTrackAdvanced) return false;

    final trackAdvanced =
        trackPts - lastTrackPts >= const Duration(milliseconds: 250);
    return !trackAdvanced && noFrameProgressFor >= freezeTimeout;
  }

  /// Whether playback itself has reached the media tail.
  ///
  /// A fully downloaded buffer is not completion: after seeking backwards the
  /// buffer can still end at [duration] while [position] is near the start.
  static bool hasReachedContentEnd({
    required Duration duration,
    required Duration position,
    required Duration buffered,
    Duration tolerance = endOfMediaTolerance,
    Duration bufferTolerance = endOfBufferTolerance,
  }) {
    if (duration <= Duration.zero) return false;
    final durationMs = duration.inMilliseconds;
    final scaledToleranceMs = durationMs ~/ 10;
    final positionToleranceMs = scaledToleranceMs
        .clamp(250, tolerance.inMilliseconds)
        .toInt();
    final effectiveBufferToleranceMs = scaledToleranceMs
        .clamp(250, bufferTolerance.inMilliseconds)
        .toInt();
    return position + Duration(milliseconds: positionToleranceMs) >= duration &&
        buffered + Duration(milliseconds: effectiveBufferToleranceMs) >=
            duration;
  }
}
