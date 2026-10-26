(function () {
  "use strict";

  var bridge = (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.startup) || null;
  var params = new URLSearchParams(window.location.search);
  var body = document.body;
  var panel = document.getElementById("panel");
  var glass = document.getElementById("glass");
  var log = document.getElementById("log");
  var statusEl = document.getElementById("status");
  var hintEl = document.getElementById("hint");
  var elapsedEl = document.getElementById("elapsed");
  var progressEl = document.getElementById("progress");
  var liveDot = document.getElementById("liveDot");
  var safeChip = document.getElementById("safeChip");
  var errorEl = document.getElementById("error");
  var errorTitle = document.getElementById("errorTitle");
  var detailEl = document.getElementById("detail");
  var actionsEl = document.getElementById("actions");
  var skipEl = document.getElementById("skip");
  var previewBar = document.getElementById("previewBar");
  var replayEl = document.getElementById("replay");
  var failDemoEl = document.getElementById("failDemo");
  var slowToggleEl = document.getElementById("slowToggle");

  var rows = new Map();
  var startedAt = Date.now();
  var lastLogKey = "";
  var handoffStarted = false;
  var finished = false;
  var previewMode = false;
  var bridgeReady = false;
  var previewTimers = [];
  var currentSnapshot = null;
  var clock = null;

  var reduceQuery = window.matchMedia ? window.matchMedia("(prefers-reduced-motion: reduce)") : null;

  function nowSeconds() {
    return Math.max(0, Math.round((Date.now() - startedAt) / 1000));
  }

  function setReduced(on) {
    body.classList.toggle("reduce", !!on);
  }

  function post(message) {
    if (!bridge) return;
    try {
      bridge.postMessage(message);
    } catch (error) {
      /* The native layer is gone; stay usable as a preview. */
    }
  }

  function clearPreviewTimers() {
    previewTimers.forEach(function (timer) { clearTimeout(timer); });
    previewTimers = [];
  }

  function previewLater(fn, delay) {
    previewTimers.push(setTimeout(fn, delay));
  }

  function statusInfo(status, fallbackLabel, fallbackHint) {
    var table = {
      preparing: { label: "INITIALIZING", data: "initializing", hint: "正在准备启动…" },
      starting: { label: "INITIALIZING", data: "initializing", hint: "正在启动 Harness…" },
      waitingPage: { label: "LOADING UI", data: "loading", hint: "服务已就绪，正在加载页面…" },
      ready: { label: "READY", data: "ready", hint: "页面已就绪，正在交接…" },
      failedBoot: { label: "FAILED", data: "failed", hint: "启动没有完成" },
      failedPage: { label: "FAILED", data: "failed", hint: "页面没有加载成功" }
    };
    var found = table[status] || table.starting;
    return {
      label: fallbackLabel || found.label,
      data: found.data,
      hint: fallbackHint || found.hint
    };
  }

  function makeLogRow() {
    var row = document.createElement("li");
    row.className = "log-row";
    row.dataset.state = "neutral";
    var mark = document.createElement("span");
    mark.className = "mark";
    var text = document.createElement("span");
    text.className = "text";
    var badge = document.createElement("span");
    badge.className = "badge";
    row.appendChild(mark);
    row.appendChild(text);
    row.appendChild(badge);
    return row;
  }

  function updateLogRow(row, item) {
    var text = row.querySelector(".text");
    var badge = row.querySelector(".badge");
    var full = item.title || item.text || "";
    text.textContent = item.text || "";
    text.title = full;
    row.title = full;
    row.dataset.state = item.state || "neutral";
    badge.textContent = item.badge || "";
  }

  function renderLogs(items) {
    items = Array.isArray(items) ? items : [];
    var key = items.map(function (item) {
      return [item.id, item.text, item.state, item.badge].join("\u0000");
    }).join("\u0001");
    if (key === lastLogKey) return;
    lastLogKey = key;

    var wanted = new Set(items.map(function (item) { return String(item.id); }));
    rows.forEach(function (row, id) {
      if (!wanted.has(id)) {
        row.remove();
        rows.delete(id);
      }
    });

    var empty = log.querySelector(".log-empty");
    if (empty) empty.remove();

    items.forEach(function (item, index) {
      var id = String(item.id);
      var row = rows.get(id);
      if (!row) {
        row = makeLogRow();
        rows.set(id, row);
      }
      updateLogRow(row, item);
      var reference = log.children[index] || null;
      if (reference !== row) {
        log.insertBefore(row, reference);
      }
    });

    if (!items.length) {
      var placeholder = document.createElement("li");
      placeholder.className = "log-empty";
      placeholder.textContent = "正在收集启动输出…";
      log.appendChild(placeholder);
    }
  }

  function renderActions(actions) {
    actionsEl.textContent = "";
    if (!Array.isArray(actions) || !actions.length) return;
    actions.forEach(function (action) {
      var button = document.createElement("button");
      button.type = "button";
      button.dataset.action = action.id;
      button.textContent = action.label || action.id;
      if (action.kind === "primary") button.className = "primary";
      if (action.kind === "danger") button.className = "danger";
      if (currentSnapshot && currentSnapshot.isBusy) button.disabled = true;
      actionsEl.appendChild(button);
    });
  }

  function renderError(snapshot) {
    var failed = snapshot.status === "failedBoot" || snapshot.status === "failedPage";
    if (!failed) {
      errorEl.hidden = true;
      return;
    }
    errorEl.hidden = false;
    errorTitle.textContent = snapshot.status === "failedPage"
      ? "页面没有加载成功"
      : "启动没有完成";
    detailEl.textContent = snapshot.detail || "没有更多诊断信息。";
    renderActions(snapshot.actions || []);
  }

  function applySnapshot(snapshot) {
    if (!snapshot || finished) return;
    if (previewMode && !snapshot.preview) {
      // A native snapshot means this is no longer a mock preview.
      previewMode = false;
      clearPreviewTimers();
      previewBar.hidden = true;
      body.classList.remove("preview");
    }
    currentSnapshot = snapshot;
    setReduced(snapshot.reduceMotion === true || (reduceQuery && reduceQuery.matches));

    var info = statusInfo(snapshot.status, snapshot.statusLabel, snapshot.hint);
    statusEl.textContent = info.label;
    panel.dataset.status = info.data;
    progressEl.dataset.state = info.data === "ready" ? "ready" : (info.data === "failed" ? "failed" : "running");
    hintEl.textContent = snapshot.hint || info.hint;
    safeChip.hidden = !snapshot.safeMode;

    var elapsed = typeof snapshot.elapsed === "number" ? Math.floor(snapshot.elapsed) : nowSeconds();
    elapsedEl.textContent = elapsed + "s";

    renderLogs(snapshot.logs || []);
    renderError(snapshot);

    if (snapshot.status === "ready" && !handoffStarted && elapsed >= 1.4) {
      beginHandoff();
    }
  }

  function prepareHandoff() {
    if (handoffStarted || finished) return;
    if (currentSnapshot && (currentSnapshot.status === "failedBoot" || currentSnapshot.status === "failedPage")) {
      return;
    }
    handoffStarted = true;

    if (body.classList.contains("reduce")) {
      body.classList.add("handoff");
      setTimeout(finishHandoff, 220);
      return;
    }

    var rect = panel.getBoundingClientRect();
    glass.style.clipPath = "inset(" + rect.top + "px " + (window.innerWidth - rect.right) + "px " +
      (window.innerHeight - rect.bottom) + "px " + rect.left + "px round var(--panel-radius))";
    body.classList.add("handoff");
    // Force the initial clip to be committed before the target is applied.
    void glass.offsetWidth;
    requestAnimationFrame(function () {
      glass.style.clipPath = "inset(0px 0px 0px 0px round 0px)";
      setTimeout(finishHandoff, 460);
    });
  }

  function finishHandoff() {
    if (finished) return;
    finished = true;
    post({ type: "handoff" });
    if (!bridge) {
      body.classList.add("preview-done");
      hintEl.textContent = "交接完成";
      previewBar.hidden = false;
    }
  }

  function beginHandoff() {
    if (handoffStarted || finished) return;
    if (currentSnapshot && (currentSnapshot.status === "failedBoot" || currentSnapshot.status === "failedPage")) {
      return;
    }
    prepareHandoff();
  }

  function skip() {
    if (finished) return;
    if (handoffStarted) return;
    if (currentSnapshot && currentSnapshot.status === "ready") {
      beginHandoff();
      return;
    }
    body.classList.add("skip-brand");
    skipEl.disabled = true;
    skipEl.textContent = "已跳过动画";
  }

  function handleAction(id) {
    if (!id) return;
    if (previewMode) {
      if (id === "retryBoot") resetPreview();
      return;
    }
    post({ type: "action", id: id });
  }

  /* ── preview ─────────────────────────────────────────────────────────── */

  function sampleLogs(progress) {
    var base = [
      { text: "Booting the web profile…", state: "done", badge: "完成" },
      { text: "Resolving the Node toolchain…", state: "done", badge: "完成" },
      { text: "Node v24.10.0 at /Users/example/.nativeharness/runtime/node/bin/node", state: "done", badge: "完成" },
      { text: "Harness entry: /Users/example/.nativeharness/harness/releases/0.2.0-rc.2/node_modules/.bin/dsh", state: "done", badge: "完成" },
      { text: "Starting: node --profile web --host 127.0.0.1 --port 51234 --no-open", state: "active", badge: "运行中" },
      { text: "Waiting for the harness to announce its address (up to 120s)…", state: "active", badge: "运行中" }
    ];
    if (progress >= 1) {
      base[4].state = "done";
      base[4].badge = "完成";
      base[5].state = "done";
      base[5].badge = "完成";
      base.push({ text: "harness is listening on port 51234", state: "done", badge: "完成" });
      base.push({ text: "Loading the harness page…", state: "active", badge: "运行中" });
    }
    if (progress >= 2) {
      base[6].state = "done";
      base[6].badge = "完成";
      base[7].state = "done";
      base[7].badge = "完成";
      base.push({ text: "page loaded: DeepSeek Harness", state: "done", badge: "完成" });
      base.push({ text: "page ready", state: "done", badge: "完成" });
    }
    return base.map(function (item, index) {
      return {
        id: index,
        text: item.text,
        title: item.text,
        state: item.state,
        badge: item.badge
      };
    });
  }

  function mockSnapshot(status, progress, extra) {
    var info = statusInfo(status);
    var snapshot = {
      status: status,
      statusLabel: info.label,
      logs: sampleLogs(progress),
      detail: null,
      elapsed: nowSeconds(),
      hint: info.hint,
      actions: [],
      pageReady: status === "ready",
      safeMode: false,
      preview: true,
      reduceMotion: body.classList.contains("reduce"),
      isBusy: false
    };
    if (extra) {
      Object.keys(extra).forEach(function (key) { snapshot[key] = extra[key]; });
    }
    return snapshot;
  }

  function resetPreview() {
    clearPreviewTimers();
    handoffStarted = false;
    finished = false;
    currentSnapshot = null;
    startedAt = Date.now();
    lastLogKey = "";
    rows.forEach(function (row) { row.remove(); });
    rows.clear();
    log.textContent = "";
    body.classList.remove("handoff", "skip-brand", "preview-done");
    glass.style.clipPath = "";
    glass.style.opacity = "";
    skipEl.disabled = false;
    skipEl.textContent = "跳过动画";
    errorEl.hidden = true;
    actionsEl.textContent = "";
    applySnapshot(mockSnapshot("starting", 0));
    previewLater(function () {
      applySnapshot(mockSnapshot("starting", 1));
    }, 1200);
    previewLater(function () {
      applySnapshot(mockSnapshot("waitingPage", 1));
    }, 2500);
    previewLater(function () {
      applySnapshot(mockSnapshot("ready", 2));
    }, 3800);
    previewLater(function () {
      beginHandoff();
    }, 4500);
  }

  function startPreview() {
    previewMode = true;
    body.classList.add("preview");
    previewBar.hidden = false;
    resetPreview();
  }

  function failDemo() {
    if (!previewMode) return;
    clearPreviewTimers();
    handoffStarted = false;
    finished = false;
    startedAt = Date.now();
    var snapshot = mockSnapshot("failedBoot", 1, {
      detail: "The harness exited with code 1.\n" +
        "Error: profile bundle dsh-example failed to load\n" +
        "    at loadBundle (/Users/example/.nativeharness/harness/releases/0.2.0-rc.2/node_modules/@deepseek-ai/dsh/lib/loader.js:42:15)\n" +
        "\nThis is example output for the failure-state preview.",
      hint: "启动没有完成",
      actions: [
        { id: "retryBoot", label: "重试", kind: "primary" },
        { id: "openRecovery", label: "打开恢复模式", kind: "secondary" },
        { id: "disablePlugins", label: "禁用可疑插件", kind: "danger" }
      ]
    });
    applySnapshot(snapshot);
  }

  /* ── wiring ──────────────────────────────────────────────────────────── */

  skipEl.addEventListener("click", skip);
  actionsEl.addEventListener("click", function (event) {
    var button = event.target.closest("button[data-action]");
    if (!button) return;
    handleAction(button.dataset.action);
  });
  replayEl.addEventListener("click", function () {
    if (previewMode) resetPreview();
    else startPreview();
  });
  failDemoEl.addEventListener("click", failDemo);
  slowToggleEl.addEventListener("click", function () {
    body.classList.toggle("slow");
    slowToggleEl.textContent = body.classList.contains("slow") ? "1×" : "0.25×";
  });

  document.addEventListener("keydown", function (event) {
    if (event.key === "Escape") {
      event.preventDefault();
      skip();
    }
  });

  window.addEventListener("resize", function () {
    if (handoffStarted || finished) return;
    // Nothing to recompute before handoff; the glass is hidden until it starts.
  });

  window.dshStartup = {
    update: applySnapshot,
    beginHandoff: beginHandoff,
    startPreview: startPreview
  };

  function preloadAssets() {
    var sources = [
      "assets/brand-icon.png",
      "assets/rider.jpg"
    ];
    return Promise.all(sources.map(function (source) {
      return new Promise(function (resolve) {
        var image = new Image();
        image.onload = function () {
          if (image.decode) {
            image.decode().then(resolve, resolve);
          } else {
            resolve();
          }
        };
        image.onerror = resolve;
        image.src = source;
      });
    }));
  }

  function startExperience() {
    body.classList.remove("booting");
    if (bridge) {
      post({ type: "ready" });
      bridgeReady = true;
    } else if (params.get("preview") === "1") {
      startPreview();
    } else {
      setTimeout(startPreview, 120);
    }
  }

  function boot() {
    if (reduceQuery) setReduced(reduceQuery.matches);
    if (reduceQuery && reduceQuery.addEventListener) {
      reduceQuery.addEventListener("change", function (event) { setReduced(event.matches); });
    }
    preloadAssets().then(startExperience);
    clock = setInterval(function () {
      if (finished) return;
      if (currentSnapshot && typeof currentSnapshot.elapsed === "number") {
        var current = nowSeconds();
        if (current > currentSnapshot.elapsed) {
          elapsedEl.textContent = current + "s";
        }
      } else {
        elapsedEl.textContent = nowSeconds() + "s";
      }
    }, 500);
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", boot, { once: true });
  } else {
    boot();
  }
})();
