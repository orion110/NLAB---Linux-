#!/usr/bin/python3
"""
nlab_db.py  — NLAB Package Registry (SQLite backend)
=====================================================
Flat-install model: everything still lands in $NLAB_EXEC (bin/, lib/, include/).
The DB is the *record* of what is installed, not a new directory layout.

Key concept — VARIANT:
  A variant is ONE install of a package under a specific compiler.
  e.g.  hdf5 @ 1.14.4  %gcc @ 14  +mpi
        hdf5 @ 1.14.4  %gcc @ 16  +mpi
  Both go to the SAME flat $NLAB_EXEC/lib/  — but only ONE can be active
  at a time (the last one wins on disk). The DB records ALL of them so
  you know what was ever built and can rebuild/swap at will.

Usage (CLI):
  python3 nlab_db.py init
  python3 nlab_db.py import-meta $NLAB_META
  python3 nlab_db.py register hdf5 1.14.4 gcc 14 mpi
  python3 nlab_db.py installed
  python3 nlab_db.py info hdf5
  python3 nlab_db.py variants hdf5
  python3 nlab_db.py deps hdf5
  python3 nlab_db.py check-abi hdf5
  python3 nlab_db.py history hdf5
  python3 nlab_db.py search openblas
  python3 nlab_db.py build-order petsc
  python3 nlab_db.py unregister hdf5 gcc 14
  python3 nlab_db.py log-build hdf5 gcc 14 success "2m30s"
  python3 nlab_db.py export-lock
  python3 nlab_db.py stats
"""

import sqlite3
import os
import sys
import json
import hashlib
import datetime
import argparse
import subprocess
from pathlib import Path
from typing import Optional, List


# ─────────────────────────────────────────────────────────────────────────────
# Configuration
# ─────────────────────────────────────────────────────────────────────────────

def get_nlab_root() -> Path:
    root = os.environ.get("NLAB_ROOT", "")
    if not root:
        # Fallback: look for common locations
        for candidate in ["/Volumes/nlab", Path.home() / "nlab", Path("/opt/nlab")]:
            if Path(candidate).exists():
                return Path(candidate)
        raise RuntimeError(
            "NLAB_ROOT not set. Source your nlab environment first, e.g.:\n"
            "  export NLAB_ROOT=\"$HOME/nlab\"   # or wherever you installed it\n"
            "  source \"$NLAB_ROOT/env/nlab_core.zsh\"\n"
            "  source \"$NLAB_ROOT/env/nlab_db.zsh\"\n"
            "(macOS example: source /Volumes/nlab/env/nlab_core.zsh)"
        )
    return Path(root)


def get_db_path() -> Path:
    db_env = os.environ.get("NLAB_DB")
    if db_env:
        return Path(db_env)
    return get_nlab_root() / "env" / "nlab.db"


def get_meta_dir() -> Path:
    meta = os.environ.get("NLAB_META", "")
    if meta:
        return Path(meta)
    return get_nlab_root() / "env" / "meta"


def get_exec_dir() -> Path:
    exec_dir = os.environ.get("NLAB_EXEC", "")
    if exec_dir:
        return Path(exec_dir)
    return get_nlab_root() / "exec"


# ─────────────────────────────────────────────────────────────────────────────
# Schema
# ─────────────────────────────────────────────────────────────────────────────

SCHEMA = """
PRAGMA journal_mode = WAL;
PRAGMA foreign_keys = ON;

-- Every known package (from recipes or discovered on disk)
CREATE TABLE IF NOT EXISTS packages (
        id              INTEGER PRIMARY KEY,
        name            TEXT    NOT NULL UNIQUE,
        description     TEXT,
        build_system    TEXT    DEFAULT 'autotools',
        url             TEXT,
        homepage        TEXT,
        license         TEXT,
        source_url      TEXT,               -- download URL
        source_path     TEXT,               -- local path (extracted)
        required_compiler TEXT DEFAULT 'clang',
        flags           TEXT,               -- default configure/cmake flags
        created_at      TEXT    DEFAULT (datetime('now'))
);

-- One row per (package × version × compiler_family × compiler_version × variants)
-- This is a "slot" in Spack terms but everything still installs flat.
CREATE TABLE IF NOT EXISTS installs (
    id               INTEGER PRIMARY KEY,
    pkg_id           INTEGER NOT NULL REFERENCES packages(id) ON DELETE CASCADE,
    version          TEXT    NOT NULL DEFAULT 'latest',
    compiler_family  TEXT    NOT NULL DEFAULT 'gcc',
    compiler_version TEXT    NOT NULL DEFAULT '14',
    variants         TEXT    NOT NULL DEFAULT '',   -- e.g. '+mpi+openmp'
    abi_hash         TEXT,                          -- hash of (compiler + deps versions)
    status           TEXT    NOT NULL DEFAULT 'installed',  -- installed|broken|removed|building
    install_date     TEXT    DEFAULT (datetime('now')),
    install_duration TEXT,                          -- e.g. "4m32s"
    nfiles           INTEGER DEFAULT 0,             -- files recorded at install time
    notes            TEXT,
    UNIQUE (pkg_id, version, compiler_family, compiler_version, variants)
);

-- Files belonging to each install (matches your existing .files tracking)
CREATE TABLE IF NOT EXISTS install_files (
    id          INTEGER PRIMARY KEY,
    install_id  INTEGER NOT NULL REFERENCES installs(id) ON DELETE CASCADE,
    path        TEXT    NOT NULL,
    kind        TEXT    DEFAULT 'file'   -- file|symlink|dir
);
CREATE INDEX IF NOT EXISTS idx_files_install ON install_files(install_id);
CREATE INDEX IF NOT EXISTS idx_files_path    ON install_files(path);

-- Runtime and build dependencies between installs
CREATE TABLE IF NOT EXISTS deps (
    id              INTEGER PRIMARY KEY,
    install_id      INTEGER NOT NULL REFERENCES installs(id) ON DELETE CASCADE,
    dep_pkg_name    TEXT    NOT NULL,   -- logical dep (resolved at build time)
    dep_install_id  INTEGER REFERENCES installs(id) ON DELETE SET NULL,  -- exact install used
    dep_type        TEXT    NOT NULL DEFAULT 'runtime'  -- runtime|build|optional
);
CREATE INDEX IF NOT EXISTS idx_deps_install ON deps(install_id);
CREATE INDEX IF NOT EXISTS idx_deps_dep     ON deps(dep_install_id);

-- Full build logs per install attempt
CREATE TABLE IF NOT EXISTS build_logs (
    id          INTEGER PRIMARY KEY,
    install_id  INTEGER NOT NULL REFERENCES installs(id) ON DELETE CASCADE,
    attempt     INTEGER DEFAULT 1,
    phase       TEXT,
    status      TEXT    DEFAULT 'success',  -- success|failed|cancelled
    stdout      TEXT,
    stderr      TEXT,
    duration    TEXT,
    started_at  TEXT    DEFAULT (datetime('now')),
    finished_at TEXT
);

-- Package-level dependency declarations (logical, version-agnostic)
-- Populated from recipes and dependencies.json
CREATE TABLE IF NOT EXISTS pkg_deps (
    id           INTEGER PRIMARY KEY,
    pkg_id       INTEGER NOT NULL REFERENCES packages(id) ON DELETE CASCADE,
    dep_name     TEXT    NOT NULL,
    dep_type     TEXT    NOT NULL DEFAULT 'runtime',
    optional     INTEGER DEFAULT 0,
    UNIQUE (pkg_id, dep_name, dep_type)
);

-- Compiler toolchains known to the system
CREATE TABLE IF NOT EXISTS compilers (
    id          INTEGER PRIMARY KEY,
    family      TEXT NOT NULL,   -- gcc | clang | llvm | mpi
    version     TEXT NOT NULL,
    path        TEXT,            -- e.g. $NLAB_EXEC/bin/gcc
    mpi_backend TEXT,            -- for mpi: underlying gcc version
    available   INTEGER DEFAULT 1,
    UNIQUE (family, version)
);

-- Phases from nlab_phases.yaml (for cross-referencing)
CREATE TABLE IF NOT EXISTS phases (
    id               INTEGER PRIMARY KEY,
    phase_key        TEXT NOT NULL UNIQUE,  -- e.g. '7-numerics-core'
    number           TEXT,
    description      TEXT,
    compiler_family  TEXT,
    compiler_version TEXT,
    pkg_group        TEXT   -- core|hpc|nuclear|other
);

CREATE TABLE IF NOT EXISTS phase_packages (
    phase_id  INTEGER NOT NULL REFERENCES phases(id) ON DELETE CASCADE,
    pkg_name  TEXT    NOT NULL,
    position  INTEGER DEFAULT 0,
    PRIMARY KEY (phase_id, pkg_name)
);

-- View: easy query of latest install per package
CREATE VIEW IF NOT EXISTS latest_installs AS
SELECT
    i.*,
    p.name       AS pkg_name,
    p.build_system,
    p.url
FROM installs i
JOIN packages p ON i.pkg_id = p.id
WHERE i.status = 'installed'
ORDER BY i.install_date DESC;
"""


