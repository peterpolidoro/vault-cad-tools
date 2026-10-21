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
    search = sub.add_parser("search", help="Search one API page; raw pagination information is retained")
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
    return p


def execute(args):
    if args.command == "doctor":
        return inspect_environment()
    if args.command == "verify-request":
        request = verify_request(args.directory)
        return {"request_id": request["request_id"], "status": "valid_not_uploaded"}
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
            return client.json(prefix + "search-results", query=query)
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
