# NLAB – Linux  
[![image-(1).jpg](https://i.postimg.cc/Yq5fNp3J/image-(1).jpg)](https://postimg.cc/JGQkMCSq)


**NLAB** is a modular, SQLite‑backed build and environment management system for scientific and high‑performance computing (HPC) software stacks. It was designed for **macOS (Apple M2 / x86)**
> NLAB is primarily designed for macOS (Apple M2 / x86). 
---

## Features

- SQLite‑centric – All package metadata (versions, build systems, dependencies, compiler requirements, source locations) lives in a single SQLite database.
- Modular Architecture – Separate modules for compiler switching (`core`), package registry (`db`), build backends (`brain`), source scanning (`meta/generation`), phases, and environment stacks.
- Compiler‑Aware – Seamlessly switch between GCC, Clang, LLVM, and MPI toolchains with a single `comp` command.
- Flat Installation – All packages install into a single `$NLAB_EXEC` prefix (bin/, lib/, include/), eliminating library path conflicts.
- Dependency Resolution – Automatic topological sorting of packages based on runtime and build dependencies stored in the DB.
- Phase Management – Organize hundreds of packages into logical build phases (e.g., bootstrap, numerics, nuclear) with a simple CLI.
- Inventory & Inspection – Query which package owns a file, check ABI consistency, list all variants, and more.



## Architecture Overview

```
NLAB_ROOT/
├── exec/            # Installed binaries, libs, includes (flat)
├── source/          # Source archives (zipped/, tarballs/, git/)
├── data/            # User data (optional)
├── scratch/         # Temporary build space
└── env/             # Environment scripts and metadata
    ├── nlab.db      # SQLite registry
    ├── nlab_core.zsh      # Paths, compiler, common functions
    ├── nlab_env.zsh       # Environment stacks (nlab env-*)
    ├── nlab_meta.zsh      # Source scanning & DB registration
    ├── nlab_db.zsh        # SQLite bridge (Zsh)
    ├── nlab_brain.zsh     # Build backends (autotools, cmake, etc.)
    ├── phases.zsh         # Phase definitions and runners
    ├── inventory.zsh      # Package inspection
    └── nlab.zsh           # Unified CLI
```

All modules are sourced in the correct order by your `~/.zshrc` (or a custom loader). The SQLite database is the **single source of truth**; flat metadata files (`.installed`, `.compiler`, etc.) are deprecated.

---

## Requirements

- **Zsh**   ( For Linux and macOS )
- **Python 3** (for the SQLite registry CLI: `nlab_db.py`)
- **SQLite3** (built‑in on macOS)
- **Build tools**: Xcode Command Line Tools (for macOS) or equivalent on Linux.


## Installation (Linux)


```bash
git clone https://github.com/orion110/NLAB-Linux

sudo apt update
sudo apt install -y \

  zsh build-essential gcc g++ gfortran \
  cmake ninja-build meson pkg-config \
  sqlite3 libsqlite3-dev python3 python3-pip \
  git curl \
  openmpi-bin libopenmpi-dev \
  default-jdk \
  texlive-full


export NLAB_ROOT="$HOME/nlab"
mkdir -p "$NLAB_ROOT/env"
echo "NLAB_ROOT is set to: $NLAB_ROOT"
python3 /home/user/Downloads/NLAB-Linux-main/nlab_db.py init

export NLAB_ENV="/home/user/Downloads/NLAB-Linux"
exec zsh
nlab db-init

chmod +x nlab_db.py
python3 nlab_db.py --help

nlab status
nlab help

```

[![Untitled.png](https://i.postimg.cc/900TjfPj/Untitled.png)](https://postimg.cc/ctq6R05D)



## Installation (MacOS)

### 1. Clone the repository

```bash
git clone https://github.com/salemph/NLAB (macOs)

/Volumes/nlab   # or wherever you want NLAB_ROOT

cd /Volumes/nlab
```


### 2. Set environment variables (Linux/MacOs)

Add to your `~/.zshrc`:

```bash
export NLAB_ROOT="/Volumes/nlab"
export NLAB_EXEC="$NLAB_ROOT/exec"
export NLAB_SRC="$NLAB_ROOT/source"
export NLAB_DATA="$NLAB_ROOT/data"
export NLAB_SCRATCH="$NLAB_ROOT/scratch"
export NLAB_ENV="$NLAB_ROOT/env"
export NLAB_META="$NLAB_ENV/meta"
export NLAB_DB="$NLAB_ENV/nlab.db"
```

### 3. Source the modules

In your `~/.zshrc` (or a dedicated loader script), source the modules in order:

```bash
source $NLAB_ENV/nlab_core.zsh
source $NLAB_ENV/nlab_env.zsh
source $NLAB_ENV/nlab_meta.zsh
source $NLAB_ENV/nlab_db.zsh
source $NLAB_ENV/nlab_brain.zsh
source $NLAB_ENV/phases.zsh
source $NLAB_ENV/inventory.zsh
source $NLAB_ENV/nlab.zsh
```

### 4. Initialise the database

```bash
nlab db-init          # Create SQLite schema
nlab db-import        # (Optional) Import existing flat meta files
```

### 5. Scan source trees and register packages

```bash
nlab scan             # Scans $NLAB_SRC/tarballs and $NLAB_SRC/git
```

This populates the `packages` and `pkg_deps` tables with metadata.

---

## Usage Examples

### Compiler Switching

```bash
comp gcc 14          # Use GCC 14 from $NLAB_EXEC
comp clang           # Use system Clang
comp mpi             # Use OpenMPI wrappers (with underlying GCC)
comp list            # Show available toolchains
```

### Building a Package

```bash
nlab build hdf5      # Builds hdf5 and its dependencies (using DB resolution)
nlab install hdf5%gcc@14^zlib^openmpi  # Install a specific variant
```

### Running a Phase

```bash
nlab phase 7         # Builds the numerics‑core phase (OpenBLAS, FFTW, GSL, Eigen)
nlab phases-core     # Build phases 0–6 (bootstrap to Qt5)
nlab phases-hpc      # Build phases 7–12 (HPC numerics)
nlab phases-all      # Build all defined phases
```

### Inspecting the Database

```bash
nlab db-stats        # Overall registry statistics
nlab db-info petsc   # Full package info
nlab db-deps hdf5    # Show dependencies and reverse dependencies
nlab db-search openblas
nlab db-variants hdf5   # All installed variants
```

### Environment Stacks

```bash
nlab env-create myenv
nlab env-add myenv openmpi
nlab env-activate myenv   # Switches compiler and sets PATHs
nlab env-deactivate
```

### Status and Help

```bash
nlab status          # Show current state (compiler, installed packages, etc.)
nlab help            # Full CLI reference



## Contributing

We welcome contributions! Please open an issue or pull request for:

- New build backends or package recipes.
- Improved SQLite schema or performance.
- Linux portability fixes.
- Documentation enhancements.



## Acknowledgments

NLAB was built to simplify the management of large, multi‑compiler scientific software stacks. It draws inspiration from Spack, Homebrew, and Conda but takes a minimalist, SQLite‑first approach tailored for macOS HPC environments.
for any refernces or updates please contact me @ salemphi@icloud.com




