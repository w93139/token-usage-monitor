# Security Policy

## Supported version

Security fixes are applied to the latest published release.

## Reporting a vulnerability

Please use GitHub's private vulnerability reporting feature for this repository. Do not open a
public Issue containing API keys, account identifiers, local database contents, conversation names,
or exploit details.

Include the affected version, reproduction steps, expected impact, and a minimal redacted example.
You should receive an initial response within seven days.

## Security boundaries

- The ingestion server binds only to `127.0.0.1`.
- Browser cross-origin preflight requests are rejected.
- Prompt bodies, response bodies, API keys, and account email addresses are not accepted or stored.
- Update checks read the public GitHub Releases feed and never install an update silently.
- Release downloads are currently ad-hoc signed and not Apple-notarized.
