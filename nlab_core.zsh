#!/bin/zsh
# ============================================================================
# NLAB CORE - Safe PATH management & compiler switching
# ============================================================================

# Guard (uncomment to prevent reload)
# if [[ -n "$_NLAB_CORE_LOADED" ]]; then return 0; fi
# _NLAB_CORE_LOADED=1

# ============================================================================
# OS DETECTION — everything below branches on this
# ============================================================================
case "$(uname -s)" in
    Darwin) export NLAB_OS="darwin"; export NLAB_SHLIB_EXT="dylib" ;;
    Linux)  export NLAB_OS="linux";  export NLAB_SHLIB_EXT="so" ;;
    *)      export NLAB_OS="unknown"; export NLAB_SHLIB_EXT="so" ;;
esac

# ── SDK & Developer Tools (macOS only) ──────────────────
if [[ "$NLAB_OS" == "darwin" ]]; then
    export DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p 2>/dev/null)}"
    [[ -z "$DEVELOPER_DIR" ]] && export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"

    export SDKROOT="${SDKROOT:-$(xcrun --show-sdk-path 2>/dev/null)}"
    if [[ -z "$SDKROOT" ]]; then
        SDKROOT=$(ls -d "$DEVELOPER_DIR/Platforms/MacOSX.platform/Developer/SDKs/MacOSX"*.sdk 2>/dev/null | sort -V | tail -1)
        export SDKROOT
    fi
fi

# ============================================================================
# JAVA ENVIRONMENT
# ============================================================================
if [[ "$NLAB_OS" == "darwin" ]]; then
    export JAVA_11_HOME="/Library/Java/JavaVirtualMachines/jdk-11.jdk/Contents/Home"
    export JAVA_17_HOME="/Library/Java/JavaVirtualMachines/jdk-17.jdk/Contents/Home"
    export JAVA_21_HOME="/Library/Java/JavaVirtualMachines/jdk-21.jdk/Contents/Home"
    export JAVA_25_HOME="/Library/Java/JavaVirtualMachines/jdk-25.jdk/Contents/Home"
else
    # Debian/Ubuntu layout: /usr/lib/jvm/java-<N>-openjdk-<arch>/
    _nlab_find_jdk() {
        local ver="$1"
        local -a matches=( /usr/lib/jvm/java-${ver}-openjdk*(N) )
        (( ${#matches[@]} > 0 )) && print -r -- "${matches[-1]}"
    }
    export JAVA_11_HOME="$(_nlab_find_jdk 11)"
    export JAVA_17_HOME="$(_nlab_find_jdk 17)"
    export JAVA_21_HOME="$(_nlab_find_jdk 21)"
    export JAVA_25_HOME="$(_nlab_find_jdk 25)"
    unset -f _nlab_find_jdk
fi
# Pick the highest available as default, falling back gracefully
export JAVA_HOME="${JAVA_25_HOME:-${JAVA_21_HOME:-${JAVA_17_HOME:-${JAVA_11_HOME:-}}}}"

javaswi() {
    local version="$1"
    local new_home=""
    case "$version" in
        11) new_home="$JAVA_11_HOME" ;;
        17) new_home="$JAVA_17_HOME" ;;
        21) new_home="$JAVA_21_HOME" ;;
        25) new_home="$JAVA_25_HOME" ;;
        *) echo "Usage: javaswi {11|17|21|25}"; return 1 ;;
    esac
    [[ ! -d "$new_home" ]] && { echo "❌ Java $version not found at $new_home"; return 1; }
    export JAVA_HOME="$new_home"
    [[ ":$PATH:" != *":$JAVA_HOME/bin:"* ]] && export PATH="$JAVA_HOME/bin:$PATH"
    echo "☕ Switched to Java $(java -version 2>&1 | head -1)"
}
alias java11='javaswi 11' java17='javaswi 17' java21='javaswi 21' java25='javaswi 25'

