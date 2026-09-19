#!/usr/bin/env python3
"""Tiny OpenAI-compat HTTP shim that translates chat-completions calls into
`agy --print` subprocess invocations. Lets Hermes (or any OpenAI-compat
client) treat the local `agy` CLI as a chat-completions provider.

Why this exists
---------------
`agy` (Google Antigravity CLI, v1.0.12) is a headless coding/story agent.
It has no HTTP API and no Python SDK. To wire it as a fallback for Hermes
when `minimax` is unavailable, we expose a minimal OpenAI-shape HTTP endpoint
on 127.0.0.1:8766 that translates each chat-completions request into one
`agy --print` subprocess call.

Wire shape (config.yaml)
------------------------
    providers:
      agy-shim:
        base_url: http://127.0.0.1:8766/v1
        api_key: not-needed
        api_mode: chat_completions
        model: gemini-3.5-flash-medium
    fallback_providers: [agy-shim]

Pitfalls (verified 2026-06-26)
------------------------------
- `agy --model <unknown>` silently falls back to default model — no error.
  Always read the first line of `agy --print` output (it says "I am currently
  running as **<model>**"). We log it.
- agy prompt latency is 17-60s (CLI boot + warmup). Default timeout 120s.
- agy is CLOUD ONLY — no local model support.
- Workspace trust prompt blocks first-run on new dirs. Set
  GEMINI_CLI_TRUST_WORKSPACE=true in this process env to bypass.
"""

from __future__ import annotations

import json
import logging
import os
import subprocess
import sys
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any

LOG_PATH = os.path.expanduser("~/.smartclaw/logs/agy-shim.log")
os.makedirs(os.path.dirname(LOG_PATH), exist_ok=True)
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
    handlers=[
        logging.FileHandler(LOG_PATH),
        logging.StreamHandler(sys.stderr),
    ],
)
log = logging.getLogger("agy-shim")

HOST = os.environ.get("AGY_SHIM_HOST", "127.0.0.1")
PORT = int(os.environ.get("AGY_SHIM_PORT", "8766"))  # 8765 is mcp_agent_mail

# agy defaults — overridable per-request via the OpenAI `model` field.
AGY_BINARY = os.environ.get("AGY_BINARY") or (
    "${HOME}/.local/bin/agy" if os.path.exists("${HOME}/.local/bin/agy") else "agy"
)
DEFAULT_AGY_MODEL = os.environ.get("AGY_DEFAULT_MODEL", "Gemini 3.5 Flash (Medium)")
AGY_TIMEOUT_SECONDS = int(os.environ.get("AGY_SHIM_TIMEOUT", "120"))
AGY_ADD_DIR = os.environ.get("AGY_SHIM_ADD_DIR") or os.getcwd()

# Map common short names to agy's exact catalog strings (which include the
# "(Medium)" / "(High)" / "(Low)" suffix the catalog requires).
MODEL_ALIASES: dict[str, str] = {
    "gemini-3.5-flash-medium": "Gemini 3.5 Flash (Medium)",
    "gemini-3.5-flash-high": "Gemini 3.5 Flash (High)",
    "gemini-3.5-flash-low": "Gemini 3.5 Flash (Low)",
    "gemini-3.1-pro-low": "Gemini 3.1 Pro (Low)",
    "gemini-3.1-pro-high": "Gemini 3.1 Pro (High)",
    "claude-sonnet-4.6-thinking": "Claude Sonnet 4.6 (Thinking)",
    "claude-opus-4.6-thinking": "Claude Opus 4.6 (Thinking)",
    "gpt-oss-120b-medium": "GPT-OSS 120B (Medium)",
}


def _resolve_agy_model(requested: str | None) -> str:
    """Map an OpenAI-shape model name to agy's exact catalog name."""
    if not requested:
        return DEFAULT_AGY_MODEL
    # If it already looks like the exact catalog form, pass through.
    if "(" in requested and requested.endswith(")"):
        return requested
    return MODEL_ALIASES.get(requested.strip().lower(), requested)


def _flatten_messages(messages: list[dict[str, Any]]) -> str:
    """Convert OpenAI messages[] into a single prompt string.

    We keep role tags so the model sees conversational structure, but we
    don't try to be clever about tool_calls / tool role — agy doesn't have
    a native tool-call protocol. Tool-using prompts fall through as text.
    """
    parts: list[str] = []
    for msg in messages:
        role = msg.get("role", "user")
        content = msg.get("content", "")
        if isinstance(content, list):
            # OpenAI vision-style parts list — flatten text parts only.
            content = "\n".join(
                p.get("text", "") for p in content if isinstance(p, dict) and p.get("type") == "text"
            )
        if not isinstance(content, str):
            content = str(content)
        if role == "system":
            parts.append(f"[SYSTEM]\n{content}")
        elif role == "assistant":
            parts.append(f"[ASSISTANT]\n{content}")
        elif role == "user":
            parts.append(f"[USER]\n{content}")
        else:
            parts.append(f"[{role.upper()}]\n{content}")
    return "\n\n".join(parts)


