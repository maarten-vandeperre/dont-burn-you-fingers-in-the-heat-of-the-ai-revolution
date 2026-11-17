// AI Gateway Console backend (docs/demos/15-ai-gateways.md, Part F).
//
// - calls the Connectivity Link llm-gateway AS a consumer (alice / bob: their API key Secrets),
//   so the browser never holds a key
// - changes the demo knobs live: RateLimitPolicy llm-api-throttle, TokenRateLimitPolicy
//   llm-api-tokens, the Praxis rate_limit in ConfigMap praxis-ai-config
// - shows the live YAML of every object a scenario talks about
// - reads Prometheus (Limitador, Praxis, gateway Envoy) for the metrics page
//
// In the cluster it uses its ServiceAccount (openshift/console.yaml). Locally:
//   K8S_API=$(oc whoami --show-server) K8S_TOKEN=$(oc whoami -t) npm run server
import express from 'express'
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import yaml from 'js-yaml'
import { Agent, fetch } from 'undici'

const NS = process.env.NAMESPACE || 'ai-gateways'
const PORT = Number(process.env.PORT || 8080)
const CONSUMERS = (process.env.CONSUMERS || 'alice,bob').split(',').map((s) => s.trim()).filter(Boolean)
const SA_DIR = '/var/run/secrets/kubernetes.io/serviceaccount'
const IN_CLUSTER = fs.existsSync(`${SA_DIR}/token`)
const K8S_API = process.env.K8S_API || 'https://kubernetes.default.svc'
const DEFAULTS = { clLimit: 5, praxisRate: 5, praxisBurst: 5, free: 500, gold: 20000 }

// Demo cluster: routes and the API server use the cluster's own CA. Verify nothing, like the
// demo scripts (curl -k); the console never sends anything but demo keys and prompts.
const insecure = new Agent({ connect: { rejectUnauthorized: false }, headersTimeout: 200_000, bodyTimeout: 200_000 })
const token = () => (IN_CLUSTER ? fs.readFileSync(`${SA_DIR}/token`, 'utf8').trim() : process.env.K8S_TOKEN)

// ------------------------------------------------------------------------------------ k8s
async function k8s(method, p, body, contentType = 'application/json') {
  const res = await fetch(`${K8S_API}${p}`, {
    method,
    dispatcher: insecure,
    headers: { Authorization: `Bearer ${token()}`, Accept: 'application/json', ...(body ? { 'Content-Type': contentType } : {}) },
    body: body ? (typeof body === 'string' ? body : JSON.stringify(body)) : undefined,
  })
  const text = await res.text()
  if (!res.ok) throw Object.assign(new Error(`${method} ${p}: ${res.status} ${text.slice(0, 300)}`), { status: res.status })
  return text ? JSON.parse(text) : {}
}
const KINDS = {
  httproute: `/apis/gateway.networking.k8s.io/v1/namespaces/${NS}/httproutes`,
  gateway: `/apis/gateway.networking.k8s.io/v1/namespaces/${NS}/gateways`,
  authpolicy: `/apis/kuadrant.io/v1/namespaces/${NS}/authpolicies`,
  ratelimitpolicy: `/apis/kuadrant.io/v1/namespaces/${NS}/ratelimitpolicies`,
  tokenratelimitpolicy: `/apis/kuadrant.io/v1alpha1/namespaces/${NS}/tokenratelimitpolicies`,
  telemetrypolicy: `/apis/extensions.kuadrant.io/v1alpha1/namespaces/${NS}/telemetrypolicies`,
  servicemonitor: `/apis/monitoring.coreos.com/v1/namespaces/${NS}/servicemonitors`,
  configmap: `/api/v1/namespaces/${NS}/configmaps`,
  secret: `/api/v1/namespaces/${NS}/secrets`,
  route: `/apis/route.openshift.io/v1/namespaces/${NS}/routes`,
  pod: `/api/v1/namespaces/${NS}/pods`,
}
const get = (kind, name) => k8s('GET', `${KINDS[kind]}/${name}`)
const mergePatch = (kind, name, patch) => k8s('PATCH', `${KINDS[kind]}/${name}`, patch, 'application/merge-patch+json')
const jsonPatch = (kind, name, ops) => k8s('PATCH', `${KINDS[kind]}/${name}`, ops, 'application/json-patch+json')

