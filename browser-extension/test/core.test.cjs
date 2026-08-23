const test = require("node:test");
const assert = require("node:assert/strict");
const Core = require("../core.js");

const COS = "https://upos-sz-mirrorcosov.bilivideo.com/upgcxcode/a/video.m4s?deadline=1";
const AKAMAI = "https://upos-hz-mirrorakam.akamaized.net/upgcxcode/a/video.m4s?deadline=1";

test("uses only candidates returned by the web playurl response", () => {
  const response = {
    data: {
      dash: {
        video: [{ baseUrl: COS, backupUrl: [AKAMAI], codecs: "av01.0.08M.08", id: 80 }],
        audio: [{ base_url: AKAMAI, backup_url: [COS], id: 30280 }],
      },
    },
  };
  const streams = Core.collectStreams(response);
  assert.equal(streams.length, 2);
  assert.deepEqual(Core.streamUrls(streams[0]), [COS, AKAMAI]);
  assert.deepEqual(Core.streamUrls(streams[1]), [AKAMAI, COS]);
});

test("expands a signed upgcxcode URL only to verified UPOS hosts", () => {
  const expanded = Core.expandUposCandidates([COS, AKAMAI], true);
  assert.equal(expanded.length, Core.KNOWN_UPOS_HOSTS.length);
  assert.ok(expanded.some((url) => Core.hostOf(url) === "upos-sz-mirrorali.bilivideo.com"));
  assert.ok(expanded.some((url) => Core.hostOf(url) === "upos-sz-mirrorhwo1.bilivideo.com"));
  assert.ok(!expanded.some((url) => Core.hostOf(url) === "upos-sz-mirrorhwov.bilivideo.com"));
  for (const url of expanded) {
    assert.equal(new URL(url).pathname, "/upgcxcode/a/video.m4s");
    assert.equal(new URL(url).search, "?deadline=1");
  }
});

test("does not synthesize hosts for non-upgcxcode resources", () => {
  const mcdn = "https://example.mcdn.bilivideo.cn/v1/resource/abc?token=1";
  assert.deepEqual(Core.expandUposCandidates([mcdn], true), [mcdn]);
});

test("ranks by learned score and excludes failed or cooling hosts", () => {
  const scores = {
    "upos-sz-mirrorcosov.bilivideo.com": 25,
    "upos-hz-mirrorakam.akamaized.net": 72,
  };
  assert.deepEqual(Core.rankCandidates([COS, AKAMAI], scores, {}, new Set()), [AKAMAI, COS]);
  assert.deepEqual(
    Core.rankCandidates([COS, AKAMAI], scores, {}, new Set(["upos-hz-mirrorakam.akamaized.net"])),
    [COS],
  );
  assert.deepEqual(
    Core.rankCandidates(
      [COS, AKAMAI],
      scores,
      { "upos-hz-mirrorakam.akamaized.net": 20_000 },
      new Set(),
      10_000,
    ),
    [COS],
  );
});

test("prefers AV1 only within the same quality", () => {
  const dash = {
    video: [
      { id: 32, codecs: "avc1.64001F" },
      { id: 16, codecs: "av01.0.08M.08" },
      { id: 32, codecs: "av01.0.08M.08" },
    ],
  };
  Core.reorderVideoArrays(dash, "av1", () => true);
  assert.deepEqual(
    dash.video.map((item) => [item.id, item.codecs.slice(0, 4)]),
    [
      [32, "av01"],
      [32, "avc1"],
      [16, "av01"],
    ],
  );
});


