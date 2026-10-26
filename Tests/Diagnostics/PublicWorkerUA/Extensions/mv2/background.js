if (typeof importScripts === "function") importScripts("identity.js");
const startup = navigator.userAgent;
browser.runtime.onMessage.addListener(async (message, sender) => {
  if (message?.type !== "identity" || message.nonce !== globalThis.fixtureNonce || sender.id !== browser.runtime.id) return;
  return {startup, current: navigator.userAgent, nonce: globalThis.fixtureNonce,
    runtime: browser.runtime.id, host: location.host, scheme: location.protocol,
    version: String(browser.runtime.getManifest().manifest_version)};
});
