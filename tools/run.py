"""Runs the whole project end to end and regenerates every diagram.

Works the same on Windows, macOS and Linux; started by the launchers
`run` (macOS / Linux), `run.ps1` (PowerShell) and `run.cmd` (cmd.exe).

  1. detects the operating system and finds PostgreSQL and Python
  2. starts a private PostgreSQL cluster in .pgdata (port 5433, created on first run)
  3. drops and recreates the database
  4. runs every SQL module, the seed data, the test suite and the EXPLAIN evidence
     in one psql session, showing each step with its timing and statement counts
  5. prints the database inventory, row counts and the first rows of every report view
  6. regenerates docs/EER_v2.html and output/diagrams.html (no PDF)
Everything is also written to output/run.log.

Options (any spelling works: --skip-explain, -SkipExplain, -skipexplain):
  --skip-explain   skip the 200 000-row EXPLAIN benchmark
  --quiet          only step summaries, no statement tags
  --no-open        do not open the diagrams page at the end
  --external       use an already running server (PGHOST / PGPORT / PGUSER / PGPASSWORD)
  --port N         port of the private cluster (default 5433)
  --database NAME  database name (default labdb)
  --stop           stop the private cluster
"""
import glob
import os
import platform
import re
import shutil
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "output")
PGDATA = os.path.join(ROOT, ".pgdata")
LOG = os.path.join(OUT, "run.log")
OS = platform.system()                       # 'Windows', 'Darwin', 'Linux'
OS_NAME = {"Windows": "Windows", "Darwin": "macOS", "Linux": "Linux"}.get(OS, OS)
EXE = ".exe" if OS == "Windows" else ""

STEPS = [
    ("sql/00_setup.sql",     "public",    "extensions, shared enum types, helper functions"),
    ("sql/01_org.sql",       "org",       "departments, labs, persons, advising, projects"),
    ("sql/02_inventory.sql", "inventory", "categories, equipment, components, transfers, consumables"),
    ("sql/03_training.sql",  "training",  "courses, sessions, attendance, authorization"),
    ("sql/04_booking.sql",   "booking",   "reservations, approval workflow, waitlist, usage"),
    ("sql/05_service.sql",   "service",   "maintenance, incidents, calibration"),
    ("sql/06_finance.sql",   "finance",   "owners, grants, rate cards, charges"),
    ("sql/07_audit.sql",     "audit",     "partitioned change log, roles, row-level security"),
    ("sql/08_reports.sql",   "report",    "reporting views, materialized view"),
    ("sql/09_indexes.sql",   "indexes",   "indexes from access patterns"),
    ("sql/90_seed.sql",      "seed",      "sample data on a pinned clock"),
    ("tests/95_tests.sql",   "tests",     "positive / negative / concurrency tests"),
]
EXPLAIN_STEP = ("tests/96_explain.sql", "explain", "200 000 rows, plans with and without each index (rolled back)")

TAG_RE = re.compile(r"^(CREATE|ALTER|DROP|INSERT|UPDATE|DELETE|SELECT|COMMENT|GRANT|REVOKE|SET|RESET|DO|CALL|BEGIN|"
                    r"COMMIT|ROLLBACK|REFRESH MATERIALIZED VIEW|TRUNCATE|ANALYZE|COPY|SAVEPOINT|RELEASE|LOCK|VACUUM|"
                    r"MERGE)( [A-Z][A-Z ]*?)?((?: \d+)*)$")


# ===================================================================== output
class Term:
    CODES = {"gray": "37", "dark": "90", "red": "91", "green": "92", "yellow": "93", "cyan": "96",
             "dcyan": "36", "white": "97", "bold": "1"}

    def __init__(self):
        try:
            sys.stdout.reconfigure(encoding="utf-8", errors="replace")
        except (AttributeError, ValueError):
            pass
        self.color = sys.stdout.isatty() and not os.environ.get("NO_COLOR")
        if self.color and OS == "Windows":
            os.system("")                    # turns on ANSI escape handling in the Windows console
        os.makedirs(OUT, exist_ok=True)
        self.log = open(LOG, "w", encoding="utf-8")

    def say(self, text="", color="gray"):
        if self.color and color in self.CODES:
            print(f"\x1b[{self.CODES[color]}m{text}\x1b[0m", flush=True)
        else:
            print(text, flush=True)
        self.log.write(text + "\n")

    def rule(self, title, color="cyan"):
        self.say()
        self.say("=" * 78, color)
        self.say("  " + title, color)
        self.say("=" * 78, color)

    def fail(self, msg):
        self.say()
        self.say("  FAILED: " + msg, "red")
        self.say("  full log: " + LOG, "dark")
        self.log.close()
        sys.exit(1)


