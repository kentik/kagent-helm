#!/bin/bash

# Script to create a Kentik provisioning token for kagent Helm chart deployment
# Usage: ./generate-provisioning-token.sh --name <token-name> [options]
#
# Kentik API (flags override environment variables):
#   --api-root <host>               API host (or K_API_ROOT env var; default: grpc.api.kentik.com)
#   --api-email <email>             Kentik account email (or K_API_EMAIL env var)
#   --api-token <token>             Kentik API token (or K_API_TOKEN env var)
#
# Token Configuration:
#   --name <name>                   Required. User-friendly name for the token.
#   --max-usage <count>             Max agents that can use this token (default: 1)
#                                   NOTE: must match the number of replicas you intend to deploy
#   --expires-at <ISO-8601>         Token expiration time (default: 1 hour from creation)
#   --allowed-private-cidrs <cidrs> Comma-separated private IP CIDRs allowed
#   --allowed-public-cidrs <cidrs>  Comma-separated public IP CIDRs allowed
#   --auto-approve                  Skip manual approval (default: requires approval)
#   --site-id <id>                  Site ID to assign to registered agents

set -euo pipefail

# ============================================================================
# Defaults
# ============================================================================
K_API_EMAIL="${K_API_EMAIL:-}"
K_API_TOKEN="${K_API_TOKEN:-}"
API_ROOT="${K_API_ROOT:-grpc.api.kentik.com}"
TOKEN_NAME=""
MAX_USAGE_COUNT=""
EXPIRES_AT=""
ALLOWED_PRIVATE_CIDRS=""
ALLOWED_PUBLIC_CIDRS=""
REQUIRES_APPROVAL="true"
SITE_ID=""

# ============================================================================
# Functions
# ============================================================================

usage() {
    cat <<EOF
Usage: $0 --name <token-name> [options]

Create a Kentik provisioning token for kagent Helm chart deployment.

Kentik API (flags override environment variables):
  --api-root <host>               API host (or K_API_ROOT env var; default: grpc.api.kentik.com)
  --api-email <email>             Kentik account email (or K_API_EMAIL env var)
  --api-token <token>             Kentik API token (or K_API_TOKEN env var)

Token Configuration:
  --name <name>                   Required. User-friendly name for the token.
  --max-usage <count>             Max agents that can use this token (default: 1)
                                  NOTE: must match the number of replicas you intend to deploy
  --expires-at <ISO-8601>         Token expiration time (default: 1h from creation)
  --allowed-private-cidrs <cidrs> Comma-separated private IP CIDRs allowed
  --allowed-public-cidrs <cidrs>  Comma-separated public IP CIDRs allowed
  --auto-approve                  Skip manual approval (default: requires approval)
  --site-id <id>                  Site ID to assign to registered agents

Examples:
  # Minimal (uses env vars for auth):
  export K_API_EMAIL=user@company.com
  export K_API_TOKEN=abc123
  $0 --name "production-agents"

  # Full options with CLI auth:
  $0 --api-root grpc.api.kentik.eu \\
     --api-email user@co.com --api-token abc123 \\
     --name "staging-fleet" \\
     --max-usage 10 \\
     --allowed-private-cidrs "10.0.0.0/8,172.16.0.0/12"
EOF
    exit "${1:-0}"
}

die() {
    printf 'Error: %b\n' "$1" >&2
    exit 1
}

detect_http_client() {
    if command -v curl &>/dev/null; then
        echo "curl"
    elif command -v wget &>/dev/null; then
        echo "wget"
    else
        die "Neither curl nor wget found. Please install one of them."
    fi
}

check_jq() {
    if ! command -v jq &>/dev/null; then
        die "jq is required but not found. Please install jq."
    fi
}


build_request_body() {
    local body
    body=$(jq -n --arg name "$TOKEN_NAME" '{name: $name}')

    if [[ -n "$MAX_USAGE_COUNT" ]]; then
        body=$(echo "$body" | jq --argjson v "$MAX_USAGE_COUNT" '. + {maxUsageCount: $v}')
    fi

    if [[ -n "$EXPIRES_AT" ]]; then
        body=$(echo "$body" | jq --arg v "$EXPIRES_AT" '. + {expiresAt: $v}')
    fi

    if [[ -n "$ALLOWED_PRIVATE_CIDRS" ]]; then
        body=$(echo "$body" | jq --arg v "$ALLOWED_PRIVATE_CIDRS" '. + {allowedPrivateCidrs: ($v | split(","))}')
    fi

    if [[ -n "$ALLOWED_PUBLIC_CIDRS" ]]; then
        body=$(echo "$body" | jq --arg v "$ALLOWED_PUBLIC_CIDRS" '. + {allowedPublicCidrs: ($v | split(","))}')
    fi

    if [[ "$REQUIRES_APPROVAL" == "true" ]]; then
        body=$(echo "$body" | jq '. + {requiresApproval: true}')
    else
        body=$(echo "$body" | jq '. + {requiresApproval: false}')
    fi

    if [[ -n "$SITE_ID" ]]; then
        body=$(echo "$body" | jq --arg v "$SITE_ID" '. + {config: {siteId: $v}}')
    fi

    echo "$body"
}

