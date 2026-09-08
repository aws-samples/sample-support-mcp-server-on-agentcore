#!/usr/bin/env bash
# One-shot deploy: upload the code zip to a private S3 bucket, then create/update the stack.
#
# Usage (env vars):
#   AWS_PROFILE=<profile> AWS_REGION=us-east-1 STACK=support-mcp-agentcore \
#   IDP_MODE=ExternalOIDC OIDC_DISCOVERY_URL=... OIDC_CLIENT_ID=... [OIDC_AUDIENCE=api://default] \
#   [KIRO_CALLBACK_PORT=8080] [RUNTIME_NAME=awsSupportMcp] [GATEWAY_NAME=aws-support-mcp] \
#   [CODE_BUCKET=<existing bucket>] ./deploy.sh
#
#   RUNTIME_NAME / GATEWAY_NAME must be unique per account+region (set them when deploying a second copy).
#
#   Evaluation mode (creates a Cognito user pool instead of using your IdP):
#   IDP_MODE=DemoCognito DEMO_USER_EMAIL=you@example.com ./deploy.sh
set -euo pipefail
cd "$(dirname "$0")"
: "${AWS_REGION:=us-east-1}"
: "${STACK:=support-mcp-agentcore}"
: "${IDP_MODE:=ExternalOIDC}"
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
: "${CODE_BUCKET:=support-mcp-agentcore-${ACCOUNT}-${AWS_REGION}}"
ZIP=dist/support-mcp-agentcore.zip
[ -f "$ZIP" ] || ./build.sh

if ! aws s3api head-bucket --bucket "$CODE_BUCKET" 2>/dev/null; then
  echo "creating private bucket $CODE_BUCKET"
  if [ "$AWS_REGION" = "us-east-1" ]; then aws s3api create-bucket --bucket "$CODE_BUCKET" >/dev/null
  else aws s3api create-bucket --bucket "$CODE_BUCKET" --create-bucket-configuration LocationConstraint="$AWS_REGION" >/dev/null; fi
  aws s3api put-public-access-block --bucket "$CODE_BUCKET" --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
  aws s3api put-bucket-versioning --bucket "$CODE_BUCKET" --versioning-configuration Status=Enabled
fi
aws s3 cp "$ZIP" "s3://$CODE_BUCKET/support-mcp-agentcore.zip" --only-show-errors

PARAMS=(ParameterKey=CodeS3Bucket,ParameterValue="$CODE_BUCKET" ParameterKey=IdentityProviderMode,ParameterValue="$IDP_MODE")
[ -n "${OIDC_DISCOVERY_URL:-}" ] && PARAMS+=(ParameterKey=OidcDiscoveryUrl,ParameterValue="$OIDC_DISCOVERY_URL")
[ -n "${OIDC_CLIENT_ID:-}" ]     && PARAMS+=(ParameterKey=OidcClientId,ParameterValue="$OIDC_CLIENT_ID")
[ -n "${OIDC_AUDIENCE:-}" ]      && PARAMS+=(ParameterKey=OidcAudience,ParameterValue="$OIDC_AUDIENCE")
[ -n "${KIRO_CALLBACK_PORT:-}" ] && PARAMS+=(ParameterKey=KiroCallbackPort,ParameterValue="$KIRO_CALLBACK_PORT")
[ -n "${DEMO_USER_EMAIL:-}" ]    && PARAMS+=(ParameterKey=DemoUserEmail,ParameterValue="$DEMO_USER_EMAIL")
[ -n "${RUNTIME_NAME:-}" ]       && PARAMS+=(ParameterKey=RuntimeName,ParameterValue="$RUNTIME_NAME")
[ -n "${GATEWAY_NAME:-}" ]       && PARAMS+=(ParameterKey=GatewayName,ParameterValue="$GATEWAY_NAME")

if aws cloudformation describe-stacks --stack-name "$STACK" >/dev/null 2>&1; then OP=update-stack; WAIT=stack-update-complete; else OP=create-stack; WAIT=stack-create-complete; fi
echo "$OP $STACK in $AWS_REGION ..."
aws cloudformation $OP --stack-name "$STACK" --template-body file://cfn/support-mcp-agentcore.yaml \
  --capabilities CAPABILITY_NAMED_IAM --parameters "${PARAMS[@]}" >/dev/null
aws cloudformation wait $WAIT --stack-name "$STACK"
aws cloudformation describe-stacks --stack-name "$STACK" --query 'Stacks[0].Outputs[].[OutputKey,OutputValue]' --output table
