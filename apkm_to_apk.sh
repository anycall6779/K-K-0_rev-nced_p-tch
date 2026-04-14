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
KEYSTORE_URL_1="https://raw.githubusercontent.com/anycall6779/K-K-0_rev-nced_p-tch/main/my_kakao_key.keystore"
KEYSTORE_URL_2="https://github.com/anycall6779/K-K-0_rev-nced_p-tch/raw/refs/heads/main/my_kakao_key.keystore"
KEYSTORE_URL_3="https://github.com/anycall6779/K-K-0_rev-nced_p-tch/raw/main/my_kakao_key.keystore"
KEYSTORE_FILE="$SCRIPT_DIR/my_kakao_key.keystore"
# alias를 강제하지 않고 keystore의 기본(유일) 엔트리를 사용합니다.
# 기존 "revanced" 강제 지정은 다른 엔트리를 집어 업데이트 실패를 유발할 수 있습니다.
KEYSTORE_ALIAS=""
KEYSTORE_PASS="android"
KEYSTORE_TYPE=""  # 자동 감지 (JKS 또는 PKCS12), 감지 불가 시 자동 모드
# 고정 keystore 무결성 체크(현재 저장소의 my_kakao_key.keystore와 동일 해시)
EXPECTED_KEYSTORE_SHA256="AA5AF5D37D84AA6B617C242FBAF3339F5A96F43C28F8604B9C20D4E9CFC3CDD9"
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

    for cmd in unzip java curl zipalign apksigner keytool sha256sum; do
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
        if [ -f "$BCPROV_JAR" ]; then
            return 0
        fi
        echo -e "${YELLOW}[INFO] Bouncy Castle provider 다운로드 중...${NC}"
        curl -L -f --connect-timeout 15 --max-time 60 -o "$BCPROV_JAR" "$BCPROV_URL" >/dev/null 2>&1 || return 1
        [ -s "$BCPROV_JAR" ] || return 1
        return 0
    }

    # 키스토어 유효성 검증 함수 (keytool로 실제 파싱 가능한지 확인, 타입 자동 감지)
verify_keystore() {
    local ks_path="$1"
    [ ! -f "$ks_path" ] && return 1

        # PKCS12로 시도
        if keytool -list -keystore "$ks_path" -storepass "$KEYSTORE_PASS" -storetype PKCS12 >/dev/null 2>&1; then
            KEYSTORE_TYPE="PKCS12"
            return 0
        fi
        # JKS로 시도
        if keytool -list -keystore "$ks_path" -storepass "$KEYSTORE_PASS" -storetype JKS >/dev/null 2>&1; then
            KEYSTORE_TYPE="JKS"
            return 0
        fi
        # BKS로 시도 (Bouncy Castle, Termux 환경에서 가끔 사용)
        if keytool -list -keystore "$ks_path" -storepass "$KEYSTORE_PASS" -storetype BKS >/dev/null 2>&1; then
            KEYSTORE_TYPE="BKS"
            return 0
        fi
        # 일부 환경(Termux/OpenJDK)에서는 BKS 계열을 keytool/apksigner가 직접 읽지 못합니다.
        # 고정 해시가 맞는 경우 BKS -> PKCS12로 변환해 apksigner 호환 형태로 맞춥니다.
        local ks_sha256
        ks_sha256=$(sha256sum "$ks_path" 2>/dev/null | awk '{print toupper($1)}')
        if [ -n "$ks_sha256" ] && [ "$ks_sha256" = "$EXPECTED_KEYSTORE_SHA256" ]; then
            local converted_ks="$SCRIPT_DIR/my_kakao_key.pkcs12"
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
                echo -e "${YELLOW}[WARN] keytool 타입 감지 실패. BKS -> PKCS12 변환 후 진행합니다.${NC}"
                return 0
            fi
            echo -e "${RED}[ERROR] 고정 키스토어를 PKCS12로 변환하지 못했습니다.${NC}"
            return 1
        fi

        return 1
    }

    # GitHub에서 고정 키스토어 다운로드 (반드시 이 키를 사용해야 함)