# ─────────────────────────────────────────────────────────────────────────────
# Connection
# ─────────────────────────────────────────────────────────────────────────────

class NlabDB:
    def __init__(self, db_path: Optional[Path] = None):
        self.db_path = db_path or get_db_path()
        self.db_path.parent.mkdir(parents=True, exist_ok=True)
        self.conn = sqlite3.connect(str(self.db_path))
        self.conn.row_factory = sqlite3.Row
        self.conn.execute("PRAGMA journal_mode=WAL")
        self.conn.execute("PRAGMA foreign_keys=ON")

    def init_schema(self):
        self.conn.executescript(SCHEMA)
        self.conn.commit()
        print(f"✅ Database initialised: {self.db_path}")

    def close(self):
        self.conn.close()

    # ── Packages ──────────────────────────────────────────────────────────────

    def upsert_package(self, name: str, description: str = "", build_system: str = "autotools",
                       url: str = "", homepage: str = "") -> int:
        cur = self.conn.execute(
            """INSERT INTO packages (name, description, build_system, url, homepage)
               VALUES (?, ?, ?, ?, ?)
               ON CONFLICT(name) DO UPDATE SET
                 description  = COALESCE(NULLIF(excluded.description, ''), description),
                 build_system = COALESCE(NULLIF(excluded.build_system, ''), build_system),
                 url          = COALESCE(NULLIF(excluded.url, ''), url),
                 homepage     = COALESCE(NULLIF(excluded.homepage, ''), homepage)""",
            (name, description, build_system, url, homepage)
        )
        self.conn.commit()
        row = self.conn.execute("SELECT id FROM packages WHERE name=?", (name,)).fetchone()
        return row["id"]

    def get_package(self, name: str) -> Optional[sqlite3.Row]:
        return self.conn.execute(
            "SELECT * FROM packages WHERE name=?", (name,)
        ).fetchone()
        
        def set_package_source(self, name: str, source_url: str = None, source_path: str = None):
                updates = []
                params = []
                if source_url is not None:
                    updates.append("source_url = ?"); params.append(source_url)
                if source_path is not None:
                    updates.append("source_path = ?"); params.append(source_path)
                if not updates:
                    return
                params.append(name)
                self.conn.execute(
                    f"UPDATE packages SET {', '.join(updates)} WHERE name = ?", params
                )
                self.conn.commit()

    # ── Installs ──────────────────────────────────────────────────────────────

    def register_install(self, pkg_name: str, version: str,
                         compiler_family: str, compiler_version: str,
                         variants: str = "", abi_hash: str = "",
                         status: str = "pending", duration: str = "",
                          nfiles: int = 0, notes: str = "") -> int:
        pkg = self.get_package(pkg_name)
        if not pkg:
            # Create a minimal package entry if not present
            pkg_id = self.upsert_package(pkg_name)
        else:
            pkg_id = pkg["id"]
        cur = self.conn.execute(
            """INSERT INTO installs
                 (pkg_id, version, compiler_family, compiler_version,
                  variants, abi_hash, status, install_duration, nfiles, notes)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
               ON CONFLICT(pkg_id, version, compiler_family, compiler_version, variants)
               DO UPDATE SET
                 status           = COALESCE(NULLIF(excluded.status, ''), status),
                 abi_hash         = COALESCE(NULLIF(excluded.abi_hash, ''), abi_hash),
                 install_date     = datetime('now'),
                 install_duration = COALESCE(NULLIF(excluded.install_duration, ''), install_duration),
                 nfiles           = CASE WHEN excluded.nfiles > 0 THEN excluded.nfiles ELSE nfiles END,
                 notes            = COALESCE(NULLIF(excluded.notes, ''), notes)""",
            (pkg_id, version, compiler_family, compiler_version,
             variants, abi_hash, status, duration, nfiles, notes)
        )
        self.conn.commit()
        row = self.conn.execute(
            """SELECT id FROM installs
               WHERE pkg_id=? AND version=? AND compiler_family=?
                 AND compiler_version=? AND variants=?""",
            (pkg_id, version, compiler_family, compiler_version, variants)
        ).fetchone()
        return row["id"]

    def get_install(self, pkg_name: str, compiler_family: str = "",
                    compiler_version: str = "", variants: str = "") -> Optional[sqlite3.Row]:
        """Return the most-recently installed variant matching the filters."""
        query = """
            SELECT i.*, p.name AS pkg_name, p.build_system
            FROM installs i JOIN packages p ON i.pkg_id = p.id
            WHERE p.name = ? AND i.status = 'installed'
        """
        params: list = [pkg_name]
        if compiler_family:
            query += " AND i.compiler_family = ?"
            params.append(compiler_family)
        if compiler_version:
            query += " AND i.compiler_version = ?"
            params.append(compiler_version)
        if variants:
            query += " AND i.variants = ?"
            params.append(variants)
        query += " ORDER BY i.install_date DESC LIMIT 1"
        return self.conn.execute(query, params).fetchone()

    def list_installs(self, status: str = "installed") -> list:
        return self.conn.execute(
            """SELECT i.*, p.name AS pkg_name
               FROM installs i JOIN packages p ON i.pkg_id = p.id
               WHERE i.status = ?
               ORDER BY p.name, i.compiler_family, i.compiler_version""",
            (status,)
        ).fetchall()

    def get_variants(self, pkg_name: str) -> list:
        """All installs (any status) for a package."""
        return self.conn.execute(
            """SELECT i.*, p.name AS pkg_name
               FROM installs i JOIN packages p ON i.pkg_id = p.id
               WHERE p.name = ?
               ORDER BY i.install_date DESC""",
            (pkg_name,)
        ).fetchall()

    def mark_removed(self, pkg_name: str, compiler_family: str, compiler_version: str):
        pkg = self.get_package(pkg_name)
        if not pkg:
            return
        self.conn.execute(
            """UPDATE installs SET status='removed'
               WHERE pkg_id=? AND compiler_family=? AND compiler_version=?""",
            (pkg["id"], compiler_family, compiler_version)
        )
        self.conn.commit()

    # ── Dependencies ──────────────────────────────────────────────────────────

    def add_dep(self, install_id: int, dep_pkg_name: str,
                dep_type: str = "runtime", dep_install_id: Optional[int] = None):
        self.conn.execute(
            """INSERT OR REPLACE INTO deps
                 (install_id, dep_pkg_name, dep_install_id, dep_type)
               VALUES (?, ?, ?, ?)""",
            (install_id, dep_pkg_name, dep_install_id, dep_type)
        )
        self.conn.commit()

    def get_deps(self, install_id: int) -> list:
        return self.conn.execute(
            """SELECT d.*, i.version, i.compiler_family, i.compiler_version,
                      i.status AS dep_status
               FROM deps d
               LEFT JOIN installs i ON d.dep_install_id = i.id
               WHERE d.install_id = ?
               ORDER BY d.dep_type, d.dep_pkg_name""",
            (install_id,)
        ).fetchall()

    def get_reverse_deps(self, pkg_name: str) -> list:
        """Which installed packages depend on pkg_name?"""
        return self.conn.execute(
            """SELECT p.name AS pkg_name, i.compiler_family, i.compiler_version,
                      i.version, d.dep_type
               FROM deps d
               JOIN installs i ON d.install_id = i.id
               JOIN packages p ON i.pkg_id = p.id
               WHERE d.dep_pkg_name = ? AND i.status = 'installed'
               ORDER BY p.name""",
            (pkg_name,)
        ).fetchall()

    def add_pkg_dep(self, pkg_name: str, dep_name: str,
                    dep_type: str = "runtime", optional: bool = False):
        pkg_id = self.upsert_package(pkg_name)
        self.conn.execute(
            """INSERT OR IGNORE INTO pkg_deps (pkg_id, dep_name, dep_type, optional)
               VALUES (?, ?, ?, ?)""",
            (pkg_id, dep_name, dep_type, 1 if optional else 0)
        )
        self.conn.commit()

    def get_pkg_deps(self, pkg_name: str) -> list:
        pkg = self.get_package(pkg_name)
        if not pkg:
            return []
        return self.conn.execute(
            "SELECT * FROM pkg_deps WHERE pkg_id=? ORDER BY dep_type, dep_name",
            (pkg["id"],)
        ).fetchall()

    # ── ABI check ─────────────────────────────────────────────────────────────

    def check_abi_consistency(self, pkg_name: str,
                              compiler_family: str, compiler_version: str) -> list:
        """
        Find dependencies of pkg that were built with a DIFFERENT compiler.
        Works even when dep_install_id is NULL (resolves dep by name from installs table).
        Returns list of mismatch dicts.
        """
        install = self.get_install(pkg_name, compiler_family, compiler_version)
        if not install:
            return []

        # Get all deps (both the install-linked ones and name-only ones)
        deps = self.conn.execute(
            "SELECT * FROM deps WHERE install_id=?", (install["id"],)
        ).fetchall()

        mismatches = []
        for dep in deps:
            dep_name = dep["dep_pkg_name"]

            # Try to resolve the dep install: first by explicit id, then by name
            dep_install = None
            if dep["dep_install_id"]:
                dep_install = self.conn.execute(
                    "SELECT * FROM installs WHERE id=?", (dep["dep_install_id"],)
                ).fetchone()

            if not dep_install:
                # Resolve by name — pick the most recent installed variant
                dep_install = self.conn.execute(
                    """SELECT i.* FROM installs i
                       JOIN packages p ON i.pkg_id = p.id
                       WHERE p.name = ? AND i.status = 'installed'
                       ORDER BY i.install_date DESC LIMIT 1""",
                    (dep_name,)
                ).fetchone()

            if not dep_install:
                # Dep not installed at all — flag as unknown, not a mismatch
                continue

            if (dep_install["compiler_family"] != compiler_family or
                    dep_install["compiler_version"] != compiler_version):

                # Allow cross-compiler for known system/bootstrap packages
                system_pkgs = {"zlib", "openssl", "libffi", "ncurses", "readline",
                               "gettext", "icu", "libxml2", "cmake", "pkgconf",
                               "libtool", "flex", "bzip2", "xz", "zstd"}
                if dep_name in system_pkgs and dep_install["compiler_family"] in ("clang", "system"):
                    continue  # expected: system packages built with clang

                mismatches.append({
                    "dep":               dep_name,
                    "dep_compiler":      f"{dep_install['compiler_family']}@{dep_install['compiler_version']}",
                    "expected_compiler": f"{compiler_family}@{compiler_version}",
                })

        return mismatches

    # ── Build logs ────────────────────────────────────────────────────────────

    def log_build(self, install_id: int, status: str = "success",
                  phase: str = "", stdout: str = "", stderr: str = "",
                  duration: str = ""):
        # Determine attempt number
        row = self.conn.execute(
            "SELECT COALESCE(MAX(attempt), 0)+1 AS n FROM build_logs WHERE install_id=?",
            (install_id,)
        ).fetchone()
        attempt = row["n"]
        self.conn.execute(
            """INSERT INTO build_logs
                 (install_id, attempt, phase, status, stdout, stderr,
                  duration, finished_at)
               VALUES (?, ?, ?, ?, ?, ?, ?, datetime('now'))""",
            (install_id, attempt, phase, status,
             stdout[:8000], stderr[:4000], duration)
        )
        if status == "success":
            self.conn.execute(
                "UPDATE installs SET status='installed' WHERE id=?", (install_id,)
            )
        elif status == "failed":
            self.conn.execute(
                "UPDATE installs SET status='broken' WHERE id=?", (install_id,)
            )
        self.conn.commit()

    def get_build_history(self, pkg_name: str) -> list:
        return self.conn.execute(
            """SELECT l.*, p.name AS pkg_name,
                      i.compiler_family, i.compiler_version, i.version
               FROM build_logs l
               JOIN installs i ON l.install_id = i.id
               JOIN packages p ON i.pkg_id = p.id
               WHERE p.name = ?
               ORDER BY l.started_at DESC""",
            (pkg_name,)
        ).fetchall()

    # ── Files ─────────────────────────────────────────────────────────────────

    def record_files(self, install_id: int, file_list: list[str]):
        self.conn.execute("DELETE FROM install_files WHERE install_id=?", (install_id,))
        self.conn.executemany(
            "INSERT INTO install_files (install_id, path) VALUES (?, ?)",
            [(install_id, f) for f in file_list]
        )
        self.conn.execute(
            "UPDATE installs SET nfiles=? WHERE id=?",
            (len(file_list), install_id)
        )
        self.conn.commit()

    def get_files(self, install_id: int) -> list[str]:
        rows = self.conn.execute(
            "SELECT path FROM install_files WHERE install_id=? ORDER BY path",
            (install_id,)
        ).fetchall()
        return [r["path"] for r in rows]

    def which_package_owns(self, file_path: str) -> Optional[sqlite3.Row]:
        return self.conn.execute(
            """SELECT p.name AS pkg_name, i.version,
                      i.compiler_family, i.compiler_version,
                      f.path
               FROM install_files f
               JOIN installs i ON f.install_id = i.id
               JOIN packages p ON i.pkg_id = p.id
               WHERE f.path LIKE ?""",
            (f"%{file_path}%",)
        ).fetchone()

    # ── Compilers ─────────────────────────────────────────────────────────────

    def register_compiler(self, family: str, version: str,
                          path: str = "", mpi_backend: str = ""):
        self.conn.execute(
            """INSERT INTO compilers (family, version, path, mpi_backend)
               VALUES (?, ?, ?, ?)
               ON CONFLICT(family, version) DO UPDATE SET
                 path        = COALESCE(NULLIF(excluded.path,''), path),
                 mpi_backend = COALESCE(NULLIF(excluded.mpi_backend,''), mpi_backend),
                 available   = 1""",
            (family, version, path, mpi_backend)
        )
        self.conn.commit()

    def list_compilers(self) -> list:
        return self.conn.execute(
            "SELECT * FROM compilers WHERE available=1 ORDER BY family, version"
        ).fetchall()

    # ── Phases ────────────────────────────────────────────────────────────────

    def import_phases_yaml(self, yaml_path: Path):
        try:
            import yaml
        except ImportError:
            print("⚠️  PyYAML not installed — run: pip3 install pyyaml")
            return
        with open(yaml_path) as f:
            data = yaml.safe_load(f)
        phases = data.get("phases", {})
        for key, info in phases.items():
            self.conn.execute(
                """INSERT INTO phases
                     (phase_key, number, description,
                      compiler_family, compiler_version, pkg_group)
                   VALUES (?, ?, ?, ?, ?, ?)
                   ON CONFLICT(phase_key) DO UPDATE SET
                     description      = excluded.description,
                     compiler_family  = excluded.compiler_family,
                     compiler_version = excluded.compiler_version""",
                (key,
                 str(info.get("number", "")),
                 info.get("description", ""),
                 info.get("compiler", "gcc"),
                 str(info.get("compiler_version", "system")),
                 info.get("group", ""))
            )
            phase_row = self.conn.execute(
                "SELECT id FROM phases WHERE phase_key=?", (key,)
            ).fetchone()
            if phase_row:
                pkgs = info.get("packages", [])
                for i, pkg in enumerate(pkgs):
                    self.upsert_package(pkg)
                    self.conn.execute(
                        """INSERT OR REPLACE INTO phase_packages
                             (phase_id, pkg_name, position)
                           VALUES (?, ?, ?)""",
                        (phase_row["id"], pkg, i)
                    )
        self.conn.commit()
        print(f"✅ Imported {len(phases)} phases from {yaml_path}")

    # ── Import from flat meta files ───────────────────────────────────────────

    def import_from_meta(self, meta_dir: Path) -> int:
        """
        Read the existing $NLAB_META flat files and populate the DB.
        Reads: *.installed  *.compiler  *.version  *.meta  *.files
        Returns the number of packages imported.
        """
        count = 0
        for installed_file in sorted(meta_dir.glob("*.installed")):
            pkg_name = installed_file.stem
            # Skip internal/event files
            if pkg_name.startswith("_") or "." in pkg_name:
                continue

            # Compiler
            compiler_str = ""
            compiler_file = meta_dir / f"{pkg_name}.compiler"
            if compiler_file.exists():
                compiler_str = compiler_file.read_text().strip()
            family, _, ver = compiler_str.partition(":")
            family = family or "unknown"
            ver    = ver    or "unknown"

            # Version
            version = "latest"
            version_file = meta_dir / f"{pkg_name}.version"
            if version_file.exists():
                version = version_file.read_text().strip() or "latest"

            # .meta file — build_system, flags, deps
            build_system = "autotools"
            deps_runtime: list[str] = []
            deps_build:   list[str] = []
            meta_file = meta_dir / f"{pkg_name}.meta"
            if meta_file.exists():
                for line in meta_file.read_text().splitlines():
                    if line.startswith("build_system:"):
                        build_system = line.split(":", 1)[1].strip()
                    elif line.startswith("deps:"):
                        raw = line.split(":", 1)[1].strip()
                        deps_runtime = [d.strip() for d in raw.split() if d.strip()]
                    elif line.startswith("build_deps:"):
                        raw = line.split(":", 1)[1].strip()
                        deps_build = [d.strip() for d in raw.split() if d.strip()]

            # Register package + install
            pkg_id     = self.upsert_package(pkg_name, build_system=build_system)
            install_id = self.register_install(
                pkg_name, version, family, ver,
                variants="", abi_hash="", duration="", nfiles=0
            )

            # Record logical deps
            for d in deps_runtime:
                if d and d != "null":
                    self.add_dep(install_id, d, dep_type="runtime")
            for d in deps_build:
                if d and d != "null":
                    self.add_dep(install_id, d, dep_type="build")

            # Record files if .files list exists
            files_file = meta_dir / f"{pkg_name}.files"
            if files_file.exists():
                lines = [l.strip() for l in files_file.read_text().splitlines() if l.strip()]
                self.record_files(install_id, lines)

            count += 1
            print(f"   📦 {pkg_name:30s}  {family}@{ver:6s}  v{version}")

        self.conn.commit()
        return count

    # ── DAG / build order ────────────────────────────────────────────────────

    def build_order(self, pkg_names: list[str]) -> list[str]:
        """
        Topological sort of pkg_names respecting pkg_deps.
        Returns ordered list with DEPENDENCIES FIRST (leaves before consumers).

        Graph model: graph[A] = {B, C} means A depends on B and C.
        Kahn's algorithm: in_degree[A] = number of deps A still needs built.
        Nodes with in_degree=0 have all deps satisfied → go next.
        """
        graph: dict[str, set[str]] = {}

        def pull_deps(name: str, seen: set):
            if name in seen:
                return
            seen.add(name)
            if name not in graph:
                graph[name] = set()
            rows = self.get_pkg_deps(name)
            for row in rows:
                dep = row["dep_name"]
                # Only include build/runtime deps, not optional (they are optional)
                if row["dep_type"] == "optional":
                    continue
                graph[name].add(dep)
                pull_deps(dep, seen)

        for p in list(pkg_names):
            pull_deps(p, set())

        # Kahn's algorithm — correct direction:
        # in_deg[p] = number of unbuilt dependencies p still needs
        in_deg: dict[str, int] = {p: len(graph.get(p, set())) for p in graph}

        # Start with packages that have no outstanding deps (pure leaves)
        queue = sorted([p for p, d in in_deg.items() if d == 0])
        order: list[str] = []

        while queue:
            node = queue.pop(0)
            order.append(node)
            # Find every package that listed `node` as a dependency
            for p, deps in graph.items():
                if node in deps:
                    in_deg[p] -= 1
                    if in_deg[p] == 0:
                        queue.append(p)
                        queue.sort()

        # Anything left has a cycle — append with warning
        remaining = [p for p in graph if p not in order]
        if remaining:
            print(f"⚠️  Dependency cycle detected, appending unresolved: {remaining}",
                  file=sys.stderr)
            order.extend(sorted(remaining))

        return order

    # ── Export / lock ─────────────────────────────────────────────────────────

    def export_lock(self) -> dict:
        rows = self.list_installs("installed")
        lock = {
            "generated_at": datetime.datetime.now().isoformat(),
            "nlab_db":      str(self.db_path),
            "packages": []
        }
        for r in rows:
            pkg_entry = {
                "name":             r["pkg_name"],
                "version":          r["version"],
                "compiler_family":  r["compiler_family"],
                "compiler_version": r["compiler_version"],
                "variants":         r["variants"],
                "abi_hash":         r["abi_hash"] or "",
                "install_date":     r["install_date"],
                "nfiles":           r["nfiles"],
            }
            deps = self.get_deps(r["id"])
            pkg_entry["deps"] = [
                {"name": d["dep_pkg_name"], "type": d["dep_type"]}
                for d in deps
            ]
            lock["packages"].append(pkg_entry)
        return lock

    # ── Statistics ────────────────────────────────────────────────────────────

    def stats(self) -> dict:
        total = self.conn.execute(
            "SELECT COUNT(*) AS n FROM installs WHERE status='installed'"
        ).fetchone()["n"]
        by_compiler = self.conn.execute(
            """SELECT compiler_family, compiler_version, COUNT(*) AS n
               FROM installs WHERE status='installed'
               GROUP BY compiler_family, compiler_version
               ORDER BY n DESC"""
        ).fetchall()
        broken = self.conn.execute(
            "SELECT COUNT(*) AS n FROM installs WHERE status='broken'"
        ).fetchone()["n"]
        pkgs_count = self.conn.execute(
            "SELECT COUNT(*) AS n FROM packages"
        ).fetchone()["n"]
        return {
            "total_installs": total,
            "packages_known": pkgs_count,
            "broken": broken,
            "by_compiler": [dict(r) for r in by_compiler],
        }
        # In NlabDB class:

        def upsert_package(self, name, description="", build_system="autotools",
                           url="", homepage="", source_url="", source_path="",
                           required_compiler="", flags="") -> int:
            cur = self.conn.execute(
                """INSERT INTO packages
                   (name, description, build_system, url, homepage,
                    source_url, source_path, required_compiler, flags)
                   VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                   ON CONFLICT(name) DO UPDATE SET
                     description      = COALESCE(NULLIF(excluded.description, ''), description),
                     build_system     = COALESCE(NULLIF(excluded.build_system, ''), build_system),
                     url              = COALESCE(NULLIF(excluded.url, ''), url),
                     homepage         = COALESCE(NULLIF(excluded.homepage, ''), homepage),
                     source_url       = COALESCE(NULLIF(excluded.source_url, ''), source_url),
                     source_path      = COALESCE(NULLIF(excluded.source_path, ''), source_path),
                     required_compiler= COALESCE(NULLIF(excluded.required_compiler, ''), required_compiler),
                     flags            = COALESCE(NULLIF(excluded.flags, ''), flags)""",
                (name, description, build_system, url, homepage,
                 source_url, source_path, required_compiler, flags)
            )
            self.conn.commit()
            row = self.conn.execute("SELECT id FROM packages WHERE name=?", (name,)).fetchone()
            return row["id"]


