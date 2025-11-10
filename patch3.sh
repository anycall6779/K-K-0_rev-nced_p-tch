#!/bin/bash
#
# EXPERIMENTAL XAPK Repacker + Patcher for DCInside (AmpleReVanced Edition)
# This script attempts to merge all split APKs into a single base APK.
#
# !!! THIS IS HIGHLY LIKELY TO FAIL !!!
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
WORK_DIR="$HOME/xapk_repack_workdir" # 임시 작업 폴더

# --- Tool Paths ---
APKTOOL_JAR="$BASE_DIR/apktool_2.9.3.jar"
SIGNER_JAR="$BASE_DIR/uber-apk-signer-1.3.0.jar"

# --- Output Paths ---
# 재조립(Repack) 스크립트는 이 경로의 파일을 생성합니다.
REPACKED_APK_PATH="$HOME/Downloads/DCInside_Repacked.apk"
# 패치 스크립트가 이 파일을 입력으로 사용합니다.
FINAL_INPUT_APK_PATH="$HOME/Downloads/DCInside_Repacked-signed.apk" 

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
    
    # Apktool 다운로드
    if [ ! -f "$APKTOOL_JAR" ]; then
        print_warn "Apktool (분해/재조립 도구) 다운로드 중..."
        wget --quiet --show-progress -O "$APKTOOL_JAR" \
            "https://bitbucket.org/iBotPeaches/apktool/downloads/apktool_2.9.3.jar" || {
            print_error "Apktool 다운로드 실패"; MISSING=1; }
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
    echo -e "${GREEN} (주의: .apk가 아닌 .xapk 선택)${NC}"
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

# --- 3. Repack XAPK (The "Magic" Part) ---
repack_xapk() {
    print_info "실험적인 XAPK 재조립(Repack)을 시작합니다..."
    
    # 0. 이전 작업 폴더/파일 삭제
    rm -rf "$WORK_DIR" "$REPACKED_APK_PATH" "$FINAL_INPUT_APK_PATH"
    mkdir -p "$WORK_DIR"
    
    local EXTRACT_DIR="$WORK_DIR/1_extracted"
    local BASE_DECOMPILE_DIR="$WORK_DIR/2_base_decompiled"
    local SPLIT_DECOMPILE_DIR="$WORK_DIR/3_split_decompiled"
    mkdir -p "$EXTRACT_DIR" "$BASE_DECOMPILE_DIR" "$SPLIT_DECOMPILE_DIR"

    # 1. XAPK 압축 해제
    print_info "[1/5] XAPK 압축 해제 중..."
    unzip -q "$SELECTED_XAPK_FILE" -d "$EXTRACT_DIR" || { print_error "XAPK 압축 해제 실패"; return 1; }

    # 2. Base.apk 찾아서 디컴파일
    local BASE_APK=$(find "$EXTRACT_DIR" -name "*.apk" -not -name "split_config.*.apk" | head -n 1)
    if [[ -z "$BASE_APK" ]]; then
        print_error "base.apk 파일을 찾지 못했습니다."
        return 1
    fi
    print_info "[2/5] Base APK 디컴파일 중... (시간이 매우 오래 걸림)"
    java -jar "$APKTOOL_JAR" d "$BASE_APK" -o "$BASE_DECOMPILE_DIR" -f &> /dev/null || { print_error "Base APK 디컴파일 실패"; return 1; }

    # 3. 모든 Split APK를 찾아서 디컴파일하고 병합
    print_info "[3/5] Split APK 병합 중..."
    local i=0
    for SPLIT_APK in $(find "$EXTRACT_DIR" -name "split_config.*.apk"); do
        i=$((i+1))
        local TEMP_DECOMPILE_SPLIT="$SPLIT_DECOMPILE_DIR/split_$i"
        print_info "  -> 조각 $i 디컴파일: $(basename "$SPLIT_APK")"
        
        # 3a. 스플릿 디컴파일
        java -jar "$APKTOOL_JAR" d "$SPLIT_APK" -o "$TEMP_DECOMPILE_SPLIT" -f &> /dev/null || { print_warn "조각 $i 디컴파일 실패, 건너뜁니다."; continue; }
        
        # 3b. 리소스 및 라이브러리 강제 복사/병합
        # (이 부분이 가장 위험하고 오류가 많이 나는 지점입니다)
        print_info "  -> 조각 $i 리소스 병합..."
        cp -r "$TEMP_DECOMPILE_SPLIT/res/"* "$BASE_DECOMPILE_DIR/res/" 2>/dev/null || true
        if [ -d "$TEMP_DECOMPILE_SPLIT/lib" ]; then
            cp -r "$TEMP_DECOMPILE_SPLIT/lib/"* "$BASE_DECOMPILE_DIR/lib/" 2>/dev/null || true
        fi
    done
    print_success "총 $i 개의 조각 병합 시도 완료."

    # 4. 하나의 APK로 리컴파일
    print_info "[4/5] 모든 조각을 하나의 APK로 재조립(리컴파일) 중... (매우 오래 걸림)"
    java -jar "$APKTOOL_JAR" b "$BASE_DECOMPILE_DIR" -o "$REPACKED_APK_PATH" -f || { print_error "리컴파일 실패! 호환되지 않는 리소스가 충돌했습니다."; return 1; }
    print_success "재조립 성공: $(basename "$REPACKED_APK_PATH")"

    # 5. APK 서명
    print_info "[5/5] 재조립된 APK 서명 중..."
    java -jar "$SIGNER_JAR" -a "$REPACKED_APK_PATH" || { print_error "서명 실패!"; return 1; }
    
    if [ ! -f "$FINAL_INPUT_APK_PATH" ]; then
        print_error "서명된 파일($FINAL_INPUT_APK_PATH)을 찾을 수 없습니다."
        return 1
    fi

    # 임시 폴더 삭제
    rm -rf "$WORK_DIR"
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
    
    # 재조립된 APK($FINAL_INPUT_APK_PATH)를 입력으로 사용
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
    echo -e "${RED}  디시 XAPK 재조립 및 패치 (실험용) ${NC}"
    echo -e "${RED}======================================${NC}"
    echo -e "${YELLOW}경고: 이 스크립트는 실패할 확률이 매우 높습니다.${NC}"
    echo ""
    
    check_dependencies || exit 1
    get_xapk_file || exit 0
    repack_xapk || { print_error "치명적 오류: XAPK 재조립에 실패했습니다."; exit 1; }
    run_patch || { print_error "치명적 오류: APK 패치에 실패했습니다."; exit 1; }
    
    echo ""
    print_success "모든 작업이 (기적적으로) 성공했습니다."
}

main
