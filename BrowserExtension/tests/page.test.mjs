// The page hooks (chromium/page.js) against a made-up WebRTC: run with `node --test BrowserExtension/tests/*.test.mjs`.
// Each test loads page.js into a fresh context whose MediaDevices, MediaStreamTrack, RTCPeerConnection and
// AudioContext behave like the browser's as far as the hooks look, then plays a call through them.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';

const pageSource = readFileSync(new URL('../chromium/page.js', import.meta.url), 'utf8');

const fakes = `
class EventTarget {
  constructor() { this._listeners = {}; }
  addEventListener(type, fn) { (this._listeners[type] ||= []).push(fn); }
  removeEventListener() {}
  dispatchEvent(event) { for (const fn of this._listeners[event.type] || []) fn(event); return true; }
}
class CustomEvent { constructor(type, init) { this.type = type; this.detail = init && init.detail; } }
const timers = [];
function setTimeout(fn) { timers.push(fn); return timers.length; }
function setInterval(fn) { intervals.push(fn); return intervals.length; }
const intervals = [];
const document = new EventTarget();

class MediaStreamTrack extends EventTarget {
  constructor(kind) { super(); this.kind = kind; this.readyState = 'live'; this._enabled = true; }
  clone() { const copy = new MediaStreamTrack(this.kind); copy._enabled = this._enabled; return copy; }
  stop() { this.readyState = 'ended'; }
}
Object.defineProperty(MediaStreamTrack.prototype, 'enabled', {
  get() { return this._enabled; }, set(value) { this._enabled = !!value; }, configurable: true, enumerable: true,
});
class MediaStream { constructor(tracks) { this.tracks = tracks; } getAudioTracks() { return this.tracks.filter((t) => t.kind === 'audio'); } }
class MediaDevices { getUserMedia(constraints) {
  if (!constraints) return Promise.reject(new TypeError('no constraints'));
  return Promise.resolve(new MediaStream([new MediaStreamTrack('audio')]));
} }
const navigator = { mediaDevices: new MediaDevices() };

class RTCRtpSender { constructor(track) { this.track = track; } replaceTrack(track) { this.track = track; return Promise.resolve(); } }
class RTCPeerConnection extends EventTarget {
  constructor() { super(); this.connectionState = 'new'; this.iceConnectionState = 'new'; this.signalingState = 'stable'; this.transceivers = []; }
  setLocalDescription() { return Promise.resolve(); }
  setRemoteDescription() { return Promise.resolve(); }
  createOffer() { return Promise.resolve({}); }
  addTrack(track) { const t = { direction: 'sendrecv', currentDirection: null, sender: new RTCRtpSender(track), receiver: { track: { kind: track.kind } } }; this.transceivers.push(t); return t.sender; }
  addTransceiver(kind, init) { const k = typeof kind === 'string' ? kind : kind.kind; const t = { direction: (init && init.direction) || 'sendrecv', currentDirection: null, sender: new RTCRtpSender(typeof kind === 'string' ? null : kind), receiver: { track: { kind: k } } }; this.transceivers.push(t); return t; }
  getTransceivers() { return this.transceivers; }
  close() { this.signalingState = 'closed'; this.connectionState = 'closed'; }
  setState(state) { this.connectionState = state; this.dispatchEvent({ type: 'connectionstatechange' }); }
}
class AudioContext {
  createMediaStreamSource(stream) { return { stream }; }
  createMediaStreamDestination() { return { stream: new MediaStream([new MediaStreamTrack('audio')]) }; }
}
`;

function load() {
  const context = vm.createContext({ JSON, Promise, Symbol, Object, Array, Set, WeakSet, WeakMap, TypeError });
  vm.runInContext(fakes + '\nglobalThis.EventTarget = EventTarget; globalThis.CustomEvent = CustomEvent; globalThis.setTimeout = setTimeout; globalThis.setInterval = setInterval; globalThis.document = document; globalThis.MediaStreamTrack = MediaStreamTrack; globalThis.MediaStream = MediaStream; globalThis.MediaDevices = MediaDevices; globalThis.navigator = navigator; globalThis.RTCRtpSender = RTCRtpSender; globalThis.RTCPeerConnection = RTCPeerConnection; globalThis.AudioContext = AudioContext; globalThis.timers = timers; globalThis.intervals = intervals;', context);
  vm.runInContext(pageSource, context);
  const states = [];
  vm.runInContext('document', context).addEventListener('__transcribeThing:state', (event) => states.push(JSON.parse(event.detail)));
  const g = (name) => vm.runInContext(name, context);
  return {
    g,
    states,
    /** Runs the batched work and gives back the last state said. */
    async settle() {
      await new Promise((resolve) => setImmediate(resolve));
      const timers = g('timers');
      while (timers.length) timers.shift()();
      return states.at(-1);
    },
    async mic() {
      const stream = await g('navigator').mediaDevices.getUserMedia({ audio: true });
      return stream.getAudioTracks()[0];
    },
    pc() { return new (g('RTCPeerConnection'))(); },
  };
}

