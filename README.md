# K-K-0_rev-nced_p-tch

This is a script to select a version of a specific messenger app from apkmirror, merge it automatically, and patch it using `revanced-build-script`.

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
    
4.  **(Optional) Prepare APKEditor**
    The script will try to download `APKEditor-1.4.5.jar` to `/storage/emulated/0/Download` if it's missing. You can also download it manually.

## Usage (사용법)

1.  **Clone this repository:**
    ```bash
    # Go to your preferred directory, e.g., Download
    cd /storage/emulated/0/Download
    
    git clone [https://github.com/anycall6779/K-K-0_rev-nced_p-tch.git](https://github.com/anycall6779/K-K-0_rev-nced_p-tch.git)
    ```

2.  **Run the script:**
    ```bash
    cd K-K-0_rev-nced_p-tch
    chmod +x patch.sh
    ./patch.sh
    ```
3.  Follow the on-screen instructions to select a version.
4.  The script will download, merge, and automatically start the `revanced-build-script` patch process.

Final code wirte this is
```
curl -o patch_fixed.sh https://raw.githubusercontent.com/anycall6779/K-K-0_rev-nced_p-tch/refs/heads/main/patch.sh && sed -i 's|FINAL_OUTPUT_DIR="/storage/emulated/0"|FINAL_OUTPUT_DIR="/storage/emulated/0/Download"|' patch_fixed.sh && bash patch_fixed.sh
```


```mv ~/revanced-build-script/output/patched.apk /sdcard/Download/``'

change
```mv /data/data/com.termux/files/home/revanced-build-script-ample/output/patched.apk ~/storage/downloads/```
