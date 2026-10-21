# Vault CAD tools guidance

This repository owns reusable Linux/Windows code. CAD geometry, server/project
configuration, and model provenance belong to project repositories.

Read README.md, docs/exchange-protocol.md, and .agents/PLANS.md. On Linux use
`guix shell --pure -m manifest.scm -- python3 -m unittest discover -s tests -v`.
On Windows use `pixi install --locked`, `pixi run --locked doctor`, and
`pixi run --locked test`. Commit manifest and lock updates together; do not
silently re-resolve dependencies. Keep the Python core portable.
Autodesk SDK binaries and installed applications are external dependencies.

Before changing a wire request, inspect the actual served OpenAPI schema and
captured successful job parameters. Avoid guessing built-in job parameters.
Keep installed-capability evidence distinct from tested end-to-end behavior.

Never log passwords/tokens or copy them into shared files. Use fixed operation
types and validated paths/checksums for exchange requests. Do not execute code
supplied in request files. Windows publication must use explicit destinations,
new-file collision detection, idempotency, and version conflict checks for updates.

Use separate working trees per host/agent. Share request/result artifacts or
commits, not a simultaneously edited worktree. Leave commits and pushes to the
user unless explicitly requested. Do not modify the server or global Vault
settings as a side effect of a test.

Test metadata consistency, path containment, modified-reference protection,
publication payload integrity, session cleanup, and failed transfer behavior.
Geometry and Autodesk integration require separate real-software validation.