# ─────────────────────────────────────────────────────────────────────────────
# CLI
# ─────────────────────────────────────────────────────────────────────────────

def _fmt_row(row: sqlite3.Row) -> str:
    return "  " + "  ".join(str(v) for v in row)


def cmd_init(db: NlabDB, args):
    db.init_schema()
    # Auto-import phases yaml if it exists
    yaml_candidates = [
        get_nlab_root() / "env" / "nlab_phases.yaml",
        Path(os.environ.get("NLAB_ENV", "")) / "nlab_phases.yaml",
    ]
    for yp in yaml_candidates:
        if yp.exists():
            db.import_phases_yaml(yp)
            break


def cmd_import_meta(db: NlabDB, args):
    meta_dir = Path(args.meta_dir) if args.meta_dir else get_meta_dir()
    if not meta_dir.exists():
        print(f"❌ Meta directory not found: {meta_dir}")
        sys.exit(1)
    print(f"📦 Importing from: {meta_dir}")
    count = db.import_from_meta(meta_dir)
    print(f"✅ Imported {count} packages into {db.db_path}")


def cmd_register_package(db: NlabDB, args):
    """Register/update package metadata without creating an install."""
    pkg_id = db.upsert_package(
        name=args.name,
        description=args.description or "",
        build_system=args.build_system or "autotools",
        url=args.url or "",
        homepage=args.homepage or "",
        source_url=args.source_url or "",
        source_path=args.source_path or "",
        required_compiler=args.required_compiler or "",
        flags=args.flags or ""
    )
    print(f"✅ Package '{args.name}' registered (id={pkg_id})")
    

