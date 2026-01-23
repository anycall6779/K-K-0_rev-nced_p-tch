#!/bin/bash
#
# Simplified APKM Merger + Patcher for KakaoTalk (AmpleReVanced Edition)
# (Modified: Enforces Custom Keystore for Consistent Signing)
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
PATCH_SCRIPT_DIR="$HOME/revanced-build-script-ample"
MERGED_APK_PATH="$HOME/Downloads/KakaoTalk_Merged.apk"
EDITOR_JAR="$BASE_DIR/APKEditor-1.4.5.jar"

# GitHub 설정 - 키스토어
KEYSTORE_URL="https://github.com/anycall6779/K-K-0_rev-nced_p-tch/raw/refs/heads/main/my_kakao_key.keystore"
GITHUB_REPO="anycall6779/K-K-0_rev-nced_p-tch"
GITHUB_API_URL="https://api.github.com/repos/$GITHUB_REPO/releases"

KEYSTORE_FILE="my_kakao_key.keystore"
RVP_FILE="$BASE_DIR/patches-fixed.rvp"

# --- Fetch RVP from GitHub Releases ---
fetch_rvp_from_github() {
    echo ""
    echo -e "${YELLOW}==================================${NC}"
    echo -e "${GREEN}RVP 파일 선택 (GitHub Releases)${NC}"
    echo -e "${YELLOW}==================================${NC}"
    echo ""
    
    echo -e "${BLUE}[INFO] GitHub 릴리스 정보 가져오는 중...${NC}"
    
    # 최근 10개 릴리스 가져오기
    local RELEASES_JSON=$(curl -s "$GITHUB_API_URL?per_page=10" 2>/dev/null)
    
    if [ -z "$RELEASES_JSON" ] || echo "$RELEASES_JSON" | grep -q '"message"'; then
        echo -e "${RED}[ERROR] GitHub API 요청 실패. 인터넷 연결을 확인하세요.${NC}"
        return 1
    fi
    
    # 릴리스 정보 파싱 (tag_name과 .rvp 파일 URL)
    local RELEASE_TAGS=()
    local RVP_URLS=()
    local RVP_NAMES=()
    
    # jq가 있으면 사용, 없으면 grep/sed로 파싱
    if command -v jq &> /dev/null; then
        while IFS= read -r line; do
            RELEASE_TAGS+=("$line")
        done < <(echo "$RELEASES_JSON" | jq -r '.[].tag_name')
        
        while IFS= read -r line; do
            RVP_URLS+=("$line")
        done < <(echo "$RELEASES_JSON" | jq -r '.[] | .assets[] | select(.name | endswith(".rvp") and (contains("sources") | not) and (contains("javadoc") | not)) | .browser_download_url' | head -10)
        
        while IFS= read -r line; do
            RVP_NAMES+=("$line")
        done < <(echo "$RELEASES_JSON" | jq -r '.[] | .assets[] | select(.name | endswith(".rvp") and (contains("sources") | not) and (contains("javadoc") | not)) | .name' | head -10)
    else
        # jq 없을 때 기본 파싱 (간단한 grep 사용)
        while IFS= read -r line; do
            RELEASE_TAGS+=("$line")
        done < <(echo "$RELEASES_JSON" | grep -oP '"tag_name"\s*:\s*"\K[^"]+' | head -10)
        
        while IFS= read -r line; do
            # .rvp로 끝나고 sources/javadoc이 아닌 URL만 필터링
            if [[ "$line" == *.rvp ]] && [[ "$line" != *sources* ]] && [[ "$line" != *javadoc* ]]; then
                RVP_URLS+=("$line")
                RVP_NAMES+=("$(basename "$line")")
            fi
        done < <(echo "$RELEASES_JSON" | grep -oP '"browser_download_url"\s*:\s*"\K[^"]+\.rvp')
    fi
    
    if [ ${#RVP_URLS[@]} -eq 0 ]; then
        echo -e "${RED}[ERROR] 사용 가능한 RVP 파일을 찾을 수 없습니다.${NC}"
        return 1
    fi
    
    echo ""
    echo -e "${GREEN}사용 가능한 RVP 버전:${NC}"
    echo -e "  ${BLUE}0.${NC} 최신 버전 자동 선택 (${RVP_NAMES[0]:-첫번째})"
    for i in "${!RVP_URLS[@]}"; do
        echo -e "  ${GREEN}$((i+1)).${NC} ${RVP_NAMES[$i]}"
    done
    echo ""
    echo -e "${YELLOW}번호를 입력하세요 (기본: 0 - 최신 버전):${NC}"
    read -r -p "> " selection
    
    # 기본값 또는 0 선택 시 최신 버전
    if [ -z "$selection" ] || [ "$selection" = "0" ]; then
        selection=1
    fi
    
    if [[ "$selection" =~ ^[0-9]+$ ]] && [ "$selection" -ge 1 ] && [ "$selection" -le ${#RVP_URLS[@]} ]; then
        SELECTED_RVP_URL="${RVP_URLS[$((selection-1))]}"
        SELECTED_RVP_NAME="${RVP_NAMES[$((selection-1))]}"
        echo -e "${GREEN}[선택됨] ${SELECTED_RVP_NAME}${NC}"
    else
        echo -e "${RED}[ERROR] 잘못된 선택입니다. 최신 버전을 사용합니다.${NC}"
        SELECTED_RVP_URL="${RVP_URLS[0]}"
        SELECTED_RVP_NAME="${RVP_NAMES[0]}"
    fi
    
    # RVP 다운로드
    echo -e "${YELLOW}[INFO] RVP 다운로드 중: ${SELECTED_RVP_NAME}...${NC}"
    rm -f "$RVP_FILE"
    curl -L -o "$RVP_FILE" "$SELECTED_RVP_URL" || {
        echo -e "${RED}[ERROR] RVP 다운로드 실패!${NC}"
        return 1
    }
    
    echo -e "${GREEN}[✓] RVP 다운로드 완료: $RVP_FILE${NC}"
    return 0
}

# Get device info
ARCH=$(getprop ro.product.cpu.abi)
[ "$ARCH" = "arm64-v8a" ] && ARCH_APK="arm64" || ARCH_APK="armeabi"

# --- Dependency Check ---
check_dependencies() {
    echo -e "${BLUE}[INFO] 필수 도구 확인 중...${NC}"
    local MISSING=0
    
    for cmd in curl wget unzip java python git; do
        if ! command -v $cmd &> /dev/null; then
            echo -e "${RED}[ERROR] '$cmd' 가 없습니다. 설치 명령어: pkg install $cmd${NC}"
            MISSING=1
        fi
    done
    
    if [ ! -d "$PATCH_SCRIPT_DIR" ]; then
        echo -e "${YELLOW}[INFO] AmpleReVanced 빌드 스크립트 다운로드 중...${NC}"
        git clone https://github.com/AmpleReVanced/revanced-build-script.git "$PATCH_SCRIPT_DIR" || {
            echo -e "${RED}[ERROR] 빌드 스크립트 다운로드 실패${NC}"
            MISSING=1
        }
    else
        echo -e "${YELLOW}[INFO] 빌드 스크립트 업데이트 확인 중...${NC}"
        git -C "$PATCH_SCRIPT_DIR" pull
    fi
    
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

# --- Run Patch (AmpleReVanced) ---
run_patch() {
    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}    AmpleReVanced 패치 시작...${NC}"
    echo -e "${GREEN}========================================${NC}"
    
    cd "$PATCH_SCRIPT_DIR"
    
    # [추가됨] 깃허브에서 고정 키스토어 다운로드
    echo -e "${YELLOW}[INFO] 고정 키스토어(my_kakao_key.keystore) 다운로드 중...${NC}"
    curl -L -o "$KEYSTORE_FILE" "$KEYSTORE_URL" || {
        echo -e "${RED}[ERROR] 키스토어 다운로드 실패! 인터넷 연결이나 URL을 확인하세요.${NC}"
        return 1
    }

    # 이전 결과물 삭제
    rm -rf output out
    
    # [수정됨] GitHub Releases에서 RVP 선택 및 다운로드
    fetch_rvp_from_github || {
        echo -e "${RED}[ERROR] RVP 선택/다운로드 실패!${NC}"
        return 1
    }
    
    # Termux 호환성을 위해 python3 -> python
    # [수정됨] --keystore + --rvp 옵션 사용
    python build.py \
        --apk "$MERGED_APK_PATH" \
        --package "$PKG_NAME" \
        --include-universal \
        --keystore "$KEYSTORE_FILE" \
        --rvp "$RVP_FILE" \
        --run || {
        echo -e "${RED}[ERROR] 패치 과정 중 오류 발생${NC}"
        return 1
    }
    
    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}    패치 완료!${NC}"
    echo -e "${GREEN}========================================${NC}"
    
    # 1. 디시인사이드 스크립트에서 성공한 'output/out' 폴더 자동 검색 로직 적용
    local OUTPUT_APK=""
    if [ -f "output/patched.apk" ]; then
        OUTPUT_APK="output/patched.apk"
    elif [ -f "out/patched.apk" ]; then
        OUTPUT_APK="out/patched.apk"
    else
        OUTPUT_APK=$(find output out -name "*.apk" -type f 2>/dev/null | head -n 1)
    fi

    # 2. 결과물 확인 및 요청하신 경로로 이동
    if [ -n "$OUTPUT_APK" ] && [ -f "$OUTPUT_APK" ]; then
        echo -e "${BLUE}[INFO] 결과물을 다운로드 폴더로 이동합니다...${NC}"
        # 덮어쓰기(-f) 및 요청하신 파일명으로 이동
        mv -f "$OUTPUT_APK" "/storage/emulated/0/Download/kakaotalkpatch.apk"
        echo -e "${GREEN}[SUCCESS] 저장 완료: /storage/emulated/0/Download/kakaotalkpatch.apk${NC}"
    else
        echo -e "${YELLOW}[WARN] 결과물 파일을 찾을 수 없습니다. 직접 확인해주세요: $PATCH_SCRIPT_DIR/output 또는 $PATCH_SCRIPT_DIR/out${NC}"
    fi
}

# --- Main ---
main() {
    clear
    echo -e "${GREEN}======================================${NC}"
    echo -e "${GREEN}  카카오톡 APKM 병합 & 패치 (Key Fixed)${NC}"
    echo -e "${GREEN}======================================${NC}"
    echo ""
    
    check_dependencies || exit 1
    get_apkm_file || exit 0
    merge_apkm || exit 1
    run_patch || exit 1
    
    echo -e "${GREEN}모든 작업이 끝났습니다.${NC}"
}

main