test("supports selectable preferred codec and legacy AV1 toggle", () => {
  assert.equal(Core.normalizeSettings({ preferredCodec: "avc" }).preferredCodec, "avc");
  assert.equal(Core.normalizeSettings().segmentToleranceSec, 10);
  assert.equal(Core.normalizeSettings().cooldownSec, 60);
  assert.equal(Core.normalizeSettings({ preferAv1: false }).preferredCodec, "default");
  assert.equal(Core.streamKind({ mimeType: "video/mp4" }), "video");
  assert.equal(Core.streamKind({ mime_type: "audio/mp4" }), "audio");
  assert.equal(Core.streamKind({ codecs: "mp4a.40.2" }), "audio");

  const dash = {
    video: [
      { id: 80, codecs: "avc1.640028" },
      { id: 80, codecs: "hev1.1.6.L120.90" },
      { id: 80, codecs: "av01.0.08M.08" },
    ],
  };
  Core.reorderVideoArrays(dash, "avc", () => true);
  assert.equal(Core.codecFamily(dash.video[0].codecs), "avc");
});
test("switches after five seconds when refill grows less than one second", () => {
  const state = Core.createHealthState(0);
  const sample = { duration: 100, position: 10, buffered: 25, playing: true, ended: false };
  assert.equal(Core.evaluateHealth(state, sample, { lowBufferSec: 2 }, 0), null);
  assert.equal(
    Core.evaluateHealth(state, { ...sample, buffered: 25.999 }, { lowBufferSec: 2 }, 4_999),
    null,
  );
  assert.equal(
    Core.evaluateHealth(state, { ...sample, buffered: 25.999 }, { lowBufferSec: 2 }, 5_000),
    "buffer-stall",
  );
});

test("switches only the failed track and otherwise only active video", () => {
  const video = { kind: "video" };
  const audio = { kind: "audio" };
  assert.deepEqual(Core.selectSwitchTargets([video, audio], null), [video]);
  assert.deepEqual(Core.selectSwitchTargets([video, audio], audio), [audio]);
});

test("uses the same refill rule at low buffer and accepts one second growth", () => {
  const state = Core.createHealthState(0);
  const sample = { duration: 100, position: 25, buffered: 35, playing: true, ended: false };
  assert.equal(Core.evaluateHealth(state, sample, {}, 0), null);
  assert.equal(
    Core.evaluateHealth(state, { ...sample, buffered: 36 }, {}, 5_000),
    null,
  );
});

test("does not treat accepted play as a CDN stall before playback really starts", () => {
  const state = Core.createHealthState(0);
  const sample = {
    duration: 100,
    position: 0,
    buffered: 0,
    playing: true,
    hasStartedPlayback: false,
    ended: false,
  };
  assert.equal(Core.evaluateHealth(state, sample, {}, 0), null);
  assert.equal(Core.evaluateHealth(state, sample, {}, 30_000), null);
  assert.equal(
    Core.evaluateHealth(state, { ...sample, hasStartedPlayback: true }, {}, 30_001),
    null,
  );
  assert.equal(
    Core.evaluateHealth(state, { ...sample, hasStartedPlayback: true }, {}, 35_001),
    "buffer-stall",
  );
});

test("measures refill as forward-buffer net growth like the app", () => {
  const state = Core.createHealthState(0);
  const sample = { duration: 100, position: 10, buffered: 25, playing: true, ended: false };
  assert.equal(Core.evaluateHealth(state, sample, {}, 0), null);
  assert.equal(
    Core.evaluateHealth(state, { ...sample, position: 15, buffered: 26 }, {}, 5_000),
    "buffer-stall",
  );
});


test("does not switch only because playback position is stuck", () => {
  const state = Core.createHealthState(0);
  const sample = { duration: 100, position: 10, buffered: 50, playing: true, ended: false };
  assert.equal(Core.evaluateHealth(state, sample, {}, 0), null);
  assert.equal(Core.evaluateHealth(state, sample, {}, 30_000), null);
});

test("detects when audio advances without new video frames", () => {
  const sample = {
    playing: true,
    seeking: false,
    position: 12,
    lastFramePosition: 11.4,
    lastFrameAt: 0,
    forwardBuffer: 10,
    minForwardBuffer: 10,
  };
  assert.equal(
    Core.shouldPauseForVideoFrameStall(sample, 8_000),
    true,
  );
  assert.equal(
    Core.shouldPauseForVideoFrameStall({ ...sample, forwardBuffer: 9.999 }, 8_000),
    false,
  );
});

test("does not run frame-stall recovery before the first real playback frame", () => {
  const sample = {
    playing: true,
    hasStartedPlayback: false,
    seeking: false,
    position: 12,
    lastFramePosition: 11.4,
    lastFrameAt: 0,
    forwardBuffer: 10,
    minForwardBuffer: 10,
  };
  assert.equal(Core.shouldPauseForVideoFrameStall(sample, 30_000), false);
});

test("gives resumed playback a fresh video-frame grace period", () => {
  const sample = {
    playing: true,
    seeking: false,
    position: 12,
    lastFramePosition: 11.4,
    lastFrameAt: 0,
    playStartedAt: 1_000,
    forwardBuffer: 10,
    minForwardBuffer: 10,
  };
  assert.equal(Core.shouldPauseForVideoFrameStall(sample, 8_999), false);
  assert.equal(Core.shouldPauseForVideoFrameStall(sample, 9_000), true);
});

