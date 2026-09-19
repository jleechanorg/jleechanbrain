#!/usr/bin/env python3
"""WA compliance sampler — pull 6 representative turns per flagship-abandoned campaign and run regex
checks for the mandatory-prompt constructs.

Usage:
  python3 scripts/wa_compliance_sampler.py \\
      --campaigns-file /tmp/wa_campaigns_over_100.json \\
      --slots 1,5,15,30,60,100 \\
      --out /tmp/wa_compliance_sample.json

Filters story-mode turns via path LIKE '%story%' and uses ROW_NUMBER() OVER (PARTITION BY campaign_id
ORDER BY ingested_at) to pick slot positions. Reads only response_text (small, <50KB even on long
prompts), avoiding the truncated request_json column.

Constructs checked:
  A. companion_arc_event / companion_arcs — boolean + 100-char excerpt
  B. arc_milestones — boolean + first phase string
  C. scene_event.quest_offered — boolean + 100-char excerpt
  D. active_mysteries / mystery — boolean
  E. planning_block.choices count — exact number
  F. last choice is Freeform / custom_action — boolean + last choice id
  G. narrative_chars — character count of narrative block
  H. response_chars — total response payload size

Source: worldarchitecture-ai.llm_forensics.llm_payloads (BigQuery). Falls back to Firestore via
wa-prod-data-query if BQ is rate-limited.
"""

from __future__ import annotations
import argparse
import json
import re
import subprocess
import sys
from pathlib import Path


CONSTRUCTS = {
    "A": (r'"companion_arc_event"|"companion_arcs"', "bool + 100-char excerpt"),
    "B": (r'"arc_milestones"', "bool + first phase"),
    "C": (r'scene_event[^}]*?quest_offered|"quest_offered"', "bool + 100-char excerpt"),
    "D": (r'"active_mysteries"|"mystery_template"|"three_suspect"', "bool"),
}


def bq_query(sql: str, max_rows: int | None = None) -> list[dict]:
    args = ["bq", "query", "--format=json", "--use_legacy_sql=false"]
    if max_rows is not None:
        args.append(f"--max_rows={max_rows}")
    args.append(sql)
    result = subprocess.run(args, capture_output=True, text=True, timeout=300)
    if result.returncode != 0:
        raise RuntimeError(f"bq query failed: {result.stderr}")
    out = json.loads(result.stdout)
    return out if isinstance(out, list) else out.get("rows", out)


def campaign_turn_pairs(campaigns: list[dict], slots: list[int]) -> list[tuple[str, str, int]]:
    """Return list of (campaign_id, owner_handle, slot_turn_number) tuples from BQ."""
    if not campaigns:
        return []
    cids = ",".join(f'"{c["campaign_id"]}"' for c in campaigns)
    slots_str = ",".join(str(s) for s in slots)
    sql = f"""
    WITH turn_index AS (
      SELECT campaign_id, MIN(ingested_at) AS at,
             ROW_NUMBER() OVER (PARTITION BY campaign_id ORDER BY MIN(ingested_at)) AS turn_n
      FROM `worldarchitecture-ai.llm_forensics.llm_payloads`
      WHERE campaign_id IN ({cids})
        AND response_status = 'ok'
        AND prompt_tokens > 1000
        AND (path LIKE '%story%' OR path LIKE '%StoryMode%')
      GROUP BY campaign_id, turn_id
    )
    SELECT campaign_id, turn_n FROM turn_index
    WHERE turn_n IN ({slots_str})
    ORDER BY campaign_id, turn_n
    """
    rows = bq_query(sql)
    return [(r["campaign_id"], "", r["turn_n"]) for r in rows]


def response_for(campaign_id: str, turn_n: int) -> str:
    """Pull a single response_text for the given campaign and turn index."""
    sql = f"""
    WITH turn_index AS (
      SELECT turn_id, response_text,
             ROW_NUMBER() OVER (PARTITION BY campaign_id ORDER BY ingested_at) AS turn_n
      FROM `worldarchitecture-ai.llm_forensics.llm_payloads`
      WHERE campaign_id = "{campaign_id}"
        AND response_status = 'ok'
        AND response_text IS NOT NULL
        AND (path LIKE '%story%' OR path LIKE '%StoryMode%')
    )
    SELECT response_text FROM turn_index WHERE turn_n = {turn_n} LIMIT 1
    """
    rows = bq_query(sql, max_rows=1)
    if not rows or "response_text" not in rows[0]:
        return ""
    return rows[0]["response_text"]


