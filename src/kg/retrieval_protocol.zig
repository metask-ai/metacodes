//! TinyKG 无向量检索的模型侧 semantic-neighborhood 协议。
//!
//! TinyKG 只负责确定性的 BM25/图检索；LLM 负责按意图生成少量分离的词法探针、
//! 合并候选并验证节点/证据。协议同时接到 system prompt、工具 schema、自动召回提醒
//! 和工具结果，避免不同 agent 入口退化成单条裸 query 或一个超大关键词袋。

const std = @import("std");

/// system prompt 中的强制协议。“语义邻域”是模型主动推理，不暗示底层计算向量距离。
pub const SYSTEM_RULES =
    \\Lexical retrieval algorithm (mandatory whenever KgRecall is warranted; follow in order):
    \\- TinyKG uses lexical BM25 and computes no embeddings or vector distance. A lexical miss is not proof that the knowledge is absent; BM25 hits are candidates, not facts.
    \\- Step 1 — SCAN FIRST: inspect any automatically recalled memory lines before forming a query. The host tracks node_id values and information gain; lexical_plan carries only the semantic choice fields in its schema.
    \\- Step 2A — ALIAS BRANCH HAS PRIORITY: if an automatic hit contains an exact canonical alias or code symbol, the first explicit query MUST contain only that exact term plus field names already requested by the user, and MUST omit `type`. This focused alias lookup is the high-precision fast path; do not widen before reading it.
    \\- Step 2B — EXACT/HIGH-PRECISION SEED: if no alias was exposed, first issue one compact, untyped KgRecall using the user's exact wording and discriminating field names. Do not mix speculative semantic variants into this seed.
    \\- Step 2C — RECORD THE PLAN: attach `lexical_plan` with schema_version lexical-query-plan-v3 to every normal KgRecall. A seed has one exact/alias variant. If the seed is insufficient, declare one fixed 2-4 member non-exact semantic batch. The host executes every declared member in order inside this single tool call, merges by node_id, exposes each node body at most once, and returns a stable plan_sha256 plus per-variant receipts. `query` is only a required legacy compatibility field; v3 deterministically executes variants[0] as its anchor and records an audited rewrite if `query` is stale. Do not spend another model turn repairing only this redundant field. The run-scoped host ledger owns seen state; omit variant_index and seen_node_ids. Query-only and v1/v2 calls remain compatibility paths.
    \\- Step 3 — BOUNDED SEMANTIC NEIGHBORHOOD: only if the seed is insufficient, infer 2-4 separate compact probes for this intent and submit them together once. Never concatenate them into a keyword bag. Choose useful dimensions rather than filling a quota: synonym/paraphrase; Chinese/English alias, abbreviation, old/new name, or code identifier; mechanism, symptom, outcome, or nearby implementation; one plausible broader/narrower concept. For enumeration, preserve the user's relation or action (for example attended, went to, joined, or received) in at least one probe while varying the event noun (for example commencement, degree conferral, convocation, or graduation); avoid bare one-word probes that drop the counted relation. The host executes at most four semantic probes per run.
    \\- Step 3E — ENUMERATION REQUIRES COVERAGE: for count/cardinality, exhaustive-list, all/every, or negative/absence questions set intent=`enumeration`. One positive hit proves existence, never completeness. Unless the seed returns an authoritative aggregate, submit a 2-4 member semantic batch; a successful v3 receipt proves every member ran. Batch execution is necessary, not sufficient: when the governed run has candidates and KgContext is available, call it on at least one recalled node and verify that merged hits and graph evidence cover the requested scope before concluding a count, exhaustive list, or absence. One best-node KgContext call is sufficient for this bounded host obligation; only fan out when that result explicitly signals contradiction, supersession, truncation, or missing evidence. The host rejects premature final answers until the available obligations commit; a zero-candidate batch does not create an impossible KgContext obligation.
    \\- Step 4 — MERGE AND VERIFY: semantically judge hits. Deduplicate candidates by node_id across every call. Memory is a candidate, not a current fact. Prefer exact aliases and authoritative nodes, but never treat score or wording overlap as correctness. Call KgContext on the best seed to read its authoritative node text and bounded graph neighborhood.
    \\- Step 5 — GOVERN EVIDENCE AND FRESHNESS: inspect verified_by or evidences links, provenance, and any deprecated_by, resolved_by, and contradiction signal exposed by KgContext. A current-generation node with connected evidence is still only a candidate: TinyKG has no universal freshness clock. If evidence is missing, the graph is truncated, the node is superseded/conflicted, or the claim is time-sensitive, do not use memory as a current fact; verify it against current code, git, tests, or external state.
    \\- Step 6 — STOP OR REPORT UNCERTAINTY: For non-enumeration lookups, stop as soon as authoritative evidence and any required current-state check are sufficient. For enumeration, the Step 3E coverage condition is part of sufficiency. If the bounded variants and graph inspection remain insufficient, say so; do not infer absence from lexical misses and do not invent a fact.