// ------------------------------------------------------------------------------------ endpoints + keys
let endpoints = null
async function getEndpoints() {
  if (endpoints) return endpoints
  const host = async (name) => (await get('route', name)).spec.host
  endpoints = {
    gateway: process.env.GATEWAY_URL || `https://${await host('llm-gateway')}`,
    praxisLimited: process.env.PRAXIS_LIMITED_URL || `https://${await host('praxis-ai-limited')}`,
  }
  return endpoints
}
const keyCache = new Map()
async function consumer(name) {
  if (!CONSUMERS.includes(name)) throw Object.assign(new Error(`unknown consumer ${name}`), { status: 400 })
  if (!keyCache.has(name) || Date.now() - keyCache.get(name).at > 30_000) {
    const s = await get('secret', `llm-key-${name}`)
    keyCache.set(name, {
      at: Date.now(),
      key: Buffer.from(s.data.api_key, 'base64').toString(),
      tier: s.metadata.annotations?.['llm-gateway/tier'] || '?',
    })
  }
  return keyCache.get(name)
}

// ------------------------------------------------------------------------------------ ledger
const ledger = []
const record = (e) => { ledger.unshift({ ts: Date.now(), ...e }); ledger.length = Math.min(ledger.length, 300) }

// ------------------------------------------------------------------------------------ calls
const SHOW_HEADERS = ['x-api-version', 'deprecation', 'sunset', 'link', 'x-ratelimit-limit', 'x-ratelimit-remaining', 'retry-after', 'via', 'content-type', 'server']

async function chat({ consumer: who, api = 'v2', model, prompt, maxTokens = 60, classification, spoofTier }) {
  const { gateway } = await getEndpoints()
  const c = await consumer(who)
  const urlPath = api === 'v2' ? '/v2/chat/completions' : '/v1/chat/completions'
  const headers = { 'content-type': 'application/json', Authorization: `APIKEY ${c.key}` }
  if (api === 'v1-header') headers['x-api-version'] = '2'
  if (classification) headers['x-data-classification'] = classification
  if (spoofTier) headers['x-consumer-tier'] = spoofTier   // the AuthPolicy overwrites it
  const body = { model, max_tokens: Number(maxTokens) || 60, messages: [{ role: 'user', content: prompt }] }
  const t0 = performance.now()
  let status = 0, text = '', resHeaders = {}
  try {
    const res = await fetch(`${gateway}${urlPath}`, { method: 'POST', headers, body: JSON.stringify(body), dispatcher: insecure })
    status = res.status
    text = await res.text()
    for (const h of SHOW_HEADERS) if (res.headers.get(h)) resHeaders[h] = res.headers.get(h)
  } catch (e) { text = String(e.cause?.message || e.message) }
  const ms = Math.round(performance.now() - t0)
  let json = null
  try { json = JSON.parse(text) } catch { /* plain text, e.g. "Forbidden" from the guardrails */ }
  const usage = json?.usage || null
  const result = {
    status, ms, api, consumer: who, tier: c.tier,
    modelAsked: model,
    modelServed: json?.model || null,
    usage,
    answer: json?.choices?.[0]?.message?.content ?? null,
    error: json?.error?.message || json?.error || (status >= 400 ? text.slice(0, 300) : null),
    request: {
      method: 'POST', url: `${gateway}${urlPath}`,
      headers: { ...headers, Authorization: `APIKEY ${c.key.slice(0, 12)}…` },
      body,
    },
    responseHeaders: resHeaders,
  }
  record({
    consumer: who, tier: c.tier, api, model: model, served: result.modelServed, status, ms,
    tokens: usage?.total_tokens ?? null, prompt: String(prompt).slice(0, 80),
    note: [classification && `x-data-classification: ${classification}`, api === 'v1-header' && 'x-api-version: 2', spoofTier && `x-consumer-tier: ${spoofTier} (sent by client)`].filter(Boolean).join(', '),
  })
  return result
}