def fmt_time(s):
    return f"{s * 1000:6.0f} ms" if s < 1 else f"{s:6.2f} s "


# ===================================================================== arguments
def parse_args(argv):
    opts = {"skipexplain": False, "quiet": False, "noopen": False, "external": False, "stop": False,
            "port": 5433, "database": "labdb"}
    alias = {"db": "database", "d": "database", "p": "port", "q": "quiet", "h": "help", "?": "help"}
    i = 0
    while i < len(argv):
        raw = argv[i]
        key, _, val = raw.lstrip("-/").partition("=")
        key = alias.get(key.lower(), key.replace("-", "").replace("_", "").lower())
        key = alias.get(key, key)
        if key == "help":
            print(__doc__)
            sys.exit(0)
        if key in ("port", "database"):
            if not val:
                i += 1
                if i >= len(argv):
                    sys.exit(f"missing value for {raw}")
                val = argv[i]
            opts[key] = int(val) if key == "port" else val
        elif key in opts:
            opts[key] = True
        else:
            sys.exit(f"unknown option {raw}  (see --help)")
        i += 1
    return opts


# ===================================================================== tools
def version_key(path):
    """(major, minor) from a path segment such as 18, postgresql@18, pgsql-18, 17.4; (0, 0) if none."""
    best = (0, 0)
    for seg in re.split(r"[\\/]", path):
        m = re.search(r"(?:^|[@-])(\d+)(?:\.(\d+))?$", seg)
        if m:
            best = max(best, (int(m.group(1)), int(m.group(2) or 0)))
    return best


def find_pg_bin(need_server):
    """Directory holding psql (and pg_ctl + initdb when we run our own cluster)."""
    cands = []
    if OS == "Windows":
        for base in (os.environ.get("ProgramFiles", r"C:\Program Files"), os.environ.get("ProgramFiles(x86)", "")):
            if base:
                cands += glob.glob(os.path.join(base, "PostgreSQL", "*", "bin"))
    elif OS == "Darwin":
        cands += glob.glob("/opt/homebrew/opt/postgresql@*/bin") + glob.glob("/usr/local/opt/postgresql@*/bin")
        cands += glob.glob("/Applications/Postgres.app/Contents/Versions/*/bin")
        cands += glob.glob("/Library/PostgreSQL/*/bin")
        cands += ["/opt/homebrew/opt/postgresql/bin", "/usr/local/opt/postgresql/bin", "/opt/homebrew/bin", "/usr/local/bin"]
    else:
        cands += glob.glob("/usr/lib/postgresql/*/bin") + glob.glob("/usr/pgsql-*/bin")
        cands += glob.glob("/usr/local/pgsql*/bin") + ["/usr/bin", "/usr/local/bin"]
    psql_on_path = shutil.which("psql")
    if psql_on_path:
        cands.insert(0, os.path.dirname(os.path.realpath(psql_on_path)))
        cands.insert(0, os.path.dirname(psql_on_path))
    tools = ["psql"] + (["pg_ctl", "initdb", "createdb", "dropdb"] if need_server else [])
    ok = [d for d in dict.fromkeys(cands)
          if all(os.path.isfile(os.path.join(d, t + EXE)) for t in tools)]
    if not ok:
        return None
    # prefer the newest version; PATH entries only win among equal versions
    return sorted(ok, key=lambda d: version_key(d), reverse=True)[0] if any(version_key(d) > (0, 0) for d in ok) else ok[0]


def install_hint():
    return {"Windows": "install PostgreSQL 18 from https://www.postgresql.org/download/windows/",
            "Darwin": "brew install postgresql@18   (or Postgres.app)",
            "Linux": "sudo apt install postgresql-18 postgresql-contrib   (or your distribution's package)"}.get(OS, "")


