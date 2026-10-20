#!/usr/bin/env python3
"""analyze_local_txt_corpus.py — scan a directory of WA campaign .txt dumps and score UX.

Usage: copy to /tmp/analyze_batch_<X>.py and edit the CAMPAIGNS list (folder names +
expected entry counts). Runs without auth/path boilerplate.

Output: /tmp/all_readings/batch_<X>.json (array, one entry per campaign) +
        /tmp/all_readings/batch_<X>_summary.json (aggregate distribution dicts).

Schema matches wa-feedback-pattern-scan (Firestore variant) so cross-batch aggregation
is trivial.

Verified on batch C (9 campaigns, 56-234 entries, 2026-08-17).
"""
import json, re, statistics
from collections import Counter
from pathlib import Path

# --- config: edit before running ---
ROOT = Path("${HOME}/Downloads/all_campaigns")
OUT_DIR = Path("/tmp/all_readings")

CAMPAIGNS = [
    # ("<folder_name>", <expected_entry_count>),
    # ...
]

# --- regex helpers ---
GM_BLOCK_RE = re.compile(
    r"Game Master:\s*\n(.*?)(?=\n(?:Player|Dice Rolls|\[Timestamp|={5,}|\Z))",
    re.DOTALL,
)
PLAYER_CHOICE_RE = re.compile(r"Player \(choice:[^)]+\):\s*\n([^\n]+)")
SCENE_MARKER_RE = re.compile(r"SCENE\s+\d+")
SECTION_DIVIDER_RE = re.compile(r"={5,}\s*SCENE\s+\d+\s*={5,}")

DND_MARKERS = [
    r"\bd20\b",
    r"Paladin|Wizard|Rogue|Cleric|Fighter|Barbarian|Bard|Druid|Sorcerer|Warlock|Monk|Ranger",
    r"HP:\s*\d",
    r"AC:\s*\d",
    r"Oath of",
    r"\b5e\b",
    r"Standard Array",
    r"Standard ability",
]
WARNING_PHRASES = [
    r"action\s+resolution\s+warning",
    r"cannot\s+resolve",
    r"unclear\s+action",
    r"invalid\s+choice",
    r"no\s+valid\s+target",
]
# Heuristic narrative-prose markers (Pitfall 2 fix)
NARRATIVE_PROSE_MARKERS = [
    "the wind", "the road", "you find yourself", "you begin", "you've",
    "you stand", "you arrive", "you wake", "the bite", "the cold",
    "you pull", "beside you",
]


def read_file_safe(path):
    return path.read_text(encoding="utf-8", errors="replace")


def gm_blocks(text):
    return GM_BLOCK_RE.findall(text)


def find_first_n_player_actions(text, n=3):
    return PLAYER_CHOICE_RE.findall(text)[:n]


def find_first_post_cc(text):
    """Pitfall 2 fix: skip system-summary / sheet-dump GM blocks, return first
    narrative prose block."""
    blocks = gm_blocks(text)
    if not blocks:
        return ""
    for block in blocks:
        first = block.strip()
        low = first.lower()
        # Skip pseudo-narrative system blocks
        if first.startswith(("CAMPAIGN LAUNCH", "CAMPAIGN SUMMARY",
                              "[CHARACTER CREATION", "Warden", "[debug_")):
            continue
        if any(m in low[:400] for m in NARRATIVE_PROSE_MARKERS):
            return first[:800]
    # Fallback: second GM block (typical: 1st=CC sheet, 2nd=scene 1)
    return blocks[1].strip()[:800] if len(blocks) >= 2 else blocks[0].strip()[:800]


def avg_chars_per_gm_block(text):
    blocks = gm_blocks(text)
    if not blocks:
        return 0
    return int(statistics.mean(len(b) for b in blocks))


def count_cc_turns(text):
    return len(PLAYER_CHOICE_RE.findall(text))


def detect_standarddnd(text):
    hits = sum(len(re.findall(p, text, flags=re.IGNORECASE)) for p in DND_MARKERS)
    return hits >= 3


def count_action_resolution_warnings(text):
    return sum(len(re.findall(p, text, flags=re.IGNORECASE)) for p in WARNING_PHRASES)


def detect_loop_severity(text):
    """Pitfall 1 fix: count repeated first lines of GM blocks + Player-choice
    unique ratio. See references/local-txt-corpus-analysis.md."""
    blocks = gm_blocks(text)
    gm_starts = Counter()
    for b in blocks:
        for line in b.split("\n"):
            line = line.strip()
            if 15 < len(line) < 220:
                gm_starts[line[:60].lower()] += 1
    max_repeat = max(gm_starts.values()) if gm_starts else 0
    distinctive = sum(1 for v in gm_starts.values() if v >= 5)

    actions = PLAYER_CHOICE_RE.findall(text)
    if actions:
        unique = len(set(a.strip()[:40].lower() for a in actions))
        ratio = unique / len(actions)
    else:
        ratio = 1.0

    if max_repeat >= 7 or distinctive >= 3:
        return "severe"
    if max_repeat >= 4 or distinctive >= 1 or ratio < 0.5:
        return "moderate"
    if max_repeat >= 2 or ratio < 0.75:
        return "mild"
    return "none"


