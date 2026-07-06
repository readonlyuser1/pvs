#!/bin/bash
# entrypoint.sh - Точка входа для контейнера

set -e

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

# Проверка переменных окружения
check_env() {
    log_info "Checking environment variables..."
    
    if [ -z "$GITHUB_TOKEN" ]; then
        log_error "GITHUB_TOKEN is not set!"
        exit 1
    fi
    
    if [ -z "$REPO" ]; then
        export REPO="readonlyuser1/pvs"
        log_warning "REPO not set, using default: $REPO"
    fi
    
    if [ -z "$MAVEN_URL" ]; then
        export MAVEN_URL="https://repo1.maven.org/maven2/com/pvsstudio/pvsstudio-maven-plugin/maven-metadata.xml"
        log_warning "MAVEN_URL not set, using default"
    fi
    
    if [ -z "$DOWNLOAD_BASE" ]; then
        export DOWNLOAD_BASE="https://files.pvs-studio.com/java/pvsstudio-cores"
        log_warning "DOWNLOAD_BASE not set, using default"
    fi
    
    log_success "Environment checks passed"
}

# Получение последней версии из Maven
get_latest_version() {
    log_info "Getting latest version from Maven..."
    
    VERSIONS=$(curl -s -f "$MAVEN_URL" | \
        xmlstarlet sel -t -v "//version" 2>/dev/null || \
        grep -oP '(?<=<version>)[^<]+' | sort -V)
    
    if [ -z "$VERSIONS" ]; then
        log_error "Could not extract versions from Maven metadata"
        return 1
    fi
    
    LATEST=$(echo "$VERSIONS" | sort -V | tail -1)
    
    if ! echo "$LATEST" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
        log_error "Invalid version format: $LATEST"
        return 1
    fi
    
    echo "$LATEST"
}

# Проверка текущего релиза на GitHub
get_current_release() {
    log_info "Getting current release from GitHub..."
    
    RESPONSE=$(curl -s -f "https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null || echo '{"tag_name":"null"}')
    CURRENT=$(echo "$RESPONSE" | jq -r '.tag_name')
    
    if [ -z "$CURRENT" ] || [ "$CURRENT" = "null" ]; then
        echo "none"
    else
        echo "$CURRENT"
    fi
}

# Создание релиза
create_release() {
    local version="$1"
    local file_size="$2"
    
    log_info "Creating release for version $version..."
    
    RELEASE_DATA=$(cat <<EOF
{
    "tag_name": "$version",
    "name": "Release $version",
    "body": "## Automated Release from Maven Central\n\n- **Version:** $version\n- **Source:** Maven Central\n- **Date:** $(date -u +'%Y-%m-%d %H:%M:%S UTC')\n- **Size:** $file_size",
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
        -d "$RELEASE_DATA") || return 1
    
    if echo "$RESPONSE" | jq -e '.message' > /dev/null 2>&1; then
        ERROR_MSG=$(echo "$RESPONSE" | jq -r '.message')
        log_error "GitHub API error: $ERROR_MSG"
        return 1
    fi
    
    RELEASE_ID=$(echo "$RESPONSE" | jq -r '.id')
    if [ -z "$RELEASE_ID" ] || [ "$RELEASE_ID" = "null" ]; then
        log_error "Failed to get release ID"
        return 1
    fi
    
    echo "$RELEASE_ID"
}

# Загрузка ассета
upload_asset() {
    local release_id="$1"
    local version="$2"
    
    log_info "Uploading asset for version $version..."
    
    RESPONSE=$(curl -s -f -X POST \
        -H "Accept: application/vnd.github+json" \
        -H "Authorization: Bearer $GITHUB_TOKEN" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        -H "Content-Type: application/zip" \
        "https://uploads.github.com/repos/$REPO/releases/$release_id/assets?name=$version.zip" \
        --data-binary @"$version.zip") || return 1
    
    if echo "$RESPONSE" | jq -e '.message' > /dev/null 2>&1; then
        ERROR_MSG=$(echo "$RESPONSE" | jq -r '.message')
        log_error "Upload error: $ERROR_MSG"
        return 1
    fi
    
    UPLOAD_ID=$(echo "$RESPONSE" | jq -r '.id')
    if [ -z "$UPLOAD_ID" ] || [ "$UPLOAD_ID" = "null" ]; then
        log_error "Failed to get upload ID"
        return 1
    fi
    
    echo "$UPLOAD_ID"
}

# Основная функция
main() {
    log_info "Starting PVS Studio Updater..."
    
    # Проверка окружения
    check_env
    
    # Получение версий
    LATEST=$(get_latest_version) || exit 1
    CURRENT=$(get_current_release)
    
    log_info "Latest Maven version: $LATEST"
    log_info "Current GitHub release: $CURRENT"
    
    if [ "$CURRENT" = "$LATEST" ]; then
        log_success "Version $LATEST already exists, skipping"
        echo "status=skipped" >> $GITHUB_OUTPUT 2>/dev/null || echo "status=skipped"
        echo "version=$LATEST" >> $GITHUB_OUTPUT 2>/dev/null || echo "version=$LATEST"
        exit 0
    fi
    
    # Скачивание файла
    log_info "Downloading $LATEST..."
    FILE_URL="$DOWNLOAD_BASE/$LATEST.zip"
    
    if ! curl -s -f -I "$FILE_URL" > /dev/null 2>&1; then
        log_error "File not found at $FILE_URL"
        exit 1
    fi
    
    if ! wget --timeout=30 --tries=3 "$FILE_URL"; then
        log_error "Failed to download file"
        exit 1
    fi
    
    if [ ! -f "$LATEST.zip" ] || [ ! -s "$LATEST.zip" ]; then
        log_error "Downloaded file is invalid"
        exit 1
    fi
    
    FILE_SIZE=$(stat -c%s "$LATEST.zip" 2>/dev/null || stat -f%z "$LATEST.zip" 2>/dev/null)
    FILE_SIZE_HUMAN=$(numfmt --to=iec $FILE_SIZE 2>/dev/null || echo "$FILE_SIZE bytes")
    log_success "Downloaded: $FILE_SIZE_HUMAN"
    
    # Создание релиза
    RELEASE_ID=$(create_release "$LATEST" "$FILE_SIZE_HUMAN") || exit 1
    log_success "Release created: $RELEASE_ID"
    
    # Загрузка ассета
    UPLOAD_ID=$(upload_asset "$RELEASE_ID" "$LATEST") || exit 1
    log_success "Asset uploaded: $UPLOAD_ID"
    
    # Очистка
    rm -f "$LATEST.zip"
    
    RELEASE_URL="https://github.com/$REPO/releases/tag/$LATEST"
    log_success "Release created successfully!"
    log_success "🔗 $RELEASE_URL"
    
    echo "status=success" >> $GITHUB_OUTPUT 2>/dev/null || echo "status=success"
    echo "version=$LATEST" >> $GITHUB_OUTPUT 2>/dev/null || echo "version=$LATEST"
    echo "release_url=$RELEASE_URL" >> $GITHUB_OUTPUT 2>/dev/null || echo "release_url=$RELEASE_URL"
}

# Запуск
main "$@"