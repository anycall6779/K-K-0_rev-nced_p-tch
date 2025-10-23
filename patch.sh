#!/bin/bash
#
# KakaoTalk Auto-Merge & Patch Script v3.1
# Fixed APKMirror scraping logic based on Revancify architecture
#
set -e

# ==================== CONFIGURATION ====================
# Color Codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# App Info
APP_NAME="KakaoTalk"
PKG_NAME="com.kakao.talk"
APKMIRROR_DEV="kakao-corp"
APKMIRROR_APP="kakaotalk"

# Paths
BASE_DIR="/storage/emulated/0/Download"
PATCH_SCRIPT_DIR="$HOME/revanced-build-script"
MERGED_APK_PATH="$HOME/Downloads/KakaoTalk.apk"
EDITOR_JAR="$BASE_DIR/APKEditor-1.4.5.jar"

# Environment
USER_AGENT="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
ARCH=$(getprop ro.product.cpu.abi)
DPI=$(getprop ro.sf.lcd_density)
LOCALE=$(getprop persist.sys.locale | sed 's/-.*//g')

# Convert arch for APK naming
case "$ARCH" in
    arm64-v8a) ARCH_APK="arm64_v8a" ;;
    armeabi-v7a) ARCH_APK="armeabi_v7a" ;;
    *) ARCH_APK="${ARCH//-/_}" ;;
esac

# Tools
DIALOG=(dialog --keep-tite --no-shadow --backtitle "KakaoTalk Auto-Merge & Patch Script v3.1 - Revancify Architecture")
CURL=(curl -sL --fail-early --connect-timeout 5 --max-time 10)
WGET=(wget -qc --show-progress --user-agent="$USER_AGENT")

# ==================== FUNCTIONS ====================

print_header() {
    clear
    echo -e "${CYAN}"
    echo "╔════════════════════════════════════════╗"
    echo "║  KakaoTalk Auto-Merge & Patch Script  ║"
    echo "║    v3.1 - Revancify Architecture      ║"
    echo "╚════════════════════════════════════════╝"
    echo -e "${NC}"
    echo -e "[$(date +%H:%M:%S)] Arch: ${CYAN}$ARCH${NC}, DPI: ${CYAN}$DPI${NC}, Locale: ${CYAN}$LOCALE${NC}"
}

log_info() {
    echo -e "[$(date +%H:%M:%S)] ${BLUE}$1${NC}"
}

log_success() {
    echo -e "[$(date +%H:%M:%S)] ${GREEN}$1${NC}"
}

log_error() {
    echo -e "[$(date +%H:%M:%S)] ${RED}$1${NC}"
}

log_warning() {
    echo -e "[$(date +%H:%M:%S)] ${YELLOW}$1${NC}"
}