def cmd_register(db: NlabDB, args):
    # Extended register command: now also accepts all package metadata
    install_id = db.register_install(
        pkg_name=args.pkg,
        version=args.version,
        compiler_family=args.compiler_family,
        compiler_version=args.compiler_version,
        variants=args.variants or "",
        status=args.status or "pending",
        duration=args.duration or "",
        notes=args.notes or ""
    )
    # Also update package metadata if provided
    if args.source_url or args.source_path or args.build_system or args.required_compiler or args.flags:
        db.upsert_package(
            name=args.pkg,
            build_system=args.build_system or "",
            source_url=args.source_url or "",
            source_path=args.source_path or "",
            required_compiler=args.required_compiler or "",
            flags=args.flags or ""
        )
    print(f"✅ Registered install for {args.pkg}@{args.version} "
          f"%{args.compiler_family}@{args.compiler_version} (id={install_id})")
          
    # Also write back to flat meta files for zsh compatibility
    meta_dir = get_meta_dir()
    meta_dir.mkdir(parents=True, exist_ok=True)
    (meta_dir / f"{args.pkg}.installed").touch()
    (meta_dir / f"{args.pkg}.compiler").write_text(
        f"{args.compiler_family}:{args.compiler_version}\n"
    )
    (meta_dir / f"{args.pkg}.version").write_text(f"{args.version}\n")
    print(f"   (flat meta files updated for zsh compatibility)")


