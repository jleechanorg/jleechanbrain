# Priority assignment rule — quick reference card

**Mapping (verified 2026-08-17 on kevin@kevinphan.com feedback review):**

| Verdict | Appearance % of scanned users | Bead priority |
|---|---|---|
| **System-wide** | ≥70% | **1** (P1 — broad reach) |
| **Template-specific** | 1-2 templates only | **2** (P2 — fix the template, not the engine) |
| **User-specific** | only the reporting user | **3** (P3 — or close as not_planned) |
| **Saturated** | ≤30% | **3** (P3 — low impact) |

**Threshold edge cases:**
- Exactly 70% → still system-wide
- Exactly 30% → still saturated

**Defensive:** unknown verdict strings raise `ValueError` — typos should not silently fall back to a default priority.

## Worked examples (2026-08-17)

| Feedback item | Scanned users showing it | Verdict | Priority |
|---|---|---|---|
| Onboarding quiz missing | 5/6 = 83% | system-wide | P1 |
| Initial friction missing | 1/6 = 17% (kevin only) | user-specific | P2 (downgraded from kevin's read) |
| Win condition missing | 1/6 = 17% (kevin only) | user-specific | P2 |
| Loops | 1/8 = 12% | user-specific | P2 |
| Readability (wall of text) | 6/6 = 100% (but all "score 0") | saturated | P3 |

Note: "friction missing" was P2 not P3 because the underlying cause was a template-coverage gap (Enochian Citadel missing first-action gating block), which is structurally close to template-specific even though only one user hit it. The classification is judgment-based — when in doubt, prefer the higher priority.