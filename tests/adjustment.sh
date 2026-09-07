#!/bin/sh
set -eu
binary=./zig-out/bin/runningman
temporary_directory=$(mktemp -d "${TMPDIR:-/tmp}/runningman-adjustment.XXXXXX")
trap 'rm -rf "$temporary_directory"' EXIT
data_file="$temporary_directory/training.jsonl"
"$binary" --data "$data_file" init 2026-07-20 >/dev/null
"$binary" --data "$data_file" plan generate examples/runner-profile.json --output "$temporary_directory/initial.json" >/dev/null
"$binary" --data "$data_file" plan apply "$temporary_directory/initial.json" >/dev/null
"$binary" --data "$data_file" history 2026-07-20 2026-08-23 |
    awk '$2 == "easy" || $2 == "quality" || $2 == "long" {print $1, $2}' > "$temporary_directory/runs.txt"
while read -r day kind; do
    distance=7
    effort=3
    if [ "$kind" = long ]; then distance=14; fi
    if [ "$kind" = quality ]; then effort=6; fi
    "$binary" --data "$data_file" log "$day" --distance "$distance" --rpe "$effort" >/dev/null
done < "$temporary_directory/runs.txt"
printf 'y\n' | "$binary" --data "$data_file" log --sick --from 2026-08-24 --through 2026-09-06 >/dev/null
for offset in $(seq 0 48); do
    morning=$(date -j -v+"${offset}"d -f '%Y-%m-%d' '2026-08-10' '+%Y-%m-%d')
    "$binary" --data "$data_file" check-in "$morning" --sleep 85 --readiness 85 >/dev/null
done
cp "$data_file" "$temporary_directory/before.jsonl"
"$binary" --data "$data_file" review --as-of 2026-09-07 > "$temporary_directory/review.txt"
grep -Fq 'Next step: create an adjustment proposal' "$temporary_directory/review.txt"
grep -Fq "$binary --data $data_file plan adjust --from 2026-09-07 --ready-to-resume --output adjusted-plan-2026-09-07.json" "$temporary_directory/review.txt"
grep -Fq 'your confirmation, not clearance inferred from Oura' "$temporary_directory/review.txt"
grep -Fq 'asks whether the target date can move' "$temporary_directory/review.txt"
cmp "$data_file" "$temporary_directory/before.jsonl"

# A default-data invocation should not accidentally direct the next step elsewhere.
binary_absolute="$(pwd)/zig-out/bin/runningman"
cp "$data_file" "$temporary_directory/runningman-data.jsonl"
(
    cd "$temporary_directory"
    "$binary_absolute" review --as-of 2026-09-07 > default-review.txt
)
grep -Fq "$binary_absolute plan adjust --from 2026-09-07" "$temporary_directory/default-review.txt"
if grep -q -- '--data\|--race-date' "$temporary_directory/default-review.txt"; then
    echo 'review assumed a data override or target-date choice' >&2
    exit 1
fi

# Execute the printed command to verify shell quoting and the complete handoff.
special_directory="$temporary_directory/runner's files"
mkdir "$special_directory"
ln -s "$binary_absolute" "$special_directory/running man"
cp "$data_file" "$special_directory/training's log.jsonl"
"$special_directory/running man" --data "$special_directory/training's log.jsonl" review --as-of 2026-09-07 > "$temporary_directory/quoted-review.txt"
next_command=$(sed -n '/^  .* plan adjust /s/^  //p' "$temporary_directory/quoted-review.txt")
test -n "$next_command"
(
    cd "$special_directory"
    printf 'movable\n' | sh -c "$next_command" > adjustment.txt
)
test -f "$special_directory/adjusted-plan-2026-09-07.json"
grep -q 'Can the target date move' "$special_directory/adjustment.txt"
cmp "$special_directory/training's log.jsonl" "$temporary_directory/before.jsonl"

