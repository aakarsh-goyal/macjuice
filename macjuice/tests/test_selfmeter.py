from macjuice import selfmeter


def test_parse_cputime_forms():
    assert selfmeter.parse_cputime("0:03.45") == 3.45
    assert selfmeter.parse_cputime("01:02:03") == 3723.0
    assert selfmeter.parse_cputime("1-00:00:00") == 86400.0
    assert selfmeter.parse_cputime("") is None


def test_parse_ps_finds_both_processes():
    text = (
        "  PID TIME     RSS ARGS\n"
        "  101 0:12.50  20480 /Users/x/Projects/macjuice/macjuice/.venv/bin/python -m macjuice.collector\n"
        "  202 1:05.00  51200 /Users/x/Projects/macjuice/macjuice/.venv/bin/python -m macjuice.app\n"
        "  303 9:99.00  10000 /usr/sbin/some-other-daemon\n"
    )
    d = selfmeter.parse_ps(text)
    assert round(d["collector_cpu_s"], 2) == 12.50
    assert round(d["dashboard_cpu_s"], 2) == 65.0
    assert round(d["collector_rss_mb"], 1) == 20.0   # 20480 KB -> 20 MB
    assert round(d["dashboard_rss_mb"], 1) == 50.0


def test_parse_ps_path_with_macjuice_is_not_mismatched():
    # a process whose path contains 'macjuice' but isn't our module must be ignored
    text = (
        "  PID TIME    RSS ARGS\n"
        "  500 0:01.00 1000 /Users/x/Projects/macjuice/notes/editor\n"
    )
    d = selfmeter.parse_ps(text)
    assert d["collector_cpu_s"] is None
    assert d["dashboard_cpu_s"] is None
