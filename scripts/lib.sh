# shellcheck shell=bash
# shellcheck disable=SC2034 # globals are how these functions return results
#
# Shared helpers for sbom-tools-action, sourced by setup.sh and run.sh.
#
# Portability: these scripts run under bash 3.2 (macOS /bin/bash), bash 5
# (Linux) and Git Bash (Windows). So: no associative arrays, no mapfile, no
# ${v,,}, and an array that may be empty is expanded as ${a[@]+"${a[@]}"} so
# that `set -u` accepts it.
#
# Functions that report a problem print workflow commands (::error:: and so
# on) to stdout and hand their results back in globals, never through $(...),
# which would swallow the annotations.

SBOM_TOOLS_REPO='sbom-tool/sbom-tools'
# The sbom-tools release workflow; it builds and attests every release archive.
SBOM_TOOLS_SIGNER_WORKFLOW='sbom-tool/sbom-tools/.github/workflows/publish-crates.yml'
SUPPORTED_COMMANDS='diff validate quality view query enrich verify license-check vex'

# ------------------------------------------------------------ workflow commands

# Escape the message part of a workflow command.
gha_escape_data() {
  local s="$1" pct='%'
  s="${s//"$pct"/%25}"
  s="${s//$'\r'/%0D}"
  s="${s//$'\n'/%0A}"
  printf '%s' "$s"
}

# Escape a property value (title=...) of a workflow command.
gha_escape_property() {
  local s
  s="$(gha_escape_data "$1")"
  s="${s//:/%3A}"
  s="${s//,/%2C}"
  printf '%s' "$s"
}

# gha_annotate <error|warning|notice> <title> <message>
gha_annotate() {
  printf '::%s title=%s::%s\n' "$1" "$(gha_escape_property "$2")" "$(gha_escape_data "$3")"
}

# gha_set_output <name> <value>: values are single-line by construction.
gha_set_output() {
  case "$2" in
    *$'\n'* | *$'\r'*)
      printf '::error::sbom-tools-action internal error: output %s contains a line break\n' "$1"
      return 1
      ;;
  esac
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    printf '%s=%s\n' "$1" "$2" >>"$GITHUB_OUTPUT"
  fi
}

# A token for ::stop-commands::, so that nothing sbom-tools prints (it echoes
# text from the SBOM) is read as a workflow command. Sets STOP_TOKEN.
new_stop_token() {
  STOP_TOKEN=$(od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')
  if [ "${#STOP_TOKEN}" -lt 32 ]; then
    STOP_TOKEN="sbom-tools-${RANDOM}${RANDOM}${RANDOM}${RANDOM}$$"
  fi
}

# --------------------------------------------------------------------- paths

on_windows() { [ "${RUNNER_OS:-}" = Windows ]; }

# Git Bash form of a Windows path (C:\x -> /c/x). Sets POSIX_PATH.
posix_path() {
  POSIX_PATH="$1"
  if on_windows && [ -n "$1" ] && command -v cygpath >/dev/null 2>&1; then
    POSIX_PATH=$(cygpath -u "$1")
  fi
}

# Native form of a path, for outputs other steps read (/c/x -> C:\x).
# Sets NATIVE_PATH.
native_path() {
  NATIVE_PATH="$1"
  if on_windows && [ -n "$1" ] && command -v cygpath >/dev/null 2>&1; then
    NATIVE_PATH=$(cygpath -w "$1")
  fi
}

# Set WORKSPACE (logical), WORKSPACE_PHYSICAL (symlinks resolved), TEMP_ROOT
# and TOOL_CACHE from the runner's environment, falling back to the current
# directory and the system temp directory outside Actions.
init_paths() {
  posix_path "${GITHUB_WORKSPACE:-$PWD}"
  WORKSPACE="${POSIX_PATH%/}"
  [ -n "$WORKSPACE" ] || WORKSPACE=/
  if ! WORKSPACE_PHYSICAL=$(cd -P -- "$WORKSPACE" 2>/dev/null && pwd -P); then
    gha_annotate error 'sbom-tools-action: workspace' "The workspace directory '$WORKSPACE' does not exist."
    return 1
  fi
  posix_path "${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
  TEMP_ROOT="${POSIX_PATH%/}"
  posix_path "${RUNNER_TOOL_CACHE:-$TEMP_ROOT}"
  TOOL_CACHE="${POSIX_PATH%/}"
}

# Resolve a path to a physical absolute path in RESOLVED_PATH. Symbolic links
# in the part that exists are followed; a tail that does not exist yet (an
# output file, say) is appended as written. Fails on a symlink loop.
resolve_physical() {
  local path="$1" tail='' hops=0 target dir base
  while :; do
    # Walk up to the nearest ancestor that exists (or is a dangling link).
    while [ ! -e "$path" ] && [ ! -L "$path" ]; do
      case "$path" in
        */*)
          base="${path##*/}"
          path="${path%/*}"
          [ -n "$path" ] || path=/
          ;;
        *)
          base="$path"
          path=.
          ;;
      esac
      tail="/$base$tail"
    done
    if [ -L "$path" ]; then
      hops=$((hops + 1))
      [ "$hops" -le 40 ] || return 1
      target=$(readlink -- "$path") || return 1
      case "$target" in
        /*) path="$target" ;;
        *)
          case "$path" in
            */*) path="${path%/*}/$target" ;;
            *) path="$target" ;;
          esac
          ;;
      esac
      continue
    fi
    if [ -d "$path" ]; then
      dir=$(cd -P -- "$path" 2>/dev/null && pwd -P) || return 1
      RESOLVED_PATH="$dir$tail"
    else
      case "$path" in
        */*)
          dir="${path%/*}"
          base="${path##*/}"
          [ -n "$dir" ] || dir=/
          ;;
        *)
          dir=.
          base="$path"
          ;;
      esac
      dir=$(cd -P -- "$dir" 2>/dev/null && pwd -P) || return 1
      RESOLVED_PATH="$dir/$base$tail"
    fi
    while :; do
      case "$RESOLVED_PATH" in
        *//*) RESOLVED_PATH="${RESOLVED_PATH//\/\//\/}" ;;
        *) break ;;
      esac
    done
    return 0
  done
}

