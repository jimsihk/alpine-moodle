#!/bin/sh
# Compare observable behavior of the v3 Bash installer and v4 /bin/sh installer.
set -eu

if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <v3-installer> <v4-installer>" >&2
    exit 2
fi
baseline=$1
candidate=$2
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

mkdir -p "$tmp/bin" "$tmp/moodle"
: > "$tmp/moodle/version.php"
cat > "$tmp/bin/php" <<'PHP'
#!/bin/sh
# The tested paths only need the Moodle core version.
printf '500\n'
PHP
chmod +x "$tmp/bin/php"

run_case() {
    local case_name script_path scenario status
    case_name=$1
    script_path=$2
    scenario=$3
    # Run each installer in a subshell so its exit status can be captured
    # without changing the harness's errexit behavior.
    case "$scenario" in
        no-options)
            if env PATH="$tmp/bin:$PATH" MOODLE_APP="$tmp/moodle" "$script_path" >"$tmp/$case_name.out" 2>"$tmp/$case_name.err"; then status=0; else status=$?; fi ;;
        empty-plugin-list)
            if env PATH="$tmp/bin:$PATH" MOODLE_APP="$tmp/moodle" MOODLE_RELEASE=5.0 "$script_path" -p '' >"$tmp/$case_name.out" 2>"$tmp/$case_name.err"; then status=0; else status=$?; fi ;;
        malformed-component)
            if env PATH="$tmp/bin:$PATH" MOODLE_APP="$tmp/moodle" MOODLE_RELEASE=5.0 "$script_path" -p invalidcomponent >"$tmp/$case_name.out" 2>"$tmp/$case_name.err"; then status=0; else status=$?; fi ;;
        unknown-plugin-type)
            if env PATH="$tmp/bin:$PATH" MOODLE_APP="$tmp/moodle" MOODLE_RELEASE=5.0 "$script_path" -p bogus_test >"$tmp/$case_name.out" 2>"$tmp/$case_name.err"; then status=0; else status=$?; fi ;;
        release-not-detectable)
            if env PATH="$tmp/bin:$PATH" MOODLE_APP="$tmp/moodle" "$script_path" -p bogus_test >"$tmp/$case_name.out" 2>"$tmp/$case_name.err"; then status=0; else status=$?; fi ;;
        *) echo "Unknown test case: $scenario" >&2; return 2 ;;
    esac
    printf '%s\n' "$status" > "$tmp/$case_name.status"
}

compare_case() {
    local case_name
    case_name=$1
    run_case "v3-$case_name" "$baseline" "$case_name"
    run_case "v4-$case_name" "$candidate" "$case_name"
    if ! cmp -s "$tmp/v3-$case_name.status" "$tmp/v4-$case_name.status" ||
       ! cmp -s "$tmp/v3-$case_name.out" "$tmp/v4-$case_name.out" ||
       ! cmp -s "$tmp/v3-$case_name.err" "$tmp/v4-$case_name.err"; then
        echo "FAIL: v3/v4 behavior differs for '$case_name'"
        diff -u "$tmp/v3-$case_name.status" "$tmp/v4-$case_name.status" || :
        diff -u "$tmp/v3-$case_name.out" "$tmp/v4-$case_name.out" || :
        diff -u "$tmp/v3-$case_name.err" "$tmp/v4-$case_name.err" || :
        return 1
    fi
    echo "PASS: v3/v4 output and exit status match for '$case_name'"
}

bash -n "$baseline"
sh -n "$candidate"
echo "PASS: v3 Bash and v4 /bin/sh syntax checks"

compare_case no-options
compare_case empty-plugin-list
compare_case malformed-component
compare_case unknown-plugin-type
compare_case release-not-detectable

echo "All installer compatibility tests passed."
