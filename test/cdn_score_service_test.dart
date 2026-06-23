import 'package:PiliPlus/services/cdn_score_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const first = 'https://cdn-a.example/video.m4s';
  const second = 'https://cdn-b.example/video.m4s';

  setUp(CdnScoreService.resetMemoryForTest);
  tearDown(CdnScoreService.resetMemoryForTest);

  test('new CDN candidates keep their original order at equal scores', () {
    expect(CdnScoreService.rankCandidates(const [first, second]), [
      first,
      second,
    ]);
  });

  test('a failed CDN is immediately demoted below an untested CDN', () {
    CdnScoreService.recordFailure(first);

    expect(CdnScoreService.rankCandidates(const [first, second]), [
      second,
      first,
    ]);
    expect(CdnScoreService.entryForUrl(first).failures, 1);
  });

  test('stable high-throughput transfers improve a CDN score gradually', () {
    CdnScoreService.recordSuccess(
      first,
      bytes: 4 * 1024 * 1024,
      networkWait: const Duration(seconds: 1),
    );

    final entry = CdnScoreService.entryForUrl(first);
    expect(entry.score, greaterThan(50));
    expect(entry.successes, 1);
    expect(entry.ewmaMbps, greaterThan(30));
  });
}
