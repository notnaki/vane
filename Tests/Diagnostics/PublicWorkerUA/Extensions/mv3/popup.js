const startup = navigator.userAgent;
browser.runtime.sendMessage({type: "identity", nonce: globalThis.fixtureNonce}).then(worker => {
  window.fixtureResult = {startup, current: navigator.userAgent, nonce: globalThis.fixtureNonce,
    runtime: browser.runtime.id, host: location.host, worker};
  document.body.textContent = "Identity received (see host JSON output).";
}).catch(() => { document.body.textContent = "Identity message failed (host deadline remains authoritative)."; });
