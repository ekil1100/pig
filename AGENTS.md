# Pig

- Local-first coding-agent project implemented in Zig.
- 不懂得参考 pi-mono 源码 https://github.com/badlogic/pi-mono，他的架构设计理念值得学习。
- zig version > 0.16.0

## test workflow

zig build commands
zig build interactive-mode
zig build config-runtime
zig build provider-live（未启用 live env 时正常 skipped）
zig build fmt-check
zig build provider-fixtures
zig build smoke
zig build test
