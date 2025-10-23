#!/bin/bash
#
# 카카오톡 버전 선택 + 자동 병합 + 자동 패치 (revanced-build-script)
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
APP_NAME="KakaoTalk"
PKG_NAME="com.kakao.talk"
APKMIRROR_APP_NAME="kakaotalk"

# 경로 설정
BASE_DIR="/storage/emulated/0/Download"
PATCH_SCRIPT_DIR="$HOME/revanced-build-script"
MERGED_APK_PATH="$HOME/Downloads/KakaoTalk.apk" # build.py가 읽을 파일 위치

# 도구 경로
EDITOR_JAR="$BASE_DIR/APKEditor-1.4.5.jar"

# 환경 변수
USER_AGENT="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/90.0.4430.93 Safari/537.36"
ARCH=$(getprop ro.product.cpu.abi)
DPI=$(getprop ro.sf.lcd_density)
LOCALE=$(getprop persist.sys.locale | sed 's/-.*//g')
[ "$ARCH" = "arm64-v8a" ] && ARCH_APK="arm64" || ARCH_APK="armeabi"

# Termux UI 도구
DIALOG=(dialog --keep-tite --no-shadow --no-collapse --visit-items --ok-label "선택" --cancel-label "취소")
CURL=(curl -L -s -k --compressed --retry 3 --retry-delay 1)
WGET=(wget --quiet --show-progress --progress=bar:force:noscroll --no-check-certificate)

# --- 2. 도구 확인 함수 ---
check_dependencies() {
    echo -e "${BLUE}[INFO] 필수 도구 확인 중...${NC}"
    local MISSING=0
    for cmd in dialog curl pup jq wget unzip java python git; do
        if ! command -v $cmd &> /dev/null; then
            echo -e "${RED}[오류] '$cmd'가 없습니다. 'pkg install ${cmd}'를 실행하세요.${NC}"
            MISSING=1
        fi
    done
    
    if [ ! -d "$PATCH_SCRIPT_DIR" ]; then
        echo -e "${RED}[오류] 패치 스크립트 폴더가 없습니다: $PATCH_SCRIPT_DIR${NC}"
        echo -e "${YELLOW} 'git clone https://git.naijun.dev/ReVanced/revanced-build-script.git' 를 홈(~)에서 실행하세요.${NC}"
        MISSING=1
    fi
    
    if [ ! -f "$EDITOR_JAR" ]; then
        echo -e "${RED}[오류] APKEditor가 없습니다: $EDITOR_JAR${NC}"
        echo -e "${YELLOW} 'wget https://.../APKEditor-1.4.5.jar' 를 $BASE_DIR 에서 실행하세요.${NC}"
        MISSING=1
    fi
    
    [ $MISSING -eq 1 ] && exit 1
    mkdir -p "$HOME/Downloads" # build.py가 사용할 폴더 생성
}

