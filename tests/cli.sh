#!/bin/sh
set -eu

binary=$1
temporary_directory=$(mktemp -d "${TMPDIR:-/tmp}/runningman-test.XXXXXX")
trap 'rm -rf "$temporary_directory"' EXIT

data_file="$temporary_directory/training.jsonl"

"$binary" help > "$temporary_directory/help.txt"
grep -Fq "runningman [--data PATH] [DATE_REFERENCE]" "$temporary_directory/help.txt"
grep -Fq "plan markdown [REVISION.json] [--output TRAINING_PLAN.md]" \
    "$temporary_directory/help.txt"
grep -Fq "Date references accept YYYY-MM-DD, a day in the current month, today, or tomorrow." \
    "$temporary_directory/help.txt"

"$binary" profile validate examples/runner-profile.json > "$temporary_directory/profile.txt"
grep -q "Runner profile is valid: example-half-marathon-runner" "$temporary_directory/profile.txt"
grep -q "target time to be recommended" "$temporary_directory/profile.txt"
grep -q "Plan span: 91 days" "$temporary_directory/profile.txt"
test ! -e "$data_file"

"$binary" evidence validate examples/evidence-ledger.json > "$temporary_directory/evidence.txt"
grep -q "Evidence ledger is valid: half-marathon-research-example" "$temporary_directory/evidence.txt"
grep -q "Entries: 1 (0 linked to at least one policy rule)" "$temporary_directory/evidence.txt"
test ! -e "$data_file"

"$binary" policy validate policies/half-marathon.json > "$temporary_directory/policy.txt"
grep -q "Training policy is valid: half-marathon version 2" "$temporary_directory/policy.txt"
grep -q "Rules: 13; phases: 6; workout recipes: 11" "$temporary_directory/policy.txt"
test ! -e "$data_file"
unsupported_policy="$temporary_directory/unsupported-policy.json"
sed 's/"policy_version": 2/"policy_version": 3/' \
    policies/half-marathon.json > "$unsupported_policy"
if "$binary" policy validate "$unsupported_policy" \
    > /dev/null 2> "$temporary_directory/unsupported-policy-error.txt"
then
    echo "expected an unsupported training policy version to be rejected" >&2
    exit 1
fi
grep -q "only training policy version 2 is supported" \
    "$temporary_directory/unsupported-policy-error.txt"
unsupported_policy_schema="$temporary_directory/unsupported-policy-schema.json"
sed 's/"schema_version": 2/"schema_version": 3/' \
    policies/half-marathon.json > "$unsupported_policy_schema"
if "$binary" policy validate "$unsupported_policy_schema" \
    > /dev/null 2> "$temporary_directory/unsupported-policy-schema-error.txt"
then
    echo "expected an unsupported training policy schema to be rejected" >&2
    exit 1
fi
grep -q "training policy schema_version must be 2" \
    "$temporary_directory/unsupported-policy-schema-error.txt"

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
generated_markdown="$temporary_directory/training-plan.md"
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
grep -q '"generator_version": "runningman-planner-v2"' "$generated_plan"
test "$(jq -r '.provenance.schema_version' "$generated_plan")" = "2"
test "$(jq -r '.provenance.training_policy.schema_version' "$generated_plan")" = "2"
test "$(jq -r '.provenance.training_policy.policy_id' "$generated_plan")" = "half-marathon"
grep -q '"phase_week": 2' "$generated_plan"
grep -q '"stage_id": "foundation-aerobic-intervals"' "$generated_plan"
grep -q '"load_method": "progress_work"' "$generated_plan"
grep -Eq '"runner_profile_sha256": "[0-9a-f]{64}"' "$generated_plan"
grep -Eq '"training_policy_sha256": "[0-9a-f]{64}"' "$generated_plan"
grep -Eq '"evidence_ledger_sha256": "[0-9a-f]{64}"' "$generated_plan"
grep -q '"profile_id": "example-half-marathon-runner"' "$generated_plan"
grep -q '"volume_method": "build_progression"' "$generated_plan"
grep -q '"recipe_id": "aerobic-intervals"' "$generated_plan"
grep -q '"recipe_id": "continuous-threshold"' "$generated_plan"
grep -q '"recipe_id": "race-week-sharpening"' "$generated_plan"
"$binary" --data "$generated_data_file" plan markdown "$generated_plan" \
    --output "$generated_markdown" > "$temporary_directory/markdown.txt"
