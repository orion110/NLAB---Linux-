#!/bin/zsh
# =============================================================================
# nlab_db.zsh  — Zsh bridge to the SQLite package registry
# =============================================================================
# Source this AFTER nlab_meta.zsh.  It wraps the key write functions so
# every install/uninstall is mirrored to the DB transparently.
#
# The flat $NLAB_EXEC layout does NOT change — all packages still land in
# $NLAB_EXEC/bin, $NLAB_EXEC/lib, etc.  The DB is a record, not a layout.
#
# Requires: python3, nlab_db.py (auto-located via NLAB_DB_PY)
# =============================================================================
# This bridge keeps the DB in sync with all package operations.
# It is sourced after nlab_core.zsh.

# ── Locate the Python script ─────────────────────────────────────────────────
export NLAB_DB_PY="${NLAB_DB_PY:-${NLAB_ENV}/nlab_db.py}"
export NLAB_DB="${NLAB_DB:-${NLAB_ENV}/nlab.db}"

_nlab_db_available() {
    [[ -f "$NLAB_DB_PY" ]] && command -v python3 >/dev/null 2>&1
}

_db() {
    if _nlab_db_available; then
        python3 "$NLAB_DB_PY" --db "$NLAB_DB" "$@" 2>&1
    fi
}

_db_quiet() {
    if _nlab_db_available; then
        python3 "$NLAB_DB_PY" --db "$NLAB_DB" "$@" >/dev/null 2>&1
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# DB init (called once at shell startup / on demand)
# ─────────────────────────────────────────────────────────────────────────────

nlab_db_init() {
    if ! _nlab_db_available; then
        echo "⚠️  nlab_db.py not found at $NLAB_DB_PY — DB tracking disabled"
        return 1
    fi
    _db init
}

# ─────────────────────────────────────────────────────────────────────────────
# Auto-import flat meta files → DB (run once after upgrading)
# ─────────────────────────────────────────────────────────────────────────────

nlab_db_import() {
    echo "📦 Importing existing flat meta files into SQLite..."
    _db import-meta "${NLAB_META}"
    echo "✅ Import complete. Run: nlab db-stats"
}
# ─────────────────────────────────────────────────────────────────────────────
# Register package metadata (without creating an install)
# Usage: nlab_db_register_package <name> [--build-system ...] [--flags ...]
# ─────────────────────────────────────────────────────────────────────────────
nlab_db_register_package() {
    local name="$1"; shift
    if ! _nlab_db_available; then
        echo "⚠️  DB not available" >&2; return 1
    fi
    _db register-package "$name" "$@"
}
# ─────────────────────────────────────────────────────────────────────────────
# WRITE-THROUGH OVERRIDES
# Override nlab_meta_register — write to BOTH flat files AND the SQLite DB.
# This is the critical hook that keeps every install in sync automatically.
# Original lives in nlab_meta.zsh; we redefine here without touching it.
# ─────────────────────────────────────────────────────────────────────────────

nlab_meta_register() {
    local pkg="$1"
    local compiler_family="${2:-${NLAB_COMPILER_FAMILY:-gcc}}"
    local compiler_version="${3:-${NLAB_COMPILER_VERSION:-14}}"
    local version="${PKG_VERSION[$pkg]:-latest}"
    local variants="${PKG_VARIANTS[$pkg]:-}"

    # 1. Call the Python script to register the install
    #    Also pass any known package metadata (build system, source, flags)
    #    We can read from associative arrays if they are set.
    local build_sys="${PKG_BUILD_SYSTEM[$pkg]:-autotools}"
    local req_comp="${PKG_COMPILER_REQUIRED[$pkg]:-}"
    local flags="${PKG_FLAGS[$pkg]:-}"
    local src_path="${PKG_SOURCE_PATH[$pkg]:-}"

    _db_quiet register "$pkg" "${version:-latest}" \
        "$compiler_family" "$compiler_version" \
        "${variants:-}" \
        --status "installed" \
        --build-system "$build_sys" \
        --required-compiler "$req_comp" \
        --flags "$flags" \
        --source-path "$src_path" || true

    # 2. Flat files (for backward compatibility – will be phased out)
    mkdir -p "$NLAB_META"
    touch "$NLAB_META/${pkg}.installed"
    echo "${compiler_family}:${compiler_version}" > "$NLAB_META/${pkg}.compiler"
    [[ -n "$version" ]] && echo "$version" > "$NLAB_META/${pkg}.version"
}


# ─────────────────────────────────────────────────────────────────────────────
# Override nlab_record_installation — record files in DB after every install
# ─────────────────────────────────────────────────────────────────────────────
nlab_record_installation() {
    local pkg="$1"
    local timestamp_file="$2"

    [[ ! -f "$timestamp_file" ]] && {
        echo "⚠️ No timestamp file, cannot record files for $pkg"
        return 1
    }

    local files_list="$NLAB_META/${pkg}.files"
    {
        find "$NLAB_EXEC" -type f -newer "$timestamp_file" 2>/dev/null
        find "$NLAB_EXEC" -type l -newer "$timestamp_file" 2>/dev/null
    } | sort -u > "$files_list"

    local count=$(wc -l < "$files_list" | tr -d ' ')
    echo "📝 Recorded $count installed files for $pkg"

    # Mirror file list into DB via inline Python (as before)
    if _nlab_db_available && [[ $count -gt 0 ]]; then
        python3 - "$NLAB_DB" "$pkg" \
                   "${NLAB_COMPILER_FAMILY:-gcc}" "${NLAB_COMPILER_VERSION:-14}" \
                   "$files_list" << 'PYEOF' 2>/dev/null || true
import sys, sqlite3
db_path, pkg, cc_fam, cc_ver, files_path = sys.argv[1:]
conn = sqlite3.connect(db_path)
conn.row_factory = sqlite3.Row
row = conn.execute(
    """SELECT i.id FROM installs i
       JOIN packages p ON i.pkg_id = p.id
       WHERE p.name=? AND i.compiler_family=? AND i.compiler_version=?
         AND i.status='installed'
       ORDER BY i.install_date DESC LIMIT 1""",
    (pkg, cc_fam, cc_ver)
).fetchone()
if row:
    lines = [l.strip() for l in open(files_path) if l.strip()]
    conn.execute("DELETE FROM install_files WHERE install_id=?", (row["id"],))
    conn.executemany(
        "INSERT INTO install_files (install_id, path) VALUES (?, ?)",
        [(row["id"], f) for f in lines]
    )
    conn.execute("UPDATE installs SET nfiles=? WHERE id=?", (len(lines), row["id"]))
    conn.commit()
conn.close()
PYEOF
    fi

    if [[ -z "${NLAB_KEEP_BUILD_FILES}" || "${NLAB_KEEP_BUILD_FILES}" -eq 0 ]]; then
        rm -f "$timestamp_file"
    fi
}


# ─────────────────────────────────────────────────────────────────────────────
# nlab_build wrapper — log build result to DB automatically
# NOTE: nlab_build_with_logging and nlab_uninstall_with_db are also defined
# in nlab_brain.zsh (copied there for standalone use). The versions here are
# canonical; brain.zsh versions will be removed in a future cleanup.
# ─────────────────────────────────────────────────────────────────────────────

_nlab_build_original() { nlab_build "$@"; }  # placeholder; real one is in brain

nlab_build_with_logging() {
    local pkg="$1"
    local t_start=$SECONDS

    # Ensure DB has a record before building
    if _nlab_db_available; then
        # Register package metadata if not present (use current arrays)
        local build_sys="${PKG_BUILD_SYSTEM[$pkg]:-autotools}"
        local req_comp="${PKG_COMPILER_REQUIRED[$pkg]:-}"
        local flags="${PKG_FLAGS[$pkg]:-}"
        local src_path="${PKG_SOURCE_PATH[$pkg]:-}"
        _db_quiet register "$pkg" \
            "${PKG_VERSION[$pkg]:-latest}" \
            "${NLAB_COMPILER_FAMILY:-gcc}" \
            "${NLAB_COMPILER_VERSION:-14}" \
            "" \
            --status "pending" \
            --build-system "$build_sys" \
            --required-compiler "$req_comp" \
            --flags "$flags" \
            --source-path "$src_path" || true
    fi

    # Run the actual build (assume nlab_build is defined elsewhere)
    nlab_build "$pkg"
    local rc=$?

    local elapsed=$(( SECONDS - t_start ))
    local minutes=$(( elapsed / 60 ))
    local secs=$(( elapsed % 60 ))
    local duration="${minutes}m${secs}s"

    if _nlab_db_available; then
        local status="success"; [[ $rc -ne 0 ]] && status="failed"
        _db_quiet log-build "$pkg" \
            "${NLAB_COMPILER_FAMILY:-gcc}" \
            "${NLAB_COMPILER_VERSION:-14}" \
            "$status" "$duration" || true
    fi

    return $rc
}
# ─────────────────────────────────────────────────────────────────────────────
# nlab_uninstall override — mark removed in DB
# ─────────────────────────────────────────────────────────────────────────────
nlab_uninstall_with_db() {
    local pkg="$1"
    nlab_uninstall "$pkg"   
    local rc=$?
    if [[ $rc -eq 0 ]] && _nlab_db_available; then
        _db_quiet unregister "$pkg" \
            "${NLAB_COMPILER_FAMILY:-gcc}" \
            "${NLAB_COMPILER_VERSION:-14}" || true
        echo "🗄️  DB: marked $pkg as removed"
    fi
    return $rc
}

# ─────────────────────────────────────────────────────────────────────────────
# DB query shortcuts (nlab db-* commands)
# These are wired into the main nlab() dispatcher in nlab.zsh
# ─────────────────────────────────────────────────────────────────────────────

nlab_db_installed()   { _db installed; }
nlab_db_info()        { _db info "$1"; }
nlab_db_variants()    { _db variants "$1"; }
nlab_db_deps()        { _db deps "$1"; }
nlab_db_check_abi()   { _db check-abi "$1"; }
nlab_db_history()     { _db history "$1"; }
nlab_db_search()      { _db search "$1"; }
nlab_db_build_order() { _db build-order "$@"; }
nlab_db_stats()       { _db stats; }
nlab_db_lock()        { _db export-lock; }
nlab_db_which()       { _db which "$1"; }
nlab_db_unregister()  { _db unregister "$@"; }
# ─────────────────────────────────────────────────────────────────────────────
# Convenience: sync flat meta → DB (for packages installed before DB existed)
# ─────────────────────────────────────────────────────────────────────────────
nlab_db_sync() {
    echo "🔄 Syncing flat meta files → SQLite DB..."
    local count=0
    for installed in "$NLAB_META"/*.installed; do
        [[ -f "$installed" ]] || continue
        local pkg=$(basename "$installed" .installed)
        [[ "$pkg" == *"."* ]] && continue

        local compiler_family="gcc"; local compiler_version="14"
        if [[ -f "$NLAB_META/${pkg}.compiler" ]]; then
            local comp_str=$(cat "$NLAB_META/${pkg}.compiler")
            compiler_family="${comp_str%:*}"
            compiler_version="${comp_str#*:}"
        fi

        local version="latest"
        [[ -f "$NLAB_META/${pkg}.version" ]] && version=$(cat "$NLAB_META/${pkg}.version")

        _db_quiet register "$pkg" "${version:-latest}" \
            "${compiler_family}" "${compiler_version}" "" \
            --status "installed" || true
        ((count++))
        printf "\r   Synced %d packages..." "$count"
    done
    echo ""
    echo "✅ Sync complete: $count packages"
    _db stats
}

nlab_db_unregister() {
    local pkg="$1"
    local compiler_family="${2:-clang}"
    local compiler_version="${3:-21}"
    _db unregister "$pkg" "$compiler_family" "$compiler_version"
}
# ─────────────────────────────────────────────────────────────────────────────
# Auto-init DB on first load (non-blocking)
# ─────────────────────────────────────────────────────────────────────────────

if _nlab_db_available && [[ ! -f "$NLAB_DB" ]]; then
    echo "🗄️  First run: initialising NLAB SQLite database..."
    nlab_db_init >/dev/null 2>&1 && echo "   DB ready: $NLAB_DB" || true
fi

[[ -n "$NLAB_VERBOSE" ]] && echo "✅ nlab_db.zsh loaded (DB: $NLAB_DB)"