cleanup() {
    log_info "Cleaning up..."
    rm -rf "$BASE_DIR/mod_temp_merge" 2>/dev/null
    rm -f "$BASE_DIR"/*.apkm.tmp 2>/dev/null
}

check_internet() {
    if ! ping -c 1 -W 2 google.com &>/dev/null; then
        log_error "No internet connection"
        return 1
    fi
}

check_dependencies() {
    log_info "Checking dependencies..."
    local MISSING=0
    
    for cmd in dialog curl pup jq wget unzip java python git; do
        if ! command -v $cmd &>/dev/null; then
            log_error "'$cmd' not found. Install with: pkg install $cmd"
            MISSING=1
        fi
    done
    
    if [ ! -d "$PATCH_SCRIPT_DIR" ]; then
        log_error "Patch script not found: $PATCH_SCRIPT_DIR"
        echo "    Clone with: git clone https://git.naijun.dev/ReVanced/revanced-build-script.git ~/"
        MISSING=1
    fi
    
    if [ ! -f "$EDITOR_JAR" ]; then
        log_warning "APKEditor not found, downloading..."
        mkdir -p "$BASE_DIR"
        if "${WGET[@]}" -O "$EDITOR_JAR" "https://github.com/REAndroid/APKEditor/releases/download/V1.4.5/APKEditor-1.4.5.jar"; then
            log_success "APKEditor downloaded"
        else
            log_error "Failed to download APKEditor"
            MISSING=1
        fi
    fi
    
    [ $MISSING -eq 1 ] && exit 1
    log_success "Dependencies OK"
    mkdir -p "$HOME/Downloads"
}

# ==================== APKMIRROR SCRAPING ====================

fetch_versions_list() {
    log_info "Fetching app info from APKMirror..."
    
    check_internet || return 1
    
    local PAGE_CONTENTS
    
    # Use search page instead of direct URL to avoid Wear OS redirect
    PAGE_CONTENTS=$("${CURL[@]}" -A "$USER_AGENT" "https://www.apkmirror.com/?s=kakaotalk+messenger" 2>/dev/null)
    
    if [ -z "$PAGE_CONTENTS" ]; then
        log_error "Failed to fetch page from APKMirror"
        return 1
    fi
    
    # Extract version numbers and URLs - FIXED selectors
    VERSIONS_TEXT=$(pup -c 'div.listWidget div.appRow h5' <<< "$PAGE_CONTENTS" 2>/dev/null | pup 'text{}' 2>/dev/null | grep -v '^$')
    
    URLS_LIST=$(pup -c 'div.listWidget div.appRow div.downloadIconPositioning a.fontBlack' <<< "$PAGE_CONTENTS" 2>/dev/null | pup 'attr{href}' 2>/dev/null | grep -v '^$')
    
    if [ -z "$VERSIONS_TEXT" ] || [ -z "$URLS_LIST" ]; then
        log_error "App not found in APKMirror"
        log_warning "This could be due to:"
        echo "    - APKMirror HTML structure changed"
        echo "    - Network/cloudflare protection"
        echo "    - Incorrect app name: $APKMIRROR_APP_NAME"
        return 1
    fi
    
    # Combine version text and URLs for dialog menu
    readarray -t VERSIONS_LIST < <(
        paste <(echo "$VERSIONS_TEXT") <(echo "$URLS_LIST") |
        awk -F'\t' '{
            # Clean version text
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", $1);
            print $1;
            print $2;
        }' |
        head -n 40  # Top 20 versions (20 * 2 lines)
    )
    
    if [ ${#VERSIONS_LIST[@]} -eq 0 ]; then
        log_error "No versions found"
        return 1
    fi
    
    log_success "Found ${#VERSIONS_LIST[@]} versions"
}

choose_version() {
    fetch_versions_list || return 1
    
    local SELECTED_URL
    if ! SELECTED_URL=$(
        "${DIALOG[@]}" \
            --title '| Version Selection |' \
            --ok-label 'Select' \
            --cancel-label 'Exit' \
            --menu "Navigate with [↑] [↓], Select with [SPACE]" 20 60 12 \
            "${VERSIONS_LIST[@]}" \
            2>&1 >/dev/tty
    ); then
        log_info "Version selection cancelled"
        return 1
    fi
    
    if [ -z "$SELECTED_URL" ] || [ "$SELECTED_URL" == "null" ]; then
        log_error "Invalid version selected"
        return 1
    fi
    
    APP_DL_URL="https://www.apkmirror.com$SELECTED_URL"
    APP_VER=$(basename "$SELECTED_URL" | sed 's/kakaotalk-//; s/-release//; s/-/./g')
    
    log_success "Selected version: $APP_VER"
}

scrape_download_link() {
    log_info "Scraping download link (Step 1/3)..."
    
    local PAGE1 PAGE2 PAGE3 URL1 URL2 URL3
    local CANONICAL_URL APP_FORMAT VARIANT_INFO
    
    # Step 1: Get variant page
    PAGE1=$("${CURL[@]}" -A "$USER_AGENT" "$APP_DL_URL" 2>/dev/null)
    
    CANONICAL_URL=$(pup -p --charset utf-8 'link[rel="canonical"] attr{href}' <<< "$PAGE1" 2>/dev/null)
    
    if grep -q "apk-download" <<< "$CANONICAL_URL"; then
        URL1="${CANONICAL_URL/https:\/\/www.apkmirror.com\//}"
    else
        # Parse variant table for BUNDLE (APKM)
        readarray -t VARIANT_INFO < <(
            pup -p --charset utf-8 'div.variants-table json{}' <<< "$PAGE1" 2>/dev/null |
                jq -r \
                    --arg ARCH "$ARCH" \
                    --arg DPI "$DPI" '
                    [
                        .[].children[1:][].children |
                        if (.[1].text | test("universal|noarch|\($ARCH)")) and
                            (
                                .[3].text | test("nodpi") or
                                (
                                    capture("(?<low>\\d+)-(?<high>\\d+)dpi") |
                                    (($DPI | tonumber) <= (.high | tonumber)) and 
                                    (($DPI | tonumber) >= (.low | tonumber))
                                )
                            )
                        then
                            .[0].children
                        else
                            empty
                        end
                    ] |
                    if length != 0 then
                        [
                            if any(.[]; .[1].text == "BUNDLE") then
                                .[] | if (.[1].text == "BUNDLE") then [.[1].text, .[0].href] else empty end
                            else
                                .[] | [.[1].text, .[0].href]
                            end
                        ][-1][]
                    else
                        empty
                    end
                ' 2>/dev/null
        )
        
        if [ "${#VARIANT_INFO[@]}" -eq 0 ]; then
            log_error "No compatible APK/BUNDLE found for $ARCH"
            return 1
        fi
        
        APP_FORMAT="${VARIANT_INFO[0]}"
        URL1="${VARIANT_INFO[1]}"
    fi
    
    log_info "Scraping download link (Step 2/3)..."
    
    # Step 2: Get download button page
    PAGE2=$("${CURL[@]}" -A "$USER_AGENT" "https://www.apkmirror.com$URL1" 2>/dev/null)
    URL2=$(pup -p --charset utf-8 'a.downloadButton attr{href}' <<< "$PAGE2" 2>/dev/null | tail -n 1)
    
    if [ -z "$URL2" ]; then
        log_error "Download button not found"
        return 1
    fi
    
    log_info "Scraping download link (Step 3/3)..."
    
    # Step 3: Get final download link
    PAGE3=$("${CURL[@]}" -A "$USER_AGENT" "https://www.apkmirror.com$URL2" 2>/dev/null)
    URL3=$(pup -p --charset UTF-8 'a:contains("here") attr{href}' <<< "$PAGE3" 2>/dev/null | head -n 1)
    
    if [ -z "$URL3" ]; then
        log_error "Final download link not found"
        return 1
    fi
    
    APP_URL="https://www.apkmirror.com$URL3"
    log_success "Download link acquired"
}

# ==================== DOWNLOAD & MERGE ====================

download_apkm() {
    local APKM_FILE="$BASE_DIR/${APP_NAME}-${APP_VER}.apkm"
    
    log_info "Downloading $APP_NAME v$APP_VER..."
    
    rm -f "$APKM_FILE"
    
    if ! "${WGET[@]}" "$APP_URL" -O "$APKM_FILE" 2>&1 | grep --line-buffered -o '[0-9]*%' | while read -r percent; do
        echo "XXX"
        echo "${percent%\%}"
        echo "Downloading: $percent"
        echo "XXX"
    done | "${DIALOG[@]}" --gauge "Downloading $APP_NAME v$APP_VER from APKMirror..." 8 60 0; then
        log_error "Download failed"
        return 1
    fi
    
    if [ ! -f "$APKM_FILE" ]; then
        log_error "Downloaded file not found"
        return 1
    fi
    
    log_success "Download complete: $(du -h "$APKM_FILE" | cut -f1)"
    
    export APKM_FILE
}

merge_apkm() {
    log_info "Merging APKM to APK..."
    
    local TEMP_DIR="$BASE_DIR/mod_temp_merge"
    rm -rf "$TEMP_DIR"
    mkdir -p "$TEMP_DIR"
    
    # Extract split APKs
    log_info "Extracting split APKs..."
    unzip -qqo "$APKM_FILE" \
        "base.apk" \
        "split_config.${ARCH_APK}.apk" \
        "split_config.${LOCALE}.apk" \
        split_config.*dpi.apk \
        -d "$TEMP_DIR" 2>/dev/null
    
    # Fallback: extract everything if minimal extraction failed
    if [ ! -f "$TEMP_DIR/base.apk" ]; then
        log_warning "Minimal extraction failed, extracting all..."
        unzip -qqo "$APKM_FILE" -d "$TEMP_DIR" 2>/dev/null
    fi
    
    # Merge with APKEditor
    log_info "Running APKEditor merge..."
    rm -f "$MERGED_APK_PATH"
    
    if ! java -jar "$EDITOR_JAR" m -i "$TEMP_DIR" -o "$MERGED_APK_PATH" 2>&1 | grep --line-buffered -E 'Merging|Writing' | while read -r line; do
        echo "XXX"
        echo "50"
        echo "$line"
        echo "XXX"
    done | "${DIALOG[@]}" --gauge "Merging with APKEditor..." 8 60 0; then
        log_error "APKEditor merge failed"
        cleanup
        return 1
    fi
    
    if [ ! -f "$MERGED_APK_PATH" ]; then
        log_error "Merged APK not found"
        cleanup
        return 1
    fi
    
    log_success "Merge complete: $(du -h "$MERGED_APK_PATH" | cut -f1)"
    
    # Cleanup
    rm -f "$APKM_FILE"
    rm -rf "$TEMP_DIR"
}

# ==================== PATCH ====================

run_patch_script() {
    log_success "Starting patch process..."
    echo ""
    
    cd "$PATCH_SCRIPT_DIR" || {
        log_error "Cannot access patch script directory"
        return 1
    }
    
    log_info "Running revanced-build-script..."
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    if ! python3 build.py \
        --apk "$MERGED_APK_PATH" \
        --package "$PKG_NAME" \
        --include-universal \
        --run; then
        log_error "Patch script failed"
        return 1
    fi
    
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_success "Patch complete!"
    log_info "Output directory: $PATCH_SCRIPT_DIR/out/"
}

# ==================== MAIN ====================

main() {
    print_header
    
    # Dependency check
    check_dependencies || exit 1
    
    # Version selection
    if ! choose_version; then
        log_info "Operation cancelled by user"
        exit 0
    fi
    
    # Download link scraping
    scrape_download_link || exit 1
    
    # Download APKM
    download_apkm || exit 1
    
    # Merge to APK
    merge_apkm || exit 1
    
    # Run patch
    run_patch_script || exit 1
    
    # Success
    echo ""
    log_success "═══════════════════════════════════════"
    log_success "  ALL TASKS COMPLETED SUCCESSFULLY!   "
    log_success "═══════════════════════════════════════"
    echo ""
    echo "Patched APK location:"
    echo "  ${CYAN}$PATCH_SCRIPT_DIR/out/${NC}"
    echo ""
    
    cleanup
}

# Error handler
trap cleanup EXIT INT TERM

# Run
main "$@"