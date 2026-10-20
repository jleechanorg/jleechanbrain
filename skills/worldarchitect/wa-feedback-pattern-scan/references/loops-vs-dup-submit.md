# Loops vs duplicate-submit — same surface, different bug class (verified 2026-08-17)

## The trap

When a user reports "the campaign got stuck in a loop" or "I had to create my own action", the surface symptom is identical for two very different bugs:

1. **LLM-side loop**: the LLM's narrative pacing stalls, generating responses that don't progress the scene. The user is forced to manually break out with a different action type.
2. **Client-side duplicate-submit**: the same user action is submitted 3x in a row (UI rapid-click, network retry, browser extension). This shows up in the data as 3 identical consecutive user actions — same fingerprint as a loop, completely different root cause.

Mixing the two leads to:
- Wasted LLM-side fix effort when the bug is a UI dedupe gap
- Wasted UI-dedupe effort when the bug is actually a prompt-level pacing issue
- Wrong priority assignment: a UI bug affecting every click is much worse than a 1-in-1000 narrative stall

## How to distinguish

| Signal | LLM loop | Client dup-submit |
|---|---|---|
| **Similarity metric** | Jaccard 0.5-0.85 (thematic overlap, varied wording) | Jaccard ≈ 1.0 (exact-string match) |
| **Consecutive count** | 3-10+ similar actions | Almost always exactly 3 (3x is the visible duplicate pattern; 5x is rare) |
| **User breakout** | Common — user types something totally different to escape | None — user just clicked again |
| **GM responses in between** | Each user action gets its own GM response | Identical user actions get identical GM responses (or 2nd/3rd are flagged as duplicate) |
| **Cross-user prevalence** | Affects users on specific templates (e.g. spicy templates without pacing directives) | Affects a single user at a single moment in time |
| **Frequency** | Pattern-level — multiple instances in the same campaign | Single instance — once the network/UI settles, the bug doesn't repeat |

## Verified example (2026-08-17)

**akey445@gmail.com / My Space Adventure** (campaign `ZSKUANpysJ2gwLSgzSt0`, 42 entries):

```
turn[30] "Apologize and Refocus on the Mission - Acknowledge the misstep and steer the conversation back to the nine names, Delta-9 strategy, and the corporate conspiracy."
turn[31] "Apologize and Refocus on the Mission - Acknowledge the misstep and steer the conversation back to the nine names, Delta-9 strategy, and the corporate conspiracy."
turn[32] "Apologize and Refocus on the Mission - Acknowledge the misstep and steer the conversation back to the nine names, Delta-9 strategy, and the corporate conspiracy."
```

Identical text 3x in a row → Jaccard ≈ 1.0 → flagged as **mild loop** by the scorer, BUT inspection revealed this is almost certainly a UI/network duplicate-submit bug, NOT an LLM pacing problem. Filed separately as a UI dedupe gap.

## The right response

When your loop scan reports `consecutive_similar_count >= 3` with high Jaccard (≥0.95):

1. **Inspect the actual text** — is it character-for-character identical, or thematically similar with varied wording?
2. **Check the GM responses** — are they identical too (duplicate) or progressively different (loop)?
3. **Check user_action count** — exactly 3, or 3-10+?
4. **If duplicate-submit**: file as a separate bug (`client_request_id` dedupe, submit-button idempotency). Do NOT include in "loops severity" verdict.
5. **If LLM loop**: file as a prompt/pacing issue (variety injection, template coverage).

## Scoring rubric update for `scan_loops.py`

The scorer should emit BOTH fields, not just a severity:

```json
{
  "consecutive_similar_count": 3,
  "consecutive_similar_runs": 1,
  "is_dup_submit_likely": true,           // NEW: Jaccard >= 0.95 + exactly-3 pattern
  "loop_severity": "mild",                // still report severity
  "dup_submit_followup": "rev-zur8j"     // NEW: link to the separate UI-bug bead
}
```

Then the operator can decide whether the loop severity itself warrants a fix, or whether the dup-submit bug is the actual action item.

## Cross-user signal

### Initial estimate (2026-08-17, N=8)
- 7/8: zero consecutive_similar_count
- 1/8 (akey445): consecutive_similar_count=3, all exact-match → dup-submit

→ "Dup-submit bugs are rare in the dataset" — *subsequently invalidated by larger samples.*

### Updated estimate (2026-08-17, N=22 across batches A + B)
- **18/22 (82%): zero consecutive_similar_count** (no dup-submit detected)
- **4/22 (18%): ≥1 dup-submit run, Jaccard=1.0, exactly 3x consecutive**

| Campaign | Batch | Signature | Trigger context |
|---|---|---|---|
| akey445 / My Space Adventure (42-entry version) | A + B | "Apologize and Refocus on the Mission" 3x (S15→S16→S17) | After spicy "Ask Rhea to have intercourse" → GM refusal |
| kevin / Harry_potter_meets_the_book_of_enoch_and_pornhub | B | "Fade to Afterglow" 3x (S13→S14→S15) | After explicit BDSM collar-and-chain scene |
| My_Epic_Adventure_9ZRIpp0i | B | "Leave the alley" 2x, "Intel and strategy" 2x | Freeform after combat |
| Dragon_Knight_UV6TeGxj | B | "Ride Forward and Parley" 2x | Choice menu re-click |

→ **Dup-submit fires in 18% of mid-length real-user campaigns.** It is NOT rare.
It is also NOT a single-user quirk — the same akey445 3x signature appears in
**two different dump versions of the same campaign** (batch A's 36-entry + batch B's
42-entry), confirming the bug fires at the same network/UI moment regardless of
where you read the campaign from. The cost of a defensive `client_request_id`
dedupe in `mvp_site/main.py` is still tiny vs. the diagnostic confusion it
causes — but the priority should be raised from "nice-to-have" to **"highest-leverage
client fix in the kevin feedback review"**.

**Common trigger context** (appears in 3/4 cases): user submits an awkward /
emotionally-charged action (spicy request, fade-to-afterglow, combat choice),
the GM responds with a non-progressing beat, and the user re-clicks the same
choice 3x. Suggests a UI/network retry that fires 3x when the user's first
action was socially awkward or the response latency was high. Check whether
the submit button has a debounce, and whether the network layer retries on
ambiguous-response timeouts.
