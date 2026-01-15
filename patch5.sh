#!/bin/bash
#
# Simplified APKM Merger + Patcher for KakaoTalk (AmpleReVanced Edition)
# (Modified: Uses Custom RVP file from GitHub)
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
WORK_DIR="$HOME/revanced-kakao-patch"
MERGED_APK_PATH="$HOME/Downloads/KakaoTalk_Merged.apk"
EDITOR_JAR="$BASE_DIR/APKEditor-1.4.5.jar"

# [수정됨] 키스토어 및 RVP 파일 설정
KEYSTORE_URL="https://github.com/anycall6779/K-K-0_rev-nced_p-tch/raw/refs/heads/main/my_kakao_key.keystore"
KEYSTORE_FILE="$WORK_DIR/my_kakao_key.keystore"
RVP_URL="https://github.com/anycall6779/K-K-0_rev-nced_p-tch/raw/refs/heads/main/patches-5.47.0-ample.2.rvp"
RVP_FILE="$WORK_DIR/patches-5.47.0-ample.2.rvp"

# ReVanced CLI 설정 (AmpleReVanced 포크 버전 - 호환성 필수!)
CLI_VERSION="5.0.1-ample.9"
CLI_URL="https://github.com/AmpleReVanced/revanced-cli/releases/download/v${CLI_VERSION}/revanced-cli-${CLI_VERSION}-all.jar"
CLI_JAR="$WORK_DIR/revanced-cli-${CLI_VERSION}-all.jar"

# Get device info
ARCH=$(getprop ro.product.cpu.abi)
[ "$ARCH" = "arm64-v8a" ] && ARCH_APK="arm64" || ARCH_APK="armeabi"

# --- Dependency Check ---
check_dependencies() {
    echo -e "${BLUE}[INFO] 필수 도구 확인 중...${NC}"
    local MISSING=0
    
    for cmd in curl wget unzip java; do
        if ! command -v $cmd &> /dev/null; then
            echo -e "${RED}[ERROR] '$cmd' 가 없습니다. 설치 명령어: pkg install $cmd${NC}"
            MISSING=1
        fi
    done
    
    mkdir -p "$WORK_DIR"
    mkdir -p "$HOME/Downloads"
    
    # APKEditor 다운로드
    if [ ! -f "$EDITOR_JAR" ]; then
        echo -e "${YELLOW}[INFO] APKEditor 다운로드 중...${NC}"
        wget --quiet --show-progress -O "$EDITOR_JAR" \
            "https://github.com/REAndroid/APKEditor/releases/download/V1.4.5/APKEditor-1.4.5.jar" || {
            echo -e "${RED}[ERROR] APKEditor 다운로드 실패${NC}"
            MISSING=1
        }
    fi
    
    # ReVanced CLI 다운로드 (기존 파일 삭제 후 재다운로드)
    # 이전 버전이나 손상된 파일 삭제
    rm -f "$WORK_DIR"/revanced-cli-*.jar 2>/dev/null
    echo -e "${YELLOW}[INFO] ReVanced CLI 다운로드 중...${NC}"
    wget --quiet --show-progress -O "$CLI_JAR" "$CLI_URL" || {
        echo -e "${RED}[ERROR] ReVanced CLI 다운로드 실패${NC}"
        MISSING=1
    }
    
    # RVP 패치 파일 다운로드
    echo -e "${YELLOW}[INFO] RVP 패치 파일 다운로드 중...${NC}"
    curl -L -o "$RVP_FILE" "$RVP_URL" || {
        echo -e "${RED}[ERROR] RVP 패치 파일 다운로드 실패${NC}"
        MISSING=1
    }
    
    # 키스토어 다운로드
    echo -e "${YELLOW}[INFO] 키스토어 다운로드 중...${NC}"
    curl -L -o "$KEYSTORE_FILE" "$KEYSTORE_URL" || {
        echo -e "${RED}[ERROR] 키스토어 다운로드 실패${NC}"
        MISSING=1
    }
    
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

# --- Run Patch (Using RVP file directly with ReVanced CLI) ---
run_patch() {
    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}    ReVanced 패치 시작...${NC}"
    echo -e "${GREEN}========================================${NC}"
    
    cd "$WORK_DIR"
    
    local OUTPUT_APK="$WORK_DIR/kakaotalk-patched.apk"
    rm -f "$OUTPUT_APK"
    
    echo -e "${BLUE}[INFO] ReVanced CLI로 패치 중... (잠시만 기다려주세요)${NC}"
    
    # ReVanced CLI를 사용하여 패치 적용
    java -jar "$CLI_JAR" patch \
        --patches "$RVP_FILE" \
        --keystore "$KEYSTORE_FILE" \
        --keystore-password "android" \
        --signer "signer" \
        --keystore-entry-password "android" \
        --keystore-entry-alias "alias" \
        --out "$OUTPUT_APK" \
        "$MERGED_APK_PATH" || {
        echo -e "${RED}[ERROR] 패치 과정 중 오류 발생${NC}"
        return 1
    }
    
    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}    패치 완료!${NC}"
    echo -e "${GREEN}========================================${NC}"
    
    # 결과물 확인 및 요청하신 경로로 이동
    if [ -f "$OUTPUT_APK" ]; then
        echo -e "${BLUE}[INFO] 결과물을 다운로드 폴더로 이동합니다...${NC}"
        mv -f "$OUTPUT_APK" "/storage/emulated/0/Download/kakaotalkpatch.apk"
        echo -e "${GREEN}[SUCCESS] 저장 완료: /storage/emulated/0/Download/kakaotalkpatch.apk${NC}"
    else
        echo -e "${YELLOW}[WARN] 결과물 파일을 찾을 수 없습니다. 직접 확인해주세요: $WORK_DIR${NC}"
    fi
}

# --- Main ---
main() {
    clear
    echo -e "${GREEN}======================================${NC}"
    echo -e "${GREEN}  카카오톡 APKM 병합 & 패치 (RVP)${NC}"
    echo -e "${GREEN}======================================${NC}"
    echo ""
    
    check_dependencies || exit 1
    get_apkm_file || exit 0
    merge_apkm || exit 1
    run_patch || exit 1
    
    echo -e "${GREEN}모든 작업이 끝났습니다.${NC}"
}

main