def check_response(resp: str) -> dict:
    """Run A-H construct checks against a single response_text."""
    if not resp:
        return {"error": "no_response_payload"}

    head = resp[:6500]
    tail = resp[-5000:] if len(resp) > 11500 else ""
    sample = head + tail

    out: dict[str, object] = {}
    for tag, (pattern, _) in CONSTRUCTS.items():
        m = re.search(pattern, sample)
        out[f"{tag}_present"] = bool(m)
        if m and tag in ("A", "C"):
            start = max(0, m.start() - 50)
            excerpt = resp[start : start + 200].replace("\n", " ")
            out[f"{tag}_excerpt"] = excerpt[:150] + ("…" if len(excerpt) > 150 else "")
        if tag == "B" and m:
            ph = re.search(r'"phase"\s*:\s*"([^"]+)"', sample)
            out["B_phase"] = ph.group(1) if ph else None

    # E. choice count — array form: [{id: ...}, {id: ...}]
    # Find planning_block section; count entries with "id":
    pb_match = re.search(r'"planning_block"\s*:\s*\{', sample)
    if pb_match:
        pb_slice = sample[pb_match.start() : pb_match.start() + 8000]
        # Count "id": " occurrences inside the planning_block slice
        ids = re.findall(r'"id"\s*:\s*"', pb_slice)
        out["E_choice_count"] = len(ids)
        if ids:
            # Find the last id in the slice
            last = re.findall(r'"id"\s*:\s*"([^"]+)"', pb_slice)
            out["E_last_choice_id"] = last[-1] if last else None
            out["F_freeform_last"] = last[-1] in ("custom_action", "__custom_action__", "freeform") if last else False
    else:
        out["E_choice_count"] = 0
        out["F_freeform_last"] = False

    out["G_narrative_chars"] = len(re.search(r'"narrative"\s*:\s*"([^"\\]|\\.)*"', resp).group(0)) if re.search(r'"narrative"\s*:\s*"', resp) else 0
    out["H_response_chars"] = len(resp)
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--campaigns-file", required=True, help="/tmp/wa_campaigns_over_100.json")
    ap.add_argument("--slots", default="1,5,15,30,60,100")
    ap.add_argument("--limit-campaigns", type=int, default=6)
    ap.add_argument("--out", default="/tmp/wa_compliance_sample.json")
    args = ap.parse_args()

    slots = [int(s) for s in args.slots.split(",")]
    campaigns = json.loads(Path(args.campaigns_file).read_text())
    campaigns = [
        c for c in campaigns
        if c.get("owner_class") in ("jeffrey", "other_user")  # exclude test/farm
    ][: args.limit_campaigns]

    pairs = campaign_turn_pairs(campaigns, slots)
    out: dict = {"campaigns": []}

    by_campaign: dict[str, list[int]] = {}
    for cid, _, slot in pairs:
        by_campaign.setdefault(cid, []).append(slot)

    for c in campaigns:
        cid = c["campaign_id"]
        title = c.get("title", "")
        sampled: list[dict] = []
        for slot in by_campaign.get(cid, []):
            resp = response_for(cid, slot)
            sampled.append({"turn_number": slot, "checks": check_response(resp)})

        # Track end-of-campaign observation
        last_active = c.get("last_active", "")
        if sampled and last_active:
            sampled.append(
                {
                    "note": "campaign total turns",
                    "campaign_turn_count": c.get("turn_count"),
                    "last_active": last_active,
                }
            )

        out["campaigns"].append({"campaign_id": cid, "title": title, "sampled_turns": sampled})

    Path(args.out).write_text(json.dumps(out, indent=2))
    print(f"Wrote {args.out} ({Path(args.out).stat().st_size} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
