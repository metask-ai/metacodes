# 评测报告:2026-09-01-frontierchallenge-official-judge

> 本文件由 generate_report.py 从 data/ 生成,请勿手改。

- 被测系统:**metacodes** @ `59dd28cdea9e` × glm-5.2 @ napi.metask-ai.com (anthropic wire)
- Judge:**gpt-5.6-sol (official pinned, per-task frozen judges, --no-judge-override)** ×3(定义内配置,可对标官方)
- 拓扑:patron long(15,conc3)+mainA(43,conc5);kunshan mainB(22,conc3)

## 结果

| 指标 | 值 |
|---|---|
| 判分题数 | 72(present 78/80) |
| Pass Rate(判分) | **45/72 = 62.5%** |
| Mean Score(判分) | **70.4 / 100** |
| 中位分 | 0.885 |
| Pass Rate(官方 97 分母) | 46.4% |
| Score(官方 97 分母) | 52.3 |
| Pass Rate(开放 81) | 55.6% |

分布(0.2 分档):12 / 2 / 6 / 10 / 42

## 残差

- `task_027_nitrosamine_lcms_nmr` — judge-flake/infra(计零)
- `task_030_disulfide_bond_ms` — judge-flake/infra(计零)
- `task_044_asymmetric_reduction_characterization` — genuine-0
- `task_045_dic_steel_tensile` — judge-flake/infra(计零)
- `task_046_lpbf_meltpool_xct` — judge-flake/infra(计零)
- `task_050_seawater_carbonate_system` — genuine-0
- `task_056_silica_melt_quench_md` — genuine-0
- `task_059_alanine_dipeptide_md` — judge-flake/infra(计零)
- `task_060_streptavidin_biotin_md` — genuine-0
- `task_073_ion_diffusion_lammps` — genuine-0
- `task_111_flyash_xrd_quantification` — judge-flake/infra(计零)
- `task_117_cp2k_mgo_phonon` — genuine-0

## 披露

- claude-CLI 无关(本轮 scaffold=metacodes);任务镜像含 pip 判分依赖与 CLI 焙层(见上一轮 meta)
- grader 包装加固:judge 每重复至多3次重试(官方judge偶发空分项JSON)、httpx proxies 垫片、fitz/PIL 守卫、dotenv 兜底、mime 跳过、pipchain
- 运行事故:早期 tests/.env 0600 权限伤及若干判分、kunshan 首航防火墙/stage 问题——受影响 trial 全部按基建纪律重跑;两题因分片 resume 边界未再入队,按零计
- 6 题在3次重试后仍因 judge 返回空分项(ids=[])不可判,按官方口径计零并披露

## 参照轮

- glm-judge round (2026-08-31):metacodes 55.7%/68.7, claude-code 64.1%/71.9 — judge=glm-5.2×3, 与本轮不可直接比(judge不同)
