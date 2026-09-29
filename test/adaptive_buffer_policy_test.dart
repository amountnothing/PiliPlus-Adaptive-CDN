import 'dart:io';

import 'package:PiliPlus/utils/adaptive_playback.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

class RecordingGateway implements WakelockGateway {
  final List<bool> calls = [];
  @override
  Future<void> enable() async => calls.add(true);
  @override
  Future<void> disable() async => calls.add(false);
}

void main() {
  late Directory directory;
  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp('adaptive-buffer-');
    Hive.init(directory.path);
    GStorage.setting = await Hive.openBox('setting');
  });
  setUp(() async {
    await GStorage.setting.clear();
    await GStorage.setting.put(SettingBoxKey.adaptivePlayback, true);
  });
  tearDownAll(() async {
    await Hive.close();
    await directory.delete(recursive: true);
  });

  Duration seconds(double value) =>
      Duration(milliseconds: (value * 1000).round());

  bool switchFor(double forward, double growth) =>
      AdaptivePlayback.shouldSwitchForStalledBuffer(
        forwardBuffer: seconds(forward),
        refillThreshold: seconds(Pref.adaptiveRefillBufferSec),
        observedFor: const Duration(seconds: 5),
        observationWindow: seconds(Pref.adaptiveStallTimeoutSec),
        bufferGrowth: seconds(growth),
        minGrowth: seconds(Pref.adaptiveLowBufferStutterMinGrowthSec),
      );

  test('real Pref queue saturation does not condemn a healthy CDN', () {
    final options = Pref.initBuffer(1, 8000000);
    final cap = double.parse(options['cache-secs']!);
    // A full queue remains flat as playback consumes and CDN replenishes it.
    for (var window = 0; window < 6; window++) {
      expect(switchFor(cap - 0.25, 0), isFalse);
    }
    // Starvation still crosses the effective refill line and requests failover.
    expect(switchFor(0.75, -2), isTrue);
    expect(switchFor(1.5, 1.25), isFalse);
  });

  test('byte-limited playback is healthy even below the refill line', () {
    final options = Pref.initBuffer(1, 80000000);
    final byteLimitedSeconds =
        int.parse(options['demuxer-max-bytes']!) * 8 / 80000000;
    expect(
      AdaptivePlayback.shouldSwitchForStalledBuffer(
        forwardBuffer: seconds(byteLimitedSeconds),
        refillThreshold: seconds(Pref.adaptiveRefillBufferSec),
        observedFor: const Duration(seconds: 5),
        observationWindow: const Duration(seconds: 5),
        bufferGrowth: Duration.zero,
        minGrowth: const Duration(seconds: 1),
        playbackProgress: const Duration(seconds: 5),
      ),
      isFalse,
    );
  });

  test('PTS freeze is reachable with the actual low-latency queue', () {
    final cap = double.parse(Pref.initBuffer()['cache-secs']!);
    expect(
      AdaptivePlayback.shouldRecoverFrozenTrack(
        trackPts: const Duration(seconds: 20),
        lastTrackPts: const Duration(seconds: 20),
        forwardBuffer: seconds(cap - 0.25),
        minForwardBuffer: seconds(Pref.adaptiveLowBufferSec),
        noFrameProgressFor: const Duration(seconds: 9),
        freezeTimeout: const Duration(seconds: 8),
        isPlaying: true,
        trackExpected: true,
      ),
      isTrue,
    );
  });

  test('legacy large thresholds cannot exceed the real queue', () async {
    await GStorage.setting.putAll({
      SettingBoxKey.adaptiveTargetBufferSec: 120.0,
      SettingBoxKey.adaptiveLowBufferSec: 40.0,
      SettingBoxKey.adaptiveSegmentToleranceSec: 30.0,
    });
    expect(switchFor(3.5, 0), isFalse);
    expect(switchFor(0.5, -1), isTrue);
    await GStorage.setting.put(SettingBoxKey.adaptivePlayback, false);
    expect(Pref.adaptiveLowBufferSec, 40);
    expect(Pref.initBuffer()['cache-secs'], '16.000');
  });

  test('fragmented-stall detection does not conflict with the 4s queue', () {
    // Stall onset is defined only by isBuffering false→true events, never by
    // the forward buffer amount. A healthy low-latency playback (buffer
    // hovering under the 4s cap, no buffering events) records zero stalls and
    // must never trigger the fragmented-stall switch.
    expect(Pref.adaptiveFragmentStallWindowSec, 30);
    expect(Pref.adaptiveFragmentStallCount, 3);
    expect(Pref.adaptiveFragmentStallTotalSec, 3);
    expect(
      AdaptivePlayback.shouldSwitchForFragmentedStalls(
        stallStarts: const [],
        stallDurations: const [],
        now: DateTime.now(),
        window: Duration(seconds: Pref.adaptiveFragmentStallWindowSec.round()),
        minStalls: Pref.adaptiveFragmentStallCount.round(),
        minTotalStall:
            Duration(seconds: Pref.adaptiveFragmentStallTotalSec.round()),
      ),
      isFalse,
    );
    // A single short rebuffer under the low-latency queue is normal.
    expect(
      AdaptivePlayback.shouldSwitchForFragmentedStalls(
        stallStarts: [DateTime.now()],
        stallDurations: const [Duration(milliseconds: 800)],
        now: DateTime.now(),
        window: const Duration(seconds: 30),
        minStalls: 3,
        minTotalStall: const Duration(seconds: 3),
      ),
      isFalse,
    );
  });

  group('WakelockHoldManager', () {
    Future<WakelockHoldManager> sync(
      RecordingGateway gateway, {
      required bool playbackRequested,
      bool isInBackground = false,
      bool continuePlayInBackground = false,
      bool onlyPlayAudio = false,
    }) async {
      final manager = WakelockHoldManager(gateway);
      await manager.sync(
        playbackRequested: playbackRequested,
        isInBackground: isInBackground,
        continuePlayInBackground: continuePlayInBackground,
        onlyPlayAudio: onlyPlayAudio,
      );
      return manager;
    }

    test('play through media replacement ends enabled', () async {
      final gateway = RecordingGateway();
      final manager = await sync(gateway, playbackRequested: true);
      // Native playing=false during _isReplacingMedia must not release.
      await manager.sync(
        playbackRequested: true,
        // controller passes the same inputs; buffering does not change intent
      );
      expect(gateway.calls, [true]);
      // Replacement ends, still playing: no extra toggle.
      await manager.sync(playbackRequested: true);
      expect(gateway.calls, [true]);
    });

    test('long buffering with playback intent keeps the wakelock', () async {
      final gateway = RecordingGateway();
      final manager = await sync(gateway, playbackRequested: true);
      await manager.sync(playbackRequested: true);
      expect(gateway.calls, [true]);
    });

    test('explicit pause disables immediately', () async {
      final gateway = RecordingGateway();
      final manager = await sync(gateway, playbackRequested: true);
      await manager.sync(playbackRequested: false);
      expect(gateway.calls, [true, false]);
      await manager.forceDisable();
      expect(gateway.calls, [true, false, false]);
    });

    test('background without continuePlayInBackground disables', () async {
      final gateway = RecordingGateway();
      final manager = await sync(gateway, playbackRequested: true);
      await manager.sync(
        playbackRequested: true,
        isInBackground: true,
        continuePlayInBackground: false,
      );
      expect(gateway.calls, [true, false]);
    });

    test('audio-only background playback disables', () async {
      final gateway = RecordingGateway();
      final manager = await sync(gateway, playbackRequested: true);
      await manager.sync(
        playbackRequested: true,
        isInBackground: true,
        continuePlayInBackground: true,
        onlyPlayAudio: true,
      );
      expect(gateway.calls, [true, false]);
    });

    test('no repeated toggles for identical states', () async {
      final gateway = RecordingGateway();
      final manager = await sync(gateway, playbackRequested: true);
      await manager.sync(playbackRequested: true);
      await manager.sync(playbackRequested: true);
      expect(gateway.calls, [true]);
      await manager.sync(playbackRequested: false);
      await manager.sync(playbackRequested: false);
      expect(gateway.calls, [true, false]);
    });
  });
}
