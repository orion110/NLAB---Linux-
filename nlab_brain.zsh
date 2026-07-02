#!/bin/zsh
# =============================================================================
# NLAB_BRAIN.ZSH — Build backends, executor, uninstall, user commands
# =============================================================================
# Architecture: Prepare → Provide → Execute → Register
#
# Every build backend follows ONE contract:
#   1. nlab_get_build_env <pkg>  → sets ALL env vars from SQLite, no args needed
#   2. Run build tool using $NLAB_PREFIX, $CFLAGS, $CMAKE_PREFIX_PATH, etc.
#   3. Return 0 (success) or non-zero (fail)
#
# Post-install (register/cache/lock/verify) = nlab_build_flat only.
# No backend queries DB or reads flat files directly.
# =============================================================================

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 1 — CENTRALIZED BUILD ENVIRONMENT PROVIDER
# Single function called by ALL 16+ backends before any build tool runs.
# Sets: NLAB_PREFIX  CMAKE_PREFIX_PATH  PKG_CONFIG_PATH  CPPFLAGS  LDFLAGS
#       LD_LIBRARY_PATH  PATH  NLAB_CMAKE_FLAGS  NLAB_DEP_NAMES
# ─────────────────────────────────────────────────────────────────────────────


nlab_get_build_env() {
    local pkg="$1"
    [[ -z "$pkg" ]] && { echo "nlab_get_build_env: pkg required" >&2; return 1; }

    local dep_names="" cmake_flags="" extra_cppflags="" extra_ldflags=""

    # ── Query SQLite for deps and package flags ─────────────────────────
    if _nlab_db_available 2>/dev/null; then
        # 1. Runtime dependencies
        dep_names=$(sqlite3 "$NLAB_DB" \
            "SELECT DISTINCT pd.dep_name
             FROM pkg_deps pd JOIN packages p ON pd.pkg_id=p.id
             WHERE p.name='$pkg' AND pd.dep_type IN ('runtime','build')" \
            2>/dev/null | tr '\n' ' ')

        # 2. Package flags (stored in packages.flags)
        local pkg_flags=$(sqlite3 "$NLAB_DB" \
            "SELECT flags FROM packages WHERE name='$pkg'" 2>/dev/null | head -1)
        [[ -n "$pkg_flags" && "$pkg_flags" != "null" ]] && {
            # Append to appropriate variables
            extra_cppflags="$extra_cppflags $pkg_flags"
            extra_ldflags="$extra_ldflags $pkg_flags"
            cmake_flags="$cmake_flags $pkg_flags"
        }

        # 3. For each dep, add CMake hints (same as before)
        for dep in ${=dep_names}; do
            local ok
            ok=$(sqlite3 "$NLAB_DB" \
                "SELECT COUNT(*) FROM installs i JOIN packages p ON i.pkg_id=p.id
                 WHERE p.name='$dep' AND i.status='installed'" 2>/dev/null)
            [[ "${ok:-0}" -lt 1 ]] && continue
            # Flat layout: all installed deps share $NLAB_EXEC
            case "$dep" in
                hdf5)         cmake_flags+=" -DHDF5_ROOT=$NLAB_EXEC -DHDF5_DIR=$NLAB_EXEC/share/cmake/hdf5" ;;
                netcdf-c|netcdf) cmake_flags+=" -DNetCDF_ROOT=$NLAB_EXEC -DNETCDF_DIR=$NLAB_EXEC/lib/cmake/netcdf" ;;
                petsc)        cmake_flags+=" -DPETSC_DIR=$NLAB_EXEC -DPETSC_ARCH=" ;;
                slepc)        cmake_flags+=" -DSLEPC_DIR=$NLAB_EXEC" ;;
                boost)        cmake_flags+=" -DBoost_ROOT=$NLAB_EXEC -DBoost_NO_SYSTEM_PATHS=ON" ;;
                eigen|eigen3) cmake_flags+=" -DEigen3_DIR=$NLAB_EXEC/share/eigen3/cmake" ;;
                metis)        cmake_flags+=" -DMETIS_DIR=$NLAB_EXEC -DTPL_METIS_INCLUDE_DIRS=$NLAB_EXEC/include -DTPL_METIS_LIBRARIES=$NLAB_EXEC/lib/libmetis.dylib" ;;
                parmetis)     cmake_flags+=" -DPARMETIS_DIR=$NLAB_EXEC -DTPL_PARMETIS_INCLUDE_DIRS=$NLAB_EXEC/include -DTPL_PARMETIS_LIBRARIES=$NLAB_EXEC/lib/libparmetis.dylib" ;;
                scotch)       cmake_flags+=" -DScotch_DIR=$NLAB_EXEC -DTPL_SCOTCH_INCLUDE_DIRS=$NLAB_EXEC/include -DTPL_SCOTCH_LIBRARIES=$NLAB_EXEC/lib/libscotch.dylib" ;;
                hypre)        cmake_flags+=" -DHYPRE_ROOT=$NLAB_EXEC" ;;
                openblas|blas|lapack) cmake_flags+=" -DBLAS_LIBRARIES=$NLAB_EXEC/lib/libopenblas.dylib -DLAPACK_LIBRARIES=$NLAB_EXEC/lib/libopenblas.dylib" ;;
                zlib)         cmake_flags+=" -DZLIB_ROOT=$NLAB_EXEC" ;;
                libpng|png)   cmake_flags+=" -DPNG_ROOT=$NLAB_EXEC" ;;
                libjpeg-turbo|jpeg) cmake_flags+=" -DJPEG_ROOT=$NLAB_EXEC" ;;
                tiff)         cmake_flags+=" -DTIFF_ROOT=$NLAB_EXEC" ;;
                freetype)     cmake_flags+=" -DFREETYPE_ROOT=$NLAB_EXEC" ;;
                fontconfig)   cmake_flags+=" -DFontconfig_ROOT=$NLAB_EXEC" ;;
                expat)        cmake_flags+=" -DEXPAT_ROOT=$NLAB_EXEC" ;;
                xerces-c)     cmake_flags+=" -DXercesC_ROOT=$NLAB_EXEC" ;;
                openmpi|mpi)  cmake_flags+=" -DMPI_C_COMPILER=mpicc -DMPI_CXX_COMPILER=mpicxx -DMPI_Fortran_COMPILER=mpif90" ;;
                moab)         cmake_flags+=" -DMOAB_DIR=$NLAB_EXEC/lib/cmake/MOAB" ;;
                sundials)     cmake_flags+=" -DSUNDIALS_ROOT=$NLAB_EXEC" ;;
                fftw|fftw3)   cmake_flags+=" -DFFTW_ROOT=$NLAB_EXEC" ;;
                gsl)          cmake_flags+=" -DGSL_ROOT_DIR=$NLAB_EXEC" ;;
                openssl)      cmake_flags+=" -DOPENSSL_ROOT_DIR=$NLAB_EXEC" ;;
            esac
        done
    else
        # Fallback: use in-memory arrays (legacy, will be removed)
        dep_names="${PKG_RUNTIME_DEPS[$pkg]:-} ${PKG_BUILD_DEPS[$pkg]:-}"
    fi

    # ── Export standard environment variables ─────────────────────────
    export NLAB_PREFIX="$NLAB_EXEC"
    export CMAKE_PREFIX_PATH="$NLAB_EXEC"
    export PKG_CONFIG_PATH="$NLAB_EXEC/lib/pkgconfig:$NLAB_EXEC/share/pkgconfig${PKG_CONFIG_PATH:+:${PKG_CONFIG_PATH}}"
    export LIBRARY_PATH="$NLAB_EXEC/lib${LIBRARY_PATH:+:${LIBRARY_PATH}}"
    export LD_LIBRARY_PATH="$NLAB_EXEC/lib${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
    export DYLD_LIBRARY_PATH="$NLAB_EXEC/lib${DYLD_LIBRARY_PATH:+:${DYLD_LIBRARY_PATH}}"
    export CPATH="$NLAB_EXEC/include${CPATH:+:${CPATH}}"
    export C_INCLUDE_PATH="$NLAB_EXEC/include${C_INCLUDE_PATH:+:${C_INCLUDE_PATH}}"
    export CPLUS_INCLUDE_PATH="$NLAB_EXEC/include${CPLUS_INCLUDE_PATH:+:${CPLUS_INCLUDE_PATH}}"
    export CPPFLAGS="-I$NLAB_EXEC/include $extra_cppflags ${CPPFLAGS:+ $CPPFLAGS}"
    export LDFLAGS="-L$NLAB_EXEC/lib -Wl,-rpath,$NLAB_EXEC/lib $extra_ldflags ${LDFLAGS:+ $LDFLAGS}"
    export NLAB_CMAKE_FLAGS="${cmake_flags# }"
    export NLAB_DEP_NAMES="${dep_names// /,}"
    [[ ":$PATH:" != *":$NLAB_EXEC/bin:"* ]] && export PATH="$NLAB_EXEC/bin:$PATH"

    echo "${dep_names}"
}

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 2 — INTERNAL HELPERS
# ─────────────────────────────────────────────────────────────────────────────