async function burst({ consumer: who, target = 'cl', count = 10 }) {
  const n = Math.max(1, Math.min(Number(count) || 10, 40))
  const { gateway, praxisLimited } = await getEndpoints()
  const c = target === 'cl' ? await consumer(who) : null
  const url = target === 'cl' ? `${gateway}/v2/models` : `${praxisLimited}/v1/models`
  const headers = c ? { Authorization: `APIKEY ${c.key}` } : {}
  const t0 = performance.now()
  const results = await Promise.all(Array.from({ length: n }, async (_, i) => {
    const s = performance.now()
    try {
      const res = await fetch(url, { headers, dispatcher: insecure })
      await res.arrayBuffer()
      return { i, status: res.status, ms: Math.round(performance.now() - s), at: Math.round(s - t0) }
    } catch (e) { return { i, status: 0, ms: Math.round(performance.now() - s), at: Math.round(s - t0), error: e.message } }
  }))
  record({ consumer: target === 'cl' ? who : '(anyone)', tier: c?.tier || '-', api: target === 'cl' ? 'v2' : 'praxis-limited',
    model: 'GET /models ×' + n, served: null, status: results.filter((r) => r.status === 429).length ? 429 : 200,
    ms: Math.round(performance.now() - t0), tokens: null, prompt: '',
    note: `${results.filter((r) => r.status === 200).length}×200 ${results.filter((r) => r.status === 429).length}×429` })
  return { url, results }
}

// ------------------------------------------------------------------------------------ knobs
const THROTTLE_RE = /(- name: throttle\s*\n\s*filters:\s*\n\s*- filter: rate_limit\s*\n\s*mode: \w+\s*\n\s*rate: )(\d+)([^\n]*\n\s*burst: )(\d+)/

async function knobs() {
  const [rlp, trlp, cm] = await Promise.all([
    get('ratelimitpolicy', 'llm-api-throttle'), get('tokenratelimitpolicy', 'llm-api-tokens'), get('configmap', 'praxis-ai-config'),
  ])
  const m = cm.data['praxis-ai.yaml'].match(THROTTLE_RE)
  const rate = rlp.spec.limits['per-consumer'].rates[0]
  return {
    cl: { limit: rate.limit, window: rate.window },
    praxis: m ? { rate: Number(m[2]), burst: Number(m[4]) } : null,
    tokens: { free: trlp.spec.limits['api-free']?.rates[0]?.limit, gold: trlp.spec.limits['api-gold']?.rates[0]?.limit, window: trlp.spec.limits['api-free']?.rates[0]?.window },
  }
}

// ConfigMap edits reach a mounted volume when the kubelet next syncs the pod (up to ~1 min).
// Touching a pod annotation makes the kubelet sync it right away; Praxis then hot-reloads.
async function nudgePraxis() {
  const pods = await k8s('GET', `${KINDS.pod}?labelSelector=app%3Dpraxis-ai`)
  await Promise.all(pods.items.map((p) => mergePatch('pod', p.metadata.name, { metadata: { annotations: { 'ai-gateway-console/config-touched': String(Date.now()) } } })))
}

async function setThrottle({ target, limit, burst: b }) {
  const n = Math.max(1, Math.min(Number(limit) || 1, 1000))
  if (target === 'cl') {
    await mergePatch('ratelimitpolicy', 'llm-api-throttle', { spec: { limits: { 'per-consumer': { rates: [{ limit: n, window: '1s' }] } } } })
  } else {
    const cm = await get('configmap', 'praxis-ai-config')
    const src = cm.data['praxis-ai.yaml']
    if (!THROTTLE_RE.test(src)) throw new Error('throttle chain not found in praxis-ai.yaml')
    const nb = Math.max(1, Math.min(Number(b) || n, 1000))
    cm.data['praxis-ai.yaml'] = src.replace(THROTTLE_RE, (_, a, _r, c) => `${a}${n}${c}${nb}`)
    await mergePatch('configmap', 'praxis-ai-config', { data: cm.data })
    await nudgePraxis().catch(() => {})
  }
  return knobs()
}

