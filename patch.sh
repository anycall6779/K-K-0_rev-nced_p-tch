#!/bin/bash
#
# 스마트 파일 핸들러 + 자동 병합/패치 스크립트
# (.apk 또는 .apkm을 입력받아 자동 처리)
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
BASE_DIR="/storage/emulated/0/Download" # APKEditor 저장 위치
FINAL_OUTPUT_DIR="/storage/emulated/0" # 최종 파일 출력 위치
PATCH_SCRIPT_DIR="$HOME/revanced-build-script"
MERGED_APK_PATH="$HOME/Downloads/KakaoTalk.apk" # build.py가 읽을 파일 위치

# 도구 경로
EDITOR_JAR="$BASE_DIR/APKEditor-1.4.5.jar"
TEMP_MERGE_DIR="$BASE_DIR/temp_merge_dir"

# --- 2. 도구 확인 함수 ---
check_dependencies() {
    echo -e "${BLUE}[INFO] Checking dependencies...${NC}"
    local MISSING=0
    # dialog 제외
    for cmd in wget unzip java python git; do
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
        wget -q --show-progress --progress=bar:force:noscroll -O "$EDITOR_JAR" "https://github.com/REAndroid/APKEditor/releases/download/V1.4.5/APKEditor-1.4.5.jar" || {
            echo -e "${RED}[ERROR] Failed to download APKEditor.${NC}";
            MISSING=1;
        }
    fi
    
    [ $MISSING -eq 1 ] && exit 1
    mkdir -p "$HOME/Downloads" # build.py가 사용할 폴더 생성
}

# --- 3. 파일 경로 수동 입력 (UI 제거) ---
get_file_input() {
    echo -e "\n${YELLOW}[INFO] 패치할 .apk 또는 .apkm 파일의 전체 경로를 입력하세요.${NC}"
    echo -e " (예: /storage/emulated/0/Download/kakaotalk.apk)"
    
    read -p "> " SELECTED_FILE_PATH

    # 입력값 앞뒤의 작은따옴표/큰따옴표 제거 (경로 붙여넣기 시 오류 방지)
    SELECTED_FILE_PATH=$(echo "$SELECTED_FILE_PATH" | tr -d \'\")

    if [ -z "$SELECTED_FILE_PATH" ]; then
        echo -e "${RED}[ERROR] No path entered.${NC}"
        return 1
    fi

    if [ ! -f "$SELECTED_FILE_PATH" ]; then
         echo -e "${RED}[ERROR] File not found: $SELECTED_FILE_PATH${NC}"
         return 1
    fi
    
    # 파일 확장자 저장
    FILE_EXT="${SELECTED_FILE_PATH##*.}"
    
    if [[ "$FILE_EXT" != "apk" && "$FILE_EXT" != "apkm" ]]; then
         echo -e "${RED}[ERROR] The selected file is not an .apk or .apkm file.${NC}"
         return 1
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
            rm -rf "$TEMP_MERGE_DIR"
            return 1
        fi

        echo -e "${BLUE}[INFO] Merging with APKEditor... (this may take a moment)${NC}"
        java -jar "$EDITOR_JAR" m -i "$TEMP_MERGE_DIR" -o "$MERGED_APK_PATH"
        
        if [ ! -f "$MERGED_APK_PATH" ]; then
            echo -e "${RED}[ERROR] APKEditor merge failed.${NC}"
            rm -rf "$TEMP_MERGE_DIR"
            return 1
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

# --- 5. 패치 스크립트 실행 ---
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

# --- 6. 최종 파일 이동 및 정리 ---
move_and_cleanup() {
    echo -e "\n${BLUE}[INFO] Moving patched file to SD Card root...${NC}"
    
    local PATCHED_FILE
    PATCHED_FILE=$(find "$PATCH_SCRIPT_DIR/out" -type f -name "*.apk" -print0 | xargs -0 ls -t | head -n 1)

    if [ -z "$PATCHED_FILE" ]; then
        echo -e "${RED}[ERROR] Patched file not found in 'out' directory.${NC}"
        return 1
    fi
    
    local FINAL_FILENAME=$(basename "$PATCHED_FILE")
    mv "$PATCHED_FILE" "$FINAL_OUTPUT_DIR/$FINAL_FILENAME"
    echo -e "${GREEN}[SUCCESS] File moved to $FINAL_OUTPUT_DIR/$FINAL_FILENAME${NC}"
    
    rm -f "$MERGED_APK_PATH"
    am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE -d "file://$FINAL_OUTPUT_DIR/$FINAL_FILENAME"
}


# --- 7. 메인 스크립트 실행 ---
main() {
    clear
    echo -e "${GREEN}=== Smart File Merge & Patch Script ===${NC}"
    
    # 1. 의존성 확인
    check_dependencies
    
    # 2. 파일 경로 입력
    if ! get_file_input; then
        echo -e "${YELLOW}[INFO] Operation cancelled.${NC}"
        exit 0
    fi
    
    # 3. 파일 준비 (병합 또는 복사)
    if ! prepare_file; then
        exit 1
    fi
    
    # 4. 패치 실행
    if ! run_patch; then
        exit 1
    fi
    
    # 5. 파일 이동 및 정리
    if ! move_and_cleanup; then
        exit 1
    fi
    
    echo -e "\n${GREEN}========= ALL TASKS COMPLETE =========${NC}"
    echo -e "최종 파일이 Sdcard 최상위 폴더($FINAL_OUTPUT_DIR)에 저장되었습니다."
    echo -e "${GREEN}======================================${NC}"
}

# 스크립트 실행
main
