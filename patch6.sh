#!/bin/bash
#
# Simplified APKM Merger + Patcher for KakaoTalk (AmpleReVanced -> Morphe Edition)
# (Modified: Uses morphe-cli and locally transferred .mpp file)
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
PATCH_SCRIPT_DIR="$HOME/morphe-build-script"
MERGED_APK_PATH="$HOME/Downloads/KakaoTalk_Merged.apk"
EDITOR_JAR="$BASE_DIR/APKEditor-1.4.5.jar"

# GitHub Setup for Keystore
KEYSTORE_URL="https://github.com/anycall6779/K-K-0_rev-nced_p-tch/raw/refs/heads/main/my_kakao_key.keystore"
KEYSTORE_FILE="$PATCH_SCRIPT_DIR/my_kakao_key.keystore"
MORPHE_CLI_JAR="$PATCH_SCRIPT_DIR/morphe-cli.jar"

# --- Dependency Check ---
check_dependencies() {
    echo -e "${BLUE}[INFO] 필수 도구 확인 중...${NC}"
    local MISSING=0
    
    for cmd in curl wget unzip java jq; do
        if ! command -v $cmd &> /dev/null; then
            echo -e "${RED}[ERROR] '$cmd' 가 없습니다. 설치 명령어: pkg install $cmd${NC}"
            MISSING=1
        fi
    done
    
    mkdir -p "$PATCH_SCRIPT_DIR"
    mkdir -p "$HOME/Downloads"
    
    if [ ! -f "$EDITOR_JAR" ]; then
        echo -e "${YELLOW}[INFO] APKEditor 다운로드 중...${NC}"
        wget --quiet --show-progress -O "$EDITOR_JAR" \
            "https://github.com/REAndroid/APKEditor/releases/download/V1.4.5/APKEditor-1.4.5.jar" || {
            echo -e "${RED}[ERROR] APKEditor 다운로드 실패${NC}"
            MISSING=1
        }
    fi

    if [ ! -f "$MORPHE_CLI_JAR" ]; then
        echo -e "${YELLOW}[INFO] morphe-cli 최신 버전 확인 중...${NC}"
        local CLI_URL=$(curl -s "https://api.github.com/repos/MorpheApp/morphe-cli/releases" | jq -r '.[0].assets[] | select(.name | endswith("all.jar")) | .browser_download_url' | head -n 1)
        if [ -z "$CLI_URL" ] || [ "$CLI_URL" = "null" ]; then
            echo -e "${RED}[ERROR] morphe-cli URL을 가져오지 못했습니다. (dev 릴리스 fallback 사용)${NC}"
            CLI_URL="https://github.com/MorpheApp/morphe-cli/releases/download/v1.5.0-dev.7/morphe-cli-1.5.0-dev.7-all.jar"
        fi
        echo -e "${YELLOW}[INFO] morphe-cli 다운로드 중...${NC}"
        wget --quiet --show-progress -O "$MORPHE_CLI_JAR" "$CLI_URL" || {
            echo -e "${RED}[ERROR] morphe-cli 다운로드 실패${NC}"
            MISSING=1
        }
    fi
    
    [ $MISSING -eq 1 ] && exit 1
    echo -e "${GREEN}[OK] 모든 준비 완료${NC}"
}

