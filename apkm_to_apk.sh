#!/bin/bash
#
# KakaoTalk APKM → 서명된 APK 변환기 (패치 없음)
# - patch5.sh의 키스토어 다운로드/검증/서명 방식을 그대로 사용
# - BKS → PKCS12 자동 변환 (Bouncy Castle) 지원
# - zipalign 최적화 (가능한 경우)
# - 서명 후 SHA-256 검증
#
set -e

# Color Codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# ========== Configuration ==========
BASE_DIR="/storage/emulated/0/Download"
WORK_DIR="$HOME/sign_only_workdir"
EDITOR_JAR="$BASE_DIR/APKEditor-1.4.5.jar"

# GitHub 키스토어 (patch5.sh 동일)
KEYSTORE_URL="https://github.com/anycall6779/K-K-0_rev-nced_p-tch/raw/refs/heads/main/my_kakao_key.keystore"
KEYSTORE_FILE="$WORK_DIR/my_kakao_key.keystore"
KEYSTORE_PASS="android"
KEYSTORE_ALIAS=""
KEYSTORE_TYPE=""

# Bouncy Castle (BKS 키스토어 변환용)
BCPROV_JAR="$WORK_DIR/bcprov-jdk18on-1.78.1.jar"
BCPROV_URL="https://repo1.maven.org/maven2/org/bouncycastle/bcprov-jdk18on/1.78.1/bcprov-jdk18on-1.78.1.jar"

# ========== Utility ==========
extract_apk_sha256() {
    local apk_path="$1"
    apksigner verify --print-certs "$apk_path" 2>/dev/null \
        | sed -n 's/^Signer #1 certificate SHA-256 digest: //p' | head -n1
}

# ========== 1. 의존성 확인 ==========
check_dependencies() {
    echo -e "${BLUE}[INFO] 필수 도구 확인 중...${NC}"
    local MISSING=0

    install_pkg() {
        local cmd="$1"
        local pkg="$1"
        [ "$cmd" = "java" ] && pkg="openjdk-17"
        echo -e "${YELLOW}[WARN] '$cmd' 없음 → 설치 시도: pkg install -y $pkg${NC}"
        pkg install -y "$pkg" >/dev/null 2>&1 || apt install -y "$pkg" >/dev/null 2>&1 || true
        if ! command -v "$cmd" &>/dev/null; then
            MISSING=1
        fi
    }

    for cmd in curl unzip java keytool apksigner; do
        command -v "$cmd" &>/dev/null || install_pkg "$cmd"
    done

    # Termux에서 zipalign/apksigner 실행 권한 누락 버그 대응
    for bin in zipalign apksigner; do
        local bin_path=$(command -v "$bin" 2>/dev/null || true)
        if [ -n "$bin_path" ] && [ ! -x "$bin_path" ]; then
            echo -e "${YELLOW}[FIX] '$bin' 실행 권한 부여 중...${NC}"
            chmod +x "$bin_path" 2>/dev/null || true
        fi
    done

    if [ "$MISSING" -eq 1 ]; then
        echo -e "${RED}[ERROR] 일부 도구 설치 실패. 수동 설치 후 다시 실행하세요.${NC}"
        echo -e "${RED}       pkg install unzip curl openjdk-17 apksigner${NC}"
        exit 1
    fi

    mkdir -p "$WORK_DIR"

    # APKEditor 다운로드
    if [ ! -f "$EDITOR_JAR" ]; then
        echo -e "${YELLOW}[INFO] APKEditor 다운로드 중...${NC}"
        curl -L -o "$EDITOR_JAR" \
            "https://github.com/REAndroid/APKEditor/releases/download/V1.4.5/APKEditor-1.4.5.jar" || {
            echo -e "${RED}[ERROR] APKEditor 다운로드 실패${NC}"
            exit 1
        }
    fi

    echo -e "${GREEN}[OK] 모든 도구 준비 완료${NC}"
}

