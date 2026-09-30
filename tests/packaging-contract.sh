#!/usr/bin/env bash
# Fast, Docker-free contracts for release metadata and the test-image harness.
set -euo pipefail

cd "$(dirname "$0")/.."

failures=0

pass() {
  printf 'PASS: %s\n' "$1"
}

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  failures=$((failures + 1))
}

expect_file_line() {
  local description=$1
  local pattern=$2
  local file=$3

  if grep -Eq "$pattern" "$file"; then
    pass "$description"
  else
    fail "$description"
  fi
}

expect_absent() {
  local description=$1
  local pattern=$2
  local file=$3

  if grep -Eq "$pattern" "$file"; then
    fail "$description"
  else
    pass "$description"
  fi
}

expect_command_status() {
  local description=$1
  local expected=$2
  shift 2

  local actual=0
  "$@" >/dev/null 2>&1 || actual=$?
  if [[ $actual -eq $expected ]]; then
    pass "$description"
  else
    fail "$description (expected status $expected, got $actual)"
  fi
}

expect_file_line 'config version is exactly 0.5.1' \
  '^version:[[:space:]]*"0\.5\.1"[[:space:]]*$' hindsight/config.yaml
expect_file_line 'config uses the generic GHCR image' \
  '^image:[[:space:]]*"ghcr\.io/bonzanni/hindsight"[[:space:]]*$' hindsight/config.yaml
expect_absent 'config does not restate the default startup mode' \
  '^startup:' hindsight/config.yaml
expect_absent 'config does not restate the default ingress port' \
  '^ingress_port:' hindsight/config.yaml
expect_absent 'config uses Docker health instead of obsolete watchdog metadata' \
  '^watchdog:' hindsight/config.yaml
expect_file_line 'config keeps ingress enabled' \
  '^ingress:[[:space:]]*true[[:space:]]*$' hindsight/config.yaml
expect_file_line 'config keeps the API port disabled by default' \
  '^[[:space:]]*8888/tcp:[[:space:]]*null[[:space:]]*$' hindsight/config.yaml