grep -Fq "Wrote a friendly 13-week training plan to $generated_markdown" \
    "$temporary_directory/markdown.txt"
grep -q "# Half-marathon training plan" "$generated_markdown"
grep -q "## Plan at a glance" "$generated_markdown"
grep -q "| 1 | 2026-07-20–2026-07-26 | Foundation | 30.0 km | 12.0 km |" \
    "$generated_markdown"
grep -q "## Week 1: Foundation" "$generated_markdown"
grep -q "Establish sustainable frequency" "$generated_markdown"
grep -q "### Tuesday, 2026-07-21 — Quality" "$generated_markdown"
grep -q "\*\*Run\*\*" "$generated_markdown"
grep -q "\*\*Bicycle instead\*\*" "$generated_markdown"
grep -q "3 × 5:15 at controlled hard RPE 6–8" "$generated_markdown"
grep -q "No bicycle workout is equivalent to the half-marathon race" "$generated_markdown"
grep -q "After exporting completed activities from Garmin Connect" "$generated_markdown"
if grep -q "Planner provenance" "$generated_markdown"; then
    echo "expected friendly Markdown to omit internal planner provenance" >&2
    exit 1
fi
"$binary" --data "$generated_data_file" plan generate examples/runner-profile.json \
    --output "$generated_plan_again" >/dev/null
cmp "$generated_plan" "$generated_plan_again"
"$binary" --data "$generated_data_file" plan preview "$generated_plan" \
    > "$temporary_directory/generated-preview.txt"
grep -q "Validation passed" "$temporary_directory/generated-preview.txt"
grep -q "Embedded profile, policy, provenance, and assessment are consistent" \
    "$temporary_directory/generated-preview.txt"
grep -q "Expected total time" "$temporary_directory/generated-preview.txt"
grep -q "Aerobic intervals: 3 repetitions totalling 3.0 km" "$temporary_directory/generated-preview.txt"
grep -q "3 × 1.0 km" "$temporary_directory/generated-preview.txt"
grep -q "4 × 1.0 km" "$temporary_directory/generated-preview.txt"
grep -q "2:00 easy recovery between repetitions" "$temporary_directory/generated-preview.txt"
if grep -q "500 m" "$temporary_directory/generated-preview.txt"; then
    echo "expected foundation progression to retain one-kilometre repetitions" >&2
    exit 1
fi
if grep -q "Controlled aerobic intervals: 3.0 km" "$temporary_directory/generated-preview.txt"; then
    echo "expected generated intervals to include repetitions and recovery" >&2
    exit 1
fi
grep -q "Assessment: example-half-marathon-runner; half-marathon v2" "$temporary_directory/generated-preview.txt"
grep -q "Planner provenance" "$temporary_directory/generated-preview.txt"
grep -q "Generator: runningman-planner-v2" "$temporary_directory/generated-preview.txt"
grep -q "Complete profile and policy snapshots are embedded" "$temporary_directory/generated-preview.txt"
grep -q "Basis: build_progression; rules PER-01, VOL-01, LONG-01" "$temporary_directory/generated-preview.txt"
grep -q "Basis: recipe aerobic-intervals; distance quality_progression" "$temporary_directory/generated-preview.txt"
grep -q "Progression: foundation-aerobic-intervals; progress_work; phase week 2/2; 4.0 km work" \
    "$temporary_directory/generated-preview.txt"
