#!/bin/sh
set -eu

binary=$1
temporary_directory=$(mktemp -d "${TMPDIR:-/tmp}/runningman-test.XXXXXX")
trap 'rm -rf "$temporary_directory"' EXIT

data_file="$temporary_directory/training.jsonl"

"$binary" --data "$data_file" init 2026-07-20 > "$temporary_directory/init.txt"
grep -q "immutable 13-week periodized running schedule" "$temporary_directory/init.txt"

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

revision_file="$temporary_directory/revision.json"
cat > "$revision_file" <<'JSON'
{
  "schema_version": 1,
  "base_schedule_id": 1,
  "effective_from": "2026-10-12",
  "reason": "Reviewed taper after twelve weeks of training evidence.",
  "name": "Reviewed race week",
  "workouts": [
    {
      "date": "2026-10-12", "phase": "race", "kind": "easy",
      "intensity": "Very easy", "details": "Reviewed short easy run.",
      "segments": [{"kind":"distance","label":"Run","distance_km":4,"pace_fast_seconds_per_km":395,"pace_slow_seconds_per_km":440}]
    },
    {
      "date": "2026-10-13", "phase": "race", "kind": "strides",
      "intensity": "Relaxed and quick", "details": "Four relaxed strides.",
      "segments": [{"kind":"repeat","label":"Strides","repetitions":4,"duration_seconds":20,"recovery_seconds":60}]
    },
    {
      "date": "2026-10-14", "phase": "race", "kind": "rest",
      "intensity": "Rest", "details": "Full rest.",
      "segments": [{"kind":"rest","label":"Rest","notes":"Full rest."}]
    },
    {
      "date": "2026-10-15", "phase": "race", "kind": "easy",
      "intensity": "Very easy", "details": "Short relaxed run.",
      "segments": [{"kind":"distance","label":"Run","distance_km":3,"pace_fast_seconds_per_km":395,"pace_slow_seconds_per_km":440}]
    },
    {
      "date": "2026-10-16", "phase": "race", "kind": "rest",
      "intensity": "Rest", "details": "Full rest.",
      "segments": [{"kind":"rest","label":"Rest","notes":"Full rest."}]
    },
    {
      "date": "2026-10-17", "phase": "race", "kind": "shakeout",
      "intensity": "Very easy", "details": "Optional short shakeout.",
      "distance_min_km": 0, "distance_max_km": 2,
      "segments": [{"kind":"distance","label":"Run","distance_km":2,"pace_fast_seconds_per_km":395,"pace_slow_seconds_per_km":440}]
    },
    {
      "date": "2026-10-18", "phase": "race", "kind": "race-reviewed",
      "intensity": "Target approximately 5:41/km", "details": "Reviewed half marathon race plan.",
      "segments": [{"kind":"distance","label":"Race","distance_km":21.0975,"pace_fast_seconds_per_km":338,"pace_slow_seconds_per_km":348}]
    }
  ]
}
JSON

"$binary" --data "$data_file" plan preview "$revision_file" > "$temporary_directory/preview.txt"
grep -q "No data was changed" "$temporary_directory/preview.txt"
grep -q "race-reviewed.*changed" "$temporary_directory/preview.txt"

"$binary" --data "$data_file" plan apply "$revision_file" > "$temporary_directory/revision.txt"
grep -q "Applied schedule #2" "$temporary_directory/revision.txt"
if "$binary" --data "$data_file" plan preview "$revision_file" >/dev/null 2>&1; then
    echo "expected a stale plan revision to fail" >&2
    exit 1
fi

"$binary" --data "$data_file" today 2026-10-18 > "$temporary_directory/revised-day.txt"
grep -q "Reviewed half marathon race plan" "$temporary_directory/revised-day.txt"
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
grep -q "2026-10-18 Sunday — race-reviewed" "$temporary_directory/check-in.md"
grep -Eq "known upcoming at period end|recorded after this period" "$temporary_directory/check-in.md"
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
