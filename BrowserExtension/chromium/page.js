// transcribe-thing: what this frame's calls are doing, from inside the page.
//
// Runs in the page's own world (MAIN) at document_start, before the page's scripts, in every frame. It watches
// WebRTC the way any call service has to use it, so it needs nothing per site:
//   - the mic: audio tracks from getUserMedia (and their clones, and what WebAudio makes of them);
//   - the call: peer connections that are connected (or were, and haven't failed or closed since);
//   - the mute: whether a live, enabled mic track is what a connected peer connection sends.
// It says what it sees as a JSON string in a CustomEvent on `document` (relay.js, in the extension's world, passes it
// on), only when that changes.
//
// It must never break a page: every hook calls the browser's own function first, unchanged, with the page's
// arguments, and returns its result; whatever this file does after that is in try/catch. Prototypes, constructors and
// `instanceof` stay what they were (only methods and one setter are wrapped, on the prototypes). It must be cheap:
// work is batched (`schedule`), and with no peer connection and no mic it does nothing at all.
//
// Browser-neutral on purpose (no chrome.* here): the same file can go into a Firefox build.
(() => {
  'use strict';
  const g = globalThis;
  const STATE_EVENT = '__transcribeThing:state';
  const ASK_EVENT = '__transcribeThing:ask';
  const FLAG = Symbol.for('transcribeThing.pageHooks');

  try {
    if (g[FLAG] || typeof g.setTimeout !== 'function' || !g.document || !g.EventTarget) return;
    Object.defineProperty(g, FLAG, { value: true });
  } catch (e) {
    return;
  }

  // The browser's own functions, taken before the page can replace them.
  const setTimeout = g.setTimeout.bind(g);
  const setInterval = g.setInterval.bind(g);
  const CustomEvent = g.CustomEvent;
  const dispatch = g.EventTarget && g.EventTarget.prototype.dispatchEvent;
  const listen = g.EventTarget && g.EventTarget.prototype.addEventListener;
  const stringify = JSON.stringify;
  const doc = g.document;

  /** Local mic tracks: getUserMedia's audio tracks and their clones. */
  const mics = new WeakSet();
  /** The same, while not ended, to go through. */
  const liveMics = new Set();
  /** A track WebAudio made (a MediaStreamAudioDestinationNode's) -> the AudioContext it came out of. */
  const derived = new WeakMap();
  /** An AudioContext -> the mic tracks fed into it. */
  const contextMics = new WeakMap();
  /** Every peer connection the page has used, until it closes. */
  const connections = new Set();
  const seen = new WeakSet();
  /** Peer connections that have been connected: a dropout (disconnected, an ICE restart) is still the call. */
  const wasConnected = new WeakSet();

  function quietly(fn) {
    try {
      fn();
    } catch (e) {
      // Never the page's problem.
    }
  }

  /**
   * Wraps `proto[name]`: the original runs first with the page's `this` and arguments and its result (or exception)
   * goes back to the page untouched; then `after(this, args, result)` runs, its errors swallowed.
   */
  function wrap(proto, name, after) {
    if (!proto) return;
    const desc = Object.getOwnPropertyDescriptor(proto, name);
    if (!desc || typeof desc.value !== 'function' || !desc.configurable) return;
    const original = desc.value;
    const wrapped = {
      [name](...args) {
        const result = original.apply(this, args);
        try {
          after(this, args, result);
        } catch (e) {
          // ignore
        }
        return result;
      },
    }[name];
    quietly(() => Object.defineProperty(wrapped, 'length', { value: original.length }));
    quietly(() => Object.defineProperty(proto, name, { ...desc, value: wrapped }));
  }

  // MARK: The mic

  function addMic(track) {
    if (!track || track.kind !== 'audio' || mics.has(track)) return;
    mics.add(track);
    if (track.readyState !== 'ended') liveMics.add(track);
    quietly(() =>
      listen.call(track, 'ended', () => {
        liveMics.delete(track);
        schedule();
      }),
    );
    schedule();
  }

  function addMicStream(stream) {
    if (!stream || typeof stream.getAudioTracks !== 'function') return;
    for (const track of stream.getAudioTracks()) addMic(track);
  }

  wrap(g.MediaDevices && g.MediaDevices.prototype, 'getUserMedia', (_, __, promise) => {
    // Our handler goes on first, so the tracks are known before the page's own code sees the stream.
    if (promise && typeof promise.then === 'function') promise.then((stream) => quietly(() => addMicStream(stream)), () => {});
  });

  const TrackProto = g.MediaStreamTrack && g.MediaStreamTrack.prototype;
  wrap(TrackProto, 'clone', (track, _, copy) => {
    if (mics.has(track)) addMic(copy);
    else if (derived.has(track)) derived.set(copy, derived.get(track));
  });
  wrap(TrackProto, 'stop', (track) => {
    if (liveMics.delete(track) || track.kind === 'audio') schedule();
  });
  quietly(() => {
    const desc = TrackProto && Object.getOwnPropertyDescriptor(TrackProto, 'enabled');
    if (!desc || typeof desc.set !== 'function' || !desc.configurable) return;
    const set = desc.set;
    Object.defineProperty(TrackProto, 'enabled', {
      get: desc.get,
      set: function (value) {
        set.call(this, value);
        quietly(() => {
          if (this.kind === 'audio') schedule();
        });
      },
      enumerable: desc.enumerable,
      configurable: true,
    });
  });

  // What WebAudio makes of the mic (noise suppression, gain) before it's sent.
  for (const Context of [g.AudioContext, g.webkitAudioContext]) {
    const proto = Context && Context.prototype;
    wrap(proto, 'createMediaStreamSource', (context, [stream]) => {
      if (!stream || typeof stream.getAudioTracks !== 'function') return;
      for (const track of stream.getAudioTracks()) {
        if (!mics.has(track)) continue;
        let fed = contextMics.get(context);
        if (!fed) contextMics.set(context, (fed = new Set()));
        fed.add(track);
      }
      schedule();
    });
    wrap(proto, 'createMediaStreamDestination', (context, _, node) => {
      for (const track of node.stream.getAudioTracks()) derived.set(track, context);
    });
  }

  // MARK: The call

  function watch(pc) {
    if (seen.has(pc)) return schedule();
    seen.add(pc);
    connections.add(pc);
    const changed = () => {
      if (pc.signalingState === 'closed' || pc.connectionState === 'closed') connections.delete(pc);
      schedule();
    };
    for (const name of ['connectionstatechange', 'iceconnectionstatechange', 'signalingstatechange']) {
      quietly(() => listen.call(pc, name, changed));
    }
    schedule();
  }

  // Every connection that carries a call goes through these; the constructor itself is left alone.
  const PCProto = g.RTCPeerConnection && g.RTCPeerConnection.prototype;
  for (const name of ['setLocalDescription', 'setRemoteDescription', 'addTrack', 'addTransceiver', 'createOffer',
    'createAnswer', 'createDataChannel', 'addIceCandidate']) {
    wrap(PCProto, name, (pc) => watch(pc));
  }
  wrap(PCProto, 'close', (pc) => {
    connections.delete(pc);
    schedule();
  });
  wrap(PCProto, 'removeTrack', () => schedule());
  wrap(g.RTCRtpSender && g.RTCRtpSender.prototype, 'replaceTrack', (_, __, promise) => {
    schedule();
    if (promise && typeof promise.then === 'function') promise.then(schedule, () => {});
  });

  /** Connected now, or connected before and not failed or closed since. */
  function inCall(pc) {
    if (pc.signalingState === 'closed') return false;
    const state = pc.connectionState;
    const ice = pc.iceConnectionState;
    if (state === 'failed' || state === 'closed' || ice === 'failed' || ice === 'closed') return false;
    if (state === 'connected' || ice === 'connected' || ice === 'completed') {
      wasConnected.add(pc);
      return true;
    }
    return wasConnected.has(pc);
  }

  /** The audio tracks a connected peer connection sends, or would: null where a sender has no track. */
  function sentAudio(pc) {
    const tracks = [];
    let transceivers = [];
    try {
      transceivers = pc.getTransceivers();
    } catch (e) {
      return tracks;
    }
    for (const transceiver of transceivers) {
      const direction = transceiver.currentDirection || transceiver.direction;
      if (direction !== 'sendrecv' && direction !== 'sendonly') continue;
      const sender = transceiver.sender;
      const track = sender ? sender.track : null;
      const kind = track ? track.kind : transceiver.receiver && transceiver.receiver.track && transceiver.receiver.track.kind;
      if (kind === 'audio') tracks.push(track || null);
    }
    return tracks;
  }

  /** 'on': it's the mic, live and enabled; 'off': silent for sure; 'unknown': a track nobody saw being made. */
  function sentState(track) {
    if (!track || track.readyState === 'ended' || !track.enabled) return 'off';
    if (mics.has(track)) return liveMics.has(track) ? 'on' : 'off';
    const context = derived.get(track);
    const fed = context && contextMics.get(context);
    if (!fed || fed.size === 0) return 'unknown';
    const live = [...fed].filter((mic) => mic.readyState !== 'ended');
    return live.some((mic) => mic.enabled) ? 'on' : 'off';
  }

  /** true muted, false heard, null unknown; only asked while in a call. */
  function muted(sent, live) {
    const micsOff = live.every((track) => !track.enabled);
    if (sent.length === 0) return micsOff ? true : null;
    const states = sent.map(sentState);
    if (states.includes('on')) return false;
    if (!states.includes('unknown')) return true;
    // What's sent was made where this frame can't see (a worker, another frame, a generator): only a mic that is
    // there and off says anything.
    return live.length > 0 && micsOff ? true : null;
  }

  function compute() {
    for (const track of liveMics) if (track.readyState === 'ended') liveMics.delete(track);
    const live = [...liveMics];
    let call = false;
    const sent = [];
    for (const pc of connections) {
      if (!inCall(pc)) continue;
      call = true;
      sent.push(...sentAudio(pc));
    }
    return { inCall: call, micLive: live.length > 0, muted: call ? muted(sent, live) : null };
  }

  // MARK: Telling

  const EMPTY = stringify({ inCall: false, micLive: false, muted: null });
  let last = EMPTY;
  let pending = false;

  function schedule() {
    if (pending) return;
    pending = true;
    setTimeout(flush, 100);
  }

  function flush(force) {
    pending = false;
    let text;
    try {
      text = stringify(compute());
    } catch (e) {
      return;
    }
    if (text === last && !force) return;
    last = text;
    quietly(() => dispatch.call(doc, new CustomEvent(STATE_EVENT, { detail: text })));
  }

  // Changes nothing hooks see (a transceiver's direction, a connection going quiet) still show within 2 s; with
  // nothing to watch this is a size check.
  setInterval(() => {
    if (connections.size > 0 || liveMics.size > 0 || last !== EMPTY) flush(false);
  }, 2000);

  // relay.js asks when it starts and whenever the extension wants everything again.
  quietly(() => listen.call(doc, ASK_EVENT, () => flush(true)));
})();
