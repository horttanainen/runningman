# Runningman product and planning roadmap

Status: in progress
Last updated: 2026-08-18

This document records the intended technical direction for `runningman` and the
detailed design for Phase 1. The phase is being implemented through explicit
review gates.

Implementation status: Phase 1 Increments 1–3 and Increments 4.1–4.4 are
implemented for review. They add versioned runner-profile, evidence-ledger,
training-policy, and proposed-plan documents; deterministic baseline assessment
and schedule generation; an independent plan validator; preview/apply
compatibility; persisted input, policy, week, and workout provenance; and
explanations for proposed and applied plans. The review increment adds a
read-only progress-to-date recommendation backed by Oura Sleep and Readiness
Scores, plus the existing detailed Markdown export.

## Direction

The project should use a deterministic, evidence-backed planning engine before
introducing machine learning. A learned model may later personalize bounded
planning parameters, but it should not freely generate an unvalidated training
schedule.

The intended long-term stack is:

| Responsibility | Technology |
|---|---|
| Current CLI and planning experiments | Zig |
| Evidence-backed policy and deterministic schedule generation | Zig initially; shared Swift package later |
| iPhone, macOS, and Apple Watch applications | Swift and SwiftUI |
| HealthKit, WorkoutKit, App Intents, and Core ML | Swift |
| Research analysis and model training | Python |
| Persistent interchange and test fixtures | Versioned JSON |

The existing Zig CLI remains the fastest place to establish whether the
planning model is useful. If the Apple application becomes the primary product,
the stable domain model and generator should be ported to a shared Swift
package. A permanent Zig-to-Swift binary boundary is not preferred because the
planning logic is not computationally expensive enough to justify the added
build, memory-ownership, and debugging complexity.

## Product principles

1. **Deterministic before learned.** Identical inputs and policy versions must
   produce identical plans.
2. **Evidence remains traceable.** Every planning rule records its source,
   applicable population, limitations, and confidence.
3. **Constraints are enforced in code.** A language model or statistical model
   may propose parameters, but it cannot bypass schedule validation.
4. **Plans are immutable and reviewable.** Generated plans use the existing
   preview/apply workflow and preserve earlier schedule revisions.
5. **Missing data remains missing.** The application must distinguish measured,
   user-entered, inferred, and defaulted values.
6. **Recommendations are explainable.** The application should state which
   profile facts and policy rules caused a phase, workout, pace, or revision.
7. **Personal data stays local by default.** Cloud synchronization or external
   model use must be an explicit later choice.

## High-level phases

### Phase 1: deterministic evidence-backed planner

Build and validate a half-marathon planning engine in Zig. It accepts a runner
profile, goal, availability, and goal date; selects a versioned policy; produces
a complete structured plan; explains the result; and passes the result through
strict validation before it can be applied.

### Phase 2: Apple application foundation

Create a shared Swift domain package and an iPhone SwiftUI application. Port the
stable profile, policy, generator, and validator using the same JSON fixtures.
Add HealthKit workout import, notifications, and private synchronization. A
macOS target provides planning and analysis; an Apple Watch target remains
optional.

### Phase 3: personal response estimation

Define a narrow prediction target such as `reduce`, `hold`, or `progress`.
Develop an interpretable baseline using rolling load, compliance, RPE, pain,
pace/heart-rate relationships, sleep, and readiness. Train population models
only after obtaining sufficient labeled runner-weeks. Core ML becomes an
on-device deployment and optional personalization mechanism, not the source of
periodization knowledge.

### Phase 4: research and language-model assistance

Add retrieval over selected research and the versioned evidence ledger. A
language model may summarize evidence, extract candidate policy changes, or
explain a plan. Any proposed policy or schedule still requires deterministic
validation and user review.

## Migration gates

The project should move from one phase to the next only when:

- Phase 1 policies and inputs no longer change rapidly.
- Synthetic profile tests cover the intended planning range.
- Plan explanations identify the effective policy and important decisions.
- The JSON interchange format is stable enough to port.
- Mobile-only capabilities such as HealthKit and WorkoutKit provide enough
  value to justify the Apple application.
- A model has a precise prediction target and enough labeled examples to
  evaluate against a non-ML baseline.

# Phase 1 proposal

## Objective

Generate a complete, explainable, periodized half-marathon schedule from:

- goal date and goal time or completion goal;
- recent fitness evidence;
- recent training volume and longest run;
- number of available running days;
- preferred workout and long-run days; and
- current interruptions or constraints that affect schedule construction.

The generated program must use structured workout segments, pace ranges,
expected durations, immutable schedule revisions, and the existing
`plan preview` / `plan apply` workflow.

## Recommended initial scope

- Half marathon only.
- Three to six core running days per week.
- One optional recovery run may be offered separately from core days.
- Eight to twenty-four weeks between plan start and race day.
- One target race and one performance peak.
- A target time is optional. When omitted, the planner proposes a
  performance-supported target from the runner's baseline, goal date, and
  available training.
- Running only; strength training remains outside Phase 1.
- Recent 5K, 10K, or half-marathon performance may establish initial paces.
- Conversational effort and RPE remain valid when heart-rate zones are absent.
- Plans outside the supported range return an explicit unsupported result rather
  than silently compressing or stretching the policy.

These boundaries intentionally keep the first policy small enough to evaluate.
Support for maintenance blocks, multiple races, marathon training, or shorter
than eight weeks can be designed after the first policy is trustworthy.

## Non-goals

Phase 1 will not:

- train or ship a machine-learning model;
- ingest papers automatically;
- create an iPhone or macOS user interface;
- make silent daily changes based on wearable scores;
- infer RPE, pain, or completion from heart rate;
- automatically apply a generated or revised schedule; or
- attempt to replace missing baseline information with false precision.

## Proposed CLI workflow

```sh
runningman plan generate runner-profile.json \
  --policy half-marathon \
  --output proposed-plan.json

runningman plan preview proposed-plan.json
runningman plan apply proposed-plan.json
```

An explanation command should show why a day exists:

```sh
runningman plan explain 2026-09-19
```

Example explanation:

```text
Long run: 18 km
Phase: race-specific
Derived from:
- recent longest run: 16 km
- week 9 of 13
- policy half-marathon long-run progression rule LR-03
- recovery week completed in week 8
```

## Workstream 1: runner profile

Define a versioned, data-only `RunnerProfile` document.

Required fields:

- profile schema version;
- plan start date;
- race date and distance;
- completion goal or target time;
- available running days;
- preferred long-run day;
- recent average weekly distance;
- recent longest run; and
- at least one recent performance result or an explicit absence of one.

Optional fields:

- recent weekly-distance history;
- current running frequency;
- recent race or time-trial effort level;
- preferred quality-workout day;
- pace or heart-rate-zone information;
- recent training interruption;
- recurring scheduling constraints; and
- user preferences such as an optional fifth run.

Every field must record whether it was measured, user-entered, derived, or
defaulted.

Deliverables:

- profile JSON schema and example files;
- CLI validation with clear field-level errors;
- backward-compatible conversion from the current hard-coded baseline; and
- profile rendering suitable for weekly review exports.

## Workstream 2: evidence ledger and training policy

Create a versioned evidence ledger. Each entry contains:

- stable evidence ID;
- citation and link;
- population and training status;
- intervention and comparison;
- relevant outcomes;
- limitations;
- proposed planning implication;
- confidence level; and
- policy rules that reference it.

Create `half-marathon` as structured policy data rather than scattered
constants. It should define:

- supported plan lengths and runner profiles;
- phase allocation;
- weekly-volume progression bands;
- recovery-week rules;
- workout categories and recipes;
- training-intensity distribution boundaries;
- quality-session spacing;
- long-run progression;
- race-specific sessions;
- taper;
- optional-run behavior;
- missed-workout behavior; and
- hard validation constraints.

