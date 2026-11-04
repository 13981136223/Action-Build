#!/usr/bin/env bash
# 开编之前确保 drivers/kernelsu/preinit/runner/runner.c 真的在场。
# 为什么放在这里而不是 SukiSU 装完之后那一步：run 41733417741 的现场打印说明
# 「修复时两处都报已就位，开编前整个 preinit 里一个 runner.c 都没有」——
# 说明中间有人重排过树（setup.sh 之后还有步骤在动 drivers/kernelsu）。
# 补的来源优先用 KernelSU 自己的克隆（kernel_platform/KernelSU/kernel/preinit/…），
# 两种上游布局都试：tiann 的 preinit/runner，和 SukiSU 的 preinit/common/runner。
set -u
WS=${1:-"$PWD/kernel_workspace"}
KP="$WS/kernel_platform"
[ -d "$KP" ] || { echo "::error::找不到 $KP"; exit 1; }

KSU=""
for C in "$KP/KernelSU/kernel" "$KP/KernelSU" "$KP/preinit/kernel"; do
  [ -d "$C/preinit" ] && { KSU="$C"; break; }
done
echo "[源] KernelSU 克隆的 preinit = ${KSU:-没找到}"

fixed=0
for PRE in $(find -L "$KP" -type d -name preinit 2>/dev/null); do
  if [ -f "$PRE/runner/runner.c" ]; then
    echo "[在场] $PRE/runner/runner.c"
    continue
  fi
  SRC=""
  for C in "$PRE/common/runner" ${KSU:+$KSU/preinit/runner} ${KSU:+$KSU/preinit/common/runner}; do
    [ -f "$C/runner.c" ] && { SRC="$C"; break; }
  done
  if [ -z "$SRC" ]; then
    echo "::error::$PRE 缺 runner/runner.c，且四个来源里一个都没有（$PRE/common/runner、$KSU/preinit/runner、$KSU/preinit/common/runner）"
    exit 1
  fi
  mkdir -p "$PRE/runner"
  cp -rL "$SRC"/. "$PRE/runner"/
  [ -f "$PRE/runner/runner.c" ] || { echo "::error::从 $SRC 复制后仍缺 $PRE/runner/runner.c"; exit 1; }
  echo "[补齐] $SRC → $PRE/runner（runner.c $(wc -c < "$PRE/runner/runner.c") B）"
  fixed=$((fixed+1))
done

# 硬断：谁引用 runner 就必须能对上，不然 make 只会甩一句 No rule
miss=0
for K in $(find -L "$KP" -type f \( -name Makefile -o -name Kbuild \) -path '*/drivers/kernelsu/*' 2>/dev/null); do
  grep -qE 'runner/runner\.c|runner\.elf' "$K" || continue
  P=$(dirname "$K")
  case "$P" in */preinit) D="$P/runner/runner.c";; *) D="$P/preinit/runner/runner.c";; esac
  if [ ! -f "$D" ]; then echo "::error::$K 引用 runner 但 $D 不在"; miss=1; fi
done
[ "$miss" = "0" ] || exit 1
# 关键：make 报的是 "../../drivers/kernelsu/preinit/runner/runner.c"，而 make[5] 的工作目录是
# 输出树 $O/drivers/kernelsu/preinit —— 从那儿数 ../../ 落回 $O/drivers/...，也就是它要的是
# **out 树里**的 runner.c（run 41738160219：源树里已备好、保障步的硬断也过了，make 仍说 No rule）。
# 所以同一份 runner.c 也要铺到对应的 out 路径（out 目录此刻可以不存在，mkdir -p 建出来即可）。
for PRE in $(find -L "$KP" -type d -name preinit 2>/dev/null); do
  [ -f "$PRE/runner/runner.c" ] || continue
  TOP=${PRE%/drivers/kernelsu/preinit}          # 该树的根（common/ 或 kernel-6.12/）
  OUT="$TOP/out/drivers/kernelsu/preinit/runner"
  if [ -f "$OUT/runner.c" ]; then
    echo "[out 树已有] $OUT/runner.c"
  elif mkdir -p "$OUT" 2>/dev/null && cp -rL "$PRE/runner/." "$OUT/" 2>/dev/null; then
    echo "[铺到 out 树] $PRE/runner/runner.c → $OUT/runner.c"
  else
    echo "::error::铺不进 $OUT"
    exit 1
  fi
done

# 最后一条兜底，且不依赖我猜 O= 是哪个目录：把那条规则里的相对依赖改写成绝对形式。
# make 报 `No rule to make target '../../drivers/kernelsu/preinit/runner/runner.c'`，
# 而源树、out 树两处我都铺了文件、硬断也过了它照样报 —— 说明 `../../` 是从某个我猜不到的
# 输出目录（Kleaf/bazel 的 execroot）数上去的。改成 `$(srctree)/drivers/...` 就跟 O= 无关了。
# 上一版只在 */drivers/kernelsu/* 里的 Makefile/Kbuild 找那句相对依赖 —— 保障步没打印
# [依赖改绝对]，说明声明 `../../drivers/kernelsu/preinit/runner/runner.c` 的文件根本不在那个范围里
# （run 41748265605 仍报同一句 No rule）。改成在全树找这个字面量，找到就改，找不到就点名，
# 不再靠我猜它写在哪个文件。
HITS=$(grep -rlF -- '../../drivers/kernelsu/preinit/' "$KP" 2>/dev/null || true)
if [ -z "$HITS" ]; then
  echo "[无相对依赖] 全树没有 ../../drivers/kernelsu/preinit/ 字面量（6.1/6.6 就这样，正常：没有这条规则就不用改，不能当成错误）"
