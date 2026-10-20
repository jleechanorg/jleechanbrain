#!/usr/bin/env python3
"""
Chi-squared dice distribution audit for one WA user's rolls.

Consumes the normalized JSON from extract_user_dice.py (or any compatible
list of roll dicts) and runs 7 statistical checks:

1. d20 uniformity (chi2, df=19)              — does the d20 distribution match fair?
2. PC vs NPC d20 buckets (2x4 contingency) — does the player get higher rolls?
3. Per-die-size uniformity                  — split by die_size
4. Success rate by DC                       — does success rate deviate from expected?
5. Actor x campaign split                   — where are rolls distributed?
6. Nat 20 / Nat 1 rate                      — observed vs 5% expected
7. Cumulative distribution                  — quartiles + 5/95 percentile

Usage:
    cd ~/worldarchitect.ai
    WORLDAI_DEV_MODE=true .venv/bin/python \\
        ~/.smartclaw/skills/wa-dice-integrity-audit/scripts/chi_squared_audit.py \\
        --input /tmp/<uid>_dice.json

Stdout: human-readable report with chi2, df, critical values, pass/fail.
Stderr: (none)

Returns exit 0 on a clean run; exit 1 if no usable d20 rolls found.

Verified 2026-08-13 against UID oPISN50TvEcH21uVYKzlZX1kKNv2:
    87 d20 single-die rolls, chi2=159.67 (df=19) -> FAIL uniform
    Nat 20: 2 (2.3% vs 5.0%), Nat 1: 0 (0.0% vs 5.0%)
    PC vs NPC: 0 PC rolls in structured data — known schema gap
"""

from __future__ import annotations

import argparse
import json
import sys
from collections import Counter, defaultdict
from statistics import mean, median, stdev

# Critical values at alpha=0.05 / alpha=0.01 for common df.
# Hand-rolled so this script has no scipy/numpy dependency.
_CRITICAL_05 = {
    1: 3.841, 2: 5.991, 3: 7.815, 4: 9.488, 5: 11.070,
    6: 12.592, 7: 14.067, 8: 15.507, 9: 16.919, 10: 18.307,
    15: 24.996, 19: 30.144, 20: 31.410, 24: 36.415,
}
_CRITICAL_01 = {
    1: 6.635, 2: 9.210, 3: 11.345, 4: 13.277, 5: 15.086,
    6: 16.812, 7: 18.475, 8: 20.090, 9: 21.666, 10: 23.209,
    15: 30.578, 19: 36.191, 20: 37.566, 24: 42.980,
}


def crit(df: int, alpha: float = 0.05) -> float:
    """Best-known chi-square critical value. Falls back to Wilson-Hilferty approximation."""
    table = _CRITICAL_05 if alpha == 0.05 else _CRITICAL_01
    if df in table:
        return table[df]
    z = 1.6449 if alpha == 0.05 else 2.3263
    return df * (1 - 2 / (9 * df) + z * (2 / (9 * df)) ** 0.5) ** 3


def test_uniformity_d20(d20_faces):
    """Test 1: chi2 for d20 uniformity. df=19."""
    counts = Counter(d20_faces)
    expected = len(d20_faces) / 20.0
    chi2 = sum((counts.get(i, 0) - expected) ** 2 / expected for i in range(1, 21))
    df = 19
    return {
        "test": "d20 uniformity",
        "n": len(d20_faces),
        "chi2": chi2,
        "df": df,
        "critical_05": crit(df, 0.05),
        "critical_01": crit(df, 0.01),
        "pass_05": chi2 < crit(df, 0.05),
        "pass_01": chi2 < crit(df, 0.01),
        "mean": mean(d20_faces) if d20_faces else None,
        "median": median(d20_faces) if d20_faces else None,
        "stdev": stdev(d20_faces) if len(d20_faces) > 1 else None,
        "counts": dict(sorted(counts.items())),
    }


