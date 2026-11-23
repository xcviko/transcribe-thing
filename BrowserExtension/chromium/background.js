// transcribe-thing: the service worker. Gathers each tab's call state from its frames (relay.js) and keeps the app
// told, through the native messaging host (the app's own executable, which relays to the running app).
//
// Protocol (JSON, one message per native message, `v` its version; the app ignores types and fields it doesn't
// know, so later versions can add per-tab audio as new message types):
//   to the app:
//     {v:1, type:'hello', installID, version, browser}     first, on every connection
//     {v:1, type:'tab', tab:Tab}                           a tab's state changed (inCall and micLive false: it's over)
//     {v:1, type:'gone', id}                               a tab that had a state closed
//     {v:1, type:'audible', tabs:[id]}                     the tabs playing sound now
//     {v:1, type:'state', tabs:[Tab], audible:[id]}        everything, every 5 s: the heartbeat
//   Tab: {id, windowId, host, room, title, audible, inCall, micLive, muted}; `room` is the call's code when the
//   address names it (Meet's abc-defg-hij), `muted` is true, false or null (unknown).
//   from the host or the app:
//     {v:1, type:'app', connected}                         the host reached the app (send everything) or lost it
'use strict';

const api = globalThis.chrome || globalThis.browser;
const HOST = 'dev.transcribe_thing.bridge';
const PROTOCOL = 1;
const HEARTBEAT_MS = 5000;
/** A frame not heard from for this long is gone (relay.js repeats itself every 10 s). */
const FRAME_STALE_MS = 30000;

/** tabId -> { frames: Map<frameKey, {state, at}>, info: chrome tab, sent: JSON of the last Tab sent } */
const tabs = new Map();
let port = null;
let retryDelay = 2000;
let retryTimer = null;
let lastAudible = '';
let installID = null;

function getInstallID() {
  if (!installID) {
    installID = api.storage.local.get('installID').then(async (stored) => {
      if (stored && typeof stored.installID === 'string' && stored.installID) return stored.installID;
      const made = crypto.randomUUID();
      await api.storage.local.set({ installID: made });
      return made;
    });
  }
  return installID;
}

function post(message) {
  if (!port) return;
  try {
    port.postMessage({ v: PROTOCOL, ...message });
  } catch (e) {
    // The port died; onDisconnect reconnects.
  }
}

// MARK: The connection

function connect() {
  if (port) return;
  clearTimeout(retryTimer);
  retryTimer = null;
  try {
    port = api.runtime.connectNative(HOST);
  } catch (e) {
    port = null;
    return retryLater();
  }
  port.onMessage.addListener(fromHost);
  port.onDisconnect.addListener(() => {
    void api.runtime.lastError; // "Specified native messaging host not found." until the app has set it up
    port = null;
    retryLater();
  });
  const opened = port;
  getInstallID().then((id) => {
    if (port !== opened) return;
    post({ type: 'hello', installID: id, version: api.runtime.getManifest().version, browser: browserName() });
    sendEverything();
  });
}

function retryLater() {
  if (retryTimer) return;
  retryTimer = setTimeout(() => {
    retryTimer = null;
    connect();
  }, retryDelay);
  retryDelay = Math.min(retryDelay * 2, 30000);
}

function fromHost(message) {
  if (!message || typeof message !== 'object') return;
  if (message.type === 'app' && message.connected) {
    retryDelay = 2000;
    sendEverything();
  }
}

function browserName() {
  try {
    const brands = (navigator.userAgentData && navigator.userAgentData.brands) || [];
    return brands.map((brand) => brand.brand).filter((name) => !/not.a.brand/i.test(name)).join(', ');
  } catch (e) {
    return '';
  }
}

// MARK: Tabs

function hostOf(url) {
  try {
    return new URL(url).hostname;
  } catch (e) {
    return '';
  }
}

/** The call's code in the address, where a service puts one: Meet's /abc-defg-hij. */
function roomOf(url) {
  try {
    const parsed = new URL(url);
    if (parsed.hostname !== 'meet.google.com') return null;
    const code = parsed.pathname.split('/').find((part) => /^[a-z]{3}-[a-z]{4}-[a-z]{3}$/.test(part));
    return code || null;
  } catch (e) {
    return null;
  }
}