_nlab_clean_build_source() {
    local source_dir="${1:-$NLAB_SOURCE_DIR}"
    [[ -d "$source_dir" ]] || return 0
    local orig="$PWD"; cd "$source_dir" || return 1
    [[ -f "Makefile" || -f "config.status" ]] && {
        make distclean 2>/dev/null || make clean 2>/dev/null || true; }
    setopt localoptions nullglob
    for d in build Build cmake-build-* meson-build _build; do
        [[ -d "$d" ]] && rm -rf "$d"
    done
    rm -f CMakeCache.txt config.log config.status 2>/dev/null
    rm -rf CMakeFiles meson-private meson-logs autom4te.cache 2>/dev/null
    cd "$orig"
}

_nlab_append_meta_flags() {
    local pkg="$1" arr_name="$2"
    local flags
    flags=$(grep -E '^flags:' "$NLAB_META/${pkg}.meta" 2>/dev/null \
        | cut -d: -f2- | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    [[ -z "$flags" || "$flags" == "null" ]] && return 0
    for flag in ${=flags}; do
        [[ -n "$flag" ]] && eval "$arr_name+=(\"$flag\")"
    done
}

nlab_get_config()    { echo "${PKG_CONFIG_ARGS[${1}_${2}]}"; }
nlab_get_extra_deps(){ nlab_get_config "$1" "extra_deps"; }

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 3 — BUILD BACKENDS  (Prepare–Execute pattern)
# Each backend:
#   1. Calls nlab_get_build_env "$pkg"  (sets all vars)
#   2. Uses $NLAB_PREFIX for install target
#   3. Uses $NLAB_CMAKE_FLAGS for cmake hints
#   4. Uses $CFLAGS/$CXXFLAGS/$LDFLAGS/$CPPFLAGS for compiler flags
# ─────────────────────────────────────────────────────────────────────────────


nlab_build_autotools() {
    local pkg="$1"; local source_dir="${NLAB_SOURCE_DIR}"; local orig="$PWD"
    echo "🔨 [$pkg] Autotools" >&2
    nlab_get_build_env "$pkg" >/dev/null
    if [[ ! -f "$source_dir/configure" ]]; then
        if   [[ -f "$source_dir/autogen.sh"  ]]; then (cd "$source_dir" && ./autogen.sh)   || return 1
        elif [[ -f "$source_dir/bootstrap.sh" ]]; then (cd "$source_dir" && ./bootstrap.sh) || return 1
        elif [[ -f "$source_dir/configure.ac" || -f "$source_dir/configure.in" ]]; then
            (cd "$source_dir" && autoreconf -fi) || return 1
        fi
    fi
    [[ ! -f "$source_dir/configure" ]] && { echo "❌ No configure for $pkg" >&2; return 1; }
    local -a args=("--prefix=$NLAB_PREFIX" "--enable-shared" "--enable-static"
        "CC=${CC:-gcc}" "CXX=${CXX:-g++}"
        "CFLAGS=${CFLAGS:-}" "CXXFLAGS=${CXXFLAGS:-}"
        "CPPFLAGS=${CPPFLAGS:-}" "LDFLAGS=${LDFLAGS:-}")
    [[ -n "${FC:-}" ]] && args+=("FC=$FC" "F77=${F77:-$FC}")
    # Use flags from NLAB_CMAKE_FLAGS if any (convert to --with-* style?)
    # For Autotools, we rely on CPPFLAGS/LDFLAGS already set.
    local build_dir="$source_dir/build"
    rm -rf "$build_dir"; mkdir -p "$build_dir"; cd "$build_dir" || return 1
    "$source_dir/configure" "${args[@]}" || return 1
    make -j"${NPROC:-4}" || return 1
    make install          || return 1
    cd "$orig"; return 0
}

nlab_build_cmake() {
    local pkg="$1"; local source_dir="${NLAB_SOURCE_DIR}"; local orig="$PWD"
    echo "🔨 [$pkg] CMake" >&2
    nlab_get_build_env "$pkg" >/dev/null
    local -a args=(
        "-DCMAKE_INSTALL_PREFIX=$NLAB_PREFIX"
        "-DCMAKE_BUILD_TYPE=Release"
        "-DBUILD_SHARED_LIBS=ON"
        "-DCMAKE_C_COMPILER=${CC:-gcc}"
        "-DCMAKE_CXX_COMPILER=${CXX:-g++}"
        "-DCMAKE_PREFIX_PATH=${CMAKE_PREFIX_PATH}"
        "-DCMAKE_INCLUDE_PATH=$NLAB_EXEC/include"
        "-DCMAKE_LIBRARY_PATH=$NLAB_EXEC/lib"
    )
    [[ -n "${FC:-}" ]] && args+=("-DCMAKE_Fortran_COMPILER=$FC")
    # Inject flags from NLAB_CMAKE_FLAGS
    for flag in ${=NLAB_CMAKE_FLAGS}; do [[ -n "$flag" ]] && args+=("$flag"); done
    # Optional deps handling (still from array, but could move to DB)
    local opt="${PKG_OPTIONAL_DEPS[$pkg]:-}"
    for d in ${=opt}; do
        case "$d" in openmp) args+=("-DOPENMP_FOUND=ON") ;;
                      tbb)   args+=("-DTBB_ROOT=$NLAB_EXEC") ;; esac
    done
    local build_dir="$source_dir/build"
    rm -rf "$build_dir"; mkdir -p "$build_dir"; cd "$build_dir" || return 1
    cmake "$source_dir" "${args[@]}" || return 1
    make -j"${NPROC:-4}" || return 1
    make install          || return 1
    cd "$orig"; return 0
}