# path_is_inside <path> <root>: both physical and absolute.
path_is_inside() {
  [ "$1" = "$2" ] && return 0
  case "$2" in
    */) case "$1" in "$2"*) return 0 ;; esac ;;
    *) case "$1" in "$2"/*) return 0 ;; esac ;;
  esac
  return 1
}

# True when a '..' path component appears (a..b.json is fine).
path_has_dotdot() {
  case "/$1/" in */../*) return 0 ;; esac
  return 1
}

# ------------------------------------------------------------------- strings

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

has_control_chars() {
  case "$1" in *[[:cntrl:]]*) return 0 ;; esac
  return 1
}

# The characters v1 rejects in paths and args: ; | & $ ` ( ) { } < > ! # \ ' "
# They are inert here (every value is one argv element and nothing is
# evaluated), and are rejected as defence in depth.
has_shell_metachars() {
  case "$1" in *[\;\|\&\$\`\(\)\{\}\<\>\!\#\\\'\"]*) return 0 ;; esac
  return 1
}

# args may also hold < and >, which version ranges need (query --version <2.17.0).
has_args_metachars() {
  case "$1" in *[\;\|\&\$\`\(\)\{\}\!\#\\\'\"]*) return 0 ;; esac
  return 1
}

# Split args on whitespace (space, tab, newline, carriage return) into
# ARGS_WORDS. No quoting, escaping or glob expansion: each word becomes one
# argument exactly as written.
split_args() {
  local IFS=$' \t\n\r'
  set -f
  # shellcheck disable=SC2206 # word splitting is the point; globbing is off
  ARGS_WORDS=($1)
  set +f
}

# -------------------------------------------------------------------- inputs

# Read the INPUT_* environment into IN_* variables; scalars are trimmed and
# args is kept as given. An unset variable takes its action.yml default (for
# local runs); a set but empty one stays empty, so an empty boolean is
# rejected rather than read as false.
load_inputs() {
  IN_VERSION=$(trim "${INPUT_VERSION-}")
  IN_COMMAND=$(trim "${INPUT_COMMAND-}")
  IN_ARGS=${INPUT_ARGS-}
  IN_FAIL_ON_VULN=$(trim "${INPUT_FAIL_ON_VULN-false}")
  IN_FAIL_ON_CHANGE=$(trim "${INPUT_FAIL_ON_CHANGE-false}")
  IN_FAIL_ON_VEX_GAP=$(trim "${INPUT_FAIL_ON_VEX_GAP-false}")
  IN_FAIL_ON_WARNING=$(trim "${INPUT_FAIL_ON_WARNING-false}")
  IN_REQUIRE_APPLICABLE=$(trim "${INPUT_REQUIRE_APPLICABLE-false}")
  IN_ENRICH_VULNS=$(trim "${INPUT_ENRICH_VULNS-false}")
  IN_SARIF_INCLUDE_PASSES=$(trim "${INPUT_SARIF_INCLUDE_PASSES-false}")
  IN_OUTPUT_FORMAT=$(trim "${INPUT_OUTPUT_FORMAT-}")
  IN_OUTPUT_FILE=$(trim "${INPUT_OUTPUT_FILE-}")
  IN_MIN_SCORE=$(trim "${INPUT_MIN_SCORE-}")
  IN_STANDARD=$(trim "${INPUT_STANDARD-}")
  IN_PROFILE=$(trim "${INPUT_PROFILE-}")
  IN_SARIF_CATEGORY=$(trim "${INPUT_SARIF_CATEGORY-}")
  IN_SARIF_BASE=$(trim "${INPUT_SARIF_BASE-}")
  IN_SARIF_MAX_RESULTS=$(trim "${INPUT_SARIF_MAX_RESULTS-}")
  IN_AS_OF=$(trim "${INPUT_AS_OF-}")
  IN_CRA_SIDECAR=$(trim "${INPUT_CRA_SIDECAR-}")
  IN_CRA_PRODUCT_CLASS=$(trim "${INPUT_CRA_PRODUCT_CLASS-}")
  IN_WORKING_DIRECTORY=$(trim "${INPUT_WORKING_DIRECTORY-.}")
  [ -n "$IN_WORKING_DIRECTORY" ] || IN_WORKING_DIRECTORY=.
  IN_VERIFY_PROVENANCE=$(trim "${INPUT_VERIFY_PROVENANCE-require}")
  IN_BINARY_PATH=$(trim "${INPUT_BINARY_PATH-}")
}

VALIDATION_ERRORS=0

# input_error <input-name> <message>
input_error() {
  VALIDATION_ERRORS=$((VALIDATION_ERRORS + 1))
  gha_annotate error "sbom-tools-action: invalid input '$1'" "$2"
}

validate_bool() {
  case "$2" in
    true | false) return 0 ;;
  esac
  input_error "$1" "must be 'true' or 'false', got '$2'."
  return 1
}

# A value handed to the CLI as-is (it validates the value): one line, no
# control characters.
validate_scalar() {
  if has_control_chars "$2"; then
    input_error "$1" "must be a single line without control characters."
    return 1
  fi
  return 0
}

validate_command() {
  local c
  for c in $SUPPORTED_COMMANDS; do
    [ "$IN_COMMAND" = "$c" ] && return 0
  done
  if [ -z "$IN_COMMAND" ]; then
    input_error command "is required. Use one of: ${SUPPORTED_COMMANDS// /, }."
  else
    input_error command "'$IN_COMMAND' is not supported. Use one of: ${SUPPORTED_COMMANDS// /, }."
  fi
  return 1
}

validate_args() {
  local ws=$' \t\n\r' rest
  rest="${IN_ARGS//[$ws]/}"
  if has_control_chars "$rest"; then
    input_error args "must not contain control characters other than spaces, tabs and line breaks."
    return 1
  fi
  if has_args_metachars "$IN_ARGS"; then
    input_error args "contains shell metacharacters (; | & \$ \` ( ) { } ! # \\ ' \"). args is split on whitespace and passed without a shell, so quoting is neither needed nor supported."
    return 1
  fi
  return 0
}

# validate_path <input-name> <value> <base-dir>
# The v1 rules: relative, no '..' component, no shell metacharacters. And,
# after following symbolic links, the path must stay inside the workspace.
validate_path() {
  local name="$1" value="$2" base="$3"
  [ -n "$value" ] || return 0
  if has_control_chars "$value"; then
    input_error "$name" "must be a single-line path without control characters."
    return 1
  fi
  if has_shell_metachars "$value"; then
    input_error "$name" "'$value' contains shell metacharacters."
    return 1
  fi
  case "$value" in
    /* | [A-Za-z]:*)
      input_error "$name" "'$value' must be a path relative to the workspace, not an absolute path."
      return 1
      ;;
  esac
  if path_has_dotdot "$value"; then
    input_error "$name" "'$value' must not contain a '..' path component."
    return 1
  fi
  if ! resolve_physical "$base/$value"; then
    input_error "$name" "'$value' cannot be resolved (a symbolic link loop?)."
    return 1
  fi
  if ! path_is_inside "$RESOLVED_PATH" "$WORKSPACE_PHYSICAL"; then
    input_error "$name" "'$value' resolves to $RESOLVED_PATH, outside the workspace (through a symbolic link)."
    return 1
  fi
  return 0
}

# validate_version <value>: the v2 version rule.
validate_version() {
  local v="$1"
  local line_re='^0\.4\.(0|[1-9][0-9]*)(-[0-9A-Za-z][0-9A-Za-z.-]*)?$'
  local semver_re='^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$'
  local older_re='^0\.[0-3]\.' line_prefix_re='^0\.4\.' v_prefix_re='^[vV][0-9]'
  if [ "$v" = latest ] || [[ "$v" =~ $line_re ]]; then
    return 0
  fi
  if [ -z "$v" ]; then
    input_error version "is empty. Use 'latest' or an exact sbom-tools 0.4.x version such as '0.4.0'."
  elif [[ "$v" =~ $v_prefix_re ]]; then
    input_error version "'$v': write the version without the leading 'v', for example '${v#[vV]}'."
  elif ! [[ "$v" =~ $semver_re ]]; then
    input_error version "'$v' is not a version. Use 'latest' or an exact sbom-tools 0.4.x version such as '0.4.0'."
  elif [[ "$v" =~ $line_prefix_re ]]; then
    input_error version "'$v' is not a valid sbom-tools 0.4.x version. Use one such as '0.4.0'."
  elif [[ "$v" =~ $older_re ]]; then
    input_error version "sbom-tools $v is not supported by sbom-tools-action v2, which runs the sbom-tools 0.4.x line. Use sbom-tool/sbom-tools-action@v1 for sbom-tools 0.3.x and earlier."
  else
    input_error version "sbom-tools $v is not supported by sbom-tools-action v2, which runs the sbom-tools 0.4.x line only. A newer sbom-tools release line needs the major version of this Action made for it."
  fi
  return 1
}

# True for versions of the line this major supports (0.4.x, pre-releases too).
version_in_line() {
  local re='^0\.4\.[0-9]+(-[0-9A-Za-z.-]+)?$'
  [[ "$1" =~ $re ]]
}

# validate_inputs <setup|run>: every check for that step. setup.sh runs the
# run checks too, so a bad input fails before anything is downloaded.
validate_inputs() {
  VALIDATION_ERRORS=0
  validate_command
  validate_bool fail-on-vuln "$IN_FAIL_ON_VULN"
  validate_bool fail-on-change "$IN_FAIL_ON_CHANGE"
  validate_bool fail-on-vex-gap "$IN_FAIL_ON_VEX_GAP"
  validate_bool fail-on-warning "$IN_FAIL_ON_WARNING"
  validate_bool require-applicable "$IN_REQUIRE_APPLICABLE"
  validate_bool enrich-vulns "$IN_ENRICH_VULNS"
  validate_bool sarif-include-passes "$IN_SARIF_INCLUDE_PASSES"
  validate_args
  local number_re='^[0-9]+(\.[0-9]+)?$'
  if [ -n "$IN_MIN_SCORE" ] && ! [[ "$IN_MIN_SCORE" =~ $number_re ]]; then
    input_error min-score "'$IN_MIN_SCORE' is not a number."
  fi
  validate_scalar output-format "$IN_OUTPUT_FORMAT"
  validate_scalar standard "$IN_STANDARD"
  validate_scalar profile "$IN_PROFILE"
  validate_scalar sarif-category "$IN_SARIF_CATEGORY"
  validate_scalar sarif-max-results "$IN_SARIF_MAX_RESULTS"
  validate_scalar as-of "$IN_AS_OF"
  validate_scalar cra-product-class "$IN_CRA_PRODUCT_CLASS"
  if validate_path working-directory "$IN_WORKING_DIRECTORY" "$WORKSPACE"; then
    local wd="$WORKSPACE/$IN_WORKING_DIRECTORY"
    if [ ! -d "$wd" ]; then
      input_error working-directory "'$IN_WORKING_DIRECTORY' is not a directory in the workspace."
    fi
    validate_path output-file "$IN_OUTPUT_FILE" "$wd"
    validate_path sarif-base "$IN_SARIF_BASE" "$wd"
    validate_path cra-sidecar "$IN_CRA_SIDECAR" "$wd"
  fi
  if [ "${1:-}" = setup ]; then
    case "$IN_VERIFY_PROVENANCE" in
      require | warn | off) ;;
      *) input_error verify-provenance "must be 'require', 'warn' or 'off', got '$IN_VERIFY_PROVENANCE'." ;;
    esac
    validate_scalar binary-path "$IN_BINARY_PATH"
    # binary-path replaces the download, so version is not used with it.
    [ -n "$IN_BINARY_PATH" ] || validate_version "$IN_VERSION"
  fi
  [ "$VALIDATION_ERRORS" -eq 0 ]
}

# ---------------------------------------------------------- version and install

# Read release tag names on stdin; set PICKED_VERSION to the newest 0.4.N.
pick_latest_supported() {
  local tag patch best=-1 re='^v0\.4\.(0|[1-9][0-9]{0,8})$'
  while IFS= read -r tag || [ -n "$tag" ]; do
    tag="${tag%$'\r'}"
    if [[ "$tag" =~ $re ]]; then
      patch="${BASH_REMATCH[1]}"
      [ "$patch" -gt "$best" ] && best="$patch"
    fi
  done
  [ "$best" -ge 0 ] || return 1
  PICKED_VERSION="0.4.$best"
}

# resolve_version <input>: sets RESOLVED_VERSION. An exact version is used as
# given; 'latest' is the newest published (not draft, not pre-release) 0.4.x.
resolve_version() {
  local tags
  if [ "$1" != latest ]; then
    RESOLVED_VERSION="$1"
    return 0
  fi
  if ! command -v gh >/dev/null 2>&1; then
    gha_annotate error 'sbom-tools-action: version' "Resolving 'latest' needs the GitHub CLI (gh), which is not installed. Pin an exact version such as '0.4.0'."
    return 1
  fi
  if ! tags=$(gh release list --repo "$SBOM_TOOLS_REPO" --exclude-drafts --exclude-pre-releases \
    --limit 100 --json tagName --jq '.[].tagName'); then
    gha_annotate error 'sbom-tools-action: version' "Could not list the sbom-tools releases to resolve 'latest'. Pin an exact version such as '0.4.0'."
    return 1
  fi
  if ! pick_latest_supported <<<"$tags"; then
    gha_annotate error 'sbom-tools-action: version' "No sbom-tools 0.4.x release is published yet, so 'latest' has nothing to resolve to. Pin an exact version, or use sbom-tool/sbom-tools-action@v1 for sbom-tools 0.3.x."
    return 1
  fi
  RESOLVED_VERSION="$PICKED_VERSION"
  echo "version 'latest' resolved to sbom-tools $RESOLVED_VERSION (newest 0.4.x release)"
}

# Sets PLATFORM_TARGET, PLATFORM_EXT and PLATFORM_EXE for this runner.
detect_platform() {
  case "${RUNNER_OS:-}-${RUNNER_ARCH:-}" in
    Linux-X64) PLATFORM_TARGET=linux-x86_64 PLATFORM_EXT=tar.gz ;;
    Linux-ARM64) PLATFORM_TARGET=linux-aarch64 PLATFORM_EXT=tar.gz ;;
    macOS-X64) PLATFORM_TARGET=macos-x86_64 PLATFORM_EXT=tar.gz ;;
    macOS-ARM64) PLATFORM_TARGET=macos-aarch64 PLATFORM_EXT=tar.gz ;;
    Windows-X64) PLATFORM_TARGET=windows-x86_64 PLATFORM_EXT=zip ;;
    *)
      gha_annotate error 'sbom-tools-action: unsupported platform' "No prebuilt sbom-tools for ${RUNNER_OS:-unknown}-${RUNNER_ARCH:-unknown}. Releases cover Linux and macOS on X64 and ARM64, and Windows on X64; elsewhere, build sbom-tools from source and pass its path as binary-path."
      return 1
      ;;
  esac
  PLATFORM_EXE=sbom-tools
  if on_windows; then PLATFORM_EXE=sbom-tools.exe; fi
}

# SHA-256 of a file, read on stdin so the tool never sees (or escapes) a path.
# Sets SHA256_RESULT.
sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    SHA256_RESULT=$(sha256sum <"$1" | awk '{print $1}')
  elif command -v shasum >/dev/null 2>&1; then
    SHA256_RESULT=$(shasum -a 256 <"$1" | awk '{print $1}')
  else
    return 2
  fi
}

# The hash checksums.sha256 lists for one file name (exact name match, text
# or binary mode). Sets CHECKSUM_RESULT.
checksum_for() {
  CHECKSUM_RESULT=$(awk -v f="$2" '{ sub(/\r$/, ""); n = $2; sub(/^\*/, "", n); if (n == f) { print $1; exit } }' "$1")
}

