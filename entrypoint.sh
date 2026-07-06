#!/bin/bash

set -e

if [ -z "$GITHUB_TOKEN" ]; then
    echo "❌ GITHUB_TOKEN is not set!"
    exit 1
fi

if [ -z "$REPO" ]; then
    export REPO="readonlyuser1/pvs"
fi

MAVEN_URL="https://repo1.maven.org/maven2/com/pvsstudio/pvsstudio-maven-plugin/maven-metadata.xml"
DOWNLOAD_BASE="https://files.pvs-studio.com/java/pvsstudio-cores"

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1"
}

log "📦 Getting latest version from Maven..."
VERSIONS=$(curl -s -f "$MAVEN_URL" | grep -oP '(?<=<version>)[^<]+' | sort -V)
if [ -z "$VERSIONS" ]; then
    echo "❌ Failed to get versions from Maven"
    exit 1
fi

LATEST=$(echo "$VERSIONS" | sort -V | tail -1)
log "Latest Maven version: $LATEST"

if ! echo "$LATEST" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    echo "❌ Invalid version format: $LATEST"
    exit 1
fi

log "📦 Getting current release from GitHub..."
CURRENT_RESPONSE=$(curl -s "https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null || echo '{"tag_name":"null"}')
CURRENT=$(echo "$CURRENT_RESPONSE" | jq -r '.tag_name')

if [ -z "$CURRENT" ] || [ "$CURRENT" = "null" ]; then
    CURRENT="none"
fi
log "Current GitHub release: $CURRENT"

if [ "$CURRENT" = "$LATEST" ]; then
    log "✅ Version $LATEST already exists, skipping"
    echo "status=skipped" >> $GITHUB_OUTPUT
    echo "version=$LATEST" >> $GITHUB_OUTPUT
    exit 0
fi

log "📥 Downloading $LATEST..."
FILE_URL="$DOWNLOAD_BASE/$LATEST.zip"

if ! curl -s -f -I "$FILE_URL" > /dev/null 2>&1; then
    echo "❌ File not found: $FILE_URL"
    exit 1
fi

if ! wget -q --timeout=30 --tries=3 "$FILE_URL"; then
    echo "❌ Failed to download file"
    exit 1
fi

if [ ! -f "$LATEST.zip" ] || [ ! -s "$LATEST.zip" ]; then
    echo "❌ Downloaded file is invalid"
    exit 1
fi

FILE_SIZE=$(stat -c%s "$LATEST.zip" 2>/dev/null || stat -f%z "$LATEST.zip" 2>/dev/null)
FILE_SIZE_HUMAN=$(numfmt --to=iec $FILE_SIZE 2>/dev/null || echo "$FILE_SIZE bytes")
log "File size: $FILE_SIZE_HUMAN"

log "📤 Creating release..."
RELEASE_DATA=$(cat <<EOF
{
    "tag_name": "$LATEST",
    "name": "Release $LATEST",
    "body": "## Automated Release from Maven Central\n\n- **Version:** $LATEST\n- **Source:** Maven Central\n- **Date:** $(date -u +'%Y-%m-%d %H:%M:%S UTC')\n- **Size:** $FILE_SIZE_HUMAN",
    "draft": false,
    "prerelease": false
}
EOF
)

RESPONSE=$(curl -s -f -X POST \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer $GITHUB_TOKEN" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "https://api.github.com/repos/$REPO/releases" \
    -d "$RELEASE_DATA") || {
    echo "❌ Failed to create release"
    exit 1
}

if echo "$RESPONSE" | jq -e '.message' > /dev/null 2>&1; then
    ERROR_MSG=$(echo "$RESPONSE" | jq -r '.message')
    echo "❌ GitHub API error: $ERROR_MSG"
    exit 1
fi

RELEASE_ID=$(echo "$RESPONSE" | jq -r '.id')
if [ -z "$RELEASE_ID" ] || [ "$RELEASE_ID" = "null" ]; then
    echo "❌ Failed to get release ID"
    exit 1
fi

log "⬆️ Uploading asset..."
UPLOAD_RESPONSE=$(curl -s -f -X POST \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer $GITHUB_TOKEN" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    -H "Content-Type: application/zip" \
    "https://uploads.github.com/repos/$REPO/releases/$RELEASE_ID/assets?name=$LATEST.zip" \
    --data-binary @"$LATEST.zip") || {
    echo "❌ Failed to upload asset"
    exit 1
}

if echo "$UPLOAD_RESPONSE" | jq -e '.message' > /dev/null 2>&1; then
    ERROR_MSG=$(echo "$UPLOAD_RESPONSE" | jq -r '.message')
    echo "❌ Upload error: $ERROR_MSG"
    exit 1
fi

UPLOAD_ID=$(echo "$UPLOAD_RESPONSE" | jq -r '.id')
if [ -z "$UPLOAD_ID" ] || [ "$UPLOAD_ID" = "null" ]; then
    echo "❌ Failed to get upload ID"
    exit 1
fi

rm -f "$LATEST.zip"

RELEASE_URL="https://github.com/$REPO/releases/tag/$LATEST"
log "✅ Release created successfully!"
log "🔗 $RELEASE_URL"

echo "status=success" >> $GITHUB_OUTPUT
echo "version=$LATEST" >> $GITHUB_OUTPUT
echo "release_url=$RELEASE_URL" >> $GITHUB_OUTPUT