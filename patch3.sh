#!/bin/bash
#
# DCInside XAPK Extractor + Patcher (Final Version)
#
# 이 스크립트는 실패하는 '재조립' 대신, 'base.apk'만 '추출'하여
# 패치를 진행하는 유일하게 성공 가능한 방법입니다.
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
WORK_DIR="$HOME/xapk_extract_workdir" # 임시 추출 폴더

# --- Output Path ---
EXTRACTED_BASE_APK="$WORK_DIR/DCInside_Base.apk" # 추출된 APK가 저장될 경로

# --- Helper Functions ---
print_info() { echo -e "${BLUE}[INFO] $1${NC}"; }
print_warn() { echo -e "${YELLOW}[WARN] $1${NC}"; }
print_error() { echo -e "${RED}[ERROR] $1${NC}"; }
print_success() { echo -e "${GREEN}[SUCCESS] $1${NC}"; }

# --- 1. Dependency Check ---
check_dependencies() {
    print_info "필수 도구 확인 중..."
    local MISSING=0
    
    # (apktool, signer 등 실험용 도구 모두 제외)
    for cmd in curl wget unzip java python git; do
        if ! command -v $cmd &> /dev/null; then
            print_error "'$cmd' 가 없습니다. (pkg install $cmd)"
            MISSING=1
        fi
    done
    
    if [ ! -d "$PATCH_SCRIPT_DIR" ]; then
        print_warn "AmpleReVanced 빌드 스크립트 다운로드 중..."
        git clone https://github.com/AmpleReVanced/revanced-build-script.git "$PATCH_SCRIPT_DIR" || {
            print_error "빌드 스크립트 다운로드 실패"; MISSING=1; }
    else
        print_info "빌드 스크립트 업데이트 확인 중..."
        git -C "$PATCH_SCRIPT_DIR" pull || print_warn "업데이트 실패. 기존 버전으로 진행."
    fi
    
    [ $MISSING -eq 1 ] && exit 1
    print_success "모든 준비 완료"
}

# --- 2. Get XAPK File Path ---
get_xapk_file() {
    echo ""
    echo -e "${YELLOW}==================================${NC}"
    echo -e "${GREEN}   디시인사이드 XAPK 파일 선택   ${NC}"
    echo -e "${YELLOW}==================================${NC}"
    echo ""
    
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

# --- 3. Extract Base APK (핵심 기능) ---
extract_base_apk() {
    print_info "XAPK 파일에서 '본체 APK' 추출을 시작합니다..."
    
    rm -rf "$WORK_DIR"
    mkdir -p "$WORK_DIR"
    
    local EXTRACT_DIR="$WORK_DIR/extracted"
    mkdir -p "$EXTRACT_DIR"

    print_info "[1/2] XAPK 압축 해제 중..."
    unzip -q "$SELECTED_XAPK_FILE" -d "$EXTRACT_DIR" || { print_error "XAPK 압축 해제 실패"; return 1; }

    print_info "[2/2] 핵심(Base) APK 파일 검색 중..."
    # 님이 보여주신 파일 목록에 따라, 'config.'로 시작하지 않는 .apk 파일을 찾습니다.
    local BASE_APK=$(find "$EXTRACT_DIR" -name "*.apk" -not -name "config.*.apk" | head -n 1)
    
    if [[ -z "$BASE_APK" ]]; then
        # 만약 위 조건으로 못찾으면, 'split_config'도 제외해 봅니다.
        BASE_APK=$(find "$EXTRACT_DIR" -name "*.apk" -not -name "split_config.*.apk" | head -n 1)
    fi
    
    if [[ -z "$BASE_APK" ]]; then
        print_error "XAPK 파일 안에서 핵심 'base.apk' (com.dcinside.app.android.apk) 파일을 찾지 못했습니다."
        return 1
    fi
    
    cp "$BASE_APK" "$EXTRACTED_BASE_APK"
    rm -rf "$EXTRACT_DIR"
    
    print_success "핵심 APK 추출 완료: $(basename "$EXTRACTED_BASE_APK")"
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
    
    print_info "build.py 실행 중... (입력 파일: $EXTRACTED_BASE_APK)"
    
    # 추출된 APK($EXTRACTED_BASE_APK)를 입력으로 사용
    python build.py \
        --apk "$EXTRACTED_BASE_APK" \
        --package "$PKG_NAME" \
        --include-universal \
        --run || {
        print_error "패치 과정 중 오류가 발생했습니다."; return 1; }
    
    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}    패치 프로세스 완료!${NC}"
    echo -e "${GREEN}========================================${NC}"
    
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
        print_warn "다음 폴더를 직접 확인해보세요: $PATCH_SCRIPT_DIR/output"
    fi
}

# --- Main Execution Flow ---
main() {
    clear
    echo -e "${GREEN}======================================${NC}"
    echo -e "${GREEN}  디시 XAPK 추출 + 패치 (최종 버전) ${NC}"
    echo -e "${GREEN}======================================${NC}"
    echo ""
    
    check_dependencies || exit 1
    get_xapk_file || exit 0
    extract_base_apk || { print_error "치명적 오류: XAPK에서 Base APK를 추출하지 못했습니다."; exit 1; }
    run_patch || { print_error "치명적 오류: APK 패치에 실패했습니다."; exit 1; }
    
    rm -rf "$WORK_DIR"
    
    echo ""
    print_success "모든 작업이 성공적으로 끝났습니다."
}

main
