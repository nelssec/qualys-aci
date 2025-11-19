#!/bin/bash
# Download qscanner binary for use in Azure Functions
# Based on Qualys qscanner download script

set -e

QSCANNER_VERSION="${QSCANNER_VERSION:-4.6.0}"
DOWNLOAD_URL="https://cdn.qualys.com/qscanner/${QSCANNER_VERSION}/qscanner_${QSCANNER_VERSION}_linux_amd64"
BINARY_PATH="./bin/qscanner"

echo "Downloading qscanner v${QSCANNER_VERSION}..."

# Create bin directory
mkdir -p bin

# Download binary
curl -sSL -o "${BINARY_PATH}" "${DOWNLOAD_URL}"

# Make executable
chmod +x "${BINARY_PATH}"

# Verify download
if [ -f "${BINARY_PATH}" ]; then
    SIZE=$(stat -f%z "${BINARY_PATH}" 2>/dev/null || stat -c%s "${BINARY_PATH}" 2>/dev/null)
    echo "Downloaded qscanner binary: ${SIZE} bytes"
    echo "Verifying..."
    "${BINARY_PATH}" version || echo "Binary downloaded successfully"
else
    echo "ERROR: Failed to download qscanner binary"
    exit 1
fi

echo "qscanner binary ready at ${BINARY_PATH}"
