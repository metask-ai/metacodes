#!/usr/bin/env bash
# tests/e2e/lib.sh —— 交互式 e2e 测试公共函数。
#
# 真·e2e:打真实模型(MiniMax,经 cc-zig 硬编码端点),不 mock。
# 驱动机制:把场景脚本的每段作为一行喂进【非 tty】REPL(管道),
#   cc-zig 在非 tty 下走 readLineBuffered 干净逐行读 + 同进程 conversation
#   跨行持续累积 = 真连续多轮对话(模型记得上下文),输出无 ANSI。
#
# 判定:软优先(真模型输出不确定)。跑 + 收集产物 + 出报告;.conf 可声明
#   EXPECT_* 断言(默认软,EXPECT_HARD=1 时进退出码)。
#
# 隔离:每场景独立 fake HOME($workdir/.home),一举隔离 transcript /
#   history / agents/skills/settings 读取 / job_registry,保证可重复。

# 仓库根 = 本文件上两级
E2E_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ZIG_ROOT="$(cd "$E2E_DIR/../.." && pwd)"
# 保存进入场景 fake HOME 前的宿主 HOME，仅用于只读解析 auth 文件。
# 凭据只进子进程环境，不复制到 run artifact，也不打印。
E2E_HOST_HOME="${HOME:-}"

# 二进制:默认 debug(带 error-return-trace + 堆栈,利于排错);
# E2E_BIN=release 可切回 ReleaseSmall(更快更小,某些慢场景用)。
if [[ -n "${E2E_BIN_PATH:-}" ]]; then
  BIN="$E2E_BIN_PATH"
else
  case "${E2E_BIN:-debug}" in
    release) BIN="$ZIG_ROOT/zig-out/bin/metacodes" ;;
    *)       BIN="$ZIG_ROOT/zig-out/bin/metacodes-debug" ;;
  esac
fi
# debug 不存在则回退 release + 提示(不静默)。
if [[ -z "${E2E_BIN_PATH:-}" && ! -x "$BIN" && "$BIN" == *metacodes-debug ]]; then
  if [[ -x "$ZIG_ROOT/zig-out/bin/metacodes" ]]; then
    echo "⚠️  metacodes-debug 不存在,回退到 release 二进制(无 trace)。先 'zig build' 产出 debug。" >&2
    BIN="$ZIG_ROOT/zig-out/bin/metacodes"
  fi
fi

# 单段最长等待(秒):真模型 + 多轮工具可能慢;到点杀进程防卡死。
# 场景 .conf 可用 TIMEOUT= 覆盖。
SESSION_TIMEOUT="${E2E_TIMEOUT:-600}"

# 分级日志规格:主要类别 debug,其余 info。全量落 debug.log(单独文件),
# stdout 仍走精简 .log(给 REPORT 软信号用)。
E2E_LOG_SPEC="agent:debug,client:debug,stream:debug,tool:debug,permission:debug,sandbox:debug,*:info"

