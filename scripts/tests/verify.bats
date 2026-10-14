#!/usr/bin/env bats
# shellcheck disable=SC2016,SC2164,SC2314   # stub bodies are single-quoted on purpose; the sandbox cd cannot fail; `! grep` is the last command
# odoosync-verify: read-only host and stack checks. A sandbox with stand-ins for every system command. No network, no root.

SCRIPTS="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

setup() {
  ROOT="$(mktemp -d)"; export ODOOSYNC_TEST_ROOT="$ROOT"
  ETC="$ROOT/etc/odoosync"; RFS="$ROOT/rootfs"; STUBS="$ROOT/stubs"; SRV="$ROOT/srv/odoosync"
  mkdir -p "$ETC/trust" "$RFS/etc/docker" "$RFS/etc/systemd/journald.conf.d" "$STUBS" "$SRV/pgdata"
  printf 'OMNISYNC_DEPLOY_ENV=staging\nOMNISYNC_COMPOSE_PROJECT=proj\nOMNISYNC_PGDATA_VOLUME_ID=vol-123\n' > "$ETC/env"
  cat > "$ETC/trust/image-policy.json" <<'JSON'
{"pg_user":"omnisync","verify":{"public_ports":[22,80,3001],"smoke":[{"url":"http://127.0.0.1:8000/admin/login/","expect":[200,302]}]}}
JSON
  printf 'PRETTY_NAME="Ubuntu 24.04.5 LTS"\n' > "$RFS/etc/os-release"
  printf '{"log-driver":"json-file","log-opts":{"max-size":"50m","max-file":"5"}}\n' > "$RFS/etc/docker/daemon.json"
  printf '[Journal]\nSystemMaxUse=500M\n' > "$RFS/etc/systemd/journald.conf.d/cap.conf"
  printf 'volume_id=vol-123 env=staging\n' > "$SRV/pgdata/VOLUME_ID"
  export STUB_ROOT="$ROOT"
  mk ufw 'echo "Status: active"'
  mk fail2ban-unused 'true'
  mk systemctl 'case "$1" in is-active) echo "${STUB_F2B:-active}";; list-units) [ -z "${STUB_RUNNER:-}" ] || echo "actions.runner.x loaded active running";; esac'
  mk timedatectl 'echo "${STUB_NTP:-yes}"'
  mk unattended-upgrade '[ -z "${STUB_UU_FAIL:-}" ]'
  mk swapon '[ -n "${STUB_NO_SWAP:-}" ] || echo "/swapfile file 2G 0B -2"'
  mk id 'if [ "$1" = ghrunner ]; then [ -n "${STUB_GHRUNNER:-}" ]; else /usr/bin/id "$@"; fi'
  mk findmnt '[ -z "${STUB_NO_MOUNT:-}" ]'
  mk curl 'printf "%s" "${STUB_HTTP:-200}"'
  mk ss 'printf "%s\n" "LISTEN 0 128 0.0.0.0:22 0.0.0.0:*" "LISTEN 0 128 0.0.0.0:80 0.0.0.0:*" "LISTEN 0 128 127.0.0.1:8000 0.0.0.0:*" ${STUB_SS_EXTRA:+"$STUB_SS_EXTRA"}'
  cat > "$STUBS/docker" <<'EOS'
#!/usr/bin/env bash
case "$1" in
  version) echo 29.9.0 ;;
  compose) echo 5.6.0 ;;
  inspect) echo sha256:img ;;
  image) printf '{"org.syncoria.python":"3.12.15","org.syncoria.django":"5.2.18"}\n' ;;
  ps)
    case "$*" in
      *"--format {{.Ports}}"*) printf '%s\n' "${STUB_PORTS:-127.0.0.1:8000->8000/tcp, 80/tcp}" ;;
      *" -a "*) printf '%s\n' "web|running|Up 1 hour (healthy)" "pg|running|Up 1 hour (healthy)" ${STUB_ROW:+"$STUB_ROW"} ;;
      *service=postgres*) [ -n "${STUB_NO_PG:-}" ] || echo cid-pg ;;
      *) echo cid-x ;;
    esac ;;
  exec)
    case "$*" in
      *pg_isready*) [ -z "${STUB_PG_DOWN:-}" ] ;;
      *"nginx -v"*) echo "nginx version: nginx/1.27.5" >&2 ;;
      *rabbitmq-diagnostics*) echo 3.13.7 ;;
      *"show server_version"*) echo 17.11 ;;
      *datcollversion*) echo "${STUB_COLL:-0}" ;;
    esac ;;
