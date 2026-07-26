#!/usr/bin/env bash
# Integration and stress tests against a real server process.
#
#   ./run-integration-tests.sh              # normal
#   ./run-integration-tests.sh --asan       # under AddressSanitizer/UBSan/LSan
#
# The server is started with NOTES_RUN_MS, so it shuts itself down rather than
# being killed -- which is what makes "shuts down gracefully" something the
# suite can actually observe.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KOKA="${KOKA:-$here/../../kk}"

ASAN=""
[ "${1:-}" = "--asan" ] && ASAN="--fasan"

work="$(mktemp -d)"
trap 'rm -rf "$work"; [ -n "${SERVER_PID:-}" ] && kill "$SERVER_PID" 2>/dev/null' EXIT

pass=0; fail=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL %s\n' "$1"; [ $# -gt 1 ] && printf '       %s\n' "$2"; fail=$((fail+1)); }
grp() { printf '\n== %s\n' "$1"; }

# eq <name> <expected> <actual>
eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2], got [$3]"; fi; }
# contains <name> <needle> <haystack>
contains() { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "missing [$2] in [$3]" ;; esac; }

PORT=18099
BASE="http://127.0.0.1:$PORT"
DB="$work/notes.db"
LOG="$work/server.log"

start_server() {
  local run_ms="${1:-60000}" db="${2:-$DB}"
  NOTES_DB="$db" NOTES_PORT="$PORT" NOTES_RUN_MS="$run_ms" NOTES_LOG=info \
    "$KOKA" run -v0 $ASAN >"$LOG" 2>&1 &
  SERVER_PID=$!
  # wait for readiness rather than sleeping a guessed amount
  for _ in $(seq 1 600); do
    if curl -s -m 1 "$BASE/health" >/dev/null 2>&1; then return 0; fi
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then
      echo "server exited during startup:" >&2; tail -20 "$LOG" >&2; return 1
    fi
    sleep 0.2
  done
  echo "server did not become ready:" >&2; tail -20 "$LOG" >&2
  return 1
}

stop_server() {
  [ -n "${SERVER_PID:-}" ] || return 0
  wait "$SERVER_PID" 2>/dev/null
  SERVER_PID=""
}

code()  { curl -s -m 5 -o /dev/null -w '%{http_code}' "$@"; }
body()  { curl -s -m 5 "$@"; }

echo "building..."
if ! "$KOKA" build -v0 $ASAN >"$work/build.log" 2>&1; then
  tail -30 "$work/build.log" >&2
  echo "build failed" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
grp "startup and readiness"

if start_server 60000; then ok "server starts and reports ready"; else bad "server starts"; exit 1; fi
contains "health reports ok" '"status":"ok"' "$(body "$BASE/health")"
eq "health is 200" 200 "$(code "$BASE/health")"

# ---------------------------------------------------------------------------
grp "the item lifecycle"

created="$(body -X POST -H 'content-type: application/json' \
                -d '{"title":"first","body":"hello"}' "$BASE/items")"
contains "create returns the stored note" '"title":"first"' "$created"
eq "create is 201" 201 "$(code -X POST -H 'content-type: application/json' \
                               -d '{"title":"second"}' "$BASE/items")"

id="$(printf '%s' "$created" | sed -n 's/.*"id":\([0-9]*\).*/\1/p')"
[ -n "$id" ] && ok "create returns an id" || bad "create returns an id" "$created"

contains "the note can be retrieved" '"title":"first"' "$(body "$BASE/items/$id")"
eq "retrieval is 200" 200 "$(code "$BASE/items/$id")"

listed="$(body "$BASE/items")"
contains "listing includes the note" '"first"' "$listed"
contains "listing has a count" '"count":' "$listed"

eq "delete is 204" 204 "$(code -X DELETE "$BASE/items/$id")"
eq "the note is gone" 404 "$(code "$BASE/items/$id")"
eq "deleting twice is 404" 404 "$(code -X DELETE "$BASE/items/$id")"

# ---------------------------------------------------------------------------
grp "input handling"

eq "malformed json is 400" 400 \
   "$(code -X POST -H 'content-type: application/json' -d '{not json' "$BASE/items")"
contains "the error says what was wrong" 'malformed JSON' \
   "$(body -X POST -H 'content-type: application/json' -d '{not json' "$BASE/items")"
eq "a missing title is 422" 422 \
   "$(code -X POST -H 'content-type: application/json' -d '{"body":"x"}' "$BASE/items")"
eq "a wrongly typed title is 422" 422 \
   "$(code -X POST -H 'content-type: application/json' -d '{"title":5}' "$BASE/items")"
eq "the wrong content type is 415" 415 \
   "$(code -X POST -H 'content-type: text/plain' -d '{"title":"x"}' "$BASE/items")"
eq "a non-numeric id is 400" 400 "$(code "$BASE/items/abc")"

# an oversized body must be refused, not buffered
python3 -c "print('{\"title\":\"a\",\"body\":\"' + 'x'*2000000 + '\"}')" > "$work/big.json"
big_code="$(curl -s -m 20 -o /dev/null -w '%{http_code}' -X POST \
              -H 'content-type: application/json' \
              --data-binary "@$work/big.json" "$BASE/items" 2>/dev/null)"
case "$big_code" in
  413|400) ok "an oversized body is rejected (HTTP $big_code)" ;;
  000)     ok "an oversized body is refused at the connection level" ;;
  *)       bad "an oversized body is rejected" "got HTTP $big_code" ;;