grep -q "Macrocycle" "$temporary_directory/generated-preview.txt"
grep -q "Week 13 .*race, 33.1 km core" "$temporary_directory/generated-preview.txt"
grep -q "No data was changed" "$temporary_directory/generated-preview.txt"
"$binary" --data "$generated_data_file" plan explain "$generated_plan" \
    > "$temporary_directory/proposal-explanation.txt"
grep -q "Proposal explanation: schedule #1" "$temporary_directory/proposal-explanation.txt"
grep -q "Current half-marathon equivalent: 1:57:49" \
    "$temporary_directory/proposal-explanation.txt"
grep -q "Week 1 .*foundation, 30.0 km core, 12.0 km long run" \
    "$temporary_directory/proposal-explanation.txt"
grep -q "Volume method: baseline" "$temporary_directory/proposal-explanation.txt"
"$binary" --data "$generated_data_file" plan explain "$generated_plan" 2026-07-21 \
    > "$temporary_directory/proposal-workout-explanation.txt"
grep -q "Workout explanation" "$temporary_directory/proposal-workout-explanation.txt"
grep -q "Recipe: aerobic-intervals" "$temporary_directory/proposal-workout-explanation.txt"
grep -q "Allocation: quality; 6.0 km from a 30.0 km core week" \
    "$temporary_directory/proposal-workout-explanation.txt"
grep -q "Quality progression: foundation-aerobic-intervals; establish; phase week 1 of 2; 3.0 km work" \
    "$temporary_directory/proposal-workout-explanation.txt"
grep -q "INT-01:" "$temporary_directory/proposal-workout-explanation.txt"
unsupported_plan="$temporary_directory/unsupported-plan.json"
sed 's/"schema_version": 2/"schema_version": 3/' \
    "$generated_plan" > "$unsupported_plan"
if "$binary" --data "$generated_data_file" plan preview "$unsupported_plan" \
    > /dev/null 2> "$temporary_directory/unsupported-plan-error.txt"
then
    echo "expected an unsupported proposed-plan schema to be rejected" >&2
    exit 1
fi
grep -q "revision file schema_version must be 2" \
    "$temporary_directory/unsupported-plan-error.txt"

unsupported_generator_plan="$temporary_directory/unsupported-generator-plan.json"
sed 's/runningman-planner-v2/runningman-planner-unsupported/' \
    "$generated_plan" > "$unsupported_generator_plan"
if "$binary" --data "$generated_data_file" plan preview "$unsupported_generator_plan" \
    > /dev/null 2> "$temporary_directory/unsupported-generator-error.txt"
then
    echo "expected unsupported generator provenance to be rejected" >&2
    exit 1
fi
grep -q "generated plan provenance does not match" \
    "$temporary_directory/unsupported-generator-error.txt"

tampered_distance_plan="$temporary_directory/tampered-distance-plan.json"
sed 's/"allocated_distance_km": 6,/"allocated_distance_km": 6.5,/' \
    "$generated_plan" > "$tampered_distance_plan"
line_count_before=$(wc -l < "$generated_data_file" | tr -d ' ')
if "$binary" --data "$generated_data_file" plan apply "$tampered_distance_plan" \
    > /dev/null 2> "$temporary_directory/tampered-distance-error.txt"
then
    echo "expected a workout distance inconsistent with its decision to be rejected" >&2
    exit 1
fi
grep -q "workout decision records the wrong distance" \
    "$temporary_directory/tampered-distance-error.txt"
line_count_after=$(wc -l < "$generated_data_file" | tr -d ' ')
test "$line_count_before" = "$line_count_after"

tampered_quality_plan="$temporary_directory/tampered-quality-plan.json"
sed 's/"work_distance_km": 3,/"work_distance_km": 3.5,/' \
    "$generated_plan" > "$tampered_quality_plan"
if "$binary" --data "$generated_data_file" plan preview "$tampered_quality_plan" \
    > /dev/null 2> "$temporary_directory/tampered-quality-error.txt"
then
    echo "expected mismatched quality progression to be rejected" >&2
    exit 1
fi
grep -q "quality-progression decision does not match its workout segments" \
    "$temporary_directory/tampered-quality-error.txt"

