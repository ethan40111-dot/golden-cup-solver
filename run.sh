#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
usage() { printf '%s\n' 'Usage: bash run.sh [--check | --probe | --dry-run | --answers]' 'Optional: CODEX_MODEL (default gpt-6.2-sol), CODEX_EFFORT (default xhigh), CODEX_FAST (default 1), CODEX_SANDBOX (default danger-full-access), CODEX_BIN_DIR, HDFS_TEST_PATH'; }
mode="${1:-solve}"
[[ $# -le 1 ]] || fail 'too many arguments'
case "$mode" in solve|--check|--probe|--dry-run|--answers) ;; -h|--help) usage; exit 0;; *) fail 'unknown argument';; esac


# Print only verified, published NN.txt answers; no Codex invocation or data rescan.
show_answers() {
    local marker=answers/.questions.sha256 fingerprint recorded file nn check actual
    local shown=0 skipped=0
    if [[ ! -d answers || -L answers ]]; then
        printf 'No published answers found.\n'
        return 0
    fi
    if [[ ! -f questions.txt || ! -f "$marker" || -L "$marker" ]]; then
        printf 'WARNING: question fingerprint unavailable; refusing to display unverified answers.\n' >&2
        return 1
    fi
    fingerprint=$(sha256sum -- questions.txt); fingerprint=${fingerprint%% *}
    recorded=$(<"$marker")
    if [[ "$fingerprint" != "$recorded" ]]; then
        printf 'WARNING: questions.txt differs from the answers fingerprint; no answers displayed.\n' >&2
        return 1
    fi
    printf '\n========== FINAL ANSWERS ==========\n'
    for file in answers/[0-9][0-9].txt; do
        [[ -e "$file" ]] || continue
        nn=${file##*/}; nn=${nn%.txt}
        check="answers/$nn.check.txt"
        if [[ ! -f "$file" || -L "$file" || ! -s "$file" || ! -f "$check" || -L "$check" || ! -s "$check" ]]; then
            ((skipped+=1)); continue
        fi
        # Machine-readable verdicts prevent natural-language/first-line false negatives.
        # Accept the original v0.6 one-line verdict for existing workspaces.
        if grep -Eq '驗證失敗|驗證未通過|暫不提交|不建議提交|不得提交|VERIFICATION_STATUS=(FAIL|BLOCKED)|SUBMISSION_STATUS=(NO|BLOCKED)' "$check"; then
            ((skipped+=1)); continue
        fi
        if ! { grep -Fxq 'VERIFICATION_STATUS=PASS' "$check" && \
               grep -Fxq 'SUBMISSION_STATUS=READY' "$check"; } && \
           ! grep -Eq '^驗證通過.*建議提交' "$check"; then
            ((skipped+=1)); continue
        fi
        if grep -Fq 'questions.txt SHA256:' "$check" && ! grep -Fxq "questions.txt SHA256: $fingerprint" "$check"; then
            ((skipped+=1)); continue
        fi
        if grep -Fq '答案 SHA256:' "$check"; then
            actual=$(sha256sum -- "$file"); actual=${actual%% *}
            if ! grep -Fxq "答案 SHA256: $actual" "$check"; then
                ((skipped+=1)); continue
            fi
        fi
        printf '\n[Q%s]\n' "$nn"
        cat -- "$file"
        printf '\n'
        ((shown+=1))
    done
    printf '===================================\nPublished: %d' "$shown"
    if ((skipped > 0)); then printf ' | Skipped (unverified): %d' "$skipped"; fi
    printf '\n'
}

# Answer-only access works even if the Codex executable is unavailable.
if [[ "$mode" == --answers ]]; then
    show_answers
    exit $?
fi

# Only this process and its children: preserve the original Hadoop/Java PATH.
if [[ -n "${CODEX_BIN_DIR:-}" ]]; then
    export PATH="$CODEX_BIN_DIR:$PATH"
fi
if ! command -v codex >/dev/null 2>&1; then
    for dir in "$HOME/.local/bin" "$HOME/.npm-global/bin" "$HOME/.codex/bin"; do
        if [[ -x "$dir/codex" ]]; then export PATH="$dir:$PATH"; break; fi
    done
fi
command -v codex >/dev/null 2>&1 || fail 'codex not found; install official CLI or set CODEX_BIN_DIR to its directory'
[[ -s AGENTS.md ]] || fail 'AGENTS.md missing or empty'

if [[ "$mode" == --check ]]; then
    printf 'Codex: '; command -v codex
    codex --version
    printf 'TERM: %s\n' "${TERM:-unset}"
    printf 'Workdir: %s\n' "$PWD"
    printf 'Login status:\n'; codex login status
    for tool in python3 hdfs hadoop hive beeline pig; do
        if command -v "$tool" >/dev/null 2>&1; then printf '%s: %s\n' "$tool" "$(command -v "$tool")"; else printf '%s: not found (optional tool)\n' "$tool"; fi
    done
    printf 'Check complete. Run --probe to test actual tool execution.\n'
    exit 0
fi

sandbox="${CODEX_SANDBOX:-danger-full-access}"
case "$sandbox" in danger-full-access|workspace-write) ;; *) fail 'CODEX_SANDBOX must be danger-full-access or workspace-write';; esac
effort="${CODEX_EFFORT:-xhigh}"
case "$effort" in low|medium|high|xhigh|default) ;; *) fail 'invalid CODEX_EFFORT';; esac
fast="${CODEX_FAST:-1}"
case "$fast" in 0|1|default) ;; *) fail 'CODEX_FAST must be 0, 1, or default';; esac
args=(exec --sandbox "$sandbox" --skip-git-repo-check --color never -c 'approval_policy="never"')
model="${CODEX_MODEL:-gpt-6.2-sol}"
args+=(-m "$model")
if [[ "$effort" != default ]]; then args+=(-c "model_reasoning_effort=\"$effort\""); fi
# Fast controls are on by default in current Codex; select the service tier explicitly.
if [[ "$fast" == 1 ]]; then args+=(-c 'service_tier="fast"'); fi
if [[ "$fast" == 0 ]]; then args+=(-c 'service_tier="default"'); fi

