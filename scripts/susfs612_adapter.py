#!/usr/bin/env python3
"""6.12 专用：把 SUSFS 补丁打不上的两处 SUS_MAP 钩子按**真源码结构**补上。

为什么需要它（实测 run 41588625844）：
- susfs4ksu 的 50_add_susfs_in_gki-android16-6.12.patch 里，show_smap 与
  show_smaps_rollup 的钩子是按 do{}while 结构写的；
- OnePlus 的 android16-6.12 真树里 show_smaps_rollup 用的是 for_each_vma；
- fuzz=0/2 时这两个文件 3 个 hunk 必然失败；fuzz=3 会"零 reject"但把代码
  塞进错误函数，编译报 `fs/proc/task_mmu.c:1516: use of undeclared identifier 'vma'`。

所以：补丁一律 fuzz<=2 应用，然后本脚本按锚点插入，锚点命中次数不对就退出 2，
绝不猜位置。
用法：python3 susfs612_adapter.py <path/to/fs/proc/task_mmu.c>
"""
import sys

MAC = '#ifdef CONFIG_KSU_SUSFS_SUS_MAP'
END = '#endif // #ifdef CONFIG_KSU_SUSFS_SUS_MAP'

ANCHOR_SMAP = (
    'static int show_smap(struct seq_file *m, void *v)\n'
    '{\n'
    '\tstruct vm_area_struct *vma = v;\n'
    '\tstruct mem_size_stats mss = {};\n'
)
INS_SMAP = (
    MAC + '\n'
    '\tif (vma->vm_file) {\n'
    '\t\tif (SUSFS_IS_INODE_SUS_MAP(file_inode(vma->vm_file)))\n'
    '\t\t\treturn 0;\n'
    '\t}\n'
    + END + '\n'
)
GUARD_SMAP = 'if (SUSFS_IS_INODE_SUS_MAP(file_inode(vma->vm_file)))\n\t\t\treturn 0;'

ANCHOR_ROLLUP = '\tfor_each_vma(vmi, vma) {\n'
INS_ROLLUP = (
    MAC + '\n'
    '\t\tif (vma->vm_file && SUSFS_IS_INODE_SUS_MAP(file_inode(vma->vm_file)))\n'
    '\t\t\tcontinue;\n'
    + END + '\n'
)
GUARD_ROLLUP = 'SUSFS_IS_INODE_SUS_MAP(file_inode(vma->vm_file)))\n\t\t\tcontinue;'


def main():
    if len(sys.argv) != 2:
        print('用法: susfs612_adapter.py <fs/proc/task_mmu.c>')
        return 2
    path = sys.argv[1]
    with open(path, encoding='utf-8', errors='surrogateescape') as f:
        src = f.read()

    changed = []

    if GUARD_SMAP not in src:
        n = src.count(ANCHOR_SMAP)
        if n != 1:
            print('::error::show_smap 锚点命中 %d 次（应为 1），拒绝猜测' % n)
            return 2
        src = src.replace(ANCHOR_SMAP, ANCHOR_SMAP + INS_SMAP, 1)
        changed.append('show_smap')

    if GUARD_ROLLUP not in src:
        n = src.count(ANCHOR_ROLLUP)
        if n != 1:
            print('::error::for_each_vma 锚点命中 %d 次（应为 1），拒绝猜测' % n)
            return 2
        src = src.replace(ANCHOR_ROLLUP, ANCHOR_ROLLUP + INS_ROLLUP, 1)
        changed.append('show_smaps_rollup')

    with open(path, 'w', encoding='utf-8', errors='surrogateescape') as f:
        f.write(src)

    n_ref = src.count('SUSFS_IS_INODE_SUS_MAP')
    has_inc = '#include <linux/susfs_def.h>' in src
    print('SUSFS_612_ADAPTER: 补了 %s；SUS_MAP 引用 %d 处；susfs_def.h 包含=%s'
          % (','.join(changed) if changed else '无（本就存在）', n_ref, has_inc))
    if n_ref < 2 or not has_inc:
        print('::error::6.12 SUS_MAP 钩子不完整（引用 %d 处，include=%s）' % (n_ref, has_inc))
        return 2
    return 0


if __name__ == '__main__':
    sys.exit(main())