# ========== 2. 키스토어 준비 (patch5.sh 방식) ==========
ensure_bcprov() {
    if [ -f "$BCPROV_JAR" ] && [ -s "$BCPROV_JAR" ]; then
        return 0
    fi
    echo -e "${YELLOW}[INFO] Bouncy Castle provider 다운로드 중...${NC}"
    curl -L -f --connect-timeout 15 --max-time 60 -o "$BCPROV_JAR" "$BCPROV_URL" >/dev/null 2>&1 || return 1
    [ -s "$BCPROV_JAR" ] || return 1
    return 0
}

verify_keystore() {
    local ks_path="$1"
    [ ! -f "$ks_path" ] && return 1

    # 1) PKCS12
    if keytool -list -keystore "$ks_path" -storepass "$KEYSTORE_PASS" -storetype PKCS12 >/dev/null 2>&1; then
        KEYSTORE_TYPE="PKCS12"
        return 0
    fi
    # 2) JKS
    if keytool -list -keystore "$ks_path" -storepass "$KEYSTORE_PASS" -storetype JKS >/dev/null 2>&1; then
        KEYSTORE_TYPE="JKS"
        return 0
    fi
    # 3) BKS (Bouncy Castle 필요)
    if ! ensure_bcprov; then
        echo -e "${RED}[ERROR] Bouncy Castle 다운로드 실패 → BKS 검증 불가${NC}"
        return 1
    fi

    if ! keytool -list \
        -providerclass org.bouncycastle.jce.provider.BouncyCastleProvider \
        -providerpath "$BCPROV_JAR" \
        -keystore "$ks_path" \
        -storetype BKS \
        -storepass "$KEYSTORE_PASS" >/dev/null 2>&1; then
        echo -e "${RED}[ERROR] PKCS12/JKS/BKS 어느 형식으로도 키스토어를 읽지 못했습니다.${NC}"
        return 1
    fi

    # BKS → PKCS12 변환 (apksigner 호환)
    local converted_ks="$WORK_DIR/my_kakao_key.temp.p12"
    if keytool -importkeystore -noprompt \
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
        echo -e "${YELLOW}[WARN] BKS → 임시 PKCS12로 변환하여 서명합니다.${NC}"
        return 0
    fi

    echo -e "${RED}[ERROR] BKS → PKCS12 변환 실패${NC}"
    return 1
}

prepare_keystore() {
    echo -e "${YELLOW}[INFO] 고정 키스토어(my_kakao_key.keystore) 다운로드 중...${NC}"
    rm -f "$KEYSTORE_FILE"
    curl -L -f -A "Mozilla/5.0 (Android; Termux)" -o "$KEYSTORE_FILE" "$KEYSTORE_URL" >/dev/null 2>&1 || {
        echo -e "${RED}[ERROR] 키스토어 다운로드 실패! 인터넷 연결이나 URL을 확인하세요.${NC}"
        return 1
    }

    # 빈 파일 체크
    if [ ! -s "$KEYSTORE_FILE" ]; then
        echo -e "${RED}[ERROR] 키스토어 파일이 비어 있습니다.${NC}"
        return 1
    fi

    # HTML 오다운로드 체크
    if head -c 256 "$KEYSTORE_FILE" 2>/dev/null | grep -qiE '<!doctype html|<html|github'; then
        echo -e "${RED}[ERROR] 키스토어 대신 HTML이 다운로드됨. URL/네트워크 확인 필요.${NC}"
        return 1
    fi

    if verify_keystore "$KEYSTORE_FILE"; then
        local ks_size=$(wc -c < "$KEYSTORE_FILE" 2>/dev/null || echo 0)
        echo -e "${GREEN}[OK] 키스토어 타입: ${KEYSTORE_TYPE}  (${ks_size}B)${NC}"
    else
        echo -e "${RED}[ERROR] 다운로드된 키스토어가 유효하지 않음${NC}"
        return 1
    fi
}

