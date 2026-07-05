#!/bin/zsh
# ============================================================================
# NLAB ENV - Environment Stacks (activate/deactivate)
# Uses existing NLAB_ENV from nlab_env.zshrc
# ============================================================================
# This file is now DB-aware: activation uses comp (DB-backed) and the
# standard path functions from nlab_core.zsh. The YAML environment files
# are kept for convenience but are not authoritative for installed packages.
# ============================================================================

# Define environments directory inside NLAB_ENV
export NLAB_ENVS_DIR="${NLAB_ENV}/environments"
mkdir -p "$NLAB_ENVS_DIR"

# -----------------------------------------------------------------------------
# Environment Helpers
# -----------------------------------------------------------------------------
nlab_set_mode() {
    export NLAB_BUILD_MODE="$1"
    echo "🔧 Build mode: $NLAB_BUILD_MODE"
}

nlab_clear() {
    unset LDFLAGS CPPFLAGS PKG_CONFIG_PATH
    echo "✅ Build flags cleared"
}

nucenv_info() {
    echo "=== Nuclear Lab Environment ==="
    local mounted_status="No"
    [[ "${NLAB_MOUNTED:-0}" -eq 1 ]] && mounted_status="Yes"
    echo "Root: $NLAB_ROOT | Mount: $mounted_status"
    echo "Active JDK: ${JAVA_HOME:-not set}"
    echo "MPI: $(command -v mpicc 2>/dev/null || echo 'not found')"
}

# -----------------------------------------------------------------------------
# Infrastructure Fixers
# -----------------------------------------------------------------------------
fix_pkgconfig() {
    echo "🔧 Fixing pkg-config files..."
    # BSD sed (macOS) requires `-i ''`; GNU sed (Linux) errors on that and
    # wants `-i` with no argument. Detect once and use the right form.
    local -a sed_i
    if [[ "$NLAB_OS" == "darwin" ]]; then
        sed_i=(sed -i '')
    else
        sed_i=(sed -i)
    fi
    for pc in "$NLAB_EXEC/lib/pkgconfig/"*.pc; do
        [ -f "$pc" ] || continue
        "${sed_i[@]}" "s|/usr/local|$NLAB_EXEC|g" "$pc" 2>/dev/null
        "${sed_i[@]}" "s|/opt/homebrew|$NLAB_EXEC|g" "$pc" 2>/dev/null
    done
    echo "✅ pkg-config files fixed"
}

