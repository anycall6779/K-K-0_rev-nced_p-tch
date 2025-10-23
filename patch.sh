#!/bin/bash
#
# KakaoTalk Auto-Merge & Patch Script
# v3.0 - Revancify Architecture
#
set -euo pipefail

# ==================== CONFIGURATION ====================
APP_NAME="KakaoTalk"
PKG_NAME="com.kakao.talk"
APKMIRROR_ORG="kakao-corp"
APKMIRROR_APP="kakaotalk"

BASE_DIR="/storage/emulated/0/Download"
PATCH_SCRIPT_DIR="$HOME/revanced-build-script"
MERGED_APK_PATH="$HOME/Downloads/KakaoTalk.apk"
EDITOR_JAR="$BASE_DIR/APKEditor-1.4.5.jar"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Environment
USER_AGENT="Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36"
ARCH=$(getprop ro.product.cpu.abi 2>/dev/null || echo "arm64-v8a")
DPI=$(getprop ro.sf.lcd_density 2>/dev/null || echo "480")
LOCALE=$(getprop persist.sys.locale 2>/dev/null | sed 's/-.*//g' || echo "ko")
[ "$ARCH" = "arm64-v8a" ] && ARCH_APK="arm64-v8a" || ARCH_APK="armeabi-v7a"

# Tools
DIALOG=(dialog --keep-tite --no-shadow --no-collapse --visit-items --ok-label "선택" --cancel-label "취소")
CURL=(curl -sL --fail-early --connect-timeout 5 --max-time 10 -H 'Cache-Control: no-cache' -A "$USER_AGENT")
WGET=(wget -qc --show-progress --user-agent="$USER_AGENT")

# ==================== UTILITY FUNCTIONS ====================
log() { echo -e "${BLUE}[$(date '+%H:%M:%S')]${NC} $*"; }
success() { echo -e "${GREEN}[$(date '+%H:%M:%S')]${NC} $*"; }
warning() { echo -e "${YELLOW}[$(date '+%H:%M:%S')]${NC} $*"; }
error() { echo -e "${RED}[$(date '+%H:%M:%S')]${NC} $*"; }

notify() {
    dialog --no-shadow --"$1"box "$2" 12 50
}

cleanup() {
    log "Cleaning up..."
    rm -f "$BASE_DIR"/*.apkm "$BASE_DIR"/debug_*.html 2>/dev/null || true
    rm -rf "$BASE_DIR/mod_temp_merge" 2>/dev/null || true
    tput cnorm
}

trap cleanup EXIT

internet() {
    if ! ping -c 1 8.8.8.8 &> /dev/null; then
        notify msg "No Internet Connection!\n\nConnect and try again."
        return 1
    fi
}

# ==================== DEPENDENCY CHECK ====================
check_dependencies() {
    log "Checking dependencies..."
    local MISSING=0
    
    for cmd in dialog curl pup jq wget unzip java python git; do
        if ! command -v "$cmd" &> /dev/null; then
            error "'$cmd' not found. Install: pkg install $cmd"
            MISSING=1
        fi
    done
    
    if [ ! -d "$PATCH_SCRIPT_DIR" ]; then
        error "Patch script not found: $PATCH_SCRIPT_DIR"
        warning "Clone: git clone https://git.naijun.dev/ReVanced/revanced-build-script.git ~/revanced-build-script"
        MISSING=1
    fi
    
    if [ ! -f "$EDITOR_JAR" ]; then
        warning "Downloading APKEditor..."
        "${WGET[@]}" -O "$EDITOR_JAR" "https://github.com/REAndroid/APKEditor/releases/download/V1.4.5/APKEditor-1.4.5.jar" || {
            error "Failed to download APKEditor";
            MISSING=1;
        }
    fi
    
    [ $MISSING -eq 1 ] && exit 1
    mkdir -p "$HOME/Downloads" "$BASE_DIR"
    success "Dependencies OK"
}

# ==================== APKMIRROR FUNCTIONS (from Revancify) ====================
fetch_app_info() {
    log "Fetching app info from APKMirror API..."
    
    local RESPONSE
    if ! RESPONSE=$("${CURL[@]}" \
        'https://www.apkmirror.com/wp-json/apkm/v1/app_exists/' \
        -H 'Accept: application/json' \
        -H 'Content-Type: application/json' \
        -H 'Authorization: Basic YXBpLXRvb2xib3gtZm9yLWdvb2dsZS1wbGF5OkNiVVcgQVVMZyBNRVJXIHU4M3IgS0s0SCBEbmJL' \
        -d "{\"pnames\":[\"$PKG_NAME\"]}" 2>/dev/null); then
        error "API request failed"
        return 1
    fi
    
    # Parse response
    APKMIRROR_APP_NAME=$(echo "$RESPONSE" | \
        jq -r ".data[] | select(.pname == \"$PKG_NAME\") | .app.link" 2>/dev/null | \
        sed 's|.*\/||; s|\/$||')
    
    if [ -z "$APKMIRROR_APP_NAME" ]; then
        error "App not found in APKMirror"
        return 1
    fi
    
    success "Found: $APKMIRROR_APP_NAME"
}

fetch_versions() {
    log "Fetching available versions..."
    
    local PAGE_URL="https://www.apkmirror.com/apk/$APKMIRROR_ORG/$APKMIRROR_APP_NAME/"
    local PAGE_CONTENT
    
    if ! PAGE_CONTENT=$("${CURL[@]}" "$PAGE_URL" 2>/dev/null); then
        error "Failed to fetch versions page"
        return 1
    fi
    
    # Extract version links
    readarray -t VERSION_LINKS < <(
        echo "$PAGE_CONTENT" | \
        pup 'div.listWidget div.appRow h5.appRowTitle a attr{href}' 2>/dev/null | \
        grep -E "/$APKMIRROR_APP_NAME.*-release/" | \
        head -n 15
    )
    
    if [ "${#VERSION_LINKS[@]}" -eq 0 ]; then
        error "No versions found"
        return 1
    fi
    
    success "Found ${#VERSION_LINKS[@]} versions"
}

choose_version() {
    local -a MENU_ITEMS=()
    
    for link in "${VERSION_LINKS[@]}"; do
        # Extract version from URL
        local version=$(echo "$link" | \
            sed -n 's|.*/'"$APKMIRROR_APP_NAME"'.*-\([0-9]\+\(-[0-9]\+\)*\)-release.*|\1|p' | \
            tr '-' '.')
        
        [ -z "$version" ] && continue
        
        MENU_ITEMS+=("$version" "$link")
    done
    
    if [ "${#MENU_ITEMS[@]}" -eq 0 ]; then
        error "Failed to parse versions"
        return 1
    fi
    
    local SELECTED_VERSION
    if ! SELECTED_VERSION=$(
        "${DIALOG[@]}" \
            --title "| $APP_NAME Version Selection |" \
            --menu "Select version to patch:" 20 60 15 \
            "${MENU_ITEMS[@]}" \
            2>&1 > /dev/tty
    ); then
        warning "Cancelled"
        return 1
    fi
    
    # Find corresponding URL
    for ((i=0; i<"${#MENU_ITEMS[@]}"; i+=2)); do
        if [ "${MENU_ITEMS[$i]}" = "$SELECTED_VERSION" ]; then
            APP_VER="$SELECTED_VERSION"
            APP_URL="https://www.apkmirror.com${MENU_ITEMS[$((i+1))]}"
            break
        fi
    done
    
    success "Selected: v$APP_VER"
}

