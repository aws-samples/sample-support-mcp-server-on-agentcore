#!/usr/bin/env bash
# One-shot deploy: upload the code zip to a private S3 bucket, then create/update the stack.
#
# Usage (env vars):
#   AWS_PROFILE=<profile> AWS_REGION=us-east-1 STACK=support-mcp-agentcore \
#   IDP_MODE=ExternalOIDC OIDC_DISCOVERY_URL=... OIDC_CLIENT_ID=... [OIDC_AUDIENCE=api://default] \
#   [KIRO_CALLBACK_PORT=8080] [RUNTIME_NAME=awsSupportMcp] [GATEWAY_NAME=aws-support-mcp] \
#   [CODE_BUCKET=<existing bucket>] ./deploy.sh
#
#   Cognito mode, standalone users (no corporate IdP):
#   IDP_MODE=Cognito COGNITO_FIRST_USER_EMAIL=you@example.com ./deploy.sh
#   -> add more users later with scripts/cognito-add-users.sh
#
#   Cognito mode, federated to IAM Identity Center (organization instance) or another SAML 2.0 IdP:
#   1) IDP_MODE=Cognito ./deploy.sh            (creates the pool; note the CognitoSamlAcsUrl / CognitoSamlAudience outputs)
#   2) create the SAML 2.0 application in IAM Identity Center with those two values (docs/deployment-guide.md, step 1b)
#   3) IDP_MODE=Cognito SAML_METADATA_URL='https://portal.sso.<region>.amazonaws.com/saml/metadata/...' \
#      [SAML_PROVIDER_NAME=IdentityCenter] ./deploy.sh
#
#   RUNTIME_NAME / GATEWAY_NAME must be unique per account+region (set them when deploying a second copy).
#   Re-running the script uploads the package again and passes its S3 object version to the stack, so the
#   Runtime rolls to the uploaded code even though the object key is unchanged (needs bucket versioning,
#   which the script enables on the bucket it creates).
set -euo pipefail
cd "$(dirname "$0")"
: "${AWS_REGION:=us-east-1}"
: "${STACK:=support-mcp-agentcore}"
: "${IDP_MODE:=ExternalOIDC}"
: "${COGNITO_FIRST_USER_EMAIL:=${DEMO_USER_EMAIL:-}}"     # DEMO_USER_EMAIL is the v1.0 name, still honoured
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
: "${CODE_BUCKET:=support-mcp-agentcore-${ACCOUNT}-${AWS_REGION}}"
CODE_KEY=support-mcp-agentcore.zip
ZIP=dist/support-mcp-agentcore.zip
[ -f "$ZIP" ] || ./build.sh

if ! aws s3api head-bucket --bucket "$CODE_BUCKET" >/dev/null 2>&1; then
  echo "creating private bucket $CODE_BUCKET"
  if [ "$AWS_REGION" = "us-east-1" ]; then aws s3api create-bucket --bucket "$CODE_BUCKET" >/dev/null
  else aws s3api create-bucket --bucket "$CODE_BUCKET" --create-bucket-configuration LocationConstraint="$AWS_REGION" >/dev/null; fi
  aws s3api put-public-access-block --bucket "$CODE_BUCKET" --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
  aws s3api put-bucket-versioning --bucket "$CODE_BUCKET" --versioning-configuration Status=Enabled
fi
VERSION_ID=$(aws s3api put-object --bucket "$CODE_BUCKET" --key "$CODE_KEY" --body "$ZIP" --query VersionId --output text)
[ "$VERSION_ID" = "None" ] && VERSION_ID=""     # bucket without versioning: the Runtime uses the latest object
echo "uploaded s3://$CODE_BUCKET/$CODE_KEY${VERSION_ID:+ (version $VERSION_ID)}"

PARAMS=(ParameterKey=CodeS3Bucket,ParameterValue="$CODE_BUCKET" ParameterKey=CodeS3Key,ParameterValue="$CODE_KEY" ParameterKey=IdentityProviderMode,ParameterValue="$IDP_MODE")
[ -n "$VERSION_ID" ]                   && PARAMS+=(ParameterKey=CodeS3ObjectVersion,ParameterValue="$VERSION_ID")
[ -n "${OIDC_DISCOVERY_URL:-}" ]       && PARAMS+=(ParameterKey=OidcDiscoveryUrl,ParameterValue="$OIDC_DISCOVERY_URL")
[ -n "${OIDC_CLIENT_ID:-}" ]           && PARAMS+=(ParameterKey=OidcClientId,ParameterValue="$OIDC_CLIENT_ID")
[ -n "${OIDC_AUDIENCE:-}" ]            && PARAMS+=(ParameterKey=OidcAudience,ParameterValue="$OIDC_AUDIENCE")
[ -n "${KIRO_CALLBACK_PORT:-}" ]       && PARAMS+=(ParameterKey=KiroCallbackPort,ParameterValue="$KIRO_CALLBACK_PORT")
[ -n "${COGNITO_FIRST_USER_EMAIL:-}" ] && PARAMS+=(ParameterKey=CognitoFirstUserEmail,ParameterValue="$COGNITO_FIRST_USER_EMAIL")
[ -n "${SAML_METADATA_URL:-}" ]        && PARAMS+=(ParameterKey=SamlMetadataUrl,ParameterValue="$SAML_METADATA_URL")
[ -n "${SAML_PROVIDER_NAME:-}" ]       && PARAMS+=(ParameterKey=SamlProviderName,ParameterValue="$SAML_PROVIDER_NAME")
[ -n "${RUNTIME_NAME:-}" ]             && PARAMS+=(ParameterKey=RuntimeName,ParameterValue="$RUNTIME_NAME")
[ -n "${GATEWAY_NAME:-}" ]             && PARAMS+=(ParameterKey=GatewayName,ParameterValue="$GATEWAY_NAME")

if aws cloudformation describe-stacks --stack-name "$STACK" >/dev/null 2>&1; then OP=update-stack; WAIT=stack-update-complete; else OP=create-stack; WAIT=stack-create-complete; fi
echo "$OP $STACK in $AWS_REGION ..."
if ! OUT=$(aws cloudformation $OP --stack-name "$STACK" --template-body file://cfn/support-mcp-agentcore.yaml \
      --capabilities CAPABILITY_NAMED_IAM --parameters "${PARAMS[@]}" 2>&1); then
  if [[ "$OUT" == *"No updates are to be performed"* ]]; then echo "stack $STACK is already up to date"; exit 0; fi
  echo "$OUT" >&2; exit 1
fi
aws cloudformation wait $WAIT --stack-name "$STACK"
aws cloudformation describe-stacks --stack-name "$STACK" --query 'Stacks[0].Outputs[].[OutputKey,OutputValue]' --output table
