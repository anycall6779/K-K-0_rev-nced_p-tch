#!/bin/bash
#
# Simplified APKM Merger + Patcher for KakaoTalk
# Fixed version for Termux
#
set -e

# Color Codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configuration
PKG_NAME="com.kakao.talk"
BASE_DIR="/storage/emulated/0/Download"
PATCH_SCRIPT_DIR="$HOME/revanced-build-script"
MERGED_APK_PATH="$HOME/Downloads/KakaoTalk.apk"
EDITOR_JAR="$BASE_DIR/APKEditor-1.4.5.jar"

# Get device info
ARCH=$(getprop ro.product.cpu.abi)
[ "$ARCH" = "arm64-v8a" ] && ARCH_APK="arm64" || ARCH_APK="armeabi"
LOCALE=$(getprop persist.sys.locale | sed 's/-.*//g' | head -c 2)

# --- Dependency Check ---
check_dependencies() {
    echo -e "${BLUE}[INFO] Checking dependencies...${NC}"
    local MISSING=0
    
    for cmd in curl wget unzip java python git; do
        if ! command -v $cmd &> /dev/null; then
            echo -e "${RED}[ERROR] '$cmd' not found. Install with: pkg install $cmd${NC}"
            MISSING=1
        fi
    done
    
    if [ ! -d "$PATCH_SCRIPT_DIR" ]; then
        echo -e "${RED}[ERROR] Patch script directory not found: $PATCH_SCRIPT_DIR${NC}"
        echo -e "${YELLOW}Run: git clone https://git.naijun.dev/ReVanced/revanced-build-script.git ~${NC}"
        MISSING=1
    fi
    
    if [ ! -f "$EDITOR_JAR" ]; then
        echo -e "${YELLOW}[INFO] Downloading APKEditor...${NC}"
        wget --quiet --show-progress -O "$EDITOR_JAR" \
            "https://github.com/REAndroid/APKEditor/releases/download/V1.4.5/APKEditor-1.4.5.jar" || {
            echo -e "${RED}[ERROR] Failed to download APKEditor${NC}"
            MISSING=1
        }
    fi
    
    [ $MISSING -eq 1 ] && exit 1
    mkdir -p "$HOME/Downloads"
    echo -e "${GREEN}[OK] All dependencies satisfied${NC}"
}