nlab_build_meson() {
    local pkg="$1"; local source_dir="${NLAB_SOURCE_DIR}"; local orig="$PWD"
    echo "🔨 [$pkg] Meson" >&2
    nlab_get_build_env "$pkg" >/dev/null
    local -a args=(
        "--prefix=$NLAB_PREFIX" "--libdir=lib" "--includedir=include"
        "--buildtype=release" "-Ddefault_library=shared"
        "-Dc_args=${CFLAGS:-}" "-Dcpp_args=${CXXFLAGS:-}"
        "-Dc_link_args=${LDFLAGS:-}" "-Dcpp_link_args=${LDFLAGS:-}"
        "-Dpkg_config_path=${PKG_CONFIG_PATH:-}"
        "-Dcmake_prefix_path=${CMAKE_PREFIX_PATH:-$NLAB_EXEC}"
    )
    _nlab_append_meta_flags "$pkg" args
    local build_dir="$source_dir/build"
    rm -rf "$build_dir"; cd "$source_dir" || return 1
    meson setup "$build_dir" "${args[@]}"    || return 1
    ninja -C "$build_dir" -j"${NPROC:-4}"   || return 1
    ninja -C "$build_dir" install            || return 1
    cd "$orig"; return 0
}

nlab_build_make() {
    local pkg="$1"; local source_dir="${NLAB_SOURCE_DIR}"; local orig="$PWD"
    echo "🔨 [$pkg] Make" >&2
    nlab_get_build_env "$pkg" >/dev/null
    cd "$source_dir" || return 1
    local build_dir="$source_dir/build"
    if [[ -f "$source_dir/configure" ]]; then
        rm -rf "$build_dir"; mkdir -p "$build_dir"; cd "$build_dir" || return 1
        local -a cfg=("--prefix=$NLAB_PREFIX")
        _nlab_append_meta_flags "$pkg" cfg
        "$source_dir/configure" "${cfg[@]}" CC="${CC:-gcc}" CXX="${CXX:-g++}" \
            CFLAGS="${CFLAGS:-}" LDFLAGS="${LDFLAGS:-}" CPPFLAGS="${CPPFLAGS:-}" || return 1
    elif [[ -f "$source_dir/Configure" ]]; then
        rm -rf "$build_dir"; mkdir -p "$build_dir"; cd "$build_dir" || return 1
        "$source_dir/Configure" "--prefix=$NLAB_PREFIX" "--openssldir=$NLAB_PREFIX/ssl" \
            "shared" CC="${CC:-gcc}" || return 1
    else
        make distclean 2>/dev/null || make clean 2>/dev/null || true
    fi
    if grep -q "PREFIX" Makefile 2>/dev/null; then
        make -j"${NPROC:-4}" PREFIX="$NLAB_PREFIX" CC="${CC:-gcc}" \
            CFLAGS="${CFLAGS:-}" LDFLAGS="${LDFLAGS:-}" || return 1
        make install PREFIX="$NLAB_PREFIX" || return 1
    else
        make -j"${NPROC:-4}" CC="${CC:-gcc}" CFLAGS="${CFLAGS:-}" \
            LDFLAGS="${LDFLAGS:-}" || return 1
        make install || return 1
    fi
    cd "$orig"; return 0
}

nlab_build_bootstrap() {
    local pkg="$1"; local source_dir="${NLAB_SOURCE_DIR}"; local orig="$PWD"
    echo "🔨 [$pkg] Bootstrap" >&2
    nlab_get_build_env "$pkg" >/dev/null
    cd "$source_dir" || return 1
    [[ -f "./bootstrap.sh" ]] && { ./bootstrap.sh --prefix="$NLAB_PREFIX" || return 1; }
    [[ -f "./bootstrap"    ]] && { ./bootstrap    --prefix="$NLAB_PREFIX" || return 1; }
    [[ -f "./autogen.sh"   ]] && { ./autogen.sh                           || return 1; }
    if [[ -f "./configure" ]]; then
        ./configure --prefix="$NLAB_PREFIX" CC="${CC:-gcc}" CXX="${CXX:-g++}" \
            CFLAGS="${CFLAGS:-}" LDFLAGS="${LDFLAGS:-}" || return 1
        make -j"${NPROC:-4}" || return 1; make install || return 1
    elif [[ -f "Makefile" || -f "GNUmakefile" ]]; then
        make -j"${NPROC:-4}" PREFIX="$NLAB_PREFIX" || return 1
        make install PREFIX="$NLAB_PREFIX" || return 1
    fi
    cd "$orig"; return 0
}

