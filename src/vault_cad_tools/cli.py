import argparse
import getpass
import json
import os
from pathlib import Path
import sys

from .api import VaultClient, component, session
from .exchange import prepare_publication, verify_request
from .environment import inspect_environment
from .project import ExchangeError, Project, atomic_json, digest


def parser():
    p = argparse.ArgumentParser(description="Versioned STEP exchange; Windows conversion/upload adapters are pending")
    p.add_argument("--project", default=".", help="CAD project checkout containing vault-project.toml")
    p.add_argument("--username", help="Vault account name; password is prompted, or read from VAULT_CAD_PASSWORD")
    sub = p.add_subparsers(dest="command", required=True)
    sub.add_parser("doctor", help="Report Python/Git and Windows Autodesk installation evidence without network access")
    sub.add_parser("status", help="Check managed reference hashes without contacting Vault")
    probe = sub.add_parser("probe", help="Save unauthenticated server info and installed OpenAPI description")
    probe.add_argument("--output", required=True)
    search = sub.add_parser("search", help="Search file versions by text, one API page; raw pagination information is retained")
    search.add_argument("text")
    search.add_argument("--limit", type=int, default=50)
    search.add_argument("--cursor")
    for name in ("file", "uses", "job"):
        command = sub.add_parser(name, help="Read a specific file version, its dependencies, or a job")
        command.add_argument("id")
    download = sub.add_parser("download", help="Download an exact file version, without overwriting")
    download.add_argument("version_id")
    download.add_argument("--output", required=True)
    imp = sub.add_parser("import-step", help="Import a verified export and record its provenance")
    imp.add_argument("source")
    imp.add_argument("--receipt", required=True)
    imp.add_argument("--as", dest="relative", required=True, help="references/... relative path")
    publish = sub.add_parser("prepare-publish", help="Package a committed STEP for a future Windows uploader; does not upload")
    publish.add_argument("relative", help="step/... relative path")
    publish.add_argument("--vault-folder", required=True)
    publish.add_argument("--exchange", required=True)
    verify = sub.add_parser("verify-request", help="Validate a publication request without uploading")
    verify.add_argument("directory")
    plan = sub.add_parser("plan-publish", help="Dry-run plan for add_step_file: vault/folder/collision checks, journal; no upload")
    plan.add_argument("directory")
    plan.add_argument("--journal", required=True, help="Publication journal JSON (created if absent)")
    plan.add_argument("--catalog", help="Offline catalog snapshot JSON; without it the Vault REST API is read (GET only)")
    plan.add_argument("--exchange", help="Exchange root when the request is not under <exchange>/requests/")
    reconcile = sub.add_parser("reconcile-publish", help="Resolve an ambiguous upload by READ-ONLY inspection of the destination")
    reconcile.add_argument("directory")
    reconcile.add_argument("--journal", required=True)
    reconcile.add_argument("--catalog")
    reconcile.add_argument("--workdir", required=True)
    reconcile.add_argument("--acknowledge-no-file", action="store_true", help="Operator confirms nothing was created; permits one retry")
    record = sub.add_parser("record-publish", help="Verify a reported upload by exact-byte re-download and write results/<id>.json")
    record.add_argument("directory")
    record.add_argument("--journal", required=True)
    record.add_argument("--catalog")
    record.add_argument("--master-id", required=True)
    record.add_argument("--version-id", required=True)
    record.add_argument("--workdir", required=True)
    record.add_argument("--exchange")
    record.add_argument("--execution", help="JSON file with what the executor observed (executed_at, executed_by_host, comment_sent, folder_id, server_version_number, server_file_size, server_checksum)")
    snapshot = sub.add_parser("catalog-snapshot", help="Save a READ-ONLY catalog snapshot (vault identity, folders, files) for offline planning")
    snapshot.add_argument("--output", required=True)
    snapshot.add_argument("--folder", action="append", required=True, help="Vault folder path ($/...), repeatable")
    bom = sub.add_parser("bom-audit-summary", help="Join a native BOM audit, exporter snapshot and Vault discovery into reviewable facts (offline)")
    bom.add_argument("--audit", required=True, help="Directory written by windows/Audit-NativeBom.ps1")
    bom.add_argument("--snapshot", required=True, help="native-snapshot.json from Export-PartAssets.ps1")
    bom.add_argument("--joints", help="joint-audit.json with Linux candidate joints (optional)")
    bom.add_argument("--discovery", help="Directory written by windows/Discover-VaultAssociations.ps1 (optional)")
    bom.add_argument("--output", required=True)
    return p


PUBLICATION_COMMANDS = ("plan-publish", "reconcile-publish", "record-publish")


def run_publication(args, catalog):
    from .publication import Journal, plan_publication, reconcile_publication, record_result
    journal = Journal(args.journal)
    if args.command == "plan-publish":
        return plan_publication(args.directory, catalog, journal, exchange=args.exchange)
    if args.command == "reconcile-publish":
        return reconcile_publication(args.directory, catalog, journal, args.workdir, acknowledge_no_file=args.acknowledge_no_file)
    execution = None
    if getattr(args, "execution", None):
        from .project import read_json
        execution = read_json(args.execution)
    return record_result(args.directory, catalog, journal, {"master_id": args.master_id, "version_id": args.version_id},
                         args.workdir, exchange=args.exchange, execution=execution)