arch_values=$(awk '
  /^arch:[[:space:]]*$/ { in_arch=1; next }
  in_arch && /^[^[:space:]]/ { exit }
  in_arch && /^[[:space:]]*-[[:space:]]*/ {
    sub(/^[[:space:]]*-[[:space:]]*/, "")
    print
  }
' hindsight/config.yaml)
if [[ $arch_values == amd64 ]]; then
  pass 'config remains amd64-only'
else
  fail "config remains amd64-only (found: ${arch_values:-none})"
fi

expect_file_line 'Dockerfile keeps the dated trixie base pin' \
  '^ARG BUILD_FROM=ghcr\.io/home-assistant/base-debian:trixie-2026\.05\.0$' hindsight/Dockerfile
expect_file_line 'Dockerfile keeps the upstream digest pin' \
  '^ARG HINDSIGHT_IMAGE=ghcr\.io/vectorize-io/hindsight@sha256:d1840062a5b79940ab7a9f4809ceb90fc776d4ad737cd9329e9b5836cc64ab70$' hindsight/Dockerfile
expect_file_line 'Dockerfile keeps the upstream source lockstep ref' \
  '^ARG HINDSIGHT_REF=5fc4ce20917b916240cef27c212c387a177f115b$' hindsight/Dockerfile
expect_file_line 'Dockerfile bounds the recall admission queue under the consumer budget' \
  '^    HINDSIGHT_API_ADMISSION_RECALL_MAX_WAIT_MS=1000 \\$' hindsight/Dockerfile
expect_file_line 'Dockerfile keeps the 18s recall handler deadline' \
  '^    HINDSIGHT_API_RECALL_HANDLER_TIMEOUT=18 \\$' hindsight/Dockerfile
expect_file_line 'Dockerfile has the OCI source label' \
  'org\.opencontainers\.image\.source="https://github\.com/bonzanni/ha-hindsight-app"' hindsight/Dockerfile
expect_file_line 'Dockerfile has the OCI title label' \
  'org\.opencontainers\.image\.title="Hindsight"' hindsight/Dockerfile
expect_file_line 'Dockerfile has the OCI description label' \
  'org\.opencontainers\.image\.description="Agent memory \(Hindsight\) for Home Assistant"' hindsight/Dockerfile
expect_file_line 'Dockerfile has the OCI license label' \
  'org\.opencontainers\.image\.licenses="MIT"' hindsight/Dockerfile
expect_file_line 'Dockerfile exposes the unchanged API and ingress ports' \
  '^EXPOSE 8888 8099$' hindsight/Dockerfile
expect_file_line 'Dockerfile healthcheck monitors the API health endpoint' \
  '^HEALTHCHECK .*|CMD curl .*127\.0\.0\.1:8888/health' hindsight/Dockerfile

final_from_line=$(grep -n '^FROM ' hindsight/Dockerfile | tail -1 | cut -d: -f1)
first_oci_label_line=$(grep -n 'org\.opencontainers\.image\.source=' hindsight/Dockerfile | head -1 | cut -d: -f1)
if [[ -n $final_from_line && -n $first_oci_label_line && $first_oci_label_line -gt $final_from_line ]]; then
  pass 'OCI labels are attached to the final image stage'
else
  fail 'OCI labels are attached to the final image stage'
fi

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
printf '%s\n' 'signal (send),' >"$tmpdir/send-only.txt"
printf '%s\n' 'signal (receive),' >"$tmpdir/receive-only.txt"
printf '%s\n' 'signal (send,receive),' >"$tmpdir/both.txt"

expect_command_status 'AppArmor validation rejects send-only signal rules' 2 \
  make --no-print-directory apparmor APPARMOR_PROFILE="$tmpdir/send-only.txt" APPARMOR_PARSER=true
expect_command_status 'AppArmor validation rejects receive-only signal rules' 2 \
  make --no-print-directory apparmor APPARMOR_PROFILE="$tmpdir/receive-only.txt" APPARMOR_PARSER=true
expect_command_status 'AppArmor validation accepts a bidirectional signal rule' 0 \
  make --no-print-directory apparmor APPARMOR_PROFILE="$tmpdir/both.txt" APPARMOR_PARSER=true
expect_command_status 'AppArmor parser failures propagate' 2 \
  make --no-print-directory apparmor APPARMOR_PROFILE="$tmpdir/both.txt" APPARMOR_PARSER=false

helper=tests/lib/test-image.sh
if [[ -f $helper ]]; then
  # shellcheck source=tests/lib/test-image.sh
  source "$helper"

  unset TEST_IMAGE
  if [[ $(test_image_ref) == hindsight-addon:dev ]]; then
    pass 'test-image helper defaults to the local development tag'
  else
    fail 'test-image helper defaults to the local development tag'
  fi

  docker_calls="$tmpdir/docker-calls"
  docker() {
    printf '%s\n' "$*" >>"$docker_calls"
  }

  prepare_test_image hindsight/ >/dev/null
  if [[ $(cat "$docker_calls") == 'build -t hindsight-addon:dev hindsight/' ]]; then
    pass 'test-image helper builds the local development image by default'
  else
    fail 'test-image helper builds the local development image by default'
  fi

  : >"$docker_calls"
  TEST_IMAGE='ghcr.io/bonzanni/hindsight:0.3.0@sha256:deadbeef'
  if [[ $(test_image_ref) == "$TEST_IMAGE" ]]; then
    pass 'test-image helper preserves an exact prebuilt reference'
  else
    fail 'test-image helper preserves an exact prebuilt reference'
  fi

  prepare_test_image hindsight/ >/dev/null
  if [[ $(cat "$docker_calls") == "pull $TEST_IMAGE" ]]; then
    pass 'test-image helper pulls a prebuilt reference without building'
  else
    fail 'test-image helper pulls a prebuilt reference without building'
  fi
else
  fail 'sourceable test-image helper exists'
fi

for harness in tests/smoke.sh tests/run-ingress.sh; do
  expect_file_line "$harness sources the shared image helper" \
    'source .*lib/test-image\.sh' "$harness"
  expect_file_line "$harness selects its image through the helper" \
    'IMG=\$\(test_image_ref\)' "$harness"
  expect_file_line "$harness delegates build-or-skip behavior to the helper" \
    'prepare_test_image[[:space:]]+hindsight/' "$harness"
  expect_absent "$harness has no unconditional docker build" \
    'docker[[:space:]]+build' "$harness"
done

if ((failures > 0)); then
  printf '%s\n' "PACKAGING CONTRACTS FAILED: $failures" >&2
  exit 1
fi

printf '%s\n' 'PACKAGING CONTRACTS PASS'