def _call_agy(prompt: str, model: str, add_dir: str) -> tuple[str, str, int]:
    """Run agy --print and return (text, model_actual, exit_code).

    model_actual is parsed from the first line of agy's output
    ("I am currently running as **<model>**") so we can detect silent
    model-routing failures.
    """
    cmd = [
        AGY_BINARY,
        "--model", model,
        "--add-dir", add_dir,
        "--dangerously-skip-permissions",
        "--print-timeout", str(AGY_TIMEOUT_SECONDS),
        "--print",
        prompt,
    ]
    log.info("agy call model=%s prompt_len=%d", model, len(prompt))
    try:
        proc = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=AGY_TIMEOUT_SECONDS + 30,  # give agy some grace over its internal timeout
            check=False,
        )
    except subprocess.TimeoutExpired:
        log.warning("agy call timed out after %ds", AGY_TIMEOUT_SECONDS + 30)
        return ("[agy-shim] agy subprocess timed out", model, 124)
    except FileNotFoundError as exc:
        log.error("agy binary not found: %s", exc)
        return (f"[agy-shim] agy binary not found at {AGY_BINARY}", model, 127)
    if proc.returncode != 0:
        err = (proc.stderr or proc.stdout or "").strip()[:500]
        log.warning("agy exit %d: %s", proc.returncode, err)
        return (f"[agy-shim] agy failed (exit {proc.returncode}): {err}", model, proc.returncode)
    text = (proc.stdout or "").strip()
    # Parse the first line for the actual model that ran. Format:
    # "I am currently running as **<model>**"
    actual = model
    if text.startswith("I am currently running as"):
        first_line = text.splitlines()[0]
        if "**" in first_line:
            try:
                actual = first_line.split("**")[1].strip()
            except IndexError:
                pass
    return (text, actual, 0)


# Cheap in-memory request counter for ops visibility.
_LOCK = threading.Lock()
_STATS: dict[str, int] = {"requests": 0, "errors": 0, "fallbacks_observed": 0}
_CONCURRENCY_SEMAPHORE = threading.Semaphore(4)


class ShimHandler(BaseHTTPRequestHandler):
    server_version = "agy-openai-shim/0.1"

    def log_message(self, fmt: str, *args: Any) -> None:  # noqa: A003
        # Quiet the default stderr access log; we have file logging.
        log.debug("%s - %s", self.address_string(), fmt % args)

    def do_GET(self) -> None:  # noqa: N802
        if self.path == "/health":
            with _LOCK:
                stats_copy = dict(_STATS)
            body = json.dumps({
                "status": "ok",
                "agy_binary": AGY_BINARY,
                "default_model": DEFAULT_AGY_MODEL,
                "stats": stats_copy,
            }).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if self.path.startswith("/v1/models"):
            body = json.dumps({
                "object": "list",
                "data": [
                    {"id": short, "object": "model", "owned_by": "agy"}
                    for short in MODEL_ALIASES
                ],
            }).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        self._send_json(404, {"error": {"message": "not found", "type": "invalid_request_error"}})

    def do_POST(self) -> None:  # noqa: N802
        if not self.path.startswith("/v1/chat/completions"):
            self._send_json(404, {"error": {"message": "not found", "type": "invalid_request_error"}})
            return
        # Concurrency limit for running agy subprocesses
        acquired = _CONCURRENCY_SEMAPHORE.acquire(timeout=60.0)
        if not acquired:
            with _LOCK:
                _STATS["errors"] += 1
            self._send_json(503, {
                "error": {
                    "message": "Server is busy: too many concurrent agy subprocesses running",
                    "type": "server_busy_error",
                }
            })
            return
        try:
            self._do_post_under_limit()
        finally:
            _CONCURRENCY_SEMAPHORE.release()

    def _do_post_under_limit(self) -> None:
        with _LOCK:
            _STATS["requests"] += 1
        try:
            length = int(self.headers.get("Content-Length", "0"))
            raw = self.rfile.read(length) if length > 0 else b"{}"
            payload = json.loads(raw)
        except (json.JSONDecodeError, ValueError) as exc:
            with _LOCK:
                _STATS["errors"] += 1
            self._send_json(400, {"error": {"message": f"bad json: {exc}", "type": "invalid_request_error"}})
            return
        messages = payload.get("messages") or []
        if not isinstance(messages, list) or not messages:
            self._send_json(400, {"error": {"message": "messages[] required", "type": "invalid_request_error"}})
            return
        model = _resolve_agy_model(payload.get("model"))
        prompt = _flatten_messages(messages)
        # Use server-side configured directory only (no client headers overrides).
        add_dir = AGY_ADD_DIR
        start = time.time()
        text, actual_model, exit_code = _call_agy(prompt, model, add_dir)
        elapsed_ms = int((time.time() - start) * 1000)
        if exit_code != 0:
            with _LOCK:
                _STATS["errors"] += 1
            self._send_json(502, {
                "error": {
                    "message": text,
                    "type": "upstream_error",
                    "code": exit_code,
                },
            })
            return
        if actual_model != model:
            with _LOCK:
                _STATS["fallbacks_observed"] += 1
            log.warning("model fallback: requested=%s actual=%s", model, actual_model)
        completion_id = f"chatcmpl-{uuid.uuid4().hex[:24]}"
        response = {
            "id": completion_id,
            "object": "chat.completion",
            "created": int(time.time()),
            "model": actual_model,
            "choices": [{
                "index": 0,
                "message": {"role": "assistant", "content": text},
                "finish_reason": "stop",
            }],
            "usage": {
                # Rough char/4 estimate — agy has no usage metadata.
                "prompt_tokens": max(1, len(prompt) // 4),
                "completion_tokens": max(1, len(text) // 4),
                "total_tokens": max(2, (len(prompt) + len(text)) // 4),
            },
            "_agy_shim_ms": elapsed_ms,
        }
        self._send_json(200, response)

    def _send_json(self, status: int, payload: dict[str, Any]) -> None:
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def main() -> None:
    server = ThreadingHTTPServer((HOST, PORT), ShimHandler)
    log.info("agy-shim listening on http://%s:%d (binary=%s, default_model=%s)",
             HOST, PORT, AGY_BINARY, DEFAULT_AGY_MODEL)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        log.info("shutting down")
        server.shutdown()


if __name__ == "__main__":
    main()