# ==================== DOWNLOAD FUNCTIONS ====================
download_apk() {
    log "Analyzing download page..."
    
    local PAGE1 DOWNLOAD_LINK VARIANT_LINK
    
    # Step 1: Get version page
    if ! PAGE1=$("${CURL[@]}" "$APP_URL" 2>/dev/null); then
        error "Failed to fetch version page"
        return 1
    fi
    
    # Find BUNDLE download link
    VARIANT_LINK=$(echo "$PAGE1" | \
        pup 'div.table-row a.accent_color attr{href}' 2>/dev/null | \
        grep -i 'bundle\|universal' | \
        head -n 1)
    
    if [ -z "$VARIANT_LINK" ]; then
        # Fallback: get first variant
        VARIANT_LINK=$(echo "$PAGE1" | \
            pup 'div.variants-table a attr{href}' 2>/dev/null | \
            head -n 1)
    fi
    
    if [ -z "$VARIANT_LINK" ]; then
        error "No variant found"
        return 1
    fi
    
    log "Found variant: $(basename "$VARIANT_LINK")"
    
    # Step 2: Get download button page
    local PAGE2 DOWNLOAD_BTN
    if ! PAGE2=$("${CURL[@]}" "https://www.apkmirror.com$VARIANT_LINK" 2>/dev/null); then
        error "Failed to fetch download page"
        return 1
    fi
    
    DOWNLOAD_BTN=$(echo "$PAGE2" | \
        pup 'a.downloadButton attr{href}' 2>/dev/null | \
        head -n 1)
    
    if [ -z "$DOWNLOAD_BTN" ]; then
        error "Download button not found"
        return 1
    fi
    
    # Step 3: Get final download link
    local PAGE3 FINAL_LINK
    if ! PAGE3=$("${CURL[@]}" "https://www.apkmirror.com$DOWNLOAD_BTN" 2>/dev/null); then
        error "Failed to fetch final page"
        return 1
    fi
    
    FINAL_LINK=$(echo "$PAGE3" | \
        pup 'a[rel="nofollow"] attr{href}' 2>/dev/null | \
        grep -E '\.(apkm|apk)' | \
        head -n 1)
    
    if [ -z "$FINAL_LINK" ]; then
        error "Final link not found"
        return 1
    fi
    
    # Handle absolute/relative URLs
    if [[ "$FINAL_LINK" =~ ^http ]]; then
        DOWNLOAD_URL="$FINAL_LINK"
    else
        DOWNLOAD_URL="https://www.apkmirror.com$FINAL_LINK"
    fi
    
    success "Download link acquired"
    
    # Download file
    local OUTPUT_FILE="$BASE_DIR/${APP_NAME}-${APP_VER}.apkm"
    log "Downloading..."
    
    if ! "${WGET[@]}" "$DOWNLOAD_URL" -O "$OUTPUT_FILE" 2>&1 | \
        stdbuf -o0 grep -oP '\d+(?=%)' | \
        "${DIALOG[@]}" --gauge "Downloading $APP_NAME v$APP_VER" 10 60 0; then
        error "Download failed"
        return 1
    fi
    tput civis
    
    if [ ! -f "$OUTPUT_FILE" ]; then
        error "File not found after download"
        return 1
    fi
    
    local FILE_SIZE=$(du -h "$OUTPUT_FILE" | cut -f1)
    success "Downloaded: $FILE_SIZE"
    
    APKM_FILE="$OUTPUT_FILE"
}