def cmd_installed(db: NlabDB, args):
    rows = db.list_installs("installed")
    if not rows:
        print("  (no installed packages)")
        return
    print(f"\n{'Package':<28} {'Version':<12} {'Compiler':<18} {'Variants':<14} {'Files':>6}  {'Date'}")
    print("─" * 90)
    for r in rows:
        compiler = f"{r['compiler_family']}@{r['compiler_version']}"
        date     = (r["install_date"] or "")[:10]
        print(f"  {r['pkg_name']:<26} {r['version']:<12} {compiler:<18} {r['variants'] or '':<14} {r['nfiles']:>6}  {date}")
    print(f"\n  Total: {len(rows)} installs")


def cmd_info(db: NlabDB, args):
    pkg = db.get_package(args.pkg)
    if not pkg:
        print(f"❌ Package not found: {args.pkg}")
        sys.exit(1)
    install = db.get_install(args.pkg,
                             args.compiler_family or "",
                             args.compiler_version or "")
    print(f"\n{'─'*60}")
    print(f"  Package    : {pkg['name']}")
    print(f"  Build sys  : {pkg['build_system']}")
    print(f"  URL        : {pkg['url'] or 'n/a'}")
    if install:
        print(f"  Status     : ✅ {install['status']}")
        print(f"  Version    : {install['version']}")
        print(f"  Compiler   : {install['compiler_family']}@{install['compiler_version']}")
        print(f"  Variants   : {install['variants'] or '(none)'}")
        print(f"  ABI hash   : {install['abi_hash'] or 'n/a'}")
        print(f"  Files      : {install['nfiles']}")
        print(f"  Installed  : {install['install_date']}")
        deps = db.get_deps(install["id"])
        if deps:
            print(f"\n  Dependencies:")
            for d in deps:
                dc = f"{d['compiler_family']}@{d['compiler_version']}" if d["compiler_family"] else "?"
                print(f"    [{d['dep_type']:7s}] {d['dep_pkg_name']:<20} {dc}")
    else:
        print(f"  Status     : ❌ not installed")

    # Logical deps from recipes
    pkg_deps = db.get_pkg_deps(args.pkg)
    if pkg_deps:
        print(f"\n  Recipe deps (logical):")
        for d in pkg_deps:
            opt = " (optional)" if d["optional"] else ""
            print(f"    [{d['dep_type']:7s}] {d['dep_name']}{opt}")
    print(f"{'─'*60}\n")


