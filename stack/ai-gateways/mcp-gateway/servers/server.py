"""
demo-mcp: a small MCP server (Streamable HTTP, stateless, Python standard library only) for the
MCP gateway part of docs/demos/15-ai-gateways.md (Part G). One file, two personalities, picked
with MCP_SERVER:

  models   list_models        the models served by OpenShift AI (LLMInferenceService, maas-models)
           ask_model          ask one of them a question, through Praxis AI (ai-gateways/praxis-ai,
                              listener "direct"): an MCP tool that itself uses the AI gateway
  ops      get_limits         the Part F limits: RateLimitPolicy llm-api-throttle and
                              TokenRateLimitPolicy llm-api-tokens
           set_throttle       change the request throttle (patches llm-api-throttle): the
                              "dangerous" tool that only gold consumers may call

No authentication here on purpose: the server is only reachable through the MCP gateway, where
Connectivity Link authenticates the caller and decides per tool (see ../policies.yaml).
"""

import json
import os
import ssl
import sys
import time
import urllib.request
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(os.environ.get("PORT", "8080"))
MODE = os.environ.get("MCP_SERVER", "models")
PRAXIS_URL = os.environ.get("PRAXIS_URL", "http://praxis-ai.ai-gateways.svc.cluster.local:8080")
GW_NS = os.environ.get("GATEWAY_NAMESPACE", "ai-gateways")
MODELS_NS = os.environ.get("MODELS_NAMESPACE", "maas-models")
SA_DIR = "/var/run/secrets/kubernetes.io/serviceaccount"
K8S = "https://kubernetes.default.svc"
SUPPORTED_PROTOCOLS = ["2025-06-18", "2025-03-26", "2024-11-05"]


def log(msg):
    print(f"{datetime.now(timezone.utc).isoformat(timespec='seconds')} [{MODE}] {msg}", file=sys.stderr, flush=True)


# ----------------------------------------------------------------------------- HTTP helpers
def _k8s(method, path, body=None, ctype="application/json"):
    ctx = ssl.create_default_context(cafile=f"{SA_DIR}/ca.crt")
    with open(f"{SA_DIR}/token") as f:
        token = f.read().strip()
    req = urllib.request.Request(f"{K8S}{path}", method=method, data=json.dumps(body).encode() if body else None,
                                 headers={"Authorization": f"Bearer {token}", "Accept": "application/json",
                                          **({"Content-Type": ctype} if body else {})})
    with urllib.request.urlopen(req, context=ctx, timeout=20) as r:
        return json.loads(r.read() or b"{}")


def _post_json(url, body, timeout=180):
    req = urllib.request.Request(url, data=json.dumps(body).encode(), headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read())


# ----------------------------------------------------------------------------- tools: models
def tool_list_models(_args):
    items = _k8s("GET", f"/apis/serving.kserve.io/v1alpha1/namespaces/{MODELS_NS}/llminferenceservices").get("items", [])
    lines = []
    for m in items:
        ready = next((c.get("status") for c in m.get("status", {}).get("conditions", []) if c.get("type") == "Ready"), "?")
        uri = m.get("spec", {}).get("model", {}).get("uri", "")
        lines.append(f"- {m['metadata']['name']}: ready={ready}, source {uri}")
    return "Models served by OpenShift AI:\n" + ("\n".join(lines) or "(none)")


def tool_ask_model(args):
    model, prompt = args.get("model", "gemma-3-270m-it"), args.get("prompt", "")
    if not prompt:
        raise ValueError("prompt is required")
    t0 = time.time()
    r = _post_json(f"{PRAXIS_URL}/v1/chat/completions",
                   {"model": model, "max_tokens": int(args.get("max_tokens", 80)),
                    "messages": [{"role": "user", "content": prompt}]})
    u = r.get("usage", {})
    return (f"{r['choices'][0]['message']['content']}\n\n"
            f"(model {r.get('model')}, {u.get('total_tokens')} tokens, {time.time() - t0:.1f}s, via Praxis AI)")


# ----------------------------------------------------------------------------- tools: ops
def _limits():
    rlp = _k8s("GET", f"/apis/kuadrant.io/v1/namespaces/{GW_NS}/ratelimitpolicies/llm-api-throttle")
    trlp = _k8s("GET", f"/apis/kuadrant.io/v1alpha1/namespaces/{GW_NS}/tokenratelimitpolicies/llm-api-tokens")
    rate = rlp["spec"]["limits"]["per-consumer"]["rates"][0]
    lim = trlp["spec"]["limits"]
    return (f"LLM API limits (namespace {GW_NS}):\n"
            f"- throttle: {rate['limit']} requests per {rate['window']} per consumer (RateLimitPolicy llm-api-throttle)\n"
            f"- tokens free: {lim['api-free']['rates'][0]['limit']} per {lim['api-free']['rates'][0]['window']}\n"
            f"- tokens gold: {lim['api-gold']['rates'][0]['limit']} per {lim['api-gold']['rates'][0]['window']}")


def tool_get_limits(_args):
    return _limits()


def tool_set_throttle(args):
    n = int(args.get("requests_per_second", 0))
    if not 1 <= n <= 100:
        raise ValueError("requests_per_second must be between 1 and 100")
    _k8s("PATCH", f"/apis/kuadrant.io/v1/namespaces/{GW_NS}/ratelimitpolicies/llm-api-throttle",
         {"spec": {"limits": {"per-consumer": {"rates": [{"limit": n, "window": "1s"}]}}}},
         "application/merge-patch+json")
    return f"Throttle set to {n} requests per second per consumer.\n\n" + _limits()


