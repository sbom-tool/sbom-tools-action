#!/usr/bin/env bash
#
# Test harness for sbom-tools-action.
#
#   bash tests/run-tests.sh [--cli PATH] [--network] [--release] [PATTERN]
#
#   --cli PATH  also run the integration tests against this sbom-tools binary,
#               through the binary-path install override (default:
#               $SBOM_TOOLS_TEST_CLI when it is set)
#   --network   also run the tests that call GitHub: resolving 'latest' and
#               installing real release assets with provenance verification
#   --release   also run the tests that need the sbom-tools v0.4.0 release;
#               until it is published they report SKIP and say so
#   PATTERN     run only the tests whose name or description contains it
#
# The Action's scripts run the way action.yml runs them: setup.sh, then
# run.sh with setup's binary output as SBOM_TOOLS_BIN, the inputs in INPUT_*
# variables, and GITHUB_OUTPUT and GITHUB_PATH pointing at files in a fresh
# sandbox per test. tests/stubs holds stand-ins for sbom-tools, gh and curl.
# The SBOMs in tests/fixtures come from the sbom-tools test suite
# (tests/fixtures/showcase, cyclonedx and cra, at sbom-tools main 67f470b).
#
# Output is TAP. The exit status is 1 when any test fails.

# Each test sets its environment in a subshell on purpose (SC2030/SC2031),
# and single-quoted '$x' and '`x`' strings are literal test inputs (SC2016).
# shellcheck disable=SC2016,SC2030,SC2031

set -u

HERE=$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
ROOT=$(dirname -- "$HERE")
SCRIPTS="$ROOT/scripts"
STUBS="$HERE/stubs"
FIXTURES="$HERE/fixtures"

CLI="${SBOM_TOOLS_TEST_CLI:-}"
NETWORK=false
RELEASE=false
PATTERN=''
while [ $# -gt 0 ]; do
  case "$1" in
    --cli)
      CLI="${2:-}"
      shift 2 || shift
      ;;
    --network) NETWORK=true; shift ;;
    --release) RELEASE=true; shift ;;
    -h | --help) sed -n '3,25p' "$0"; exit 0 ;;
    *) PATTERN="$1"; shift ;;
  esac
done
if [ -n "$CLI" ]; then
  case "$CLI" in /*) ;; *) CLI="$PWD/$CLI" ;; esac
  if [ ! -x "$CLI" ]; then
    echo "run-tests.sh: --cli $CLI is not an executable file" >&2
    exit 2
  fi
fi

case "$(uname -s)" in
  Darwin) HOST_OS=macOS ;;
  Linux) HOST_OS=Linux ;;
  MINGW* | MSYS* | CYGWIN*) HOST_OS=Windows ;;
  *) HOST_OS=Linux ;;
esac
case "$(uname -m)" in
  arm64 | aarch64) HOST_ARCH=ARM64 ;;
  *) HOST_ARCH=X64 ;;
esac

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/sbom-tools-action-tests.XXXXXX") || exit 2
TMP_ROOT=$(cd -P -- "$TMP_ROOT" && pwd -P) || exit 2
trap 'rm -rf -- "$TMP_ROOT"' EXIT

# Git Bash makes copies for ln -s unless Windows symlinks are enabled.
HAVE_SYMLINKS=false
if ln -s "$TMP_ROOT" "$TMP_ROOT/.probe" 2>/dev/null && [ -L "$TMP_ROOT/.probe" ]; then HAVE_SYMLINKS=true; fi
rm -rf "$TMP_ROOT/.probe"

# ------------------------------------------------------------------ framework

T_NUM=0
T_PASS=0
T_FAIL=0
T_SKIP=0
FAILS=''
SKIP_REASON=''

fail() { FAILS="${FAILS}#   $*"$'\n'; }
skip() { SKIP_REASON="$1"; }

assert_eq() {
  [ "$1" = "$2" ] || fail "${3:-value}: expected '$2', got '$1'"
}
assert_contains() {
  case "$1" in *"$2"*) ;; *) fail "${3:-log} does not contain: $2" ;; esac
}
assert_not_contains() {
  case "$1" in *"$2"*) fail "${3:-log} unexpectedly contains: $2" ;; esac
}

# t <function> <description>: run one test in a fresh sandbox.
t() {
  local fn="$1" desc="$2" f
  if [ -n "$PATTERN" ]; then
    case "$fn $desc" in *"$PATTERN"*) ;; *) return 0 ;; esac
  fi
  T_NUM=$((T_NUM + 1))
  FAILS=''
  SKIP_REASON=''
  new_sandbox
  "$fn"
  if [ -n "$SKIP_REASON" ]; then
    printf 'ok %d - %s # SKIP %s\n' "$T_NUM" "$desc" "$SKIP_REASON"
    T_SKIP=$((T_SKIP + 1))
  elif [ -z "$FAILS" ]; then
    printf 'ok %d - %s\n' "$T_NUM" "$desc"
    T_PASS=$((T_PASS + 1))
  else
    printf 'not ok %d - %s\n%s' "$T_NUM" "$desc" "$FAILS"
    for f in "$SB"/*.log; do
      [ -f "$f" ] || continue
      echo "#   --- ${f##*/}"
      tail -n 30 "$f" | sed 's/^/#   | /'
    done
    T_FAIL=$((T_FAIL + 1))
  fi
}

new_sandbox() {
  SB="$TMP_ROOT/t$T_NUM"
  mkdir -p "$SB/ws" "$SB/temp" "$SB/toolcache" "$SB/bin" "$SB/stubpath"
  : >"$SB/path"
  cp "$STUBS/sbom-tools" "$SB/bin/sbom-tools"
  cp "$STUBS/gh" "$STUBS/curl" "$SB/stubpath/"
  chmod +x "$SB/bin/sbom-tools" "$SB/stubpath/gh" "$SB/stubpath/curl"
  STUB_BIN="$SB/bin/sbom-tools"
  STUB_PATH="PATH=$SB/stubpath:$PATH"
}

unset_action_env() {
  local v
  for v in $(compgen -e); do
    case "$v" in
      INPUT_* | STUB_* | SBOM_TOOLS_BIN | GITHUB_* | RUNNER_*) unset "$v" ;;
    esac
  done
}

# run_step <setup|run> [NAME=value ...]: run one of the Action's scripts as
# its action.yml step does. Sets STEP_STATUS; the log is $SB/<step>.log and
# the outputs are in $SB/<step>.output.
run_step() {
  local step="$1"
  shift
  : >"$SB/$step.output"
  (
    unset_action_env
    export GITHUB_WORKSPACE="$SB/ws" GITHUB_OUTPUT="$SB/$step.output" GITHUB_PATH="$SB/path"
    export RUNNER_TEMP="$SB/temp" RUNNER_TOOL_CACHE="$SB/toolcache"
    export RUNNER_OS="$HOST_OS" RUNNER_ARCH="$HOST_ARCH"
    export STUB_ARGV_FILE="$SB/argv" STUB_GH_LOG="$SB/gh.calls" STUB_CURL_LOG="$SB/curl.calls"
    for kv in "$@"; do export "${kv?}"; done
    cd "$SB/ws" || exit 99
    exec "$BASH" "$SCRIPTS/$step.sh"
  ) >"$SB/$step.log" 2>&1
  STEP_STATUS=$?
}

# output_of <step> <name>: the value the step wrote for an output.
output_of() {
  local line value=''
  if [ -f "$SB/$1.output" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in "$2="*) value="${line#*=}" ;; esac
    done <"$SB/$1.output"
  fi
  printf '%s' "$value"
}

# run_action [NAME=value ...]: the composite action: setup.sh, then run.sh if
# setup passed. Sets SETUP_STATUS, SETUP_LOG, RUN_STATUS ('' when run.sh did
# not run), RUN_LOG, and the Action's outputs: EXIT_CODE (as
# action.yml computes it), VERSION, SLSA_VERIFIED, OUTPUT_FILE.
run_action() {
  run_step setup "$@"
  SETUP_STATUS=$STEP_STATUS
  SETUP_LOG=$(cat "$SB/setup.log")
  RUN_STATUS=''
  RUN_LOG=''
  rm -f "$SB/run.output" "$SB/run.log"
  if [ "$SETUP_STATUS" -eq 0 ]; then
    run_step run "SBOM_TOOLS_BIN=$(output_of setup binary)" "$@"
    RUN_STATUS=$STEP_STATUS
    RUN_LOG=$(cat "$SB/run.log")
  fi
  # steps.run.outputs.exit-code || steps.setup.outputs.exit-code
  EXIT_CODE=$(output_of run exit-code)
  [ -n "$EXIT_CODE" ] || EXIT_CODE=$(output_of setup exit-code)
  VERSION=$(output_of setup version)
  SLSA_VERIFIED=$(output_of setup slsa-verified)
  OUTPUT_FILE=$(output_of run output-file)
}

# run_stub [NAME=value ...]: run_action with the stub CLI as binary-path.
run_stub() {
  run_action "INPUT_BINARY_PATH=$STUB_BIN" "$@"
}

# The arguments the stub CLI received, joined with '|'.
stub_argv() {
  local line out=''
  if [ -f "$SB/argv" ]; then
    while IFS= read -r line; do out="$out|$line"; done <"$SB/argv"
  fi
  printf '%s' "${out#|}"
}

# The step failed with <status>, and the Action's exit-code output says so.
assert_failed_with() {
  local status="$1"
  if [ -n "$RUN_STATUS" ]; then
    assert_eq "$RUN_STATUS" "$status" 'run step status'
  else
    assert_eq "$SETUP_STATUS" "$status" 'setup step status'
  fi
  assert_eq "$EXIT_CODE" "$status" 'exit-code output'
}

# A setup-time configuration error naming the input.
assert_input_error() {
  assert_eq "$SETUP_STATUS" 3 'setup step status'
  assert_eq "$RUN_STATUS" '' 'run step ran'
  assert_eq "$EXIT_CODE" 3 'exit-code output'
  assert_contains "$SETUP_LOG" "::error title=sbom-tools-action%3A invalid input '$1'::"
  if [ -n "${2:-}" ]; then assert_contains "$SETUP_LOG" "$2"; fi
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    SHA=$(sha256sum <"$1" | awk '{print $1}')
  else
    SHA=$(shasum -a 256 <"$1" | awk '{print $1}')
  fi
}

have_zip() {
  command -v zip >/dev/null 2>&1 || command -v python3 >/dev/null 2>&1
}

# make_zip <archive> <dir>: zip the contents of dir (zip, or Python's zipfile).
make_zip() {
  local out="$1" dir="$2"
  if command -v zip >/dev/null 2>&1; then
    (cd "$dir" && zip -q -r -y "$out" .)
  else
    python3 -I -c 'import os, sys, zipfile
z = zipfile.ZipFile(sys.argv[1], "w")
for n in sorted(os.listdir(sys.argv[2])):
    z.write(os.path.join(sys.argv[2], n), n)
z.close()' "$out" "$dir"
  fi
}

# make_release <target> <ext> [exe] [layout: ok|symlink|missing]: a fake
# release in $SB/release: the archive (holding the stub CLI) and its
# checksums.sha256.
make_release() {
  local target="$1" ext="$2" exe="${3:-sbom-tools}" layout="${4:-ok}" stage archive
  RELEASE_DIR="$SB/release"
  mkdir -p "$RELEASE_DIR"
  stage=$(mktemp -d "$SB/stage.XXXXXX")
  case "$layout" in
    ok)
      cp "$STUBS/sbom-tools" "$stage/$exe"
      chmod +x "$stage/$exe"
      ;;
    symlink)
      cp "$STUBS/sbom-tools" "$stage/real-sbom-tools"
      ln -s real-sbom-tools "$stage/$exe"
      ;;
    missing) ;;
  esac
  printf 'MIT License\n' >"$stage/LICENSE"
  archive="sbom-tools-$target.$ext"
  case "$ext" in
    tar.gz) tar -czf "$RELEASE_DIR/$archive" -C "$stage" . ;;
    zip) make_zip "$RELEASE_DIR/$archive" "$stage" ;;
  esac
  sha256_file "$RELEASE_DIR/$archive"
  printf '%s  %s\n' "$SHA" "$archive" >"$RELEASE_DIR/checksums.sha256"
  RELEASE_ARCHIVE="$archive"
}

