#!/bin/bash
#
# Self-test for scripts/asc.swift (bead openmoji-2pq). Run: make release-test
#
# Never calls the real App Store Connect API and holds no real key. Every case
# starts scripts/test-support/asc-stub.swift, a local HTTP server on 127.0.0.1
# that answers from a scripted scenario, and runs asc.swift against it through
# its ASC_TEST_BASE_URL test hook. The key is a throwaway P-256 key generated
# when the test starts. The stub verifies every request's ES256 JWT against the
# matching public key and logs what it saw (header, claims, signature, query),
# so the cases can assert on the exact requests asc.swift made.
#
# asc.swift and the stub are compiled once into a temporary directory, which also
# proves they compile. One case runs the script the way the lane does,
# `swift scripts/asc.swift`, to prove the interpreter mode works.
#
# Fake credentials only, built at runtime: nothing here for gitleaks to flag.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)

unset ASC_ISSUER_ID ASC_KEY_ID ASC_PRIVATE_KEY_BASE64 ASC_TEST_BASE_URL ASC_TEST_RETRY_DELAY OP_SERVICE_ACCOUNT_TOKEN

TMP=$(mktemp -d "${TMPDIR:-/tmp}/openmoji-asc-test.XXXXXX")
STUB_PID=""
stop_stub() {
  if [ -n "$STUB_PID" ]; then
    kill "$STUB_PID" 2>/dev/null || true
    wait "$STUB_PID" 2>/dev/null || true
    STUB_PID=""
  fi
}
cleanup() {
  stop_stub
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

# -- build the tools, generate the throwaway keys ---------------------------------
BIN="$TMP/bin"
mkdir -p "$BIN"
printf 'compiling asc.swift and the stub server...\n'
swiftc -o "$BIN/asc" "$ROOT/scripts/asc.swift" &
asc_build=$!
swiftc -o "$BIN/asc-stub" "$ROOT/scripts/test-support/asc-stub.swift" &
stub_build=$!
wait "$asc_build" || {
  echo "asc.swift does not compile" >&2
  exit 1
}
wait "$stub_build" || {
  echo "asc-stub.swift does not compile" >&2
  exit 1
}
"$BIN/asc-stub" keygen "$TMP/key"
"$BIN/asc-stub" keygen "$TMP/other-key"
KEY_B64=$(base64 <"$TMP/key/AuthKey.p8" | tr -d '\n')
OTHER_KEY_B64=$(base64 <"$TMP/other-key/AuthKey.p8" | tr -d '\n')
KEY_ID="TESTKEY123"
ISSUER="11111111-2222-3333-4444-555555555555"

# -- scenario builders (JSON as strings) ------------------------------------------
BUNDLE="com.backhaushold.openmoji"
resp() { # status [body]
  printf '{"status":%s%s}' "$1" "${2:+,\"body\":$2}"
}
join() { # items... -> comma-joined
  local out="" item
  for item in "$@"; do out="${out:+$out,}$item"; done
  printf '%s' "$out"
}
list() { printf '{"data":[%s]}' "$(join "$@")"; } # resource objects -> list body
route() {                                         # method path query-json-array responses...
  local method="$1" path="$2" query="$3"
  shift 3
  printf '{"method":"%s","path":"%s","query":%s,"responses":[%s]}' "$method" "$path" "$query" "$(join "$@")"
}
# Backslash-escaped quotes inside a "$(...)" inside double quotes are avoided
# below: bash 3.2 (macOS /bin/bash) mis-parses them.
Q_APP="[\"filter[bundleId]=$BUNDLE\"]"
app_route() {
  local app
  app=$(printf '{"id":"APP1","type":"apps","attributes":{"name":"OpenMoji Family","bundleId":"%s"}}' "$BUNDLE")
  route GET /v1/apps "$Q_APP" "$(resp 200 "$(list "$app")")"
}
build_obj() { # state [expirationDate] [version] [id]
  printf '{"id":"%s","type":"builds","attributes":{"version":"%s","processingState":"%s","uploadedDate":"2026-10-03T10:00:00-07:00"%s}}' \
    "${4:-B42}" "${3:-42}" "$1" "${2:+,\"expirationDate\":\"$2\"}"
}
builds_route() { # version responses... : GET /v1/builds?filter[version]=N
  local version="$1"
  shift
  route GET /v1/builds "[\"filter[app]=APP1\",\"filter[version]=$version\"]" "$@"
}
EXPIRY="2027-01-01T10:00:00.123-08:00"

# -- one case = a scenario file, a stub, one asc run ------------------------------
CASE_DIR="" RC=0 STDOUT="" STDERR="" LOG=""
new_case() {
  CASE_DIR="$TMP/cases/$1"
  mkdir -p "$CASE_DIR"
  LOG="$CASE_DIR/stub/requests.log"
  : >"$CASE_DIR/scenario.json"
}
scenario() { printf '{"routes":[%s]}\n' "$(join "$@")" >"$CASE_DIR/scenario.json"; }

start_stub() { # public-key-dir
  rm -rf "$CASE_DIR/stub" "$CASE_DIR/port"
  "$BIN/asc-stub" serve --public-key "$1/public.pem" --scenario "$CASE_DIR/scenario.json" \
    --log "$CASE_DIR/stub" --port-file "$CASE_DIR/port" &
  STUB_PID=$!
  local waited=0
  while [ ! -s "$CASE_DIR/port" ]; do
    sleep 0.05
    waited=$((waited + 1))
    if [ "$waited" -gt 200 ]; then
      echo "stub server did not start" >&2
      exit 1
    fi
  done
}

# run_asc [VAR=value | -u VAR]... -- arguments...: runs asc against the case's stub
# with a complete, valid environment; the leading arguments override it. ASC_BIN
# is the program to run (default: the compiled binary).
ASC_BIN=""
run_asc() {
  STDOUT="$CASE_DIR/stdout"
  STDERR="$CASE_DIR/stderr"
  RC=0
  start_stub "$TMP/key"
  local port
  port=$(cat "$CASE_DIR/port")
  local environment=(
    "ASC_ISSUER_ID=$ISSUER" "ASC_KEY_ID=$KEY_ID" "ASC_PRIVATE_KEY_BASE64=$KEY_B64"
    "ASC_TEST_BASE_URL=http://127.0.0.1:$port" "ASC_TEST_RETRY_DELAY=0.05"
  )
  local kept entry
  while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do
    if [ "$1" = "-u" ]; then
      # `env` wants its -u options before any NAME=value, so drop the variable instead.
      kept=()
      for entry in "${environment[@]}"; do
        case $entry in
          "$2="*) ;;
          *) kept+=("$entry") ;;
        esac
      done
      environment=("${kept[@]}")
      shift 2
    else
      environment+=("$1")
      shift
    fi
  done
  shift
  if [ -n "$ASC_BIN" ]; then
    # shellcheck disable=SC2086 # ASC_BIN is a command with arguments ("swift scripts/asc.swift")
    env "${environment[@]}" $ASC_BIN "$@" >"$STDOUT" 2>"$STDERR" || RC=$?
  else
    env "${environment[@]}" "$BIN/asc" "$@" >"$STDOUT" 2>"$STDERR" || RC=$?
  fi
  stop_stub
}

