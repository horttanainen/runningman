# runningman

`runningman` is a local, running-only training tracker written in Zig. It shows
the planned workout for a date, records what actually happened, preserves every
schedule revision, and produces a weekly check-in suitable for sharing with
ChatGPT.

The training log is append-only JSONL. Corrections and schedule changes add new
records instead of silently changing history.

## Planner inputs and assessment

The general half-marathon planner uses standalone runner-profile,
evidence-ledger, and policy documents. Validate them:

```sh
./zig-out/bin/runningman profile validate examples/runner-profile.json
./zig-out/bin/runningman evidence validate evidence/half-marathon.json
./zig-out/bin/runningman policy validate policies/half-marathon.json
```

Assess the example runner's baseline and target:

```sh
./zig-out/bin/runningman plan assess examples/runner-profile.json
```

These commands do not read or create the personal training log. Assessment
reports:

- the primary recent performance used;
- a current half-marathon equivalent;
- estimate uncertainty;
- a bounded training-improvement assumption;
- a supported race-date outcome range;
- a rounded target recommendation;
- target classification and explanation;
- effort and pace anchors; and
- the effective policy rules.

Target classifications are:

- `completion`: there is not enough performance evidence for a numeric target;
- `recommended`: no target was supplied, so the planner proposes one;
- `supported`: the requested target is no faster than the supported fast
  boundary;
- `aspirational`: the target is outside the range but may remain motivational;
  and
- `infeasible`: the target is beyond the strongest outcome supported by the
  profile, plan window, and policy.

An aspirational or infeasible target is never used as the training-pace anchor.
Assessment does not write or apply a plan.

Generate a deterministic proposal against an initialized append-only data file:

```sh
./zig-out/bin/runningman plan generate examples/runner-profile.json \
  --output proposed-plan.json
./zig-out/bin/runningman plan preview proposed-plan.json
./zig-out/bin/runningman plan apply proposed-plan.json
```

Generation allocates the macrocycle, weekly volume, long-run progression,
explicit quality-work progression, and structured daily workouts before
running an independent policy validator. Quality sessions record their stage,
phase position, work distance, repetition format, recovery, and whether the
week establishes, progresses, reduces, tapers, or sharpens the load. In the
foundation phase, progression adds whole 1 km repetitions while retaining the
same 1 km repetition length and two-minute recovery; it no longer alternates
between unrelated 1 km and 500 m formats. The proposal is never applied
automatically. With no supported pace anchor, the plan retains effort guidance
without inventing pace or duration precision.

Generated proposals also embed deterministic provenance: the complete runner
profile and policy snapshots, SHA-256 identities for the profile, policy, and
evidence ledger, the assessment used for pacing, and structured decisions for
every week and workout. Applying a proposal preserves the same provenance in
the append-only schedule revision. No generation timestamp is included, so
identical source files still produce byte-identical proposals.

Explain an active schedule, one active workout, a proposal, or one proposed
workout without selecting a mode flag:

```sh
./zig-out/bin/runningman plan explain
./zig-out/bin/runningman plan explain today
./zig-out/bin/runningman plan explain tomorrow
./zig-out/bin/runningman plan explain 26
./zig-out/bin/runningman plan explain 2026-07-22
./zig-out/bin/runningman plan explain proposed-plan.json
./zig-out/bin/runningman plan explain proposed-plan.json today
./zig-out/bin/runningman plan explain proposed-plan.json tomorrow
./zig-out/bin/runningman plan explain proposed-plan.json 2026-07-22
```

The command recognizes `today`, `tomorrow`, or a strict `YYYY-MM-DD` argument as
a date and otherwise treats it as a proposal path. It recomputes the target
assessment and explains phase purpose, weekly progression, workout allocation,
pace derivation, rule summaries, evidence IDs, and explicit product assumptions.
Explanation is read-only and never revises the schedule.

The canonical JSON Schemas include:

- [`schemas/runner-profile.schema.json`](schemas/runner-profile.schema.json)
- [`schemas/evidence-ledger.schema.json`](schemas/evidence-ledger.schema.json)
- [`schemas/training-policy.schema.json`](schemas/training-policy.schema.json)
- [`schemas/proposed-plan.schema.json`](schemas/proposed-plan.schema.json)

Runner inputs are represented as a `value` plus one of these sources:

- `measured`
- `user_entered`
- `derived`
- `defaulted`

