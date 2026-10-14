// The service worker (chromium/background.js) against a made-up chrome.*: run with
// `node --test BrowserExtension/tests/*.test.mjs`. Frames say their state as relay.js does; what goes to the native
// port is what the app gets.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';

const source = readFileSync(new URL('../chromium/background.js', import.meta.url), 'utf8');

function load({ hostInstalled = true } = {}) {
  const sent = [];
  const listeners = { message: [], updated: [], removed: [] };
  const intervals = [];
  const timers = [];
  let port = null;
  const audible = [];
  const chrome = {
    runtime: {
      lastError: undefined,
      getManifest: () => ({ version: '1.0.0' }),
      onMessage: { addListener: (fn) => listeners.message.push(fn) },
      connectNative: (name) => {
        assert.equal(name, 'dev.transcribe_thing.bridge');
        const disconnect = [];
        const incoming = [];
        port = {
          postMessage: (message) => sent.push(JSON.parse(JSON.stringify(message))),
          onMessage: { addListener: (fn) => incoming.push(fn) },
          onDisconnect: { addListener: (fn) => disconnect.push(fn) },
          receive: (message) => incoming.forEach((fn) => fn(message)),
          drop: () => disconnect.forEach((fn) => fn()),
        };
        if (!hostInstalled) queueMicrotask(() => port.drop());
        return port;
      },
    },
    storage: { local: (() => {
      const data = {};
      return { get: async (key) => (key in data ? { [key]: data[key] } : {}), set: async (values) => Object.assign(data, values) };
    })() },
    tabs: {
      query: async (filter) => (filter && filter.audible ? audible.map((id) => ({ id })) : []),
      sendMessage: () => Promise.resolve(),
      onUpdated: { addListener: (fn) => listeners.updated.push(fn) },
      onRemoved: { addListener: (fn) => listeners.removed.push(fn) },
    },
  };
  const context = vm.createContext({
    chrome, crypto, navigator: {}, URL, JSON, Promise, Map, Math, Date,
    setTimeout: (fn) => timers.push(fn), clearTimeout: () => {}, setInterval: (fn) => intervals.push(fn),
  });
  vm.runInContext(source, context);
  const settle = () => new Promise((resolve) => setTimeout(resolve, 5));
  return {
    sent,
    audible,
    port: () => port,
    settle,
    frame(tab, state, frameId = 0, documentId = `doc-${tab.id}-${frameId}`) {
      for (const fn of listeners.message) fn({ type: 'frame', state }, { tab, frameId, documentId });
    },
    update(tabId, change, tab) { for (const fn of listeners.updated) fn(tabId, change, tab); },
    remove(tabId) { for (const fn of listeners.removed) fn(tabId); },
    heartbeat() { intervals.forEach((fn) => fn()); },
    timers,
  };
}

const meet = { id: 3, windowId: 1, url: 'https://meet.google.com/abc-defg-hij?authuser=0', title: 'Meet - abc-defg-hij', audible: true };

test('hello first, then a tab as its call starts, mutes and ends', async () => {
  const sw = load();
  await sw.settle();
  assert.equal(sw.sent[0].type, 'hello');
  assert.equal(sw.sent[0].v, 1);
  assert.match(sw.sent[0].installID, /^[0-9a-f-]{36}$/);
  assert.equal(sw.sent[0].version, '1.0.0');
  sw.sent.length = 0;

  sw.frame(meet, { inCall: true, micLive: true, muted: false });
  const tab = sw.sent.at(-1);
  assert.equal(tab.type, 'tab');
  assert.deepEqual(tab.tab, { id: 3, windowId: 1, host: 'meet.google.com', room: 'abc-defg-hij', title: 'Meet - abc-defg-hij',
    audible: true, inCall: true, micLive: true, muted: false });
  const count = sw.sent.length;
  sw.frame(meet, { inCall: true, micLive: true, muted: false });
  assert.equal(sw.sent.length, count, 'the same state again says nothing');

  // An iframe of the page with the mic only: the tab is still heard.
  sw.frame(meet, { inCall: false, micLive: true, muted: null }, 5);
  sw.frame(meet, { inCall: true, micLive: true, muted: true });
  assert.equal(sw.sent.at(-1).tab.muted, true);

  sw.frame(meet, { inCall: false, micLive: false, muted: null });
  sw.frame(meet, { inCall: false, micLive: false, muted: null }, 5);
  assert.deepEqual([sw.sent.at(-1).tab.inCall, sw.sent.at(-1).tab.micLive], [false, false]);
  const after = sw.sent.length;
  sw.heartbeat();
  await sw.settle();
  assert.deepEqual(sw.sent.slice(after).map((m) => m.type), ['state']);
  assert.deepEqual(sw.sent.at(-1).tabs, [], 'an ended tab is dropped');
});

test('a retitled tab is told again; a closed one is gone; the heartbeat lists what is on', async () => {
  const sw = load();
  await sw.settle();
  const slack = { id: 7, windowId: 2, url: 'https://app.slack.com/client/T1/C1', title: 'general - Slack', audible: false };
  sw.frame(slack, { inCall: true, micLive: true, muted: false });
  sw.update(7, { title: 'random - Slack' }, { ...slack, title: 'random - Slack' });
  assert.equal(sw.sent.at(-1).tab.title, 'random - Slack');
  assert.equal(sw.sent.at(-1).tab.room, null);
  sw.audible.push(9);
  sw.heartbeat();
  await sw.settle();
  const state = sw.sent.at(-1);
  assert.equal(state.type, 'state');
  assert.deepEqual(state.tabs.map((t) => t.id), [7]);
  assert.deepEqual(state.audible, [9]);
  sw.remove(7);
  assert.deepEqual(sw.sent.at(-1), { v: 1, type: 'gone', id: 7 });
});

test('the app coming back gets everything', async () => {
  const sw = load();
  await sw.settle();
  sw.frame(meet, { inCall: true, micLive: true, muted: false });
  sw.sent.length = 0;
  sw.port().receive({ v: 1, type: 'app', connected: true });
  await sw.settle();
  assert.equal(sw.sent.at(-1).type, 'state');
  assert.equal(sw.sent.at(-1).tabs[0].id, 3);
});

test('without the host it tries again later, and says nothing meanwhile', async () => {
  const sw = load({ hostInstalled: false });
  await sw.settle();
  assert.equal(sw.timers.length, 1, 'a retry is set');
  sw.frame(meet, { inCall: true, micLive: true, muted: false });
  assert.ok(sw.sent.every((m) => m.type === 'hello' || m.type === 'tab'));
});