test("waits for the buffering recovery window before another frame switch", () => {
  const sample = {
    playing: true,
    seeking: false,
    position: 12,
    lastFramePosition: 11.4,
    lastFrameAt: 0,
    recoveryUntil: 9_000,
    forwardBuffer: 10,
    minForwardBuffer: 10,
  };
  assert.equal(Core.shouldPauseForVideoFrameStall(sample, 8_999), false);
  assert.equal(Core.shouldPauseForVideoFrameStall(sample, 9_000), true);
});

test("ignores request failures caused by an adaptive CDN abort", () => {
  assert.equal(Core.shouldSwitchForRequestFailure(503, false), true);
  assert.equal(Core.shouldSwitchForRequestFailure(403, false), true);
  assert.equal(Core.shouldSwitchForRequestFailure(204, false), true);
  assert.equal(Core.shouldSwitchForRequestFailure(200, false), false);
  assert.equal(Core.shouldSwitchForRequestFailure(206, false), false);
  assert.equal(Core.shouldSwitchForRequestFailure(503, true), false);
  assert.equal(Core.shouldSwitchForRequestFailure(null, true), false);
});

test("ignores a late failure from a CDN that is no longer current", () => {
  assert.equal(
    Core.isCurrentResourceFailure("https://new.example/video.m4s", "old.example"),
    false,
  );
  assert.equal(
    Core.isCurrentResourceFailure("https://new.example/video.m4s", "new.example"),
    true,
  );
});

test("pauses switching during a likely whole-network outage", () => {
  const state = Core.createNetworkGuardState();
  assert.equal(Core.shouldPauseNetworkSwitch(state, { host: "a", kind: "video" }, 0), false);
  assert.equal(Core.shouldPauseNetworkSwitch(state, { host: "a", kind: "video" }, 1_000), false);
  assert.equal(Core.shouldPauseNetworkSwitch(state, { host: "b", kind: "video" }, 2_000), true);
  assert.equal(Core.shouldPauseNetworkSwitch(state, { host: "b", kind: "audio" }, 21_999), true);
  assert.equal(Core.shouldPauseNetworkSwitch(state, { host: "b", kind: "audio" }, 22_000), false);
});

test("treats a seek jump like startup rebuffering instead of a CDN stall", () => {
  const state = Core.createHealthState(0);
  const settings = { lowBufferSec: 10, bufferStallSec: 4 };
  assert.equal(
    Core.evaluateHealth(
      state,
      { duration: 100, position: 10, buffered: 40, playing: true, ended: false },
      settings,
      0,
    ),
    null,
  );
  assert.equal(
    Core.evaluateHealth(
      state,
      { duration: 100, position: 70, buffered: 70, playing: true, ended: false },
      settings,
      1_000,
    ),
    null,
  );
  assert.equal(
    Core.evaluateHealth(
      state,
      { duration: 100, position: 70.5, buffered: 70, playing: true, ended: false },
      settings,
      4_999,
    ),
    null,
  );
  assert.equal(
    Core.evaluateHealth(
      state,
      { duration: 100, position: 70.5, buffered: 70, playing: true, ended: false },
      settings,
      5_000,
    ),
    null,
  );
  assert.equal(
    Core.evaluateHealth(
      state,
      { duration: 100, position: 70.5, buffered: 70, playing: true, ended: false },
      settings,
      8_999,
    ),
    "buffer-stall",
  );
});
test("a fully downloaded file is not complete after seeking to its start", () => {
  const state = Core.createHealthState(0);
  const sample = { duration: 100, position: 0, buffered: 100, playing: true, ended: false };
  assert.equal(Core.evaluateHealth(state, sample, {}, 20_000), null);
  assert.equal(Core.evaluateHealth(state, sample, {}, 40_000), null);
});

test("does not switch repeatedly while the final segment is playing", () => {
  const state = Core.createHealthState(0);
  const sample = { duration: 100, position: 96, buffered: 98, playing: true, ended: false };
  assert.equal(Core.evaluateHealth(state, sample, {}, 20_000), null);
  assert.equal(Core.evaluateHealth(state, sample, {}, 40_000), null);
});