tampered_assessment_plan="$temporary_directory/tampered-assessment-plan.json"
sed 's/"recommended_target_seconds": 7200/"recommended_target_seconds": 7100/g' \
    "$generated_plan" > "$tampered_assessment_plan"
if "$binary" --data "$generated_data_file" plan preview "$tampered_assessment_plan" \
    > /dev/null 2> "$temporary_directory/tampered-assessment-error.txt"
then
    echo "expected an edited assessment to be rejected" >&2
    exit 1
fi
grep -q "generated assessment does not match" \
    "$temporary_directory/tampered-assessment-error.txt"

tampered_volume_plan="$temporary_directory/tampered-volume-plan.json"
sed 's/"maximum_peak_relative_to_baseline": 1.5/"maximum_peak_relative_to_baseline": 1.0/' \
    "$generated_plan" > "$tampered_volume_plan"
if "$binary" --data "$generated_data_file" plan preview "$tampered_volume_plan" \
    > /dev/null 2> "$temporary_directory/tampered-volume-error.txt"
then
    echo "expected a proposal exceeding its embedded volume policy to be rejected" >&2
    exit 1
fi
grep -q "weekly volume exceeds" "$temporary_directory/tampered-volume-error.txt"

tampered_spacing_plan="$temporary_directory/tampered-spacing-plan.json"
sed 's/"minimum_easy_or_rest_days_between_demanding_sessions": 1/"minimum_easy_or_rest_days_between_demanding_sessions": 3/' \
    "$generated_plan" > "$tampered_spacing_plan"
if "$binary" --data "$generated_data_file" plan preview "$tampered_spacing_plan" \
    > /dev/null 2> "$temporary_directory/tampered-spacing-error.txt"
then
    echo "expected a proposal violating demanding-session spacing to be rejected" >&2
    exit 1
fi
grep -q "demanding sessions do not have enough" \
    "$temporary_directory/tampered-spacing-error.txt"

"$binary" --data "$generated_data_file" plan apply "$generated_plan" \
    > "$temporary_directory/generated-apply.txt"
grep -q "Applied schedule #2" "$temporary_directory/generated-apply.txt"
grep -q '"plan_provenance":{' "$generated_data_file"
grep -q '"generator_version":"runningman-planner-v2"' "$generated_data_file"
grep -q '"decision":{"recipe_id":"aerobic-intervals"' "$generated_data_file"
grep -q '"plan_weeks":\[' "$generated_data_file"
active_markdown="$temporary_directory/active-training-plan.md"
"$binary" --data "$generated_data_file" plan markdown > "$active_markdown"
grep -q "# Half-marathon training plan" "$active_markdown"
grep -q "## Week 13: Race" "$active_markdown"
saved_active_markdown="$temporary_directory/saved-active-training-plan.md"
"$binary" --data "$generated_data_file" plan markdown \
    --output "$saved_active_markdown" > "$temporary_directory/active-markdown.txt"
grep -Fq "Wrote a friendly 13-week training plan to $saved_active_markdown" \
    "$temporary_directory/active-markdown.txt"
cmp "$active_markdown" "$saved_active_markdown"
"$binary" --data "$generated_data_file" 2026-07-21 \
    > "$temporary_directory/generated-reload.txt"
grep -q "Schedule #2" "$temporary_directory/generated-reload.txt"
if "$binary" --data "$generated_data_file" today 2026-07-21 \
    > /dev/null 2> "$temporary_directory/obsolete-today-date-error.txt"
then
    echo "expected the obsolete 'today DATE' form to be rejected" >&2
    exit 1
fi
grep -q "too many arguments" "$temporary_directory/obsolete-today-date-error.txt"
line_count_before=$(wc -l < "$generated_data_file" | tr -d ' ')
"$binary" --data "$generated_data_file" plan explain \
    > "$temporary_directory/schedule-explanation.txt"
