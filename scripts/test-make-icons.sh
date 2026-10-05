#!/bin/bash
#
# Self-test for `generate` in scripts/make-icons.swift (bead openmoji-98g.1). Run:
#   bash scripts/test-make-icons.sh
#
# Never calls the real OpenAI API and holds no real key. A tiny python3 HTTP server
# on 127.0.0.1 stands in for the Images API; make-icons.swift reaches it through its
# ICONS_TEST_ENDPOINT hook (loopback hosts only). The key is a made-up string built
# at runtime. The cases check the request body, the saved candidates, the request cap
# and --n limit, and that the key never shows up in the output, the log or any file
# `generate` wrote, even when the stub echoes it back inside an error body.
#
# `render` and the rendering checks are covered by `swift scripts/make-icons.swift selftest`.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)

unset ICONS_TEST_ENDPOINT OPENAI_API_KEY

TMP=$(mktemp -d "${TMPDIR:-/tmp}/openmoji-icons-test.XXXXXX")
STUB_PID=""
cleanup() {
  if [ -n "$STUB_PID" ]; then
    kill "$STUB_PID" 2>/dev/null || true
    wait "$STUB_PID" 2>/dev/null || true
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT

PASSES=0
FAILURES=0
CURRENT_GROUP=""
group() {
  CURRENT_GROUP="$1"
  printf '\n%s\n' "$1"
}
check() { # description, command...
  local description="$1"
  shift
  if "$@"; then
    PASSES=$((PASSES + 1))
    printf '  ok    %s\n' "$description"
  else
    FAILURES=$((FAILURES + 1))
    printf '  FAIL  %s   [%s]\n' "$description" "$CURRENT_GROUP"
  fi
}

# A fake key, split so no key-shaped literal sits in the source for gitleaks to flag.
FAKE_KEY="sk-""test-NOTAREALKEY0123456789"
OTHER_KEY_TEXT="sk-""proj-ANOTHERFAKE9876543210"

# -- build the tool, start the stub -----------------------------------------------
BIN="$TMP/bin"
STUB="$TMP/stub"
mkdir -p "$BIN" "$STUB"
printf 'compiling make-icons.swift...\n'
swiftc -o "$BIN/make-icons" "$ROOT/scripts/make-icons.swift" || {
  echo "make-icons.swift does not compile" >&2
  exit 1
}

cat >"$STUB/stub.py" <<'PY'
# Stand-in for POST /v1/images/generations. Mode (ok or error) is read from <dir>/mode
# on every request; every request body is saved as <dir>/request-<n>.json.
import glob
import http.server
import json
import os
import sys

DIR = sys.argv[1]
KEY = os.environ["STUB_KEY"]
OTHER = os.environ["STUB_OTHER"]
# A 1x1 PNG.
PIXEL = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="


class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        count = len(glob.glob(os.path.join(DIR, "request-*.json"))) + 1
        with open(os.path.join(DIR, "request-%d.json" % count), "wb") as saved:
            saved.write(body)
        with open(os.path.join(DIR, "auth"), "a") as auth:
            auth.write("ok\n" if self.headers.get("Authorization") == "Bearer " + KEY else "bad\n")
        with open(os.path.join(DIR, "mode")) as mode:
            failing = mode.read().strip() == "error"
        if failing:
            status = 401
            reply = {"error": {"message": "Incorrect API key provided: %s (also %s)." % (KEY, OTHER),
                               "type": "invalid_request_error", "code": "invalid_api_key"}}
        else:
            status = 200
            wanted = json.loads(body).get("n", 1)
            reply = {"created": 1, "data": [{"b64_json": PIXEL} for _ in range(wanted)],
                     "usage": {"input_tokens": 104, "output_tokens": 1756, "total_tokens": 1860}}
        payload = json.dumps(reply).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, *args):
        pass


server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
with open(os.path.join(DIR, "port"), "w") as port:
    port.write(str(server.server_address[1]))
server.serve_forever()
PY

echo ok >"$STUB/mode"
STUB_KEY="$FAKE_KEY" STUB_OTHER="$OTHER_KEY_TEXT" python3 "$STUB/stub.py" "$STUB" &
STUB_PID=$!
waited=0
while [ ! -s "$STUB/port" ]; do
  sleep 0.05
  waited=$((waited + 1))
  if [ "$waited" -gt 200 ]; then
    echo "stub server did not start" >&2
    exit 1
  fi
done
ENDPOINT="http://127.0.0.1:$(cat "$STUB/port")/v1/images/generations"

# -- helpers ----------------------------------------------------------------------
RC=0
OUTPUT=""
run() { # command... : captures stdout+stderr in OUTPUT and the exit status in RC
  set +e
  OUTPUT=$("$@" 2>&1)
  RC=$?
  set -e
}
requests_seen() { find "$STUB" -name 'request-*.json' | wc -l | tr -d ' '; }
candidates_in() { find "$1" -name 'candidate-*.png' | wc -l | tr -d ' '; }
log_lines() { wc -l <"$1/requests.log" | tr -d ' '; }
generate() { # make-icons args... (key and endpoint set, unless a case overrides them)
  ICONS_TEST_ENDPOINT="$ENDPOINT" OPENAI_API_KEY="$FAKE_KEY" "$BIN/make-icons" generate "$@"
}
body_has() { # request-file n quality
  python3 - "$1" "$2" "$3" <<'PY'
import json
import sys

body = json.load(open(sys.argv[1]))
want = {"model": "gpt-image-2.5-flare", "n": int(sys.argv[2]), "size": "1024x1024", "quality": sys.argv[3],
        "background": "transparent", "output_format": "png", "moderation": "auto"}
for field, value in want.items():
    assert body.get(field) == value, (field, body.get(field))
assert set(body) == set(want) | {"prompt"}, sorted(body)
assert len(body["prompt"]) > 40
PY
}
is_png() { [ "$(head -c 4 "$1" | od -An -tx1 | tr -d ' \n')" = "89504e47" ]; }
no_key_in() { ! grep -rqF -e "$FAKE_KEY" -e "$OTHER_KEY_TEXT" "$1"; }
output_has() { printf '%s' "$OUTPUT" | grep -qF -- "$1"; }
output_lacks_key() { ! printf '%s' "$OUTPUT" | grep -qF -e "$FAKE_KEY" -e "$OTHER_KEY_TEXT" -e "sk-"; }

