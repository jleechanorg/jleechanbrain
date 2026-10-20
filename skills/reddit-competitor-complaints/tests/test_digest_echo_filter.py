"""Regression test for the digest-echo filter (added 2026-08-16).

A user pasted the previous digest verbatim into a Reddit thread. PullPush
indexed it, the script pulled it back, and the new digest re-emitted its
own previous output — visible duplication of `## N.` headers and our
stdout markers inside a single thread entry.

The detector must:
  - Skip posts whose title or body contains any of our stdout markers
  - Skip posts whose body contains ≥2 of our `## N. [...]` headers
  - Pass through normal Reddit posts that happen to mention "Top 10"
    in passing (combined with other markers is what real digests carry)

Run: python3 ~/.smartclaw/skills/reddit-competitor-complaints/tests/test_digest_echo_filter.py
"""
import importlib.util
import sys
from pathlib import Path

SCRIPT = Path.home() / ".smartclaw/scripts/reddit-competitor-complaints.py"
spec = importlib.util.spec_from_file_location("rcc", SCRIPT)
assert spec is not None and spec.loader is not None, f"cannot load {SCRIPT}"
r = importlib.util.module_from_spec(spec)
sys.modules["rcc"] = r
spec.loader.exec_module(r)


def case(label, title, body, expected):
    got = r._looks_like_digest_echo(title, body)
    status = "PASS" if got == expected else "FAIL"
    print(f"  [{status}] {label}: got={got} expected={expected}")
    return got == expected


failed = 0

# Cases that MUST be skipped (digest echoes)
if not case("stdout marker in body",
            "[Voyage] foo",
            "[2026-08-16 09:03:37 PDT] [reddit-competitor] === end (10 threads emitted) ===",
            True):
    failed += 1
if not case("digest header in body (≥2)",
            "[AI WEEKLY]",
            "## 9. [Voyage] foo\n\n## 10. [Voyage] bar\n\nTop 10 threads selected from 252 candidates",
            True):
    failed += 1
if not case("full Voyage thread #9 from real incident",
            "[AI WEEKLY NEWS RUNDOWN] Autonomous Agents Breach Taiwan, Enterprises Refuse the Frontier, and the Watermark Split (August 16, 2026)",
            "Top 10 threads selected from 252 candidates\n\n### :dart: Top 3 AI Dungeon threads\n\n**1. Scales, Streaks, Player Morale**\n\n[2026-08-16 09:03:37 PDT] [reddit-competitor] === end (10 threads emitted) ===",
            True):
    failed += 1
if not case("title contains digest marker",
            "Re: Top 10 threads selected from yesterday",
            "Normal Reddit body, no markers, no headers.",
            True):
    failed += 1

# Cases that MUST pass through (legitimate Reddit posts)
if not case("plain Reddit complaint post",
            "I showed Anthropic how not to fix their model",
            "Four days ago I published a post warning Anthropic about Context-Induced Activation Drift a vulnerability where harmless text shifts the model's internal states and weakens RLHF constraints.",
            False):
    failed += 1
if not case("empty post",
            "", "",
            False):
    failed += 1
if not case("single ## header is allowed (one is fine)",
            "Top 10 reasons AI Dungeon filters suck",
            "Here are my top 10 complaints about the NSFW filter.\n\n## 1. The filter blocks even mild romance.",
            False):
    failed += 1

# Known false-positive risk (accepted): a post that mentions "Top 10 threads
# selected from" without being a digest paste will be skipped. The trade-off
# is correct because the substring almost never appears in genuine Reddit
# posts and the alternative is re-emitting our own digest.
if not case("known false-positive (Top 10 substr)",
            "Top 10 threads selected from my saved posts",
            "A user ranking their own saved posts.",
            True):
    failed += 1

print()
if failed:
    print(f"FAILED: {failed} test(s)")
    sys.exit(1)
print(f"OK: all 8 tests passed")