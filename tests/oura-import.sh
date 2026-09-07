#!/bin/sh
set -eu

repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
importer="$repository_root/scripts/import-oura"
fixture="$repository_root/tests/fixtures/oura-trends.csv"

temporary_directory=$(mktemp -d "${TMPDIR:-/tmp}/runningman-oura-test.XXXXXX")
trap 'rm -rf "$temporary_directory"' EXIT

capture_file="$temporary_directory/captured-arguments.txt"
fake_runningman="$temporary_directory/runningman"
cat > "$fake_runningman" <<'EOF'
#!/bin/sh
set -eu
: "${CAPTURE_FILE:?}"
first=true
for argument in "$@"; do
    if [ "$first" = false ]; then
        printf '\t' >> "$CAPTURE_FILE"
    fi
    printf '%s' "$argument" >> "$CAPTURE_FILE"
    first=false
done
printf '\n' >> "$CAPTURE_FILE"
EOF
chmod +x "$fake_runningman"

data_file="$temporary_directory/training.jsonl"
printf '%s\n' \
    '{"schema_version":2,"type":"morning_check_in","id":1,"date":"2026-08-11","notes":"","sleep_score":80,"readiness_score":80,"recorded_at":1}' \
    > "$data_file"

RUNNINGMAN_BIN="$fake_runningman" \
    "$importer" --dry-run --data "$data_file" "$fixture" \
    > "$temporary_directory/dry-run.txt"

grep -q '2026-08-11.*88.*88.*already recorded; skipped' \
    "$temporary_directory/dry-run.txt"
grep -q '2026-08-12.*87.*83.*missing; will check in' \
    "$temporary_directory/dry-run.txt"
grep -q '2026-08-13.*77.*81.*missing; will check in' \
    "$temporary_directory/dry-run.txt"
grep -q '2 missing check-in(s); 1 already recorded' \
    "$temporary_directory/dry-run.txt"
grep -q 'Dry run: no check-ins recorded' "$temporary_directory/dry-run.txt"
test ! -e "$capture_file"

reordered_csv="$temporary_directory/reordered.csv"
printf 'date,Readiness Score,Sleep Score\r\n2026-08-19,82,78\r\n' > "$reordered_csv"
printf 'y\n' |
    RUNNINGMAN_BIN="$fake_runningman" \
    CAPTURE_FILE="$temporary_directory/reordered-arguments.txt" \
    "$importer" --data "$data_file" "$reordered_csv" \
    > "$temporary_directory/reordered.txt"
grep -q -- 'check-in.*2026-08-19.*--sleep.*78.*--readiness.*82' \
    "$temporary_directory/reordered-arguments.txt"

bad_header="$temporary_directory/bad-header.csv"
printf 'date,Sleep Score,Sleep Score\n2026-08-19,78,78\n' > "$bad_header"
if RUNNINGMAN_BIN="$fake_runningman" \
    "$importer" --dry-run --data "$data_file" "$bad_header" \
    > "$temporary_directory/bad-header.txt" 2>&1
then
    echo "expected missing Readiness column to fail" >&2
    exit 1
fi
grep -q 'Expected CSV columns' "$temporary_directory/bad-header.txt"
if grep -q 'no score rows' "$temporary_directory/bad-header.txt"; then
    echo "header failure must not also report an empty CSV" >&2
    exit 1
fi

empty_csv="$temporary_directory/empty.csv"
printf 'date,Sleep Score,Readiness Score\n\n' > "$empty_csv"
if RUNNINGMAN_BIN="$fake_runningman" \
    "$importer" --dry-run --data "$data_file" "$empty_csv" \
    > "$temporary_directory/empty.txt" 2>&1
then
    echo "expected a CSV without score rows to fail" >&2
    exit 1
fi
grep -q 'no score rows' "$temporary_directory/empty.txt"

printf 'n\n' |
    RUNNINGMAN_BIN="$fake_runningman" \
    CAPTURE_FILE="$capture_file" \
    "$importer" --data "$data_file" "$fixture" \
    > "$temporary_directory/cancel.txt"

grep -q 'Import cancelled' "$temporary_directory/cancel.txt"
test ! -e "$capture_file"

printf 'y\n' |
    RUNNINGMAN_BIN="$fake_runningman" \
    CAPTURE_FILE="$capture_file" \
    "$importer" --data "$data_file" "$fixture" \
    > "$temporary_directory/import.txt"

test "$(wc -l < "$capture_file" | tr -d ' ')" -eq 2
grep -q -- "--data.*$data_file.*check-in.*2026-08-12.*--sleep.*87.*--readiness.*83" \
    "$capture_file"
grep -q -- "--data.*$data_file.*check-in.*2026-08-13.*--sleep.*77.*--readiness.*81" \
    "$capture_file"
grep -q 'Oura Trends import; source oura-trends.csv' "$capture_file"
grep -q 'Imported 2 Oura check-in(s)' "$temporary_directory/import.txt"

trend_directory="$temporary_directory/oura_trends"
mkdir "$trend_directory"
cp "$fixture" "$trend_directory/older.csv"
cp "$fixture" "$trend_directory/newer.csv"
touch -t 202608170100 "$trend_directory/older.csv"
touch -t 202608180100 "$trend_directory/newer.csv"

OURA_TREND_DIR="$trend_directory" \
RUNNINGMAN_BIN="$fake_runningman" \
    "$importer" --dry-run --data "$data_file" \
    > "$temporary_directory/default-file.txt"

grep -q 'Oura Trends from newer.csv' "$temporary_directory/default-file.txt"

invalid_score="$temporary_directory/invalid-score.csv"
printf '%s\n' \
    'date,Sleep Score,Readiness Score' \
    '2026-08-12,101,83' > "$invalid_score"
if RUNNINGMAN_BIN="$fake_runningman" \
    "$importer" --dry-run --data "$data_file" "$invalid_score" \
    > "$temporary_directory/invalid-score.txt" 2>&1
then
    echo "expected an invalid Oura score to fail" >&2
    exit 1
fi
grep -q 'Invalid Oura Sleep Score' "$temporary_directory/invalid-score.txt"

duplicate_date="$temporary_directory/duplicate-date.csv"
printf '%s\n' \
    'date,Sleep Score,Readiness Score' \
    '2026-08-12,87,83' \
    '2026-08-12,88,84' > "$duplicate_date"
if RUNNINGMAN_BIN="$fake_runningman" \
    "$importer" --dry-run --data "$data_file" "$duplicate_date" \
    > "$temporary_directory/duplicate-date.txt" 2>&1
then
    echo "expected a duplicate Oura date to fail" >&2
    exit 1
fi
grep -q 'Duplicate Oura date' "$temporary_directory/duplicate-date.txt"

invalid_date="$temporary_directory/invalid-date.csv"
printf '%s\n' \
    'date,Sleep Score,Readiness Score' \
    '2026-02-30,87,83' > "$invalid_date"
if RUNNINGMAN_BIN="$fake_runningman" \
    "$importer" --dry-run --data "$data_file" "$invalid_date" \
    > "$temporary_directory/invalid-date.txt" 2>&1
then
    echo "expected an invalid Oura date to fail" >&2
    exit 1
fi
grep -q 'invalid calendar date' "$temporary_directory/invalid-date.txt"
