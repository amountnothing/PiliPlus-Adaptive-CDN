(async function () {
  "use strict";

  const Core = globalThis.PiliPlusAdaptiveCdnCore;
  const controls = [...document.querySelectorAll("[data-setting]")];
  const saved = document.getElementById("saved");
  let saveTimer = 0;

  const stored = await chrome.storage.local.get(["settings", "scores"]);
  let settings = Core.normalizeSettings(stored.settings);

  function fillControls() {
    for (const control of controls) {
      const key = control.dataset.setting;
      if (control.type === "checkbox") control.checked = Boolean(settings[key]);
      else control.value = settings[key];
    }
  }

  function renderScores(scores) {
    const list = document.getElementById("scores");
    const entries = Object.entries(scores || {}).sort((a, b) => b[1] - a[1]);
    if (!entries.length) {
      list.innerHTML = "<p>尚无评分记录。</p>";
      return;
    }
    list.replaceChildren(
      ...entries.map(([host, score]) => {
        const row = document.createElement("div");
        const name = document.createElement("span");
        const value = document.createElement("strong");
        name.textContent = host;
        value.textContent = Number(score).toFixed(0);
        row.append(name, value);
        return row;
      }),
    );
  }

  async function save() {
    const next = { ...settings };
    for (const control of controls) {
      next[control.dataset.setting] = control.type === "checkbox"
        ? control.checked
        : control.tagName === "SELECT"
          ? control.value
          : Number(control.value);
    }
    settings = Core.normalizeSettings(next);
    await chrome.storage.local.set({ settings });
    saved.textContent = "已保存";
    clearTimeout(saveTimer);
    saveTimer = setTimeout(() => (saved.textContent = "设置会自动保存"), 1200);
  }

  for (const control of controls) control.addEventListener("change", save);
  document.getElementById("reset-scores").addEventListener("click", async () => {
    await chrome.storage.local.set({ scores: {}, cooldowns: {} });
    renderScores({});
    saved.textContent = "评分已重置";
  });

  fillControls();
  renderScores(stored.scores);
})();
