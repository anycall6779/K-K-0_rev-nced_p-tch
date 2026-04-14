#!/bin/bash
#
# APKM to APK Merger & Signer
# APKM 파일을 병합하고 지정된 keystore로 서명하여 순정 APK로 만듭니다.
#

set -e

# Color Codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

BASE_DIR="/storage/emulated/0/Download"
SCRIPT_DIR="$HOME/apkm_to_apk"
EDITOR_JAR="$BASE_DIR/APKEditor-1.4.5.jar"

# Keystore 설정
KEYSTORE_URL="https://github.com/anycall6779/K-K-0_rev-nced_p-tch/raw/refs/heads/main/my_kakao_key.keystore"
KEYSTORE_FILE="$SCRIPT_DIR/my_kakao_key.keystore"
KEYSTORE_ALIAS="revanced"
KEYSTORE_PASS="android"

check_dependencies() {
    clear
    echo -e "${BLUE}=======================================${NC}"
    echo -e "${GREEN}       APKM to APK 병합 및 서명기       ${NC}"
    echo -e "${BLUE}=======================================${NC}"
    echo -e "${BLUE}[INFO] 필요 도구 확인 중...${NC}"
    
    local MISSING=0
    
    install_pkg() {
        local cmd=$1
        local pkg=$1
        
        # 명령어와 패키지 이름이 다른 경우 매핑
        if [ "$cmd" = "java" ]; then pkg="openjdk-17"; fi
        
        echo -e "${YELLOW}[WARN] '$cmd' 명령어가 없습니다. 설치 시도 중...${NC}"
        
        if [ "$cmd" = "zipalign" ]; then
            # zipalign은 기본 저장소에 없으므로 tur-repo 또는 rendiix 저장소 사용
            pkg install -y tur-repo 2>/dev/null
            pkg install -y zipalign 2>/dev/null
            
            if ! command -v zipalign &> /dev/null; then
                echo -e "${YELLOW}[INFO] 외부 저장소(rendiix)를 통해 zipalign 설치 시도...${NC}"
                curl -s https://raw.githubusercontent.com/rendiix/rendiix.github.io/master/install-repo.sh | bash
                pkg install -y zipalign
            fi
        else
            pkg install -y $pkg || apt install -y $pkg
        fi
        
        if ! command -v $cmd &> /dev/null; then
            MISSING=1
        fi
    }

    for cmd in unzip java wget apksigner zipalign; do
        if ! command -v $cmd &> /dev/null; then
            install_pkg $cmd
        fi
    done
    
    if [ $MISSING -eq 1 ]; then
        echo -e "${RED}[ERROR] 일부 도구를 자동 설치할 수 없습니다.${NC}"
        echo -e "${RED}수동으로 설치를 확인해주세요: pkg install unzip openjdk-17 wget apksigner zipalign${NC}"
        exit 1
    fi
    
    mkdir -p "$SCRIPT_DIR"
    
    if [ ! -f "$EDITOR_JAR" ]; then
        echo -e "${YELLOW}[INFO] 병합 툴(APKEditor) 다운로드 중...${NC}"
        wget --quiet --show-progress -O "$EDITOR_JAR" "https://github.com/REAndroid/APKEditor/releases/download/V1.4.5/APKEditor-1.4.5.jar" || exit 1
    fi

    if [ ! -f "$KEYSTORE_FILE" ]; then
        echo -e "${YELLOW}[INFO] 서명 키스토어 다운로드 중...${NC}"
        wget --quiet -O "$KEYSTORE_FILE" "$KEYSTORE_URL" || exit 1
    fi
}