# -- predicates over the last run ---------------------------------------------------
rc_is() { [ "$RC" -eq "$1" ]; }
rc_nonzero() { [ "$RC" -ne 0 ]; }
out_has() { grep -qF -- "$1" "$STDOUT"; }
err_has() { grep -qF -- "$1" "$STDERR"; }
out_lacks() { ! grep -qF -- "$1" "$STDOUT"; }
err_lacks() { ! grep -qF -- "$1" "$STDERR"; }
req_count() { grep -cE -- "$1" "$LOG" || true; }
req_has() { grep -qE -- "$1" "$LOG"; }
req_lacks() { ! grep -qE -- "$1" "$LOG"; }
req_matching_is() { [ "$(req_count "$1")" -eq "$2" ]; }
no_requests() { [ ! -s "$LOG" ]; }
no_unmatched() { req_lacks 'matched=no'; }
every_signature_valid() {
  local total valid
  total=$(grep -c '^REQ ' "$LOG" || true)
  valid=$(grep -c ' sig=valid ' "$LOG" || true)
  [ "$total" -gt 0 ] && [ "$total" -eq "$valid" ]
}
no_secrets_in_output() {
  local file
  for file in "$STDOUT" "$STDERR"; do
    if grep -qF -e "$KEY_B64" -e "$OTHER_KEY_B64" -e "BEGIN PRIVATE KEY" -e "eyJhbGci" -e "Bearer " "$file"; then
      return 1
    fi
  done
}
req_n() { # method path: number of the first matching request
  grep -E "^REQ n=[0-9]+ method=$1 path=$2 " "$LOG" | sed -E 's/^REQ n=([0-9]+) .*/\1/' | head -n 1
}
body_value() { # method path json-key-path: a field of the request body
  local n
  n=$(req_n "$1" "$2")
  [ -n "$n" ] || return 1
  plutil -extract "$3" raw -o - "$CASE_DIR/stub/$n.body"
}
body_is() { # method path json-key-path expected
  local actual
  actual=$(body_value "$1" "$2" "$3") || return 1
  [ "$actual" = "$4" ]
}
body_length_at_most() { # method path json-key-path limit
  local actual
  actual=$(body_value "$1" "$2" "$3") || return 1
  [ "${#actual}" -le "$4" ]
}
body_ends_with() { # method path json-key-path suffix
  local actual
  actual=$(body_value "$1" "$2" "$3") || return 1
  [ "${actual%"$4"}" != "$actual" ]
}
body_starts_with() { # method path json-key-path prefix
  local actual
  actual=$(body_value "$1" "$2" "$3") || return 1
  [ "${actual#"$4"}" != "$actual" ]
}

# ================================================================= (a) =======
group "(a) JWT: ES256 header and claims, signature verified against the public key"