line_count_after=$(wc -l < "$generated_data_file" | tr -d ' ')
test "$line_count_before" = "$line_count_after"
grep -q "Schedule #2 explanation" "$temporary_directory/schedule-explanation.txt"
grep -q "Macrocycle explanation" "$temporary_directory/schedule-explanation.txt"
grep -q "Volume method: recovery_reduction" "$temporary_directory/schedule-explanation.txt"
"$binary" --data "$generated_data_file" plan explain 2026-07-21 \
    > "$temporary_directory/schedule-workout-explanation.txt"
grep -q "Schedule #2 explanation" "$temporary_directory/schedule-workout-explanation.txt"
grep -q "Recipe: aerobic-intervals" "$temporary_directory/schedule-workout-explanation.txt"
future_plan_source="$temporary_directory/future-plan-source.json"
future_plan="$temporary_directory/future-plan.json"
"$binary" --data "$generated_data_file" plan generate examples/runner-profile.json \
    --output "$future_plan_source" >/dev/null
sed 's/"effective_from": "2026-07-20"/"effective_from": "2026-07-27"/' \
    "$future_plan_source" > "$future_plan"
"$binary" --data "$generated_data_file" plan preview "$future_plan" \
    > "$temporary_directory/future-preview.txt"
grep -q "Replacement span: 2026-07-27 through 2026-10-18 (84 daily entries)" \
    "$temporary_directory/future-preview.txt"
grep -q "Validation context: complete 91-day plan from 2026-07-20" \
    "$temporary_directory/future-preview.txt"

tampered_history_plan="$temporary_directory/tampered-history-plan.json"
sed 's/Easy aerobic run: 6.0 km/Edited historical run: 6.0 km/' \
    "$future_plan" > "$tampered_history_plan"
if "$binary" --data "$generated_data_file" plan preview "$tampered_history_plan" \
    > /dev/null 2> "$temporary_directory/tampered-history-error.txt"
then
    echo "expected a pre-effective workout edit to be rejected" >&2
    exit 1
fi
grep -q "workouts before effective_from must exactly match" \
    "$temporary_directory/tampered-history-error.txt"

"$binary" --data "$generated_data_file" plan apply "$future_plan" \
    > "$temporary_directory/future-apply.txt"
grep -q "Applied schedule #3, effective 2026-07-27" \
    "$temporary_directory/future-apply.txt"
"$binary" --data "$generated_data_file" 2026-07-26 \
    > "$temporary_directory/future-prefix.txt"
grep -q "Schedule #2" "$temporary_directory/future-prefix.txt"
"$binary" --data "$generated_data_file" 2026-07-27 \
    > "$temporary_directory/future-effective.txt"
grep -q "Schedule #3" "$temporary_directory/future-effective.txt"

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

"$binary" --data "$data_file" 2026-07-20 > "$temporary_directory/today.txt"
grep -q "Core easy aerobic run" "$temporary_directory/today.txt"
grep -q "6.0 km at 6:15–7:00/km, 8.6–9.6 km/h (37:30–42:00)" \
    "$temporary_directory/today.txt"
grep -q "Bicycle replacement (conservative time-and-effort match; not a proven 1:1 equivalence)" \
    "$temporary_directory/today.txt"
grep -q "Total ride time: 40:00" "$temporary_directory/today.txt"
if grep -q "Expected total time: 37:30–42:00" "$temporary_directory/today.txt"; then
    echo "expected a single-segment workout not to repeat its duration" >&2
    exit 1
fi

printf '\ncompleted\n8.2\n52:00\n139\n3\n0\nComfortable\n' |
    "$binary" --data "$data_file" log 2026-07-22 > "$temporary_directory/interactive.txt"
grep -q "Recorded completed" "$temporary_directory/interactive.txt"

"$binary" --data "$data_file" schedule --weeks 4 --from 2026-07-20 > "$temporary_directory/schedule.txt"
grep -q "Week 4" "$temporary_directory/schedule.txt"
grep -q "2026-08-15 Saturday: long — 13.0 km" "$temporary_directory/schedule.txt"
grep -q "13.0 km at 6:15–6:55/km, 8.7–9.6 km/h (1:21:15–1:29:55)" \
    "$temporary_directory/schedule.txt"