# Already logged runs move the suggested start, without changing the review horizon.
logged_data="$temporary_directory/returned.jsonl"
cp "$data_file" "$logged_data"
"$binary" --data "$logged_data" log 2026-09-07 --distance 7 --rpe 3 >/dev/null
"$binary" --data "$logged_data" review --as-of 2026-09-07 > "$temporary_directory/returned-review.txt"
grep -q 'plan adjust --from 2026-09-08' "$temporary_directory/returned-review.txt"
grep -q 'leave all logged training unchanged' "$temporary_directory/returned-review.txt"
"$binary" --data "$logged_data" log 2026-09-10 --distance 7 --rpe 3 >/dev/null
"$binary" --data "$logged_data" review --as-of 2026-09-07 > "$temporary_directory/returned-review.txt"
grep -q 'Schedule review as of 2026-09-07' "$temporary_directory/returned-review.txt"
grep -q 'plan adjust --from 2026-09-11' "$temporary_directory/returned-review.txt"
"$binary" --data "$logged_data" log 2026-09-07 --distance 7 --rpe 9 >/dev/null
"$binary" --data "$logged_data" review --as-of 2026-09-07 > "$temporary_directory/reduce-review.txt"
grep -q 'Recommendation: REDUCE' "$temporary_directory/reduce-review.txt"
if grep -q 'plan adjust' "$temporary_directory/reduce-review.txt"; then
    echo 'review offered adjustment despite current reduction signals' >&2
    exit 1
fi

if "$binary" --data "$data_file" plan adjust --from 2026-09-07 --output "$temporary_directory/not-ready.json" </dev/null >/dev/null 2>&1; then
    echo 'adjustment accepted missing readiness confirmation' >&2
    exit 1
fi
if "$binary" --data "$data_file" plan adjust --from 2026-09-07 --ready-to-resume --output "$temporary_directory/no-choice.json" </dev/null > "$temporary_directory/no-choice.txt" 2>&1; then
    echo 'adjustment assumed a race-date choice on EOF' >&2
    exit 1
fi
test ! -e "$temporary_directory/no-choice.json"
grep -q 'choose whether the date can move' "$temporary_directory/no-choice.txt"
printf '\nwrong\nmovable\n' | "$binary" --data "$data_file" plan adjust --from 2026-09-07 --ready-to-resume --output "$temporary_directory/flexible.json" > "$temporary_directory/flexible.txt"
grep -q 'Can the target date move' "$temporary_directory/flexible.txt"
grep -q 'no date choice has been assumed' "$temporary_directory/flexible.txt"
grep -q '2026-10-18 -> 2026-11-22 (flexible)' "$temporary_directory/flexible.txt"
grep -q 'No source weeks omitted' "$temporary_directory/flexible.txt"
grep -q 'Repeat source week 4' "$temporary_directory/flexible.txt"
grep -q 'NOT a mandatory duration' "$temporary_directory/flexible.txt"
midweek_data="$temporary_directory/midweek-return.jsonl"
cp "$data_file" "$midweek_data"
"$binary" --data "$midweek_data" log 2026-09-07 --distance 7 --rpe 3 >/dev/null
"$binary" --data "$midweek_data" plan adjust --from 2026-09-08 --ready-to-resume --race-date flexible --base-weeks 2 --output "$temporary_directory/two-week-base.json" > "$temporary_directory/two-week-base.txt"
grep -q 'Checkpoint: Sunday, 2026-09-20;' "$temporary_directory/two-week-base.txt"
if grep -q '"return_load_percent"' "$temporary_directory/flexible.json"; then
    echo 'adjustment retained the invented percentage cap' >&2
    exit 1
fi
"$binary" --data "$data_file" plan preview "$temporary_directory/flexible.json" >/dev/null
"$binary" --data "$data_file" plan explain "$temporary_directory/flexible.json" 2026-09-14 > "$temporary_directory/explain.txt"
grep -q 'PROVISIONAL repeat stage' "$temporary_directory/explain.txt"
grep -q 'not extra improvement inferred from the moved target date' "$temporary_directory/explain.txt"
printf 'fixed\n' | "$binary" --data "$data_file" plan adjust --from 2026-09-07 --ready-to-resume --output "$temporary_directory/keep.json" > "$temporary_directory/keep.txt"
grep -q '2026-10-18 -> 2026-10-18 (keep)' "$temporary_directory/keep.txt"
grep -q 'omitted source weeks 5 6 7 8 11' "$temporary_directory/keep.txt"
grep -q '2026-10-18 Sunday: race \[unchanged\]' "$temporary_directory/keep.txt"
"$binary" --data "$data_file" plan preview "$temporary_directory/keep.json" >/dev/null
"$binary" --data "$data_file" plan adjust --from 2026-09-07 --ready-to-resume --race-date 2026-11-01 --output "$temporary_directory/later.json" > "$temporary_directory/later.txt"
grep -q '2026-10-18 -> 2026-11-01 (change)' "$temporary_directory/later.txt"
for target in 2026-09-20 2026-10-31; do
    if "$binary" --data "$data_file" plan adjust --from 2026-09-07 --ready-to-resume --race-date "$target" --output "$temporary_directory/bad-date.json" >/dev/null 2>&1; then
        echo 'adjustment accepted an unsupported target' >&2
        exit 1
    fi
    test ! -e "$temporary_directory/bad-date.json"
