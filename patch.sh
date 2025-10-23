#!/bin/bash
#
# APKM Version Selector + Auto-Merger + Auto-Patcher (for revanced-build-script)
# Improved Version with Better Error Handling and Logging
#
set -euo pipefail # Exit on error, undefined variables, and pipeline failures

# --- 1. Basic Config & Variables ---
# Color Codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# App-specific Info
APP_NAME="KakaoTalk"
PKG_NAME="com.kakao.talk"
APKMIRROR_APP_NAME="kakaotalk"

# Path Config
BASE_DIR="/storage/emulated/0/Download"
PATCH_SCRIPT_DIR="$HOME/revanced-build-script"
MERGED_APK_PATH="$HOME/Downloads/KakaoTalk.apk"

# Tool Paths
EDITOR_JAR="$BASE_DIR/APKEditor-1.4.5.jar"

# Environment
USER_AGENT="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
ARCH=$(getprop ro.product.cpu.abi 2>/dev/null || echo "arm64-v8a")
DPI=$(getprop ro.sf.lcd_density 2>/dev/null || echo "480")
LOCALE=$(getprop persist.sys.locale 2>/dev/null | sed 's/-.*//g' || echo "en")
[ "$ARCH" = "arm64-v8a" ] && ARCH_APK="arm64" || ARCH_APK="armeabi"

# Termux UI Tools
DIALOG=(dialog --keep-tite --no-shadow --no-collapse --visit-items --ok-label "선택" --cancel-label "취소")
CURL=(curl -L -s -k --compressed --retry 3 --retry-delay 1 --max-time 30)
WGET=(wget --quiet --show-progress --progress=bar:force:noscroll --no-check-certificate --timeout=30)

# Logging
LOG_FILE="$BASE_DIR/patch_script.log"
exec 1> >(tee -a "$LOG_FILE")
exec 2>&1

# --- 2. Utility Functions ---
log_info() {
    echo -e "${BLUE}[INFO]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $*"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $*"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $*"
}

cleanup_temp_files() {
    log_info "Cleaning up temporary files..."
    rm -f "$BASE_DIR"/*.apkm 2>/dev/null || true
    rm -rf "$BASE_DIR/mod_temp_merge" 2>/dev/null || true
}

# Trap for cleanup on exit
trap cleanup_temp_files EXIT

# --- 3. Dependency Check Function ---
check_dependencies() {
    log_info "Checking dependencies..."
    local MISSING=0
    
    for cmd in dialog curl pup jq wget unzip java python git; do
        if ! command -v "$cmd" &> /dev/null; then
            log_error "'$cmd' not found. Please run: pkg install $cmd"
            MISSING=1
        fi
    done
    
    # Check Java version
    if command -v java &> /dev/null; then
        JAVA_VERSION=$(java -version 2>&1 | head -n 1 | cut -d'"' -f2 | cut -d'.' -f1)
        if [ "$JAVA_VERSION" -lt 11 ]; then
            log_error "Java 11+ required. Current: $JAVA_VERSION"
            MISSING=1
        fi
    fi
    
    if [ ! -d "$PATCH_SCRIPT_DIR" ]; then
        log_error "Patch script directory not found: $PATCH_SCRIPT_DIR"
        log_warning "Please clone: git clone https://git.naijun.dev/ReVanced/revanced-build-script.git ~/revanced-build-script"
        MISSING=1
    fi
    
    if [ ! -f "$EDITOR_JAR" ]; then
        log_warning "$EDITOR_JAR not found. Attempting to download..."
        if "${WGET[@]}" -O "$EDITOR_JAR" "https://github.com/REAndroid/APKEditor/releases/download/V1.4.5/APKEditor-1.4.5.jar"; then
            log_success "APKEditor downloaded successfully"
        else
            log_error "Failed to download APKEditor"
            MISSING=1
        fi
    fi
    
    [ $MISSING -eq 1 ] && exit 1
    
    # Ensure required directories exist
    mkdir -p "$HOME/Downloads" "$BASE_DIR"
    
    log_success "All dependencies satisfied"
}

# --- 4. Version Scraping & Selection (IMPROVED) ---
choose_version() {
    log_info "Fetching version list from APKMirror..."
    
    local PAGE_CONTENTS
    if ! PAGE_CONTENTS=$("${CURL[@]}" -A "$USER_AGENT" "https://www.apkmirror.com/uploads/?appcategory=$APKMIRROR_APP_NAME"); then
        log_error "Failed to fetch APKMirror page"
        return 1
    fi
    
    if [ -z "$PAGE_CONTENTS" ]; then
        log_error "Empty response from APKMirror"
        return 1
    fi
    
    # Extract versions and URLs separately
    local VERSIONS URLS
    VERSIONS=$(echo "$PAGE_CONTENTS" | pup 'div.listWidget .appRow > a > div > span.appVersion text{}' 2>/dev/null)
    URLS=$(echo "$PAGE_CONTENTS" | pup 'div.listWidget .appRow > a attr{href}' 2>/dev/null)
    
    if [ -z "$VERSIONS" ] || [ -z "$URLS" ]; then
        log_error "Failed to parse versions or URLs from APKMirror"
        log_warning "The page structure may have changed. Please report this issue."
        return 1
    fi
    
    # Create dialog menu array
    local -a MENU_ITEMS=()
    local version_count=0
    
    while IFS= read -r version && IFS= read -r url <&3; do
        [ -z "$version" ] && continue
        [ -z "$url" ] && continue
        
        MENU_ITEMS+=("$version" "$url")
        ((version_count++))
        
        # Limit to 15 versions
        [ $version_count -ge 15 ] && break
    done < <(echo "$VERSIONS") 3< <(echo "$URLS")
    
    if [ ${#MENU_ITEMS[@]} -eq 0 ]; then
        log_error "No versions found. The scraper may be broken."
        return 1
    fi
    
    log_info "Found $version_count versions"
    
    local SELECTED_URL
    if ! SELECTED_URL=$(
        "${DIALOG[@]}" \
            --title "| KakaoTalk Version Selection |" \
            --menu "Select the version to patch:" 20 60 15 \
            "${MENU_ITEMS[@]}" \
            2>&1 > /dev/tty
    ); then
        log_warning "User cancelled version selection"
        return 1
    fi
    
    if [ -z "$SELECTED_URL" ] || [ "$SELECTED_URL" = "null" ]; then
        log_error "Invalid selection (empty or null)"
        return 1
    fi
    
    APP_DL_URL="https://www.apkmirror.com$SELECTED_URL"
    APP_VER=$(echo "$SELECTED_URL" | sed -n 's|.*/kakaotalk-\(.*\)-release.*|\1|p')
    
    if [ -z "$APP_VER" ]; then
        log_error "Failed to extract version number from URL: $SELECTED_URL"
        return 1
    fi
    
    log_success "Selected version: $APP_VER"
    log_info "Download page: $APP_DL_URL"
}

