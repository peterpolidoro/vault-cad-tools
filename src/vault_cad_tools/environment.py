"""Report portable dependencies and Windows installation evidence without login."""
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys


def inspect_environment():
    git = shutil.which("git")
    git_version = None
    if git:
        try:
            result = subprocess.run([git, "--version"], capture_output=True, text=True, timeout=10)
            if result.returncode == 0:
                git_version = result.stdout.strip()
        except (OSError, subprocess.TimeoutExpired):
            pass
    report = {
        "platform": platform.system(),
        "python": {"version": platform.python_version(), "executable": sys.executable},
        "git": {"executable": git, "version": git_version},
        "pixi_environment": os.environ.get("PIXI_ENVIRONMENT_NAME"),
        "portable_tools_ready": sys.version_info >= (3, 11) and git_version is not None,
        "windows": None,
    }
    if sys.platform == "win32":
        autodesk = Path(os.environ.get("ProgramFiles", r"C:\Program Files")) / "Autodesk"
        explorer = autodesk / "Vault Client 2025" / "Explorer"
        inventor = autodesk / "Inventor 2025" / "Bin" / "Inventor.exe"
        assemblies = [explorer / name for name in (
            "Autodesk.Connectivity.WebServices.dll",
            "Autodesk.DataManagement.Client.Framework.dll",
            "Autodesk.DataManagement.Client.Framework.Vault.dll",
        )]
        report["windows"] = {
            "powershell": shutil.which("powershell"),
            "vault_client_directory": str(explorer) if explorer.is_dir() else None,
            "job_processor": str(explorer / "JobProcessor.exe") if (explorer / "JobProcessor.exe").is_file() else None,
            "inventor_application": str(inventor) if inventor.is_file() else None,
            "sdk_candidate_assemblies": [str(path) for path in assemblies if path.is_file()],
            "note": "Presence checks at default paths only; licensing, runtime compatibility, authentication, and conversion are unverified.",
        }
    return report
