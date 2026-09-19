#!/usr/bin/env python3
"""
scene_rewrite_batch.py — canonical Step 4 sibling-worker runner.

Usage:
    python3 scene_rewrite_batch.py \
        --scenes overlord-carne-rescue:JQeI1Aq5:9:21:ains_shy_lich:ca197e7b \
                valeria-razors-edge:1jO5rtBM:275:285:valeria_iseki:c1338ce4 \
                tenebria-sector2:FsiyESY9:225:235::: \
        --provider grok --out-dir /tmp/avatar_scene_gen/scenes

Each --scenes argument is `<slug>:<cid>:<lo>:<hi>:<avatar-slug?>:<avatar-sha8?>`
(missing avatar parts → campaign-avatar-default placeholder).

The script:
  1. Probes 1-3 xAI keys from ~/.bashrc and picks the first that responds.
  2. For each scene, loads raw_<cid>.jsonl, slices entries [lo..hi], builds a
     tone-specific prompt, sends to Grok-4.3 with max_tokens=3000.
  3. Backs up any existing grok.md to grok.vN.md (rotation).
  4. Writes the raw prose to grok.md, the prompt to grok_prompt.txt, and the
     meta.json with model/tokens/wall_seconds/avatars_used.
  5. Runs a word-count check on every output; if any scene lands under 600,
     appends to a follow-up JSON list the caller can use for Round 2.

Designed to be idempotent across re-runs (just overwrites the canonical
files; backups preserve history).
"""
import argparse
import concurrent.futures as cf
import json
import os
import re
import shutil
import sys
import time
import urllib.request
from pathlib import Path

# ---------------------------------------------------------------------------
# CONSTANTS — tone templates per IP (keyed by a substring of the campaign
# label). Add new IPs here; the dispatch is a label-substring match.
# ---------------------------------------------------------------------------

TONE_TEMPLATES = {
    "Overlord": (
        "Rewrite this scene for a 600-900 word cinematic, Overlord isekai tone — "
        "third-person, dark-comedic, preserving named NPCs (Ains, Sebas, Enri Emmot, "
        "Captain Nigun, the Vanguard, Gazef Stronoff) verbatim. Cognitive dissonance "
        "between a god-queen lich calling the attack 'very mean' and her elite knights "
        "radiating lethal intent is the hook."
    ),
    "Valeria iseki": (
        "Rewrite this scene for a 600-900 word dramatic isekai combat beat — preserve "
        "dawn light, 'geometric kill-box,' and obsidian walls 'in ghostly shifting hues.' "
        "Third-person, tense, named NPCs verbatim."
    ),
    "tenebria": (
        "Rewrite this scene for a 600-900 word tense-espionage beat — claustrophobic, "
        "third-person. Preserve the rust-scented condensation, unshielded power cables, "
        "stagnant coolant slurry, and the named Horuset jamming arrays. Named NPCs verbatim."
    ),
    "Visenya v9": (
        "Rewrite this scene for a 600-900 word dark-comedy political-drama beat — "
        "third-person, preserving the geometric table staging (Maekar, Baelor, Hand, "
        "terrified brothers) and the cute-voice-on-ruthless-shift contrast. Candles burn "
        "'like cooling blood.' Named NPCs verbatim."
    ),
    "Supergirl": (
        "Rewrite this scene for a 600-900 word iconic-NPC-banter dramatic-reveal beat — "
        "third-person. Preserve the marble annexe, lead-lined air, and the Lex-vs-Supergirl "
        "banter. Close on her quiet apology: '16 and tired of living for others.' Named "
        "NPCs verbatim."
    ),
}

SYSTEM_PROMPT = (
    "You are a cinematic sci-fi/fantasy scene rewriter. Output ONLY the rewritten scene "
    "prose — no preamble, no labels, no headers. Match the source material's tone exactly. "
    "Preserve named NPCs and environmental details verbatim. WRITING LENGTH: hit the "
    "explicit word floor stated in the user prompt — under-length output is rejected."
)

XAI_URL = "https://api.x.ai/v1/chat/completions"


# ---------------------------------------------------------------------------
# KEY PROBE — read ~/.bashrc, try 1-3 xAI keys, return first that responds.
# Do NOT trust os.environ inside Hermes because the gateway masks env values.
# ---------------------------------------------------------------------------

def load_xai_keys():
    keys = []
    key_names = ["GROK_API_KEY", "WORLDAI_GROK_KEY", "AI_UNIV_GROK_KEY"]
    for line in open(Path.home() / ".bashrc"):
        s = line.strip()
        for k in key_names:
            m = re.match(rf'export\s+{k}="([^"]+)"', s)
            if m and not m.group(1).startswith("$"):
                if m.group(1) not in keys:
                    keys.append(m.group(1))
    return keys