# --- 3. 버전 스크래핑 및 선택 ---
choose_version() {
    echo -e "${BLUE}[INFO] APKMirror에서 버전 목록을 불러옵니다...${NC}"
    local PAGE_CONTENTS
    PAGE_CONTENTS=$("${CURL[@]}" -A "$USER_AGENT" "https://www.apkmirror.com/uploads/?appcategory=$APKMIRROR_APP_NAME")

    readarray -t VERSIONS_LIST < <(
        pup -c 'div.listWidget div:not([class]) json{}' <<< "$PAGE_CONTENTS" |
            jq -rc '
            .[].children as $CHILDREN |
            {
                version: $CHILDREN[1].children[0].children[1].text,
                url: $CHILDREN[0].children[0].children[1].children[0].children[0].children[0].href
            } |
            "\(.version)" "\( .url | @json )"
        ' | head -n 30
    )

    if [ ${#VERSIONS_LIST[@]} -eq 0 ]; then
        echo -e "${RED}[오류] 버전 목록을 가져오지 못했습니다.${NC}"
        exit 1
    fi

    local SELECTED_URL_JSON
    if ! SELECTED_URL_JSON=$(
        "${DIALOG[@]}" \
            --title "| 버전 선택 (KakaoTalk) |" \
            --menu "스크롤하여 원하는 버전을 선택하세요" -1 -1 0 \
            "${VERSIONS_LIST[@]}" \
            2>&1 > /dev/tty
    ); then
        return 1 # 사용자가 '취소' 선택
    fi
    
    APP_DL_URL="https://www.apkmirror.com$(jq -r . <<< "$SELECTED_URL_JSON")"
    APP_VER=$(jq -r . <<< "$SELECTED_URL_JSON" | cut -d '/' -f 6 | sed 's/kakaotalk-//; s/-release//')
    
    echo -e "${GREEN}[선택] 버전: $APP_VER${NC}"
}

# --- 4. 다운로드 링크 자동 스크래핑 ---
scrape_download_link() {
    echo -e "\n${BLUE}[INFO] 1/3: 버전 페이지 분석 중...${NC}"
    local PAGE1 PAGE2 URL1 URL2 URL3 VARIANT_INFO
    
    PAGE1=$("${CURL[@]}" -A "$USER_AGENT" "$APP_DL_URL")

    readarray -t VARIANT_INFO < <(
        pup -p --charset utf-8 'div.variants-table json{}' <<< "$PAGE1" |
            jq -r \
                --arg ARCH "$ARCH" \
                --arg DPI "$DPI" '
                [
                    .[].children[1:][].children |
                    if (.[1].text | test("universal|noarch|\($ARCH)")) and
                       (.[3].text | test("nodpi") or 
                           (capture("(?<low>\\d+)-(?<high>\\d+)dpi") | 
                           (($DPI | tonumber) <= (.high | tonumber)) and (($DPI | tonumber) >= (.low | tonumber)))
                       )
                    then .[0].children else empty end
                ] |
                (.[[] | if (.[1].text == "BUNDLE") then .[0].href else empty end][-1]) // (.[[] | .[0].href][-1])
            '
    )
    
    URL1="${VARIANT_INFO[0]}"
    if [ -z "$URL1" ]; then
        echo -e "${RED}[오류] 이 버전에 $ARCH 아키텍처를 지원하는 파일이 없습니다.${NC}"
        return 1
    fi
    
    echo -e "${BLUE}[INFO] 2/3: 다운로드 페이지 분석 중...${NC}"
    PAGE2=$("${CURL[@]}" -A "$USER_AGENT" "https://www.apkmirror.com$URL1")
    URL2=$(pup -p --charset utf-8 'a.downloadButton[data-google-vignette="false"] attr{href}' <<< "$PAGE2" 2> /dev/null | head -n 1)
    
    echo -e "${BLUE}[INFO] 3/3: 최종 링크 가져오는 중...${NC}"
    PAGE3=$("${CURL[@]}" -A "$USER_AGENT" "https://www.apkmirror.com$URL2")
    URL3=$(pup -p --charset UTF-8 'a:contains("here") attr{href}' <<< "$PAGE3" 2> /dev/null | head -n 1)
    
    if [ -z "$URL3" ]; then
        echo -e "${RED}[오류] 최종 다운로드 링크를 찾는 데 실패했습니다.${NC}"
        return 1
    fi

    APP_URL="https://www.apkmirror.com$URL3"
    APKM_FILE="$BASE_DIR/${APP_VER}.apkm" # 임시 저장될 .apkm 파일 경로
    echo -e "${GREEN}[성공] 최종 다운로드 링크 확보!${NC}"
}

# --- 5. 다운로드 및 병합 ---
download_and_merge() {
    echo -e "\n${BLUE}[INFO] 파일을 다운로드합니다. ( $APP_NAME-$APP_VER.apkm )${NC}"
    rm -f "$APKM_FILE"
    "${WGET[@]}" "$APP_URL" -O "$APKM_FILE"
    
    if [ ! -f "$APKM_FILE" ]; then
        echo -e "${RED}[오류] 파일 다운로드에 실패했습니다.${NC}"
        return 1
    fi

    echo -e "\n${BLUE}[INFO] APKM 파일을 병합합니다... (-> $MERGED_APK_PATH)${NC}"
    local TEMP_DIR="$BASE_DIR/kkt_temp_merge"
    rm -rf "$TEMP_DIR" && mkdir -p "$TEMP_DIR"
    
    # Revancify의 효율적인 압축 해제 로직
    unzip -qqo "$APKM_FILE" \
        "base.apk" \
        "split_config.${ARCH_APK}_v8a.apk" \
        "split_config.${LOCALE}.apk" \
        split_config.*dpi.apk \
        -d "$TEMP_DIR" 2> /dev/null

    if [ ! -f "$TEMP_DIR/base.apk" ]; then
        echo -e "${YELLOW}[경고] 필수 파일 추출 실패. 전체 압축 해제를 시도합니다...${NC}"
        unzip -qqo "$APKM_FILE" -d "$TEMP_DIR" 2> /dev/null
    fi

    echo -e "${BLUE}[INFO] APKEditor로 병합 중... (시간이 걸립니다)${NC}"
    # build.py가 읽을 최종 경로로 바로 병합
    rm -f "$MERGED_APK_PATH"
    java -jar "$EDITOR_JAR" m -i "$TEMP_DIR" -o "$MERGED_APK_PATH"
    
    if [ ! -f "$MERGED_APK_PATH" ]; then
        echo -e "${RED}[오류] APKEditor 병합에 실패했습니다.${NC}"
        rm -rf "$TEMP_DIR" "$APKM_FILE"
        return 1
    fi
    
    echo -e "${GREEN}[성공] 병합 완료: $MERGED_APK_PATH${NC}"
    
    # 임시 파일 정리
    rm -f "$APKM_FILE"
    rm -rf "$TEMP_DIR"
}

# --- 6. 패치 스크립트 실행 ---
run_patch() {
    echo -e "\n${GREEN}========= 패치 스크립트 실행 =========${NC}"
    cd "$PATCH_SCRIPT_DIR"
    
    # 사용자가 요청한 build.py 명령어 실행
    ./build.py \
        --apk "$MERGED_APK_PATH" \
        --package "$PKG_NAME" \
        --include-universal \
        --run
    
    local EXIT_CODE=$?
    if [ $EXIT_CODE -ne 0 ]; then
        echo -e "${RED}[오류] 패치 스크립트 실행 중 오류가 발생했습니다.${NC}"
        return 1
    fi
    
    echo -e "${GREEN}=======================================${NC}"
}


# --- 7. 메인 스크립트 실행 ---
main() {
    clear
    echo -e "${GREEN}=== 카카오톡 자동 병합 및 패치 스크립트 ===${NC}"
    
    # 1. 준비
    check_dependencies
    
    # 2. 버전 선택
    if ! choose_version; then
        echo -e "${YELLOW}[알림] 작업을 취소했습니다.${NC}"
        exit 0
    fi
    
    # 3. 링크 스크래핑
    if ! scrape_download_link; then
        exit 1
    fi
    
    # 4. 다운로드 및 병합
    if ! download_and_merge; then
        exit 1
    fi
    
    # 5. 패치 실행
    if ! run_patch; then
        exit 1
    fi
    
    echo -e "\n${GREEN}========= 모든 작업 완료 =========${NC}"
    echo -e "패치된 파일은 $PATCH_SCRIPT_DIR/out 폴더를 확인하세요."
    echo -e "${GREEN}================================${NC}"
}

# 스크립트 실행
main