# ============================================================================
# .conf 解析:把同名 scenarios/<name>.conf 读进环境变量(无则全空 = 默认 bypass)
# ============================================================================
# 设置的变量(调用方读):
#   CONF_PERMISSION CONF_SETTINGS CONF_ALLOWED_TOOLS CONF_DISALLOWED_TOOLS
#   CONF_ADD_DIR(换行分隔多条) CONF_ANSWERS CONF_GIT_INIT CONF_MCP_MOCK_SERVERS CONF_KG_SEED CONF_TIMEOUT
#   CONF_EXPECT(换行分隔多条 EXPECT_* 原始行) CONF_EXPECT_HARD
load_conf() {
  local conf_file="$1"
  CONF_PERMISSION="bypassPermissions"
  CONF_SETTINGS=""
  CONF_ALLOWED_TOOLS=""
  CONF_DISALLOWED_TOOLS=""
  CONF_ADD_DIR=""
  CONF_ANSWERS=""
  CONF_GIT_INIT=""
  CONF_MCP_MOCK_SERVERS=""
  CONF_KG_SEED=""
  CONF_TIMEOUT=""
  CONF_EXPECT=""
  CONF_EXPECT_HARD="0"

  [[ -f "$conf_file" ]] || return 0

  local line key val
  while IFS= read -r line || [[ -n "$line" ]]; do
    # 跳过空行和注释
    line="${line%%#*}"
    line="$(printf '%s' "$line" | sed 's/[[:space:]]*$//')"
    [[ -z "$line" ]] && continue
    key="${line%%=*}"
    val="${line#*=}"
    key="$(printf '%s' "$key" | sed 's/[[:space:]]*$//;s/^[[:space:]]*//')"
    val="$(printf '%s' "$val" | sed 's/^[[:space:]]*//')"
    case "$key" in
      PERMISSION)        CONF_PERMISSION="$val" ;;
      SETTINGS)          CONF_SETTINGS="$val" ;;
      ALLOWED_TOOLS)     CONF_ALLOWED_TOOLS="$val" ;;
      DISALLOWED_TOOLS)  CONF_DISALLOWED_TOOLS="$val" ;;
      ADD_DIR)           CONF_ADD_DIR="${CONF_ADD_DIR}${val}"$'\n' ;;
      ANSWERS)           CONF_ANSWERS="$val" ;;
      GIT_INIT)          CONF_GIT_INIT="$val" ;;
      MCP_MOCK_SERVERS)  CONF_MCP_MOCK_SERVERS="$val" ;;
      KG_SEED)           CONF_KG_SEED="$val" ;;
      TIMEOUT)           CONF_TIMEOUT="$val" ;;
      EXPECT_FILE|EXPECT_CONTAINS|EXPECT_MIN_LINES|EXPECT_ABSENT)
                         CONF_EXPECT="${CONF_EXPECT}${key}=${val}"$'\n' ;;
      EXPECT_HARD)       CONF_EXPECT_HARD="$val" ;;
      *) echo "⚠️  未知 .conf 键: $key(忽略)" >&2 ;;
    esac
  done < "$conf_file"
}

# ============================================================================
# fake HOME 夹具:建空 .claude / .metacodes 骨架(默认纯净基线)。
# 场景可在调用后往里塞预置 agents/skills/settings。
# ============================================================================
setup_fake_home() {
  local home_dir="$1"
  mkdir -p "$home_dir/.claude/agents" \
           "$home_dir/.claude/skills" \
           "$home_dir/.metacodes"
}