nlab_build_python() {
    local pkg="$1"; local source_dir="${NLAB_SOURCE_DIR}"; local orig="$PWD"
    echo "🔨 [$pkg] Python" >&2
    nlab_get_build_env "$pkg" >/dev/null
    cd "$source_dir" || return 1
    local py="$NLAB_PREFIX/bin/python3"
    [[ ! -x "$py" ]] && py="$(command -v python3)"
    if [[ "$pkg" == "python" ]]; then
        ./configure --prefix="$NLAB_PREFIX" --enable-shared --enable-optimizations \
            CC="${CC:-gcc}" CXX="${CXX:-g++}" CFLAGS="${CFLAGS:-}" LDFLAGS="${LDFLAGS:-}" || return 1
        make -j"${NPROC:-4}" || return 1; make install || return 1
        ln -sf "$NLAB_PREFIX/bin/python3" "$NLAB_PREFIX/bin/python" 2>/dev/null || true
        ln -sf "$NLAB_PREFIX/bin/pip3"    "$NLAB_PREFIX/bin/pip"    2>/dev/null || true
        "$NLAB_PREFIX/bin/python3" -m pip install --upgrade pip setuptools wheel
    elif [[ -f "pyproject.toml" ]]; then
        "$py" -m pip install . --prefix="$NLAB_PREFIX" --no-build-isolation 2>/dev/null \
            || "$py" -m pip install . --prefix="$NLAB_PREFIX" || return 1
    elif [[ -f "setup.py" ]]; then
        "$py" setup.py build || return 1
        "$py" setup.py install --prefix="$NLAB_PREFIX" || return 1
    else
        "$py" -m pip install . --prefix="$NLAB_PREFIX" || return 1
    fi
    cd "$orig"; return 0
}

nlab_build_boost() {
    local pkg="$1"; local source_dir="${NLAB_SOURCE_DIR}"; local orig="$PWD"
    echo "🔨 [$pkg] Boost.Build" >&2
    nlab_get_build_env "$pkg" >/dev/null
    cd "$source_dir" || return 1
    ./bootstrap.sh --prefix="$NLAB_PREFIX" --with-libraries=all \
        --with-toolset="${NLAB_COMPILER_FAMILY:-gcc}" || return 1
    ./b2 -j"${NPROC:-4}" install toolset="${NLAB_COMPILER_FAMILY:-gcc}" \
        cxxflags="${CXXFLAGS:-}" linkflags="${LDFLAGS:-}" || return 1
    cd "$orig"; return 0
}

nlab_build_cargo() {
    local pkg="$1"; local source_dir="${NLAB_SOURCE_DIR}"; local orig="$PWD"
    echo "🔨 [$pkg] Cargo" >&2
    nlab_get_build_env "$pkg" >/dev/null
    cd "$source_dir" || return 1
    cargo build --release --target-dir "$source_dir/target" || return 1
    for bin in "$source_dir/target/release"/*; do
        [[ -f "$bin" && -x "$bin" && ! "$bin" =~ \. ]] && \
            cp "$bin" "$NLAB_PREFIX/bin/" && chmod +x "$NLAB_PREFIX/bin/$(basename "$bin")"
    done
    cd "$orig"; return 0
}

nlab_build_go() {
    local pkg="$1"; local source_dir="${NLAB_SOURCE_DIR}"; local orig="$PWD"
    echo "🔨 [$pkg] Go" >&2
    nlab_get_build_env "$pkg" >/dev/null
    cd "$source_dir" || return 1
    if [[ -f "go.mod" ]]; then
        go build -o "$NLAB_PREFIX/bin/$pkg" . || return 1
    else
        local main; main=$(find . -name "main.go" | head -1)
        [[ -z "$main" ]] && { echo "❌ No main.go" >&2; return 1; }
        go build -o "$NLAB_PREFIX/bin/$pkg" "$main" || return 1
    fi
    cd "$orig"; return 0
}

nlab_build_node() {
    local pkg="$1"; local source_dir="${NLAB_SOURCE_DIR}"; local orig="$PWD"
    echo "🔨 [$pkg] npm" >&2
    nlab_get_build_env "$pkg" >/dev/null
    cd "$source_dir" || return 1
    npm install || return 1
    grep -q '"build"' package.json 2>/dev/null && { npm run build || return 1; }
    npm install -g --prefix "$NLAB_PREFIX" . || return 1
    cd "$orig"; return 0
}

nlab_build_ruby() {
    local pkg="$1"; local source_dir="${NLAB_SOURCE_DIR}"; local orig="$PWD"
    echo "🔨 [$pkg] Ruby gem" >&2
    nlab_get_build_env "$pkg" >/dev/null
    cd "$source_dir" || return 1
    [[ -f "Gemfile" ]] && { bundle install || true; }
    local gemspec; gemspec=$(ls *.gemspec 2>/dev/null | head -1)
    if [[ -n "$gemspec" ]]; then
        gem build "$gemspec" || return 1
        local gf; gf=$(ls *.gem 2>/dev/null | head -1)
        [[ -n "$gf" ]] && gem install --local "$gf" --install-dir "$NLAB_PREFIX/lib/ruby/gems" || return 1
    fi
    cd "$orig"; return 0
}

nlab_build_perl() {
    local pkg="$1"; local source_dir="${NLAB_SOURCE_DIR}"; local orig="$PWD"
    echo "🔨 [$pkg] Perl" >&2
    nlab_get_build_env "$pkg" >/dev/null
    cd "$source_dir" || return 1
    if [[ -f "Makefile.PL" ]]; then
        perl Makefile.PL INSTALL_BASE="$NLAB_PREFIX" || return 1
        make -j"${NPROC:-4}" || return 1; make install || return 1
    elif [[ -f "Build.PL" ]]; then
        perl Build.PL --install_base "$NLAB_PREFIX" || return 1
        ./Build || return 1; ./Build install || return 1
    else
        echo "❌ No Perl build file" >&2; return 1
    fi
    cd "$orig"; return 0
}

nlab_build_scons() {
    local pkg="$1"; local source_dir="${NLAB_SOURCE_DIR}"; local orig="$PWD"
    echo "🔨 [$pkg] SCons" >&2
    nlab_get_build_env "$pkg" >/dev/null
    cd "$source_dir" || return 1
    scons -j"${NPROC:-4}" CC="${CC:-gcc}" CXX="${CXX:-g++}" \
        CFLAGS="${CFLAGS:-}" LDFLAGS="${LDFLAGS:-}" || return 1
    if grep -q "install" SConstruct 2>/dev/null; then
        scons install --prefix="$NLAB_PREFIX" || return 1
    else
        local bd; bd=$(find . -maxdepth 2 -type d \( -name "build" -o -name "bin" \) | head -1)
        [[ -n "$bd" ]] && find "$bd" -maxdepth 1 -type f -executable \
            -exec cp {} "$NLAB_PREFIX/bin/" \;
    fi
    cd "$orig"; return 0
}

nlab_build_waf() {
    local pkg="$1"; local source_dir="${NLAB_SOURCE_DIR}"; local orig="$PWD"
    echo "🔨 [$pkg] Waf" >&2
    nlab_get_build_env "$pkg" >/dev/null
    cd "$source_dir" || return 1
    local waf="waf"; [[ -f "./waf" ]] && { chmod +x ./waf; waf="./waf"; }
    [[ ! -f "wscript" && ! -f "./waf" ]] && { echo "❌ No waf/wscript" >&2; return 1; }
    "$waf" configure --prefix="$NLAB_PREFIX" CC="${CC:-gcc}" CXX="${CXX:-g++}" || return 1
    "$waf" build   -j"${NPROC:-4}" || return 1
    "$waf" install                  || return 1
    cd "$orig"; return 0
}

nlab_build_qmake() {
    local pkg="$1"; local source_dir="${NLAB_SOURCE_DIR}"; local orig="$PWD"
    echo "🔨 [$pkg] QMake" >&2
    nlab_get_build_env "$pkg" >/dev/null
    local pro; pro=$(find "$source_dir" -maxdepth 1 -name "*.pro" | head -1)
    [[ -z "$pro" ]] && { echo "❌ No .pro file" >&2; return 1; }
    local build_dir="$source_dir/build"
    rm -rf "$build_dir"; mkdir -p "$build_dir"; cd "$build_dir" || return 1
    qmake "$pro" PREFIX="$NLAB_PREFIX" \
        QMAKE_CC="${CC:-gcc}" QMAKE_CXX="${CXX:-g++}" \
        QMAKE_CFLAGS="${CFLAGS:-}" QMAKE_LFLAGS="${LDFLAGS:-}" || return 1
    make -j"${NPROC:-4}" || return 1; make install || return 1
    cd "$orig"; return 0
}

nlab_build_fortran() {
    local pkg="$1"; local source_dir="${NLAB_SOURCE_DIR}"; local orig="$PWD"
    echo "🔨 [$pkg] Fortran" >&2
    nlab_get_build_env "$pkg" >/dev/null
    cd "$source_dir" || return 1
    setopt localoptions nullglob
    local -a fsrcs=( *.f90 *.F90 *.f *.F )
    [[ ${#fsrcs[@]} -eq 0 ]] && { echo "❌ No Fortran files" >&2; return 1; }
    local fc="${FC:-gfortran}"; local -a objs=()
    for f in "${fsrcs[@]}"; do
        "$fc" -c -O2 -fPIC "${FFLAGS:-}" "$f" -o "${f%.*}.o" || return 1
        objs+=("${f%.*}.o")
    done
    "$fc" -O2 -fPIC "${FFLAGS:-}" "${objs[@]}" -o "$NLAB_PREFIX/bin/$pkg" || return 1
    chmod +x "$NLAB_PREFIX/bin/$pkg"
    cd "$orig"; return 0
}

nlab_build_doxygen() {
    local pkg="$1"; local source_dir="${NLAB_SOURCE_DIR}"; local orig="$PWD"
    echo "🔨 [$pkg] Doxygen" >&2
    nlab_get_build_env "$pkg" >/dev/null
    cd "$source_dir" || return 1
    [[ ! -f "Doxyfile" ]] && { echo "❌ No Doxyfile" >&2; return 1; }
    doxygen Doxyfile || return 1
    local out_dir; out_dir=$(grep -E '^OUTPUT_DIRECTORY' Doxyfile | sed -E 's/.*=[[:space:]]*//')
    [[ -z "$out_dir" ]] && out_dir="html"
    local doc_dir="$NLAB_PREFIX/share/doc/$pkg"; mkdir -p "$doc_dir"
    [[ -d "$out_dir" ]] && cp -a "$out_dir"/. "$doc_dir/"
    cd "$orig"; return 0
}

