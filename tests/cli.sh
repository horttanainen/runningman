#!/bin/sh
set -eu

binary=$1
temporary_directory=$(mktemp -d "${TMPDIR:-/tmp}/runningman-test.XXXXXX")
trap 'rm -rf "$temporary_directory"' EXIT

data_file="$temporary_directory/training.jsonl"

"$binary" profile validate examples/runner-profile.json > "$temporary_directory/profile.txt"
grep -q "Runner profile is valid: example-half-marathon-runner" "$temporary_directory/profile.txt"
grep -q "target time to be recommended" "$temporary_directory/profile.txt"
grep -q "Plan span: 91 days" "$temporary_directory/profile.txt"
test ! -e "$data_file"

"$binary" evidence validate examples/evidence-ledger.json > "$temporary_directory/evidence.txt"
grep -q "Evidence ledger is valid: half-marathon-research-example" "$temporary_directory/evidence.txt"
grep -q "Entries: 1 (0 linked to at least one policy rule)" "$temporary_directory/evidence.txt"
test ! -e "$data_file"

"$binary" policy validate policies/half-marathon-v1.json > "$temporary_directory/policy.txt"
grep -q "Training policy is valid: half-marathon-v1 version 1" "$temporary_directory/policy.txt"
grep -q "Rules: 13; phases: 6; workout recipes: 11" "$temporary_directory/policy.txt"
test ! -e "$data_file"

"$binary" plan assess examples/runner-profile.json > "$temporary_directory/assessment.txt"
grep -q "Current half-marathon equivalent: 1:57:49" "$temporary_directory/assessment.txt"
grep -q "Supported race-date outcome range: 1:48:42–2:02:32" "$temporary_directory/assessment.txt"
grep -q "Planner recommendation: 2:00:00" "$temporary_directory/assessment.txt"
grep -q "Classification: recommended" "$temporary_directory/assessment.txt"
grep -q "This command only assesses the profile" "$temporary_directory/assessment.txt"
test ! -e "$data_file"

"$binary" --data "$data_file" init 2026-07-20 > "$temporary_directory/init.txt"
grep -q "immutable 13-week periodized running schedule" "$temporary_directory/init.txt"

generated_data_file="$temporary_directory/generated-data.jsonl"
generated_plan="$temporary_directory/generated-plan.json"
generated_plan_again="$temporary_directory/generated-plan-again.json"
"$binary" --data "$generated_data_file" init 2026-07-20 >/dev/null
"$binary" --data "$generated_data_file" plan generate examples/runner-profile.json \
    --output "$generated_plan" > "$temporary_directory/generate.txt"
grep -q "Generated a validated 91-day plan through 2026-10-18" "$temporary_directory/generate.txt"
grep -Fq "Review it with: runningman --data $generated_data_file plan preview $generated_plan" \
    "$temporary_directory/generate.txt"
if grep -q -- "--data DATA" "$temporary_directory/generate.txt"; then
    echo "expected generated review command to use the selected data path" >&2
    exit 1
fi
grep -q '"phase": "recovery"' "$generated_plan"
grep -q '"schema_version": 2' "$generated_plan"
grep -q '"phase": "race_specific"' "$generated_plan"
grep -q '"phase": "taper"' "$generated_plan"
grep -q '"generator_version": "runningman-phase-1-v1"' "$generated_plan"
grep -Eq '"runner_profile_sha256": "[0-9a-f]{64}"' "$generated_plan"
grep -Eq '"training_policy_sha256": "[0-9a-f]{64}"' "$generated_plan"
grep -Eq '"evidence_ledger_sha256": "[0-9a-f]{64}"' "$generated_plan"
grep -q '"profile_id": "example-half-marathon-runner"' "$generated_plan"
grep -q '"volume_method": "build_progression"' "$generated_plan"
grep -q '"recipe_id": "aerobic-intervals"' "$generated_plan"
grep -q '"recipe_id": "continuous-threshold"' "$generated_plan"
grep -q '"recipe_id": "race-week-sharpening"' "$generated_plan"
"$binary" --data "$generated_data_file" plan generate examples/runner-profile.json \
    --output "$generated_plan_again" >/dev/null
cmp "$generated_plan" "$generated_plan_again"
"$binary" --data "$generated_data_file" plan preview "$generated_plan" \
    > "$temporary_directory/generated-preview.txt"
grep -q "Expected total time" "$temporary_directory/generated-preview.txt"
grep -q "Aerobic intervals: 3 repetitions totalling 3.0 km" "$temporary_directory/generated-preview.txt"
grep -q "3 × 1.0 km" "$temporary_directory/generated-preview.txt"
grep -q "2:00 easy recovery between repetitions" "$temporary_directory/generated-preview.txt"
if grep -q "Controlled aerobic intervals: 3.0 km" "$temporary_directory/generated-preview.txt"; then
    echo "expected generated intervals to include repetitions and recovery" >&2
    exit 1