Initial research review queue:

- [Periodization and training-intensity distribution in middle- and long-distance running](https://pubmed.ncbi.nlm.nih.gov/29182410/)
- [Block periodization of endurance training: systematic review and meta-analysis](https://pmc.ncbi.nlm.nih.gov/articles/PMC6802561/)
- [Individualized endurance training based on recovery and training status](https://pubmed.ncbi.nlm.nih.gov/35975912/)
- [Effects of tapering on endurance performance: systematic review and meta-analysis](https://pubmed.ncbi.nlm.nih.gov/37163550/)
- [Association between running injuries and training parameters](https://pmc.ncbi.nlm.nih.gov/articles/PMC9528699/)

The review must capture uncertainty and disagreement. A paper is not converted
directly into a universal rule merely because it reports a positive result.

Deliverables:

- evidence-ledger schema;
- reviewed starter evidence entries;
- `half-marathon` policy file;
- a policy linter; and
- documentation that maps every policy rule to evidence or an explicit product
  assumption.

## Workstream 3: baseline and goal assessment

Produce an initial planning baseline:

- current sustainable weekly volume;
- current long-run capacity;
- estimated training paces or effort bands;
- available plan length;
- target-time estimate range; and
- missing evidence that reduces confidence.

The assessment should distinguish:

- the user's requested target, when provided;
- the planner's performance-supported target or outcome range;
- an aspirational target used for race-specific pace guidance; and
- a completion goal.

Any race-time formula is an estimate with named assumptions. The application
must show the supporting recent result and must not present a single calculated
time as certainty.

If the requested target is not supported by the available evidence, the planner
first proposes a realistic target and explains the difference. If the user
declines that proposal, the requested target may remain as an explicit
aspirational goal. The generated training must still remain inside the policy's
progression, recovery, intensity, and scheduling constraints.

An aspirational target must not cause the planner to compress training that
would normally require several weeks into a shorter period. When the available
time or baseline makes the requested result infeasible, the planner generates
the most progressive plan allowed by the policy and reports:

- why the requested target is not currently supported;
- the limiting inputs, such as available weeks, starting volume, or recent
  performance;
- the planner's estimated outcome range;
- the difference between that range and the requested target; and
- which later date or additional preparation would make the target more
  plausible, when that can be estimated.

Here, "most progressive" means the plan that makes the greatest policy-approved
progress toward the goal. It does not mean bypassing hard constraints or
claiming that the plan guarantees a particular result.

Deliverables:

- pure baseline-calculation functions;
- a structured assessment result;
- target recommendation and feasibility classification;
- human-readable explanations; and
- unit tests covering missing or conflicting baseline inputs.

## Workstream 4: macrocycle generation

Allocate complete weeks to phases according to policy:

- foundation;
- build;
- recovery;
- race-specific;
- taper; and
- race.

Generate the weekly-volume curve and long-run curve before assigning individual
workouts. Recovery and taper reductions must be visible and testable.

The generator should return a structured failure when the requested dates,
availability, baseline, and policy cannot produce a valid macrocycle.

Deliverables:

- pure deterministic macrocycle generator;
- phase and weekly-target explanations;
- exact race-date placement; and
- tests across every supported plan length.

## Workstream 5: weekly workout allocation

Allocate workout recipes to the runner's available days while enforcing:

- required rest or easy separation between demanding sessions;
- compatibility between quality work and the long run;
- recovery-week reductions;
- optional runs remaining truly optional;
- no attempt to compensate for a missed workout by stacking later work;
- day-of-week preferences; and
- complete race-week scheduling.

Workout recipes should produce the existing segment format:

- warm-up;
- work repetitions or sustained work;
- recovery;
- cooldown;
- distance or time;
- pace range; and
- derived duration range.

Deliverables:

- constraint-aware weekly allocator;
- reusable structured workout recipes;
- allocation explanations; and
- explicit unsatisfied-constraint errors.

## Workstream 6: validation

Validation is a separate component and must run before preview or apply.

Required invariants:

- every calendar day from plan start through race day is represented;
- race day matches the goal date;
- workout and schedule IDs are internally consistent;
- phases are ordered correctly;
- recovery weeks reduce planned load;
- taper reduces volume while retaining policy-approved intensity;
- demanding sessions have policy-required separation;
- long-run progression remains within policy bounds;
- weekly volume remains within policy bounds;
- workouts occur only on allowed days unless explicitly optional;
- distance segments have pace and expected-duration information;
- no segment has an invalid pace, duration, repetition, or recovery value; and
- generated metadata identifies the profile, policy version, and policy hash.

Validation failures should identify the exact date, rule ID, and conflicting
inputs.

Target feasibility is not itself a reason to weaken these invariants. An
aspirational target can change the explanation and bounded workout emphasis, but
cannot make an otherwise invalid plan valid.

Deliverables:

- validator component;
- rule-specific error types;
- validation report included in preview; and
- property-oriented tests that examine invariants rather than only exact output.

## Workstream 7: provenance and explainability

Every generated schedule snapshot should preserve:

- normalized input-profile snapshot;
- selected policy ID and version;
- policy content hash;
- generation timestamp;
- baseline assessment;
- important defaults;
- feasibility assessment;
- rule IDs used for phase and workout decisions; and
- reason for a later regeneration.

Weekly review exports should include this information without requiring the
entire research ledger.

Deliverables:

- generation-context data model;
- compact plan and workout explanations;
- `plan explain` command; and
- review-export integration.

## Workstream 8: tests and evaluation

Create a committed library of synthetic runner profiles covering at least:

- three, four, five, and six running days;
- completion and time goals;
- 5K, 10K, half-marathon, and no recent race evidence;
- low and high starting volume within supported policy limits;
- different preferred long-run days;
- eight-week and twenty-four-week boundary plans;
- missing optional fields;
- interrupted recent training;
- unavailable preferred workout combinations; and
- target dates or profiles the first policy must reject.

Evaluation has three levels:

1. Unit tests for calculations, parsing, policy rules, and recipes.
2. Invariant tests for every generated plan.
3. Human review of representative full schedules and explanations.

Golden files should be used sparingly. They are appropriate for stable schemas
and selected reference plans, but broad tests should focus on invariants so a
legitimate policy improvement does not require rewriting every fixture.

Deliverables:

- synthetic-profile fixtures;
- invariant-test helpers;
- selected reference-plan fixtures;
- test coverage in `./check.sh`; and
- a manual review checklist.

## Implementation increments

### Increment 1: schemas and decisions

- [x] Approve Phase 1 scope.
- [x] Draft runner-profile and evidence-ledger schemas.
- [x] Use an eight-to-twenty-four-week range and three to six core running days.
- [x] Add examples and validation only; do not generate plans yet.

Review gate: confirm that the profile captures enough information without
becoming burdensome.

### Increment 2: policy and baseline

- [x] Review the initial research queue.
- [x] Produce `half-marathon`.
- [x] Implement baseline and goal assessment.
- [x] Render explanations and confidence-reducing missing data.

Review gate: inspect policy rules and baseline assessments for representative
profiles.

### Increment 3: generator and validator

- [x] Generate macrocycles.
- [x] Allocate structured workouts.
- [x] Run independent validation.
- [x] Produce proposed-plan JSON compatible with preview/apply.

Review gate: inspect several complete schedules, including boundary cases.

### Increment 4: provenance, explanation, and evaluation

- [x] Preserve policy and input provenance (Increment 4.1).
- [x] Revalidate edited proposals before preview and apply (Increment 4.2).
- [x] Add `plan explain` (Increment 4.3).
- [x] Add progress-to-date review, compact adherence breakdowns, deterministic
  classification, provenance context, and policy guardrails (Increment 4.4).
- Complete the synthetic-profile and invariant-test suite.

Review gate: decide whether Phase 1 is stable enough to begin the Swift port or
requires another policy iteration in Zig.

#### Increment 4.4 plan: review export and local classification

`runningman review` produces a concise recommendation over progress through the
latest closed training day. The deterministic decision window is capped at 28
days, while the progress summary covers the plan from its beginning. An
unfinished core workout today is not counted as missing; the activity horizon
closes yesterday while today's Oura observation can still describe yesterday's
recovery. `--as-of DATE` makes that behavior reproducible.

`runningman review report` produces the self-contained Markdown snapshot for
an explicit review period. External language models are optional; they are not
part of the decision path.

Interfaces:

```sh
runningman review
runningman review --as-of 2026-08-16
runningman review report --weeks 4 --ending 2026-08-16
```

The export must include:

- the active schedule, race date, time remaining, profile and policy identity,
  hashes, assessment confidence, feasibility, supported outcome range, and
  target anchors;
- daily plan-versus-reality records with outcome, distance, duration, average
  heart rate when recorded, RPE, pain, modification reason, next-morning Sleep
  and Readiness Scores, and explicit missing data;
- planned and completed distance, core and optional adherence, workout-category
  adherence, previous-period comparison, and bounded sleep, readiness, pain,
  and unusually difficult-session signals;
- the next two weeks in daily detail and the remaining macrocycle as compact
  weekly phase, distance, long-run, progression, recovery, and taper context;
  and
- the applicable progression, recovery, intensity-distribution, long-run,
  scheduling, optional-run, missed-workout, and taper guardrails with rule IDs.

Runningman classifies the review itself using versioned policy v5:

- `HOLD`: coverage is sufficient and neither direction has enough evidence;
- `PROGRESS`: repeated performance evidence indicates the provisional or
  current prescription is conservative;
- `REPLAN`: repeated disruption means the next proposal must reconnect remaining
  progression to completed training; interruption alone does not prescribe a
  load reduction or decide how to shift workouts or handle the race date;
- `REDUCE`: unusually difficult effort, persistent Oura
  recovery signals, or user-confirmed current pain constrains the next proposal
  downward; and
- `INSUFFICIENT_DATA`: the observation window lacks the required activity or
  recovery coverage for a trustworthy decision.

Classification rules must operate on structured data, use an explicit
observation window, record their inputs and rule IDs, and distinguish evidence
backed thresholds from conservative product assumptions. Missing activity must
not be treated as rest, and one unusual Oura score must not automatically alter
the schedule. Thresholds and persistence requirements must be reviewed before
implementation rather than chosen implicitly in code.

Oura remains responsible for deriving recovery scores from its underlying
signals. Runningman uses the published Sleep and Readiness Scores independently
and does not calculate with raw HRV or other wearable measurements. The current
pattern distinguishes balanced, sleep-limited, readiness-limited despite
adequate sleep, and both-limited mornings. A low score requests review only
when Sleep or Readiness is below Oura's Good category on at least two of the
latest three mornings. The category boundary comes from Oura; the three-morning
window and persistence requirement are conservative product assumptions.

The decision is bidirectional because plans created without useful baseline
performance data are deliberately provisional and may be too easy. Progression
requires at least two quality sessions below prescribed RPE or two sessions
faster than a complete structured pace prescription without exceeding its RPE
range. Any reduction signal takes precedence. Completed running sessions also
calibrate central observed session-average HR bands by workout category when
at least two HR/RPE pairs match the prescribed effort. Quality HR remains a
whole-session observation until structured lap HR is available.

Pain scores through 3 are context only. A score above 3 causes the concise
review to ask whether pain currently affects the user's ability to follow the
plan. Only a user-confirmed yes selects `REDUCE`; the answer affects that
read-only result and is not persisted as a medical judgment.

The output must explain the recommendation and list every direction or coverage
rule. It must never mutate the schedule. The export may be given to a person or
an optional local or external language model for interpretation, but any replacement program still
uses the proposed-plan schema, independent validation, preview, and explicit apply.

This increment does not implement automatic `reduce`, `hold`, or `progress`
adaptation. Phase 3 will add that response policy, candidate-plan generation,
and later optional learned personalization. Apple Foundation Models may provide
local note interpretation and natural-language explanation in the Swift
application, while Core ML remains an optional deployment mechanism after a
sufficient runner-week outcome dataset exists. Neither model bypasses the
deterministic review policy or plan validator.

The explicit interruption proposal is available through `plan adjust` for
generated road distance plans. Policy v3 replaces the percentage-cap/calendar
rejoin approach with a Friel-inspired aerobic return, repeat of the last
completed loading week, and continuation from that point. It asks whether the
target date is movable or fixed; movable targets retain the source progression,
while fixed-date compromises list omitted weeks and must pass structural checks.
Return stages require explicit user response confirmation and recorded training;
future stages remain provisional rather than advancing automatically by date.
Midweek aerobic returns preserve already logged runs. Baseline evidence and the
race prescription stay intact. This is published coaching guidance adapted to
the product, not an experimentally validated recovery algorithm. See
[interruption adjustment](interruption-adjustment.md) for the source, assumptions,
stage workflow, supported scope and independent validation. Foundation-only,
trail/duration-based returns and comprehensive fixed-date candidate search remain
future work.

Increment 4.4 tests must cover complete and sparse logs, missing Oura data,
superseded activity corrections, modified and skipped workouts, persisted and
reconstructed weekly decisions, explicit ending-date determinism, all three
classification results, rule explanations, absence of future-data leakage, and
confirmation that review never changes stored data. Concise-review tests also
cover the unfinished-today horizon, all four recommendation directions,
Sleep/Readiness disagreement, upward calibration, HR/RPE bands, yes/no pain
confirmation, compatibility with the detailed report command, and preservation
of historical workout IDs after a schedule revision.

## Phase 1 acceptance criteria

Phase 1 is complete when:

- a valid profile produces a complete plan through race day;
- a missing target time produces a supported target recommendation or outcome
  range;
- an unsupported requested target produces a realistic alternative before it
  can be retained as aspirational;
- an aspirational target never overrides progression, recovery, intensity, or
  workout-spacing constraints;
- an infeasible requested outcome results in the strongest policy-valid plan
  plus a visible expected shortfall;
- identical profile and policy inputs produce byte-equivalent proposed plans
  except for explicitly excluded generation timestamps and IDs;
- every generated plan passes all independent invariants;
- invalid or unsupported profiles fail with actionable explanations;
- every workout contains structured, renderable instructions;
- planned distance and pace imply visible duration estimates;
- the plan records its profile snapshot, policy version, and policy hash;
- weekly review produces a local, explained `HOLD`, `PROGRESS`, `REDUCE`, `REPLAN`, or
  `INSUFFICIENT_DATA` recommendation without requiring a language model;
- review classification is reproducible for an explicit ending date and never
  changes the stored schedule;
- representative three-to-six-day plans have been manually reviewed;
- generation never writes data before explicit preview and apply; and
- `./check.sh` exercises profile validation, generation, invariants, CLI flow,
  current proposal enforcement, and historical event loading.

## Decisions requested before implementation

1. Approve half marathon as the only Phase 1 race distance.
2. Approve three to six core running days per week.
3. Approve an eight-to-twenty-four-week supported range.
4. **Decided:** target time is optional. When absent, the planner recommends a
   supported target or outcome range.
5. **Decided:** when a requested target is weakly supported, the planner first
   recommends a realistic alternative. The user may retain the original target
   as aspirational, but the generated plan remains within hard policy
   constraints. If the requested outcome is infeasible in the available time,
   the planner generates the strongest policy-valid plan and reports the
   expected shortfall.
6. Confirm that strength training remains outside Phase 1.
7. Confirm that generated plans always require preview and explicit apply.