def cmd_variants(db: NlabDB, args):
    rows = db.get_variants(args.pkg)
    if not rows:
        print(f"  No records for: {args.pkg}")
        return
    print(f"\n  Variants of '{args.pkg}':")
    print(f"  {'Compiler':<18} {'Version':<12} {'Status':<12} {'Variants':<14} {'Date'}")
    print("  " + "─" * 70)
    for r in rows:
        compiler = f"{r['compiler_family']}@{r['compiler_version']}"
        date     = (r["install_date"] or "")[:10]
        status   = "✅" if r["status"] == "installed" else "❌"
        print(f"  {compiler:<18} {r['version']:<12} {status} {r['status']:<10} {r['variants'] or '':<14} {date}")


def cmd_deps(db: NlabDB, args):
    install = db.get_install(args.pkg)
    if not install:
        print(f"❌ {args.pkg} not installed")
        sys.exit(1)
    print(f"\n  Dependencies of {args.pkg}@{install['version']} ({install['compiler_family']}@{install['compiler_version']}):")
    deps = db.get_deps(install["id"])
    if not deps:
        print("    (none recorded)")
    for d in deps:
        icon = "🔧" if d["dep_type"] == "build" else "📦"
        dep_ver = f"  v{d['version']}" if d["version"] else ""
        dep_cc  = f"  %{d['compiler_family']}@{d['compiler_version']}" if d["compiler_family"] else ""
        print(f"    {icon} {d['dep_pkg_name']:<20}{dep_ver}{dep_cc}")

    rdeps = db.get_reverse_deps(args.pkg)
    if rdeps:
        print(f"\n  Packages that depend on {args.pkg}:")
        for r in rdeps:
            print(f"    ← {r['pkg_name']:<20} ({r['compiler_family']}@{r['compiler_version']})")


