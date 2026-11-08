import 'package:PiliPlus/models/common/video/base_quality.dart';
import 'package:PiliPlus/models/video/play/url.dart';
import 'package:flutter_test/flutter_test.dart';

// Regression guard for the 2026-10-18 bangumi crash: Bilibili ships new
// quality ids without notice (qn=100 智能修复). Since upstream's quality
// refactor, unknown ids become a dynamic quality instead of throwing.
void main() {
  group('VideoQuality.fromCode', () {
    test('resolves every known code exactly', () {
      for (final q in VideoQuality.values) {
        expect(VideoQuality.fromCode(q.code), q);
      }
    });
    test('bangumi super-resolution id 100 resolves exactly', () {
      expect(VideoQuality.fromCode(100), VideoQuality.superResolution);
    });
    test('unknown code does not throw and keeps its id', () {
      final q = VideoQuality.fromCode(130);
      expect(q.code, 130);
      expect(VideoQuality.safeFromCode(130), isNull);
    });
  });
  group('AudioQuality.fromCode', () {
    test('resolves every known code exactly', () {
      for (final q in AudioQuality.values) {
        expect(AudioQuality.fromCode(q.code), q);
      }
    });
    test('unknown code does not throw', () {
      expect(AudioQuality.fromCode(99999).code, 99999);
    });
  });
  group('VideoItem.fromJson', () {
    Map<String, dynamic> stream(int id) => {
      'id': id,
      'baseUrl': 'https://example.com/v.m4s',
      'mimeType': 'video/mp4',
      'codecs': 'hev1.1.6.L120.90',
    };
    test('bangumi super-resolution stream parses', () {
      final item = VideoItem.fromJson(stream(100), null);
      expect(item.quality, VideoQuality.superResolution);
    });
    test('future unknown dash stream id still parses', () {
      final item = VideoItem.fromJson(stream(130), null);
      expect(item.quality.code, 130);
    });
  });
}