# The env for an install from the fake release, with stub gh and curl.
release_env() {
  RELEASE_ENV=("$STUB_PATH" "STUB_RELEASE_DIR=$SB/release" "INPUT_COMMAND=validate" "INPUT_ARGS=sbom.json")
}

copy_fixture() {
  local f
  for f in "$@"; do cp "$FIXTURES/$f" "$SB/ws/$f"; done
}

# A PATH with the stub curl and links to the tools the scripts use, but no gh.
path_without_gh() {
  local dir="$SB/nogh" tool src
  mkdir -p "$dir"
  for tool in bash env mktemp rm mkdir mv chmod cp cat tar gzip unzip awk sed grep tr od head \
    dirname basename readlink sha256sum shasum tee sort uname; do
    src=$(command -v "$tool" 2>/dev/null) || continue
    case "$src" in /*) ln -s "$src" "$dir/$tool" ;; esac
  done
  cp "$STUBS/curl" "$dir/curl"
  chmod +x "$dir/curl"
  NOGH_PATH="PATH=$dir"
}

# The form the Action gives other steps a path in: native on Windows.
native() {
  if [ "$HOST_OS" = Windows ] && command -v cygpath >/dev/null 2>&1; then
    cygpath -w "$1"
  else
    printf '%s' "$1"
  fi
}

need_symlinks() {
  if [ "$HAVE_SYMLINKS" != true ]; then
    skip 'needs symbolic links (ln -s makes copies here)'
    return 1
  fi
}

cli_supports() { # <command> <flag>
  "$CLI" "$1" --help 2>/dev/null | grep -q -- "$2"
}

need_cli() {
  if [ -z "$CLI" ]; then
    skip 'no sbom-tools binary given (--cli PATH)'
    return 1
  fi
}

need_network() {
  if [ "$NETWORK" != true ]; then
    skip 'calls GitHub (--network)'
    return 1
  fi
}

# ------------------------------------------------------------- static checks

test_action_yml_wiring() {
  if ! command -v ruby >/dev/null 2>&1; then
    skip 'needs ruby to parse action.yml'
    return
  fi
  local vars out
  vars=$(grep -ho 'INPUT_[A-Z][A-Z_]*' "$SCRIPTS"/*.sh | sort -u | tr '\n' ' ')
  # shellcheck disable=SC2086 # $vars is a word list
  out=$(ruby -ryaml -e '
    a = YAML.load_file(ARGV.shift)
    readme = File.read(ARGV.shift)
    used = ARGV
    errs = []
    inputs = a["inputs"]
    steps = a["runs"]["steps"]
    setup = steps.find { |s| s["id"] == "setup" } || {}
    run = steps.find { |s| s["id"] == "run" } || {}
    steps.each { |s| errs << "step #{s["id"]}: a ${{ }} expression in run:" if s["run"].to_s.include?("${{") }
    setup_only = %w[version verify-provenance binary-path]
    inputs.each_key do |name|
      var = "INPUT_" + name.upcase.tr("-", "_")
      want = "${{ inputs.#{name} }}"
      errs << "setup env #{var} is not #{want}" unless (setup["env"] || {})[var] == want
      if setup_only.include?(name)
        errs << "run env maps #{var}, which run.sh does not use" if (run["env"] || {}).key?(var)
      else
        errs << "run env #{var} is not #{want}" unless (run["env"] || {})[var] == want
      end
    end
    [setup, run].each do |s|
      (s["env"] || {}).each_key do |k|
        next unless k.start_with?("INPUT_")
        errs << "#{s["id"]} env #{k} maps no declared input" unless inputs.key?(k.sub("INPUT_", "").downcase.tr("_", "-"))
      end
    end
    used.each { |v| errs << "the scripts read #{v}, which maps no declared input" unless inputs.key?(v.sub("INPUT_", "").downcase.tr("_", "-")) }
    %w[fail-on-vuln fail-on-change fail-on-vex-gap fail-on-warning require-applicable enrich-vulns sarif-include-passes].each do |b|
      errs << "#{b} default is not false" unless (inputs[b] || {})["default"] == "false"
    end
    errs << "working-directory default is not ." unless inputs["working-directory"]["default"] == "."
    errs << "verify-provenance default is not require" unless inputs["verify-provenance"]["default"] == "require"
    v = inputs["version"]["default"].to_s
    errs << "version default #{v} is not an exact 0.4.x release" unless v =~ /\A0\.4\.\d+\z/
    errs << "README does not give the default version `#{v}`" unless readme.include?("`#{v}`")
    %w[exit-code version slsa-verified output-file].each { |o| errs << "output #{o} is missing" unless (a["outputs"] || {}).key?(o) }
    puts errs
  ' "$ROOT/action.yml" "$ROOT/README.md" $vars 2>&1) || fail "ruby failed: $out"
  if [ -n "$out" ]; then fail "$out"; fi
}

test_workflow_actions_pinned() {
  local f line ref bad='' re='^[A-Za-z0-9_.-]+/[A-Za-z0-9_./-]+@[0-9a-f]{40} # v[0-9]+(\.[0-9]+)*$'
  for f in "$ROOT"/.github/workflows/*.yml; do
    [ -f "$f" ] || continue
    while IFS= read -r line; do
      case "$line" in *'uses:'*) ;; *) continue ;; esac
      ref="${line#*uses:}"
      ref="${ref#"${ref%%[![:space:]]*}"}"
      case "$ref" in ./* | "'./"* | '"./'*) continue ;; esac
      [[ "$ref" =~ $re ]] || bad="$bad ${f##*/}: $ref;"
    done <"$f"
  done
  if [ -n "$bad" ]; then fail "not pinned to a full commit SHA with a version comment:$bad"; fi
}

# --------------------------------------------------------------- version rule

test_version_rejects_older_line() {
  local v
  for v in 0.3.0 0.3.12 0.2.0 0.1.16 0.0.1; do
    run_stub "$STUB_PATH" INPUT_BINARY_PATH= "INPUT_VERSION=$v" INPUT_COMMAND=validate
    assert_input_error version "sbom-tools $v is not supported by sbom-tools-action v2"
    assert_contains "$SETUP_LOG" 'Use sbom-tool/sbom-tools-action@v1 for sbom-tools 0.3.x and earlier'
  done
}

test_version_rejects_newer_line() {
  local v
  for v in 0.5.0 0.40.0 0.10.0 1.0.0 2.4.1; do
    run_stub INPUT_BINARY_PATH= "INPUT_VERSION=$v" INPUT_COMMAND=validate
    assert_input_error version "sbom-tools $v is not supported by sbom-tools-action v2, which runs the sbom-tools 0.4.x line only"
    assert_not_contains "$SETUP_LOG" '@v1'
  done
}

test_version_rejects_malformed() {
  run_stub INPUT_BINARY_PATH= INPUT_VERSION=v0.4.0 INPUT_COMMAND=validate
  assert_input_error version "without the leading 'v', for example '0.4.0'"
  local v
  for v in 0.4 0.4.x '0.4.*' 'latest;id' '0.4.0 0.4.1' '>=0.4.0' 0.4.0- stable; do
    run_stub INPUT_BINARY_PATH= "INPUT_VERSION=$v" INPUT_COMMAND=validate
    assert_input_error version 'is not a version'
  done
  run_stub INPUT_BINARY_PATH= INPUT_VERSION=0.4.01 INPUT_COMMAND=validate
  assert_input_error version "'0.4.01' is not a valid sbom-tools 0.4.x version"
  run_stub INPUT_BINARY_PATH= INPUT_VERSION= INPUT_COMMAND=validate
  assert_input_error version 'is empty'
}

test_version_exact_used_as_given() {
  local v
  make_release linux-x86_64 tar.gz
  release_env
  for v in 0.4.0 0.4.7 0.4.12 0.4.0-rc.1; do
    : >"$SB/curl.calls"
    run_action "${RELEASE_ENV[@]}" "INPUT_VERSION=$v" RUNNER_OS=Linux RUNNER_ARCH=X64
    assert_eq "$SETUP_STATUS" 0 "setup status for $v"
    assert_eq "$VERSION" "$v" 'version output'
    assert_contains "$(cat "$SB/curl.calls")" "https://github.com/sbom-tool/sbom-tools/releases/download/v$v/sbom-tools-linux-x86_64.tar.gz" 'download URLs'
    assert_contains "$(cat "$SB/gh.calls")" "--source-ref refs/tags/v$v" 'gh calls'
    assert_not_contains "$(cat "$SB/gh.calls")" 'release list' 'gh calls'
  done
}

test_version_latest_picks_newest_0_4() {
  make_release linux-x86_64 tar.gz
  release_env
  run_action "${RELEASE_ENV[@]}" INPUT_VERSION=latest RUNNER_OS=Linux RUNNER_ARCH=X64 \
    'STUB_GH_TAGS=v0.5.0 v0.4.2 v0.4.10 v0.4.9 v0.40.1 v0.4.11-rc.1 v0.4.03 v0.3.0 v1.0.0'
  assert_eq "$SETUP_STATUS" 0 'setup status'
  assert_eq "$VERSION" 0.4.10 'version output'
  assert_contains "$(cat "$SB/curl.calls")" '/releases/download/v0.4.10/' 'download URLs'
  assert_contains "$(cat "$SB/gh.calls")" 'gh release list --repo sbom-tool/sbom-tools --exclude-drafts --exclude-pre-releases' 'gh calls'
  assert_contains "$SETUP_LOG" "version 'latest' resolved to sbom-tools 0.4.10"
}

test_version_latest_without_0_4_release() {
  run_action "$STUB_PATH" INPUT_VERSION=latest INPUT_COMMAND=validate 'STUB_GH_TAGS=v0.3.0 v0.2.0 v0.5.0'
  assert_failed_with 3
  assert_contains "$SETUP_LOG" 'No sbom-tools 0.4.x release is published yet'
  assert_eq "$(cat "$SB/curl.calls" 2>/dev/null)" '' 'download URLs'
}

test_version_latest_list_fails() {
  run_action "$STUB_PATH" INPUT_VERSION=latest INPUT_COMMAND=validate STUB_GH_LIST_EXIT=1
  assert_failed_with 3
  assert_contains "$SETUP_LOG" "Could not list the sbom-tools releases to resolve 'latest'"
}

test_version_latest_without_gh() {
  if [ "$HOST_OS" = Windows ]; then
    skip 'builds a PATH without gh from symlinks'
    return
  fi
  path_without_gh
  run_action "$NOGH_PATH" INPUT_VERSION=latest INPUT_COMMAND=validate
  assert_failed_with 3
  assert_contains "$SETUP_LOG" "Resolving 'latest' needs the GitHub CLI (gh)"
}

test_version_ignored_with_binary_path() {
  run_stub INPUT_VERSION=0.3.0 INPUT_COMMAND=validate INPUT_ARGS=sbom.json
  assert_eq "$SETUP_STATUS" 0 'setup status'
  assert_eq "$RUN_STATUS" 0 'run status'
  assert_eq "$VERSION" 0.4.0 'version output (from the binary)'
}

# ------------------------------------------------------------------ install