esac
EOS
  chmod +x "$STUBS/docker"
  export PATH="$STUBS:$PATH"
}
mk() { printf '#!/usr/bin/env bash\n%s\n' "$2" > "$STUBS/$1"; chmod +x "$STUBS/$1"; }
teardown() { rm -rf "$ROOT"; }
v() { run "$SCRIPTS/odoosync-verify" "$@"; echo "$output"; }

@test "versions prints what runs and exits 0" {
  v versions
  [ "$status" -eq 0 ]
  [[ "$output" == *"INFO os Ubuntu 24.04.5 LTS"* ]]
  [[ "$output" == *"INFO docker 29.9.0"* ]]
  [[ "$output" == *"INFO nginx 1.27.5"* ]]
  [[ "$output" == *"INFO postgres 17.11"* ]]
  [[ "$output" == *"INFO rabbitmq 3.13.7"* ]]
  [[ "$output" == *"INFO python 3.12.15"* ]]
  [[ "$output" == *"INFO django 5.2.18"* ]]
}

@test "host: a healthy baseline passes" {
  v host
  [ "$status" -eq 0 ]; [[ "$output" == *"verify_ok"* ]]
}

@test "host: each broken baseline item fails by name" {
  STUB_F2B=inactive v host;       [ "$status" -eq 1 ]; [[ "$output" == *"FAIL fail2ban"* ]]
  STUB_NTP=no v host;             [ "$status" -eq 1 ]; [[ "$output" == *"FAIL time_sync"* ]]
  STUB_UU_FAIL=1 v host;          [ "$status" -eq 1 ]; [[ "$output" == *"FAIL unattended_upgrades"* ]]
  STUB_NO_SWAP=1 v host;          [ "$status" -eq 1 ]; [[ "$output" == *"FAIL swap"* ]]
  STUB_GHRUNNER=1 v host;         [ "$status" -eq 1 ]; [[ "$output" == *"FAIL ghrunner_user"* ]]
  STUB_RUNNER=1 v host;           [ "$status" -eq 1 ]; [[ "$output" == *"FAIL runner_service"* ]]
}

@test "host: missing docker log rotation or journald cap fails" {
  echo '{}' > "$RFS/etc/docker/daemon.json"
  v host; [ "$status" -eq 1 ]; [[ "$output" == *"FAIL docker_log_rotation"* ]]
  rm "$RFS/etc/systemd/journald.conf.d/cap.conf"
  v host; [[ "$output" == *"FAIL journald_cap"* ]]
}

@test "host --post-boot: mountpoint and matching VOLUME_ID pass" {
  v host --post-boot
  [ "$status" -eq 0 ]; [[ "$output" == *"PASS pgdata_mount"* ]]; [[ "$output" == *"PASS volume_id"* ]]
}

@test "host --post-boot: not a mountpoint fails" {
  STUB_NO_MOUNT=1 v host --post-boot
  [ "$status" -eq 1 ]; [[ "$output" == *"FAIL pgdata_mount"* ]]
}

