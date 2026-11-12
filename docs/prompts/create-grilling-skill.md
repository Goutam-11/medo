# Prompt — create the `project-grilling` skill

Copy everything below the line into a **fresh agent session**. It is self-contained: the
new session does not see the conversation that produced it.

---

## Task

Create a reusable DSH skill named **`project-grilling`** that turns a vague product idea into
locked decisions and a build blueprint through adversarial multiple-choice interrogation.

Write it to `~/.agents/skills/project-grilling/SKILL.md`. First inspect two or three existing
skills in that directory (`~/.agents/skills/minimal-first-development/SKILL.md`,
`~/.agents/skills/impeccable/SKILL.md`) and match the frontmatter shape and tone you find there.
If that path does not exist on this machine, locate the active skills root before writing
anything and report where you put it.

Also add `~/.agents/skills/project-grilling/references/question-bank.md` with reusable question
sets for common domains (CLI tool, desktop/plugin UI, web app, API service, data pipeline).

## What "grilling" means here

A grilling session is **not** a friendly interview. It is hypothesis-driven interrogation:
research the platform and the domain first, state what you found, then force the user through
concrete trade-offs in batches of multiple-choice questions until every decision that shapes the
build is locked. The output is not a chat summary — it is a decision table plus a blueprint
document committed to the repo.

The reference session that produced this prompt (medo, a Noctalia task-manager plugin) took
**four rounds of 7–8 questions**, produced **22 locked decisions**, and caught three things the
user had wrong or unknown: the shell's plugin API ceiling was 34 not 53, "Material UI" was a
React library that could not apply, and animation-based "cute" was impossible in that UI
toolkit. Those corrections came from *recon before questions*, and they are the point of the
method.

## Required behaviour to encode in the skill

### Phase 0 — Recon (no questions yet)

- Read the repo, README, configs, and any existing plan; run version/availability commands.
- Find the real platform limits (versions, API levels, dependency availability, hardware).
- Check long-term memory for prior decisions and preferences before asking anything.
- Output a short **"what I found"** brief: 4–8 bullets with hard facts and file paths.

### Phase 1 — Research (no questions yet)

- Search the web for: official docs for the platform, existing/nearby solutions, and any
  evidence-based UX or engineering research that bears on the design.
- Inspect the local ecosystem: installed plugins/extensions, sibling repos, competitor lists.
- Output a **"landscape"** note: what already exists, what none of them do, and one or two
  research findings worth stealing.
- If a finding contradicts an assumption in the user's request, say so here, before asking.

### Phase 2 — Decision rounds

- Ask with the `ask_user_question` tool. **3–5 options per question, the recommended one first,
  labelled "(Recommended)"**, each option carrying a one-sentence trade-off.
- Use `multi_select` only when the items are genuinely independent (feature bundles,
  notification types, integrations) — never for mutually exclusive choices.
- Batch **6–8 questions per round**, ordered by blast radius: platform/architecture first,
  data model second, flow third, polish and packaging last.
- Each round opens with a 3–6 line brief of new findings relevant to that round. Never re-ask
  what an earlier round already settled.
- After each round, replay the answers as a compact **locked-decisions table** (`#`, decision,
  choice) so drift is visible immediately.
- Hard stop: **at most four rounds**. If decisions remain, list them as "open micro-decisions
  the agent will take by default" and move on. Offer to continue only if the user asks.

### Phase 3 — Lock and draw the line

- Any option the user picks that is technically impossible must be flagged in the same round
  with the corrected option — do not silently implement something different.
- Where research suggests the user's stated flow will fail (e.g. silent rollover creating a
  rotting backlog), present the risk with the alternative as a recommended option, not as a
  lecture.
- The decision table is the contract. Later changes amend it in a PR with a reason.

### Phase 4 — Blueprint document

Write `<repo>/docs/DESIGN.md` with:

1. one-line product statement and a decision table with every locked answer,
2. platform constraints discovered in recon, with API/version numbers,
3. architecture (entries/modules, single-writer rule, data flow) + file layout,
4. data schema(s) with a real example object,
5. the core flows as ordered sequences (day rollover, triage, notifications, reports),
6. scoring/business rules as formulas, not adjectives,
7. UI spec with ASCII wireframes and real copy examples,
8. risks table with mitigations,
9. phased build plan with a testable acceptance criterion per phase,
10. open micro-decisions with the default the agent will take.

Commit it with a Conventional Commit (`docs: add <project> design blueprint`) on a branch and
open a PR if the repo's flow requires it.

## Question-quality bar (encode as a checklist the skill enforces)

- Every question has a recommended option and a stated cost.
- No question whose answer is discoverable from the repo, the docs, or a version command.
- No question that is a disguised feature list — split it.
- No more than one question per dimension per round (don't ask "tabs" and "tab order" together).
- Options must be concrete: name the mechanism, not the vibe ("auto-size panel with max height",
  not "responsive layout").
- Personality, tone, packaging, backup/ownership get their own round — they are the questions
  agents skip and users regret.
- The word "efficiency", "performance", "cute", "simple" is never accepted as a requirement
  until it is quantified or exemplified.

## Skills to read before writing

Check the Skills catalog for overlap (`impeccable`, `minimal-first-development`, `design`,
`ui-ux-pro-max`). The new skill must not duplicate them: it is about **requirements
interrogation and decision locking**, and it should delegate visual work to `impeccable`/`design`
and implementation minimalism to `minimal-first-development` by name.

## Validation (do all three, report the results)

1. **Load test** — start a fresh session, invoke the skill via the `skill` tool, and confirm it
   loads with no missing references.
2. **Trigger test** — confirm the frontmatter description fires on: "grill me on X", "interrogate
   my requirements", "plan this before we build", "I want to build X, ask me questions".
3. **Dry run** — run the skill on a toy idea (e.g. "a CLI bookmark manager") for one round only,
   with three questions, and check the questions meet the quality bar above. Report the three
   questions verbatim.

## Deliverables

- `~/.agents/skills/project-grilling/SKILL.md` (frontmatter `name`, `description`; body with
  When to use / Non-goals / Process / Question rules / Output contract / Anti-patterns /
  Worked example / Validation checklist)
- `~/.agents/skills/project-grilling/references/question-bank.md`
- A short report: where the skill lives, the three validation results, and any overlap you
  removed.

## Constraints

- Keep `SKILL.md` under ~200 lines; push detail into `references/`.
- The description line must name the trigger phrases and stay under ~300 characters.
- Do not invent platform facts; cite versions you actually checked.
- Do not create the skill in more than one location; report the canonical path.
