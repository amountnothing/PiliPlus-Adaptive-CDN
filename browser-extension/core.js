(function (root, factory) {
  const api = factory();
  root.PiliPlusAdaptiveCdnCore = api;
  if (typeof module === "object" && module.exports) module.exports = api;
})(typeof globalThis === "object" ? globalThis : this, function () {
  "use strict";

  const DEFAULT_SETTINGS = Object.freeze({
    enabled: true,
    preferredCodec: "hevc",
    expandKnownUpos: true,
    targetBufferSec: 30,
    segmentToleranceSec: 10,
    lowBufferSec: 10,
    bufferStallSec: 10,
    endToleranceSec: 2,
    cooldownSec: 30,
    traverseAllCdns: true,
    maxSwitches: 3,
    stableRewardSec: 30,
  });

  // These hosts accept the same signed /upgcxcode/ path. Keep this bounded to
  // nodes verified with HTTP 206 + Bilibili CORS instead of guessing domains.
  const KNOWN_UPOS_HOSTS = Object.freeze([
    "upos-sz-mirrorali.bilivideo.com",
    "upos-sz-mirroralib.bilivideo.com",
    "upos-sz-mirroralio1.bilivideo.com",
    "upos-sz-mirrorcos.bilivideo.com",
    "upos-sz-mirrorcosb.bilivideo.com",
    "upos-sz-mirrorcoso1.bilivideo.com",
    "upos-sz-mirrorhw.bilivideo.com",
    "upos-sz-mirrorhwb.bilivideo.com",
    "upos-sz-mirrorhwo1.bilivideo.com",
    "upos-sz-mirroraliov.bilivideo.com",
    "upos-sz-mirrorcosov.bilivideo.com",
    "upos-hz-mirrorakam.akamaized.net",
  ]);

  const NUMBER_RANGES = Object.freeze({
    targetBufferSec: [5, 120],
    segmentToleranceSec: [0, 30],
    lowBufferSec: [2, 30],
    bufferStallSec: [2, 60],
    endToleranceSec: [0, 10],
    cooldownSec: [0, 600],
    maxSwitches: [1, 50],
    stableRewardSec: [10, 300],
  });

  function clamp(value, min, max) {
    return Math.min(max, Math.max(min, value));
  }

  function normalizeSettings(input) {
    const source = input && typeof input === "object" ? input : {};
    const output = { ...DEFAULT_SETTINGS };
    for (const key of ["enabled", "preferAv1", "expandKnownUpos", "traverseAllCdns"]) {
      if (typeof source[key] === "boolean") output[key] = source[key];
    }
    if (["av1", "hevc", "avc", "default"].includes(source.preferredCodec)) {
      output.preferredCodec = source.preferredCodec;
    } else if (source.preferAv1 === false) {
      output.preferredCodec = "default";
    }
    for (const [key, [min, max]] of Object.entries(NUMBER_RANGES)) {
      const value = Number(source[key]);
      if (Number.isFinite(value)) output[key] = clamp(value, min, max);
    }
    return output;
  }

  function hostOf(value) {
    try {
      return new URL(String(value), "https://www.bilibili.com").hostname;
    } catch (_) {
      return "";
    }
  }

  function resourceKey(value) {
    try {
      const url = new URL(String(value), "https://www.bilibili.com");
      return url.pathname;
    } catch (_) {
      return "";
    }
  }

  function isMediaUrl(value) {
    const host = hostOf(value);
    if (!host) return false;
    return (
      host.endsWith(".bilivideo.com") ||
      host.endsWith(".bilivideo.cn") ||
      host.endsWith(".akamaized.net")
    );
  }

  function isPlayUrlApi(value) {
    try {
      const url = new URL(String(value), "https://www.bilibili.com");
      return (
        /(^|\/)playurl(?:v2)?(?:\/|$)/i.test(url.pathname) ||
        /\/player\/(?:wbi\/)?playurl/i.test(url.pathname)
      );
    } catch (_) {
      return false;
    }
  }

  function uniqueUrls(values) {
    const result = [];
    const seen = new Set();
    for (const value of values || []) {
      if (typeof value !== "string" || !isMediaUrl(value) || seen.has(value)) {
        continue;
      }
      seen.add(value);
      result.push(value);
    }
    return result;
  }

  function expandUposCandidates(values, enabled = true) {
    const source = uniqueUrls(values);
    if (!enabled) return source;
    const template = source.find((value) => {
      try {
        return new URL(value).pathname.startsWith("/upgcxcode/");
      } catch (_) {
        return false;
      }
    });
    if (!template) return source;
    const expanded = [...source];
    for (const host of KNOWN_UPOS_HOSTS) {
      const url = new URL(template);
      url.hostname = host;
      url.port = "";
      url.protocol = "https:";
      expanded.push(url.toString());
    }
    return uniqueUrls(expanded);
  }

  function scoreOf(scores, urlOrHost) {
    const host = urlOrHost.includes?.("://") ? hostOf(urlOrHost) : urlOrHost;
    const value = Number(scores?.[host]);
    return Number.isFinite(value) ? value : 50;
  }

  function rankCandidates(values, scores, cooldowns, failedHosts, now = Date.now()) {
    return uniqueUrls(values)
      .map((url, index) => ({ url, index, host: hostOf(url) }))
      .filter(({ host }) => {
        if (!host || failedHosts?.has(host)) return false;
        return Number(cooldowns?.[host] || 0) <= now;
      })
      .sort((a, b) => scoreOf(scores, b.host) - scoreOf(scores, a.host) || a.index - b.index)
      .map(({ url }) => url);
  }

  function streamUrls(stream) {
    if (!stream || typeof stream !== "object") return [];
    const base = stream.baseUrl || stream.base_url;
    const backup = stream.backupUrl || stream.backup_url || [];
    return uniqueUrls([base, ...(Array.isArray(backup) ? backup : [backup])]);
  }

  function collectStreams(rootValue) {
    const streams = [];
    const visited = new Set();
    function walk(value, depth) {
      if (!value || typeof value !== "object" || depth > 9 || visited.has(value)) return;
      visited.add(value);
      if (streamUrls(value).length) streams.push(value);
      if (Array.isArray(value)) {
        for (const item of value) walk(item, depth + 1);
      } else {
        for (const child of Object.values(value)) walk(child, depth + 1);
      }
    }
    walk(rootValue, 0);
    return streams;
  }

  function isAv1Codec(codec) {
    return /^av01/i.test(String(codec || ""));
  }

  function codecFamily(codec) {
    const value = String(codec || "").toLowerCase();
    if (value.startsWith("av01")) return "av1";
    if (value.startsWith("hev1") || value.startsWith("hvc1")) return "hevc";
    if (value.startsWith("avc1")) return "avc";
    return "";
  }

  function reorderVideoArrays(rootValue, preferredCodec, canPlayCodec) {
    if (preferredCodec === true) preferredCodec = "av1";
    if (!preferredCodec || preferredCodec === "default" || !rootValue || typeof rootValue !== "object") return;
    const visited = new Set();
    function walk(value, depth) {
      if (!value || typeof value !== "object" || depth > 8 || visited.has(value)) return;
      visited.add(value);
      if (Array.isArray(value.video) && value.video.some((item) => codecFamily(item?.codecs) === preferredCodec)) {
        value.video.sort((a, b) => {
          if (a?.id !== b?.id) return Number(b?.id || 0) - Number(a?.id || 0);
          return (
            Number(canPlayCodec?.(b?.codecs) && codecFamily(b?.codecs) === preferredCodec) -
            Number(canPlayCodec?.(a?.codecs) && codecFamily(a?.codecs) === preferredCodec)
          );
        });
      }
      for (const child of Object.values(value)) walk(child, depth + 1);
    }
    walk(rootValue, 0);
  }

  function createHealthState(now = 0) {
    return {
      lastBuffered: 0,
      lastBufferProgressAt: now,
      bufferBelowTarget: false,
      lowBufferArmed: false,
      lastPosition: 0,
      lastPositionProgressAt: now,
      lastSwitchAt: -Infinity,
    };
  }

  function resetAtMediaTail(state, sample, now) {
    state.lastBuffered = sample.buffered;
    state.lastBufferProgressAt = now;
    state.bufferBelowTarget = false;
    state.lowBufferArmed = false;
    state.lastPosition = sample.position;
    state.lastPositionProgressAt = now;
  }

  function evaluateHealth(state, sample, rawSettings, now) {
    const settings = normalizeSettings(rawSettings);
    const duration = Number(sample.duration) || 0;
    const position = Number(sample.position) || 0;
    const buffered = Math.max(position, Number(sample.buffered) || 0);
    const trying = Boolean(sample.playing) && !sample.ended;
    const atTail =
      duration > 0 && Math.max(position, buffered) + settings.endToleranceSec >= duration;

    if (atTail) {
      resetAtMediaTail(state, { position, buffered }, now);
      return null;
    }

    const positionDelta = Math.abs(position - state.lastPosition);
    if (positionDelta >= 0.25 || !trying) {
      state.lastPosition = position;
      state.lastPositionProgressAt = now;
    }


    if (buffered < state.lastBuffered || buffered - state.lastBuffered >= 0.25) {
      state.lastBuffered = buffered;
      state.lastBufferProgressAt = now;
    }

    const forward = Math.max(0, buffered - position);
    if (forward > settings.lowBufferSec) {
      state.lowBufferArmed = true;
    } else if (
      trying &&
      (state.lowBufferArmed || now - state.lastSwitchAt >= settings.bufferStallSec * 1000)
    ) {
      state.lowBufferArmed = false;
      state.lastSwitchAt = now;
      return "low-buffer";
    }

    const targetFloor = Math.max(
      settings.lowBufferSec,
      settings.targetBufferSec - settings.segmentToleranceSec,
    );
    if (forward >= targetFloor) {
      state.bufferBelowTarget = false;
      return null;
    }
    if (!state.bufferBelowTarget) {
      state.bufferBelowTarget = true;
      state.lastBufferProgressAt = now;
      return null;
    }
    if (trying && now - state.lastBufferProgressAt >= settings.bufferStallSec * 1000) {
      state.lastSwitchAt = now;
      return "buffer-stall";
    }
    return null;
  }

  return Object.freeze({
    DEFAULT_SETTINGS,
    KNOWN_UPOS_HOSTS,
    normalizeSettings,
    hostOf,
    resourceKey,
    isMediaUrl,
    isPlayUrlApi,
    uniqueUrls,
    expandUposCandidates,
    scoreOf,
    rankCandidates,
    streamUrls,
    collectStreams,
    isAv1Codec,
    codecFamily,
    reorderVideoArrays,
    createHealthState,
    evaluateHealth,
  });
});
