// transcribe-thing: passes this frame's call state from page.js (the page's world) to the service worker.
//
// Runs in the extension's isolated world in every frame. Says nothing while its frame has neither a call nor a mic,
// so ordinary pages never wake the service worker. While it has one, it says it again every 10 s, so a service worker
// that restarted (or missed a message) catches up, and frames that went away without a word are forgotten there.
(() => {
  'use strict';
  const STATE_EVENT = '__transcribeThing:state';
  const ASK_EVENT = '__transcribeThing:ask';
  const EMPTY = { inCall: false, micLive: false, muted: null };
  const api = globalThis.chrome || globalThis.browser;
  let last = null;

  function active(state) {
    return !!state && (state.inCall || state.micLive);
  }

  function send(state) {
    try {
      const sent = api.runtime.sendMessage({ type: 'frame', state });
      if (sent && typeof sent.catch === 'function') sent.catch(() => {});
    } catch (e) {
      // The extension was reloaded or removed: this frame's script is an orphan now.
    }
  }

  document.addEventListener(STATE_EVENT, (event) => {
    let state;
    try {
      state = JSON.parse(event.detail);
    } catch (e) {
      return;
    }
    if (!state || typeof state.inCall !== 'boolean' || typeof state.micLive !== 'boolean') return;
    if (state.muted !== true && state.muted !== false) state.muted = null;
    const was = last;
    last = state;
    // A frame that never had anything stays silent.
    if (active(state) || active(was)) send(state);
  });

  try {
    api.runtime.onMessage.addListener((message) => {
      if (message && message.type === 'resend' && active(last)) send(last);
    });
  } catch (e) {
    // ignore
  }

  setInterval(() => {
    if (active(last)) send(last);
  }, 10000);

  // Leaving the page (or into the back-forward cache) ends its call; coming back from the cache, it says again.
  addEventListener('pagehide', () => {
    if (active(last)) send(EMPTY);
  });
  addEventListener('pageshow', (event) => {
    if (event.persisted) document.dispatchEvent(new CustomEvent(ASK_EVENT));
  });

  document.dispatchEvent(new CustomEvent(ASK_EVENT));
})();
