"""e2e_helpers 纯文件逻辑单测(离线,不起二进制,bin_path 未用)。

sync_auth_back 覆写用户真实 ~/.metacodes/auth.json——方向写反/守卫失灵的后果是
用过期凭证覆盖新凭证(与它要防的事故同级)。它是纯文件逻辑,凭证死亡状态下 live
路径无法验证,单测是唯一可行的验证面(仓库律:未测试路径=未验证)。
"""
import os
import sys
import json
import stat
import shutil
import tempfile

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from e2e_helpers import sync_auth_back  # noqa: E402


def _mk_home(oauth=None, raw=None):
    """建一个含 .metacodes/auth.json 的临时 HOME。oauth=None 则不写 oauth 键;raw 直写字节。"""
    home = tempfile.mkdtemp(prefix="unit-auth-home-")
    d = os.path.join(home, ".metacodes")
    os.makedirs(d)
    p = os.path.join(d, "auth.json")
    if raw is not None:
        with open(p, "w") as f:
            f.write(raw)
    else:
        body = {"api_key": "k"}
        if oauth is not None:
            body["oauth"] = oauth
        with open(p, "w") as f:
            json.dump(body, f)
    return home


def _mk_real(oauth, extra=None):
    fd, p = tempfile.mkstemp(prefix="unit-auth-real-", suffix=".json")
    body = dict(extra or {})
    if oauth is not None:
        body["oauth"] = oauth
    with os.fdopen(fd, "w") as f:
        json.dump(body, f)
    os.chmod(p, 0o600)
    return p


def _oauth(exp, rt="rt"):
    return {"access_token": "at", "refresh_token": rt, "expires_at": exp}


def _read(p):
    with open(p) as f:
        return json.load(f)


def test_sync_newer_seeded_writes_back_and_keeps_other_fields(bin_path):
    # seeded 更新 → 回传 oauth 块;真实文件其余字段(selected_model)原样保留;0600。
    home = _mk_home(oauth=_oauth(2000, "rt-new"))
    real = _mk_real(_oauth(1000, "rt-old"), extra={"selected_model": "m-user", "api_key": "real-k"})
    try:
        sync_auth_back(home, real_auth=real)
        r = _read(real)
        assert r["oauth"]["refresh_token"] == "rt-new", r
        assert r["oauth"]["expires_at"] == 2000, r
        assert r["selected_model"] == "m-user", "回传不得动 oauth 之外的字段"
        assert r["api_key"] == "real-k", "回传不得动 oauth 之外的字段"
        if os.name != "nt":  # Windows 无 POSIX mode 语义,断言仅在 POSIX 有意义
            mode = stat.S_IMODE(os.stat(real).st_mode)
            assert mode == 0o600, "凭证文件必须 0600,实际 %o" % mode
    finally:
        shutil.rmtree(home, ignore_errors=True)
        os.unlink(real)


def test_sync_stale_loose_tmp_still_writes_0600(bin_path):
    # 旧崩溃残留 0644 的 .tmp:O_CREAT 的 mode 只在创建时生效,复用不改权限 →
    # 显式 chmod 兜底,最终凭证文件仍必须 0600。
    if os.name == "nt":
        return
    home = _mk_home(oauth=_oauth(2000, "rt-new"))
    real = _mk_real(_oauth(1000, "rt-old"))
    stale = real + ".tmp"
    try:
        with open(stale, "w") as f:
            f.write("junk")
        os.chmod(stale, 0o644)
        sync_auth_back(home, real_auth=real)
        assert _read(real)["oauth"]["refresh_token"] == "rt-new"
        mode = stat.S_IMODE(os.stat(real).st_mode)
        assert mode == 0o600, "残留 tmp 复用后凭证文件权限泄漏成 %o" % mode
    finally:
        shutil.rmtree(home, ignore_errors=True)
        for p in (real, stale):
            try:
                os.unlink(p)
            except OSError:
                pass


