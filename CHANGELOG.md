# Changelog

Each major version of this Action runs one sbom-tools release line: v1 runs
sbom-tools 0.3.x and earlier, v2 runs 0.4.x. Breaking changes come only with
a new major version, and are listed under its **Breaking changes**.

## v2.0.0 (unreleased)

Released with sbom-tools 0.4.0.

### Highlights

v2 runs sbom-tools 0.4.x and fails closed. Every non-zero sbom-tools exit
fails the step, with an annotation that says what the exit code means for the
command that ran, and the `exit-code` output is set either way, for soft gates
built on `continue-on-error`. The default `version` is an exact release
(`0.4.0`), `latest` stays on the 0.4 line, and every standard, profile and
SARIF option of sbom-tools 0.4.0 is available.

### Breaking changes

- **Failing gates fail the step.** v1 passed the step on exit codes 1, 2 and
  4 (compliance errors, new vulnerabilities, VEX gaps), printing only an
  annotation. For the old behaviour, set `continue-on-error: true` and read
  `exit-code`.
- **sbom-tools 0.4.x only.** `version` defaults to `0.4.0` instead of
  `latest`; `latest` resolves to the newest 0.4.x release; any version outside
  0.4.x is rejected, naming `sbom-tools-action@v1` for 0.3.x.
- **Exit 3 is a configuration error** (an sbom-tools usage or operational
  error, or the Action failing before sbom-tools runs). Exit 2 is always a
  gate.
- **`args` comes right after the command**, without the `--` v1 put in front
  of it, so it can hold flags and the `vex` and `verify` subcommands. It is
  split on all whitespace, including line breaks.
- **`standard` and `profile` are passed through** to sbom-tools, which
  validates them, instead of being checked against v1's lists.
- **`output-format` is passed as `--output`** and valued flags as
  `--flag=value`.
- **`verify-slsa` is removed** (deprecated in v1).
- **`fail-on-vex-gap` is documented for `diff` only**; sbom-tools' `vex`
  commands never took it.

### What's new

- Inputs `fail-on-warning`, `require-applicable`, `sarif-category`,
  `sarif-base`, `sarif-include-passes`, `sarif-max-results`, `as-of`,
  `cra-sidecar` and `cra-product-class`.
- Input `binary-path`: run an existing sbom-tools binary (one built from
  source, say) instead of downloading a release.
- Output `output-file`: the absolute path of the report, when one was
  written.
- Per-command exit annotations, quoting sbom-tools' error message for exit 3.
- Documentation of all 16 standards and 9 quality profiles, with their
  aliases.
- sbom-tools' output cannot issue workflow commands: the Action wraps it in
  `::stop-commands::`.
- Path inputs must stay inside the workspace after symbolic links are
  followed.
- The run logic lives in `scripts/`, with a test harness
  (`tests/run-tests.sh`) and CI on Linux, macOS and Windows.

### Bug fixes

- **Provenance verification works.** v1 passed the release's cosign signature
  bundle to `gh attestation verify --bundle`, which rejects it, and fell back
  to SLSA provenance whose only subject is the crate, so no install could pass
  v1.3.0's default `verify-provenance: require`. v2 verifies the archive's
  GitHub artifact attestation, pinned to the sbom-tools release workflow and
  tag, and no longer downloads `slsa-verifier`.
- `vex` and `verify` run (v1's `--` hid their subcommand from sbom-tools).
- A multi-line `args` is read in full (v1 read only its first line).
- `license-check` accepts `output-format` (it has no `-o`; `--output` works).
- `validate` exit 1 is reported as compliance errors, not as "SBOM changes
  detected".
- A path such as `sbom..v2.json` is no longer rejected as traversal; a `..`
  path component still is.
- The checksum entry is matched by exact file name.

### Upgrade notes

See [Migrating from v1](README.md#migrating-from-v1).

## v1.x

The v1 releases (v1.0.0 to v1.3.0) run sbom-tools 0.3.x and earlier; see the
[releases](https://github.com/sbom-tool/sbom-tools-action/releases).