# --- Get APKM File Path ---
get_apkm_file() {
    echo ""
    echo -e "${YELLOW}==================================${NC}"
    echo -e "${GREEN}카카오톡 APKM 파일 선택${NC}"
    echo -e "${YELLOW}==================================${NC}"
    echo ""
    
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
        
        if [[ "$selection" =~ ^[0-9]+$ ]] && [ "$selection" -ge 1 ] && [ "$selection" -le ${#APKM_FILES[@]} ]; then
            APKM_FILE="$BASE_DIR/${APKM_FILES[$((selection-1))]}"
            echo -e "${GREEN}[선택됨] ${APKM_FILES[$((selection-1))]}${NC}"
            return 0
        fi
        
        if [ -n "$selection" ]; then
            APKM_FILE="$selection"
        fi
    else
        echo -e "${BLUE}APKM 파일의 전체 경로를 입력하세요:${NC}"
        echo -e "${YELLOW}(예: /storage/emulated/0/Download/com.kakao.talk.apkm)${NC}"
        echo ""
        read -r -p "> " APKM_FILE
    fi
    
    if [ -z "$APKM_FILE" ] || [ ! -f "$APKM_FILE" ]; then
        echo -e "${RED}[ERROR] 유효하지 않은 파일 경로입니다.${NC}"
        return 1
    fi
    
    return 0
}

# --- Get MPP File Path ---
get_mpp_file() {
    echo ""
    echo -e "${YELLOW}==================================${NC}"
    echo -e "${GREEN}Morphe (.mpp) 패치 파일 선택${NC}"
    echo -e "${YELLOW}==================================${NC}"
    echo ""
    
    local MPP_FILES=()
    while IFS= read -r -d '' file; do
        MPP_FILES+=("$(basename "$file")")
    done < <(find "$BASE_DIR" -maxdepth 1 -name "*.mpp" -print0 2>/dev/null)
    
    if [ ${#MPP_FILES[@]} -gt 0 ]; then
        echo -e "${BLUE}다운로드 폴더에서 발견된 MPP 파일:${NC}"
        for i in "${!MPP_FILES[@]}"; do
            echo -e "  ${GREEN}$((i+1)).${NC} ${MPP_FILES[$i]}"
        done
        echo ""
        echo -e "${YELLOW}번호를 입력하거나, 직접 경로를 입력하세요:${NC}"
        read -r -p "> " selection
        
        if [[ "$selection" =~ ^[0-9]+$ ]] && [ "$selection" -ge 1 ] && [ "$selection" -le ${#MPP_FILES[@]} ]; then
            MPP_FILE="$BASE_DIR/${MPP_FILES[$((selection-1))]}"
            echo -e "${GREEN}[선택됨] ${MPP_FILES[$((selection-1))]}${NC}"
            return 0
        fi
        
        if [ -n "$selection" ]; then
            MPP_FILE="$selection"
        fi
    else
        echo -e "${BLUE}MPP 파일의 전체 경로를 입력하세요:${NC}"
        echo -e "${YELLOW}(예: /storage/emulated/0/Download/patches.mpp)${NC}"
        echo ""
        read -r -p "> " MPP_FILE
    fi
    
    if [ -z "$MPP_FILE" ] || [ ! -f "$MPP_FILE" ]; then
        echo -e "${RED}[ERROR] 유효하지 않은 파일 경로입니다. MPP 파일을 Download 폴더에 넣어주세요.${NC}"
        return 1
    fi
    
    return 0
}

# --- Merge APKM ---
merge_apkm() {
    echo ""
    echo -e "${BLUE}[INFO] APKM 파일 병합 시작...${NC}"
    local TEMP_DIR="$BASE_DIR/kakao_temp_merge"
    rm -rf "$TEMP_DIR" && mkdir -p "$TEMP_DIR"
    
    unzip -qqo "$APKM_FILE" -d "$TEMP_DIR" 2>/dev/null || {
        echo -e "${RED}[ERROR] 압축 해제 실패${NC}"
        rm -rf "$TEMP_DIR"
        return 1
    }
    
    if [ ! -f "$TEMP_DIR/base.apk" ]; then
        echo -e "${RED}[ERROR] base.apk 없음${NC}"
        rm -rf "$TEMP_DIR"
        return 1
    fi
    
    echo -e "${BLUE}[INFO] APKEditor로 병합 중... (잠시만 기다려주세요)${NC}"
    rm -f "$MERGED_APK_PATH"
    java -jar "$EDITOR_JAR" m -i "$TEMP_DIR" -o "$MERGED_APK_PATH" &> /dev/null || {
        echo -e "${RED}[ERROR] 병합 실패${NC}"
        rm -rf "$TEMP_DIR"
        return 1
    }
    
    if [ ! -f "$MERGED_APK_PATH" ]; then
        echo -e "${RED}[ERROR] 병합된 파일 생성 실패${NC}"
        rm -rf "$TEMP_DIR"
        return 1
    fi
    
    echo -e "${GREEN}[SUCCESS] 병합 완료: $(basename "$MERGED_APK_PATH")${NC}"
    rm -rf "$TEMP_DIR"
    return 0
}

# --- Run Patch (Morphe) ---
run_patch() {
    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}    Morphe 패치 시작...${NC}"
    echo -e "${GREEN}========================================${NC}"
    
    cd "$PATCH_SCRIPT_DIR"
    
    echo -e "${YELLOW}[INFO] 고정 키스토어(my_kakao_key.keystore) 다운로드 중...${NC}"
    if [ ! -f "$KEYSTORE_FILE" ]; then
        curl -L -s -o "$KEYSTORE_FILE" "$KEYSTORE_URL" || {
            echo -e "${RED}[ERROR] 키스토어 다운로드 실패!${NC}"
            return 1
        }
    fi

    local OUTPUT_APK="$PATCH_SCRIPT_DIR/patched.apk"
    rm -f "$OUTPUT_APK"
    
    echo -e "${BLUE}[INFO] morphe-cli 실행 중...${NC}"
    java -jar "$MORPHE_CLI_JAR" patch \
        -p "$MPP_FILE" \
        -o "$OUTPUT_APK" \
        --keystore "$KEYSTORE_FILE" \
        "$MERGED_APK_PATH" || {
        echo -e "${RED}[ERROR] 패치 과정 중 오류 발생${NC}"
        return 1
    }
    
    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}    패치 완료!${NC}"
    echo -e "${GREEN}========================================${NC}"
    
    if [ -f "$OUTPUT_APK" ]; then
        echo -e "${BLUE}[INFO] 결과물을 다운로드 폴더로 이동합니다...${NC}"
        mv -f "$OUTPUT_APK" "$BASE_DIR/kakaotalkpatch.apk"
        echo -e "${GREEN}[SUCCESS] 저장 완료: $BASE_DIR/kakaotalkpatch.apk${NC}"
    else
        echo -e "${RED}[ERROR] 결과물 파일을 찾을 수 없습니다.${NC}"
        return 1
    fi
}

# --- Main ---
main() {
    clear
    echo -e "${GREEN}======================================${NC}"
    echo -e "${GREEN}  카카오톡 APKM 병합 & Morphe 패치${NC}"
    echo -e "${GREEN}======================================${NC}"
    echo ""
    
    check_dependencies || exit 1
    get_apkm_file || exit 0
    get_mpp_file || exit 0
    merge_apkm || exit 1
    run_patch || exit 1
    
    echo -e "${GREEN}모든 작업이 끝났습니다.${NC}"
}

main