;

pub const TOOL_DESCRIPTION =
    "Search the knowledge graph for durable memories (decisions, preferences, project facts) from this and past sessions. " ++
    "Use when the user refers to prior decisions/context or when continuing cross-session work. Retrieval is LEXICAL BM25: TinyKG has no embeddings and computes no vector distance. Start exact; if insufficient, declare 2-4 separate compact semantic variants in one host-executed batch, never one combined keyword bag. " ++
    "Attach lexical_plan (lexical-query-plan-v3). The host executes every declared variant, merges node ids, emits each node body once, and returns per-variant receipts. Count/list/all questions use intent=enumeration and require batch coverage before claiming completeness. " ++
    "Deduplicate node_id values across calls, then use KgContext to read authoritative node text and structured evidence/freshness/supersession signals. Memory hits are candidates, never automatically current facts. Hits carrying a \"source\" field come from a memory markdown file; update that file instead of KgRemembering a duplicate.";

pub const QUERY_DESCRIPTION =
    "FIRST inspect automatic recall. Seed with one untyped exact/alias variant. If insufficient, declare 2-4 separate semantic variants in one v3 batch: synonym/paraphrase; Chinese/English alias, abbreviation, old/new name, or code identifier; mechanism/symptom/outcome/nearby implementation; broader/narrower concept. Never combine variants into a keyword bag. query is a legacy compatibility field; v3 uses variants[0] as its effective anchor, the host executes all members, and it audits any stale-query normalization. Count/list/all questions use intent=enumeration and require batch coverage before completeness. A lexical miss does not prove absence.";

pub const PLAN_DESCRIPTION =
    "Governed lexical-query-plan-v3 artifact. Seed: one exact/alias variant, no type. Semantic expansion: one fixed 2-4 member non-exact batch. Omit variant_index and seen_node_ids. The host treats variants[0] as the effective query anchor, audits normalization of a stale redundant top-level query, executes all variants in order, caps the run at four semantic probes, merges by node_id, emits each node body once, and returns replayable per-variant receipts. For count/list/all/absence use intent=enumeration; batch execution is necessary but graph-scope verification is still required. TinyKG remains lexical BM25 only.";

pub const TYPE_DESCRIPTION =
    "Optional facet filter: decision | user_preference | module | bug | observation. Omit on the exact/high-precision seed because a bridge to the final decision may itself be an observation or module. Use only on a later focused call when an earlier untyped hit explicitly justifies the facet.";

pub const CONTEXT_DESCRIPTION =
    "Read one TinyKG candidate's authoritative node text, bounded local graph neighborhood, and structured knowledge_governance signals. Use after KgRecall to verify the selected node; inspect verified_by/evidences provenance plus deprecated_by/resolved_by/contradiction signals. For a bounded enumeration obligation, one best-node KgContext call is sufficient; inspect another connected node only when the first result explicitly signals contradiction, supersession, truncation, or missing evidence. Page long node text with text_offset/text_limit. Time-sensitive claims still require current code/git/test/external-state verification. This is deterministic graph traversal, not semantic or vector search.";

pub const CONTEXT_RESULT_GUIDANCE =
    "For the bounded enumeration evidence obligation, one best-node KgContext call is sufficient; inspect another connected node only when this result explicitly signals contradiction, supersession, truncation, or missing evidence. Verify authoritative text, track node_id values already inspected, and follow only relevant edges. Treat knowledge_governance as a fail-closed status: if evidence is missing, graph_truncated is true, current_generation is false, or contradiction signals exist, do not use memory as a current fact. Even evidence_connected_candidate has unknown freshness; verify time-sensitive claims against current code, git, tests, or external state. A graph edge alone does not prove the neighboring text is applicable.";

/// 自动召回使用原始 user 文本，未经过 LLM 扩词；明确说明它不是权威缺席判断。
pub const AUTO_RECALL_NOTE =
    "This automatic recall was one untyped raw-message lexical BM25 probe (no LLM expansion, no embeddings). Every line is a candidate, not a current fact, and carries a stable node_id for KgContext(node_id). Treat absence or partial coverage as non-authoritative. If a hit exposes an exact canonical alias/symbol, use it directly in one focused untyped KgRecall with only user-requested field names. Otherwise begin with one compact exact/high-precision query; only if it is insufficient should you try 1-4 separate compact semantic variants.";

/// 放在自动命中之后：让模型在决策点最后读到下一步，而非被 hit 正文冲淡。
pub const AUTO_RECALL_NEXT_ACTION =
    "强制下一步 / MANDATORY NEXT ACTION: 先检查上面的命中。若有 canonical alias/代码符号，先用一个无 type 的精确 seed。否则先做一个精确/高精度 seed；仅在不足时一次声明 2-4 个分离的语义变体，由宿主整批执行并按 node_id 合并。随后用 KgContext 读取最佳节点及相连证据。";