do_post() {
    local url="$1"
    local body="$2"
    local http_client
    http_client=$(detect_http_client)

    if [[ "$http_client" == "curl" ]]; then
        curl -s -w "\n%{http_code}" \
            -X POST \
            -H "Content-Type: application/json" \
            -H "X-CH-Auth-Email: $K_API_EMAIL" \
            -H "X-CH-Auth-API-Token: $K_API_TOKEN" \
            -d "$body" \
            "$url"
    else
        # wget: capture response body + status
        local tmp_file
        tmp_file=$(mktemp)
        local http_code
        http_code=$(wget -q -O "$tmp_file" \
            --header="Content-Type: application/json" \
            --header="X-CH-Auth-Email: $K_API_EMAIL" \
            --header="X-CH-Auth-API-Token: $K_API_TOKEN" \
            --post-data="$body" \
            --server-response \
            "$url" 2>&1 | awk '/HTTP\//{print $2}' | tail -1)
        cat "$tmp_file"
        echo ""
        echo "${http_code:-000}"
        rm -f "$tmp_file"
    fi
}

# ============================================================================
# Parse Arguments
# ============================================================================

while [[ $# -gt 0 ]]; do
    if [[ "$1" =~ ^--(api-email|api-token|name|max-usage|expires-at|allowed-private-cidrs|allowed-public-cidrs|site-id|api-root)$ ]]; then
        if [[ $# -lt 2 || "${2:-}" == --* ]]; then
            die "Missing value for $1"
        fi
    fi
    case "$1" in
        --api-email)
            K_API_EMAIL="$2"
            shift 2
            ;;
        --api-token)
            K_API_TOKEN="$2"
            shift 2
            ;;
        --name)
            TOKEN_NAME="$2"
            shift 2
            ;;
        --max-usage)
            MAX_USAGE_COUNT="$2"
            shift 2
            ;;
        --expires-at)
            EXPIRES_AT="$2"
            shift 2
            ;;
        --allowed-private-cidrs)
            ALLOWED_PRIVATE_CIDRS="$2"
            shift 2
            ;;
        --allowed-public-cidrs)
            ALLOWED_PUBLIC_CIDRS="$2"
            shift 2
            ;;
        --auto-approve)
            REQUIRES_APPROVAL="false"
            shift
            ;;
        --site-id)
            SITE_ID="$2"
            shift 2
            ;;
        --api-root)
            API_ROOT="$2"
            shift 2
            ;;
        --help|-h)
            usage 0
            ;;
        *)
            die "Unknown option: $1. Use --help for usage."
            ;;
    esac
done

# ============================================================================
# Validate Inputs
# ============================================================================

check_jq

[[ -z "$K_API_EMAIL" ]] && die "Kentik email is required. Use --api-email or set K_API_EMAIL env var."
[[ -z "$K_API_TOKEN" ]] && die "Kentik API token is required. Use --api-token or set K_API_TOKEN env var."
[[ -z "$TOKEN_NAME" ]] && die "Token name is required. Use --name <name>."

if [[ -n "$MAX_USAGE_COUNT" ]]; then
    if ! [[ "$MAX_USAGE_COUNT" =~ ^[0-9]+$ ]] || [[ "$MAX_USAGE_COUNT" -lt 1 ]]; then
        die "--max-usage must be a positive integer."
    fi
fi

# ============================================================================
# Create Token
# ============================================================================

URL="https://${API_ROOT}/kagent/v202401/provisioning-tokens"
BODY=$(build_request_body)

echo "Creating provisioning token..."
echo "  API:    $API_ROOT"
echo "  Name:   $TOKEN_NAME"
echo ""

RESPONSE=$(do_post "$URL" "$BODY")
HTTP_CODE=$(echo "$RESPONSE" | tail -1)
RESPONSE_BODY=$(echo "$RESPONSE" | sed '$d')

if [[ "$HTTP_CODE" -ne 200 ]]; then
    echo "API request failed (HTTP $HTTP_CODE):" >&2
    echo "$RESPONSE_BODY" | jq . 2>/dev/null || echo "$RESPONSE_BODY" >&2
    exit 1
fi

# Extract token value
PROV_TOKEN=$(echo "$RESPONSE_BODY" | jq -r '.token.token')
TOKEN_EXPIRES=$(echo "$RESPONSE_BODY" | jq -r '.token.expiresAt // "N/A"')
TOKEN_MAX_USAGE=$(echo "$RESPONSE_BODY" | jq -r '.token.maxUsageCount // 1')

if [[ -z "$PROV_TOKEN" || "$PROV_TOKEN" == "null" ]]; then
    die "Failed to extract token from API response. Full response:\n$RESPONSE_BODY"
fi

# ============================================================================
# Output
# ============================================================================

echo "✓ Provisioning token created successfully!"
echo ""
echo "  Token:       $PROV_TOKEN"
echo "  Expires:     $TOKEN_EXPIRES"
echo "  Max Agents:  $TOKEN_MAX_USAGE"
echo ""
echo "Use with Helm:"
echo ""
echo "  helm install kagent ./kagent-helm \\"
echo "    --set-string kagent.companyId=<YOUR_COMPANY_ID> \\"
echo "    --set-string kagent.provisioningToken=$PROV_TOKEN"
echo ""