# ============================================================================
# SAFE PATH MANAGEMENT
# ============================================================================
nlab_set_path() {
    [[ -d "$NLAB_EXEC/bin" ]] && [[ ":$PATH:" != *":$NLAB_EXEC/bin:"* ]] && export PATH="$NLAB_EXEC/bin:$PATH"
    local system_paths=( "/usr/local/bin" "/usr/bin" "/bin" "/usr/sbin" "/sbin" )
    for p in "${system_paths[@]}"; do
        [[ -d "$p" ]] && [[ ":$PATH:" != *":$p:"* ]] && export PATH="$PATH:$p"
    done

    # TeX
    local -a tex_candidates
    if [[ "$NLAB_OS" == "darwin" ]]; then
        tex_candidates=( "/Library/TeX/texbin" "/usr/local/texlive/2024/bin/universal-darwin" "/opt/local/share/texmf-texlive/bin" )
    else
        tex_candidates=( "/usr/bin" /usr/local/texlive/*/bin/x86_64-linux(N) )
    fi
    for tex in "${tex_candidates[@]}"; do
        if [[ -d "$tex" ]] && command -v "$tex/tex" >/dev/null 2>&1; then
            export TEX="$tex"
            [[ ":$PATH:" != *":$tex:"* ]] && export PATH="$PATH:$tex"
            break
        fi
    done

    # Other appends
    local -a paths_to_add=( "$NLAB_EXEC" )
    [[ -n "$JAVA_HOME" ]] && paths_to_add+=( "$JAVA_HOME/bin" )
    if [[ "$NLAB_OS" == "darwin" ]]; then
        paths_to_add+=(
            "$DEVELOPER_DIR/usr/bin" "$HOME/Library/Python/3.9/bin"
            "/opt/X11/bin" "/private/var/select/X11/bin"
            "/Volumes/nlab/Applications/Doxygen.app/Contents/MacOS"
            "/Volumes/nlab/Applications/Emacs.app/Contents/MacOS"
            "/Volumes/nlab/Applications/Gmsh.app/Contents/MacOS"
            "/Volumes/nlab/Applications/gxsview.app/Contents/MacOS"
            "/Applications/SCALE-6.2.1.app/Contents/MacOS"
        )
    else
        paths_to_add+=(
            "$HOME/.local/bin" "/usr/lib/x86_64-linux-gnu"
        )
    fi
    for p in "${paths_to_add[@]}"; do
        [[ -d "$p" ]] && [[ ":$PATH:" != *":$p:"* ]] && export PATH="$PATH:$p"
    done
}

nlab_set_lib_paths() {
    export LIBRARY_PATH="$NLAB_EXEC/lib:/usr/lib:/usr/local/lib"
    if [[ "$NLAB_OS" == "darwin" ]]; then
        export DYLD_LIBRARY_PATH="$NLAB_EXEC/lib"
        export DYLD_FALLBACK_LIBRARY_PATH="$NLAB_EXEC/lib:/usr/lib:/usr/local/lib"
    fi
    export LD_LIBRARY_PATH="$NLAB_EXEC/lib${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
}

# ============================================================================
# COMMON ENVIRONMENT (flags, paths)
# ============================================================================
_set_common_env() {
    nlab_set_path
    nlab_set_lib_paths
    local arch_flag=""
    if [[ "$NLAB_OS" == "darwin" ]]; then
        arch_flag="-mcpu=apple-m2"
    else
        arch_flag="-march=native"
    fi
    export CFLAGS="-O2 $arch_flag -fPIC -I$NLAB_EXEC/include"
    export CXXFLAGS="$CFLAGS"
    export FFLAGS="$CFLAGS"
    export LDFLAGS="-L$NLAB_EXEC/lib -Wl,-rpath,$NLAB_EXEC/lib"
    export PKG_CONFIG_PATH="$NLAB_EXEC/lib/pkgconfig:$NLAB_EXEC/share/pkgconfig"
    export PKG_CONFIG="$NLAB_EXEC/bin/pkgconf"
}

check_sdk() {
    echo "🔧 Checking SDK environment..."
    if [[ "$NLAB_OS" == "darwin" ]]; then
        [[ -d /usr/include || -d /opt/homebrew/include ]] && { echo "✅ SDK found"; return 0; }
    else
        # Debian/Ubuntu: build-essential provides headers under /usr/include
        if [[ -d /usr/include ]] && command -v gcc >/dev/null 2>&1; then
            echo "✅ SDK found (build-essential)"; return 0
        fi
        echo "⚠️  Missing build tools — try: sudo apt install build-essential"
        return 1
    fi
    echo "⚠️ SDK not fully detected"
}

# ============================================================================
# COMPILER DETECTION (with version awareness)
# ============================================================================
nlab_check_tool() {
    local tool="$1"
    case "$tool" in
        clang)
            if [[ -x "/usr/bin/clang" ]] && [[ -x "/usr/bin/clang++" ]]; then
                echo "✅ System Clang: /usr/bin/clang" >&2; return 0
            else
                echo "❌ System Clang not found" >&2; return 1
            fi ;;
        gcc)
            if [[ -x "$NLAB_EXEC/bin/gcc" ]]; then
                echo "✅ NLAB GCC: $NLAB_EXEC/bin/gcc" >&2; return 0
            elif command -v gcc >/dev/null; then
                echo "✅ System GCC: $(command -v gcc)" >&2; return 0
            else
                echo "❌ No GCC found" >&2; return 1
            fi ;;
        mpicc|mpi)
            if command -v mpicc >/dev/null; then
                echo "✅ MPI: $(command -v mpicc)" >&2; return 0
            else
                echo "❌ mpicc not found" >&2; return 1
            fi ;;
        llvm)
            if [[ -x "$NLAB_EXEC/bin/clang" ]]; then
                echo "✅ NLAB LLVM: $NLAB_EXEC/bin/clang" >&2
                [[ -x "$NLAB_EXEC/bin/flang" ]] && echo "   Flang: $NLAB_EXEC/bin/flang" >&2
                return 0
            else
                echo "❌ NLAB LLVM not found" >&2; return 1
            fi ;;
        *) command -v "$tool" >/dev/null && { echo "✅ $tool: $(command -v "$tool")" >&2; return 0; } || { echo "❌ $tool not found" >&2; return 1; } ;;
    esac
}

nlab_detect_compiler() {
    local compiler="$1"
    local preferred_version="${2:-auto}"
    echo "🔍 Detecting compiler: $compiler (version: $preferred_version)" >&2

    case "$compiler" in
        clang)
            nlab_check_tool "clang" || return 1
            export CC="/usr/bin/clang"
            export CXX="/usr/bin/clang++"
            unset FC F77
            export NLAB_COMPILER_FAMILY="clang"
            export NLAB_COMPILER_VERSION=$("$CC" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -1 | cut -d. -f1)
            ;;
        gcc)
            local gcc_bin=""
            if [[ "$preferred_version" != "auto" ]]; then
                local versioned_gcc="$NLAB_EXEC/gcc${preferred_version}/bin/gcc"
                [[ -x "$versioned_gcc" ]] && gcc_bin="$versioned_gcc"
            fi
            [[ -z "$gcc_bin" && -x "$NLAB_EXEC/bin/gcc" ]] && gcc_bin="$NLAB_EXEC/bin/gcc"
            [[ -z "$gcc_bin" ]] && command -v gcc >/dev/null && gcc_bin="$(command -v gcc)"
            [[ -z "$gcc_bin" ]] && { echo "❌ No GCC found" >&2; return 1; }
            export CC="$gcc_bin"
            local gxx_bin="${gcc_bin%/*}/g++"
            [[ -x "$gxx_bin" ]] && export CXX="$gxx_bin" || export CXX="$(command -v g++ 2>/dev/null || echo 'g++')"
            local gfortran_bin="${gcc_bin%/*}/gfortran"
            if [[ -x "$gfortran_bin" ]]; then
                export FC="$gfortran_bin"
                export F77="$FC"
            else
                unset FC F77
            fi
            export NLAB_COMPILER_FAMILY="gcc"
            export NLAB_COMPILER_VERSION=$("$CC" -dumpversion 2>/dev/null | cut -d. -f1)
            ;;
        mpi)
            nlab_detect_compiler "gcc" "$preferred_version" || return 1
            command -v mpicc >/dev/null || { echo "❌ mpicc not found" >&2; return 1; }
            export CC="$(command -v mpicc)"
            export CXX="$(command -v mpicxx 2>/dev/null || echo 'mpicxx')"
            export FC="$(command -v mpif90 2>/dev/null || echo 'mpif90')"
            export OMPI_CC="${OMPI_CC:-$NLAB_EXEC/bin/gcc}"
            export OMPI_CXX="${OMPI_CXX:-$NLAB_EXEC/bin/g++}"
            export OMPI_FC="${OMPI_FC:-$NLAB_EXEC/bin/gfortran}"
            export NLAB_COMPILER_FAMILY="mpi"
            # version already set by gcc detection
            ;;
        llvm)
            nlab_check_tool "llvm" || return 1
            export CC="$NLAB_EXEC/bin/clang"
            export CXX="$NLAB_EXEC/bin/clang++"
            export FC="$NLAB_EXEC/bin/flang"
            export F77="$NLAB_EXEC/bin/flang"
            export OMPI_CC="$CC"; export OMPI_CXX="$CXX"; export OMPI_FC="$FC"
            export NLAB_COMPILER_FAMILY="llvm"
            export NLAB_COMPILER_VERSION=$("$CC" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -1 | cut -d. -f1)
            ;;
        *) echo "❌ Unknown compiler: $compiler" >&2; return 1 ;;
    esac
    echo "   CC:  $CC" >&2
    echo "   CXX: $CXX" >&2
    [[ -n "$FC" ]] && echo "   FC:  $FC" >&2
    return 0
}

# ============================================================================
# MAIN COMPILER SWITCH (with subcommands: list, verify, detect)
# ============================================================================
comp() {
    local family="$1"
    local version="auto"
    local force=0

    # Parse arguments: if second arg is --force, treat as force; else as version
    if [[ "$2" == "--force" ]]; then
        force=1
    elif [[ -n "$2" ]]; then
        version="$2"
        if [[ "$3" == "--force" ]]; then force=1; fi
    fi

    # Subcommands
    case "$family" in
        list)    comp_list; return $? ;;
        verify)  verify_compiler; return $? ;;
        detect)  nlab_detect_system_compilers; return $? ;;
    esac

    # Validate family
    case "$family" in
        gcc|mpi|clang|llvm) ;;
        *) echo "❌ Unknown compiler family: $family"; return 1 ;;
    esac

    # Skip if already set and no force
    if [[ $force -eq 0 ]] && [[ "$NLAB_COMPILER_FAMILY" == "$family" && "$NLAB_COMPILER_VERSION" == "$version" ]]; then
        echo "✅ Environment already set to $family:$version"
        return 0
    fi

    # Detect and set compiler
    if ! nlab_detect_compiler "$family" "$version"; then
        echo "❌ Failed to set compiler: $family (version $version)"
        return 1
    fi

    # Apply common flags and paths
    _set_common_env

    # Show final settings
    echo " CC=$CC"
    echo " CXX=$CXX"
    [[ -n "$FC" ]] && echo " FC=$FC"
    echo " CFLAGS=$CFLAGS"
    echo " LDFLAGS=$LDFLAGS"
    echo " PKG_CONFIG_PATH=$PKG_CONFIG_PATH"
    echo "🚀 NLAB environment shifted to: $family:$NLAB_COMPILER_VERSION"
}

# ============================================================================
# UNIFIED VERIFICATION (C, C++, Fortran all in one)
# ============================================================================
verify_compiler() {
    echo "🔍 Verifying active compiler suite..."
    local errors=0

    # --- C compiler ---
    if [[ -n "$CC" ]]; then
        echo "━━━ C compiler ($CC) ━━━"
        if "$CC" --version 2>/dev/null | head -1; then :; fi
        cat > "$NLAB_SCRATCH/verify_c.c" << 'EOF'
#include <stdio.h>
#include <math.h>
int main() { printf("C works, π=%.15f\n", M_PI); return 0; }
EOF
        if "$CC" -O2 -o "$NLAB_SCRATCH/verify_c" "$NLAB_SCRATCH/verify_c.c" -lm 2>/dev/null; then
            "$NLAB_SCRATCH/verify_c"
            echo "✅ C compiler functional"
        else
            echo "❌ C compiler test failed"
            ((errors++))
        fi
        rm -f "$NLAB_SCRATCH/verify_c"*
    else
        echo "⚠️  CC not set, skipping C test"
    fi

    # --- C++ compiler ---
    if [[ -n "$CXX" ]]; then
        echo "━━━ C++ compiler ($CXX) ━━━"
        if "$CXX" --version 2>/dev/null | head -1; then :; fi
        cat > "$NLAB_SCRATCH/verify_cxx.cpp" << 'EOF'
#include <iostream>
#include <vector>
int main() {
    std::vector<int> v{1,2,3};
    std::cout << "C++ works, size=" << v.size() << std::endl;
    return 0;
}
EOF
        if "$CXX" -std=c++17 -O2 -o "$NLAB_SCRATCH/verify_cxx" "$NLAB_SCRATCH/verify_cxx.cpp" 2>/dev/null || \
           "$CXX" -std=c++14 -O2 -o "$NLAB_SCRATCH/verify_cxx" "$NLAB_SCRATCH/verify_cxx.cpp" 2>/dev/null; then
            "$NLAB_SCRATCH/verify_cxx"
            echo "✅ C++ compiler functional"
        else
            echo "❌ C++ compiler test failed"
            ((errors++))
        fi
        rm -f "$NLAB_SCRATCH/verify_cxx"*
    else
        echo "⚠️  CXX not set, skipping C++ test"
    fi

    # --- Fortran compiler (if set) ---
    if [[ -n "$FC" ]]; then
        echo "━━━ Fortran compiler ($FC) ━━━"
        if "$FC" --version 2>/dev/null | head -1; then :; fi
        cat > "$NLAB_SCRATCH/verify_f.f90" << 'EOF'
program test
  print *, "Fortran works"
end program
EOF
        if "$FC" -O2 -o "$NLAB_SCRATCH/verify_f" "$NLAB_SCRATCH/verify_f.f90" 2>/dev/null; then
            "$NLAB_SCRATCH/verify_f"
            echo "✅ Fortran compiler functional"
        else
            echo "❌ Fortran compiler test failed"
            ((errors++))
        fi
        rm -f "$NLAB_SCRATCH/verify_f"*
    else
        echo "ℹ️  FC not set, skipping Fortran test"
    fi

    if [[ $errors -eq 0 ]]; then
        echo "🎉 All available compilers are functional!"
        return 0
    else
        echo "❌ Some compiler tests failed ($errors error(s))"
        return 1
    fi
}

# ============================================================================
# LISTING & DETECTION FUNCTIONS (unchanged)
# ============================================================================
comp_list() {
    echo "=== NLAB GCC TOOLCHAINS ==="
    local found=0
    [[ -x "$NLAB_EXEC/bin/gcc" ]] && { echo "✅ gcc (default) → $NLAB_EXEC/bin"; "$NLAB_EXEC/bin/gcc" --version | head -n1; found=1; }
    for dir in "$NLAB_EXEC"/gcc*; do
        if [[ -d "$dir" && -x "$dir/bin/gcc" ]]; then
            local ver=$(basename "$dir" | sed 's/gcc//')
            echo "✅ gcc$ver → $dir"
            "$dir/bin/gcc" --version | head -n1
            found=1
        fi
    done
    [[ $found -eq 0 ]] && echo "❌ No GCC toolchains found in $NLAB_EXEC"
    echo "\n=== MPI WRAPPERS ==="
    command -v mpicc >/dev/null && echo "✅ MPI CC: $(command -v mpicc)" || echo "❌ MPI CC missing"
    echo "\n=== LLVM/Flang Toolchain ==="
    [[ -x "$NLAB_EXEC/bin/flang" ]] && { echo "✅ Flang: $NLAB_EXEC/bin/flang"; "$NLAB_EXEC/bin/flang" --version 2>/dev/null | head -1; } || echo "❌ Flang not found"
}

nlab_list_variants() {
    local filter="${1:-}"
    case "$filter" in
        compilers)
            echo "=== Available Compilers ==="
            nlab_check_tool "clang" 2>/dev/null || true
            nlab_check_tool "gcc" 2>/dev/null || true
            nlab_check_tool "llvm" 2>/dev/null || true
            nlab_check_tool "mpi" 2>/dev/null || true
            ;;
        "")
            echo "=== Installed Tools ==="
            echo "\n── Compilers ──"
            nlab_check_tool "clang" 2>/dev/null || true
            nlab_check_tool "gcc" 2>/dev/null || true
            nlab_check_tool "llvm" 2>/dev/null || true
            nlab_check_tool "mpi" 2>/dev/null || true
            echo "\n── Binaries in \$NLAB_EXEC/bin ──"
            [[ -d "$NLAB_EXEC/bin" ]] && ls "$NLAB_EXEC/bin" 2>/dev/null | head -30 | while read bin; do echo "   📦 $bin"; done
            echo "\n── Libraries in \$NLAB_EXEC/lib ──"
            [[ -d "$NLAB_EXEC/lib" ]] && ls "$NLAB_EXEC/lib"/*."$NLAB_SHLIB_EXT" "$NLAB_EXEC/lib"/*.a 2>/dev/null | head -20 | while read lib; do echo "   📚 $(basename "$lib")"; done
            ;;
        *)
            echo "=== $filter ==="
            [[ -d "$NLAB_EXEC/bin" ]] && ls "$NLAB_EXEC/bin/${filter}"* 2>/dev/null | while read f; do echo "   ✅ $(basename "$f")"; done
            [[ -d "$NLAB_EXEC/lib" ]] && ls "$NLAB_EXEC/lib/lib${filter}"* 2>/dev/null | while read f; do echo "   📚 $(basename "$f")"; done
            ;;
    esac
}

nlab_detect_system_compilers() {
    echo "=== System Compiler Detection ==="
    [[ -x "/usr/bin/clang" ]] && echo "✅ System Clang: $(/usr/bin/clang --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -1) (/usr/bin/clang)" || echo "❌ System Clang not found"
    local sys_gcc="$(command -v gcc 2>/dev/null)"
    [[ -n "$sys_gcc" ]] && echo "✅ System GCC: $("$sys_gcc" -dumpversion 2>/dev/null) ($sys_gcc)" || echo "⚠️  System GCC not found"
    [[ -x "$NLAB_EXEC/bin/gcc" ]] && echo "✅ NLAB GCC: $("$NLAB_EXEC/bin/gcc" -dumpversion 2>/dev/null | cut -d. -f1) ($NLAB_EXEC/bin/gcc)" || echo "⚠️  NLAB GCC not built yet"
    [[ -x "$NLAB_EXEC/bin/clang" ]] && echo "✅ NLAB LLVM: $("$NLAB_EXEC/bin/clang" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -1)" || echo "⚠️  NLAB LLVM not built yet"
    command -v mpicc >/dev/null && echo "✅ MPI: $(command -v mpicc)" || echo "⚠️  MPI not found"
    echo "\nCurrent: CC=${CC:-not set}  CXX=${CXX:-not set}  FC=${FC:-not set}"
    echo "Family: ${NLAB_COMPILER_FAMILY:-not set}  Version: ${NLAB_COMPILER_VERSION:-not set}"
}

# ============================================================================
# BUILD OPTIMIZATIONS (unchanged)
# ============================================================================
nlab_total_cores() {
    if [[ "$NLAB_OS" == "darwin" ]]; then
        sysctl -n hw.activecpu
    else
        nproc --all 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4
    fi
}
nlab_total_ram_gb() {
    if [[ "$NLAB_OS" == "darwin" ]]; then
        echo $(( $(sysctl -n hw.memsize) / 1024 / 1024 / 1024 ))
    else
        # /proc/meminfo MemTotal is in kB
        awk '/MemTotal/ {print int($2/1024/1024)}' /proc/meminfo 2>/dev/null || echo 8
    fi
}
get_make_jobs() {
    local total_cores=$(nlab_total_cores)
    local ram_gb=$(nlab_total_ram_gb)
    local ram_based_jobs=$((ram_gb / 2))
    local recommended_jobs=$((ram_based_jobs < total_cores ? ram_based_jobs : total_cores))
    if (( recommended_jobs > 12 )); then echo 12; elif (( recommended_jobs < 2 )); then echo 2; else echo $recommended_jobs; fi
}
maks() { local jobs=$(get_make_jobs); print -P "%F{green}🔧 make -j$jobs (${cores} cores, ${ram}GB RAM)%f"; make -j$jobs "$@"; }
makf() { make -j$(nlab_total_cores) "$@"; }
maksa() { local safe_jobs=$(( $(nlab_total_cores) / 2 )); (( safe_jobs < 1 )) && safe_jobs=1; print -P "%F{yellow}🐢 Safe mode: -j$safe_jobs%f"; make -j$safe_jobs "$@"; }
maksi() { make -j1 "$@"; }
makin() { make install; }
nlab-lto() { export LDFLAGS="$LDFLAGS -flto=auto"; export CFLAGS="$CFLAGS -flto=auto"; echo "✅ LTO enabled"; }

# ============================================================================
# INITIAL SETUP
# ============================================================================
nlab_set_path
nlab_set_lib_paths
[[ -n "$NLAB_VERBOSE" ]] && echo "✅ NLAB Core loaded (PATH-safe mode)"
# ============================================================================
# BACKWARD-COMPATIBLE WRAPPERS (optional, if you still want to call them directly)
# ============================================================================

#setup_gcc_env()   { comp gcc  14 --force; }
#setup_clang_env() { comp clang    --force; }
#setup_llvm_env()  { comp llvm     --force; }
#setup_mpi_env()   { comp mpi  14 --force; }