test_install_downloads_verifies_and_runs() {
  make_release linux-x86_64 tar.gz
  release_env
  run_action "${RELEASE_ENV[@]}" INPUT_VERSION=0.4.0 RUNNER_OS=Linux RUNNER_ARCH=X64 INPUT_STANDARD=cra
  assert_eq "$SETUP_STATUS" 0 'setup status'
  assert_eq "$RUN_STATUS" 0 'run status'
  assert_eq "$VERSION" 0.4.0 'version output'
  assert_eq "$SLSA_VERIFIED" true 'slsa-verified output'
  assert_eq "$(output_of setup binary)" "$SB/toolcache/sbom-tools/0.4.0/sbom-tools" 'binary output'
  assert_eq "$(cat "$SB/path")" "$SB/toolcache/sbom-tools/0.4.0" 'GITHUB_PATH'
  assert_eq "$(stub_argv)" 'validate|sbom.json|--standard=cra' 'installed binary argv'
  assert_eq "$(cat "$SB/curl.calls")" "https://github.com/sbom-tool/sbom-tools/releases/download/v0.4.0/sbom-tools-linux-x86_64.tar.gz
https://github.com/sbom-tool/sbom-tools/releases/download/v0.4.0/checksums.sha256" 'download URLs'
  assert_eq "$(cat "$SB/gh.calls")" 'gh attestation verify sbom-tools-linux-x86_64.tar.gz --repo sbom-tool/sbom-tools --signer-workflow sbom-tool/sbom-tools/.github/workflows/publish-crates.yml --source-ref refs/tags/v0.4.0 --deny-self-hosted-runners' 'gh calls'
  assert_contains "$SETUP_LOG" 'SHA-256 verified: sbom-tools-linux-x86_64.tar.gz'
  assert_contains "$SETUP_LOG" 'Build provenance verified'
  if ls "$SB/temp"/sbom-tools-install.* >/dev/null 2>&1; then fail 'the install work directory was not removed'; fi
}

test_install_platforms() {
  local spec os arch archive
  for spec in Linux:X64:linux-x86_64.tar.gz Linux:ARM64:linux-aarch64.tar.gz \
    macOS:X64:macos-x86_64.tar.gz macOS:ARM64:macos-aarch64.tar.gz Windows:X64:windows-x86_64.zip; do
    os="${spec%%:*}"
    arch="${spec#*:}"
    arch="${arch%%:*}"
    archive="sbom-tools-${spec##*:}"
    : >"$SB/curl.calls"
    # No release files: the download 404s after naming the archive it wanted.
    run_action "$STUB_PATH" "STUB_RELEASE_DIR=$SB/none" INPUT_VERSION=0.4.0 INPUT_COMMAND=validate \
      "RUNNER_OS=$os" "RUNNER_ARCH=$arch"
    assert_failed_with 3
    assert_contains "$(cat "$SB/curl.calls")" "/download/v0.4.0/$archive" "download URL for $os-$arch"
    assert_contains "$SETUP_LOG" "Could not download $archive and checksums.sha256 from the sbom-tools v0.4.0 release"
  done
}

test_install_unsupported_platform() {
  local spec
  for spec in Linux:ARM Windows:ARM64 macOS:X86 FreeBSD:X64; do
    : >"$SB/gh.calls"
    run_action "$STUB_PATH" INPUT_VERSION=latest INPUT_COMMAND=validate "RUNNER_OS=${spec%:*}" "RUNNER_ARCH=${spec#*:}"
    assert_failed_with 3
    assert_contains "$SETUP_LOG" "No prebuilt sbom-tools for ${spec%:*}-${spec#*:}"
    assert_contains "$SETUP_LOG" 'pass its path as binary-path'
    assert_eq "$(cat "$SB/gh.calls")" '' 'gh calls (fails before resolving latest)'
  done
}

test_install_checksum_mismatch() {
  make_release linux-x86_64 tar.gz
  printf 'tampered' >>"$SB/release/$RELEASE_ARCHIVE"
  release_env
  run_action "${RELEASE_ENV[@]}" INPUT_VERSION=0.4.0 RUNNER_OS=Linux RUNNER_ARCH=X64
  assert_failed_with 3
  assert_contains "$SETUP_LOG" '::error title=sbom-tools-action%3A checksum mismatch::sbom-tools-linux-x86_64.tar.gz does not match checksums.sha256'
  assert_not_contains "$(cat "$SB/gh.calls" 2>/dev/null)" 'attestation' 'gh calls'
  [ ! -e "$SB/toolcache/sbom-tools" ] || fail 'something was installed'
}

test_install_checksum_entry_missing() {
  make_release linux-x86_64 tar.gz
  printf '%s  %s\n' "$SHA" sbom-tools-linux-x86_64.tar.gz.sig >"$SB/release/checksums.sha256"
  release_env
  run_action "${RELEASE_ENV[@]}" INPUT_VERSION=0.4.0 RUNNER_OS=Linux RUNNER_ARCH=X64
  assert_failed_with 3
  assert_contains "$SETUP_LOG" 'has no entry for sbom-tools-linux-x86_64.tar.gz'
}

test_install_checksum_malformed() {
  make_release linux-x86_64 tar.gz
  printf 'NOT-A-HASH  %s\n' "$RELEASE_ARCHIVE" >"$SB/release/checksums.sha256"
  release_env
  run_action "${RELEASE_ENV[@]}" INPUT_VERSION=0.4.0 RUNNER_OS=Linux RUNNER_ARCH=X64
  assert_failed_with 3
  assert_contains "$SETUP_LOG" 'is malformed'
}

test_install_checksum_formats() {
  make_release linux-x86_64 tar.gz
  # Binary-mode marker, CRLF line ends, other archives listed first.
  printf '%s *sbom-tools-linux-aarch64.tar.gz\r\n%s *%s\r\n' \
    0000000000000000000000000000000000000000000000000000000000000000 "$SHA" "$RELEASE_ARCHIVE" \
    >"$SB/release/checksums.sha256"
  release_env
  run_action "${RELEASE_ENV[@]}" INPUT_VERSION=0.4.0 RUNNER_OS=Linux RUNNER_ARCH=X64
  assert_eq "$SETUP_STATUS" 0 'setup status'
}

test_install_provenance_modes() {
  make_release linux-x86_64 tar.gz
  release_env
  run_action "${RELEASE_ENV[@]}" INPUT_VERSION=0.4.0 RUNNER_OS=Linux RUNNER_ARCH=X64 STUB_GH_ATTEST_EXIT=1
  assert_failed_with 3
  assert_contains "$SETUP_LOG" "::error title=sbom-tools-action%3A provenance not verified::Not installing sbom-tools v0.4.0"
  assert_contains "$SETUP_LOG" "verify-provenance is 'require'"
  [ ! -e "$SB/toolcache/sbom-tools" ] || fail 'installed despite require'

  run_action "${RELEASE_ENV[@]}" INPUT_VERSION=0.4.0 RUNNER_OS=Linux RUNNER_ARCH=X64 STUB_GH_ATTEST_EXIT=1 INPUT_VERIFY_PROVENANCE=warn
  assert_eq "$SETUP_STATUS" 0 'warn: setup status'
  assert_eq "$RUN_STATUS" 0 'warn: run status'
  assert_eq "$SLSA_VERIFIED" false 'warn: slsa-verified'
  assert_contains "$SETUP_LOG" '::warning title=sbom-tools-action%3A provenance not verified::'

  : >"$SB/gh.calls"
  run_action "${RELEASE_ENV[@]}" INPUT_VERSION=0.4.0 RUNNER_OS=Linux RUNNER_ARCH=X64 STUB_GH_ATTEST_EXIT=1 INPUT_VERIFY_PROVENANCE=off
  assert_eq "$SETUP_STATUS" 0 'off: setup status'
  assert_eq "$SLSA_VERIFIED" false 'off: slsa-verified'
  assert_eq "$(cat "$SB/gh.calls")" '' 'off: gh calls'
  assert_contains "$SETUP_LOG" 'Build provenance not checked (verify-provenance: off)'
}

test_install_provenance_without_gh() {
  if [ "$HOST_OS" = Windows ]; then
    skip 'builds a PATH without gh from symlinks'
    return
  fi
  make_release linux-x86_64 tar.gz
  path_without_gh
  run_action "$NOGH_PATH" "STUB_RELEASE_DIR=$SB/release" INPUT_COMMAND=validate INPUT_VERSION=0.4.0 RUNNER_OS=Linux RUNNER_ARCH=X64
  assert_failed_with 3
  assert_contains "$SETUP_LOG" 'the GitHub CLI (gh), which verifies build provenance, is not installed'
  run_action "$NOGH_PATH" "STUB_RELEASE_DIR=$SB/release" INPUT_COMMAND=validate INPUT_VERSION=0.4.0 RUNNER_OS=Linux RUNNER_ARCH=X64 INPUT_VERIFY_PROVENANCE=warn
  assert_eq "$SETUP_STATUS" 0 'warn: setup status'
  assert_eq "$SLSA_VERIFIED" false 'warn: slsa-verified'
}

test_install_rejects_bad_archives() {
  need_symlinks || return
  make_release linux-x86_64 tar.gz sbom-tools symlink
  release_env
  run_action "${RELEASE_ENV[@]}" INPUT_VERSION=0.4.0 RUNNER_OS=Linux RUNNER_ARCH=X64
  assert_failed_with 3
  assert_contains "$SETUP_LOG" 'sbom-tools in sbom-tools-linux-x86_64.tar.gz is a symbolic link'

  rm -rf "$SB/release"
  make_release linux-x86_64 tar.gz sbom-tools missing
  run_action "${RELEASE_ENV[@]}" INPUT_VERSION=0.4.0 RUNNER_OS=Linux RUNNER_ARCH=X64
  assert_failed_with 3
  assert_contains "$SETUP_LOG" 'sbom-tools-linux-x86_64.tar.gz does not contain sbom-tools'
}

test_install_windows_zip() {
  if ! have_zip; then
    skip 'needs zip or python3 to build a zip archive'
    return
  fi
  make_release windows-x86_64 zip sbom-tools.exe
  release_env
  run_action "${RELEASE_ENV[@]}" INPUT_VERSION=0.4.0 RUNNER_OS=Windows RUNNER_ARCH=X64
  assert_eq "$SETUP_STATUS" 0 'setup status'
  assert_eq "$RUN_STATUS" 0 'run status'
  assert_contains "$(output_of setup binary)" '/sbom-tools/0.4.0/sbom-tools.exe' 'binary output'
}

# ---------------------------------------------------------------- binary-path

test_binary_path_override() {
  run_stub INPUT_COMMAND=validate INPUT_ARGS=sbom.json
  assert_eq "$SETUP_STATUS" 0 'setup status'
  assert_eq "$RUN_STATUS" 0 'run status'
  assert_eq "$VERSION" 0.4.0 'version output'
  assert_eq "$SLSA_VERIFIED" false 'slsa-verified output'
  assert_eq "$(output_of setup binary)" "$STUB_BIN" 'binary output'
  assert_eq "$(cat "$SB/curl.calls" 2>/dev/null)" '' 'downloads'
  assert_eq "$(cat "$SB/path")" '' 'GITHUB_PATH'
  assert_contains "$SETUP_LOG" 'download, checksum and provenance checks skipped'
  assert_not_contains "$SETUP_LOG" '::warning'
}