# ============================================================================
# 跑一个场景:把脚本各段喂进非 tty REPL,全量 stdout 落 logfile。
# 用法: run_session <scenario_file> <workdir> <logfile> <debug_logfile> <conf_file>
# 返回(echo): session 退出码
# ============================================================================
run_session() {
  local scenario_file="$1" workdir="$2" logfile="$3" debug_logfile="$4" conf_file="$5"

  load_conf "$conf_file"
  local timeout="${CONF_TIMEOUT:-$SESSION_TIMEOUT}"
  [[ -n "$CONF_TIMEOUT" ]] || timeout="$SESSION_TIMEOUT"

  mkdir -p "$workdir"

  # --- 真实仓库稀疏快照:由 scored suite 冻结完整 commit id + 路径清单。---
  # materializer 只接受 Git regular files，限制文件数/总字节，并拒绝路径逃逸与链接。
  # suite 外的普通探索场景不含 task 条目，helper 会直接 no-op。
  python3 "$E2E_DIR/materialize_repo_snapshot.py" \
    --suite "${E2E_EVAL_SUITE:-$ZIG_ROOT/evals/suites/core-e2e.json}" \
    --task "$(basename "$workdir")" \
    --repo-root "$ZIG_ROOT" \
    --workspace "$workdir" || {
      echo "repository snapshot materialization failed" >&2
      echo 93
      return 0
    }

  # --- HOME 隔离:每场景独立 fake HOME,隔离一切 HOME 级副作用 ---
  local fake_home="$workdir/.home"
  setup_fake_home "$fake_home"

  # --- TinyKG 夹具:只向本场景 fake HOME 的全新 store 写入,以 global project 供任意
  # workdir domain 只读召回。fixture 路径同时在 eval suite environment.fixtures 中冻结。---
  if [[ -n "$CONF_KG_SEED" ]]; then
    local tinykg_bin="${METACODES_TEST_TINYKG_BIN:-${METACODES_KG_BIN:-}}"
    local kg_fixture="$E2E_DIR/$CONF_KG_SEED"
    if [[ ! -x "$tinykg_bin" || ! -f "$kg_fixture" ]]; then
      echo "KG fixture dependency missing: explicit TinyKG binary or $kg_fixture" >&2
      echo 94
      return 0
    fi
    python3 "$E2E_DIR/seed_kg_fixture.py" \
      "$tinykg_bin" "$fake_home/.metacodes/kg/store.kg" "$kg_fixture" || {
        echo 94
        return 0
      }
  fi

  # --- 场景级预置夹具:fixtures/agents → fake HOME(供 22_subagent_custom 等)---
  if [[ -d "$E2E_DIR/fixtures/agents" ]]; then
    cp -f "$E2E_DIR/fixtures/agents/"*.md "$fake_home/.claude/agents/" 2>/dev/null || true
  fi

  # --- 真 MCP allowlist 夹具:同一个确定性 mock 以多个 server name 启动。---
  # AgentDef.mcpServers 的发布场景需要同时存在 allowed/blocked server，才能证明
  # 请求 tools 与运行时 session 都被裁剪。缺 binary 直接使 rollout invalid，绝不降级。
  if [[ -n "$CONF_MCP_MOCK_SERVERS" ]]; then
    local mock_mcp="$ZIG_ROOT/zig-out/bin/mock_mcp_server"
    if [[ ! -x "$mock_mcp" ]]; then
      echo "MCP fixture missing: $mock_mcp (run zig build first)" >&2
      echo 96
      return 0
    fi
    python3 - "$fake_home/.metacodes/config.json" "$mock_mcp" "$CONF_MCP_MOCK_SERVERS" <<'PY'
import json
import sys
from pathlib import Path

output, command, raw_names = sys.argv[1:]
names = [item.strip() for item in raw_names.split(",") if item.strip()]
if not names:
    raise SystemExit("MCP_MOCK_SERVERS must contain at least one server name")
payload = {"mcp_servers": [{"name": name, "command": [command]} for name in names]}
Path(output).write_text(json.dumps(payload, sort_keys=True) + "\n", encoding="utf-8")
PY
  fi

  # --- git 夹具:GIT_INIT=1 时框架预先 init + 初始 commit(省一轮模型调用,更稳)---
  if [[ "$CONF_GIT_INIT" == "1" ]]; then
    (
      cd "$workdir" || exit 0
      git init -q 2>/dev/null
      git config user.email e2e@cc-zig.local 2>/dev/null
      git config user.name "cc-zig e2e" 2>/dev/null
      printf '.home/\n' > .git/info/exclude
      # 放个种子文件,保证有东西可 commit
      printf 'cc-zig e2e worktree fixture\n' > .gitseed
      git add -A 2>/dev/null
      git commit -q -m init 2>/dev/null
    )
  fi

  # --- 拼 CLI 参数(从 .conf)---
  local -a cli_args=()
  cli_args+=(--permission "$CONF_PERMISSION")
  local eval_model="${E2E_MODEL:-claude-sonnet-4-20250514}"
  local eval_provider="${E2E_MODEL_PROVIDER:-anthropic}"
  case "$eval_provider" in
    anthropic|openai|gemini) ;;
    *) echo "invalid E2E_MODEL_PROVIDER: $eval_provider" >&2; echo 95; return 0 ;;
  esac
  cli_args+=(--model "$eval_model")
  [[ -n "$CONF_SETTINGS" ]] && cli_args+=(--settings "$E2E_DIR/$CONF_SETTINGS")
  [[ -n "$CONF_ALLOWED_TOOLS" ]] && cli_args+=(--allowedTools "$CONF_ALLOWED_TOOLS")
  [[ -n "$CONF_DISALLOWED_TOOLS" ]] && cli_args+=(--disallowedTools "$CONF_DISALLOWED_TOOLS")
  if [[ -n "$CONF_ADD_DIR" ]]; then
    while IFS= read -r d; do
      [[ -n "$d" ]] && cli_args+=(--add-dir "$d")
    done <<< "$CONF_ADD_DIR"
  fi
  [[ -n "$CONF_ANSWERS" ]] && cli_args+=(--answers-file "$E2E_DIR/$CONF_ANSWERS")

  # --- 真实模型认证:fake HOME 不复制用户 auth.json。---
  # 付费控制面传入匿名 fd；普通手工 E2E 保留旧的 env/auth-file 兼容路径。
  local runtime_api_key_fd="${E2E_API_KEY_FD:-}"
  local eval_api_key="${METASK_API_KEY:-}"
  local auth_source="${E2E_AUTH_FILE:-${E2E_HOST_HOME:+$E2E_HOST_HOME/.metacodes/auth.json}}"
  if [[ -n "$runtime_api_key_fd" && -n "$eval_api_key" ]]; then
    echo "ambiguous E2E provider credentials" >&2
    echo 96
    return 0
  fi
  if [[ -z "$runtime_api_key_fd" && -z "$eval_api_key" && -n "$auth_source" && -f "$auth_source" ]]; then
    eval_api_key="$(python3 - "$auth_source" <<'PY'
