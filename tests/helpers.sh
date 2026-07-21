#!/usr/bin/env bash
# 极简断言库。失败即打印并退出非零。
TESTS_PASSED=0

assert_eq() {  # 实际值 期望值 说明
  if [[ "$1" == "$2" ]]; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    echo "FAIL: $3 — 期望 [$2]，实际 [$1]" >&2
    exit 1
  fi
}

assert_contains() {  # 内容 子串 说明
  if printf '%s' "$1" | grep -qF -- "$2"; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    echo "FAIL: $3 — 未找到子串 [$2]，内容: [$1]" >&2
    exit 1
  fi
}

assert_not_contains() {  # 内容 子串 说明
  if printf '%s' "$1" | grep -qF -- "$2"; then
    echo "FAIL: $3 — 不应出现子串 [$2]" >&2
    exit 1
  else
    TESTS_PASSED=$((TESTS_PASSED + 1))
  fi
}

assert_rc() { assert_eq "$1" "$2" "$3"; }

report() { echo "OK: ${TESTS_PASSED} 个断言通过（$0）"; }
