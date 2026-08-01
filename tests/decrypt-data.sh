#!/bin/sh
set -eu

repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
decryptor="$repository_root/scripts/decrypt-data"

temporary_directory=$(mktemp -d "${TMPDIR:-/tmp}/runningman-decrypt-test.XXXXXX")
trap 'rm -rf "$temporary_directory"' EXIT

fake_gpg="$temporary_directory/gpg"
cat > "$fake_gpg" <<'EOF'
#!/bin/sh
set -eu

output_path=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --pinentry-mode)
            test "$2" = "loopback"
            shift 2
            ;;
        --output)
            output_path=$2
            shift 2
            ;;
        --decrypt)
            shift 2
            ;;
        *)
            echo "unexpected fake GPG argument: $1" >&2
            exit 1
            ;;
    esac
done

cp "$FAKE_DECRYPTED_FILE" "$output_path"
if [ "${FAIL_DECRYPTION:-false}" = true ]; then
    exit 1
fi
EOF
chmod +x "$fake_gpg"

encrypted_file="$temporary_directory/training.jsonl.gpg"
data_file="$temporary_directory/training.jsonl"
decrypted_file="$temporary_directory/decrypted.jsonl"
printf '%s\n' 'fake encrypted content' > "$encrypted_file"

schedule='{"schema_version":2,"type":"schedule","id":1}'
activity_one='{"schema_version":2,"type":"activity","id":1}'
activity_two='{"schema_version":2,"type":"activity","id":2}'
check_in='{"schema_version":2,"type":"morning_check_in","id":1}'

printf '%s\n' "$schedule" "$activity_one" > "$decrypted_file"
GPG_BIN="$fake_gpg" \
    FAKE_DECRYPTED_FILE="$decrypted_file" \
    "$decryptor" \
    --input "$encrypted_file" \
    --data "$data_file" > "$temporary_directory/install.txt"
cmp -s "$decrypted_file" "$data_file"
grep -Fq 'Installed decrypted data' "$temporary_directory/install.txt"

GPG_BIN="$fake_gpg" \
    FAKE_DECRYPTED_FILE="$decrypted_file" \
    "$decryptor" \
    --input "$encrypted_file" \
    --data "$data_file" > "$temporary_directory/identical.txt"
grep -Fq 'already identical' "$temporary_directory/identical.txt"

printf '%s\n' "$schedule" "$activity_one" "$activity_two" > "$data_file"
GPG_BIN="$fake_gpg" \
    FAKE_DECRYPTED_FILE="$decrypted_file" \
    "$decryptor" \
    --input "$encrypted_file" \
    --data "$data_file" > "$temporary_directory/local-newer.txt"
grep -Fq 'Local data is newer' "$temporary_directory/local-newer.txt"
grep -Fxq "$activity_two" "$data_file"

printf '%s\n' "$schedule" "$activity_one" > "$data_file"
printf '%s\n' "$schedule" "$activity_one" "$check_in" > "$decrypted_file"
GPG_BIN="$fake_gpg" \
    FAKE_DECRYPTED_FILE="$decrypted_file" \
    "$decryptor" \
    --input "$encrypted_file" \
    --data "$data_file" > "$temporary_directory/no-activity.txt"
grep -Fq 'no newer activity records' "$temporary_directory/no-activity.txt"
line_count=$(wc -l < "$data_file" | tr -d '[:space:]')
test "$line_count" -eq 2

printf '%s\n' "$schedule" "$activity_one" "$activity_two" > "$decrypted_file"
GPG_BIN="$fake_gpg" \
    FAKE_DECRYPTED_FILE="$decrypted_file" \
    "$decryptor" \
    --input "$encrypted_file" \
    --data "$data_file" > "$temporary_directory/remote-newer.txt"
cmp -s "$decrypted_file" "$data_file"
grep -Fq 'Installed newer decrypted activity data' "$temporary_directory/remote-newer.txt"

printf '%s\n' "$schedule" '{"schema_version":2,"type":"activity","id":9}' > "$data_file"
printf '%s\n' "$schedule" "$activity_one" "$activity_two" > "$decrypted_file"
if GPG_BIN="$fake_gpg" \
    FAKE_DECRYPTED_FILE="$decrypted_file" \
    "$decryptor" \
    --input "$encrypted_file" \
    --data "$data_file" >/dev/null 2>&1
then
    echo "expected divergent logs to fail" >&2
    exit 1
fi
grep -Fq '"id":9' "$data_file"

printf '%s\n' 'preserve local data' > "$data_file"
if GPG_BIN="$fake_gpg" \
    FAKE_DECRYPTED_FILE="$decrypted_file" \
    FAIL_DECRYPTION=true \
    "$decryptor" \
    --input "$encrypted_file" \
    --data "$data_file" >/dev/null 2>&1
then
    echo "expected failed decryption to return a non-zero status" >&2
    exit 1
fi
grep -Fxq 'preserve local data' "$data_file"
