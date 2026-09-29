import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:flutter/foundation.dart';

/// Seam for tests: records enable/disable instead of touching the plugin.
abstract interface class WakelockGateway {
  Future<void> enable();
  Future<void> disable();
}

/// Holds the screen wakelock while the user requested playback, deduplicating
/// consecutive identical states so repeated player events do not toggle the
/// plugin back and forth.
class WakelockHoldManager {
  WakelockHoldManager(this.gateway);

  final WakelockGateway gateway;
  bool? _lastHold;

  Future<void> sync({
    required bool playbackRequested,
    bool isInBackground = false,
    bool continuePlayInBackground = false,
    bool onlyPlayAudio = false,
  }) async {
    final hold = AdaptivePlayback.shouldHoldWakelock(
      playbackRequested: playbackRequested,
      isInBackground: isInBackground,
      continuePlayInBackground: continuePlayInBackground,
      onlyPlayAudio: onlyPlayAudio,
    );
    if (hold == _lastHold) return;
    _lastHold = hold;
    if (hold) {
      await gateway.enable();
    } else {
      await gateway.disable();
    }
  }

  /// Unconditional release used on dispose.
  Future<void> forceDisable() async {
    _lastHold = false;
    await gateway.disable();
  }
}

abstract final class AdaptivePlayback {
  static const endOfMediaTolerance = Duration(seconds: 5);
  static const endOfBufferTolerance = Duration(seconds: 2);
  // media_kit's buffer stream is broadcast/non-replay. Waiting for `.first`
  // before seek can therefore defer the actual seek for the full timeout.
  static const shouldAwaitBufferUpdateBeforeSeek = false;

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

  static bool shouldStartMediaDuringOpen({
    required bool autoplay,
    required bool playbackRequested,
    required int pauseGenerationAtStart,
    required int currentPauseGeneration,
  }) => shouldAutoplayAfterAsyncOperation(
    autoplay: autoplay,
    playbackRequested: playbackRequested,
    pauseGenerationAtStart: pauseGenerationAtStart,
    currentPauseGeneration: currentPauseGeneration,
  );

  static bool shouldAcceptNativePlayingEvent({
    required bool playbackRequested,
  }) => playbackRequested;

  /// A native `playing` event is optimistic on some media_kit backends: it can
  /// be emitted as soon as the play command is accepted, before a frame or the
  /// media clock advances. Only kick/reopen a source when useful buffered data
  /// already exists and the clock has remained still for the whole window.
  static bool shouldRecoverStalledPlayback({
    required bool playbackRequested,
    required bool temporarilyPaused,
    required bool inBackgroundWithoutPlayback,
    required bool processing,
    required bool completed,
    required Duration startPosition,
    required Duration currentPosition,
    required Duration forwardBuffer,
    required Duration observedFor,
    required Duration timeout,
    Duration minForwardBuffer = const Duration(milliseconds: 500),
    Duration minProgress = const Duration(milliseconds: 500),
  }) {
    final progress = Duration(
      milliseconds: (currentPosition - startPosition).inMilliseconds.abs(),
    );
    return playbackRequested &&
        !temporarilyPaused &&
        !inBackgroundWithoutPlayback &&
        !processing &&
        !completed &&
        progress < minProgress &&
        forwardBuffer >= minForwardBuffer &&
        observedFor >= timeout;
  }

  static bool shouldShowLoading({
    required bool dataLoading,
    required bool playbackRequested,
    required bool isBuffering,
    required bool presentationStalled,
  }) =>
      dataLoading || presentationStalled || (playbackRequested && isBuffering);

  /// The wakelock truth source is the user's playback intent, not transient
  /// native playing events. Audio-only playback never needs the screen;
  /// background playback keeps it only while background playing is allowed.
  static bool shouldHoldWakelock({
    required bool playbackRequested,
    required bool isInBackground,
    required bool continuePlayInBackground,
    required bool onlyPlayAudio,
  }) =>
      playbackRequested &&
      !onlyPlayAudio &&
      (!isInBackground || continuePlayInBackground);

  /// True when the sliding window contains at least [minStalls] rebuffer
  /// onsets totalling at least [minTotalStall] of buffering time. Stalls that
  /// started before `now - window` are ignored. [stallStarts] and
  /// [stallDurations] are parallel lists; entries without a matching duration
  /// contribute zero time.
  ///
  /// A stall is recorded from isBuffering false→true events only, never from
  /// the forward buffer amount, so the low-latency (4s) queue cannot create
  /// phantom stalls.
  static bool shouldSwitchForFragmentedStalls({
    required List<DateTime> stallStarts,
    required List<Duration> stallDurations,
    required DateTime now,
    required Duration window,
    required int minStalls,
    required Duration minTotalStall,
  }) {
    final windowStart = now.subtract(window);
    var count = 0;
    var total = Duration.zero;
    for (var i = 0; i < stallStarts.length; i++) {
      final start = stallStarts[i];
      if (start.isBefore(windowStart)) continue;
      count += 1;
      if (i < stallDurations.length) {
        total += stallDurations[i];
      }
    }
    return count >= minStalls && total >= minTotalStall;
  }

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

  /// MPV can briefly report zero (or an earlier keyframe) after opening a
  /// media item with a non-zero start position. Keep the requested position
  /// authoritative until the native clock has reached that neighbourhood, so
  /// an early CDN rebuild cannot turn the transient value into a new start.
  static Duration protectPendingResumePosition({
    required Duration reported,
    required Duration? pending,
    Duration confirmationTolerance = const Duration(seconds: 5),
  }) {
    if (pending == null || pending <= Duration.zero) return reported;
    if (reported <= Duration.zero) return pending;
    final confirmationThreshold = pending > confirmationTolerance
        ? pending - confirmationTolerance
        : Duration.zero;
    return reported < confirmationThreshold ? pending : reported;
  }

  static bool hasConfirmedPendingResume({
    required Duration reported,
    required Duration? pending,
    Duration confirmationTolerance = const Duration(seconds: 5),
  }) {
    if (pending == null || pending <= Duration.zero) return true;
    if (reported <= Duration.zero) return false;
    final confirmationThreshold = pending > confirmationTolerance
        ? pending - confirmationTolerance
        : Duration.zero;
    return reported >= confirmationThreshold;
  }

  static bool shouldSwitchForStalledBuffer({
    required Duration forwardBuffer,
    required Duration refillThreshold,
    required Duration observedFor,
    required Duration observationWindow,
    required Duration bufferGrowth,
    required Duration minGrowth,
    Duration playbackProgress = Duration.zero,
  }) =>
      forwardBuffer <= refillThreshold &&
      observedFor >= observationWindow &&
      bufferGrowth < minGrowth &&
      // A byte-limited queue can stay below the time-based refill line while
      // CDN delivery keeps pace with playback. Flat is not stalled then.
      !(forwardBuffer > Duration.zero &&
          playbackProgress >= const Duration(seconds: 1) &&
          bufferGrowth >= const Duration(milliseconds: -250));

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