def test_sync_older_or_equal_seeded_is_noop(bin_path):
    # seeded 更旧/相等 → 绝不覆盖(方向反了就是用过期凭证杀新凭证)。
    for seeded_exp in (500, 1000):
        home = _mk_home(oauth=_oauth(seeded_exp, "rt-stale"))
        real = _mk_real(_oauth(1000, "rt-current"))
        try:
            sync_auth_back(home, real_auth=real)
            assert _read(real)["oauth"]["refresh_token"] == "rt-current", \
                "seeded expires_at=%d 不得覆盖 real=1000" % seeded_exp
        finally:
            shutil.rmtree(home, ignore_errors=True)
            os.unlink(real)


def test_sync_seeded_without_refresh_token_is_noop(bin_path):
    # seeded oauth 缺 refresh_token(binary 写坏/清空)→ 不回传损坏状态。
    home = _mk_home(oauth={"access_token": "at", "expires_at": 9999})
    real = _mk_real(_oauth(1000, "rt-current"))
    try:
        sync_auth_back(home, real_auth=real)
        assert _read(real)["oauth"]["refresh_token"] == "rt-current"
    finally:
        shutil.rmtree(home, ignore_errors=True)
        os.unlink(real)


def test_sync_missing_files_is_noop(bin_path):
    # real 不存在 / seeded 不存在 → 静默 no-op 不炸。
    home = _mk_home(oauth=_oauth(2000))
    gone = tempfile.mktemp(prefix="unit-auth-gone-")
    try:
        sync_auth_back(home, real_auth=gone)  # real 缺
        assert not os.path.exists(gone)
        empty_home = tempfile.mkdtemp(prefix="unit-auth-empty-")
        real = _mk_real(_oauth(1000, "rt-current"))
        try:
            sync_auth_back(empty_home, real_auth=real)  # seeded 缺
            assert _read(real)["oauth"]["refresh_token"] == "rt-current"
        finally:
            shutil.rmtree(empty_home, ignore_errors=True)
            os.unlink(real)
    finally:
        shutil.rmtree(home, ignore_errors=True)


def test_sync_corrupt_seeded_json_is_noop(bin_path):
    # seeded 是半截 JSON(binary 写一半被杀)→ 不炸、real 不动。
    home = _mk_home(raw='{"oauth": {"refresh_')
    real = _mk_real(_oauth(1000, "rt-current"))
    try:
        sync_auth_back(home, real_auth=real)
        assert _read(real)["oauth"]["refresh_token"] == "rt-current"
    finally:
        shutil.rmtree(home, ignore_errors=True)
        os.unlink(real)


def test_offline_real_model_case_reports_skip(bin_path):
    # #222:TTY_SKIP_MODEL=1 下真模型用例要报 skip,不能 return 后被计为通过。
    import e2e_helpers
    saved = e2e_helpers.SKIP
    e2e_helpers.SKIP = True
    try:
        try:
            e2e_helpers.require_model()
        except e2e_helpers.SkipTest:
            pass
        else:
            raise AssertionError("require_model() 在 SKIP 下没有报 skip")
    finally:
        e2e_helpers.SKIP = saved


def test_no_case_turns_an_offline_skip_into_a_pass(bin_path):
    # 同一个缺陷的静态形态:用例自己读 TTY_SKIP_MODEL,或 `if SKIP:` 后直接 return。
    import re
    cases = os.path.dirname(os.path.abspath(__file__))
    offenders = []
    for fn in sorted(os.listdir(cases)):
        if not fn.endswith(".py"):
            continue
        with open(os.path.join(cases, fn), encoding="utf-8") as f:
            src = f.read()
        if re.search(r"if\s+SKIP\s*:\s*\n?\s*return\b", src) or "TTY_SKIP_MODEL\")" in src:
            offenders.append(fn)
    assert not offenders, "这些用例离线时把 skip 计成了通过,改用 require_model():" + ", ".join(offenders)


def test_case_tmpdirs_are_released(bin_path):
    # #222:用例自建的临时目录由 runner 在每个用例结束后删(失败也删)。
    from tty_driver import case_tmpdir, release_case_dirs
    made = [case_tmpdir("unit-case-dir-") for _ in range(2)]
    assert all(os.path.isdir(p) for p in made)
    release_case_dirs()
    assert not any(os.path.exists(p) for p in made), made