def score_onboarding(text):
    first = text[:1500].lower()
    has_cc = "character creation" in first or "character sheet" in first
    has_scaffold = any(t in first for t in ("ability scores", "stats", "class:"))
    if has_cc and has_scaffold:
        return 2
    if has_cc:
        return 1
    return 0


def score_friction(text):
    actions = PLAYER_CHOICE_RE.findall(text)
    n = len(actions)
    if n == 0:
        return 0
    avg_len = statistics.mean(len(a) for a in actions)
    if n > 50 and avg_len < 100:
        return 2
    if n > 20 or avg_len < 60:
        return 1
    return 0


def score_goal(text):
    low = text.lower()
    head = low[:3000]
    has_mission = any(p in head for p in ("you must", "your mission", "objective:", "goal:", "your task"))
    has_worldbuild = "world history" in low or "campaign summary" in low
    if has_mission and has_worldbuild:
        return 2
    if has_mission or has_worldbuild:
        return 1
    return 0


def score_readability(text):
    avg = avg_chars_per_gm_block(text)
    if avg == 0:
        return 0
    if avg < 800:
        return 2
    if avg < 1500:
        return 1
    return 0


def collect_patterns(text, avg_chars, name):
    pats = []
    if "Dice Rolls:" in text:
        pats.append("uses dice rolls")
    if "Game Master:" in text:
        pats.append("GM narrator blocks")
    if "Player (choice:" in text:
        pats.append("structured player choices")
    if "HP:" in text[:5000] or "Conditions:" in text[:5000]:
        pats.append("stat block header")
    if "Standard Array" in text or "Standard ability" in text:
        pats.append("D&D 5e character creation")
    if avg_chars > 2000:
        pats.append("wall-of-text GM blocks (>2k chars)")
    elif avg_chars > 1200:
        pats.append("long GM blocks (>1.2k chars)")
    head = text[:3000].lower()
    if any(t in head for t in ("aurum", "sariel", "lucifer", "imperium")):
        pats.append("deep lore setting")
    if any(t in text[:5000].lower() for t in ("lusty", "ballsac", " sex ", "erotic", "nsfw")):
        pats.append("adult themes")
    if "dragon" in name.lower() or "Dragon" in text[:2000]:
        pats.append("dragon-themed")
    if any(t in name.lower() for t in ("halcyon", "wyltopia", "trashcon", "space")):
        pats.append("original setting (not standard DnD name)")
    return pats


def analyze_campaign(name, expected):
    path = ROOT / name / f"{name}.txt"
    if not path.exists():
        return {"campaign": name, "error": "file not found"}
    text = read_file_safe(path)
    avg = avg_chars_per_gm_block(text)
    return {
        "campaign": name,
        "expected_entries": expected,
        "scene_marker_count": len(SCENE_MARKER_RE.findall(text)),
        "cc_turns": count_cc_turns(text),
        "cc_uses_standarddnd": detect_standarddnd(text),
        "action_resolution_warning_count": count_action_resolution_warnings(text),
        "loop_severity": detect_loop_severity(text),
        "onboarding_score": score_onboarding(text),
        "friction_score": score_friction(text),
        "goal_score": score_goal(text),
        "readability": score_readability(text),
        "wall_of_text_evidence": avg,
        "file_size_kb": path.stat().st_size // 1024,
        "notable_patterns": collect_patterns(text, avg, name),
        "first_3_user_actions": find_first_n_player_actions(text, 3),
        "first_post_cc_text": find_first_post_cc(text),
    }


def aggregate(out):
    return {
        "campaigns_analyzed": len(out),
        "avg_cc_turns": int(statistics.mean(r["cc_turns"] for r in out)),
        "median_cc_turns": int(statistics.median(r["cc_turns"] for r in out)),
        "uses_standarddnd_count": sum(1 for r in out if r["cc_uses_standarddnd"]),
        "loop_severity_dist": Counter(r["loop_severity"] for r in out),
        "onboarding_dist": Counter(r["onboarding_score"] for r in out),
        "friction_dist": Counter(r["friction_score"] for r in out),
        "readability_dist": Counter(r["readability"] for r in out),
        "avg_wall_of_text_chars": int(statistics.mean(r["wall_of_text_evidence"] for r in out)),
        "median_wall_of_text_chars": int(statistics.median(r["wall_of_text_evidence"] for r in out)),
        "total_action_resolution_warnings": sum(r["action_resolution_warning_count"] for r in out),
    }


def main():
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    out = [analyze_campaign(name, expected) for name, expected in CAMPAIGNS]
    summary = aggregate(out)
    # Make Counter JSON-serializable
    for k in ("loop_severity_dist", "onboarding_dist", "friction_dist", "readability_dist"):
        summary[k] = dict(summary[k])
    summary_path = OUT_DIR / "batch_X_summary.json"
    out_path = OUT_DIR / "batch_X.json"
    summary_path.write_text(json.dumps(summary, indent=2, ensure_ascii=False))
    out_path.write_text(json.dumps(out, indent=2, ensure_ascii=False))
    print(f"Wrote {out_path} and {summary_path}.")
    print(json.dumps(summary, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()
