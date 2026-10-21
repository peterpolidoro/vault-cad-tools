"""Small REST reader based on the installation report; live qualification pending."""
from contextlib import contextmanager
import json
import os
from pathlib import Path
import tempfile
from urllib.error import HTTPError, URLError
from urllib.parse import quote, urlencode
from urllib.request import Request, build_opener, HTTPRedirectHandler, ProxyHandler

from .project import ExchangeError


class NoRedirect(HTTPRedirectHandler):
    # Do not forward authorization headers to a redirected endpoint.
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


class VaultClient:
    def __init__(self, base_url, token=None, timeout=30):
        self.base = base_url.rstrip("/") + "/"
        self.token = token
        self.timeout = timeout
        # Access the internal server directly, without ambient HTTP proxies.
        self.opener = build_opener(ProxyHandler({}), NoRedirect())

    def open(self, path, query=None, method="GET", body=None):
        if path.startswith("/") or ":" in path or ".." in path.split("/"):
            raise ExchangeError("Expected a relative API path")
        url = self.base + path
        if query:
            url += "?" + urlencode(query)
        headers = {"Accept": "application/json"}
        if self.token:
            headers["Authorization"] = "Bearer " + self.token
        data = None
        if body is not None:
            data = json.dumps(body).encode("utf-8")
            headers["Content-Type"] = "application/json"
        try:
            return self.opener.open(Request(url, data=data, headers=headers, method=method), timeout=self.timeout)
        except HTTPError as exc:
            # Do not echo response bodies; authentication errors may reflect inputs.
            code = exc.code
            exc.close()
            error = ExchangeError(f"Vault returned HTTP {code} for {method} {path}")
            error.status = code
            raise error from None
        except (URLError, TimeoutError) as exc:
            raise ExchangeError(f"Cannot reach Vault: {exc}") from None

    def json(self, path, **kwargs):
        with self.open(path, **kwargs) as response:
            data = response.read()
        if not data:
            return None
        try:
            return json.loads(data)
        except ValueError:
            raise ExchangeError("Vault returned invalid JSON") from None

    def download(self, path, destination):
        destination = Path(destination)
        destination.parent.mkdir(parents=True, exist_ok=True)
        if destination.exists() or destination.is_symlink():
            raise ExchangeError(f"Download destination already exists: {destination}")
        fd, tmp_name = tempfile.mkstemp(prefix=".vault-cad-download-", dir=destination.parent)
        try:
            with os.fdopen(fd, "wb") as output, self.open(path) as response:
                size = 0
                for chunk in iter(lambda: response.read(1024 * 1024), b""):
                    output.write(chunk)
                    size += len(chunk)
                expected = response.headers.get("Content-Length")
                if expected is not None and int(expected) != size:
                    raise ExchangeError("Incomplete Vault download")
            # Exclusive creation prevents concurrent downloads from overwriting.
            with destination.open("xb") as output, Path(tmp_name).open("rb") as source:
                import shutil
                try:
                    shutil.copyfileobj(source, output)
                except Exception:
                    output.close()
                    destination.unlink()
                    raise
        finally:
            Path(tmp_name).unlink(missing_ok=True)


def component(value):
    return quote(str(value), safe="")


@contextmanager
def session(client, vault_name, username=None, password=None):
    """Use an externally supplied token, or create and clean up a temporary session."""
    if client.token:
        yield client
        return
    if not username or password is None:
        raise ExchangeError("Set VAULT_CAD_TOKEN or supply --username for an interactive login")
    result = client.json("sessions", method="POST", body={"input": {
        "vault": vault_name, "userName": username, "password": password,
        "appCode": "vault-cad-tools"}})
    if not isinstance(result, dict) or not result.get("id") or not result.get("accessToken"):
        raise ExchangeError("Unexpected session response; compare the installed OpenAPI description")
    client.token = result["accessToken"]
    try:
        yield client
    finally:
        try:
            client.json("sessions/" + component(result["id"]), method="DELETE")
        except ExchangeError as exc:
            # Vault Professional Server 2025 (30.4) answers 501 Not Implemented to DELETE
            # /sessions/{id} although the served OpenAPI description lists it; the session
            # then expires server-side. Only unexpected failures deserve a warning.
            if getattr(exc, "status", None) not in (405, 501):
                import warnings
                warnings.warn("Could not close Vault session; it may remain active until timeout")
        client.token = None