async function setTokens({ tier, limit }) {
  if (!['free', 'gold'].includes(tier)) throw Object.assign(new Error('tier must be free or gold'), { status: 400 })
  const n = Math.max(1, Math.min(Number(limit) || 1, 10_000_000))
  await jsonPatch('tokenratelimitpolicy', 'llm-api-tokens', [{ op: 'replace', path: `/spec/limits/api-${tier}/rates/0/limit`, value: n }])
  return knobs()
}

async function reset() {
  await setThrottle({ target: 'cl', limit: DEFAULTS.clLimit })
  await setThrottle({ target: 'praxis', limit: DEFAULTS.praxisRate, burst: DEFAULTS.praxisBurst })
  await setTokens({ tier: 'free', limit: DEFAULTS.free })
  return setTokens({ tier: 'gold', limit: DEFAULTS.gold })
}

// ------------------------------------------------------------------------------------ live YAML
const LIVE = {
  'route-v1': ['httproute', 'llm-api-v1'], 'route-v2': ['httproute', 'llm-api-v2'], 'route-models': ['httproute', 'llm-models'],
  'gateway': ['gateway', 'llm-gateway'],
  'auth': ['authpolicy', 'llm-api-auth'], 'rlp': ['ratelimitpolicy', 'llm-api-throttle'],
  'trlp': ['tokenratelimitpolicy', 'llm-api-tokens'], 'telemetry': ['telemetrypolicy', 'llm-gateway-telemetry'],
  'servicemonitor': ['servicemonitor', 'praxis-ai'],
}
function tidy(obj) {
  const out = { apiVersion: obj.apiVersion, kind: obj.kind, metadata: { name: obj.metadata.name, namespace: obj.metadata.namespace } }
  out.spec = obj.spec
  if (obj.status?.conditions) out.status = { conditions: obj.status.conditions.map(({ type, status, reason, message }) => ({ type, status, reason, message })) }
  if (obj.status?.parents) out.status = { parents: obj.status.parents.map((p) => ({ parentRef: p.parentRef?.name, conditions: p.conditions.map(({ type, status, reason }) => ({ type, status, reason })) })) }
  return out
}
async function liveYaml(ref) {
  if (ref.startsWith('praxis:')) {
    const want = ref.slice(7).split(',').filter(Boolean)
    const cm = await get('configmap', 'praxis-ai-config')
    const cfg = yaml.load(cm.data['praxis-ai.yaml'])
    const sel = {}
    const listeners = (cfg.listeners || []).filter((l) => want.includes(`listener/${l.name}`))
    const chains = (cfg.filter_chains || []).filter((c) => want.includes(c.name))
    if (want.includes('insecure_options')) sel.insecure_options = cfg.insecure_options
    if (listeners.length) sel.listeners = listeners
    if (chains.length) sel.filter_chains = chains
    return `# live: ConfigMap ${NS}/praxis-ai-config, key praxis-ai.yaml (selected parts, comments stripped)\n` + yaml.dump(sel, { lineWidth: 140, noRefs: true })
  }
  const target = LIVE[ref]
  if (!target) throw Object.assign(new Error(`unknown ref ${ref}`), { status: 400 })
  const obj = await get(...target)
  return `# live: oc get ${target[0]} ${target[1]} -n ${NS} -o yaml (spec + status)\n` + yaml.dump(tidy(obj), { lineWidth: 140, noRefs: true })
}