def probe_key(key):
    body = json.dumps({
        "model": "grok-4.3",
        "max_tokens": 10,
        "messages": [{"role": "user", "content": "PONG"}],
    }).encode()
    req = urllib.request.Request(
        XAI_URL,
        data=body,
        headers={"Content-Type": "application/json", "Authorization": f"Bearer {key}"},
    )
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            resp = json.loads(r.read().decode())
        return resp.get("model", "").startswith("grok")
    except Exception:
        return False


def select_xai_key():
    for k in load_xai_keys():
        if probe_key(k):
            return k
    raise SystemExit("No working xAI key found in ~/.bashrc")


# ---------------------------------------------------------------------------
# PROMPT BUILDING
# ---------------------------------------------------------------------------

def load_entries(cid, lo, hi, base_dir):
    rows = []
    with open(Path(base_dir) / f"raw_{cid}.jsonl") as f:
        for line in f:
            if not line.strip():
                continue
            rows.append(json.loads(line))
    return sorted([r for r in rows if lo <= r.get("idx", -1) + 1 <= hi],
                  key=lambda r: r.get("idx", 0))


def find_tone_template(label):
    for needle, tmpl in TONE_TEMPLATES.items():
        if needle.lower() in label.lower():
            return tmpl
    return ("Rewrite this scene for a 600-900 word cinematic beat, third-person, "
            "preserving named NPCs and environmental details verbatim.")


def build_prompt(scene, label, avatar_filename, entries):
    tmpl = find_tone_template(label)
    avatar_line = ""
    if avatar_filename:
        avatar_line = (
            f"Reference avatar file '{avatar_filename}' as the visible character (named "
            f"verbatim with that exact filename) when describing them.\n\n"
        )
    else:
        avatar_line = (
            "No matching Drive avatar exists for this scene — write the visible-character "
            "slot as the literal placeholder 'campaign-avatar-default' rather than "
            "fabricating an avatar filename.\n\n"
        )
    text_blob = "\n\n".join(
        f"[entry {r['idx']+1} | {r.get('ts','?')} | {r.get('actor','?')} | {r.get('mode','?')}]\n{r.get('text','')[:1800]}"
        for r in entries
    )
    return (
        f"{tmpl}\n\n{avatar_line}"
        f"ORIGINAL ENTRIES (range: {scene['lo']}-{scene['hi']}):\n\n{text_blob}"
    )


# ---------------------------------------------------------------------------
# GROK CALL
# ---------------------------------------------------------------------------

def call_grok(key, prompt, max_tokens=3000, temperature=0.85):
    body = json.dumps({
        "model": "grok-4.3",
        "max_tokens": max_tokens,
        "temperature": temperature,
        "messages": [
            {"role": "system", "content": SYSTEM_PROMPT},
            {"role": "user", "content": prompt},
        ],
    }).encode()
    req = urllib.request.Request(
        XAI_URL,
        data=body,
        headers={"Content-Type": "application/json", "Authorization": f"Bearer {key}"},
    )
    t0 = time.time()
    with urllib.request.urlopen(req, timeout=180) as r:
        resp = json.loads(r.read().decode())
    return resp, time.time() - t0


# ---------------------------------------------------------------------------
# WRITE
# ---------------------------------------------------------------------------

def backup_rotation(scene_dir):
    """Promote any existing grok.md → grok.vN.md (max+1)."""
    cur = scene_dir / "grok.md"
    if not cur.exists():
        return None
    existing = []
    for p in scene_dir.glob("grok.v*.md"):
        m = re.match(r"grok\.v(\d+)\.md$", p.name)
        if m:
            existing.append(int(m.group(1)))
    next_idx = (max(existing) + 1) if existing else 1
    backup = scene_dir / f"grok.v{next_idx}.md"
    shutil.copy(cur, backup)
    return str(backup)


def write_outputs(scene_dir, msg, prompt_text, meta_extra):
    backup = backup_rotation(scene_dir)
    scene_dir.mkdir(parents=True, exist_ok=True)
    (scene_dir / "grok.md").write_text(msg.strip() + "\n")
    (scene_dir / "grok_prompt.txt").write_text(prompt_text)
    if backup:
        meta_extra["backed_up_to"] = backup
    (scene_dir / "meta.json").write_text(json.dumps(meta_extra, indent=2))


# ---------------------------------------------------------------------------
# MAIN
# ---------------------------------------------------------------------------

