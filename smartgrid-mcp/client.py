import asyncio

from mcp import Client
from server import mcp


async def main():
    async with Client(mcp) as client:
        result = await client.call_tool(
            "list_running_pods",
            {"namespace": "smartgrid"}, #test
        )
        print(result)


if __name__ == "__main__":
    asyncio.run(main())