if [[ "$mode" == --probe ]]; then
    # This is an environment-only probe. No competition data or questions are read.
    mkdir -p -- work
    [[ -d work && ! -L work ]] || fail 'work must be a real directory'

    # Absolute HDFS path; '/' is the default and HDFS_TEST_PATH may override it.
    test_path="${HDFS_TEST_PATH:-/}"
    [[ "$test_path" != *$'\n'* && "$test_path" != *$'\r'* ]] \
        || fail 'HDFS_TEST_PATH must not contain line breaks'
    case "$test_path" in
        /*|hdfs://*|viewfs://*) ;;
        *) fail 'HDFS_TEST_PATH must be an absolute HDFS path' ;;
    esac
    # Stage 1: host-side HDFS preflight; fail before invoking Codex.
    printf '[HDFS] Checking command...\n'
    command -v hdfs >/dev/null 2>&1 || fail 'hdfs not found in PATH'
    printf '[HDFS] Checking configuration...\n'
    default_fs="$(hdfs getconf -confKey fs.defaultFS)" \
        || fail 'Cannot read Hadoop fs.defaultFS'
    printf '[HDFS] fs.defaultFS: %s\n' "$default_fs"
    case "$default_fs" in
        hdfs://*|viewfs://*) ;;
        *) fail "fs.defaultFS does not point to HDFS/ViewFS: $default_fs" ;;
    esac
    printf '[HDFS] Checking path: %s\n' "$test_path"
    hdfs dfs -ls "$test_path" >/dev/null \
        || fail "Cannot list HDFS test path: $test_path"
    printf '[HDFS] Host preflight PASS\n'

    # Probe files are isolated and removed on exit, including a failed Codex run.
    probe_dir="$(mktemp -d "$PWD/work/.probe.XXXXXXXX")" \
        || fail 'Cannot create temporary probe directory'
    probe_script="$probe_dir/check.sh"
    probe_result="$probe_dir/result"
    probe_work_file="$probe_dir/probe.txt"
    cleanup_probe() {
        rm -f -- "$probe_script" "$probe_result" "$probe_work_file"
        rmdir -- "$probe_dir"
    }
    trap cleanup_probe EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM

    # Deterministic checks; only this script may write the PASS result.
    cat > "$probe_script" <<'PROBE_SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
[[ $# -eq 3 ]] || { printf '[Probe] Invalid arguments\n' >&2; exit 2; }
test_path="$1"
result_file="$2"
work_file="$3"

printf '[Shell] Testing file creation and readback...\n'
printf 'GOLDEN_CUP_PROBE\n' > "$work_file"
[[ "$(< "$work_file")" == GOLDEN_CUP_PROBE ]]

printf '[Python] Testing execution...\n'
[[ "$(python3 -c 'print(17 * 19)')" == 323 ]]

printf '[HDFS] Checking command inside Codex...\n'
command -v hdfs >/dev/null 2>&1
printf '[HDFS] Checking configuration inside Codex...\n'
fs="$(hdfs getconf -confKey fs.defaultFS)"
case "$fs" in
    hdfs://*|viewfs://*) ;;
    *) printf '[HDFS] Invalid fs.defaultFS: %s\n' "$fs" >&2; exit 1 ;;
esac
printf '[HDFS] Checking path inside Codex: %s\n' "$test_path"
hdfs dfs -ls "$test_path" >/dev/null

for tool in hadoop hive beeline; do
    if command -v "$tool" >/dev/null 2>&1; then
        printf '[Tool] %s: AVAILABLE\n' "$tool"
    else
        printf '[Tool] %s: NOT FOUND (optional)\n' "$tool"
    fi
done

printf 'PASS\n' > "$result_file"
printf '[Probe] All required checks PASS\n'
PROBE_SCRIPT

    # %q quotes user-configured paths safely for the command run by Codex.
    printf -v probe_command 'bash %q %q %q %q' \
        "$probe_script" "$test_path" "$probe_result" "$probe_work_file"
    prompt="遵循 AGENTS.md。這是賽前環境驗證，不是正式解題。
只使用下方明確指定的環境檢查指令；不要讀取 questions.txt、競賽資料或執行解題。
不得下載大型資料、安裝套件、修改系統設定或 HDFS 內容，也不得更改驗證腳本與結果檔案。
請使用 Shell 實際執行下一行完整指令，等待它結束。不要代替指令自行宣告成功：
PROBE_COMMAND: $probe_command
只簡短回報實際 PASS/FAIL 與必要錯誤訊息。若執行失敗，不要自行修復環境。"

else
    [[ -s questions.txt ]] || fail 'questions.txt missing or empty'
    prompt=$(cat <<'PROMPT'
遵循 AGENTS.md，讀取 questions.txt，自主完成全部題目。若多題共用資料，合併探索；依預期得分效率調度，不為了輸出順序阻塞其他題目。
自行取得已授權資料、下載至工作區、執行 SQL/Python、驗證；不等待人工核准。若必要資訊無法取得，標記該題阻塞並繼續其他題，最後回頭處理；不可猜測。保留原始檔案不變。
每題完成必要驗證後，先將純答案（無題號、驗證文字、Markdown 圍欄；依題目精確格式）以 UTF-8 寫到 answers/NN.txt.tmp，再以同目錄重新命名為 answers/NN.txt。NN 為兩位題號。另存 answers/NN.check.txt，記錄實際執行的驗證證據及提交判定；只有通過驗證且建議提交時，check 檔必須包含以下兩個各佔一行的精確標記（可放在任意行）：VERIFICATION_STATUS=PASS 與 SUBMISSION_STATUS=READY。不得未驗證就寫入標記。先完成 check 檔，再發布正式答案；未通過驗證不發布，將原因記在 answers/NN.blocked.txt（非答案）。
每發布一題，立即在原生終端輸出，使用一次 Shell 指令 printf '[QNN]\n'; cat answers/NN.txt（把 NN 換成實際題號），並附一行簡短驗證與提交判定（可讀取 check 檔）。這是為了在整個 exec 結束前看到答案。不要等待全部題目完成，也不要重複輸出同一答案或敘述解題思路。直接繼續其他題。
若存在前次的正式答案及對應 check，核對其對應本次題目與有效性後跳過重算；只有暫存、阻塞或缺少有效 check 不視為完成。不要刪除既有答案。若重算，僅在新答案通過驗證後替換對應答案。成功後以 check 的最新判定為準，舊 blocked 紀錄僅供追溯。
只使用本工作區題目與資料及題目明確授權的競賽資料位置；不要搜尋測試標準答案或工作區外的評分工具。不要自行提交。全部處理完後僅列出已完成/未完成題號與必要阻塞原因。
PROMPT
)
fi

if [[ "$mode" == --dry-run ]]; then
    printf 'codex'; printf ' %q' "${args[@]}"; printf ' <task prompt>\n'
    printf '%s\n' "$prompt"
    exit 0
fi

if [[ "$mode" == solve ]]; then
    mkdir -p answers
    [[ -d answers && ! -L answers ]] || fail 'answers must be a real directory'
    fingerprint=$(sha256sum -- questions.txt); fingerprint=${fingerprint%% *}
    marker=answers/.questions.sha256
    if [[ -e "$marker" ]]; then
        [[ ! -L "$marker" && "$(cat -- "$marker")" == "$fingerprint" ]] || fail 'questions.txt changed; use a fresh workspace/answers directory (preserve old answers)'
    else
        shopt -s nullglob dotglob
        existing=(answers/*)
        shopt -u nullglob dotglob
        [[ ${#existing[@]} == 0 ]] || fail 'existing answers without fingerprint; preserve them and use a fresh workspace'
        printf '%s\n' "$fingerprint" > "$marker"
    fi
fi
# Preserve native CLI output: no pipes, JSON parsing, TUI, or background monitor.
# Full access does not change Linux/HDFS identity. Use the authorized contest account, not root.
if [[ "$mode" == solve ]]; then
    # EXIT also runs after a nonzero Codex exit. Signal handlers cover shell interrupts
    # when the process/session is still alive; SIGKILL or destroyed sessions cannot be trapped.
    on_solve_exit() {
        local status=$?
        trap - EXIT INT TERM
        if ((status != 0)); then
            printf '\nWARNING: Codex exited with status %d; showing any verified answers.\n' "$status" >&2
        fi
        show_answers || true
        exit "$status"
    }
    trap on_solve_exit EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    codex "${args[@]}" "$prompt"
elif [[ "$mode" == --probe ]]; then
    # Keep the shell alive so Codex output alone cannot be treated as success.
    codex "${args[@]}" "$prompt" || fail 'Codex probe execution failed'
    [[ -f "$probe_result" && ! -L "$probe_result" ]] \
        || fail 'Probe result file missing (Codex did not complete checks)'
    [[ "$(< "$probe_result")" == PASS ]] \
        || fail 'Probe checks did not pass'
    printf '\nPROBE PASS: Environment verified.\n'
else
    exec codex "${args[@]}" "$prompt"
fi