test('a call with the mic: in a call, heard, then muted and unmuted by enabled', async () => {
  const page = load();
  assert.equal(await page.settle(), undefined, 'says nothing while nothing happens');
  const mic = await page.mic();
  assert.deepEqual(await page.settle(), { inCall: false, micLive: true, muted: null });
  const pc = page.pc();
  pc.addTrack(mic);
  pc.setState('connecting');
  assert.deepEqual(await page.settle(), { inCall: false, micLive: true, muted: null });
  pc.setState('connected');
  assert.deepEqual(await page.settle(), { inCall: true, micLive: true, muted: false });
  mic.enabled = false;
  assert.equal(mic.enabled, false, 'the setter still sets');
  assert.deepEqual(await page.settle(), { inCall: true, micLive: true, muted: true });
  mic.enabled = true;
  assert.deepEqual(await page.settle(), { inCall: true, micLive: true, muted: false });
  pc.setState('disconnected');
  assert.deepEqual(await page.settle(), { inCall: true, micLive: true, muted: false }, 'a dropout is still the call');
  pc.close();
  assert.deepEqual(await page.settle(), { inCall: false, micLive: true, muted: null });
  mic.stop();
  assert.deepEqual(await page.settle(), { inCall: false, micLive: false, muted: null });
});

test('replaceTrack(null) mutes; the mic put back unmutes', async () => {
  const page = load();
  const mic = await page.mic();
  const pc = page.pc();
  const sender = pc.addTrack(mic);
  pc.setState('connected');
  assert.equal((await page.settle()).muted, false);
  await sender.replaceTrack(null);
  assert.equal((await page.settle()).muted, true);
  await sender.replaceTrack(mic);
  assert.equal((await page.settle()).muted, false);
});

test('a connection made before the mic: muted until the mic is sent', async () => {
  const page = load();
  const pc = page.pc();
  const transceiver = pc.addTransceiver('audio', { direction: 'sendrecv' });
  pc.setState('connected');
  assert.deepEqual(await page.settle(), { inCall: true, micLive: false, muted: true });
  const mic = await page.mic();
  await transceiver.sender.replaceTrack(mic);
  assert.deepEqual(await page.settle(), { inCall: true, micLive: true, muted: false });
});

test('letting go of the mic to mute (Telegram) is muted', async () => {
  const page = load();
  const mic = await page.mic();
  const pc = page.pc();
  pc.addTrack(mic);
  pc.setState('connected');
  assert.equal((await page.settle()).muted, false);
  mic.stop();
  assert.deepEqual(await page.settle(), { inCall: true, micLive: false, muted: true });
});

test('the mic through WebAudio: heard while the mic is enabled', async () => {
  const page = load();
  const mic = await page.mic();
  const context = new (page.g('AudioContext'))();
  context.createMediaStreamSource({ getAudioTracks: () => [mic] });
  const out = context.createMediaStreamDestination().stream.getAudioTracks()[0];
  const pc = page.pc();
  pc.addTrack(out);
  pc.setState('connected');
  assert.equal((await page.settle()).muted, false);
  mic.enabled = false;
  assert.equal((await page.settle()).muted, true);
  mic.enabled = true;
  out.enabled = false;
  assert.equal((await page.settle()).muted, true);
});

test('a sent track nobody saw made: unknown, unless the mic is off', async () => {
  const page = load();
  const mic = await page.mic();
  const pc = page.pc();
  pc.addTrack(new (page.g('MediaStreamTrack'))('audio'));
  pc.setState('connected');
  assert.equal((await page.settle()).muted, null);
  mic.enabled = false;
  assert.equal((await page.settle()).muted, true);
});

test('a clone of the mic is the mic', async () => {
  const page = load();
  const mic = await page.mic();
  const copy = mic.clone();
  const pc = page.pc();
  pc.addTrack(copy);
  pc.setState('connected');
  assert.equal((await page.settle()).muted, false);
  copy.enabled = false;
  assert.equal((await page.settle()).muted, true);
});

test("the page's own calls work as before", async () => {
  const page = load();
  await assert.rejects(page.g('navigator').mediaDevices.getUserMedia(), /no constraints/, 'a failure is the page\'s');
  const pc = page.pc();
  assert.ok(pc instanceof page.g('RTCPeerConnection'));
  assert.equal(page.g('RTCPeerConnection').prototype.addTrack.name, 'addTrack');
  const offer = await pc.createOffer();
  assert.equal(JSON.stringify(offer), '{}');
  pc.setState('failed');
  assert.equal(await page.settle(), undefined, 'a failed connection was never a call');
});

test('loaded twice, hooks once', async () => {
  const page = load();
  const before = page.g('RTCPeerConnection').prototype.addTrack;
  vm.runInContext(pageSource, vm.createContext({}), { filename: 'bare' }); // no window at all: does nothing
  page.g('eval')(pageSource);
  assert.equal(page.g('RTCPeerConnection').prototype.addTrack, before);
});
