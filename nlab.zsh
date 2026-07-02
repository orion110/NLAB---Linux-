#!/bin/zsh
# ============================================================================
# NLAB v6 - Unified CLI (DB‑centric)
# ============================================================================

# -----------------------------------------------------------------------------
# Compiler shortcuts (using core's comp)
# -----------------------------------------------------------------------------
env_gcc()   { comp gcc "${1:-14}"; }
env_mpi()   { comp mpi "${1:-15}"; }
env_clang() { comp clang; }

# ============================================================================
# MAIN CLI DISPATCHER
# ============================================================================

nlab() {
    local cmd="$1"
    shift || true

    case "$cmd" in
        # ============================================================
        # BUILD & PACKAGE MANAGEMENT
        # ============================================================
        build)          nlab_build "$@" ;;
        install)        nlab_install "$@"  ;;
        remove)         nlab_uninstall "$@" ;;
        uninstall)      nlab_uninstall "$@" ;;
        info|i)         nlab_pkg_info "$@" ;;
        source)         nlab_find_source "$@" ;;
        clean)          nlab_clean "$@" ;;
        deepclean)      nlab_deepclean "$@" ;;
        rebuild)        nlab_rebuild "$@" ;;
        find)           nlab_find_source "$@" ;;
        tree)           nlab_tree "$@" ;;
        doctor)         nlab_doctor "$@" ;;
        check)          nlab_check "$@" ;;
        lock)           nlab_generate_installed_lock "$@" ;;

        # ============================================================
        # SOURCE SCANNING & DB REGISTRATION (NEW)
        # ============================================================
        scan)           nlab_scan_all_sources "$@" ;;
        scan-pkg)       nlab_scan_and_register_package "$1" "$2" ;;
        generate)       nlab_scan_all_sources ;;   # alias for scan
        generate-all)   nlab_scan_all_sources ;;   # same

        # ============================================================
        # PHASE MANAGEMENT (unchanged)
        # ============================================================
        phase)          nlab_phase_run "$@" ;;
        phases-list)    nlab_phases_list ;;
        phases-core)
            echo "🔨 Building core phases..."
            for p in 0 1 1_5 2 3 4 5 6; do
                nlab_phase_run "$p" || return 1
            done
            echo "✅ Core phases complete"
            ;;
        phases-hpc)
            echo "🔬 Building HPC phases..."
            for p in 7 8 9 10 11 12; do
                nlab_phase_run "$p" || return 1
            done
            echo "✅ HPC phases complete"
            ;;
        phases-nuclear)
            echo "☢️  Building nuclear phases..."
            for p in 14a 14b; do
                nlab_phase_run "$p" || return 1
            done
            echo "✅ Nuclear phases complete"
            ;;
        phases-all)
            echo "🚀 Building all phases..."
            for p in 0 1 1_5 2 3 4 5 6 7 8 9 10 11 12 13 14a 14b 15 16; do
                nlab_phase_run "$p" || return 1
            done
            echo "✅ All phases complete"
            ;;
        phases-global)
            nlab_generate_phases_global "$@" ;;

        # ============================================================
        # ENVIRONMENT STACKS (unchanged)
        # ============================================================
        env-create)     nlab_env_create "$1" ;;
        env-add)        nlab_env_add "$1" "$2" ;;
        env-remove)     nlab_env_remove "$1" "$2" ;;
        env-activate)   nlab_env_activate "$1" ;;
        env-deactivate) nlab_env_deactivate ;;
        env-list)       nlab_env_list ;;
        env-show)       nlab_env_show "$1" ;;
        env-destroy)    nlab_env_destroy "$1" ;;

        # ============================================================
        # CACHE MANAGEMENT (unchanged)
        # ============================================================
        cache-clean)    nlab_cache_clean "$1" ;;
        cache-stats)
            local cache_dir="${NLAB_ROOT}/cache"
            echo "Cache directory: $cache_dir"
            du -sh "$cache_dir" 2>/dev/null
            echo "Entries: $(find "$cache_dir" -type f -name "*.tar.gz" 2>/dev/null | wc -l)"
            ;;

        # ============================================================
        # TOOLCHAIN (from core.zsh)
        # ============================================================
        comp)           comp "$@" ;;
        comp-list)      comp_list ;;
        env-gcc)        env_gcc "$@" ;;
        env-mpi)        env_mpi "$@" ;;
        env-clang)      env_clang ;;

        # ============================================================
        # INVENTORY (from inventory.zsh)
        # ============================================================
        inventory|inv)  nlab_inventory "$1" ;;
        which-pkg|wp)   nlab_which_pkg "$1" ;;

        # ============================================================
        # DATABASE COMMANDS (nlab_db.zsh)
        # ============================================================
        db-init)        nlab_db_init ;;
        db-import)      nlab_db_import ;;
        db-sync)        nlab_db_sync ;;
        db-installed)   nlab_db_installed ;;
        db-info)        nlab_db_info "$1" ;;
        db-variants)    nlab_db_variants "$1" ;;
        db-deps)        nlab_db_deps "$1" ;;
        db-check-abi)   nlab_db_check_abi "$1" ;;
        db-history)     nlab_db_history "$1" ;;
        db-search)      nlab_db_search "$1" ;;
        db-build-order) nlab_db_build_order "$@" ;;
        db-stats)       nlab_db_stats ;;
        db-lock)        nlab_db_lock ;;
        db-which)       nlab_db_which "$1" ;;
        db-unregister)  nlab_db_unregister "$@" ;;

        # ============================================================
        # STATUS
        # ============================================================
        status)
            echo "=== NLAB Status ==="
            echo "Root:     $NLAB_ROOT"
            echo "Exec:     $NLAB_EXEC"
            echo "Src:      $NLAB_SRC"
            echo "Compiler: ${NLAB_COMPILER_FAMILY:-none}@${NLAB_COMPILER_VERSION:-none}"
            echo "CC:       ${CC:-not set}"
            echo "CXX:      ${CXX:-not set}"
            echo "Env:      ${NLAB_ACTIVE_ENV:-none}"
            # Removed generation counter
            echo ""
            echo "=== Installed Packages (from DB) ==="
            nlab_db_installed 2>/dev/null || echo "  (none)"
            ;;

        # ============================================================
        # VERSION
        # ============================================================
        version)
            echo "NLAB v6 - Nuclear Lab HPC Environment (DB-centric)"
            echo "Compiler: ${NLAB_COMPILER_FAMILY:-none}@${NLAB_COMPILER_VERSION:-none}"
            ;;

        # ============================================================
        # HELP
        # ============================================================
        help|--help|-h)
            cat << 'EOF'
