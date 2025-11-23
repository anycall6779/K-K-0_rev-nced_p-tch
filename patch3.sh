#!/bin/bash
#
# DCInside Patcher based on AmpleReVanced
# (Modified: Enforces Custom Keystore for Consistent Signing)
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

# [추가됨] 키스토어 설정
KEYSTORE_URL="https://github.com/anycall6779/K-K-0_rev-nced_p-tch/raw/refs/heads/main/my_kakao_key.keystore"
KEYSTORE_FILE="my_kakao_key.keystore"

# --- Helper Functions ---
print_info() { echo -e "${BLUE}[INFO] $1${NC}"; }
print_warn() { echo -e "${YELLOW}[WARN] $1${NC}"; }
print_error() { echo -e "${RED}[ERROR] $1${NC}"; }
print_success() { echo -e "${GREEN}[SUCCESS] $1${NC}"; }

# --- 1. Dependency Check ---
check_dependencies() {
    print_info "필수 도구 확인 중..."
    local MISSING=0
    
    # 기본 도구 (APKEditor 제외)
    for cmd in curl wget unzip java python git; do
        if ! command -v $cmd &> /dev/null; then
            print_error "'$cmd' 가 없습니다. 설치 명령어: pkg install $cmd"
            MISSING=1
        fi
    done
    
    # AmpleReVanced 스크립트 확인
    if [ ! -d "$PATCH_SCRIPT_DIR" ]; then
        print_warn "AmpleReVanced 빌드 스크립트 다운로드 중..."
        git clone https://github.com/AmpleReVanced/revanced-build-script.git "$PATCH_SCRIPT_DIR" || {
            print_error "빌드 스크립트 다운로드 실패"
            MISSING=1
        }
    else
        print_info "빌드 스크립트 업데이트 확인 중..."
        git -C "$PATCH_SCRIPT_DIR" pull || print_warn "업데이트 실패. 기존 버전으로 진행."
    fi
    
    [ $MISSING -eq 1 ] && exit 1
    mkdir -p "$HOME/Downloads"
    print_success "모든 준비 완료"
}

# --- 2. Get APK File Path ---
get_apk_file() {
    echo ""
    echo -e "${YELLOW}==================================${NC}"
    echo -e "${GREEN}   디시인사이드 APK 파일 선택   ${NC}"
    echo -e "${YELLOW}==================================${NC}"
    echo ""
    
    local APK_FILES=()
    # .apkm이 아닌 .apk 파일을 찾습니다.
    while IFS= read -r -d '' file; do
        APK_FILES+=("$(basename "$file")")
    done < <(find "$BASE_DIR" -maxdepth 1 -name "*.apk" -print0 2>/dev/null)
    
    if [ ${#APK_FILES[@]} -gt 0 ]; then
        echo -e "${BLUE}다운로드 폴더에서 발견된 APK 파일:${NC}"
        for i in "${!APK_FILES[@]}"; do
            echo -e "  ${GREEN}$((i+1)).${NC} ${APK_FILES[$i]}"
        done
        echo ""
        echo -e "${YELLOW}번호를 입력하거나, 직접 경로를 입력하세요:${NC}"
        read -r -p "> " selection
        
        if [[ "$selection" =~ ^[0-9]+$ ]] && [ "$selection" -ge 1 ] && [ "$selection" -le ${#APK_FILES[@]} ]; then
            SELECTED_APK_FILE="$BASE_DIR/${APK_FILES[$((selection-1))]}"
            print_success "선택됨: ${APK_FILES[$((selection-1))]}"
            return 0
        fi
        
        if [ -n "$selection" ]; then
            SELECTED_APK_FILE="$selection"
        fi
    else
        echo -e "${BLUE}APK 파일의 전체 경로를 입력하세요:${NC}"
        read -r -p "> " SELECTED_APK_FILE
    fi
    
    if [ -z "$SELECTED_APK_FILE" ] || [ ! -f "$SELECTED_APK_FILE" ]; then
        print_error "유효하지 않은 파일 경로입니다."
        return 1
    fi
    
    # .xapk 파일 입력을 방지하기 위한 간단한 확인
    if [[ "$SELECTED_APK_FILE" == *.xapk ]]; then
        print_error ".xapk 파일은 지원되지 않습니다. 순수 .apk 파일을 입력해주세요."
        return 1
    fi
    
    return 0
}

# --- 3. Run Patch (AmpleReVanced) ---
run_patch() {
    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}    AmpleReVanced 패치 시작...${NC}"
    echo -e "${GREEN}========================================${NC}"
    
    cd "$PATCH_SCRIPT_DIR"
    
    # [추가됨] 깃허브에서 고정 키스토어 다운로드
    echo -e "${YELLOW}[INFO] 고정 키스토어(my_kakao_key.keystore) 다운로드 중...${NC}"
    curl -L -o "$KEYSTORE_FILE" "$KEYSTORE_URL" || {
        print_error "키스토어 다운로드 실패! 인터넷 연결이나 URL을 확인하세요."
        return 1
    }

    # 이전 결과물 삭제 및 폴더 확인
    rm -rf output out
    
    # 패치 실행 (선택된 APK 파일을 바로 사용)
    print_info "build.py 실행 중... (입력 파일: $SELECTED_APK_FILE)"
    
    # [수정됨] --keystore 옵션 추가
    python build.py \
        --apk "$SELECTED_APK_FILE" \
        --package "$PKG_NAME" \
        --include-universal \
        --keystore "$KEYSTORE_FILE" \
        --run || {
        print_error "패치 과정 중 오류가 발생했습니다."
        return 1
    }
    
    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}    패치 프로세스 완료!${NC}"
    echo -e "${GREEN}========================================${NC}"
    
    # 결과물 확인 및 이동 (output 폴더와 out 폴더 모두 확인)
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
        # 덮어쓰기(-f) 옵션 추가
        mv -f "$OUTPUT_APK" "/storage/emulated/0/Download/DCInside_ReVanced.apk"
        print_success "저장 완료: /storage/emulated/0/Download/DCInside_ReVanced.apk"
    else
        print_error "결과물 파일을 찾을 수 없습니다."
        print_warn "다음 폴더를 직접 확인해보세요: $PATCH_SCRIPT_DIR/output 또는 $PATCH_SCRIPT_DIR/out"
    fi
}

# --- Main ---
main() {
    clear
    echo -e "${GREEN}======================================${NC}"
    echo -e "${GREEN}  디시인사이드 패치 (Key Fixed)   ${NC}"
    echo -e "${GREEN}======================================${NC}"
    echo ""
    
    check_dependencies || exit 1
    get_apk_file || exit 0
    # merge_apkm 단계는 제거됨
    run_patch || exit 1
    
    echo ""
    print_success "모든 작업이 성공적으로 끝났습니다."
}

main