INSTALL_WORK_DIR=''

cleanup_install() {
  if [ -n "$INSTALL_WORK_DIR" ]; then
    rm -rf -- "$INSTALL_WORK_DIR"
    INSTALL_WORK_DIR=''
  fi
}

# verify_provenance <archive> <version> <mode>: check the archive's GitHub
# artifact attestation (SLSA build provenance) made by the sbom-tools release
# workflow for the v<version> tag on a GitHub-hosted runner. Sets SLSA_VERIFIED.
verify_provenance() {
  local archive="$1" version="$2" mode="$3" why=''
  SLSA_VERIFIED=false
  if [ "$mode" = off ]; then
    echo "Build provenance not checked (verify-provenance: off); the SHA-256 checksum was verified."
    return 0
  fi
  if ! command -v gh >/dev/null 2>&1; then
    why="the GitHub CLI (gh), which verifies build provenance, is not installed on this runner"
  else
    echo "::group::Verify build provenance of $archive"
    if gh attestation verify "$archive" \
      --repo "$SBOM_TOOLS_REPO" \
      --signer-workflow "$SBOM_TOOLS_SIGNER_WORKFLOW" \
      --source-ref "refs/tags/v$version" \
      --deny-self-hosted-runners; then
      SLSA_VERIFIED=true
    else
      why="gh attestation verify found no valid build provenance for $archive from the sbom-tools release workflow at tag v$version"
    fi
    echo '::endgroup::'
  fi
  if [ "$SLSA_VERIFIED" = true ]; then
    echo "Build provenance verified: $archive was built by $SBOM_TOOLS_SIGNER_WORKFLOW at refs/tags/v$version."
    return 0
  fi
  if [ "$mode" = require ]; then
    gha_annotate error 'sbom-tools-action: provenance not verified' "Not installing sbom-tools v$version: $why. The SHA-256 checksum matched, but verify-provenance is 'require'. Set verify-provenance to 'warn' to install on the checksum alone."
    return 1
  fi
  gha_annotate warning 'sbom-tools-action: provenance not verified' "$why. Installing on the SHA-256 checksum alone (verify-provenance: warn)."
  return 0
}