# --- Get APKM File Path ---
get_apkm_file() {
    echo ""
    echo -e "${YELLOW}==================================${NC}"
    echo -e "${GREEN}카카오톡 APKM 파일 선택${NC}"
    echo -e "${YELLOW}==================================${NC}"
    echo ""
    
    # 다운로드 폴더에서 .apkm 파일 찾기
    local APKM_FILES=()
    while IFS= read -r -d '' file; do
        APKM_FILES+=("$(basename "$file")")
    done < <(find "$BASE_DIR" -maxdepth 1 -name "*.apkm" -print0 2>/dev/null)
    
    if [ ${#APKM_FILES[@]} -gt 0 ]; then
        echo -e "${BLUE}다운로드 폴더에서 발견된 APKM 파일:${NC}"
        for i in "${!APKM_FILES[@]}"; do
            echo -e "  ${GREEN}$((i+1)).${NC} ${APKM_FILES[$i]}"
        done
        echo ""
        echo -e "${YELLOW}번호를 입력하거나, 직접 경로를 입력하세요:${NC}"
        read -r -p "> " selection
        
        # 숫자인 경우
        if [[ "$selection" =~ ^[0-9]+$ ]] && [ "$selection" -ge 1 ] && [ "$selection" -le ${#APKM_FILES[@]} ]; then
            APKM_FILE="$BASE_DIR/${APKM_FILES[$((selection-1))]}"
            echo -e "${GREEN}[선택됨] ${APKM_FILES[$((selection-1))]}${NC}"
            return 0
        fi
        
        # 경로인 경우
        if [ -n "$selection" ]; then
            APKM_FILE="$selection"
        fi
    else
        echo -e "${BLUE}APKM 파일의 전체 경로를 입력하세요:${NC}"
        echo -e "${YELLOW}(예: /storage/emulated/0/Download/com.kakao.talk.apkm)${NC}"
        echo ""
        read -r -p "> " APKM_FILE
    fi
    
    # 빈 입력 체크
    if [ -z "$APKM_FILE" ]; then
        echo -e "${RED}[ERROR] 경로가 입력되지 않았습니다.${NC}"
        return 1
    fi
    
    # 파일 존재 체크
    if [ ! -f "$APKM_FILE" ]; then
        echo -e "${RED}[ERROR] 파일을 찾을 수 없습니다: $APKM_FILE${NC}"
        return 1
    fi
    
    echo -e "${GREEN}[OK] 파일 확인됨${NC}"
    return 0
}

# --- Merge APKM ---
merge_apkm() {
    echo ""
    echo -e "${BLUE}[INFO] APKM 파일 병합 시작...${NC}"
    
    local TEMP_DIR="$BASE_DIR/kakao_temp_merge"
    rm -rf "$TEMP_DIR" && mkdir -p "$TEMP_DIR"
    
    # Extract APKM
    echo -e "${BLUE}[INFO] APKM 압축 해제 중...${NC}"
    unzip -qqo "$APKM_FILE" -d "$TEMP_DIR" 2>/dev/null || {
        echo -e "${RED}[ERROR] APKM 압축 해제 실패${NC}"
        rm -rf "$TEMP_DIR"
        return 1
    }
    
    # Check base.apk exists
    if [ ! -f "$TEMP_DIR/base.apk" ]; then
        echo -e "${RED}[ERROR] base.apk를 찾을 수 없습니다.${NC}"
        rm -rf "$TEMP_DIR"
        return 1
    fi
    
    # Merge with APKEditor
    echo -e "${BLUE}[INFO] APKEditor로 병합 중... (시간이 걸릴 수 있습니다)${NC}"
    rm -f "$MERGED_APK_PATH"
    
    java -jar "$EDITOR_JAR" m -i "$TEMP_DIR" -o "$MERGED_APK_PATH" || {
        echo -e "${RED}[ERROR] APKEditor 병합 실패${NC}"
        rm -rf "$TEMP_DIR"
        return 1
    }
    
    # Verify merged file
    if [ ! -f "$MERGED_APK_PATH" ]; then
        echo -e "${RED}[ERROR] 병합된 APK 파일이 생성되지 않았습니다.${NC}"
        rm -rf "$TEMP_DIR"
        return 1
    fi
    
    echo -e "${GREEN}[SUCCESS] 병합 완료: $MERGED_APK_PATH${NC}"
    rm -rf "$TEMP_DIR"
    return 0
}

# --- Run Patch ---
run_patch() {
    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}    AmpleReVanced 패치 스크립트 실행 중...${NC}"
    echo -e "${GREEN}========================================${NC}"
    
    cd "$PATCH_SCRIPT_DIR"
    
    ./build.py \
        --apk "$MERGED_APK_PATH" \
        --package "$PKG_NAME" \
        --include-universal \
        --run || {
        echo -e "${RED}[ERROR] 패치 스크립트 실패${NC}"
        return 1
    }
    
    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}    패치 완료!${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo ""
    echo -e "패치된 파일 위치:"
    echo -e "${YELLOW}$PATCH_SCRIPT_DIR/out/${NC}"
    echo ""
}

# --- Main ---
main() {
    clear
    echo -e "${GREEN}======================================${NC}"
    echo -e "${GREEN}  카카오톡 APKM 병합 & 패치 도구${NC}"
    echo -e "${GREEN}======================================${NC}"
    echo ""
    
    # 1. Check dependencies
    check_dependencies
    
    # 2. Get APKM file
    if ! get_apkm_file; then
        echo -e "${YELLOW}[INFO] 작업이 취소되었습니다.${NC}"
        exit 0
    fi
    
    # 3. Merge APKM
    if ! merge_apkm; then
        exit 1
    fi
    
    # 4. Run patch
    if ! run_patch; then
        exit 1
    fi
    
    echo -e "${GREEN}모든 작업이 완료되었습니다!${NC}"
}

# Run
main
