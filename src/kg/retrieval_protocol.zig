//! TinyKG 无向量检索的模型侧 lexical bridge 协议。
//!
//! TinyKG 只负责确定性的 BM25/图检索；语义扩展与命中判读由 LLM 完成。把同一份
//! 协议同时接到 system prompt、KgRecall schema、自动召回提醒和工具结果，避免某条
//! agent 入口只看到一句弱提示后退化成裸 query。

/// system prompt 中的强制协议。所谓“语义邻域”是模型判断，不暗示底层计算向量距离。
pub const SYSTEM_RULES =
    \\Lexical retrieval algorithm (mandatory whenever KgRecall is warranted; follow in order):
    \\- TinyKG uses lexical BM25 and computes no embeddings or vector distance. A lexical miss is not proof that the knowledge is absent.
    \\- Step 1 — SCAN FIRST: inspect any automatically recalled memory lines before forming a query.
    \\- Step 2A — ALIAS BRANCH HAS PRIORITY: if an automatic hit contains an exact canonical alias or code symbol, the first explicit query MUST contain only that exact term plus field names already requested by the user, and MUST omit `type`. Taking the broad branch instead, or adding terms not copied from the user or that hit, is a protocol violation.
    \\- Step 2B — BROAD BRANCH ONLY IF NO ALIAS WAS EXPOSED: preserve the user's exact terms and add only 3-8 high-confidence lexical equivalents: synonyms, Chinese/English forms, aliases/acronyms, current/legacy names, or code identifiers. Every added term must be a direct substitute for a user term, not merely related to the topic.
    \\- Step 2C — TOKEN PROVENANCE CHECK: before calling KgRecall, classify every query term as U (copied from the user), H (copied from a hit), or P (a direct paraphrase/translation of one U term). Delete every term that cannot receive exactly one of those labels. A term that proposes how the answer may work is related context, not a paraphrase, and must be deleted.
    \\- Step 3 — JUDGE: assess hits semantically yourself; BM25 score is lexical evidence, not semantic correctness. A bridge may be an observation/module even when the final fact is a decision, so the first explicit KgRecall always omits `type`.
    \\- Step 4 — ONE CALIBRATION MAX: after an untyped broad probe, make at most one focused follow-up using exact aliases/symbols learned from its hits; only then may `type` be used if a hit explicitly justifies the facet. Total explicit KgRecall calls: at most two. If Step 2A applied, make that one focused call and stop widening.
;

pub const TOOL_DESCRIPTION =
    "Search the knowledge graph for durable memories (decisions, preferences, project facts) from this and past sessions. " ++
    "Use when the user refers to prior decisions/context or when continuing cross-session work. Retrieval is LEXICAL BM25: TinyKG has no embeddings and computes no vector distance, so you must supply and judge the semantics using the mandatory bounded lexical-bridge protocol in the query field. " ++
    "Hits carrying a \"source\" field come from a memory markdown file; update that file instead of KgRemembering a duplicate.";

pub const QUERY_DESCRIPTION =
    "Follow the lexical decision tree exactly. FIRST inspect automatic recall. If it exposed an exact canonical alias/code symbol, this query MUST contain ONLY that exact term plus user-requested field names; OMIT type and DO NOT add anything else. Use the broad branch only when automatic hits exposed no exact term: keep user terms and add only 3-8 intent-preserving equivalents (synonyms, Chinese/English forms, aliases/acronyms, current/legacy names, code identifiers). Before calling, label every term U (copied from user), H (copied from hit), or P (direct paraphrase/translation of one U term), and DELETE every unlabeled term. Topically related implementation guesses are not paraphrases. At most TWO explicit calls total; a second call must be focused on exact hit terms. A lexical miss does not prove absence.";

pub const TYPE_DESCRIPTION =
    "Optional facet filter: decision | user_preference | module | bug | observation. NEVER set this on the first explicit KgRecall. A bridge that names the final decision may itself be an observation or module, so filtering early can hide it. Use type only for the single allowed follow-up and only when an earlier untyped hit explicitly supports that facet; otherwise omit it.";

/// 自动召回用原始 user 文本，未经过 LLM 扩词；必须显式告诉模型它不是权威缺席判断。
pub const AUTO_RECALL_NOTE =
    "This automatic recall was one untyped raw-message lexical BM25 probe (no LLM expansion, no embeddings). Treat absence or partial coverage as non-authoritative. If a hit exposes an exact canonical alias/symbol, use it directly in one focused untyped KgRecall with only user-requested field names. Otherwise the first explicit KgRecall must be an untyped bounded lexical bridge whose every term passes the U/H/P provenance check.";

/// 放在自动命中之后：模型在决策点最后读到的必须是下一步，而不是让若干 hit 把前置规则冲淡。
pub const AUTO_RECALL_NEXT_ACTION =
    "强制下一步 / MANDATORY NEXT ACTION: 先检查上面的命中。只要任一命中给出 canonical alias 或代码符号，下一次 KgRecall 就必须是无 type 的聚焦查询，且只能包含该精确词和用户已要求的字段名；不要添加任何其他词。仅当命中没有给出精确词时，才可做一次无 type 的受限扩词；逐词标记 U=用户原词、H=命中原词、P=某个 U 的直接同义改写/翻译，删除所有无法标记的词。";

/// 每次 KgRecall 结果都携带的短提示：把“读命中后校准”放到决策时点，而非只靠远端 system prompt。
pub const RESULT_GUIDANCE =
    "Semantically judge these lexical hits. Reuse exact aliases or symbols from them for at most one focused KgRecall containing only the alias and user-requested fields; do not widen to related topics. Use a type filter only if these untyped hits explicitly justify the facet.";