nlab_log_event() {
    local event="$1"
    local pkg="$2"
    local version="$3"
    local extra="$4"

    # Try to write to DB first
    if _nlab_db_available 2>/dev/null; then
        # We need an install_id – try to get the latest install
        local install_id=$(sqlite3 "$NLAB_DB" \
            "SELECT i.id FROM installs i JOIN packages p ON i.pkg_id=p.id
             WHERE p.name='$pkg' AND i.status='installed'
               AND i.compiler_family='${NLAB_COMPILER_FAMILY:-gcc}'
               AND i.compiler_version='${NLAB_COMPILER_VERSION:-14}'
             ORDER BY i.install_date DESC LIMIT 1" 2>/dev/null)
        if [[ -n "$install_id" ]]; then
            _db_quiet log-build "$pkg" "${NLAB_COMPILER_FAMILY:-gcc}" "${NLAB_COMPILER_VERSION:-14}" \
                "$event" "" 2>/dev/null || true
        fi
    else
        # Fallback to flat file
        mkdir -p "$NLAB_META/events"
        local file="$NLAB_META/events/${pkg}.jsonl"
        cat >> "$file" <<EOF
{
  "event": "$event",
  "package": "$pkg",
  "version": "$version",
  "abi": "$(nlab_compute_abi_hash 2>/dev/null || echo 'unknown')",
  "extra": $extra,
  "timestamp": "$(date -Iseconds)"
}
EOF
    fi
}

nlab_fix_libtool() {
    echo "🔧 Fixing libtool and library links..."
    [[ -f "$NLAB_EXEC/bin/glibtool" && ! -f "$NLAB_EXEC/bin/libtool" ]] && ln -sf glibtool "$NLAB_EXEC/bin/libtool"
}

# -----------------------------------------------------------------------------
# Process & Resource Management
# -----------------------------------------------------------------------------
nucps() {
    ps aux | grep -Ei "(mcnp|openmc|scale|geant4|petsc|trilinos)" | grep -v grep
}

nuckill() {
    [[ -z "$1" ]] && { echo "Usage: nuckill <pattern>"; return 1; }
    pkill -f "$1" && echo "Killed processes matching: $1"
}

# -----------------------------------------------------------------------------
# Legacy: Module File Generation (deprecated for flat installs)
# -----------------------------------------------------------------------------
nlab_generate_module() {
    local pkg="$1"
    local version="$2"
    local compiler_subdir="$(nlab_compiler_subdir 2>/dev/null || echo "${NLAB_COMPILER_FAMILY:-gcc}-${NLAB_COMPILER_VERSION:-14}")"
    local install_prefix="$NLAB_EXEC/opt/${pkg}-${version}-${compiler_subdir}"

    echo "⚠️  Module generation is deprecated for flat installs. This function will be removed in the future."
    echo "   Install prefix: $install_prefix"

    local module_dir="$NLAB_ROOT/modulefiles/$pkg"
    mkdir -p "$module_dir"

    cat > "$module_dir/$version.lua" << EOF
-- NLAB Module for $pkg@$version ($compiler_subdir)
local pkg_root = "$install_prefix"
whatis("Name: $pkg")
whatis("Version: $version")
whatis("Compiler: $compiler_subdir")
whatis("Description: Built with NLAB (legacy opt/ layout)")
prepend_path("PATH", pathJoin(pkg_root, "bin"))
prepend_path("LD_LIBRARY_PATH", pathJoin(pkg_root, "lib"))
prepend_path("CPATH", pathJoin(pkg_root, "include"))
prepend_path("PKG_CONFIG_PATH", pathJoin(pkg_root, "lib/pkgconfig"))
setenv("${pkg:u}_ROOT", pkg_root)
setenv("${pkg:u}_VERSION", "$version")
setenv("${pkg:u}_COMPILER", "$compiler_subdir")
EOF
    echo "📦 Module generated: $module_dir/$version.lua"
}

# -----------------------------------------------------------------------------
# Legacy: nlab_aware – compiler‑aware build (deprecated in favour of flat)
# -----------------------------------------------------------------------------
nlab_aware() {
    local pkg="$1"
    local version="${2:-latest}"
    local compiler_dir="${NLAB_COMPILER_FAMILY:-gcc}-${NLAB_COMPILER_VERSION:-14}"
    local install_dir="$NLAB_EXEC/opt/${pkg}-${version}-${compiler_dir}"

    echo "⚠️  nlab_aware is DEPRECATED. Use flat installation (nlab build)."
    echo "🔨 Building $pkg with ${NLAB_COMPILER_FAMILY}@${NLAB_COMPILER_VERSION}"
    echo "   → Installing to: $install_dir"

    mkdir -p "$install_dir"/{bin,lib,include,share}
    export PKG_CONFIG_PATH="$install_dir/lib/pkgconfig:$PKG_CONFIG_PATH"
    export CPATH="$install_dir/include:$CPATH"

    if [[ -f "configure" ]]; then
        ./configure --prefix="$install_dir" \
                    --libdir="$install_dir/lib" \
                    --includedir="$install_dir/include"
    fi
    make -j${NPROC:-4} && make install

    if [[ -f "$install_dir/bin/$pkg" ]]; then
        ln -sf "$install_dir/bin/$pkg" "$NLAB_EXEC/bin/$pkg-${compiler_dir}"
        echo "   → Also available as: $pkg-${compiler_dir}"
    fi
    echo "$pkg:$version:$compiler_dir" >> "$NLAB_META/compiler_aware_installs.txt"
    echo "✅ Built $pkg with ${compiler_dir}"
}

comp_build() {
    export NLAB_COMPILER_AWARE=1
    nlab_aware "$@"
}

# -----------------------------------------------------------------------------
# Environment Management (YAML‑based, independent of DB)
# -----------------------------------------------------------------------------
nlab_env_create() {
    local env_name="$1"
    [[ -z "$env_name" ]] && { echo "❌ Usage: nlab env-create <name>"; return 1; }
    local env_file="$NLAB_ENVS_DIR/$env_name.yaml"
    [[ -f "$env_file" ]] && { echo "❌ Environment '$env_name' already exists"; return 1; }

    cat > "$env_file" << EOF
name: $env_name
created: $(date -Iseconds)
compiler: ${NLAB_COMPILER_FAMILY:-gcc}@${NLAB_COMPILER_VERSION:-14}
packages: []
EOF
    echo "✅ Created environment: $env_name"
}

nlab_env_add() {
    local env_name="$1" pkg="$2"
    [[ -z "$env_name" || -z "$pkg" ]] && { echo "❌ Usage: nlab env-add <env-name> <package>"; return 1; }
    local env_file="$NLAB_ENVS_DIR/$env_name.yaml"
    [[ ! -f "$env_file" ]] && { echo "❌ Environment '$env_name' not found"; return 1; }
    if grep -q "^  - $pkg$" "$env_file"; then
        echo "ℹ️  $pkg already in environment $env_name"
        return 0
    fi
    local temp_file="${env_file}.tmp"
    cp "$env_file" "$temp_file"
    if grep -q "^packages:" "$temp_file"; then
        sed -i '' "/^packages:/a\\
  - $pkg" "$temp_file"
    else
        echo "" >> "$temp_file"
        echo "packages:" >> "$temp_file"
        echo "  - $pkg" >> "$temp_file"
    fi
    mv "$temp_file" "$env_file"
    echo "✅ Added $pkg to $env_name"
}

nlab_env_remove() {
    local env_name="$1" pkg="$2"
    [[ -z "$env_name" || -z "$pkg" ]] && { echo "❌ Usage: nlab env-remove <env-name> <package>"; return 1; }
    local env_file="$NLAB_ENVS_DIR/$env_name.yaml"
    [[ ! -f "$env_file" ]] && { echo "❌ Environment '$env_name' not found"; return 1; }
    sed -i '' "/^  - $pkg$/d" "$env_file"
    echo "✅ Removed $pkg from $env_name"
}

nlab_env_show() {
    local env_name="$1"
    [[ -z "$env_name" ]] && { echo "❌ Usage: nlab env-show <name>"; return 1; }
    local env_file="$NLAB_ENVS_DIR/$env_name.yaml"
    [[ ! -f "$env_file" ]] && { echo "❌ Environment '$env_name' not found"; return 1; }
    echo "📦 Environment: $env_name"
    cat "$env_file"
}

nlab_env_activate() {
    local env_name="$1"
    [[ -z "$env_name" ]] && { echo "❌ Usage: nlab env-activate <name>"; return 1; }
    local env_file="$NLAB_ENVS_DIR/$env_name.yaml"
    [[ ! -f "$env_file" ]] && { echo "❌ Environment '$env_name' not found"; return 1; }

    # Extract compiler from YAML
    local compiler_line=$(grep "^compiler:" "$env_file" | cut -d: -f2- | sed 's/^[[:space:]]*//')
    local compiler_family="${compiler_line%@*}"
    local compiler_version="${compiler_line#*@}"

    # Switch compiler using the DB‑aware comp function
    if ! comp "$compiler_family" "$compiler_version"; then
        echo "❌ Failed to switch compiler for environment '$env_name'"
        return 1
    fi

    # Re‑set paths (ensures $NLAB_EXEC/bin and lib are in PATH/LD_LIBRARY_PATH)
    nlab_set_path
    nlab_set_lib_paths

    # (Optional) Show which packages are in the environment – informational only
    local packages=$(grep "^  - " "$env_file" | sed 's/^  - //')
    if [[ -n "$packages" ]]; then
        echo "📦 Environment packages:"
        echo "$packages" | while read pkg; do
            echo "   - $pkg"
            # We could also check DB status here
        done
    fi

    export NLAB_ACTIVE_ENV="$env_name"
    echo "🌍 Activated environment: $env_name"
}

nlab_env_deactivate() {
    unset NLAB_ACTIVE_ENV
    echo "🔓 Deactivated current environment"
}

nlab_env_list() {
    echo "=== Available Environments ==="
    local count=0
    for env in "$NLAB_ENVS_DIR"/*.yaml; do
        [[ -f "$env" ]] || continue
        echo "  - $(basename "$env" .yaml)"
        ((count++))
    done
    if [[ $count -eq 0 ]]; then
        echo "  (none)"
    fi
}

nlab_env_destroy() {
    local env_name="$1"
    [[ -z "$env_name" ]] && { echo "❌ Usage: nlab env-destroy <name>"; return 1; }
    local env_file="$NLAB_ENVS_DIR/$env_name.yaml"
    [[ ! -f "$env_file" ]] && { echo "❌ Environment '$env_name' not found"; return 1; }

    echo "⚠️  This will permanently delete environment '$env_name'"
    read -q "choice?Proceed? [y/N]: "; echo
    if [[ "$choice" == "y" ]]; then
        rm -f "$env_file"
        echo "🗑️  Deleted environment: $env_name"
        [[ "$NLAB_ACTIVE_ENV" == "$env_name" ]] && nlab_env_deactivate
    else
        echo "🚫 Aborted."
    fi
}

# -----------------------------------------------------------------------------
# Legacy link helpers – removed
# -----------------------------------------------------------------------------
# nlab_link_to_global and _nlab_link_to_global are OBSOLETE with flat installs.
# They have been removed to avoid confusion.