test_binary_path_relative_and_old_version() {
  mkdir -p "$SB/ws/target/release"
  cp "$STUBS/sbom-tools" "$SB/ws/target/release/sbom-tools"
  chmod +x "$SB/ws/target/release/sbom-tools"
  run_action INPUT_BINARY_PATH=target/release/sbom-tools INPUT_COMMAND=validate INPUT_ARGS=sbom.json STUB_VERSION=0.3.0
  assert_eq "$SETUP_STATUS" 0 'setup status'
  assert_eq "$RUN_STATUS" 0 'run status'
  assert_eq "$(output_of setup binary)" "$SB/ws/target/release/sbom-tools" 'binary output'
  assert_eq "$VERSION" 0.3.0 'version output'
  assert_contains "$SETUP_LOG" '::warning title=sbom-tools-action%3A binary-path::binary-path reports sbom-tools 0.3.0'
}

test_binary_path_invalid() {
  run_action "INPUT_BINARY_PATH=$SB/missing" INPUT_COMMAND=validate
  assert_failed_with 3
  assert_contains "$SETUP_LOG" "'$SB/missing' is not a file"
  run_action "INPUT_BINARY_PATH=$SB/bin" INPUT_COMMAND=validate
  assert_failed_with 3
  assert_contains "$SETUP_LOG" 'is not a file'
  printf 'not a program\n' >"$SB/plain"
  chmod -x "$SB/plain"
  run_action "INPUT_BINARY_PATH=$SB/plain" INPUT_COMMAND=validate
  assert_failed_with 3
  assert_contains "$SETUP_LOG" 'is not executable'
}

# ---------------------------------------------------------- inputs to argv

# expect_argv <expected> [NAME=value ...]: run with the stub, compare argv.
expect_argv() {
  local want="$1"
  shift
  rm -f "$SB/argv"
  run_stub "$@"
  assert_eq "$RUN_STATUS" 0 "run status for: $*"
  assert_eq "$(stub_argv)" "$want" "argv for: $*"
}

test_argv_each_input() {
  local base=(INPUT_COMMAND=validate INPUT_ARGS=sbom.json)
  expect_argv 'validate|sbom.json' "${base[@]}"
  expect_argv 'validate|sbom.json|--fail-on-vuln' "${base[@]}" INPUT_FAIL_ON_VULN=true
  expect_argv 'validate|sbom.json|--fail-on-change' "${base[@]}" INPUT_FAIL_ON_CHANGE=true
  expect_argv 'validate|sbom.json|--fail-on-vex-gap' "${base[@]}" INPUT_FAIL_ON_VEX_GAP=true
  expect_argv 'validate|sbom.json|--fail-on-warning' "${base[@]}" INPUT_FAIL_ON_WARNING=true
  expect_argv 'validate|sbom.json|--require-applicable' "${base[@]}" INPUT_REQUIRE_APPLICABLE=true
  expect_argv 'validate|sbom.json|--enrich-vulns' "${base[@]}" INPUT_ENRICH_VULNS=true
  expect_argv 'validate|sbom.json|--sarif-include-passes' "${base[@]}" INPUT_SARIF_INCLUDE_PASSES=true
  expect_argv 'validate|sbom.json|--output=sarif' "${base[@]}" INPUT_OUTPUT_FORMAT=sarif
  expect_argv 'validate|sbom.json|--output-file=reports.sarif' "${base[@]}" INPUT_OUTPUT_FILE=reports.sarif
  expect_argv 'validate|sbom.json|--min-score=72.5' "${base[@]}" INPUT_MIN_SCORE=72.5
  expect_argv 'validate|sbom.json|--standard=cra,ntia' "${base[@]}" INPUT_STANDARD=cra,ntia
  expect_argv 'validate|sbom.json|--standard=eo-14028, cisa,tr-03183' "${base[@]}" 'INPUT_STANDARD=eo-14028, cisa,tr-03183'
  expect_argv 'validate|sbom.json|--profile=ai_readiness' "${base[@]}" INPUT_PROFILE=ai_readiness
  expect_argv 'validate|sbom.json|--sarif-category=sbom-tools/cra/api' "${base[@]}" INPUT_SARIF_CATEGORY=sbom-tools/cra/api
  expect_argv 'validate|sbom.json|--sarif-base=.' "${base[@]}" INPUT_SARIF_BASE=.
  expect_argv 'validate|sbom.json|--sarif-max-results=500' "${base[@]}" INPUT_SARIF_MAX_RESULTS=500
  expect_argv 'validate|sbom.json|--as-of=2027-01-01T00:00:00Z' "${base[@]}" INPUT_AS_OF=2027-01-01T00:00:00Z
  expect_argv 'validate|sbom.json|--cra-sidecar=sbom.cra.json' "${base[@]}" INPUT_CRA_SIDECAR=sbom.cra.json
  expect_argv 'validate|sbom.json|--cra-product-class=important-class-1' "${base[@]}" INPUT_CRA_PRODUCT_CLASS=important-class-1
}

test_argv_false_and_empty_inputs_add_nothing() {
  expect_argv 'quality|sbom.json' INPUT_COMMAND=quality INPUT_ARGS=sbom.json \
    INPUT_FAIL_ON_VULN=false INPUT_FAIL_ON_CHANGE=false INPUT_FAIL_ON_VEX_GAP=false INPUT_FAIL_ON_WARNING=false \
    INPUT_REQUIRE_APPLICABLE=false INPUT_ENRICH_VULNS=false INPUT_SARIF_INCLUDE_PASSES=false \
    INPUT_OUTPUT_FORMAT= INPUT_OUTPUT_FILE= INPUT_MIN_SCORE= INPUT_STANDARD= INPUT_PROFILE= INPUT_SARIF_CATEGORY= \
    INPUT_SARIF_BASE= INPUT_SARIF_MAX_RESULTS= INPUT_AS_OF= INPUT_CRA_SIDECAR= INPUT_CRA_PRODUCT_CLASS= \
    'INPUT_STANDARD=   ' INPUT_WORKING_DIRECTORY=
}

test_argv_all_inputs_in_order() {
  expect_argv 'diff|old.json|new.json|--fail-on-vuln|--fail-on-change|--fail-on-vex-gap|--fail-on-warning|--require-applicable|--enrich-vulns|--sarif-include-passes|--output=sarif|--output-file=out.sarif|--min-score=80|--standard=cra|--profile=cra|--sarif-category=c|--sarif-base=.|--sarif-max-results=9|--as-of=2027-01-01|--cra-sidecar=s.json|--cra-product-class=critical' \
    INPUT_COMMAND=diff 'INPUT_ARGS=old.json new.json' INPUT_FAIL_ON_VULN=true INPUT_FAIL_ON_CHANGE=true \
    INPUT_FAIL_ON_VEX_GAP=true INPUT_FAIL_ON_WARNING=true INPUT_REQUIRE_APPLICABLE=true INPUT_ENRICH_VULNS=true \
    INPUT_SARIF_INCLUDE_PASSES=true INPUT_OUTPUT_FORMAT=sarif INPUT_OUTPUT_FILE=out.sarif INPUT_MIN_SCORE=80 \
    INPUT_STANDARD=cra INPUT_PROFILE=cra INPUT_SARIF_CATEGORY=c INPUT_SARIF_BASE=. INPUT_SARIF_MAX_RESULTS=9 \
    INPUT_AS_OF=2027-01-01 INPUT_CRA_SIDECAR=s.json INPUT_CRA_PRODUCT_CLASS=critical
}

test_argv_values_stay_one_argument() {
  # A value that looks like a flag is still the flag's value.
  expect_argv 'validate|sbom.json|--standard=--fail-on-warning' INPUT_COMMAND=validate INPUT_ARGS=sbom.json INPUT_STANDARD=--fail-on-warning
  expect_argv 'validate|sbom.json|--sarif-category=-x y' INPUT_COMMAND=validate INPUT_ARGS=sbom.json 'INPUT_SARIF_CATEGORY=-x y'
  # Surrounding whitespace is trimmed from scalar inputs.
  expect_argv 'validate|sbom.json|--standard=cra|--profile=x' INPUT_COMMAND=validate INPUT_ARGS=sbom.json \
    $'INPUT_STANDARD=  cra \n' $'INPUT_PROFILE=\tx'
}

test_args_split_on_whitespace() {
  expect_argv 'diff|old.json|new.json|--kev|--fail-on-kev' INPUT_COMMAND=diff \
    $'INPUT_ARGS=  old.json\tnew.json\n  --kev\r\n--fail-on-kev  \n'
  expect_argv 'validate' INPUT_COMMAND=validate 'INPUT_ARGS=   '
}

test_args_no_glob_expansion() {
  : >"$SB/ws/a.cdx.json"
  : >"$SB/ws/b.cdx.json"
  expect_argv 'query|log4j|*.cdx.json|fleet/?.json|[ab].json' INPUT_COMMAND=query 'INPUT_ARGS=log4j *.cdx.json fleet/?.json [ab].json'
}

test_args_flags_go_before_double_dash() {
  expect_argv 'validate|--output=json|--standard=cra|--|-odd-name.json' INPUT_COMMAND=validate \
    'INPUT_ARGS=-- -odd-name.json' INPUT_STANDARD=cra INPUT_OUTPUT_FORMAT=json
  expect_argv 'vex|status|sbom.json|--vex|v.json|--actionable-only|--output=json' INPUT_COMMAND=vex \
    'INPUT_ARGS=status sbom.json --vex v.json --actionable-only' INPUT_OUTPUT_FORMAT=json
}

test_args_version_ranges_allowed() {
  expect_argv 'query|--version|<2.17.0|log4j|fleet.json|--name|a>b' INPUT_COMMAND=query 'INPUT_ARGS=--version <2.17.0 log4j fleet.json --name a>b'
}

test_args_metacharacters_rejected() {
  local a
  for a in 'a.json;id' 'a.json|id' 'a.json&' '$(id)' '`id`' 'a.json$HOME' '(a)' '{a,b}' '!a' 'a#b' 'a\b' "it's" '"a b"'; do
    run_stub INPUT_COMMAND=validate "INPUT_ARGS=$a"
    assert_input_error args 'contains shell metacharacters'
  done
  run_stub INPUT_COMMAND=validate $'INPUT_ARGS=a.json\001'
  assert_input_error args 'must not contain control characters'
}

test_inputs_booleans_strict() {
  local name v
  for name in FAIL_ON_VULN FAIL_ON_CHANGE FAIL_ON_VEX_GAP FAIL_ON_WARNING REQUIRE_APPLICABLE ENRICH_VULNS SARIF_INCLUDE_PASSES; do
    for v in yes True 1 ''; do
      run_stub INPUT_COMMAND=validate "INPUT_$name=$v"
      assert_input_error "$(printf '%s' "$name" | tr 'A-Z_' 'a-z-')" "must be 'true' or 'false', got '$v'"
    done
  done
}

test_inputs_command_whitelist() {
  local c
  for c in diff validate quality view query enrich verify license-check vex; do
    expect_argv "$c" "INPUT_COMMAND=$c"
  done
  for c in watch help diff-multi 'validate --help' VALIDATE; do
    run_stub "INPUT_COMMAND=$c"
    assert_input_error command "'$c' is not supported"
  done
  run_stub INPUT_COMMAND=
  assert_input_error command 'is required'
}

test_inputs_min_score_numeric() {
  expect_argv 'quality|s.json|--min-score=80' INPUT_COMMAND=quality INPUT_ARGS=s.json INPUT_MIN_SCORE=80
  local v
  for v in 80% abc -1 1e2 '8 0'; do
    run_stub INPUT_COMMAND=quality "INPUT_MIN_SCORE=$v"
    assert_input_error min-score 'is not a number'
  done
}

test_inputs_single_line_values() {
  local name
  for name in OUTPUT_FORMAT STANDARD PROFILE SARIF_CATEGORY SARIF_MAX_RESULTS AS_OF CRA_PRODUCT_CLASS; do
    run_stub INPUT_COMMAND=validate "INPUT_$name=a"$'\n'"b"
    assert_input_error "$(printf '%s' "$name" | tr 'A-Z_' 'a-z-')" 'must be a single line'
  done
}

