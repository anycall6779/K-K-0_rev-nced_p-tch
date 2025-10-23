#!/bin/bash
#
# APKM 파일 수동 선택 + 자동 병합 + 자동 패치 스크립트
# (Revancify의 main.sh 스타일 메뉴 인터페이스 적용)
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
DIALOG=(dialog --keep-tite --no-shadow --no-collapse --visit-items --ok-label "선택" --cancel-label "뒤로")

# --- 2. 헬퍼 함수 (UI 및 알림) ---

# UI 개선을 위한 공지 함수
notify() {
    "${DIALOG[@]}" --title "$1" --msgbox "$2" 10 70
}

# 작업 완료 후 메뉴로 돌아가기 전 대기
pause() {
    "${DIALOG[@]}" --pause "작업 완료. 메뉴로 돌아가려면 Enter를 누르세요..." 8 70
}

# --- 3. 핵심 기능 함수 ---

# 최초 1회 설치 함수
install_prerequisites() {
    ("${DIALOG[@]}" --title "| 최초 환경 설정 |" --infobox "필수 패키지를 설치합니다...\n(git, openjdk-17, python, unzip, wget, dialog)" 10 70)
    pkg install git openjdk-17 python unzip wget dialog -y || {
        notify "오류" "패키지 설치에 실패했습니다."
        return 1
    }
    
    ("${DIALOG[@]}" --title "| 최초 환경 설정 |" --infobox "revanced-build-script를 복제합니다..." 10 70)
    cd "$HOME"
    git clone https://git.naijun.dev/ReVanced/revanced-build-script.git || {
        notify "오류" "revanced-build-script 복제에 실패했습니다. 이미 폴더가 있는지 확인하세요."
        return 1
    }

    ("${DIALOG[@]}" --title "| 최초 환경 설정 |" --infobox "Python 요구사항을 설치합니다..." 10 70)
    cd "$PATCH_SCRIPT_DIR"
    pip install -r requirements.txt || {
        notify "오류" "Python 요구사항 설치에 실패했습니다."
        return 1
    }
    
    ("${DIALOG[@]}" --title "| 최초 환경 설정 |" --infobox "APKEditor를 다운로드합니다..." 10 70)
    cd "$BASE_DIR"
    wget -q --show-progress --progress=bar:force:noscroll -O "$EDITOR_JAR" "https://github.com/REAndroid/APKEditor/releases/download/V1.4.5/APKEditor-1.4.5.jar" || {
         notify "오류" "APKEditor 다운로드에 실패했습니다."
        return 1
    }
    
    notify "성공" "모든 환경 설정이 완료되었습니다."
}

# 도구 확인 함수
check_dependencies() {
    local MISSING_TOOLS=""
    for cmd in dialog wget unzip java python git; do
        command -v $cmd &> /dev/null || MISSING_TOOLS+=" $cmd"
    done
    
    if [ -n "$MISSING_TOOLS" ]; then
        return 1
    fi
    if [ ! -d "$PATCH_SCRIPT_DIR" ] || [ ! -f "$EDITOR_JAR" ]; then
        return 1
    fi
    return 0
}

# --- [패치 워크플로우 함수] ---

get_file_input() {
    if ! SELECTED_APKM_PATH=$(
        "${DIALOG[@]}" \
            --title "| 1/4: .apkm 파일 선택 |" \
            --fselect "$BASE_DIR/" 20 70 \
            2>&1 > /dev/tty
    ); then
        return 1 # '취소' 선택
    fi

    if [ -z "$SELECTED_APKM_PATH" ] || [[ "${SELECTED_APKM_PATH##*.}" != "apkm" ]]; then
         notify "오류" "올바른 .apkm 파일을 선택하지 않았습니다."
         return 1
    fi
    echo -e "${GREEN}[INFO] Selected file: $SELECTED_APKM_PATH${NC}"
}