def execute(args):
    if args.command == "doctor":
        return inspect_environment()
    if args.command == "verify-request":
        request = verify_request(args.directory)
        return {"request_id": request["request_id"], "status": "valid_not_uploaded"}
    if args.command in PUBLICATION_COMMANDS and args.catalog:
        from .publication import StaticCatalog
        from .project import read_json
        return run_publication(args, StaticCatalog(read_json(args.catalog)))
    if args.command == "bom-audit-summary":
        from .bom_audit import summarize
        summary = summarize(args.audit, args.snapshot, args.output, joints_path=args.joints, discovery_dir=args.discovery)
        return {"output": args.output, "groups": len(summary["groups"]), "joint_categories": summary["joint_coverage_categories"],
                "coincident_pairs": summary["coincident_pairs"], "virtual_components": summary["virtual_components"],
                "native_parts_not_exported": summary["native_parts_not_exported"], "drawings_available": summary["drawings_available"]}
    project = Project(args.project)
    if args.command == "status":
        return project.status()
    if args.command == "import-step":
        return project.import_step(args.source, args.relative, args.receipt)
    if args.command == "prepare-publish":
        return prepare_publication(project, args.relative, args.vault_folder, args.exchange)
    client = VaultClient(project.vault["base_url"])
    if args.command == "probe":
        output = Path(args.output)
        if output.exists():
            raise ExchangeError("Choose a new probe output directory")
        # Fetch first, then create output; incomplete probes are never called complete.
        info = client.json("server-info")
        vaults = client.json("vaults")
        with client.open("openapi-spec.yml") as response:
            spec = response.read()
        output.mkdir(parents=True)
        atomic_json(output / "server-info.json", info)
        atomic_json(output / "vaults.json", vaults)
        (output / "openapi-spec.yml").write_bytes(spec)
        return {"output": str(output), "openapi_sha256": digest(output / "openapi-spec.yml")}
    client.token = os.environ.get("VAULT_CAD_TOKEN")
    username = args.username or os.environ.get("VAULT_CAD_USERNAME")
    password = None
    if client.base.startswith("http:"):
        print("Vault endpoint uses HTTP: credentials/tokens are not protected by TLS.", file=sys.stderr)
    if not client.token and username:
        password = os.environ.get("VAULT_CAD_PASSWORD")
        if password is None:
            password = getpass.getpass("Vault password: ")
    with session(client, project.vault["name"], username, password):
        prefix = "vaults/" + component(project.vault["id"]) + "/"
        if args.command == "search":
            if not 1 <= args.limit <= 1000:
                raise ExchangeError("--limit must be between 1 and 1000")
            query = {"q": args.text, "option[latestOnly]": "true", "limit": args.limit}
            if args.cursor:
                query["cursorState"] = args.cursor
            # Verified on Vault 2025 (30.4): the basic search endpoint `search-results` answered
            # HTTP 403 (Vault error 303, inadequate permissions) for an ordinary Active Directory
            # account, while the file-versions text query returned the same files. Results are
            # FileVersion objects with `id` (version), `file.id` (master) and `parentFolderId`.
            return client.json(prefix + "file-versions", query=query)
        if args.command == "job":
            return client.json(prefix + "jobs/" + component(args.id))
        if args.command in ("file", "uses"):
            path = prefix + "file-versions/" + component(args.id)
            if args.command == "uses":
                return client.json(path + "/uses", query={"option[recurse]": "true", "option[getLatestAssocs]": "false"})
            return client.json(path)
        if args.command == "download":
            client.download(prefix + "file-versions/" + component(args.version_id) + "/content", args.output)
            return {"output": args.output, "version_id": args.version_id, "sha256": digest(args.output)}
        if args.command in PUBLICATION_COMMANDS or args.command == "catalog-snapshot":
            # READ-ONLY: folder walk, folder contents and file-version downloads. No upload exists in this API version.
            from .publication import RestCatalog, write_catalog_snapshot
            catalog = RestCatalog(client, project.vault["id"])
            if args.command == "catalog-snapshot":
                output = Path(args.output)
                if output.exists():
                    raise ExchangeError("Choose a new snapshot output path")
                snapshot = write_catalog_snapshot(output, catalog, args.folder)
                return {"output": str(output), "folders": len(snapshot["folders"]), "missing_folders": snapshot["missing_folders"]}
            return run_publication(args, catalog)
    raise ExchangeError("Unknown command")


def main(argv=None):
    args = parser().parse_args(argv)
    try:
        result = execute(args)
        print(json.dumps(result, indent=2, sort_keys=True))
        if args.command == "doctor" and not result["portable_tools_ready"]:
            return 1
        if args.command == "status" and any(item["state"] != "clean" for item in result["references"]):
            return 1
        return 0
    except (ExchangeError, OSError) as exc:
        print(f"vault-cad: {exc}", file=sys.stderr)
        return 2
