#!/bin/sh
# Compare the observable behavior of the v3 Bash installer and the v4 /bin/sh
# installer for inputs that should be unaffected by the shell refactor.
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
# The installer only needs the core version in these tests.
printf '500\n'
PHP
chmod +x "$tmp/bin/php"

run_case() {
    name=$1
    script=$2
    shift 2
    set +e
    env PATH="$tmp/bin:$PATH" MOODLE_APP="$tmp/moodle" "$@" "$script" >"$tmp/$name.out" 2>"$tmp/$name.err"
    status=$?
    set -e
    printf '%s\n' "$status" > "$tmp/$name.status"
}

compare_case() {
    name=$1
    shift
    run_case "v3-$name" "$baseline" "$@"
    run_case "v4-$name" "$candidate" "$@"
    if ! cmp -s "$tmp/v3-$name.status" "$tmp/v4-$name.status" ||
       ! cmp -s "$tmp/v3-$name.out" "$tmp/v4-$name.out" ||
       ! cmp -s "$tmp/v3-$name.err" "$tmp/v4-$name.err"; then
        echo "FAIL: v3/v4 behavior differs for case '$name'"
        diff -u "$tmp/v3-$name.status" "$tmp/v4-$name.status" || :
        diff -u "$tmp/v3-$name.out" "$tmp/v4-$name.out" || :
        diff -u "$tmp/v3-$name.err" "$tmp/v4-$name.err" || :
        return 1
    fi
    echo "PASS: v3/v4 output and exit status match for '$name'"
}

# Syntax checks use each script's intended interpreter.
bash -n "$baseline"
sh -n "$candidate"
echo "PASS: v3 Bash and v4 /bin/sh syntax checks"

compare_case no-options
compare_case empty-plugin-list MOODLE_RELEASE=5.0 -p ''
compare_case malformed-component MOODLE_RELEASE=5.0 -p invalidcomponent
compare_case unknown-plugin-type MOODLE_RELEASE=5.0 -p bogus_test
compare_case release-not-detectable -p bogus_test

echo "All installer compatibility tests passed."