# --- 5. Automatic Download Link Scraper (IMPROVED) ---
scrape_download_link() {
    log_info "Step 1/3: Analyzing version page..."
    
    local PAGE1
    if ! PAGE1=$("${CURL[@]}" -A "$USER_AGENT" "$APP_DL_URL"); then
        log_error "Failed to fetch version page"
        return 1
    fi
    
    # Extract variant information with better error handling
    local VARIANT_JSON URL1
    VARIANT_JSON=$(echo "$PAGE1" | pup 'div.variants-table json{}' 2>/dev/null)
    
    if [ -z "$VARIANT_JSON" ]; then
        log_error "Failed to parse variants table"
        return 1
    fi
    
    # Find compatible variant (prioritize BUNDLE, then universal, then architecture-specific)
    URL1=$(echo "$VARIANT_JSON" | jq -r \
        --arg ARCH "$ARCH" \
        --arg DPI "$DPI" '
        [
            .[].children[1:][].children |
            if (.[1].text | test("universal|noarch|\($ARCH)"; "i")) and
               (.[3].text | test("nodpi"; "i") or 
                   (capture("(?<low>\\d+)-(?<high>\\d+)"; "i") | 
                   (($DPI | tonumber) <= (.high | tonumber)) and (($DPI | tonumber) >= (.low | tonumber)))
               )
            then {
                href: .[0].children[0].href,
                type: .[1].text,
                priority: (if (.[1].text | test("BUNDLE"; "i")) then 1 elif (.[1].text | test("universal"; "i")) then 2 else 3 end)
            } else empty end
        ] | sort_by(.priority) | .[0].href // empty
    ' 2>/dev/null)
    
    if [ -z "$URL1" ]; then
        log_error "No compatible APK/BUNDLE found"
        log_info "Architecture: $ARCH, DPI: $DPI"
        log_warning "Try downloading manually from: $APP_DL_URL"
        return 1
    fi
    
    log_info "Selected variant: $URL1"
    
    log_info "Step 2/3: Analyzing download page..."
    local PAGE2 URL2
    if ! PAGE2=$("${CURL[@]}" -A "$USER_AGENT" "https://www.apkmirror.com$URL1"); then
        log_error "Failed to fetch download page"
        return 1
    fi
    
    URL2=$(echo "$PAGE2" | pup 'a.downloadButton[data-google-vignette="false"] attr{href}' 2>/dev/null | head -n 1)
    
    if [ -z "$URL2" ]; then
        log_error "Failed to find download button"
        return 1
    fi
    
    log_info "Step 3/3: Fetching final download link..."
    local PAGE3 URL3
    if ! PAGE3=$("${CURL[@]}" -A "$USER_AGENT" "https://www.apkmirror.com$URL2"); then
        log_error "Failed to fetch final page"
        return 1
    fi
    
    URL3=$(echo "$PAGE3" | pup 'a:contains("here") attr{href}' 2>/dev/null | head -n 1)
    
    if [ -z "$URL3" ]; then
        log_error "Failed to find final download link"
        return 1
    fi

    APP_URL="https://www.apkmirror.com$URL3"
    APKM_FILE="$BASE_DIR/${APP_NAME}-${APP_VER}.apkm"
    
    log_success "Download link acquired!"
    log_info "URL: $APP_URL"
}

# --- 6. Download & Merge (IMPROVED) ---
download_and_merge() {
    log_info "Downloading: $APP_NAME-$APP_VER.apkm"
    
    # Remove old file if exists
    rm -f "$APKM_FILE"
    
    if ! "${WGET[@]}" "$APP_URL" -O "$APKM_FILE"; then
        log_error "Download failed"
        return 1
    fi
    
    if [ ! -f "$APKM_FILE" ]; then
        log_error "Download file not found: $APKM_FILE"
        return 1
    fi
    
    local FILE_SIZE
    FILE_SIZE=$(du -h "$APKM_FILE" | cut -f1)
    log_success "Downloaded: $FILE_SIZE"
    
    log_info "Merging APKM bundle..."
    local TEMP_DIR="$BASE_DIR/mod_temp_merge"
    rm -rf "$TEMP_DIR"
    mkdir -p "$TEMP_DIR"
    
    # Extract splits with priority order
    log_info "Extracting APK splits..."
    if ! unzip -qqo "$APKM_FILE" \
        "base.apk" \
        "split_config.${ARCH_APK}*.apk" \
        "split_config.${LOCALE}.apk" \
        "split_config.*dpi.apk" \
        -d "$TEMP_DIR" 2>/dev/null; then
        log_warning "Targeted extraction failed, trying full extraction..."
        if ! unzip -qqo "$APKM_FILE" -d "$TEMP_DIR" 2>/dev/null; then
            log_error "Failed to extract APKM file"
            return 1
        fi
    fi
    
    if [ ! -f "$TEMP_DIR/base.apk" ]; then
        log_error "base.apk not found in bundle"
        ls -lh "$TEMP_DIR"
        return 1
    fi
    
    local SPLIT_COUNT
    SPLIT_COUNT=$(find "$TEMP_DIR" -name "*.apk" | wc -l)
    log_info "Found $SPLIT_COUNT APK files to merge"
    
    log_info "Running APKEditor merge (this may take 1-2 minutes)..."
    rm -f "$MERGED_APK_PATH"
    
    if ! java -jar "$EDITOR_JAR" m -i "$TEMP_DIR" -o "$MERGED_APK_PATH" 2>&1 | grep -v "WARNING"; then
        log_error "APKEditor merge failed"
        return 1
    fi
    
    if [ ! -f "$MERGED_APK_PATH" ]; then
        log_error "Merged APK not created: $MERGED_APK_PATH"
        return 1
    fi
    
    local MERGED_SIZE
    MERGED_SIZE=$(du -h "$MERGED_APK_PATH" | cut -f1)
    log_success "Merge complete: $MERGED_SIZE"
    log_info "Merged APK: $MERGED_APK_PATH"
    
    # Cleanup
    rm -f "$APKM_FILE"
    rm -rf "$TEMP_DIR"
}

# --- 7. Run Patch Script (IMPROVED) ---
run_patch() {
    log_success "Starting ReVanced patch process..."
    
    if [ ! -f "$PATCH_SCRIPT_DIR/build.py" ]; then
        log_error "build.py not found in $PATCH_SCRIPT_DIR"
        return 1
    fi
    
    cd "$PATCH_SCRIPT_DIR" || return 1
    
    log_info "Running build.py with arguments:"
    log_info "  APK: $MERGED_APK_PATH"
    log_info "  Package: $PKG_NAME"
    
    if ! python build.py \
        --apk "$MERGED_APK_PATH" \
        --package "$PKG_NAME" \
        --include-universal \
        --run; then
        log_error "Patch script failed (exit code: $?)"
        return 1
    fi
    
    log_success "Patch completed successfully!"
}

# --- 8. Main Execution ---
main() {
    clear
    echo -e "${GREEN}╔════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║  KakaoTalk Auto-Merge & Patch Script  ║${NC}"
    echo -e "${GREEN}║          Improved Version v2.0        ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════╝${NC}"
    echo ""
    
    log_info "Log file: $LOG_FILE"
    log_info "Architecture: $ARCH ($ARCH_APK)"
    log_info "DPI: $DPI"
    log_info "Locale: $LOCALE"
    echo ""
    
    # 1. Check dependencies
    if ! check_dependencies; then
        log_error "Dependency check failed"
        exit 1
    fi
    
    # 2. Select version
    if ! choose_version; then
        log_warning "Operation cancelled by user"
        exit 0
    fi
    
    # 3. Scrape download link
    if ! scrape_download_link; then
        log_error "Failed to scrape download link"
        exit 1
    fi
    
    # 4. Download and merge
    if ! download_and_merge; then
        log_error "Download or merge failed"
        exit 1
    fi
    
    # 5. Run patch
    if ! run_patch; then
        log_error "Patching failed"
        exit 1
    fi
    
    echo ""
    echo -e "${GREEN}╔════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║         ALL TASKS COMPLETE! ✓         ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════╝${NC}"
    echo ""
    log_success "Patched APK location:"
    echo -e "${CYAN}  → $PATCH_SCRIPT_DIR/out/${NC}"
    echo ""
    log_info "Log saved to: $LOG_FILE"
}

# Run main function
main "$@"
