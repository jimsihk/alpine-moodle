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
    name=$1
    script=$2
    scenario=$3
    set +e
    case "$scenario" in
        no-options)
            env PATH="$tmp/bin:$PATH" MOODLE_APP="$tmp/moodle" "$script" ;;
        empty-plugin-list)
            env PATH="$tmp/bin:$PATH" MOODLE_APP="$tmp/moodle" MOODLE_RELEASE=5.0 "$script" -p '' ;;
        malformed-component)
            env PATH="$tmp/bin:$PATH" MOODLE_APP="$tmp/moodle" MOODLE_RELEASE=5.0 "$script" -p invalidcomponent ;;
        unknown-plugin-type)
            env PATH="$tmp/bin:$PATH" MOODLE_APP="$tmp/moodle" MOODLE_RELEASE=5.0 "$script" -p bogus_test ;;
        release-not-detectable)
            env PATH="$tmp/bin:$PATH" MOODLE_APP="$tmp/moodle" "$script" -p bogus_test ;;
        *) echo "Unknown test case: $scenario" >&2; exit 2 ;;
    esac >"$tmp/$name.out" 2>"$tmp/$name.err"
    status=$?
    set -e
    printf '%s\n' "$status" > "$tmp/$name.status"
}

compare_case() {
    name=$1
    run_case "v3-$name" "$baseline" "$name"
    run_case "v4-$name" "$candidate" "$name"
    if ! cmp -s "$tmp/v3-$name.status" "$tmp/v4-$name.status" ||
       ! cmp -s "$tmp/v3-$name.out" "$tmp/v4-$name.out" ||
       ! cmp -s "$tmp/v3-$name.err" "$tmp/v4-$name.err"; then
        echo "FAIL: v3/v4 behavior differs for '$name'"
        diff -u "$tmp/v3-$name.status" "$tmp/v4-$name.status" || :
        diff -u "$tmp/v3-$name.out" "$tmp/v4-$name.out" || :
        diff -u "$tmp/v3-$name.err" "$tmp/v4-$name.err" || :
        return 1
    fi
    echo "PASS: v3/v4 output and exit status match for '$name'"
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
