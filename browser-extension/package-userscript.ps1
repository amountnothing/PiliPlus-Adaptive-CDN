$ErrorActionPreference = 'Stop'

$extensionRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $extensionRoot
$dist = Join-Path $repoRoot 'dist'
$output = Join-Path $dist 'PiliPlus-Adaptive-CDN-Web.user.js'

if (!(Test-Path -LiteralPath $dist)) {
    New-Item -ItemType Directory -Path $dist | Out-Null
}

$manifest = Get-Content -LiteralPath (Join-Path $extensionRoot 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$core = Get-Content -LiteralPath (Join-Path $extensionRoot 'core.js') -Raw -Encoding UTF8
$page = Get-Content -LiteralPath (Join-Path $extensionRoot 'page.js') -Raw -Encoding UTF8

$meta = @"
// ==UserScript==
// @name         PiliPlus Adaptive CDN for Web
// @namespace    https://github.com/amountnothing/PiliPlus-Adaptive-CDN
// @version      $($manifest.version)
// @description  Adaptive CDN optimization for bilibili web video playback.
// @match        *://www.bilibili.com/video/*
// @match        *://www.bilibili.com/bangumi/play/*
// @run-at       document-start
// @inject-into  page
// @grant        none
// ==/UserScript==

"@

$bridge = @'
(function () {
  "use strict";
  const BRIDGE_SOURCE = "pili-adaptive-cdn-bridge";
  const PAGE_SOURCE = "pili-adaptive-cdn-page";
  const KEY_PREFIX = "piliPlusAdaptiveCdn:";
  function readJson(key, fallback) {
    try {
      const raw = localStorage.getItem(KEY_PREFIX + key);
      return raw ? JSON.parse(raw) : fallback;
    } catch (_) {
      return fallback;
    }
  }
  function writeJson(key, value) {
    try {
      localStorage.setItem(KEY_PREFIX + key, JSON.stringify(value || {}));
    } catch (_) {}
  }
  function post(type, payload) {
    window.postMessage({ source: BRIDGE_SOURCE, type, payload }, "*");
  }
  window.addEventListener("message", (event) => {
    if (event.source !== window || event.data?.source !== PAGE_SOURCE) return;
    if (event.data.type === "ready") {
      post("config", {
        settings: readJson("settings", {}),
        scores: readJson("scores", {}),
        cooldowns: readJson("cooldowns", {}),
      });
    } else if (event.data.type === "scores") {
      writeJson("scores", event.data.payload);
    } else if (event.data.type === "cooldowns") {
      writeJson("cooldowns", event.data.payload);
    }
  });
})();
'@

Set-Content -LiteralPath $output -Value ($meta + $core + "`r`n" + $page + "`r`n" + $bridge) -Encoding UTF8
Write-Output $output