fi
grep -q "Assessment: example-half-marathon-runner; half-marathon-v1 v1" "$temporary_directory/generated-preview.txt"
grep -q "Planner provenance" "$temporary_directory/generated-preview.txt"
grep -q "Generator: runningman-phase-1-v1" "$temporary_directory/generated-preview.txt"
grep -q "Complete profile and policy snapshots are embedded" "$temporary_directory/generated-preview.txt"
grep -q "Basis: build_progression; rules PER-01, VOL-01, LONG-01" "$temporary_directory/generated-preview.txt"
grep -q "Basis: recipe aerobic-intervals; distance quality_weekly_fraction" "$temporary_directory/generated-preview.txt"
grep -q "Macrocycle" "$temporary_directory/generated-preview.txt"
grep -q "Week 13 .*race, 33.1 km core" "$temporary_directory/generated-preview.txt"
grep -q "No data was changed" "$temporary_directory/generated-preview.txt"
legacy_plan="$temporary_directory/legacy-plan.json"
sed 's/"schema_version": 2/"schema_version": 1/' "$generated_plan" > "$legacy_plan"
if "$binary" --data "$generated_data_file" plan preview "$legacy_plan" \
    > /dev/null 2> "$temporary_directory/legacy-plan-error.txt"
then
    echo "expected proposed-plan schema version 1 to be rejected" >&2
    exit 1
fi
grep -q "revision file schema_version must be 2" "$temporary_directory/legacy-plan-error.txt"
"$binary" --data "$generated_data_file" plan apply "$generated_plan" \
    > "$temporary_directory/generated-apply.txt"
grep -q "Applied schedule #2" "$temporary_directory/generated-apply.txt"
grep -q '"plan_provenance":{' "$generated_data_file"
grep -q '"generator_version":"runningman-phase-1-v1"' "$generated_data_file"
grep -q '"decision":{"recipe_id":"aerobic-intervals"' "$generated_data_file"
"$binary" --data "$generated_data_file" today 2026-07-21 \
    > "$temporary_directory/generated-reload.txt"
grep -q "Schedule #2" "$temporary_directory/generated-reload.txt"

for fixture in \
    tests/fixtures/runner-profile-8-week-3-day.json \
    tests/fixtures/runner-profile-24-week-6-day.json
do
    fixture_name=$(basename "$fixture" .json)
    fixture_data="$temporary_directory/$fixture_name.jsonl"
    fixture_plan="$temporary_directory/$fixture_name-plan.json"
    "$binary" --data "$fixture_data" init 2026-07-20 >/dev/null
    "$binary" --data "$fixture_data" plan generate "$fixture" \
        --output "$fixture_plan" >/dev/null
    "$binary" --data "$fixture_data" plan preview "$fixture_plan" >/dev/null
done
test "$(sed -n '/"workouts": \[/,$p' "$temporary_directory/runner-profile-8-week-3-day-plan.json" | grep -c '"date"')" = 56
test "$(sed -n '/"workouts": \[/,$p' "$temporary_directory/runner-profile-24-week-6-day-plan.json" | grep -c '"date"')" = 168

"$binary" --data "$data_file" today 2026-07-20 > "$temporary_directory/today.txt"
grep -q "Core easy aerobic run" "$temporary_directory/today.txt"
grep -q "6.0 km at 6:15–7:00/km (37:30–42:00)" "$temporary_directory/today.txt"
grep -q "Expected total time: 37:30–42:00" "$temporary_directory/today.txt"

printf 'completed\n8.2\n52:00\n139\n3\n0\nComfortable\n' |
    "$binary" --data "$data_file" log 2026-07-22 > "$temporary_directory/interactive.txt"
grep -q "Recorded completed" "$temporary_directory/interactive.txt"

"$binary" --data "$data_file" schedule --weeks 4 --from 2026-07-20 > "$temporary_directory/schedule.txt"
grep -q "Week 4" "$temporary_directory/schedule.txt"
grep -q "2026-08-15 Saturday: long — 13.0 km" "$temporary_directory/schedule.txt"
grep -q "Expected total time: 1:21:15–1:29:55" "$temporary_directory/schedule.txt"

"$binary" --data "$data_file" log 2026-07-20 \
    --distance 7.1 \
    --duration 44:30 \
    --avg-hr 141 \
    --rpe 3 \
    --pain 0 \
    --notes "Easy | relaxed" > /dev/null

"$binary" --data "$data_file" log 2026-07-21 \
    --modified \
    --distance 6 \
    --duration 39:00 \
    --rpe 8 \
    --pain 2 \
    --pain-location "right knee" \
    --reason "Stopped intervals early" > /dev/null

