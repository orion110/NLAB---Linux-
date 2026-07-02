#!/usr/bin/env zsh
# =============================================================================
# NLAB PHASE MANAGEMENT - SQLite-centric (no YAML dependency)
# =============================================================================
# Phases are stored in the SQLite `phases` and `phase_packages` tables.
# The CLI commands `nlab phase <num>` and `nlab phases-*` use this.
# =============================================================================

# ─────────────────────────────────────────────────────────────────────────────
# run_phase - Build a single phase group using SQLite DB
# ─────────────────────────────────────────────────────────────────────────────

run_phase() {
    local phase_key="$1"
    local force=0
    [[ "$2" == "--force" ]] && force=1

    local _orig_dir="$PWD"

    # ── Get phase metadata from DB ─────────────────────────────────
    local desc compiler compiler_version
    if _nlab_db_available 2>/dev/null; then
        # Query phases table
        local row=$(sqlite3 -separator $'\t' "$NLAB_DB" \
            "SELECT description, compiler_family, compiler_version
             FROM phases WHERE phase_key='$phase_key'" 2>/dev/null)
        if [[ -z "$row" ]]; then
            echo "❌ Phase '$phase_key' not found in database." >&2
            cd "$_orig_dir" 2>/dev/null
            return 1
        fi
        IFS=$'\t' read -r desc compiler compiler_version <<< "$row"

        # Get packages for this phase (ordered by position)
        local packages=$(sqlite3 "$NLAB_DB" \
            "SELECT pkg_name FROM phase_packages
             WHERE phase_id=(SELECT id FROM phases WHERE phase_key='$phase_key')
             ORDER BY position" 2>/dev/null | tr '\n' ' ')
    else
        echo "❌ Database not available. Run: nlab db-init" >&2
        cd "$_orig_dir" 2>/dev/null
        return 1
    fi

    echo ""
    echo "═══════════════════════════════════════════════════════════"
    echo "  Phase: $desc"
    echo "  Compiler: $compiler@$compiler_version"
    echo "═══════════════════════════════════════════════════════════"

    # ── Special case handlers (toolchain builds) ──────────────────
    # These are special phases that build compilers themselves.
    # They may need specific handling; keep them as is.
    case "$phase_key" in
        1.5-gcc14)            build_gcc14; local r=$?; cd "$_orig_dir" 2>/dev/null; return $r ;;
        1.7-gcc16|1.8-gcc16)  build_gcc16; local r=$?; cd "$_orig_dir" 2>/dev/null; return $r ;;
        1.6-llvm|1.8-llvm)    build_llvm;  local r=$?; cd "$_orig_dir" 2>/dev/null; return $r ;;
        16-validation)        validate_stack; local r=$?; cd "$_orig_dir" 2>/dev/null; return $r ;;
    esac

    # ── Compiler setup ──────────────────────────────────────────────
    if typeset -f comp >/dev/null 2>&1; then
        local comp_ver_arg="$compiler_version"
        [[ -z "$comp_ver_arg" || "$comp_ver_arg" == "auto" || "$comp_ver_arg" == "system" ]] && comp_ver_arg=""
        if [[ -n "$comp_ver_arg" ]]; then
            comp "$compiler" "$comp_ver_arg" || { cd "$_orig_dir" 2>/dev/null; return 1; }
        else
            comp "$compiler" || { cd "$_orig_dir" 2>/dev/null; return 1; }
        fi
    else
        echo "⚠️  Compiler switching not available; using current compiler." >&2
    fi

    # ── Build order using SQLite DB ──────────────────────────────────
    local -a phase_pkgs_raw=(${=packages})
    local -a phase_pkgs=()

    # Use DB build-order (handles transitive deps)
    if _nlab_db_available 2>/dev/null; then
        local -a db_order=($(nlab_db_build_order ${phase_pkgs_raw[@]} 2>/dev/null))
        # Filter to packages in this phase
        for pkg in "${db_order[@]}"; do
            if [[ " ${phase_pkgs_raw[*]} " == *" $pkg "* ]]; then
                phase_pkgs+=("$pkg")
            fi
        done
    fi

    # Fallback: use raw phase list if DB didn't return anything
    if [[ ${#phase_pkgs[@]} -eq 0 ]]; then
        echo "⚠️  No packages in DB build-order; using phase list directly." >&2
        phase_pkgs=("${phase_pkgs_raw[@]}")
    fi

    if [[ ${#phase_pkgs[@]} -eq 0 ]]; then
        echo "ℹ️  No packages to build in this phase"
        cd "$_orig_dir" 2>/dev/null
        return 0
    fi

    echo "📋 Build order for this phase: ${phase_pkgs[*]}"
    echo ""

    # ── Build each package using nlab_build ────────────────────────
    for pkg in "${phase_pkgs[@]}"; do
        # Check if already installed and compatible (via DB)
        local installed=0
        if _nlab_db_available 2>/dev/null; then
            local st=$(sqlite3 "$NLAB_DB" \
                "SELECT status FROM installs i JOIN packages p ON i.pkg_id=p.id
                 WHERE p.name='$pkg'
                   AND i.compiler_family='${NLAB_COMPILER_FAMILY:-gcc}'
                   AND i.compiler_version='${NLAB_COMPILER_VERSION:-14}'
                   AND i.status='installed'" 2>/dev/null | head -1)
            [[ "$st" == "installed" ]] && installed=1
        fi
        if [[ $force -eq 0 ]] && [[ $installed -eq 1 ]]; then
            echo "⏭️  $pkg already installed (${NLAB_COMPILER_FAMILY:-gcc}@${NLAB_COMPILER_VERSION:-14})"
            continue
        fi

        echo "🔨 Building $pkg..."
        # Use nlab_build_flat directly? nlab_build is the entry point.
        if nlab_build "$pkg"; then
            echo "✅ $pkg built"
        else
            echo "❌ Failed to build $pkg" >&2
            cd "$_orig_dir" 2>/dev/null
            return 1
        fi
    done

    cd "$_orig_dir" 2>/dev/null
    echo "✅ Phase $phase_key completed"
    return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# nlab_generate_phases_global - Build all phases in global dependency order
# ─────────────────────────────────────────────────────────────────────────────

nlab_generate_phases_global() {
    local force=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --force) force=1; shift ;;
            *) echo "❌ Unknown option: $1"; return 1 ;;
        esac
    done

    echo ""
    echo "═══════════════════════════════════════════════════════════"
    echo "  🔬 NLAB PHASE BUILD - GLOBAL DEPENDENCY RESOLUTION (DB)"
    echo "═══════════════════════════════════════════════════════════"
    echo ""

    if ! _nlab_db_available 2>/dev/null; then
        echo "❌ Database not available. Run: nlab db-init" >&2
        return 1
    fi

    # Get all installed packages (status='installed') or all known packages?
    # For a global build, we want all packages in the DB (including those not yet installed)
    # but we need to resolve dependencies. We'll use the packages table.
    local all_pkgs=($(sqlite3 "$NLAB_DB" "SELECT name FROM packages" 2>/dev/null))
    if [[ ${#all_pkgs[@]} -eq 0 ]]; then
        echo "⚠️  No packages found in DB. Run: nlab scan to populate." >&2
        return 1
    fi

    echo "📊 Resolving global package dependencies (${#all_pkgs[@]} packages)..."
    local -a global_order=($(nlab_db_build_order ${all_pkgs[@]} 2>/dev/null))
    if [[ ${#global_order[@]} -eq 0 ]]; then
        echo "⚠️  DB build-order empty; using package list in alphabetical order." >&2
        global_order=(${all_pkgs[@]})
    fi

    # Get phase mapping: which phase does each package belong to?
    local -A pkg_to_phase
    local phase_pkg_rows=$(sqlite3 "$NLAB_DB" \
        "SELECT phase_key, pkg_name FROM phase_packages pp
         JOIN phases ph ON pp.phase_id = ph.id" 2>/dev/null)
    while IFS='|' read -r phase_key pkg_name; do
        pkg_to_phase[$pkg_name]="$phase_key"
    done <<< "$phase_pkg_rows"

    echo "   Build order: ${#global_order[@]} packages"
    echo ""

    echo "─────────────────────────────────────────────────────────────"
    echo "  🚀 Building packages in global dependency order"
    echo "─────────────────────────────────────────────────────────────"

    local -a built_pkgs=()
    local -a failed_pkgs=()
    local current_phase=""
    local pkg_count=0

    for pkg in "${global_order[@]}"; do
        ((pkg_count++))

        # Find phase for this package
        local pkg_phase="${pkg_to_phase[$pkg]:-unknown}"
        if [[ "$pkg_phase" != "$current_phase" ]] && [[ "$pkg_phase" != "unknown" ]]; then
            current_phase="$pkg_phase"
            echo ""
            echo "═══════════════════════════════════════════════════════════"
            echo "  📁 Phase: $current_phase"
            echo "═══════════════════════════════════════════════════════════"
        elif [[ "$pkg_phase" == "unknown" ]]; then
            # Package not in any phase – we still build it, but note it.
            if [[ "$current_phase" != "unassigned" ]]; then
                current_phase="unassigned"
                echo ""
                echo "═══════════════════════════════════════════════════════════"
                echo "  📁 Phase: (unassigned – not in any phase group)"
                echo "═══════════════════════════════════════════════════════════"
            fi
        fi

        echo "   [$pkg_count/${#global_order[@]}] $pkg"

        # Check if already installed
        local installed=0
        local st=$(sqlite3 "$NLAB_DB" \
            "SELECT status FROM installs i JOIN packages p ON i.pkg_id=p.id
             WHERE p.name='$pkg'
               AND i.compiler_family='${NLAB_COMPILER_FAMILY:-gcc}'
               AND i.compiler_version='${NLAB_COMPILER_VERSION:-14}'
               AND i.status='installed'" 2>/dev/null | head -1)
        [[ "$st" == "installed" ]] && installed=1

        if [[ $force -eq 0 ]] && [[ $installed -eq 1 ]]; then
            echo "      ⏭️  Already installed"
            built_pkgs+=("$pkg")
            continue
        fi

        echo "      🔨 Building..."
        if nlab_build "$pkg"; then
            built_pkgs+=("$pkg")
            echo "      ✅ Done"
        else
            echo "      ❌ Failed"
            failed_pkgs+=("$pkg")
        fi
    done

    # Summary
    echo ""
    echo "═══════════════════════════════════════════════════════════"
    echo "  📊 BUILD SUMMARY"
    echo "═══════════════════════════════════════════════════════════"
    echo "   Total packages:  ${#global_order[@]}"
    echo "   Built:           ${#built_pkgs[@]}"
    echo "   Failed:          ${#failed_pkgs[@]}"

    if [[ ${#failed_pkgs[@]} -gt 0 ]]; then
        echo ""
        echo "❌ Failed packages:"
        for pkg in "${failed_pkgs[@]}"; do
            echo "   - $pkg"
        done
        return 1
    fi

    echo ""
    echo "✅ All phases completed successfully!"
    return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# CLI Mapper (phase number → phase_key)
# ─────────────────────────────────────────────────────────────────────────────

nlab_phase_run() {
    local phase_num="$1"
    [[ -z "$phase_num" ]] && {
        echo "❌ Usage: nlab phase <number>" >&2
        echo "   Available: 0,1,1_5,2,3,4,5,6,7,8,9,10,11,12,13,14a,14b,15,16" >&2
        echo "   Options: --force  Force rebuild even if installed" >&2
        return 1
    }

    local force=0
    [[ "$2" == "--force" ]] && force=1

    local phase_key
    case "$phase_num" in
        0)   phase_key="0-bootstrap" ;;
        1)   phase_key="1-crypto-core-libs" ;;
        1_5) phase_key="1.5-gcc14" ;;
        1_6) phase_key="1.6-llvm" ;;
        1_7) phase_key="1.7-gcc15" ;;
        1_8) phase_key="1.8-gcc16" ;;
        2)   phase_key="2-python" ;;
        3)   phase_key="3-graphics-core" ;;
        4)   phase_key="4-graphics-extras-gui" ;;
        5)   phase_key="5-mpi" ;;
        6)   phase_key="6-qt5-graphviz" ;;
        7)   phase_key="7-numerics-core" ;;
        8)   phase_key="8-partitioning" ;;
        9)   phase_key="9-scientific-io" ;;
        10)  phase_key="10-mesh-geometry" ;;
        11)  phase_key="11-hpc-solvers" ;;
        12)  phase_key="12-python-scientific" ;;
        13)  phase_key="13-visualization" ;;
        14a) phase_key="14a-nuclear-geometry" ;;
        14b) phase_key="14b-nuclear-monte-carlo" ;;
        15)  phase_key="15-machine-learning" ;;
        16)  phase_key="16-validation" ;;
        *)   echo "❌ Unknown phase: $phase_num" >&2; return 1 ;;
    esac

    if [[ $force -eq 1 ]]; then
        run_phase "$phase_key" --force
    else
        run_phase "$phase_key"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Batch runner (entry point for full build)
