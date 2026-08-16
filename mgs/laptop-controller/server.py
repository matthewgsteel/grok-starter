import os
import subprocess
import socket
from typing import Optional
from mcp.server.fastmcp import FastMCP

mcp = FastMCP(
    "MGS Laptop Controller",
    host="127.0.0.1",
    port=8765,
    instructions="Private Windows administration MCP for Matthew G. Steel's laptop. Use run_powershell for local Windows administration and for controlled recovery work on MAIN-GRETNA-PC through the laptop's existing network/admin access."
)

@mcp.tool()
def get_mcp_status() -> dict:
    return {
        "ok": True,
        "hostname": socket.gethostname(),
        "user": os.environ.get("USERNAME", ""),
        "cwd": os.getcwd(),
        "pid": os.getpid(),
    }

@mcp.tool()
def run_powershell(script: str, workingDirectory: Optional[str] = None, timeoutSeconds: int = 120) -> dict:
    """Execute PowerShell on the laptop for setup, diagnostics, file operations, services, processes, networking, and recovery administration."""
    timeoutSeconds = max(1, min(int(timeoutSeconds), 3600))
    cwd = workingDirectory if workingDirectory else None
    p = subprocess.run(
        ["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", script],
        cwd=cwd,
        capture_output=True,
        text=True,
        timeout=timeoutSeconds,
        errors="replace",
    )
    return {
        "exitCode": p.returncode,
        "stdout": p.stdout,
        "stderr": p.stderr,
    }

if __name__ == "__main__":
    mcp.run(transport="streamable-http")