# ========== 3. APKM 파일 선택 ==========
get_apkm_file() {
    echo ""
    echo -e "${YELLOW}==================================${NC}"
    echo -e "${GREEN}카카오톡 APKM 파일 선택${NC}"
    echo -e "${YELLOW}==================================${NC}"
    echo ""

    local apkm_files=()
    while IFS= read -r -d '' file; do
        apkm_files+=("$(basename "$file")")
    done < <(find "$BASE_DIR" -maxdepth 1 -name "*.apkm" -print0 2>/dev/null)

    if [ ${#apkm_files[@]} -gt 0 ]; then
        echo -e "${BLUE}다운로드 폴더에서 발견된 APKM 파일:${NC}"
        for i in "${!apkm_files[@]}"; do
            echo -e "  ${GREEN}$((i+1)).${NC} ${apkm_files[$i]}"
        done
        echo ""
        echo -e "${YELLOW}번호를 입력하거나, 직접 경로를 입력하세요:${NC}"
        read -r -p "> " selection

        if [[ "$selection" =~ ^[0-9]+$ ]] && [ "$selection" -ge 1 ] && [ "$selection" -le ${#apkm_files[@]} ]; then
            APKM_FILE="$BASE_DIR/${apkm_files[$((selection-1))]}"
            echo -e "${GREEN}[선택됨] ${apkm_files[$((selection-1))]}${NC}"
            return 0
        fi

        if [ -n "$selection" ]; then
            APKM_FILE="$selection"
        fi
    else
        echo -e "${BLUE}APKM 파일의 전체 경로를 입력하세요:${NC}"
        echo -e "${YELLOW}(예: /storage/emulated/0/Download/com.kakao.talk.apkm)${NC}"
        echo ""
        read -r -p "> " APKM_FILE
    fi

    if [ -z "$APKM_FILE" ] || [ ! -f "$APKM_FILE" ]; then
        echo -e "${RED}[ERROR] 유효하지 않은 파일 경로입니다.${NC}"
        return 1
    fi
}

# ========== 4. APKM 병합 ==========
merge_apkm() {
    echo ""
    echo -e "${BLUE}[1/3] APKM 압축 해제 및 병합 중...${NC}"
    local temp_dir="$WORK_DIR/temp_merge"
    rm -rf "$temp_dir" && mkdir -p "$temp_dir"

    unzip -qqo "$APKM_FILE" -d "$temp_dir" 2>/dev/null || {
        echo -e "${RED}[ERROR] 압축 해제 실패${NC}"
        rm -rf "$temp_dir"
        return 1
    }

    if [ ! -f "$temp_dir/base.apk" ]; then
        echo -e "${RED}[ERROR] base.apk를 찾을 수 없습니다 (올바른 APKM이 아닐 수 있습니다)${NC}"
        rm -rf "$temp_dir"
        return 1
    fi

    local merged_apk="$WORK_DIR/merged_unsigned.apk"
    rm -f "$merged_apk"

    echo -e "${BLUE}[INFO] APKEditor로 병합 중... (잠시만 기다려주세요)${NC}"
    java -jar "$EDITOR_JAR" m -i "$temp_dir" -o "$merged_apk" >/dev/null 2>&1 || {
        echo -e "${RED}[ERROR] APKEditor 병합 실패${NC}"
        rm -rf "$temp_dir"
        return 1
    }

    if [ ! -f "$merged_apk" ]; then
        echo -e "${RED}[ERROR] 병합된 APK 생성 실패${NC}"
        rm -rf "$temp_dir"
        return 1
    fi

    rm -rf "$temp_dir"
    MERGED_APK="$merged_apk"
    echo -e "${GREEN}[OK] 병합 완료${NC}"
}

# ========== 5. Zipalign 최적화 ==========
zipalign_apk() {
    echo -e "${BLUE}[2/3] Zipalign 최적화 중...${NC}"

    if ! command -v zipalign &>/dev/null; then
        echo -e "${YELLOW}[WARN] zipalign을 찾을 수 없어 최적화를 건너뜁니다.${NC}"
        return 0
    fi

    local aligned_apk="$WORK_DIR/merged_aligned.apk"
    rm -f "$aligned_apk"
    zipalign -p -f 4 "$MERGED_APK" "$aligned_apk" || true

    if [ -f "$aligned_apk" ]; then
        mv "$aligned_apk" "$MERGED_APK"
        echo -e "${GREEN}[OK] Zipalign 최적화 완료${NC}"
    else
        echo -e "${YELLOW}[WARN] Zipalign 실패, 최적화 없이 계속 진행${NC}"
    fi
}

# ========== 6. APK 서명 (patch5.sh 방식) ==========
sign_apk() {
    echo -e "${BLUE}[3/3] apksigner로 서명 중...${NC}"

    # 결과물 파일명: 원본 APKM에서 확장자 변경
    local file_base=$(basename "$APKM_FILE" .apkm)
    local final_apk="$BASE_DIR/${file_base}_Signed.apk"
    rm -f "$final_apk"

    # 키스토어 유효성 최종 확인
    if [ ! -f "$KEYSTORE_FILE" ]; then
        echo -e "${RED}[ERROR] 키스토어 파일이 존재하지 않습니다: $KEYSTORE_FILE${NC}"
        return 1
    fi

    local ks_size=$(wc -c < "$KEYSTORE_FILE" 2>/dev/null || echo 0)
    echo -e "${CYAN}  키스토어: $(basename "$KEYSTORE_FILE")${NC}"
    echo -e "${CYAN}  크기: ${ks_size}B / 타입: ${KEYSTORE_TYPE:-자동}${NC}"

    # 서명 명령 구성 (patch5.sh 동일 방식)
    local SIGN_CMD=(apksigner sign
        --ks "$KEYSTORE_FILE"
        --ks-pass "pass:$KEYSTORE_PASS"
        --key-pass "pass:$KEYSTORE_PASS"
    )

    if [ -n "$KEYSTORE_ALIAS" ]; then
        SIGN_CMD+=(--ks-key-alias "$KEYSTORE_ALIAS")
    fi

    if [ -n "$KEYSTORE_TYPE" ]; then
        SIGN_CMD+=(--ks-type "$KEYSTORE_TYPE")
    fi

    SIGN_CMD+=(--out "$final_apk" "$MERGED_APK")

    "${SIGN_CMD[@]}" || {
        echo -e "${RED}[ERROR] APK 서명 실패${NC}"
        return 1
    }

    # 서명 검증
    if [ ! -f "$final_apk" ]; then
        echo -e "${RED}[ERROR] 서명된 APK 파일이 생성되지 않았습니다.${NC}"
        return 1
    fi

    if ! apksigner verify "$final_apk" >/dev/null 2>&1; then
        echo -e "${RED}[ERROR] 서명 검증 실패! APK가 손상되었거나 서명이 올바르지 않습니다.${NC}"
        return 1
    fi

    # SHA-256 인증서 해시 출력
    local cert_sha256=$(extract_apk_sha256 "$final_apk")

    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║         서명 완료!                    ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════╝${NC}"
    echo -e "${GREEN}  저장 위치: ${final_apk}${NC}"
    if [ -n "$cert_sha256" ]; then
        echo -e "${BLUE}  서명 SHA-256: ${cert_sha256}${NC}"
    fi
    echo -e "${YELLOW}  [안내] 기존 설치본과 SHA-256이 같아야 업데이트 설치가 됩니다.${NC}"
    echo ""

    FINAL_APK="$final_apk"
}

# ========== 7. 임시 파일 정리 ==========
cleanup() {
    echo -e "${YELLOW}[INFO] 임시 파일 정리 중...${NC}"
    rm -f "$WORK_DIR/merged_unsigned.apk" \
          "$WORK_DIR/merged_aligned.apk" \
          "$WORK_DIR/my_kakao_key.temp.p12"
    echo -e "${GREEN}[OK] 정리 완료${NC}"
}

# ========== Main ==========
main() {
    clear
    echo -e "${GREEN}╔══════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║  APKM → 서명된 APK 변환기 (패치 없음)    ║${NC}"
    echo -e "${GREEN}║  (patch5.sh 서명 방식 동일)               ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════╝${NC}"
    echo ""

    check_dependencies
    prepare_keystore  || exit 1
    get_apkm_file     || exit 1
    merge_apkm        || exit 1
    zipalign_apk
    sign_apk          || exit 1
    cleanup

    echo -e "${GREEN}모든 작업이 완료되었습니다!${NC}"
}

main
