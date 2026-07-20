#!/bin/sh
set -eu

repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
importer="$repository_root/scripts/import-polar"
fixture="$repository_root/tests/fixtures/polar-observations.json"
image="$repository_root/tests/fixtures/Screenshot 2026-07-20.png"

temporary_directory=$(mktemp -d "${TMPDIR:-/tmp}/runningman-polar-test.XXXXXX")
trap 'rm -rf "$temporary_directory"' EXIT

capture_file="$temporary_directory/captured-arguments.txt"
fake_runningman="$temporary_directory/runningman"
cat > "$fake_runningman" <<'EOF'
#!/bin/sh
set -eu
for argument in "$@"; do
    if [ "$argument" = "today" ]; then
        printf '%s\n' 'Planned distance: 6.0 km'
        exit 0
    fi
done
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
    /^  # --distance 6.0  # planned distance$/ { print "  --distance 6.0"; next }
    /^  # --rpe 1-10$/ { print "  --rpe 4"; next }
    /^  # --pain 0-10$/ { print "  --pain 0"; next }
    { print }
' "$command_file" > "$edited_file"
mv "$edited_file" "$command_file"
EOF
chmod +x "$fake_editor"

data_file="$temporary_directory/training.jsonl"
image_hash=$(shasum -a 256 "$image" | awk '{print $1}')
printf '%s\n' \
    "{\"schema_version\":1,\"type\":\"activity\",\"id\":1,\"date\":\"2026-07-20\",\"notes\":\"source_sha256=$image_hash\",\"recorded_at\":1}" \
    > "$data_file"

RUNNINGMAN_BIN="$fake_runningman" \
    "$importer" \
    --dry-run \
    --ocr-fixture "$fixture" \
    --data "$data_file" \
    "$image" > "$temporary_directory/dry-run.txt"

grep -q "# WARNING: this date already has an activity" "$temporary_directory/dry-run.txt"
grep -q "# WARNING: this exact image hash already appears" "$temporary_directory/dry-run.txt"
grep -q -- "--duration '0:41:51'" "$temporary_directory/dry-run.txt"
grep -q -- "--avg-hr 138" "$temporary_directory/dry-run.txt"
grep -q "  # --distance 6.0  # planned distance" "$temporary_directory/dry-run.txt"
grep -q "  # --rpe 1-10" "$temporary_directory/dry-run.txt"
grep -q "  # --pain 0-10" "$temporary_directory/dry-run.txt"
grep -q "max HR 167 bpm" "$temporary_directory/dry-run.txt"
grep -q "HR zones Z1 00:03:21, Z2 00:07:10, Z3 00:16:23, Z4 00:14:55, Z5 00:00:02" \
    "$temporary_directory/dry-run.txt"

printf 'y\n' |
    EDITOR="$fake_editor" \
    RUNNINGMAN_BIN="$fake_runningman" \
    CAPTURE_FILE="$capture_file" \
    "$importer" \
    --ocr-fixture "$fixture" \
    --data "$data_file" \
    "$image" > "$temporary_directory/import.txt"

grep -Fxq -- "--data" "$capture_file"
grep -Fxq "$data_file" "$capture_file"
grep -Fxq -- "--duration" "$capture_file"
grep -Fxq "0:41:51" "$capture_file"
grep -Fxq -- "--avg-hr" "$capture_file"
grep -Fxq "138" "$capture_file"
grep -Fxq -- "--distance" "$capture_file"
grep -Fxq "6.0" "$capture_file"
grep -Fxq -- "--rpe" "$capture_file"
grep -Fxq "4" "$capture_file"
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
    --ocr-fixture "$fixture" \
    "$image" > "$temporary_directory/cancel.txt"

grep -q "Editor exited with status 42; import cancelled" "$temporary_directory/cancel.txt"
test ! -e "$capture_file"

if RUNNINGMAN_BIN="$fake_runningman" \
    "$importer" \
    --dry-run \
    --date 2026-02-30 \
    --ocr-fixture "$fixture" \
    "$image" >/dev/null 2>&1
then
    echo "expected an invalid date to fail" >&2
    exit 1
fi
