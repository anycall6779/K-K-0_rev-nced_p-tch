#!/bin/bash
#
# APKM Version Selector + Auto-Merger + Auto-Patcher (for revanced-build-script)
# Fixed Version v2.1 - Updated APKMirror Scraping
#
set -euo pipefail

# --- 1. Basic Config & Variables ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# App Info
APP_NAME="KakaoTalk"
PKG_NAME="com.kakao.talk"
APKMIRROR_BASE_URL="https://www.apkmirror.com/apk/kakao-corp/kakaotalk"

# Paths
BASE_DIR="/storage/emulated/0/Download"
PATCH_SCRIPT_DIR="$HOME/revanced-build-script"
MERGED_APK_PATH="$HOME/Downloads/KakaoTalk.apk"
EDITOR_JAR="$BASE_DIR/APKEditor-1.4.5.jar"

# Environment
USER_AGENT="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
ARCH=$(getprop ro.product.cpu.abi 2>/dev/null || echo "arm64-v8a")
DPI=$(getprop ro.sf.lcd_density 2>/dev/null || echo "480")
LOCALE=$(getprop persist.sys.locale 2>/dev/null | sed 's/-.*//g' || echo "ko")
[ "$ARCH" = "arm64-v8a" ] && ARCH_APK="arm64" || ARCH_APK="armeabi"

# Tools
DIALOG=(dialog --keep-tite --no-shadow --no-collapse --visit-items --ok-label "선택" --cancel-label "취소")
CURL=(curl -L -s -k --compressed --retry 3 --retry-delay 1 --max-time 30)
WGET=(wget --quiet --show-progress --progress=bar:force:noscroll --no-check-certificate --timeout=30)

# Logging
LOG_FILE="$BASE_DIR/patch_script.log"
exec 1> >(tee -a "$LOG_FILE")
exec 2>&1

# --- 2. Utility Functions ---
log_info() { echo -e "${BLUE}[INFO]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $*"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $*"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $*"; }

