# Pig

- Local-first coding-agent project implemented in Zig.
- zig version > 0.16.0

## 碰到问题可以借鉴 pi 的实现

更新 pi 到最新版本。

```shell
pi update
```

pi 是一个 npm 包，它源码就在对应的 npm 包里。

如果本地没有安装 pi，你可以自己 clone 一个临时的查看代码.

pi 源码地址：

https://github.com/badlogic/pi-mono

## test workflow

zig build commands
zig build interactive-mode
zig build config-runtime
zig build provider-live（未启用 live env 时正常 skipped）
zig build fmt-check
zig build provider-fixtures
zig build smoke
zig build test
