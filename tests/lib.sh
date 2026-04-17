# Assertion helpers for the unit test scripts. Source into a runner.
# Tracks pass/fail counts in script-global vars; exits report() non-zero
# if any assertion failed.

tests_pass=0
tests_fail=0

_pass() { tests_pass=$((tests_pass + 1)); printf '    [PASS] %s\n' "$1"; }
_fail() { tests_fail=$((tests_fail + 1)); printf '    [FAIL] %s: %s\n' "$1" "$2" >&2; }

assert_eq() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    _pass "$name"
  else
    _fail "$name" "expected=[$expected] actual=[$actual]"
  fi
}

assert_file_exists() {
  local name="$1" path="$2"
  if [[ -f "$path" ]]; then _pass "$name"; else _fail "$name" "missing: $path"; fi
}

assert_file_absent() {
  local name="$1" path="$2"
  if [[ ! -e "$path" ]]; then _pass "$name"; else _fail "$name" "exists: $path"; fi
}

assert_file_mode() {
  local name="$1" path="$2" expected="$3"
  local actual
  actual=$(stat -c '%a' "$path" 2>/dev/null) || { _fail "$name" "stat failed on $path"; return; }
  if [[ "$actual" == "$expected" ]]; then
    _pass "$name"
  else
    _fail "$name" "expected mode=$expected actual=$actual"
  fi
}

assert_contains() {
  local name="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    _pass "$name"
  else
    _fail "$name" "needle not found: [$needle]"
  fi
}

assert_not_contains() {
  local name="$1" needle="$2" haystack="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    _pass "$name"
  else
    _fail "$name" "needle unexpectedly present: [$needle]"
  fi
}

assert_matches() {
  local name="$1" regex="$2" actual="$3"
  if [[ "$actual" =~ $regex ]]; then
    _pass "$name"
  else
    _fail "$name" "regex=[$regex] actual=[$actual]"
  fi
}

assert_exit_nonzero() {
  local name="$1" rc="$2"
  if [[ "$rc" -ne 0 ]]; then
    _pass "$name"
  else
    _fail "$name" "expected non-zero exit, got 0"
  fi
}

report() {
  printf '\n  results: %d pass, %d fail\n' "$tests_pass" "$tests_fail"
  [[ "$tests_fail" -eq 0 ]]
}