new_case jwt
scenario "$(app_route)" "$(builds_route 42 "$(resp 200 "$(list "$(build_obj VALID "$EXPIRY")")")")"
run_asc -- wait-for-build 42 --interval 0.1 --timeout 20
check "exits 0" rc_is 0
check "every request carries a JWT whose ES256 signature verifies with the public key" every_signature_valid
check "header alg is ES256" req_has ' alg=ES256 '
check "header kid is the key id" req_has " kid=$KEY_ID "
check "header typ is JWT" req_has ' typ=JWT '
check "claim iss is the issuer id" req_has " iss=$ISSUER "
check "claim aud is appstoreconnect-v1" req_has ' aud=appstoreconnect-v1 '
check "claim iat is now, and exp is in the future" req_lacks 'iat_ok=no'
check "token lifetime is positive and at most 20 minutes (Apple's limit)" req_lacks 'life_ok=no'
check "the lifetime is 300 s" req_has ' lifetime=300 '
check "no key, token or Authorization header in the output" no_secrets_in_output
check "every request matched a scripted route" no_unmatched

new_case jwt-wrong-key
scenario "$(app_route)" "$(builds_route 42 "$(resp 200 "$(list "$(build_obj VALID "$EXPIRY")")")")"
STDOUT="$CASE_DIR/stdout"
STDERR="$CASE_DIR/stderr"
start_stub "$TMP/key"
RC=0
PORT=$(cat "$CASE_DIR/port")
env "ASC_ISSUER_ID=$ISSUER" "ASC_KEY_ID=$KEY_ID" "ASC_PRIVATE_KEY_BASE64=$OTHER_KEY_B64" \
  "ASC_TEST_BASE_URL=http://127.0.0.1:$PORT" \
  "$BIN/asc" wait-for-build 42 --interval 0.1 --timeout 20 >"$STDOUT" 2>"$STDERR" || RC=$?
stop_stub
check "a token signed with a different key is reported invalid by the stub (the signature check discriminates)" req_has ' sig=invalid '
check "no request verified against the wrong key" req_lacks ' sig=valid '

# ================================================================= (b) =======
group "(b) credentials and the test hook"

new_case env-missing
scenario "$(app_route)"
run_asc -u ASC_PRIVATE_KEY_BASE64 -u ASC_KEY_ID -- latest-build
check "missing variables: exits 1" rc_is 1
check "missing variables: names them" err_has "missing environment: ASC_KEY_ID, ASC_PRIVATE_KEY_BASE64"
check "missing variables: no request was made" no_requests

new_case env-bad-base64
scenario "$(app_route)"
run_asc "ASC_PRIVATE_KEY_BASE64=@@@ not base64 @@@" -- latest-build
check "invalid base64 key: exits 1" rc_is 1
check "invalid base64 key: says so" err_has "not valid base64"
check "invalid base64 key: no request was made" no_requests

new_case env-not-a-key
scenario "$(app_route)"
run_asc "ASC_PRIVATE_KEY_BASE64=$(printf 'hello\n' | base64)" -- latest-build
check "base64 of something that is not a key: exits 1" rc_is 1
check "base64 of something that is not a key: says so" err_has "does not decode to a P-256 .p8 private key"
check "base64 of something that is not a key: nothing echoed back" err_lacks "hello"
check "base64 of something that is not a key: no request was made" no_requests

new_case key-with-line-wrapping
scenario "$(app_route)" "$(builds_route 42 "$(resp 200 "$(list "$(build_obj VALID "$EXPIRY")")")")"
run_asc "ASC_PRIVATE_KEY_BASE64=$(base64 <"$TMP/key/AuthKey.p8" | fold -w 60)" -- wait-for-build 42 --interval 0.1 --timeout 20
check "a base64 key wrapped over several lines still works" rc_is 0

for url in "http://192.0.2.1:9" "https://127.0.0.1:1" "http://127.0.0.1.invalid" "http://localhost.invalid:80" "ftp://127.0.0.1"; do
  new_case "hook-refuses-$(printf '%s' "$url" | tr -c 'A-Za-z0-9\n' '_')"
  scenario "$(app_route)"
  run_asc "ASC_TEST_BASE_URL=$url" -- latest-build
  check "ASC_TEST_BASE_URL=$url: refused, exits 1" rc_is 1
  check "ASC_TEST_BASE_URL=$url: says it must be loopback" err_has "must be an http://127.0.0.1 or http://localhost URL"
  check "ASC_TEST_BASE_URL=$url: the stub saw nothing" no_requests
done

# ================================================================= (c) =======
group "(c) wait-for-build: polling, INVALID/FAILED, timeout, errors"

new_case wait-poll
scenario "$(app_route)" "$(builds_route 42 \
  "$(resp 200 "$(list)")" \
  "$(resp 200 "$(list "$(build_obj PROCESSING)")")" \
  "$(resp 200 "$(list "$(build_obj PROCESSING)")")" \
  "$(resp 200 "$(list "$(build_obj VALID "$EXPIRY")")")")"
