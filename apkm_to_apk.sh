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

# Keystore 설정 (patch5.sh 방식 그대로)
KEYSTORE_URL="https://github.com/anycall6779/K-K-0_rev-nced_p-tch/raw/refs/heads/main/my_kakao_key.keystore"
KEYSTORE_FILE="$SCRIPT_DIR/my_kakao_key.keystore"
KEYSTORE_ALIAS=""
KEYSTORE_PASS="android"
KEYSTORE_TYPE=""  # PKCS12 또는 JKS 감지
BCPROV_JAR="$SCRIPT_DIR/bcprov-jdk18on-1.78.1.jar"
BCPROV_URL="https://repo1.maven.org/maven2/org/bouncycastle/bcprov-jdk18on/1.78.1/bcprov-jdk18on-1.78.1.jar"

extract_apk_sha256() {
    local apk_path="$1"
    apksigner verify --print-certs "$apk_path" 2>/dev/null | sed -n 's/^Signer #1 certificate SHA-256 digest: //p' | head -n1
}

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
        pkg install -y $pkg || apt install -y $pkg || true
        
        if ! command -v $cmd &> /dev/null; then
            MISSING=1
        fi
    }

    for cmd in unzip java curl zipalign apksigner keytool; do
        if ! command -v $cmd &> /dev/null; then
            install_pkg $cmd
        fi
    done

    # Termux에서 zipalign/apksigner에 실행 권한이 없는 버그 수정
    for bin in zipalign apksigner; do
        local bin_path=$(command -v $bin 2>/dev/null || true)
        if [ -n "$bin_path" ] && [ ! -x "$bin_path" ]; then
            echo -e "${YELLOW}[FIX] '$bin' 실행 권한 부여 중...${NC}"
            chmod +x "$bin_path" 2>/dev/null || true
        fi
    done
    
    if [ $MISSING -eq 1 ]; then
        echo -e "${RED}[ERROR] 일부 도구를 자동 설치할 수 없습니다.${NC}"
        echo -e "${RED}수동으로 설치를 확인해주세요: pkg install unzip openjdk-17 curl apksigner${NC}"
        exit 1
    fi
    
    mkdir -p "$SCRIPT_DIR"
    
    if [ ! -f "$EDITOR_JAR" ]; then
        echo -e "${YELLOW}[INFO] 병합 툴(APKEditor) 다운로드 중...${NC}"
        curl -L -o "$EDITOR_JAR" "https://github.com/REAndroid/APKEditor/releases/download/V1.4.5/APKEditor-1.4.5.jar" || exit 1
    fi

    ensure_bcprov() {
        if [ -f "$BCPROV_JAR" ] && [ -s "$BCPROV_JAR" ]; then
            return 0
        fi
        echo -e "${YELLOW}[INFO] Bouncy Castle provider 다운로드 중...${NC}"
        curl -L -f --connect-timeout 15 --max-time 60 -o "$BCPROV_JAR" "$BCPROV_URL" >/dev/null 2>&1 || return 1
        [ -s "$BCPROV_JAR" ] || return 1
        return 0
    }

    # patch5.sh keystore를 원본 그대로 내려받고, 필요할 때만 임시 PKCS12로 변환합니다.
    verify_keystore() {
        local ks_path="$1"
        [ ! -f "$ks_path" ] && return 1

        if keytool -list -keystore "$ks_path" -storepass "$KEYSTORE_PASS" -storetype PKCS12 >/dev/null 2>&1; then
            KEYSTORE_TYPE="PKCS12"
            return 0
        fi
        if keytool -list -keystore "$ks_path" -storepass "$KEYSTORE_PASS" -storetype JKS >/dev/null 2>&1; then
            KEYSTORE_TYPE="JKS"
            return 0
        fi
        # 일부 환경에서는 원본 keystore를 직접 못 읽어서 임시 PKCS12 변환이 필요합니다.
        local converted_ks="$SCRIPT_DIR/my_kakao_key.temp.p12"
        if ensure_bcprov && keytool -importkeystore -noprompt \
            -providerclass org.bouncycastle.jce.provider.BouncyCastleProvider \
            -providerpath "$BCPROV_JAR" \
            -srckeystore "$ks_path" \
            -srcstoretype BKS \
            -srcstorepass "$KEYSTORE_PASS" \
            -destkeystore "$converted_ks" \
            -deststoretype PKCS12 \
            -deststorepass "$KEYSTORE_PASS" \
            -destkeypass "$KEYSTORE_PASS" >/dev/null 2>&1; then
            KEYSTORE_FILE="$converted_ks"
            KEYSTORE_TYPE="PKCS12"
            echo -e "${YELLOW}[WARN] 원본 keystore는 유지하고, 임시 PKCS12로 변환해 서명합니다.${NC}"
            return 0
        fi
        return 1
    }

    # patch5.sh처럼 GitHub 원본 keystore를 그대로 다운로드하고 바로 검증합니다.
    download_keystore() {
        echo -e "${YELLOW}[INFO] 고정 키스토어(my_kakao_key.keystore) 다운로드 중...${NC}"
        rm -f "$KEYSTORE_FILE"
        curl -L -f -o "$KEYSTORE_FILE" "$KEYSTORE_URL" >/dev/null 2>&1 || {
            echo -e "${RED}[ERROR] 키스토어 다운로드 실패! 인터넷 연결이나 URL을 확인하세요.${NC}"
            exit 1
        }

        if verify_keystore "$KEYSTORE_FILE"; then
            echo -e "${GREEN}[OK] 키스토어 타입: ${KEYSTORE_TYPE}${NC}"
        else
            echo -e "${RED}[ERROR] 다운로드된 키스토어가 유효하지 않음${NC}"
            exit 1
        fi
    }
    download_keystore
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
    if command -v zipalign &> /dev/null; then
        zipalign -p -f 4 "$MERGED_APK" "$ALIGNED_APK" || true
        if [ -f "$ALIGNED_APK" ]; then
            mv "$ALIGNED_APK" "$MERGED_APK"
            echo -e "${GREEN}[OK] Zipalign 최적화 완료${NC}"
        else
            echo -e "${YELLOW}[WARN] Zipalign 실패, 최적화 없이 계속 진행합니다.${NC}"
        fi
    else
        echo -e "${YELLOW}[WARN] zipalign을 찾을 수 없어 최적화를 건너뜁니다.${NC}"
    fi

    echo -e "${BLUE}[4/4] apksigner를 이용해 키스토어로 서명 중...${NC}"

    # 키스토어 파일 유효성 최종 확인
    if [ ! -f "$KEYSTORE_FILE" ]; then
        echo -e "${RED}[ERROR] 키스토어 파일이 존재하지 않습니다: $KEYSTORE_FILE${NC}"
        exit 1
    fi
    local KS_SIZE=$(wc -c < "$KEYSTORE_FILE" 2>/dev/null || echo 0)
    echo -e "${BLUE}[DEBUG] 키스토어: ${KEYSTORE_FILE}${NC}"
    echo -e "${BLUE}[DEBUG] 키스토어 크기: ${KS_SIZE}B / 타입: ${KEYSTORE_TYPE:-자동}${NC}"

    # apksigner 서명 명령 구성
    rm -f "$FINAL_APK"
    local SIGN_CMD=(apksigner sign
        --ks "$KEYSTORE_FILE"
        --ks-pass "pass:$KEYSTORE_PASS"
        --key-pass "pass:$KEYSTORE_PASS"
    )

    if [ -n "$KEYSTORE_ALIAS" ]; then
        SIGN_CMD+=(--ks-key-alias "$KEYSTORE_ALIAS")
    fi

    # 감지된 키스토어 타입이 있으면 명시적으로 전달 (JKS/PKCS12 혼동 방지)
    if [ -n "$KEYSTORE_TYPE" ]; then
        SIGN_CMD+=(--ks-type "$KEYSTORE_TYPE")
    fi

    SIGN_CMD+=(--out "$FINAL_APK" "$MERGED_APK")

    "${SIGN_CMD[@]}"

    if [ -f "$FINAL_APK" ]; then
        if ! apksigner verify "$FINAL_APK" >/dev/null 2>&1; then
            echo -e "${RED}[ERROR] 서명 검증 실패! (생성된 APK가 손상되었거나 서명이 올바르지 않음)${NC}"
            exit 1
        fi

        local apk_cert_sha256=$(extract_apk_sha256 "$FINAL_APK")
        echo -e "\n${GREEN}[============= 성공! =============]${NC}"
        echo -e "${GREEN}저장 완료: $FINAL_APK${NC}"
        if [ -n "$apk_cert_sha256" ]; then
            echo -e "${BLUE}[INFO] 최종 APK 서명 SHA-256: ${apk_cert_sha256}${NC}"
        fi
        echo -e "${YELLOW}[안내] 기존 설치본과 서명 SHA-256이 같아야 '업데이트' 설치가 됩니다.${NC}"
    else
        echo -e "${RED}[ERROR] 서명 실패!${NC}"
    fi

    echo -e "${YELLOW}임시 파일 정리 중...${NC}"
    rm -rf "$TEMP_DIR" "$MERGED_APK" "$ALIGNED_APK" "$SCRIPT_DIR/my_kakao_key.temp.p12"
}

main() {
    check_dependencies
    get_apkm_file
    merge_and_sign
}

main
