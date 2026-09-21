#!/bin/sh
# ═════════════════════════════════════════════════════════════════════════════
# pre-commit 钩子自测
#   在**独立的临时仓库**里验证「该拦的拦、该放的放」，绝不触碰 ZenFile 仓库本身。
#   改动 pre-commit 之后请务必跑一遍（钩子出错的代价是所有人的提交被卡住）：
#
#       sh scripts/git-hooks/selftest.sh
#
#   退出码 0 = 三项期望全部满足。
# ═════════════════════════════════════════════════════════════════════════════

here=${0%/*}
# 转成绝对路径：后面要 cd 进临时仓库，相对路径会失效（且本机 dirname 不一定在 PATH 上）
case "$here" in
  /*) : ;;
  *) here="$(pwd)/$here" ;;
esac
hook="$here/pre-commit"

tmp_base=${TMPDIR:-/tmp}
w="$tmp_base/zf_precommit_selftest_$$"
rm -rf "$w"
mkdir -p "$w/lib/core"
cd "$w" || exit 9

git init -q
git config user.email selftest@local
git config user.name selftest
git config core.autocrlf false

cat > lib/core/utils.dart <<'DART'
class FileUtils {
  static int a() => 1;
}
DART
cat > lib/b.dart <<'DART'
void f() { FileUtils.a(); }
DART
git add -A
git commit -q -m init

fail=0

check() {
  desc="$1"
  expect="$2"
  sh "$hook" >/dev/null 2>&1
  code=$?
  if [ "$code" -eq "$expect" ]; then
    echo "PASS  $desc （exit=$code）"
  else
    echo "FAIL  $desc —— 期望 exit=$expect，实际 exit=$code"
    fail=1
  fi
}

echo "--- 场景 C：索引完整（引用与定义都在索引里）"
check "应放行" 0

echo "--- 场景 A：只暂存调用方，新增方法的定义留在工作区（= 368a5fe 事故形态）"
cat > lib/core/utils.dart <<'DART'
class FileUtils {
  static int a() => 1;
  static int c() => 3;
}
DART
cat > lib/b.dart <<'DART'
void f() { FileUtils.a(); FileUtils.c(); }
DART
git add lib/b.dart
check "应阻止" 1

echo "--- 场景 B：把定义文件也暂存"
git add lib/core/utils.dart
check "应放行" 0

echo "--- 场景 D：引用的是常量/字段（不是方法）——早期版本会误判为未定义、卡住正常提交"
cat > lib/core/utils.dart <<'DART'
class FileUtils {
  static int a() => 1;
  static int c() => 3;
  static const List<String> exts = ['.apk'];
}
DART
cat > lib/b.dart <<'DART'
void f() { FileUtils.a(); FileUtils.c(); if (FileUtils.exts.isEmpty) {} }
DART
git add lib/core/utils.dart lib/b.dart
check "应放行（常量定义已在索引里）" 0

echo "--- 场景 E：常量定义留在工作区，只暂存调用方 → 仍应阻止"
cat > lib/core/utils.dart <<'DART'
class FileUtils {
  static int a() => 1;
  static int c() => 3;
}
DART
git add lib/core/utils.dart
check "应阻止" 1

cd /
rm -rf "$w"

if [ "$fail" -eq 0 ]; then
  echo "全部通过 ✅"
else
  echo "存在失败 ❌"
fi
exit "$fail"
