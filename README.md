# runningman

`runningman` is a local, running-only training tracker written in Zig. It shows
the planned workout for a date, records what actually happened, preserves every
schedule revision, and produces a weekly check-in suitable for sharing with
ChatGPT.

The training log is append-only JSONL. Corrections and schedule changes add new
records instead of silently changing history.

## Planner inputs and assessment

Phase 1 of the general half-marathon planner begins with standalone, versioned
runner-profile, evidence-ledger, and policy documents. Validate them:

```sh
./zig-out/bin/runningman profile validate examples/runner-profile.json
./zig-out/bin/runningman evidence validate evidence/half-marathon-v1.json
./zig-out/bin/runningman policy validate policies/half-marathon-v1.json
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

Generation allocates the macrocycle, weekly volume, long-run progression, and
structured daily workouts before running an independent policy validator. The
proposal is never applied automatically. With no supported pace anchor, the
plan retains effort guidance without inventing pace or duration precision.

The canonical JSON Schemas include:

- [`schemas/runner-profile-v1.schema.json`](schemas/runner-profile-v1.schema.json)
- [`schemas/evidence-ledger-v1.schema.json`](schemas/evidence-ledger-v1.schema.json)
- [`schemas/training-policy-v1.schema.json`](schemas/training-policy-v1.schema.json)
- [`schemas/proposed-plan-v1.schema.json`](schemas/proposed-plan-v1.schema.json)

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

The first profile version supports half-marathon plans spanning 8–24 weeks and
3–6 core running days. Profile validation also checks date ordering, day
availability, numeric baselines, recent performances, and known unavailable
dates. The evidence ledger requires traceable citations, populations,
comparisons, outcomes, limitations, confidence, planning implications, and
stable policy-rule links. Policy validation checks numerical boundaries,
workout recipes, unique identifiers, and reciprocal links between every rule
and evidence entry.

The policy and assessment design is explained in
[`docs/half-marathon-v1-policy.md`](docs/half-marathon-v1-policy.md).

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

## See the daily schedule

With no command, `runningman` shows today:

```sh
./zig-out/bin/runningman
./zig-out/bin/runningman today 2026-07-25
```

The output includes the phase, workout instructions, intensity, distance,
segment pace ranges, time implied by each distance/pace pair, expected total
time, schedule revision ID, workout ID, and any recorded result.

See a detailed upcoming schedule, starting today by default:

```sh
./zig-out/bin/runningman schedule --weeks 4
./zig-out/bin/runningman schedule --weeks 4 --from 2026-07-20
```

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

The file has this shape:

```json
{
  "schema_version": 1,
  "base_schedule_id": 1,
  "effective_from": "2026-08-03",
  "reason": "Adjusted from the weekly evidence.",
  "workouts": [
    {
      "date": "2026-08-03",
      "phase": "recovery",
      "kind": "easy",
      "intensity": "Zone 2, conversational",
      "details": "6 km easy.",
      "segments": [
        {
          "kind": "distance",
          "label": "Run",
          "distance_km": 6,
          "pace_fast_seconds_per_km": 375,
          "pace_slow_seconds_per_km": 420
        }
      ]
    }
  ]
}
```

The real file must contain one workout or rest entry for every consecutive date
from `effective_from` through the schedule's race date. A segment can prescribe
`distance_km` with a fast/slow pace range, or `duration_seconds`; repetitions
and recovery are represented with `repetitions` and `recovery_seconds`.

Applying creates a new immutable schedule snapshot. Dates before
`effective_from` are copied into that snapshot, while the full remaining
program comes from the revision file. Previous schedules remain present, and
recorded activities remain linked to the exact schedule and workout that were
in effect when they were logged.

## Data model

Every JSON line has `schema_version: 1` and one of these event types:

- `schedule`: immutable context and revision metadata
- `workout`: one dated workout in a complete schedule snapshot, with structured
  segments and pace ranges
- `activity`: an actual result linked to the exact schedule and workout
- `morning_check_in`: Oura Sleep and Readiness Scores for a dated morning

This preserves both what was planned and what was known when an activity was
recorded.
