import 'dart:async';
import 'dart:io';

import 'package:PiliPlus/services/cdn_score_service.dart';
import 'package:PiliPlus/services/cdn_relay_server.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('CdnRelayServer', () {
    late CdnRelayServer relayServer;
    final upstreamServers = <HttpServer>[];

    setUp(() {
      CdnScoreService.resetMemoryForTest();
      relayServer = CdnRelayServer();
    });

    tearDown(() async {
      CdnScoreService.resetMemoryForTest();
      await relayServer.close();
      for (final server in upstreamServers) {
        await server.close(force: true);
      }
      upstreamServers.clear();
    });

    test(
      'switches CDN behind one stable URL without splicing responses',
      () async {
        final payload = List<int>.generate(32, (index) => index);
        final upstreamStalled = Completer<void>();
        final first = await _startUpstream(
          payload,
          stallAfterBytes: 8,
          stallFor: const Duration(seconds: 2),
          onStallStarted: () {
            if (!upstreamStalled.isCompleted) upstreamStalled.complete();
          },
        );
        final second = await _startUpstream(payload);
        upstreamServers.addAll([first, second]);

        final switches = <(String, String)>[];
        final stalls = <bool>[];
        final session = await relayServer.createSession(
          videoCandidates: [
            'http://127.0.0.1:${first.port}/video.m4s',
            'http://localhost:${second.port}/video.m4s',
          ],
          videoIndex: 0,
          stallTimeout: const Duration(milliseconds: 500),
          cooldown: Duration.zero,
          maxSwitches: 3,
          onSwitch: (track, failed, next) {
            if (track == CdnRelayTrack.video) switches.add((failed, next));
          },
          onStall: stalls.add,
        );

        final client = HttpClient();
        final stableUrl = session.videoUrl;
        final request = await client.getUrl(Uri.parse(stableUrl));
        final response = await request.close();
        await upstreamStalled.future.timeout(const Duration(seconds: 1));
        final firstBytes = await _readBytesAllowingPrematureClose(response);
        expect(firstBytes.length, lessThanOrEqualTo(8));
        expect(firstBytes, payload.sublist(0, firstBytes.length));
        expect(switches, hasLength(1));
        expect(
          session.currentVideoSource,
          contains('localhost:${second.port}'),
        );

        final resumedRequest = await client.getUrl(Uri.parse(stableUrl));
        resumedRequest.headers.set(HttpHeaders.rangeHeader, 'bytes=8-');
        final resumedBytes = await (await resumedRequest.close())
            .fold<List<int>>(
              <int>[],
              (bytes, chunk) => bytes..addAll(chunk),
            );

        expect(session.videoUrl, stableUrl);
        expect(resumedBytes, payload.sublist(8));
        expect(stalls, [true, false]);
        client.close(force: true);
      },
    );

    test(
      'controller switch selects the next CDN without changing local URL',
      () async {
        final payload = List<int>.generate(32, (index) => index);
        final upstreamStalled = Completer<void>();
        final first = await _startUpstream(
          payload,
          stallAfterBytes: 8,
          stallFor: const Duration(seconds: 2),
          onStallStarted: () {
            if (!upstreamStalled.isCompleted) upstreamStalled.complete();
          },
        );
        final second = await _startUpstream(payload);
        upstreamServers.addAll([first, second]);

        final firstUrl = 'http://127.0.0.1:${first.port}/video.m4s';
        final stalls = <bool>[];
        final session = await relayServer.createSession(
          videoCandidates: [
            firstUrl,
            'http://localhost:${second.port}/video.m4s',
          ],
          videoIndex: 0,
          stallTimeout: const Duration(seconds: 5),
          cooldown: Duration.zero,
          maxSwitches: 3,
          onStall: stalls.add,
        );

        final client = HttpClient();
        final stableUrl = session.videoUrl;
        final request = await client.getUrl(Uri.parse(session.videoUrl));
        final response = await request.close();
        final subscription = response.listen(null);

        await upstreamStalled.future.timeout(const Duration(seconds: 1));
        expect(session.switchVideo(expectedUrl: firstUrl), isTrue);
        await subscription.cancel();
        client.close(force: true);

        expect(session.videoUrl, stableUrl);
        expect(
          session.currentVideoSource,
          contains('localhost:${second.port}'),
        );
        expect(stalls, isEmpty);
      },
    );

    test(
      'video switch leaves a healthy audio response on its current CDN',
      () async {
        final payload = List<int>.generate(32, (index) => index);
        final first = await _startUpstream(payload);
        final second = await _startUpstream(payload);
        upstreamServers.addAll([first, second]);

        final failedVideo = 'http://127.0.0.1:${first.port}/video.m4s';
        final failedAudio = 'http://127.0.0.1:${first.port}/audio.m4s';
        final session = await relayServer.createSession(
          videoCandidates: [
            failedVideo,
            'http://localhost:${second.port}/video.m4s',
          ],
          videoIndex: 0,
          audioCandidates: [
            failedAudio,
            'http://localhost:${second.port}/audio.m4s',
          ],
          audioIndex: 0,
          stallTimeout: const Duration(milliseconds: 500),
          cooldown: Duration.zero,
          maxSwitches: 3,
        );

        expect(session.switchVideo(expectedUrl: failedVideo), isTrue);

        expect(session.currentAudioSource, failedAudio);
        final entry = CdnScoreService.entryForUrl(failedVideo);
        expect(entry.failures, 1);
        expect(entry.score, 36);
      },
    );

    test(
      'does not switch CDN while CDN failure switching is paused',
      () async {
        final payload = List<int>.generate(32, (index) => index);
        final upstreamStalled = Completer<void>();
        final first = await _startUpstream(
          payload,
          stallAfterBytes: 8,
          stallFor: const Duration(seconds: 2),
          onStallStarted: () {
            if (!upstreamStalled.isCompleted) upstreamStalled.complete();
          },
        );
        final second = await _startUpstream(payload);
        upstreamServers.addAll([first, second]);

        final firstUrl = 'http://127.0.0.1:${first.port}/video.m4s';
        final switches = <(String, String)>[];
        final session = await relayServer.createSession(
          videoCandidates: [
            firstUrl,
            'http://localhost:${second.port}/video.m4s',
          ],
          videoIndex: 0,
          stallTimeout: const Duration(milliseconds: 300),
          cooldown: Duration.zero,
          maxSwitches: 3,
          onSwitch: (track, failed, next) {
            if (track == CdnRelayTrack.video) switches.add((failed, next));
          },
        );
        session.setCdnSwitchPaused(true);

        final client = HttpClient();
        final request = await client.getUrl(Uri.parse(session.videoUrl));
        final response = await request.close();
        final readFuture = _readBytesAllowingPrematureClose(response);

        await upstreamStalled.future.timeout(const Duration(seconds: 1));
        await readFuture;
        client.close(force: true);

        expect(switches, isEmpty);
        expect(session.currentVideoSource, firstUrl);
        expect(CdnScoreService.entryForUrl(firstUrl).failures, 0);
      },
    );

    test(
      'recent player byte delivery pauses CDN failure switching',
      () async {
        final payload = List<int>.generate(32, (index) => index);
        final upstreamStalled = Completer<void>();
        final first = await _startUpstream(
          payload,
          stallAfterBytes: 8,
          stallFor: const Duration(seconds: 2),
          onStallStarted: () {
            if (!upstreamStalled.isCompleted) upstreamStalled.complete();
          },
        );
        final second = await _startUpstream(payload);
        upstreamServers.addAll([first, second]);

        final firstUrl = 'http://127.0.0.1:${first.port}/video.m4s';
        final switches = <(String, String)>[];
        final session = await relayServer.createSession(
          videoCandidates: [
            firstUrl,
            'http://localhost:${second.port}/video.m4s',
          ],
          videoIndex: 0,
          stallTimeout: const Duration(milliseconds: 300),
          cooldown: Duration.zero,
          maxSwitches: 3,
          onSwitch: (track, failed, next) {
            if (track == CdnRelayTrack.video) switches.add((failed, next));
          },
        );
        session.setCdnSwitchPullGrace(const Duration(seconds: 3));

        final client = HttpClient();
        final request = await client.getUrl(Uri.parse(session.videoUrl));
        final response = await request.close();

        await upstreamStalled.future.timeout(const Duration(seconds: 1));
        await _readBytesAllowingPrematureClose(response);
        client.close(force: true);

        expect(switches, isEmpty);
        expect(session.currentVideoSource, firstUrl);
        expect(session.isCdnSwitchPaused, isTrue);
        expect(CdnScoreService.entryForUrl(firstUrl).failures, 0);
      },
    );

    test(
      'pauses CDN switching when the whole network looks impaired',
      () async {
        final payload = List<int>.generate(32, (index) => index);
        final first = await _startUpstream(
          payload,
          stallAfterBytes: 0,
          stallFor: const Duration(seconds: 2),
        );
        final second = await _startUpstream(
          payload,
          stallAfterBytes: 0,
          stallFor: const Duration(seconds: 2),
        );
        upstreamServers.addAll([first, second]);

        final switches = <(String, String)>[];
        final session = await relayServer.createSession(
          videoCandidates: [
            'http://127.0.0.1:${first.port}/video.m4s',
            'http://localhost:${second.port}/video.m4s',
          ],
          videoIndex: 0,
          stallTimeout: const Duration(milliseconds: 300),
          cooldown: Duration.zero,
          maxSwitches: 3,
          onSwitch: (track, failed, next) {
            if (track == CdnRelayTrack.video) switches.add((failed, next));
          },
        );

        final firstClient = HttpClient();
        final firstRequest = await firstClient.getUrl(
          Uri.parse(session.videoUrl),
        );
        final firstResponse = await firstRequest.close();
        await _readBytesAllowingPrematureClose(firstResponse);
        firstClient.close(force: true);

        expect(switches, hasLength(1));
        expect(
          session.currentVideoSource,
          contains('localhost:${second.port}'),
        );
        expect(session.isNetworkSwitchPaused, isFalse);

        final secondClient = HttpClient();
        final secondRequest = await secondClient.getUrl(
          Uri.parse(session.videoUrl),
        );
        final secondResponse = await secondRequest.close();
        await _readBytesAllowingPrematureClose(secondResponse);
        secondClient.close(force: true);

        expect(switches, hasLength(1));
        expect(
          session.currentVideoSource,
          contains('localhost:${second.port}'),
        );
        expect(session.isNetworkSwitchPaused, isTrue);
      },
    );

    test('manual pause suspends relay timeout and CDN penalties', () async {
      final payload = List<int>.generate(32, (index) => index);
      final upstreamStalled = Completer<void>();
      final first = await _startUpstream(
        payload,
        stallAfterBytes: 8,
        stallFor: const Duration(seconds: 3),
        onStallStarted: () {
          if (!upstreamStalled.isCompleted) upstreamStalled.complete();
        },
      );
      final second = await _startUpstream(payload);
      upstreamServers.addAll([first, second]);

      final firstUrl = 'http://127.0.0.1:${first.port}/video.m4s';
      final switches = <(String, String)>[];
      final session = await relayServer.createSession(
        videoCandidates: [
          firstUrl,
          'http://localhost:${second.port}/video.m4s',
        ],
        videoIndex: 0,
        stallTimeout: const Duration(milliseconds: 500),
        cooldown: Duration.zero,
        maxSwitches: 3,
        onSwitch: (track, failed, next) {
          if (track == CdnRelayTrack.video) switches.add((failed, next));
        },
      );

      final client = HttpClient();
      final request = await client.getUrl(Uri.parse(session.videoUrl));
      final responseFuture = request.close();

      await upstreamStalled.future.timeout(const Duration(seconds: 1));
      session.setPlaybackPaused(true);
      await Future<void>.delayed(const Duration(milliseconds: 700));

      expect(switches, isEmpty);
      expect(session.currentVideoSource, firstUrl);

      session.setPlaybackPaused(false);
      final response = await responseFuture;
      final firstBytes = await _readBytesAllowingPrematureClose(response);
      client.close(force: true);

      expect(firstBytes.length, lessThanOrEqualTo(8));
      expect(firstBytes, payload.sublist(0, firstBytes.length));
      expect(switches, hasLength(1));
      expect(session.currentVideoSource, contains('localhost:${second.port}'));
    });

    test('forwards byte ranges without changing the player URL', () async {
      final payload = List<int>.generate(32, (index) => index);
      final upstream = await _startUpstream(payload);
      upstreamServers.add(upstream);
      final session = await relayServer.createSession(
        videoCandidates: ['http://127.0.0.1:${upstream.port}/video.m4s'],
        videoIndex: 0,
        stallTimeout: const Duration(seconds: 1),
        cooldown: Duration.zero,
        maxSwitches: 3,
      );

      final stableUrl = session.videoUrl;
      final client = HttpClient();
      final request = await client.getUrl(Uri.parse(stableUrl));
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=10-19');
      final response = await request.close();
      final bytes = await response.fold<List<int>>(
        <int>[],
        (buffer, chunk) => buffer..addAll(chunk),
      );
      client.close(force: true);

      expect(response.statusCode, HttpStatus.partialContent);
      expect(bytes, payload.sublist(10, 20));
      expect(session.videoUrl, stableUrl);
    });
  });
}

