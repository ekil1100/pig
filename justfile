set shell := ["sh", "-eu", "-c"]

install_dir := env_var_or_default("PIG_INSTALL_DIR", env_var("HOME") + "/.local/bin")

default:
    @just --list

build:
    zig build

test:
    zig build test

fmt-check:
    zig build fmt-check

smoke:
    zig build smoke

install mode="release":
    case "{{mode}}" in \
      release) optimize="ReleaseSafe" ;; \
      debug) optimize="Debug" ;; \
      *) echo "usage: just install [release|debug]" >&2; exit 2 ;; \
    esac; \
    zig build -Doptimize="$optimize"
    mkdir -p "{{install_dir}}"
    tmp="{{install_dir}}/.pig.tmp.$$"; \
    trap 'rm -f "$tmp"' EXIT HUP INT TERM; \
    cp zig-out/bin/pig "$tmp"; \
    chmod 755 "$tmp"; \
    if command -v codesign >/dev/null 2>&1 && [ "$(uname -s)" = "Darwin" ]; then \
      codesign -f -s - "$tmp"; \
    fi; \
    mv -f "$tmp" "{{install_dir}}/pig"; \
    trap - EXIT HUP INT TERM
    "{{install_dir}}/pig" --version