# -- cases ------------------------------------------------------------------------
group "one image, medium quality, through the swift interpreter"
OUT1="$TMP/out1"
run env ICONS_TEST_ENDPOINT="$ENDPOINT" OPENAI_API_KEY="$FAKE_KEY" \
  swift "$ROOT/scripts/make-icons.swift" generate --n 1 --quality medium --out "$OUT1"
check "exits 0" test "$RC" -eq 0
check "wrote one candidate" test "$(candidates_in "$OUT1")" -eq 1
CANDIDATE=$(find "$OUT1" -name 'candidate-*-1.png' | head -n 1)
check "the candidate is a PNG" is_png "${CANDIDATE:-/nonexistent}"
check "the output names the candidate" output_has "candidate-"
check "the output shows the usage" output_has '"output_tokens" : 1756'
check "the stub saw one request" test "$(requests_seen)" -eq 1
check "the request body has exactly the spec fields" body_has "$STUB/request-1.json" 1 medium
check "the Authorization header carried the key" grep -qx ok "$STUB/auth"
check "the request log has one line" test "$(log_lines "$OUT1")" -eq 1
check "the log line has the status" grep -q 'status=200' "$OUT1/requests.log"
check "the key is not in the output" output_lacks_key
check "the key is not in any written file" no_key_in "$OUT1"

group "defaults: three candidates at high quality"
OUT2="$TMP/out2"
run generate --out "$OUT2"
check "exits 0" test "$RC" -eq 0
check "wrote three candidates" test "$(candidates_in "$OUT2")" -eq 3
check "the default request is n=3, quality high" body_has "$STUB/request-2.json" 3 high

group "more than four images is refused before any request"
SEEN=$(requests_seen)
run generate --n 5 --out "$TMP/out3"
check "exits non-zero" test "$RC" -ne 0
check "says why" output_has "--n must be 1 to 4"
check "sent nothing" test "$(requests_seen)" -eq "$SEEN"
check "left no request log" test ! -e "$TMP/out3/requests.log"

group "an unknown quality is refused"
run generate --quality ultra --out "$TMP/out3"
check "exits non-zero" test "$RC" -ne 0
check "sent nothing" test "$(requests_seen)" -eq "$SEEN"

group "no key"
run env ICONS_TEST_ENDPOINT="$ENDPOINT" "$BIN/make-icons" generate --n 1 --out "$TMP/out3"
check "exits non-zero" test "$RC" -ne 0
check "says the key is missing" output_has "OPENAI_API_KEY is not set"
check "sent nothing" test "$(requests_seen)" -eq "$SEEN"

group "a test endpoint that is not loopback is refused"
run env ICONS_TEST_ENDPOINT="https://example.com/v1/images/generations" OPENAI_API_KEY="$FAKE_KEY" \
  "$BIN/make-icons" generate --n 1 --out "$TMP/out3"
check "exits non-zero" test "$RC" -ne 0
check "says why" output_has "127.0.0.1 or localhost"
check "left no request log" test ! -e "$TMP/out3/requests.log"

group "the request cap"
OUT4="$TMP/out4"
mkdir -p "$OUT4"
for i in 1 2 3 4 5; do echo "2026-01-01T00:00:0${i}Z status=200 seconds=1.0 n=1 quality=high" >>"$OUT4/requests.log"; done
SEEN=$(requests_seen)
run generate --n 1 --out "$OUT4"
check "refuses at five logged requests" test "$RC" -ne 0
check "mentions the cap and --force" output_has "--force"
check "sent nothing" test "$(requests_seen)" -eq "$SEEN"
check "the log is unchanged" test "$(log_lines "$OUT4")" -eq 5
run generate --n 1 --out "$OUT4" --force
check "--force goes ahead" test "$RC" -eq 0
check "--force still logs the request" test "$(log_lines "$OUT4")" -eq 6

group "an error body that echoes the key is scrubbed"
OUT5="$TMP/out5"
echo error >"$STUB/mode"
run generate --n 1 --out "$OUT5"
check "exits non-zero" test "$RC" -ne 0
check "reports the status" output_has "status 401"
check "shows the scrubbed message" output_has "[redacted]"
check "the key is not in the output" output_lacks_key
check "the log records the failure" grep -q 'status=401' "$OUT5/requests.log"
check "the key is not in any written file" no_key_in "$OUT5"
check "no candidate was written" test "$(candidates_in "$OUT5")" -eq 0

printf '\n%s passed, %s failed\n' "$PASSES" "$FAILURES"
[ "$FAILURES" -eq 0 ]
