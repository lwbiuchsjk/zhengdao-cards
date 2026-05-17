#!/usr/bin/env python3
"""
Design submodule 模式检查脚本

背景：Design 是 Windows junction，WSL git 会把它识别为 symlink（120000），
     Windows git 识别为 submodule（160000）。WSL 端的 `git add Design`
     会错误地把 Design 记录为 symlink，破坏 submodule 跟踪状态。

功能：检查即将提交的 staged changes 中，Design 条目是否被记录为 symlink（120000）。
     如果是，阻断提交并提示修正方法。

用法：
  python tools/check_design_submodule.py     # 检查 staged 状态（pre-commit 使用）

退出码：
  0 — Design 未在此次提交中，或已正确记录为 160000
  1 — Design 被错误记录为 symlink，阻断提交
"""

import subprocess
import sys


def get_staged_design_mode() -> str | None:
    """读取 staged 中 Design 条目的 mode。

    返回值：
      "160000" — 正确的 submodule gitlink
      "120000" — 错误的 symlink（WSL 识别 junction 产生）
      None — Design 不在本次提交的 staged 变更中
    """
    # git diff --cached --raw 输出格式（简化）：
    # :<src_mode> <dst_mode> <src_hash> <dst_hash> <status>\t<path>
    # 删除类：dst_mode = 000000
    # 新增类：src_mode = 000000
    # 我们关心 dst_mode（本次提交后的模式）。
    result = subprocess.run(
        ["git", "diff", "--cached", "--raw", "--", "Design"],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        return None
    output = result.stdout.strip()
    if not output:
        return None
    # 可能有多行（typechange 输出两行：删除旧模式 + 新增新模式），取最后一行的 dst_mode。
    for line in output.splitlines():
        if not line.startswith(":"):
            continue
        parts = line.split()
        if len(parts) < 5:
            continue
        dst_mode = parts[1]
        # 跳过删除行（dst_mode = 000000）
        if dst_mode == "000000":
            continue
        return dst_mode
    return None


def main() -> int:
    mode = get_staged_design_mode()
    if mode is None:
        # Design 不在本次提交中，放行。
        return 0
    if mode == "160000":
        # 正确：submodule gitlink。
        return 0
    if mode == "120000":
        print("✗ Design 被错误记录为 symlink（mode 120000），应为 submodule（mode 160000）")
        print("  原因：WSL git 将 Windows junction 识别为 symlink，`git add Design` 会覆盖 submodule 跟踪。")
        print("")
        print("  修正方法：")
        print("    git rm --cached Design")
        print("    git update-index --add --cacheinfo 160000,<Design 仓库 HEAD hash>,Design")
        print("    # <Design 仓库 HEAD hash> 可通过 `cd Design && git rev-parse HEAD` 获取")
        return 1
    # 其他未知 mode（例如 100644 blob），也阻断。
    print(f"✗ Design 被记录为未预期的 mode: {mode}（应为 160000）")
    return 1


if __name__ == "__main__":
    sys.exit(main())
