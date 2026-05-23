# Nextsteps: Long-Running Harness Design (2026-05-02)

## Table of Contents
1. [Executive Summary](#executive-summary)
2. [Source Article Analysis](#source-article-analysis)
3. [Architecture Overview](#architecture-overview)
4. [Agent Roles & Responsibilities](#agent-roles--responsibilities)
5. [Contract-Gated Verification Loop (cherry-picked from superteam)](#contract-gated-verification-loop-cherry-picked-from-superteam)
6. [Handoff Artifacts](#handoff-artifacts)
7. [Context Management (Context Resets)](#context-management)
8. [Advisor Strategy Integration](#advisor-strategy-integration)
9. [Boris-Style Planning Pipeline](#boris-style-planning-pipeline)
10. [Claude Code Implementation (Teams + /goal)](#claude-code-implementation-teams--goal)
11. [Implementation Phases](#implementation-phases)
12. [Gap Analysis: What Exists vs What's Needed](#gap-analysis-what-exists-vs-whats-needed)
13. [New Findings (2026-05-15 Research)](#new-findings-2026-05-15-research)

---

## Executive Summary

**Goal**: Build a long-running autonomous coding harness that combines three proven approaches into one coherent system:

1. **Anthropic Advisor Strategy** — Opus as advisor, Haiku/Sonnet as executor (near-Opus intelligence at ~Sonnet cost)
2. **Anthropic Harness Engineering** — Planner/Generator/Evaluator three-agent GAN-style loop with context resets
3. **Boris's Workflow** — Research → Plan → Annotate → Todo → Implement (human judgment at planning)

**Target behavior**: Fully autonomous multi-hour coding sessions that produce complete, tested, reviewable PRs without human intervention, using cost-efficient model combinations with evaluator-gated quality.

**Status**: All three source approaches analyzed. AO has many building blocks (skeptic=evaluator, decomposer=planner, workspace-worktree=context). Missing: Advisor orchestration layer, structured handoff artifacts, context reset trigger logic.

---

## Source Article Analysis

### 1. Anthropic Advisor Strategy (claude.com/blog/the-advisor-strategy)

**Core insight**: Pair Opus as advisor with Sonnet/Haiku as executor.
- Executor (Sonnet/Haiku) runs task end-to-end, calls tools, iterates
- When executor hits a hard decision, it consults Opus for guidance
- Result: near-Opus quality at Sonnet cost
- Key mechanism: executor explicitly invokes advisor tool when stuck

**What it gives us**:
- Cost efficiency: Haiku/Sonnet do the bulk of work; Opus only for decisions
- Quality preservation: Opus-level judgment available on-demand
- Simple mental model: two roles, clear handoff points

### 2. Anthropic Harness Engineering (anthropic.com/engineering/harness-design-long-running-apps)

**Core insight**: Three-agent GAN architecture — planner, generator, evaluator.
- **Context resets** (not just compaction) solve context anxiety and coherence loss
- **Evaluator must be external** (not self-evaluation) — agents are biased toward praising their own work
- **Structured handoff artifacts** carry state between context resets
- **Grading criteria** turn subjective quality into gradable terms

**Architecture**:
```
Planner → [Handoff Artifact] → Generator → [Output] → Evaluator
                ↑                                            │
                └──────── [Critique] ───────────────────────┘
```

**Context reset rule**: When context window hits threshold, reset executor with handoff artifact. Not compaction — clean slate.

**Evaluator tuning**: Few-shot examples with score breakdowns calibrate evaluator to human preferences.

**What it gives us**:
- GAN-style iteration loop
- Context reset protocol
- Evaluator-gated quality (skeptic is the evaluator)
- Grading criteria for code quality

### 3. Boris's Workflow (boristane.com/blog/how-i-use-claude-code)

**Core insight**: Never let agent write code until human approves written plan.
- **Research first**: deep-read to `research.md` — surface-level reading is unacceptable
- **Plan.md**: detailed implementation plan with code snippets, file paths, trade-offs
- **Annotation cycle**: human annotates plan.md with inline corrections, agent revises
- **Todo list**: granular task breakdown from plan, tracked in plan.md
- **"Implement it all"**: only after human approval, with typecheck and no stopping
- **Feedback during implementation**: terse corrections, screenshots for visual issues
- **Scope protection**: revert + narrow rather than patch bad approaches

**Key phrases that matter**:
- "deeply", "in great details", "intricacies" — signals unacceptable to skim
- "write a detailed report" — persistent artifact, not verbal
- "don't implement yet" — essential guard
- "implement it all, do not stop until all tasks completed"

**What it gives us**:
- Research artifact requirement
- Plan annotation with inline corrections
- Human judgment at planning phase (not at implementation)
- Todo-driven execution with progress tracking

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│                     LONG-RUNNING HARNESS                            │
│                                                                     │
│  ┌──────────┐    ┌─────────────┐    ┌─────────────┐    ┌─────────┐ │
│  │ RESEARCH │───▶│   PLANNER   │───▶│  GENERATOR  │───▶│EVALUATOR│ │
│  │  Agent   │    │   (Opus)    │    │(Sonnet/H6)  │    │(Skeptic)│ │
│  │ (Sonnet) │    │  Advisor    │    │             │    │         │ │
│  └──────────┘    └─────────────┘    └─────────────┘    └─────────┘ │
│       │              │                   │                  │     │
│       ▼              ▼                   ▼                  ▼     │
│  research.md    plan.md +          code + tests       VERDICT     │
│                 annotated_plan.md                            │     │
│                      │                                        │     │
│              [Human Review] ◀────────────────────────────────┘     │
│              (if configured)                                        │
│                      │                                               │
│                      ▼                                               │
│              ┌─────────────┐                                        │
│              │CONTEXT RESET│ (when window threshold hit)           │
│              │  + HANDOFF  │                                        │
│              └─────────────┘                                        │
└─────────────────────────────────────────────────────────────────────┘
```

### Agent Model Assignments

| Role | Model | Rationale |
|------|-------|-----------|
| Research Agent | Sonnet-4.5 | Fast exploration, broad codebase reading |
| Planner (Advisor) | Claude Opus | Complex architectural decisions, tradeoff analysis |
| Generator | Haiku-4 | Cost-efficient implementation, high throughput |
| Evaluator | Sonnet-4.5 | Skeptic-style critique, detailed feedback |

**Advisor Strategy variant**: Use Opus as Planner/Advisor (decisions only) and Haiku as Generator (bulk work). Sonnet for Research (fast, broad) and Evaluator (skeptic).

---

## Agent Roles & Responsibilities

### Research Agent (Sonnet)
- Deep-read relevant codebase sections
- Write findings to `research.md`
- Identify constraints, existing patterns, potential bugs
- **Output**: `research.md` artifact

### Planner / Advisor (Opus)
- Read `research.md`
- Produce detailed `plan.md`:
  - Feature name and description
  - Code snippets showing approach
  - File paths to modify
  - Trade-offs and alternatives considered
- If human-in-loop: wait for annotation cycle
- If autonomous: self-annotate and revise
- **Output**: `plan.md` artifact (possibly annotated)

### Generator (Haiku/Sonnet)
- Read approved `plan.md` + `research.md`
- Execute plan.md todo list item by item
- Mark items complete in plan.md as done
- Run typecheck continuously
- **Output**: implemented code + test files

### Evaluator (Skeptic/Sonnet)
- Read generated code + tests + original plan
- Score against grading criteria (see below)
- Write detailed critique
- Gate: PASS → proceed to PR, FAIL → iterate with critique
- **Output**: VERDICT (PASS/FAIL with markers)

### Grading Criteria (for Evaluator)

From Anthropic harness engineering, adapted for code:

| Criterion | Question | Weight |
|-----------|----------|--------|
| Correctness | Does it solve the problem as specified? | 30% |
| Tests | Does it have passing tests that prove the behavior? | 25% |
| Code Quality | Is the code clean, typed, no `any`/`@ts-ignore`? | 20% |
| Alignment | Does it follow the tenets/goals from the plan? | 15% |
| Safety | No injection risks, credential exposure, or regression? | 10% |

---

## Contract-Gated Verification Loop (cherry-picked from superteam)

Superteam's key architectural insight: **contract gates** between phases prevent cascade failures in multi-hour autonomous runs. A contract is an explicit, machine-checkable criteria block that must PASS before the harness transitions to the next phase.

### What a Contract Gate Looks Like

```
Phase N output → [CONTRACT GATE] → Phase N+1
                         │
                    PASS ✓ → proceed
                    FAIL ✗ → return output + critique to Phase N
```

### Contract Schema

Each gate is a small set of concrete checks, not vague criteria:

```
Gate: <phase boundary name>
Checks:
  [ ] <check 1> — verifiable condition (e.g., "file X exists at path Y")
  [ ] <check 2> — verifiable condition (e.g., "pytest X passes")
  [ ] <check 3> — verifiable condition (e.g., "no TODO markers in new code")
Pass threshold: all | N of M
On fail: return to <phase> with <critique artifact>
Max retries: 2
```

### Contract Gate Points in This Harness

| Gate | From | To | Key Checks |
|------|------|----|-----------|
| G1 | Research | Plan | research.md exists, covers all task areas, identifies constraints |
| G2 | Plan | Implement | plan.md approved, todos enumerated, grading criteria set |
| G3 | Implement | Evaluate | All todos marked complete, typecheck passes, tests pass |
| G4 | Evaluate | PR (or iterate) | VERDICT: PASS with all grading criteria met |

### Retry Budget

| Gate | Max retries | Escalation |
|------|-----------|------------|
| G1 | 1 | Escalate to human |
| G2 | 2 | Escalate to human |
| G3 | 3 | Advisor consultation (Opus) |
| G4 | 3 | Advisor consultation (Opus) |

### Why Contract Gates Matter

- **Structural vs ask-nicely**: Most harnesses ask agents to "be thorough." Contract gates enforce it — a phase cannot proceed until its gate passes.
- **Cascade prevention**: A bad plan (caught at G2) prevents wasted implementation. Bad code (caught at G3) prevents wasted evaluation.
- **Autonomous PR quality**: G4 directly feeds into the existing Skeptic evaluator — the contract is the handoff contract between generator and skeptic.

### Comparison: Superteam vs This Harness

| Aspect | Superteam (7 roles, 5 phases) | This Harness (3 roles, 4 gates) |
|--------|-------------------------------|---------------------------------|
| Role count | 7 outer-loop roles | 3 mandatory + optional extras |
| Phase structure | 5 named orchestration phases | 4 contract-gated transitions |
| Role flexibility | Fixed role topology | Mandatory: Orchestrator, Advisor, Worker. Claude Code adds extras dynamically |
| Contract enforcement | Task-form driven inner-loop | Lightweight checklists in gate schema |
| Exit prevention | Structural anti-premature-exit | Contract-gated retry with escalation |
| Complexity | High (framework-level) | Low (pattern-level, composable) |

---

## Handoff Artifacts

Each phase produces a persistent markdown artifact that survives context resets:

### `research.md`
```markdown
# Research: <feature name>

## Date
<timestamp>

## Codebase Understanding
<findings from deep-read>

## Constraints
<existing patterns, conventions, limitations>

## Potential Issues
<bugs found, risky areas>

## References
<files studied, relevant code snippets>
```

### `plan.md`
```markdown
# Plan: <feature name>

## Overview
<what we're building and why>

## Approach
<code snippets, file paths, trade-offs>

## Todo List
- [ ] Task 1
- [ ] Task 2

## Grading Criteria
<what "done" looks like>

##open questions
<things to decide>
```

### Annotated `plan.md` (post-annotation)
Same as plan.md but with human/agent inline annotations:
```markdown
## Approach
Use drizzle:generate for migrations, not raw SQL  [[HUMAN: domain knowledge]]

- [ ] Add migration file [[AGENT: note about ordering constraint]]
```

### Handoff Artifact (for context reset)
```markdown
# Handoff: <feature name>

## Session Resume Point
<last completed todo item>

## Next Steps
<remaining todo items>

## Current State
<what's been built so far>

##open issues
<known problems, evaluator critiques not yet addressed>

## Context Notes
<anything the next agent needs to know that won't be in the code>
```

---

## Context Management

### Context Reset Trigger
- **Threshold**: 70% of context window consumed
- **Trigger**: Evaluator flags context anxiety OR explicit token budget warning
- **Not** compaction — full reset with handoff artifact

### Reset Protocol
1. Generator signals it cannot continue cleanly (or threshold hit)
2. Write handoff artifact to `handoff.md` with current state
3. Start fresh Generator agent with:
   - `plan.md` (full plan + todo list)
   - `research.md` (original research)
   - `handoff.md` (current state + resume point)
4. Generator resumes from last incomplete todo item
5. Evaluation continues from where it left off (or re-evaluates if needed)

### Compaction vs Reset
| | Compaction | Context Reset |
|--|-----------|---------------|
| What | Summarize history in place | Clear + reload from artifacts |
| Agent | Same agent continues | Fresh agent picks up |
| Context anxiety | Can persist | Eliminated |
| Complexity | Lower | Higher |
| When to use | Mid-session, <70% window | Threshold hit or evaluator requests |

---

## Advisor Strategy Integration

### When the Generator Calls Advisor (Opus)

Generator calls Opus advisor when hitting:
1. Architectural decision with no clear answer in plan
2. Cross-cutting concern not covered in research
3. evaluator critique that requires judgment call
4. Two feasible approaches with trade-offs

### Advisor Request Format
```
ADVISOR REQUEST:
Context: <current situation>
Options considered: <option A vs option B>
Risk: <what could go wrong with each>
Question: <what should we do and why>
```

### Advisor Response Format
```
ADVISOR RESPONSE:
Decision: <pick option or propose third>
Reasoning: <why this is the right call>
Trade-off accepted: <what we're giving up>
Next step: <concrete action>
```

### Advisor Budget
- Max 3 advisor calls per todo item
- Max 10 advisor calls per feature
- Prevents over-reliance on Opus (preserves cost efficiency)

---

## Boris-Style Planning Pipeline

### Phase 1: Research (Generator = Sonnet)
```
Read this folder in depth, understand how it works deeply, what it does and all its specificities.
When that's done, write a detailed report of your learnings and findings in research.md.
```

### Phase 2: Plan (Planner/Advisor = Opus)
```
Based on research.md, write a detailed plan.md explaining how to implement <feature>.
Include code snippets, file paths, trade-offs considered.
```

### Phase 3: Annotate (Human or Agent self-annotation)
- If human-in-loop: human adds inline notes to plan.md
- If autonomous: agent self-reviews and annotates
- Guard: "don't implement yet"

### Phase 4: Todo List
```
Add a detailed todo list to plan.md with all phases and individual tasks necessary.
Do not implement yet.
```

### Phase 5: Implement (Generator = Haiku)
```
Implement it all. When done with a task or phase, mark it as completed in plan.md.
Do not stop until all tasks and phases are completed.
Do not add unnecessary comments or jsdocs.
Do not use any or unknown types.
Continuously run typecheck to make sure you're not introducing new issues.
```

### Phase 6: Evaluate (Evaluator = Skeptic/Sonnet)
Skeptic evaluates generated code + plan.md + research.md

---

## Claude Code Implementation (Teams + /goal)

This section describes how to implement this harness specifically using **Claude Code** as the agent runtime. Claude Code has two native features that map directly to harness needs: **Agent Teams** (multi-agent orchestration) and the **`/goal` command** (autonomous "run until done" mode).

### Role Structure: Mandatory + Optional

**3 mandatory roles** (the harness cannot run without these):

| Role | Mandatory? | Maps to Harness Role | Model |
|------|-----------|---------------------|-------|
| **Lead/Orchestrator** | ✅ Mandatory | Planner + dispatcher | Sonnet (cheap, fast orchestration) |
| **Advisor/Reviewer** | ✅ Mandatory | Evaluator / contract gate checker | Opus (expensive, on-demand only) |
| **Worker** | ✅ Mandatory | Generator / executor | Haiku or Sonnet (bulk work) |

**Optional teammates** (Claude Code's lead decides dynamically):
- Researcher (codebase deep-read → research.md)
- Tester (dedicated test writing)
- QA / Bug hunter (exploratory testing)
- Documenter (docs generation)
- Reviewer (second-pass code review)
- Refactorer (cleanup pass)
- Any other role the task needs — live free

**Rule**: The lead/orchestrator role cannot be delegated. It must stay with the top-level session. Advisor/Worker can be subagents or teammates.

### How Agent Teams Maps to This Harness

Claude Code Agent Teams is configured via `.claude/agents/` directory (subagent definitions referenced by teammates):

```
.claude/agents/
├── orchestrator.md     # mandatory — the lead
├── advisor.md          # mandatory — Opus-powered reviewer
├── worker.md           # mandatory — executor
├── researcher.md       # optional — deep codebase read
├── tester.md           # optional — test coverage specialist
└── ...                 # any additional roles
```

**Mandatory vs optional enforcement**: The agents directory MUST contain orchestrator.md, advisor.md, and worker.md. All other role files are optional — Claude Code's lead agent decides at runtime whether to spin them up as teammates based on the task.

### The /goal Command as Harness Persistence

The `**/goal**` command (Claude Code v2.1.139+) is the native "run until done" mode:

```
/goal Implement feature X across files A, B, C with passing tests
```

**How it maps to harness concepts:**

| Harness Concept | /goal Equivalent |
|----------------|-----------------|
| Completion condition | The goal text itself — a small fast model checks it each turn |
| Context reset | /goal survives compaction and resume — goal persists |
| Autonomous execution | No human prompting needed between turns |
| Progress tracking | Lead agent checks contract gates each cycle |

**In practice**: Set `/goal` at the top level with the completion condition. The lead/orchestrator spawns subagents as needed. After each sub-task completes, the advisor evaluates output against contract gates. Loop continues until `/goal` condition is met.

### Team Prompt Pattern

When spawning the Claude Code team, the lead should receive:

```
/goal <completion condition>

## Mandatory Roles
You are the Orchestrator. You have these teammates available:
  - Advisor (Opus) — call for contract gate evaluation and hard decisions
  - Worker — executes implementation tasks

You may recruit additional teammates (Researcher, Tester, etc.) if the task benefits.

## Harness Protocol
1. For each sub-task: Worker implements → Advisor evaluates against contract gate
2. All gates must PASS before advancing to next phase
3. Use structured artifacts (research.md, plan.md, handoff.md) between phases
4. Escalate to Advisor when: architectural decisions, contract gate failures, trade-off calls
5. If a gate fails after max retries: report the state to the user and stop
```

### Claude Code Specifics

- **Enable teams**: `export CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`
- **Start with team**: Ask Claude Code to create a team naturally (e.g., "Create a team with an orchestrator, advisor, and worker") — teammates are spawned via the Agent tool and discover reusable role definitions from `.claude/agents/`
- **Goal persists**: Even across context compactions or session resumes
- **Subagents vs teams**: Use Agent Teams for the outer harness loop (orchestrator + advisor + worker roles). Use subagents for inner tasks each teammate dispatches (cheap, focused, single-shot function calls).
- **Lead session**: The top-level Claude Code session IS the orchestrator. It holds the /goal and manages the team.

---

## Implementation Phases

### Phase 0: Build Existing AO Components (foundation)
**Owner**: Existing AO
- [x] Skeptic evaluator (skeptic.ts)
- [x] Decomposer/planner (decomposer.ts)
- [x] Workspace/worktree management
- [x] Lifecycle manager with context awareness
- [ ] **NEW**: Handoff artifact schema and writer
- [ ] **NEW**: Context reset trigger logic

### Phase 1: Advisor Orchestration
**Owner**: New plugin or core enhancement
- [ ] `advisor.ts` — handles advisor request/response protocol
- [ ] Model picker for advisor vs executor roles
- [ ] Advisor budget tracking per feature
- [ ] Advisor budget enforcement (max calls gate)

### Phase 2: Context Reset Protocol
**Owner**: Lifecycle manager enhancement
- [ ] Context threshold detection (70% window)
- [ ] Handoff artifact writer
- [ ] Fresh agent restart with artifact reload
- [ ] Reset counter + budget (max N resets per session)

### Phase 3: Artifact Management
**Owner**: Workspace plugin enhancement
- [ ] `research.md` writer/reader
- [ ] `plan.md` writer/reader with annotation support
- [ ] `handoff.md` schema and lifecycle
- [ ] Artifact versioning across resets

### Phase 4: GAN-Style Iteration Loop
**Owner**: Skeptic + lifecycle integration
- [ ] Iterate until evaluator PASS (with max iteration budget)
- [ ] Pass evaluator critique back to generator
- [ ] Track iteration count per feature

### Phase 5: Human-in-Loop (optional mode)
**Owner**: Configuration
- [ ] Plan approval gate (pause before implementation)
- [ ] Annotation support in plan.md
- [ ] "Don't implement yet" guard

### Phase 6: Claude Code Team Setup (standalone)
**Owner**: Configuration / team-roles
- [ ] Create `.claude/team-roles/orchestrator.md` — the lead session role
- [ ] Create `.claude/team-roles/advisor.md` — Opus-powered contract gate evaluator
- [ ] Create `.claude/team-roles/worker.md` — executor subagent
- [ ] Create optional role templates (researcher, tester, etc.)
- [ ] Harness prompt template that sets `/goal` + mandatory roles + protocol
- [ ] Contract gate checklists embedded in advisor role definition
- [ ] Export `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` in startup script

---

## New Findings (2026-05-15 Research)

### Default-FAIL Evidence Contract (from Anthropic `cwc-long-running-agents`)

Each contract gate now requires **verifiable evidence** — not just a claim. Default state = FAIL. Agent must flip to PASS with proof.

| Gate | Evidence Required to PASS |
|------|--------------------------|
| G1: Requirements clear | `requirements.md` written, no TBD items |
| G2: Plan actionable | `plan.md` has file paths + code snippets |
| G3: Tests pass | `pytest` / `pnpm test` exit code 0 in terminal output |
| G4: Evaluator PASS | Evaluator posted PASS with diff summary |

### Fresh-Context Evaluator (from Anthropic `cwc-long-running-agents`)

A **read-only** agent (no Write/Edit tools) that grades work from a fresh context window. Eliminates "I built this so it must be good" bias. This is structurally different from Advisor (Opus, consultative) — Evaluator is pure verification.

- New role: `.claude/team-roles/evaluator.md`
- Tools: Read, Grep, Glob, Bash (for running tests) — **no Write/Edit**
- Triggered by Orchestrator at G4

### Initializer Agent (from Anthropic "Effective Harnesses" Nov 2025)

The very first context window uses a **specialized prompt** that sets up the environment — NOT plan features. Creates:
- `init.sh` — project-specific setup (deps, env, build)
- `features.json` — granular feature list, all `status: failing` by default
- `PROGRESS.md` — rolling log of what each session accomplished
- Initial git commit showing scaffold

This is a new **Phase 0.5** between "start" and "research" in the Boris pipeline.

### Context Anxiety Headroom Reminder (from agentic-patterns.com)

At 70%+ context usage, inject: "You have significant headroom remaining. Continue working thoroughly — do not rush or wrap up early." This is a prompt engineering fix against Anthropic-documented "context anxiety" behavior.

### Automatic Handoff via Stop Hook (from Anthropic `cwc-long-running-agents`)

A Claude Code `Stop` hook that:
1. Writes current progress to `PROGRESS.md`
2. Stashes or commits uncommitted changes
3. Updates `features.json` with completed items

Ensures no work lost even on unexpected session termination.

### Tool Minimization (from Vercel d0 case study)

Vercel cut tools from 15 → 3 and accuracy went 83% → 95%. Apply:
- **Worker**: Bash, Read, Write, Grep, Glob (5 tools). No web/MCP/browser.
- **Researcher**: Read, Grep, Glob, WebSearch (4 tools). No Write.
- **Evaluator**: Read, Grep, Glob, Bash (4 tools). No Write/Edit.
- **Advisor**: Full tools (flexibility for judgment calls).

### Harness Verb-Commands (from Chachamaru `claude-code-harness`)

5 slash commands mapping to harness phases:
- `/harness-setup` → Phase 0.5 (initialize scaffold)
- `/harness-plan` → Phase 1-2 (research + plan)
- `/harness-work` → Phase 3 (implement)
- `/harness-review` → Phase 4 (evaluate)
- `/harness-release` → Phase 5 (PR/merge)

### Tunable Harness Config (from Anthropic "Managed Agents" Apr 2026)

Harnesses encode assumptions that go stale as models improve. Make gate params tunable:
- Gate retry budgets: config, not hardcoded
- Model assignments: config, not baked into role files
- Context threshold: env var, not hardcoded 70%

---

## Gap Analysis: What Exists vs What's Needed

### Exists in AO Today

| Component | Location | Status |
|-----------|----------|--------|
| Evaluator (Skeptic) | `fork-skeptic-extension.ts`, `skeptic.ts` | ✅ Works |
| Decomposer/Planner | `decomposer.ts` | ✅ Works |
| Workspace management | `workspace-worktree/` | ✅ Works |
| Lifecycle manager | `fork-lifecycle-manager.ts` | ✅ Works |
| Context awareness | `config.ts` | ✅ Partial |
| Failure budget | `failure-budget.ts` | ✅ Works |
| Agent selection | `agent-selection.ts` | ✅ Partial |
| Minimax plugin | `agent-minimax/` | ✅ Fixed |
| PR workflow | `scm-github/` | ✅ Works |

### Missing / Needs Enhancement

| Component | Gap | Effort |
|-----------|-----|--------|
| **Advisor orchestration** | No Opus-as-advisor layer; generator can't call for decisions | Medium |
| **Handoff artifacts** | No `research.md`/`plan.md`/`handoff.md` schema and lifecycle | Medium |
| **Context reset trigger** | Lifecycle doesn't detect 70% threshold and reset | Small |
| **GAN iteration loop** | Skeptic → generator iteration not wired; no max-iter budget | Medium |
| **Advisor budget** | No tracking/enforcement of max advisor calls | Small |
| **Human-in-loop mode** | No plan approval gate; annotation support missing | Medium |
| **Research phase** | No deep-read → `research.md` artifact step | Small |
| **Generator model** | AO defaults to Sonnet; Haiku for cost efficiency not configurable | Small |
| **Contract gates** | No explicit contract gate schema or lifecycle between phases | Small |
| **Claude Code team-roles** | No `.claude/team-roles/` directory with orchestrator/advisor/worker | Small |
| **Claude Code /goal prompt** | No standard harness prompt template for `/goal` + roles + protocol | Small |
| **Default-FAIL evidence** | Gates lack verifiable evidence requirements — agent can claim PASS without proof | Small |
| **Fresh-context evaluator** | No read-only evaluator role — advisor has Write/Edit tools, shares context with worker | Small |
| **Initializer pattern** | No Phase 0.5 scaffold setup (init.sh, features.json, PROGRESS.md) | Small |
| **Context anxiety headroom** | No prompt-based reminder at 70% to prevent premature completion | Small |
| **Auto-handoff stop hook** | No Claude Code Stop hook to persist progress on session termination | Small |
| **Tool minimization** | Workers get full tool suite — no restriction to 5 core tools | Small |
| **Harness verb-commands** | No `/harness-{setup,plan,work,review,release}` slash commands | Small |
| **Tunable gate params** | Retry budgets, model assignments, context threshold hardcoded | Small |

### Priority Order

1. **Phase 0 + Context reset trigger** (small, high value) — foundation
2. **Phase 6 (Claude Code team-roles)** (small) — standalone Claude Code harness, works independently
3. **Default-FAIL evidence + Fresh-context evaluator** (small) — quality gate integrity
4. **Tool minimization** (small) — worker/researcher tool restrictions for accuracy
5. **Initializer pattern** (small) — Phase 0.5 scaffold setup
6. **Context anxiety headroom** (small) — prompt engineering fix
7. **Auto-handoff stop hook** (small) — prevent work loss
8. **Phase 3 (Artifact management)** (medium) — enables everything else
9. **Phase 1 (Advisor orchestration)** (medium) — key differentiator
10. **Phase 4 (GAN loop)** (medium) — quality gate automation
11. **Phase 2 (Reset protocol)** (medium) — depends on Phase 3
12. **Harness verb-commands** (medium) — slash command UX
13. **Tunable gate params** (small) — future-proofing
14. **Phase 5 (Human-in-loop)** (medium) — optional, config flag

---

## Appendix: Key Design Decisions

### Q: Why not use Claude Agent SDK like Anthropic did?
**A**: AO already has robust orchestration, lifecycle management, and Slack integration. Building on AO infrastructure (fork-lifecycle-manager, workspace-worktree) is more maintainable than introducing a parallel SDK.

### Q: Why Haiku for generator instead of Sonnet?
**A**: Advisor strategy means Opus handles decisions; Haiku does execution. Haiku-4 is faster and cheaper for implementation. Sonnet reserved for Research (broad reading) and Evaluator (complex critique).

### Q: How does this differ from the existing decomposer?
**A**: Decomposer breaks tasks into subtasks (planner→worker). This harness adds: evaluator gate between generator and PR, context resets, advisor calls, and structured artifact pipeline (research→plan→annotate→implement→evaluate).

### Q: What triggers a context reset vs compaction?
**A**: Reset when: (a) 70% window threshold, (b) evaluator requests it, (c) generator signals confusion. Compaction happens naturally as AO manages context window.

### Q: How is cost managed across advisor + generator + evaluator?
**A**: Advisor budget (max 10 calls/feature) caps Opus usage. Generator uses Haiku (low cost). Evaluator runs once per iteration cycle. Max iteration budget (e.g., 5 iterations) caps total spend.
