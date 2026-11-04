#!/bin/bash
# 跨厂（OPPO / 真我 / 小米 / 联想 / 红魔）公开内核源取回。
# 这些厂商的 GitHub 公开仓库是「一个 common 内核快照」（没有 kernel_platform 外层，
# 也没有 AOSP prebuilts），而本流水线整条链是按 kernel_workspace/kernel_platform/common
# 双仓布局写的。所以这里把源码摊平成那个布局，并把 clang 放到 Build Kernel FAST
# 能自动找到的位置（目录名必须以 prebuilts 开头，里面有 clang/host/linux-x86/clang-rXXX/bin）。
#
# 用法: bash fetch_crossvendor_source.sh <FILE> <kernel_workspace 绝对路径> <表文件路径>
# CROSSVENDOR_FETCH_SHIM_v1
set -e

FILE="$1"; WS="$2"; TBL="$3"
[ -d "$WS" ] || { echo "::error::kernel_workspace 不存在：$WS"; exit 1; }
[ -f "$TBL" ] || { echo "::error::跨厂源码表不存在：$TBL"; exit 1; }

LINE=$(grep -m1 "^${FILE}|" "$TBL" || true)
[ -n "$LINE" ] || { echo "::error::跨厂源码表里没有 FILE=${FILE}（现有 $(grep -c '' "$TBL") 行）"; exit 1; }

# FILE|KIND|SRC|CPU|ANDROID|ANDROID_MAJOR|LABEL
IFS='|' read -r NAME KIND SRC CPU ANDROID ANDROID_MAJOR LABEL <<EOF
$LINE
EOF
echo "==== 跨厂源码：$NAME kind=$KIND src=$SRC cpu=$CPU android=$ANDROID ($LABEL) ===="

PLAT="$WS/kernel_platform"
COMMON="$PLAT/common"
if [ -e "$COMMON" ]; then
  echo "::error::$COMMON 已存在，摊平前不该有内容（前面某步提前建了目录？）"
  exit 1
fi
mkdir -p "$PLAT"

STAGE="$WS/.cv_stage"
rm -rf "$STAGE"; mkdir -p "$STAGE"

# 找内核根：必须有 Makefile(VERSION =) 和 arch/arm64/configs/gki_defconfig
find_kernel_root() {
  local BASE=$1 HIT
  HIT=$(find "$BASE" -maxdepth 4 -type f -name Makefile 2>/dev/null | while read -r M; do
          grep -q '^VERSION *=' "$M" && dirname "$M"
        done | head -1)
  [ -n "$HIT" ] || { echo "::error::解压结果里找不到内核根（没有带 VERSION= 的 Makefile）"; exit 1; }
  # Makefile 旁边得有 arm64 配置才算内核根（排除 Documentation/ 里的同名文件）
  if [ ! -d "$HIT/arch/arm64" ]; then
    echo "::error::认出的内核根 $HIT 里没有 arch/arm64，布局不认识"
    exit 1
  fi
  echo "$HIT"
}

case "$KIND" in
  git)
    OWNER_REPO=${SRC%%@*}; REF=${SRC#*@}
    echo "正在 git clone --depth=1 -b '$REF' $OWNER_REPO ..."
    git clone --depth=1 --single-branch -b "$REF" "https://github.com/${OWNER_REPO}" "$STAGE/tree" \
      || { echo "::error::clone 失败：${OWNER_REPO} 分支 ${REF}"; exit 1; }
    ;;
  tar)
    echo "正在下载 tar.gz：$SRC"
    curl -fSL --retry 3 "$SRC" -o "$STAGE/src.tar.gz" || { echo "::error::下载失败：$SRC"; exit 1; }
    ls -l "$STAGE/src.tar.gz"
    mkdir -p "$STAGE/tree"
    tar -xzf "$STAGE/src.tar.gz" -C "$STAGE/tree" || { echo "::error::tar 解包失败"; exit 1; }
    rm -f "$STAGE/src.tar.gz"
    ;;
  *)
    echo "::error::不支持的 KIND=[$KIND]（只认 git / tar）"; exit 1 ;;
esac

ROOT=$(find_kernel_root "$STAGE/tree")
echo "内核根：$ROOT"
mv "$ROOT" "$COMMON"
# 内核根在 tree/<某包装目录> 时，把剩下没搬走的清掉，别让 kernel_workspace 里留垃圾
rm -rf "$STAGE"