╔═══════════════════════════════════════════════════════════════════════════╗
║                         NLAB v6 - Nuclear Lab HPC                         ║
╠═══════════════════════════════════════════════════════════════════════════╣
║                                                                           ║
║  BUILD & PACKAGE MANAGEMENT                                               ║
║    build <pkg>              Build package (with deps)                     ║
║    install <spec>           Install spec (pkg%compiler@ver^dep)           ║
║    uninstall <pkg>          Remove package                                ║
║    info <pkg>               Show package info (from DB)                   ║
║    clean <pkg>              Clean installed files                         ║
║    deepclean <pkg>          Clean + remove source                         ║
║    rebuild <pkg>            Clean and rebuild                             ║
║    tree <pkg>               Show dependency tree                          ║
║    doctor                   Validate tools, paths, compiler setup         ║
║    check                    Check installed metadata/files/ABI            ║
║    lock                     Generate installed.lock.json                  ║
║                                                                           ║
║  SOURCE SCANNING & DB REGISTRATION                                        ║
║    scan                     Scan all source trees and register in DB      ║
║    scan-pkg <path> <pkg>    Scan a specific source directory              ║
║    generate                  Alias for scan                               ║
║                                                                           ║
║  PHASE MANAGEMENT                                                         ║
║    phase <num>              Run specific phase (0-16)                     ║
║    phases-core              Build core (0-6)                              ║
║    phases-hpc               Build HPC (7-12)                              ║
║    phases-nuclear           Build nuclear (14a-14b)                       ║
║    phases-all               Build all (0-16)                              ║
║    phases-global            Build with global dependency resolution       ║
║                                                                           ║
║  ENVIRONMENT STACKS                                                       ║
║    env-create <name>        Create environment                            ║
║    env-add <env> <pkg>      Add package to environment                    ║
║    env-activate <name>      Activate environment                          ║
║    env-deactivate           Deactivate environment                        ║
║    env-list                 List environments                             ║
║                                                                           ║
║  TOOLCHAIN                                                                ║
║    comp <family> [ver]      Select compiler (gcc, mpi, clang, llvm)       ║
║    comp-list                Show available compilers                      ║
║    env-gcc [ver]            Activate GCC                                  ║
║    env-mpi [ver]            Activate MPI                                  ║
║    env-clang                Activate Clang                                ║
║                                                                           ║
║  INVENTORY & INSPECTION                                                   ║
║    inventory                Show installed packages and files             ║
║    which-pkg <file>         Find which package owns a file                ║
║                                                                           ║
║  DATABASE QUERIES                                                         ║
║    db-init                  Initialise SQLite database                    ║
║    db-import                Import flat meta files → DB (one‑time)        ║
║    db-sync                  Sync flat meta → DB (if any new)              ║
║    db-installed             List all installs (with compiler + variant)   ║
║    db-info <pkg>            Full package info from DB                     ║
║    db-variants <pkg>        All recorded variants of a package            ║
║    db-deps <pkg>            Dependencies + reverse-deps                   ║
║    db-check-abi <pkg>       Check for ABI compiler mismatches             ║
║    db-history <pkg>         Build history log                             ║
║    db-search <query>        Search packages by name                       ║
║    db-build-order <pkgs>    Dependency-sorted build order                 ║
║    db-stats                 Registry statistics                           ║
║    db-lock                  Write installed.lock.json                     ║
║    db-which <file>          Find which package owns a file                ║
║                                                                           ║
║  UTILITIES                                                                ║
║    status                   Show system status                            ║
║    version                  Show version info                             ║
║    help                     Show this help                                ║
║                                                                           ║
║  SHORTCUTS: i=info                                                        ║
║                                                                           ║
║  EXAMPLES:                                                                ║
║    nlab scan                 Register all packages from sources           ║
║    nlab build hdf5           Build HDF5 with dependencies                 ║
║    nlab phase 7              Run phase 7 (numerics)                       ║
║    comp gcc 14               Switch to GCC 14                             ║
║    nlab db-stats             Show database statistics                     ║
╚═══════════════════════════════════════════════════════════════════════════╝
EOF
            ;;

        # ============================================================
        # UNKNOWN
        # ============================================================
        *)
            echo "❌ Unknown command: $cmd"
            echo "Run 'nlab help' for available commands"
            return 1
            ;;
    esac
}

