#!/usr/bin/env bash
# 有些树里（实测 oneplus_pad_mt6897_v，MTK kernel-6.1.128），migration_inline.h 把
# VMA_PAD_START 定义成 `(vma->vm_end - (vma_pad_pages(vma) << PAGE_SHIFT))`，
# 但这棵树没有 vma_pad_pages 的实现 → 开编即死：
#   fs/proc/task_mmu.c:311: error: call to undeclared function 'vma_pad_pages'
# 同一行日志还给出关键事实：宏 VMA_PAD_START 的上一处定义就是 ((vma)->vm_end)，
# 即这台机器"页填充"本来就是 0 页。补一个返回 0 的等价物，不改任何行为；
# 有真实现的树一个字节都不碰。
# 2026-11-04 三次失败的教训：upstream 克隆里的 SusfsCompat.kts 也会补 VMA_PAD_START，
# 但它补的那份不含 vma_pad_pages，且它来自别人仓库、改不动 → 这里必须自己兜底。
set -u
WS=${1:-"$PWD/kernel_workspace"}
[ -d "$WS" ] || { echo "::error::找不到 $WS"; exit 1; }

has_real_impl() {
  grep -rn --include='*.h' --include='*.c' -E 'unsigned long[[:space:]]+vma_pad_pages[[:space:]]*\(' "$WS" 2>/dev/null | grep -q .
}

# ---- 阶段一：migration_inline.h 存在且引用 vma_pad_pages，但全树没有实现 ----
HITS=$(find -L "$WS" -type f -name 'migration_inline.h' 2>/dev/null)
if [ -n "$HITS" ]; then
  NEED=0
  for H in $HITS; do grep -q 'vma_pad_pages' "$H" && NEED=1; done
  if [ "$NEED" = "1" ] && ! has_real_impl; then
    for H in $HITS; do
      grep -q 'vma_pad_pages' "$H" || continue
      grep -q 'KSU_VMA_PAD_PAGES_SHIM' "$H" && { echo "[已补过] $H"; continue; }
      FIRST=$(grep -n 'vma_pad_pages' "$H" | head -1 | cut -d: -f1)
      [ -n "$FIRST" ] || { echo "::error::$H 找不到使用行"; exit 1; }
      {
        head -n $((FIRST - 1)) "$H"
        printf '#ifndef KSU_VMA_PAD_PAGES_SHIM\n#define KSU_VMA_PAD_PAGES_SHIM\nstatic inline unsigned long vma_pad_pages(const struct vm_area_struct *vma) { return 0; }\n#endif\n'
        tail -n +"$FIRST" "$H"
      } > "$H.ksushim" && mv "$H.ksushim" "$H"
      grep -q 'static inline unsigned long vma_pad_pages' "$H" || { echo "::error::$H shim 行没落地"; exit 1; }
      echo "[已补 inline] $H 第 $FIRST 行前"
    done
  elif [ "$NEED" = "1" ]; then
    echo "VMA_PAD_SHIM: 树里已有真实现，跳过 inline 补丁"
  else
    echo "VMA_PAD_SHIM: migration_inline.h 里没引用 vma_pad_pages"
  fi
else
  echo "VMA_PAD_SHIM: 树里没有 migration_inline.h"
fi

# ---- 阶段二：task_mmu.c 用了 VMA_PAD_START，但全树没有 vma_pad_pages 实现 ----
# 不依赖任何上游脚本：直接给 task_mmu.c 顶部塞函数式宏（不需要类型声明，
# 展开成 0UL，与 ((vma)->vm_end) 等价）。
PATCHED=0
for TM in $(find -L "$WS" -type f -path '*/fs/proc/task_mmu.c' 2>/dev/null); do
  grep -q 'VMA_PAD_START(' "$TM" || continue
  grep -q 'pgsize_migration' "$TM" && { echo "[已包含 pgsize 头] $TM"; continue; }
  # 首选：树里自带 include/linux/pgsize_migration.h（实测 mt6991/sm8755 系都有），
  # 它按 CONFIG 给出 extern 或返回 0 的 static inline —— 直接用，签名不用猜。
  HDR=$(find -L "$WS" -type f -path '*/include/linux/pgsize_migration.h' 2>/dev/null | head -1)
  if [ -n "$HDR" ]; then
    grep -q 'vma_pad_pages' "$HDR" || { echo "::warning::$HDR 里没有 vma_pad_pages，退回宏方案"; HDR=""; }
  fi
  NOTE=""
  if [ -n "$HDR" ]; then
    NOTE="[已补 include] $TM ← <linux/pgsize_migration.h>"
    { head -n 1 "$TM"; printf '#include <linux/pgsize_migration.h>\n'; tail -n +2 "$TM"; } > "$TM.ksushim2"
  else
    NOTE="[已补宏] $TM（树里没有 pgsize_migration.h）"
    { head -n 1 "$TM"; printf '#ifndef vma_pad_pages\n#define vma_pad_pages(vma) 0UL\n#endif\n'; tail -n +2 "$TM"; } > "$TM.ksushim2"
  fi
  mv "$TM.ksushim2" "$TM"
  grep -qE 'pgsize_migration|define vma_pad_pages' "$TM" || { echo "::error::补丁未落地 $TM"; exit 1; }
  echo "$NOTE（$(wc -c < "$TM") B）"
  PATCHED=1
done
[ "$PATCHED" = "1" ] || echo "VMA_PAD_SHIM: 未触发 task_mmu.c 补丁（不需要）"

# ---- 阶段三：树里没有 pgsize_migration.h 时才用 -include 宏兜底 ----
# 有那头的树已经在阶段二 include 进来了，再补宏会跟真实 inline 撞定义，所以这里必须互斥。
PGHDR=$(find -L "$WS" -type f -path '*/include/linux/pgsize_migration.h' 2>/dev/null | head -1)
if [ -z "$PGHDR" ] && ! has_real_impl; then
  HDR="$WS/.ksu_vma_pad_include.h"
  printf '/* injected by vma_pad_shim.sh */\n#ifndef vma_pad_pages\n#define vma_pad_pages(vma) 0UL\n#endif\n' > "$HDR"
  echo "$HDR" > "$WS/.ksu_vma_pad_include"
  echo "[-include 标记] $WS/.ksu_vma_pad_include → $HDR"
else
  rm -f "$WS/.ksu_vma_pad_include" 2>/dev/null || true
fi

echo "VMA_PAD_SHIM: 完成"
