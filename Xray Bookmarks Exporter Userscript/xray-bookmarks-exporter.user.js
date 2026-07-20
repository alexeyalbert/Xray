// ==UserScript==
// @name         Xray Bookmarks Exporter
// @namespace    https://alexeyalbert.com/xray
// @version      0.4.1
// @description  Capture X bookmarks in your normal browser session and stream or export them in Xray's import format.
// @author       Xray
// @license      MIT
// @match        https://x.com/i/bookmarks*
// @match        https://twitter.com/i/bookmarks*
// @run-at       document-start
// @inject-into  auto
// @grant        GM_xmlhttpRequest
// @grant        GM_getValue
// @grant        GM_setValue
// @connect      127.0.0.1
// @connect      localhost
// @connect      ::1
// ==/UserScript==

// Based in part on prinsss/twitter-web-exporter by prin.
// Copyright (c) 2023 prin. MIT licensed; see THIRD_PARTY_NOTICES.md.

(function () {
  "use strict";

  const PANEL_ID = "xray-bookmarks-exporter-panel";
  const DEFAULT_SCROLL_PIXELS_PER_SECOND = 4800;
  const MIN_SCROLL_PIXELS_PER_SECOND = 900;
  const MAX_SCROLL_PIXELS_PER_SECOND = 12000;
  const IDLE_CHECK_INTERVAL_MS = 1200;
  const MAX_IDLE_SCROLLS = 30;
  const SCROLL_PROGRESS_EPSILON_PX = 24;
  const MAX_DIRECT_FETCH_EMPTY_PAGES = 3;
  const RESPONSE_STALE_AFTER_MS = 1800;
  const RESPONSE_RECENT_AFTER_MS = 700;
  const RATE_LIMIT_COOLDOWN_MS = 65000;
  const RATE_LIMIT_LOAD_MORE_SETTLE_MS = 1500;
  const STREAM_BATCH_SIZE = 100;
  const STREAM_RETRY_DELAY_MS = 3000;
  const STREAM_MAX_RETRY_DELAY_MS = 15000;
  const STREAM_REQUEST_TIMEOUT_MS = 8000;
  const STREAM_BACKPRESSURE_LIMIT = 1000;
  const CONSECUTIVE_EXISTING_STOP_THRESHOLD = 200;
  const DOM_PRUNE_INTERVAL_MS = 2500;
  const DOM_PRUNE_KEEP_BEHIND_VIEWPORTS = 5;
  const STORAGE_KEYS = {
    autoScroll: "xrayBookmarks.autoScrollEnabled",
    prunePage: "xrayBookmarks.prunePageEnabled",
    maxSpeed: "xrayBookmarks.maxScrollSpeed",
    receiverURL: "xrayBookmarks.receiverURL",
    sessionToken: "xrayBookmarks.sessionToken",
    jsonExportPosts: "xrayBookmarks.jsonExportPosts",
    bookmarkRequestTemplate: "xrayBookmarks.bookmarkRequestTemplate",
    nextBookmarkCursor: "xrayBookmarks.nextBookmarkCursor",
  };

  const persistedJsonExportPosts = readStoredExportPosts();

  const state = {
    mode: "idle",
    autoScrollEnabled: readBoolean(STORAGE_KEYS.autoScroll, true),
    prunePageEnabled: readBoolean(STORAGE_KEYS.prunePage, true),
    maxScrollSpeed: Math.min(MAX_SCROLL_PIXELS_PER_SECOND, Math.max(MIN_SCROLL_PIXELS_PER_SECOND, readNumber(STORAGE_KEYS.maxSpeed, DEFAULT_SCROLL_PIXELS_PER_SECOND))),
    adaptiveSpeed: Math.min(MAX_SCROLL_PIXELS_PER_SECOND, Math.max(MIN_SCROLL_PIXELS_PER_SECOND, readNumber(STORAGE_KEYS.maxSpeed, DEFAULT_SCROLL_PIXELS_PER_SECOND))),
    posts: new Map(),
    seenPostIds: new Set(),
    capturedPostCount: 0,
    jsonExportPosts: persistedJsonExportPosts,
    jsonExportHadStoredPosts: persistedJsonExportPosts.size > 0,
    jsonExportUnanchoredInsertIndex: null,
    jsonExportPersistTimer: null,
    scrollAnimationFrame: null,
    idleCheckTimer: null,
    rateLimitTimer: null,
    domPruneTimer: null,
    rateLimitResumeAt: 0,
    retryTimer: null,
    lastScrollFrameAt: 0,
    lastObservedScrollY: 0,
    idleScrolls: 0,
    previousCount: 0,
    bookmarkResponseCount: 0,
    lastResponseAt: 0,
    lastActivityText: "Waiting for Start.",
    lastErrorText: "",
    uiReady: false,
    statusElements: null,
    receiverURL: readString(STORAGE_KEYS.receiverURL, ""),
    sessionToken: readString(STORAGE_KEYS.sessionToken, ""),
    browserSessionId: createSessionId(),
    streamingEnabled: false,
    connectionState: "disconnected",
    connectionDetailText: "Streaming idle.",
    isConnecting: false,
    isSending: false,
    pendingPostIds: [],
    pendingPostIdSet: new Set(),
    inFlightPostIds: [],
    inFlightPostIdSet: new Set(),
    inFlightBatch: null,
    nextBatchSequence: 1,
    batchesAttempted: 0,
    batchesAcked: 0,
    ackedPostIds: new Set(),
    receiverAcceptedCount: 0,
    receiverInsertedCount: 0,
    receiverSkippedExistingCount: 0,
    consecutiveSkippedExistingCount: 0,
    stoppedAfterExistingStreak: false,
    lastSuccessfulSendText: "No batches sent yet.",
    retryDelayMs: STREAM_RETRY_DELAY_MS,
    shouldNotifyCompletion: false,
    prunedPostObjectsCount: 0,
    prunedDOMNodesCount: 0,
    originalFetch: null,
    bookmarkRequestTemplate: readJSONStorage(STORAGE_KEYS.bookmarkRequestTemplate, null),
    nextBookmarkCursor: readString(STORAGE_KEYS.nextBookmarkCursor, ""),
    isDirectFetchingBookmarks: false,
    directFetchEmptyPages: 0,
    uiView: "setup",
    captureDestination: "stream",
  };

  installNetworkHooks();
  bootstrapUI();

  function installNetworkHooks() {
    const originalFetch = window.fetch.bind(window);
    state.originalFetch = originalFetch;
    window.fetch = async (...args) => {
      void rememberBookmarkFetchRequest(args);
      const response = await originalFetch(...args);
      tryHandleResponse(extractURLFromFetchArgs(args), () => response.clone().json(), {
        status: response.status,
        statusText: response.statusText,
      });
      return response;
    };

    const originalOpen = XMLHttpRequest.prototype.open;
    const originalSend = XMLHttpRequest.prototype.send;

    XMLHttpRequest.prototype.open = function open(method, url, ...rest) {
      this.__xrayMethod = method;
      this.__xrayURL = typeof url === "string" ? url : String(url);
      return originalOpen.call(this, method, url, ...rest);
    };

    XMLHttpRequest.prototype.send = function send(...args) {
      rememberBookmarkXHRRequest(this.__xrayMethod, this.__xrayURL, args[0]);
      this.addEventListener("load", () => {
        tryHandleResponse(this.__xrayURL, () => {
          if (!this.responseText) {
            return null;
          }
          return JSON.parse(this.responseText);
        }, {
          status: this.status,
          statusText: this.statusText,
        });
      });
      return originalSend.apply(this, args);
    };
  }

  function bootstrapUI() {
    if (document.readyState === "loading") {
      document.addEventListener("DOMContentLoaded", mountPanel, { once: true });
    } else {
      mountPanel();
    }
  }

  function mountPanel() {
    if (document.getElementById(PANEL_ID)) {
      return;
    }

    const panel = document.createElement("div");
    panel.id = PANEL_ID;
    panel.style.cssText = [
      "position:fixed",
      "right:16px",
      "bottom:16px",
      "z-index:2147483647",
      "width:340px",
      "max-height:min(85vh,920px)",
      "overflow:auto",
      "padding:16px",
      "border-radius:16px",
      "background:rgba(20,20,24,0.94)",
      "color:#f5f5f7",
      "font:12px/1.45 -apple-system,BlinkMacSystemFont,Segoe UI,system-ui,sans-serif",
      "box-shadow:0 18px 48px rgba(0,0,0,0.35)",
      "backdrop-filter:blur(16px)",
      "border:1px solid rgba(255,255,255,0.08)",
    ].join(";");

    panel.innerHTML = `
      <div style="display:flex;align-items:center;justify-content:space-between;gap:12px;margin-bottom:14px;">
        <strong style="font-size:15px;letter-spacing:-0.01em;">Xray Bookmarks</strong>
        <span id="xray-destination-badge" style="display:none;padding:4px 8px;border-radius:999px;background:rgba(125,183,255,0.14);color:#9ac9ff;font-size:10px;font-weight:700;"></span>
      </div>

      <section id="xray-setup-view">
        <div style="margin-bottom:14px;color:#c8c8d0;font-size:12px;line-height:1.5;">
          Stream bookmarks directly into Xray as they are captured.
        </div>
        <div style="display:grid;gap:10px;padding:12px;border-radius:12px;background:rgba(255,255,255,0.045);border:1px solid rgba(255,255,255,0.06);">
          <label style="display:grid;gap:5px;">
            <span style="font-size:11px;color:#c8c8d0;">Receiver URL</span>
            <input id="xray-receiver-url" type="text" placeholder="Paste the URL shown in Xray" value="${escapeAttribute(state.receiverURL)}" />
          </label>
          <label style="display:grid;gap:5px;">
            <span style="font-size:11px;color:#c8c8d0;">Session token</span>
            <input id="xray-session-token" type="text" placeholder="Paste the token shown in Xray" value="${escapeAttribute(state.sessionToken)}" />
          </label>
          <button id="xray-connect">Connect to Xray</button>
          <div id="xray-setup-error" style="display:none;color:#ffb1b1;font-size:11px;line-height:1.4;"></div>
        </div>
        <div style="display:flex;align-items:center;gap:10px;margin:14px 0;color:#777985;font-size:10px;">
          <span style="height:1px;flex:1;background:rgba(255,255,255,0.08);"></span>
          OR
          <span style="height:1px;flex:1;background:rgba(255,255,255,0.08);"></span>
        </div>
        <button id="xray-use-file" style="width:100%;background:transparent;color:#f5f5f7;border:1px solid rgba(255,255,255,0.14);">Use file export instead</button>
        <div style="margin-top:8px;text-align:center;color:#8f919c;font-size:10px;">Capture now, then import the JSON file into Xray.</div>
      </section>

      <section id="xray-capture-view" style="display:none;">
        <div id="xray-friendly-status" style="padding:12px;margin-bottom:12px;border-radius:12px;background:rgba(125,183,255,0.10);border:1px solid rgba(125,183,255,0.16);color:#e9f3ff;line-height:1.45;">
          Ready to capture your bookmarks.
        </div>
        <div style="display:flex;align-items:baseline;justify-content:space-between;margin:0 2px 12px;">
          <span style="color:#aeb0bb;font-size:11px;">Bookmarks captured</span>
          <strong id="xray-count-primary" style="font-size:24px;letter-spacing:-0.03em;">0</strong>
        </div>
        <div style="display:grid;grid-template-columns:minmax(0,1fr) minmax(0,1fr);gap:8px;margin-bottom:10px;">
          <button id="xray-start" style="grid-column:span 2;">Start capture</button>
          <button id="xray-pause-toggle" style="background:rgba(255,255,255,0.08);color:#f5f5f7;border:1px solid rgba(255,255,255,0.08);">Pause scrolling</button>
          <button id="xray-stop" style="background:rgba(255,255,255,0.08);color:#f5f5f7;border:1px solid rgba(255,255,255,0.08);">Finish capture</button>
        </div>
        <div style="margin:-2px 2px 14px;color:#8f919c;font-size:10px;line-height:1.4;">
          Pausing stops automatic scrolling. Already captured bookmarks can still finish importing.
        </div>

        <section id="xray-file-export-card" style="display:none;margin-bottom:12px;padding:12px;border-radius:12px;background:rgba(255,255,255,0.045);border:1px solid rgba(255,255,255,0.06);">
          <div style="font-weight:700;margin-bottom:3px;">Bookmark file</div>
          <div style="color:#aeb0bb;font-size:11px;margin-bottom:10px;">Your file currently contains <span id="xray-json-count-primary">0</span> bookmarks.</div>
          <button id="xray-export" style="width:100%;">Download JSON file</button>
          <button id="xray-clear-json" style="width:100%;margin-top:6px;background:transparent;color:#ffaaa8;border:1px solid rgba(255,120,116,0.24);">Clear saved file data</button>
        </section>

        <details id="xray-settings" style="margin-bottom:8px;padding:0 12px;border-radius:12px;background:rgba(255,255,255,0.035);border:1px solid rgba(255,255,255,0.06);">
          <summary style="padding:11px 0;cursor:pointer;font-weight:650;color:#d9dae1;">Capture settings</summary>
          <div style="display:grid;gap:12px;padding:2px 0 12px;">
            <label style="display:flex;align-items:center;justify-content:space-between;gap:10px;color:#c8c8d0;">
              <span>Scroll automatically</span>
              <input id="xray-auto-scroll" type="checkbox" ${state.autoScrollEnabled ? "checked" : ""} />
            </label>
            <label style="display:flex;align-items:center;justify-content:space-between;gap:10px;color:#c8c8d0;">
              <span>Unload posts already passed</span>
              <input id="xray-prune-page" type="checkbox" ${state.prunePageEnabled ? "checked" : ""} />
            </label>
            <div style="display:grid;gap:6px;color:#d6d6de;">
              <label for="xray-speed" style="display:flex;align-items:center;justify-content:space-between;gap:12px;">
                <span>Maximum scroll speed</span>
                <span id="xray-speed-value" style="color:#aeb0bb;font-size:11px;">${Math.round(state.maxScrollSpeed)} px/s</span>
              </label>
              <input id="xray-speed" type="range" min="${MIN_SCROLL_PIXELS_PER_SECOND}" max="${MAX_SCROLL_PIXELS_PER_SECOND}" step="100" value="${Math.round(state.maxScrollSpeed)}" />
            </div>
          </div>
        </details>

        <details id="xray-diagnostics" style="padding:0 12px;border-radius:12px;background:rgba(255,255,255,0.035);border:1px solid rgba(255,255,255,0.06);">
          <summary style="padding:11px 0;cursor:pointer;font-weight:650;color:#d9dae1;">Advanced details</summary>
          <div style="display:grid;gap:6px;padding:2px 0 12px;color:#aeb0bb;font-size:11px;overflow-wrap:anywhere;">
        <div><strong>Mode:</strong> <span id="xray-mode">idle</span></div>
        <div><strong>Captured:</strong> <span id="xray-count">0</span></div>
        <div><strong>JSON export:</strong> <span id="xray-json-count">0</span></div>
        <div><strong>Queued:</strong> <span id="xray-queued">0</span></div>
        <div><strong>Pruned:</strong> <span id="xray-pruned">0 page / 0 buffer</span></div>
        <div><strong>Responses:</strong> <span id="xray-responses">0</span></div>
        <div><strong>Live speed:</strong> <span id="xray-live-speed">${Math.round(state.adaptiveSpeed)} px/s</span></div>
        <div><strong>Connection:</strong> <span id="xray-connection">disconnected</span></div>
        <div><strong>Receiver:</strong> <span id="xray-connection-detail">Streaming idle.</span></div>
        <div><strong>Batches:</strong> <span id="xray-batches">0 attempted / 0 acked</span></div>
        <div><strong>Imported:</strong> <span id="xray-imported">0 inserted / 0 skipped</span></div>
        <div><strong>Already imported streak:</strong> <span id="xray-existing-streak">0 / ${CONSECUTIVE_EXISTING_STOP_THRESHOLD}</span></div>
        <div><strong>Last send:</strong> <span id="xray-last-send">No batches sent yet.</span></div>
        <div><strong>Last activity:</strong> <span id="xray-activity">Waiting for Start.</span></div>
        <div id="xray-error-wrap" style="display:none;color:#ffb1b1;"><strong>Error:</strong> <span id="xray-error"></span></div>
          </div>
        </details>
        <button id="xray-change-method" style="width:100%;margin-top:10px;background:transparent;color:#aeb0bb;">Change import method</button>
      </section>
    `;

    document.body.appendChild(panel);

    for (const button of panel.querySelectorAll("button")) {
      button.style.cssText = `${buttonBaseStyle()};${button.style.cssText}`;
    }

    for (const input of panel.querySelectorAll("input[type='text']")) {
      input.style.cssText = textInputStyle();
    }

    state.statusElements = {
      mode: panel.querySelector("#xray-mode"),
      count: panel.querySelector("#xray-count"),
      jsonCount: panel.querySelector("#xray-json-count"),
      queued: panel.querySelector("#xray-queued"),
      responses: panel.querySelector("#xray-responses"),
      liveSpeed: panel.querySelector("#xray-live-speed"),
      speedSlider: panel.querySelector("#xray-speed"),
      speedValue: panel.querySelector("#xray-speed-value"),
      activity: panel.querySelector("#xray-activity"),
      errorWrap: panel.querySelector("#xray-error-wrap"),
      error: panel.querySelector("#xray-error"),
      autoScroll: panel.querySelector("#xray-auto-scroll"),
      prunePage: panel.querySelector("#xray-prune-page"),
      receiverURL: panel.querySelector("#xray-receiver-url"),
      sessionToken: panel.querySelector("#xray-session-token"),
      connection: panel.querySelector("#xray-connection"),
      connectionDetail: panel.querySelector("#xray-connection-detail"),
      batches: panel.querySelector("#xray-batches"),
      imported: panel.querySelector("#xray-imported"),
      existingStreak: panel.querySelector("#xray-existing-streak"),
      lastSend: panel.querySelector("#xray-last-send"),
      pruned: panel.querySelector("#xray-pruned"),
      setupView: panel.querySelector("#xray-setup-view"),
      captureView: panel.querySelector("#xray-capture-view"),
      destinationBadge: panel.querySelector("#xray-destination-badge"),
      friendlyStatus: panel.querySelector("#xray-friendly-status"),
      countPrimary: panel.querySelector("#xray-count-primary"),
      jsonCountPrimary: panel.querySelector("#xray-json-count-primary"),
      fileExportCard: panel.querySelector("#xray-file-export-card"),
      pauseToggle: panel.querySelector("#xray-pause-toggle"),
      startButton: panel.querySelector("#xray-start"),
      stopButton: panel.querySelector("#xray-stop"),
      connectButton: panel.querySelector("#xray-connect"),
      setupError: panel.querySelector("#xray-setup-error"),
    };

    panel.querySelector("#xray-start").addEventListener("click", startCapture);
    panel.querySelector("#xray-pause-toggle").addEventListener("click", () => {
      if (state.mode === "paused" || state.mode === "rate-limited") {
        resumeCapture();
      } else {
        pauseCapture();
      }
    });
    panel.querySelector("#xray-stop").addEventListener("click", stopCapture);
    panel.querySelector("#xray-export").addEventListener("click", exportJSON);
    panel.querySelector("#xray-clear-json").addEventListener("click", clearJSONExport);
    panel.querySelector("#xray-connect").addEventListener("click", async () => {
      state.captureDestination = "stream";
      state.streamingEnabled = true;
      await connectReceiver("manual connect");
    });
    panel.querySelector("#xray-use-file").addEventListener("click", () => {
      disconnectReceiver();
      state.captureDestination = "file";
      state.uiView = "capture";
      state.lastErrorText = "";
      updateStatus();
    });
    panel.querySelector("#xray-change-method").addEventListener("click", () => {
      state.uiView = "setup";
      updateStatus();
    });
    state.statusElements.autoScroll.addEventListener("change", (event) => {
      state.autoScrollEnabled = event.target.checked;
      writeStorage(STORAGE_KEYS.autoScroll, state.autoScrollEnabled ? "1" : "0");
      if (state.mode === "running" && state.autoScrollEnabled) {
        scheduleScroll();
      }
    });
    state.statusElements.prunePage.addEventListener("change", (event) => {
      state.prunePageEnabled = event.target.checked;
      writeStorage(STORAGE_KEYS.prunePage, state.prunePageEnabled ? "1" : "0");
      if (state.prunePageEnabled && state.mode === "running") {
        scheduleDOMPrune();
      } else {
        clearDOMPruneTimer();
      }
      updateStatus();
    });
    state.statusElements.speedSlider.addEventListener("input", (event) => {
      const nextSpeed = Number(event.target.value);
      state.maxScrollSpeed = Number.isFinite(nextSpeed) ? nextSpeed : DEFAULT_SCROLL_PIXELS_PER_SECOND;
      state.adaptiveSpeed = Math.min(state.adaptiveSpeed, state.maxScrollSpeed);
      writeStorage(STORAGE_KEYS.maxSpeed, String(state.maxScrollSpeed));
      updateStatus();
    });
    state.statusElements.receiverURL.addEventListener("change", (event) => {
      state.receiverURL = event.target.value.trim();
      writeStorage(STORAGE_KEYS.receiverURL, state.receiverURL);
      updateStatus();
    });
    state.statusElements.sessionToken.addEventListener("change", (event) => {
      state.sessionToken = event.target.value.trim();
      writeStorage(STORAGE_KEYS.sessionToken, state.sessionToken);
      updateStatus();
    });

    state.uiReady = true;
    updateStatus();
  }

  function startCapture() {
    clearRateLimitCooldown();
    state.mode = "running";
    state.lastErrorText = "";
    state.idleScrolls = 0;
    state.previousCount = state.capturedPostCount;
    state.lastObservedScrollY = currentScrollY();
    state.directFetchEmptyPages = 0;
    state.consecutiveSkippedExistingCount = 0;
    state.stoppedAfterExistingStreak = false;
    state.adaptiveSpeed = state.maxScrollSpeed;
    state.lastActivityText = state.capturedPostCount > 0
      ? "Capture running with existing buffered posts."
      : "Capture started. Waiting for bookmark responses.";
    updateStatus();
    scheduleScroll();
    scheduleDOMPrune();
    void flushPendingQueue("capture start");
  }

  function pauseCapture() {
    if (state.mode !== "running" && state.mode !== "rate-limited") {
      return;
    }
    clearRateLimitCooldown();
    state.mode = "paused";
    clearScheduledScroll();
    clearDOMPruneTimer();
    state.lastActivityText = "Capture paused.";
    updateStatus();
    void flushPendingQueue("pause");
  }

  function resumeCapture() {
    if (state.mode !== "paused" && state.mode !== "rate-limited") {
      return;
    }
    clearRateLimitCooldown();
    state.mode = "running";
    state.lastActivityText = "Capture resumed.";
    updateStatus();
    scheduleScroll();
    scheduleDOMPrune();
    void flushPendingQueue("resume");
  }

  function stopCapture() {
    state.stoppedAfterExistingStreak = false;
    state.mode = "stopped";
    state.shouldNotifyCompletion = true;
    clearRateLimitCooldown();
    clearScheduledScroll();
    clearDOMPruneTimer();
    state.lastActivityText = "Capture stopped. Export when ready.";
    updateStatus();
    void flushPendingQueue("stop");
    void finalizeStreamingIfPossible();
  }

  function scheduleScroll() {
    clearScheduledScroll();
    if (state.mode !== "running" || !state.autoScrollEnabled) {
      return;
    }
    state.lastScrollFrameAt = performance.now();
    state.lastObservedScrollY = currentScrollY();

    const step = (timestamp) => {
      if (state.mode !== "running" || !state.autoScrollEnabled) {
        state.scrollAnimationFrame = null;
        return;
      }

      const elapsedMs = Math.max(0, timestamp - state.lastScrollFrameAt);
      state.lastScrollFrameAt = timestamp;
      updateAdaptiveScrollSpeed();
      const distance = (state.adaptiveSpeed * elapsedMs) / 1000;
      if (distance > 0) {
        window.scrollBy(0, distance);
      }

      state.scrollAnimationFrame = window.requestAnimationFrame(step);
    };

    const idleCheck = () => {
      if (state.mode !== "running" || !state.autoScrollEnabled) {
        state.idleCheckTimer = null;
        return;
      }

      const nextScrollY = currentScrollY();
      const madeScrollProgress = Math.abs(nextScrollY - state.lastObservedScrollY) >= SCROLL_PROGRESS_EPSILON_PX;
      state.lastObservedScrollY = nextScrollY;

      if (state.capturedPostCount > state.previousCount) {
        state.previousCount = state.capturedPostCount;
        state.idleScrolls = 0;
      } else if (madeScrollProgress) {
        state.idleScrolls = 0;
      } else {
        state.idleScrolls += 1;
      }

      if (state.idleScrolls >= MAX_IDLE_SCROLLS && canDirectFetchBookmarks()) {
        void fetchNextBookmarksPageDirectly("scroll idle");
        state.idleScrolls = Math.max(0, MAX_IDLE_SCROLLS - 4);
        state.idleCheckTimer = window.setTimeout(idleCheck, IDLE_CHECK_INTERVAL_MS);
        return;
      }

      if (state.idleScrolls >= MAX_IDLE_SCROLLS) {
        state.mode = "stopped";
        state.shouldNotifyCompletion = true;
        state.lastActivityText = "No new bookmarks found after repeated scrolls. Capture stopped.";
        clearScheduledScroll();
        clearDOMPruneTimer();
        updateStatus();
        void flushPendingQueue("idle stop");
        void finalizeStreamingIfPossible();
        return;
      }

      state.idleCheckTimer = window.setTimeout(idleCheck, IDLE_CHECK_INTERVAL_MS);
    };

    state.scrollAnimationFrame = window.requestAnimationFrame(step);
    state.idleCheckTimer = window.setTimeout(idleCheck, IDLE_CHECK_INTERVAL_MS);
    scheduleDOMPrune();
  }

  function clearScheduledScroll() {
    if (state.scrollAnimationFrame !== null) {
      window.cancelAnimationFrame(state.scrollAnimationFrame);
      state.scrollAnimationFrame = null;
    }
    if (state.idleCheckTimer !== null) {
      window.clearTimeout(state.idleCheckTimer);
      state.idleCheckTimer = null;
    }
  }

  function scheduleDOMPrune() {
    if (!state.prunePageEnabled || state.mode !== "running" || state.domPruneTimer !== null) {
      return;
    }

    state.domPruneTimer = window.setTimeout(() => {
      state.domPruneTimer = null;
      if (!state.prunePageEnabled || state.mode !== "running") {
        return;
      }

      pruneOldTimelineDOM();
      scheduleDOMPrune();
    }, DOM_PRUNE_INTERVAL_MS);
  }

  function clearDOMPruneTimer() {
    if (state.domPruneTimer !== null) {
      window.clearTimeout(state.domPruneTimer);
      state.domPruneTimer = null;
    }
  }

  function pruneOldTimelineDOM() {
    const main = document.querySelector("main");
    if (!main) {
      return;
    }

    const keepBehindPixels = Math.max(
      window.innerHeight * DOM_PRUNE_KEEP_BEHIND_VIEWPORTS,
      3200
    );
    let pruned = 0;

    for (const article of main.querySelectorAll("article[data-testid='tweet']")) {
      if (article.dataset.xrayPruned === "1" || article.contains(document.activeElement)) {
        continue;
      }

      const rect = article.getBoundingClientRect();
      if (rect.bottom > -keepBehindPixels || rect.height <= 0) {
        continue;
      }

      const placeholder = document.createElement("div");
      placeholder.dataset.xrayPruned = "1";
      placeholder.setAttribute("aria-hidden", "true");
      placeholder.style.cssText = [
        `height:${Math.ceil(rect.height)}px`,
        "min-height:1px",
        "width:100%",
        "flex-shrink:0",
        "overflow:hidden",
        "pointer-events:none",
        "contain:strict",
      ].join(";");

      article.replaceWith(placeholder);
      pruned += 1;
    }

    if (pruned > 0) {
      state.prunedDOMNodesCount += pruned;
      updateStatus();
    }
  }

  function tryHandleResponse(url, parseJSON, responseMeta = {}) {
    if (state.stoppedAfterExistingStreak || !isBookmarksGraphQLURL(url)) {
      return;
    }

    if (responseMeta.status === 429) {
      pauseForRateLimit(responseMeta.statusText || "HTTP 429");
      return;
    }

    Promise.resolve()
      .then(parseJSON)
      .then((payload) => {
        if (!payload) {
          return;
        }
        if (payloadHasRateLimitError(payload)) {
          pauseForRateLimit("GraphQL rate limit");
          return;
        }
        rememberNextBookmarkCursor(payload);
        handleBookmarksPayload(payload);
      })
      .catch((error) => {
        state.lastErrorText = error instanceof Error ? error.message : String(error);
        updateStatus();
      });
  }

  function pauseForRateLimit(reason) {
    if (state.mode !== "running" && state.mode !== "rate-limited") {
      state.lastActivityText = `X bookmark rate limit detected (${reason}). Start or resume after ${Math.round(RATE_LIMIT_COOLDOWN_MS / 1000)}s.`;
      updateStatus();
      return;
    }

    clearScheduledScroll();
    clearDOMPruneTimer();
    clearRateLimitCooldown();
    state.mode = "rate-limited";
    state.adaptiveSpeed = MIN_SCROLL_PIXELS_PER_SECOND;
    state.rateLimitResumeAt = Date.now() + RATE_LIMIT_COOLDOWN_MS;
    state.lastErrorText = "";
    state.lastActivityText = `X bookmark rate limit detected (${reason}). Pausing scroll for ${Math.round(RATE_LIMIT_COOLDOWN_MS / 1000)}s.`;
    updateStatus();

    state.rateLimitTimer = window.setTimeout(finishRateLimitCooldown, RATE_LIMIT_COOLDOWN_MS);
  }

  function finishRateLimitCooldown() {
    state.rateLimitTimer = null;
    state.rateLimitResumeAt = 0;
    if (state.mode !== "rate-limited") {
      updateStatus();
      return;
    }

    state.mode = "running";
    state.idleScrolls = 0;
    state.previousCount = state.capturedPostCount;
    state.lastObservedScrollY = currentScrollY();
    state.adaptiveSpeed = Math.min(state.maxScrollSpeed, Math.max(state.adaptiveSpeed, MIN_SCROLL_PIXELS_PER_SECOND));

    const clickedLoadMore = clickRateLimitLoadMoreControl();
    state.lastActivityText = clickedLoadMore
      ? `Rate limit cooldown finished at ${timeStamp()}. Clicked load more and resuming capture.`
      : `Rate limit cooldown finished at ${timeStamp()}. Resuming capture.`;
    updateStatus();

    if (clickedLoadMore) {
      state.rateLimitTimer = window.setTimeout(() => {
        state.rateLimitTimer = null;
        if (state.mode !== "running") {
          updateStatus();
          return;
        }
        scheduleScroll();
        scheduleDOMPrune();
        void flushPendingQueue("rate limit cooldown");
      }, RATE_LIMIT_LOAD_MORE_SETTLE_MS);
      return;
    }

    scheduleScroll();
    scheduleDOMPrune();
    void flushPendingQueue("rate limit cooldown");
  }

  function clearRateLimitCooldown() {
    if (state.rateLimitTimer !== null) {
      window.clearTimeout(state.rateLimitTimer);
      state.rateLimitTimer = null;
    }
    state.rateLimitResumeAt = 0;
  }

  function clickRateLimitLoadMoreControl() {
    window.scrollTo(0, Math.max(
      document.body?.scrollHeight ?? 0,
      document.documentElement?.scrollHeight ?? 0
    ));

    const candidates = [
      ...document.querySelectorAll("main button, main [role='button'], main a[role='link'], button, [role='button']")
    ];
    const loadMorePattern = /\b(load more|retry|try again)\b/i;

    const matchingCandidates = candidates
      .filter((element) => !document.getElementById(PANEL_ID)?.contains(element))
      .filter((element) => loadMorePattern.test(controlAccessibleText(element)))
      .filter(isVisibleElement)
      .sort((left, right) => elementCenterY(right) - elementCenterY(left));

    const target = matchingCandidates[0];
    if (!target) {
      return false;
    }

    target.scrollIntoView({ block: "center", inline: "nearest" });
    target.click();
    return true;
  }

  function currentScrollY() {
    return Math.max(
      window.scrollY || 0,
      document.documentElement?.scrollTop || 0,
      document.body?.scrollTop || 0
    );
  }

  async function rememberBookmarkFetchRequest(args) {
    const url = extractURLFromFetchArgs(args);
    if (!isBookmarksGraphQLURL(url)) {
      return;
    }

    try {
      const input = args[0];
      const init = args[1] || {};
      const request = typeof Request !== "undefined" && input instanceof Request ? input : null;
      const method = String(init.method || request?.method || "GET").toUpperCase();
      const headers = headersToObject(init.headers || request?.headers);
      let body = init.body ?? null;

      if (body === null && request && method !== "GET" && method !== "HEAD") {
        body = await request.clone().text();
      }

      state.bookmarkRequestTemplate = {
        transport: "fetch",
        url: new URL(url, window.location.origin).toString(),
        method,
        headers,
        body: body === null || body === undefined ? null : String(body),
      };
      writeJSONStorage(STORAGE_KEYS.bookmarkRequestTemplate, state.bookmarkRequestTemplate);
    } catch (error) {
      state.lastErrorText = error instanceof Error ? error.message : String(error);
      updateStatus();
    }
  }

  function rememberBookmarkXHRRequest(method, url, body) {
    if (!isBookmarksGraphQLURL(url)) {
      return;
    }

    state.bookmarkRequestTemplate = {
      transport: "xhr",
      url: new URL(url, window.location.origin).toString(),
      method: String(method || "GET").toUpperCase(),
      headers: {},
      body: body === null || body === undefined ? null : String(body),
    };
    writeJSONStorage(STORAGE_KEYS.bookmarkRequestTemplate, state.bookmarkRequestTemplate);
  }

  function canDirectFetchBookmarks() {
    return Boolean(
      state.originalFetch &&
      state.bookmarkRequestTemplate &&
      state.nextBookmarkCursor &&
      !state.isDirectFetchingBookmarks &&
      state.directFetchEmptyPages < MAX_DIRECT_FETCH_EMPTY_PAGES
    );
  }

  async function fetchNextBookmarksPageDirectly(reason) {
    if (!canDirectFetchBookmarks()) {
      return false;
    }

    const cursor = state.nextBookmarkCursor;
    state.isDirectFetchingBookmarks = true;
    state.lastActivityText = `Fetching next bookmark page directly (${reason}).`;
    updateStatus();

    try {
      const request = buildDirectBookmarkRequest(cursor);
      const response = await state.originalFetch(request.url, request.init);
      const payload = await response.clone().json();

      if (state.stoppedAfterExistingStreak) {
        return false;
      }

      if (response.status === 429 || payloadHasRateLimitError(payload)) {
        pauseForRateLimit(response.statusText || "direct GraphQL rate limit");
        return false;
      }

      const beforeCount = state.capturedPostCount;
      rememberNextBookmarkCursor(payload);
      handleBookmarksPayload(payload);
      const added = state.capturedPostCount - beforeCount;

      if (added > 0) {
        state.lastActivityText = `Direct fetch captured ${added} bookmark${added === 1 ? "" : "s"} at ${timeStamp()}.`;
        if (state.mode === "running" && state.nextBookmarkCursor) {
          window.setTimeout(() => {
            if (state.mode === "running" && canDirectFetchBookmarks()) {
              void fetchNextBookmarksPageDirectly("direct pagination");
            }
          }, 150);
        }
      } else {
        state.directFetchEmptyPages += 1;
        state.lastActivityText = `Direct bookmark page had no new posts at ${timeStamp()}.`;
      }

      updateStatus();
      return added > 0;
    } catch (error) {
      state.directFetchEmptyPages += 1;
      state.lastErrorText = error instanceof Error ? error.message : String(error);
      state.lastActivityText = "Direct bookmark fetch failed; falling back to page scrolling.";
      updateStatus();
      return false;
    } finally {
      state.isDirectFetchingBookmarks = false;
    }
  }

  function buildDirectBookmarkRequest(cursor) {
    const template = state.bookmarkRequestTemplate;
    const url = new URL(template.url);
    const init = {
      method: template.method,
      credentials: "include",
      headers: template.headers,
    };

    if (template.method === "GET" || template.method === "HEAD") {
      const variables = parseJSONMaybe(url.searchParams.get("variables")) || {};
      variables.cursor = cursor;
      url.searchParams.set("variables", JSON.stringify(variables));
    } else {
      const body = parseJSONMaybe(template.body) || {};
      body.variables = body.variables && typeof body.variables === "object" ? body.variables : {};
      body.variables.cursor = cursor;
      init.body = JSON.stringify(body);
      if (!hasHeader(init.headers, "content-type")) {
        init.headers = { ...init.headers, "content-type": "application/json" };
      }
    }

    return {
      url: url.toString(),
      init,
    };
  }

  function rememberNextBookmarkCursor(payload) {
    const cursor = extractBottomCursor(payload);
    if (cursor) {
      state.nextBookmarkCursor = cursor;
      writeStorage(STORAGE_KEYS.nextBookmarkCursor, cursor);
    }
  }

  function extractBottomCursor(root) {
    for (const entries of findTimelineEntryArrays(root)) {
      for (const entry of entries) {
        const cursor = cursorFromTimelineEntry(entry);
        if (cursor) {
          return cursor;
        }
      }
    }

    return cursorFromAnyObject(root, new Set());
  }

  function cursorFromTimelineEntry(entry) {
    const entryId = String(entry?.entryId || entry?.entry_id || "").toLowerCase();
    const content = entry?.content ?? entry;
    const operation = content?.operation ?? content;
    const cursorType = String(operation?.cursorType || operation?.cursor_type || "").toLowerCase();
    const value = operation?.value;

    if (typeof value === "string" && value && (
      cursorType === "bottom" ||
      entryId.includes("cursor-bottom") ||
      entryId.includes("cursor-showmorethreads")
    )) {
      return value;
    }

    return "";
  }

  function cursorFromAnyObject(value, visited) {
    if (!value || typeof value !== "object" || visited.has(value)) {
      return "";
    }
    visited.add(value);

    if (Array.isArray(value)) {
      for (const item of value) {
        const cursor = cursorFromAnyObject(item, visited);
        if (cursor) {
          return cursor;
        }
      }
      return "";
    }

    const cursorType = String(value.cursorType || value.cursor_type || "").toLowerCase();
    if (cursorType === "bottom" && typeof value.value === "string" && value.value) {
      return value.value;
    }

    for (const child of Object.values(value)) {
      const cursor = cursorFromAnyObject(child, visited);
      if (cursor) {
        return cursor;
      }
    }

    return "";
  }

  function headersToObject(headers) {
    if (!headers) {
      return {};
    }

    if (headers instanceof Headers) {
      return Object.fromEntries(headers.entries());
    }

    if (Array.isArray(headers)) {
      return Object.fromEntries(headers);
    }

    return { ...headers };
  }

  function parseJSONMaybe(value) {
    if (!value || typeof value !== "string") {
      return null;
    }

    try {
      return JSON.parse(value);
    } catch {
      return null;
    }
  }

  function hasHeader(headers, name) {
    const lowerName = name.toLowerCase();
    return Object.keys(headers || {}).some((key) => key.toLowerCase() === lowerName);
  }

  function controlAccessibleText(element) {
    return [
      element.innerText,
      element.textContent,
      element.getAttribute("aria-label"),
      element.getAttribute("title"),
    ].filter(Boolean).join(" ").trim();
  }

  function isVisibleElement(element) {
    const rect = element.getBoundingClientRect();
    const style = window.getComputedStyle(element);
    return rect.width > 0 &&
      rect.height > 0 &&
      style.visibility !== "hidden" &&
      style.display !== "none" &&
      rect.bottom >= 0 &&
      rect.top <= window.innerHeight;
  }

  function elementCenterY(element) {
    const rect = element.getBoundingClientRect();
    return rect.top + (rect.height / 2);
  }

  function payloadHasRateLimitError(payload) {
    if (!payload || typeof payload !== "object") {
      return false;
    }

    if (Array.isArray(payload.errors) && payload.errors.some(isRateLimitError)) {
      return true;
    }

    return containsRateLimitError(payload, new Set());
  }

  function containsRateLimitError(value, visited) {
    if (!value || typeof value !== "object" || visited.has(value)) {
      return false;
    }
    visited.add(value);

    if (isRateLimitError(value)) {
      return true;
    }

    if (Array.isArray(value)) {
      return value.some((item) => containsRateLimitError(item, visited));
    }

    return Object.values(value).some((item) => containsRateLimitError(item, visited));
  }

  function isRateLimitError(error) {
    if (!error || typeof error !== "object") {
      return false;
    }

    const code = error.code ?? error.extensions?.code ?? error.extensions?.errorCode;
    if (code === 88 || code === 429 || code === "88" || code === "429") {
      return true;
    }

    const message = String(error.message ?? error.detail ?? error.title ?? "").toLowerCase();
    return message.includes("rate limit") || message.includes("too many requests");
  }

  function handleBookmarksPayload(payload) {
    if (state.stoppedAfterExistingStreak) {
      return;
    }
    state.bookmarkResponseCount += 1;
    state.lastResponseAt = Date.now();
    state.adaptiveSpeed = state.maxScrollSpeed;

    let added = 0;
    const exportPosts = [];
    for (const tweetResult of extractTweetResults(payload)) {
      const normalized = normalizeTweet(tweetResult);
      if (!normalized) {
        continue;
      }
      exportPosts.push(normalized);
      if (!state.seenPostIds.has(normalized.id)) {
        state.seenPostIds.add(normalized.id);
        state.posts.set(normalized.id, normalized);
        state.capturedPostCount += 1;
        enqueuePostForStreaming(normalized.id);
        added += 1;
      }
    }

    mergeObservedPostsIntoExport(exportPosts);
    if (exportPosts.length > 0) {
      scheduleExportPostsPersist();
    }

    if (added > 0) {
      state.directFetchEmptyPages = 0;
      state.lastActivityText = `Captured ${added} new bookmark${added === 1 ? "" : "s"} at ${timeStamp()}.`;
      state.idleScrolls = 0;
      state.previousCount = state.capturedPostCount;
      void flushPendingQueue("new bookmarks");
      scheduleDOMPrune();
    } else if (state.mode === "running") {
      state.lastActivityText = `Bookmark response received with no new posts at ${timeStamp()}.`;
    }

    updateStatus();
  }

  function enqueuePostForStreaming(postId) {
    if (state.ackedPostIds.has(postId)) {
      return;
    }
    if (state.pendingPostIdSet.has(postId)) {
      return;
    }
    if (state.inFlightPostIdSet.has(postId)) {
      return;
    }

    state.pendingPostIds.push(postId);
    state.pendingPostIdSet.add(postId);

    if (state.pendingPostIds.length >= STREAM_BACKPRESSURE_LIMIT && state.mode === "running") {
      pauseForBackpressure();
    }
  }

  function pauseForBackpressure() {
    state.mode = "paused";
    clearScheduledScroll();
    clearDOMPruneTimer();
    state.lastActivityText = "Capture paused to avoid outrunning Xray while queued posts build up.";
    updateStatus();
  }

  async function connectReceiver(reason) {
    if (state.isConnecting) {
      return;
    }

    syncReceiverCredentialsFromUI();
    if (!state.receiverURL || !state.sessionToken) {
      state.connectionState = "disconnected";
      state.connectionDetailText = "Enter the receiver URL and token from Xray first.";
      state.lastErrorText = "Receiver URL and session token are required for streaming.";
      updateStatus();
      return;
    }

    clearRetryTimer();
    state.streamingEnabled = true;
    state.isConnecting = true;
    state.connectionState = "connecting";
    state.connectionDetailText = `Connecting to Xray (${reason})...`;
    updateStatus();

    try {
      const status = await requestReceiver("/session/status", {
        method: "GET",
      });

      const startPayload = {
        sessionId: state.browserSessionId,
        clientName: "Xray bookmarks userscript",
        startedAtMillis: Date.now(),
      };
      const startResponse = await requestReceiver("/session/start", {
        method: "POST",
        body: JSON.stringify(startPayload),
      });

      if (!startResponse.success) {
        throw new Error(startResponse.message || "Xray rejected the browser session.");
      }

      state.connectionState = "connected";
      state.connectionDetailText = status.receiverStatus || "Connected to Xray.";
      state.lastErrorText = "";
      state.retryDelayMs = STREAM_RETRY_DELAY_MS;
      state.lastSuccessfulSendText = `Connected at ${timeStamp()}.`;
      state.captureDestination = "stream";
      if (state.uiView === "setup") {
        state.uiView = "capture";
      }
      updateStatus();
      await flushPendingQueue("connected");
    } catch (error) {
      state.connectionState = "retrying";
      state.connectionDetailText = `Retrying in ${Math.round(state.retryDelayMs / 1000)}s.`;
      state.lastErrorText = error instanceof Error ? error.message : String(error);
      updateStatus();
      scheduleRetry("connect failed");
    } finally {
      state.isConnecting = false;
      updateStatus();
    }
  }

  function disconnectReceiver() {
    state.streamingEnabled = false;
    state.connectionState = "disconnected";
    state.connectionDetailText = "Streaming disabled.";
    state.lastErrorText = "";
    clearRetryTimer();
    updateStatus();
  }

  async function flushPendingQueue(reason) {
    if (!state.streamingEnabled) {
      updateStatus();
      return;
    }

    if (state.isSending) {
      return;
    }

    if (state.connectionState !== "connected") {
      await connectReceiver(reason);
      if (state.connectionState !== "connected") {
        return;
      }
    }

    if (state.pendingPostIds.length === 0) {
      await finalizeStreamingIfPossible();
      updateStatus();
      return;
    }

    await sendNextBatch(reason);
  }

  async function sendNextBatch(reason) {
    if (state.isSending || state.pendingPostIds.length === 0) {
      return;
    }

    const ids = state.pendingPostIds.splice(0, STREAM_BATCH_SIZE);
    for (const postId of ids) {
      state.pendingPostIdSet.delete(postId);
      state.inFlightPostIdSet.add(postId);
    }

    const posts = ids
      .map((postId) => state.posts.get(postId))
      .filter(Boolean);

    const batch = {
      sessionId: state.browserSessionId,
      batchSequence: state.nextBatchSequence,
      sentAtMillis: Date.now(),
      posts,
    };

    state.inFlightBatch = batch;
    state.inFlightPostIds = ids;
    state.isSending = true;
    state.batchesAttempted += 1;
    state.connectionDetailText = `Sending batch ${batch.batchSequence} (${posts.length} posts, ${reason}).`;
    updateStatus();

    try {
      const response = await requestReceiver("/session/batch", {
        method: "POST",
        body: JSON.stringify(batch),
      });

      if (!response.success) {
        throw new Error(response.message || "Xray rejected the batch.");
      }

      for (const postId of ids) {
        state.ackedPostIds.add(postId);
        state.inFlightPostIdSet.delete(postId);
      }
      pruneAckedPostObjects(ids);

      state.inFlightBatch = null;
      state.inFlightPostIds = [];
      state.isSending = false;
      state.batchesAcked += 1;
      state.nextBatchSequence += 1;
      state.receiverAcceptedCount = response.totalAcceptedCount ?? state.receiverAcceptedCount + posts.length;
      state.receiverInsertedCount = response.totalInsertedCount ?? state.receiverInsertedCount + (response.insertedCount || 0);
      state.receiverSkippedExistingCount = response.totalSkippedExistingCount ?? state.receiverSkippedExistingCount + (response.skippedExistingCount || 0);
      updateConsecutiveExistingStreak(response, posts.length);
      state.connectionState = "connected";
      state.connectionDetailText = `Xray acknowledged batch ${batch.batchSequence}.`;
      state.lastSuccessfulSendText = `Batch ${batch.batchSequence} acknowledged at ${timeStamp()}.`;
      state.lastErrorText = "";
      state.retryDelayMs = STREAM_RETRY_DELAY_MS;
      finishCaptureAfterExistingStreakIfNeeded();
      updateStatus();

      if (state.pendingPostIds.length > 0) {
        await sendNextBatch("drain queue");
      } else {
        await finalizeStreamingIfPossible();
      }
    } catch (error) {
      requeueInFlightBatch();
      state.connectionState = "retrying";
      state.connectionDetailText = `Retrying in ${Math.round(state.retryDelayMs / 1000)}s after batch failure.`;
      state.lastErrorText = error instanceof Error ? error.message : String(error);
      updateStatus();
      scheduleRetry("batch failed");
    } finally {
      state.isSending = false;
      updateStatus();
    }
  }

  function requeueInFlightBatch() {
    if (!state.inFlightBatch || state.inFlightPostIds.length === 0) {
      return;
    }

    for (const postId of [...state.inFlightPostIds].reverse()) {
      state.inFlightPostIdSet.delete(postId);
      if (!state.pendingPostIdSet.has(postId) && !state.ackedPostIds.has(postId)) {
        state.pendingPostIds.unshift(postId);
        state.pendingPostIdSet.add(postId);
      }
    }

    state.inFlightBatch = null;
    state.inFlightPostIds = [];
  }

  function updateConsecutiveExistingStreak(response, fallbackAcceptedCount) {
    if (state.stoppedAfterExistingStreak) {
      return;
    }
    const acceptedCount = Number(response.acceptedCount ?? fallbackAcceptedCount);
    const insertedCount = Number(response.insertedCount ?? 0);
    const skippedExistingCount = Number(response.skippedExistingCount ?? 0);
    const entireBatchAlreadyImported = acceptedCount > 0 &&
      insertedCount === 0 &&
      skippedExistingCount === acceptedCount;

    state.consecutiveSkippedExistingCount = entireBatchAlreadyImported
      ? state.consecutiveSkippedExistingCount + skippedExistingCount
      : 0;
  }

  function finishCaptureAfterExistingStreakIfNeeded() {
    if (state.consecutiveSkippedExistingCount < CONSECUTIVE_EXISTING_STOP_THRESHOLD) {
      return;
    }
    if (state.mode === "stopped") {
      return;
    }

    state.mode = "stopped";
    state.stoppedAfterExistingStreak = true;
    state.shouldNotifyCompletion = true;
    clearRateLimitCooldown();
    clearScheduledScroll();
    clearDOMPruneTimer();
    state.lastActivityText = `Reached ${state.consecutiveSkippedExistingCount} consecutive bookmarks already imported into Xray. Capture finished.`;
  }

  function pruneAckedPostObjects(postIds) {
    let pruned = 0;

    for (const postId of postIds) {
      if (state.pendingPostIdSet.has(postId) || state.inFlightPostIdSet.has(postId)) {
        continue;
      }
      if (state.posts.delete(postId)) {
        pruned += 1;
      }
    }

    if (pruned > 0) {
      state.prunedPostObjectsCount += pruned;
    }
  }

  async function finalizeStreamingIfPossible() {
    if (!state.streamingEnabled || !state.shouldNotifyCompletion) {
      return;
    }
    if (state.pendingPostIds.length > 0 || state.inFlightBatch || state.connectionState !== "connected") {
      return;
    }

    try {
      const response = await requestReceiver("/session/complete", {
        method: "POST",
        body: JSON.stringify({
          sessionId: state.browserSessionId,
          sentAtMillis: Date.now(),
          capturedCount: state.capturedPostCount,
          ackedCount: state.ackedPostIds.size,
        }),
      });

      if (response.success) {
        state.connectionDetailText = "Xray marked the browser session complete.";
        state.lastSuccessfulSendText = `Session completed at ${timeStamp()}.`;
        state.shouldNotifyCompletion = false;
        state.lastErrorText = "";
        updateStatus();
      }
    } catch (error) {
      state.connectionState = "retrying";
      state.connectionDetailText = `Retrying completion in ${Math.round(state.retryDelayMs / 1000)}s.`;
      state.lastErrorText = error instanceof Error ? error.message : String(error);
      updateStatus();
      scheduleRetry("complete failed");
    }
  }

  function scheduleRetry(reason) {
    if (!state.streamingEnabled) {
      return;
    }
    clearRetryTimer();
    state.retryTimer = window.setTimeout(async () => {
      state.retryTimer = null;
      if (!state.streamingEnabled) {
        return;
      }
      await connectReceiver(reason);
      if (state.connectionState === "connected") {
        await flushPendingQueue("retry");
      }
    }, state.retryDelayMs);
    state.retryDelayMs = Math.min(STREAM_MAX_RETRY_DELAY_MS, Math.round(state.retryDelayMs * 1.5));
    updateStatus();
  }

  function clearRetryTimer() {
    if (state.retryTimer !== null) {
      window.clearTimeout(state.retryTimer);
      state.retryTimer = null;
    }
  }

  async function requestReceiver(path, options) {
    const candidateBases = buildReceiverCandidates(state.receiverURL);
    let lastError = null;

    for (const baseURL of candidateBases) {
      try {
        const payload = await requestReceiverOnce(baseURL, path, options);
        if (baseURL !== state.receiverURL) {
          state.receiverURL = baseURL;
          writeStorage(STORAGE_KEYS.receiverURL, state.receiverURL);
        }
        return payload;
      } catch (error) {
        lastError = error;
      }
    }

    throw lastError || new Error("Failed to reach the Xray receiver.");
  }

  function exportJSON() {
    try {
      void flushPendingQueue("export");
      persistExportPostsNow();
      const posts = [...state.jsonExportPosts.values()];
      const blob = new Blob([JSON.stringify(posts, null, 2)], { type: "application/json" });
      const url = URL.createObjectURL(blob);
      const link = document.createElement("a");
      link.href = url;
      link.download = `xray-bookmarks-${exportTimestamp()}.json`;
      document.body.appendChild(link);
      link.click();
      link.remove();
      URL.revokeObjectURL(url);
      state.lastActivityText = `Exported ${posts.length} posts to JSON.`;
      state.lastErrorText = "";
      updateStatus();
    } catch (error) {
      state.lastErrorText = error instanceof Error ? error.message : String(error);
      updateStatus();
    }
  }

  function clearJSONExport() {
    if (state.jsonExportPosts.size > 0 && !window.confirm("Clear all bookmarks saved for file export? This cannot be undone.")) {
      return;
    }
    state.jsonExportPosts.clear();
    state.jsonExportHadStoredPosts = false;
    state.jsonExportUnanchoredInsertIndex = null;
    persistExportPostsNow();
    state.lastActivityText = "Cleared JSON export posts.";
    state.lastErrorText = "";
    updateStatus();
  }

  function updateStatus() {
    if (!state.uiReady || !state.statusElements) {
      return;
    }

    state.statusElements.mode.textContent = state.mode;
    state.statusElements.count.textContent = String(state.capturedPostCount);
    state.statusElements.jsonCount.textContent = String(state.jsonExportPosts.size);
    state.statusElements.queued.textContent = String(state.pendingPostIds.length + state.inFlightPostIds.length);
    state.statusElements.pruned.textContent = `${state.prunedDOMNodesCount} page / ${state.prunedPostObjectsCount} buffer`;
    state.statusElements.responses.textContent = String(state.bookmarkResponseCount);
    state.statusElements.speedSlider.value = String(state.maxScrollSpeed);
    state.statusElements.speedValue.textContent = `${Math.round(state.maxScrollSpeed)} px/s`;
    state.statusElements.liveSpeed.textContent = `${Math.round(state.adaptiveSpeed)} px/s`;
    state.statusElements.activity.textContent = state.lastActivityText;
    state.statusElements.receiverURL.value = state.receiverURL;
    state.statusElements.sessionToken.value = state.sessionToken;
    state.statusElements.connection.textContent = state.connectionState;
    state.statusElements.connectionDetail.textContent = state.connectionDetailText;
    state.statusElements.batches.textContent = `${state.batchesAttempted} attempted / ${state.batchesAcked} acked`;
    state.statusElements.imported.textContent = `${state.receiverInsertedCount} inserted / ${state.receiverSkippedExistingCount} skipped`;
    state.statusElements.existingStreak.textContent = `${state.consecutiveSkippedExistingCount} / ${CONSECUTIVE_EXISTING_STOP_THRESHOLD}`;
    state.statusElements.lastSend.textContent = state.lastSuccessfulSendText;
    state.statusElements.connectButton.disabled = state.isConnecting;
    state.statusElements.connectButton.textContent = state.isConnecting ? "Connecting…" : "Connect to Xray";
    state.statusElements.connectButton.style.opacity = state.isConnecting ? "0.6" : "1";
    state.statusElements.connectButton.style.cursor = state.isConnecting ? "default" : "pointer";
    state.statusElements.setupView.style.display = state.uiView === "setup" ? "block" : "none";
    state.statusElements.captureView.style.display = state.uiView === "capture" ? "block" : "none";
    state.statusElements.destinationBadge.style.display = state.uiView === "capture" ? "inline-flex" : "none";
    state.statusElements.destinationBadge.textContent = state.captureDestination === "stream" ? "LIVE TO XRAY" : "FILE EXPORT";
    state.statusElements.fileExportCard.style.display = state.captureDestination === "file" ? "block" : "none";
    state.statusElements.countPrimary.textContent = String(state.capturedPostCount);
    state.statusElements.jsonCountPrimary.textContent = String(state.jsonExportPosts.size);
    state.statusElements.friendlyStatus.textContent = friendlyStatusText();

    const isRunning = state.mode === "running";
    const isPaused = state.mode === "paused" || state.mode === "rate-limited";
    const canFinish = isRunning || isPaused;
    state.statusElements.startButton.disabled = isRunning || isPaused;
    state.statusElements.startButton.textContent = isRunning
      ? "Capturing bookmarks…"
      : isPaused
        ? "Capture paused"
        : state.mode === "stopped"
          ? "Continue capture"
          : "Start capture";
    state.statusElements.pauseToggle.disabled = !canFinish;
    state.statusElements.pauseToggle.textContent = isPaused ? "Resume scrolling" : "Pause scrolling";
    state.statusElements.stopButton.disabled = !canFinish;
    for (const button of [state.statusElements.startButton, state.statusElements.pauseToggle, state.statusElements.stopButton]) {
      button.style.opacity = button.disabled ? "0.45" : "1";
      button.style.cursor = button.disabled ? "default" : "pointer";
    }

    if (state.uiView === "setup" && state.lastErrorText) {
      state.statusElements.setupError.style.display = "block";
      state.statusElements.setupError.textContent = state.lastErrorText;
    } else {
      state.statusElements.setupError.style.display = "none";
      state.statusElements.setupError.textContent = "";
    }

    if (state.lastErrorText) {
      state.statusElements.errorWrap.style.display = "block";
      state.statusElements.error.textContent = state.lastErrorText;
    } else {
      state.statusElements.errorWrap.style.display = "none";
      state.statusElements.error.textContent = "";
    }
  }

  function friendlyStatusText() {
    if (state.captureDestination === "file") {
      if (state.mode === "running") {
        return "Capturing bookmarks now. When you finish, download the file below and import it into Xray.";
      }
      if (state.mode === "paused") {
        return "Automatic scrolling is paused. Resume when you’re ready to continue capturing.";
      }
      if (state.mode === "rate-limited") {
        return "X has temporarily slowed requests. Scrolling will resume automatically after the cooldown.";
      }
      if (state.mode === "stopped") {
        return `Capture finished with ${state.jsonExportPosts.size} bookmark${state.jsonExportPosts.size === 1 ? "" : "s"}. Download the JSON file below.`;
      }
      return "Ready to capture. Bookmarks will be saved in this browser until you download the JSON file.";
    }

    if (state.connectionState === "retrying") {
      return "The connection to Xray was interrupted. The exporter will keep retrying automatically.";
    }
    if (state.connectionState === "connecting") {
      return "Connecting to Xray…";
    }
    if (state.lastErrorText) {
      return "Capture hit a problem. Open Advanced details for more information.";
    }
    if (state.mode === "running") {
      return `Capturing bookmarks and sending them to Xray. ${state.receiverAcceptedCount} received so far.`;
    }
    if (state.mode === "paused") {
      return "Automatic scrolling is paused. Xray can still finish importing bookmarks already captured.";
    }
    if (state.mode === "rate-limited") {
      return "X has temporarily slowed requests. Scrolling will resume automatically after the cooldown.";
    }
    if (state.mode === "stopped") {
      if (state.stoppedAfterExistingStreak) {
        return `Finished automatically after ${state.consecutiveSkippedExistingCount} consecutive bookmarks were already in Xray.`;
      }
      return `Capture finished. Xray received ${state.receiverAcceptedCount} bookmark${state.receiverAcceptedCount === 1 ? "" : "s"}.`;
    }
    return "Connected to Xray. Start capture and keep this bookmarks page open while it scrolls.";
  }

  function extractTweetResults(root) {
    const timelineResults = extractTimelineTweetResults(root);
    if (timelineResults.length > 0) {
      return timelineResults;
    }

    const results = [];
    const seen = new Set();

    visit(root);
    return results;

    function visit(node) {
      if (!node || typeof node !== "object") {
        return;
      }

      if (Array.isArray(node)) {
        for (const child of node) {
          visit(child);
        }
        return;
      }

      const tweetResult = node?.tweet_results?.result;
      if (tweetResult) {
        const unwrapped = unwrapResult(tweetResult);
        const restID = unwrapped?.rest_id;
        if (restID && !seen.has(restID)) {
          seen.add(restID);
          results.push(unwrapped);
        }
      }

      for (const value of Object.values(node)) {
        visit(value);
      }
    }
  }

  function extractTimelineTweetResults(root) {
    const results = [];
    const seen = new Set();

    for (const entries of findTimelineEntryArrays(root)) {
      for (const entry of entries) {
        for (const tweetResult of tweetResultsFromTimelineEntry(entry)) {
          const unwrapped = unwrapResult(tweetResult);
          const restID = unwrapped?.rest_id;
          if (restID && !seen.has(restID)) {
            seen.add(restID);
            results.push(unwrapped);
          }
        }
      }
    }

    return results;
  }

  function findTimelineEntryArrays(root) {
    const arrays = [];
    const visited = new Set();

    visit(root);
    return arrays;

    function visit(node) {
      if (!node || typeof node !== "object" || visited.has(node)) {
        return;
      }
      visited.add(node);

      if (Array.isArray(node)) {
        for (const child of node) {
          visit(child);
        }
        return;
      }

      if (Array.isArray(node.entries)) {
        arrays.push(node.entries);
      }

      if (Array.isArray(node.instructions)) {
        for (const instruction of node.instructions) {
          if (Array.isArray(instruction?.entries)) {
            arrays.push(instruction.entries);
          } else if (instruction?.entry) {
            arrays.push([instruction.entry]);
          }
        }
      }

      for (const value of Object.values(node)) {
        visit(value);
      }
    }
  }

  function tweetResultsFromTimelineEntry(entry) {
    const results = [];
    const content = entry?.content ?? entry;

    pushItemContent(content?.itemContent);
    pushItemContent(content?.item?.itemContent);
    pushItemContent(content?.content?.itemContent);

    const moduleItems = content?.items ?? content?.moduleItems ?? entry?.items ?? [];
    if (Array.isArray(moduleItems)) {
      for (const moduleItem of moduleItems) {
        pushItemContent(moduleItem?.item?.itemContent);
        pushItemContent(moduleItem?.itemContent);
      }
    }

    return results;

    function pushItemContent(itemContent) {
      const tweetResult = itemContent?.tweet_results?.result;
      if (tweetResult) {
        results.push(tweetResult);
      }
    }
  }

  function unwrapResult(result) {
    let current = result;

    while (current && typeof current === "object") {
      if (current.tweet) {
        current = current.tweet;
        continue;
      }
      if (current.result) {
        current = current.result;
        continue;
      }
      if (current.tweet_results?.result) {
        current = current.tweet_results.result;
        continue;
      }
      break;
    }

    return current;
  }

  function normalizeTweet(result) {
    const tweet = unwrapResult(result);
    if (!tweet || typeof tweet !== "object") {
      return null;
    }

    const restID = tweet.rest_id;
    const legacy = tweet.legacy;
    const user = unwrapUser(tweet.core?.user_results?.result);

    if (!restID || !legacy || !user) {
      return null;
    }

    const screenName = user.legacy?.screen_name ?? user.core?.screen_name;
    const profileImageURL = user.avatar?.image_url ?? user.legacy?.profile_image_url_https;
    if (!screenName || !profileImageURL) {
      return null;
    }

    const article = normalizeArticle(tweet.article?.article_results?.result);
    const cleanedTweetText = cleanExportText(noteTweetText(tweet) ?? legacy.full_text ?? "");

    return {
      id: restID,
      created_at: formatArchiveDate(legacy.created_at),
      full_text: cleanedTweetText || article?.searchable_text || "",
      media: normalizeMedia(legacy),
      article,
      links: normalizeLinks(tweet),
      quoted_post: normalizeQuotedPost(tweet),
      screen_name: screenName,
      name: user.legacy?.name ?? user.core?.name ?? screenName,
      profile_image_url: profileImageURL,
      profile_image_shape: profileImageShape(user),
      url: `https://x.com/${screenName}/status/${restID}`,
      text_embedding: [],
      img_embedding: [],
      primary_topic: "",
      secondary_topics: [],
    };
  }

  function normalizeQuotedPost(tweet) {
    const quoted = unwrapResult(
      tweet.quoted_status_result?.result ??
      tweet.note_tweet?.quoted_tweet_results?.result ??
      tweet.legacy?.quoted_status_result?.result
    );

    if (!quoted?.legacy) {
      return null;
    }

    const user = unwrapUser(quoted.core?.user_results?.result);
    const screenName = user?.legacy?.screen_name ?? user?.core?.screen_name;
    const profileImageURL = user?.avatar?.image_url ?? user?.legacy?.profile_image_url_https;
    if (!quoted.rest_id || !screenName || !profileImageURL) {
      return null;
    }

    const article = normalizeArticle(quoted.article?.article_results?.result);
    const cleanedQuotedText = cleanExportText(noteTweetText(quoted) ?? quoted.legacy.full_text ?? "");

    return {
      id: quoted.rest_id,
      created_at: quoted.legacy.created_at ? formatArchiveDate(quoted.legacy.created_at) : null,
      full_text: cleanedQuotedText || article?.searchable_text || "",
      media: normalizeMedia(quoted.legacy),
      screen_name: screenName,
      name: user?.legacy?.name ?? user?.core?.name ?? screenName,
      profile_image_url: profileImageURL,
      profile_image_shape: profileImageShape(user),
      url: `https://x.com/${screenName}/status/${quoted.rest_id}`,
    };
  }

  function unwrapUser(userResult) {
    let current = userResult;
    while (current && typeof current === "object" && current.result) {
      current = current.result;
    }
    return current;
  }

  function noteTweetText(tweet) {
    return tweet.note_tweet?.note_tweet_results?.result?.text ?? null;
  }

  function cleanExportText(text) {
    return String(text ?? "")
      .replace(/\S*t\.co\S*/g, "")
      .trim();
  }

  function normalizeLinks(tweet) {
    const urls = tweet?.legacy?.entities?.urls ?? [];
    const card = normalizeCard(tweet?.card);
    const normalized = urls.map((entity) => {
      const url = entity?.url;
      if (!url) {
        return null;
      }
      return {
        url,
        expanded_url: entity?.expanded_url ?? null,
        display_url: entity?.display_url ?? null,
        card,
      };
    }).filter(Boolean);

    if (normalized.length === 0 && card?.url) {
      normalized.push({
        url: card.url,
        expanded_url: null,
        display_url: card.vanity_url ?? card.domain ?? null,
        card,
      });
    }

    return normalized.length > 0 ? normalized : [];
  }

  function normalizeCard(card) {
    const legacy = card?.legacy;
    const bindings = Array.isArray(legacy?.binding_values) ? legacy.binding_values : [];
    if (bindings.length === 0) {
      return null;
    }

    const strings = new Map();
    const images = new Map();
    for (const binding of bindings) {
      const key = binding?.key;
      const value = binding?.value;
      if (!key || !value) {
        continue;
      }
      if (typeof value.string_value === "string" && value.string_value.trim()) {
        strings.set(key, value.string_value.trim());
      }
      if (value.image_value?.url) {
        images.set(key, value.image_value);
      }
    }

    const image = images.get("summary_photo_image_large")
      ?? images.get("photo_image_full_size_large")
      ?? images.get("summary_photo_image")
      ?? images.get("photo_image_full_size")
      ?? images.get("thumbnail_image_large")
      ?? images.get("thumbnail_image")
      ?? images.get("summary_photo_image_original")
      ?? images.get("photo_image_full_size_original")
      ?? null;

    const normalized = {
      title: strings.get("title") ?? null,
      description: strings.get("description") ?? null,
      domain: strings.get("domain") ?? null,
      vanity_url: strings.get("vanity_url") ?? null,
      image_url: image?.url ?? null,
      image_alt: strings.get("summary_photo_image_alt_text") ?? strings.get("photo_image_full_size_alt_text") ?? image?.alt ?? null,
      image_width: typeof image?.width === "number" ? image.width : null,
      image_height: typeof image?.height === "number" ? image.height : null,
      url: legacy?.url ?? card?.rest_id ?? null,
    };

    const hasPreviewContent = [
      normalized.title,
      normalized.description,
      normalized.domain,
      normalized.vanity_url,
      normalized.image_url,
    ].some((value) => typeof value === "string" && value.length > 0);

    return hasPreviewContent ? normalized : null;
  }

  function normalizeArticle(articleResult) {
    if (!articleResult || typeof articleResult !== "object") {
      return null;
    }

    const title = String(articleResult.title ?? "").trim();
    const contentState = articleResult.content_state;
    const blocks = Array.isArray(contentState?.blocks) ? contentState.blocks : [];
    if (!title && blocks.length === 0) {
      return null;
    }

    const normalizedBlocks = blocks.map((block) => ({
      key: block?.key ?? crypto.randomUUID(),
      text: typeof block?.text === "string" ? block.text : "",
      type: typeof block?.type === "string" ? block.type : "unstyled",
      data: block?.data ?? {},
      entityRanges: Array.isArray(block?.entityRanges) ? block.entityRanges.map((range) => ({
        key: Number(range?.key ?? -1),
        offset: Number(range?.offset ?? 0),
        length: Number(range?.length ?? 0),
      })) : [],
      inlineStyleRanges: Array.isArray(block?.inlineStyleRanges) ? block.inlineStyleRanges.map((range) => ({
        offset: Number(range?.offset ?? 0),
        length: Number(range?.length ?? 0),
        style: typeof range?.style === "string" ? range.style : "",
      })) : [],
    }));

    const normalizedEntityMap = Array.isArray(contentState?.entityMap)
      ? contentState.entityMap.map((entry, index) => ({
        key: String(entry?.key ?? index),
        value: {
          type: String(entry?.value?.type ?? ""),
          data: {
            url: entry?.value?.data?.url ?? null,
            caption: entry?.value?.data?.caption ?? null,
            mediaItems: Array.isArray(entry?.value?.data?.mediaItems) ? entry.value.data.mediaItems.map((item) => ({
              localMediaId: item?.localMediaId ?? null,
              mediaCategory: item?.mediaCategory ?? null,
              mediaId: item?.mediaId ?? item?.media_id ?? null,
            })) : null,
            tweetId: entry?.value?.data?.tweetId ?? null,
          },
        },
      }))
      : [];

    const normalizedMediaEntities = Array.isArray(articleResult.media_entities)
      ? articleResult.media_entities
        .map(normalizeArticleMediaEntity)
        .filter(Boolean)
      : [];

    const coverMedia = normalizeArticleMediaEntity(articleResult.cover_media);
    const paragraphs = normalizedBlocks
      .filter((block) => block.type !== "atomic")
      .map((block) => block.text.trim())
      .filter(Boolean);
    const searchableText = [title, ...paragraphs].join("\n\n").trim();

    return {
      rest_id: articleResult.rest_id ?? null,
      title,
      preview_text: articleResult.preview_text ?? null,
      summary_text: articleResult.summary_text ?? null,
      cover_media: coverMedia,
      media_entities: normalizedMediaEntities,
      content_state: {
        blocks: normalizedBlocks,
        entityMap: normalizedEntityMap,
      },
      searchable_text: searchableText,
    };
  }

  function normalizeArticleMediaEntity(entity) {
    const originalURL = entity?.media_info?.original_img_url;
    if (!entity?.media_id || !originalURL) {
      return null;
    }

    return {
      media_id: String(entity.media_id),
      media_info: {
        original_img_url: originalURL,
        original_img_width: typeof entity.media_info?.original_img_width === "number" ? entity.media_info.original_img_width : null,
        original_img_height: typeof entity.media_info?.original_img_height === "number" ? entity.media_info.original_img_height : null,
      },
    };
  }

  function normalizeMedia(legacy) {
    const candidates = legacy?.extended_entities?.media ?? legacy?.entities?.media ?? [];
    const normalized = candidates.map((item) => {
      const type = item?.type ?? "";
      const mediaURL = item?.media_url_https;
      const size = item?.sizes?.large ?? item?.sizes?.medium ?? item?.sizes?.small ?? item?.sizes?.thumb;
      if (!type || !mediaURL) {
        return null;
      }

      if (type.includes("video") || type.includes("animated_gif")) {
        const variants = item?.video_info?.variants ?? [];
        const bestVariant = [...variants]
          .filter((variant) => variant?.content_type === "video/mp4" && variant?.url)
          .sort((left, right) => (right?.bitrate ?? 0) - (left?.bitrate ?? 0))[0];

        return {
          type,
          thumbnail: buildSizedMediaURL(mediaURL, "small"),
          original: bestVariant?.url ?? mediaURL,
          width: size?.w,
          height: size?.h,
        };
      }

      return {
        type,
        thumbnail: buildSizedMediaURL(mediaURL, "small"),
        original: buildSizedMediaURL(mediaURL, "orig"),
        width: size?.w,
        height: size?.h,
      };
    }).filter(Boolean);

    return normalized.length > 0 ? normalized : null;
  }

  function buildSizedMediaURL(url, size) {
    const parsed = new URL(url);
    const pathname = parsed.pathname;
    const extension = pathname.split(".").pop() || "jpg";
    const withoutExtension = pathname.endsWith(`.${extension}`)
      ? pathname.slice(0, -(`.${extension}`).length)
      : pathname;
    return `${parsed.origin}${withoutExtension}?format=${extension}&name=${size}`;
  }

  function profileImageShape(user) {
    if (user?.profile_image_shape === "Square") {
      return "Square";
    }

    const professionalType = user?.professional?.professional_type?.toLowerCase();
    const verifiedType = user?.verification?.verified_type?.toLowerCase();
    if (professionalType === "business" || verifiedType === "business") {
      return "Square";
    }

    return "Circle";
  }

  function formatArchiveDate(rawDate) {
    const date = new Date(rawDate);
    if (Number.isNaN(date.getTime())) {
      throw new Error(`Could not parse tweet date: ${rawDate}`);
    }

    const year = date.getFullYear();
    const month = pad2(date.getMonth() + 1);
    const day = pad2(date.getDate());
    const hours = pad2(date.getHours());
    const minutes = pad2(date.getMinutes());
    const seconds = pad2(date.getSeconds());
    const offsetMinutes = -date.getTimezoneOffset();
    const sign = offsetMinutes >= 0 ? "+" : "-";
    const absoluteOffset = Math.abs(offsetMinutes);
    const offsetHours = pad2(Math.floor(absoluteOffset / 60));
    const offsetRemainder = pad2(absoluteOffset % 60);
    return `${year}-${month}-${day} ${hours}:${minutes}:${seconds} ${sign}${offsetHours}${offsetRemainder}`;
  }

  function updateAdaptiveScrollSpeed() {
    const now = Date.now();
    const timeSinceResponse = state.lastResponseAt === 0 ? Infinity : now - state.lastResponseAt;
    let targetSpeed = state.maxScrollSpeed;

    if (timeSinceResponse > RESPONSE_STALE_AFTER_MS) {
      targetSpeed = Math.max(
        MIN_SCROLL_PIXELS_PER_SECOND,
        Math.round(state.maxScrollSpeed * 0.55)
      );
    } else if (timeSinceResponse > RESPONSE_RECENT_AFTER_MS) {
      targetSpeed = Math.max(
        MIN_SCROLL_PIXELS_PER_SECOND,
        Math.round(state.maxScrollSpeed * 0.82)
      );
    }

    if (state.adaptiveSpeed < targetSpeed) {
      state.adaptiveSpeed = Math.min(targetSpeed, state.adaptiveSpeed + 220);
    } else if (state.adaptiveSpeed > targetSpeed) {
      state.adaptiveSpeed = Math.max(targetSpeed, state.adaptiveSpeed - 140);
    }
  }

  function extractURLFromFetchArgs(args) {
    const input = args[0];
    if (typeof input === "string") {
      return input;
    }
    if (input instanceof URL) {
      return input.toString();
    }
    if (typeof Request !== "undefined" && input instanceof Request) {
      return input.url;
    }
    return "";
  }

  function isBookmarksGraphQLURL(urlString) {
    if (!urlString) {
      return false;
    }

    try {
      const url = new URL(urlString, window.location.origin);
      return url.pathname.includes("/graphql/") && url.pathname.endsWith("/Bookmarks");
    } catch {
      return false;
    }
  }

  function syncReceiverCredentialsFromUI() {
    if (!state.statusElements) {
      return;
    }
    state.receiverURL = state.statusElements.receiverURL.value.trim();
    state.sessionToken = state.statusElements.sessionToken.value.trim();
    writeStorage(STORAGE_KEYS.receiverURL, state.receiverURL);
    writeStorage(STORAGE_KEYS.sessionToken, state.sessionToken);
  }

  function exportTimestamp() {
    const now = new Date();
    return [
      now.getFullYear(),
      pad2(now.getMonth() + 1),
      pad2(now.getDate()),
      "-",
      pad2(now.getHours()),
      pad2(now.getMinutes()),
      pad2(now.getSeconds()),
    ].join("");
  }

  function timeStamp() {
    return new Date().toLocaleTimeString();
  }

  function pad2(value) {
    return String(value).padStart(2, "0");
  }

  function createSessionId() {
    return `xray-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 10)}`;
  }

  function readString(key, fallback) {
    try {
      return window.localStorage.getItem(key) || fallback;
    } catch {
      return fallback;
    }
  }

  function readNumber(key, fallback) {
    const value = Number(readString(key, ""));
    return Number.isFinite(value) ? value : fallback;
  }

  function readBoolean(key, fallback) {
    const value = readString(key, fallback ? "1" : "0");
    return value === "1";
  }

  function readStoredExportPosts() {
    const value = readJSONStorage(STORAGE_KEYS.jsonExportPosts, []);
    const posts = Array.isArray(value) ? value : [];
    const map = new Map();

    for (const post of posts) {
      if (post && typeof post.id === "string") {
        map.set(post.id, post);
      }
    }

    return map;
  }

  function mergeObservedPostsIntoExport(observedPosts) {
    const observed = [];
    const observedIds = new Set();
    let added = 0;

    for (const post of observedPosts) {
      if (!post || typeof post.id !== "string" || observedIds.has(post.id)) {
        continue;
      }
      observed.push(post);
      observedIds.add(post.id);
      if (!state.jsonExportPosts.has(post.id)) {
        added += 1;
      }
    }

    if (observed.length === 0) {
      return 0;
    }

    const previousEntries = [...state.jsonExportPosts.entries()];
    const previousIndexById = new Map(
      previousEntries.map(([id], index) => [id, index])
    );
    let insertIndex = null;

    for (const post of observed) {
      const previousIndex = previousIndexById.get(post.id);
      if (previousIndex !== undefined) {
        insertIndex = insertIndex === null ? previousIndex : Math.min(insertIndex, previousIndex);
      }
    }

    if (insertIndex === null) {
      if (state.jsonExportUnanchoredInsertIndex !== null) {
        insertIndex = state.jsonExportUnanchoredInsertIndex;
      } else if (state.jsonExportHadStoredPosts && state.bookmarkResponseCount === 1) {
        insertIndex = 0;
      } else {
        insertIndex = previousEntries.length;
      }
    } else {
      state.jsonExportUnanchoredInsertIndex = null;
    }

    const remainingEntries = previousEntries.filter(([id]) => !observedIds.has(id));
    const boundedInsertIndex = Math.max(0, Math.min(insertIndex, previousEntries.length));
    const remainingInsertIndex = previousEntries
      .slice(0, boundedInsertIndex)
      .filter(([id]) => !observedIds.has(id))
      .length;
    const observedEntries = observed.map((post) => [post.id, post]);
    state.jsonExportPosts = new Map([
      ...remainingEntries.slice(0, remainingInsertIndex),
      ...observedEntries,
      ...remainingEntries.slice(remainingInsertIndex),
    ]);

    if (insertIndex !== null && !observed.some((post) => previousIndexById.has(post.id))) {
      state.jsonExportUnanchoredInsertIndex = remainingInsertIndex + observedEntries.length;
    }

    return added;
  }

  function scheduleExportPostsPersist() {
    if (state.jsonExportPersistTimer !== null) {
      window.clearTimeout(state.jsonExportPersistTimer);
    }
    state.jsonExportPersistTimer = window.setTimeout(() => {
      state.jsonExportPersistTimer = null;
      persistExportPostsNow();
    }, 500);
  }

  function persistExportPostsNow() {
    if (state.jsonExportPersistTimer !== null) {
      window.clearTimeout(state.jsonExportPersistTimer);
      state.jsonExportPersistTimer = null;
    }
    writeJSONStorage(STORAGE_KEYS.jsonExportPosts, [...state.jsonExportPosts.values()]);
  }

  function readJSONStorage(key, fallback) {
    try {
      const value = typeof GM_getValue === "function"
        ? GM_getValue(key, null)
        : window.localStorage.getItem(key);
      if (!value) {
        return fallback;
      }
      if (typeof value !== "string") {
        return value;
      }
      return JSON.parse(value);
    } catch {
      return fallback;
    }
  }

  function writeJSONStorage(key, value) {
    try {
      const serialized = JSON.stringify(value);
      if (typeof GM_setValue === "function") {
        GM_setValue(key, serialized);
      } else {
        window.localStorage.setItem(key, serialized);
      }
    } catch {
      // ignore storage failures
    }
  }

  function writeStorage(key, value) {
    try {
      window.localStorage.setItem(key, value);
    } catch {
      // ignore storage failures
    }
  }

  function buttonBaseStyle() {
    return [
      "appearance:none",
      "border:none",
      "border-radius:10px",
      "padding:8px 10px",
      "background:#f5f5f7",
      "color:#111217",
      "font:600 12px/1.2 -apple-system,BlinkMacSystemFont,Segoe UI,system-ui,sans-serif",
      "cursor:pointer",
    ].join(";");
  }

  function textInputStyle() {
    return [
      "appearance:none",
      "border:1px solid rgba(255,255,255,0.12)",
      "border-radius:10px",
      "padding:8px 10px",
      "background:rgba(12,12,16,0.92)",
      "color:#f5f5f7",
      "font:12px/1.2 ui-monospace,SFMono-Regular,Menlo,monospace",
      "outline:none",
      "width:100%",
      "box-sizing:border-box",
    ].join(";");
  }

  function escapeAttribute(value) {
    return String(value)
      .replaceAll("&", "&amp;")
      .replaceAll("\"", "&quot;")
      .replaceAll("<", "&lt;")
      .replaceAll(">", "&gt;");
  }

  function safeJSONParse(text) {
    if (!text) {
      return {};
    }
    try {
      return JSON.parse(text);
    } catch {
      return {};
    }
  }

  function requestReceiverOnce(baseURL, path, options) {
    return new Promise((resolve, reject) => {
      const timeoutId = window.setTimeout(() => {
        reject(new Error("Timed out talking to the Xray receiver."));
      }, STREAM_REQUEST_TIMEOUT_MS);

      GM_xmlhttpRequest({
        url: `${baseURL}${path}`,
        method: options.method,
        headers: {
          "Content-Type": "application/json",
          "X-Xray-Session-Token": state.sessionToken,
        },
        data: options.body,
        responseType: "text",
        onload: (response) => {
          window.clearTimeout(timeoutId);
          const payload = safeJSONParse(response.responseText);
          if (response.status < 200 || response.status >= 300) {
            const message = payload?.message || payload?.receiverStatus || `HTTP ${response.status}`;
            reject(new Error(message));
            return;
          }
          resolve(payload);
        },
        onerror: () => {
          window.clearTimeout(timeoutId);
          reject(new Error(`Failed to reach the Xray receiver at ${baseURL}.`));
        },
        ontimeout: () => {
          window.clearTimeout(timeoutId);
          reject(new Error(`Timed out talking to the Xray receiver at ${baseURL}.`));
        },
      });
    });
  }

  function buildReceiverCandidates(rawURL) {
    const trimmed = rawURL.trim();
    if (!trimmed) {
      return [];
    }

    try {
      const parsed = new URL(trimmed);
      const candidates = [];
      const portsuffix = parsed.port ? `:${parsed.port}` : "";
      const pathSuffix = parsed.pathname === "/" ? "" : parsed.pathname;
      const searchSuffix = parsed.search || "";

      const hosts = [];
      if (parsed.hostname === "127.0.0.1") {
        hosts.push("127.0.0.1", "localhost", "[::1]");
      } else if (parsed.hostname === "localhost") {
        hosts.push("localhost", "127.0.0.1", "[::1]");
      } else if (parsed.hostname === "[::1]" || parsed.hostname === "::1") {
        hosts.push("[::1]", "localhost", "127.0.0.1");
      } else {
        hosts.push(parsed.host);
      }

      for (const host of hosts) {
        const hostWithPort = host.includes(":") && !host.startsWith("[")
          ? `[${host}]${portsuffix}`
          : `${host}${portsuffix}`;
        candidates.push(`${parsed.protocol}//${hostWithPort}${pathSuffix}${searchSuffix}`);
      }

      return [...new Set(candidates)];
    } catch {
      return [trimmed];
    }
  }
})();