def cmd_check_abi(db: NlabDB, args):
    family  = args.compiler_family or os.environ.get("NLAB_COMPILER_FAMILY", "gcc")
    version = args.compiler_version or os.environ.get("NLAB_COMPILER_VERSION", "14")
    mismatches = db.check_abi_consistency(args.pkg, family, version)
    if not mismatches:
        print(f"✅ No ABI mismatches found for {args.pkg} ({family}@{version})")
    else:
        print(f"⚠️  ABI mismatches for {args.pkg}:")
        for m in mismatches:
            print(f"   dep: {m['dep']}")
            print(f"     built with: {m['dep_compiler']}")
            print(f"     expected:   {m['expected_compiler']}")


def cmd_history(db: NlabDB, args):
    rows = db.get_build_history(args.pkg)
    if not rows:
        print(f"  No build history for: {args.pkg}")
        return
    print(f"\n  Build history for {args.pkg}:")
    for r in rows:
        icon = "✅" if r["status"] == "success" else "❌"
        print(f"  {icon} attempt {r['attempt']}  {r['compiler_family']}@{r['compiler_version']}  {r['duration'] or '?'}  {r['started_at'][:16]}")
        if r["stderr"] and args.verbose:
            print(f"    stderr: {r['stderr'][:200]}")


def cmd_search(db: NlabDB, args):
    rows = db.conn.execute(
        """SELECT p.name, p.build_system, p.url,
                  COUNT(i.id) AS install_count
           FROM packages p
           LEFT JOIN installs i ON p.id = i.pkg_id AND i.status='installed'
           WHERE p.name LIKE ?
           GROUP BY p.id
           ORDER BY p.name""",
        (f"%{args.query}%",)
    ).fetchall()
    if not rows:
        print(f"  No packages matching: {args.query}")
        return
    print(f"\n  Results for '{args.query}':")
    for r in rows:
        status = f"✅ ({r['install_count']} variant(s))" if r["install_count"] else "  (not installed)"
        print(f"  {r['name']:<30} {r['build_system']:<14} {status}")


def cmd_build_order(db: NlabDB, args):
    pkgs = args.packages
    order = db.build_order(pkgs)
    print(f"\n  Build order for: {', '.join(pkgs)}")
    for i, p in enumerate(order, 1):
        installed = "✅" if db.get_install(p) else "  "
        print(f"  {i:3d}. {installed} {p}")


def cmd_unregister(db: NlabDB, args):
    db.mark_removed(args.pkg, args.compiler_family, args.compiler_version)
    print(f"✅ Marked {args.pkg} ({args.compiler_family}@{args.compiler_version}) as removed")


def cmd_log_build(db: NlabDB, args):
    install = db.get_install(args.pkg, args.compiler_family, args.compiler_version)
    if not install:
        print(f"❌ Install not found for {args.pkg} — register it first")
        sys.exit(1)
    db.log_build(install["id"], status=args.status, duration=args.duration or "")
    print(f"✅ Logged build: {args.pkg} [{args.status}]")


def cmd_export_lock(db: NlabDB, args):
    lock = db.export_lock()
    out_path = Path(args.output) if args.output else get_nlab_root() / "env" / "installed.lock.json"
    out_path.parent.mkdir(parents=True, exist_ok=True)
    with open(out_path, "w") as f:
        json.dump(lock, f, indent=2)
    print(f"✅ Lock file written: {out_path}  ({len(lock['packages'])} packages)")


def cmd_stats(db: NlabDB, args):
    s = db.stats()
    print(f"\n  NLAB Package Registry — {db.db_path}")
    print(f"  {'─'*50}")
    print(f"  Packages known   : {s['packages_known']}")
    print(f"  Active installs  : {s['total_installs']}")
    print(f"  Broken installs  : {s['broken']}")
    print(f"\n  By compiler:")
    for row in s["by_compiler"]:
        print(f"    {row['compiler_family']:<8} @{row['compiler_version']:<8} {row['n']:4d} packages")


def cmd_which(db: NlabDB, args):
    row = db.which_package_owns(args.file)
    if not row:
        print(f"  No package found owning: {args.file}")
    else:
        print(f"  📦 {row['pkg_name']}@{row['version']} ({row['compiler_family']}@{row['compiler_version']})")
        print(f"     {row['path']}")

def cmd_install_spec(db, args):
    """
    Parse a spec string and print the build order.
    Actual building is done by zsh (nlab_build); this command just resolves
    the order and registers the intent, then prints a shell-executable plan.

    Spec format: pkg%compiler@version^dep1^dep2
    Example:     hdf5%gcc@14^zlib^openssl
    """
    import re
    m = re.match(r'^([^%@]+)(?:%([^@]+)@([^ ^]+))?(?:\^(.*))?$', args.spec)
    if not m:
        print("❌ Invalid spec. Use: pkg%compiler@version^dep1^dep2")
        print("   Example: hdf5%gcc@14^zlib^openssl")
        sys.exit(1)
    pkg              = m.group(1).strip()
    compiler_family  = (m.group(2) or "gcc").strip()
    compiler_version = (m.group(3) or "14").strip()
    deps_str         = m.group(4) or ""
    deps             = [d.strip() for d in deps_str.split("^") if d.strip()]

    all_pkgs = deps + [pkg]
    order    = db.build_order(all_pkgs)

    print(f"\n  Spec   : {args.spec}")
    print(f"  Compiler: {compiler_family}@{compiler_version}")
    print(f"\n  Build order ({len(order)} packages):")
    for i, p in enumerate(order, 1):
        installed = "✅" if db.get_install(p) else "  "
        print(f"    {i:3d}. {installed} {p}")

    print(f"\n  To build, run in zsh:")
    print(f"    comp {compiler_family} {compiler_version}")
    for p in order:
        print(f"    nlab build {p}")