test_inputs_verify_provenance_values() {
  run_action "$STUB_PATH" INPUT_COMMAND=validate INPUT_VERSION=0.4.0 INPUT_VERIFY_PROVENANCE=strict
  assert_input_error verify-provenance "must be 'require', 'warn' or 'off', got 'strict'"
}

test_inputs_errors_reported_together() {
  run_action "$STUB_PATH" INPUT_COMMAND=watch INPUT_VERSION=0.3.0 INPUT_FAIL_ON_VULN=yes INPUT_OUTPUT_FILE=/etc/x
  assert_failed_with 3
  assert_contains "$SETUP_LOG" "invalid input 'command'"
  assert_contains "$SETUP_LOG" "invalid input 'version'"
  assert_contains "$SETUP_LOG" "invalid input 'fail-on-vuln'"
  assert_contains "$SETUP_LOG" "invalid input 'output-file'"
  assert_contains "$SETUP_LOG" '4 input error(s); sbom-tools was not installed or run.'
  assert_eq "$(cat "$SB/curl.calls" 2>/dev/null)" '' 'downloads'
}

# ---------------------------------------------------------- path validation

test_paths_accepted() {
  mkdir -p "$SB/ws/sub/dir" "$SB/ws/.hidden"
  local p
  for p in out.sarif ./out.sarif reports/out.sarif a..b.json .hidden/x.json sub/./x.json; do
    expect_argv "validate|--output-file=$p" INPUT_COMMAND=validate "INPUT_OUTPUT_FILE=$p"
  done
  expect_argv 'validate|--sarif-base=sub' INPUT_COMMAND=validate INPUT_SARIF_BASE=sub
  expect_argv 'validate|--cra-sidecar=sub/dir/s.cra.json' INPUT_COMMAND=validate INPUT_CRA_SIDECAR=sub/dir/s.cra.json
  expect_argv 'validate' INPUT_COMMAND=validate INPUT_WORKING_DIRECTORY=sub/dir
}

test_paths_traversal_rejected() {
  local name var p
  for name in working-directory output-file sarif-base cra-sidecar; do
    var="INPUT_$(printf '%s' "$name" | tr 'a-z-' 'A-Z_')"
    for p in /etc/passwd /tmp ../x a/../../x .. a/.. C:/x 'c:x'; do
      run_stub INPUT_COMMAND=validate "$var=$p"
      assert_input_error "$name" "'$p'"
    done
    for p in 'a;b' 'a$b' 'a\b' 'a b`'; do
      run_stub INPUT_COMMAND=validate "$var=$p"
      assert_input_error "$name" 'contains shell metacharacters'
    done
    run_stub INPUT_COMMAND=validate "$var=a"$'\n'"b"
    assert_input_error "$name" 'single-line path'
  done
}

test_paths_symlink_escape_rejected() {
  need_symlinks || return
  mkdir -p "$SB/outside" "$SB/ws/sub"
  ln -s "$SB/outside" "$SB/ws/out-link"
  ln -s ../../outside "$SB/ws/sub/rel-out"
  ln -s ../outside "$SB/ws/sub/rel-in"
  ln -s "$SB/outside/x.sarif" "$SB/ws/file-link.sarif"
  ln -s /nonexistent/x "$SB/ws/dangling.sarif"
  ln -s sub "$SB/ws/in-link"
  run_stub INPUT_COMMAND=validate INPUT_OUTPUT_FILE=out-link/r.sarif
  assert_input_error output-file 'outside the workspace'
  run_stub INPUT_COMMAND=validate INPUT_OUTPUT_FILE=sub/rel-out/r.sarif
  assert_input_error output-file 'outside the workspace'
  run_stub INPUT_COMMAND=validate INPUT_OUTPUT_FILE=file-link.sarif
  assert_input_error output-file 'outside the workspace'
  run_stub INPUT_COMMAND=validate INPUT_OUTPUT_FILE=dangling.sarif
  assert_input_error output-file 'outside the workspace'
  run_stub INPUT_COMMAND=validate INPUT_WORKING_DIRECTORY=out-link
  assert_input_error working-directory 'outside the workspace'
  run_stub INPUT_COMMAND=validate INPUT_SARIF_BASE=out-link
  assert_input_error sarif-base 'outside the workspace'
  run_stub INPUT_COMMAND=validate INPUT_CRA_SIDECAR=out-link/s.json
  assert_input_error cra-sidecar 'outside the workspace'
  # A link that stays inside the workspace is fine, even a dangling one.
  expect_argv 'validate|--output-file=in-link/r.sarif' INPUT_COMMAND=validate INPUT_OUTPUT_FILE=in-link/r.sarif
  expect_argv 'validate|--output-file=sub/rel-in/r.sarif' INPUT_COMMAND=validate INPUT_OUTPUT_FILE=sub/rel-in/r.sarif
  # Paths are relative to working-directory, and must still stay inside.
  expect_argv 'validate|--output-file=r.sarif' INPUT_COMMAND=validate INPUT_WORKING_DIRECTORY=in-link INPUT_OUTPUT_FILE=r.sarif
  run_stub INPUT_COMMAND=validate INPUT_WORKING_DIRECTORY=sub INPUT_OUTPUT_FILE=rel-out/r.sarif
  assert_input_error output-file 'outside the workspace'
}

test_paths_working_directory_must_exist() {
  run_stub INPUT_COMMAND=validate INPUT_WORKING_DIRECTORY=missing-dir
  assert_input_error working-directory "'missing-dir' is not a directory in the workspace"
  : >"$SB/ws/a-file"
  run_stub INPUT_COMMAND=validate INPUT_WORKING_DIRECTORY=a-file
  assert_input_error working-directory "'a-file' is not a directory in the workspace"
}

test_paths_workspace_through_symlink() {
  # GITHUB_WORKSPACE may itself be reached through a symbolic link.
  need_symlinks || return
  ln -s "$SB/ws" "$SB/ws-link"
  mkdir -p "$SB/ws/reports"
  run_step setup "INPUT_BINARY_PATH=$STUB_BIN" INPUT_COMMAND=validate INPUT_OUTPUT_FILE=reports/r.sarif "GITHUB_WORKSPACE=$SB/ws-link"
  assert_eq "$STEP_STATUS" 0 'setup status'
  run_step run "SBOM_TOOLS_BIN=$STUB_BIN" INPUT_COMMAND=validate INPUT_OUTPUT_FILE=reports/r.sarif "GITHUB_WORKSPACE=$SB/ws-link"
  assert_eq "$STEP_STATUS" 0 'run status'
  assert_eq "$(output_of run output-file)" "$(native "$SB/ws-link/reports/r.sarif")" 'output-file output'
  [ -f "$SB/ws/reports/r.sarif" ] || fail 'the report was not written'
}

test_run_sh_validates_on_its_own() {
  # run.sh re-checks its inputs, so it is safe without setup.sh in front.
  run_step run "SBOM_TOOLS_BIN=$STUB_BIN" INPUT_COMMAND=validate INPUT_OUTPUT_FILE=../escape.sarif
  assert_eq "$STEP_STATUS" 3 'run.sh status'
  assert_eq "$(output_of run exit-code)" 3 'exit-code output'
  assert_contains "$(cat "$SB/run.log")" "invalid input 'output-file'"
  [ ! -e "$SB/argv" ] || fail 'sbom-tools ran'
}

# ---------------------------------------------------------- exit contract

# The meaning the annotation must give, from each command's --help.
expected_meaning() {
  case "$1:$2" in
    diff:1) echo 'SBOM changes detected (--fail-on-change)' ;;
    diff:2) echo 'New vulnerabilities introduced (--fail-on-vuln)' ;;
    diff:4) echo 'Introduced vulnerabilities lack VEX statements (--fail-on-vex-gap)' ;;
    diff:6) echo "An introduced vulnerability is in CISA's Known Exploited Vulnerabilities catalog (--fail-on-kev)" ;;
    diff:7) echo 'An ML performance metric regressed (--fail-on-ml-regression)' ;;
    validate:1) echo 'Compliance errors found: the SBOM is non-compliant, or a selected standard does not apply to it under --require-applicable' ;;
    validate:2) echo 'Compliance warnings found (--fail-on-warning)' ;;
    quality:1) echo 'Quality score below --min-score, or the SBOM is non-compliant under --fail-on-noncompliant' ;;
    view:2) echo 'The SBOM contains vulnerabilities (--fail-on-vuln)' ;;
    query:1) echo 'No components matched the query' ;;
    vex:1) echo 'Actionable vulnerabilities remain (--actionable-only)' ;;
    verify:1) echo 'Verification failed: a hash mismatch, weak or missing component hashes, mismatched model weights, or a receipt that does not pass' ;;
    license-check:5) echo 'License policy violations found' ;;
    *:1) echo 'Gate failed' ;;
    *:2) echo 'Vulnerabilities found (--fail-on-vuln) or compliance warnings (--fail-on-warning)' ;;
    *:4) echo 'VEX gaps found (--fail-on-vex-gap)' ;;
    *:5) echo 'License policy violations found' ;;
    *:6) echo 'Actively exploited (CISA KEV) vulnerability introduced (--fail-on-kev)' ;;
    *:7) echo 'ML performance metric regressed (--fail-on-ml-regression)' ;;
  esac
}

CASE_CMD=''
CASE_CODE=''

case_exit_code() {
  local args label
  case "$CASE_CMD" in
    diff) args='old.json new.json' ;;
    query) args='log4j fleet.json' ;;
    vex) args='status sbom.json' ;;
    verify) args='hash sbom.json' ;;
    *) args='sbom.json' ;;
  esac
  label="$CASE_CMD"
  case "$CASE_CMD" in vex | verify) label="$CASE_CMD ${args%% *}" ;; esac
  run_stub "INPUT_COMMAND=$CASE_CMD" "INPUT_ARGS=$args" "STUB_EXIT=$CASE_CODE" \
    'STUB_STDERR=error: invalid value '\''foo'\'' for '\''--standard <STANDARD>'\'''
  assert_eq "$SETUP_STATUS" 0 'setup status'
  assert_eq "$RUN_STATUS" "$CASE_CODE" 'run step status (the CLI exit code)'
  assert_eq "$EXIT_CODE" "$CASE_CODE" 'exit-code output'
  case "$CASE_CODE" in
    0)
      assert_not_contains "$RUN_LOG" '::error'
      assert_contains "$RUN_LOG" "sbom-tools $label passed (exit 0)."
      ;;
    3)
      assert_contains "$RUN_LOG" "::error title=sbom-tools $label%3A configuration error::Configuration error (exit 3): sbom-tools rejected its arguments or could not complete: invalid value 'foo' for '--standard <STANDARD>'."
      ;;
    1 | 2 | 4 | 5 | 6 | 7)
      assert_contains "$RUN_LOG" "::error title=sbom-tools $label%3A gate failed::$(expected_meaning "$CASE_CMD" "$CASE_CODE") (exit $CASE_CODE)."
      ;;
    *)
      assert_contains "$RUN_LOG" "::error title=sbom-tools $label%3A failed::sbom-tools exited $CASE_CODE, which is not one of its documented exit codes"
      ;;
  esac
}

test_exit_3_messages() {
  run_stub INPUT_COMMAND=validate INPUT_ARGS=nope.json STUB_EXIT=3 \
    $'STUB_STDERR=INFO Parsing SBOM\nError: Parse failed for nope.json: Failed to read SBOM file nope.json\n\nCaused by:\n    0: No such file'
  assert_contains "$RUN_LOG" 'could not complete: Parse failed for nope.json: Failed to read SBOM file nope.json. Exit 3 is a usage or operational error'
  run_stub INPUT_COMMAND=validate STUB_EXIT=3
  assert_contains "$RUN_LOG" '::error title=sbom-tools validate%3A configuration error::Configuration error (exit 3): sbom-tools rejected its arguments or could not complete. Exit 3'
  # Annotation text is escaped: a line break in the CLI message cannot end it.
  run_stub INPUT_COMMAND=validate STUB_EXIT=3 'STUB_STDERR=error: 100% wrong'
  assert_contains "$RUN_LOG" 'could not complete: 100%25 wrong.'
}