done
for stage in repeat continuation; do
    if "$binary" --data "$data_file" plan adjust --from 2026-09-07 --ready-to-resume --race-date flexible --stage "$stage" --output "$temporary_directory/no-response.json" >/dev/null 2>&1; then
        echo 'adjustment advanced without recorded return training' >&2
        exit 1
    fi
done
if "$binary" --data "$data_file" plan adjust --from 2026-09-07 --ready-to-resume --race-date flexible --output "$data_file" >/dev/null 2>&1; then
    echo 'adjustment overwrote an existing file' >&2
    exit 1
fi
cmp "$data_file" "$temporary_directory/before.jsonl"
sed 's/"policy_version": 3,/"policy_version": 2,/' "$temporary_directory/flexible.json" > "$temporary_directory/superseded.json"
if "$binary" --data "$data_file" plan preview "$temporary_directory/superseded.json" > "$temporary_directory/superseded.txt" 2>&1; then
    echo 'preview accepted a superseded adjustment' >&2
    exit 1
fi
grep -q 'superseded adjustment policy' "$temporary_directory/superseded.txt"
sed 's/"observed_weekly_km": 35/"observed_weekly_km": 350/' "$temporary_directory/flexible.json" > "$temporary_directory/inflated.json"
if "$binary" --data "$data_file" plan preview "$temporary_directory/inflated.json" >/dev/null 2>&1; then
    echo 'preview accepted an invented observed baseline' >&2
    exit 1
fi
"$binary" --data "$data_file" plan apply "$temporary_directory/flexible.json" > "$temporary_directory/applied.txt"
grep -q 'Checkpoint: Sunday, 2026-09-13;' "$temporary_directory/applied.txt"
grep -Fq "$binary --data $data_file review" "$temporary_directory/applied.txt"
"$binary" --data "$data_file" review --as-of 2026-09-07 > "$temporary_directory/return-guidance.txt"
grep -q 'Current action: follow the applied return plan' "$temporary_directory/return-guidance.txt"
grep -q 'Historical review signal: REPLAN' "$temporary_directory/return-guidance.txt"
grep -q 'Checkpoint: Sunday, 2026-09-13; possible repeat stage from Monday, 2026-09-14' "$temporary_directory/return-guidance.txt"
grep -q 'No daily adjustment is needed' "$temporary_directory/return-guidance.txt"
grep -q 'If YES at the checkpoint' "$temporary_directory/return-guidance.txt"
grep -q -- '--stage repeat --output repeat-plan-2026-09-14.json' "$temporary_directory/return-guidance.txt"
grep -q -- '--stage base --output base-plan-2026-09-14.json' "$temporary_directory/return-guidance.txt"
if grep -q 'Next step: create an adjustment proposal\|The next proposal should reconnect' "$temporary_directory/return-guidance.txt"; then
    echo 'applied return plan still triggers generic replanning guidance' >&2
    exit 1
fi
"$binary" --data "$data_file" 2026-09-08 > "$temporary_directory/day-guidance.txt"
grep -q 'Checkpoint: Sunday, 2026-09-13;' "$temporary_directory/day-guidance.txt"
grep -Fq "$binary --data $data_file review" "$temporary_directory/day-guidance.txt"

# Missing observations or current strain must not offer stage confirmation commands.
"$binary" --data "$data_file" review --as-of 2026-09-13 > "$temporary_directory/missing-guidance.txt"
grep -q 'Stage change blocked: resolve the missing information' "$temporary_directory/missing-guidance.txt"
if grep -q ' plan adjust ' "$temporary_directory/missing-guidance.txt"; then
    echo 'stage guidance ignored missing review data' >&2
    exit 1
fi
blocked_data="$temporary_directory/blocked-return.jsonl"
cp "$data_file" "$blocked_data"
"$binary" --data "$blocked_data" log 2026-09-07 --distance 7 --rpe 9 >/dev/null
"$binary" --data "$blocked_data" review --as-of 2026-09-07 > "$temporary_directory/blocked-guidance.txt"
grep -q 'Recommendation: REDUCE' "$temporary_directory/blocked-guidance.txt"
grep -q 'Stage change blocked: the current review recommends REDUCE' "$temporary_directory/blocked-guidance.txt"
if grep -q ' plan adjust ' "$temporary_directory/blocked-guidance.txt"; then
    echo 'stage guidance ignored current strain' >&2
    exit 1
