const startupUA = navigator.userAgent;
const birthNonce = crypto.randomUUID();
const namespace = "@NAMESPACE@";
let queryCount = 0;
const eligible = (async () => {
  const started = performance.now();
  if (typeof self.clients?.matchAll !== 'function')
    return {status:'api-unavailable', queryCount, clients:[], started, completed:performance.now()};
  try {
    queryCount++;
    const clients = await self.clients.matchAll({includeUncontrolled:true, type:'all'});
    return {status:'observed', queryCount, started, completed:performance.now(),
      clients:clients.map(client => ({id:client.id,url:client.url,type:client.type,frameType:client.frameType}))};
  } catch (error) {
    return {status:'error', queryCount, clients:[], started, completed:performance.now(), error:String(error)};
  }
})();
function identity(request) {
  return {namespace, requestNonce:request.requestNonce, birthNonce,
    runtimeID:browser.runtime.id, origin:self.location.origin, scriptURL:self.location.href,
    manifestVersion:browser.runtime.getManifest().manifest_version,
    version:browser.runtime.getManifest().version, startupUA, currentUA:navigator.userAgent};
}
browser.runtime.onMessage.addListener(async request => {
  if (request.namespace !== namespace) throw new Error('Wrong capability namespace');
  if (request.kind === 'identity') return identity(request);
  if (request.kind === 'eligible-result') return {...identity(request), snapshot:await eligible};
  throw new Error('Unknown capability request');
});
eligible.then(() => browser.action.setBadgeText({text:birthNonce}));