nlab_build_swig() {
    local pkg="$1"; local source_dir="${NLAB_SOURCE_DIR}"; local orig="$PWD"
    echo "🔨 [$pkg] SWIG" >&2
    nlab_get_build_env "$pkg" >/dev/null
    cd "$source_dir" || return 1
    setopt localoptions nullglob
    local -a sfs=( *.i *.swg )
    [[ ${#sfs[@]} -eq 0 ]] && { echo "❌ No .i/.swg files" >&2; return 1; }
    local lang="${SWIG_TARGET_LANG:-python}"
    for sf in "${sfs[@]}"; do
        local base="${sf%.*}"
        swig -"$lang" -o "${base}_wrap.c" "$sf" || return 1
        if [[ "$lang" == "python" ]]; then
            local site="$NLAB_PREFIX/lib/python3/site-packages"; mkdir -p "$site"
            "${CC:-gcc}" -O2 -fPIC -shared "${CFLAGS:-}" "${base}_wrap.c" -o "_${base}.so" || return 1
            cp "_${base}.so" "$site/"
        fi
    done
    cd "$orig"; return 0
}

nlab_build_elisp() {
    local pkg="$1"; local source_dir="${NLAB_SOURCE_DIR}"; local orig="$PWD"
    echo "🔨 [$pkg] Emacs Lisp" >&2
    nlab_get_build_env "$pkg" >/dev/null
    cd "$source_dir" || return 1
    setopt localoptions nullglob
    local -a els=( *.el )
    [[ ${#els[@]} -eq 0 ]] && { echo "❌ No .el files" >&2; return 1; }
    for el in "${els[@]}"; do emacs -batch -f batch-byte-compile "$el" || return 1; done
    local site="$NLAB_PREFIX/share/emacs/site-lisp/$pkg"; mkdir -p "$site"
    cp *.el *.elc "$site/" 2>/dev/null || true
    cd "$orig"; return 0
}

nlab_build_wmake() {
    local pkg="$1"; local source_dir="${NLAB_SOURCE_DIR}"; local orig="$PWD"
    echo "🔨 [$pkg] wmake" >&2
    nlab_get_build_env "$pkg" >/dev/null
    cd "$source_dir" || return 1
    ./Allwmake -j"${NPROC:-4}" || return 1
    cd "$orig"; return 0
}

nlab_build_binary() {
    local pkg="$1"; local source_dir="${NLAB_SOURCE_DIR}"
    echo "📦 [$pkg] Binary install" >&2
    nlab_get_build_env "$pkg" >/dev/null
    local n=0
    for d in bin libexec; do
        [[ ! -d "$source_dir/$d" ]] && continue
        for f in "$source_dir/$d"/*; do
            [[ -f "$f" && -x "$f" ]] || continue
            cp "$f" "$NLAB_PREFIX/bin/" && chmod +x "$NLAB_PREFIX/bin/$(basename "$f")" && ((n++))
        done
    done
    for d in lib lib64; do
        [[ ! -d "$source_dir/$d" ]] && continue
        for f in "$source_dir/$d"/*.{dylib,so,a} 2>/dev/null; do
            [[ -f "$f" ]] && cp "$f" "$NLAB_PREFIX/lib/" && ((n++))
        done
    done
    [[ -d "$source_dir/include" ]] && cp -rn "$source_dir/include"/. "$NLAB_PREFIX/include/"
    [[ $n -eq 0 ]] && { echo "❌ No binaries/libs in $source_dir" >&2; return 1; }
    return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 4 — BUILD EXECUTOR (DB-centric)
# ─────────────────────────────────────────────────────────────────────────────

nlab_build_package() {
    local pkg="$1" override_bs="${2:-}" orig="$PWD"
    local version="${PKG_VERSION[$pkg]:-latest}"
    echo ""; echo "═══════════════════════════════════════════════════════════"
    echo "  Building: $pkg  v${version}  (${NLAB_COMPILER_FAMILY:-?}@${NLAB_COMPILER_VERSION:-?})"
    echo "═══════════════════════════════════════════════════════════"

    # Virtual/system
    local pkg_type="${PKG_TYPE[$pkg]:-}"
    if [[ "$pkg_type" == "virtual" || "$pkg_type" == "system" ]]; then
        echo "📦 $pkg is virtual/system — satisfied"
        return 0
    fi

    # ── Check DB for existing install ──────────────────────────────────
    if _nlab_db_available 2>/dev/null; then
        local status=$(sqlite3 "$NLAB_DB" \
            "SELECT status FROM installs i JOIN packages p ON i.pkg_id=p.id
             WHERE p.name='$pkg'
               AND i.compiler_family='${NLAB_COMPILER_FAMILY:-gcc}'
               AND i.compiler_version='${NLAB_COMPILER_VERSION:-14}'
               AND i.status='installed'" 2>/dev/null | head -1)
        if [[ "$status" == "installed" ]]; then
            echo "⏭️  $pkg already installed (${NLAB_COMPILER_FAMILY:-gcc}@${NLAB_COMPILER_VERSION:-14})"
            return 0
        fi
    fi

    # Cache restore (still uses flat cache directory; keep as is)
    if nlab_cache_restore "$pkg" "$version" 2>/dev/null; then
        echo "🧊 Restored $pkg from cache"; return 0
    fi

    # ── Determine build system ────────────────────────────────────────
    local bs="$override_bs"
    if [[ -z "$bs" || "$bs" == "unknown" || "$bs" == "auto" ]]; then
        if _nlab_db_available 2>/dev/null; then
            bs=$(sqlite3 "$NLAB_DB" "SELECT build_system FROM packages WHERE name='$pkg'" 2>/dev/null | head -1)
        fi
    fi
    [[ -z "$bs" || "$bs" == "unknown" ]] && bs="${PKG_BUILD_SYSTEM[$pkg]:-}"

    # ── Prepare source ─────────────────────────────────────────────────
    local source_dir
    source_dir=$(nlab_prepare_source "$pkg") || { echo "❌ Source prep failed" >&2; return 1; }
    export NLAB_SOURCE_DIR="$source_dir"
    _nlab_clean_build_source "$source_dir"

    # Scan source if build system still unknown
    if [[ -z "$bs" || "$bs" == "unknown" || "$bs" == "auto" ]]; then
        typeset -f detect_build_system >/dev/null 2>&1 && \
            bs=$(detect_build_system "$source_dir") || true
        if [[ -n "$bs" && "$bs" != "unknown" ]]; then
            # Update DB with detected build system
            if _nlab_db_available 2>/dev/null; then
                sqlite3 "$NLAB_DB" "UPDATE packages SET build_system='$bs' WHERE name='$pkg'" 2>/dev/null
            fi
        fi
    fi
    [[ -z "$bs" || "$bs" == "unknown" ]] && { echo "❌ Cannot determine build system for $pkg" >&2; return 1; }
    echo "🔧 Build system: $bs"

    # ── Dispatch ──────────────────────────────────────────────────────
    local ret=0
    case "$bs" in
        autotools) nlab_build_autotools "$pkg" || ret=$? ;;
        cmake)     nlab_build_cmake     "$pkg" || ret=$? ;;
        make)      nlab_build_make      "$pkg" || ret=$? ;;
        meson)     nlab_build_meson     "$pkg" || ret=$? ;;
        python)    nlab_build_python    "$pkg" || ret=$? ;;
        bootstrap) nlab_build_bootstrap "$pkg" || ret=$? ;;
        boost)     nlab_build_boost     "$pkg" || ret=$? ;;
        cargo)     nlab_build_cargo     "$pkg" || ret=$? ;;
        go)        nlab_build_go        "$pkg" || ret=$? ;;
        node)      nlab_build_node      "$pkg" || ret=$? ;;
        ruby)      nlab_build_ruby      "$pkg" || ret=$? ;;
        perl)      nlab_build_perl      "$pkg" || ret=$? ;;
        scons)     nlab_build_scons     "$pkg" || ret=$? ;;
        waf)       nlab_build_waf       "$pkg" || ret=$? ;;
        qmake)     nlab_build_qmake     "$pkg" || ret=$? ;;
        fortran)   nlab_build_fortran   "$pkg" || ret=$? ;;
        doxygen)   nlab_build_doxygen   "$pkg" || ret=$? ;;
        swig)      nlab_build_swig      "$pkg" || ret=$? ;;
        elisp)     nlab_build_elisp     "$pkg" || ret=$? ;;
        wmake)     nlab_build_wmake     "$pkg" || ret=$? ;;
        binary)    nlab_build_binary    "$pkg" || ret=$? ;;
        *)
            echo "❌ Unknown build system: $bs" >&2
            ret=1 ;;
    esac

    cd "$orig" 2>/dev/null
    [[ $ret -eq 0 ]] && echo "✅ $pkg built" || echo "❌ Build failed: $pkg"
    return $ret
}

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 5 — TOP-LEVEL ENTRY POINTS
# ─────────────────────────────────────────────────────────────────────────────

nlab_build_flat() {
    local force=0 keep_build=0 override_bs=""
    local -a pkgs=()
    local orig="$PWD"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --force)        force=1;             shift ;;
            --keep-build)   keep_build=1;        shift ;;
            --build-system) shift; override_bs="$1"; shift ;;
            --cmake)        override_bs="cmake"; shift ;;
            --meson)        override_bs="meson"; shift ;;
            --make)         override_bs="make";  shift ;;
            --autotools)    override_bs="autotools"; shift ;;
            --help|-h)      echo "Usage: nlab build [--force] [--cmake|…] <pkg> …"; return 0 ;;
            --*)            echo "❌ Unknown: $1"; return 1 ;;
            *)              pkgs+=("$1"); shift ;;
        esac
    done
    (( ${#pkgs} == 0 )) && { echo "❌ Usage: nlab build <pkg> …"; return 1; }
    export NLAB_KEEP_BUILD_FILES=$keep_build

    # Resolve build order (assume resolve_build_order now uses DB)
    local -a order; order=($(resolve_build_order "${pkgs[@]}"))

    # Ensure package records exist in DB (register metadata if missing)
    for pkg in "${order[@]}"; do
        if _nlab_db_available 2>/dev/null; then
            local exists=$(sqlite3 "$NLAB_DB" "SELECT name FROM packages WHERE name='$pkg'" 2>/dev/null)
            [[ -z "$exists" ]] && {
                # Register minimal package info; source detection will fill details later
                nlab_db_register_package "$pkg" --build-system "auto" 2>/dev/null || true
            }
        fi
    done

    local -a failed=(); local n=0; local total=${#order[@]}

    for pkg in "${order[@]}"; do
        ((n++))
        echo ""; echo "─────────────────────────────────────────────────────────"
        echo "  [$n/$total] $pkg"; echo "─────────────────────────────────────────────────────────"

        if nlab_build_package "$pkg" "$override_bs"; then
            # Register install in DB (flat files are deprecated but still written for compatibility)
            nlab_meta_register "$pkg" "${NLAB_COMPILER_FAMILY:-gcc}" "${NLAB_COMPILER_VERSION:-14}"
            local ts; ts=$(mktemp)
            sleep 0.1
            nlab_record_installation "$pkg" "$ts" 2>/dev/null || true
            nlab_lock_update "$pkg" 2>/dev/null || true
            nlab_cache_save "$pkg" "${PKG_VERSION[$pkg]:-latest}" 2>/dev/null || true
            refresh_pkgconfig
            nlab_verify_installation "$pkg" || true
        else
            failed+=("$pkg")
        fi
    done

    cd "$orig" 2>/dev/null
    if [[ ${#failed[@]} -eq 0 ]]; then
        echo ""; echo "✅ All $total package(s) built successfully!"
        return 0
    else
        echo ""; echo "❌ Failed: ${failed[*]}"
        return ${#failed[@]}
    fi
}

nlab_build() {
    local pkg="$1"; shift; local opts=("$@"); local t=$SECONDS
    _nlab_db_available 2>/dev/null && \
        _db_quiet register "$pkg" "${PKG_VERSION[$pkg]:-latest}" \
            "${NLAB_COMPILER_FAMILY:-gcc}" "${NLAB_COMPILER_VERSION:-14}" || true
    nlab_build_flat "$pkg" "${opts[@]}"
    local rc=$?
    _nlab_db_available 2>/dev/null && \
        _db_quiet log-build "$pkg" "${NLAB_COMPILER_FAMILY:-gcc}" "${NLAB_COMPILER_VERSION:-14}" \
            "$( [[ $rc -eq 0 ]] && echo success || echo failed )" "$(( SECONDS - t ))s" || true
    return $rc
}

nlab_install() {
    local spec="$1"
    [[ -z "$spec" ]] && { echo "❌ Usage: nlab install pkg%compiler@ver^dep1^dep2"; return 1; }
    local pkg="" fam="" ver=""; local -a deps=()
    if [[ "$spec" =~ ^([^%^]+)(%([^@^]+)@([^@^]+))?(\^(.+))?$ ]]; then
        pkg="${match[1]}"; fam="${match[3]:-gcc}"; ver="${match[4]:-14}"
        local dp="${match[6]:-}"; [[ -n "$dp" ]] && deps=(${(s:^:)dp})
    else
        echo "❌ Cannot parse: $spec" >&2; return 1
    fi
    typeset -f comp >/dev/null 2>&1 && comp "$fam" "$ver" || true
    nlab_build_flat "${deps[@]}" "$pkg" || return 1
    echo "✅ Installed: $spec"
}
# ─────────────────────────────────────────────────────────────────────────────
# SECTION 6 — UNINSTALL / CLEAN
# ─────────────────────────────────────────────────────────────────────────────

nlab_clean() {
    local pkg="$1"
    rm -f "$NLAB_META/${pkg}.installed" "$NLAB_META/${pkg}.compiler" \
          "$NLAB_META/${pkg}.files"     "$NLAB_META/${pkg}.timestamp" \
          "$NLAB_META/${pkg}.meta"
    echo "✅ Cleaned meta: $pkg" >&2
}

nlab_deepclean() {
    local pkg="$1"; nlab_clean "$pkg"
    local src; src=$(find_local_source "$pkg" 2>/dev/null) || true
    [[ -n "$src" && -d "$src" ]] && { echo "   Removing $src" >&2; rm -rf "$src"; }
}

nlab_uninstall() {
    local -a failed=() success=()
    [[ $# -eq 0 ]] && { echo "Usage: nlab uninstall <pkg> … | --all"; return 1; }
    if [[ "$1" == "--all" ]]; then
        echo "⚠️  Uninstall ALL?"; print -n "[y/N]: "; read -r R
        [[ ! "$R" =~ ^[Yy]$ ]] && { echo "Cancelled"; return 1; }
        set -- $(nlab_list_installed)
    fi
    for pkg in "$@"; do
        # Check DB first
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
        if [[ $installed -eq 0 ]]; then
            echo "❌ $pkg not installed (DB)" ; failed+=("$pkg"); continue
        fi
        echo "🗑️  Uninstalling $pkg..."
        # Try make uninstall
        local src; src=$(find_local_source "$pkg" 2>/dev/null) || true
        if [[ -n "$src" && -d "$src" ]]; then
            local bd="$src/build"; [[ ! -d "$bd" ]] && bd="$src"
            if [[ -f "$bd/Makefile" ]]; then
                (cd "$bd" && make uninstall 2>/dev/null) || true
                (cd "$bd" && make clean     2>/dev/null) || true
                (cd "$bd" && make distclean 2>/dev/null) || true
            fi
        fi
        # Remove recorded files from flat list
        local fl="$NLAB_META/${pkg}.files" rm=0 gn=0
        if [[ -f "$fl" ]]; then
            while IFS= read -r fp; do
                [[ -z "$fp" ]] && continue
                if [[ -f "$fp" || -L "$fp" ]]; then rm -f "$fp" && ((rm++)) || true
                else ((gn++)); fi
            done < "$fl"
        fi
        nlab_clean "$pkg"
        # Mark removed in DB
        _nlab_db_available 2>/dev/null && \
            _db_quiet unregister "$pkg" "${NLAB_COMPILER_FAMILY:-gcc}" "${NLAB_COMPILER_VERSION:-14}" 2>/dev/null || true
        echo "   ✅ Removed $rm files ($gn already gone)"
        success+=("$pkg")
    done
    echo ""; echo "📊 Uninstall: ✅${#success[@]}  ❌${#failed[@]}"
    return ${#failed[@]}
}

nlab_uninstall_pat() {
    local pattern="$1"
    [[ -z "$pattern" ]] && { echo "Usage: nlab uninstall-pattern <pattern>"; return 1; }
    local -a matched=()
    for p in $(nlab_list_installed); do [[ "$p" =~ $pattern ]] && matched+=("$p"); done
    [[ ${#matched[@]} -eq 0 ]] && { echo "No match: $pattern"; return 1; }
    printf "Found: %s\n" "${matched[*]}"
    print -n "Uninstall? [y/N]: "; read -r R
    [[ "$R" =~ ^[Yy]$ ]] && nlab_uninstall "${matched[@]}"
}

nlab_rebuild()     { nlab_uninstall "$1" && nlab_deepclean "$1" && nlab_build "$1"; }
nlab_rebuild_all() {
    local -a todo=()
    # Get list from DB
    if _nlab_db_available 2>/dev/null; then
        todo=($(sqlite3 "$NLAB_DB" \
            "SELECT p.name FROM installs i JOIN packages p ON i.pkg_id=p.id
             WHERE i.status='installed' AND i.compiler_family='${NLAB_COMPILER_FAMILY:-gcc}'
               AND i.compiler_version='${NLAB_COMPILER_VERSION:-14}'" 2>/dev/null))
    fi
    [[ ${#todo[@]} -eq 0 ]] && { echo "✅ No installed packages to rebuild"; return 0; }
    echo "📦 Rebuilding: ${todo[*]}"
    for p in "${todo[@]}"; do nlab_build "$p" || { echo "❌ Failed: $p"; return 1; }; done
}

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 7 — PACKAGE INFO (DB-centric)
# ─────────────────────────────────────────────────────────────────────────────

nlab_pkg_info() {
    local pkg="$1"
    [[ -z "$pkg" ]] && { echo "❌ Usage: nlab info <pkg>"; return 1; }
    echo ""; echo "╔══════════════════════════════════════════════════════════════╗"
    printf "║  Package: %-53s║\n" "$pkg"
    echo "╠══════════════════════════════════════════════════════════════╣"

    if _nlab_db_available 2>/dev/null; then
        local row=$(sqlite3 -separator $'\t' "$NLAB_DB" \
            "SELECT build_system, source_url, source_path, required_compiler, flags
             FROM packages WHERE name='$pkg'" 2>/dev/null)
        IFS=$'\t' read -r bs src_url src_path req_comp flags <<< "$row"
        [[ -z "$bs" ]] && bs="unknown"
        [[ -z "$flags" ]] && flags="none"
        printf "║  Build System: %-48s║\n" "$bs"
        printf "║  Source URL:   %-48s║\n" "${src_url:-local}"
        printf "║  Source Path:  %-48s║\n" "${src_path:-n/a}"
        printf "║  Required Comp:%-48s║\n" "${req_comp:-auto}"
        printf "║  Flags:        %-48s║\n" "$flags"
        # Get dependencies from pkg_deps
        local deps=$(sqlite3 "$NLAB_DB" \
            "SELECT dep_name FROM pkg_deps WHERE pkg_id=(SELECT id FROM packages WHERE name='$pkg')
             AND dep_type='runtime' ORDER BY dep_name" 2>/dev/null | tr '\n' ' ')
        [[ -z "$deps" ]] && deps="none"
        printf "║  Runtime Deps: %-48s║\n" "$deps"
        # Build deps
        local bdeps=$(sqlite3 "$NLAB_DB" \
            "SELECT dep_name FROM pkg_deps WHERE pkg_id=(SELECT id FROM packages WHERE name='$pkg')
             AND dep_type='build' ORDER BY dep_name" 2>/dev/null | tr '\n' ' ')
        [[ -z "$bdeps" ]] && bdeps="none"
        printf "║  Build Deps:   %-48s║\n" "$bdeps"
        # Check install status
        local status=$(sqlite3 "$NLAB_DB" \
            "SELECT status FROM installs i JOIN packages p ON i.pkg_id=p.id
             WHERE p.name='$pkg'
               AND i.compiler_family='${NLAB_COMPILER_FAMILY:-gcc}'
               AND i.compiler_version='${NLAB_COMPILER_VERSION:-14}'
               AND i.status='installed'" 2>/dev/null | head -1)
        if [[ "$status" == "installed" ]]; then
            printf "║  Status:       ✅ Installed (%s%*s║\n" \
                "${NLAB_COMPILER_FAMILY:-gcc}@${NLAB_COMPILER_VERSION:-14}" $((40 - 2 - ${#NLAB_COMPILER_FAMILY} - ${#NLAB_COMPILER_VERSION})) ""
        else
            printf "║  Status:       ❌ Not installed%37s║\n" ""
        fi
    else
        printf "║  DB not available%48s║\n" ""
    fi
    echo "╚══════════════════════════════════════════════════════════════╝"; echo ""
}

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 8 — INIT
# ─────────────────────────────────────────────────────────────────────────────

[[ -n "$NLAB_VERBOSE" ]] && {
    echo "🧠 NLAB Brain loaded (DB-centric)"
    echo "   Architecture: Prepare → nlab_get_build_env → Execute → Register"
    echo "   Backends: autotools cmake make meson python bootstrap boost"
    echo "             cargo go node ruby perl scons waf qmake fortran"
    echo "             doxygen swig elisp wmake binary"
}
