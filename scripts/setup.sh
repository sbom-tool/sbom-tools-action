#!/usr/bin/env bash
#
# sbom-tools-action, step 1 of 2: validate every input, then install
# sbom-tools: download the release for this runner and check its SHA-256 and
# build provenance, or adopt the binary given as binary-path.
#
# Inputs arrive as INPUT_* environment variables (see action.yml).
# Outputs: version, slsa-verified, binary; and exit-code=3 when this step
# fails, so the Action's exit-code output is set however it ends.

set -uo pipefail

# shellcheck source-path=SCRIPTDIR source=lib.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

OUT_VERSION=''
OUT_SLSA_VERIFIED=false
OUT_BINARY=''

# shellcheck disable=SC2317,SC2329 # called by the EXIT trap
finish() {
  local status=$?
  cleanup_install
  gha_set_output version "$OUT_VERSION"
  gha_set_output slsa-verified "$OUT_SLSA_VERIFIED"
  gha_set_output binary "$OUT_BINARY"
  if [ "$status" -ne 0 ]; then
    gha_set_output exit-code 3
  fi
}
trap 'finish' EXIT

main() {
  init_paths || exit 3
  load_inputs
  if ! validate_inputs setup; then
    gha_annotate error 'sbom-tools-action: configuration error' "$VALIDATION_ERRORS input error(s); sbom-tools was not installed or run."
    exit 3
  fi

  if [ -n "$IN_BINARY_PATH" ]; then
    adopt_binary "$IN_BINARY_PATH" || exit 3
    OUT_SLSA_VERIFIED=false
  else
    resolve_version "$IN_VERSION" || exit 3
    install_release "$RESOLVED_VERSION" "$IN_VERIFY_PROVENANCE" || exit 3
    INSTALLED_VERSION="$RESOLVED_VERSION"
    OUT_SLSA_VERIFIED="$SLSA_VERIFIED"
  fi
  OUT_VERSION="$INSTALLED_VERSION"
  OUT_BINARY="$INSTALLED_BINARY"
}

main "$@"