# install_release <version> <provenance-mode>: download this runner's release
# archive and checksums.sha256, check the SHA-256 and the build provenance,
# extract, and install into the tool cache. Sets INSTALLED_BINARY and
# SLSA_VERIFIED; adds the install directory to GITHUB_PATH.
install_release() {
  local version="$1" mode="$2" archive base_url expected here install_dir
  detect_platform || return 1
  archive="sbom-tools-${PLATFORM_TARGET}.${PLATFORM_EXT}"
  base_url="https://github.com/${SBOM_TOOLS_REPO}/releases/download/v${version}"
  if ! INSTALL_WORK_DIR=$(mktemp -d "$TEMP_ROOT/sbom-tools-install.XXXXXX"); then
    gha_annotate error 'sbom-tools-action: install' "Could not create a temporary directory under $TEMP_ROOT."
    return 1
  fi
  here=$PWD
  cd -- "$INSTALL_WORK_DIR" || return 1

  echo "::group::Download sbom-tools v$version ($PLATFORM_TARGET)"
  if ! curl -fsSL --proto '=https' --tlsv1.2 --retry 3 -o "$archive" "$base_url/$archive" ||
    ! curl -fsSL --proto '=https' --tlsv1.2 --retry 3 -o checksums.sha256 "$base_url/checksums.sha256"; then
    echo '::endgroup::'
    gha_annotate error 'sbom-tools-action: download failed' "Could not download $archive and checksums.sha256 from the sbom-tools v$version release. Check that https://github.com/$SBOM_TOOLS_REPO/releases/tag/v$version exists."
    cd -- "$here" || true
    return 1
  fi
  echo '::endgroup::'

  checksum_for checksums.sha256 "$archive"
  expected="$CHECKSUM_RESULT"
  if [ -z "$expected" ]; then
    gha_annotate error 'sbom-tools-action: checksum' "checksums.sha256 of sbom-tools v$version has no entry for $archive."
    cd -- "$here" || true
    return 1
  fi
  local hash_re='^[0-9a-f]{64}$'
  if ! [[ "$expected" =~ $hash_re ]]; then
    gha_annotate error 'sbom-tools-action: checksum' "checksums.sha256 of sbom-tools v$version is malformed: the entry for $archive is not a SHA-256 hash."
    cd -- "$here" || true
    return 1
  fi
  if ! sha256_of "$archive"; then
    gha_annotate error 'sbom-tools-action: checksum' "No SHA-256 tool (sha256sum or shasum) on this runner; cannot verify $archive."
    cd -- "$here" || true
    return 1
  fi
  if [ "$SHA256_RESULT" != "$expected" ]; then
    gha_annotate error 'sbom-tools-action: checksum mismatch' "$archive does not match checksums.sha256 of sbom-tools v$version (expected $expected, got $SHA256_RESULT). Not installing it."
    cd -- "$here" || true
    return 1
  fi
  echo "SHA-256 verified: $archive $SHA256_RESULT"

  if ! verify_provenance "$archive" "$version" "$mode"; then
    cd -- "$here" || true
    return 1
  fi

  # Extract into a subdirectory of the work dir, so a hostile archive cannot
  # write anywhere else (tar and unzip refuse '..' members).
  mkdir extract || return 1
  case "$PLATFORM_EXT" in
    tar.gz) tar -xzf "$archive" -C extract ;;
    zip) unzip -q "$archive" -d extract ;;
  esac || {
    gha_annotate error 'sbom-tools-action: install' "Could not extract $archive."
    cd -- "$here" || true
    return 1
  }
  if [ -L "extract/$PLATFORM_EXE" ]; then
    gha_annotate error 'sbom-tools-action: install' "$PLATFORM_EXE in $archive is a symbolic link; refusing to install it."
    cd -- "$here" || true
    return 1
  fi
  if [ ! -f "extract/$PLATFORM_EXE" ]; then
    gha_annotate error 'sbom-tools-action: install' "$archive does not contain $PLATFORM_EXE."
    cd -- "$here" || true
    return 1
  fi

  install_dir="$TOOL_CACHE/sbom-tools/$version"
  if ! mkdir -p -- "$install_dir" || ! mv -f -- "extract/$PLATFORM_EXE" "$install_dir/$PLATFORM_EXE"; then
    gha_annotate error 'sbom-tools-action: install' "Could not install sbom-tools into $install_dir."
    cd -- "$here" || true
    return 1
  fi
  on_windows || chmod +x "$install_dir/$PLATFORM_EXE"
  cd -- "$here" || return 1

  INSTALLED_BINARY="$install_dir/$PLATFORM_EXE"
  if [ -n "${GITHUB_PATH:-}" ]; then
    native_path "$install_dir"
    printf '%s\n' "$NATIVE_PATH" >>"$GITHUB_PATH"
  fi
  echo "Installed sbom-tools v$version to $install_dir"
}

