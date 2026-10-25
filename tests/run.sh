#!/bin/sh
# shellcheck disable=SC2015,SC2016 # ok/bad never fail; literal $ in test names is intended
# Tests for the Shipyard action. POSIX sh.
#     sh action/tests/run.sh
# Optional live test against a dev panel:
#     SHIPYARD_TEST_PANEL=http://127.0.0.1:8080 SHIPYARD_TEST_SECRET=... SHIPYARD_TEST_REPO=owner/repo sh action/tests/run.sh
HERE=$(cd "$(dirname "$0")" && pwd)
ACTION="$HERE/.."
ROOT="$HERE/../.."
# shellcheck source=/dev/null
. "$ACTION/lib.sh"
TAB=$(printf '\t')
pass=0
fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$*"; }

# Slug and version parity with core (core/tests/fixtures/slugs.tsv).
# Tab is IFS whitespace (empty fields collapse), so read with "|" instead.
sed "s/$TAB/|/g" "$ROOT/core/tests/fixtures/slugs.tsv" >"${TMPDIR:-/tmp}/shipyard-slugs.$$"
while IFS='|' read -r name slug version; do
    case $name in '#'* | '') continue ;; esac
    got=$(sy_slug "$name")
    [ "$got" = "$slug" ] && ok || bad "slug of '$name': got '$got', want '$slug'"
    [ "$version" = - ] && version=''
    got=$(sy_version_text "$name")
    [ "$got" = "$version" ] && ok || bad "version text of '$name': got '$got', want '$version'"
done <"${TMPDIR:-/tmp}/shipyard-slugs.$$"
rm -f "${TMPDIR:-/tmp}/shipyard-slugs.$$"

# Lesson 4: reject bad names instead of sanitising.
for good in "Tom's Tools (Lite)-1.0+3.abc1234.jar" 'Bang!_v2.zip' 'a.JAR'; do
    [ -z "$(sy_check_name "$good")" ] && ok || bad "should accept '$good': $(sy_check_name "$good")"
done
long=$(printf '%0125d' 0).jar
for badname in '' '../evil.jar' 'A&B.jar' '$HOME.jar' 'a`id`.jar' 'a"b.jar' '.hidden.jar' '-rf.jar' ' a.jar' 'a.jar ' 'plugin.exe' "$long" "$(printf 'caf\303\251.jar')"; do
    [ -n "$(sy_check_name "$badname")" ] && ok || bad "should reject '$badname'"
done