"$binary" --data "$data_file" log 2026-07-21 \
    --modified \
    --distance 6.1 \
    --duration 39:10 \
    --rpe 8 \
    --pain 2 \
    --pain-location "right knee" \
    --reason "Corrected watch distance" > "$temporary_directory/correction.txt"
grep -q "supersedes activity" "$temporary_directory/correction.txt"

"$binary" --data "$data_file" log 2026-08-01 \
    --distance 15 \
    --duration 1:40:00 \
    --rpe 5 \
    --pain 0 > /dev/null

revision_file="$generated_plan"

"$binary" --data "$data_file" plan preview "$revision_file" > "$temporary_directory/preview.txt"
grep -q "No data was changed" "$temporary_directory/preview.txt"
grep -q "quality.*changed" "$temporary_directory/preview.txt"

"$binary" --data "$data_file" plan apply "$revision_file" > "$temporary_directory/revision.txt"
grep -q "Applied schedule #2" "$temporary_directory/revision.txt"
if "$binary" --data "$data_file" plan preview "$revision_file" >/dev/null 2>&1; then
    echo "expected a stale plan revision to fail" >&2
    exit 1
fi

"$binary" --data "$data_file" today 2026-10-18 > "$temporary_directory/revised-day.txt"
grep -q "Half marathon. Start controlled" "$temporary_directory/revised-day.txt"
grep -q "Schedule #2" "$temporary_directory/revised-day.txt"

"$binary" --data "$data_file" log 2026-08-01 \
    --distance 15.1 \
    --duration 1:40:30 \
    --rpe 5 \
    --pain 0 > "$temporary_directory/post-revision-correction.txt"
grep -q "supersedes activity" "$temporary_directory/post-revision-correction.txt"
tail -n 1 "$data_file" | grep -q '"schedule_id":1,"workout_id":13'

"$binary" --data "$data_file" today 2026-10-05 > "$temporary_directory/taper-week.txt"
grep -q "taper phase" "$temporary_directory/taper-week.txt"

"$binary" --data "$data_file" check-in 2026-07-21 \
    --sleep 65 \
    --readiness 59 \
    --notes "Poor recovery" > "$temporary_directory/oura.txt"
grep -q "Sleep 65 and Readiness 59" "$temporary_directory/oura.txt"

printf '82\n76\nBetter morning\n' |
    "$binary" --data "$data_file" check-in 2026-07-22 > "$temporary_directory/oura-interactive.txt"
grep -q "Sleep 82 and Readiness 76" "$temporary_directory/oura-interactive.txt"

"$binary" --data "$data_file" history 2026-07-20 2026-07-26 > "$temporary_directory/history.txt"
grep -q "completed, 7.10 km" "$temporary_directory/history.txt"
grep -q "modified, 6.10 km" "$temporary_directory/history.txt"
grep -q "Next morning Oura: Sleep 65, Readiness 59" "$temporary_directory/history.txt"

"$binary" --data "$data_file" compare --weeks 1 --ending 2026-07-26 > "$temporary_directory/compare.txt"
grep -q "Pain was reported" "$temporary_directory/compare.txt"
grep -q "do not assume they were rest days" "$temporary_directory/compare.txt"
grep -q "Readiness was below 70" "$temporary_directory/compare.txt"

"$binary" --data "$data_file" review --weeks 1 --ending 2026-07-26 > "$temporary_directory/check-in.md"
grep -q "# Running training check-in" "$temporary_directory/check-in.md"
grep -q "## Training context" "$temporary_directory/check-in.md"
grep -q "## Signals for review" "$temporary_directory/check-in.md"
grep -q "## Complete remaining program" "$temporary_directory/check-in.md"
grep -q "## Whole-program revision contract" "$temporary_directory/check-in.md"
grep -q "2026-10-18 Sunday — race" "$temporary_directory/check-in.md"
grep -q 'It must use `schema_version: 2`' "$temporary_directory/check-in.md"
grep -Eq "active by period end|known upcoming at period end|recorded after this period" \
    "$temporary_directory/check-in.md"
grep -Fq 'Easy \| relaxed' "$temporary_directory/check-in.md"
grep -q "right knee" "$temporary_directory/check-in.md"
grep -q "Sleep 65/100; Readiness 59/100" "$temporary_directory/check-in.md"

line_count=$(wc -l < "$data_file" | tr -d ' ')
test "$line_count" = "192"

"$binary" --data "$data_file" export --format jsonl > "$temporary_directory/raw.jsonl"
cmp "$data_file" "$temporary_directory/raw.jsonl"

if "$binary" --data "$data_file" log 2026-07-22 --distance 8 --rpe 11 >/dev/null 2>&1; then
    echo "expected invalid RPE to fail" >&2
    exit 1
fi
