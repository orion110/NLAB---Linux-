# NLAB on Linux (Debian/Ubuntu)

This fork now detects the OS at load time (`$NLAB_OS` = `linux` or `darwin`) and
branches accordingly, so the same scripts work on both platforms. No separate
Linux branch is needed.

## 1. Install system dependencies

```bash
sudo apt update
sudo apt install -y \
  zsh build-essential gcc g++ gfortran \
  cmake ninja-build meson pkg-config \
  sqlite3 libsqlite3-dev python3 python3-pip \
  git curl \
  openmpi-bin libopenmpi-dev \
  default-jdk \
  texlive-full   # optional, only if you need the TeX toolchain
```

`pkgconf` is what NLAB expects at `$NLAB_EXEC/bin/pkgconf` once it's built from
source into the flat prefix; `pkg-config` from apt works fine as a bootstrap
before that exists.

## 2. Set environment variables

Add to `~/.zshrc` (same as macOS, just point `NLAB_ROOT` wherever you like —
there's no `/Volumes` on Linux, so a normal path works):

```bash
export NLAB_ROOT="$HOME/nlab"
export NLAB_EXEC="$NLAB_ROOT/exec"
export NLAB_SRC="$NLAB_ROOT/source"
export NLAB_DATA="$NLAB_ROOT/data"
export NLAB_SCRATCH="$NLAB_ROOT/scratch"
export NLAB_ENV="$NLAB_ROOT/env"
export NLAB_META="$NLAB_ENV/meta"
export NLAB_DB="$NLAB_ENV/nlab.db"

mkdir -p "$NLAB_EXEC" "$NLAB_SRC" "$NLAB_DATA" "$NLAB_SCRATCH" "$NLAB_ENV"
```

## 3. Source the modules (order matters, unchanged from macOS)

```bash
source $NLAB_ENV/nlab_core.zsh
source $NLAB_ENV/nlab_env.zsh
source $NLAB_ENV/nlab_meta.zsh
source $NLAB_ENV/nlab_db.zsh
source $NLAB_ENV/nlab_brain.zsh
source $NLAB_ENV/phases.zsh
source $NLAB_ENV/nlab.zsh
```

(There's no `inventory.zsh` in this repo currently, despite the main README
mentioning it — the CLI dispatcher `nlab.zsh` still works without it.)

## 4. Initialize and use exactly as on macOS

```bash
nlab db-init
nlab scan
comp gcc          # or: comp clang / comp mpi / comp llvm
comp verify
nlab build hdf5
```

## What changed for Linux support

| Area | macOS behavior | Linux behavior |
|---|---|---|
| OS/lib detection | n/a | New `$NLAB_OS` / `$NLAB_SHLIB_EXT` set at top of `nlab_core.zsh` |
| SDK/Xcode | `xcode-select`, `xcrun`, `SDKROOT` | Skipped; uses `build-essential` + `/usr/include` |
| Java | `/Library/Java/JavaVirtualMachines/jdk-N.jdk` | `/usr/lib/jvm/java-N-openjdk*` (auto-detected, version-agnostic) |
| PATH extras | `/Applications/*.app/Contents/MacOS`, `/opt/X11`, Xcode dev tools | Dropped (not applicable); adds `~/.local/bin` |
| TeX | `/Library/TeX/texbin` | `/usr/bin` (apt texlive) or `/usr/local/texlive/*/bin/x86_64-linux` |
| Shared libs | `DYLD_LIBRARY_PATH`, `.dylib` | `LD_LIBRARY_PATH` only, `.so` |
| CFLAGS | `-mcpu=apple-m2` | `-march=native` |
| CPU/RAM detection | `sysctl -n hw.activecpu` / `hw.memsize` | `nproc` / `/proc/meminfo` |
| `sed -i` | BSD form: `sed -i ''` | GNU form: `sed -i` (now auto-detected in `fix_pkgconfig`) |
| cmake TPL libs (metis/parmetis/scotch/openblas) | hardcoded `.dylib` paths | now use `$NLAB_SHLIB_EXT` |

## Known pre-existing bug fixed along the way

`nlab_build_binary()` in `nlab_brain.zsh` had an invalid shell construct —
a redirect (`2>/dev/null`) placed inside a `for...in` glob list, which is a
syntax error in any POSIX-ish shell, plus it only globbed `.dylib`. This has
been fixed to glob `.dylib`, `.so`, `.so.*`, and `.a` as separate patterns.
