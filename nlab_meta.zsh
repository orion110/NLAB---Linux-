#!/bin/zsh
# ============================================================================
# NLAB GENERATION - Source Management & DB Registration
# ============================================================================
# This file provides source discovery, download, extraction, and detection.
# All metadata is written directly to SQLite (no YAML/meta files).
# ============================================================================

# ─────────────────────────────────────────────────────────────────────────────
# GLOBAL ARRAYS (for caching, still used by some functions)
# ─────────────────────────────────────────────────────────────────────────────
typeset -gA PKG_RUNTIME_DEPS PKG_BUILD_DEPS PKG_OPTIONAL_DEPS
typeset -gA PKG_VERSION PKG_SOURCE PKG_TYPE PKG_BUILD_SYSTEM
typeset -gA PKG_IS_SOLVER PKG_URL PKG_FLAGS PKG_DEPS
typeset -gA PKG_BUILD_DEPS_RECIPE PKG_COMPILER_REQUIRED
typeset -gA PKG_CONFIG_ARGS PKG_SOURCE_PATH

# ─────────────────────────────────────────────────────────────────────────────
# 1. Build System Detection
# ─────────────────────────────────────────────────────────────────────────────
detect_build_system() {
    local source_dir="$1"
    [[ -z "$source_dir" ]] && source_dir="${NLAB_SOURCE_DIR:-.}"
    cd "$source_dir" 2>/dev/null || return 1

    if [[ -f "CMakeLists.txt" ]]; then
        echo "cmake"; return 0
    elif [[ -f "meson.build" ]]; then
        echo "meson"; return 0
    elif [[ -f "configure" ]] || [[ -f "configure.ac" ]] || [[ -f "configure.in" ]]; then
        echo "autotools"; return 0
    elif [[ -f "Makefile" ]] || [[ -f "GNUmakefile" ]]; then
        if grep -q "boost" Makefile 2>/dev/null || [[ -f "bootstrap.sh" ]] && grep -q "boost" bootstrap.sh 2>/dev/null; then
            echo "boost"; return 0
        fi
        if [[ -f "Allwmake" ]] || grep -q "wmake" Makefile 2>/dev/null; then
            echo "wmake"; return 0
        fi
        echo "make"; return 0
    elif [[ -f "setup.py" ]] || [[ -f "pyproject.toml" ]]; then
        echo "python"; return 0
    elif [[ -f "Cargo.toml" ]]; then
        echo "cargo"; return 0
    elif [[ -f "go.mod" ]]; then
        echo "go"; return 0
    elif [[ -f "package.json" ]]; then
        echo "node"; return 0
    elif [[ -f "Gemfile" ]] || ls *.gemspec 2>/dev/null | head -1 >/dev/null; then
        echo "ruby"; return 0
    elif [[ -f "Makefile.PL" ]] || [[ -f "Build.PL" ]]; then
        echo "perl"; return 0
    elif [[ -f "SConstruct" ]] || [[ -f "SConscript" ]]; then
        echo "scons"; return 0
    elif [[ -f "wscript" ]] || [[ -f "waf" ]]; then
        echo "waf"; return 0
    elif ls *.pro 2>/dev/null | head -1 >/dev/null; then
        echo "qmake"; return 0
    elif ls *.f90 *.F90 *.f *.F 2>/dev/null | head -1 >/dev/null; then
        echo "fortran"; return 0
    elif [[ -f "Doxyfile" ]]; then
        echo "doxygen"; return 0
    elif ls *.i *.swg 2>/dev/null | head -1 >/dev/null; then
        echo "swig"; return 0
    elif ls *.el 2>/dev/null | head -1 >/dev/null; then
        echo "elisp"; return 0
    elif [[ -f "bootstrap" ]] || [[ -f "bootstrap.sh" ]] || [[ -f "autogen.sh" ]]; then
        echo "bootstrap"; return 0
    elif [[ -d "bin" ]] && [[ -d "lib" ]] && [[ -d "include" ]]; then
        echo "binary"; return 0
    else
        echo "unknown"; return 1
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# 2. Source Discovery (local & download)
# ─────────────────────────────────────────────────────────────────────────────
find_local_source() {
    local pkg="$1"
    local src_base="${NLAB_SRC:-/Volumes/nlab/source}"
    local extracted=$(find "$src_base/tarballs" -maxdepth 1 -type d -iname "${pkg}-*" 2>/dev/null | sort -V | head -1)
    [[ -n "$extracted" && -d "$extracted" ]] && { echo "$extracted"; return 0; }
    [[ -d "$src_base/git/$pkg/.git" ]] && { echo "$src_base/git/$pkg"; return 0; }
    local tarball=""
    for ext in tar.gz tgz tar.xz tar.bz2 zip; do
        tarball=$(find "$src_base/tarballs" -maxdepth 1 -type f -iname "${pkg}-*.${ext}" 2>/dev/null | sort -V | head -1)
        [[ -n "$tarball" ]] && break
    done
    [[ -n "$tarball" && -f "$tarball" ]] && { echo "$tarball"; return 0; }
    [[ -d "$src_base/$pkg" ]] && { echo "$src_base/$pkg"; return 0; }
    [[ -d "$src_base/tarballs/$pkg" ]] && { echo "$src_base/tarballs/$pkg"; return 0; }
    return 1
}

extract() {
    local target_dir="${NLAB_SRC:-.}/tarballs"
    local archives=() verbose=1 force=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dir|-d) shift; target_dir="$1"; shift ;;
            --force|-f) force=1; shift ;;
            --quiet|-q) verbose=0; shift ;;
            -*) echo "❌ Unknown: $1" >&2; return 1 ;;
            *) archives+=("$1"); shift ;;
        esac
    done
    [[ ${#archives[@]} -eq 0 ]] && { echo "❌ Usage: extract <archive> ..." >&2; return 1; }
    mkdir -p "$target_dir"
    local extracted=0 skipped=0 failed=0
    for archive in "${archives[@]}"; do
        [[ ! -f "$archive" ]] && { echo "⚠️  Not found: $archive" >&2; ((failed++)); continue; }
        local archive_name=$(basename "$archive")
        local base_name="$archive_name"
        base_name="${base_name%.tar.gz}"; base_name="${base_name%.tgz}"
        base_name="${base_name%.tar.xz}"; base_name="${base_name%.tar.bz2}"
        base_name="${base_name%.tar.Z}"; base_name="${base_name%.tar}"
        base_name="${base_name%.zip}"; base_name="${base_name%.7z}"
        local extract_dir="$target_dir/$base_name"
        if [[ -d "$extract_dir" ]] && [[ $force -eq 0 ]]; then
            (( verbose )) && echo "⏭️  Already extracted: $base_name" >&2
            echo "$extract_dir"; ((skipped++)); continue
        fi
        (( verbose )) && echo "📂 Extracting: $archive_name ..." >&2
        case "$archive_name" in
            *.tar.gz|*.tgz) tar -xzf "$archive" -C "$target_dir" || { ((failed++)); continue; } ;;
            *.tar.xz|*.txz) tar -xJf "$archive" -C "$target_dir" || { ((failed++)); continue; } ;;
            *.tar.bz2|*.tbz2) tar -xjf "$archive" -C "$target_dir" || { ((failed++)); continue; } ;;
            *.tar.Z) tar -xZf "$archive" -C "$target_dir" || { ((failed++)); continue; } ;;
            *.tar) tar -xf "$archive" -C "$target_dir" || { ((failed++)); continue; } ;;
            *.zip) unzip -qo "$archive" -d "$target_dir" || { ((failed++)); continue; } ;;
            *.7z) 7z x "$archive" -o"$target_dir" -y >/dev/null || { ((failed++)); continue; } ;;
            *) echo "❌ Unknown format: $archive_name" >&2; ((failed++)); continue ;;
        esac
        if [[ -d "$extract_dir" ]]; then
            echo "$extract_dir"; ((extracted++))
        else
            local created=$(find "$target_dir" -maxdepth 1 -type d -newer "$archive" ! -name ".*" 2>/dev/null | head -1)
            [[ -n "$created" && -d "$created" ]] && { echo "$created"; ((extracted++)); } || { echo "❌ Extraction failed: $archive_name" >&2; ((failed++)); }
        fi
    done
    (( verbose && total > 1 )) && { echo "Extracted: $extracted | Skipped: $skipped | Failed: $failed" >&2; }
    return $failed
}

