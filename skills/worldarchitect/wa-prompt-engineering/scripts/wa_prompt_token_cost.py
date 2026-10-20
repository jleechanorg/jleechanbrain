#!/usr/bin/env python3
"""
Measure the served-prompt token cost of a single mvp_site/prompts/*.md file.

Usage:
  python3 scripts/wa_prompt_token_cost.py <prompt-file.md> [--times N]
  python3 scripts/wa_prompt_token_cost.py mvp_site/prompts/deferred_rewards_instruction.md --times 7

Output: raw bytes, line count, and cl100k_base token estimate (close to Gemini 2.0/2.5).
The `--times N` flag multiplies the cost by N to project the total cost of injecting the
prompt into N time-advancing agents (see wa-prompt-engineering §"Orthogonal prompt-injection").

Run from the worldarchitect.ai repo root.
"""
import argparse
import sys
from pathlib import Path

try:
    import tiktoken
except ImportError:
    print("tiktoken not installed; install with: pip install tiktoken", file=sys.stderr)
    sys.exit(1)


def main():
    p = argparse.ArgumentParser(description="Measure prompt token cost (cl100k_base).")
    p.add_argument("path", type=Path, help="Path to a mvp_site/prompts/*.md file.")
    p.add_argument("--times", type=int, default=1, help="Multiplier (e.g. number of agents).")
    args = p.parse_args()

    if not args.path.is_file():
        print(f"error: file not found: {args.path}", file=sys.stderr)
        sys.exit(2)

    text = args.path.read_text(encoding="utf-8")
    enc = tiktoken.get_encoding("cl100k_base")
    tokens = len(enc.encode(text))

    lines = text.count("\n") + 1
    raw_bytes = len(text.encode("utf-8"))

    print(f"path:           {args.path}")
    print(f"lines:          {lines}")
    print(f"raw_bytes:      {raw_bytes}")
    print(f"tokens:         {tokens}  (cl100k_base ~ Gemini 2.0/2.5)")
    if args.times > 1:
        print(f"x {args.times} agents:  {tokens * args.times} tokens/turn total")


if __name__ == "__main__":
    main()