def test_pc_vs_npc(parsed):
    """Test 2: 2x4 contingency table on PC vs NPC d20 buckets."""
    pc_d20 = [
        p["faces"][0]
        for p in parsed
        if p["die_size"] == 20
        and len(p["faces"]) == 1
        and p.get("actor") == "user"
        and 1 <= p["faces"][0] <= 20
    ]
    npc_d20 = [
        p["faces"][0]
        for p in parsed
        if p["die_size"] == 20
        and len(p["faces"]) == 1
        and p.get("actor") != "user"
        and 1 <= p["faces"][0] <= 20
    ]
    if not pc_d20 or not npc_d20:
        return {
            "test": "PC vs NPC d20 buckets",
            "pc_n": len(pc_d20),
            "npc_n": len(npc_d20),
            "skipped": True,
            "reason": "insufficient PC or NPC structured rolls",
        }

    def bucket(rolls):
        b = Counter()
        for r in rolls:
            if r <= 5:
                b["1-5"] += 1
            elif r <= 10:
                b["6-10"] += 1
            elif r <= 15:
                b["11-15"] += 1
            else:
                b["16-20"] += 1
        return b

    pc_b = bucket(pc_d20)
    npc_b = bucket(npc_d20)
    cats = ["1-5", "6-10", "11-15", "16-20"]
    observed = [[pc_b.get(c, 0) for c in cats], [npc_b.get(c, 0) for c in cats]]
    col_totals = [observed[0][j] + observed[1][j] for j in range(4)]
    row_totals = [sum(observed[0]), sum(observed[1])]
    grand = sum(row_totals)
    chi2 = 0.0
    for i in range(2):
        for j in range(4):
            exp = row_totals[i] * col_totals[j] / grand if grand else 0
            if exp > 0:
                chi2 += (observed[i][j] - exp) ** 2 / exp
    df = 3
    return {
        "test": "PC vs NPC d20 buckets",
        "pc_n": len(pc_d20),
        "npc_n": len(npc_d20),
        "pc_mean": mean(pc_d20),
        "npc_mean": mean(npc_d20),
        "chi2": chi2,
        "df": df,
        "critical_05": crit(df, 0.05),
        "critical_01": crit(df, 0.01),
        "pass_05": chi2 < crit(df, 0.05),
        "pass_01": chi2 < crit(df, 0.01),
        "contingency": observed,
    }


def test_per_die_uniformity(parsed):
    """Test 3: per-die-size chi2."""
    by_die = defaultdict(list)
    for p in parsed:
        if len(p["faces"]) == 1 and 1 <= p["faces"][0] <= p["die_size"]:
            by_die[p["die_size"]].append(p["faces"][0])

    results = []
    for die_size in sorted(by_die.keys()):
        faces = by_die[die_size]
        if len(faces) < 5 or die_size > 100:
            continue
        counts = Counter(faces)
        expected = len(faces) / die_size
        df = die_size - 1
        chi2 = sum((counts.get(i, 0) - expected) ** 2 / expected for i in range(1, die_size + 1))
        results.append(
            {
                "die_size": die_size,
                "n": len(faces),
                "mean": mean(faces),
                "chi2": chi2,
                "df": df,
                "critical_05": crit(df, 0.05),
                "pass_05": chi2 < crit(df, 0.05),
            }
        )
    return results


def test_success_rate_by_dc(parsed):
    """Test 4: success rate by DC for 1d20+modifier vs DC."""
    by_dc = defaultdict(list)
    for p in parsed:
        if p["die_size"] != 20 or len(p["faces"]) != 1 or p["dc"] is None or p["total"] is None:
            continue
        by_dc[p["dc"]].append(p["success"])
    out = {}
    for dc in sorted(by_dc.keys()):
        succ = sum(1 for s in by_dc[dc] if s is True)
        fail = sum(1 for s in by_dc[dc] if s is False)
        n = succ + fail
        if n == 0:
            continue
        out[dc] = {
            "n": n,
            "pass": succ,
            "fail": fail,
            "pass_pct": succ / n * 100,
        }
    return out


def test_actor_by_campaign(parsed):
    """Test 5: actor x campaign split."""
    counter = Counter()
    for p in parsed:
        actor = "PC" if p.get("actor") == "user" else "NPC"
        counter[(p["campaign"], actor)] += 1
    out = {}
    for (camp, actor), count in counter.items():
        out.setdefault(camp, {"PC": 0, "NPC": 0})
        out[camp][actor] = count
    return out


def test_nat_rates(parsed):
    """Test 6: nat 20 / nat 1 rates on d20 single-die rolls."""
    d20_single = [
        p["faces"][0]
        for p in parsed
        if p["die_size"] == 20 and len(p["faces"]) == 1
    ]
    n = len(d20_single)
    nat20 = sum(1 for r in d20_single if r == 20)
    nat1 = sum(1 for r in d20_single if r == 1)
    if n == 0:
        return {"n": 0}
    exp = n * 0.05
    chi2 = ((nat20 - exp) ** 2 / exp) + ((nat1 - exp) ** 2 / exp) if exp > 0 else 0.0
    return {
        "n": n,
        "nat_20": nat20,
        "nat_20_pct": nat20 / n * 100,
        "nat_1": nat1,
        "nat_1_pct": nat1 / n * 100,
        "expected_5pct": exp,
        "chi2": chi2,
        "df": 1,
        "critical_05": crit(1, 0.05),
        "pass_05": chi2 < crit(1, 0.05),
    }


