#!/bin/bash
#
# EXPERIMENTAL XAPK Repacker (via Python) + Patcher for DCInside
# This script uses xapktoapk.py instead of manual apktool logic.
#
# !!! THIS IS STILL HIGHLY LIKELY TO FAIL !!!
#
set -e

# --- Color Codes ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# --- Configuration ---
PKG_NAME="com.dcinside.app.android"
BASE_DIR="/storage/emulated/0/Download"
PATCH_SCRIPT_DIR="$HOME/revanced-build-script-ample"
WORK_DIR="$HOME/xapk_py_workdir" # 임시 작업 폴더

# --- Tool Paths ---
# .py 스크립트와 서명 도구만 다운로드합니다. (apktool은 .py가 알아서 할 것으로 가정)
PYTHON_SCRIPT_URL="https://raw.githubusercontent.com/LuigiVampa92/xapk-to-apk/refs/heads/development/xapktoapk.py"
PYTHON_SCRIPT_PATH="$WORK_DIR/xapktoapk.py"
SIGNER_JAR="$BASE_DIR/uber-apk-signer-1.3.0.jar"

# --- Output Paths ---
# .py 스크립트가 생성할 파일 (서명 전)
REPACKED_APK_PATH="$HOME/Downloads/DCInside_Repacked_py.apk"
# 서명 후 패치 스크립트에 전달될 최종 파일
FINAL_INPUT_APK_PATH="$HOME/Downloads/DCInside_Repacked_py-signed.apk" 

# --- Helper Functions ---
print_info() { echo -e "${BLUE}[INFO] $1${NC}"; }
print_warn() { echo -e "${YELLOW}[WARN] $1${NC}"; }
print_error() { echo -e "${RED}[ERROR] $1${NC}"; }
print_success() { echo -e "${GREEN}[SUCCESS] $1${NC}"; }

# --- 1. Dependency Check ---
check_dependencies() {
    print_info "필수 도구 확인 중..."
    local MISSING=0
    
    # 기본 도구
    for cmd in curl wget unzip java python git; do
        if ! command -v $cmd &> /dev/null; then
            print_error "'$cmd' 가 없습니다. (pkg install $cmd)"
            MISSING=1
        fi
    done
    
    # AmpleReVanced 스크립트
    if [ ! -d "$PATCH_SCRIPT_DIR" ]; then
        print_warn "AmpleReVanced 빌드 스크립트 다운로드 중..."
        git clone https://github.com/AmpleReVanced/revanced-build-script.git "$PATCH_SCRIPT_DIR" || {
            print_error "빌드 스크립트 다운로드 실패"; MISSING=1; }
    else
        print_info "빌드 스크립트 업데이트 확인 중..."
        git -C "$PATCH_SCRIPT_DIR" pull || print_warn "업데이트 실패. 기존 버전으로 진행."
    fi
    
    # xapktoapk.py 다운로드
    mkdir -p "$WORK_DIR"
    if [ ! -f "$PYTHON_SCRIPT_PATH" ]; then
        print_warn "xapktoapk.py (Python 스크립트) 다운로드 중..."
        wget --quiet --show-progress -O "$PYTHON_SCRIPT_PATH" "$PYTHON_SCRIPT_URL" || {
            print_error "xapktoapk.py 다운로드 실패"; MISSING=1; }
    fi

    # uber-apk-signer (서명 도구) 다운로드
    if [ ! -f "$SIGNER_JAR" ]; then
        print_warn "uber-apk-signer (서명 도구) 다운로드 중..."
        wget --quiet --show-progress -O "$SIGNER_JAR" \
            "https://github.com/patrickfav/uber-apk-signer/releases/download/v1.3.0/uber-apk-signer-1.3.0.jar" || {
            print_error "uber-apk-signer 다운로드 실패"; MISSING=1; }
    fi
    
    [ $MISSING -eq 1 ] && exit 1
    mkdir -p "$HOME/Downloads"
    print_success "모든 준비 완료"
}

