#!/bin/bash
#
# APKM 파일 수동 선택 + 자동 병합 + 자동 패치 스크립트
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
BASE_DIR="/storage/emulated/0/Download" # APKEditor 저장 위치 및 파일 탐색 시작 위치
FINAL_OUTPUT_DIR="/storage/emulated/0" # 최종 파일 출력 위치
PATCH_SCRIPT_DIR="$HOME/revanced-build-script"
MERGED_APK_PATH="$HOME/Downloads/KakaoTalk.apk" # build.py가 읽을 파일 위치

# 도구 경로
EDITOR_JAR="$BASE_DIR/APKEditor-1.4.5.jar"
TEMP_MERGE_DIR="$BASE_DIR/temp_merge_dir"

# Termux UI 도구
DIALOG=(dialog --keep-tite --no-shadow --no-collapse --visit-items --ok-label "선택" --cancel-label "취소")

# --- 2. 도구 확인 함수 ---
check_dependencies() {
    echo -e "${BLUE}[INFO] Checking dependencies...${NC}"
    local MISSING=0
    # 스크래핑 도구(curl, pup, jq) 완전 제외.
    # 파일 선택(dialog), 병합(unzip, java, wget), 패치(python, git)만 확인.
    for cmd in dialog wget unzip java python git; do
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

# --- 3. 파일 수동 선택 ---
get_file_input() {
    echo -e "${YELLOW}[INFO] Please select the .apkm file you downloaded.${NC}"
    
    if ! SELECTED_APKM_PATH=$(
        "${DIALOG[@]}" \
            --title "| .apkm 파일 선택 |" \
            --fselect "$BASE_DIR/" 20 70 \
            2>&1 > /dev/tty
    ); then
        return 1 # '취소' 선택
    fi

    if [ -z "$SELECTED_APKM_PATH" ]; then
        echo -e "${RED}[ERROR] No file selected.${NC}"
        return 1
    fi
    
    # 파일이 .apkm이 맞는지 확인
    if [[ "${SELECTED_APKM_PATH##*.}" != "apkm" ]]; then
         echo -e "${RED}[ERROR] The selected file is not an .apkm file.${NC}"
         return 1
    fi
    
    echo -e "${GREEN}[SUCCESS] Selected file: $SELECTED_APKM_PATH${NC}"
}

# --- 4. 선택된 파일 병합 ---
merge_file() {
    echo -e "\n${BLUE}[INFO] Repackaging APKM file... (-> $MERGED_APK_PATH)${NC}"
    rm -rf "$TEMP_MERGE_DIR" && mkdir -p "$TEMP_MERGE_DIR"
    
    # "하나도 놓치지 말고" 요청에 따라 모든 파일을 압축 해제
    echo -e "${BLUE}[INFO] Extracting all files from .apkm...${NC}"
    unzip -qqo "$SELECTED_APKM_PATH" -d "$TEMP_MERGE_DIR" 2> /dev/null

    if [ ! -f "$TEMP_MERGE_DIR/base.apk" ]; then
        echo -e "${RED}[ERROR] base.apk not found. Is the selected file a valid .apkm?${NC}"
        rm -rf "$TEMP_MERGE_DIR"
        return 1
    fi

    echo -e "${BLUE}[INFO] Merging with APKEditor... (this may take a moment)${NC}"
    rm -f "$MERGED_APK_PATH"
    java -jar "$EDITOR_JAR" m -i "$TEMP_MERGE_DIR" -o "$MERGED_APK_PATH"
    
    if [ ! -f "$MERGED_APK_PATH" ]; then
        echo -e "${RED}[ERROR] APKEditor merge failed.${NC}"
        rm -rf "$TEMP_MERGE_DIR"
        return 1
    fi
    
    echo -e "${GREEN}[SUCCESS] Merge complete: $MERGED_APK_PATH${NC}"
    
    # 임시 병합 폴더 정리 (원본 .apkm 파일은 삭제하지 않음)
    rm -rf "$TEMP_MERGE_DIR"
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
    
    # 패치 스크립트의 'out' 폴더에서 가장 최근에 생성된 .apk 파일을 찾음
    local PATCHED_FILE
    PATCHED_FILE=$(find "$PATCH_SCRIPT_DIR/out" -type f -name "*.apk" -print0 | xargs -0 ls -t | head -n 1)

    if [ -z "$PATCHED_FILE" ]; then
        echo -e "${RED}[ERROR] Patched file not found in 'out' directory.${NC}"
        return 1
    fi
    
    local FINAL_FILENAME=$(basename "$PATCHED_FILE")
    
    # sdcard 최상위로 이동
    mv "$PATCHED_FILE" "$FINAL_OUTPUT_DIR/$FINAL_FILENAME"
    
    echo -e "${GREEN}[SUCCESS] File moved to $FINAL_OUTPUT_DIR/$FINAL_FILENAME${NC}"
    
    # 원본 병합 파일 삭제
    rm -f "$MERGED_APK_PATH"
    
    # 미디어 스캔
    am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE -d "file://$FINAL_OUTPUT_DIR/$FINAL_FILENAME"
}


# --- 7. 메인 스크립트 실행 ---
main() {
    clear
    echo -e "${GREEN}=== Manual File Merge & Patch Script ===${NC}"
    
    # 1. 의존성 확인
    check_dependencies
    
    # 2. 파일 선택
    if ! get_file_input; then
        echo -e "${YELLOW}[INFO] Operation cancelled.${NC}"
        exit 0
    fi
    
    # 3. 병합
    if ! merge_file; then
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
