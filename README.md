# sbom-tools GitHub Action

Install and run [sbom-tools](https://github.com/sbom-tool/sbom-tools) in your GitHub Actions workflows for semantic SBOM diff, validation, and quality scoring.

Downloads pre-built binaries with SHA-256 checksum verification and optional [SLSA](https://slsa.dev/) provenance verification. Supports Linux (x86_64, ARM64), macOS (x86_64, ARM64), and Windows (x86_64).

## Quick start

```yaml
- uses: sbom-tool/sbom-tools-action@v1
  with:
    command: diff
    args: old.json new.json
    fail-on-vuln: true
    enrich-vulns: true
    output-format: sarif
    output-file: results.sarif
```

## Inputs

| Input | Description | Default |
|-------|-------------|---------|
| `version` | sbom-tools version (`"0.1.14"` or `"latest"`) | `latest` |
| `command` | Command to run: `diff`, `validate`, `quality`, `view`, `query` | *required* |
| `args` | Arguments to pass to the command | `""` |
| `fail-on-vuln` | Exit non-zero on new vulnerabilities (diff) | `false` |
| `fail-on-change` | Exit non-zero on any SBOM changes (diff) | `false` |
| `fail-on-vex-gap` | Exit non-zero on VEX coverage gaps (diff) | `false` |
| `enrich-vulns` | Enrich with OSV/KEV vulnerability data | `false` |
| `output-format` | Output format: `json`, `sarif`, `markdown`, `summary`, `table`, `csv`, `html` | `""` |
| `output-file` | Write output to file | `""` |
| `min-score` | Minimum quality score threshold (quality) | `""` |
| `standard` | Compliance standard(s): `ntia`, `cra`, `fda`, `ssdf`, `eo14028` | `""` |
| `profile` | Quality profile: `minimal`, `standard`, `security`, `comprehensive`, `cra` | `""` |
| `working-directory` | Working directory | `.` |
| `verify-slsa` | Verify SLSA provenance of downloaded binary | `true` |

## Outputs

| Output | Description |
|--------|-------------|
| `exit-code` | Exit code from sbom-tools (`0`=success, `1`=changes, `2`=vulns, `4`=vex-gaps) |
| `version` | Installed sbom-tools version |
| `slsa-verified` | Whether SLSA provenance was successfully verified (`true`/`false`) |

## Security

This action implements multiple layers of binary verification:

1. **SHA-256 checksum** (always) -- verifies the downloaded archive matches the checksum published alongside the release. The checksum is compared by hash value only, not by filename (preventing filename-based attacks in checksum files).

2. **SLSA provenance** (enabled by default) -- downloads the [SLSA Level 3](https://slsa.dev/spec/v1.0/levels) provenance attestation from the release and verifies it using [slsa-verifier](https://github.com/slsa-framework/slsa-verifier). This cryptographically proves the binary was built by the sbom-tools CI pipeline from the expected source commit.

3. **Input validation** -- all inputs are validated against strict whitelists or regex patterns before use. Shell metacharacters are rejected.

4. **No expression injection** -- user inputs are never interpolated via `${{ }}` in `run:` blocks. All values flow through environment variables exclusively.

### SLSA verification behavior

| Scenario | Result |
|----------|--------|
| Provenance found + verifies | `slsa-verified=true` |
| Provenance found + fails verification | Warning, continues (SHA-256 was verified) |
| No provenance in release | Warning, continues (SHA-256 was verified) |
| `verify-slsa: false` | Skipped entirely |

To require SLSA verification (fail if not verified):

```yaml
- uses: sbom-tool/sbom-tools-action@v1
  id: sbom
  with:
    command: quality
    args: sbom.json

- if: steps.sbom.outputs.slsa-verified != 'true'
  run: |
    echo "::error::SLSA provenance verification failed"
    exit 1
```

## Examples

### SBOM diff with vulnerability gating

```yaml
name: SBOM Check

on:
  pull_request:
    paths: ['sbom.json']

jobs:
  sbom-diff:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 2

      - name: Get previous SBOM
        run: git show HEAD~1:sbom.json > /tmp/old-sbom.json

      - name: Diff SBOM
        uses: sbom-tool/sbom-tools-action@v1
        with:
          command: diff
          args: /tmp/old-sbom.json sbom.json
          fail-on-vuln: true
          enrich-vulns: true
          output-format: sarif
          output-file: results.sarif

      - name: Upload SARIF
        if: always()
        uses: github/codeql-action/upload-sarif@v3
        with:
          sarif_file: results.sarif
```

### Quality scoring

```yaml
- uses: sbom-tool/sbom-tools-action@v1
  with:
    command: quality
    args: sbom.json
    profile: security
    min-score: '80'
```

### CRA compliance validation

```yaml
- uses: sbom-tool/sbom-tools-action@v1
  with:
    command: validate
    args: sbom.json
    standard: cra
    output-format: sarif
    output-file: compliance.sarif
```

### VEX coverage gating

```yaml
- uses: sbom-tool/sbom-tools-action@v1
  with:
    command: diff
    args: old.json new.json
    fail-on-vex-gap: true
    enrich-vulns: true
```

### Pin a specific version

```yaml
- uses: sbom-tool/sbom-tools-action@v1
  with:
    version: '0.1.14'
    command: quality
    args: sbom.json
```

## Exit codes

The action maps sbom-tools exit codes to GitHub annotations:

| Code | Meaning | Annotation |
|------|---------|------------|
| `0` | Success | None |
| `1` | Changes detected (`--fail-on-change`) | Warning |
| `2` | New vulnerabilities (`--fail-on-vuln`) | Error |
| `4` | VEX gaps found (`--fail-on-vex-gap`) | Error |

Exit codes 1, 2, and 4 are captured in the `exit-code` output but do **not** fail the step, so you can use conditional logic:

```yaml
- uses: sbom-tool/sbom-tools-action@v1
  id: sbom
  with:
    command: diff
    args: old.json new.json
    fail-on-vuln: true

- if: steps.sbom.outputs.exit-code == '2'
  run: echo "New vulnerabilities found!"
```

## License

MIT
