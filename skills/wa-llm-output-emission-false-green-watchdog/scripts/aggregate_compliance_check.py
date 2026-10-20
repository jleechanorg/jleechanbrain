#!/usr/bin/env python3
"""Aggregate WA LLM-output compliance check across N campaigns × M sampled turns.

Recipe companion: references/aggregate-compliance-sampling.md (added 2026-08-18).

Inputs:
  - /tmp/wa_arc_work/raw_sample.json  (BQ pull, head_text + tail_text + response_chars per row)
  - /tmp/wa_campaigns_over_<threshold>.json  (campaign metadata)

Output:
  - /tmp/wa_arc_compliance_sample.json  (one JSON object per spec)
  - Per-campaign summary printed to stdout

Usage:
  $ python3 scripts/aggregate_compliance_check.py

Verified against the 2026-08-18 jeffrey sample (6 campaigns × 6 slots).
"""
import json
import re
import sys
import os

# --- Configuration ----------------------------------------------------------

# Edit these for a new run; defaults reproduce the 2026-08-18 jeffrey sample.
DEFAULT_RAW_PATH = "/tmp/wa_arc_work/raw_sample.json"
DEFAULT_CAMPAIGNS_PATH = "/tmp/wa_campaigns_over_100.json"
DEFAULT_OUTPUT_PATH = "/tmp/wa_arc_compliance_sample.json"

# Title short labels (matches the user-given task brief; full titles come from
# the campaigns-over-threshold JSON when available).
TASK_CAMPAIGNS = [
    ("fw9Fo3QXkqshtVxBIwX2", "Visenya v9 'forgot tybolt'"),
    ("qoQtHsU7DxZnR24VNU9w", "Visenya v9"),
    ("wc2BBcSgOljiU3vJ160A", "bg3 nocturne 'think ignored'"),
    ("1jO5rtBMvkvreFGCLahs", "Valeria iseki"),
    ("EROaUnSbmDhqBedTbJMg", "Sariel Valyria"),
    ("6aXYric3k1IXtJIg6LjT", "Supergirl 'off track'"),
]

TARGET_TURNS = [1, 5, 15, 30, 60, 100]

# Story-row totals per campaign — pre-computed via BQ MAX(rn). Update when
# sampling a new campaign. (For end-of-run detection: if MAX(rn) < target_turn,
# the slot is reported as `campaign_ended_at_turn_N`.)
STORY_TOTALS = {
    "1jO5rtBMvkvreFGCLahs": 113,
    "6aXYric3k1IXtJIg6LjT": 90,
    "EROaUnSbmDhqBedTbJMg": 38,
    "fw9Fo3QXkqshtVxBIwX2": 72,
    "qoQtHsU7DxZnR24VNU9w": 50,
    "wc2BBcSgOljiU3vJ160A": 138,
}

FREE_RE = re.compile(r"freeform|custom_action|__custom_action__", re.IGNORECASE)


# --- Helpers ----------------------------------------------------------------

def safe_excerpt(text, start, length=100):
    if start < 0:
        return ""
    end = min(start + length, len(text))
    return text[start:end].replace("\n", " ").strip()


def _walk_balanced(text, start):
    """Walk balanced {...} or [...] starting at `start` (the opening char index).
    Returns the index just past the matching close, or None on failure."""
    opener = text[start]
    depth = 0
    in_str = False
    esc = False
    for i in range(start, len(text)):
        ch = text[i]
        if esc:
            esc = False
            continue
        if ch == "\\":
            esc = True
            continue
        if ch == '"':
            in_str = not in_str
            continue
        if in_str:
            continue
        if ch in "{[":
            depth += 1
        elif ch in "}]":
            depth -= 1
            if depth == 0:
                return i + 1
    return None


