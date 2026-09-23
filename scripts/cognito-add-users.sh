#!/usr/bin/env bash
# Create standalone users in the Cognito user pool of a stack deployed in Cognito mode (one user per e-mail
# address). Cognito e-mails each new user a temporary password; they set their own on first sign-in.
#
# Usage:
#   scripts/cognito-add-users.sh --stack <stack-name>     [--region <region>] [--profile <profile>] [--resend] [--dry-run] <emails-file>
#   scripts/cognito-add-users.sh --user-pool-id <pool-id> [--region <region>] [--profile <profile>] [--resend] [--dry-run] <emails-file>
#
#   <emails-file>  one e-mail address per line; a CSV whose first column is the address also works.
#                  Blank lines and lines starting with # are ignored; addresses are lower-cased. Use - for stdin.
#   --resend       re-send the temporary-password e-mail to users that already exist and have never signed in
#   --dry-run      print what would be created without calling Cognito
#
# Needs the AWS CLI with cognito-idp:AdminCreateUser on the pool (and cloudformation:DescribeStacks when --stack is used).
# Not applicable when the stack is federated to IAM Identity Center (SamlMetadataUrl set): users then come from the IdP.
set -euo pipefail

STACK="" POOL="" RESEND=0 DRY=0 FILE=""
AWSARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --stack)        STACK=$2; shift 2 ;;
    --user-pool-id) POOL=$2; shift 2 ;;
    --region)       AWSARGS+=(--region "$2"); shift 2 ;;
    --profile)      AWSARGS+=(--profile "$2"); shift 2 ;;
    --resend)       RESEND=1; shift ;;
    --dry-run)      DRY=1; shift ;;
    -h|--help)      sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)             echo "unknown option: $1" >&2; exit 2 ;;
    *)              FILE=$1; shift ;;
  esac
done
if [ -z "$FILE" ] || { [ -z "$STACK" ] && [ -z "$POOL" ]; }; then
  echo "usage: $0 (--stack <name> | --user-pool-id <id>) [--region r] [--profile p] [--resend] [--dry-run] <emails-file|->" >&2; exit 2
fi
aws_() { aws ${AWSARGS[@]+"${AWSARGS[@]}"} "$@"; }

if [ -z "$POOL" ]; then
  POOL=$(aws_ cloudformation describe-stacks --stack-name "$STACK" \
           --query "Stacks[0].Outputs[?OutputKey=='CognitoUserPoolId'].OutputValue | [0]" --output text)
  if [ -z "$POOL" ] || [ "$POOL" = "None" ]; then
    echo "stack $STACK has no CognitoUserPoolId output - is it deployed in Cognito mode?" >&2; exit 1
  fi
fi
echo "user pool: $POOL"

created=0 existing=0 resent=0 skipped=0 failed=0
while IFS= read -r line || [ -n "$line" ]; do
  email=$(printf '%s' "$line" | cut -d, -f1 | tr -d '[:space:]\r"' | tr '[:upper:]' '[:lower:]')
  case "$email" in ''|\#*) continue ;; esac
  case "$email" in *@*.*) ;; *) echo "skip     $line (not an e-mail address)"; skipped=$((skipped+1)); continue ;; esac
  if [ "$DRY" = 1 ]; then echo "would create $email"; created=$((created+1)); continue; fi
  if out=$(aws_ cognito-idp admin-create-user --user-pool-id "$POOL" --username "$email" \
             --user-attributes Name=email,Value="$email" Name=email_verified,Value=true \
             --desired-delivery-mediums EMAIL --output text 2>&1); then
    echo "created  $email"; created=$((created+1))
  elif [[ "$out" == *UsernameExistsException* ]]; then
    if [ "$RESEND" = 1 ]; then
      if out=$(aws_ cognito-idp admin-create-user --user-pool-id "$POOL" --username "$email" \
                 --message-action RESEND --desired-delivery-mediums EMAIL --output text 2>&1); then
        echo "resent   $email"; resent=$((resent+1))
      else
        echo "FAILED   $email (resend): ${out##*Error:}" >&2; failed=$((failed+1))
      fi
    else
      echo "exists   $email (add --resend to re-send the temporary password)"; existing=$((existing+1))
    fi
  else
    echo "FAILED   $email: ${out##*Error:}" >&2; failed=$((failed+1))
  fi
done < <(if [ "$FILE" = "-" ]; then cat; else cat "$FILE"; fi)

echo "done: created=$created existing=$existing resent=$resent skipped=$skipped failed=$failed${DRY:+}"
[ "$failed" -eq 0 ]
