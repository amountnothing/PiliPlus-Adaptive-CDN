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
  assert.equal(Core.normalizeSettings({ preferAv1: false }).preferredCodec, "default");

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

test("uses the same refill rule at low buffer and accepts one second growth", () => {
  const state = Core.createHealthState(0);
  const sample = { duration: 100, position: 25, buffered: 35, playing: true, ended: false };
  assert.equal(Core.evaluateHealth(state, sample, {}, 0), null);
  assert.equal(
    Core.evaluateHealth(state, { ...sample, buffered: 36 }, {}, 5_000),
    null,
  );
});


test("does not switch only because playback position is stuck", () => {
  const state = Core.createHealthState(0);
  const sample = { duration: 100, position: 10, buffered: 50, playing: true, ended: false };
  assert.equal(Core.evaluateHealth(state, sample, {}, 0), null);
  assert.equal(Core.evaluateHealth(state, sample, {}, 30_000), null);
});

test("pauses the whole video when audio advances without new frames", () => {
  assert.equal(
    Core.shouldPauseForVideoFrameStall(
      { playing: true, seeking: false, position: 12, lastFramePosition: 11.4, lastFrameAt: 0 },
      1_500,
    ),
    true,
  );
  assert.equal(
    Core.shouldPauseForVideoFrameStall(
      { playing: true, seeking: false, position: 12, lastFramePosition: 11.4, lastFrameAt: 1 },
      1_500,
    ),
    false,
  );
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
test("does not classify the downloaded media tail as a CDN stall", () => {
  const state = Core.createHealthState(0);
  const sample = { duration: 100, position: 70, buffered: 99, playing: true, ended: false };
  assert.equal(Core.evaluateHealth(state, sample, {}, 20_000), null);
  assert.equal(Core.evaluateHealth(state, sample, {}, 40_000), null);
});