@test "host --post-boot: a VOLUME_ID for another volume or another environment fails" {
  printf 'volume_id=vol-999 env=staging\n' > "$SRV/pgdata/VOLUME_ID"
  v host --post-boot; [ "$status" -eq 1 ]; [[ "$output" == *"FAIL volume_id"* ]]
  printf 'volume_id=vol-123 env=production\n' > "$SRV/pgdata/VOLUME_ID"
  v host --post-boot; [ "$status" -eq 1 ]; [[ "$output" == *"FAIL volume_id"* ]]
  rm "$SRV/pgdata/VOLUME_ID"
  v host --post-boot; [ "$status" -eq 1 ]; [[ "$output" == *"FAIL volume_id no marker"* ]]
}

@test "host --post-boot: a collation version change warns but does not fail" {
  STUB_COLL=2 v host --post-boot
  [ "$status" -eq 0 ]; [[ "$output" == *"WARN collation"* ]]
}

@test "the plain host check does not look at pgdata" {
  STUB_NO_MOUNT=1 v host
  [ "$status" -eq 0 ]
}

@test "smoke: all containers healthy and URLs answering passes" {
  v smoke
  [ "$status" -eq 0 ]; [[ "$output" == *"PASS url:http://127.0.0.1:8000/admin/login/ 200"* ]]; [[ "$output" == *"PASS postgres_ready"* ]]
}

@test "smoke: an exited or unhealthy container fails" {
  STUB_ROW="bad|exited|Exited (1) 2 minutes ago" v smoke
  [ "$status" -eq 1 ]; [[ "$output" == *"FAIL container:bad"* ]]
  STUB_ROW="sick|running|Up 5 minutes (unhealthy)" v smoke
  [ "$status" -eq 1 ]; [[ "$output" == *"FAIL container:sick"* ]]
}

@test "smoke: a URL answering with an unexpected code fails" {
  STUB_HTTP=500 v smoke
  [ "$status" -eq 1 ]; [[ "$output" == *"FAIL url:"* ]]
}

@test "smoke: postgres not ready fails" {
  STUB_PG_DOWN=1 v smoke
  [ "$status" -eq 1 ]; [[ "$output" == *"FAIL postgres_ready"* ]]
}

@test "security: only allowed public ports passes" {
  v security
  [ "$status" -eq 0 ]; [[ "$output" == *"PASS database_port"* ]]
}

@test "security: a public listener outside the policy fails" {
  STUB_SS_EXTRA="LISTEN 0 128 0.0.0.0:9999 0.0.0.0:*" v security
  [ "$status" -eq 1 ]; [[ "$output" == *"FAIL listen:9999"* ]]
}

@test "security: the same port on IPv4 and IPv6 is one finding" {
  STUB_SS_EXTRA="LISTEN 0 128 0.0.0.0:9999 0.0.0.0:*
LISTEN 0 128 [::]:9999 [::]:*" v security
  [ "$(printf '%s\n' "$output" | grep -c 'FAIL listen:9999')" -eq 1 ]
}

@test "security: a public 5432 fails even if someone allowed it" {
  jq '.verify.public_ports += [5432]' "$ETC/trust/image-policy.json" > "$ROOT/p" && mv "$ROOT/p" "$ETC/trust/image-policy.json"
  STUB_SS_EXTRA="LISTEN 0 128 0.0.0.0:5432 0.0.0.0:*" v security
  [ "$status" -eq 1 ]; [[ "$output" == *"FAIL database_port"* ]]
}

@test "security: a docker publish on all interfaces outside the policy fails, loopback does not" {
  STUB_PORTS="0.0.0.0:8081->8081/tcp, [::]:8081->8081/tcp" v security
  [ "$status" -eq 1 ]; [[ "$output" == *"FAIL docker_publish:8081"* ]]
}

@test "unimplemented subcommands and bad use exit 2" {
  v parity; [ "$status" -eq 2 ]
  v nonsense; [ "$status" -eq 2 ]
}

@test "the tool changes nothing and never prints a secret" {
  ! grep -nE "docker (run|rm|stop|restart|compose (up|down))|rm -|chmod|systemctl (start|stop|restart|enable)|password|SECRET|TOKEN" "$SCRIPTS/odoosync-verify"
}
