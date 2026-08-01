#!/bin/sh
set -eu

repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
encryptor="$repository_root/scripts/encrypt-data"
recipient_fingerprint="F66219D7C10E26FF1000B9932E2818269A17B4DB"

temporary_directory=$(mktemp -d "${TMPDIR:-/tmp}/runningman-encrypt-test.XXXXXX")
trap 'rm -rf "$temporary_directory"' EXIT

fake_gpg="$temporary_directory/gpg"
cat > "$fake_gpg" <<'EOF'
#!/bin/sh
set -eu

if [ "${1:-}" = "--batch" ] && [ "${2:-}" = "--list-keys" ]; then
    printf '%s\n' "$3" > "$CAPTURED_RECIPIENT"
    if [ "${FAIL_RECIPIENT_LOOKUP:-false}" = true ]; then
        exit 1
    fi
    exit 0
fi

output_path=""
recipient=""
input_path=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --batch|--encrypt)
            shift
            ;;
        --output)
            output_path=$2
            shift 2
            ;;
        --recipient)
            recipient=$2
            shift 2
            ;;
        *)
            input_path=$1
            shift
            ;;
    esac
done

printf 'encrypted for %s\n' "$recipient" > "$output_path"
cat "$input_path" >> "$output_path"
if [ "${FAIL_ENCRYPTION:-false}" = true ]; then
    exit 1
fi
EOF
chmod +x "$fake_gpg"

data_file="$temporary_directory/training.jsonl"
output_file="$temporary_directory/training.jsonl.gpg"
captured_recipient="$temporary_directory/recipient.txt"
printf '%s\n' '{"schema_version":2,"type":"activity","id":1}' > "$data_file"
printf '%s\n' 'old encrypted snapshot' > "$output_file"

GPG_BIN="$fake_gpg" \
    CAPTURED_RECIPIENT="$captured_recipient" \
    "$encryptor" \
    --data "$data_file" \
    --output "$output_file" > "$temporary_directory/success.txt"

grep -Fxq "$recipient_fingerprint" "$captured_recipient"
grep -Fxq "encrypted for $recipient_fingerprint" "$output_file"
grep -Fq '"schema_version":2' "$output_file"
grep -Fq "Output: $output_file" "$temporary_directory/success.txt"

printf '%s\n' 'preserve this snapshot' > "$output_file"
if GPG_BIN="$fake_gpg" \
    CAPTURED_RECIPIENT="$captured_recipient" \
    FAIL_ENCRYPTION=true \
    "$encryptor" \
    --data "$data_file" \
    --output "$output_file" >/dev/null 2>&1
then
    echo "expected failed encryption to return a non-zero status" >&2
    exit 1
fi
grep -Fxq 'preserve this snapshot' "$output_file"

if GPG_BIN="$fake_gpg" \
    CAPTURED_RECIPIENT="$captured_recipient" \
    FAIL_RECIPIENT_LOOKUP=true \
    "$encryptor" \
    --data "$data_file" \
    --output "$output_file" >/dev/null 2>&1
then
    echo "expected a missing GPG recipient to fail" >&2
    exit 1
fi
grep -Fxq 'preserve this snapshot' "$output_file"

if GPG_BIN="$fake_gpg" \
    CAPTURED_RECIPIENT="$captured_recipient" \
    "$encryptor" \
    --data "$temporary_directory/missing.jsonl" >/dev/null 2>&1
then
    echo "expected a missing plaintext data file to fail" >&2
    exit 1
fi