/// 每次 KgRecall 结果都携带：把下一步决策放在使用时点，而非只依赖 system prompt。
pub const RESULT_GUIDANCE =
    "Semantically judge the merged lexical candidates. content_ref=exposed_elsewhere_in_run points to the same node body already exposed in this run, not missing evidence. A v3 all_variants_executed receipt proves declared probes ran, not that the answer is complete. If a seed is insufficient, submit one 2-4 member semantic batch; do not issue its members separately or combine them into a keyword bag. For enumeration, verify merged graph scope before a count/list/absence conclusion. Use KgContext for authoritative text and governance signals. Never promote a hit to a current fact without evidence/freshness/supersession checks; lexical misses do not prove absence.";

/// Added to the real tool-result message when the host observes a committed
/// seed for a count/list query but no committed v3 semantic batch. This is an
/// executable control-loop signal, not another static system-prompt slogan.
pub const ENUMERATION_COVERAGE_REMINDER =
    "[lexical-coverage-obligation] The current user query requires enumeration coverage. A governed KgRecall seed committed, but no lexical-query-plan-v3 semantic_expansion batch has committed. Before any final answer or abstention, call KgRecall once with intent=enumeration and 2-4 distinct non-exact variants; the host will execute the whole batch. A seed miss or partial hit cannot justify completeness or unavailability.";

/// One bounded repair is allowed if a model still tries to end the run. The
/// agent loop rejects that premature final answer and gives the model a chance
/// to discharge the already-observed obligation.
pub const ENUMERATION_COVERAGE_REPAIR =
    "[lexical-coverage-rejected-final] Your proposed final answer was rejected by the host because enumeration coverage is still pending. Do not answer yet. Call KgRecall now with lexical-query-plan-v3, intent=enumeration, stage=semantic_expansion, and one fixed batch of 2-4 distinct non-exact variants. After the batch receipt, answer from the merged evidence.";

pub const ENUMERATION_CONTEXT_REMINDER =
    "[lexical-evidence-obligation] The enumeration batch committed and returned candidates, but no recalled node has been verified through KgContext. Call KgContext once on the best node_id from the governed recall result and inspect its authoritative text, graph scope, evidence, freshness, and supersession signals. Do not fan out to more nodes unless that result explicitly signals contradiction, supersession, truncation, or missing evidence.";

pub const ENUMERATION_CONTEXT_REPAIR =
    "[lexical-evidence-rejected-final] Your proposed final answer was rejected because the enumeration candidates remain unverified. Do not repeat KgRecall. Call KgContext once on the best node_id returned by the governed recall batch, inspect its graph and governance receipt, then produce the final answer. Only inspect another node if the first result explicitly signals contradiction, supersession, truncation, or missing evidence.";

/// Deliberately high-precision host hint. The model-declared intent remains a
/// second signal, but obvious cardinality wording must not be silently
/// downgraded to fact_lookup as happened in a paid calibration.
pub fn queryRequiresEnumerationCoverage(query: []const u8) bool {
    const ascii_phrases = [_][]const u8{
        "how many",
        "number of",
        "count of",
        "count the",
        "list all",
        "list every",
        "all matching",
        "every matching",
    };
    for (ascii_phrases) |phrase| {
        if (containsAsciiIgnoreCase(query, phrase)) return true;
    }
    const unicode_phrases = [_][]const u8{
        "多少",
        "几次",
        "几个",
        "几条",
        "几项",
        "列出所有",
        "列出全部",
        "全部列出",
    };
    for (unicode_phrases) |phrase| {
        if (std.mem.indexOf(u8, query, phrase) != null) return true;
    }
    return false;
}

fn containsAsciiIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or haystack.len < needle.len) return false;
    var offset: usize = 0;
    while (offset <= haystack.len - needle.len) : (offset += 1) {
        if (!std.ascii.eqlIgnoreCase(haystack[offset .. offset + needle.len], needle)) continue;
        const left_is_word = offset > 0 and isAsciiWordByte(haystack[offset - 1]);
        const right = offset + needle.len;
        const right_is_word = right < haystack.len and isAsciiWordByte(haystack[right]);
        if (!left_is_word and !right_is_word) return true;
    }
    return false;
}

fn isAsciiWordByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_';
}

test "enumeration coverage hint is high precision and multilingual" {
    try std.testing.expect(queryRequiresEnumerationCoverage("How many graduation ceremonies did I attend?"));
    try std.testing.expect(queryRequiresEnumerationCoverage("LIST ALL matching releases"));
    try std.testing.expect(queryRequiresEnumerationCoverage("一共有几次发布失败？"));
    try std.testing.expect(queryRequiresEnumerationCoverage("列出所有未关闭任务"));
    try std.testing.expect(!queryRequiresEnumerationCoverage("Install all dependencies"));
    try std.testing.expect(!queryRequiresEnumerationCoverage("Please discount the price"));
    try std.testing.expect(!queryRequiresEnumerationCoverage("Fix the counter implementation"));
}