This prevents a later plan explanation from presenting a default or estimate as
measured fact. A target time is optional. If it is omitted, the later baseline
assessment will recommend a supported target or outcome range. The
`recent_performances.value` list may be empty, but it must still be present so
that missing performance evidence is explicit.

The current profile format supports half-marathon plans spanning 8–24 weeks
and 3–6 core running days. Profile validation also checks date ordering, day
availability, numeric baselines, recent performances, and known unavailable
dates. The evidence ledger requires traceable citations, populations,
comparisons, outcomes, limitations, confidence, planning implications, and
stable policy-rule links. Policy validation checks numerical boundaries,
workout recipes, unique identifiers, and reciprocal links between every rule
and evidence entry.

The policy and assessment design is explained in
[`docs/half-marathon-policy.md`](docs/half-marathon-policy.md).

## Build and test

Zig 0.16 is required:

```sh
./check.sh
```

The script formats the Zig source, builds the executable, and runs unit and CLI
tests. The executable is written to `zig-out/bin/runningman`.

## Initialize the plan

Choose the Monday on which week 1 starts:

```sh
./zig-out/bin/runningman init 2026-07-20
```

The generated plan has 13 complete weeks and ends with the half marathon on
Sunday of week 13. For a start date of 2026-07-20, race day is 2026-10-18.

The four core runs are Monday, Tuesday, Thursday, and Saturday. Wednesday is an
optional recovery run, and Friday and Sunday are rest days (except race day).
Training progresses through these phases:

| Weeks | Phase | Main progression |
|---|---|---|
| 1–3 | Foundation | Establish consistent easy volume and controlled quality |
| 4 | Recovery | Reduce volume and intensity |
| 5–7 | Build | Increase long runs, intervals, and sustained work |
| 8 | Recovery | Absorb the build before race-specific work |
| 9–11 | Race-specific | Longer half-marathon-effort segments and peak long runs |
| 12 | Taper | Reduce volume while retaining short controlled intensity |
| 13 | Race | Short easy running, rest, and the half marathon |

By default, data is stored in `runningman-data.jsonl` in the current directory.
Root-level JSONL data files and generated weekly check-ins are gitignored, so
personal training data is not included in repository commits.
Use a different file by placing `--data PATH` before the command:

```sh
./zig-out/bin/runningman --data ~/training/running.jsonl today
```

Every CLI date argument accepts an explicit `YYYY-MM-DD`, a day number in the
current month such as `26`, `today`, or `tomorrow`. Relative dates use the
computer's local calendar date; a day number never rolls into another month.

## See the daily schedule

With no command, `runningman` shows today:

```sh
./zig-out/bin/runningman
./zig-out/bin/runningman today
./zig-out/bin/runningman tomorrow
./zig-out/bin/runningman 26
./zig-out/bin/runningman 2026-07-25
```

The output includes the phase, workout instructions, intensity, distance,
segment pace ranges, time implied by each distance/pace pair, expected total
time, a time-and-effort-matched bicycle replacement, schedule revision ID,
workout ID, and any recorded result.

See a detailed upcoming schedule, starting today by default:

```sh
./zig-out/bin/runningman schedule --weeks 4
./zig-out/bin/runningman schedule --weeks 4 --from 2026-07-20
```

### Bicycle replacements

Every non-rest running workout includes a bicycle option derived from the
planned segment durations. Repetitions, recovery periods, recovery-week
reductions, taper reductions, and the distinction between easy and demanding
work are retained. Bicycle distance is deliberately not prescribed because
terrain, wind, equipment, and cycling economy make a kilometre conversion
misleading.

