#!/bin/bash
#
# KakaoTalk APKM Merger (No Patch) for Termux
# - patch5.sh 흐름에서 패치 단계만 제거
#

set -e

# Color Codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configuration
BASE_DIR="/storage/emulated/0/Download"
MERGED_APK_PATH="$BASE_DIR/KakaoTalk_Merged.apk"
EDITOR_JAR="$BASE_DIR/APKEditor-1.4.5.jar"

check_dependencies() {
    echo -e "${BLUE}[INFO] 필수 도구 확인 중...${NC}"
    local missing=0

    install_cmd() {
        local cmd="$1"
        local pkg_name="$1"
        [ "$cmd" = "java" ] && pkg_name="openjdk-17"
        echo -e "${YELLOW}[WARN] '$cmd' 없음. 설치 시도: pkg install -y $pkg_name${NC}"
        pkg install -y "$pkg_name" >/dev/null 2>&1 || true
        command -v "$cmd" >/dev/null 2>&1 || missing=1
    }

    for cmd in curl unzip java; do
        command -v "$cmd" >/dev/null 2>&1 || install_cmd "$cmd"
    done

    if [ "$missing" -eq 1 ]; then
        echo -e "${RED}[ERROR] 필수 도구 설치 실패. 수동 설치 후 다시 실행하세요.${NC}"
        echo -e "${YELLOW}pkg install unzip curl openjdk-17${NC}"
        exit 1
    fi

    if [ ! -f "$EDITOR_JAR" ]; then
        echo -e "${YELLOW}[INFO] APKEditor 다운로드 중...${NC}"
        curl -L -o "$EDITOR_JAR" \
            "https://github.com/REAndroid/APKEditor/releases/download/V1.4.5/APKEditor-1.4.5.jar" || {
            echo -e "${RED}[ERROR] APKEditor 다운로드 실패${NC}"
            exit 1
        }
    fi

    echo -e "${GREEN}[OK] 준비 완료${NC}"
}

get_apkm_file() {
    echo ""
    echo -e "${YELLOW}==================================${NC}"
    echo -e "${GREEN}카카오톡 APKM 파일 선택${NC}"
    echo -e "${YELLOW}==================================${NC}"
    echo ""

    local apkm_files=()
    while IFS= read -r -d '' file; do
        apkm_files+=("$(basename "$file")")
    done < <(find "$BASE_DIR" -maxdepth 1 -name "*.apkm" -print0 2>/dev/null)

    if [ ${#apkm_files[@]} -gt 0 ]; then
        echo -e "${BLUE}다운로드 폴더에서 발견된 APKM 파일:${NC}"
        for i in "${!apkm_files[@]}"; do
            echo -e "  ${GREEN}$((i+1)).${NC} ${apkm_files[$i]}"
        done
        echo ""
        echo -e "${YELLOW}번호를 입력하거나, 직접 경로를 입력하세요:${NC}"
        read -r -p "> " selection

        if [[ "$selection" =~ ^[0-9]+$ ]] && [ "$selection" -ge 1 ] && [ "$selection" -le ${#apkm_files[@]} ]; then
            APKM_FILE="$BASE_DIR/${apkm_files[$((selection-1))]}"
            echo -e "${GREEN}[선택됨] ${apkm_files[$((selection-1))]}${NC}"
            return 0
        fi

        if [ -n "$selection" ]; then
            APKM_FILE="$selection"
        fi
    else
        echo -e "${BLUE}APKM 파일의 전체 경로를 입력하세요:${NC}"
        read -r -p "> " APKM_FILE
    fi

    if [ -z "$APKM_FILE" ] || [ ! -f "$APKM_FILE" ]; then
        echo -e "${RED}[ERROR] 유효하지 않은 파일 경로입니다.${NC}"
        return 1
    fi
}

merge_apkm() {
    echo ""
    echo -e "${BLUE}[INFO] APKM 파일 병합 시작...${NC}"
    local temp_dir="$BASE_DIR/kakao_temp_merge"
    rm -rf "$temp_dir" && mkdir -p "$temp_dir"

    unzip -qqo "$APKM_FILE" -d "$temp_dir" 2>/dev/null || {
        echo -e "${RED}[ERROR] 압축 해제 실패${NC}"
        rm -rf "$temp_dir"
        return 1
    }

    if [ ! -f "$temp_dir/base.apk" ]; then
        echo -e "${RED}[ERROR] base.apk 없음${NC}"
        rm -rf "$temp_dir"
        return 1
    fi

    echo -e "${BLUE}[INFO] APKEditor로 병합 중...${NC}"
    rm -f "$MERGED_APK_PATH"
    java -jar "$EDITOR_JAR" m -i "$temp_dir" -o "$MERGED_APK_PATH" >/dev/null 2>&1 || {
        echo -e "${RED}[ERROR] 병합 실패${NC}"
        rm -rf "$temp_dir"
        return 1
    }

    if [ ! -f "$MERGED_APK_PATH" ]; then
        echo -e "${RED}[ERROR] 병합된 파일 생성 실패${NC}"
        rm -rf "$temp_dir"
        return 1
    fi

    rm -rf "$temp_dir"
    echo -e "${GREEN}[SUCCESS] 병합 완료: $MERGED_APK_PATH${NC}"
}

main() {
    clear
    echo -e "${GREEN}======================================${NC}"
    echo -e "${GREEN} 카카오톡 APKM 병합 전용 (No Patch) ${NC}"
    echo -e "${GREEN}======================================${NC}"
    echo ""

    check_dependencies
    get_apkm_file || exit 1
    merge_apkm || exit 1

    echo ""
    echo -e "${GREEN}모든 작업이 끝났습니다.${NC}"
}

main
