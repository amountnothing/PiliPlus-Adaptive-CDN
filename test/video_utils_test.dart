import 'package:PiliPlus/models/common/video/cdn_type.dart';
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

    test('builds a small unique candidate pool', () {
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
      expect(candidates.toSet(), hasLength(candidates.length));
    });

    test('temporarily cools down a failed CDN host', () {
      const failed = 'https://cdn-cooldown-test.invalid/upgcxcode/video.m4s';

      VideoUtils.markCdnFailed(failed, cooldown: const Duration(seconds: 30));

      expect(VideoUtils.isCdnCoolingDown(failed), isTrue);
    });
  });
}
