#!/usr/bin/env bats
# shellcheck disable=SC2016,SC2164,SC2314   # stub bodies are single-quoted on purpose; the sandbox cd cannot fail; `! grep` is the last command
# odoosync-deploy blue/green for web (ADR-08 3.9): migrate, idle colour, readiness, relink + reload, quiet check, stop with the compose grace.
load helpers

setup() {
  make_sandbox; set_env staging
  REPO=ghcr.io/syncoria/omnisync; INC="$ROOT/upstream-web.conf"
  policy_add '.bluegreen = {"web": {"colours": {"a": {"service": "web-a", "port": 8000}, "b": {"service": "web-b", "port": 8002}},
                                   "include": "'"$INC"'", "edge_service": "edge", "quiet_cap": 4, "probe_timeout": 2}}'
  # wrap the shared docker stub: handle the blue/green calls here, everything else (pull, psql, serving values) falls through
  mv "$STUBS/docker" "$STUBS/docker.base"
  cat > "$STUBS/docker" <<'EOS'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_DOCKER_LOG"
case "$1" in
  compose)
    case "$*" in
      *" config --format json"*) echo '{"services":{"web-a":{"stop_grace_period":"4m30s"},"web-b":{"stop_grace_period":"4m30s"}}}' ;;
      *" ps -q "*) all="$*"; svc="${all##* }"; [ ! -e "$STUB_ROOT/running.$svc" ] || echo "cid-$svc" ;;
      *" run --rm "*) [ -z "${STUB_MIGRATE_FAIL:-}" ] ;;
      *" up -d "*) [ -z "${STUB_UP_FAIL:-}" ] || exit 1; all="$*"; svc="${all##* }"; touch "$STUB_ROOT/running.$svc" ;;
      *" stop "*) all="$*"; svc="${all##* }"; rm -f "$STUB_ROOT/running.$svc" ;;
    esac ;;
  image) case "$*" in *org.opencontainers.image.revision*) echo "${STUB_REV:-rev123}" ;; *) exec "$(dirname "$0")/docker.base" "$@" ;; esac ;;
  exec)
    case "$*" in
      *"nginx -t"*) [ -z "${STUB_NGINX_FAIL:-}" ] ;;
      *"nginx -s reload"*) true ;;
      *"manage.py check"*) [ -z "${STUB_CHECK_FAIL:-}" ] ;;
      *"/proc/net/tcp"*|*"python -c"*)  # established connections: a queue of counts, one per call (the last repeats)
        q="$STUB_ROOT/estab.seq"; [ -f "$q" ] || printf '%s' "${STUB_ESTAB:-0}" > "$q"
        read -r first rest < "$q"; if [ -n "$rest" ]; then printf '%s' "$rest" > "$q"; fi
        echo "${first:-0}" ;;
      *) exec "$(dirname "$0")/docker.base" "$@" ;;
    esac ;;
  *) exec "$(dirname "$0")/docker.base" "$@" ;;
esac
EOS
  cat > "$STUBS/curl" <<'EOS'
#!/usr/bin/env bash
[ -z "${STUB_HEALTH_DOWN:-}" ] || exit 22
printf '{"status":"ok","release":"%s"}\n' "${STUB_HEALTH_RELEASE:-rev123}"
EOS
  chmod +x "$STUBS/docker" "$STUBS/curl"
  export PATH="$STUBS:$PATH"
  touch "$ROOT/running.edge"   # the edge container is up
}
teardown() { rm -rf "$ROOT"; }

# like helpers' apply, but prints the tool's output so a failing test shows why
apply() { local s="$1" d="$2" r="$3"; shift 3; run ${BG_TRACE:+bash -x} "$SCRIPTS/odoosync-deploy" request --env /etc/odoosync/env --service "$s" --digest "$d" --ref "$r" "$@"; echo "$output"; if [ "$status" -ne 0 ]; then echo "--- docker log"; cat "$STUB_DOCKER_LOG"; fi; }