test_exit_crash_and_missing_binary() {
  run_step run "SBOM_TOOLS_BIN=$SB/no-such-binary" INPUT_COMMAND=validate INPUT_ARGS=sbom.json
  assert_eq "$STEP_STATUS" 127 'run.sh status'
  assert_eq "$(output_of run exit-code)" 127 'exit-code output'
  assert_contains "$(cat "$SB/run.log")" '::error title=sbom-tools validate%3A failed::sbom-tools exited 127'
  run_step run SBOM_TOOLS_BIN= INPUT_COMMAND=validate
  assert_eq "$STEP_STATUS" 3 'run.sh status without a binary'
  assert_eq "$(output_of run exit-code)" 3 'exit-code output without a binary'
}

test_exit_code_when_setup_fails() {
  run_action "$STUB_PATH" INPUT_COMMAND=validate INPUT_VERSION=0.3.0
  assert_eq "$(output_of setup exit-code)" 3 'setup exit-code output'
  assert_eq "$EXIT_CODE" 3 'exit-code output'
  assert_eq "$VERSION" '' 'version output'
  assert_eq "$SLSA_VERIFIED" false 'slsa-verified output'
}

test_output_file_output() {
  local code
  for code in 0 1 2 4 5 6 7; do
    run_stub INPUT_COMMAND=validate INPUT_ARGS=sbom.json INPUT_OUTPUT_FILE=out.json "STUB_EXIT=$code"
    assert_eq "$OUTPUT_FILE" "$(native "$SB/ws/out.json")" "output-file after exit $code"
  done
  for code in 3 9 139; do
    run_stub INPUT_COMMAND=validate INPUT_ARGS=sbom.json INPUT_OUTPUT_FILE=out.json "STUB_EXIT=$code"
    assert_eq "$OUTPUT_FILE" '' "output-file after exit $code (the file exists from earlier)"
  done
  rm -f "$SB/ws/out.json"
  run_stub INPUT_COMMAND=validate INPUT_ARGS=sbom.json INPUT_OUTPUT_FILE=out.json STUB_NO_OUTPUT_FILE=1
  assert_eq "$OUTPUT_FILE" '' 'output-file when nothing was written'
  run_stub INPUT_COMMAND=validate INPUT_ARGS=sbom.json
  assert_eq "$OUTPUT_FILE" '' 'output-file without the input'
  mkdir -p "$SB/ws/sub/reports"
  run_stub INPUT_COMMAND=validate INPUT_ARGS=sbom.json INPUT_WORKING_DIRECTORY=sub INPUT_OUTPUT_FILE=./reports/r.sarif
  assert_eq "$OUTPUT_FILE" "$(native "$SB/ws/sub/reports/r.sarif")" 'output-file in a working-directory'
}

test_stop_commands_around_cli_output() {
  run_stub INPUT_COMMAND=view INPUT_ARGS=sbom.json 'STUB_STDOUT=::warning::forged by an SBOM' $'STUB_STDERR=::error::also forged'
  local token
  token=$(sed -n 's/^::stop-commands::\([0-9a-f]*\)$/\1/p' "$SB/run.log")
  assert_eq "${#token}" 32 'stop-commands token length'
  local stop_line forged_line resume_line
  stop_line=$(grep -n '^::stop-commands::' "$SB/run.log" | cut -d: -f1)
  forged_line=$(grep -n '^::warning::forged by an SBOM$' "$SB/run.log" | cut -d: -f1)
  resume_line=$(grep -n "^::$token::\$" "$SB/run.log" | cut -d: -f1)
  if [ -z "$stop_line" ] || [ -z "$forged_line" ] || [ -z "$resume_line" ] ||
    [ "$stop_line" -ge "$forged_line" ] || [ "$forged_line" -ge "$resume_line" ]; then
    fail "the CLI output is not between ::stop-commands:: and ::<token>:: (lines $stop_line $forged_line $resume_line)"
  fi
  assert_contains "$RUN_LOG" '::error::also forged'
}

# ---------------------------------------- integration with the real sbom-tools

test_cli_validate_verdicts() {
  need_cli || return
  copy_fixture ntia-warnings-only.cdx.json supply-chain-baseline.cdx.json
  run_action "INPUT_BINARY_PATH=$CLI" INPUT_COMMAND=validate INPUT_ARGS=ntia-warnings-only.cdx.json INPUT_STANDARD=ntia
  assert_eq "$RUN_STATUS" 0 'compliant: run status'
  assert_eq "$EXIT_CODE" 0 'compliant: exit-code'
  assert_not_contains "$RUN_LOG" '::error'
  run_action "INPUT_BINARY_PATH=$CLI" INPUT_COMMAND=validate INPUT_ARGS=ntia-warnings-only.cdx.json INPUT_STANDARD=ntia INPUT_FAIL_ON_WARNING=true
  assert_failed_with 2
  assert_contains "$RUN_LOG" '::error title=sbom-tools validate%3A gate failed::Compliance warnings found (--fail-on-warning) (exit 2).'
  run_action "INPUT_BINARY_PATH=$CLI" INPUT_COMMAND=validate INPUT_ARGS=supply-chain-baseline.cdx.json INPUT_STANDARD=ntia
  assert_failed_with 1
  assert_contains "$RUN_LOG" '::error title=sbom-tools validate%3A gate failed::Compliance errors found'
  run_action "INPUT_BINARY_PATH=$CLI" INPUT_COMMAND=validate INPUT_ARGS=ntia-warnings-only.cdx.json INPUT_STANDARD=ai-act
  assert_eq "$RUN_STATUS" 0 'N/A standard: run status'
  run_action "INPUT_BINARY_PATH=$CLI" INPUT_COMMAND=validate INPUT_ARGS=ntia-warnings-only.cdx.json INPUT_STANDARD=ai-act INPUT_REQUIRE_APPLICABLE=true
  assert_failed_with 1
}

test_cli_usage_errors_exit_3() {
  need_cli || return
  copy_fixture ntia-warnings-only.cdx.json supply-chain-baseline.cdx.json
  run_action "INPUT_BINARY_PATH=$CLI" INPUT_COMMAND=validate INPUT_ARGS=ntia-warnings-only.cdx.json INPUT_STANDARD=ntia,nist-800-53
  assert_failed_with 3
  assert_contains "$RUN_LOG" "::error title=sbom-tools validate%3A configuration error::Configuration error (exit 3): sbom-tools rejected its arguments or could not complete: invalid value 'nist-800-53' for '--standard <STANDARD>'"
  run_action "INPUT_BINARY_PATH=$CLI" INPUT_COMMAND=diff 'INPUT_ARGS=supply-chain-baseline.cdx.json supply-chain-baseline.cdx.json' INPUT_FAIL_ON_WARNING=true
  assert_failed_with 3
  assert_contains "$RUN_LOG" "unexpected argument '--fail-on-warning' found"
  run_action "INPUT_BINARY_PATH=$CLI" INPUT_COMMAND=validate INPUT_ARGS=missing.cdx.json
  assert_failed_with 3
  assert_contains "$RUN_LOG" 'could not complete: Parse failed for missing.cdx.json'
  run_action "INPUT_BINARY_PATH=$CLI" INPUT_COMMAND=validate INPUT_ARGS=ntia-warnings-only.cdx.json INPUT_AS_OF=yesterday
  assert_failed_with 3
  assert_contains "$RUN_LOG" 'invalid --as-of'
  run_action "INPUT_BINARY_PATH=$CLI" INPUT_COMMAND=enrich INPUT_ARGS=ntia-warnings-only.cdx.json INPUT_OUTPUT_FORMAT=json
  assert_failed_with 3
  assert_contains "$RUN_LOG" "unexpected argument '--output' found"
}

STANDARDS='ntia fda cra cra-phase1 ssdf eo14028 cnsa2 pqc bsi oss-steward eucc ai-act bsi-ai cisa-2026 pci-dss fsct'
STANDARD_ALIASES='cra-phase2 cra-2026 nist-ssdf nist_ssdf eo-14028 eo_14028 cnsa-2 cnsa_2 cnsa2.0 nist-pqc nist_pqc tr-03183 tr03183 bsi-tr-03183-2 cra-oss-steward cra-oss cra-art24 art24 eucc-substantial common-criteria ai_act aiact eu-ai-act bsi_ai bsiai sbom-for-ai ai-bom cisa cisa2026 minimum-elements-2026 pci pci-dss-6-3-2 pci-dss-4 fsct-3 component-transparency'
PROFILES='minimal standard security license-compliance cra bsi comprehensive cbom ai-readiness'
PROFILE_ALIASES='license cyber-resilience tr-03183 tr03183 bsi-tr-03183-2 full cryptographic ai_readiness'

test_cli_every_standard_accepted() {
  need_cli || return
  copy_fixture ntia-warnings-only.cdx.json
  local s
  for s in $STANDARDS $STANDARD_ALIASES; do
    run_action "INPUT_BINARY_PATH=$CLI" INPUT_COMMAND=validate INPUT_ARGS=ntia-warnings-only.cdx.json "INPUT_STANDARD=$s"
    [ "$RUN_STATUS" != 3 ] || fail "standard $s: exit 3: $(grep '::error' "$SB/run.log")"
  done
  run_action "INPUT_BINARY_PATH=$CLI" INPUT_COMMAND=validate INPUT_ARGS=ntia-warnings-only.cdx.json "INPUT_STANDARD=${STANDARDS// /,}"
  [ "$RUN_STATUS" != 3 ] || fail 'all 16 standards at once: exit 3'
}

test_cli_every_profile_accepted() {
  need_cli || return
  copy_fixture ntia-warnings-only.cdx.json
  local p
  for p in $PROFILES $PROFILE_ALIASES; do
    run_action "INPUT_BINARY_PATH=$CLI" INPUT_COMMAND=quality INPUT_ARGS=ntia-warnings-only.cdx.json "INPUT_PROFILE=$p"
    [ "$RUN_STATUS" != 3 ] || fail "profile $p: exit 3: $(grep '::error' "$SB/run.log")"
  done
}

test_cli_diff_gates() {
  need_cli || return
  copy_fixture supply-chain-baseline.cdx.json supply-chain-incident.cdx.json supply-chain-vex.openvex.json
  run_action "INPUT_BINARY_PATH=$CLI" INPUT_COMMAND=diff 'INPUT_ARGS=supply-chain-baseline.cdx.json supply-chain-baseline.cdx.json' INPUT_FAIL_ON_CHANGE=true
  assert_eq "$RUN_STATUS" 0 'no change: run status'
  run_action "INPUT_BINARY_PATH=$CLI" INPUT_COMMAND=diff 'INPUT_ARGS=supply-chain-baseline.cdx.json supply-chain-incident.cdx.json' INPUT_FAIL_ON_CHANGE=true
  assert_failed_with 1
  assert_contains "$RUN_LOG" 'gate failed::SBOM changes detected (--fail-on-change) (exit 1).'
  run_action "INPUT_BINARY_PATH=$CLI" INPUT_COMMAND=diff 'INPUT_ARGS=supply-chain-baseline.cdx.json supply-chain-incident.cdx.json' INPUT_FAIL_ON_VULN=true
  assert_failed_with 2
  assert_contains "$RUN_LOG" 'gate failed::New vulnerabilities introduced (--fail-on-vuln) (exit 2).'
  run_action "INPUT_BINARY_PATH=$CLI" INPUT_COMMAND=diff \
    'INPUT_ARGS=supply-chain-baseline.cdx.json supply-chain-incident.cdx.json --vex supply-chain-vex.openvex.json' INPUT_FAIL_ON_VEX_GAP=true
  assert_failed_with 4
  assert_contains "$RUN_LOG" 'gate failed::Introduced vulnerabilities lack VEX statements (--fail-on-vex-gap) (exit 4).'
}