get_apkm_file() {
    echo ""
    echo -e "${GREEN}변환할 APKM 파일을 선택하세요 (Download 폴더 기준)${NC}"
    
    local APKM_FILES=()
    while IFS= read -r -d '' file; do
        APKM_FILES+=("$(basename "$file")")
    done < <(find "$BASE_DIR" -maxdepth 1 -name "*.apkm" -print0 2>/dev/null)
    
    if [ ${#APKM_FILES[@]} -gt 0 ]; then
        for i in "${!APKM_FILES[@]}"; do
            echo -e "  ${GREEN}$((i+1)).${NC} ${APKM_FILES[$i]}"
        done
        echo ""
        read -r -p "> 번호 입력 (혹은 0을 눌러 직접 입력): " selection
        
        if [[ "$selection" =~ ^[0-9]+$ ]] && [ "$selection" -ge 1 ] && [ "$selection" -le ${#APKM_FILES[@]} ]; then
            APKM_FILE="$BASE_DIR/${APKM_FILES[$((selection-1))]}"
            echo -e "${GREEN}[선택됨] ${APKM_FILES[$((selection-1))]}${NC}"
            return 0
        fi
    fi
    
    echo -e "\n${YELLOW}APKM 파일의 전체 경로를 입력해주세요:${NC}"
    read -r -p "> 경로: " APKM_FILE
    if [ ! -f "$APKM_FILE" ]; then
        echo -e "${RED}[ERROR] 파일이 존재하지 않습니다: $APKM_FILE${NC}"
        exit 1
    fi
}

merge_and_sign() {
    local TEMP_DIR="$SCRIPT_DIR/temp_merge"
    local MERGED_APK="$SCRIPT_DIR/merged_unsigned.apk"
    local ALIGNED_APK="$SCRIPT_DIR/merged_aligned.apk"
    
    # 결과물은 원본 파일명에서 .apkm을 제거하고 _Signed_APK.apk를 붙입니다.
    local FILE_BASE_NAME=$(basename "$APKM_FILE" .apkm)
    local FINAL_APK="$BASE_DIR/${FILE_BASE_NAME}_Signed.apk"

    rm -rf "$TEMP_DIR" && mkdir -p "$TEMP_DIR"
    
    echo -e "\n${BLUE}[1/4] APKM 압축 해제 중...${NC}"
    unzip -qqo "$APKM_FILE" -d "$TEMP_DIR" 2>/dev/null
    
    if [ ! -f "$TEMP_DIR/base.apk" ]; then
        echo -e "${RED}[ERROR] 압축 해제 패일에 base.apk가 존재하지 않습니다 (올바른 APKM 파일이 아님).${NC}"
        exit 1
    fi
    
    echo -e "${BLUE}[2/4] APKEditor를 통한 파일 병합 중...${NC}"
    rm -f "$MERGED_APK"
    java -jar "$EDITOR_JAR" m -i "$TEMP_DIR" -o "$MERGED_APK" >/dev/null 2>&1
    
    if [ ! -f "$MERGED_APK" ]; then
        echo -e "${RED}[ERROR] 파일 병합 실패!${NC}"
        exit 1
    fi
    
    echo -e "${BLUE}[3/4] Zipalign 파일 최적화 중...${NC}"
    rm -f "$ALIGNED_APK"
    zipalign -p -f 4 "$MERGED_APK" "$ALIGNED_APK"
    
    echo -e "${BLUE}[4/4] apksigner를 이용해 키스토어로 서명 중...${NC}"
    rm -f "$FINAL_APK"
    apksigner sign --ks "$KEYSTORE_FILE" \
        --ks-key-alias "$KEYSTORE_ALIAS" \
        --ks-pass "pass:$KEYSTORE_PASS" \
        --key-pass "pass:$KEYSTORE_PASS" \
        --out "$FINAL_APK" "$ALIGNED_APK"

    if [ -f "$FINAL_APK" ]; then
        echo -e "\n${GREEN}[============= 성공! =============]${NC}"
        echo -e "${GREEN}저장 완료: $FINAL_APK${NC}"
    else
        echo -e "${RED}[ERROR] 서명 실패!${NC}"
    fi

    echo -e "${YELLOW}임시 파일 정리 중...${NC}"
    rm -rf "$TEMP_DIR" "$MERGED_APK" "$ALIGNED_APK"
}

main() {
    check_dependencies
    get_apkm_file
    merge_and_sign
}

main
