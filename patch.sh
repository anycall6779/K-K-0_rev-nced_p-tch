#!/bin/bash
#
# APKM Version Selector + Auto-Merger + Auto-Patcher (for revanced-build-script)
#
set -e # Exit immediately if a command exits with a non-zero status.

# --- 1. Basic Config & Variables ---
# Color Codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# App-specific Info (Keep this internal to the script)
APP_NAME="KakaoTalk"
PKG_NAME="com.kakao.talk"
APKMIRROR_APP_NAME="kakaotalk"

# Path Config
BASE_DIR="/storage/emulated/0/Download" # Default download dir
PATCH_SCRIPT_DIR="$HOME/revanced-build-script"
MERGED_APK_PATH="$HOME/Downloads/KakaoTalk.apk" # Target file for build.py

# Tool Paths
EDITOR_JAR="$BASE_DIR/APKEditor-1.4.5.jar"

# Environment
USER_AGENT="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/90.0.4430.93 Safari/537.36"
ARCH=$(getprop ro.product.cpu.abi)
DPI=$(getprop ro.sf.lcd_density)
LOCALE=$(getprop persist.sys.locale | sed 's/-.*//g')
[ "$ARCH" = "arm64-v8a" ] && ARCH_APK="arm64" || ARCH_APK="armeabi"

# Termux UI Tools
DIALOG=(dialog --keep-tite --no-shadow --no-collapse --visit-items --ok-label "선택" --cancel-label "취소")
CURL=(curl -L -s -k --compressed --retry 3 --retry-delay 1)
WGET=(wget --quiet --show-progress --progress=bar:force:noscroll --no-check-certificate)

# --- 2. Dependency Check Function ---
check_dependencies() {
    echo -e "${BLUE}[INFO] Checking dependencies...${NC}"
    local MISSING=0
    # JQ를 버전 선택에서 제거했으므로, 의존성 검사에서는 남겨둠 (build.py가 쓸 수 있으므로)
    for cmd in dialog curl pup jq wget unzip java python git; do
        if ! command -v $cmd &> /dev/null; then
            echo -e "${RED}[ERROR] '$cmd' not found. Please run 'pkg install ${cmd}'${NC}"
            MISSING=1
        fi
    done
    
    if [ ! -d "$PATCH_SCRIPT_DIR" ]; then
        echo -e "${RED}[ERROR] Patch script directory not found: $PATCH_SCRIPT_DIR${NC}"
        echo -e "${YELLOW}Please run 'git clone https://git.naijun.dev/ReVanced/revanced-build-script.git' in your HOME (~) folder.${NC}"
        MISSING=1
    fi
    
    if [ ! -f "$EDITOR_JAR" ]; then
        echo -e "${YELLOW}[WARNING] $EDITOR_JAR not found.${NC}"
        echo -e "${BLUE}Attempting to download APKEditor...${NC}"
        "${WGET[@]}" -O "$EDITOR_JAR" "https://github.com/REAndroid/APKEditor/releases/download/V1.4.5/APKEditor-1.4.5.jar" || {
            echo -e "${RED}[ERROR] Failed to download APKEditor.${NC}";
            MISSING=1;
        }
    fi
    
    [ $MISSING -eq 1 ] && exit 1
    mkdir -p "$HOME/Downloads" # Ensure build.py target dir exists
}

