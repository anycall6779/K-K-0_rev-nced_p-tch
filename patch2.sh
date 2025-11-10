#!/bin/bash
#
# APKM 병합 + ReVanced CLI 패치 스크립트 (RVP 파일 사용)
#
set -e # 오류 발생 시 즉시 중지

# --- 1. 기본 설정 및 변수 ---
# 색상 코드
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 앱 고정 정보
PKG_NAME="com.kakao.talk"

# 경로 설정
BASE_DIR="/storage/emulated/0/Download" # 작업 폴더
FINAL_OUTPUT_DIR="/storage/emulated/0" # 최종 파일 출력 위치

# 패치 도구 경로
EDITOR_JAR="$BASE_DIR/APKEditor-1.4.5.jar"
CLI_JAR="$BASE_DIR/revanced-cli.jar" # ReVanced CLI
RVP_FILE="$BASE_DIR/patches-ample.rvp" # Ample 패치 파일
TEMP_MERGE_DIR="$BASE_DIR/temp_merge_dir"

# 사용자가 제공한 RVP 파일 URL
RVP_URL="https://github.com/AmpleReVanced/revanced-patches/releases/download/v5.45.0-ample.1/patches-5.45.0-ample.1.rvp"

# 패치 스크립트가 아닌, 병합된 APK가 저장될 위치
MERGED_APK_PATH="$HOME/Downloads/KakaoTalk-merged.apk"

# --- 2. 도구 확인 함수 ---
check_dependencies() {
    echo -e "${BLUE}[INFO] Checking dependencies...${NC}"
    local MISSING=0
    # python, git 제외. java, unzip, wget만 필요.
    for cmd in wget unzip java; do
        if ! command -v $cmd &> /dev/null; then
            echo -e "${RED}[ERROR] '$cmd' not found. Please run 'pkg install ${cmd}'${NC}"
            MISSING=1
        fi
    done
    
    # 1. APKEditor (병합용)
    if [ ! -f "$EDITOR_JAR" ]; then
        echo -e "${YELLOW}[WARNING] $EDITOR_JAR not found. Downloading...${NC}"
        wget -q --show-progress -O "$EDITOR_JAR" "https://github.com/REAndroid/APKEditor/releases/download/V1.4.5/APKEditor-1.4.5.jar" || {
            echo -e "${RED}[ERROR] Failed to download APKEditor.${NC}"; MISSING=1;
        }
    fi
    
    # 2. ReVanced CLI (패치용)
    if [ ! -f "$CLI_JAR" ]; then
        echo -e "${YELLOW}[WARNING] $CLI_JAR not found. Downloading...${NC}"
        # (ReVanced CLI의 공식 릴리즈 URL 예시, 필요시 변경)
        wget -q --show-progress -O "$CLI_JAR" "https://github.com/revanced/revanced-cli/releases/download/v4.4.0/revanced-cli-4.4.0-all.jar" || {
            echo -e "${RED}[ERROR] Failed to download ReVanced CLI.${NC}"; MISSING=1;
        }
    fi

    [ $MISSING -eq 1 ] && exit 1
    mkdir -p "$HOME/Downloads"
}

