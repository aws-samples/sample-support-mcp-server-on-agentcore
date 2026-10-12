"""AgentCore Runtime entrypoint for the AWS Support MCP Server.

Wraps awslabs.aws-support-mcp-server (v0.1.23, awslabs/mcp@e9f2439; vendored with one
logging change, see THIRD-PARTY-LICENSES) and serves it over stateless streamable-HTTP
on 0.0.0.0:8000/mcp, which is the contract AgentCore Runtime expects for MCP protocol
runtimes.

Upstream hard-codes stdio transport in server.main(); we import the FastMCP
instance and run it with the HTTP transport instead. No tool code is changed.

Auth model: this process performs NO authentication itself. Inbound requests are
authenticated upstream by AgentCore (Gateway JWT authorizer -> SigV4 to Runtime).
Do not run this entrypoint exposed on a network outside AgentCore Runtime.
"""

import os
import sys

from loguru import logger

# AWS Support is an account-level service whose standard-partition endpoint lives
# in us-east-1. Pin the boto3 region for the Support client regardless of the
# region AgentCore Runtime is deployed in. Override with SUPPORT_API_REGION.
os.environ["AWS_REGION"] = os.environ.get("SUPPORT_API_REGION", "us-east-1")
os.environ.pop("AWS_PROFILE", None)  # always use the Runtime execution role

# The upstream package configures loguru at DEBUG when it is imported, and upstream
# server.main() lowers it to INFO unless --debug. This entrypoint bypasses server.main(), so
# apply the same default after the package import and before the server module (which
# creates the Support client) is imported. DEBUG logs request parameters such as case IDs
# and subjects. FASTMCP_LOG_LEVEL (set by the template) controls these logs and FastMCP's own.
import awslabs.aws_support_mcp_server  # noqa: E402,F401

logger.remove()
logger.add(sys.stderr, level=os.environ.get("FASTMCP_LOG_LEVEL", "INFO"))

from awslabs.aws_support_mcp_server.server import mcp  # noqa: E402


def main() -> None:
    mcp.run(
        transport="http",
        # AgentCore Runtime contract: the MCP server must listen on 0.0.0.0:8000 inside the
        # Runtime microVM; the only route to it is the Runtime's authenticated invocation API
        # (see module docstring). Not a public bind.
        host="0.0.0.0",  # nosec B104
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
