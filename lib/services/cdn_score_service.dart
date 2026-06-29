import 'dart:async';
import 'dart:math' as math;

import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/video_utils.dart';
import 'package:flutter/foundation.dart';

class CdnScoreEntry {
  const CdnScoreEntry({
    required this.score,
    required this.successes,
    required this.failures,
    required this.ewmaMbps,
  });

  static const initial = CdnScoreEntry(
    score: 50,
    successes: 0,
    failures: 0,
    ewmaMbps: 0,
  );

  final double score;
  final int successes;
  final int failures;
  final double ewmaMbps;

  factory CdnScoreEntry.fromMap(Map data) => CdnScoreEntry(
    score: (data['score'] as num?)?.toDouble().clamp(0, 100) ?? 50,
    successes: (data['successes'] as num?)?.toInt() ?? 0,
    failures: (data['failures'] as num?)?.toInt() ?? 0,
    ewmaMbps: (data['ewmaMbps'] as num?)?.toDouble() ?? 0,
  );

  Map<String, Object> toMap() => {
    'score': score,
    'successes': successes,
    'failures': failures,
    'ewmaMbps': ewmaMbps,
  };
}

/// Persistent, host-based CDN reputation. Stability has a much stronger
/// influence than raw throughput so a fast but stalling CDN is demoted quickly.
abstract final class CdnScoreService {
  static const _storageKey = 'adaptiveCdnScoresV2';
  static final ValueNotifier<int> revision = ValueNotifier(0);
  static Map<String, CdnScoreEntry>? _entries;
  static Timer? _persistTimer;

  static Map<String, CdnScoreEntry> get entries =>
      Map.unmodifiable(_ensureLoaded());

  static CdnScoreEntry entryForUrl(String url) {
    final host = VideoUtils.cdnHost(url);
    if (host == null) return CdnScoreEntry.initial;
    return _ensureLoaded()[host] ?? CdnScoreEntry.initial;
  }

  static double scoreForUrl(String url) => entryForUrl(url).score;

  static List<String> rankCandidates(Iterable<String> urls) {
    final indexed = urls.indexed.toList(growable: false)
      ..sort((a, b) {
        final scoreCompare = scoreForUrl(b.$2).compareTo(scoreForUrl(a.$2));
        return scoreCompare != 0 ? scoreCompare : a.$1.compareTo(b.$1);
      });
    return indexed.map((item) => item.$2).toList(growable: false);
  }

  static void recordSuccess(
    String url, {
    required int bytes,
    required Duration networkWait,
  }) {
    if (bytes < 64 * 1024 || networkWait <= Duration.zero) return;
    final host = VideoUtils.cdnHost(url);
    if (host == null) return;
    final current = _ensureLoaded()[host] ?? CdnScoreEntry.initial;
    final seconds = math.max(networkWait.inMicroseconds / 1000000, 0.001);
    final mbps = (bytes * 8 / 1000000) / seconds;
    final ewma = current.ewmaMbps == 0
        ? mbps
        : current.ewmaMbps * 0.75 + mbps * 0.25;
    final speedSample = (50 + 18 * (math.log(mbps + 1) / math.ln10)).clamp(
      50,
      90,
    );
    final nextScore = (current.score * 0.88 + speedSample * 0.12 + 0.5).clamp(
      0,
      100,
    );
    _entries![host] = CdnScoreEntry(
      score: nextScore.toDouble(),
      successes: current.successes + 1,
      failures: current.failures,
      ewmaMbps: ewma,
    );
    _changed();
  }

  static void recordFailure(String url, {double penalty = 14}) {
    final host = VideoUtils.cdnHost(url);
    if (host == null) return;
    final current = _ensureLoaded()[host] ?? CdnScoreEntry.initial;
    _entries![host] = CdnScoreEntry(
      score: (current.score - penalty).clamp(0, 100),
      successes: current.successes,
      failures: current.failures + 1,
      ewmaMbps: current.ewmaMbps,
    );
    _changed(immediate: true);
  }

  static Future<void> clear() async {
    _persistTimer?.cancel();
    _entries = {};
    revision.value += 1;
    try {
      await GStorage.localCache.delete(_storageKey);
    } catch (_) {}
  }

  @visibleForTesting
  static void resetMemoryForTest([Map<String, CdnScoreEntry>? values]) {
    _persistTimer?.cancel();
    _entries = values == null ? {} : Map.of(values);
  }

  static Map<String, CdnScoreEntry> _ensureLoaded() {
    if (_entries case final entries?) return entries;
    final result = <String, CdnScoreEntry>{};
    try {
      final raw = GStorage.localCache.get(_storageKey);
      if (raw is Map) {
        for (final item in raw.entries) {
          if (item.key is String && item.value is Map) {
            result[item.key as String] = CdnScoreEntry.fromMap(
              item.value as Map,
            );
          }
        }
      }
    } catch (_) {}
    return _entries = result;
  }

  static void _changed({bool immediate = false}) {
    revision.value += 1;
    _persistTimer?.cancel();
    if (immediate) {
      _persist();
    } else {
      _persistTimer = Timer(const Duration(seconds: 2), _persist);
    }
  }

  static void _persist() {
    final data = _entries!.map(
      (host, entry) => MapEntry(host, entry.toMap()),
    );
    try {
      unawaited(GStorage.localCache.put(_storageKey, data));
    } catch (_) {}
  }
}
