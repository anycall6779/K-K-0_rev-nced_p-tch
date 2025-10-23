#!/bin/bash
#
# KakaoTalk Auto-Merge & Patch Script
# Version 3.0 - Revancify Style Architecture
#
set -euo pipefail

# ============================================================================
# CONFIGURATION
# ============================================================================

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# App Configuration
APP_NAME="KakaoTalk"
PKG_NAME="com.kakao.talk"
APKMIRROR_APP_NAME="kakaotalk"

# Paths
BASE_DIR="/storage/emulated/0/Download"
PATCH_SCRIPT_DIR="$HOME/revanced-build-script"
MERGED_APK_PATH="$HOME/Downloads/KakaoTalk.apk"
EDITOR_JAR="$BASE_DIR/APKEditor-1.4.5.jar"
DATA_DIR="$BASE_DIR/.kakao_patch_data"

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

# ============================================================================
# UTILITY FUNCTIONS
# ============================================================================

log_info() { echo -e "${BLUE}[INFO]${NC} $(date '+%H:%M:%S') - $*"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $(date '+%H:%M:%S') - $*"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $(date '+%H:%M:%S') - $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $(date '+%H:%M:%S') - $*"; }

notify_info() {
    "${DIALOG[@]}" --title '| Info |' --infobox "$1" -1 -1
    sleep 2
}

notify_msg() {
    "${DIALOG[@]}" --title '| Notice |' --msgbox "$1" -1 -1
}