esac
eq "the server still works after an oversized request" 200 "$(code "$BASE/health")"

# ---------------------------------------------------------------------------
grp "routing"

eq "an unknown route is 404" 404 "$(code "$BASE/nope")"
eq "a wrong method is 405" 405 "$(code -X PUT "$BASE/items")"
contains "405 lists the allowed methods" 'GET' \
   "$(curl -s -m 5 -D - -o /dev/null -X PUT "$BASE/items" | tr -d '\r')"
eq "a deeper unknown path is 404" 404 "$(code "$BASE/items/1/extra")"

# ---------------------------------------------------------------------------
grp "concurrency"

# Wait on the *clients* only.  A bare `wait` also waits for the server, which
# was started with `&` -- so every check after it would run against a server
# that had already shut down, and the whole group would look like a
# concurrency failure when nothing was wrong.
client_pids=()
for i in $(seq 1 40); do
  ( curl -s -m 10 -o /dev/null -X POST -H 'content-type: application/json' \
         -d "{\"title\":\"c$i\"}" "$BASE/items" ) &
  client_pids+=($!)
done
wait "${client_pids[@]}"
count="$(body "$BASE/items" | sed -n 's/.*"count":\([0-9]*\).*/\1/p')"
[ -n "$count" ] && [ "$count" -ge 40 ] \
  && ok "40 concurrent creates all landed (count=$count)" \
  || bad "40 concurrent creates all landed" "count=$count"
eq "the server is healthy afterwards" 200 "$(code "$BASE/health")"

# ---------------------------------------------------------------------------
grp "stress"

# repeated connect and disconnect, without sending anything
for _ in $(seq 1 100); do
  (exec 3<>/dev/tcp/127.0.0.1/$PORT) 2>/dev/null && exec 3<&- 3>&-
done
eq "survives 100 connect/disconnect cycles" 200 "$(code "$BASE/health")"

# many short requests over fresh connections
short_fail=0
for _ in $(seq 1 100); do
  [ "$(code -H 'connection: close' "$BASE/health")" = "200" ] || short_fail=$((short_fail+1))
done
eq "100 short requests all succeed" 0 "$short_fail"

# keep-alive: several requests down one connection.
# One -o per URL: curl applies them positionally, so a single -o would discard
# only the first body and let the rest land in the captured output.
ka="$(curl -s -m 10 -w '%{http_code} ' \
        -o /dev/null "$BASE/health" \
        -o /dev/null "$BASE/items" \
        -o /dev/null "$BASE/health" 2>/dev/null)"
contains "keep-alive serves several requests on one connection" "200 200 200" "$ka "

# a slow client: send a request line, pause, then the rest
slow="$( { printf 'GET /health HTTP/1.1\r\nhost: x\r\n'; sleep 1; printf '\r\n'; sleep 1; } \
         | timeout 20 nc 127.0.0.1 $PORT 2>/dev/null | head -1 )"
contains "a slow client is served, not dropped" "200" "$slow"

# a client that disconnects mid-request must not disturb the server
( printf 'POST /items HTTP/1.1\r\nhost: x\r\ncontent-length: 100\r\n\r\npartial' \
  | timeout 3 nc 127.0.0.1 $PORT >/dev/null 2>&1 ) || true
eq "a client that vanishes mid-request is survived" 200 "$(code "$BASE/health")"

# a request that never completes must hit the request timeout, not hang forever
( printf 'GET /health HTTP/1.1\r\nhost: x\r\n' | timeout 25 nc 127.0.0.1 $PORT >/dev/null 2>&1 ) || true
eq "the server is alive after an abandoned request" 200 "$(code "$BASE/health")"

# ---------------------------------------------------------------------------
grp "logging"

# Grep the whole log rather than its head: a sanitizer build prints compiler
# notes first, and those are not the server's output.
contains "logs are line-delimited json"  '"level":"info"' "$(grep -m1 '^{' "$LOG")"
contains "logs carry a request id"       '"request-id":"r' "$(cat "$LOG")"
contains "logs carry the status"         '"status":"200"'  "$(cat "$LOG")"
contains "logs carry the method and path" '"path":"/health"' "$(cat "$LOG")"
contains "logs carry the service context" '"service":"notes"' "$(cat "$LOG")"

# ---------------------------------------------------------------------------
grp "graceful shutdown"

stop_server
contains "the server logs that it stopped" '"msg":"server stopped"' "$(cat "$LOG")"
sleep 0.5
[ "$(code "$BASE/health")" = "000" ] \
  && ok "the port is released after shutdown" \
  || bad "the port is released after shutdown"
grep -q "uncaught exception" "$LOG" \
  && bad "shutdown is clean" "$(grep 'uncaught exception' "$LOG" | head -2)" \
  || ok "shutdown leaves no uncaught exception"

# ---------------------------------------------------------------------------
grp "persistence across a restart"

if start_server 20000; then
  again="$(body "$BASE/items" | sed -n 's/.*"count":\([0-9]*\).*/\1/p')"
  [ -n "$again" ] && [ "$again" = "$count" ] \
    && ok "the data is still there after a restart (count=$again)" \
    || bad "the data is still there after a restart" "before=$count after=$again"
  stop_server
else
  bad "the server restarts against an existing database"
fi

# ---------------------------------------------------------------------------
printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