# --- 2. Get XAPK File Path ---
get_xapk_file() {
    echo ""
    echo -e "${YELLOW}==================================${NC}"
    echo -e "${GREEN}   디시인사이드 XAPK 파일 선택   ${NC}"
    echo -e "${YELLOW}==================================${NC}"
    echo ""
    
    # (이전 스크립트와 동일한 코드를 사용)
    local XAPK_FILES=()
    while IFS= read -r -d '' file; do
        XAPK_FILES+=("$(basename "$file")")
    done < <(find "$BASE_DIR" -maxdepth 1 -name "*.xapk" -print0 2>/dev/null)
    
    if [ ${#XAPK_FILES[@]} -gt 0 ]; then
        echo -e "${BLUE}다운로드 폴더에서 발견된 XAPK 파일:${NC}"
        for i in "${!XAPK_FILES[@]}"; do
            echo -e "  ${GREEN}$((i+1)).${NC} ${XAPK_FILES[$i]}"
        done
        echo ""
        echo -e "${YELLOW}번호를 입력하거나, 직접 경로를 입력하세요:${NC}"
        read -r -p "> " selection
        
        if [[ "$selection" =~ ^[0-9]+$ ]] && [ "$selection" -ge 1 ] && [ "$selection" -le ${#XAPK_FILES[@]} ]; then
            SELECTED_XAPK_FILE="$BASE_DIR/${XAPK_FILES[$((selection-1))]}"
            print_success "선택됨: ${XAPK_FILES[$((selection-1))]}"
            return 0
        fi
        
        if [ -n "$selection" ]; then
            SELECTED_XAPK_FILE="$selection"
        fi
    else
        echo -e "${BLUE}XAPK 파일의 전체 경로를 입력하세요:${NC}"
        read -r -p "> " SELECTED_XAPK_FILE
    fi
    
    if [ -z "$SELECTED_XAPK_FILE" ] || [ ! -f "$SELECTED_XAPK_FILE" ]; then
        print_error "유효하지 않은 파일 경로입니다."
        return 1
    fi
    return 0
}

# --- 3. Repack XAPK (Using Python script) ---
repack_with_python() {
    print_info "Python 스크립트(xapktoapk.py)로 재조립을 시작합니다..."
    
    # 0. 이전 작업 파일 삭제
    rm -f "$REPACKED_APK_PATH" "$FINAL_INPUT_APK_PATH"
    
    # 1. Python 스크립트 실행
    print_info "[1/2] xapktoapk.py 실행 중... (시간이 매우 오래 걸림)"
    print_warn "만약 'ModuleNotFoundError'가 발생하면, 'pip install [모듈명]'으로 직접 설치해야 합니다."
    
    python "$PYTHON_SCRIPT_PATH" "$SELECTED_XAPK_FILE" -o "$REPACKED_APK_PATH" || {
        print_error "Python 스크립트 실행 실패!"
        print_error "patch3.sh와 동일하게 'Apktool' 재조립(리컴파일) 단계에서 충돌했을 것입니다."
        return 1
    }

    if [ ! -f "$REPACKED_APK_PATH" ]; then
        print_error "재조립된 APK 파일($REPACKED_APK_PATH)이 생성되지 않았습니다."
        return 1
    fi
    print_success "Python 스크립트가 재조립을 완료했습니다."

    # 2. APK 서명
    print_info "[2/2] 재조립된 APK 서명 중..."
    java -jar "$SIGNER_JAR" -a "$REPACKED_APK_PATH" || { print_error "서명 실패!"; return 1; }
    
    if [ ! -f "$FINAL_INPUT_APK_PATH" ]; then
        print_error "서명된 파일($FINAL_INPUT_APK_PATH)을 찾을 수 없습니다."
        return 1
    fi

    rm -rf "$WORK_DIR" # xapktoapk.py만 삭제 (임시 폴더가 크지 않으므로)
    print_success "XAPK 재조립 및 서명 완료!"
    return 0
}

# --- 4. Run Patch (AmpleReVanced) ---
run_patch() {
    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}    AmpleReVanced 패치 시작...${NC}"
    echo -e "${GREEN}========================================${NC}"
    
    cd "$PATCH_SCRIPT_DIR"
    rm -rf output out
    
    print_info "build.py 실행 중... (입력 파일: $FINAL_INPUT_APK_PATH)"
    
    # 재조립+서명된 APK($FINAL_INPUT_APK_PATH)를 입력으로 사용
    python build.py \
        --apk "$FINAL_INPUT_APK_PATH" \
        --package "$PKG_NAME" \
        --include-universal \
        --run || {
        print_error "패치 과정 중 오류가 발생했습니다."; return 1; }
    
    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}    패치 프로세스 완료!${NC}"
    echo -e "${GREEN}========================================${NC}"
    
    # 결과물 확인 및 이동
    local OUTPUT_APK=""
    if [ -f "output/patched.apk" ]; then
        OUTPUT_APK="output/patched.apk"
    elif [ -f "out/patched.apk" ]; then
        OUTPUT_APK="out/patched.apk"
    else
        OUTPUT_APK=$(find output out -name "*.apk" -type f 2>/dev/null | head -n 1)
    fi

    if [ -n "$OUTPUT_APK" ] && [ -f "$OUTPUT_APK" ]; then
        print_info "결과물을 다운로드 폴더로 이동합니다..."
        mv -f "$OUTPUT_APK" "/storage/emulated/0/Download/DCInside_ReVanced.apk"
        print_success "저장 완료: /storage/emulated/0/Download/DCInside_ReVanced.apk"
    else
        print_error "결과물 파일을 찾을 수 없습니다."
        print_warn "다음 폴더를 직접 확인해보세요: $PATCH_SCRIPT_DIR/output 또는 $PATCH_SCRIPT_DIR/out"
    fi
}

# --- Main Execution Flow ---
main() {
    clear
    echo -e "${RED}======================================${NC}"
    echo -e "${RED}  디시 XAPK 재조립(Python) + 패치   ${NC}"
    echo -e "${RED}======================================${NC}"
    echo -e "${YELLOW}경고: 이 스크립트도 동일한 이유로 실패할 것입니다.${NC}"
    echo ""
    
    check_dependencies || exit 1
    get_xapk_file || exit 0
    repack_with_python || { print_error "치명적 오류: XAPK 재조립에 실패했습니다."; exit 1; }
    run_patch || { print_error "치명적 오류: APK 패치에 실패했습니다."; exit 1; }
    
    echo ""
    print_success "모든 작업이 (기적적으로) 성공했습니다."
}

main
