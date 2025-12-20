#!/bin/bash
#
# ReVanced Patcher for KakaoTalk (Target: footfoot22/revanced-patches_fix)
# (Modified: APKM Merge + CLI Patching)
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
WORK_DIR="$HOME/revanced-kakao-footfoot22"
MERGED_APK_PATH="$HOME/Downloads/KakaoTalk_Merged.apk"
EDITOR_JAR="$BASE_DIR/APKEditor-1.4.5.jar"

# Repositories (footfoot22 설정)
PATCHES_REPO="footfoot22/revanced-patches_fix"
CLI_REPO="ReVanced/revanced-cli"
INTEGRATIONS_REPO="ReVanced/revanced-integrations"

# --- Dependency Check ---
check_dependencies() {
    echo -e "${BLUE}[INFO] 필수 도구 확인 중...${NC}"
    local MISSING=0
    
    # jq 추가됨 (GitHub API 파싱용)
    for cmd in curl wget unzip java git jq; do
        if ! command -v $cmd &> /dev/null; then
            echo -e "${RED}[ERROR] '$cmd' 가 없습니다. 설치 명령어: pkg install $cmd${NC}"
            MISSING=1
        fi
    done
    
    # 작업 폴더 생성
    mkdir -p "$WORK_DIR"
    
    if [ ! -f "$EDITOR_JAR" ]; then
        echo -e "${YELLOW}[INFO] APKEditor 다운로드 중...${NC}"
        wget --quiet --show-progress -O "$EDITOR_JAR" \
            "https://github.com/REAndroid/APKEditor/releases/download/V1.4.5/APKEditor-1.4.5.jar" || {
            echo -e "${RED}[ERROR] APKEditor 다운로드 실패${NC}"
            MISSING=1
        }
    fi
    
    [ $MISSING -eq 1 ] && exit 1
    mkdir -p "$HOME/Downloads"
    echo -e "${GREEN}[OK] 모든 준비 완료${NC}"
}

# --- Helper: Get Latest Release ---
get_latest_release() {
    local repo=$1
    local pattern=$2
    local output=$3
    
    echo -e "${YELLOW}[DOWNLOAD] $repo 에서 최신 파일 검색 중...${NC}"
    local download_url=$(curl -s "https://api.github.com/repos/$repo/releases/latest" | \
        jq -r ".assets[] | select(.name | test(\"$pattern\")) | .browser_download_url" | head -n 1)

    if [ -z "$download_url" ] || [ "$download_url" == "null" ]; then
        echo -e "${RED}[ERROR] $repo 에서 $pattern 파일을 찾을 수 없습니다.${NC}"
        return 1
    fi

    # 이미 파일이 있으면 다운로드 건너뛰기 (선택 사항)
    # rm -f "$output" # 항상 새로 받으려면 주석 해제
    
    echo -e "⬇️ 다운로드: $download_url"
    curl -L -o "$output" "$download_url"
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
    }
    
    echo -e "${GREEN}[SUCCESS] 병합 완료: $(basename "$MERGED_APK_PATH")${NC}"
    rm -rf "$TEMP_DIR"
    return 0
}

# --- Run Patch (footfoot22/CLI) ---
run_patch() {
    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}    footfoot22 패치 다운로드 및 실행...${NC}"
    echo -e "${GREEN}========================================${NC}"
    
    cd "$WORK_DIR"

    # 1. 파일 다운로드 (CLI, Patches, Integrations)
    get_latest_release "$CLI_REPO" "cli.*\.jar" "revanced-cli.jar" || return 1
    get_latest_release "$INTEGRATIONS_REPO" "integrations.*\.apk" "integrations.apk" || return 1
    get_latest_release "$PATCHES_REPO" "patches.*\.jar" "patches.jar" || return 1
    
    # patches.json 다운로드 시도 (없을 수도 있음)
    echo -e "${YELLOW}[CHECK] patches.json 확인 중...${NC}"
    local json_url=$(curl -s "https://api.github.com/repos/$PATCHES_REPO/releases/latest" | \
        jq -r ".assets[] | select(.name | test(\"json\")) | .browser_download_url" | head -n 1)
        
    if [ -n "$json_url" ] && [ "$json_url" != "null" ]; then
        echo -e "⬇️ 다운로드: patches.json"
        curl -L -o "patches.json" "$json_url"
    else
        echo -e "${YELLOW}[WARN] patches.json 없음. jar 내장 파일 사용.${NC}"
        rm -f patches.json
    fi

    echo ""
    echo -e "${BLUE}[INFO] 패치 프로세스 시작 (시간이 소요됩니다)...${NC}"
    
    local FINAL_OUTPUT="patched_kakao.apk"
    rm -f "$FINAL_OUTPUT"

    # 2. ReVanced CLI 실행
    # (주의: CLI 방식은 키스토어 비밀번호가 필요하므로, 여기서는 기본 서명(Debug Key)을 사용합니다.)
    # (기존 카톡을 삭제하고 설치해야 합니다.)
    
    if [ -f "patches.json" ]; then
        java -jar revanced-cli.jar patch \
            --patch-bundle patches.jar \
            --patches-json patches.json \
            --merge integrations.apk \
            --out "$FINAL_OUTPUT" \
            "$MERGED_APK_PATH"
    else
        java -jar revanced-cli.jar patch \
            --patch-bundle patches.jar \
            --merge integrations.apk \
            --out "$FINAL_OUTPUT" \
            "$MERGED_APK_PATH"
    fi

    # 3. 결과 확인 및 이동
    if [ -f "$FINAL_OUTPUT" ]; then
        echo ""
        echo -e "${GREEN}========================================${NC}"
        echo -e "${GREEN}    패치 완료!${NC}"
        echo -e "${GREEN}========================================${NC}"
        
        local TARGET_PATH="/storage/emulated/0/Download/kakaotalkpatch.apk"
        mv -f "$FINAL_OUTPUT" "$TARGET_PATH"
        
        echo -e "${BLUE}[INFO] 결과물 이동 완료${NC}"
        echo -e "${GREEN}[SUCCESS] 저장됨: $TARGET_PATH${NC}"
        echo -e "${YELLOW}* 주의: 서명이 변경되었으므로 기존 카톡을 삭제 후 설치하세요.${NC}"
    else
        echo -e "${RED}[ERROR] 패치된 파일이 생성되지 않았습니다. 위 로그를 확인하세요.${NC}"
        return 1
    fi
}

# --- Main ---
main() {
    clear
    echo -e "${GREEN}======================================${NC}"
    echo -e "${GREEN}  카카오톡 Patcher (Target: footfoot22)${NC}"
    echo -e "${GREEN}======================================${NC}"
    echo ""
    
    check_dependencies || exit 1
    get_apkm_file || exit 0
    merge_apkm || exit 1
    run_patch || exit 1
    
    echo -e "${GREEN}모든 작업이 끝났습니다.${NC}"
}

main