The replacement uses the same planned time and a cycling-specific RPE target as
a conservative field approximation. It is not presented as a proven 1:1
physiological equivalence. Running and cycling can produce different heart-rate
and oxygen-uptake responses at apparently matched effort, and running-specific
mechanical preparation is not replaced. The 2026
[systematic review and meta-analysis](https://doi.org/10.3389/fspor.2026.1843803)
found no clear short- to medium-term difference in the limited studies, but
explicitly concluded that the evidence does not establish interchangeability.
The mode-dependent RPE/heart-rate response is supported by
[Hassmén (1990)](https://doi.org/10.1007/BF00705035), and an acute matched-HIIT
comparison found different cardiorespiratory responses between running and
cycling
([Scanlan et al.](https://pubmed.ncbi.nlm.nih.gov/36203053/)).

Use bike-specific power or heart-rate zones when they have been established
from cycling. Otherwise follow the displayed RPE and breathing cues. Stop if
cycling produces knee pain. The half-marathon race itself has no equivalent
bicycle replacement.

## Record morning recovery

Record the Oura scores shown each morning:

```sh
./zig-out/bin/runningman check-in
./zig-out/bin/runningman check-in 2026-07-21 \
  --sleep 82 \
  --readiness 76 \
  --notes "Slept well"
```

Running `check-in` without score flags prompts for them interactively. A second
check-in for the same date creates an append-only correction.

## Record training

Run `log` without activity flags for guided input:

```sh
./zig-out/bin/runningman log
./zig-out/bin/runningman log 2026-07-20
```

Or provide everything directly:

```sh
./zig-out/bin/runningman log 2026-07-20 \
  --distance 7.1 \
  --duration 44:30 \
  --avg-hr 141 \
  --rpe 3 \
  --pain 0 \
  --notes "Easy and relaxed"
```

Outcomes are:

- `completed`
- `modified`
- `skipped`
- `rested`

A modified workout requires a reason:

```sh
./zig-out/bin/runningman log 2026-07-21 \
  --modified \
  --distance 6 \
  --duration 39:00 \
  --rpe 8 \
  --pain 2 \
  --pain-location "right knee" \
  --reason "Stopped intervals early"
```

RPE uses 1–10 and pain uses 0–10. Distance, duration, heart rate, RPE, pain, and
notes are optional. For repetition-based workouts such as intervals or hills,
you can record completion, RPE, pain, and a short note without inventing a
distance or duration. Logging the same date again creates an explicit correction
linked to the prior activity. The next morning’s Oura scores provide the
recovery signal in weekly reports.

Duration accepts whole minutes (`44`), minutes and seconds (`44:30`), or hours,
minutes, and seconds (`1:03:10`).

Record a bicycle replacement by sport and duration. Bicycle kilometres remain
separate from running volume in reports:

```sh
./zig-out/bin/runningman log 2026-07-28 \
  --sport cycling \
  --duration 43:00 \
  --avg-hr 138 \
  --rpe 7 \
  --pain 0 \
  --notes "Completed the prescribed bicycle intervals"
```

## Import a Polar Beat screenshot

On macOS, a Polar Beat summary screenshot can be recognized locally with
Apple's Vision framework:

```sh
./scripts/import-polar \
  "polar_beat_screenshots/Screenshot 2026-07-20 at 19.01.46.png"
```

The importer reads the date from the filename and extracts visible values such
as duration, average and maximum heart rate, calories, fat-burn percentage,
training benefit, and heart-rate-zone durations. OCR uses recognized labels and
their relative positions, so small crop and scale differences do not require
fixed screenshot coordinates.

The script displays its inference and asks whether to use those values as the
starting point. If accepted, it opens a complete `runningman log` command in
`$EDITOR`, falling back to `vi`. Add missing values, correct OCR results, or
change the outcome in that file. Saving and exiting successfully runs the
edited command immediately. Exit the editor with a non-zero status—for example,
Vim's `:cq`—to cancel without recording anything.

Missing fields appear as commented options inside the editable command.
Distance uses the active workout's planned distance as its suggested value when
the plan has one. RPE and pain remain placeholders because they must describe
what actually happened.

For a GUI editor, configure it to wait until the file is closed:

```sh
EDITOR="code --wait" ./scripts/import-polar SCREENSHOT.png
```

Preview the generated editor file without recording:

```sh
./scripts/import-polar --dry-run SCREENSHOT.png
```

Override a missing or incorrect filename date, or select another data file:

```sh
./scripts/import-polar --date 2026-07-20 SCREENSHOT.png
./scripts/import-polar --data ~/training/running.jsonl SCREENSHOT.png
```

Duration and average HR populate their dedicated activity fields. Other Polar
values and a SHA-256 source-image identifier are preserved in notes. Distance,
RPE, and pain remain explicitly missing for manual entry. If the date already
has an activity, the editor file warns that running it will create an
append-only correction. Reimporting the exact same image also produces a
warning.

## Review training

Show daily plan versus reality:

```sh
./zig-out/bin/runningman history
./zig-out/bin/runningman history 2026-07-20 2026-08-16
```

Summarize recent weeks and compare mileage with the preceding equal-length
period:

```sh
./zig-out/bin/runningman compare --weeks 4
./zig-out/bin/runningman compare --weeks 1 --ending 2026-07-26
```

The comparison includes outcomes, planned distance ranges, actual mileage and
duration, easy/quality/long-run distribution, average RPE, heart rate, Oura
Sleep and Readiness Scores, pain reports, and missing records. Missing data is
never treated as rest.

## Weekly ChatGPT check-in

Generate a Markdown report:

```sh
./zig-out/bin/runningman review \
  --weeks 1 \
  --ending 2026-07-26 > weekly-check-in.md
```

It contains:

- Training goal, baseline, availability, and intensity guidance
- Planner, profile, policy, evidence, source hashes, assessment, and race
  context when generated provenance is available
- A deterministic `KEEP_PLAN`, `REVIEW_REQUIRED`, or `INSUFFICIENT_DATA`
  classification with every coverage and warning rule
- Schedule revision history
- Planned-versus-actual summary
- Comparison signals
- Daily workout expectations
- Actual results, RPE, heart rate, pain, reasons, and notes
- Next-morning Oura Sleep and Readiness Scores
- The latest known schedule revision
- Every remaining planned day through race day, including structured segments,
  pace ranges, and expected duration
- The JSON contract for proposing a complete replacement program

The local classifier uses review policy `runningman-review` version 2. It requires an
explicit outcome for every core run and next-morning Sleep/Readiness coverage
for at least half of eligible core runs. It requests review for a modified or
missed core run, any recorded pain, a non-race RPE of 9–10, or at least two
mornings below 70 for Sleep or Readiness. These thresholds are labeled as
conservative product assumptions in the report. One unusual wearable score
does not trigger review, missing activity is never treated as rest, and data
after `--ending` is excluded from classification.

Classification is read-only: it does not automatically reduce, hold, progress,
or replace the schedule. This keeps the program from making a medical or
training-load decision from an unsupported threshold. Any replacement still
uses the independently validated preview/apply workflow below.

The raw audit log can also be exported:

```sh
./zig-out/bin/runningman export --format jsonl > training-export.jsonl
```

Give the Markdown file to ChatGPT or Codex for a weekly review. A review does
not have to change the program. If a change is recommended, ask it to create a
revision JSON file that follows the contract in the report and replaces every
remaining day through race day.

## Revise the remaining program

A revision targets the current schedule ID, so an older AI response cannot
silently overwrite a newer program. Previewing is read-only:

```sh
./zig-out/bin/runningman plan preview revised-program.json
```

After inspecting the full preview, apply it:

```sh
./zig-out/bin/runningman plan apply revised-program.json
```

Revision files use only the
[`proposed-plan` schema](schemas/proposed-plan.schema.json). The complete
document must preserve its planner provenance, assessment, macrocycle weeks,
and the structured decision attached to every week and workout. Unsupported
proposal schema versions are rejected.

The easiest starting point for a revised program is a newly generated complete
proposal. It must contain one workout or rest entry for every consecutive date
from the embedded runner profile's plan start through race day. `effective_from`
marks the first workout changed by the revision. Earlier workouts are retained
as validation context and must exactly match the current schedule. A segment
can prescribe `distance_km` with a fast/slow pace range, or `duration_seconds`;
repetitions and recovery are represented with `repetitions` and
`recovery_seconds`.

Preview and apply both recompute the embedded assessment and run the complete
plan through the independent validator. Editing a prescription without its
decision record, changing historical context, or violating progression,
spacing, volume, phase, or taper rules causes the proposal to be rejected.

Applying creates a new immutable schedule snapshot. Dates before
`effective_from` are copied from the parent schedule, while later dates come
from the revision file. Previous schedules remain present, and recorded
activities remain linked to the exact schedule and workout that were in effect
when they were logged.

## Data model

Every JSON line has `schema_version: 2` and one of these event types:

- `schedule`: immutable context, revision metadata, provenance, and weekly
  decisions when available
- `workout`: one dated workout in a complete schedule snapshot, with structured
  segments and pace ranges
- `activity`: an actual result linked to the exact schedule and workout
- `morning_check_in`: Oura Sleep and Readiness Scores for a dated morning

This preserves both what was planned and what was known when an activity was
recorded.