fi
for K in $HITS; do
  sed -i 's#\.\./\.\./drivers/kernelsu/preinit/#$(srctree)/drivers/kernelsu/preinit/#g' "$K"
  grep -qF 'srctree)/drivers/kernelsu/preinit/' "$K" || { echo "::error::$K 改写失败"; exit 1; }
  echo "[依赖改绝对] $K（$(grep -cF 'srctree)/drivers/kernelsu/preinit/' "$K") 处）"
done
# 改完必须一个残留都不留，否则 make 还会从相对路径去找
if grep -rlF -- '../../drivers/kernelsu/preinit/' "$KP" 2>/dev/null | grep -q .; then
  echo "::error::仍有残留的相对依赖：$(grep -rlF -- '../../drivers/kernelsu/preinit/' "$KP" 2>/dev/null | tr '\n' ' ')"
  exit 1
fi
# 上游 kernel/Makefile 的第 7-11 行是个二选一：
#   ifeq ($(filter /%,$(src)),)  → KSU_KERNEL_DIR := $(srctree)/$(src)
#   else                         → KSU_KERNEL_DIR := $(src)
# 实测（run 41773078323，sha 0c2c9ae53）：走的是**第一条**，而这一层递归里 $(srctree) 展开成
# 相对串 "../.."，所以 $(KSU_KERNEL_DIR) = "../../drivers/kernelsu" —— 上一版把第二条改成
# $(srctree)/$(src) 等于什么都没改：两条最终都是同一个相对值。这就是"改完了还是同样报错"的原因。
# make 打印的目标是 drivers/kernelsu/preinit/runner.elf（相对 objtree），说明它的 CWD 是 objtree 根，
# 于是 "../../drivers/kernelsu/…" 落到 kernel_platform 这一层（或再往上一层）——那里没有 drivers/ 目录。
for M in $(find -L "$KP" -type f -path '*/drivers/kernelsu/Makefile' 2>/dev/null); do
  grep -qxF 'KSU_KERNEL_DIR := $(src)' "$M" || continue
  awk '{ if ($0 == "KSU_KERNEL_DIR := $(src)") print "KSU_KERNEL_DIR := $(srctree)/$(src)"; else print }' "$M" > "$M.tmp" && mv "$M.tmp" "$M"
  echo "[定义统一] $M（真正生效的是下面那条命令行覆盖，这里只是不再依赖分支）"
done

# 决定性修复一：把 KSU_KERNEL_DIR 用命令行钉成绝对路径。命令行赋值优先于 Makefile 里的 :=，
# 上游那个 ifeq/else 无论走哪条都被覆盖，展开结果不再依赖 $(srctree) 是绝对还是相对。
COMMON_REAL=$(readlink -f "$KP/common" 2>/dev/null)
[ -n "$COMMON_REAL" ] && [ -d "$COMMON_REAL" ] || { echo "::error::读不到 common 的真实目录"; exit 1; }
KSU_DIR="$COMMON_REAL/drivers/kernelsu"
[ -f "$KSU_DIR/preinit/runner/runner.c" ] || { echo "::error::给命令行的绝对目录里缺 runner.c：$KSU_DIR"; exit 1; }
echo "KSU_KERNEL_DIR_ABS=$KSU_DIR" > "$WS/.ksu_kernelsu_dir"
echo "[命令行覆盖] 写入 $WS/.ksu_kernelsu_dir → $KSU_DIR"

# 决定性修复二：Makefile 里另有 -I$(srctree)/drivers/kernelsu 这类硬编码（上游 15-16 行自己承认
# 6.12 下 $(src) 变绝对才硬编码的）。同一个相对 $(srctree) 会让这些引用也指到 kernel_platform 这层。
# 于是把 ../../drivers 这一层"补"出来：只在该位置本来没有 drivers 时才建符号链接，绝不覆盖已有目录。
for BASE in "$KP" "$(dirname "$KP")"; do
  if [ -e "$BASE/drivers" ]; then
    echo "[补路径跳过] $BASE/drivers 已存在（$(test -L "$BASE/drivers" && echo 符号链接 || echo 真目录)）"
    continue
  fi
  ln -s "$COMMON_REAL" "$BASE/drivers" || { echo "::error::无法在 $BASE 建 drivers 链接"; exit 1; }
  echo "[补路径] $BASE/drivers -> $COMMON_REAL"
done
for BASE in "$KP" "$(dirname "$KP")"; do
  [ -f "$BASE/drivers/kernelsu/preinit/runner/runner.c" ] && echo "[可达] $BASE/drivers/kernelsu/preinit/runner/runner.c"
done
grep -qxF 'KSU_KERNEL_DIR := $(src)' <(find -L "$KP" -type f -path '*/drivers/kernelsu/Makefile' -exec cat {} + 2>/dev/null) \
  && { echo "::error::仍有相对定义残留"; exit 1; }

echo "ENSURE_PREINIT: 补齐 $fixed 处，引用与文件全部对得上"