merge_file() {
    (
    echo 10; echo "XXX"; echo "APKM 파일 압축을 해제합니다...";
    rm -rf "$TEMP_MERGE_DIR" && mkdir -p "$TEMP_MERGE_DIR"
    unzip -qqo "$SELECTED_APKM_PATH" -d "$TEMP_MERGE_DIR" 2> /dev/null
    
    if [ ! -f "$TEMP_MERGE_DIR/base.apk" ]; then
        echo "XXX";
        notify "오류" "base.apk를 찾을 수 없습니다. 유효한 .apkm 파일이 아닙니다."
        return 1
    fi
    
    echo 50; echo "XXX"; echo "APKEditor로 파일을 병합합니다... (시간 소요)";
    rm -f "$MERGED_APK_PATH"
    java -jar "$EDITOR_JAR" m -i "$TEMP_MERGE_DIR" -o "$MERGED_APK_PATH" &> /dev/null
    
    if [ ! -f "$MERGED_APK_PATH" ]; then
        echo "XXX";
        notify "오류" "APKEditor 병합에 실패했습니다."
        return 1
    fi
    
    echo 100; echo "XXX"; echo "병합 완료!";
    sleep 1
    ) | "${DIALOG[@]}" --title "| 2/4: APK 병합 중 |" --gauge "파일을 병합하고 있습니다..." 10 70 0
    
    rm -rf "$TEMP_MERGE_DIR" # 임시 폴더 정리
}

run_patch() {
    clear
    echo -e "${GREEN}========= 3/4: Running Patch Script =========${NC}"
    echo "패치 선택 화면으로 진입합니다..."
    echo "Space 바로 선택, Enter로 다음 단계로 이동하세요."
    sleep 2
    
    cd "$PATCH_SCRIPT_DIR"
    
    ./build.py \
        --apk "$MERGED_APK_PATH" \
        --package "$PKG_NAME" \
        --include-universal \
        --run
    
    local EXIT_CODE=$?
    if [ $EXIT_CODE -ne 0 ]; then
        notify "오류" "패치 스크립트 실행 중 오류가 발생했습니다."
        return 1
    fi
}

move_and_cleanup() {
    ("${DIALOG[@]}" --title "| 4/4: 파일 정리 |" --infobox "패치된 파일을 SD카드로 이동 중..." 10 70)
    
    local PATCHED_FILE
    PATCHED_FILE=$(find "$PATCH_SCRIPT_DIR/out" -type f -name "*.apk" -print0 | xargs -0 ls -t | head -n 1)

    if [ -z "$PATCHED_FILE" ]; then
        notify "오류" "패치된 파일(out/*.apk)을 찾을 수 없습니다."
        return 1
    fi
    
    local FINAL_FILENAME=$(basename "$PATCHED_FILE")
    mv "$PATCHED_FILE" "$FINAL_OUTPUT_DIR/$FINAL_FILENAME"
    
    echo -e "${GREEN}[SUCCESS] File moved to $FINAL_OUTPUT_DIR/$FINAL_FILENAME${NC}"
    rm -f "$MERGED_APK_PATH"
    
    # 미디어 스캔
    am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE -d "file://$FINAL_OUTPUT_DIR/$FINAL_FILENAME"
}

# --- [메인 워크플로우 실행기] ---
start_patch_process() {
    clear
    get_file_input && \
    merge_file && \
    run_patch && \
    move_and_cleanup
    
    if [ $? -eq 0 ]; then
        notify "작업 완료" "모든 작업이 성공적으로 완료되었습니다.\n최종 파일이 SD카드 최상위 폴더에 저장되었습니다."
    else
        notify "작업 중단" "작업 중 오류가 발생했거나 사용자가 취소했습니다."
    fi
    
    # Revancify처럼 메뉴로 돌아가기 전 대기
    pause
}


# --- 4. 메인 메뉴 (Revancify main.sh 스타일) ---
main_menu() {
    # 시작 시 의존성 확인
    if ! check_dependencies; then
        notify "환경 설정 필요" "필수 도구가 설치되지 않았습니다. '최초 환경 설정' 메뉴를 먼저 실행해 주세요."
    fi

    while true; do
        MAIN=$(
            "${DIALOG[@]}" \
                --title '| K-K-0 Patcher |' \
                --ok-label '실행' \
                --cancel-label '종료' \
                --menu "작업을 선택하세요:" -1 -1 0 \
                1 "패치 실행 (APKM 파일 선택)" \
                2 "최초 환경 설정 (도구 설치)" \
                2>&1 > /dev/tty
        ) || break # '종료' 선택 시 루프 탈출

        case "$MAIN" in
            1)
                start_patch_process
                ;;
            2)
                if "${DIALOG[@]}" --title "| 경고 |" --yesno "이미 설치된 경우 중복 실행될 수 있습니다. 계속하시겠습니까?" 8 70; then
                    clear
                    install_prerequisites
                else
                    notify "취소" "환경 설정을 취소했습니다."
                fi
                ;;
        esac
    done
}

# --- 스크립트 시작 ---
tput civis # 커서 숨기기
main_menu
tput cnorm # 커서 보이기
clear