# ==================== MERGE FUNCTIONS ====================
merge_apk() {
    log "Extracting APKM bundle..."
    
    local TEMP_DIR="$BASE_DIR/mod_temp_merge"
    rm -rf "$TEMP_DIR"
    mkdir -p "$TEMP_DIR"
    
    # Extract all APKs
    if ! unzip -qqo "$APKM_FILE" -d "$TEMP_DIR" 2>/dev/null; then
        error "Failed to extract APKM"
        return 1
    fi
    
    # Verify base.apk exists
    if [ ! -f "$TEMP_DIR/base.apk" ]; then
        error "base.apk not found in bundle"
        ls -lh "$TEMP_DIR"
        return 1
    fi
    
    local SPLIT_COUNT=$(find "$TEMP_DIR" -name "*.apk" | wc -l)
    log "Found $SPLIT_COUNT APK files to merge"
    
    # Merge with APKEditor
    log "Merging with APKEditor..."
    rm -f "$MERGED_APK_PATH"
    
    {
        java -jar "$EDITOR_JAR" m \
            -i "$TEMP_DIR" \
            -o "$MERGED_APK_PATH" 2>&1 | \
            grep -v "WARNING" || true
    } | "${DIALOG[@]}" --programbox "Merging APK splits..." 20 80
    tput civis
    
    if [ ! -f "$MERGED_APK_PATH" ]; then
        error "Merge failed"
        return 1
    fi
    
    local MERGED_SIZE=$(du -h "$MERGED_APK_PATH" | cut -f1)
    success "Merged APK: $MERGED_SIZE"
    
    # Cleanup
    rm -f "$APKM_FILE"
    rm -rf "$TEMP_DIR"
}

# ==================== PATCH FUNCTIONS ====================
patch_apk() {
    log "Starting ReVanced patch process..."
    
    if [ ! -f "$PATCH_SCRIPT_DIR/build.py" ]; then
        error "build.py not found in $PATCH_SCRIPT_DIR"
        return 1
    fi
    
    cd "$PATCH_SCRIPT_DIR" || return 1
    
    log "Running build.py..."
    log "  APK: $MERGED_APK_PATH"
    log "  Package: $PKG_NAME"
    
    if ! python build.py \
        --apk "$MERGED_APK_PATH" \
        --package "$PKG_NAME" \
        --include-universal \
        --run 2>&1 | \
        "${DIALOG[@]}" --programbox "Patching $APP_NAME v$APP_VER" 30 100; then
        error "Patching failed"
        return 1
    fi
    tput civis
    
    success "Patch completed!"
}

# ==================== MAIN WORKFLOW ====================
main() {
    clear
    echo -e "${GREEN}╔════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║  KakaoTalk Auto-Merge & Patch Script  ║${NC}"
    echo -e "${GREEN}║    v3.0 - Revancify Architecture      ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════╝${NC}"
    echo ""
    
    log "Arch: $ARCH, DPI: $DPI, Locale: $LOCALE"
    echo ""
    
    # Check dependencies
    check_dependencies || exit 1
    
    # Check internet
    internet || exit 1
    
    # Fetch app info from APKMirror API
    fetch_app_info || exit 1
    
    # Fetch available versions
    fetch_versions || exit 1
    
    # Let user choose version
    choose_version || exit 0
    
    # Download APK
    download_apk || exit 1
    
    # Merge APKM
    merge_apk || exit 1
    
    # Patch APK
    patch_apk || exit 1
    
    # Done
    echo ""
    echo -e "${GREEN}╔════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║         ALL TASKS COMPLETE! ✓         ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════╝${NC}"
    echo ""
    success "Patched APK location:"
    echo -e "${CYAN}  → $PATCH_SCRIPT_DIR/out/${NC}"
    echo ""
    
    # Offer to install
    if "${DIALOG[@]}" \
        --title "| Installation |" \
        --yesno "Patch completed!\n\nOpen patched APK?" 10 40; then
        termux-open "$PATCH_SCRIPT_DIR/out/"*.apk 2>/dev/null || true
    fi
}

# Run
main "$@"
