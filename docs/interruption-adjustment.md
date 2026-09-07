# Friel-inspired interruption adjustment — policy v3

`plan adjust` produces a complete, unapplied proposal after a sickness gap.
It asks whether the target date can move; it never assumes a booked race.

## Coaching source and scope

The source is Joe Friel's [Missed Workouts](https://joefrieltraining.com/missed-workouts/)
(2010), particularly the one-to-two-week illness interruption during a build:
return to aerobic/base work until the usual effort/heart-rate/pace relationship
returns, repeat the last completed loading week, then progress if it goes well.

This is an adaptation of cycling/triathlon coaching guidance for Runningman's
road, distance-based half-marathon plans. It is **not** an experimentally
validated half-marathon recovery algorithm. Friel does not prescribe the exact
distances, number of return days, or this repository's phase labels. An illness
week is not treated as a planned recovery week.

The first adjustment requires a complete `REPLAN` review and
`--ready-to-resume`, a user statement, not clearance inferred from Oura.
A continuation of an already applied v3 adjustment can also have a HOLD or
PROGRESS review. Missing data or current REDUCE signals still block it.
A completed pre-illness loading week must be available; foundation-only,
trail, duration-based, and more complex return cases need another policy.

## Start and race-date choice

```sh
./zig-out/bin/runningman plan adjust --from 2026-09-07 \
  --ready-to-resume --output return-plan.json
```

The prompt is:

> Can the target date move, or is there a fixed race? [movable/fixed]:

Blank/invalid answers are not a choice. EOF fails without creating a proposal.
For unattended use, provide `--race-date flexible`, `--race-date keep`, or
`--race-date YYYY-MM-DD`. An explicit date is a fixed constraint, not permission
to choose some other date. Duplicate date flags are rejected.

- **Movable:** keep every source week from the resumed progression, in order,
  and derive a target date after the return stage and repeated loading week.
  This may move the target by more than the missed two weeks: returning to an
  earlier completed week and projecting aerobic-return time also occupy dates.
- **Fixed:** first determine how much of that continuation fits. The bounded
  compromise removes later build weeks, then recovery weeks, then early taper
  weeks if necessary. It never removes the repeated week, race-specific weeks,
  race, or required final taper. Independent progression, recovery-spacing,
  specificity and taper checks can reject the candidate. The preview lists
  every omitted source week and distinguishes scheduling feasibility from the
  original finishing-time goal.

The fixed-date omission order is our explicit mapping of Friel's broad advice,
not his exact Base/Build/Peak taxonomy, and is not an exhaustive feasibility
search. A rejected candidate does not prove the date is medically impossible.
Targets must retain the original race weekday and remain within the existing
24-week plan horizon. A fixed date beyond the intact continuation is rejected:
adding extra training blocks is outside this increment.

## Three response-based stages

The selected stage is a user confirmation stored in the proposal and its
append-only schedule provenance. No stage is advanced by the passage of time.

1. **`--stage base` (default):** only easy, effort-based running and rest.
   It may start any day; all prescriptions before `--from` remain unchanged.
   No intervals, long-run progression, pace targets, or optional mileage.
2. **`--stage repeat`:** confirms easy running and subsequent recovery feel
   normal. At least one completed return run must already be logged.
   Repeat the last fully completed build/race-specific week before the gap.
   If this week does not go well, use the repeat stage again (or return to base).
3. **`--stage continuation`:** confirms the repeated loading week went well.
   A complete repeated week of running outcomes and distances must exist in the
   active return plan. Resume the following source week and its progression.

Repeat and continuation start on Mondays to preserve complete source weeks
and workout weekdays. This is a CLI scheduling boundary, not a physiological
requirement to wait a full week. When a run is already logged today, start a
base proposal tomorrow instead of overwriting today's prescription or outcome.

The complete proposal includes later stages to show a possible periodized
continuation and target date, but those stages are **provisional**. Date/day
lookup does not present an unconfirmed stage as the current prescribed workout.
Schedule and Markdown output mark those workouts as provisional. To advance,
create, preview, and explicitly apply a new adjustment with the confirmed stage.
Activity logging always remains available: an actual workout is a historical
fact, even when it differed from the proposed return stage.

```sh
# Once easy running and recovery feel normal:
./zig-out/bin/runningman plan adjust --from 2026-09-14 \
  --ready-to-resume --stage repeat --race-date flexible --output repeat-plan.json

# Once the repeated loading week is logged and went well:
./zig-out/bin/runningman plan adjust --from 2026-09-21 \
  --ready-to-resume --stage continuation --race-date flexible --output continue-plan.json
```