// ------------------------------------------------------------------------------------ metrics
const PROM = process.env.PROMETHEUS_URL || 'https://thanos-querier.openshift-monitoring.svc:9091'
async function prom(query) {
  const res = await fetch(`${PROM}/api/v1/query?query=${encodeURIComponent(query)}`, { dispatcher: insecure, headers: { Authorization: `Bearer ${token()}` } })
  if (!res.ok) throw new Error(`prometheus ${res.status}: ${(await res.text()).slice(0, 200)}`)
  const j = await res.json()
  return j.data.result.map((r) => ({ labels: r.metric, value: Number(r.value[1]) }))
}
const LIM = `limitador_namespace=~"${NS}/.*"`
const QUERIES = {
  consumerCalls: `sum by (user, tier, limitador_namespace) (authorized_calls{${LIM}, user!=""})`,
  consumerLimited: `sum by (user, tier, limitador_namespace) (limited_calls{${LIM}, user!=""})`,
  consumerHits: `sum by (user, tier, limitador_namespace) (authorized_hits{${LIM}, user!=""})`,
  modelPromptTokens: `sum by (model) (praxis_ai_prompt_tokens_total{namespace="${NS}"})`,
  modelOutputTokens: `sum by (model) (praxis_ai_output_tokens_total{namespace="${NS}"})`,
  clusterRequests: `sum by (cluster, status_class) (praxis_http_requests_total{namespace="${NS}"})`,
  clusterLatency: `sum by (cluster) (praxis_http_request_duration_seconds_sum{namespace="${NS}"}) / sum by (cluster) (praxis_http_request_duration_seconds_count{namespace="${NS}"})`,
  gatewayP95: `histogram_quantile(0.95, sum by (le, destination_service_name) (rate(istio_request_duration_milliseconds_bucket{namespace="${NS}", source_workload="llm-gateway-openshift-default"}[10m])))`,
  gatewayCodes: `sum by (response_code) (increase(istio_requests_total{namespace="${NS}", source_workload="llm-gateway-openshift-default"}[30m]))`,
}
async function metrics() {
  const out = { queries: QUERIES, results: {}, errors: {} }
  await Promise.all(Object.entries(QUERIES).map(async ([k, q]) => {
    try { out.results[k] = await prom(q) } catch (e) { out.errors[k] = e.message; out.results[k] = [] }
  }))
  return out
}

async function openaiKeyState() {
  try {
    const s = await get('secret', 'praxis-openai-key')
    const v = Buffer.from(s.data?.OPENAI_API_KEY || '', 'base64').toString()
    return v && v !== 'not-set' && v.length > 12 ? 'set' : 'not-set'
  } catch { return 'missing' }
}

// ------------------------------------------------------------------------------------ http
const app = express()
app.use(express.json({ limit: '64kb' }))
const h = (fn) => async (req, res) => {
  try { res.json(await fn(req)) } catch (e) { res.status(e.status && e.status < 600 ? e.status : 500).json({ error: e.message }) }
}
app.get('/healthz', (_q, res) => res.send('ok'))
app.get('/api/config', h(async () => {
  const [ep, ks, openai, cons] = await Promise.all([
    getEndpoints(), knobs(), openaiKeyState(),
    Promise.all(CONSUMERS.map(async (n) => { try { return { name: n, tier: (await consumer(n)).tier } } catch { return { name: n, tier: 'missing' } } })),
  ])
  return { namespace: NS, ...ep, knobs: ks, openai, consumers: cons, defaults: DEFAULTS }
}))
app.post('/api/chat', h((req) => chat(req.body)))
app.post('/api/burst', h((req) => burst(req.body)))
app.get('/api/knobs', h(() => knobs()))
app.put('/api/throttle', h((req) => setThrottle(req.body)))
app.put('/api/tokens', h((req) => setTokens(req.body)))
app.post('/api/reset', h(() => reset()))
app.get('/api/yaml', h(async (req) => ({ yaml: await liveYaml(String(req.query.ref || '')) })))
app.get('/api/metrics', h(() => metrics()))
app.get('/api/ledger', h(() => ledger))
app.delete('/api/ledger', h(() => { ledger.length = 0; return [] }))

const dist = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', 'dist')
app.use(express.static(dist))
app.get('*', (_q, res) => res.sendFile(path.join(dist, 'index.html')))

app.listen(PORT, () => console.log(`ai-gateway-console on :${PORT} (namespace ${NS}, ${IN_CLUSTER ? 'in-cluster' : K8S_API})`))