def run(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8", errors="replace", **kw)


def stream(cmd, on_line):
    p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    for raw in p.stdout:
        on_line(raw.decode("utf-8", "replace").rstrip("\r\n"))
    return p.wait()


def open_file(path):
    try:
        if OS == "Windows":
            os.startfile(path)  # noqa: S606
        elif OS == "Darwin":
            subprocess.Popen(["open", path])
        elif shutil.which("xdg-open") and (os.environ.get("DISPLAY") or os.environ.get("WAYLAND_DISPLAY")):
            subprocess.Popen(["xdg-open", path], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except OSError:
        pass


# ===================================================================== main
def main():
    o = parse_args(sys.argv[1:])
    os.environ.update(PGCLIENTENCODING="UTF8", LC_MESSAGES="C", LANGUAGE="C")
    t = Term()
    pg_bin = find_pg_bin(need_server=not o["external"])
    if not pg_bin:
        t.fail(("PostgreSQL client tools not found" if o["external"] else
                "PostgreSQL server tools (psql, pg_ctl, initdb) not found") + " - " + install_hint())
    exe = lambda n: os.path.join(pg_bin, n + EXE)  # noqa: E731
    psql, pg_ctl = exe("psql"), exe("pg_ctl")

    if o["stop"]:
        r = run([pg_ctl, "stop", "-D", PGDATA, "-m", "fast"])
        t.say((r.stdout + r.stderr).strip())
        t.log.close()
        sys.exit(r.returncode)

    started = time.time()
    commit = ""
    if shutil.which("git"):
        commit = run(["git", "-C", ROOT, "log", "-1", "--format=%h %s"]).stdout.strip()
        branch = run(["git", "-C", ROOT, "branch", "--show-current"]).stdout.strip()
        if branch:
            commit = f"{commit}  [{branch}]"

    t.rule("University Research Laboratory & Equipment Management System - full run")
    t.say("  started   " + time.strftime("%Y-%m-%d %H:%M:%S"))
    t.say("  folder    " + ROOT)
    if commit:
        t.say("  commit    " + commit)

    # ------------------------------------------------------------- 1. environment
    t.rule("1. Environment")
    t.say(f"  system    {OS_NAME} {platform.release()} ({platform.machine()})")
    t.say(f"  psql      {run([psql, '--version']).stdout.strip()}  ({pg_bin})")
    t.say(f"  python    Python {platform.python_version()}  ({sys.executable})")

    # ------------------------------------------------------------- 2. server
    t.rule("2. PostgreSQL server")
    port = o["port"]
    if o["external"]:
        os.environ.setdefault("PGHOST", "localhost")
        os.environ.setdefault("PGPORT", "5432")
        os.environ.setdefault("PGUSER", "postgres")
        t.say(f"  using external server {os.environ['PGHOST']}:{os.environ['PGPORT']} as {os.environ['PGUSER']}")
    else:
        if OS != "Windows" and hasattr(os, "geteuid") and os.geteuid() == 0:
            t.fail("PostgreSQL refuses to run as root - run as a normal user, or use --external")
        if not os.path.isfile(os.path.join(PGDATA, "PG_VERSION")):
            t.say(f"  creating private cluster in {PGDATA} (first run only) ...", "yellow")
            code = stream([exe("initdb"), "-D", PGDATA, "-U", "postgres", "-A", "trust", "-E", "UTF8",
                           "--locale=C", "--no-instructions"], lambda l: t.say("    " + l, "dark"))
            if code != 0:
                t.fail("initdb failed")
        running = os.path.isfile(os.path.join(PGDATA, "postmaster.pid")) and \
            run([pg_ctl, "status", "-D", PGDATA]).returncode == 0
        if running:
            with open(os.path.join(PGDATA, "postmaster.pid")) as f:
                lines = f.read().splitlines()
            if len(lines) > 3 and lines[3].strip().isdigit():
                port = int(lines[3])
            t.say(f"  private cluster already running on port {port}")
        else:
            t.say(f"  starting private cluster on port {port} ...")
            server_opts = f"-p {port} -c lc_messages=C"
            if OS != "Windows":
                # no Unix socket (its path length is limited); everything goes through localhost TCP
                server_opts += " -c unix_socket_directories=''"
            # PGHOST in the server's environment makes dblink (concurrency tests) connect over TCP too
            env = dict(os.environ, PGHOST="localhost")
            ctl_out = os.path.join(OUT, "_pg_ctl.txt")
            with open(ctl_out, "w") as f:      # a file, not a pipe: the postmaster keeps running after us
                code = subprocess.call([pg_ctl, "start", "-D", PGDATA, "-l", os.path.join(OUT, "postgres.log"),
                                        "-w", "-t", "60", "-o", server_opts], stdout=f, stderr=subprocess.STDOUT, env=env)
            with open(ctl_out, encoding="utf-8", errors="replace") as f:
                for line in f.read().splitlines():
                    t.say("    " + line, "dark")
            if code != 0:
                t.fail("server did not start, see " + os.path.join(OUT, "postgres.log"))
        os.environ.update(PGHOST="localhost", PGPORT=str(port), PGUSER="postgres")
    r = run([psql, "-X", "-At", "-d", "postgres", "-c", "SHOW server_version"])
    if r.returncode != 0:
        t.fail("cannot connect: " + r.stderr.strip())
    t.say(f"  connected: PostgreSQL {r.stdout.strip()} at {os.environ['PGHOST']}:{os.environ['PGPORT']}, "
          f"user {os.environ['PGUSER']}", "green")

    # ------------------------------------------------------------- 3. database
    db = o["database"]
    t.rule(f"3. Fresh database '{db}'")
    for cmd in ([exe("dropdb"), "--if-exists", "--force", db], [exe("createdb"), db]):
        if not os.path.isfile(cmd[0]):      # --external with client-only tools
            cmd = [psql, "-X", "-q", "-d", "postgres", "-c",
                   f'DROP DATABASE IF EXISTS "{db}" WITH (FORCE)' if "dropdb" in cmd[0] else f'CREATE DATABASE "{db}"']
        code = stream(cmd, lambda l: t.say("  " + l, "dark"))
        if code != 0:
            t.fail(f"{os.path.basename(cmd[0])} failed")
    t.say(f"  dropped and recreated {db}", "green")

    # ------------------------------------------------------------- 4. scripts
    steps = STEPS + ([] if o["skipexplain"] else [EXPLAIN_STEP])
    driver = os.path.join(OUT, "_driver.sql")
    lines = ["\\set ON_ERROR_STOP on", "\\pset pager off", "SET client_min_messages = warning;"]
    for i, (f, _, _) in enumerate(steps):
        path = os.path.join(ROOT, f)
        if not os.path.isfile(path):
            t.fail("missing script " + f)
        lines += [f"\\echo @@STEP|{i}", "\\i '" + path.replace("\\", "/").replace("'", "\\'") + "'"]
    lines.append("\\echo @@END")
    with open(driver, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")

    t.rule(f"4. Build, seed and test  ({len(steps)} scripts, one psql session)")
    st = {"cur": -1, "t0": 0.0, "tags": {}, "last": None, "n": 0}
    results = []

    def flush_tag():
        if st["last"]:
            if not o["quiet"]:
                t.say("      " + st["last"] + (f"  x{st['n']}" if st["n"] > 1 else ""), "dark")
            st["last"], st["n"] = None, 0

    def close_step(ok):
        if st["cur"] < 0:
            return
        flush_tag()
        secs = time.time() - st["t0"]
        parts = [f"{k} {c} ({rows} rows)" if k in ("INSERT", "UPDATE", "DELETE") else f"{k} {c}"
                 for k, (c, rows) in st["tags"].items()]
        f, mod, _ = steps[st["cur"]]
        t.say(f"   [{' OK ' if ok else 'FAIL'}] {fmt_time(secs)}  {f}", "green" if ok else "red")
        if parts:
            t.say("          " + ", ".join(parts), "dcyan")
        results.append((f, mod, secs, ok))
        st["cur"] = -1

    def on_line(l):
        m = re.match(r"^@@STEP\|(\d+)$", l)
        if m:
            close_step(True)
            st["cur"] = int(m.group(1))
            f, _, desc = steps[st["cur"]]
            t.say()
            t.say(f"  >> [{st['cur'] + 1:02d}/{len(steps):02d}] {f:<22} {desc}", "white")
            st["t0"], st["tags"] = time.time(), {}
            return
        if l == "@@END":
            close_step(True)
            return
        is_test = st["cur"] >= 0 and steps[st["cur"]][1] in ("tests", "explain")
        m = TAG_RE.match(l)
        if m:
            tag = (m.group(1) + (m.group(2) or "")).strip()
            nums = m.group(3).split()
            rows = int(nums[-1]) if nums else 0
            if st["cur"] >= 0:
                c, r_ = st["tags"].get(tag, (0, 0))
                st["tags"][tag] = (c + 1, r_ + rows)
            shown = f"{tag} ({rows} rows)" if tag in ("INSERT", "UPDATE", "DELETE") else tag
            if shown == st["last"]:
                st["n"] += 1
            else:
                flush_tag()
                st["last"], st["n"] = shown, 1
            return
        flush_tag()
        if re.search(r"(^|: )(ERROR|FATAL|PANIC):", l):
            t.say("      " + l, "red")
        elif re.search(r"(^|: )(WARNING|NOTICE):", l):
            t.say("      " + l, "yellow")
        elif l.startswith("====="):
            t.say()
            t.say("    " + l, "cyan")
        elif l.startswith("-----"):
            t.say("    " + l, "dcyan")
        elif is_test:
            color = ("green" if re.search(r"\| PASS\s*$", l) else "red" if re.search(r"\| FAIL\s*$", l)
                     else "yellow" if "| skipped" in l else "gray")
            t.say("    " + l, color)
        elif l.strip() and not o["quiet"]:
            t.say("      " + l, "dark")

    code = stream([psql, "-X", "-d", db, "-v", "ON_ERROR_STOP=1", "-f", driver], on_line)
    if code != 0:
        at = steps[st["cur"]][0] if st["cur"] >= 0 else "?"
        close_step(False)
        t.fail(f"psql stopped in {at} (exit code {code})")

    # ------------------------------------------------------------- 5 / 6. inventory and reports
    width = max(100, shutil.get_terminal_size((156, 40)).columns - 6)
    fmt = f"\\pset pager off\n\\pset format wrapped\n\\pset columns {width}\n\\pset border 2\n\\pset linestyle unicode\n"

    def run_sql(sql):
        tmp = os.path.join(OUT, "_query.sql")
        with open(tmp, "w", encoding="utf-8") as f:
            f.write(fmt + sql)

        def show(l):
            if l.startswith("====="):
                t.say()
                t.say("  " + l, "cyan")
            else:
                t.say("    " + l, "red" if "ERROR:" in l else "gray")
        stream([psql, "-X", "-d", db, "-v", "ON_ERROR_STOP=1", "-f", tmp], show)

    t.rule("5. Database inventory")
    run_sql(INVENTORY_SQL)

    t.rule("6. Report views (first 5 rows of each)")
    views = run([psql, "-X", "-At", "-d", db, "-c",
                 "SELECT schemaname||'.'||viewname FROM pg_views WHERE schemaname='report' UNION ALL "
                 "SELECT schemaname||'.'||matviewname FROM pg_matviews WHERE schemaname='report' ORDER BY 1"]).stdout.split()
    run_sql("SET lab.now = '2026-12-01 09:00:00+03';\nSET TIME ZONE 'Europe/Istanbul';\n" +
            "".join(f"\\echo ===== {v} =====\nSELECT * FROM {v} LIMIT 5;\n" for v in views))

    tr = run([psql, "-X", "-At", "-F", "|", "-d", db, "-c",
              "SELECT count(*), count(*) FILTER (WHERE passed), count(*) FILTER (WHERE observed = 'skipped') "
              "FROM test.result"]).stdout.strip().split("|")
    t_total, t_pass, t_skip = (int(x) for x in tr) if len(tr) == 3 else (0, 0, 0)

    # ------------------------------------------------------------- 7. diagrams
    t.rule("7. Diagrams (regenerated from the current code and the live database)")
    html_path, diagram_ok = None, False
    try:
        sys.path.insert(0, os.path.join(ROOT, "tools"))
        import build_diagrams
        html_path = build_diagrams.generate(psql, os.environ["PGHOST"], os.environ["PGPORT"], os.environ["PGUSER"],
                                            db, OUT, log=t.say)
        diagram_ok = True
    except Exception as e:  # noqa: BLE001
        t.say(f"  diagram generation failed: {e!r}", "red")

    # ------------------------------------------------------------- summary
    t.rule("Summary", "green")
    for f, mod, secs, ok in results:
        t.say(f"  {' OK ' if ok else 'FAIL'}  {fmt_time(secs)}  {f:<22} {mod}", "green" if ok else "red")
    t.say()
    skipped = f" ({t_skip} skipped)" if t_skip else ""
    t.say(f"  tests       {t_pass} / {t_total} passed{skipped}", "green" if t_pass == t_total and t_total else "red")
    t.say(f"  total time  {time.time() - started:.1f} s")
    t.say()
    t.say("  generated files", "white")
    for f in (html_path, os.path.join(ROOT, "docs", "EER_v2.html"), LOG):
        if f and os.path.isfile(f):
            t.say("    " + f, "cyan")
    t.say()
    t.say("  connect to the database:", "white")
    q = (lambda s: f"& '{s}'") if OS == "Windows" else (lambda s: f"'{s}'")
    t.say(f"    {q(psql)} -h {os.environ['PGHOST']} -p {os.environ['PGPORT']} -U {os.environ['PGUSER']} -d {db}", "dark")
    if not o["external"]:
        launcher = ".\\run" if OS == "Windows" else "./run"
        t.say(f"  stop the private server:   {launcher} --stop", "dark")
    t.log.close()

    if diagram_ok and not o["noopen"]:
        open_file(html_path)
    sys.exit(0 if diagram_ok and t_total and t_pass == t_total else 1)


INVENTORY_SQL = r"""
\echo ===== Objects per schema =====
WITH s AS (SELECT oid, nspname FROM pg_namespace
           WHERE nspname IN ('public','org','inventory','training','booking','service','finance','audit','report'))
SELECT s.nspname AS schema,
  (SELECT count(*) FROM pg_class c WHERE c.relnamespace=s.oid AND c.relkind IN ('r','p') AND NOT c.relispartition) AS tables,
  (SELECT count(*) FROM pg_class c WHERE c.relnamespace=s.oid AND c.relispartition) AS partitions,
  (SELECT count(*) FROM pg_class c WHERE c.relnamespace=s.oid AND c.relkind IN ('v','m')) AS views,
  (SELECT count(*) FROM pg_proc p WHERE p.pronamespace=s.oid
     AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid=p.oid AND d.deptype='e')) AS functions,
  (SELECT count(*) FROM pg_trigger t JOIN pg_class c ON c.oid=t.tgrelid
     WHERE c.relnamespace=s.oid AND NOT t.tgisinternal AND t.tgparentid=0) AS triggers,
  (SELECT count(*) FROM pg_constraint k JOIN pg_class c ON c.oid=k.conrelid
     WHERE c.relnamespace=s.oid AND k.contype='f' AND k.conparentid=0) AS fks,
  (SELECT count(*) FROM pg_constraint k JOIN pg_class c ON c.oid=k.conrelid
     WHERE c.relnamespace=s.oid AND k.contype IN ('c','x') AND k.conparentid=0) AS "check/excl",
  (SELECT count(*) FROM pg_index i JOIN pg_class c ON c.oid=i.indexrelid JOIN pg_class r ON r.oid=i.indrelid
     WHERE c.relnamespace=s.oid AND NOT r.relispartition) AS indexes,
  (SELECT count(*) FROM pg_policy pl JOIN pg_class c ON c.oid=pl.polrelid WHERE c.relnamespace=s.oid) AS policies
FROM s ORDER BY array_position(ARRAY['public','org','inventory','training','booking','service','finance','audit','report'], s.nspname::text);

\echo ===== Rows per table (after seed) =====
SELECT n.nspname AS schema, c.relname AS "table",
       (xpath('/row/c/text()', query_to_xml(format('SELECT count(*) AS c FROM %I.%I', n.nspname, c.relname), false, true, '')))[1]::text::int AS rows
FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
WHERE c.relkind IN ('r','p') AND NOT c.relispartition
  AND n.nspname IN ('org','inventory','training','booking','service','finance','audit')
ORDER BY array_position(ARRAY['org','inventory','training','booking','service','finance','audit'], n.nspname::text), c.relname;

\echo ===== Roles =====
SELECT rolname AS role, rolcanlogin AS login,
       (SELECT string_agg(b.rolname, ', ') FROM pg_auth_members m JOIN pg_roles b ON b.oid=m.roleid WHERE m.member=r.oid) AS member_of
FROM pg_roles r WHERE rolname LIKE 'lab\_%' ORDER BY 1;
"""

if __name__ == "__main__":
    main()
