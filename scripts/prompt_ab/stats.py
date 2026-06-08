"""双比例 z 检验 + Wilson 置信区间(纯函数,无依赖)。

提示词 A/B 的统计层:把"variant A 命中率 vs variant B 命中率"从裸百分点差,
升级成"差异是否统计显著(α=0.05)"+ 每个比率的置信区间。
不引第三方库(numpy/scipy),手算——题量小,精度足够。
"""
import math


def _phi(z):
    """标准正态 CDF(Abramowitz & Stegun 7.1.26 误差函数近似)。"""
    return 0.5 * (1.0 + math.erf(z / math.sqrt(2.0)))


def wilson_ci(successes, n, z=1.96):
    """Wilson score 95% 置信区间(比 normal approx 在小样本/极端比率下稳)。
    返回 (lo, hi),n==0 时返回 (0,1)。"""
    if n == 0:
        return (0.0, 1.0)
    p = successes / n
    denom = 1.0 + z * z / n
    center = (p + z * z / (2 * n)) / denom
    half = (z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n))) / denom
    return (max(0.0, center - half), min(1.0, center + half))


def two_proportion_z(s1, n1, s2, n2):
    """双比例 z 检验(双尾)。H0: p1==p2。
    返回 (z, p_value)。任一 n==0 → (0.0, 1.0)。
    用合并比例 p_pool 估标准误(标准双比例检验形式)。"""
    if n1 == 0 or n2 == 0:
        return (0.0, 1.0)
    p1, p2 = s1 / n1, s2 / n2
    p_pool = (s1 + s2) / (n1 + n2)
    se = math.sqrt(p_pool * (1 - p_pool) * (1.0 / n1 + 1.0 / n2))
    if se == 0:
        # 两比率完全相同(常见于都 0 或都 1)→ 无差异
        return (0.0, 1.0)
    z = (p1 - p2) / se
    p_value = 2.0 * (1.0 - _phi(abs(z)))
    return (z, p_value)


def fmt_rate(s, n):
    if n == 0:
        return "n/a (0)"
    lo, hi = wilson_ci(s, n)
    return f"{s}/{n}={s/n:.0%} [95%CI {lo:.0%}-{hi:.0%}]"


if __name__ == "__main__":
    # 自检:明显有差异的两组应显著
    z, p = two_proportion_z(18, 20, 8, 20)
    print(f"18/20 vs 8/20: z={z:.2f} p={p:.4f} -> {'显著' if p < 0.05 else '不显著'}")
    z, p = two_proportion_z(11, 20, 9, 20)
    print(f"11/20 vs 9/20: z={z:.2f} p={p:.4f} -> {'显著' if p < 0.05 else '不显著'}")
    print("wilson 9/20 =", wilson_ci(9, 20))