# ============================================================================
# PHASES LIST HELPER (unchanged)
# ============================================================================

nlab_phases_list() {
    cat << 'EOF'
Available NLAB Phases:
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Core Infrastructure (0-6):
    0      - Bootstrap toolchain
    1      - Crypto & core libraries
    1_5    - Math stack (GMP, MPFR, MPC, ISL)
    2      - Python 3.12
    3      - Graphics core
    4      - MPI (OpenMPI)
    5      - Graphics extras (Clang)
    6      - Qt5 + Graphviz (Clang)

  HPC Numerics (7-12):
    7      - Numerics (OpenBLAS, FFTW, GSL, Eigen)
    8      - Partitioning (METIS, ParMETIS, Scotch, Hypre)
    9      - I/O (HDF5, NetCDF)
    10     - Mesh & geometry (MOAB, p4est)
    11     - Solvers (PETSc, SLEPc, SUNDIALS)
    12     - Python bridges (NumPy, SciPy, mpi4py)

  Visualization & Nuclear (13-16):
    13     - Visualization (VTK, Octave)
    14a    - Nuclear geometry (DAGMC)
    14b    - Nuclear solvers (OpenMC, Geant4, ROOT)
    15     - ML/AI (TensorFlow, PyTorch) + Doxygen, R
    16     - Validation & testing

Commands:
  nlab phase <num>     - Run specific phase
  nlab phases-core     - Core phases (0-6)
  nlab phases-hpc      - HPC phases (7-12)
  nlab phases-nuclear  - Nuclear phases (14a-14b)
  nlab phases-all      - All phases (0-16)
  nlab phases-global   - Global dependency resolution
EOF
}

# ============================================================================
# INIT
# ============================================================================

echo "🧠 NLAB v6 loaded (DB-centric)"
echo "   Root: $NLAB_ROOT"
echo "   Type 'nlab help' for commands"