run_asc -- wait-for-build 42 --interval 0.1 --timeout 30
check "not listed, PROCESSING, PROCESSING, then VALID: exits 0" rc_is 0
check "looked the app up by bundle ID" req_has "path=/v1/apps .*query=filter\[bundleId\]=$BUNDLE"
check "polled /v1/builds exactly four times" req_matching_is '^REQ n=[0-9]+ method=GET path=/v1/builds ' 4
check "builds are filtered by app and by build number" req_has 'path=/v1/builds .*query=filter\[app\]=APP1&filter\[version\]=42&'
check "builds are sorted newest first, limit 1" req_has 'sort=-uploadedDate&limit=1$'
check "reports a build that is not listed yet" out_has "build 42: not listed yet"
check "reports PROCESSING" out_has "build 42: PROCESSING"
check "reports VALID with the exact expirationDate" out_has "build 42 is VALID; state=VALID uploaded=2026-10-03T10:00:00-07:00 expirationDate=$EXPIRY"
check "every request was signed correctly" every_signature_valid
check "no request was unmatched" no_unmatched

new_case wait-valid-first
scenario "$(app_route)" "$(builds_route 42 "$(resp 200 "$(list "$(build_obj VALID "$EXPIRY")")")")"
run_asc -- wait-for-build 42
check "already VALID with the default options: exits 0 without sleeping" rc_is 0
check "default options: one build request" req_matching_is 'path=/v1/builds ' 1

for state in INVALID FAILED; do
  new_case "wait-$state"
  scenario "$(app_route)" "$(builds_route 42 \
    "$(resp 200 "$(list "$(build_obj PROCESSING)")")" \
    "$(resp 200 "$(list "$(build_obj "$state")")")")"
  run_asc -- wait-for-build 42 --interval 0.1 --timeout 30
  check "$state: exits 4" rc_is 4
  check "$state: says the build finished processing as $state" err_has "build 42 finished processing as $state"
  check "$state: stops polling" req_matching_is 'path=/v1/builds ' 2
  check "$state: does not claim VALID" out_lacks "is VALID"
done

new_case wait-timeout
scenario "$(app_route)" "$(builds_route 42 "$(resp 200 "$(list "$(build_obj PROCESSING)")")")"
run_asc -- wait-for-build 42 --interval 0.2 --timeout 1
check "still PROCESSING at the deadline: exits 3" rc_is 3
check "timeout: says timed out and the last state" err_has "timed out after 1 s; build 42 was last PROCESSING"
check "timeout: polled more than once" test "$(req_count 'path=/v1/builds ')" -ge 2

new_case wait-never-listed
scenario "$(app_route)" "$(builds_route 42 "$(resp 200 "$(list)")")"
run_asc -- wait-for-build 42 --interval 0.2 --timeout 1
check "never listed: exits 3" rc_is 3
check "never listed: says so" err_has "build 42 was last not listed yet"

new_case wait-unknown-state
scenario "$(app_route)" "$(builds_route 42 \
  "$(resp 200 "$(list "$(build_obj SOMETHING_NEW)")")" \
  "$(resp 200 "$(list "$(build_obj VALID "$EXPIRY")")")")"
run_asc -- wait-for-build 42 --interval 0.1 --timeout 30
check "an unknown state is treated as still waiting, then VALID: exits 0" rc_is 0

new_case wait-503-then-valid
scenario "$(app_route)" "$(builds_route 42 \
  "$(resp 503 '{"errors":[{"title":"busy"}]}')" \
  "$(resp 200 "$(list "$(build_obj VALID "$EXPIRY")")")")"
run_asc -- wait-for-build 42 --interval 0.1 --timeout 30
check "a 503 on a GET is retried: exits 0" rc_is 0
check "503: two build requests" req_matching_is 'path=/v1/builds ' 2

new_case wait-503-forever
scenario "$(app_route)" "$(builds_route 42 "$(resp 503 '{"errors":[{"title":"busy"}]}')")"
run_asc -- wait-for-build 42 --interval 0.05 --timeout 60
check "five polls in a row that fail transiently: exits 1" rc_is 1
check "persistent 503: says it was 5 of 5 in a row" err_has "(5 of 5 in a row)"
check "persistent 503: 3 attempts per poll, 5 polls" req_matching_is 'path=/v1/builds ' 15

new_case wait-401
scenario "$(app_route)" "$(builds_route 42 "$(resp 401 '{"errors":[{"code":"NOT_AUTHORIZED","title":"Authentication credentials are missing or invalid.","detail":"Provide a properly configured and signed bearer token."}]}')")"
run_asc -- wait-for-build 42 --interval 0.1 --timeout 30
check "401: exits 1" rc_is 1
check "401: says HTTP 401 with Apple's code and title" err_has "HTTP 401: NOT_AUTHORIZED - Authentication credentials are missing or invalid."
check "401: points at the key" err_has "Check ASC_KEY_ID, ASC_ISSUER_ID and the key"
check "401: not retried" req_matching_is 'path=/v1/builds ' 1
check "401: no secret in the output" no_secrets_in_output

