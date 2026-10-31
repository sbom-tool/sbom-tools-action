# Changelog

Each major version of this Action runs one sbom-tools release line: v1 runs
sbom-tools 0.3.x and earlier, and v2 runs 0.4.x.

## v1.4.0 (unreleased)

### Changes

- **`version: latest` stays on sbom-tools 0.3.x.** It now resolves to the
  newest 0.3.x release instead of the newest release overall, because
  sbom-tools 0.4.0 changes exit codes and JSON output. An explicit version of
  0.4.0 or later still installs, with a warning pointing at
  sbom-tools-action@v2.

### Bug fixes

- **Provenance verification works.** v1.3.0 passed the release's cosign
  signature bundle to `gh attestation verify --bundle`, which rejects it, and
  fell back to SLSA provenance whose only subject is the crate, so with the
  default `verify-provenance: require` no install could succeed. The Action
  now verifies the archive's GitHub artifact attestation, pinned to the
  sbom-tools release workflow (`publish-crates.yml`), the release tag and a
  GitHub-hosted runner, and no longer downloads `slsa-verifier`. The
  `require`, `warn` and `off` modes, and the deprecated `verify-slsa`, behave
  as before.

## v1.3.0 and earlier

See the [releases](https://github.com/sbom-tool/sbom-tools-action/releases).