Future<HttpServer> _startUpstream(
  List<int> payload, {
  int? stallAfterBytes,
  Duration stallFor = Duration.zero,
  void Function()? onStallStarted,
}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    final range = request.headers.value(HttpHeaders.rangeHeader);
    final match = range == null
        ? null
        : RegExp(r'^bytes=(\d+)-(\d*)$').firstMatch(range);
    final start = match == null ? 0 : int.parse(match.group(1)!);
    final requestedEnd = match == null || match.group(2)!.isEmpty
        ? payload.length - 1
        : int.parse(match.group(2)!);
    final end = requestedEnd.clamp(start, payload.length - 1);
    final response = request.response
      ..statusCode = range == null ? HttpStatus.ok : HttpStatus.partialContent
      ..headers.set(HttpHeaders.acceptRangesHeader, 'bytes')
      ..headers.contentType = ContentType.binary;
    if (range != null) {
      response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes $start-$end/${payload.length}',
      );
    }
    response.contentLength = end - start + 1;

    final body = payload.sublist(start, end + 1);
    final firstLength = stallAfterBytes == null
        ? body.length
        : stallAfterBytes.clamp(0, body.length);
    try {
      response.add(body.sublist(0, firstLength));
      await response.flush();
      if (firstLength < body.length) {
        onStallStarted?.call();
        await Future<void>.delayed(stallFor);
        response.add(body.sublist(firstLength));
      }
      await response.close();
    } catch (_) {
      // The relay intentionally cancels a stalled upstream request.
    }
  });
  return server;
}

Future<List<int>> _readBytesAllowingPrematureClose(
  HttpClientResponse response,
) async {
  final bytes = <int>[];
  final completer = Completer<List<int>>();
  late final StreamSubscription<List<int>> subscription;
  subscription = response.listen(
    bytes.addAll,
    onError: (Object _, StackTrace _) {
      if (!completer.isCompleted) completer.complete(bytes);
    },
    onDone: () {
      if (!completer.isCompleted) completer.complete(bytes);
    },
    cancelOnError: true,
  );
  try {
    return await completer.future;
  } finally {
    await subscription.cancel();
  }
}