new_case wait-403
scenario "$(app_route)" "$(builds_route 42 "$(resp 403 '{"errors":[{"code":"FORBIDDEN_ERROR","title":"This request is forbidden for security reasons."}]}')")"
run_asc -- wait-for-build 42
check "403: exits 1 and mentions the App Manager role" err_has "needs App Manager"

new_case wait-no-app
scenario "$(route GET /v1/apps "$Q_APP" "$(resp 200 "$(list)")")"
run_asc -- wait-for-build 42
check "no app record: exits 1" rc_is 1
check "no app record: says to create it" err_has "no app with bundle ID $BUNDLE is visible to this key"

new_case wait-usage
scenario "$(app_route)"
run_asc -- wait-for-build
check "no build number: usage, exit 2" rc_is 2
run_asc -- wait-for-build 4x2
check "non-numeric build number: exit 2" rc_is 2
run_asc -- wait-for-build 42 --timeout
check "--timeout without a value: exit 2" rc_is 2
run_asc -- wait-for-build 42 --timeout abc
check "--timeout abc: exit 2" rc_is 2
run_asc -- wait-for-build 42 --timeout 0
check "--timeout 0: exit 2" rc_is 2
run_asc -- wait-for-build 42 --bogus 1
check "unknown option: exit 2" rc_is 2
check "usage errors show the usage text" err_has "wait-for-build <build>"
check "usage errors make no request" no_requests
run_asc -- frobnicate
check "unknown command: exit 2" rc_is 2

# ================================================================= (d) =======
group "(d) set-whats-new: create, update, locales, truncation"

NOTES=$'- fix the thing\n- add "quotes" and a \\ backslash\n- emoji \xf0\x9f\x98\x80 and caf\xc3\xa9'
LOC_ROUTE_PATH="/v1/builds/B42/betaBuildLocalizations"

new_case notes-create
scenario "$(app_route)" "$(builds_route 42 "$(resp 200 "$(list "$(build_obj VALID "$EXPIRY")")")")" \
  "$(route GET "$LOC_ROUTE_PATH" '[]' "$(resp 200 "$(list)")")" \
  "$(route POST /v1/betaBuildLocalizations '[]' "$(resp 201 '{"data":{"id":"L1","type":"betaBuildLocalizations"}}')")"
run_asc -- set-whats-new 42 "$NOTES"
check "no localization yet: exits 0" rc_is 0
check "created exactly one localization" req_matching_is 'method=POST path=/v1/betaBuildLocalizations ' 1
check "no PATCH when there was nothing to update" req_lacks 'method=PATCH'
check "body type is betaBuildLocalizations" body_is POST /v1/betaBuildLocalizations data.type betaBuildLocalizations
check "body locale is en-US" body_is POST /v1/betaBuildLocalizations data.attributes.locale en-US
check "body whatsNew is the text, newlines, quotes, backslash and Unicode intact" body_is POST /v1/betaBuildLocalizations data.attributes.whatsNew "$NOTES"
check "body relates the localization to the build" body_is POST /v1/betaBuildLocalizations data.relationships.build.data.id B42
check "body relationship type is builds" body_is POST /v1/betaBuildLocalizations data.relationships.build.data.type builds
check "the POST was signed correctly" every_signature_valid
check "reports what it set" out_has "build 42: set What to Test for en-US"
check "no request was unmatched" no_unmatched

new_case notes-update
scenario "$(app_route)" "$(builds_route 42 "$(resp 200 "$(list "$(build_obj VALID "$EXPIRY")")")")" \
  "$(route GET "$LOC_ROUTE_PATH" '[]' "$(resp 200 "$(list '{"id":"L7","type":"betaBuildLocalizations","attributes":{"locale":"en-US","whatsNew":"old"}}')")")" \
  "$(route PATCH /v1/betaBuildLocalizations/L7 '[]' "$(resp 200 '{"data":{"id":"L7"}}')")"
run_asc -- set-whats-new 42 "$NOTES"
check "en-US exists: exits 0" rc_is 0
check "patched that localization" req_matching_is 'method=PATCH path=/v1/betaBuildLocalizations/L7 ' 1
check "no POST when en-US already existed" req_lacks 'method=POST'
check "patch body id" body_is PATCH /v1/betaBuildLocalizations/L7 data.id L7
check "patch body whatsNew is the text" body_is PATCH /v1/betaBuildLocalizations/L7 data.attributes.whatsNew "$NOTES"
check "patch body type is betaBuildLocalizations" body_is PATCH /v1/betaBuildLocalizations/L7 data.type betaBuildLocalizations

new_case notes-other-locale
scenario "$(app_route)" "$(builds_route 42 "$(resp 200 "$(list "$(build_obj VALID "$EXPIRY")")")")" \
  "$(route GET "$LOC_ROUTE_PATH" '[]' "$(resp 200 "$(list '{"id":"L9","type":"betaBuildLocalizations","attributes":{"locale":"fr-FR","whatsNew":"vieux"}}')")")" \
  "$(route PATCH /v1/betaBuildLocalizations/L9 '[]' "$(resp 200 '{"data":{"id":"L9"}}')")" \
  "$(route POST /v1/betaBuildLocalizations '[]' "$(resp 201 '{"data":{"id":"L10"}}')")"