These dates are examples, not a required recovery timetable.

### CLI checkpoint guidance

Generation, preview, application, and daily workout views display the next
checkpoint and direct the runner to `review`. The checkpoint is the Sunday
before the first provisional next-stage week, derived from the selected stage
and week mappings (including extended or partial base weeks).

`review` identifies the applied return revision, describes the response to
assess, and prints separate commands for advancing or staying in the current
stage. Each branch creates a proposal followed by a separately authorized
apply command; run only the branch matching the response. Existing output
files must not be overwritten. Readiness and race-date choices remain explicit.

Before the checkpoint, the commands are conditional instructions for that
date, not a request to advance immediately. On or after the checkpoint, a
missing recorded return run or incomplete repeated week prevents offering the
advance command. Missing review coverage or current reduction signals block
stage-change commands altogether. No HR/RPE value automatically confirms the
runner's subjective response.

After a missed checkpoint, later workouts remain provisional; the suggested
restart advances to an available Monday after recorded training. Extending
base schedules a new checkpoint. An applied repeat revision shows the next
continuation checkpoint, even when its effective date is still upcoming.
An applied continuation has no further return-stage checkpoint. Historical
sickness skips alone are explained as already addressed, while new disruption
or strain still appears in the review.

## Explicit construction assumptions

- Use up to four complete weeks before the first sickness skip for actual
  average/peak weekly running, longest run, and mean easy-run distance. Easy
  observations with known RPE above 4 are excluded from the familiar-distance
  calculation; missing RPE remains unknown, not an invented easy-effort score.
- Select the latest fully completed loading week in that window, not the first
  missed week. All core sessions must be completed runs; cycling substitutions,
  modified workouts, and skipped outcomes cannot establish a completed week.
- For aerobic-return dates, use the familiar easy distance, capped so the
  original core frequency does not exceed observed average weekly running.
  Round down to 0.1 km. These are planning ceilings; shorter runs are allowed.
  This maps aerobic return onto the existing running days; it is not a claim
  that every runner should run this exact distance.
- `--base-weeks 1-4` controls only the calendar forecast (default 1, including
  any partial restart week). Friel gives no universal duration. Repeat or
  extend base according to actual response; the provisional target then moves.
- Scale the repeated source week down only when its prescription exceeds that
  week's completed running volume/long run. Preserve its session structure.
  Later growth starts from the repeated loading level, not a reduced base week
  or an arbitrary jump to the old calendar's next week.
- Retain the original plan's progression, long-run share, recovery reductions,
  demanding-session spacing, intensity distribution, and taper bounds. The
  easy-only return is intentionally exempt from the normal minimum quality
  allocation. These bounds are existing product assumptions, not Friel's rules.
- Preserve source recovery weeks when they fit the generator's nearest-0.5-km
  target rounding and the validator's existing 0.01 recovery-fraction tolerance.
  For example, 38 km followed by 32.5 km remains intact, including its 1 km
  repetitions; it is not scaled to 32.3 km and 994 m repetitions. Larger required
  reductions remain constrained by the strict cap, and independent progression
  and long-run limits still apply. This does not round recorded running data.
- Once the repeated week is logged, continuation uses its actual running volume
  and long run for growth limits. Completing a shorter week does not count as
  having achieved its larger planned load.
- Preserve original performance evidence, baseline, assessment and the race
  workout. Flexible target dates have `derived` provenance; explicitly selected
  dates are `user_entered`. There is no invented fitness-loss percentage.

The previous `--return-load-percent` option and policy v1/v2 proposals are
explicitly rejected. Existing proposal files are never overwritten.

New proposals record `recovery_rounding: source_half_km`. Older v3 proposals
without this field keep their original strict-cap construction for validation
and historical replay. An existing applied plan is not silently rewritten; the
rounding correction takes effect in the next generated adjustment, including
a next-stage proposal whose parent used the older rounding.

## Validation and persistence

Every proposal contains its parent snapshot, selected stage, observed baseline,
completed source week, source-week mappings and any omissions. Later adjustments
retain the original source progression through their parent chain instead of
treating a provisional calendar as completed training.

Preview/apply bind the parent to stored prescriptions and provenance, recompute
observations from the log, and check stage prerequisites. New logs on replaced
dates block application. Embedded validation checks deterministic construction
and independently checks load, phase ordering, intensity, spacing and taper
constraints. Historical prescriptions and activity IDs stay intact.

Generation and preview do not change the active schedule. Application remains
a separate, explicit `plan apply FILE` operation.
