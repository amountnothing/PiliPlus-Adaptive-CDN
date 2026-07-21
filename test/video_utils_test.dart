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
    test('treats a fully buffered media tail as complete', () {
      expect(
        AdaptivePlayback.hasReachedContentEnd(
          duration: const Duration(seconds: 100),
          position: const Duration(seconds: 80),
          buffered: const Duration(seconds: 100),
        ),
        isTrue,
      );
    });

    test('allows small segment and duration drift at the tail', () {
      expect(
        AdaptivePlayback.hasReachedContentEnd(
          duration: const Duration(seconds: 100),
          position: const Duration(seconds: 98),
          buffered: const Duration(milliseconds: 98500),
        ),
        isTrue,
      );
    });

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
  });

  group('AdaptivePlayback.shouldAccumulateCdnStall', () {
    test('ignores a stale buffering flag after a manual pause', () {
      expect(
        AdaptivePlayback.shouldAccumulateCdnStall(
          playbackRequested: false,
        ),
        isFalse,
      );
    });

    test('monitors an actively playing video', () {
      expect(
        AdaptivePlayback.shouldAccumulateCdnStall(
          playbackRequested: true,
        ),
        isTrue,
      );
    });
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

  group('AdaptivePlayback.shouldRecoverFrozenTrack', () {
    test('detects video pts stuck while playback and buffer advance', () {
      expect(
        AdaptivePlayback.shouldRecoverFrozenTrack(
          trackPts: const Duration(seconds: 12),
          lastTrackPts: const Duration(seconds: 12),
          position: const Duration(seconds: 40),
          lastPlaybackPosition: const Duration(seconds: 39),
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
        position: Duration(seconds: 40),
        lastPlaybackPosition: Duration(seconds: 39),
        forwardBuffer: Duration(seconds: 25),
        minForwardBuffer: Duration(seconds: 10),
        noFrameProgressFor: Duration(seconds: 9),
        freezeTimeout: Duration(seconds: 8),
      );

      expect(
        AdaptivePlayback.shouldRecoverFrozenTrack(
          trackPts: args.videoPts,
          lastTrackPts: args.lastVideoPts,
          position: args.position,
          lastPlaybackPosition: args.lastPlaybackPosition,
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
          position: args.position,
          lastPlaybackPosition: args.lastPlaybackPosition,
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
          position: args.position,
          lastPlaybackPosition: args.lastPlaybackPosition,
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
  });
}
