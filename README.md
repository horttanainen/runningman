# runningman

`runningman` is a local, running-only training tracker written in Zig. It shows
the planned workout for a date, records what actually happened, preserves every
schedule revision, and produces a weekly check-in suitable for sharing with
ChatGPT.

The training log is append-only JSONL. Corrections and schedule changes add new
records instead of silently changing history.

## Build

Zig 0.16 is required:

```sh
zig build
zig build test
```

The executable is written to `zig-out/bin/runningman`.

## Initialize the plan

Choose the Monday on which week 1 starts:

```sh
./zig-out/bin/runningman init 2026-07-20
```

Weeks 1–11 reproduce the supplied plan. The source only says “race week” for
week 12, so those seven workouts remain explicitly unspecified until a race
date and taper are provided.

By default, data is stored in `runningman-data.jsonl` in the current directory.
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

The output includes the workout instructions, intensity, distance expectation,
schedule revision ID, workout ID, and any recorded result.

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
./zig-out/bin/runningman export \
  --format markdown \
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
- The latest known schedule revision and the upcoming seven planned days

The raw audit log can also be exported:

```sh
./zig-out/bin/runningman export --format jsonl > training-export.jsonl
```

## Revise a workout

```sh
./zig-out/bin/runningman revise 2026-08-01 \
  --kind long \
  --intensity "Easy, conversational" \
  --min-km 12 \
  --max-km 12 \
  --details "Reduced long run: 12 km at easy effort." \
  --reason "Accumulated fatigue after week 2"
```

The command creates a new schedule revision containing a complete copy of all
84 planned days with the selected workout changed. The previous schedule and
all activities linked to it remain untouched.

## Data model

Every JSON line has `schema_version: 1` and one of these event types:

- `schedule`: immutable context and revision metadata
- `workout`: one dated workout in a complete schedule snapshot
- `activity`: an actual result linked to the exact schedule and workout
- `morning_check_in`: Oura Sleep and Readiness Scores for a dated morning

This preserves both what was planned and what was known when an activity was
recorded.