def _choices_block_and_kind(text):
    """Find the value of "choices" inside planning_block. Returns (body, opener_char)."""
    m = re.search(r'"planning_block"\s*:\s*\{', text)
    if not m:
        return None, None
    pb_open = m.end() - 1
    pb_end = _walk_balanced(text, pb_open)
    if pb_end is None:
        return None, None
    pb_body = text[pb_open:pb_end]
    cm = re.search(r'"choices"\s*:\s*(\{|\[)', pb_body)
    if not cm:
        return None, None
    ch_open_in_pb = cm.end() - 1
    ch_open_in_full = pb_open + ch_open_in_pb
    ch_end_in_full = _walk_balanced(text, ch_open_in_full)
    if ch_end_in_full is None:
        return None, None
    return text[ch_open_in_full:ch_end_in_full], cm.group(1)


def _collect_keys_at_depth0(body):
    """Collect top-level string keys (key:value) at depth=0 of a JSON object body."""
    depth = 0
    in_str = False
    esc = False
    keys = []
    i = 1  # skip opening '{'
    n = len(body) - 1  # ignore closing '}'
    while i < n:
        ch = body[i]
        if esc:
            esc = False
            i += 1
            continue
        if ch == "\\":
            esc = True
            i += 1
            continue
        if ch == '"':
            if not in_str and depth == 0:
                j = i + 1
                while j < n:
                    if body[j] == "\\":
                        j += 2
                        continue
                    if body[j] == '"':
                        break
                    j += 1
                k = j + 1
                while k < n and body[k] in " \n\t\r":
                    k += 1
                if k < n and body[k] == ":":
                    keys.append(body[i + 1 : j])
                in_str = True
            elif in_str:
                in_str = False
            i += 1
            continue
        if not in_str:
            if ch in "{[":
                depth += 1
            elif ch in "}]":
                depth -= 1
        i += 1
    return keys


def count_choices_in_planning_block(text):
    """Count choices inside planning_block. Handles array and dict shapes."""
    body, opener = _choices_block_and_kind(text)
    if body is None:
        return 0
    if opener == "[":
        ids = re.findall(r'"id"\s*:\s*"[^"]+"', body)
        return len(ids)
    return len(_collect_keys_at_depth0(body))


def collect_choice_ids(text):
    """Return ordered list of choice IDs from planning_block (source order)."""
    body, opener = _choices_block_and_kind(text)
    if body is None:
        return []
    if opener == "[":
        return re.findall(r'"id"\s*:\s*"([^"]+)"', body)
    return _collect_keys_at_depth0(body)


def last_choice_id_is_freeform(text):
    ids = collect_choice_ids(text)
    if not ids:
        return False
    last = ids[-1].lower()
    return bool(FREE_RE.search(last))


def extract_narrative_chars(text):
    """Find "narrative": "..." and return (text, char_count). Handles \\" escapes."""
    m = re.search(r'"narrative"\s*:\s*"', text)
    if not m:
        return None, 0
    start = m.end()
    i = start
    while i < len(text):
        ch = text[i]
        if ch == "\\":
            i += 2
            continue
        if ch == '"':
            return text[start:i], len(text[start:i])
        i += 1
    return None, 0


def analyze_turn(row):
    """Run all 6 checks (A-F) plus narrative_chars + response_chars on a row."""
    head = row.get("head_text") or ""
    tail = row.get("tail_text") or ""
    full = head + ("\n" + tail if tail else "")

    # A. companion_arc_event OR companion_arcs
    a_match = re.search(r'"companion_arc_event"|"companion_arcs"', full)
    A = (a_match is not None, safe_excerpt(full, a_match.start() if a_match else -1, 100))

    # B. arc_milestones — phase string
    b_present = '"arc_milestones"' in full or '"arc_milestone"' in full
    b_phase = None
    if b_present:
        ph_m = re.search(r'"phase"\s*:\s*"([^"]+)"', full)
        if ph_m:
            b_phase = ph_m.group(1)
    B = (b_present, b_phase)

    # C. scene_event.quest_offered
    c_idx = full.find('"quest_offered"')
    if c_idx < 0:
        c_idx = full.find('"scene_event"')
    C = (c_idx >= 0, safe_excerpt(full, c_idx, 100))

    # D. active_mysteries OR mystery
    d_idx = full.find('"active_mysteries"')
    if d_idx < 0:
        d_idx = full.find('"mystery"')
    D = (d_idx >= 0, safe_excerpt(full, d_idx, 100))

    # E. planning_block.choices count
    E_count = count_choices_in_planning_block(full)

    # F. last choice is freeform
    F = last_choice_id_is_freeform(full)

    # G. narrative_chars
    _, narr_chars = extract_narrative_chars(full)

    # H. response_chars (full size from BQ)
    H = row.get("response_chars", 0)

    return {
        "A_companion_arc_event": [A[0], A[1]],
        "B_arc_milestones": [B[0], B[1]],
        "C_quest_offered": [C[0], C[1]],
        "D_active_mysteries": [D[0], D[1]],
        "E_choices_count": E_count,
        "F_last_choice_freeform": F,
        "narrative_chars": narr_chars,
        "response_chars": H,
    }


