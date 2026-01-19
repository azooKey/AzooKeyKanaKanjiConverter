# 개발 가이드

## 필요한 환경

- Swift 6.1 이상
- iOS 16+, macOS 13+, visionOS 1+, Ubuntu 22.04+ (기본 개발용)
- iOS 18+, macOS 15+ (ZenzaiCoreML trait 사용 시)

## 설정

레포지토리를 클론하세요. 서브모듈을 포함하므로 `--recursive` 옵션이 필요합니다.

```bash
git clone https://github.com/ensan-hcl/AzooKeyKanaKanjiConverter --recursive
```

## 빌드

### 기본 빌드

```bash
swift build -Xswiftc -strict-concurrency=complete
```

### Zenzai (llama.cpp + GPU) 활성화 빌드

```bash
swift build --traits Zenzai -Xswiftc -strict-concurrency=complete
```

### ZenzaiCoreML (CoreML + Stateful) 활성화 빌드

iOS 18+, macOS 15+가 필요합니다.

```bash
swift build --traits ZenzaiCoreML -Xswiftc -strict-concurrency=complete
```

### ZenzaiCPU (llama.cpp + CPU only) 활성화 빌드

```bash
swift build --traits ZenzaiCPU -Xswiftc -strict-concurrency=complete
```

## 테스트

### 기본 테스트

```bash
swift test -c release -Xswiftc -strict-concurrency=complete
```

### Zenzai trait으로 테스트

```bash
swift test --traits Zenzai -c release -Xswiftc -strict-concurrency=complete
```

### ZenzaiCoreML trait으로 테스트

```bash
swift test --traits ZenzaiCoreML -c release -Xswiftc -strict-concurrency=complete
```

## CLI 도구

디버깅용 CLI 도구로 `anco` 명령이 있습니다. `install_cli.sh`를 실행하여 설치하세요. 경우에 따라 `sudo`가 필요할 수 있습니다.

```bash
sh install_cli.sh
```

자세한 내용은 [cli.md](./cli.md)를 참조하세요.

## DevContainer

개발에 DevContainer를 사용할 수 있습니다. 자세한 내용은 [devcontainer.md](./devcontainer.md)를 참조하세요.

## Zenzai / CoreML 개발

Zenzai와 CoreML 백엔드 개발에 대해서는 다음 문서를 참조하세요:
- [zenzai.ko.md](./zenzai.ko.md) - Zenzai 사용 방법
- [ZenzAvailability.ko.md](./ZenzAvailability.ko.md) - CoreML 가용성 가이드라인

## 기여하기

기여를 환영합니다! 풀 리퀘스트를 보내기 전에 다음을 확인하세요:
- Swift 6 strict concurrency checking으로 빌드가 통과하는지
- 모든 테스트가 성공하는지
- 코드가 SwiftLint 규칙을 따르는지