grep -q "Total ride time: 1:25:00" "$temporary_directory/schedule.txt"

"$binary" --data "$data_file" log 2026-07-23 \
    --sport cycling \
    --duration 45:00 \
    --avg-hr 138 \
    --rpe 3 \
    --pain 0 \
    --notes "Pain-free bicycle replacement" > "$temporary_directory/cycling-log.txt"
grep -q "Recorded completed" "$temporary_directory/cycling-log.txt"

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

"$binary" --data "$data_file" 2026-10-18 > "$temporary_directory/revised-day.txt"
grep -q "Half marathon. Start controlled" "$temporary_directory/revised-day.txt"
grep -q "Schedule #2" "$temporary_directory/revised-day.txt"

"$binary" --data "$data_file" log 2026-08-01 \
    --distance 15.1 \
    --duration 1:40:30 \
    --rpe 5 \
    --pain 0 > "$temporary_directory/post-revision-correction.txt"
grep -q "supersedes activity" "$temporary_directory/post-revision-correction.txt"
tail -n 1 "$data_file" | grep -q '"schedule_id":1,"workout_id":13'

"$binary" --data "$data_file" 2026-10-05 > "$temporary_directory/taper-week.txt"
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
grep -q "completed, cycling, 0:45:00" "$temporary_directory/history.txt"
grep -q "Next morning Oura: Sleep 65, Readiness 59" "$temporary_directory/history.txt"

"$binary" --data "$data_file" compare --weeks 1 --ending 2026-07-26 > "$temporary_directory/compare.txt"
grep -q "Pain was reported" "$temporary_directory/compare.txt"
grep -q "do not assume they were rest days" "$temporary_directory/compare.txt"
grep -q "Readiness was below 70" "$temporary_directory/compare.txt"

"$binary" --data "$data_file" review --weeks 1 --ending 2026-07-26 > "$temporary_directory/check-in.md"
grep -q "# Running training check-in" "$temporary_directory/check-in.md"
grep -q "## Training context" "$temporary_directory/check-in.md"
grep -q 'Planner: runningman-planner-v2; profile `example-half-marathon-runner`; policy `half-marathon` v2' \
    "$temporary_directory/check-in.md"
grep -q "Supported race-date outcome range: 1:48:42–2:02:32" \
    "$temporary_directory/check-in.md"
grep -q "## Signals for review" "$temporary_directory/check-in.md"
grep -q "## Applicable planning guardrails" "$temporary_directory/check-in.md"
grep -q '`RECIPE-01` quality: at most 22% of core weekly distance' \
    "$temporary_directory/check-in.md"
grep -q "## Complete remaining program" "$temporary_directory/check-in.md"
grep -q "## Whole-program revision contract" "$temporary_directory/check-in.md"
grep -q "2026-10-18 Sunday — race" "$temporary_directory/check-in.md"
grep -q 'It must use `schema_version: 2`' "$temporary_directory/check-in.md"
grep -Eq "active by period end|known upcoming at period end|recorded after this period" \
    "$temporary_directory/check-in.md"
grep -Fq 'Easy \| relaxed' "$temporary_directory/check-in.md"
grep -q "right knee" "$temporary_directory/check-in.md"
grep -q "Sleep 65/100; Readiness 59/100" "$temporary_directory/check-in.md"
grep -q "Classification: \\*\\*INSUFFICIENT_DATA\\*\\*" "$temporary_directory/check-in.md"
grep -q "REVIEW-COVERAGE-ACTIVITY-01.*FIRED" "$temporary_directory/check-in.md"
grep -q "REVIEW-PAIN-01.*FIRED" "$temporary_directory/check-in.md"

line_count=$(wc -l < "$data_file" | tr -d ' ')
test "$line_count" = "193"

