# Kevin vs the system-wide baseline (2026-08-17)

## Origin

A user reported a single session (kevin@kevinphan.com, "Harry potter meets the book of enoch and pornhub", 44 entries) with these complaints:

- No onboarding/quiz; user opens campaign straight into action
- User typed "throw an orgy" as 3rd action (no friction)
- "Deepen the Encounter" → similar loop pattern (had to break out manually)
- No clear win condition in early turns

The question: is kevin's experience a one-off, or system-wide?

## Method

Scanned 6 real-user campaigns with >20 story entries each (top by story count, deduped per user, excluding jleechan's UIDs/emails and test patterns). Scored each on 3 patterns (onboarding, friction, goal) using direct Firestore reads via in-process Python. Output: per-user JSON + SUMMARY.json at `/tmp/feedback_review/`.

## Scanned campaigns

| Campaign | Entries | Onboarding | Friction | Goal |
|---|---|---|---|---|
| kevinzsalleh@gmail.com / Dragon Knight Round 5 | 718 | 0 | 2 | 2 |
| hanjistevens@gmail.com / HALCYON DAYS | 384 | 1 | 2 | 2 |
| pickyourfavouritememory@gmail.com / My Epic Ballsac Dragonurphace | 234 | 0 | 2 | 2 |
| thiago.hirai@gmail.com / My Epic Adventure | 82 | 0 | 2 | 2 |
| nordicsuccubus@proton.me / Dragon Warrioress | 68 | 0 | 1 | 1 |
| mushrooming.fungus@gmail.com / Dragon Knight | 52 | 0 | 2 | 2 |

## Findings

**Onboarding/Quiz: systemically absent.**
- 5/6 = score 0 (no quiz at all)
- 1/6 = score 1 (subtle hint during CC)
- 0/6 = score 2 (explicit quiz)

This confirms kevin's "no onboarding" experience is the **modal** experience, not an outlier. The system does not ask real users what type of game they want, what experience level they have, or what content to avoid. They open the campaign and start.

**Initial friction: present once user reaches the game world.**
- 0/6 = score 0 (full compliance)
- 1/6 = score 1 (system menu friction only — nordicsuccubus never left CC)
- 5/6 = score 2 (clear in-narrative obstacles)

The nordicsuccubus case (friction=1) is informative: the only "friction" she encountered was the character-creation wizard ("Use 'X' anyway", "Edit Character", "Edit Equipment"). Once the user passes CC, the GM reliably introduces real obstacles (Prefect demanding slaughter, dragon battle setup, Vespera's cold detachment, etc.). kevin's no-friction experience is **not** the modal one — most users hit obstacles immediately.

**Win condition / goal: present.**
- 0/6 = score 0
- 1/6 = score 1 (vague hint — nordicsuccubus, still inside CC)
- 5/6 = score 2 (explicit mission with stakes)

Again, the nordicsuccubus case shows that goals get established the moment the user passes CC. kevin's no-win-condition experience is **not** the modal one. The original kevin@kevinphan.com review was on a 44-entry campaign — perhaps the goal emerged later and was missed in the early-turn review window. Or kevin's character backstory didn't seed one.

## Net read

The fix worth shipping is **onboarding/quiz**: 0/6 explicit onboarding confirms a real product gap. Friction and goals are delivered; kevin's experience there is anomalous (probably 44-entry campaign-specific). The single systemic recommendation is:

> Add a 1-2 question preference prompt before character creation starts. Examples: "what kind of story do you want?" / "any content to avoid?" / "preferred play style?". This is the one place the system's silence is hurting real users (including kevin).

## Reproducing

```bash
GOOGLE_APPLICATION_CREDENTIALS=~/serviceAccountKey.json \
WORLDAI_DEV_MODE=true \
python3 ~/.smartclaw/skills/worldarchitect/wa-feedback-pattern-scan/scripts/scan_campaigns.py
```

Outputs to `/tmp/feedback_review/SUMMARY.json` (totals) and one `<safe_email>.json` per scanned user (per-campaign detail with evidence quotes).

## Files

- `/tmp/feedback_review/SUMMARY.json`
- `/tmp/feedback_review/kevinzsalleh_gmail.com.json`
- `/tmp/feedback_review/hanjistevens_gmail.com.json`
- `/tmp/feedback_review/pickyourfavouritememory_gmail.com.json`
- `/tmp/feedback_review/thiago.hirai_gmail.com.json`
- `/tmp/feedback_review/nordicsuccubus_proton.me.json`
- `/tmp/feedback_review/mushrooming.fungus_gmail.com.json`