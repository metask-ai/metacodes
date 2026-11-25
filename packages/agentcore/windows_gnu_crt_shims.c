/*
 * The bundled Zig compiler_rt defines roundq (binary128 round) as a weak
 * symbol, and std.json's integer parsing calls it. GNU ld does not load an
 * archive member to satisfy a reference with a weak definition, and MinGW's
 * own libraries do not provide roundq (libquadmath does), so MinGW-linked
 * consumers of the x86_64-windows-gnu archive, such as the Rust bindings'
 * cargo builds, failed with undefined references to it. This strong
 * definition, the musl algorithm compiler_rt also uses, resolves it; a Zig
 * link keeps one definition because the strong symbol overrides the weak one.
 * It is a link-visible support symbol, not an AgentCore ABI entry point.
 */
#if defined(__x86_64__)

typedef union {
    __float128 f;
    unsigned __int128 i;
} binary128;

__float128 roundq(__float128 x) {
    /* 2^112: adding and subtracting it drops the fraction bits. */
    const __float128 toint = (__float128)(1ULL << 56) * (__float128)(1ULL << 56);
    const __float128 half = 0.5;
    binary128 u = {x};
    unsigned exponent = (unsigned)(u.i >> 112) & 0x7fffu;
    int negative = (int)(u.i >> 127);
    volatile __float128 inexact;
    __float128 y;

    if (exponent >= 0x3fffu + 112u) return x; /* integral, infinite or NaN */
    if (negative) x = -x;
    if (exponent < 0x3fffu - 1u) { /* |x| < 0.5 */
        inexact = x + toint;
        (void)inexact;
        return 0 * u.f; /* zero with the sign of x */
    }
    y = x + toint - toint - x;
    if (y > half)
        y = y + x - 1;
    else if (y <= -half)
        y = y + x + 1;
    else
        y = y + x;
    return negative ? -y : y;
}

#endif
