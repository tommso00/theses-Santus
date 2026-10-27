import json
import subprocess

from mcp.server import MCPServer

mcp = MCPServer("smartgrid")


@mcp.tool()
def list_running_pods(namespace: str = "smartgrid") -> list[str]:
    """Return the names of running pods in a namespace."""
    result = subprocess.run(
        [
            "kubectl", "get", "pods",
            "--namespace", namespace,
            "--field-selector=status.phase=Running",
            "--output=json",
        ],
        capture_output=True,
        text=True,
        check=True,
        timeout=15,
    )

    pods = json.loads(result.stdout)
    return [pod["metadata"]["name"] for pod in pods["items"]]


if __name__ == "__main__":
    mcp.run()