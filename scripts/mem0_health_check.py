#!/usr/bin/env python3
"""Red-green smoke test for the shared mem0 (hermes_mem0) store.

Reproduces the historical failure modes (vector-dim mismatch, missing
groq package, broken LLM extraction) and verifies that they are fixed.

The script is deliberately idempotent so it can run from CI, cron, or
a one-off shell. Exit codes:
    0 = all checks passed (green)
    1 = at least one check failed (red)

Usage:
    python3 ~/.smartclaw/scripts/mem0_health_check.py
"""
from __future__ import annotations

import os
import subprocess
import sys
import traceback
from typing import Callable

MEM0_CLIENT = os.path.expanduser("~/.smartclaw/scripts/mem0_shared_client.py")
USER_ID = "jleechan"


def _banner(label: str, ok: bool, detail: str = "") -> None:
    mark = "PASS" if ok else "FAIL"
    print(f"[{mark}] {label}" + (f"  ({detail})" if detail else ""))


def check_dependencies() -> bool:
    """The `groq` pip package must be importable in the venv mem0 lives in."""
    try:
        from groq import Groq  # noqa: F401
        _banner("groq python package importable", True)
        return True
    except Exception as exc:
        _banner("groq python package importable", False, repr(exc))
        return False


def check_collection_dims() -> bool:
    """The qdrant `hermes_mem0` collection must match the configured embedder dims."""
    try:
        import urllib.request
        import json as _json

        # qdrant can stall briefly during vector indexing; retry once after 2s
        last_exc: Exception | None = None
        for attempt in range(2):
            try:
                with urllib.request.urlopen(
                    "http://127.0.0.1:6333/collections/hermes_mem0", timeout=15
                ) as resp:
                    data = _json.loads(resp.read())
                size = data["result"]["config"]["params"]["vectors"]["size"]
                if size == 768:
                    _banner("qdrant hermes_mem0 dim == 768", True, f"size={size}")
                    return True
                _banner("qdrant hermes_mem0 dim == 768", False, f"size={size} (expected 768)")
                return False
            except Exception as exc:
                last_exc = exc
                if attempt == 0:
                    import time as _time
                    _time.sleep(2)
        raise last_exc  # type: ignore[misc]
    except Exception as exc:
        _banner("qdrant hermes_mem0 dim == 768", False, repr(exc))
        return False


def check_groq_configured() -> bool:
    """The mem0 LLM config must use groq, with GROQ_API_KEY in env or api_key in config."""
    try:
        sys.path.insert(0, os.path.expanduser("~/.smartclaw/.claude/hooks"))
        import mem0_config  # type: ignore

        llm = mem0_config.MEM0_CONFIG.get("llm", {})
        prov = (llm.get("provider") or "").lower()
        api_key = (llm.get("config") or {}).get("api_key") or os.environ.get("GROQ_API_KEY", "")
        if prov != "groq":
            _banner("mem0 LLM provider == groq", False, f"provider={prov!r}")
            return False
        if not api_key or api_key.startswith("$"):
            _banner("mem0 LLM provider == groq", False, "no GROQ_API_KEY in config or env")
            return False
        _banner("mem0 LLM provider == groq", True, f"api_key={'set' if api_key else 'missing'}")
        return True
    except Exception as exc:
        _banner("mem0 LLM provider == groq", False, repr(exc))
        return False


def check_add_with_infer() -> bool:
    """The end-to-end path: add_memory(text, user_id, infer=True) succeeds
    (i.e. Groq extraction works AND the embed+vector_store write lands).

    Accepts either a successful new write OR a MemoryWriteError dedup — the
    latter is the correct, expected behavior of mem0 when the same fact is
    added twice (it deduplicates via the LLM extractor).

    Timeout is 300s because the full pipeline (mem0 init + Groq extraction +
    Ollama embed + qdrant insert) can take 60-180s on first run when mem0
    creates its internal `mem0migrations` collection from scratch.
    """
    import time as _time
    try:
        result = subprocess.run(
            [
                "python3",
                MEM0_CLIENT,
                "add",
                f"mem0_health_check: red-green smoke fact at {_time.time_ns()}",
                "--user-id", USER_ID,
            ],
            capture_output=True,
            text=True,
            timeout=300,
        )
        out = result.stdout.strip()
        err = (result.stderr or "").strip()
        # Accept either: new write (exit=0 with results) OR dedup (MemoryWriteError)
        if result.returncode == 0 and out:
            _banner("mem0 add (LLM extract + embed + vector store)", True, out[:120])
            return True
        if "MemoryWriteError" in err and "deduplicated" in err:
            _banner("mem0 add (LLM extract + embed + vector store) — dedup", True,
                    "Groq LLM dedup'd identical fact (correct)")
            return True
        last = err.splitlines()[-3:] if err else []
        _banner("mem0 add (LLM extract + embed + vector store)", False,
                f"exit={result.returncode}  last_stderr={last}")
        return False
    except Exception as exc:
        _banner("mem0 add (LLM extract + embed + vector store)", False, repr(exc))
        return False


def check_search() -> bool:
    """Search must return at least 1 result for the smoke fact.

    Note: when infer=True, Groq extracts a fact from the input rather than
    storing it verbatim — so the search query and stored text need not match
    exactly. We only require a non-empty result list (any score).

    Timeout is 60s because the search pipeline is three serial network calls
    (mem0 LLM extraction → Ollama embedder → qdrant search). Under launchd
    each leg can take 10-15s on a cold cache; 30s was insufficient (see
    2026-06-22 incident). 60s gives ~20s/leg of headroom while still
    surfacing real outages within 1 minute.
    """
    try:
        result = subprocess.run(
            [
                "python3",
                MEM0_CLIENT,
                "search",
                "mem0 health check red green",
                "--user-id", USER_ID,
            ],
            capture_output=True,
            text=True,
            timeout=60,
        )
        out = result.stdout.strip()
        if result.returncode == 0 and out and "[]" not in out.splitlines()[0]:
            _banner("mem0 search returns at least one result", True, out[:120])
            return True
        _banner("mem0 search returns at least one result", False,
                f"exit={result.returncode}  stdout={out[:120]}")
        return False
    except Exception as exc:
        _banner("mem0 search returns at least one result", False, repr(exc))
        return False


CHECKS: list[tuple[str, Callable[[], bool]]] = [
    ("groq dependency", check_dependencies),
    ("qdrant collection dim", check_collection_dims),
    ("mem0 groq config", check_groq_configured),
    ("add_memory(infer=True)", check_add_with_infer),
    ("search_memory()", check_search),
]


def main() -> int:
    print("mem0 health check — red-green smoke")
    print("-" * 60)
    results: list[tuple[str, bool]] = []
    for name, fn in CHECKS:
        try:
            ok = bool(fn())
        except Exception:
            traceback.print_exc()
            ok = False
        results.append((name, ok))

    print("-" * 60)
    passed = sum(1 for _, ok in results if ok)
    total = len(results)
    print(f"Result: {passed}/{total} passed")
    for name, ok in results:
        _banner(name, ok)
    return 0 if passed == total else 1


if __name__ == "__main__":
    sys.exit(main())