test_cli_other_commands() {
  need_cli || return
  copy_fixture supply-chain-baseline.cdx.json supply-chain-incident.cdx.json supply-chain-vex.openvex.json license-risk.cdx.json
  run_action "INPUT_BINARY_PATH=$CLI" INPUT_COMMAND=quality INPUT_ARGS=supply-chain-baseline.cdx.json INPUT_MIN_SCORE=99
  assert_failed_with 1
  assert_contains "$RUN_LOG" 'gate failed::Quality score below --min-score'
  run_action "INPUT_BINARY_PATH=$CLI" INPUT_COMMAND=quality INPUT_ARGS=supply-chain-baseline.cdx.json INPUT_MIN_SCORE=1 INPUT_PROFILE=security
  assert_eq "$RUN_STATUS" 0 'quality above min-score'
  run_action "INPUT_BINARY_PATH=$CLI" INPUT_COMMAND=query 'INPUT_ARGS=no-such-component supply-chain-baseline.cdx.json'
  assert_failed_with 1
  assert_contains "$RUN_LOG" 'gate failed::No components matched the query (exit 1).'
  run_action "INPUT_BINARY_PATH=$CLI" INPUT_COMMAND=view INPUT_ARGS=supply-chain-incident.cdx.json INPUT_FAIL_ON_VULN=true
  assert_failed_with 2
  assert_contains "$RUN_LOG" 'gate failed::The SBOM contains vulnerabilities (--fail-on-vuln) (exit 2).'
  run_action "INPUT_BINARY_PATH=$CLI" INPUT_COMMAND=license-check 'INPUT_ARGS=license-risk.cdx.json --strict'
  assert_failed_with 5
  assert_contains "$RUN_LOG" 'sbom-tools license-check%3A gate failed::License policy violations found (exit 5).'
  run_action "INPUT_BINARY_PATH=$CLI" INPUT_COMMAND=license-check INPUT_ARGS=license-risk.cdx.json INPUT_OUTPUT_FORMAT=json
  assert_eq "$RUN_STATUS" 0 'license-check takes output-format as --output'
  run_action "INPUT_BINARY_PATH=$CLI" INPUT_COMMAND=vex \
    'INPUT_ARGS=status supply-chain-incident.cdx.json --vex supply-chain-vex.openvex.json --actionable-only' INPUT_OUTPUT_FORMAT=json
  assert_failed_with 1
  assert_contains "$RUN_LOG" 'sbom-tools vex status%3A gate failed::Actionable vulnerabilities remain (--actionable-only) (exit 1).'
  run_action "INPUT_BINARY_PATH=$CLI" INPUT_COMMAND=verify \
    'INPUT_ARGS=hash supply-chain-baseline.cdx.json --expected=sha256:0000000000000000000000000000000000000000000000000000000000000000'
  assert_failed_with 1
  assert_contains "$RUN_LOG" 'sbom-tools verify hash%3A gate failed::Verification failed'
  run_action "INPUT_BINARY_PATH=$CLI" INPUT_COMMAND=enrich INPUT_ARGS=supply-chain-baseline.cdx.json INPUT_OUTPUT_FILE=enriched.json
  assert_eq "$RUN_STATUS" 0 'enrich: run status'
  assert_eq "$OUTPUT_FILE" "$(native "$SB/ws/enriched.json")" 'enrich: output-file'
}

test_cli_sarif_report() {
  need_cli || return
  copy_fixture supply-chain-baseline.cdx.json
  mkdir -p "$SB/ws/reports"
  run_action "INPUT_BINARY_PATH=$CLI" INPUT_COMMAND=validate INPUT_ARGS=supply-chain-baseline.cdx.json INPUT_STANDARD=cra,ntia \
    INPUT_OUTPUT_FORMAT=sarif INPUT_OUTPUT_FILE=reports/validate.sarif
  assert_failed_with 1
  assert_eq "$OUTPUT_FILE" "$(native "$SB/ws/reports/validate.sarif")" 'output-file output'
  if [ -f "$OUTPUT_FILE" ]; then
    assert_contains "$(head -c 4000 "$OUTPUT_FILE")" '"version": "2.1.0"' 'SARIF file'
    assert_contains "$(cat "$OUTPUT_FILE")" '"runs"' 'SARIF file'
  else
    fail 'no SARIF file'
  fi
}

test_cli_sarif_include_passes() {
  need_cli || return
  if ! cli_supports validate --sarif-include-passes; then
    skip 'needs WP 1.6 (--sarif-include-passes) in the sbom-tools binary'
    return
  fi
  # A CBOM whose algorithms pass NIST PQC checks.
  copy_fixture cbom-cnsa2-compliant.cdx.json
  run_action "INPUT_BINARY_PATH=$CLI" INPUT_COMMAND=validate INPUT_ARGS=cbom-cnsa2-compliant.cdx.json INPUT_STANDARD=pqc \
    INPUT_OUTPUT_FORMAT=sarif INPUT_OUTPUT_FILE=v.sarif
  assert_eq "$RUN_STATUS" 0 'without passes: run status'
  assert_not_contains "$(cat "$SB/ws/v.sarif" 2>/dev/null)" '"kind": "pass"' 'SARIF without passes'
  run_action "INPUT_BINARY_PATH=$CLI" INPUT_COMMAND=validate INPUT_ARGS=cbom-cnsa2-compliant.cdx.json INPUT_STANDARD=pqc \
    INPUT_OUTPUT_FORMAT=sarif INPUT_OUTPUT_FILE=v.sarif INPUT_SARIF_INCLUDE_PASSES=true
  assert_eq "$RUN_STATUS" 0 'with passes: run status'
  assert_contains "$(cat "$SB/ws/v.sarif" 2>/dev/null)" '"kind": "pass"' 'SARIF with passes'
}

test_cli_sarif_category_and_base() {
  need_cli || return
  if ! cli_supports validate --sarif-category || ! cli_supports validate --sarif-base; then
    skip 'needs WP 1.5 (--sarif-category, --sarif-base) in the sbom-tools binary'
    return
  fi
  mkdir -p "$SB/ws/services/api"
  cp "$FIXTURES/ntia-warnings-only.cdx.json" "$SB/ws/services/api/sbom.cdx.json"
  run_action "INPUT_BINARY_PATH=$CLI" INPUT_COMMAND=validate INPUT_ARGS=services/api/sbom.cdx.json INPUT_STANDARD=ntia \
    INPUT_OUTPUT_FORMAT=sarif INPUT_OUTPUT_FILE=api.sarif INPUT_SARIF_CATEGORY=sbom-tools/ntia/api INPUT_SARIF_BASE=services
  assert_eq "$RUN_STATUS" 0 'run status'
  local sarif
  sarif=$(cat "$SB/ws/api.sarif" 2>/dev/null)
  assert_contains "$sarif" '"id": "sbom-tools/ntia/api/"' 'automationDetails.id'
  assert_contains "$sarif" '"uri": "api/sbom.cdx.json"' 'artifact URI relative to sarif-base'
  run_action "INPUT_BINARY_PATH=$CLI" INPUT_COMMAND=validate INPUT_ARGS=services/api/sbom.cdx.json \
    INPUT_OUTPUT_FORMAT=sarif INPUT_SARIF_BASE=services/missing
  assert_failed_with 3
  assert_contains "$RUN_LOG" 'invalid --sarif-base'
}

test_cli_sarif_max_results() {
  need_cli || return
  if ! cli_supports validate --sarif-max-results; then
    skip 'needs --sarif-max-results in the sbom-tools binary (not added yet)'
    return
  fi
  copy_fixture supply-chain-baseline.cdx.json
  run_action "INPUT_BINARY_PATH=$CLI" INPUT_COMMAND=validate INPUT_ARGS=supply-chain-baseline.cdx.json INPUT_STANDARD=ntia \
    INPUT_OUTPUT_FORMAT=sarif INPUT_OUTPUT_FILE=v.sarif INPUT_SARIF_MAX_RESULTS=1
  [ "$RUN_STATUS" != 3 ] || fail 'sarif-max-results: exit 3'
}

test_cli_cra_inputs() {
  need_cli || return
  copy_fixture cra-compliant.cdx.json cra-sidecar.cra.json
  run_action "INPUT_BINARY_PATH=$CLI" INPUT_COMMAND=validate INPUT_ARGS=cra-compliant.cdx.json INPUT_STANDARD=cra \
    INPUT_CRA_SIDECAR=cra-sidecar.cra.json INPUT_CRA_PRODUCT_CLASS=important-class-1 INPUT_AS_OF=2027-01-01
  assert_eq "$RUN_STATUS" 0 'validate with sidecar, class and as-of'
  run_action "INPUT_BINARY_PATH=$CLI" INPUT_COMMAND=quality INPUT_ARGS=cra-compliant.cdx.json INPUT_PROFILE=cra \
    INPUT_CRA_SIDECAR=cra-sidecar.cra.json INPUT_AS_OF=2027-01-01T00:00:00Z
  assert_eq "$RUN_STATUS" 0 'quality with sidecar and as-of'
  run_action "INPUT_BINARY_PATH=$CLI" INPUT_COMMAND=validate INPUT_ARGS=cra-compliant.cdx.json INPUT_STANDARD=cra INPUT_CRA_PRODUCT_CLASS=bogus
  assert_failed_with 3
  run_action "INPUT_BINARY_PATH=$CLI" INPUT_COMMAND=validate INPUT_ARGS=cra-compliant.cdx.json INPUT_STANDARD=cra INPUT_CRA_SIDECAR=missing.cra.json
  assert_failed_with 3
}

test_cli_working_directory() {
  need_cli || return
  mkdir -p "$SB/ws/app/out"
  cp "$FIXTURES/ntia-warnings-only.cdx.json" "$SB/ws/app/sbom.cdx.json"
  run_action "INPUT_BINARY_PATH=$CLI" INPUT_COMMAND=validate INPUT_ARGS=sbom.cdx.json INPUT_WORKING_DIRECTORY=app \
    INPUT_OUTPUT_FORMAT=json INPUT_OUTPUT_FILE=out/validate.json
  assert_eq "$RUN_STATUS" 0 'run status'
  assert_eq "$OUTPUT_FILE" "$(native "$SB/ws/app/out/validate.json")" 'output-file output'
}

# ------------------------------------------------------------------- network

test_network_latest_matches_releases() {
  need_network || return
  command -v gh >/dev/null 2>&1 || { skip 'gh is not installed'; return; }
  local tags newest
  tags=$(gh release list --repo sbom-tool/sbom-tools --exclude-drafts --exclude-pre-releases --limit 100 --json tagName --jq '.[].tagName') ||
    { skip 'gh cannot list releases (not authenticated?)'; return; }
  newest=$(printf '%s\n' "$tags" | sed -n 's/^v\(0\.4\.[0-9][0-9]*\)$/\1/p' | sort -t. -k3,3n | tail -n 1)
  # Real gh, stub curl: resolve, then stop at the (stub) download.
  run_action "PATH=$TMP_ROOT/curl-only:$PATH" "STUB_RELEASE_DIR=$SB/none" INPUT_VERSION=latest INPUT_COMMAND=validate
  if [ -z "$newest" ]; then
    assert_failed_with 3
    assert_contains "$SETUP_LOG" 'No sbom-tools 0.4.x release is published yet'
  else
    assert_contains "$SETUP_LOG" "version 'latest' resolved to sbom-tools $newest"
  fi
}

