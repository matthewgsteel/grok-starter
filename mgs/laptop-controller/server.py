import os
import socket
import subprocess
from typing import Optional

from mcp.server.mcpserver import MCPServer
from mcp.server.transport_security import TransportSecuritySettings

mcp = MCPServer("MGS Laptop Controller")


@mcp.tool()
def get_mcp_status() -> dict:
    """Return basic status for the temporary laptop administration MCP."""
    return {
        "ok": True,
        "hostname": socket.gethostname(),
        "user": os.environ.get("USERNAME", ""),
        "cwd": os.getcwd(),
        "pid": os.getpid(),
    }


@mcp.tool()
def run_powershell(
    script: str,
    workingDirectory: Optional[str] = None,
    timeoutSeconds: int = 120,
) -> dict:
    """Execute PowerShell locally on the laptop for Windows administration and recovery work."""
    timeoutSeconds = max(1, min(int(timeoutSeconds), 3600))
    proc = subprocess.run(
        [
            "powershell.exe",
            "-NoProfile",
            "-ExecutionPolicy",
            "Bypass",
            "-Command",
            script,
        ],
        cwd=workingDirectory or None,
        capture_output=True,
        text=True,
        timeout=timeoutSeconds,
        errors="replace",
    )
    return {
        "exitCode": proc.returncode,
        "stdout": proc.stdout,
        "stderr": proc.stderr,
    }


if __name__ == "__main__":
    security = TransportSecuritySettings(
        enable_dns_rebinding_protection=True,
        allowed_hosts=[
            "127.0.0.1:*",
            "localhost:*",
            "mcp.matthewgsteel.com",
            "mcp.matthewgsteel.com:*",
        ],
        allowed_origins=[
            "http://127.0.0.1:*",
            "http://localhost:*",
            "https://mcp.matthewgsteel.com",
        ],
    )

    mcp.run(
        transport="streamable-http",
        host="127.0.0.1",
        port=8765,
        stateless_http=True,
        json_response=True,
        transport_security=security,
    )