def cmd_import_deps(db: NlabDB, args):
    """Import package dependencies from dependencies.yaml into the pkg_deps table."""
    try:
        import yaml
    except ImportError:
        print("❌ PyYAML not installed — run: pip3 install pyyaml")
        sys.exit(1)

    yaml_path_str = args.yaml_path if args.yaml_path else ""
    if not yaml_path_str:
        try:
            yaml_path = get_nlab_root() / "env" / "dependencies.yaml"
        except RuntimeError:
            print("❌ NLAB_ROOT not set and no yaml_path provided")
            sys.exit(1)
    else:
        yaml_path = Path(yaml_path_str)

    if not yaml_path.exists():
        print(f"❌ Not found: {yaml_path}")
        sys.exit(1)

    with open(yaml_path) as f:
        data = yaml.safe_load(f)

    # Clear and reimport
    db.conn.execute("DELETE FROM pkg_deps")
    db.conn.commit()

    count = 0
    skipped = 0
    for pkg in data:
        name = pkg.get("name")
        if not name:
            continue
        pkg_id = db.upsert_package(
            name,
            description=pkg.get("description", ""),
            build_system=pkg.get("build_system", "autotools"),
            url=pkg.get("url", ""),
        )
        for dep_type in ("runtime", "build", "optional"):
            for dep in pkg.get("dependencies", {}).get(dep_type, []) or []:
                if dep and dep != "null":
                    optional = 1 if dep_type == "optional" else 0
                    try:
                        db.conn.execute(
                            """INSERT OR IGNORE INTO pkg_deps
                                 (pkg_id, dep_name, dep_type, optional)
                               VALUES (?, ?, ?, ?)""",
                            (pkg_id, dep, dep_type, optional)
                        )
                    except Exception:
                        skipped += 1
        count += 1

    db.conn.commit()
    print(f"✅ Imported {count} packages and their deps from {yaml_path.name}")
    if skipped:
        print(f"   ({skipped} dep entries skipped due to conflicts)")
# ─────────────────────────────────────────────────────────────────────────────
# Entry point
# ─────────────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(prog="nlab_db.py")
    parser.add_argument("--db", default="", help="Path to nlab.db")
    sub = parser.add_subparsers(dest="cmd", required=True)
    # init
    sub.add_parser("init", help="Initialise schema")

    # import-meta
    p = sub.add_parser("import-meta", help="Import existing flat meta files into the DB")
    p.add_argument("meta_dir", nargs="?", default="", help="Path to $NLAB_META (default: auto-detect)")

    # register-package
    p = sub.add_parser("register-package", help="Register/update package metadata")
    p.add_argument("name")
    p.add_argument("--description", default="")
    p.add_argument("--build-system", default="autotools")
    p.add_argument("--url", default="")
    p.add_argument("--homepage", default="")
    p.add_argument("--source-url", default="")
    p.add_argument("--source-path", default="")
    p.add_argument("--required-compiler", default="")
    p.add_argument("--flags", default="")

    # installed
    sub.add_parser("installed", help="List all installed packages")

    # info
    p = sub.add_parser("info", help="Show package info")
    p.add_argument("pkg")
    p.add_argument("--compiler-family", dest="compiler_family", default="")
    p.add_argument("--compiler-version", dest="compiler_version", default="")
    
    # register (install)
    p = sub.add_parser("register", help="Register a package install")
    p.add_argument("pkg")
    p.add_argument("version")
    p.add_argument("compiler_family")
    p.add_argument("compiler_version")
    p.add_argument("variants", nargs="?", default="")
    p.add_argument("--status", default="pending")
    p.add_argument("--duration", default="")
    p.add_argument("--notes", default="")
    p.add_argument("--source-url", default="")
    p.add_argument("--source-path", default="")
    p.add_argument("--build-system", default="")
    p.add_argument("--required-compiler", default="")
    p.add_argument("--flags", default="")
   
    # variants
    p = sub.add_parser("variants", help="Show all recorded variants of a package")
    p.add_argument("pkg")

    # deps
    p = sub.add_parser("deps", help="Show dependencies of a package")
    p.add_argument("pkg")

    # check-abi
    p = sub.add_parser("check-abi", help="Check ABI consistency of a package's deps")
    p.add_argument("pkg")
    p.add_argument("--compiler-family", dest="compiler_family", default="")
    p.add_argument("--compiler-version", dest="compiler_version", default="")

    # history
    p = sub.add_parser("history", help="Show build history for a package")
    p.add_argument("pkg")
    p.add_argument("-v", "--verbose", action="store_true")

    # search
    p = sub.add_parser("search", help="Search packages by name")
    p.add_argument("query")

    # build-order
    p = sub.add_parser("build-order", help="Print build order for packages")
    p.add_argument("packages", nargs="+")

    # unregister
    p = sub.add_parser("unregister", help="Mark an install as removed")
    p.add_argument("pkg")
    p.add_argument("compiler_family")
    p.add_argument("compiler_version")

    # log-build
    p = sub.add_parser("log-build", help="Record a build result")
    p.add_argument("pkg")
    p.add_argument("compiler_family")
    p.add_argument("compiler_version")
    p.add_argument("status", choices=["success", "failed", "cancelled"])
    p.add_argument("duration", nargs="?", default="")

    # export-lock
    p = sub.add_parser("export-lock", help="Write installed.lock.json")
    p.add_argument("--output", "-o", default="")

    # stats
    sub.add_parser("stats", help="Show registry statistics")

    # which
    p = sub.add_parser("which", help="Find which package owns a file path fragment")
    p.add_argument("file")

    # install-spec  (was in dispatch but missing from argparse — now fixed)
    p = sub.add_parser("install-spec",
                       help="Install a package spec: pkg%%compiler@ver^dep1^dep2")
    p.add_argument("spec", help="e.g. hdf5%%gcc@14^zlib^openssl")

    # import-deps  (import dependencies from dependencies.yaml into pkg_deps)
    p = sub.add_parser("import-deps",
                       help="Import dependencies from dependencies.yaml into pkg_deps table")
    p.add_argument("yaml_path", nargs="?", default="",
                   help="Path to dependencies.yaml (default: $NLAB_ROOT/env/dependencies.yaml)")

    args = parser.parse_args()
    db = NlabDB(Path(args.db) if args.db else None)

    db_path = Path(args.db) if args.db else None
    db = NlabDB(db_path)

    dispatch = {
        "init":         cmd_init,
        "import-meta":  cmd_import_meta,
        "register-package":  cmd_register_package,
        "register":     cmd_register,
        "installed":    cmd_installed,
        "info":         cmd_info,
        "variants":     cmd_variants,
        "deps":         cmd_deps,
        "check-abi":    cmd_check_abi,
        "history":      cmd_history,
        "search":       cmd_search,
        "build-order":  cmd_build_order,
        "unregister":   cmd_unregister,
        "log-build":    cmd_log_build,
        "export-lock":  cmd_export_lock,
        "stats":        cmd_stats,
        "which":        cmd_which,
        "install-spec": cmd_install_spec,
        "import-deps":  cmd_import_deps,
    }
    dispatch[args.cmd](db, args)
    db.close()


if __name__ == "__main__":
    main()