running() { touch "$ROOT/running.$1"; }
is_running() { [ -e "$ROOT/running.$1" ]; }
last_result() { tail -n1 "$SRV/state/releases.jsonl" | jq -r .result; }
order_ok() {  # the first line matching each pattern must appear in the given order in the docker log
  local prev=0 n p
  for p in "$@"; do
    n="$(grep -n -m1 -- "$p" "$STUB_DOCKER_LOG" | cut -d: -f1)"
    if [ -z "$n" ] || [ "$n" -le "$prev" ]; then echo "out of order or missing: $p"; return 1; fi
    prev="$n"
  done
}

@test "blue/green: a switch from a to b runs migrate, start, reload, then stops the old colour, in that order" {
  running web-a; echo a > "$SRV/state/web.active"; printf 'server 127.0.0.1:8000;\n' > "$INC"
  apply web "$D1" release/ok
  [ "$status" -eq 0 ]; [[ "$output" == *"applied service=web"*"colour=b"* ]]
  order_ok " run --rm --no-deps web-b python manage.py migrate" " up -d --no-deps --force-recreate web-b" "nginx -t" "nginx -s reload" " stop -t 270 web-a"
  is_running web-b; ! is_running web-a
  [ "$(cat "$INC")" = "server 127.0.0.1:8002;" ]
  [ "$(cat "$SRV/state/web.active")" = b ]
  [ "$(last_result)" = ok ]
}

@test "blue/green: the next deploy switches back to a" {
  running web-b; echo b > "$SRV/state/web.active"
  apply web "$D1" release/ok
  [ "$status" -eq 0 ]; [[ "$output" == *"colour=a"* ]]
  [ "$(cat "$INC")" = "server 127.0.0.1:8000;" ]
  ! is_running web-b
}

@test "blue/green: the grace period is read from compose config (4m30s = 270), never a literal" {
  running web-a; echo a > "$SRV/state/web.active"
  apply web "$D1" release/ok
  grep -q " stop -t 270 web-a" "$STUB_DOCKER_LOG"
  ! grep -E ' (up|stop) ' "$STUB_DOCKER_LOG" | grep -vE -- ' -t 270 ' | grep -Eq -- ' -t [0-9]'
  grep -q " config --format json" "$STUB_DOCKER_LOG"
}

@test "blue/green: the new colour gets the new digest through its own image variable" {
  running web-a; echo a > "$SRV/state/web.active"
  apply web "$D1" release/ok
  [ "$(sed -n 's/^IMAGE_WEB_B=//p' "$SRV/state/images.env")" = "$REPO@$D1" ]
}

@test "blue/green: a colour can name its own upstream (a name on the compose network), used in the include" {
  policy_add '.bluegreen.web.colours.b.upstream = "web-b:8000"'
  running web-a; echo a > "$SRV/state/web.active"
  apply web "$D1" release/ok
  [ "$status" -eq 0 ]
  [ "$(cat "$INC")" = "server web-b:8000;" ]
}

@test "blue/green: an upstream with shell characters is refused" {
  policy_add '.bluegreen.web.colours.b.upstream = "x; rm -rf /"'
  running web-a; echo a > "$SRV/state/web.active"
  apply web "$D1" release/ok
  [ "$status" -eq 3 ]; [[ "$output" == *"bluegreen_layout"* ]]
}

@test "blue/green: a first start (nothing running) starts a, relinks, and has no old colour to stop" {
  apply web "$D1" release/ok
  [ "$status" -eq 0 ]; [[ "$output" == *"colour=a"* ]]
  is_running web-a
  ! grep -q " stop -t 270" "$STUB_DOCKER_LOG"
  [ "$(cat "$INC")" = "server 127.0.0.1:8000;" ]
}

@test "blue/green: a failing migrate switches nothing" {
  running web-a; echo a > "$SRV/state/web.active"; printf 'server 127.0.0.1:8000;\n' > "$INC"
  STUB_MIGRATE_FAIL=1 apply web "$D1" release/ok
  [ "$status" -eq 4 ]; [[ "$output" == *"step=migrate"* ]]
  ! grep -q " up -d" "$STUB_DOCKER_LOG"
  is_running web-a
  [ "$(cat "$INC")" = "server 127.0.0.1:8000;" ]; [ "$(last_result)" = failed ]
}

