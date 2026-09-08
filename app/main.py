"""AgentCore Runtime entrypoint for the AWS Support MCP Server.

Wraps the unmodified awslabs.aws-support-mcp-server (v0.1.23, awslabs/mcp@e9f2439)
and serves it over stateless streamable-HTTP on 0.0.0.0:8000/mcp, which is the
contract AgentCore Runtime expects for MCP protocol runtimes.

Upstream hard-codes stdio transport in server.main(); we import the FastMCP
instance and run it with the HTTP transport instead. No tool code is changed.

Auth model: this process performs NO authentication itself. Inbound requests are
authenticated upstream by AgentCore (Gateway JWT authorizer -> SigV4 to Runtime).
Do not run this entrypoint exposed on a network outside AgentCore Runtime.
"""

import os

# AWS Support is an account-level service whose standard-partition endpoint lives
# in us-east-1. Pin the boto3 region for the Support client regardless of the
# region AgentCore Runtime is deployed in. Override with SUPPORT_API_REGION.
os.environ["AWS_REGION"] = os.environ.get("SUPPORT_API_REGION", "us-east-1")
os.environ.pop("AWS_PROFILE", None)  # always use the Runtime execution role

from awslabs.aws_support_mcp_server.server import mcp  # noqa: E402


def main() -> None:
    mcp.run(
        transport="http",
        host="0.0.0.0",
        port=int(os.environ.get("PORT", "8000")),
        path="/mcp",
        stateless_http=True,
        # AgentCore Runtime forwards requests with a non-localhost Host header; FastMCP's
        # DNS-rebinding guard would answer 421. Runtime/Gateway are the auth boundary, so
        # the guard adds nothing here (same approach as AWS's API-MCP-on-AgentCore blog).
        host_origin_protection=False,
        show_banner=False,
    )


if __name__ == "__main__":
    main()
