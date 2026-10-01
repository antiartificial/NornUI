# Release qualification

Official macOS release qualification runs only for the exact current commit on
protected `main`. The manual **NornUI release qualification** workflow builds a
universal Release archive, signs it with Developer ID Application, submits it
to Apple notarization, staples the accepted ticket, and requires Gatekeeper to
accept the app. It verifies that the executable contains exactly the `arm64`
and `x86_64` architectures, then retains the qualified zip and its
`SHA256SUMS` manifest as a seven-day workflow artifact. It does not create a
GitHub Release or install the app.

Configure a protected `release-qualification` environment with required
reviewers. Add the `APPLE_DEVELOPMENT_TEAM` environment variable and these
environment secrets:

- `DEVELOPER_ID_APPLICATION_P12_BASE64`
- `DEVELOPER_ID_APPLICATION_P12_PASSWORD`
- `APPLE_API_KEY_P8_BASE64`
- `APPLE_API_KEY_ID`
- `APPLE_API_ISSUER_ID`

The certificate secret must contain a base64-encoded Developer ID Application
certificate and private key in PKCS #12 format. The API key secrets must name a
base64-encoded App Store Connect API private key and its key and issuer IDs.

After the intended change is merged, copy the full 40-character `main` SHA and
dispatch the workflow with that exact value. The first job rejects a branch,
tag, pull-request head, abbreviated SHA, ancestor, or stale `main` revision
before the protected environment and signing secrets are available. The
signing job fetches and checks `origin/main` again after environment approval,
so a candidate that became stale while waiting cannot be signed. Approval
therefore applies to one visible protected-main candidate. A successful run is
qualification evidence for the retained artifact, not evidence of publication
or installation.