"$binary" --data "$data_file" export --format jsonl > "$temporary_directory/raw.jsonl"
cmp "$data_file" "$temporary_directory/raw.jsonl"
grep -q '"sport":"cycling"' "$temporary_directory/raw.jsonl"

keep_review_data="$temporary_directory/keep-review.jsonl"
"$binary" --data "$keep_review_data" init 2026-07-20 >/dev/null
"$binary" --data "$keep_review_data" log 2026-07-20 \
    --distance 6 --rpe 3 --pain 0 >/dev/null
"$binary" --data "$keep_review_data" log 2026-07-21 \
    --distance 6 --rpe 6 --pain 0 >/dev/null
"$binary" --data "$keep_review_data" log 2026-07-23 \
    --distance 6 --rpe 3 --pain 0 >/dev/null
"$binary" --data "$keep_review_data" log 2026-07-25 \
    --distance 12 --rpe 5 --pain 0 >/dev/null
"$binary" --data "$keep_review_data" check-in 2026-07-21 \
    --sleep 82 --readiness 78 >/dev/null
"$binary" --data "$keep_review_data" check-in 2026-07-22 \
    --sleep 65 --readiness 69 >/dev/null
keep_line_count=$(wc -l < "$keep_review_data" | tr -d ' ')
"$binary" --data "$keep_review_data" review --weeks 1 --ending 2026-07-26 \
    > "$temporary_directory/keep-review.md"
grep -q "Classification: \\*\\*KEEP_PLAN\\*\\*" "$temporary_directory/keep-review.md"
grep -q "REVIEW-RECOVERY-PERSISTENCE-01.*passed" "$temporary_directory/keep-review.md"
test "$keep_line_count" = "$(wc -l < "$keep_review_data" | tr -d ' ')"

"$binary" --data "$keep_review_data" log 2026-08-01 \
    --distance 15 --rpe 10 --pain 5 >/dev/null
"$binary" --data "$keep_review_data" review --weeks 1 --ending 2026-07-26 \
    > "$temporary_directory/no-future-leakage-review.md"
grep -q "Classification: \\*\\*KEEP_PLAN\\*\\*" \
    "$temporary_directory/no-future-leakage-review.md"

review_required_data="$temporary_directory/review-required.jsonl"
cp "$keep_review_data" "$review_required_data"
"$binary" --data "$review_required_data" log 2026-07-21 \
    --modified --distance 5 --rpe 9 --pain 2 \
    --reason "Stopped early" >/dev/null
"$binary" --data "$review_required_data" review --weeks 1 --ending 2026-07-26 \
    > "$temporary_directory/review-required.md"
grep -q "Classification: \\*\\*REVIEW_REQUIRED\\*\\*" \
    "$temporary_directory/review-required.md"
grep -q "REVIEW-ADHERENCE-01.*FIRED" "$temporary_directory/review-required.md"
grep -q "REVIEW-PAIN-01.*FIRED" "$temporary_directory/review-required.md"
grep -q "REVIEW-DIFFICULTY-01.*FIRED" "$temporary_directory/review-required.md"

sparse_review_data="$temporary_directory/sparse-review.jsonl"
"$binary" --data "$sparse_review_data" init 2026-07-20 >/dev/null
"$binary" --data "$sparse_review_data" log 2026-07-20 \
    --distance 6 --rpe 3 --pain 0 >/dev/null
"$binary" --data "$sparse_review_data" review --weeks 1 --ending 2026-07-26 \
    > "$temporary_directory/sparse-review.md"
grep -q "Classification: \\*\\*INSUFFICIENT_DATA\\*\\*" \
    "$temporary_directory/sparse-review.md"
grep -q "REVIEW-COVERAGE-RECOVERY-01.*FIRED" "$temporary_directory/sparse-review.md"

if "$binary" --data "$data_file" log 2026-07-22 --distance 8 --rpe 11 >/dev/null 2>&1; then
    echo "expected invalid RPE to fail" >&2
    exit 1
fi