# adopt_binary <path>: use an existing binary instead of a release (the
# binary-path input). Relative paths are taken from the workspace root. Sets
# INSTALLED_BINARY and INSTALLED_VERSION (from `--version`, or 'unknown').
adopt_binary() {
  local given="$1" path out first re='^sbom-tools ([0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?)'
  posix_path "$given"
  path="$POSIX_PATH"
  case "$path" in
    /*) ;;
    *) path="$WORKSPACE/$path" ;;
  esac
  if [ ! -f "$path" ]; then
    gha_annotate error "sbom-tools-action: invalid input 'binary-path'" "'$given' is not a file."
    return 1
  fi
  if [ ! -x "$path" ]; then
    gha_annotate error "sbom-tools-action: invalid input 'binary-path'" "'$given' is not executable."
    return 1
  fi
  out=$("$path" --version 2>/dev/null) || true
  first="${out%%$'\n'*}"
  INSTALLED_VERSION=unknown
  if [[ "$first" =~ $re ]]; then INSTALLED_VERSION="${BASH_REMATCH[1]}"; fi
  if ! version_in_line "$INSTALLED_VERSION"; then
    gha_annotate warning 'sbom-tools-action: binary-path' "binary-path reports sbom-tools $INSTALLED_VERSION. sbom-tools-action v2 is built for the exit codes and flags of sbom-tools 0.4.x."
  fi
  INSTALLED_BINARY="$path"
  echo "Using sbom-tools $INSTALLED_VERSION from binary-path ($path); download, checksum and provenance checks skipped."
}

# ---------------------------------------------------------------------- run

# Build ARGV: the command, then the args words, then one flag per input that
# is set. Flags that take a value are written --flag=value, so a value can
# never be read as another flag. If args holds a literal --, the flags go in
# front of it.
build_argv() {
  local w inserted=false
  local -a flags=()
  [ "$IN_FAIL_ON_VULN" = true ] && flags+=(--fail-on-vuln)
  [ "$IN_FAIL_ON_CHANGE" = true ] && flags+=(--fail-on-change)
  [ "$IN_FAIL_ON_VEX_GAP" = true ] && flags+=(--fail-on-vex-gap)
  [ "$IN_FAIL_ON_WARNING" = true ] && flags+=(--fail-on-warning)
  [ "$IN_REQUIRE_APPLICABLE" = true ] && flags+=(--require-applicable)
  [ "$IN_ENRICH_VULNS" = true ] && flags+=(--enrich-vulns)
  [ "$IN_SARIF_INCLUDE_PASSES" = true ] && flags+=(--sarif-include-passes)
  [ -n "$IN_OUTPUT_FORMAT" ] && flags+=("--output=$IN_OUTPUT_FORMAT")
  [ -n "$IN_OUTPUT_FILE" ] && flags+=("--output-file=$IN_OUTPUT_FILE")
  [ -n "$IN_MIN_SCORE" ] && flags+=("--min-score=$IN_MIN_SCORE")
  [ -n "$IN_STANDARD" ] && flags+=("--standard=$IN_STANDARD")
  [ -n "$IN_PROFILE" ] && flags+=("--profile=$IN_PROFILE")
  [ -n "$IN_SARIF_CATEGORY" ] && flags+=("--sarif-category=$IN_SARIF_CATEGORY")
  [ -n "$IN_SARIF_BASE" ] && flags+=("--sarif-base=$IN_SARIF_BASE")
  [ -n "$IN_SARIF_MAX_RESULTS" ] && flags+=("--sarif-max-results=$IN_SARIF_MAX_RESULTS")
  [ -n "$IN_AS_OF" ] && flags+=("--as-of=$IN_AS_OF")
  [ -n "$IN_CRA_SIDECAR" ] && flags+=("--cra-sidecar=$IN_CRA_SIDECAR")
  [ -n "$IN_CRA_PRODUCT_CLASS" ] && flags+=("--cra-product-class=$IN_CRA_PRODUCT_CLASS")

  split_args "$IN_ARGS"
  ARGV=("$IN_COMMAND")
  for w in ${ARGS_WORDS[@]+"${ARGS_WORDS[@]}"}; do
    if [ "$w" = -- ] && [ "$inserted" = false ]; then
      ARGV+=(${flags[@]+"${flags[@]}"})
      inserted=true
    fi
    ARGV+=("$w")
  done
  if [ "$inserted" = false ]; then
    ARGV+=(${flags[@]+"${flags[@]}"})
  fi
}

# The name used in annotations: the command, plus the subcommand for the
# command groups (vex status, verify hash, ...).
command_label() {
  COMMAND_LABEL="$IN_COMMAND"
  case "$IN_COMMAND" in
    vex | verify)
      split_args "$IN_ARGS"
      if [ "${#ARGS_WORDS[@]}" -gt 0 ]; then
        case "${ARGS_WORDS[0]}" in
          -*) ;;
          *) COMMAND_LABEL="$IN_COMMAND ${ARGS_WORDS[0]}" ;;
        esac
      fi
      ;;
  esac
}

# exit_meaning <command> <code>: what a gate exit means for that command, from
# its --help EXIT CODES. Sets EXIT_MEANING.
exit_meaning() {
  case "$1:$2" in
    diff:1) EXIT_MEANING='SBOM changes detected (--fail-on-change)' ;;
    diff:2) EXIT_MEANING='New vulnerabilities introduced (--fail-on-vuln)' ;;
    diff:4) EXIT_MEANING='Introduced vulnerabilities lack VEX statements (--fail-on-vex-gap)' ;;
    diff:6) EXIT_MEANING="An introduced vulnerability is in CISA's Known Exploited Vulnerabilities catalog (--fail-on-kev)" ;;
    diff:7) EXIT_MEANING='An ML performance metric regressed (--fail-on-ml-regression)' ;;
    validate:1) EXIT_MEANING='Compliance errors found: the SBOM is non-compliant, or a selected standard does not apply to it under --require-applicable' ;;
    validate:2) EXIT_MEANING='Compliance warnings found (--fail-on-warning)' ;;
    quality:1) EXIT_MEANING='Quality score below --min-score, or the SBOM is non-compliant under --fail-on-noncompliant' ;;
    view:2) EXIT_MEANING='The SBOM contains vulnerabilities (--fail-on-vuln)' ;;
    query:1) EXIT_MEANING='No components matched the query' ;;
    vex:1) EXIT_MEANING='Actionable vulnerabilities remain (--actionable-only)' ;;
    verify:1) EXIT_MEANING='Verification failed: a hash mismatch, weak or missing component hashes, mismatched model weights, or a receipt that does not pass' ;;
    license-check:5) EXIT_MEANING='License policy violations found' ;;
    *:1) EXIT_MEANING='Gate failed' ;;
    *:2) EXIT_MEANING='Vulnerabilities found (--fail-on-vuln) or compliance warnings (--fail-on-warning)' ;;
    *:4) EXIT_MEANING='VEX gaps found (--fail-on-vex-gap)' ;;
    *:5) EXIT_MEANING='License policy violations found' ;;
    *:6) EXIT_MEANING="Actively exploited (CISA KEV) vulnerability introduced (--fail-on-kev)" ;;
    *:7) EXIT_MEANING='ML performance metric regressed (--fail-on-ml-regression)' ;;
    *) EXIT_MEANING="Exit $2" ;;
  esac
}

# The first error line sbom-tools printed (clap's "error: ..." or anyhow's
# "Error: ..."), without the prefix. Sets ERROR_LINE.
first_error_line() {
  local esc=$'\033'
  ERROR_LINE=''
  [ -f "$1" ] || return 0
  ERROR_LINE=$(sed "s/${esc}\[[0-9;]*[A-Za-z]//g" "$1" | grep -m1 -E '^(error|Error): ') || ERROR_LINE=''
  ERROR_LINE="${ERROR_LINE#error: }"
  ERROR_LINE="${ERROR_LINE#Error: }"
  if [ "${#ERROR_LINE}" -gt 500 ]; then ERROR_LINE="${ERROR_LINE:0:500}..."; fi
}

# run_cli <stderr-log> <command...>: run it with stdout untouched and stderr
# copied to the log, and return its exit code.
run_cli() {
  local log="$1" status
  shift
  { "$@" 2>&1 1>&3 3>&- | tee "$log" 1>&2 3>&-; status=${PIPESTATUS[0]}; } 3>&1
  return "$status"
}

# report_exit <status> <stderr-log>: the log line or annotation for an exit.
report_exit() {
  local status="$1" title
  command_label
  title="sbom-tools $COMMAND_LABEL"
  case "$status" in
    0)
      echo "$title passed (exit 0)."
      ;;
    3)
      first_error_line "$2"
      gha_annotate error "$title: configuration error" "Configuration error (exit 3): sbom-tools rejected its arguments or could not complete${ERROR_LINE:+: $ERROR_LINE}. Exit 3 is a usage or operational error, not a gate verdict; check the inputs, args and the log above."
      ;;
    1 | 2 | 4 | 5 | 6 | 7)
      exit_meaning "$IN_COMMAND" "$status"
      gha_annotate error "$title: gate failed" "$EXIT_MEANING (exit $status)."
      ;;
    *)
      gha_annotate error "$title: failed" "sbom-tools exited $status, which is not one of its documented exit codes; it may have crashed or been killed."
      ;;
  esac
}