/** A tab's frames together: in a call if one is, the mic live if one has it; muted unless a frame in a call is
 * heard, unknown if one can't tell. */
function merged(entry, now) {
  let inCall = false;
  let micLive = false;
  const mutes = [];
  for (const [key, frame] of entry.frames) {
    if (now - frame.at > FRAME_STALE_MS) {
      entry.frames.delete(key);
      continue;
    }
    inCall = inCall || frame.state.inCall;
    micLive = micLive || frame.state.micLive;
    if (frame.state.inCall) mutes.push(frame.state.muted);
  }
  let muted = null;
  if (mutes.includes(false)) muted = false;
  else if (mutes.length > 0 && !mutes.includes(null)) muted = true;
  return { inCall, micLive, muted };
}

function payload(tabId, entry, now) {
  const state = merged(entry, now);
  const info = entry.info || {};
  return {
    id: tabId,
    windowId: typeof info.windowId === 'number' ? info.windowId : null,
    host: hostOf(info.url || ''),
    room: roomOf(info.url || ''),
    title: info.title || '',
    audible: !!info.audible,
    ...state,
  };
}

/** Tells the app about a tab when what it would say has changed; a tab with nothing left is said once, then dropped. */
function report(tabId, now = Date.now()) {
  const entry = tabs.get(tabId);
  if (!entry) return;
  const tab = payload(tabId, entry, now);
  const text = JSON.stringify(tab);
  if (text !== entry.sent) {
    entry.sent = text;
    post({ type: 'tab', tab });
  }
  if (!tab.inCall && !tab.micLive) tabs.delete(tabId);
}

function sendEverything() {
  const now = Date.now();
  const list = [];
  for (const [tabId, entry] of tabs) {
    const tab = payload(tabId, entry, now);
    if (!tab.inCall && !tab.micLive) {
      report(tabId, now);
      continue;
    }
    entry.sent = JSON.stringify(tab);
    list.push(tab);
  }
  api.tabs.query({ audible: true }).then(
    (audible) => {
      const ids = audible.map((tab) => tab.id);
      lastAudible = JSON.stringify(ids);
      post({ type: 'state', tabs: list, audible: ids });
    },
    () => post({ type: 'state', tabs: list }),
  );
}

function sendAudible() {
  api.tabs.query({ audible: true }).then((audible) => {
    const ids = audible.map((tab) => tab.id);
    const text = JSON.stringify(ids);
    if (text === lastAudible) return;
    lastAudible = text;
    post({ type: 'audible', tabs: ids });
  }, () => {});
}

api.runtime.onMessage.addListener((message, sender) => {
  if (!message || message.type !== 'frame' || !sender.tab || typeof sender.tab.id !== 'number') return;
  const state = message.state || {};
  const tabId = sender.tab.id;
  const key = sender.documentId || `frame-${sender.frameId}`;
  let entry = tabs.get(tabId);
  const active = !!(state.inCall || state.micLive);
  if (!entry) {
    if (!active) return;
    entry = { frames: new Map(), info: sender.tab, sent: '' };
    tabs.set(tabId, entry);
  }
  entry.info = sender.tab;
  if (active) {
    entry.frames.set(key, { state: { inCall: !!state.inCall, micLive: !!state.micLive, muted: state.muted }, at: Date.now() });
  } else {
    entry.frames.delete(key);
  }
  connect();
  report(tabId);
});

api.tabs.onUpdated.addListener((tabId, change, tab) => {
  if ('audible' in change) sendAudible();
  const entry = tabs.get(tabId);
  if (!entry || !('title' in change || 'url' in change || 'audible' in change)) return;
  entry.info = tab;
  report(tabId);
});

api.tabs.onRemoved.addListener((tabId) => {
  if (!tabs.has(tabId)) return;
  tabs.delete(tabId);
  post({ type: 'gone', id: tabId });
});

setInterval(() => {
  const now = Date.now();
  for (const tabId of [...tabs.keys()]) report(tabId, now);
  if (port) sendEverything();
}, HEARTBEAT_MS);

// A service worker that starts again has forgotten every tab: their frames say again.
api.tabs.query({}).then((all) => {
  for (const tab of all) {
    const sent = api.tabs.sendMessage(tab.id, { type: 'resend' });
    if (sent && typeof sent.catch === 'function') sent.catch(() => {});
  }
}, () => {});

connect();