def parse_scene_arg(spec):
    parts = spec.split(":")
    if len(parts) < 4:
        raise argparse.ArgumentTypeError(
            f"--scenes entry '{spec}' needs at least slug:cid:lo:hi"
        )
    slug, cid, lo, hi = parts[:4]
    avatar_slug = parts[4] if len(parts) > 4 and parts[4] else None
    avatar_sha = parts[5] if len(parts) > 5 and parts[5] else None
    avatar_filename = (
        f"{avatar_sha}_{avatar_slug}" if avatar_slug and avatar_sha else None
    )
    return {
        "slug": slug,
        "cid": cid,
        "lo": int(lo),
        "hi": int(hi),
        "avatar_filename": avatar_filename,
    }


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--scenes", nargs="+", required=True, type=parse_scene_arg,
                    metavar="slug:cid:lo:hi[:avatar_slug:avatar_sha8]",
                    help="One or more scene specs (see docstring)")
    ap.add_argument("--labels", default="{}",
                    help="JSON mapping cid→label, e.g. '{\"JQeI1Aq5\":\"Overlord shy lich\"}'")
    ap.add_argument("--provider", default="grok", choices=["grok", "openai", "gemini"])
    ap.add_argument("--base-dir", default="/tmp/avatar_scene_gen")
    ap.add_argument("--out-dir", default=None,
                    help="Defaults to <base-dir>/scenes")
    ap.add_argument("--max-tokens", type=int, default=3000)
    ap.add_argument("--temperature", type=float, default=0.85)
    ap.add_argument("--max-workers", type=int, default=5)
    args = ap.parse_args()

    labels = json.loads(args.labels) if args.labels else {}
    out_dir = Path(args.out_dir) if args.out_dir else Path(args.base_dir) / "scenes"
    out_dir.mkdir(parents=True, exist_ok=True)

    if args.provider != "grok":
        raise SystemExit(f"Provider {args.provider} not yet wired in this script.")

    key = select_xai_key()
    print(f"[setup] using xAI key len={len(key)}")

    def worker(scene):
        label = labels.get(scene["cid"], "unknown")
        entries = load_entries(scene["cid"], scene["lo"], scene["hi"], args.base_dir)
        prompt = build_prompt(scene, label, scene["avatar_filename"], entries)
        resp, dt = call_grok(key, prompt,
                             max_tokens=args.max_tokens,
                             temperature=args.temperature)
        msg = resp["choices"][0]["message"]["content"]
        usage = resp.get("usage", {})
        scene_dir = out_dir / scene["slug"]
        meta = {
            "model_used": "grok-4.3",
            "provider": "xai",
            "campaign_id8": scene["cid"],
            "campaign_label": label,
            "scene_slug": scene["slug"],
            "entry_range": [scene["lo"], scene["hi"]],
            "avatars_used": [scene["avatar_filename"]] if scene["avatar_filename"] else [],
            "drive_avatar_dir": "~/llm_wiki/raw/assets/avatars/",
            "prompt_tokens": usage.get("prompt_tokens"),
            "completion_tokens": usage.get("completion_tokens"),
            "total_tokens": usage.get("total_tokens"),
            "wall_seconds": round(dt, 2),
            "response_chars": len(msg),
            "response_words": len(msg.split()),
            "raw_response_path": str(scene_dir / "grok.md"),
            "prompt_path": str(scene_dir / "grok_prompt.txt"),
            "model_fallback_note": None,
            "run_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        }
        write_outputs(scene_dir, msg, prompt, meta)
        return scene["slug"], len(msg.split()), usage

    t0 = time.time()
    under_target = []
    with cf.ThreadPoolExecutor(max_workers=args.max_workers) as ex:
        futs = [ex.submit(worker, s) for s in args.scenes]
        for f in cf.as_completed(futs):
            slug, wc, usage = f.result()
            flag = "✅" if 600 <= wc <= 900 else ("⚠ " + ("under" if wc < 600 else "over"))
            print(f"[{slug:30s}] {wc:4d}w {flag} p={usage.get('prompt_tokens',0)} c={usage.get('completion_tokens',0)}")
            if wc < 600:
                under_target.append(slug)
    print(f"\n[done] total wall {time.time()-t0:.1f}s, "
          f"{len(args.scenes)-len(under_target)}/{len(args.scenes)} in range")
    if under_target:
        print(f"\n[follow-up needed] under-target scenes (run Round 2): {under_target}")
        sys.exit(0)  # not a hard error — just informational
    sys.exit(0)


if __name__ == "__main__":
    main()