download_keystore() {
        # 기존 파일이 있으면 먼저 유효성 검사
        if [ -f "$KEYSTORE_FILE" ]; then
            echo -e "${BLUE}[INFO] 기존 키스토어 유효성 검증 중...${NC}"
            if verify_keystore "$KEYSTORE_FILE"; then
                local current_sha256
                current_sha256=$(sha256sum "$KEYSTORE_FILE" 2>/dev/null | awk '{print toupper($1)}')
                if [ -n "$current_sha256" ] && [ "$current_sha256" = "$EXPECTED_KEYSTORE_SHA256" ]; then
                    echo -e "${GREEN}[OK] 기존 키스토어가 유효하며 해시도 일치합니다. 재사용합니다.${NC}"
                    return 0
                fi
                echo -e "${YELLOW}[WARN] 기존 키스토어 해시가 고정값과 다릅니다. 다시 다운로드합니다.${NC}"
            else
                echo -e "${YELLOW}[WARN] 기존 키스토어가 손상되었습니다. 다시 다운로드합니다.${NC}"
            fi
            rm -f "$KEYSTORE_FILE"
        fi

        # 여러 URL로 다운로드 시도
        local URLS=("$KEYSTORE_URL_1" "$KEYSTORE_URL_2" "$KEYSTORE_URL_3")
        local DOWNLOADED=0

        for url in "${URLS[@]}"; do
            echo -e "${YELLOW}[INFO] 키스토어 다운로드 시도: $(basename "$url")...${NC}"
            rm -f "$KEYSTORE_FILE"
            if curl -L -f --connect-timeout 15 --max-time 60 -o "$KEYSTORE_FILE" "$url" 2>/dev/null; then
                # 다운로드 성공 - 파일 크기 확인
                local FILESIZE=$(wc -c < "$KEYSTORE_FILE" 2>/dev/null || echo 0)
                if [ "$FILESIZE" -lt 100 ]; then
                    echo -e "${YELLOW}[WARN] 다운로드 파일이 너무 작습니다 (${FILESIZE}B). 다음 URL 시도...${NC}"
                    rm -f "$KEYSTORE_FILE"
                    continue
                fi

                local DOWNLOADED_SHA256
                DOWNLOADED_SHA256=$(sha256sum "$KEYSTORE_FILE" 2>/dev/null | awk '{print toupper($1)}')
                if [ -z "$DOWNLOADED_SHA256" ] || [ "$DOWNLOADED_SHA256" != "$EXPECTED_KEYSTORE_SHA256" ]; then
                    echo -e "${YELLOW}[WARN] 키스토어 SHA-256 불일치. 다음 URL 시도...${NC}"
                    echo -e "${YELLOW}[WARN] expected=${EXPECTED_KEYSTORE_SHA256}${NC}"
                    echo -e "${YELLOW}[WARN] actual=${DOWNLOADED_SHA256:-N/A}${NC}"
                    rm -f "$KEYSTORE_FILE"
                    continue
                fi

                # keytool 유효성 검증 (또는 해시 고정값 기반 fallback)
                if verify_keystore "$KEYSTORE_FILE"; then
                    echo -e "${GREEN}[OK] 키스토어 다운로드/해시/검증 완료 (타입: ${KEYSTORE_TYPE:-auto})${NC}"
                    DOWNLOADED=1
                    break
                else
                    echo -e "${YELLOW}[WARN] 다운로드 파일이 유효한 키스토어가 아닙니다. 다음 URL 시도...${NC}"
                    rm -f "$KEYSTORE_FILE"
                fi
            else
                echo -e "${YELLOW}[WARN] 다운로드 실패. 다음 URL 시도...${NC}"
                rm -f "$KEYSTORE_FILE"
            fi
        done

        if [ $DOWNLOADED -eq 0 ]; then
            echo -e "${RED}============================================${NC}"
            echo -e "${RED}[ERROR] 고정 키스토어 다운로드에 실패했습니다!${NC}"
            echo -e "${RED}이 스크립트는 반드시 GitHub의 고정 키스토어를 사용해야 합니다.${NC}"
            echo -e "${RED}인터넷 연결 또는 GitHub 접속을 확인하세요.${NC}"
            echo -e "${RED}URL: $KEYSTORE_URL_1${NC}"
            echo -e "${RED}============================================${NC}"
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
    rm -rf "$TEMP_DIR" "$MERGED_APK" "$ALIGNED_APK"
}

main() {
    check_dependencies
    get_apkm_file
    merge_and_sign
}

main
