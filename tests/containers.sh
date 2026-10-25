#!/bin/sh
# The action inside a stock Pterodactyl Java image, the image Shipyard's managed
# runners use: it has a JDK but no zip, python3 or node (fix brief v3 R2).
# Checks that stamping falls back to jar and signing to java.
#     sh action/tests/containers.sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ACTION=$(cd "$HERE/.." && pwd)
IMAGE=${SHIPYARD_TEST_IMAGE:-ghcr.io/pterodactyl/yolks:java_25}
pass=0
fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$*"; }

if ! command -v docker >/dev/null 2>&1 || ! docker image inspect "$IMAGE" >/dev/null 2>&1 && ! docker pull -q "$IMAGE" >/dev/null 2>&1; then
    echo "skip: docker or $IMAGE not available"
    exit 0
fi

T=$(mktemp -d)
chmod 777 "$T"
# The expected HMAC, worked out here (core's Upload::sign is the reference).
want=$(printf 'shipyard-v1\nmsg' | php -r 'echo hash_hmac("sha256", stream_get_contents(STDIN), "k3y"), "\n";')

out=$(docker run --rm -v "$ACTION:/action:ro" -v "$T:/w" -w /w -e SHIPYARD_SECRET=k3y --entrypoint sh "$IMAGE" -c '
    for t in zip python3 node; do command -v "$t" >/dev/null 2>&1 && echo "HAS $t"; done
    mkdir -p jar build && printf "name: x\n" >jar/plugin.yml && (cd jar && jar cf ../build/Foo-1.0.jar plugin.yml)
    . /action/lib.sh
    printf "shipyard-v1\nmsg" | sy_hmac | sed "s/^/HMAC /"
    GITHUB_REPOSITORY=example-org/demo-plugin GITHUB_RUN_ID=42 GITHUB_RUN_NUMBER=7 SHIPYARD_COMMIT=0000000000000000000000000000000000000000 \
        SHIPYARD_BRANCH=main RUNNER_TEMP=/w/tmp INPUT_UPLOAD=false INPUT_FILES="build/Foo-1.0.jar" SHIPYARD_SECRET= sh /action/shipyard.sh
    echo "EXIT $?"
    mkdir -p x && cd x && jar xf ../build/Foo-1.0.jar META-INF/shipyard-build.json && cat META-INF/shipyard-build.json
' 2>&1)

printf '%s\n' "$out" | grep -q '^HAS ' && bad "the image is expected to lack zip, python3 and node: $(printf '%s\n' "$out" | grep '^HAS')" || ok
[ "$(printf '%s\n' "$out" | sed -n 's/^HMAC //p')" = "$want" ] && ok || bad "java HMAC differs from the reference: $(printf '%s\n' "$out" | grep -i hmac)"
printf '%s\n' "$out" | grep -q '^EXIT 0$' && ok || bad "upload false must stamp with jar: $out"
printf '%s\n' "$out" | grep -q '"runId":"42"' && ok || bad "the jar stamp must be in the archive: $out"
rm -rf "$T"

printf '%d passed, %d failed (action in %s)\n' "$pass" "$fail" "$IMAGE"
[ "$fail" -eq 0 ]
