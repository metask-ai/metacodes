#!/usr/bin/env bash
# tests/e2e/lib.sh —— 交互式 e2e 测试公共函数。
#
# 真·e2e:打真实模型(MiniMax,经 cc-zig 硬编码端点),不 mock。
# 驱动机制:把场景脚本的每段作为一行喂进【非 tty】REPL(管道),
#   cc-zig 在非 tty 下走 readLineBuffered 干净逐行读 + 同进程 conversation
#   跨行持续累积 = 真连续多轮对话(模型记得上下文),输出无 ANSI。
#
# 判定:不硬断言(真模型输出不确定)。只跑 + 收集产物 + 出报告,人工看。

# 仓库根 = 本文件上两级
E2E_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ZIG_ROOT="$(cd "$E2E_DIR/../.." && pwd)"
BIN="$ZIG_ROOT/zig-out/bin/metacodes"

# 单段最长等待(秒):真模型 + 多轮工具可能慢;到点杀进程防卡死。
SESSION_TIMEOUT="${E2E_TIMEOUT:-600}"

# --- 跑一个场景:把脚本各段喂进非 tty REPL,全量 stdout 落 logfile ---
# 用法: run_session <scenario_file> <workdir> <logfile>
run_session() {
  local scenario_file="$1" workdir="$2" logfile="$3"

  mkdir -p "$workdir"

  # 组装喂给 REPL 的输入:每段(--- 分隔)→ 一行(= 一轮 agent turn)。
  # 段内的换行压成空格(REPL 一行 = 一次提交;不能在段中间出现裸空行,
  # 否则 readLineBuffered 把空行当 EOF/Goodbye 提前退出)。末尾追加 /exit。
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
  # 关键:cd 到隔离 workdir;bypassPermissions 让无人值守工具调用不卡权限 prompt。
  (
    cd "$workdir" || exit 97
    printf '%s\n' "$feed" | \
      METACODES_LOG="agent:info,client:warn,*:warn" \
      perl -e '
        my $to=shift; my @cmd=@ARGV;
        my $pid=fork();
        if ($pid==0) { exec @cmd or exit 127; }
        $SIG{ALRM}=sub { kill "TERM",$pid; sleep 2; kill "KILL",$pid; exit 124; };
        alarm $to; waitpid($pid,0); exit($? >> 8);
      ' "$SESSION_TIMEOUT" \
      "$BIN" --permission bypassPermissions
  ) > "$logfile" 2>&1
  local rc=$?
  echo "$rc"  # 返回退出码给调用方
}

# --- 收集产物,把摘要追加到 REPORT.md ---
# 用法: collect_artifacts <scenario_name> <workdir> <logfile> <report> <session_rc>
collect_artifacts() {
  local name="$1" workdir="$2" logfile="$3" report="$4" rc="$5"

  {
    echo ""
    echo "## 场景: $name"
    echo ""
    echo "- session 退出码: \`$rc\` $( [[ "$rc" == "124" ]] && echo '(⚠️ 超时被杀)' )"

    # 工具调用痕迹:非 tty 下 agent_loop 用 log "tool.exec start name=X" / "name=X" 记录
    # (tty 才打 [Tool: X] 到 stdout)。统计成功 vs 失败。
    echo "- 工具调用统计:"
    if grep -q 'tool.exec start name=' "$logfile"; then
      grep -oE 'tool\.exec start name=[A-Za-z_]+' "$logfile" | sed 's/.*name=//' \
        | sort | uniq -c | sort -rn | sed 's/^/    - /'
      local nfail
      nfail=$(grep -c 'tool.exec FAILED' "$logfile" 2>/dev/null || echo 0)
      echo "    - (其中失败: $nfail 次 —— 见 \`tool.exec FAILED\`)"
    else
      echo "    - (未检测到工具调用)"
    fi

    # 会话健康(含 SSE 流错误 / 请求失败 / 工具执行失败)
    local errs
    errs=$(grep -ciE 'error:|panic|unreachable|Unauthorized|StreamTooLong|RequestFailed|takeDelimiter failed|err=true|tool.exec FAILED' "$logfile" | tr -d ' \n')
    echo "- 日志中疑似错误/失败行数: $errs"
    if [[ "$errs" != "0" ]]; then
      echo "  <details><summary>错误行</summary>"
      echo ""
      echo '  ```'
      grep -iE 'error:|panic|unreachable|Unauthorized|StreamTooLong|RequestFailed|takeDelimiter failed|tool.exec FAILED' "$logfile" | head -10 | sed 's/^/  /'
      echo '  ```'
      echo "  </details>"
    fi

    # 文件树(产物)
    echo "- 产物文件树:"
    echo '  ```'
    ( cd "$workdir" && find . -type f -not -path './.*' | sort | sed 's/^/  /' )
    echo '  ```'

    # 关键文件:HTML 软信号 + 设计/研究文档摘录
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
}

# --- 给报告写头 ---
report_header() {
  local report="$1" ts="$2"
  {
    echo "# cc-zig 交互式 e2e 测试报告"
    echo ""
    echo "- 时间: $ts"
    echo "- 模型/端点: cc-zig 默认(MiniMax,硬编码端点)"
    echo "- 驱动: stdin 管道 → 非 tty REPL(真连续多轮会话)"
    echo "- 判定: 不硬断言,人工看产物 + 工具调用 + 错误"
    echo ""
    echo "---"
  } > "$report"
}
