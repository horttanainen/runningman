#!/bin/sh
set -eu

repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
importer="$repository_root/scripts/import-garmin"
fixture="$repository_root/tests/fixtures/garmin-summary.json"

temporary_directory=$(mktemp -d "${TMPDIR:-/tmp}/runningman-garmin-test.XXXXXX")
trap 'rm -rf "$temporary_directory"' EXIT

capture_file="$temporary_directory/captured-arguments.txt"
fake_runningman="$temporary_directory/runningman"
cat > "$fake_runningman" <<'EOF'
#!/bin/sh
set -eu
: "${CAPTURE_FILE:?}"
printf '%s\n' "$@" > "$CAPTURE_FILE"
EOF
chmod +x "$fake_runningman"

fake_editor="$temporary_directory/editor"
cat > "$fake_editor" <<'EOF'
#!/bin/sh
set -eu
command_file=$1
edited_file="$command_file.edited"
awk '
    /^  # --rpe 1-10$/ { print "  --rpe 7"; next }
    /^  # --pain 0-10$/ { print "  --pain 0"; next }
    { print }
' "$command_file" > "$edited_file"
mv "$edited_file" "$command_file"
EOF
chmod +x "$fake_editor"

activity_file="$temporary_directory/activity.fit"
printf '%s\n' 'fixture FIT content' > "$activity_file"
activity_hash=$(shasum -a 256 "$activity_file" | awk '{print $1}')
data_file="$temporary_directory/training.jsonl"
printf '%s\n' \
    "{\"schema_version\":1,\"type\":\"activity\",\"id\":1,\"date\":\"2026-07-28\",\"notes\":\"source_fit_sha256=$activity_hash\",\"recorded_at\":1}" \
    > "$data_file"

RUNNINGMAN_BIN="$fake_runningman" \
    "$importer" \
    --dry-run \
    --summary-fixture "$fixture" \
    --data "$data_file" \
    "$activity_file" > "$temporary_directory/dry-run.txt"

grep -q "# WARNING: this date already has an activity" "$temporary_directory/dry-run.txt"
grep -q "# WARNING: this exact FIT activity hash already appears" "$temporary_directory/dry-run.txt"
grep -q -- "--sport cycling" "$temporary_directory/dry-run.txt"
grep -q -- "--distance 21.52" "$temporary_directory/dry-run.txt"
grep -q -- "--duration '46:23'" "$temporary_directory/dry-run.txt"
grep -q -- "--avg-hr 150" "$temporary_directory/dry-run.txt"
grep -q "max HR 171 bpm" "$temporary_directory/dry-run.txt"
grep -q "aerobic TE 2.2, anaerobic TE 0" "$temporary_directory/dry-run.txt"
grep -q "HR zones below Z1 0:26, Z1 9:48, Z2 26:10, Z3 9:55, Z4 0:00, Z5 0:00, above Z5 0:00" \
    "$temporary_directory/dry-run.txt"

RUNNINGMAN_BIN="$fake_runningman" \
    "$importer" \
    --dry-run \
    --sport running \
    --summary-fixture "$fixture" \
    "$activity_file" > "$temporary_directory/running-override.txt"

grep -q -- "--sport running" "$temporary_directory/running-override.txt"
grep -q "Garmin sport cycling, imported as running" \
    "$temporary_directory/running-override.txt"
if grep -q "If this ride replaced a planned run" "$temporary_directory/running-override.txt"; then
    echo "expected running import not to show cycling replacement guidance" >&2
    exit 1
fi

printf 'y\n' |
    EDITOR="$fake_editor" \
    RUNNINGMAN_BIN="$fake_runningman" \
    CAPTURE_FILE="$capture_file" \
    "$importer" \
    --summary-fixture "$fixture" \
    --data "$data_file" \
    "$activity_file" > "$temporary_directory/import.txt"

if [ ! -f "$capture_file" ]; then
    cat "$temporary_directory/import.txt" >&2
    echo "expected edited Garmin import command to execute" >&2
    exit 1
fi
grep -Fxq -- "--data" "$capture_file"
grep -Fxq "$data_file" "$capture_file"
grep -Fxq -- "--sport" "$capture_file"
grep -Fxq "cycling" "$capture_file"
grep -Fxq -- "--distance" "$capture_file"
grep -Fxq "21.52" "$capture_file"
grep -Fxq -- "--duration" "$capture_file"
grep -Fxq "46:23" "$capture_file"
grep -Fxq -- "--avg-hr" "$capture_file"
grep -Fxq "150" "$capture_file"
grep -Fxq -- "--rpe" "$capture_file"
grep -Fxq "7" "$capture_file"
grep -Fxq -- "--pain" "$capture_file"
grep -Fxq "0" "$capture_file"

cancel_editor="$temporary_directory/cancel-editor"
cat > "$cancel_editor" <<'EOF'
#!/bin/sh
exit 42
EOF
chmod +x "$cancel_editor"
rm -f "$capture_file"

printf 'y\n' |
    EDITOR="$cancel_editor" \
    RUNNINGMAN_BIN="$fake_runningman" \
    CAPTURE_FILE="$capture_file" \
    "$importer" \
    --summary-fixture "$fixture" \
    "$activity_file" > "$temporary_directory/cancel.txt"

grep -q "Editor exited with status 42; import cancelled" "$temporary_directory/cancel.txt"
test ! -e "$capture_file"

if RUNNINGMAN_BIN="$fake_runningman" \
    "$importer" \
    --dry-run \
    --date 2026-02-30 \
    --summary-fixture "$fixture" \
    "$activity_file" >/dev/null 2>&1
then
    echo "expected an invalid date to fail" >&2
    exit 1
fi

if RUNNINGMAN_BIN="$fake_runningman" \
    "$importer" \
    --dry-run \
    --sport swimming \
    --summary-fixture "$fixture" \
    "$activity_file" >/dev/null 2>&1
then
    echo "expected an unsupported sport override to fail" >&2
    exit 1
fi