fi
no_return_data="$temporary_directory/no-return.jsonl"
cp "$data_file" "$no_return_data"
for day in 2026-09-07 2026-09-08 2026-09-10 2026-09-12; do
    "$binary" --data "$no_return_data" log "$day" --skipped --reason scheduling >/dev/null
done
"$binary" --data "$no_return_data" review --as-of 2026-09-13 > "$temporary_directory/no-return-guidance.txt"
grep -q 'Recommendation: REPLAN' "$temporary_directory/no-return-guidance.txt"
grep -q 'recorded-training prerequisite is not met' "$temporary_directory/no-return-guidance.txt"
if grep -q -- '--stage repeat' "$temporary_directory/no-return-guidance.txt"; then
    echo 'checkpoint offered repeat without a completed return run' >&2
    exit 1
fi
"$binary" --data "$data_file" history 2026-08-24 2026-09-06 > "$temporary_directory/history.txt"
test "$(grep -c 'skipped, reason: sickness' "$temporary_directory/history.txt")" -eq 8
"$binary" --data "$data_file" 2026-09-14 > "$temporary_directory/pending.txt"
grep -q 'provisional repeat stage, not yet confirmed' "$temporary_directory/pending.txt"
"$binary" --data "$data_file" schedule --from 2026-09-07 --weeks 2 > "$temporary_directory/schedule.txt"
grep -q 'PROVISIONAL repeat stage' "$temporary_directory/schedule.txt"
"$binary" --data "$data_file" plan markdown --output "$temporary_directory/plan.md" >/dev/null
grep -q 'Provisional repeat stage' "$temporary_directory/plan.md"
if "$binary" --data "$data_file" plan apply "$temporary_directory/flexible.json" >/dev/null 2>&1; then
    echo 'adjustment allowed a stale proposal to be reapplied' >&2
    exit 1
fi
for day in 2026-09-07 2026-09-08 2026-09-10 2026-09-12; do
    "$binary" --data "$data_file" log "$day" --distance 7 --rpe 3 >/dev/null
done
"$binary_absolute" --data "$data_file" review --as-of 2026-09-13 > "$temporary_directory/checkpoint.txt"
grep -q 'The checkpoint is today' "$temporary_directory/checkpoint.txt"
grep -q 'Completed runs after the latest sickness skip: 4' "$temporary_directory/checkpoint.txt"
"$binary" --data "$data_file" 2026-09-15 > "$temporary_directory/overdue.txt"
grep -q 'checkpoint is overdue' "$temporary_directory/overdue.txt"
grep -q 'possible repeat stage from Monday, 2026-09-21' "$temporary_directory/overdue.txt"
overdue_data="$temporary_directory/overdue-return.jsonl"
cp "$data_file" "$overdue_data"
"$binary" --data "$overdue_data" log 2026-09-14 --distance 7 --rpe 3 >/dev/null
"$binary" --data "$overdue_data" review --as-of 2026-09-15 > "$temporary_directory/overdue-review.txt"
grep -q 'checkpoint is overdue' "$temporary_directory/overdue-review.txt"
grep -q 'plan adjust --from 2026-09-21 --ready-to-resume --stage repeat' "$temporary_directory/overdue-review.txt"
grep -q 'plan adjust --from 2026-09-15 --ready-to-resume --stage base' "$temporary_directory/overdue-review.txt"

# The not-yet branch extends base and derives a fresh checkpoint.
base_command=$(sed -n '/ plan adjust .*--stage base /s/^  //p' "$temporary_directory/checkpoint.txt")
test -n "$base_command"
(
    cd "$temporary_directory"
    printf 'movable\n' | sh -c "$base_command" > extended-preview.txt
)
extended_data="$temporary_directory/extended-return.jsonl"
cp "$data_file" "$extended_data"
"$binary" --data "$extended_data" plan apply "$temporary_directory/base-plan-2026-09-14.json" >/dev/null
"$binary" --data "$extended_data" review --as-of 2026-09-13 > "$temporary_directory/extended-guidance.txt"
grep -q 'selected stage base, effective 2026-09-14' "$temporary_directory/extended-guidance.txt"
grep -q 'Checkpoint: Sunday, 2026-09-20; possible repeat stage from Monday, 2026-09-21' "$temporary_directory/extended-guidance.txt"
if "$binary" --data "$data_file" plan adjust --from 2026-09-14 --ready-to-resume --race-date flexible --stage continuation --output "$temporary_directory/skipped-repeat.json" >/dev/null 2>&1; then
    echo 'adjustment skipped the repeated loading week' >&2
    exit 1