@test "blue/green: a new colour that never reports the expected release is stopped and the old one keeps serving" {
  running web-a; echo a > "$SRV/state/web.active"; printf 'server 127.0.0.1:8000;\n' > "$INC"
  STUB_HEALTH_RELEASE=wrong apply web "$D1" release/ok
  [ "$status" -eq 4 ]; [[ "$output" == *"step=readiness"* ]]
  ! is_running web-b; is_running web-a
  [ "$(cat "$INC")" = "server 127.0.0.1:8000;" ]
  ! grep -q "nginx -s reload" "$STUB_DOCKER_LOG"
}

@test "blue/green: the database check inside the new colour must pass" {
  running web-a; echo a > "$SRV/state/web.active"
  STUB_CHECK_FAIL=1 apply web "$D1" release/ok
  [ "$status" -eq 4 ]; [[ "$output" == *"step=readiness"* ]]
  is_running web-a; ! is_running web-b
}

@test "blue/green: an unreachable /_health fails readiness" {
  running web-a; echo a > "$SRV/state/web.active"
  STUB_HEALTH_DOWN=1 apply web "$D1" release/ok
  [ "$status" -eq 4 ]
  is_running web-a
}

@test "blue/green: nginx refusing the config restores the old include and stops the new colour" {
  running web-a; echo a > "$SRV/state/web.active"; printf 'server 127.0.0.1:8000;\n' > "$INC"
  STUB_NGINX_FAIL=1 apply web "$D1" release/ok
  [ "$status" -eq 4 ]; [[ "$output" == *"step=nginx"* ]]
  [ "$(cat "$INC")" = "server 127.0.0.1:8000;" ]
  is_running web-a; ! is_running web-b
  [ "$(cat "$SRV/state/web.active")" = a ]
  [ "$(last_result)" = failed ]
}

@test "blue/green: waits while the old colour still has established connections, then stops it" {
  running web-a; echo a > "$SRV/state/web.active"
  STUB_ESTAB="2 1 0" apply web "$D1" release/ok
  [ "$status" -eq 0 ]
  [ "$(cat "$ROOT/estab.seq")" = 0 ]
  ! is_running web-a
}

@test "blue/green: at the quiet cap it stops the old colour anyway (the stop itself drains) and logs it" {
  running web-a; echo a > "$SRV/state/web.active"
  STUB_ESTAB="3" apply web "$D1" release/ok
  [ "$status" -eq 0 ]
  ! is_running web-a
  grep -q "quiet_cap_reached" "$ROOT/logger.log"
}

@test "blue/green: every guard still applies first (an unsigned digest is refused before anything starts)" {
  STUB_COSIGN_FAIL="no matching signatures" apply web "$D2" release/ok
  [ "$status" -eq 3 ]
  ! grep -q " up -d" "$STUB_DOCKER_LOG"
}

@test "blue/green: a service without a layout in the policy is still recreated in place" {
  policy_add 'del(.bluegreen)'
  apply web "$D1" release/ok
  [ "$status" -eq 0 ]; [[ "$output" != *"colour="* ]]
  grep ' up ' "$STUB_DOCKER_LOG" | grep -q -- '--no-deps --force-recreate web$'
}

@test "blue/green: production accepts web (with a layout and the digest the signed release file names)" {
  set_env production
  running web-a; echo a > "$SRV/state/web.active"
  apply web "$D1" release/ok
  [ "$status" -eq 0 ]; [[ "$output" == *"colour=b"* ]]
}

@test "blue/green: production still refuses a payment-path service that has no layout (web without one, edge)" {
  set_env production
  policy_add 'del(.bluegreen)'
  apply web "$D1" release/ok
  [ "$status" -eq 3 ]; [[ "$output" == *"apply_needs_bluegreen"* ]]
}

@test "blue/green: rollback of web goes back through the same switch" {
  running web-a; echo a > "$SRV/state/web.active"
  apply web "$D1" release/ok; [ "$status" -eq 0 ]
  apply web "$D3" release/ok; [ "$status" -eq 0 ]
  run "$SCRIPTS/odoosync-deploy" rollback --service web
  [ "$status" -eq 0 ]; [[ "$output" == *"applied service=web digest=$D1"* ]]
}

@test "blue/green: a broken layout in the policy is refused" {
  policy_add '.bluegreen.web.colours.a.port = "x; rm -rf /"'
  apply web "$D1" release/ok
  [ "$status" -eq 3 ]; [[ "$output" == *"bluegreen_layout"* ]]
}