run_asc -- set-whats-new 42 "- one"
check "only fr-FR exists: exits 0" rc_is 0
check "updated the existing fr-FR localization" req_matching_is 'method=PATCH path=/v1/betaBuildLocalizations/L9 ' 1
check "and created en-US" body_is POST /v1/betaBuildLocalizations data.attributes.locale en-US

new_case notes-long
LONG=$(awk 'BEGIN { for (i = 1; i <= 400; i++) printf "- commit subject number %d with some padding words here\n", i }')
scenario "$(app_route)" "$(builds_route 42 "$(resp 200 "$(list "$(build_obj VALID "$EXPIRY")")")")" \
  "$(route GET "$LOC_ROUTE_PATH" '[]' "$(resp 200 "$(list)")")" \
  "$(route POST /v1/betaBuildLocalizations '[]' "$(resp 201 '{"data":{"id":"L1"}}')")"
run_asc -- set-whats-new 42 "$LONG"
check "over-long text: exits 0" rc_is 0
check "over-long text: cut to at most 4000 characters" body_length_at_most POST /v1/betaBuildLocalizations data.attributes.whatsNew 4000
check "over-long text: says it was truncated" body_ends_with POST /v1/betaBuildLocalizations data.attributes.whatsNew "(truncated)"
check "over-long text: keeps the start of the text" body_starts_with POST /v1/betaBuildLocalizations data.attributes.whatsNew "- commit subject number 1 with"

new_case notes-empty
scenario "$(app_route)"
run_asc -- set-whats-new 42 $'  \n '
check "blank text: exits 2" rc_is 2
check "blank text: says it is empty" err_has "What to Test text is empty"
check "blank text: no request was made" no_requests

new_case notes-no-build
scenario "$(app_route)" "$(builds_route 42 "$(resp 200 "$(list)")")"
run_asc -- set-whats-new 42 "- x"
check "build not listed: exits 1" rc_is 1
check "build not listed: says so" err_has "build 42 is not listed in App Store Connect"

new_case notes-409
scenario "$(app_route)" "$(builds_route 42 "$(resp 200 "$(list "$(build_obj VALID "$EXPIRY")")")")" \
  "$(route GET "$LOC_ROUTE_PATH" '[]' "$(resp 200 "$(list)")")" \
  "$(route POST /v1/betaBuildLocalizations '[]' "$(resp 409 '{"errors":[{"code":"ENTITY_ERROR.ATTRIBUTE.INVALID","title":"An attribute value is invalid.","detail":"whatsNew is too long"}]}')")"
run_asc -- set-whats-new 42 "- x"
check "409 on create: exits 1" rc_is 1
check "409 on create: shows Apple's code, title and detail" err_has "HTTP 409: ENTITY_ERROR.ATTRIBUTE.INVALID - An attribute value is invalid. - whatsNew is too long"
check "409 on create: the POST is not repeated" req_matching_is 'method=POST ' 1

new_case notes-usage
scenario "$(app_route)"
run_asc -- set-whats-new 42
check "text missing: exit 2" rc_is 2
run_asc -- set-whats-new abc "- x"
check "bad build number: exit 2" rc_is 2

# ================================================================= (e) =======
group "(e) ensure-in-group: add when missing, no-op when present"

GROUP_ROUTE=$(route GET /v1/betaGroups '["filter[app]=APP1","filter[name]=Family"]' \
  "$(resp 200 "$(list '{"id":"G1","type":"betaGroups","attributes":{"name":"Family","isInternalGroup":true,"hasAccessToAllBuilds":true}}')")")
VALID_BUILD_ROUTE=$(builds_route 42 "$(resp 200 "$(list "$(build_obj VALID "$EXPIRY")")")")
MEMBERSHIP='["filter[id]=B42","filter[betaGroups]=G1"]'

new_case group-add
scenario "$(app_route)" "$VALID_BUILD_ROUTE" "$GROUP_ROUTE" \
  "$(route GET /v1/builds "$MEMBERSHIP" "$(resp 200 "$(list)")")" \
  "$(route POST /v1/builds/B42/relationships/betaGroups '[]' "$(resp 204)")"
run_asc -- ensure-in-group 42 Family
check "build not in the group: exits 0" rc_is 0
check "looked the group up by app and name" req_has 'path=/v1/betaGroups .*query=filter\[app\]=APP1&filter\[name\]=Family'
check "checked membership with the build id and group id" req_has 'path=/v1/builds .*query=filter\[id\]=B42&filter\[betaGroups\]=G1'
check "added it with exactly one POST" req_matching_is 'method=POST path=/v1/builds/B42/relationships/betaGroups ' 1
check "POST body links the group (type)" body_is POST /v1/builds/B42/relationships/betaGroups data.0.type betaGroups
check "POST body links the group (id)" body_is POST /v1/builds/B42/relationships/betaGroups data.0.id G1
check "says it added the build" out_has "added build 42 to group Family"
check "reports whether automatic distribution is on" out_has "automatic distribution is on"
check "every request was signed correctly" every_signature_valid
check "no request was unmatched" no_unmatched

