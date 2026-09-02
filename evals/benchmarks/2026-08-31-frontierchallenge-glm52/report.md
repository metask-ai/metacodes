# 评测报告:2026-08-31-frontierchallenge-glm52

> 本文件由 `generate_report.py` 从 `data/` 自动生成,请勿手改。

## 概要

- **基准**: FrontierChallenge(open 赛道,官方分母 97,开放赛道 81 题,实跑 80 题)
- **模型**: glm-5.2 @ https://napi.metask-ai.com/v1/messages(anthropic-messages)
- **Judge**: glm-5.2 ×3(官方 pin:gpt-5.6-sol per-task frozen judges;scores are internally comparable between the two scaffold runs; NOT comparable with official-judge results)
- **对照设计**: 同机(patron (vm-ubuntu3))、同题、同模型、同 judge、同补丁与限时,仅 scaffold 不同

## 主结果

| 指标 | claude-code + glm-5.2 | metacodes + glm-5.2 |
|---|---|---|
| scaffold 版本 | 2.1.251 | main@59dd28c |
| 有效判分题数 | 78 | 79 |
| 通过数 | 50 | 44 |
| Pass Rate(判分口径) | **64.1%** | **55.7%** |
| Mean Score(判分口径) | **71.9** | **68.7** |
| 中位分 | 0.886 | 0.842 |
| Pass Rate(官方 97 分母) | 51.5% | 45.4% |
| Score(官方 97 分母) | 57.8 | 55.9 |
| Pass Rate(开放赛道 81) | 61.7% | 54.3% |

分数分布(判分题,按 0.2 分档):

| 区间 | 0–0.2 | 0.2–0.4 | 0.4–0.6 | 0.6–0.8 | 0.8–1.0 |
|---|---|---|---|---|---|
| claude-code | 9 | 5 | 8 | 8 | 48 |
| metacodes | 9 | 4 | 13 | 11 | 42 |

## 逐题对照

共同判分 78 题,通过判定一致 64 题(82.1%)。分歧最大者:

**metacodes 明显落后**(多为缺交付归零):

| 任务 | claude-code | metacodes | Δ |
|---|---|---|---|
| `task_206_smd_jarzynski_ala10` | 1.00 | 0.00 | -1.00 |
| `task_041_chromium_speciation_lcicpms` | 0.96 | 0.00 | -0.96 |
| `task_007_pxrd_indexing_cell_refinement` | 0.94 | 0.00 | -0.94 |
| `task_058_ki67_hscore_imaging` | 1.00 | 0.42 | -0.58 |
| `task_035_ebsd_austenite_reconstruction` | 0.88 | 0.40 | -0.48 |
| `task_038_hzo_pund_polarization` | 0.95 | 0.55 | -0.40 |

**metacodes 明显领先**(MD/计算化学簇):

| 任务 | claude-code | metacodes | Δ |
|---|---|---|---|
| `task_050_seawater_carbonate_system` | 0.00 | 0.57 | +0.57 |
| `task_044_asymmetric_reduction_characterization` | 0.00 | 0.60 | +0.60 |
| `task_203_qmmm_trypsin_link_atom` | 0.31 | 1.00 | +0.69 |
| `task_073_ion_diffusion_lammps` | 0.00 | 0.90 | +0.90 |
| `task_056_silica_melt_quench_md` | 0.00 | 0.90 | +0.90 |
| `task_061_mmgbsa_residue_decomposition` | 0.00 | 0.95 | +0.95 |

## 零分与残差明细

**claude-code** — 缺交付零分 9 题,不可判残差 2 题:

- 缺交付(genuine 0):`task_044_asymmetric_reduction_characterization`
- 缺交付(genuine 0):`task_050_seawater_carbonate_system`
- 缺交付(genuine 0):`task_056_silica_melt_quench_md`
- 缺交付(genuine 0):`task_060_streptavidin_biotin_md`
- 缺交付(genuine 0):`task_061_mmgbsa_residue_decomposition`
- 缺交付(genuine 0):`task_062_hydration_free_energy_ti`
- 缺交付(genuine 0):`task_064_protein_tremd_sampling`
- 缺交付(genuine 0):`task_073_ion_diffusion_lammps`
- 缺交付(genuine 0):`task_117_cp2k_mgo_phonon`
- 不可判(harness/verifier,按官方口径计零):`task_030_disulfide_bond_ms`
- 不可判(harness/verifier,按官方口径计零):`task_072_pt_co_adsorption`