# --- 3. 파일 경로 수동 입력 ---
get_file_input() {
    echo -e "\n${YELLOW}[INFO] 패치할 .apk 또는 .apkm 파일의 전체 경로를 입력하세요.${NC}"
    echo -e " (예: /storage/emulated/0/Download/kakaotalk.apk)"
    
    read -p "> " SELECTED_FILE_PATH

    SELECTED_FILE_PATH=$(echo "$SELECTED_FILE_PATH" | tr -d \'\")

    if [ -z "$SELECTED_FILE_PATH" ]; then
        echo -e "${RED}[ERROR] No path entered.${NC}"; return 1;
    fi
    if [ ! -f "$SELECTED_FILE_PATH" ]; then
         echo -e "${RED}[ERROR] File not found: $SELECTED_FILE_PATH${NC}"; return 1;
    fi
    
    FILE_EXT="${SELECTED_FILE_PATH##*.}"
    if [[ "$FILE_EXT" != "apk" && "$FILE_EXT" != "apkm" ]]; then
         echo -e "${RED}[ERROR] The selected file is not an .apk or .apkm file.${NC}"; return 1;
    fi
    
    echo -e "${GREEN}[SUCCESS] Selected file: $SELECTED_FILE_PATH${NC}"
}

# --- 4. 파일 준비 (병합 또는 복사) ---
prepare_file() {
    rm -f "$MERGED_APK_PATH" # 기존에 있던 파일 삭제

    # .apkm 파일이면 병합 수행
    if [[ "$FILE_EXT" == "apkm" ]]; then
        echo -e "\n${BLUE}[INFO] .apkm file detected. Repackaging... (-> $MERGED_APK_PATH)${NC}"
        rm -rf "$TEMP_MERGE_DIR" && mkdir -p "$TEMP_MERGE_DIR"
        
        echo -e "${BLUE}[INFO] Extracting all files from .apkm...${NC}"
        unzip -qqo "$SELECTED_FILE_PATH" -d "$TEMP_MERGE_DIR" 2> /dev/null

        if [ ! -f "$TEMP_MERGE_DIR/base.apk" ]; then
            echo -e "${RED}[ERROR] base.apk not found. Is the selected file a valid .apkm?${NC}"
            rm -rf "$TEMP_MERGE_DIR"; return 1;
        fi

        echo -e "${BLUE}[INFO] Merging with APKEditor... (this may take a moment)${NC}"
        java -jar "$EDITOR_JAR" m -i "$TEMP_MERGE_DIR" -o "$MERGED_APK_PATH"
        
        if [ ! -f "$MERGED_APK_PATH" ]; then
            echo -e "${RED}[ERROR] APKEditor merge failed.${NC}"; rm -rf "$TEMP_MERGE_DIR"; return 1;
        fi
        
        echo -e "${GREEN}[SUCCESS] Merge complete.${NC}"
        rm -rf "$TEMP_MERGE_DIR"
    
    # .apk 파일이면 그냥 복사
    elif [[ "$FILE_EXT" == "apk" ]]; then
        echo -e "\n${BLUE}[INFO] .apk file detected. Skipping merge.${NC}"
        echo -e "${BLUE}[INFO] Copying file to target location... (-> $MERGED_APK_PATH)${NC}"
        cp "$SELECTED_FILE_PATH" "$MERGED_APK_PATH"
        echo -e "${GREEN}[SUCCESS] File copied.${NC}"
    fi
}

# --- 5. ReVanced CLI로 패치 실행 ---
run_patch() {
    echo -e "\n${GREEN}========= Running ReVanced CLI Patch =========${NC}"
    
    # 1. RVP 패치 파일 다운로드
    echo -e "${BLUE}[INFO] Downloading Ample patches ($RVP_URL)...${NC}"
    wget -q --show-progress -O "$RVP_FILE" "$RVP_URL"
    if [ ! -f "$RVP_FILE" ]; then
        echo -e "${RED}[ERROR] Failed to download RVP patch file.${NC}"; return 1;
    fi
    
    # 2. 패치 이름 입력받기
    echo -e "\n${YELLOW}[INFO] 적용할 패치 이름을 콤마(,)로 구분하여 입력하세요.${NC}"
    echo -e " (예: patch-name-1,patch-name-2,patch-name-3)"
    read -p "> " PATCH_NAMES_INPUT
    
    if [ -z "$PATCH_NAMES_INPUT" ]; then
        echo -e "${RED}[ERROR] No patch names entered.${NC}"; return 1;
    fi
    
    # 3. 패치 이름 목록을 --include 인수로 변환
    local PATCH_ARGS=""
    IFS=',' read -ra PATCH_NAMES <<< "$PATCH_NAMES_INPUT"
    for patch in "${PATCH_NAMES[@]}"; do
        # 앞뒤 공백 제거
        patch=$(echo "$patch" | xargs)
        PATCH_ARGS+=" --include \"$patch\""
    done
    
    echo -e "${BLUE}[INFO] Starting patch... (this will take several minutes)${NC}"
    
    local FINAL_PATCHED_FILE="$FINAL_OUTPUT_DIR/$(basename "$MERGED_APK_PATH" .apk)-patched.apk"
    rm -f "$FINAL_PATCHED_FILE"
    
    # 4. ReVanced CLI 실행
    # (주의: eval을 사용하여 $PATCH_ARGS의 따옴표를 올바르게 해석)
    eval "java -jar \"$CLI_JAR\" patch \
        -p \"$RVP_FILE\" \
        -m \"$MERGED_APK_PATH\" \
        -o \"$FINAL_PATCHED_FILE\" \
        $PATCH_ARGS \
        \"$MERGED_APK_PATH\""
        
    local EXIT_CODE=$?
    if [ $EXIT_CODE -ne 0 ]; then
        echo -e "${RED}[ERROR] ReVanced CLI patch failed.${NC}"; return 1;
    fi

    if [ ! -f "$FINAL_PATCHED_FILE" ]; then
        echo -e "${RED}[ERROR] Patched file was not created.${NC}"; return 1;
    fi
    
    echo -e "${GREEN}[SUCCESS] Patch complete!${NC}"
    echo -e "${GREEN}File saved to: $FINAL_PATCHED_FILE${NC}"

    # 5. 정리
    rm -f "$MERGED_APK_PATH"
    rm -f "$RVP_FILE"
    am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE -d "file://$FINAL_PATCHED_FILE"
}


# --- 6. 메인 스크립트 실행 ---
main() {
    clear
    echo -e "${GREEN}=== Smart File Merge & ReVanced CLI Patcher ===${NC}"
    
    # 1. 의존성 확인
    check_dependencies
    
    # 2. 파일 경로 입력
    if ! get_file_input; then
        echo -e "${YELLOW}[INFO] Operation cancelled.${NC}"; exit 0;
    fi
    
    # 3. 파일 준비 (병합 또는 복사)
    if ! prepare_file; then
        exit 1
    fi
    
    # 4. 패치 실행
    if ! run_patch; then
        exit 1
    fi
    
    echo -e "\n${GREEN}========= ALL TASKS COMPLETE =========${NC}"
    echo -e "최종 파일이 Sdcard 최상위 폴더($FINAL_OUTPUT_DIR)에 저장되었습니다."
    echo -e "${GREEN}======================================${NC}"
}

# 스크립트 실행
main