cleanup_temp_files() {
    log_info "Cleaning up temporary files..."
    rm -f "$BASE_DIR"/*.apkm 2>/dev/null || true
    rm -rf "$BASE_DIR/mod_temp_merge" 2>/dev/null || true
}

trap cleanup_temp_files EXIT

# --- 3. Dependency Check ---
check_dependencies() {
    log_info "Checking dependencies..."
    local MISSING=0
    
    for cmd in dialog curl pup jq wget unzip java python git; do
        if ! command -v "$cmd" &> /dev/null; then
            log_error "'$cmd' not found. Please run: pkg install $cmd"
            MISSING=1
        fi
    done
    
    if command -v java &> /dev/null; then
        JAVA_VERSION=$(java -version 2>&1 | head -n 1 | cut -d'"' -f2 | cut -d'.' -f1)
        if [ "$JAVA_VERSION" -lt 11 ]; then
            log_error "Java 11+ required. Current: $JAVA_VERSION"
            MISSING=1
        fi
    fi
    
    if [ ! -d "$PATCH_SCRIPT_DIR" ]; then
        log_error "Patch script directory not found: $PATCH_SCRIPT_DIR"
        log_warning "Clone it: git clone https://git.naijun.dev/ReVanced/revanced-build-script.git ~/revanced-build-script"
        MISSING=1
    fi
    
    if [ ! -f "$EDITOR_JAR" ]; then
        log_warning "APKEditor not found. Downloading..."
        if "${WGET[@]}" -O "$EDITOR_JAR" "https://github.com/REAndroid/APKEditor/releases/download/V1.4.5/APKEditor-1.4.5.jar"; then
            log_success "APKEditor downloaded"
        else
            log_error "Failed to download APKEditor"
            MISSING=1
        fi
    fi
    
    [ $MISSING -eq 1 ] && exit 1
    mkdir -p "$HOME/Downloads" "$BASE_DIR"
    log_success "All dependencies satisfied"
}

# --- 4. NEW: Fixed Version Selection ---
choose_version() {
    log_info "Fetching version list from APKMirror..."
    
    local PAGE_CONTENTS
    if ! PAGE_CONTENTS=$("${CURL[@]}" -A "$USER_AGENT" "$APKMIRROR_BASE_URL/"); then
        log_error "Failed to fetch APKMirror main page"
        return 1
    fi
    
    if [ -z "$PAGE_CONTENTS" ]; then
        log_error "Empty response from APKMirror"
        return 1
    fi
    
    # NEW METHOD: Extract from the main app page
    # Look for release links in the "All Releases" section
    local RELEASE_LINKS
    RELEASE_LINKS=$(echo "$PAGE_CONTENTS" | \
        pup 'div.listWidget div.appRow h5 a attr{href}' 2>/dev/null | \
        grep -E '/kakaotalk.*-release/' | \
        head -n 15)
    
    if [ -z "$RELEASE_LINKS" ]; then
        log_warning "Method 1 failed. Trying alternative parsing..."
        
        # Alternative: Look for any links to release pages
        RELEASE_LINKS=$(echo "$PAGE_CONTENTS" | \
            pup 'a[href*="kakaotalk"][href*="-release"] attr{href}' 2>/dev/null | \
            sort -u | \
            head -n 15)
    fi
    
    if [ -z "$RELEASE_LINKS" ]; then
        log_error "Failed to extract version links"
        log_warning "Trying manual version list..."
        
        # Fallback: Use known recent versions
        RELEASE_LINKS=$(cat <<EOF
/apk/kakao-corp/kakaotalk/kakaotalk-messenger-25-9-0-release/
/apk/kakao-corp/kakaotalk/kakaotalk-messenger-25-8-3-release/
/apk/kakao-corp/kakaotalk/kakaotalk-messenger-25-8-2-release/
/apk/kakao-corp/kakaotalk/kakaotalk-messenger-25-8-1-release/
/apk/kakao-corp/kakaotalk/kakaotalk-messenger-25-7-3-release/
EOF
)
    fi
    
    # Extract versions from URLs and create menu
    local -a MENU_ITEMS=()
    local version_count=0
    
    while IFS= read -r url; do
        [ -z "$url" ] && continue
        
        # Extract version from URL (e.g., "25-9-0" -> "25.9.0")
        local version=$(echo "$url" | \
            sed -n 's|.*/kakaotalk.*-\([0-9]\+-[0-9]\+-[0-9]\+\)-release.*|\1|p' | \
            tr '-' '.')
        
        [ -z "$version" ] && continue
        
        MENU_ITEMS+=("$version" "$url")
        ((version_count++))
        
    done <<< "$RELEASE_LINKS"
    
    if [ "${#MENU_ITEMS[@]}" -eq 0 ]; then
        log_error "No versions found"
        return 1
    fi
    
    log_success "Found $version_count versions"
    
    # Show dialog - dialog returns the selected TAG (version), not ITEM (URL)
    local SELECTED_VERSION
    if ! SELECTED_VERSION=$(
        "${DIALOG[@]}" \
            --title "| KakaoTalk Version Selection |" \
            --menu "Select version to patch:" 20 60 15 \
            "${MENU_ITEMS[@]}" \
            2>&1 > /dev/tty
    ); then
        log_warning "User cancelled"
        return 1
    fi
    
    if [ -z "$SELECTED_VERSION" ]; then
        log_error "Invalid selection"
        return 1
    fi
    
    # Find the URL corresponding to the selected version
    local SELECTED_URL=""
    for ((i=0; i<${#MENU_ITEMS[@]}; i+=2)); do
        if [ "${MENU_ITEMS[$i]}" = "$SELECTED_VERSION" ]; then
            SELECTED_URL="${MENU_ITEMS[$i+1]}"
            break
        fi
    done
    
    if [ -z "$SELECTED_URL" ]; then
        log_error "Could not find URL for version: $SELECTED_VERSION"
        return 1
    fi
    
    APP_DL_URL="https://www.apkmirror.com$SELECTED_URL"
    APP_VER="$SELECTED_VERSION"
    
    log_success "Selected version: $APP_VER"
    log_info "Page: $APP_DL_URL"
}

# --- 5. Download Link Scraper ---
scrape_download_link() {
    log_info "Step 1/3: Analyzing version page..."
    
    local PAGE1
    if ! PAGE1=$("${CURL[@]}" -A "$USER_AGENT" "$APP_DL_URL"); then
        log_error "Failed to fetch version page"
        return 1
    fi
    
    # Look for "BUNDLE" or universal APK
    local URL1
    URL1=$(echo "$PAGE1" | \
        pup 'div.table-cell a[href*="/download/"] attr{href}' 2>/dev/null | \
        head -n 1)
    
    if [ -z "$URL1" ]; then
        log_error "No download link found on version page"
        log_info "Trying alternative method..."
        
        # Alternative: Look in variants table
        URL1=$(echo "$PAGE1" | \
            pup 'div.variants-table a attr{href}' 2>/dev/null | \
            grep -v '#' | \
            head -n 1)
    fi
    
    if [ -z "$URL1" ]; then
        log_error "Could not find download link"
        return 1
    fi
    
    log_success "Found variant link"
    
    log_info "Step 2/3: Analyzing download page..."
    local PAGE2 URL2
    if ! PAGE2=$("${CURL[@]}" -A "$USER_AGENT" "https://www.apkmirror.com$URL1"); then
        log_error "Failed to fetch download page"
        return 1
    fi
    
    URL2=$(echo "$PAGE2" | \
        pup 'a.downloadButton attr{href}' 2>/dev/null | \
        grep -v 'google-vignette' | \
        head -n 1)
    
    if [ -z "$URL2" ]; then
        log_error "Download button not found"
        return 1
    fi
    
    log_info "Step 3/3: Getting final link..."
    local PAGE3 URL3
    if ! PAGE3=$("${CURL[@]}" -A "$USER_AGENT" "https://www.apkmirror.com$URL2"); then
        log_error "Failed to fetch final page"
        return 1
    fi
    
    URL3=$(echo "$PAGE3" | \
        pup 'a[rel="nofollow"] attr{href}' 2>/dev/null | \
        grep -E '\.(apkm|apk)$' | \
        head -n 1)
    
    if [ -z "$URL3" ]; then
        log_error "Final download link not found"
        return 1
    fi

    APP_URL="https://www.apkmirror.com$URL3"
    APKM_FILE="$BASE_DIR/${APP_NAME}-${APP_VER}.apkm"
    
    log_success "Download link acquired!"
}

# --- 6. Download & Merge ---
download_and_merge() {
    log_info "Downloading: $APP_NAME-$APP_VER"
    
    rm -f "$APKM_FILE"
    
    if ! "${WGET[@]}" "$APP_URL" -O "$APKM_FILE"; then
        log_error "Download failed"
        return 1
    fi
    
    if [ ! -f "$APKM_FILE" ]; then
        log_error "File not found after download"
        return 1
    fi
    
    local FILE_SIZE=$(du -h "$APKM_FILE" | cut -f1)
    log_success "Downloaded: $FILE_SIZE"
    
    log_info "Extracting and merging..."
    local TEMP_DIR="$BASE_DIR/mod_temp_merge"
    rm -rf "$TEMP_DIR"
    mkdir -p "$TEMP_DIR"
    
    if ! unzip -qqo "$APKM_FILE" -d "$TEMP_DIR" 2>/dev/null; then
        log_error "Failed to extract APKM"
        return 1
    fi
    
    if [ ! -f "$TEMP_DIR/base.apk" ]; then
        log_error "base.apk not found"
        ls -lh "$TEMP_DIR"
        return 1
    fi
    
    local SPLIT_COUNT=$(find "$TEMP_DIR" -name "*.apk" | wc -l)
    log_info "Found $SPLIT_COUNT APK files"
    
    log_info "Running APKEditor merge..."
    rm -f "$MERGED_APK_PATH"
    
    if ! java -jar "$EDITOR_JAR" m -i "$TEMP_DIR" -o "$MERGED_APK_PATH" 2>&1 | \
        grep -v "WARNING" | grep -v "^$"; then
        :
    fi
    
    if [ ! -f "$MERGED_APK_PATH" ]; then
        log_error "Merge failed"
        return 1
    fi
    
    local MERGED_SIZE=$(du -h "$MERGED_APK_PATH" | cut -f1)
    log_success "Merge complete: $MERGED_SIZE"
    
    rm -f "$APKM_FILE"
    rm -rf "$TEMP_DIR"
}

# --- 7. Run Patch ---
run_patch() {
    log_success "Starting ReVanced patch..."
    
    if [ ! -f "$PATCH_SCRIPT_DIR/build.py" ]; then
        log_error "build.py not found"
        return 1
    fi
    
    cd "$PATCH_SCRIPT_DIR" || return 1
    
    log_info "Running build.py..."
    
    if ! python build.py \
        --apk "$MERGED_APK_PATH" \
        --package "$PKG_NAME" \
        --include-universal \
        --run; then
        log_error "Patch failed (exit code: $?)"
        return 1
    fi
    
    log_success "Patch completed!"
}

# --- 8. Main ---
main() {
    clear
    echo -e "${GREEN}╔════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║  KakaoTalk Auto-Merge & Patch Script  ║${NC}"
    echo -e "${GREEN}║         Fixed Version v2.1            ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════╝${NC}"
    echo ""
    
    log_info "Log: $LOG_FILE"
    log_info "Arch: $ARCH, DPI: $DPI, Locale: $LOCALE"
    echo ""
    
    check_dependencies || exit 1
    choose_version || exit 0
    scrape_download_link || exit 1
    download_and_merge || exit 1
    run_patch || exit 1
    
    echo ""
    echo -e "${GREEN}╔════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║         ALL TASKS COMPLETE! ✓         ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════╝${NC}"
    echo ""
    log_success "Patched APK: $PATCH_SCRIPT_DIR/out/"
    log_info "Log: $LOG_FILE"
}

main "$@"