import json
import sys

try:
    value = json.load(open(sys.argv[1], encoding="utf-8")).get("api_key") or ""
except (OSError, ValueError, TypeError):
    value = ""
sys.stdout.write(value if isinstance(value, str) else "")
PY
)"
  fi
  local -a auth_env=()
  if [[ -n "$runtime_api_key_fd" ]]; then
    [[ "$runtime_api_key_fd" =~ ^[0-9]+$ ]] || { echo "invalid E2E_API_KEY_FD" >&2; echo 96; return 0; }
    auth_env+=("METACODES_API_KEY_FD=$runtime_api_key_fd")
    unset E2E_API_KEY_FD
  elif [[ -n "$eval_api_key" ]]; then
    auth_env+=("METASK_API_KEY=$eval_api_key")
  fi

  # --- record 模式(Stage 7):E2E_RECORD=1 时录 cassette 到 <workdir>/cassette/ ---
  if [[ "${E2E_RECORD:-0}" == "1" ]]; then
    cli_args+=(--record "$workdir/cassette")
  fi
  # --- replay 模式(Stage 7):E2E_BASE_URL 设置时指向 mock(由 replay 驱动起)---
  [[ -n "${E2E_BASE_URL:-}" ]] && cli_args+=(--base-url "$E2E_BASE_URL")

  # --- 原生 evaluation events(M2):在子进程启动前冻结所有可比性身份。---
  # suite 外的探索场景不强行计分；prepare-e2e 会跳过且不创建 metadata。
  local eval_metadata="$workdir/.eval-metadata.tmp"
  local eval_events="$workdir/events.jsonl"
  local eval_events_stage="$workdir/.eval-events.tmp"
  local eval_task eval_run_name eval_revision
  eval_task="$(basename "$workdir")"
  eval_run_name="$(basename "$(dirname "$workdir")"):${eval_task}:${E2E_TRIAL:-0}"
  if [[ -n "${E2E_HARNESS_REVISION:-}" ]]; then
    eval_revision="$E2E_HARNESS_REVISION"
  else
    eval_revision="$(git -C "$ZIG_ROOT" rev-parse HEAD 2>/dev/null || printf 'unknown')"
  fi
  local -a eval_budget_args=()
  if [[ -n "${E2E_MAX_METERED_TOKENS:-}" ]]; then
    eval_budget_args+=("--max-metered-tokens" "$E2E_MAX_METERED_TOKENS")
  fi
  if [[ -n "${E2E_MAX_COST_USD:-}" ]]; then
    eval_budget_args+=("--max-cost-usd" "$E2E_MAX_COST_USD")
  fi
  python3 "$ZIG_ROOT/scripts/eval/cli.py" prepare-e2e \
    --suite "${E2E_EVAL_SUITE:-$ZIG_ROOT/evals/suites/core-e2e.json}" \
    --task "$eval_task" \
    --output "$eval_metadata" \
    --events "$eval_events" \
    --run-id "$eval_run_name" \
    --trial "${E2E_TRIAL:-0}" \
    --model-provider "$eval_provider" \
    --model-id "$eval_model" \
    --harness-config-id "${E2E_HARNESS_CONFIG_ID:-metacodes-e2e-native-v1}" \
    --harness-revision "$eval_revision" \
    --permission-mode "$CONF_PERMISSION" \
    --binary "$BIN" \
    "${eval_budget_args[@]}" >/dev/null || return 98
  # Budget inputs are now sealed in the inherited metadata fd. Do not expose
  # runner control state to the model or its tools through the child env.
  unset E2E_MAX_METERED_TOKENS E2E_MAX_COST_USD
  local eval_enabled=0
  [[ -f "$eval_metadata" ]] && eval_enabled=1

  # 组装喂给 REPL 的输入:每段(--- 分隔)→ 一行(= 一轮 agent turn)。
  # 段内换行压成空格;末尾追加 /exit。
  local feed
  feed="$(awk '
    BEGIN { seg="" }
    /^---[[:space:]]*$/ { if (seg != "") { print seg; seg="" }; next }
    {
      line=$0
      if (seg == "") seg=line; else seg=seg " " line
    }
    END { if (seg != "") print seg; print "/exit" }
  ' "$scenario_file")"

  # 用 perl 实现可移植的超时(macOS 无 timeout)。
  # 关键:cd 到隔离 workdir;HOME 指 fake HOME;分级日志双写(debug 落单独文件)。
  (
    cd "$workdir" || exit 97
    local -a eval_env=()
    if [[ "$eval_enabled" == "1" ]]; then
      exec 8<"$eval_metadata" || exit 98
      rm -f "$eval_metadata" || exit 98
      : > "$eval_events_stage" || exit 98
      exec 9<>"$eval_events_stage" || exit 98
      rm -f "$eval_events_stage" || exit 98
      eval_env+=("METACODES_EVAL_METADATA_FD=8" "METACODES_EVAL_FD=9")
    fi
    printf '%s\n' "$feed" | \
      env \
      "HOME=$fake_home" \
      "METACODES_LOG=$E2E_LOG_SPEC" \
      "METACODES_LOG_FILE=$debug_logfile" \
      "METACODES_PROVIDER=$eval_provider" \
      "${auth_env[@]}" \
      "${eval_env[@]}" \
      perl -e '
        my $to=shift; my @cmd=@ARGV;
        my $pid=fork();
        if ($pid==0) { exec @cmd or exit 127; }
        $SIG{ALRM}=sub { kill "TERM",$pid; sleep 2; kill "KILL",$pid; exit 124; };
        alarm $to; waitpid($pid,0); exit($? >> 8);
      ' "$timeout" \
      "$BIN" "${cli_args[@]}"
    child_rc=$?
    if [[ "$eval_enabled" == "1" ]]; then
      python3 "$ZIG_ROOT/scripts/eval/cli.py" finalize-e2e \
        --fd 9 --output "$eval_events" || exit 98
    fi
    exit "$child_rc"
  ) > "$logfile" 2>&1
  local rc=$?

  # --- worktree 兜底清理(Stage 5)---
  if [[ "$CONF_GIT_INIT" == "1" ]]; then
    git -C "$workdir" worktree prune 2>/dev/null || true
  fi

  # --- 关联 transcript(Stage 0):从 fake HOME 把本场景 transcript.jsonl 拷出来 ---
  # transcript 写在 $fake_home/.metacodes/projects/<cwd_hash>/<session_id>/transcript.jsonl
  local tpath
  tpath="$(find "$fake_home/.metacodes/projects" -name 'transcript.jsonl' -type f 2>/dev/null | head -1)"
  if [[ -n "$tpath" ]]; then
    cp -f "$tpath" "$workdir/transcript.jsonl" 2>/dev/null || true
  fi

  echo "$rc"
}

