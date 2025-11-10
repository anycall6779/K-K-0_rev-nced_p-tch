#!/bin/bash
#
# Simplified APKM Merger + Patcher for KakaoTalk (AmpleReVanced Edition)
# (Improved output finding logic)
#
set -e

# --- Color Codes ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# --- Configuration ---
PKG_NAME="com.kakao.talk"
BASE_DIR="/storage/emulated/0/Download"
PATCH_SCRIPT_DIR="$HOME/revanced-build-script-ample"
MERGED_APK_PATH="$HOME/Downloads/KakaoTalk_Merged.apk" # 병합된 파일 이름 변경
EDITOR_JAR="$BASE_DIR/APKEditor-1.4.5.jar"

# --- Helper Functions ---
print_info() { echo -e "${BLUE}[INFO] $1${NC}"; }
print_warn() { echo -e "${YELLOW}[WARN] $1${NC}"; }
print_error() { echo -e "${RED}[ERROR] $1${NC}"; }
print_success() { echo -e "${GREEN}[SUCCESS] $1${NC}"; }

# --- 1. Dependency Check ---
check_dependencies() {
    print_info "필수 도구 확인 중..."
    local MISSING=0
    
    for cmd in curl wget unzip java python git; do
        if ! command -v $cmd &> /dev/null; then
            print_error "'$cmd' 가 없습니다. 설치 명령어: pkg install $cmd"
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
    
    if [ ! -f "$EDITOR_JAR" ]; then
        print_warn "APKEditor 다운로드 중..."
        wget --quiet --show-progress -O "$EDITOR_JAR" \
            "https://github.com/REAndroid/APKEditor/releases/download/V1.4.5/APKEditor-1.4.5.jar" || {
            print_error "APKEditor 다운로드 실패"; MISSING=1; }
    fi
    
    [ $MISSING -eq 1 ] && exit 1
    mkdir -p "$HOME/Downloads"
    print_success "모든 준비 완료"
}

# --- 2. Get APKM File Path ---
get_apkm_file() {
    echo ""
    echo -e "${YELLOW}==================================${NC}"
    echo -e "${GREEN}   카카오톡 APKM 파일 선택   ${NC}"
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
            print_success "선택됨: ${APKM_FILES[$((selection-1))]}"
            return 0
        fi
        
        if [ -n "$selection" ]; then
            APKM_FILE="$selection"
        fi
    else
        echo -e "${BLUE}APKM 파일의 전체 경로를 입력하세요:${NC}"
        print_warn "(예: /storage/emulated/0/Download/com.kakao.talk.apkm)"
        read -r -p "> " APKM_FILE
    fi
    
    if [ -z "$APKM_FILE" ] || [ ! -f "$APKM_FILE" ]; then
        print_error "유효하지 않은 파일 경로입니다."
        return 1
    fi
    return 0
}

# --- 3. Merge APKM ---
merge_apkm() {
    echo ""
    print_info "APKM 파일 병합 시작..."
    local TEMP_DIR="$BASE_DIR/kakao_temp_merge"
    rm -rf "$TEMP_DIR" && mkdir -p "$TEMP_DIR"
    
    unzip -qqo "$APKM_FILE" -d "$TEMP_DIR" 2>/dev/null || {
        print_error "압축 해제 실패"; rm -rf "$TEMP_DIR"; return 1; }
    
    if [ ! -f "$TEMP_DIR/base.apk" ]; then
        print_error "base.apk 없음"; rm -rf "$TEMP_DIR"; return 1; }
    
    print_info "APKEditor로 병합 중... (잠시만 기다려주세요)"
    rm -f "$MERGED_APK_PATH"
    java -jar "$EDITOR_JAR" m -i "$TEMP_DIR" -o "$MERGED_APK_PATH" &> /dev/null || {
        print_error "병합 실패"; rm -rf "$TEMP_DIR"; return 1; }
    
    if [ ! -f "$MERGED_APK_PATH" ]; then
        print_error "병합된 파일 생성 실패"; rm -rf "$TEMP_DIR"; return 1; }
    
    print_success "병합 완료: $(basename "$MERGED_APK_PATH")"
    rm -rf "$TEMP_DIR"
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
    
    # python3 대신 python 사용
    python build.py \
        --apk "$MERGED_APK_PATH" \
        --package "$PKG_NAME" \
        --include-universal \
        --run || {
        print_error "패치 과정 중 오류 발생"; return 1; }
    
    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}    패치 프로세스 완료!${NC}"
    echo -e "${GREEN}========================================${NC}"
    
    # --- [적용된 기술] ---
    # 결과물 확인 및 이동 (output 폴더와 out 폴더 모두 확인)
    local OUTPUT_APK=""
    if [ -f "output/patched.apk" ]; then
        OUTPUT_APK="output/patched.apk"
    elif [ -f "out/patched.apk" ]; then
        OUTPUT_APK="out/patched.apk"
    else
        # 이름이 다를 경우를 대비해 검색
        OUTPUT_APK=$(find output out -name "*.apk" -type f 2>/dev/null | head -n 1)
    fi

    if [ -n "$OUTPUT_APK" ] && [ -f "$OUTPUT_APK" ]; then
        print_info "결과물을 다운로드 폴더로 이동합니다..."
        # 파일명 고정 (KakaoTalk_ReVanced.apk)
        mv -f "$OUTPUT_APK" "/storage/emulated/0/Download/KakaoTalk_ReVanced.apk"
        print_success "저장 완료: /storage/emulated/0/Download/KakaoTalk_ReVanced.apk"
    else
        print_error "결과물 파일을 찾을 수 없습니다."
        print_warn "다음 폴더를 직접 확인해보세요: $PATCH_SCRIPT_DIR/output 또는 $PATCH_SCRIPT_DIR/out"
    fi
    # --- [여기까지 적용] ---
}

# --- Main ---
main() {
    clear
    echo -e "${GREEN}======================================${NC}"
    echo -e "${GREEN}  카카오톡 APKM 병합 & 패치 (개선판)${NC}"
    echo -e "${GREEN}======================================${NC}"
    echo ""
    
    check_dependencies || exit 1
    get_apkm_file || exit 0
    merge_apkm || exit 1
    run_patch || exit 1
    
    echo ""
    print_success "모든 작업이 끝났습니다."
}

main
