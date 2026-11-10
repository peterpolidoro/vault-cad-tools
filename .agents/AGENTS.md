# Vault CAD tools guidance

This repository owns reusable Linux/Windows code. CAD geometry, server/project
configuration, and model provenance belong to project repositories.

The direction of the wider work and the layout of project repositories (where
STEP files and metadata go, and who writes which file) are kept in the sibling
`mechanical-cad` repository: `docs/direction.md` and `docs/layout-proposal.md`.
Read them before changing the exporter's output layout, the lock or the
exchange protocol. Work that spans repositories runs from an agent session
rooted there (Peter, 2026-11-10).

Read README.md, docs/exchange-protocol.md, and .agents/PLANS.md.
.agents/HISTORY.md and windows/HISTORY.md hold the finished checkpoints; read
them only to trace how something came about. On Linux use
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

.agents/PLANS.md holds the current state, the next work and the open items, and
nothing else. When a checkpoint is finished, move its record to
.agents/HISTORY.md. Do not write commit ids or "uncommitted" into tracked files:
Git knows, and the text is wrong as soon as Peter commits. A checkbox is a task;
a measurement or a decision is a sentence.