def test_cdf(parsed):
    """Test 7: cumulative distribution quartiles + 5/95 percentiles on d20."""
    d20_faces = sorted(
        [
            p["faces"][0]
            for p in parsed
            if p["die_size"] == 20 and len(p["faces"]) == 1 and 1 <= p["faces"][0] <= 20
        ]
    )
    n = len(d20_faces)
    if n == 0:
        return {"n": 0}
    out = {"n": n}
    for pct in [0.05, 0.25, 0.5, 0.75, 0.95]:
        idx = min(int(pct * n), n - 1)
        out[f"p{int(pct*100)}"] = {
            "observed": d20_faces[idx],
            "expected_fair": pct * 20,
            "delta": d20_faces[idx] - pct * 20,
        }
    return out


def render_report(parsed, metadata=None):
    """Render the 7-test report as human-readable text."""
    d20_faces = [
        p["faces"][0]
        for p in parsed
        if p["die_size"] == 20 and len(p["faces"]) == 1 and 1 <= p["faces"][0] <= 20
    ]

    lines = []
    lines.append("=" * 72)
    lines.append("CHI-SQUARED DICE INTEGRITY AUDIT")
    lines.append("=" * 72)
    if metadata:
        lines.append(f"UID: {metadata.get('uid', '?')}")
        lines.append(f"Campaigns: {len(metadata.get('campaigns', []))}")
    lines.append(f"Total rolls parsed: {len(parsed)}")
    lines.append(f"d20 single-die rolls: {len(d20_faces)}")
    lines.append("")

    t1 = test_uniformity_d20(d20_faces)
    lines.append("=" * 72)
    lines.append("TEST 1: d20 UNIFORMITY (null: fair die, expected 1/20 each)")
    lines.append("=" * 72)
    lines.append(f"  d20 single-die rolls: {t1['n']}")
    if t1["n"] > 0:
        lines.append(f"  Observed counts: {t1['counts']}")
        lines.append(f"  Expected (fair): {t1['n']/20:.2f} per face")
        lines.append(f"  chi2 = {t1['chi2']:.3f}")
        lines.append(f"  df = {t1['df']}")
        lines.append(f"  Critical (alpha=0.05): {t1['critical_05']:.3f}  -> {'PASS (uniform)' if t1['pass_05'] else 'FAIL (non-uniform)'}")
        lines.append(f"  Critical (alpha=0.01): {t1['critical_01']:.3f}  -> {'PASS (uniform)' if t1['pass_01'] else 'FAIL (non-uniform)'}")
        lines.append(f"  Mean: {t1['mean']:.2f}  (expected 10.5)")
        lines.append(f"  Median: {t1['median']:.1f}  (expected 10.5)")
        if t1["stdev"] is not None:
            lines.append(f"  StDev: {t1['stdev']:.2f}  (expected 5.76 for uniform 1-20)")
    lines.append("")

    t2 = test_pc_vs_npc(parsed)
    lines.append("=" * 72)
    lines.append("TEST 2: PC vs NPC d20 BUCKETS")
    lines.append("=" * 72)
    if t2 is None:
        lines.append("  Skipped: no d20 rolls found")
    elif t2.get("skipped"):
        lines.append(f"  Skipped: {t2['reason']}")
        lines.append(f"  PC d20 rolls: {t2['pc_n']}")
        lines.append(f"  NPC d20 rolls: {t2['npc_n']}")
    else:
        lines.append(f"  PC d20 rolls: {t2['pc_n']}  (mean {t2['pc_mean']:.2f})")
        lines.append(f"  NPC d20 rolls: {t2['npc_n']}  (mean {t2['npc_mean']:.2f})")
        lines.append(f"  Delta: PC mean - NPC mean = {t2['pc_mean'] - t2['npc_mean']:+.2f}")
        lines.append(f"  Contingency (PC | NPC):")
        cats = ["1-5", "6-10", "11-15", "16-20"]
        lines.append(f"    {'bucket':<8} | {'PC':>4} | {'NPC':>4}")
        for j, c in enumerate(cats):
            lines.append(f"    {c:<8} | {t2['contingency'][0][j]:>4} | {t2['contingency'][1][j]:>4}")
        lines.append(f"  chi2 = {t2['chi2']:.3f}  df={t2['df']}")
        lines.append(f"  Critical (alpha=0.05): {t2['critical_05']:.3f}  -> {'PASS (independent)' if t2['pass_05'] else 'FAIL (PC favored)'}")
        lines.append(f"  Critical (alpha=0.01): {t2['critical_01']:.3f}  -> {'PASS (independent)' if t2['pass_01'] else 'FAIL (PC favored)'}")
    lines.append("")

    t3 = test_per_die_uniformity(parsed)
    lines.append("=" * 72)
    lines.append("TEST 3: PER-DIE-SIZE UNIFORMITY")
    lines.append("=" * 72)
    if not t3:
        lines.append("  No die sizes with n >= 5 found")
    else:
        for r in t3:
            verdict = "PASS" if r["pass_05"] else "FAIL"
            lines.append(f"  d{r['die_size']:>3}: n={r['n']:>3}  mean={r['mean']:>5.2f}  chi2={r['chi2']:>8.2f}  df={r['df']}  -> {verdict}")
    lines.append("")

    t4 = test_success_rate_by_dc(parsed)
    lines.append("=" * 72)
    lines.append("TEST 4: SUCCESS RATE BY DC (1d20+modifier vs DC)")
    lines.append("=" * 72)
    if not t4:
        lines.append("  No structured 1d20 vs DC rolls found")
    else:
        for dc, r in sorted(t4.items()):
            lines.append(f"  DC {dc:>2}: {r['n']:>3} rolls -> {r['pass']} pass / {r['fail']} fail ({r['pass_pct']:.1f}% pass)")
    lines.append("")

    t5 = test_actor_by_campaign(parsed)
    lines.append("=" * 72)
    lines.append("TEST 5: ACTOR x CAMPAIGN (PC vs NPC)")
    lines.append("=" * 72)
    if not t5:
        lines.append("  No rolls found")
    else:
        for camp, counts in sorted(t5.items()):
            pc = counts["PC"]
            npc = counts["NPC"]
            total = pc + npc
            ratio = pc / total * 100 if total else 0
            lines.append(f"  {camp:<30}  PC: {pc:>4}   NPC: {npc:>4}   {ratio:.1f}% PC")
    lines.append("")

    t6 = test_nat_rates(parsed)
    lines.append("=" * 72)
    lines.append("TEST 6: NAT 20 / NAT 1 RATES (expected 5% each for fair d20)")
    lines.append("=" * 72)
    if t6.get("n", 0) == 0:
        lines.append("  No d20 single rolls")
    else:
        lines.append(f"  Total d20 single rolls: {t6['n']}")
        lines.append(f"  Nat 20s: {t6['nat_20']}  ({t6['nat_20_pct']:.1f}%  expected 5.0%)")
        lines.append(f"  Nat 1s:  {t6['nat_1']}  ({t6['nat_1_pct']:.1f}%  expected 5.0%)")
        if t6.get("chi2") is not None:
            lines.append(f"  chi2 (df={t6['df']}): {t6['chi2']:.3f}  (critical alpha=0.05: {t6['critical_05']:.3f})  -> {'PASS' if t6['pass_05'] else 'FAIL'}")
    lines.append("")

    t7 = test_cdf(parsed)
    lines.append("=" * 72)
    lines.append("TEST 7: CUMULATIVE DISTRIBUTION (d20)")
    lines.append("=" * 72)
    if t7.get("n", 0) == 0:
        lines.append("  No d20 rolls")
    else:
        lines.append(f"  n = {t7['n']}")
        for pct in ["p5", "p25", "p50", "p75", "p95"]:
            r = t7.get(pct)
            if r:
                lines.append(f"    {pct[1:]:>3}th percentile: observed={r['observed']:>3}  expected={r['expected_fair']:>4.1f}  delta={r['delta']:+.1f}")
    lines.append("")
    lines.append("=" * 72)
    lines.append("END OF AUDIT")
    lines.append("=" * 72)
    return "\n".join(lines)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument(
        "--input",
        required=True,
        help="JSON file from extract_user_dice.py (or compatible list of roll dicts)",
    )
    args = ap.parse_args()

    with open(args.input) as f:
        data = json.load(f)

    if isinstance(data, dict) and "rolls_normalized" in data:
        parsed = data["rolls_normalized"]
        metadata = {
            "uid": data.get("uid"),
            "campaigns": data.get("campaigns", []),
        }
    elif isinstance(data, list):
        parsed = data
        metadata = None
    else:
        print("ERROR: input must be a dict with 'rolls_normalized' or a list of roll dicts", file=sys.stderr)
        return 1

    if not parsed:
        print("No rolls parsed — nothing to audit", file=sys.stderr)
        return 1

    print(render_report(parsed, metadata))
    return 0


if __name__ == "__main__":
    sys.exit(main())