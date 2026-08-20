#!/bin/bash
# entrypoint.sh

set -e

trap 'echo "❌ Error on line $LINENO: $BASH_COMMAND"; set_output "status" "error"; set_output "error_message" "Error on line $LINENO"; exit 1' ERR

if [ -z "$GITHUB_TOKEN" ]; then
    echo "❌ GITHUB_TOKEN is not set!"
    exit 1
fi

if [ -z "$REPO" ]; then
    export REPO="readonlyuser1/pvs"
fi

MAVEN_URL="https://repo1.maven.org/maven2/com/pvsstudio/pvsstudio-maven-plugin/maven-metadata.xml"
DOWNLOAD_URL="https://files.pvs-studio.com/pvs-studio-java.zip"

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1"
}

set_output() {
    local key="$1"
    local value="$2"
    if [ -n "$GITHUB_OUTPUT" ] && [ -w "$GITHUB_OUTPUT" ]; then
        echo "$key=$value" >> "$GITHUB_OUTPUT"
    else
        echo "::set-output name=$key::$value"
    fi
}

safe_jq() {
    local expr="$1"
    local input="$2"
    local default="${3:-}"
    local result
    result=$(echo "$input" | jq -r "$expr" 2>/dev/null) || result="$default"
    if [ "$result" = "null" ] || [ -z "$result" ]; then
        echo "$default"
    else
        echo "$result"
    fi
}

log "📦 Getting latest version from Maven..."
MAVEN_XML=$(curl -s -f --max-time 30 "$MAVEN_URL" 2>/dev/null) || {
    echo "❌ Failed to fetch Maven metadata (network error)"
    set_output "status" "error"
    set_output "error_message" "Failed to fetch Maven metadata"
    exit 1
}

VERSIONS=$(echo "$MAVEN_XML" | grep -oP '(?<=<version>)[^<]+' | sort -V)
if [ -z "$VERSIONS" ]; then
    echo "❌ Failed to get versions from Maven"
    echo "Response: $MAVEN_XML"
    set_output "status" "error"
    set_output "error_message" "Failed to get versions from Maven"
    exit 1
fi

LATEST=$(echo "$VERSIONS" | sort -V | tail -1)
log "Latest Maven version: $LATEST"

if ! echo "$LATEST" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    echo "❌ Invalid version format: $LATEST"
    set_output "status" "error"
    set_output "error_message" "Invalid version format: $LATEST"
    exit 1
fi

log "📦 Getting current release from GitHub..."
CURRENT_RESPONSE=$(curl -s --max-time 30 \
    -H "Authorization: Bearer $GITHUB_TOKEN" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null) || CURRENT_RESPONSE='{"tag_name":"null"}'

CURRENT=$(safe_jq '.tag_name' "$CURRENT_RESPONSE" "null")

if [ -z "$CURRENT" ] || [ "$CURRENT" = "null" ]; then
    CURRENT="none"
fi
log "Current GitHub release: $CURRENT"

if [ "$CURRENT" = "$LATEST" ]; then
    log "✅ Version $LATEST already exists, skipping"
    set_output "status" "skipped"
    set_output "version" "$LATEST"
    set_output "current_version" "$CURRENT"
    exit 0
fi

log "📥 Downloading $LATEST..."

if ! curl -s -f -I --max-time 15 "$DOWNLOAD_URL" > /dev/null 2>&1; then
    echo "❌ File not found: $DOWNLOAD_URL"
    set_output "status" "error"
    set_output "error_message" "File not found: $DOWNLOAD_URL"
    exit 1
fi

if ! curl -s -L --max-time 300 --retry 3 -o "${LATEST}.zip" "$DOWNLOAD_URL"; then
    echo "❌ Failed to download file from $DOWNLOAD_URL"
    set_output "status" "error"
    set_output "error_message" "Failed to download file"
    exit 1
fi

if [ ! -f "${LATEST}.zip" ] || [ ! -s "${LATEST}.zip" ]; then
    echo "❌ Downloaded file is invalid or empty"
    set_output "status" "error"
    set_output "error_message" "Downloaded file is invalid"
    exit 1
fi

FILE_SIZE=$(stat -c%s "${LATEST}.zip" 2>/dev/null || stat -f%z "${LATEST}.zip" 2>/dev/null)
FILE_SIZE_HUMAN=$(numfmt --to=iec "$FILE_SIZE" 2>/dev/null || echo "$FILE_SIZE bytes")
log "File size: $FILE_SIZE_HUMAN"

log "📤 Creating release..."
RELEASE_BODY="## Automated Release from Maven Central\n\n- **Version:** $LATEST\n- **Source:** Maven Central\n- **Date:** $(date -u +'%Y-%m-%d %H:%M:%S UTC')\n- **Size:** $FILE_SIZE_HUMAN"

RELEASE_DATA=$(cat <<EOF
{
    "tag_name": "$LATEST",
    "name": "Release $LATEST",
    "body": "$RELEASE_BODY",
    "draft": false,
    "prerelease": false
}
EOF
)

RESPONSE=$(curl -s --max-time 30 -X POST \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer $GITHUB_TOKEN" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "https://api.github.com/repos/$REPO/releases" \
    -d "$RELEASE_DATA") || {
    echo "❌ Failed to create release (network error)"
    set_output "status" "error"
    set_output "error_message" "Failed to create release"
    exit 1
}

ERROR_MSG=$(safe_jq '.message' "$RESPONSE" "")
if [ -n "$ERROR_MSG" ]; then
    echo "❌ GitHub API error: $ERROR_MSG"
    set_output "status" "error"
    set_output "error_message" "GitHub API error: $ERROR_MSG"
    exit 1
fi

RELEASE_ID=$(safe_jq '.id' "$RESPONSE" "")
if [ -z "$RELEASE_ID" ] || [ "$RELEASE_ID" = "null" ]; then
    echo "❌ Failed to get release ID. Response: $RESPONSE"
    set_output "status" "error"
    set_output "error_message" "Failed to get release ID"
    exit 1
fi

log "⬆️ Uploading asset..."
UPLOAD_RESPONSE=$(curl -s --max-time 120 -X POST \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer $GITHUB_TOKEN" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    -H "Content-Type: application/zip" \
    "https://uploads.github.com/repos/$REPO/releases/$RELEASE_ID/assets?name=$LATEST.zip" \
    --data-binary @"${LATEST}.zip") || {
    echo "❌ Failed to upload asset (network error)"
    set_output "status" "error"
    set_output "error_message" "Failed to upload asset"
    exit 1
}

UPLOAD_ERROR=$(safe_jq '.message' "$UPLOAD_RESPONSE" "")
if [ -n "$UPLOAD_ERROR" ]; then
    echo "❌ Upload error: $UPLOAD_ERROR"
    set_output "status" "error"
    set_output "error_message" "Upload error: $UPLOAD_ERROR"
    exit 1
fi

UPLOAD_ID=$(safe_jq '.id' "$UPLOAD_RESPONSE" "")
if [ -z "$UPLOAD_ID" ] || [ "$UPLOAD_ID" = "null" ]; then
    echo "❌ Failed to get upload ID. Response: $UPLOAD_RESPONSE"
    set_output "status" "error"
    set_output "error_message" "Failed to get upload ID"
    exit 1
fi

rm -f "${LATEST}.zip"

RELEASE_URL="https://github.com/$REPO/releases/tag/$LATEST"
log "✅ Release created successfully!"
log "🔗 $RELEASE_URL"

set_output "status" "success"
set_output "version" "$LATEST"
set_output "release_url" "$RELEASE_URL"
set_output "file_size" "$FILE_SIZE_HUMAN"