download() {
    local target_tarballs="${NLAB_SRC:-.}/tarballs" target_git="${NLAB_SRC:-.}/git"
    local url="" filename="" batch_mode=0 interactive=0 force=0
    local -a batch_pkgs=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dir-tarballs|-t) shift; target_tarballs="$1"; shift ;;
            --dir-git|-g) shift; target_git="$1"; shift ;;
            --batch|-b) batch_mode=1; shift
                while [[ $# -gt 0 && "$1" != -* ]]; do batch_pkgs+=("$1"); shift; done ;;
            --interactive|-i) interactive=1; shift ;;
            --force|-f) force=1; shift ;;
            -*) echo "❌ Unknown: $1" >&2; return 1 ;;
            *) url="$1"; shift; [[ $# -gt 0 && "$1" != -* ]] && { filename="$1"; shift; } ;;
        esac
    done
    mkdir -p "$target_tarballs" "$target_git"

    # Batch mode: download multiple packages using DB URLs
    if [[ $batch_mode -eq 1 ]]; then
        [[ ${#batch_pkgs[@]} -eq 0 ]] && { echo "❌ Usage: download --batch <pkg1> ..." >&2; return 1; }
        local downloaded=0 skipped=0 failed=0
        for pkg in "${batch_pkgs[@]}"; do
            # Query DB for source_url
            local src_url=$(sqlite3 "$NLAB_DB" "SELECT source_url FROM packages WHERE name='$pkg'" 2>/dev/null)
            [[ -z "$src_url" ]] && { ((failed++)); continue; }
            if [[ $force -eq 0 ]] && _download_check_exists "$pkg" "$src_url" "$target_tarballs" "$target_git"; then
                ((skipped++)); continue
            fi
            local filename=$(basename "$src_url")
            if _download_single "$src_url" "$filename" "$target_tarballs" "$target_git" "$force"; then
                ((downloaded++))
            else
                ((failed++))
            fi
        done
        echo "Downloaded: $downloaded | Skipped: $skipped | Failed: $failed" >&2
        return $failed
    fi

    # Single/interactive mode
    if [[ $interactive -eq 1 ]] || [[ -z "$url" ]]; then
        [[ -t 0 ]] || { echo "❌ No URL and not interactive" >&2; return 1; }
        echo -n "📎 Enter download URL: " >&2; read -r url
        [[ -z "$url" ]] && { echo "❌ No URL" >&2; return 1; }
        [[ -z "$filename" ]] && { echo -n "📎 Filename (auto): " >&2; read -r filename; }
    fi
    [[ -z "$filename" ]] && filename=$(basename "$url")
    _download_single "$url" "$filename" "$target_tarballs" "$target_git" "$force"
}

_download_check_exists() {
    local pkg="$1" url="$2" tarballs_dir="$3" git_dir="$4"
    if [[ "$url" =~ \.git$ ]] || [[ "$url" =~ ^git@ ]] || [[ "$url" =~ ^https://github\.com/.+/.+$ ]]; then
        local repo=$(basename "$url" .git)
        for candidate in "$repo" "${pkg}" "${pkg}-main" "${pkg}-master"; do
            [[ -d "$git_dir/$candidate/.git" ]] && { echo "✅ Git repo exists: $candidate" >&2; return 0; }
        done
    fi
    local filename=$(basename "$url")
    [[ -f "$tarballs_dir/$filename" ]] && { echo "✅ Archive exists: $filename" >&2; return 0; }
    local base_name="${filename%.tar.gz}"; base_name="${base_name%.tgz}"; base_name="${base_name%.tar.xz}"; base_name="${base_name%.tar.bz2}"; base_name="${base_name%.tar}"; base_name="${base_name%.zip}"; base_name="${base_name%.7z}"
    [[ -d "$tarballs_dir/$base_name" ]] && { echo "✅ Extracted: $base_name" >&2; return 0; }
    return 1
}

_download_single() {
    local url="$1" filename="$2" tarballs_dir="$3" git_dir="$4" force="${5:-0}"
    if [[ "$url" =~ \.git$ ]] || [[ "$url" =~ ^git@ ]] || [[ "$url" =~ ^https://github\.com/.+/.+$ ]]; then
        local repo=$(basename "$url" .git)
        local target="$git_dir/$repo"
        [[ -d "$target/.git" && $force -eq 0 ]] && { echo "✅ Already cloned: $repo" >&2; echo "$target"; return 0; }
        [[ $force -eq 1 && -d "$target" ]] && rm -rf "$target"
        echo "⬇️  Cloning $repo ..." >&2
        git clone --depth 1 "$url" "$target" 2>&1 | grep -v "^Cloning into" >&2 || return 1
        echo "$target"; return 0
    fi
    local target_file="$tarballs_dir/$filename"
    [[ -f "$target_file" && $force -eq 0 ]] && { echo "✅ Already downloaded: $filename" >&2; echo "$target_file"; return 0; }
    echo "⬇️  Downloading $filename ..." >&2
    if command -v curl >/dev/null; then
        curl -L -f -C - --progress-bar "$url" -o "$target_file" 2>&1 && { echo "$target_file"; return 0; }
    fi
    if command -v wget >/dev/null; then
        wget -c -q --show-progress "$url" -O "$target_file" 2>&1 && { echo "$target_file"; return 0; }
    fi
    echo "❌ Download failed" >&2; rm -f "$target_file"; return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# 3. Dependency Scanner (returns deps, build_deps, flags)
# ─────────────────────────────────────────────────────────────────────────────
declare -gA PKG_NAME_MAP=(
    [png]="libpng" [jpeg]="libjpeg-turbo" [z]="zlib" [bz2]="bzip2"
    [lzma]="xz" [zstd]="zstd" [lz4]="lz4" [ssl]="openssl"
    [xml2]="libxml2" [xslt]="libxslt" [xerces]="xerces-c" [expat]="expat"
    [iconv]="libiconv" [gettext]="gettext" [intl]="gettext" [icu]="icu4c"
    [ffi]="libffi" [x11]="libx11" [xcb]="libxcb" [xau]="libxau"
    [xdmcp]="libxdmcp" [xrender]="libxrender" [xkbcommon]="libxkbcommon"
    [ldap]="openldap" [sasl]="cyrus-sasl" [psl]="libpsl" [krb5]="krb5"
    [pcre]="pcre2" [pcre2]="pcre2" [gmp]="gmp" [mpfr]="mpfr"
    [mpc]="mpc" [isl]="isl" [blas]="openblas" [lapack]="openblas"
    [curl]="curl" [nghttp2]="nghttp2" [libssh2]="libssh2" [libidn2]="libidn2"
    [tiff]="libtiff" [gif]="giflib" [webp]="libwebp" [freetype]="freetype"
    [vorbis]="libvorbis" [ogg]="libogg" [theora]="libtheora" [opus]="opus"
    [readline]="readline" [ncurses]="ncurses" [libedit]="libedit"
)

scan_deps() {
    local source_dir="$1" pkg="$2"
    local deps="" build_deps="" flags=""
    cd "$source_dir" || return 1

    # HDF5 special
    if [[ "$pkg" == "hdf5"* ]] || [[ -f "H5public.h" ]] || [[ -f "hdf5.h" ]]; then
        deps="zlib"; build_deps="pkg-config"; flags="--enable-shared --disable-static --with-zlib=$NLAB_EXEC"
        if [[ -f "$NLAB_EXEC/lib/libszip.a" ]] || [[ -f "$NLAB_EXEC/lib/libszip.dylib" ]]; then
            deps+=" szip"; flags+=" --with-szlib=$NLAB_EXEC"
        fi
        if command -v mpicc &>/dev/null; then
            deps+=" mpi"; flags+=" --enable-parallel"; build_deps+=" mpi"
        fi
        echo "$deps|$build_deps|$flags"; return 0
    fi

    # Autotools
    if [[ -f "configure" ]]; then
        local help_out=$(./configure --help 2>/dev/null | sed 's/\[[^]]*\]//g')
        local opts=$(echo "$help_out" | grep -E '^  --(with|enable)-' | awk '{print $1}' | sed 's/^--//' | sed 's/[=,].*//' | sed 's/\[.*//' | grep -v '^with-PACKAGE$' | grep -v '^enable-FEATURE$' | sort -u)
        for opt in ${=opts}; do
            [[ "$opt" =~ ^(with-pic|with-gnu-ld|with-sysroot|enable-shared|enable-static|enable-dependency-tracking)$ ]] && continue
            if [[ "$opt" =~ ^with- ]]; then
                local lib="${opt#with-}"
                [[ "$lib" =~ ^(pic|gnu-ld|sysroot|pthread|threads)$ ]] && continue
                [[ "$lib" =~ (prefix|exec-prefix|dir|path)$ ]] && continue
                local mapped="${PKG_NAME_MAP[$lib]:-$lib}"
                [[ -n "$mapped" ]] && { deps+=" $mapped"; flags+=" --with-${lib}=$NLAB_EXEC"; }
            elif [[ "$opt" =~ ^enable- ]]; then
                local feat="${opt#enable-}"
                [[ "$feat" =~ ^(shared|static|silent-rules|maintainer-mode)$ ]] && continue
                flags+=" --enable-${feat}"
            fi
        done
        grep -q "pkg-config" configure && build_deps+=" pkg-config"
    fi

    # CMake
    if [[ -f "CMakeLists.txt" ]]; then
        local cmake_pkgs=$(grep -E 'find_package[[:space:]]*\([^)]+REQUIRED' CMakeLists.txt | sed -E 's/.*find_package[[:space:]]*\([[:space:]]*([^) ]+).*/\1/')
        for p in ${=cmake_pkgs}; do
            [[ "$p" =~ ^(PkgConfig|Threads|OpenMP|ZLIB|BZip2)$ ]] && continue
            local mapped="${PKG_NAME_MAP[$p]:-$p}"
            deps+=" $mapped"; flags+=" -D${p}_ROOT=$NLAB_EXEC"
        done
        grep -q "find_package(PkgConfig)" CMakeLists.txt && build_deps+=" pkg-config"
    fi

    # Meson
    if [[ -f "meson.build" ]]; then
        local meson_deps=$(grep -E 'dependency[[:space:]]*\([^)]+\)' meson.build | sed -E "s/.*dependency[[:space:]]*\([[:space:]]*['\"]([^'\"]+)['\"].*/\1/")
        for d in ${=meson_deps}; do
            [[ "$d" =~ ^(threads|pthread|m|dl)$ ]] && continue
            local mapped="${PKG_NAME_MAP[$d]:-$d}"
            deps+=" $mapped"; flags+=" -D${d}_prefix=$NLAB_EXEC"
        done
        grep -q "dependency('pkg-config')" meson.build && build_deps+=" pkg-config"
    fi

    # Python
    if [[ -f "setup.py" ]]; then
        local req=$(grep -E 'install_requires[[:space:]]*=' setup.py | sed -E 's/.*install_requires[[:space:]]*=[[:space:]]*\[([^]]*)\].*/\1/' | tr ',' '\n' | sed -E "s/['\" ]//g" | grep -v '^$')
        deps+=" $req"
    elif [[ -f "pyproject.toml" ]]; then
        local req=$(grep -E 'dependencies[[:space:]]*=' pyproject.toml | sed -E 's/.*dependencies[[:space:]]*=[[:space:]]*\[([^]]*)\].*/\1/' | tr ',' '\n' | sed -E "s/['\" ]//g" | grep -v '^$')
        deps+=" $req"
    fi

    # Makefile
    if [[ -f "Makefile" ]]; then
        local libs=$(grep -E '^(LIBS|LDLIBS)[[:space:]]*=' Makefile | sed -E 's/.*=[[:space:]]*//' | tr ' ' '\n' | grep -E '^-l' | sed 's/^-l//')
        for lib in ${=libs}; do
            [[ "$lib" =~ ^(pthread|m|dl|c|rt|util)$ ]] && continue
            local mapped="${PKG_NAME_MAP[$lib]:-$lib}"
            deps+=" $mapped"
        done
        grep -q "pkg-config" Makefile && build_deps+=" pkg-config"
    fi

    deps=$(echo "$deps" | tr ' ' '\n' | sort -u | grep -v '^$' | tr '\n' ' ')
    build_deps=$(echo "$build_deps" | tr ' ' '\n' | sort -u | grep -v '^$' | tr '\n' ' ')
    flags=$(echo "$flags" | tr ' ' '\n' | sort -u | grep -v '^$' | tr '\n' ' ')
    echo "${deps# }|${build_deps# }|${flags# }"
    return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# 4. Source Preparation (queries DB for URL/path, downloads if needed)
# ─────────────────────────────────────────────────────────────────────────────
nlab_prepare_source() {
    local pkg="$1"; shift
    local refresh=0 no_download=0 clean_build=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --refresh) refresh=1; shift ;;
            --no-download) no_download=1; shift ;;
            --clean-build) clean_build=1; shift ;;
            *) echo "❌ Unknown: $1" >&2; return 1 ;;
        esac
    done
    [[ -z "$pkg" ]] && { echo "❌ Usage: nlab_prepare_source <pkg>" >&2; return 1; }

    # 1. Query DB for source info
    local src_url="" src_path=""
    if _nlab_db_available 2>/dev/null; then
        local row=$(sqlite3 -separator $'\t' "$NLAB_DB" \
            "SELECT source_url, source_path FROM packages WHERE name='$pkg'" 2>/dev/null)
        if [[ -n "$row" ]]; then
            IFS=$'\t' read -r src_url src_path <<< "$row"
        fi
    fi

    # 2. Find local source
    local local_src=$(find_local_source "$pkg" 2>/dev/null) || true

    # 3. If local_src is a directory, use it; if it's an archive, extract it
    local final_src=""
    if [[ -n "$local_src" ]]; then
        if [[ -f "$local_src" ]]; then
            # Archive → extract
            final_src=$(extract "$local_src") || return 1
        elif [[ -d "$local_src" ]]; then
            final_src="$local_src"
        fi
    fi

    # 4. If no source found and download not prohibited, download using URL from DB
    if [[ -z "$final_src" && $no_download -eq 0 ]]; then
        if [[ -z "$src_url" ]]; then
            # Prompt if interactive
            if [[ -t 0 ]]; then
                echo "No source URL for $pkg in DB." >&2
                echo -n "Enter download URL (or 'local' for local path): " >&2
                read -r user_url
                if [[ "$user_url" == "local" ]]; then
                    echo -n "Enter local path: " >&2; read -r local_path
                    [[ -d "$local_path" ]] && { final_src="$local_path"; }
                elif [[ -n "$user_url" ]]; then
                    src_url="$user_url"
                    # Save to DB
                    sqlite3 "$NLAB_DB" "UPDATE packages SET source_url='$src_url' WHERE name='$pkg'" 2>/dev/null
                fi
            else
                echo "❌ No source URL in DB for $pkg and non-interactive." >&2; return 1
            fi
        fi
        if [[ -n "$src_url" ]]; then
            local filename=$(basename "$src_url")
            local downloaded=$(download "$src_url" "$filename") || return 1
            if [[ -f "$downloaded" ]]; then
                final_src=$(extract "$downloaded") || return 1
            elif [[ -d "$downloaded" ]]; then
                final_src="$downloaded"
            fi
        fi
    fi

    # 5. If still no source, fail
    [[ -z "$final_src" || ! -d "$final_src" ]] && { echo "❌ Source not found for $pkg" >&2; return 1; }

    # 6. Export source dir and version
    export NLAB_SOURCE_DIR="$final_src"
    local dir_name=$(basename "$final_src")
    if [[ "$dir_name" =~ ^${pkg}-(.+)$ ]]; then
        export NLAB_SOURCE_VERSION="${match[1]}"
    else
        export NLAB_SOURCE_VERSION="unknown"
    fi

    # 7. Update DB with source_path if missing
    if _nlab_db_available 2>/dev/null; then
        sqlite3 "$NLAB_DB" "UPDATE packages SET source_path='$final_src' WHERE name='$pkg'" 2>/dev/null
    fi

    echo "$final_src"
    return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# 5. Scan and Register Package to DB
# ─────────────────────────────────────────────────────────────────────────────
nlab_scan_and_register_package() {
    local source_dir="$1" pkg="$2"
    [[ -z "$source_dir" || -z "$pkg" ]] && return 1
    [[ -d "$source_dir" ]] || return 1

    local build_system=$(detect_build_system "$source_dir")
    local req_compiler="clang"   # default, can be refined later
    local scan_result=$(scan_deps "$source_dir" "$pkg" 2>/dev/null)
    local deps="${scan_result%%|*}"
    local rest="${scan_result#*|}"
    local build_deps="${rest%%|*}"
    local flags="${rest#*|}"
    local version=$(basename "$source_dir" | sed -E "s/^${pkg}[_-]//")
    [[ "$version" =~ ^[0-9] ]] || version="latest"

    # Register package metadata in DB
    if _nlab_db_available 2>/dev/null; then
        nlab_db_register_package "$pkg" \
            --build-system "$build_system" \
            --required-compiler "$req_compiler" \
            --flags "$flags" \
            --source-path "$source_dir" \
            --version "$version" 2>/dev/null || true
        echo "✅ Registered $pkg (build: $build_system, deps: ${deps:-none})" >&2
    else
        echo "❌ DB not available" >&2; return 1
    fi
    return 0
}

nlab_scan_all_sources() {
    local tarballs="${NLAB_SRC}/tarballs"
    local gitdir="${NLAB_SRC}/git"
    local registered=0 skipped=0 failed=0

    for dir in "$tarballs"/*/ "$gitdir"/*/; do
        [[ -d "$dir" ]] || continue
        local pkg=$(basename "$dir")
        [[ "$pkg" =~ ^(tarballs|git|zipped|build|\.)$ ]] && continue
        # Check if already in DB
        if _nlab_db_available 2>/dev/null; then
            local exists=$(sqlite3 "$NLAB_DB" "SELECT name FROM packages WHERE name='$pkg'" 2>/dev/null)
            [[ -n "$exists" ]] && { ((skipped++)); continue; }
        fi
        echo "📦 Scanning: $pkg" >&2
        if nlab_scan_and_register_package "$dir" "$pkg"; then
            ((registered++))
        else
            ((failed++))
        fi
    done
    echo "── Registered: $registered | Skipped: $skipped | Failed: $failed ──"
}

# ─────────────────────────────────────────────────────────────────────────────
# 6. Helper – clean build artifacts
# ─────────────────────────────────────────────────────────────────────────────
_clean_build_artifacts() {
    local source_dir="$1"
    [[ -d "$source_dir" ]] || return 0
    cd "$source_dir" || return 1
    [[ -f "Makefile" || -f "config.status" ]] && { make distclean 2>/dev/null || make clean 2>/dev/null || true; }
    for d in build Build cmake-build-* meson-build; do [[ -d "$d" ]] && rm -rf "$d"; done
    rm -f CMakeCache.txt config.log config.status 2>/dev/null
    rm -rf meson-private meson-logs autom4te.cache 2>/dev/null
    return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# INIT
# ─────────────────────────────────────────────────────────────────────────────
[[ -n "$NLAB_VERBOSE" ]] && {
    echo "✅ Generation (DB-centric) loaded"
    echo "   Commands: nlab_prepare_source, nlab_scan_all_sources"
}