# install_real <version> <mode> [NAME=value ...]: install_release from
# lib.sh, with real gh, outside the version rule (so 0.3.0 can stand in for
# 0.4.0). Sets REAL_STATUS and REAL_LOG.
install_real() {
  local version="$1" mode="$2"
  shift 2
  (
    unset_action_env
    export GITHUB_WORKSPACE="$SB/ws" GITHUB_OUTPUT="$SB/real.output" GITHUB_PATH="$SB/path"
    export RUNNER_TEMP="$SB/temp" RUNNER_TOOL_CACHE="$SB/toolcache" RUNNER_OS="$HOST_OS" RUNNER_ARCH="$HOST_ARCH"
    for kv in "$@"; do export "${kv?}"; done
    # shellcheck source-path=SCRIPTDIR source=../scripts/lib.sh
    . "$SCRIPTS/lib.sh"
    init_paths || exit 3
    install_release "$version" "$mode" || exit 3
    echo "INSTALLED=$INSTALLED_BINARY SLSA=$SLSA_VERIFIED"
    "$INSTALLED_BINARY" --version
  ) >"$SB/real.log" 2>&1
  REAL_STATUS=$?
  REAL_LOG=$(cat "$SB/real.log")
}

test_network_install_real_release() {
  need_network || return
  command -v gh >/dev/null 2>&1 || { skip 'gh is not installed'; return; }
  # v0.3.0 stands in for 0.4.0 until 0.4.0 is released: same assets, same
  # release workflow, same attestations.
  install_real 0.3.0 require
  assert_eq "$REAL_STATUS" 0 'install status'
  assert_contains "$REAL_LOG" 'SHA-256 verified'
  assert_contains "$REAL_LOG" 'Build provenance verified'
  assert_contains "$REAL_LOG" 'SLSA=true'
  assert_contains "$REAL_LOG" 'sbom-tools 0.3.0'
}

test_network_provenance_catches_tampering() {
  need_network || return
  command -v gh >/dev/null 2>&1 || { skip 'gh is not installed'; return; }
  local target
  case "$HOST_OS-$HOST_ARCH" in
    Linux-X64) target=linux-x86_64 ;;
    Linux-ARM64) target=linux-aarch64 ;;
    macOS-X64) target=macos-x86_64 ;;
    macOS-ARM64) target=macos-aarch64 ;;
    *) skip "no tar.gz release archive for $HOST_OS-$HOST_ARCH"; return ;;
  esac
  # An archive the sbom-tools release workflow did not build, served with a
  # checksums.sha256 that matches it: only the provenance check can stop it.
  make_release "$target" tar.gz
  install_real 0.3.0 require "PATH=$TMP_ROOT/curl-only:$PATH" "STUB_RELEASE_DIR=$SB/release"
  assert_eq "$REAL_STATUS" 3 'install status'
  assert_contains "$REAL_LOG" 'SHA-256 verified'
  assert_contains "$REAL_LOG" 'provenance not verified::Not installing sbom-tools v0.3.0'
  [ ! -e "$SB/toolcache/sbom-tools" ] || fail 'the unverified archive was installed'
}

# ------------------------------------------------- needs the v0.4.0 release

need_release() {
  if [ "$RELEASE" != true ]; then
    skip 'needs the sbom-tools v0.4.0 release (--release)'
    return 1
  fi
  if ! gh release view v0.4.0 --repo sbom-tool/sbom-tools >/dev/null 2>&1; then
    skip 'needs the sbom-tools v0.4.0 release, which is not published yet'
    return 1
  fi
}

test_release_install_0_4_0() {
  need_release || return
  copy_fixture ntia-warnings-only.cdx.json
  run_action INPUT_VERSION=0.4.0 INPUT_COMMAND=validate INPUT_ARGS=ntia-warnings-only.cdx.json INPUT_STANDARD=ntia
  assert_eq "$SETUP_STATUS" 0 'setup status'
  assert_eq "$VERSION" 0.4.0 'version output'
  assert_eq "$SLSA_VERIFIED" true 'slsa-verified output'
  assert_eq "$RUN_STATUS" 0 'run status'
  assert_contains "$("$(output_of setup binary)" --version)" 'sbom-tools 0.4.0' 'installed --version'
}

test_release_latest_resolves_to_0_4() {
  need_release || return
  copy_fixture supply-chain-baseline.cdx.json
  run_action INPUT_VERSION=latest INPUT_COMMAND=validate INPUT_ARGS=supply-chain-baseline.cdx.json INPUT_STANDARD=ntia
  assert_eq "$SETUP_STATUS" 0 'setup status'
  case "$VERSION" in 0.4.*) ;; *) fail "latest resolved to '$VERSION'" ;; esac
  assert_failed_with 1
}

# ---------------------------------------------------------------------- main

mkdir -p "$TMP_ROOT/curl-only"
cp "$STUBS/curl" "$TMP_ROOT/curl-only/curl"
chmod +x "$TMP_ROOT/curl-only/curl"

echo "# sbom-tools-action tests ($HOST_OS-$HOST_ARCH, bash $BASH_VERSION)"
if [ -n "$CLI" ]; then
  echo "# sbom-tools binary: $CLI ($("$CLI" --version 2>/dev/null | head -n 1))"
fi

t test_action_yml_wiring 'action.yml: every input reaches its step through env, no ${{ }} in run:, defaults'
t test_workflow_actions_pinned 'workflows pin third-party actions to a full commit SHA with a version comment'

t test_version_rejects_older_line 'version: 0.3.x and earlier are rejected, naming sbom-tools-action@v1'
t test_version_rejects_newer_line 'version: 0.5.0, 0.40.0, 1.0.0 and other lines are rejected'
t test_version_rejects_malformed 'version: malformed values are rejected with a fix'
t test_version_exact_used_as_given 'version: an exact 0.4.x (pre-releases too) is downloaded as given'
t test_version_latest_picks_newest_0_4 "version: 'latest' is the newest published 0.4.x release"
t test_version_latest_without_0_4_release "version: 'latest' fails clearly while no 0.4.x is published"
t test_version_latest_list_fails "version: 'latest' fails clearly when the release list fails"
t test_version_latest_without_gh "version: 'latest' without gh fails clearly"
t test_version_ignored_with_binary_path 'version: ignored when binary-path is set'

t test_install_downloads_verifies_and_runs 'install: download, SHA-256, provenance, tool cache, PATH, run'
t test_install_platforms 'install: each runner platform downloads its archive'
t test_install_unsupported_platform 'install: unsupported platforms fail and point at binary-path'
t test_install_checksum_mismatch 'install: a checksum mismatch fails before provenance and install'
t test_install_checksum_entry_missing 'install: an archive missing from checksums.sha256 fails'
t test_install_checksum_malformed 'install: a malformed checksums.sha256 fails'
t test_install_checksum_formats 'install: binary-mode entries and CRLF checksum files are read'
t test_install_provenance_modes 'install: verify-provenance require fails, warn warns, off skips'
t test_install_provenance_without_gh 'install: without gh, require fails and warn continues'
t test_install_rejects_bad_archives 'install: a symlinked or missing binary in the archive fails'
t test_install_windows_zip 'install: Windows zip with sbom-tools.exe'

t test_binary_path_override 'binary-path: skips the download; outputs version from --version'
t test_binary_path_relative_and_old_version 'binary-path: relative to the workspace; warns on a non-0.4 binary'
t test_binary_path_invalid 'binary-path: missing, directory and non-executable paths fail'

t test_argv_each_input 'argv: each input adds exactly its flag'
t test_argv_false_and_empty_inputs_add_nothing 'argv: false and empty inputs add nothing'
t test_argv_all_inputs_in_order 'argv: all inputs together, after the args'
t test_argv_values_stay_one_argument 'argv: values are one --flag=value argument, trimmed'
t test_args_split_on_whitespace 'args: split on spaces, tabs and line breaks'
t test_args_no_glob_expansion 'args: no glob expansion'
t test_args_flags_go_before_double_dash 'args: input flags go before a literal --, after a subcommand'
t test_args_version_ranges_allowed 'args: < and > are allowed (version ranges)'
t test_args_metacharacters_rejected 'args: shell metacharacters and control characters are rejected'
t test_inputs_booleans_strict "inputs: booleans must be exactly 'true' or 'false'"
t test_inputs_command_whitelist 'inputs: command must be one of the nine commands'
t test_inputs_min_score_numeric 'inputs: min-score must be a number'
t test_inputs_single_line_values 'inputs: pass-through values must be a single line'
t test_inputs_verify_provenance_values 'inputs: verify-provenance must be require, warn or off'
t test_inputs_errors_reported_together 'inputs: every invalid input is reported, before any download'

t test_paths_accepted 'paths: relative paths inside the workspace are accepted'
t test_paths_traversal_rejected 'paths: absolute, .. and metacharacter paths are rejected for every path input'
t test_paths_symlink_escape_rejected 'paths: symbolic links out of the workspace are rejected'
t test_paths_working_directory_must_exist 'paths: working-directory must be a directory'
t test_paths_workspace_through_symlink 'paths: a workspace reached through a symbolic link'
t test_run_sh_validates_on_its_own 'paths: run.sh re-validates without setup.sh'

for CASE_CMD in diff validate quality view query enrich verify license-check vex; do
  for CASE_CODE in 0 1 2 3 4 5 6 7 9 101 130; do
    t case_exit_code "exit $CASE_CODE from $CASE_CMD: step result, exit-code output and annotation"
  done
done
t test_exit_3_messages 'exit 3: the annotation quotes the CLI error line, escaped'
t test_exit_crash_and_missing_binary 'exit: a missing binary is reported as an unexpected exit'
t test_exit_code_when_setup_fails 'exit-code: 3 when the Action fails before sbom-tools runs'
t test_output_file_output 'output-file: absolute path after 0 and gate exits; empty otherwise'
t test_stop_commands_around_cli_output 'workflow commands printed by sbom-tools are not executed'

t test_cli_validate_verdicts 'cli: validate exits 0, 1 and 2, N/A and --require-applicable'
t test_cli_usage_errors_exit_3 'cli: usage and operational errors exit 3 as configuration errors'
t test_cli_every_standard_accepted 'cli: all 16 standards and their aliases pass through'
t test_cli_every_profile_accepted 'cli: all 9 profiles and their aliases pass through'
t test_cli_diff_gates 'cli: diff exits 0, 1, 2 and 4'
t test_cli_other_commands 'cli: quality, query, view, license-check, vex, verify, enrich'
t test_cli_sarif_report 'cli: validate writes SARIF to output-file'
t test_cli_sarif_include_passes 'cli: sarif-include-passes'
t test_cli_sarif_category_and_base 'cli: sarif-category sets automationDetails.id; sarif-base the URI root'
t test_cli_sarif_max_results 'cli: sarif-max-results'
t test_cli_cra_inputs 'cli: cra-sidecar, cra-product-class and as-of'
t test_cli_working_directory 'cli: working-directory and output-file inside it'

t test_network_latest_matches_releases "network: 'latest' matches the published releases"
t test_network_install_real_release 'network: installs a real release with SHA-256 and provenance verified'
t test_network_provenance_catches_tampering 'network: a rebuilt archive with a matching checksum fails provenance'

t test_release_install_0_4_0 'release: installs and runs sbom-tools 0.4.0'
t test_release_latest_resolves_to_0_4 "release: 'latest' resolves to a 0.4.x release"

echo "1..$T_NUM"
echo "# pass $T_PASS, fail $T_FAIL, skip $T_SKIP"
[ "$T_FAIL" -eq 0 ]