# ============================================================================
# EXPECT 断言(Stage 8):跑 .conf 声明的 EXPECT_*,echo PASS/FAIL 行到 stdout。
# 用法: run_expects <workdir> <logfile>  (依赖 load_conf 已填 CONF_EXPECT)
# 返回(echo): 多行 "STATUS|描述";调用方聚合。STATUS ∈ PASS/FAIL
# ============================================================================
run_expects() {
  local workdir="$1" logfile="$2"
  [[ -z "$CONF_EXPECT" ]] && return 0
  local line key val path needle n
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    key="${line%%=*}"
    val="${line#*=}"
    case "$key" in
      EXPECT_FILE)
        if [[ -f "$workdir/$val" ]]; then echo "PASS|文件存在: $val"; else echo "FAIL|文件缺失: $val"; fi
        ;;
      EXPECT_CONTAINS)
        path="${val%%:*}"; needle="${val#*:}"
        if [[ -f "$workdir/$path" ]] && grep -qF "$needle" "$workdir/$path"; then
          echo "PASS|$path 含 '$needle'"
        else
          echo "FAIL|$path 不含 '$needle'(或文件缺失)"
        fi
        ;;
      EXPECT_MIN_LINES)
        path="${val%%:*}"; n="${val#*:}"
        if [[ -f "$workdir/$path" ]]; then
          local actual; actual=$(wc -l < "$workdir/$path" | tr -d ' ')
          if [[ "$actual" -ge "$n" ]]; then echo "PASS|$path ≥$n 行(实际 $actual)"; else echo "FAIL|$path <$n 行(实际 $actual)"; fi
        else
          echo "FAIL|$path 缺失(要求 ≥$n 行)"
        fi
        ;;
      EXPECT_ABSENT)
        # 格式 :str(空 path)在 logfile 里找;或 path:str 在文件里找
        path="${val%%:*}"; needle="${val#*:}"
        local target
        if [[ -z "$path" ]]; then target="$logfile"; else target="$workdir/$path"; fi
        if [[ -f "$target" ]] && grep -qF "$needle" "$target"; then
          echo "FAIL|不应出现 '$needle'(在 ${path:-log})"
        else
          echo "PASS|无 '$needle'(在 ${path:-log})"
        fi
        ;;
    esac
  done <<< "$CONF_EXPECT"
}

