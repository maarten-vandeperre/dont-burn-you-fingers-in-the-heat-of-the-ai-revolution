async function call(method, url, body) {
  const res = await fetch(url, {
    method,
    headers: body ? { 'content-type': 'application/json' } : {},
    body: body ? JSON.stringify(body) : undefined,
  })
  const json = await res.json().catch(() => ({}))
  if (!res.ok) throw new Error(json.error || `${res.status}`)
  return json
}
export const api = {
  config: () => call('GET', '/api/config'),
  chat: (b) => call('POST', '/api/chat', b),
  burst: (b) => call('POST', '/api/burst', b),
  knobs: () => call('GET', '/api/knobs'),
  throttle: (b) => call('PUT', '/api/throttle', b),
  tokens: (b) => call('PUT', '/api/tokens', b),
  reset: () => call('POST', '/api/reset'),
  yaml: (ref) => call('GET', `/api/yaml?ref=${encodeURIComponent(ref)}`),
  metrics: () => call('GET', '/api/metrics'),
  ledger: () => call('GET', '/api/ledger'),
  clearLedger: () => call('DELETE', '/api/ledger'),
}
