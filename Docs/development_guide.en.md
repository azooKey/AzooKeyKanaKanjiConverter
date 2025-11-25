# Development Guide

**English** | [日本語](./development_guide.md) | [한국어](./development_guide.ko.md)

## Requirements

- Swift 6.1 or later
- iOS 16+, macOS 13+, visionOS 1+, Ubuntu 22.04+ (for basic development)
- iOS 18+, macOS 15+ (when using ZenzaiCoreML trait)

## Setup

Clone the repository. The `--recursive` option is required because it includes submodules.

```bash
git clone https://github.com/ensan-hcl/AzooKeyKanaKanjiConverter --recursive
```

## Build

### Basic Build

```bash
swift build -Xswiftc -strict-concurrency=complete
```

### Build with Zenzai (llama.cpp + GPU)

```bash
swift build --traits Zenzai -Xswiftc -strict-concurrency=complete
```

### Build with ZenzaiCoreML (CoreML + Stateful)

Requires iOS 18+, macOS 15+.

```bash
swift build --traits ZenzaiCoreML -Xswiftc -strict-concurrency=complete
```

### Build with ZenzaiCPU (llama.cpp + CPU only)

```bash
swift build --traits ZenzaiCPU -Xswiftc -strict-concurrency=complete
```

## Test

### Basic Test

```bash
swift test -c release -Xswiftc -strict-concurrency=complete
```

### Test with Zenzai trait

```bash
swift test --traits Zenzai -c release -Xswiftc -strict-concurrency=complete
```

### Test with ZenzaiCoreML trait

```bash
swift test --traits ZenzaiCoreML -c release -Xswiftc -strict-concurrency=complete
```

## CLI Tool

There is a CLI tool called `anco` for debugging. Run `install_cli.sh` to install it. You may need `sudo`.

```bash
sh install_cli.sh
```

For details, see [cli.md](./cli.md).

## DevContainer

You can use DevContainer for development. For details, see [devcontainer.md](./devcontainer.md).

## Swift Concurrency Support

AzooKeyKanaKanjiConverter targets Swift 6 strict concurrency checking, but this branch omits the migration document.

## Zenzai / CoreML Development

For Zenzai and CoreML backend development, refer to the following documents:
- [zenzai.en.md](./zenzai.en.md) - Zenzai Usage
- [ZenzAvailability.en.md](./ZenzAvailability.en.md) - CoreML Availability Guidelines

## Contributing

Contributions are welcome! Before sending a pull request, please ensure:
- Build passes with Swift 6 strict concurrency checking
- All tests pass
- Code follows SwiftLint rules
