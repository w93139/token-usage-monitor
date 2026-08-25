# Contributing

Thanks for helping improve Token监测.

## Development setup

Requirements:

- Python 3.9 or newer
- macOS 13 or newer and Swift 5.8+ for the menu-bar application
- A local Codex installation for live account testing

Run the dependency-free Python tests:

```bash
python3 -m unittest discover -s scripts/tests -v
```

Build and verify the macOS application:

```bash
macos/TokenUsageMonitor/scripts/build_app.sh
codesign --verify --deep --strict "macos/TokenUsageMonitor/dist/Token监测.app"
```

## Pull requests

1. Keep collection local-first and never add prompt, response, credential, or email storage.
2. Add or update tests for behavior changes.
3. Keep API ingestion compatible with both OpenAI and OpenAI-compatible `usage` fields.
4. Run the Python tests and macOS release build before opening a pull request.
5. Explain user-visible changes and privacy implications in the pull request description.

Do not commit generated build directories, local databases, logs, credentials, or personal
conversation data.