**metacodes** — 缺交付零分 7 题,不可判残差 1 题:

- 缺交付(genuine 0):`task_007_pxrd_indexing_cell_refinement`
- 缺交付(genuine 0):`task_030_disulfide_bond_ms`
- 缺交付(genuine 0):`task_041_chromium_speciation_lcicpms`
- 缺交付(genuine 0):`task_060_streptavidin_biotin_md`
- 缺交付(genuine 0):`task_062_hydration_free_energy_ti`
- 缺交付(genuine 0):`task_114_he_tumor_infiltration`
- 缺交付(genuine 0):`task_117_cp2k_mgo_phonon`
- 不可判(harness/verifier,按官方口径计零):`task_072_pt_co_adsorption`

## 结构性结论

- 两 scaffold 交付纪律互补:claude-code 独有缺交付 6 题,metacodes 独有 4 题——差距主要不在解题力,而在是否把任务规定的 deliverables 完整写入 `/app/output`。
- metacodes 在分子动力学/计算化学工作流上系统性占优;在部分分析化学/晶体学任务上因漏交文件归零。

## 附:FrontierScience-Olympiad(同模型,public harness)

- 题数 100,判对 74(当前数据为重试后状态 74.0%;首跑口径 70.0%,重试策略见 meta.json)
- 单题时长 p50 = 132s,最长 601s;无答案题 5 题

## 披露清单(结果解读必读)

- 任务镜像:claude CLI 2.1.251 + nodejs baked via npmmirror (downloads.claude.ai unreachable from CN); pristine image kept as :2026.08-orig
- grader 包装补丁:run_frontier_verifier.py: one retry per failed judge repetition
- grader 包装补丁:run_judge.py: httpx 'proxies' kwarg compat shim (after __future__ imports)
- grader 包装补丁:run_judge.py: fitz/PIL import guards (indentation-aware)
- grader 包装补丁:run_judge.py: explicit /tests/.env dotenv fallback + tests/.env credential file
- grader 包装补丁:run_judge.py: non-image artifact mime rejection converted to skip-with-note
- grader 包装补丁:test.sh: pip install fallback chain (env mirror -> direct pypi -> pip upgrade)
- 重跑纪律:trials whose verifier/harness failed for infrastructure reasons were deleted and rerun; genuine agent failures (missing deliverables) kept from their original attempt; task_072 failed verifier-env chronically in BOTH runs and counts zero in both
- 剔除:`task_098_orca_claisen_thermochemistry` — upstream registry labels it open-image but preflight requires licensed ORCA 6.0.1
- Judge 传输层:litellm shim on 172.17.0.1:4400 (OpenAI->anthropic), thinking disabled via extra_body, max_tokens floor 16384, image parts replaced by text placeholder (text-only judge), non-image artifacts skipped, component-id compliance note appended (active for claude-code final retry round and all metacodes tasks)
- 网络:CN network: HF via Mac relay (xet CDN + tree pagination broken via mirror), npm via npmmirror, apt via TUNA, pip via TUNA with fallback chain, model+judge traffic via metask gateway

## 数据文件

- `data/run-claude-code/summary.{json,csv}` — claude-code 全量逐题明细
- `data/run-metacodes/summary.{json,csv}` — metacodes 全量逐题明细
- `data/olympiad-glm52/results.json` — olympiad 逐题明细
- `data/meta.json` — 环境、版本、判分配置、披露与时间线
- 原始 trial 产物(transcript/verifier 日志)在 patron (vm-ubuntu3):`~/frontier-bench/FrontierAgent/benchmarks/frontierchallenge/results/harbor/`