# The signed message and HMAC match core's Upload::sign.
if command -v php >/dev/null 2>&1; then
    export SHIPYARD_SECRET='test-secret-not-real'
    digest=$(printf 'x' | sha256sum | cut -c1-64)
    mine=$(printf 'shipyard-v1\n%s\n%s\n%s\n%s\n%s\n%s' "$digest" example-org/p 123 "Tom's P-1.0.jar" feature/x "$(printf '%040d' 1)" | sy_hmac)
    theirs=$(php -r '
        spl_autoload_register(function ($c) { $f = $GLOBALS["argv"][1] . "/core/src/" . str_replace(["Shipyard\\Core\\", "\\"], ["", "/"], $c) . ".php"; if (is_file($f)) require $f; });
        echo Shipyard\Core\Ingest\Upload::sign(getenv("SHIPYARD_SECRET"), $argv[2], "example-org/p", "123", "Tom'"'"'s P-1.0.jar", "feature/x", str_repeat("0", 39) . "1");
    ' "$ROOT" "$digest")
    [ "$mine" = "$theirs" ] && ok || bad "HMAC differs from core: $mine vs $theirs"
    fp=$(sy_fingerprint)
    core_fp=$(php -r 'echo substr(hash("sha256", getenv("SHIPYARD_SECRET")), 0, 8);')
    [ "$fp" = "$core_fp" ] && ok || bad "fingerprint differs from core"
    unset SHIPYARD_SECRET
else
    echo 'skip: php not installed, HMAC parity not checked'
fi

[ "$(sy_urlencode "Tom's 100% P.jar")" = "Tom's%20100%25%20P.jar" ] && ok || bad "urlencode"

# Review fix 7: re-stamping an already stamped archive leaves one stamp entry, the new one.
if command -v python3 >/dev/null 2>&1 && command -v zip >/dev/null 2>&1; then
    S=$(mktemp -d)
    mkdir -p "$S/old/META-INF"
    printf 'name: x\n' >"$S/old/plugin.yml"
    printf '{"runId":"1"}' >"$S/old/META-INF/shipyard-build.json"
    (cd "$S/old" && zip -q ../a.jar plugin.yml META-INF/shipyard-build.json)
    printf '{"runId":"2"}' >"$S/new.json"
    sy_stamp_python "$S/a.jar" "$S/new.json" && ok || bad "python stamp failed"
    entries=$(python3 -c 'import sys, zipfile; n = zipfile.ZipFile(sys.argv[1]).namelist(); print(n.count("META-INF/shipyard-build.json"), n.count("plugin.yml"))' "$S/a.jar")
    [ "$entries" = '1 1' ] && ok || bad "python stamp: want one stamp and the other files kept, got: $entries"
    [ "$(unzip -p "$S/a.jar" META-INF/shipyard-build.json)" = '{"runId":"2"}' ] && ok || bad "python stamp: the new stamp must replace the old"
    rm -rf "$S"
else
    echo 'skip: python3 or zip not installed, python stamp not checked'
fi

# Runs the action script with a fake GitHub environment; output in $T/out.
run_action() {
    (
        cd "$T" || exit 1
        GITHUB_REPOSITORY=example-org/demo-plugin GITHUB_RUN_ID=${RUN:-42} GITHUB_RUN_NUMBER=7 \
            SHIPYARD_COMMIT=${COMMIT:-$(printf '%040d' 0)} SHIPYARD_BRANCH=main RUNNER_TEMP="$T/tmp" \
            INPUT_PANEL_URL=${PANEL:-http://127.0.0.1:9} INPUT_RETRIES=0 "$@" sh "$ACTION/shipyard.sh"
    ) >"$T/out" 2>&1
    status=$?
}
make_jar() {
    (cd "$T" && mkdir -p jar && printf 'name: x\n' >jar/plugin.yml && cd jar && zip -q "../$1" plugin.yml)
}

T=$(mktemp -d)
mkdir -p "$T/tmp" "$T/build"
make_jar build/Foo-1.0.jar
make_jar build/Foo-1.0-all.jar

run_action env SHIPYARD_SECRET=x INPUT_FILES='build/*.jar'
[ "$status" -ne 0 ] && grep -q 'same plugin (foo)' "$T/out" && ok || bad "trap 13: two jars of one plugin must be refused: $(cat "$T/out")"
grep -q 'retrying\|Sent ' "$T/out" && bad "trap 13: nothing may be uploaded when a file is refused" || ok

run_action env SHIPYARD_SECRET= INPUT_FILES='build/Foo-1.0.jar'
[ "$status" -ne 0 ] && grep -q 'SHIPYARD_SECRET is empty' "$T/out" && ok || bad "missing secret must fail clearly"

run_action env SHIPYARD_SECRET=abc INPUT_FILES='build/Foo-1.0.jar' INPUT_PANEL_URL=http://panel.example.com
grep -q 'must start with https' "$T/out" && ok || bad "plain http to a remote panel must be refused"

run_action env SHIPYARD_SECRET=s3cret-value INPUT_FILES='build/Foo-1.0.jar'
grep -q 'length 12, fingerprint [0-9a-f]\{8\}' "$T/out" && ok || bad "lesson 3: prints length and fingerprint"
grep -q 's3cret-value' "$T/out" && bad "lesson 3: the secret must never be printed" || ok
[ "$status" -ne 0 ] && grep -q 'answered 000' "$T/out" && ok || bad "unreachable panel must fail: $(cat "$T/out")"

mkdir -p "$T/spaced"
make_jar "spaced/My Plugin-1.0.jar"
run_action env SHIPYARD_SECRET=x INPUT_FILES='spaced/*.jar'
grep -q 'No file matches' "$T/out" && bad "a file name with a space must be found: $(cat "$T/out")" || ok
grep -q 'My Plugin-1.0.jar' "$T/out" && ok || bad "a file name with a space must be sent: $(cat "$T/out")"

# Review fix 4: a workflow_run trigger would mix the build's commit with another run's id.
run_action env SHIPYARD_SECRET=x GITHUB_EVENT_NAME=workflow_run INPUT_FILES='build/Foo-1.0.jar'
[ "$status" -ne 0 ] && grep -q 'not in a workflow triggered by workflow_run' "$T/out" && ok || bad "workflow_run must be refused: $(cat "$T/out")"
grep -q 'retrying\|Sent ' "$T/out" && bad "workflow_run: nothing may be uploaded" || ok

run_action env SHIPYARD_SECRET=x INPUT_FILES='build/nothing-*.jar'
[ "$status" -ne 0 ] && grep -q 'No files matched' "$T/out" && ok || bad "no matching files must fail"

# upload: false stamps in place, needs no panel or secret, and allows several jars of one plugin.
cp "$T/build/Foo-1.0.jar" "$T/build/keep.jar"
run_action env SHIPYARD_SECRET= INPUT_PANEL_URL= INPUT_UPLOAD=false INPUT_FILES='build/Foo-*.jar'
[ "$status" -eq 0 ] && grep -q 'Stamped build/Foo-1.0.jar' "$T/out" && grep -q 'Stamped build/Foo-1.0-all.jar' "$T/out" && ok || bad "upload false must stamp every file: $(cat "$T/out")"
[ "$(unzip -p "$T/build/Foo-1.0.jar" META-INF/shipyard-build.json 2>/dev/null | grep -o '"runId":"42"')" = '"runId":"42"' ] && ok || bad "upload false: the stamp is written into the file itself"
[ "$(unzip -p "$T/build/Foo-1.0.jar" plugin.yml)" = 'name: x' ] && ok || bad "upload false: the archive keeps its own files"
grep -q 'retrying\|Sent \|fingerprint' "$T/out" && bad "upload false: nothing is sent and no secret is read" || ok
run_action env INPUT_UPLOAD=maybe INPUT_FILES='build/keep.jar'
[ "$status" -ne 0 ] && grep -q 'upload must be true or false' "$T/out" && ok || bad "upload: only true or false"
mv "$T/build/keep.jar" "$T/build/Foo-1.0.jar"

# Optional: a real upload to a dev panel. The panel checks the HMAC, the digest
# and that the stamp the action wrote matches the run.
if [ -n "${SHIPYARD_TEST_PANEL:-}" ]; then
    RUN=$(date +%s)
    COMMIT=$(printf '%s' "$RUN" | sha1sum | cut -c1-40)
    rm -f "$T/build/Foo-1.0-all.jar"
    PANEL=$SHIPYARD_TEST_PANEL
    run_action env SHIPYARD_SECRET="${SHIPYARD_TEST_SECRET:-}" GITHUB_REPOSITORY="${SHIPYARD_TEST_REPO:-example-org/demo-plugin}" INPUT_FILES='build/Foo-1.0.jar'
    [ "$status" -eq 0 ] && grep -q 'Sent Foo-1.0.jar' "$T/out" && ok || bad "live upload: $(cat "$T/out")"
    unzip -p "$T/build/Foo-1.0.jar" META-INF/shipyard-build.json >/dev/null 2>&1 && bad "the original build output must stay unmodified" || ok
fi
rm -rf "$T"

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
