import 'package:PiliPlus/models/common/video/cdn_type.dart';
import 'package:PiliPlus/utils/adaptive_playback.dart';
import 'package:PiliPlus/utils/video_utils.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('VideoUtils.getCdnUrl', () {
    const base =
        'https://example.mcdn.bilivideo.com/v1/resource/video.m4s?foo=bar';
    const backup =
        'https://upos-sz-mirrorcos.bilivideo.com/upgcxcode/video.m4s?foo=bar';

    test('prefers a backup URL and rewrites it to the Ali mirror', () {
      final result = VideoUtils.getCdnUrl(
        const [base, backup],
        defaultCDNService: CDNService.ali,
        preferBackup: true,
      );

      expect(
        result,
        'https://upos-sz-mirrorali.bilivideo.com/upgcxcode/video.m4s?foo=bar',
      );
    });

    test('keeps the API base URL when explicitly requested', () {
      final result = VideoUtils.getCdnUrl(
        const [base, backup],
        defaultCDNService: CDNService.baseUrl,
      );

      expect(result, base);
    });

    test('proxies an mcdn URL when it is the only candidate', () {
      final result = VideoUtils.getCdnUrl(
        const [base],
        defaultCDNService: CDNService.ali,
      );

      final uri = Uri.parse(result);
      expect(uri.host, 'proxy-tf-all-ws.bilivideo.com');
      expect(uri.queryParameters['url'], base);
    });

    test('handles an empty candidate list', () {
      expect(
        VideoUtils.getCdnUrl(
          const [],
          defaultCDNService: CDNService.ali,
        ),
        isEmpty,
      );
    });

    test('builds a unique candidate pool from every known fixed CDN', () {
      final candidates = VideoUtils.getCdnCandidates(
        const [base, backup],
        preferredService: CDNService.ali,
      );

      expect(candidates, contains(base));
      expect(candidates, contains(backup));
      expect(
        candidates,
        contains(
          'https://upos-sz-mirrorali.bilivideo.com/upgcxcode/video.m4s?foo=bar',
        ),
      );
      expect(
        candidates,
        contains(
          'https://upos-sz-mirrorcosov.bilivideo.com/upgcxcode/video.m4s?foo=bar',
        ),
      );
      expect(
        candidates.where((url) => url.contains('/upgcxcode/')),
        hasLength(
          CDNService.values.where((service) => service.host != null).length,
        ),
      );
      expect(candidates.toSet(), hasLength(candidates.length));
    });

    test('temporarily cools down a failed CDN host', () {
      const failed = 'https://cdn-cooldown-test.invalid/upgcxcode/video.m4s';

      VideoUtils.markCdnFailed(failed, cooldown: const Duration(seconds: 30));

      expect(VideoUtils.isCdnCoolingDown(failed), isTrue);
    });
  });

  group('AdaptivePlayback.hasReachedContentEnd', () {
    test('does not treat a fully buffered seek target as complete', () {
      expect(
        AdaptivePlayback.hasReachedContentEnd(
          duration: const Duration(seconds: 100),
          position: const Duration(seconds: 80),
          buffered: const Duration(seconds: 100),
        ),
        isFalse,
      );
    });

    test('allows small segment and duration drift at the tail', () {
      expect(
        AdaptivePlayback.hasReachedContentEnd(
          duration: const Duration(seconds: 100),
          position: const Duration(milliseconds: 99800),
          buffered: const Duration(seconds: 100),
        ),
        isTrue,
      );
    });

    test('does not switch CDN while the final segment is playing', () {
      expect(
        AdaptivePlayback.hasReachedContentEnd(
          duration: const Duration(seconds: 100),
          position: const Duration(seconds: 96),
          buffered: const Duration(seconds: 98),
        ),
        isTrue,
      );
    });

    test('still recovers when the final segment has not been downloaded', () {
      expect(
        AdaptivePlayback.hasReachedContentEnd(
          duration: const Duration(seconds: 100),
          position: const Duration(seconds: 96),
          buffered: const Duration(seconds: 96),
        ),
        isFalse,
      );
    });

    test(
      'allows playback after seeking to the start of a fully buffered file',
      () {
        expect(
          AdaptivePlayback.hasReachedContentEnd(
            duration: const Duration(seconds: 100),
            position: Duration.zero,
            buffered: const Duration(seconds: 100),
          ),
          isFalse,
        );
      },
    );

    test('does not hide a real stall before the media tail', () {
      expect(
        AdaptivePlayback.hasReachedContentEnd(
          duration: const Duration(seconds: 100),
          position: const Duration(seconds: 90),
          buffered: const Duration(seconds: 91),
        ),
        isFalse,
      );
    });

    test('does not infer completion when duration is unknown', () {
      expect(
        AdaptivePlayback.hasReachedContentEnd(
          duration: Duration.zero,
          position: const Duration(seconds: 100),
          buffered: const Duration(seconds: 100),
        ),
        isFalse,
      );
    });

    test('does not treat the start of a short video as its tail', () {
      expect(
        AdaptivePlayback.hasReachedContentEnd(
          duration: const Duration(seconds: 4),
          position: Duration.zero,
          buffered: const Duration(seconds: 4),
        ),
        isFalse,
      );
      expect(
        AdaptivePlayback.hasReachedContentEnd(
          duration: const Duration(seconds: 4),
          position: const Duration(milliseconds: 3700),
          buffered: const Duration(seconds: 4),
        ),
        isTrue,
      );
    });
  });

  group('AdaptivePlayback.shouldAccumulateCdnStall', () {
    test('ignores a stale buffering flag after an explicit pause', () {
      expect(
        AdaptivePlayback.shouldAccumulateCdnStall(
          playbackRequested: false,
          temporarilyPaused: false,
          hasStartedPlayback: true,
        ),
        isFalse,
      );
    });

    test('monitors playback intent even when native playing turns false', () {
      expect(
        AdaptivePlayback.shouldAccumulateCdnStall(
          playbackRequested: true,
          temporarilyPaused: false,
          hasStartedPlayback: true,
        ),
        isTrue,
      );
    });

    test('ignores a lifecycle or audio-focus pause', () {
      expect(
        AdaptivePlayback.shouldAccumulateCdnStall(
          playbackRequested: true,
          temporarilyPaused: true,
          hasStartedPlayback: true,
        ),
        isFalse,
      );
    });

    test('does not monitor before the current media has actually started', () {
      expect(
        AdaptivePlayback.shouldAccumulateCdnStall(
          playbackRequested: true,
          temporarilyPaused: false,
          hasStartedPlayback: false,
        ),
        isFalse,
      );
    });
  });

  test('recoverable player errors respect playback intent', () {
    expect(
      AdaptivePlayback.shouldRecoverPlayerError(
        playbackRequested: true,
        onlyPlayAudio: false,
        isLocalRelayFailure: false,
      ),
      isTrue,
    );
    expect(
      AdaptivePlayback.shouldRecoverPlayerError(
        playbackRequested: false,
        onlyPlayAudio: false,
        isLocalRelayFailure: false,
      ),
      isFalse,
    );
    expect(
      AdaptivePlayback.shouldRecoverPlayerError(
        playbackRequested: false,
        onlyPlayAudio: true,
        isLocalRelayFailure: true,
      ),
      isFalse,
    );
  });

  test('async recovery cannot override a later manual pause', () {
    expect(
      AdaptivePlayback.shouldAutoplayAfterAsyncOperation(
        autoplay: true,
        playbackRequested: true,
        pauseGenerationAtStart: 4,
        currentPauseGeneration: 4,
      ),
      isTrue,
    );
    expect(
      AdaptivePlayback.shouldAutoplayAfterAsyncOperation(
        autoplay: true,
        playbackRequested: false,
        pauseGenerationAtStart: 4,
        currentPauseGeneration: 5,
      ),
      isFalse,
    );
    expect(
      AdaptivePlayback.shouldAutoplayAfterAsyncOperation(
        autoplay: true,
        playbackRequested: true,
        pauseGenerationAtStart: 4,
        currentPauseGeneration: 5,
      ),
      isFalse,
    );
  });

  test('late native playing events cannot override a manual pause', () {
    expect(
      AdaptivePlayback.shouldAcceptNativePlayingEvent(
        playbackRequested: true,
      ),
      isTrue,
    );
    expect(
      AdaptivePlayback.shouldAcceptNativePlayingEvent(
        playbackRequested: false,
      ),
      isFalse,
    );
  });

  test('recognizes relay startup format errors separately', () {
    const message = 'Failed to recognize file format.';
    expect(AdaptivePlayback.isUnrecognizedFormat(message), isTrue);
    expect(AdaptivePlayback.isVideoBitstreamCorruption(message), isTrue);
  });

  test('loading follows playback intent and presentation state', () {
    expect(
      AdaptivePlayback.shouldShowLoading(
        dataLoading: false,
        playbackRequested: false,
        isBuffering: true,
        presentationStalled: false,
      ),
      isFalse,
    );
    expect(
      AdaptivePlayback.shouldShowLoading(
        dataLoading: false,
        playbackRequested: true,
        isBuffering: true,
        presentationStalled: false,
      ),
      isTrue,
    );
    expect(
      AdaptivePlayback.shouldShowLoading(
        dataLoading: false,
        playbackRequested: true,
        isBuffering: false,
        presentationStalled: true,
      ),
      isTrue,
    );
  });

  test('player rebuild resumes only from the same media checkpoint', () {
    expect(
      AdaptivePlayback.rebuildResumePosition(
        checkpointCid: 1,
        targetCid: 1,
        checkpoint: const Duration(seconds: 42),
        requested: const Duration(seconds: 10),
      ),
      const Duration(seconds: 42),
    );
    expect(
      AdaptivePlayback.rebuildResumePosition(
        checkpointCid: 1,
        targetCid: 2,
        checkpoint: const Duration(seconds: 42),
        requested: const Duration(seconds: 10),
      ),
      const Duration(seconds: 10),
    );
    expect(
      AdaptivePlayback.rebuildResumePosition(
        checkpointCid: 1,
        targetCid: 1,
        checkpoint: Duration.zero,
        requested: const Duration(seconds: 42),
      ),
      const Duration(seconds: 42),
    );
  });

  test('buffer stall requires 5s with less than 1s growth', () {
    const common = (
      forwardBuffer: Duration(seconds: 8),
      refillThreshold: Duration(seconds: 20),
      observationWindow: Duration(seconds: 5),
      minGrowth: Duration(seconds: 1),
    );
    expect(
      AdaptivePlayback.shouldSwitchForStalledBuffer(
        forwardBuffer: common.forwardBuffer,
        refillThreshold: common.refillThreshold,
        observedFor: const Duration(milliseconds: 4999),
        observationWindow: common.observationWindow,
        bufferGrowth: Duration.zero,
        minGrowth: common.minGrowth,
      ),
      isFalse,
    );
    expect(
      AdaptivePlayback.shouldSwitchForStalledBuffer(
        forwardBuffer: common.forwardBuffer,
        refillThreshold: common.refillThreshold,
        observedFor: const Duration(seconds: 5),
        observationWindow: common.observationWindow,
        bufferGrowth: const Duration(milliseconds: 999),
        minGrowth: common.minGrowth,
      ),
      isTrue,
    );
    expect(
      AdaptivePlayback.shouldSwitchForStalledBuffer(
        forwardBuffer: common.forwardBuffer,
        refillThreshold: common.refillThreshold,
        observedFor: const Duration(seconds: 5),
        observationWindow: common.observationWindow,
        bufferGrowth: const Duration(seconds: 1),
        minGrowth: common.minGrowth,
      ),
      isFalse,
    );
  });

  test('recognizes errors caused by closing an old relay response', () {
    expect(
      AdaptivePlayback.isExpectedRelayInterruptionError(
        'http: Stream ends prematurely at 10, should be 20',
      ),
      isTrue,
    );
    expect(
      AdaptivePlayback.isExpectedRelayInterruptionError(
        'Seek failed (to 832836571, size -38)',
      ),
      isTrue,
    );
  });

  test('rebuilds after an empty interrupted response has no file format', () {
    expect(
      AdaptivePlayback.isVideoBitstreamCorruption(
        'Failed to recognize file format.',
      ),
      isTrue,
    );
    expect(
      AdaptivePlayback.isDetachedAudioPadNoise(
        'Pad aid1 is not connected to anything.',
      ),
      isTrue,
    );
    expect(
      AdaptivePlayback.isVideoBitstreamCorruption(
        'NULL: Invalid OBU: fragment too short (1 bytes).',
      ),
      isTrue,
    );
    expect(
      AdaptivePlayback.isVideoBitstreamCorruption(
        'NULL: zero_bit out of range: 1, but must be in [0,0].',
      ),
      isTrue,
    );
    expect(
      AdaptivePlayback.isLoopbackRelayConnectionFailure(
        'tcp: Connection to tcp://127.0.0.1:39169 failed: Connection timed out',
      ),
      isTrue,
    );
  });

  group('AdaptivePlayback.shouldRecoverFrozenTrack', () {
    test('does not infer a freeze from an unavailable audio pts property', () {
      expect(
        AdaptivePlayback.shouldRecoverFrozenTrack(
          trackPts: null,
          lastTrackPts: const Duration(seconds: 12),
          forwardBuffer: const Duration(seconds: 20),
          minForwardBuffer: const Duration(seconds: 10),
          noFrameProgressFor: const Duration(seconds: 8),
          freezeTimeout: const Duration(seconds: 8),
          isPlaying: true,
          trackExpected: true,
          peerTrackAdvanced: true,
        ),
        isFalse,
      );
    });

    test('does not recover while an expected pts has never initialized', () {
      expect(
        AdaptivePlayback.shouldRecoverFrozenTrack(
          trackPts: null,
          lastTrackPts: null,
          forwardBuffer: const Duration(seconds: 20),
          minForwardBuffer: const Duration(seconds: 10),
          noFrameProgressFor: const Duration(seconds: 11),
          freezeTimeout: const Duration(seconds: 8),
          isPlaying: true,
          trackExpected: true,
          peerTrackAdvanced: true,
        ),
        isFalse,
      );
    });

    test('does not recover a missing pts when both tracks are stalled', () {
      expect(
        AdaptivePlayback.shouldRecoverFrozenTrack(
          trackPts: null,
          lastTrackPts: const Duration(seconds: 12),
          forwardBuffer: Duration.zero,
          minForwardBuffer: const Duration(seconds: 10),
          noFrameProgressFor: const Duration(seconds: 20),
          freezeTimeout: const Duration(seconds: 8),
          isPlaying: true,
          trackExpected: true,
        ),
        isFalse,
      );
    });

    test('detects a stuck pts even when the playback clock also stops', () {
      expect(
        AdaptivePlayback.shouldRecoverFrozenTrack(
          trackPts: const Duration(seconds: 12),
          lastTrackPts: const Duration(seconds: 12),
          forwardBuffer: const Duration(seconds: 25),
          minForwardBuffer: const Duration(seconds: 10),
          noFrameProgressFor: const Duration(seconds: 9),
          freezeTimeout: const Duration(seconds: 8),
          isPlaying: true,
          trackExpected: true,
        ),
        isTrue,
      );
    });

    test('does not recover while paused, audio-only, or low buffer', () {
      const args = (
        videoPts: Duration(seconds: 12),
        lastVideoPts: Duration(seconds: 12),
        forwardBuffer: Duration(seconds: 25),
        minForwardBuffer: Duration(seconds: 10),
        noFrameProgressFor: Duration(seconds: 9),
        freezeTimeout: Duration(seconds: 8),
      );

      expect(
        AdaptivePlayback.shouldRecoverFrozenTrack(
          trackPts: args.videoPts,
          lastTrackPts: args.lastVideoPts,
          forwardBuffer: args.forwardBuffer,
          minForwardBuffer: args.minForwardBuffer,
          noFrameProgressFor: args.noFrameProgressFor,
          freezeTimeout: args.freezeTimeout,
          isPlaying: false,
          trackExpected: true,
        ),
        isFalse,
      );
      expect(
        AdaptivePlayback.shouldRecoverFrozenTrack(
          trackPts: args.videoPts,
          lastTrackPts: args.lastVideoPts,
          forwardBuffer: args.forwardBuffer,
          minForwardBuffer: args.minForwardBuffer,
          noFrameProgressFor: args.noFrameProgressFor,
          freezeTimeout: args.freezeTimeout,
          isPlaying: true,
          trackExpected: false,
        ),
        isFalse,
      );
      expect(
        AdaptivePlayback.shouldRecoverFrozenTrack(
          trackPts: args.videoPts,
          lastTrackPts: args.lastVideoPts,
          forwardBuffer: const Duration(seconds: 5),
          minForwardBuffer: args.minForwardBuffer,
          noFrameProgressFor: args.noFrameProgressFor,
          freezeTimeout: args.freezeTimeout,
          isPlaying: true,
          trackExpected: true,
        ),
        isFalse,
      );
    });

    test('recovers a frozen track at low buffer when its peer advances', () {
      expect(
        AdaptivePlayback.shouldRecoverFrozenTrack(
          trackPts: const Duration(seconds: 12),
          lastTrackPts: const Duration(seconds: 12),
          forwardBuffer: const Duration(seconds: 2),
          minForwardBuffer: const Duration(seconds: 10),
          noFrameProgressFor: const Duration(seconds: 9),
          freezeTimeout: const Duration(seconds: 8),
          isPlaying: true,
          trackExpected: true,
          peerTrackAdvanced: true,
        ),
        isTrue,
      );
    });
  });
}