# ─────────────────────────────────────────────────────────────────────────────

nlab_phases_all() {
    local force=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --force) force=1; shift ;;
            --global) shift ;;   # global is the default now
            *) echo "❌ Unknown option: $1"; return 1 ;;
        esac
    done
    nlab_generate_phases_global "--force" "$force"
}

# ─────────────────────────────────────────────────────────────────────────────
# Initialize: ensure DB has phases (populate from YAML if missing)
# ─────────────────────────────────────────────────────────────────────────────

# If phases table is empty, try to import from YAML (for backward compatibility)
if _nlab_db_available 2>/dev/null; then
    local phase_count=$(sqlite3 "$NLAB_DB" "SELECT COUNT(*) FROM phases" 2>/dev/null)
    if [[ "$phase_count" -eq 0 ]] && [[ -f "${NLAB_PHASES_YAML:-$NLAB_ENV/nlab_phases.yaml}" ]]; then
        echo "📥 Importing phases from YAML into DB..." >&2
        python3 "$NLAB_DB_PY" import-phases "${NLAB_PHASES_YAML:-$NLAB_ENV/nlab_phases.yaml}" 2>/dev/null || true
    fi
fi

[[ -n "$NLAB_VERBOSE" ]] && {
    echo "✅ Phase management loaded (SQLite‑backed)"
    echo "   Run 'nlab phase <num>' for specific phases"
    echo "   Run 'nlab phases-all --global' for global dependency resolution"
}