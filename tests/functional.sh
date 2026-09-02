#!/usr/bin/env bash
# Functional test of the manage-swap module.
#
# Runs cf-agent with the policy sets built by tests/build-policies.sh and checks
# the resulting state. Must run as root on a Linux host with CFEngine installed
# (for example a GitHub Actions runner, or the container started by
# tests/run-locally.sh). The host's swap and /etc/fstab are touched, but restored.
#
# Environment:
#   POLICIES   Directory with the built policy sets (default: tests/out/policies)
#   SWAP_PATH  Swap file path configured in the policy sets (default: /swapfile)
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
policies="${POLICIES:-$here/out/policies}"
swap_path="${SWAP_PATH:-/swapfile}"
export PATH="/var/cfengine/bin:$PATH"

[ "$(id -u)" = "0" ] || { echo "must run as root" >&2; exit 1; }
command -v cf-agent >/dev/null || { echo "cf-agent not found" >&2; exit 1; }
[ -d "$policies/small" ] || { echo "policy sets not found in $policies, run tests/build-policies.sh" >&2; exit 1; }

fstab_backup="$(mktemp)"
cp /etc/fstab "$fstab_backup"
cleanup() {
  swapoff "$swap_path" 2>/dev/null || true
  rm -f "$swap_path"
  cp "$fstab_backup" /etc/fstab
  rm -f "$fstab_backup"
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

use_policy() {
  rm -rf /var/cfengine/inputs
  cp -R "$policies/$1" /var/cfengine/inputs
}
run_agent() {
  cf-agent -KI -f /var/cfengine/inputs/promises.cf > /tmp/agent.log 2>&1 || true
  grep -E "manage-swap|error" /tmp/agent.log || true
  if grep -q "error:" /tmp/agent.log; then fail "agent run had errors"; fi
}
swap_active() { grep -q "^$swap_path " /proc/swaps; }
swap_size_kb() { awk -v p="$swap_path" '$1 == p { print $3 }' /proc/swaps; }
fstab_entries() { grep -c "^$swap_path " /etc/fstab || true; }

# No background agent runs during the test: stop CFEngine daemons if the
# package started them (the test policy sets also give cf-execd an empty schedule).
systemctl stop cfengine3 2>/dev/null || true
pkill -x cf-execd 2>/dev/null || true
pkill -x cf-serverd 2>/dev/null || true
pkill -x cf-monitord 2>/dev/null || true

# Start from a clean state, whatever the host has.
swapoff "$swap_path" 2>/dev/null || true
rm -f "$swap_path"
sed -i "\|^$swap_path |d" /etc/fstab

echo "### 1. fresh host: create 256 MB swap file, activate, add to fstab"
use_policy small
run_agent
[ -f "$swap_path" ] || fail "swap file not created"
[ "$(stat -c %a:%U:%G "$swap_path")" = "600:root:root" ] || fail "wrong permissions: $(stat -c %a:%U:%G "$swap_path")"
[ "$(stat -c %s "$swap_path")" = "268435456" ] || fail "wrong size: $(stat -c %s "$swap_path")"
swap_active || fail "swap not active"
grep -q "^$swap_path none swap sw 0 0$" /etc/fstab || fail "fstab entry missing"
echo "OK"

echo "### 2. second run: no changes"
run_agent
grep -qE "manage-swap: .*(created|activated|resized|added)" /tmp/agent.log && fail "second run made changes"
[ "$(fstab_entries)" = "1" ] || fail "duplicate fstab entries"
echo "OK"

echo "### 3. resize to 512 MB: swapoff, rewrite, mkswap, swapon"
use_policy bigger
run_agent
grep -q "resized to 0.5 GB" /tmp/agent.log || fail "resize not reported"
[ "$(stat -c %s "$swap_path")" = "536870912" ] || fail "not resized: $(stat -c %s "$swap_path")"
swap_active || fail "swap not active after resize"
[ "$(swap_size_kb)" -gt 500000 ] || fail "active swap size not updated: $(swap_size_kb)"
[ "$(fstab_entries)" = "1" ] || fail "fstab entries changed"
echo "OK"

echo "### 4. shrink back to 256 MB"
use_policy small
run_agent
[ "$(stat -c %s "$swap_path")" = "268435456" ] || fail "not shrunk: $(stat -c %s "$swap_path")"
swap_active || fail "swap not active after shrinking"
echo "OK"

echo "### 5. deactivated by hand (e.g. after reboot): re-activated, nothing rewritten"
swapoff "$swap_path"
run_agent
grep -q "manage-swap: swap file '$swap_path' activated" /tmp/agent.log || fail "re-activation not reported"
swap_active || fail "swap not re-activated"
echo "OK"

echo "### 6. custom fstab entry is respected"
swapoff "$swap_path"
sed -i "\|^$swap_path |d" /etc/fstab
echo "$swap_path none swap sw,pri=10 0 0" >> /etc/fstab
run_agent
[ "$(fstab_entries)" = "1" ] || fail "custom fstab entry not respected"
grep -q "^$swap_path none swap sw,pri=10 0 0$" /etc/fstab || fail "custom fstab entry rewritten"
echo "OK"

echo "### 7. inventory variables"
cf-agent -KI -f /var/cfengine/inputs/promises.cf --show-evaluated-vars=manage_swap 2>&1 | grep -E "swap_files|swap_total_mb" | tee /tmp/vars.log
grep -q "swap_files.*$swap_path" /tmp/vars.log || fail "swap_files inventory missing the swap file"
grep -q "attribute_name=Swap files" /tmp/vars.log || fail "swap_files not tagged as inventory"
grep -qE "swap_total_mb[[:space:]]+[1-9][0-9]*" /tmp/vars.log || fail "swap_total_mb inventory missing"
echo "OK"

echo "### 8. invalid size input: reported, nothing changed"
use_policy invalid
size_before="$(stat -c %s "$swap_path")"
run_agent
grep -q "Invalid swap size 'abc'" /tmp/agent.log || fail "invalid size not reported"
[ "$(stat -c %s "$swap_path")" = "$size_before" ] || fail "invalid input changed the swap file"
echo "OK"

echo "### 9. no input at all: defaults (2 GB, /swapfile) are used"
use_policy defaults
cf-promises -f /var/cfengine/inputs/promises.cf --show-vars=manage_swap:main 2>&1 | grep -E "swap_size_gb|swap_file_path" | tee /tmp/defaults.log
grep -qE "swap_size_gb[[:space:]]+2([[:space:]]|$)" /tmp/defaults.log || fail "default size not 2"
grep -qE "swap_file_path[[:space:]]+/swapfile([[:space:]]|$)" /tmp/defaults.log || fail "default path not /swapfile"
echo "OK"

echo "ALL TESTS PASSED"
