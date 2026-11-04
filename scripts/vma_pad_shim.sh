#!/usr/bin/env bash
# 有些树（实测 oneplus_pad_mt6897_v，MTK kernel-6.1.128）里 rekernel 带的
# include/linux/migration_inline.h 用了 vma_pad_pages()，但这棵树本身没这个函数，
# 于是开编就死：
#   fs/proc/task_mmu.c:311:11: error: call to undeclared function 'vma_pad_pages'
# 同一行日志还给出关键事实：宏 VMA_PAD_START 的**上一处定义**就是 ((vma)->vm_end)，
# 也就是说这台机器上"页填充"本来就是 0 页。补一个返回 0 的 static inline，
# 展开结果与原厂定义逐字相同，不改变任何行为；有真实现的树一个字节都不碰。
set -u
WS=${1:-"$PWD/kernel_workspace"}
[ -d "$WS" ] || { echo "::error::找不到 $WS"; exit 1; }

HITS=$(find -L "$WS" -type f -name 'migration_inline.h' 2>/dev/null)
[ -n "$HITS" ] || { echo "VMA_PAD_SHIM: 树里没有 migration_inline.h，无事可做"; exit 0; }

NEED=0
for H in $HITS; do
  grep -q 'vma_pad_pages' "$H" || continue
  NEED=1
done
[ "$NEED" = "1" ] || { echo "VMA_PAD_SHIM: migration_inline.h 里没引用 vma_pad_pages，无事可做"; exit 0; }

# 只有"全树没有任何 vma_pad_pages 的定义/声明"时才补，否则会撞重复定义
DECL=$(grep -rn --include='*.h' --include='*.c' -E '(^|[[:space:]])vma_pad_pages[[:space:]]*\(' "$WS" 2>/dev/null \
  | grep -vE 'vma_pad_pages\(vma\)|vma_pad_pages\(\$?\{?[a-z_]*\}\?\)[[:space:]]*<<' \
  | grep -E 'unsigned long|static inline|#define' | head -1)
if [ -n "$DECL" ]; then
  echo "VMA_PAD_SHIM: 树里已有定义，不补 → ${DECL:0:150}"
  exit 0
fi

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
  grep -q 'KSU_VMA_PAD_PAGES_SHIM' "$H" || { echo "::error::$H 补完找不到 shim 标记"; exit 1; }
  grep -q 'static inline unsigned long vma_pad_pages' "$H" || { echo "::error::$H shim 行没落地"; exit 1; }
  echo "[已补] $H 第 $FIRST 行前插入返回 0 的 vma_pad_pages（$(wc -c < "$H") B）"
done
echo "VMA_PAD_SHIM: 完成"