TOOLSETS = {
    "models": [
        {"name": "list_models", "description": "List the LLMs served by OpenShift AI on this cluster and whether they are ready.",
         "inputSchema": {"type": "object", "properties": {}}, "fn": tool_list_models},
        {"name": "ask_model", "description": "Ask one of the cluster's LLMs a question (through the Praxis AI gateway).",
         "inputSchema": {"type": "object", "properties": {
             "model": {"type": "string", "description": "qwen3-0-6b or gemma-3-270m-it", "default": "gemma-3-270m-it"},
             "prompt": {"type": "string"},
             "max_tokens": {"type": "integer", "default": 80}}, "required": ["prompt"]},
         "fn": tool_ask_model},
    ],
    "ops": [
        {"name": "get_limits", "description": "Show the LLM API's request throttle and token limits per tier.",
         "inputSchema": {"type": "object", "properties": {}}, "fn": tool_get_limits},
        {"name": "set_throttle", "description": "Change the LLM API's request throttle (requests per second per consumer).",
         "inputSchema": {"type": "object", "properties": {
             "requests_per_second": {"type": "integer", "minimum": 1, "maximum": 100}}, "required": ["requests_per_second"]},
         "fn": tool_set_throttle},
    ],
}
TOOLS = TOOLSETS[MODE]
TOOLS_BY_NAME = {t["name"]: t for t in TOOLS}


# ----------------------------------------------------------------------------- MCP (JSON-RPC)
def handle_rpc(msg):
    mid, method, params = msg.get("id"), msg.get("method", ""), msg.get("params") or {}
    if mid is None:   # notification
        return None

    def result(r):
        return {"jsonrpc": "2.0", "id": mid, "result": r}

    if method == "initialize":
        asked = params.get("protocolVersion", SUPPORTED_PROTOCOLS[0])
        return result({"protocolVersion": asked if asked in SUPPORTED_PROTOCOLS else SUPPORTED_PROTOCOLS[0],
                       "capabilities": {"tools": {"listChanged": False}},
                       "serverInfo": {"name": f"demo-mcp-{MODE}", "version": "1.0.0"}})
    if method == "ping":
        return result({})
    if method == "tools/list":
        return result({"tools": [{k: v for k, v in t.items() if k != "fn"} for t in TOOLS]})
    if method == "tools/call":
        name, args = params.get("name"), params.get("arguments") or {}
        tool = TOOLS_BY_NAME.get(name)
        if not tool:
            return {"jsonrpc": "2.0", "id": mid, "error": {"code": -32602, "message": f"unknown tool {name}"}}
        try:
            text = tool["fn"](args)
            log(f"tool {name} {json.dumps(args)} ok")
            return result({"content": [{"type": "text", "text": text}], "isError": False})
        except Exception as ex:
            log(f"tool {name} failed: {ex!r}")
            return result({"content": [{"type": "text", "text": f"Tool {name} failed: {ex}"}], "isError": True})
    if method in ("resources/list", "prompts/list"):
        return result({method.split("/")[0]: []})
    return {"jsonrpc": "2.0", "id": mid, "error": {"code": -32601, "message": f"method not found: {method}"}}


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        pass

    def _send(self, code, body=None, ctype="application/json"):
        data = b"" if body is None else (body if isinstance(body, bytes) else json.dumps(body).encode())
        self.send_response(code)
        if data:
            self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        if data:
            self.wfile.write(data)

    def do_GET(self):
        if self.path in ("/healthz", "/readyz"):
            return self._send(200, b"ok", "text/plain")
        return self._send(405, {"error": "use POST /mcp"})

    def do_DELETE(self):
        return self._send(405)

    def _body(self):
        # The MCP gateway's router sends its own requests (initialize, tools/call) chunked, without
        # Content-Length; http.server doesn't decode that by itself.
        if "chunked" in self.headers.get("Transfer-Encoding", "").lower():
            data = b""
            while True:
                size = int(self.rfile.readline().split(b";")[0].strip() or b"0", 16)
                if size == 0:
                    while self.rfile.readline() not in (b"\r\n", b"\n", b""):   # trailers
                        pass
                    return data
                data += self.rfile.read(size)
                self.rfile.readline()   # CRLF after each chunk
        return self.rfile.read(int(self.headers.get("Content-Length", "0") or 0))

    def do_POST(self):
        if not self.path.split("?")[0].rstrip("/").endswith("/mcp"):
            return self._send(404, {"error": "not found"})
        try:
            body = json.loads(self._body() or b"null")
        except json.JSONDecodeError:
            return self._send(400, {"jsonrpc": "2.0", "id": None, "error": {"code": -32700, "message": "parse error"}})
        if isinstance(body, dict):
            # what the gateway passed on: the tool header set by the MCP router, who is calling
            h = self.headers
            log(f"{body.get('method')} from {h.get('User-Agent', '-')[:20]}: x-mcp-toolname={h.get('x-mcp-toolname', '-')} "
                f"x-mcp-method={h.get('x-mcp-method', '-')} x-consumer={h.get('x-consumer', '-')} "
                f"authorization={'yes' if h.get('Authorization') else 'no'}")
        if isinstance(body, list):
            replies = [r for r in (handle_rpc(m) for m in body) if r is not None]
            return self._send(200, replies) if replies else self._send(202)
        if not isinstance(body, dict):
            return self._send(400, {"jsonrpc": "2.0", "id": None, "error": {"code": -32600, "message": "invalid request"}})
        reply = handle_rpc(body)
        if body.get("method") and reply is None:
            return self._send(202)
        return self._send(200, reply)


if __name__ == "__main__":
    log(f"demo-mcp '{MODE}' listening on :{PORT} (/mcp), tools: {', '.join(TOOLS_BY_NAME)}")
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
