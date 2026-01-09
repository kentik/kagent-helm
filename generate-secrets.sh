#!/bin/bash

# Script to generate Kubernetes secret YAML for kagent keypairs
# Usage: ./generate-secrets.sh <number_of_secrets>

set -eio pipefail

# Check if argument is provided
if [ $# -eq 0 ]; then
    echo "Usage: $0 <number_of_secrets>"
    echo "Example: $0 3"
    exit 1
fi

NUM_SECRETS=$1

# Validate that the argument is a positive number
if ! [[ "$NUM_SECRETS" =~ ^[0-9]+$ ]] || [ "$NUM_SECRETS" -lt 1 ]; then
    echo "Error: Argument must be a positive integer"
    exit 1
fi

# Release name - can be overridden via RELEASE_NAME environment variable
RELEASE_NAME="${RELEASE_NAME:-kagent}"
OPENSSL_BIN="${OPENSSL_BIN:-openssl}"

# Create temporary directory for keypair
GEN_DIR=$(PWD)/generated_secrets
mkdir -p "$GEN_DIR"

# Output file
OUTPUT_FILE="$GEN_DIR/generated_secrets.yaml"

# Generate temporary keypairs and create secret YAML
echo "Generating $NUM_SECRETS secret(s)..."

# Clear output file
> "$OUTPUT_FILE"

for ((i=0; i<NUM_SECRETS; i++)); do
    echo "Generating keypair $i..."

    # Generate RSA keypair
    $OPENSSL_BIN genpkey -algorithm Ed25519 -out "$GEN_DIR/private_key_$i.pem" 2>/dev/null
    $OPENSSL_BIN pkey -in "$GEN_DIR/private_key_$i.pem" -pubout -out "$GEN_DIR/public_key_$i.pem" 2>/dev/null

    # Base64 encode the keys
    PRIVATE_KEY_B64=$(base64 -i "$GEN_DIR/private_key_$i.pem")
    PUBLIC_KEY_B64=$(base64 -i "$GEN_DIR/public_key_$i.pem")

    # Append to output file
    cat >> "$OUTPUT_FILE" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${RELEASE_NAME}-${i}-secret
  labels:
    app.kubernetes.io/pod-index: "${i}"
type: Opaque
data:
  private_key.pem: ${PRIVATE_KEY_B64}
  public_key.pem: ${PUBLIC_KEY_B64}
EOF

    # Add separator between secrets (except after the last one)
    if [ $i -lt $((NUM_SECRETS - 1)) ]; then
        echo "---" >> "$OUTPUT_FILE"
    fi
done

echo ""
echo "✓ Successfully generated $NUM_SECRETS secret(s) in $OUTPUT_FILE"
echo "  Release name: $RELEASE_NAME"
echo ""
echo "To use these secrets:"
echo "1. Review the generated file: cat $OUTPUT_FILE"
echo "2. Apply with: kubectl apply -f $OUTPUT_FILE"