new_case group-present
scenario "$(app_route)" "$VALID_BUILD_ROUTE" "$GROUP_ROUTE" \
  "$(route GET /v1/builds "$MEMBERSHIP" "$(resp 200 "$(list "$(build_obj VALID "$EXPIRY")")")")"
run_asc -- ensure-in-group 42 Family
check "build already in the group: exits 0" rc_is 0
check "already in the group: no POST at all (no-op)" req_lacks 'method=POST'
check "already in the group: says nothing to do" out_has "build 42 is already in group Family (nothing to do"

new_case group-missing
scenario "$(app_route)" "$VALID_BUILD_ROUTE" \
  "$(route GET /v1/betaGroups '["filter[name]=Family"]' "$(resp 200 "$(list)")")" \
  "$(route GET /v1/apps/APP1/betaGroups '[]' "$(resp 200 "$(list '{"id":"G2","type":"betaGroups","attributes":{"name":"Beta Friends","isInternalGroup":false}}')")")"
run_asc -- ensure-in-group 42 Family
check "no such group: exits 1" rc_is 1
check "no such group: lists the groups that exist" err_has "no beta group named Family on this app (groups: Beta Friends)"
check "no such group: nothing was POSTed" req_lacks 'method=POST'

new_case group-external
scenario "$(app_route)" "$VALID_BUILD_ROUTE" \
  "$(route GET /v1/betaGroups '["filter[name]=Family"]' "$(resp 200 "$(list '{"id":"G1","type":"betaGroups","attributes":{"name":"Family","isInternalGroup":false}}')")")"
run_asc -- ensure-in-group 42 Family
check "external group: exits 1" rc_is 1
check "external group: says it is not internal" err_has "is not an internal group"
check "external group: nothing was POSTed" req_lacks 'method=POST'

new_case group-processing
scenario "$(app_route)" "$(builds_route 42 "$(resp 200 "$(list "$(build_obj PROCESSING)")")")"
run_asc -- ensure-in-group 42 Family
check "build still PROCESSING: exits 1" rc_is 1
check "build still PROCESSING: says it is not VALID" err_has "build 42 is PROCESSING, not VALID"
check "build still PROCESSING: no group request" req_lacks 'path=/v1/betaGroups'

new_case group-race
scenario "$(app_route)" "$VALID_BUILD_ROUTE" "$GROUP_ROUTE" \
  "$(route GET /v1/builds "$MEMBERSHIP" "$(resp 200 "$(list)")" "$(resp 200 "$(list "$(build_obj VALID "$EXPIRY")")")")" \
  "$(route POST /v1/builds/B42/relationships/betaGroups '[]' "$(resp 409 '{"errors":[{"code":"STATE_ERROR","title":"already there"}]}')")"
run_asc -- ensure-in-group 42 Family
check "409 on POST because distribution added it meanwhile: exits 0" rc_is 0

new_case group-409
scenario "$(app_route)" "$VALID_BUILD_ROUTE" "$GROUP_ROUTE" \
  "$(route GET /v1/builds "$MEMBERSHIP" "$(resp 200 "$(list)")")" \
  "$(route POST /v1/builds/B42/relationships/betaGroups '[]' "$(resp 409 '{"errors":[{"code":"STATE_ERROR","title":"A beta group cannot be edited","detail":"build is not in a testable state"}]}')")"
run_asc -- ensure-in-group 42 Family
check "409 and still not in the group: exits 1" rc_is 1
check "409 and still not in the group: shows Apple's reason" err_has "HTTP 409: STATE_ERROR - A beta group cannot be edited - build is not in a testable state"
check "409: the POST is not repeated" req_matching_is 'method=POST ' 1

new_case group-usage
scenario "$(app_route)"
run_asc -- ensure-in-group 42
check "group name missing: exit 2" rc_is 2
run_asc -- ensure-in-group 42 ""
check "empty group name: exit 2" rc_is 2

# ================================================================= (f) =======
group "(f) latest-build: processing state and the exact expirationDate"

new_case latest-valid
scenario "$(app_route)" "$(route GET /v1/builds '["filter[app]=APP1"]' "$(resp 200 "$(list "$(build_obj VALID 2099-01-01T10:00:00.123-08:00 43 B43)" "$(build_obj VALID "$EXPIRY" 42)")")")"
run_asc -- latest-build
check "newest VALID: exits 0" rc_is 0
check "prints the newest build's number, state and Apple's exact expirationDate string" out_has "newest build 43: state=VALID uploaded=2026-10-03T10:00:00-07:00 expirationDate=2099-01-01T10:00:00.123-08:00 ("
check "prints the same instant in UTC" out_has "2099-01-01T18:00:00Z"
check "prints the days left" out_has " days left)"
check "newest is VALID: no second line" out_lacks "newest VALID build"
check "asks for the newest first, 20 builds" req_has 'sort=-uploadedDate&limit=20$'
check "one build listing request" req_matching_is 'path=/v1/builds ' 1
check "no key or token in the output" no_secrets_in_output