cleanup_temp_files() {
    log_info "Cleaning up..."
    rm -f "$BASE_DIR"/*.apkm 2>/dev/null || true
    rm -rf "$BASE_DIR/mod_temp_merge" 2>/dev/null || true
}

trap cleanup_temp_files EXIT

# ============================================================================
# DEPENDENCY CHECK
# ============================================================================

check_dependencies() {
    log_info "Checking dependencies..."
    local MISSING=0
    
    for cmd in dialog curl pup jq wget unzip java python git; do
        if ! command -v "$cmd" &> /dev/null; then
            log_error "'$cmd' not found. Install: pkg install $cmd"
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
        log_error "Patch script not found: $PATCH_SCRIPT_DIR"
        log_warning "Clone: git clone https://git.naijun.dev/ReVanced/revanced-build-script.git ~/revanced-build-script"
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
    
    mkdir -p "$HOME/Downloads" "$BASE_DIR" "$DATA_DIR"
    log_success "Dependencies OK"
}

# ============================================================================
# VERSION SCRAPING (Revancify Style)
# ============================================================================

scrape_versions_list() {
    local PAGE_CONTENTS PAGE_JSON MERGED_JSON
    local IDX MAX_PAGE_COUNT=3
    declare -A TMP_FILES PAGE_CONTENTS PAGE_JSON
    
    log_info "Scraping versions from APKMirror (parallel fetch)..."
    
    # Parallel fetch multiple pages
    for ((IDX = 1; IDX <= MAX_PAGE_COUNT; IDX++)); do
        TMP_FILES[$IDX]=$(mktemp)
        "${CURL[@]}" -A "$USER_AGENT" \
            "https://www.apkmirror.com/uploads/page/$IDX/?appcategory=$APKMIRROR_APP_NAME" \
            > "${TMP_FILES[$IDX]}" 2>/dev/null &
    done
    wait
    
    # Read fetched pages
    for ((IDX = 1; IDX <= MAX_PAGE_COUNT; IDX++)); do
        PAGE_CONTENTS[$IDX]=$(cat "${TMP_FILES[$IDX]}")
        rm -f "${TMP_FILES[$IDX]}"
    done
    
    # Parse each page with pup + jq
    for ((IDX = 1; IDX <= MAX_PAGE_COUNT; IDX++)); do
        PAGE_JSON[$IDX]=$(
            pup -c 'div.widget_appmanager_recentpostswidget div.listWidget div:not([class]) json{}' \
                <<< "${PAGE_CONTENTS[$IDX]}" 2>/dev/null |
                jq -rc '
                .[].children as $CHILDREN |
                {
                    version: $CHILDREN[1].children[0].children[1].text,
                    info: $CHILDREN[0].children[0].children[1].children[0].children[0].children[0]
                } |
                {
                    version: .version,
                    tag: (
                        .info.text | ascii_downcase |
                        if test("beta") then "[BETA]"
                        elif test("alpha") then "[ALPHA]"
                        else "[STABLE]"
                        end
                    ),
                    url: .info.href
                }
            ' 2>/dev/null || echo ""
        )
    done
    
    # Merge all JSONs
    MERGED_JSON=$(jq -s 'flatten | unique_by(.version)' <<< "$(printf '%s\n' "${PAGE_JSON[@]}")" 2>/dev/null)
    
    if [ "$MERGED_JSON" = "[]" ] || [ -z "$MERGED_JSON" ]; then
        log_error "Failed to fetch versions"
        return 1
    fi
    
    # Convert to dialog menu format
    readarray -t VERSIONS_LIST < <(
        jq -rc '.[] | ., "\(.version)|\(.tag)"' <<< "$MERGED_JSON" 2>/dev/null
    )
    
    if [ ${#VERSIONS_LIST[@]} -eq 0 ]; then
        log_error "No versions parsed"
        return 1
    fi
    
    # Cache the list
    echo "$MERGED_JSON" > "$DATA_DIR/versions.json"
    
    local VERSION_COUNT=$((${#VERSIONS_LIST[@]} / 2))
    log_success "Found $VERSION_COUNT versions"
}

# ============================================================================
# VERSION SELECTION
# ============================================================================

choose_version() {
    unset APP_VER APP_DL_URL
    local SELECTED_VERSION
    
    # Load cached versions if recent (< 5 minutes)
    if [ -f "$DATA_DIR/versions.json" ]; then
        local FILE_AGE=$((($(date +%s) - $(stat -c %Y "$DATA_DIR/versions.json" 2>/dev/null || echo 0)) / 60))
        if [ $FILE_AGE -le 5 ]; then
            log_info "Using cached versions list"
            local MERGED_JSON=$(cat "$DATA_DIR/versions.json")
            readarray -t VERSIONS_LIST < <(
                jq -rc '.[] | ., "\(.version)|\(.tag)"' <<< "$MERGED_JSON"
            )
        fi
    fi
    
    # Fetch if no cache
    if [ ${#VERSIONS_LIST[@]} -eq 0 ]; then
        notify_info "Fetching versions from APKMirror..."
        scrape_versions_list || return 1
    fi
    
    # Show dialog
    if ! SELECTED_VERSION=$(
        "${DIALOG[@]}" \
            --title '| Version Selection |' \
            --no-tags \
            --column-separator "|" \
            --ok-label '선택' \
            --cancel-label '취소' \
            --menu "Select KakaoTalk version to patch:" 20 60 15 \
            "${VERSIONS_LIST[@]}" \
            2>&1 > /dev/tty
    ); then
        log_warning "User cancelled"
        return 1
    fi
    
    # Extract version and URL
    APP_VER=$(jq -nrc --argjson SEL "$SELECTED_VERSION" '$SEL.version | gsub(" "; "")')
    APP_DL_URL=$(jq -nrc --argjson SEL "$SELECTED_VERSION" '"https://www.apkmirror.com" + $SEL.url')
    
    log_success "Selected: $APP_VER"
}

# ============================================================================
# DOWNLOAD LINK SCRAPING (Revancify Style)
# ============================================================================

scrape_app_info() {
    local PAGE1 PAGE2 PAGE3
    local URL1 URL2 URL3
    local CANONICAL_URL VARIANT_INFO APP_FORMAT
    
    log_info "Step 1/3: Analyzing version page..."
    
    # Fetch main page
    PAGE1=$("${CURL[@]}" -A "$USER_AGENT" "$APP_DL_URL")
    
    # Check if direct download page
    CANONICAL_URL=$(pup -p --charset utf-8 'link[rel="canonical"] attr{href}' <<< "$PAGE1" 2>/dev/null)
    
    if grep -q "apk-download" <<< "$CANONICAL_URL"; then
        URL1="${CANONICAL_URL/https:\/\/www.apkmirror.com\//}"
    else
        # Parse variants table (prefer BUNDLE)
        APP_FORMAT="BUNDLE"
        
        readarray -t VARIANT_INFO < <(
            pup -p --charset utf-8 'div.variants-table json{}' <<< "$PAGE1" |
                jq -r \
                    --arg ARCH "$ARCH" \
                    --arg DPI "$DPI" \
                    --arg APP_FORMAT "$APP_FORMAT" '
                    [
                        .[].children[1:][].children |
                        if (.[1].text | test("universal|noarch|\($ARCH)")) and
                            (
                                .[3].text |
                                test("nodpi") or
                                (
                                    capture("(?<low>\\d+)-(?<high>\\d+)dpi") |
                                    (($DPI | tonumber) <= (.high | tonumber)) and 
                                    (($DPI | tonumber) >= (.low | tonumber))
                                )
                            )
                        then .[0].children
                        else empty
                        end
                    ] |
                    if length != 0 then
                        [
                            if any(.[]; .[1].text == $APP_FORMAT) then
                                .[] |
                                if (.[1].text == $APP_FORMAT) then
                                    [.[1].text, .[0].href]
                                else empty
                                end
                            else
                                .[] | [.[1].text, .[0].href]
                            end
                        ][-1][]
                    else empty
                    end
                ' 2>/dev/null
        )
        
        if [ ${#VARIANT_INFO[@]} -eq 0 ]; then
            log_error "No compatible variant found"
            echo 1 >&2
            return 1
        fi
        
        APP_FORMAT="${VARIANT_INFO[0]}"
        URL1="${VARIANT_INFO[1]}"
    fi
    
    echo 33 >&2
    log_info "Step 2/3: Getting download page..."
    
    # Fetch download page
    PAGE2=$("${CURL[@]}" -A "$USER_AGENT" "https://www.apkmirror.com$URL1")
    readarray -t DL_URLS < <(pup -p --charset utf-8 'a.downloadButton attr{href}' <<< "$PAGE2" 2>/dev/null)
    
    if [ "$APP_FORMAT" = "APK" ]; then
        URL2="${DL_URLS[0]}"
    else
        URL2="${DL_URLS[-1]}"
    fi
    
    if [ -z "$URL2" ]; then
        log_error "Download button not found"
        echo 2 >&2
        return 1
    fi
    
    echo 66 >&2
    log_info "Step 3/3: Getting final link..."
    
    # Get final download link
    URL3=$("${CURL[@]}" -A "$USER_AGENT" "https://www.apkmirror.com$URL2" |
        pup -p --charset UTF-8 'a:contains("here") attr{href}' 2>/dev/null | head -n 1)
    
    if [ -z "$URL3" ]; then
        log_error "Final link not found"
        echo 2 >&2
        return 1
    fi
    
    APP_URL="https://www.apkmirror.com$URL3"
    APP_EXT="${APP_FORMAT,,}"
    [ "$APP_FORMAT" = "BUNDLE" ] && APP_EXT="apkm"
    
    # Save to cache
    cat > "$DATA_DIR/download.env" <<EOF
APP_FORMAT="$APP_FORMAT"
APP_URL="$APP_URL"
APP_EXT="$APP_EXT"
EOF
    
    echo 100 >&2
    log_success "Download link acquired"
}

fetch_download_url() {
    local EXIT_CODE
    
    # Check cache (5 min)
    if [ -f "$DATA_DIR/download.env" ]; then
        local FILE_AGE=$((($(date +%s) - $(stat -c %Y "$DATA_DIR/download.env" 2>/dev/null || echo 0)) / 60))
        if [ $FILE_AGE -le 5 ]; then
            source "$DATA_DIR/download.env"
            log_info "Using cached download URL"
            return 0
        fi
    fi
    
    # Scrape with progress gauge
    EXIT_CODE=$(
        {
            scrape_app_info 2>&3 |
                "${DIALOG[@]}" --gauge \
                    "App    : $APP_NAME\nVersion: $APP_VER\n\nScraping Download Link..." \
                    -1 -1 0 2>&1 > /dev/tty
        } 3>&1
    )
    
    if [ -f "$DATA_DIR/download.env" ]; then
        source "$DATA_DIR/download.env"
    else
        case $EXIT_CODE in
            1)
                notify_msg "No APK/Bundle matching your device architecture.\nTry another version."
                ;;
            2)
                notify_msg "Unable to fetch link!\nCheck internet or try VPN."
                ;;
        esac
        return 1
    fi
    
    tput civis
}

# ============================================================================
# DOWNLOAD & MERGE
# ============================================================================

download_app() {
    local APKM_FILE="$BASE_DIR/${APP_NAME}-${APP_VER}.$APP_EXT"
    
    log_info "Downloading: $APP_NAME-$APP_VER.$APP_EXT"
    
    rm -f "$APKM_FILE"
    
    "${WGET[@]}" "$APP_URL" -O "$APKM_FILE" |&
        stdbuf -o0 cut -b 63-65 |
        stdbuf -o0 grep '[0-9]' |
        "${DIALOG[@]}" --gauge \
            "File: $APP_NAME-$APP_VER.$APP_EXT\n\nDownloading..." \
            -1 -1 0 2>&1 > /dev/tty
    
    tput civis
    
    if [ ! -f "$APKM_FILE" ]; then
        notify_msg "Download failed!\nCheck your internet connection."
        return 1
    fi
    
    local FILE_SIZE=$(du -h "$APKM_FILE" | cut -f1)
    log_success "Downloaded: $FILE_SIZE"
    
    # If BUNDLE, merge splits
    if [ "$APP_EXT" = "apkm" ]; then
        antisplit_app "$APKM_FILE" || return 1
    else
        mv "$APKM_FILE" "$MERGED_APK_PATH"
    fi
}

antisplit_app() {
    local APKM_FILE=$1
    local APP_DIR="$BASE_DIR/mod_temp_merge"
    
    notify_info "Merging APK splits..."
    
    rm -rf "$APP_DIR"
    mkdir -p "$APP_DIR"
    
    # Extract relevant splits
    unzip -qqo "$APKM_FILE" \
        "base.apk" \
        "split_config.${ARCH//-/_}.apk" \
        "split_config.${LOCALE}.apk" \
        split_config.*dpi.apk \
        -d "$APP_DIR" 2>/dev/null || \
        unzip -qqo "$APKM_FILE" -d "$APP_DIR" 2>/dev/null
    
    if [ ! -f "$APP_DIR/base.apk" ]; then
        log_error "base.apk not found in bundle"
        return 1
    fi
    
    local SPLIT_COUNT=$(find "$APP_DIR" -name "*.apk" | wc -l)
    log_info "Merging $SPLIT_COUNT APK files..."
    
    # Merge with APKEditor
    java -jar "$EDITOR_JAR" m -i "$APP_DIR" -o "$MERGED_APK_PATH" &>/dev/null
    
    if [ ! -f "$MERGED_APK_PATH" ]; then
        notify_msg "APKEditor merge failed!"
        return 1
    fi
    
    rm -f "$APKM_FILE"
    rm -rf "$APP_DIR"
    
    local MERGED_SIZE=$(du -h "$MERGED_APK_PATH" | cut -f1)
    log_success "Merged: $MERGED_SIZE"
}

# ============================================================================
# PATCH
# ============================================================================

run_patch() {
    log_success "Starting ReVanced patch..."
    
    if [ ! -f "$PATCH_SCRIPT_DIR/build.py" ]; then
        log_error "build.py not found in $PATCH_SCRIPT_DIR"
        return 1
    fi
    
    cd "$PATCH_SCRIPT_DIR" || return 1
    
    notify_info "Patching... This may take 3-5 minutes."
    
    if ! python build.py \
        --apk "$MERGED_APK_PATH" \
        --package "$PKG_NAME" \
        --include-universal \
        --run; then
        log_error "Patch failed"
        return 1
    fi
    
    log_success "Patch complete!"
}

# ============================================================================
# MAIN
# ============================================================================

main() {
    clear
    echo -e "${GREEN}╔════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║  KakaoTalk Auto-Merge & Patch Script  ║${NC}"
    echo -e "${GREEN}║    v3.0 - Revancify Architecture      ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════╝${NC}"
    echo ""
    
    log_info "Arch: $ARCH, DPI: $DPI, Locale: $LOCALE"
    echo ""
    
    check_dependencies || exit 1
    
    choose_version || exit 0
    
    fetch_download_url || exit 1
    
    download_app || exit 1
    
    run_patch || exit 1
    
    echo ""
    echo -e "${GREEN}╔════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║            SUCCESS! ✓                 ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════╝${NC}"
    echo ""
    log_success "Patched APK: $PATCH_SCRIPT_DIR/out/"
    echo ""
}

main "$@"
