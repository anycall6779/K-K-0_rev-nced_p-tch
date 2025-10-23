# ApkMod-Script for Termux

This is a script to select a version of a specific messenger app from apkmirror, merge it, and patch it using `revanced-build-script`.

## Prerequisites (최초 1회 설정)

Before running the script, you must prepare the following tools and repositories in Termux.

1.  **Install Required Packages**
    ```bash
    pkg update && pkg upgrade -y
    pkg install git openjdk-17 python unzip wget dialog jq pup apksigner -y
    ```

2.  **Clone `revanced-build-script` (in Home dir)**
    ```bash
    cd ~
    git clone [https://git.naijun.dev/ReVanced/revanced-build-script.git](https://git.naijun.dev/ReVanced/revanced-build-script.git)
    ```

3.  **Install Python Requirements**
    ```bash
    cd ~/revanced-build-script
    pip install -r requirements.txt
    ```

## Usage (사용법)

1.  Clone this repository:
    ```bash
    # /storage/emulated/0/Download 폴더 또는 원하는 위치로 이동
    cd /storage/emulated/0/Download
    
    # 'ApkMod-Script'라는 이름으로 폴더가 생성됩니다.
    git clone [여기에-이-저장소의-Git-URL] ApkMod-Script
    ```

2.  Run the script:
    ```bash
    cd ApkMod-Script
    chmod +x patch.sh
    ./patch.sh
    ```