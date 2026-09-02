#!/usr/bin/env bash
# Build the policy sets used by tests/functional.sh.
#
# For each scenario a cfbs policy-set project (masterfiles + this module) is
# created in tests/out/projects/<name> and the built policy set is copied to
# tests/out/policies/<name>. The module is added as a local directory with the
# module's own build steps, so no git remote is needed.
#
# Environment:
#   SWAP_PATH  Swap file path to configure (default: /swapfile)
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/.." && pwd)"
out="$here/out"
swap_path="${SWAP_PATH:-/swapfile}"

rm -rf "$out/projects" "$out/policies"
mkdir -p "$out/projects" "$out/policies"

# build_policy <name> <size_gb or ""> <path or "">
build_policy() {
  local name="$1" size="$2" path="$3" project="$out/projects/$1"
  echo "Building policy set '$name' (size='${size:-default}', path='${path:-default}')"
  mkdir -p "$project/manage-swap/policy"
  cp "$repo/policy/main.cf" "$project/manage-swap/policy/main.cf"
  # Test-only augments for the Masterfiles Policy Framework (MPF):
  # - the package inventory needs a bootstrapped host (python symlink and
  #   installed package modules) and is unrelated to this module: disable it;
  # - cf-execd must never start agent runs in the background during the test.
  cat > "$project/test-def.json" <<'JSON'
{
  "classes": { "disable_inventory_package_refresh": ["any"] },
  "vars": { "control_executor_schedule": ["!any"] }
}
JSON
  (
    cd "$project"
    cfbs init --non-interactive >/dev/null
    REPO="$repo" SIZE="$size" SWAP="$path" python3 - <<'PY'
import json, os
with open(os.path.join(os.environ["REPO"], "cfbs.json")) as f:
    module = json.load(f)["provides"]["manage-swap"]
with open("cfbs.json") as f:
    project = json.load(f)
project["build"].append({
    "name": "./test-def.json",
    "description": "Test-only augments",
    "tags": ["local"],
    "steps": ["json ./test-def.json def.json"],
    "added_by": "cfbs add",
})
project["build"].append({
    "name": "./manage-swap/",
    "description": module["description"],
    "tags": ["local"],
    "steps": module["steps"],
    "input": module["input"],
    "added_by": "cfbs add",
})
with open("cfbs.json", "w") as f:
    json.dump(project, f, indent=2)
responses = {"swap_size_gb": os.environ["SIZE"], "swap_file_path": os.environ["SWAP"]}
if any(responses.values()):
    data = []
    for element in module["input"]:
        element = dict(element)
        if responses[element["variable"]]:
            element["response"] = responses[element["variable"]]
        data.append(element)
    with open("manage-swap/input.json", "w") as f:
        json.dump(data, f, indent=2)
PY
    cfbs build >/dev/null
  )
  cp -R "$project/out/masterfiles" "$out/policies/$name"
}

build_policy small "0.25" "$swap_path"   # 256 MB
build_policy bigger "0.5" "$swap_path"   # 512 MB, used for the resize test
build_policy invalid "abc" "$swap_path"  # invalid size, must not touch anything
build_policy defaults "" ""              # no input at all: defaults 2 GB, /swapfile

echo "Policy sets built in $out/policies"
