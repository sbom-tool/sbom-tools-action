#!/usr/bin/env bash
#
# sbom-tools-action, step 2 of 2: run sbom-tools with the arguments the
# inputs describe, and report how it exited.
#
# Any non-zero exit fails the step with sbom-tools' own exit code, annotated
# with what that code means for the command that ran. Outputs: exit-code
# (always) and output-file (the absolute path, when output-file was written).
#
# Inputs arrive as INPUT_* environment variables (see action.yml), and the
# binary to run as SBOM_TOOLS_BIN (setup.sh's binary output).

set -uo pipefail

# shellcheck source-path=SCRIPTDIR source=lib.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

OUT_EXIT_CODE=''
OUT_OUTPUT_FILE=''
RUN_TMP=''

# shellcheck disable=SC2317,SC2329 # called by the EXIT trap
finish() {
  local status=$?
  if [ -n "$RUN_TMP" ]; then rm -rf -- "$RUN_TMP"; fi
  # Exits before sbom-tools ran (bad inputs) report their own status: 3.
  [ -n "$OUT_EXIT_CODE" ] || OUT_EXIT_CODE="$status"
  gha_set_output exit-code "$OUT_EXIT_CODE"
  gha_set_output output-file "$OUT_OUTPUT_FILE"
}
trap 'finish' EXIT

main() {
  local bin status
  init_paths || exit 3
  load_inputs
  if ! validate_inputs run; then
    gha_annotate error 'sbom-tools-action: configuration error' "$VALIDATION_ERRORS input error(s); sbom-tools was not run."
    exit 3
  fi

  posix_path "${SBOM_TOOLS_BIN:-}"
  bin="$POSIX_PATH"
  if [ -z "$bin" ]; then
    gha_annotate error 'sbom-tools-action: internal error' 'No sbom-tools binary was set up (SBOM_TOOLS_BIN is empty).'
    exit 3
  fi
  case "$bin" in
    /*) ;;
    *) bin="$PWD/$bin" ;;
  esac

  if ! cd -- "$WORKSPACE/$IN_WORKING_DIRECTORY" 2>/dev/null; then
    gha_annotate error "sbom-tools-action: invalid input 'working-directory'" "'$IN_WORKING_DIRECTORY' is not a directory in the workspace."
    exit 3
  fi

  build_argv
  printf 'Running: sbom-tools'
  printf ' %q' "${ARGV[@]}"
  printf '\n'

  if ! RUN_TMP=$(mktemp -d "$TEMP_ROOT/sbom-tools-run.XXXXXX"); then
    gha_annotate error 'sbom-tools-action: run' "Could not create a temporary directory under $TEMP_ROOT."
    exit 3
  fi

  # sbom-tools prints text from the SBOM; nothing it prints may act as a
  # workflow command.
  new_stop_token
  printf '::stop-commands::%s\n' "$STOP_TOKEN"
  run_cli "$RUN_TMP/stderr.log" "$bin" "${ARGV[@]}"
  status=$?
  printf '::%s::\n' "$STOP_TOKEN"

  OUT_EXIT_CODE="$status"
  report_exit "$status" "$RUN_TMP/stderr.log"

  # A gate exit (and 0) means the report was produced; exit 3 and crashes
  # promise nothing, so a file left from an earlier step is not reported.
  if [ -n "$IN_OUTPUT_FILE" ]; then
    case "$status" in
      0 | 1 | 2 | 4 | 5 | 6 | 7)
        if [ -f "$IN_OUTPUT_FILE" ]; then
          native_path "$PWD/${IN_OUTPUT_FILE#./}"
          OUT_OUTPUT_FILE="$NATIVE_PATH"
        fi
        ;;
    esac
  fi
  exit "$status"
}

main "$@"
