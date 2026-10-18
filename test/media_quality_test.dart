import 'package:PiliPlus/models/common/video/audio_quality.dart';
import 'package:PiliPlus/models/common/video/video_quality.dart';
import 'package:PiliPlus/models/video/play/url.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('VideoQuality.fromCode', () {
    test('resolves every known code exactly', () {
      for (final q in VideoQuality.values) {
        expect(VideoQuality.fromCode(q.code), q);
      }
    });
    test('bangumi super-resolution id 100 resolves exactly', () {
      // qn=100 智能修复 (VIP-only tiers on popular bangumi); missing it
      // crashed VideoItem.fromJson with a null-check error.
      expect(VideoQuality.fromCode(100), VideoQuality.superResolution);
    });
    test('unknown high code falls back to nearest tier below', () {
      // e.g. a future VIP-only id above 8K
      expect(VideoQuality.fromCode(130), VideoQuality.hdrVivid);
    });
    test('unknown low code falls back to lowest tier', () {
      expect(VideoQuality.fromCode(0), VideoQuality.speed240);
    });
  });
  group('AudioQuality.fromCode', () {
    test('resolves every known code exactly', () {
      for (final q in AudioQuality.values) {
        expect(AudioQuality.fromCode(q.code), q);
      }
    });
    test('unknown code falls back instead of throwing', () {
      expect(AudioQuality.fromCode(99999).code, lessThanOrEqualTo(99999));
    });
  });
  group('VideoItem.fromJson', () {
    test('bangumi super-resolution stream parses', () {
      final item = VideoItem.fromJson({
        'id': 100,
        'baseUrl': 'https://example.com/v.m4s',
        'mimeType': 'video/mp4',
        'codecs': 'hev1.1.6.L120.90',
      });
      expect(item.quality, VideoQuality.superResolution);
    });
    test('future unknown dash stream id still parses via fallback', () {
      final item = VideoItem.fromJson({
        'id': 130,
        'baseUrl': 'https://example.com/v.m4s',
        'mimeType': 'video/mp4',
        'codecs': 'hev1.1.6.L120.90',
      });
      expect(item.quality, VideoQuality.hdrVivid);
    });
  });
}