fi
# Follow both commands printed by the checkpoint instead of hand-writing the handoff.
repeat_command=$(sed -n '/ plan adjust .*--stage repeat /s/^  //p' "$temporary_directory/checkpoint.txt")
repeat_apply=$(sed -n '/ plan apply repeat-plan-/s/^  //p' "$temporary_directory/checkpoint.txt")
test -n "$repeat_command"
test -n "$repeat_apply"
(
    cd "$temporary_directory"
    printf 'movable\n' | sh -c "$repeat_command" > repeat.txt
    sh -c "$repeat_apply" > repeat-applied.txt
)
grep -q 'Current return stage: repeat' "$temporary_directory/repeat.txt"
"$binary" --data "$data_file" review --as-of 2026-09-13 > "$temporary_directory/repeat-guidance.txt"
grep -q 'selected stage repeat, effective 2026-09-14' "$temporary_directory/repeat-guidance.txt"
grep -q 'Checkpoint: Sunday, 2026-09-20; possible continuation stage from Monday, 2026-09-21' "$temporary_directory/repeat-guidance.txt"
"$binary" --data "$data_file" 2026-09-14 > "$temporary_directory/current.txt"
if grep -q 'not yet confirmed' "$temporary_directory/current.txt"; then
    echo 'confirmed repeat stage still gated' >&2
    exit 1
fi
"$binary" --data "$data_file" 2026-09-21 > "$temporary_directory/pending.txt"
grep -q 'provisional continuation stage' "$temporary_directory/pending.txt"
for day in 2026-09-14 2026-09-15 2026-09-17; do
    "$binary" --data "$data_file" log "$day" --distance 7 --rpe 3 >/dev/null
done
incomplete_repeat_data="$temporary_directory/incomplete-repeat.jsonl"
cp "$data_file" "$incomplete_repeat_data"
"$binary" --data "$incomplete_repeat_data" log 2026-09-19 --skipped --reason scheduling >/dev/null
"$binary" --data "$incomplete_repeat_data" review --as-of 2026-09-20 > "$temporary_directory/incomplete-repeat.txt"
grep -q 'recorded-training prerequisite is not met' "$temporary_directory/incomplete-repeat.txt"
if grep -q -- '--stage continuation' "$temporary_directory/incomplete-repeat.txt"; then
    echo 'checkpoint offered continuation without the repeated week' >&2
    exit 1
fi
"$binary" --data "$data_file" log 2026-09-19 --distance 14 --rpe 3 >/dev/null
"$binary" --data "$data_file" review --as-of 2026-09-20 > "$temporary_directory/continuation-guidance.txt"
grep -q -- '--stage continuation --output continuation-plan-2026-09-21.json' "$temporary_directory/continuation-guidance.txt"
grep -q 'plan apply continuation-plan-2026-09-21.json' "$temporary_directory/continuation-guidance.txt"
"$binary" --data "$data_file" plan adjust --from 2026-09-21 --ready-to-resume --race-date flexible --stage continuation --output "$temporary_directory/continue.json" > "$temporary_directory/continue.txt"
grep -q '2026-11-22 -> 2026-11-22 (flexible)' "$temporary_directory/continue.txt"
sed 's/"returned_weekly_km": 35/"returned_weekly_km": 350/' "$temporary_directory/continue.json" > "$temporary_directory/inflated-return.json"
if "$binary" --data "$data_file" plan preview "$temporary_directory/inflated-return.json" >/dev/null 2>&1; then
    echo 'preview accepted an invented completed return load' >&2
    exit 1
fi
"$binary" --data "$data_file" plan apply "$temporary_directory/continue.json" >/dev/null
"$binary" --data "$data_file" review --as-of 2026-09-20 > "$temporary_directory/confirmed-continuation.txt"
grep -q 'No further return-stage checkpoint is scheduled' "$temporary_directory/confirmed-continuation.txt"
if grep -q ' plan adjust ' "$temporary_directory/confirmed-continuation.txt"; then
    echo 'confirmed continuation restarted the return-stage loop' >&2
    exit 1
fi
"$binary" --data "$data_file" 2026-09-21 > "$temporary_directory/current.txt"
if grep -q 'not yet confirmed' "$temporary_directory/current.txt"; then
    echo 'confirmed continuation stage still gated' >&2
    exit 1
fi