# ============================================================================
# 收集产物,把摘要追加到 REPORT.md。
# 用法: collect_artifacts <name> <workdir> <logfile> <debug_logfile> <report> <rc>
# 注意:collect 在独立子shell 跑(run_e2e 用 $(...) 捕获返回),CONF_* 不跨子shell,
#   故本函数自己重新 load_conf(传 conf_file)。
# echo 出 "<错误数>|<EXPECT FAIL 数>" 供调用方做摘要/退出码。
# ============================================================================
collect_artifacts() {
  local name="$1" workdir="$2" logfile="$3" debug_logfile="$4" report="$5" rc="$6" conf_file="$7"
  local nfail nerr expect_out expect_fail=0

  # 重新加载 .conf(本子shell 看不到 run_session 设的 CONF_*)
  load_conf "$conf_file"

  # 工具失败数:tool.exec FAILED 计数(在 debug.log,因为 warn 级)
  nfail=$(grep -c 'tool.exec FAILED' "$debug_logfile" 2>/dev/null)
  nfail="${nfail//[^0-9]/}"; nfail="${nfail:-0}"

  # 工具失败分类(e2e triage):区分**模型可纠正的 user_error**(字段/路径/patch context
  # 错,cc-zig 正确拒绝)vs **cc-zig/工具真错**。与 core/tool_error.zig 的 user_error
  # 映射保持一致；原生日志只有 Zig error name，故在这里保留兼容表。
  local nfail_model nfail_real
  nfail_model=$(grep -E 'tool.exec FAILED' "$debug_logfile" 2>/dev/null | grep -cE 'err=(Missing|Invalid|Empty|NotRead|StaleFile|UnknownTool|FileNotFound|MultipleMatches|StringNotFound|ContextNotFound|OldLinesNotFound|NoOpEdit)' )
  nfail_model="${nfail_model//[^0-9]/}"; nfail_model="${nfail_model:-0}"
  nfail_real=$(( 10#${nfail:-0} - 10#${nfail_model:-0} ))

  # 错误数(D10 修正):真·崩溃/网络错误类 + cc-zig 真工具错。**不含模型给错参**(那是模型问题,
  # cc-zig 行为正确)、**不含 err=true**(误命中正常日志)。
  local ncrash
  ncrash=$(grep -ciE 'panic|unreachable|StreamTooLong|RequestFailed|ApiError|Unauthorized|RateLimited|ServerError' "$debug_logfile" 2>/dev/null)
  ncrash="${ncrash//[^0-9]/}"; ncrash="${ncrash:-0}"
  nerr=$(( 10#${nfail_real:-0} + 10#${ncrash:-0} ))

  {
    echo ""
    echo "## 场景: $name"
    echo ""
    echo "- session 退出码: \`$rc\` $( [[ "$rc" == "124" ]] && echo '(⚠️ 超时被杀)' )"
    echo "- 权限模式: \`$CONF_PERMISSION\`$( [[ -n "$CONF_SETTINGS" ]] && echo " · settings=\`$CONF_SETTINGS\`" )"

    # --- 工具调用统计(主对话 vs subagent 分桶,Stage 4)---
    echo "- 工具调用统计:"
    if grep -qE 'tool\.exec start(\(par\))? name=' "$debug_logfile" 2>/dev/null; then
      grep -oE 'tool\.exec start(\(par\))? name=[A-Za-z_]+' "$debug_logfile" | sed 's/.*name=//' \
        | sort | uniq -c | sort -rn | sed 's/^/    - /'
      echo "    - (其中失败: $nfail 次 = 模型给错参 $nfail_model + cc-zig 真错 $nfail_real)"
    else
      echo "    - (未检测到工具调用)"
    fi

    # --- subagent 痕迹(Stage 4)---
    local nsub
    nsub=$(grep -cE 'spawnAgent|subagent|agent_depth=|Task' "$debug_logfile" 2>/dev/null || echo 0)
    nsub="${nsub//[^0-9]/}"
    if [[ "${nsub:-0}" != "0" ]]; then
      echo "- subagent 痕迹: $nsub 行(见 debug.log spawnAgent/Task/agent_depth)"
    fi

    # --- worktree Enter/Exit 配对校验(Stage 5)---
    # 精确数 tool.exec 调用(不数提示词/工具定义/流式 delta 里的工具名提及)。
    if [[ "$CONF_GIT_INIT" == "1" ]] || grep -qE 'tool\.exec start(\(par\))? name=EnterWorktree' "$debug_logfile" 2>/dev/null; then
      local n_enter n_exit
      n_enter=$(grep -cE 'tool\.exec start(\(par\))? name=EnterWorktree' "$debug_logfile" 2>/dev/null); n_enter="${n_enter//[^0-9]/}"; n_enter="${n_enter:-0}"
      n_exit=$(grep -cE 'tool\.exec start(\(par\))? name=ExitWorktree' "$debug_logfile" 2>/dev/null); n_exit="${n_exit//[^0-9]/}"; n_exit="${n_exit:-0}"
      if [[ "$n_enter" == "$n_exit" ]]; then
        echo "- worktree: Enter=$n_enter Exit=$n_exit ✓ 配对"
      else
        echo "- worktree: ⚠️ Enter=$n_enter Exit=$n_exit **不配对**(cwd 副作用泄漏风险;真模型多次尝试也会不等)"
      fi
    fi

    # --- 会话健康 ---
    echo "- cc-zig/网络错误计数: $nerr(cc-zig 真工具错 $nfail_real + 崩溃/网络类 $ncrash)$( [[ "$nfail_model" != "0" ]] && echo " · 另有模型给错参 $nfail_model 次(cc-zig 行为正确,不计入)" )"
    if [[ "$nerr" != "0" ]]; then
      echo "  <details><summary>错误行(前 10)</summary>"
      echo ""
      echo '  ```'
      grep -iE 'panic|unreachable|StreamTooLong|RequestFailed|ApiError|Unauthorized|RateLimited|ServerError|tool.exec FAILED' "$debug_logfile" 2>/dev/null | head -10 | sed 's/^/  /'
      echo '  ```'
      echo "  </details>"
    fi

    # --- 失败时间线(Stage 0):逐轮 turn → tool.exec → done/FAILED ---
    echo "- 轮次时间线:"
    echo "  <details><summary>展开</summary>"
    echo ""
    echo '  ```'
    grep -oE '(turn [0-9]+/[0-9]+ starting|tool\.exec start name=[A-Za-z_]+|tool\.exec done name=[A-Za-z_]+|tool\.exec FAILED name=[A-Za-z_]+[^,]*)' "$debug_logfile" 2>/dev/null \
      | sed 's/^/  /' | head -80
    echo '  ```'
    echo "  </details>"

    # --- transcript 关联(Stage 0)---
    if [[ -f "$workdir/transcript.jsonl" ]]; then
      echo "- transcript: \`$name/transcript.jsonl\`($(wc -l < "$workdir/transcript.jsonl" | tr -d ' ') 条)"
    else
      echo "- transcript: (未捕获)"
    fi

    # --- EXPECT 断言(Stage 8)---
    expect_out="$(run_expects "$workdir" "$logfile")"
    if [[ -n "$expect_out" ]]; then
      echo "- EXPECT 断言:"
      while IFS='|' read -r st desc; do
        [[ -z "$st" ]] && continue
        if [[ "$st" == "PASS" ]]; then
          echo "    - ✓ $desc"
        else
          echo "    - ✗ **$desc**"
          expect_fail=$(( expect_fail + 1 ))
        fi
      done <<< "$expect_out"
      [[ "$CONF_EXPECT_HARD" == "1" ]] && echo "    - (EXPECT_HARD=1:FAIL 进退出码)"
    fi

    # --- 文件树 ---
    echo "- 产物文件树:"
    echo '  ```'
    ( cd "$workdir" && find . -type f -not -path './.*' | sort | sed 's/^/  /' )
    echo '  ```'

    # --- 关键文件摘录 ---
    local f
    while IFS= read -r f; do
      [[ -z "$f" ]] && continue
      local rel="${f#$workdir/}"
      echo ""
      echo "### 文件: \`$rel\` ($(wc -l < "$f" | tr -d ' ') 行)"
      case "$f" in
        *.html|*.htm)
          echo "- HTML 软信号:"
          for sig in '<canvas' '<script' 'requestAnimationFrame' 'addEventListener' 'getContext'; do
            if grep -qiF "$sig" "$f"; then echo "    - ✓ $sig"; else echo "    - ℹ 无 $sig"; fi
          done
          ;;
      esac
      echo "  <details><summary>前 30 行</summary>"
      echo ""
      echo '  ```'
      head -30 "$f" | sed 's/^/  /'
      echo '  ```'
      echo "  </details>"
    done < <(cd "$workdir" && find "$PWD" -type f \( -name '*.md' -o -name '*.html' -o -name '*.htm' -o -name '*.js' -o -name '*.css' -o -name '*.txt' \) -not -path '*/.*' | sort)

  } >> "$report"

  # 返回:错误数 | EXPECT FAIL 数(仅 EXPECT_HARD=1 时计入退出码)
  local hard_fail=0
  [[ "$CONF_EXPECT_HARD" == "1" ]] && hard_fail="$expect_fail"
  echo "${nerr}|${hard_fail}"
}

# ============================================================================
# 报告头(Stage 1:环境快照)
# ============================================================================
report_header() {
  local report="$1" ts="$2"
  local zigver build_type
  zigver="$(zig version 2>/dev/null || echo '未知')"
  case "$BIN" in
    *metacodes-debug) build_type="Debug(带 trace)" ;;
    *) build_type="ReleaseSmall" ;;
  esac
  {
    echo "# cc-zig 交互式 e2e 测试报告"
    echo ""
    echo "- 时间: $ts"
    echo "- 模型/端点: cc-zig 默认(MiniMax,硬编码端点)"
    echo "- 驱动: stdin 管道 → 非 tty REPL(真连续多轮会话)"
    echo "- 判定: 软优先;.conf EXPECT_* 可选硬断言"
    echo ""
    echo "### 环境快照"
    echo ""
    echo "- zig: \`$zigver\`"
    echo "- 二进制: \`$BIN\`($build_type)"
    echo "- HOME 隔离: ✓ 每场景独立 fake HOME(\`<workdir>/.home\`)"
    echo "- 单段超时: ${SESSION_TIMEOUT}s"
    echo ""
    echo "---"
  } > "$report"
}