# --- 3. Version Scraping & Selection ---
choose_version() {
    echo -e "${BLUE}[INFO] Fetching version list from APKMirror...${NC}"
    local PAGE_CONTENTS
    PAGE_CONTENTS=$("${CURL[@]}" -A "$USER_AGENT" "https://www.apkmirror.com/uploads/?appcategory=$APKMIRROR_APP_NAME")

    # --- [START] JQ/PUP FIX 10 (Final) ---
    # JQ를 완전히 제거하고, pup, paste, awk로만 목록을 생성
    
    local VERSIONS_TEXT URLS_LIST
    
    # 1. 버전 텍스트 추출 (e.g., "10.7.5")
    VERSIONS_TEXT=$(pup -c 'div.listWidget .appRow > a > div > span.appVersion' <<< "$PAGE_CONTENTS" | pup 'text{}')
    # 2. URL 추출 (e.g., "/apk/kakao-corp/...")
    URLS_LIST=$(pup -c 'div.listWidget .appRow > a' <<< "$PAGE_CONTENTS" | pup 'attr{href}')

    # 3. `paste`로 두 리스트를 탭(\t)으로 병합하고, `awk`로 dialog 형식(Tag, Item)으로 변환
    readarray -t VERSIONS_LIST < <(
        paste <(echo "$VERSIONS_TEXT") <(echo "$URLS_LIST") |
        awk -F'\t' '{ print $1; print $2 }' | # $1=Tag(버전), $2=Item(URL)
        head -n 30 # 상위 15개 버전 (15 * 2줄 = 30줄)
    )
    # --- [END] JQ/PUP FIX 10 ---

    if [ ${#VERSIONS_LIST[@]} -eq 0 ]; then
        echo -e "${RED}[ERROR] Failed to fetch version list. (Scraper may be broken)${NC}"
        exit 1
    fi

    local SELECTED_URL
    if ! SELECTED_URL=$(
        "${DIALOG[@]}" \
            --title "| Version Selection |" \
            --menu "Select the desired version" -1 -1 0 \
            "${VERSIONS_LIST[@]}" \
            2>&1 > /dev/tty
    ); then
        return 1 # User pressed 'Cancel'
    fi
    
    # 사용자가 null을 선택했는지 확인
    if [ -z "$SELECTED_URL" ] || [ "$SELECTED_URL" == "null" ]; then
        echo -e "${RED}[ERROR] Invalid selection. (Selected item was null)${NC}"
        return 1
    fi
    
    APP_DL_URL="https://www.apkmirror.com$SELECTED_URL"
    APP_VER=$(echo "$SELECTED_URL" | cut -d '/' -f 6 | sed 's/kakaotalk-//; s/-release//')
    
    echo -e "${GREEN}[SELECTED] Version: $APP_VER${NC}"
}

# --- 4. Automatic Download Link Scraper ---
scrape_download_link() {
    echo -e "\n${BLUE}[INFO] 1/3: Analyzing version page...${NC}"
    local PAGE1 PAGE2 URL1 URL2 URL3 VARIANT_INFO
    
    PAGE1=$("${CURL[@]}" -A "$USER_AGENT" "$APP_DL_URL")

    readarray -t VARIANT_INFO < <(
        pup -p --charset utf-8 'div.variants-table json{}' <<< "$PAGE1" |
            jq -r \
                --arg ARCH "$ARCH" \
                --arg DPI "$DPI" '
                [
                    .[].children[1:][].children |
                    if (.[1].text | test("universal|noarch|\($ARCH)")) and
                       (.[3].text | test("nodpi") or 
                           (capture("(?<low>\\d+)-(?<high>\\d+)dpi") | 
                           (($DPI | tonumber) <= (.high | tonumber)) and (($DPI | tonumber) >= (.low | tonumber)))
                       )
                    then .[0].children else empty end
                ] |
                (.[[] | if (.[1].text == "BUNDLE") then .[0].href else empty end][-1]) // (.[[] | .[0].href][-1])
            '
    )
    
    URL1="${VARIANT_INFO[0]}"
    if [ -z "$URL1" ]; then
        echo -e "${RED}[ERROR] No compatible APK/BUNDLE found for $ARCH architecture.${NC}"
        return 1
    fi
    
    echo -e "${BLUE}[INFO] 2/3: Analyzing download page...${NC}"
    PAGE2=$("${CURL[@]}" -A "$USER_AGENT" "https://www.apkmirror.com$URL1")
    URL2=$(pup -p --charset utf-8 'a.downloadButton[data-google-vignette="false"] attr{href}' <<< "$PAGE2" 2> /dev/null | head -n 1)
    
    echo -e "${BLUE}[INFO] 3/3: Fetching final link...${NC}"
    PAGE3=$("${CURL[@]}" -A "$USER_AGENT" "https://www.apkmirror.com$URL2")
    URL3=$(pup -p --charset UTF-8 'a:contains("here") attr{href}' <<< "$PAGE3" 2> /dev/null | head -n 1)
    
    if [ -z "$URL3" ]; then
        echo -e "${RED}[ERROR] Failed to find final download link.${NC}"
        return 1
    fi

    APP_URL="https://www.apkmirror.com$URL3"
    APKM_FILE="$BASE_DIR/${APP_VER}.apkm" # Temp .apkm file path
    echo -e "${GREEN}[SUCCESS] Download link acquired!${NC}"
}

# --- 5. Download & Merge ---
download_and_merge() {
    echo -e "\n${BLUE}[INFO] Downloading file: $APP_NAME-$APP_VER.apkm${NC}"
    rm -f "$APKM_FILE"
    "${WGET[@]}" "$APP_URL" -O "$APKM_FILE"
    
    if [ ! -f "$APKM_FILE" ]; then
        echo -e "${RED}[ERROR] File download failed.${NC}"
        return 1
    fi

    echo -e "\n${BLUE}[INFO] Merging APKM file... (-> $MERGED_APK_PATH)${NC}"
    local TEMP_DIR="$BASE_DIR/mod_temp_merge"
    rm -rf "$TEMP_DIR" && mkdir -p "$TEMP_DIR"
    
    unzip -qqo "$APKM_FILE" \
        "base.apk" \
        "split_config.${ARCH_APK}_v8a.apk" \
        "split_config.${LOCALE}.apk" \
        split_config.*dpi.apk \
        -d "$TEMP_DIR" 2> /dev/null

    if [ ! -f "$TEMP_DIR/base.apk" ]; then
        echo -e "${YELLOW}[WARNING] Minimal extraction failed. Attempting full extraction...${NC}"
        unzip -qqo "$APKM_FILE" -d "$TEMP_DIR" 2> /dev/null
    fi

    echo -e "${BLUE}[INFO] Merging with APKEditor... (this may take a moment)${NC}"
    rm -f "$MERGED_APK_PATH"
    java -jar "$EDITOR_JAR" m -i "$TEMP_DIR" -o "$MERGED_APK_PATH"
    
    if [ ! -f "$MERGED_APK_PATH" ]; then
        echo -e "${RED}[ERROR] APKEditor merge failed.${NC}"
        rm -rf "$TEMP_DIR" "$APKM_FILE"
        return 1
    fi
    
    echo -e "${GREEN}[SUCCESS] Merge complete: $MERGED_APK_PATH${NC}"
    
    # Cleanup temp files
    rm -f "$APKM_FILE"
    rm -rf "$TEMP_DIR"
}

# --- 6. Run Patch Script ---
run_patch() {
    echo -e "\n${GREEN}========= Running Patch Script =========${NC}"
    cd "$PATCH_SCRIPT_DIR"
    
    ./build.py \
        --apk "$MERGED_APK_PATH" \
        --package "$PKG_NAME" \
        --include-universal \
        --run
    
    local EXIT_CODE=$?
    if [ $EXIT_CODE -ne 0 ]; then
        echo -e "${RED}[ERROR] Patch script failed.${NC}"
        return 1
    fi
    
    echo -e "${GREEN}=======================================${NC}"
}

# --- 7. Main Execution ---
main() {
    clear
    echo -e "${GREEN}=== Auto-Merge & Patch Script ===${NC}"
    
    # 1. Check dependencies
    check_dependencies
    
    # 2. Select version
    if ! choose_version; then
        echo -e "${YELLOW}[INFO] Operation cancelled.${NC}"
        exit 0
    fi
    
    # 3. Scrape link
    if ! scrape_download_link; then
        exit 1
    fi
    
    # 4. Download and merge
    if ! download_and_merge; then
        exit 1
    fi
    
    # 5. Run patch
    if ! run_patch; then
        exit 1
    fi
    
    echo -e "\n${GREEN}========= ALL TASKS COMPLETE =========${NC}"
    echo -e "Patched file is located in:"
    echo -e "${YELLOW}$PATCH_SCRIPT_DIR/out/${NC}"
    echo -e "${GREEN}======================================${NC}"
}

# Run main function
main
