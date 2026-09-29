import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:PiliPlus/services/cdn_score_service.dart';
import 'package:PiliPlus/services/cdn_relay_server.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('CdnRelayServer', () {
    late CdnRelayServer relayServer;
    final upstreamServers = <HttpServer>[];

    setUp(() {
      CdnScoreService.resetMemoryForTest();
      relayServer = CdnRelayServer(connectivityProbe: () async => true);
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
      'keepalive serves repeated ranges then cancels a paused request',
      () async {
        final ports = <int>[];
        final stalled = Completer<void>();
        final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        origin.listen((request) async {
          ports.add(request.connectionInfo!.remotePort);
          if (ports.length == 4) {
            stalled.complete();
            return;
          }
          request.response
            ..contentLength = 2
            ..add([1, 2]);
          await request.response.close();
        });
        upstreamServers.add(origin);
        final url = 'http://127.0.0.1:${origin.port}/video';
        final session = await relayServer.createSession(
          videoCandidates: [url],
          videoIndex: 0,
          cooldown: Duration.zero,
          maxSwitches: 0,
        );
        final client = HttpClient();
        addTearDown(() => client.close(force: true));
        final localPorts = <int>[];
        for (var i = 0; i < 3; i++) {
          final response = await (await client.getUrl(
            Uri.parse(session.videoUrl),
          )).close();
          localPorts.add(response.connectionInfo!.localPort);
          expect(await _readBytesAllowingPrematureClose(response), [1, 2]);
        }
        expect(localPorts.toSet(), hasLength(1));
        final pending = (await client.getUrl(Uri.parse(session.videoUrl)))
            .close()
            .then<void>((response) => response.drain<void>())
            .catchError((Object _) {});
        await stalled.future;
        session.setPlaybackPaused(true);
        client.close(force: true);
        await pending;
        await session.dispose().timeout(const Duration(seconds: 1));
        await relayServer.close().timeout(const Duration(seconds: 1));
        expect(CdnScoreService.entryForUrl(url).failures, 0);
      },
    );

    test(
      'paused downstream cancellation releases the upstream socket',
      () async {
        final origin = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(origin.close);
        final connected = Completer<Socket>();
        final disconnected = Completer<void>();
        origin.listen((socket) {
          connected.complete(socket);
          addTearDown(socket.destroy);
          var replied = false;
          socket.listen((_) {
            if (replied) return;
            replied = true;
            socket
              ..write('HTTP/1.1 200 OK\r\nContent-Length: 100000\r\n\r\n')
              ..add(Uint8List(64 * 1024));
          }, onDone: disconnected.complete);
        });
        final url = 'http://127.0.0.1:${origin.port}/video';
        final session = await relayServer.createSession(
          videoCandidates: [url],
          videoIndex: 0,
          cooldown: Duration.zero,
          maxSwitches: 0,
        );
        final client = HttpClient();
        addTearDown(() => client.close(force: true));
        final response = await (await client.getUrl(
          Uri.parse(session.videoUrl),
        )).close();
        final received = Completer<void>();
        final subscription = response.listen((_) {
          if (!received.isCompleted) received.complete();
        }, onError: (Object _) {});
        await received.future;
        session.setPlaybackPaused(true);
        final peer = await connected.future;
        peer.add([2]);
        await peer.flush();
        await Future<void>.delayed(const Duration(milliseconds: 100));
        client.close(force: true);
        await subscription.cancel();
        await disconnected.future.timeout(const Duration(seconds: 1));
        expect(session.isDisposed, isFalse);
        expect(CdnScoreService.entryForUrl(url).failures, 0);
      },
    );

    test('times out silent upstream response headers', () async {
      await relayServer.close();
      relayServer = CdnRelayServer(
        connectivityProbe: () async => true,
        upstreamSilenceTimeout: const Duration(milliseconds: 60),
      );
      final started = Completer<void>();
      final first = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      first.listen((request) {
        if (!started.isCompleted) started.complete();
        // Keep TCP open without sending any HTTP response headers.
      });
      final payload = List<int>.generate(32, (index) => index);
      final second = await _startUpstream(payload);
      upstreamServers.addAll([first, second]);
      final firstUrl = 'http://127.0.0.1:${first.port}/video.m4s';
      final session = await relayServer.createSession(
        videoCandidates: [
          firstUrl,
          'http://localhost:${second.port}/video.m4s',
        ],
        videoIndex: 0,
        cooldown: Duration.zero,
        maxSwitches: 1,
      );
      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      final request = await client.getUrl(Uri.parse(session.videoUrl));
      final bytesFuture = request.close().then(
        _readBytesAllowingPrematureClose,
      );
      await started.future.timeout(const Duration(seconds: 1));
      expect(await bytesFuture.timeout(const Duration(seconds: 1)), payload);
      expect(session.switchCount, 1);
      expect(CdnScoreService.entryForUrl(firstUrl).failures, 1);
    });

    test(
      'body silence closes without splicing and next Range recovers',
      () async {
        await relayServer.close();
        relayServer = CdnRelayServer(
          connectivityProbe: () async => true,
          upstreamSilenceTimeout: const Duration(milliseconds: 100),
        );
        const prefix = 64 * 1024;
        final payload = List<int>.generate(128 * 1024, (index) => index % 256);
        final first = await _startUpstream(
          payload,
          stallAfterBytes: prefix,
          stallUntil: Completer<void>().future,
        );
        final second = await _startUpstream(payload);
        upstreamServers.addAll([first, second]);
        final firstUrl = 'http://127.0.0.1:${first.port}/video.m4s';
        final session = await relayServer.createSession(
          videoCandidates: [
            firstUrl,
            'http://localhost:${second.port}/video.m4s',
          ],
          videoIndex: 0,
          cooldown: Duration.zero,
          maxSwitches: 1,
        );
        final client = HttpClient();
        addTearDown(() => client.close(force: true));
        final request = await client.getUrl(Uri.parse(session.videoUrl));
        final bytes = await request
            .close()
            .then(_readBytesAllowingPrematureClose)
            .timeout(const Duration(seconds: 1));
        expect(bytes, payload.sublist(0, prefix));
        expect(session.switchCount, 1);
        expect(CdnScoreService.entryForUrl(firstUrl).failures, 1);
        final retry = await client.getUrl(Uri.parse(session.videoUrl));
        retry.headers.set(HttpHeaders.rangeHeader, 'bytes=$prefix-');
        expect(
          await retry.close().then(_readBytesAllowingPrematureClose),
          payload.sublist(prefix),
        );
      },
    );

    for (final headers in [true, false]) {
      test(
        'pause suspends ${headers ? 'header' : 'body'} silence timer',
        () async {
          await relayServer.close();
          relayServer = CdnRelayServer(
            connectivityProbe: () async => true,
            upstreamSilenceTimeout: const Duration(milliseconds: 100),
          );
          final started = Completer<void>();
          final release = Completer<void>();
          final first = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          first.listen((request) async {
            try {
              request.response.contentLength = 2;
              if (!headers) {
                request.response.add([1]);
                await request.response.flush();
              }
              started.complete();
              await release.future;
              request.response.add(headers ? [1, 2] : [2]);
              await request.response.close();
            } catch (_) {}
          });
          upstreamServers.add(first);
          final url = 'http://127.0.0.1:${first.port}/video';
          final session = await relayServer.createSession(
            videoCandidates: [url, 'http://localhost:${first.port}/video'],
            videoIndex: 0,
            cooldown: Duration.zero,
            maxSwitches: 1,
          );
          final client = HttpClient();
          addTearDown(() => client.close(force: true));
          final request = await client.getUrl(Uri.parse(session.videoUrl));
          final bytes = request.close().then(_readBytesAllowingPrematureClose);
          await started.future;
          session.setPlaybackPaused(true);
          await Future<void>.delayed(const Duration(milliseconds: 250));
          expect(session.switchCount, 0);
          session.setPlaybackPaused(false);
          await Future<void>.delayed(const Duration(milliseconds: 30));
          release.complete();
          expect(await bytes.timeout(const Duration(seconds: 1)), [1, 2]);
          expect(CdnScoreService.entryForUrl(url).failures, 0);
        },
      );
    }

    test(
      'downstream cancellation during body silence does not penalize CDN',
      () async {
        await relayServer.close();
        relayServer = CdnRelayServer(
          connectivityProbe: () async => true,
          upstreamSilenceTimeout: const Duration(milliseconds: 150),
        );
        final first = await _startUpstream(
          List<int>.filled(128 * 1024, 1),
          stallAfterBytes: 64 * 1024,
          stallUntil: Completer<void>().future,
        );
        upstreamServers.add(first);
        final url = 'http://127.0.0.1:${first.port}/video';
        final session = await relayServer.createSession(
          videoCandidates: [url, 'http://localhost:${first.port}/video'],
          videoIndex: 0,
          cooldown: Duration.zero,
          maxSwitches: 1,
        );
        final client = HttpClient();
        addTearDown(() => client.close(force: true));
        final response = await (await client.getUrl(
          Uri.parse(session.videoUrl),
        )).close();
        final received = Completer<void>();
        final subscription = response.listen((_) {
          if (!received.isCompleted) received.complete();
        }, onError: (Object _) {});
        await received.future;
        client.close(force: true);
        await subscription.cancel();
        await Future<void>.delayed(const Duration(milliseconds: 350));
        expect(session.switchCount, 0);
        expect(CdnScoreService.entryForUrl(url).failures, 0);
      },
    );

    test('downstream backpressure is not upstream silence', () async {
      await relayServer.close();
      relayServer = CdnRelayServer(
        connectivityProbe: () async => true,
        upstreamSilenceTimeout: const Duration(milliseconds: 150),
      );
      final payload = Uint8List(16 * 1024 * 1024);
      final first = await _startUpstream(payload);
      upstreamServers.add(first);
      final url = 'http://127.0.0.1:${first.port}/video';
      final session = await relayServer.createSession(
        videoCandidates: [url, 'http://localhost:${first.port}/video'],
        videoIndex: 0,
        cooldown: Duration.zero,
        maxSwitches: 1,
      );
      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      final response = await (await client.getUrl(Uri.parse(session.videoUrl)))
          .close();
      final done = Completer<void>();
      var count = 0;
      final sub = response.listen(
        (data) {
          count += data.length;
        },
        onDone: done.complete,
        onError: done.completeError,
      )..pause();
      addTearDown(sub.cancel);
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(session.switchCount, 0);
      sub.resume();
      await done.future.timeout(const Duration(seconds: 5));
      expect(count, payload.length);
      expect(CdnScoreService.entryForUrl(url).failures, 0);
    });

    for (final action in [
      'generation',
      'pause',
      'cancel',
      'retire',
      'budget',
    ]) {
      test('header timeout respects $action during network probe', () async {
        await relayServer.close();
        final probing = Completer<void>();
        final releaseProbe = Completer<bool>();
        relayServer = CdnRelayServer(
          connectivityProbe: () {
            probing.complete();
            return releaseProbe.future;
          },
          upstreamSilenceTimeout: const Duration(milliseconds: 100),
        );
        final first = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        first.listen((_) {});
        final second = await _startUpstream([1, 2]);
        upstreamServers.addAll([first, second]);
        final url = 'http://127.0.0.1:${first.port}/video';
        final next = 'http://localhost:${second.port}/video';
        final session = await relayServer.createSession(
          videoCandidates: [url, next],
          videoIndex: 0,
          cooldown: Duration.zero,
          maxSwitches: 1,
          initialSwitchCount: action == 'budget' ? 1 : 0,
        );
        final client = HttpClient();
        addTearDown(() => client.close(force: true));
        final request = await client.getUrl(Uri.parse(session.videoUrl));
        final completed = request
            .close()
            .then(_readBytesAllowingPrematureClose)
            .catchError((Object _) => <int>[]);
        if (action == 'budget') {
          await completed.timeout(const Duration(seconds: 1));
          expect(probing.isCompleted, isFalse);
          expect(session.switchCount, 1);
        } else {
          await probing.future.timeout(const Duration(seconds: 1));
          switch (action) {
            case 'generation':
              // Same URL, new generation: expectedUrl alone cannot guard this.
              session.updateSources(
                videoCandidates: [url, next, '$next?new'],
                videoIndex: 0,
                audioCandidates: [],
                audioIndex: 0,
              );
            case 'pause':
              session.setPlaybackPaused(true);
            case 'cancel':
              client.close(force: true);
            case 'retire':
              session.retire();
          }
          await Future<void>.delayed(const Duration(milliseconds: 30));
          releaseProbe.complete(true);
          await Future<void>.delayed(const Duration(milliseconds: 30));
          expect(session.switchCount, 0);
          expect(session.currentVideoSource, url);
        }
        expect(CdnScoreService.entryForUrl(url).failures, 0);
        await session.dispose();
        await completed;
      });
    }

    test(
      'closes the active response and serves the next Range from the new CDN',
      () async {
        const prefixLength = 300 * 1024;
        final payload = List<int>.generate(512 * 1024, (index) => index % 256);
        final upstreamStalled = Completer<void>();
        final first = await _startUpstream(
          payload,
          stallAfterBytes: prefixLength,
          stallFor: const Duration(seconds: 2),
          onStallStarted: () {
            if (!upstreamStalled.isCompleted) upstreamStalled.complete();
          },
        );
        final second = await _startUpstream(payload);
        upstreamServers.addAll([first, second]);

        final switches = <(String, String)>[];
        final firstUrl = 'http://127.0.0.1:${first.port}/video.m4s';
        final session = await relayServer.createSession(
          videoCandidates: [
            firstUrl,
            'http://localhost:${second.port}/video.m4s',
          ],
          videoIndex: 0,
          cooldown: Duration.zero,
          maxSwitches: 3,
          onSwitch: (track, failed, next) {
            if (track == CdnRelayTrack.video) switches.add((failed, next));
          },
        );

        final client = HttpClient();
        final stableUrl = session.videoUrl;
        final request = await client.getUrl(Uri.parse(stableUrl));
        final response = await request.close();
        final receivedPrefix = Completer<void>();
        final readFuture = _readBytesAllowingPrematureClose(
          response,
          onBytes: (bytes) {
            if (bytes.length >= prefixLength && !receivedPrefix.isCompleted) {
              receivedPrefix.complete();
            }
          },
        );
        await receivedPrefix.future.timeout(const Duration(seconds: 1));
        expect(
          await session.switchVideo(expectedUrl: firstUrl, reason: 'test'),
          isTrue,
        );
        final firstBytes = await readFuture;

        expect(firstBytes, payload.sublist(0, prefixLength));
        expect(switches, hasLength(1));
        expect(
          session.currentVideoSource,
          contains('localhost:${second.port}'),
        );
        expect(session.videoUrl, stableUrl);
        final resumedRequest = await client.getUrl(Uri.parse(stableUrl));
        resumedRequest.headers.set(
          HttpHeaders.rangeHeader,
          'bytes=$prefixLength-',
        );
        final resumedBytes = await (await resumedRequest.close())
            .fold<List<int>>(
              <int>[],
              (bytes, chunk) => bytes..addAll(chunk),
            );
        client.close(force: true);

        expect(resumedBytes, payload.sublist(prefixLength));
      },
    );

    test(
      'controller switch selects the next CDN without changing local URL',
      () async {
        final payload = List<int>.generate(32, (index) => index);
        final requestStarted = Completer<void>();
        final first = await _startUpstream(
          payload,
          responseDelay: const Duration(seconds: 2),
          onRequest: () {
            if (!requestStarted.isCompleted) requestStarted.complete();
          },
        );
        final second = await _startUpstream(payload);
        upstreamServers.addAll([first, second]);

        final firstUrl = 'http://127.0.0.1:${first.port}/video.m4s';
        final session = await relayServer.createSession(
          videoCandidates: [
            firstUrl,
            'http://localhost:${second.port}/video.m4s',
          ],
          videoIndex: 0,
          cooldown: Duration.zero,
          maxSwitches: 3,
        );

        final client = HttpClient();
        final stableUrl = session.videoUrl;
        final request = await client.getUrl(Uri.parse(session.videoUrl));
        final responseFuture = request.close();

        await requestStarted.future.timeout(const Duration(seconds: 1));
        expect(await session.switchVideo(expectedUrl: firstUrl), isTrue);
        final response = await responseFuture;
        final bytes = await response.fold<List<int>>(
          <int>[],
          (buffer, chunk) => buffer..addAll(chunk),
        );
        client.close(force: true);

        expect(session.videoUrl, stableUrl);
        expect(bytes, payload);
        expect(
          session.currentVideoSource,
          contains('localhost:${second.port}'),
        );
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
          cooldown: Duration.zero,
          maxSwitches: 3,
        );

        expect(await session.switchVideo(expectedUrl: failedVideo), isTrue);

        expect(session.currentAudioSource, failedAudio);
        final entry = CdnScoreService.entryForUrl(failedVideo);
        expect(entry.failures, 1);
        expect(entry.score, 36);
      },
    );

    test(
      'video switch restarts the audio Range without changing its CDN',
      () async {
        const prefixLength = 64 * 1024;
        final payload = List<int>.generate(256 * 1024, (index) => index % 256);
        final audioStalled = Completer<void>();
        final first = await _startUpstream(payload);
        final second = await _startUpstream(payload);
        final audio = await _startUpstream(
          payload,
          stallAfterBytes: prefixLength,
          stallFor: const Duration(seconds: 2),
          stallFirstRequestOnly: true,
          onStallStarted: () {
            if (!audioStalled.isCompleted) audioStalled.complete();
          },
        );
        upstreamServers.addAll([first, second, audio]);

        final failedVideo = 'http://127.0.0.1:${first.port}/video.m4s';
        final audioSource = 'http://127.0.0.1:${audio.port}/audio.m4s';
        final session = await relayServer.createSession(
          videoCandidates: [
            failedVideo,
            'http://localhost:${second.port}/video.m4s',
          ],
          videoIndex: 0,
          audioCandidates: [audioSource],
          audioIndex: 0,
          cooldown: Duration.zero,
          maxSwitches: 3,
        );

        final client = HttpClient();
        final firstAudioRequest = await client.getUrl(
          Uri.parse(session.audioUrl!),
        );
        final firstAudioResponse = await firstAudioRequest.close();
        final firstAudioRead = _readBytesAllowingPrematureClose(
          firstAudioResponse,
        );
        await audioStalled.future.timeout(const Duration(seconds: 1));

        expect(await session.switchVideo(expectedUrl: failedVideo), isTrue);
        expect(await firstAudioRead, payload.sublist(0, prefixLength));
        expect(session.currentAudioSource, audioSource);
        expect(session.audioSwitchCount, 0);

        final resumedRequest = await client.getUrl(
          Uri.parse(session.audioUrl!),
        );
        resumedRequest.headers.set(
          HttpHeaders.rangeHeader,
          'bytes=$prefixLength-',
        );
        final resumedBytes = await (await resumedRequest.close())
            .fold<List<int>>(
              <int>[],
              (buffer, chunk) => buffer..addAll(chunk),
            );
        client.close(force: true);
        expect(resumedBytes, payload.sublist(prefixLength));
      },
    );

    test(
      'Relay-detected video failure also restarts the current audio Range',
      () async {
        const prefixLength = 64 * 1024;
        final payload = List<int>.generate(256 * 1024, (index) => index % 256);
        final audioStalled = Completer<void>();
        final videoSwitched = Completer<void>();
        final first = await _startUpstream(
          payload,
          ignoreRange: true,
        );
        final second = await _startUpstream(payload);
        final audio = await _startUpstream(
          payload,
          stallAfterBytes: prefixLength,
          stallFor: const Duration(seconds: 2),
          stallFirstRequestOnly: true,
          onStallStarted: () {
            if (!audioStalled.isCompleted) audioStalled.complete();
          },
        );
        upstreamServers.addAll([first, second, audio]);

        final audioSource = 'http://127.0.0.1:${audio.port}/audio.m4s';
        final session = await relayServer.createSession(
          videoCandidates: [
            'http://127.0.0.1:${first.port}/video.m4s',
            'http://localhost:${second.port}/video.m4s',
          ],
          videoIndex: 0,
          audioCandidates: [audioSource],
          audioIndex: 0,
          cooldown: Duration.zero,
          maxSwitches: 3,
          onSwitch: (track, _, _) {
            if (track == CdnRelayTrack.video && !videoSwitched.isCompleted) {
              videoSwitched.complete();
            }
          },
        );

        final client = HttpClient();
        final audioResponse = await (await client.getUrl(
          Uri.parse(session.audioUrl!),
        )).close();
        final audioRead = _readBytesAllowingPrematureClose(audioResponse);
        await audioStalled.future.timeout(const Duration(seconds: 1));

        final videoRequest = await client.getUrl(Uri.parse(session.videoUrl));
        videoRequest.headers.set(HttpHeaders.rangeHeader, 'bytes=0-');
        final videoResponse = await videoRequest.close();
        await _readBytesAllowingPrematureClose(videoResponse);
        await videoSwitched.future.timeout(const Duration(seconds: 1));

        expect(await audioRead, payload.sublist(0, prefixLength));
        expect(session.currentAudioSource, audioSource);
        expect(session.audioSwitchCount, 0);
        expect(session.switchCount, 1);
        client.close(force: true);
      },
    );

    test('video switch budget does not block audio recovery', () async {
      final payload = List<int>.generate(32, (index) => index);
      final failedAudio = await _startUpstream(
        payload,
        disconnectAfterBytes: 0,
      );
      final healthyAudio = await _startUpstream(payload);
      upstreamServers.addAll([failedAudio, healthyAudio]);

      final session = await relayServer.createSession(
        videoCandidates: const [
          'https://video-a.invalid/video.m4s',
          'https://video-b.invalid/video.m4s',
        ],
        videoIndex: 0,
        audioCandidates: [
          'http://127.0.0.1:${failedAudio.port}/audio.m4s',
          'http://localhost:${healthyAudio.port}/audio.m4s',
        ],
        audioIndex: 0,
        cooldown: Duration.zero,
        maxSwitches: 1,
        maxAudioSwitches: 1,
      );

      expect(await session.switchVideo(reason: 'test'), isTrue);
      expect(session.remainingSwitches, 0);
      expect(session.remainingAudioSwitches, 1);

      final client = HttpClient();
      final firstRequest = await client.getUrl(Uri.parse(session.audioUrl!));
      final firstResponse = await firstRequest.close();
      await _readBytesAllowingPrematureClose(firstResponse);

      expect(session.remainingAudioSwitches, 0);
      expect(
        session.currentAudioSource,
        contains('localhost:${healthyAudio.port}'),
      );

      final retry = await client.getUrl(Uri.parse(session.audioUrl!));
      final bytes = await (await retry.close()).fold<List<int>>(
        <int>[],
        (buffer, chunk) => buffer..addAll(chunk),
      );
      client.close(force: true);
      expect(bytes, payload);
    });

    test('retired relay no longer calls the active controller', () async {
      final switches = <(String, String)>[];
      final logs = <String>[];
      final session = await relayServer.createSession(
        videoCandidates: const [
          'https://first.example/video.m4s',
          'https://second.example/video.m4s',
        ],
        videoIndex: 0,
        cooldown: Duration.zero,
        maxSwitches: 3,
        onSwitch: (track, failed, next) => switches.add((failed, next)),
        onLog: logs.add,
      );
      logs.clear();

      session.retire();
      expect(await session.switchVideo(reason: 'test'), isFalse);

      expect(switches, isEmpty);
      expect(logs, isEmpty);
      expect(session.currentVideoSource, contains('first.example'));
      expect(
        CdnScoreService.entryForUrl(
          'https://first.example/video.m4s',
        ).failures,
        0,
      );
    });

    test('offline hold does not override a manual pause', () async {
      await relayServer.close();
      relayServer = CdnRelayServer(
        connectivityProbe: () async => false,
        unreachableSwitchDelay: const Duration(milliseconds: 20),
      );
      final session = await relayServer.createSession(
        videoCandidates: const [
          'https://first.example/video.m4s',
          'https://second.example/video.m4s',
        ],
        videoIndex: 0,
        cooldown: Duration.zero,
        maxSwitches: 3,
      );

      final switchFuture = session.switchVideo(reason: 'test');
      await Future<void>.delayed(const Duration(milliseconds: 5));
      session.setPlaybackPaused(true);

      expect(await switchFuture, isFalse);
      expect(session.currentVideoSource, contains('first.example'));
    });

    test('switch guard cancels a transition after the network probe', () async {
      await relayServer.close();
      relayServer = CdnRelayServer(
        connectivityProbe: () async => false,
        unreachableSwitchDelay: const Duration(milliseconds: 20),
      );
      final session = await relayServer.createSession(
        videoCandidates: const [
          'https://first.example/video.m4s',
          'https://second.example/video.m4s',
        ],
        videoIndex: 0,
        cooldown: Duration.zero,
        maxSwitches: 3,
      );
      var allowSwitch = true;

      final switchFuture = session.switchVideo(
        reason: 'test',
        canSwitch: () => allowSwitch,
      );
      await Future<void>.delayed(const Duration(milliseconds: 5));
      allowSwitch = false;

      expect(await switchFuture, isFalse);
      expect(session.currentVideoSource, contains('first.example'));
    });

    test(
      'pauses CDN switching when the whole network looks impaired',
      () async {
        final payload = List<int>.generate(32, (index) => index);
        final first = await _startUpstream(
          payload,
          disconnectAfterBytes: 0,
        );
        final second = await _startUpstream(
          payload,
          disconnectAfterBytes: 0,
        );
        upstreamServers.addAll([first, second]);

        final switches = <(String, String)>[];
        final session = await relayServer.createSession(
          videoCandidates: [
            'http://127.0.0.1:${first.port}/video.m4s',
            'http://localhost:${second.port}/video.m4s',
          ],
          videoIndex: 0,
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
        expect(session.isNetworkSwitchPaused, isFalse);

        final thirdClient = HttpClient();
        final thirdRequest = await thirdClient.getUrl(
          Uri.parse(session.videoUrl),
        );
        final thirdResponse = await thirdRequest.close();
        await _readBytesAllowingPrematureClose(thirdResponse);
        thirdClient.close(force: true);

        expect(session.isNetworkSwitchPaused, isTrue);
      },
    );

    test(
      'manual pause resumes the same CDN without a failure penalty',
      () async {
        final payload = List<int>.generate(32, (index) => index);
        final upstreamStalled = Completer<void>();
        final releaseUpstream = Completer<void>();
        final first = await _startUpstream(
          payload,
          stallAfterBytes: 8,
          stallUntil: releaseUpstream.future,
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
        await Future<void>.delayed(const Duration(milliseconds: 100));
        releaseUpstream.complete();

        expect(switches, isEmpty);
        expect(session.currentVideoSource, firstUrl);

        session.setPlaybackPaused(false);
        final response = await responseFuture;
        final bytes = await _readBytesAllowingPrematureClose(response);

        expect(bytes, payload);
        expect(switches, isEmpty);
        expect(session.currentVideoSource, firstUrl);
        expect(CdnScoreService.entryForUrl(firstUrl).failures, 0);
        client.close(force: true);
      },
    );

    test('forwards byte ranges without changing the player URL', () async {
      final payload = List<int>.generate(32, (index) => index);
      final upstream = await _startUpstream(payload);
      upstreamServers.add(upstream);
      final session = await relayServer.createSession(
        videoCandidates: ['http://127.0.0.1:${upstream.port}/video.m4s'],
        videoIndex: 0,
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

    test('source updates do not reset the switch budget', () async {
      final session = await relayServer.createSession(
        videoCandidates: const [
          'https://cdn-a.invalid/video.m4s',
          'https://cdn-b.invalid/video.m4s',
          'https://cdn-c.invalid/video.m4s',
        ],
        videoIndex: 0,
        cooldown: Duration.zero,
        maxSwitches: 1,
      );

      expect(await session.switchVideo(reason: 'test'), isTrue);
      session.updateSources(
        videoCandidates: const [
          'https://cdn-b.invalid/video.m4s',
          'https://cdn-c.invalid/video.m4s',
        ],
        videoIndex: 0,
        audioCandidates: const [],
        audioIndex: 0,
      );
      expect(await session.switchVideo(reason: 'test'), isFalse);
    });

    test('a rebuilt relay inherits the shared switch budget', () async {
      final session = await relayServer.createSession(
        videoCandidates: const [
          'https://cdn-a.invalid/video.m4s',
          'https://cdn-b.invalid/video.m4s',
        ],
        videoIndex: 0,
        cooldown: Duration.zero,
        maxSwitches: 1,
        initialSwitchCount: 1,
      );

      expect(session.remainingSwitches, 0);
      expect(await session.switchVideo(reason: 'test'), isFalse);
    });

    test('a retired relay remains readable during handoff', () async {
      final payload = List<int>.generate(64, (index) => index);
      final upstream = await _startUpstream(payload);
      upstreamServers.add(upstream);
      final session = await relayServer.createSession(
        videoCandidates: ['http://127.0.0.1:${upstream.port}/video.m4s'],
        videoIndex: 0,
        cooldown: Duration.zero,
        maxSwitches: 1,
      );

      session.retire();
      final client = HttpClient();
      final response = await (await client.getUrl(
        Uri.parse(session.videoUrl),
      )).close();
      final bytes = await response.fold<List<int>>(
        <int>[],
        (buffer, chunk) => buffer..addAll(chunk),
      );
      client.close(force: true);

      expect(response.statusCode, HttpStatus.ok);
      expect(bytes, payload);
      expect(await session.switchVideo(reason: 'test'), isFalse);
    });
  });
}

Future<HttpServer> _startUpstream(
  List<int> payload, {
  int? stallAfterBytes,
  int? disconnectAfterBytes,
  Duration responseDelay = Duration.zero,
  Duration stallFor = Duration.zero,
  Future<void>? stallUntil,
  bool stallFirstRequestOnly = false,
  bool ignoreRange = false,
  void Function()? onRequest,
  void Function()? onStallStarted,
}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  var requestCount = 0;
  server.listen((request) async {
    requestCount += 1;
    onRequest?.call();
    if (responseDelay > Duration.zero) {
      await Future<void>.delayed(responseDelay);
    }
    final requestedRange = request.headers.value(HttpHeaders.rangeHeader);
    final range = ignoreRange ? null : requestedRange;
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
    final effectiveStallAfterBytes = stallFirstRequestOnly && requestCount > 1
        ? null
        : stallAfterBytes;
    final firstLength = effectiveStallAfterBytes == null
        ? (disconnectAfterBytes ?? body.length).clamp(0, body.length)
        : effectiveStallAfterBytes.clamp(0, body.length);
    try {
      response.add(body.sublist(0, firstLength));
      await response.flush();
      if (disconnectAfterBytes != null) {
        final socket = await response.detachSocket();
        socket.destroy();
        return;
      }
      if (firstLength < body.length) {
        onStallStarted?.call();
        if (stallUntil case final wait?) {
          await wait;
        } else {
          await Future<void>.delayed(stallFor);
        }
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
  HttpClientResponse response, {
  void Function(List<int> bytes)? onBytes,
}) async {
  final bytes = <int>[];
  final completer = Completer<List<int>>();
  late final StreamSubscription<List<int>> subscription;
  subscription = response.listen(
    (chunk) {
      bytes.addAll(chunk);
      onBytes?.call(bytes);
    },
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