KV=$(awk -F'= *' '/^VERSION/{v=$2}/^PATCHLEVEL/{p=$2}/^SUBLEVEL/{s=$2}END{print v"."p"."s}' "$COMMON/Makefile")
echo "源码内核版本：$KV"
echo "CROSSVENDOR_SOURCE: $NAME $SRC -> common ($KV, $LABEL)"

# ---- clang：FAST 步骤靠 "prebuilts* 且里面有 clang/host/linux-x86" 认目录 ----
CLANG_ZIP_URL="https://github.com/cctv18/oneplus_sm8650_toolchain/releases/download/LLVM-Clang18-r510928/clang-r510928.zip"
STUB="prebuilts-clangstub"
DEST="$PLAT/$STUB/clang/host/linux-x86"
# 树里要求的 clang 版本（没有就按 r510928）
ASKED=$(grep -m1 '^CLANG_VERSION=' "$COMMON/build.config.constants" 2>/dev/null | cut -d= -f2 | tr -d '"' || true)
[ -n "$ASKED" ] || ASKED="r510928"
echo "树要求的 clang：$ASKED"

if [ ! -x "$DEST/clang-r510928/bin/clang" ]; then
  mkdir -p "$DEST" "$WS/.clang_dl"
  curl -fSL --retry 3 "$CLANG_ZIP_URL" -o "$WS/.clang_dl/clang.zip" || { echo "::error::clang 下载失败"; exit 1; }
  unzip -q "$WS/.clang_dl/clang.zip" -d "$WS/.clang_dl/x" || { echo "::error::clang 解压失败"; exit 1; }
  REAL=$(find "$WS/.clang_dl/x" -maxdepth 3 -type f -path '*/bin/clang' | head -1)
  [ -n "$REAL" ] || { echo "::error::clang.zip 里找不到 bin/clang"; exit 1; }
  REALDIR=$(dirname "$(dirname "$REAL")")
  BASENAME=$(basename "$REALDIR")
  mv "$REALDIR" "$DEST/"
  echo "clang 就位：$DEST/$BASENAME"
  # 树要求的版本名 ≠ 我们下载的版本名时，补一个同名软链，别去改 build.config 里的版本号
  if [ "$BASENAME" != "$ASKED" ] && [ ! -e "$DEST/$ASKED" ]; then
    ln -sfn "$BASENAME" "$DEST/$ASKED"
    echo "已建别名：$DEST/$ASKED -> $BASENAME"
  fi
  rm -rf "$WS/.clang_dl"
fi

CLANG_BIN_PATH="$STUB/clang/host/linux-x86/${ASKED}/bin"
[ -x "$PLAT/$CLANG_BIN_PATH/clang" ] || { echo "::error::按 $CLANG_BIN_PATH 找不到可执行 clang（FAST 会走错工具链）"; exit 1; }

# 把 build.config 里的 CLANG_PREBUILT_BIN 钉成我们的绝对布局：
# FAST 直接拿它当 bin 目录用，AOSP 那套变量展开在这里没有 prebuilts 仓库会落空。
for f in "$COMMON/build.config.common" "$COMMON/build.config.constants"; do
  [ -f "$f" ] || continue
  if grep -q '^CLANG_PREBUILT_BIN=' "$f"; then
    sed -i "s|^CLANG_PREBUILT_BIN=.*|CLANG_PREBUILT_BIN=$CLANG_BIN_PATH|" "$f"
  else
    printf 'CLANG_PREBUILT_BIN=%s\n' "$CLANG_BIN_PATH" >> "$f"
  fi
  echo "[$(basename "$f")] CLANG_PREBUILT_BIN=$CLANG_BIN_PATH"
done

# 单仓快照没有 kernel_platform/build（官方 build.sh/kleaf 用不到，FAST 里那句
# source _setup_env.sh 是 || true，所以缺了不影响），但缺了会让个别 grep 步骤空转。
[ -d "$PLAT/build" ] || mkdir -p "$PLAT/build"

# 标记 + 后续步骤要用的环境变量
echo "$NAME" > "$WS/.crossvendor_mode"
{
  echo "CV_CPU=$CPU"
  echo "CV_ANDROID=$ANDROID"
  echo "CV_ANDROID_MAJOR=$ANDROID_MAJOR"
  echo "CV_LABEL=$LABEL"
  echo "CV_KVER=$KV"
} >> "$WS/.crossvendor_env"
echo "==== 跨厂源码摊平完成：$COMMON ===="
ls "$COMMON" | head -8