def build_campaign_block(cid, title, sample_by_key):
    out_turns = []
    for tn in TARGET_TURNS:
        key = (cid, str(tn))
        if key in sample_by_key:
            row = sample_by_key[key]
            out_turns.append({
                "turn_number": tn,
                "sampled_at": row["ingested_at"],
                "natural_turn_index": row.get("turn_index"),
                "agent": row["agent"],
                "event_type": row["event_type"],
                "model": row["model"],
                "checks": analyze_turn(row),
            })
        else:
            total = STORY_TOTALS.get(cid, "?")
            out_turns.append({
                "turn_number": tn,
                "status": f"campaign_ended_at_turn_{total}",
            })
    return {"campaign_id": cid, "title": title, "sampled_turns": out_turns}


def main():
    raw_path = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_RAW_PATH
    out_path = sys.argv[2] if len(sys.argv) > 2 else DEFAULT_OUTPUT_PATH

    if not os.path.exists(raw_path):
        sys.exit(f"FATAL: {raw_path} not found. Run the BQ pull first — see references/aggregate-compliance-sampling.md Step 2.")

    with open(raw_path) as f:
        rows = json.load(f)

    sample_by_key = {(r["campaign_id"], str(r["sampled_turn"])): r for r in rows}

    result = {
        "campaigns": [
            build_campaign_block(cid, title, sample_by_key) for cid, title in TASK_CAMPAIGNS
        ]
    }

    os.makedirs(os.path.dirname(out_path) or ".", exist_ok=True)
    with open(out_path, "w") as f:
        json.dump(result, f, indent=2)

    # Print a quick summary table to stdout
    print(f"Wrote {out_path}")
    for camp in result["campaigns"]:
        print(f"\n=== {camp['campaign_id']} — {camp['title']} ===")
        for t in camp["sampled_turns"]:
            if "status" in t:
                print(f"  T{t['turn_number']}: {t['status']}")
            else:
                c = t["checks"]
                print(
                    f"  T{t['turn_number']}: A={c['A_companion_arc_event'][0]} "
                    f"B={c['B_arc_milestones'][0]}({c['B_arc_milestones'][1]}) "
                    f"C={c['C_quest_offered'][0]} D={c['D_active_mysteries'][0]} "
                    f"E={c['E_choices_count']} F={c['F_last_choice_freeform']} "
                    f"narr={c['narrative_chars']} resp={c['response_chars']}"
                )

    # Aggregate compliance rate
    total = sum(1 for c in result["campaigns"] for t in c["sampled_turns"] if "checks" in t)
    hits = {"A": 0, "B": 0, "C": 0, "D": 0, "F": 0}
    for camp in result["campaigns"]:
        for t in camp["sampled_turns"]:
            if "checks" not in t:
                continue
            c = t["checks"]
            if c["A_companion_arc_event"][0]:
                hits["A"] += 1
            if c["B_arc_milestones"][0]:
                hits["B"] += 1
            if c["C_quest_offered"][0]:
                hits["C"] += 1
            if c["D_active_mysteries"][0]:
                hits["D"] += 1
            if c["F_last_choice_freeform"]:
                hits["F"] += 1
    print(f"\nOverall compliance (n={total}):")
    for k in "ABCDF":
        pct = (hits[k] / total * 100) if total else 0
        print(f"  {k}: {hits[k]}/{total} = {pct:.1f}%")


if __name__ == "__main__":
    main()