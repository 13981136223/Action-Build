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

# 找内核根：必须有 Makefile(VERSION =) 和 arch/arm64
# 不能写成 `... | head -1`：find 出来多个候选时 head 先退场，dirname 收到 SIGPIPE
# 就以非 0 退出，set -e 直接把整步杀掉（realme_gt7pro 那轮日志里一排 "dirname: Broken pipe"）。
find_kernel_root() {
  local BASE=$1 M
  for M in $(find "$BASE" -maxdepth 4 -type f -name Makefile 2>/dev/null); do
    if grep -q '^VERSION *=' "$M" 2>/dev/null; then
      local D=$(dirname "$M")
      if [ -d "$D/arch/arm64" ]; then echo "$D"; return 0; fi
    fi
  done
  echo "::error::解压结果里找不到带 arch/arm64 的内核根（Makefile 有 VERSION= 的那种）" >&2
  return 1
}

# 公开的 common 快照只开园内核，vendor 侧目录（kernel/oplus_cpu/sched 等）常常整块缺席。
# Kconfig 里那行 source "kernel/oplus_cpu/sched/Kconfig" 就会让 gki_defconfig 直接
# "can't open file" Error 1（realme gtneo6/gt6 实测）；Makefile 里 obj-y += 缺失目录同理会炸。
# 这里只注释「指向不存在路径」的那几行，指向存在文件的一律不动。
strip_dangling_refs() {
  # 只治「Kconfig source 指向不存在的文件」这一种实测会炸的情况
  # （init/Kconfig: can't open file "kernel/oplus_cpu/sched/Kconfig" → gki_defconfig Error 1）。
  # 之前顺手改写 Makefile 里 obj-y 的缺失目录，实测同一棵树（cv_oppo_sm8735_66 / mt6993_612 /
  # mt6789_612）改前 19-33 分钟出包、改后 148 分钟还没编完 —— 那部分改写不是需要的修复，是新增风险，撤掉。
  # 另外：全树没有打不开的 source 时一个字节都不改（不做无谓的读写，也不动 mtime）。
  python3 - "$COMMON" <<'PY'
import os, re, sys
root = sys.argv[1]
src = re.compile(r'^(\s*)source\s+"([^"]+)"')
todo = []
for dirpath, dirs, files in os.walk(root):
    if 'out' in dirs:
        dirs.remove('out')
    for f in files:
        if not (f == 'Kconfig' or f.startswith('Kconfig.')):
            continue
        p = os.path.join(dirpath, f)
        lines = open(p, encoding='utf-8', errors='replace').read().split('\n')
        hits = []
        for i, l in enumerate(lines):
            m = src.match(l)
            if not m:
                continue
            t = m.group(2)
            # 关键：带 make 变量的 source（arch/$(SRCARCH)/Kconfig、$(KCONFIG_EXT_PREFIX)Kconfig.ext…）
            # 根本不是"文件不存在"，而是 kbuild 在展开时才解析。CV 诊断跑（run 41979260668）实测
            # 把 arch/$(SRCARCH)/Kconfig 等 4 条正常 source 注释掉了 —— 等于删掉整个 arch 的 Kconfig，
            # 结果 gki_defconfig 直接崩、编出来的 .config 面目全非、构建 130 分钟都编不完。
            if '$' in t:
                continue
            if os.path.exists(os.path.join(root, t)) or os.path.exists(os.path.join(dirpath, t)):
                continue
            hits.append((i, m.group(1) + '# CVSHIM ' + l.strip(), t))
        if hits:
            todo.append((p, lines, hits))
if not todo:
    print('CVSHIM: 没有打不开的 Kconfig source，源码一个字节都没改')
else:
    n = 0
    for p, lines, hits in todo:
        for i, new, _ in hits:
            lines[i] = new
        open(p, 'w', encoding='utf-8').write('\n'.join(lines))
        n += len(hits)
        print('CVSHIM 注释 %s：%s' % (os.path.relpath(p, root), ', '.join(t for _, _, t in hits)))
    print('CVSHIM: 共注释 %d 处' % n)
PY
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

ROOT=$(find_kernel_root "$STAGE/tree") || exit 1
echo "内核根：$ROOT"
mv "$ROOT" "$COMMON"
# 单仓快照里 vendor 侧目录缺失，先把打不开的 source/obj-y 注释掉（必须在打 susfs/KernelSU 补丁之前）
strip_dangling_refs
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