new_case latest-processing
scenario "$(app_route)" "$(route GET /v1/builds '["filter[app]=APP1"]' "$(resp 200 "$(list "$(build_obj PROCESSING '' 44 B44)" "$(build_obj VALID "$EXPIRY" 43 B43)")")")"
run_asc -- latest-build
check "newest PROCESSING: exits 0" rc_is 0
check "newest PROCESSING: shows its state" out_has "newest build 44: state=PROCESSING"
check "newest PROCESSING: no expirationDate yet is reported as such" out_has "expirationDate=(none reported)"
check "newest PROCESSING: also shows the newest VALID build with its exact expirationDate" out_has "newest VALID build 43: state=VALID uploaded=2026-10-03T10:00:00-07:00 expirationDate=$EXPIRY ("

new_case latest-expired
scenario "$(app_route)" "$(route GET /v1/builds '["filter[app]=APP1"]' "$(resp 200 "$(list "$(build_obj VALID 2020-01-01T00:00:00Z 40 B40)")")")"
run_asc -- latest-build
check "an expired build: exits 0" rc_is 0
check "an expired build: marked EXPIRED" out_has "EXPIRED)"

new_case latest-none-valid
scenario "$(app_route)" "$(route GET /v1/builds '["filter[app]=APP1"]' "$(resp 200 "$(list "$(build_obj FAILED '' 41 B41)")")")"
run_asc -- latest-build
check "only a FAILED build: exits 0" rc_is 0
check "only a FAILED build: says so" out_has "none of the 20 newest builds is VALID"

new_case latest-no-builds
scenario "$(app_route)" "$(route GET /v1/builds '["filter[app]=APP1"]' "$(resp 200 "$(list)")")"
run_asc -- latest-build
check "no builds: exits 1" rc_is 1
check "no builds: says to run make testflight" err_has "no builds are listed for $BUNDLE yet"

new_case latest-args
scenario "$(app_route)"
run_asc -- latest-build extra
check "latest-build with an argument: exit 2" rc_is 2

# ================================================================= (g) =======
group "(g) runs as the lane runs it: swift scripts/asc.swift"

new_case interpreter
scenario "$(app_route)" "$(route GET /v1/builds '["filter[app]=APP1"]' "$(resp 200 "$(list "$(build_obj VALID "$EXPIRY" 42)")")")"
ASC_BIN="swift $ROOT/scripts/asc.swift"
run_asc -- latest-build
ASC_BIN=""
check "swift scripts/asc.swift latest-build: exits 0" rc_is 0
check "swift scripts/asc.swift latest-build: prints the state and expirationDate" out_has "newest build 42: state=VALID uploaded=2026-10-03T10:00:00-07:00 expirationDate=$EXPIRY"
check "swift scripts/asc.swift latest-build: JWT verified by the stub" every_signature_valid

# ================================================================= (h) =======
group "(h) source hygiene: no third-party code, only the ASC variables from .env.example"

asc_imports() { sed -n 's/^import //p' "$ROOT/scripts/asc.swift" | sort | tr '\n' ' '; }
check "asc.swift imports only CryptoKit and Foundation (NFR-7)" test "$(asc_imports)" = "CryptoKit Foundation "
asc_env_names() { grep -oE '"ASC_[A-Z0-9_]+"' "$ROOT/scripts/asc.swift" | tr -d '"' | grep -vE '^ASC_TEST_' | sort -u | tr '\n' ' '; }
check "asc.swift reads exactly ASC_ISSUER_ID, ASC_KEY_ID and ASC_PRIVATE_KEY_BASE64" \
  test "$(asc_env_names)" = "ASC_ISSUER_ID ASC_KEY_ID ASC_PRIVATE_KEY_BASE64 "
env_example_lists_asc_vars() {
  local name
  for name in ASC_ISSUER_ID ASC_KEY_ID ASC_PRIVATE_KEY_BASE64; do
    grep -qE "^$name=op://OpenMoji/testflight-asc-api-key/" "$ROOT/release/.env.example" || return 1
  done
}
check "release/.env.example injects those three from the 1Password item" env_example_lists_asc_vars
asc_never_writes_files() { ! grep -nE 'write\(to:|createFile|FileManager|NSTemporaryDirectory|contentsOfFile' "$ROOT/scripts/asc.swift"; }
check "asc.swift never writes a file (the key stays in memory)" asc_never_writes_files

if command -v shellcheck >/dev/null 2>&1; then
  check "shellcheck: test-asc.sh is clean" shellcheck -s bash "${BASH_SOURCE[0]}"
else
  printf '  skip  shellcheck is not installed (brew install shellcheck)\n'
fi

printf '\n%s passed, %s failed\n' "$PASSES" "$FAILURES"
[ "$FAILURES" -eq 0 ]
