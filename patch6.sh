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

# GitHub Setup for Keystore & Patches
GITHUB_REPO="anycall6779/K-K-0_rev-nced_p-tch"
GITHUB_API_URL="https://api.github.com/repos/$GITHUB_REPO/releases"
KEYSTORE_URL="https://github.com/anycall6779/K-K-0_rev-nced_p-tch/raw/refs/heads/main/my_kakao_key.keystore"
KEYSTORE_FILE="$PATCH_SCRIPT_DIR/my_kakao_key.keystore"
MORPHE_CLI_JAR="$PATCH_SCRIPT_DIR/morphe-cli.jar"
MPP_FILE="$BASE_DIR/patches-fixed.mpp"

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

# --- Fetch MPP from GitHub Releases ---
fetch_mpp_from_github() {
    echo ""
    echo -e "${YELLOW}==================================${NC}"
    echo -e "${GREEN}MPP 파일 선택 (GitHub Releases)${NC}"
    echo -e "${YELLOW}==================================${NC}"
    echo ""
    
    echo -e "${BLUE}[INFO] GitHub 릴리스 정보 가져오는 중...${NC}"
    
    # 최근 10개 릴리스 가져오기
    local RELEASES_JSON=$(curl -s "$GITHUB_API_URL?per_page=10" 2>/dev/null)
    
    if [ -z "$RELEASES_JSON" ] || echo "$RELEASES_JSON" | grep -q '"message"'; then
        echo -e "${RED}[ERROR] GitHub API 요청 실패. 인터넷 연결을 확인하세요.${NC}"
        return 1
    fi
    
    # 릴리스 정보 파싱 (tag_name과 .mpp 파일 URL)
    local RELEASE_TAGS=()
    local MPP_URLS=()
    local MPP_NAMES=()
    
    # jq가 있으면 사용, 없으면 grep/sed로 파싱
    if command -v jq &> /dev/null; then
        while IFS= read -r line; do
            RELEASE_TAGS+=("$line")
        done < <(echo "$RELEASES_JSON" | jq -r '.[].tag_name')
        
        while IFS= read -r line; do
            MPP_URLS+=("$line")
        done < <(echo "$RELEASES_JSON" | jq -r '.[] | .assets[] | select(.name | endswith(".mpp") and (contains("sources") | not) and (contains("javadoc") | not)) | .browser_download_url' | head -10)
        
        while IFS= read -r line; do
            MPP_NAMES+=("$line")
        done < <(echo "$RELEASES_JSON" | jq -r '.[] | .assets[] | select(.name | endswith(".mpp") and (contains("sources") | not) and (contains("javadoc") | not)) | .name' | head -10)
    else
        # jq 없을 때 기본 파싱 (간단한 grep 사용)
        while IFS= read -r line; do
            RELEASE_TAGS+=("$line")
        done < <(echo "$RELEASES_JSON" | grep -oP '"tag_name"\s*:\s*"\K[^"]+' | head -10)
        
        while IFS= read -r line; do
            # .mpp로 끝나고 sources/javadoc이 아닌 URL만 필터링
            if [[ "$line" == *.mpp ]] && [[ "$line" != *sources* ]] && [[ "$line" != *javadoc* ]]; then
                MPP_URLS+=("$line")
                MPP_NAMES+=("$(basename "$line")")
            fi
        done < <(echo "$RELEASES_JSON" | grep -oP '"browser_download_url"\s*:\s*"\K[^"]+\.mpp')
    fi
    
    if [ ${#MPP_URLS[@]} -eq 0 ]; then
        echo -e "${RED}[ERROR] 사용 가능한 MPP 파일을 찾을 수 없습니다.${NC}"
        return 1
    fi
    
    echo ""
    echo -e "${GREEN}사용 가능한 MPP 버전:${NC}"
    echo -e "  ${BLUE}0.${NC} 최신 버전 자동 선택 (${MPP_NAMES[0]:-첫번째})"
    for i in "${!MPP_URLS[@]}"; do
        echo -e "  ${GREEN}$((i+1)).${NC} ${MPP_NAMES[$i]}"
    done
    echo ""
    echo -e "${YELLOW}번호를 입력하세요 (기본: 0 - 최신 버전):${NC}"
    read -r -p "> " selection
    
    # 기본값 또는 0 선택 시 최신 버전
    if [ -z "$selection" ] || [ "$selection" = "0" ]; then
        selection=1
    fi
    
    if [[ "$selection" =~ ^[0-9]+$ ]] && [ "$selection" -ge 1 ] && [ "$selection" -le ${#MPP_URLS[@]} ]; then
        SELECTED_MPP_URL="${MPP_URLS[$((selection-1))]}"
        SELECTED_MPP_NAME="${MPP_NAMES[$((selection-1))]}"
        echo -e "${GREEN}[선택됨] ${SELECTED_MPP_NAME}${NC}"
    else
        echo -e "${RED}[ERROR] 잘못된 선택입니다. 최신 버전을 사용합니다.${NC}"
        SELECTED_MPP_URL="${MPP_URLS[0]}"
        SELECTED_MPP_NAME="${MPP_NAMES[0]}"
    fi
    
    # MPP 다운로드
    echo -e "${YELLOW}[INFO] MPP 다운로드 중: ${SELECTED_MPP_NAME}...${NC}"
    rm -f "$MPP_FILE"
    curl -L -o "$MPP_FILE" "$SELECTED_MPP_URL" || {
        echo -e "${RED}[ERROR] MPP 다운로드 실패!${NC}"
        return 1
    }
    
    echo -e "${GREEN}[✓] MPP 다운로드 완료: $MPP_FILE${NC}"
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

# --- Run Patch (Morphe + TUI 메뉴) ---
run_patch() {
    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}    Morphe 패치 시작... (패치 메뉴 로딩)${NC}"
    echo -e "${GREEN}========================================${NC}"
    
    # 파이썬 기반 TUI 다운로드
    if [ ! -d "$PATCH_SCRIPT_DIR/revanced-build-script" ]; then
        echo -e "${YELLOW}[INFO] 패치 선택기(AmpleReVanced UI) 다운로드 중...${NC}"
        git clone https://github.com/AmpleReVanced/revanced-build-script.git "$PATCH_SCRIPT_DIR/revanced-build-script" -q
    else
        git -C "$PATCH_SCRIPT_DIR/revanced-build-script" pull -q
    fi

    echo -e "${YELLOW}[INFO] 고정 키스토어(my_kakao_key.keystore) 다운로드 중...${NC}"
    if [ ! -f "$KEYSTORE_FILE" ]; then
        curl -L -s -o "$KEYSTORE_FILE" "$KEYSTORE_URL" || {
            echo -e "${RED}[ERROR] 키스토어 다운로드 실패!${NC}"
            return 1
        }
    fi
    
    # build.py 스크립트 실행 폴더로 이동
    cd "$PATCH_SCRIPT_DIR/revanced-build-script"
    
    # 이전 잔재 삭제
    rm -rf output out
    
    # 파이썬 코드를 핫픽스하여 최신 Morphe 엔진과 호환되게 만듭니다 (자동 다운로드 우회)
    cat << 'EOF' > fix_build.py
import os
with open('build.py', 'r', encoding='utf-8') as f: code = f.read()
code = code.replace("tag_cli, assets_cli = get_latest_release(CLI_RELEASE_URL)", "tag_cli = 'dummy'; assets_cli = []")
code = code.replace("url_cli, name_cli = pick_cli_jar_download_url(assets_cli)", "url_cli = 'http://dummy'; name_cli = 'dummy'")
code = code.replace("dest_cli = os.path.join(args.output, name_cli)", "dest_cli = os.environ.get('MORPHE_CLI_JAR')")
code = code.replace("download_file(url_cli, dest_cli)", "pass")
code = code.replace("tag_patches, assets_patches = get_latest_release(PATCHES_RELEASE_URL)", "tag_patches = 'dummy'; assets_patches = []")
code = code.replace("url_rvp, name_rvp = pick_patches_rvp_download_url(assets_patches)", "url_rvp = 'http://dummy'; name_rvp = 'dummy'")
code = code.replace("dest_rvp = os.path.join(args.output, name_rvp)", "dest_rvp = os.environ.get('MPP_FILE')")
code = code.replace("download_file(url_rvp, dest_rvp)", "pass")
code = code.replace("cmd.append(rvp_path)", "cmd.extend(['--patches', rvp_path])")
with open('build.py', 'w', encoding='utf-8') as f: f.write(code)
EOF
    python fix_build.py

    echo -e "${BLUE}[INFO] 패치 선택 메뉴를 엽니다...${NC}"

    export MORPHE_CLI_JAR="$MORPHE_CLI_JAR"
    export MPP_FILE="$MPP_FILE"

    python build.py \
        --apk "$MERGED_APK_PATH" \
        --package "$PKG_NAME" \
        --include-universal \
        --keystore "$KEYSTORE_FILE" \
        --key-alias "revanced" \
        --keystore-password "android" \
        --key-password "android" \
        --run || {
        echo -e "${RED}[ERROR] 패치 과정 중 오류 발생${NC}"
        return 1
    }
    
    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}    패치 완료!${NC}"
    echo -e "${GREEN}========================================${NC}"
    
    # 결과물 찾기 및 복사
    local OUTPUT_APK=""
    if [ -f "output/patched.apk" ]; then
        OUTPUT_APK="output/patched.apk"
    elif [ -f "out/patched.apk" ]; then
        OUTPUT_APK="out/patched.apk"
    else
        OUTPUT_APK=$(find output out -name "*.apk" -type f 2>/dev/null | head -n 1)
    fi

    if [ -n "$OUTPUT_APK" ] && [ -f "$OUTPUT_APK" ]; then
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
    fetch_mpp_from_github || exit 1
    merge_apkm || exit 1
    run_patch || exit 1
    
    echo -e "${GREEN}모든 작업이 끝났습니다.${NC}"
}

main
