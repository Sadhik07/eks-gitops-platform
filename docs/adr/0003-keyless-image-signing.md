# ADR 0003: Keyless image signing with Sigstore, enforced by Kyverno

- Status: accepted
- Date: 2026-10

## Context

Scanning an image in CI does not guarantee that the scanned image is what runs
in the cluster. Someone with ECR push rights could push a different image under
an expected name.

## Decision

- CI signs each image digest with **cosign keyless** signing. The signature
  binds the digest to the GitHub Actions workflow identity
  (`https://github.com/<owner>/<repo>/.github/workflows/...`) and is recorded in
  the public Rekor transparency log.
- An SBOM (SPDX) is attached as a signed attestation.
- A Kyverno `verifyImages` policy admits our images only when that identity
  signed them, and rewrites tags to the verified digest.
- The `promote` workflow re-verifies the signature before opening a
  promotion PR.

## Alternatives considered

- **Key-based cosign with KMS**: works offline, but adds key management and
  rotation. Keyless removes the key entirely.
- **ECR enhanced scanning only**: detects vulnerabilities but proves nothing
  about provenance.

## Consequences

- Images pushed by hand, or by another repository, are rejected at admission.
- Kyverno needs ECR read access (a Pod Identity role in Terraform).
- Admission depends on Rekor availability. Kyverno's webhook timeout is set to
  30s; an air-gapped setup would switch to key-based signing.
