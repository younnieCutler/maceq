# MacEQ — Gate A 상세 + A~E 로드맵

## Context

`/Users/macbook/dev/tools/local-eq`는 빈 디렉토리다. PRD(§1–46)는 macOS 시스템 전체 오디오에 20-band EQ를 거는 앱을 정의한다. UI부터 만들면 Core Audio routing 제약 때문에 구조를 갈아엎게 되므로, **시스템 오디오 → Core Audio Tap → EQ → 물리 출력** end-to-end가 실제 음악으로 들리는 것을 먼저 증명한다(Gate A). 그 전까지 SwiftUI 코드는 한 줄도 쓰지 않는다.

이 문서는 Gate A를 실행 가능한 수준으로, Gate B~E는 목표·산출물·리스크만 요약한다. Gate A 통과 후 실측 결과를 반영해 Gate B 플랜을 다시 쓴다.

**환경(확인됨)**: macOS 26.6 / Xcode 26.4 / Swift 6.3 / Apple Silicon. 서명 identity `Apple Development: ehrktm090@gmail.com (7TFR357KWQ)` 존재.

---

## 확정된 기술 사실 (SDK 헤더 직접 확인)

MacOSX.sdk `CoreAudio.framework/Headers` 기준. 추측 아님.

| 사실 | 근거 |
|---|---|
| `AudioHardwareCreateProcessTap(CATapDescription*, AudioObjectID*)` — macOS 14.2+ | `AudioHardwareTapping.h:43` |
| `CATapDescription(excludingProcesses:andDeviceUID:withStream:)` — **특정 출력 장치의 특정 스트림만** 탭하고 지정 프로세스 제외. tap format = 그 스트림 format | `CATapDescription.h` |
| `muteBehavior = .mutedWhenTapped` — 탭이 읽히는 동안 원래 경로 음소거 | `CATapDescription.h:30` |
| `privateTap = true` — 생성 프로세스에만 보임 | `CATapDescription.h` |
| aggregate device dict 키: `"taps"`, `"subdevices"`, `"master"`, `"private"`, `"tapautostart"`, sub-tap `"uid"`/`"drift"` | `AudioHardware.h:1566–1900` |
| `AudioHardwareCreateAggregateDevice` / `DestroyAggregateDevice` | `AudioHardware.h:657,671` |
| `kAudioHardwarePropertyTranslatePIDToProcessObject` = `'id2p'` — getpid() → AudioObjectID | `AudioHardware.h:634` |
| `kAudioTapPropertyFormat` = `'tfmt'`, `kAudioTapPropertyUID` = `'tuid'` | `AudioHardware.h:2025` |

### 아키텍처 (사용자 승인)

```
private aggregate device
├─ subdevices: [현재 물리 출력 장치]   ← output 스트림, clock master
└─ taps:       [MacEQ tap]              ← input 스트림
        │
        └─ AudioDeviceIOProc 1개
           input(tap) → preamp → 20×biquad → limiter → output(물리 장치)
```

단일 IOProc = 단일 클럭 = 링버퍼 없음 = 드리프트 없음 = 최저 latency. AVAudioEngine 미사용.

**피드백 루프가 안 생기는 이유**: 탭 description에서 MacEQ 자기 process object ID를 제외 → MacEQ 출력은 탭에 안 잡히고 음소거도 안 됨. 다른 앱들 소리만 잡히고 원래 경로에서 음소거됨. **이 가정이 Gate A의 유일한 핵심 미검증 항목이다.**

---

## 저장소 레이아웃

```
local-eq/
├── Package.swift                    # executable target "maceq", macOS(.v14)
├── Makefile                         # build / bundle / run / clean
├── .gitignore                       # .build/, *.app, .DS_Store
├── Sources/MacEQ/
│   ├── main.swift                   # 엔트리 + Gate A 조작 루프
│   ├── CoreAudioProperty.swift      # AudioObject get/set 제네릭 헬퍼
│   ├── OutputDevice.swift           # 기본 출력 장치 ID/UID/format 조회
│   ├── ProcessTap.swift             # tap 생성/format/UID/파괴
│   ├── TapAggregateDevice.swift     # aggregate 조립/파괴 + stale 정리
│   ├── EQEngine.swift               # IOProc 설치/시작/정지, 파라미터 전달
│   └── Biquad.swift                 # peaking EQ biquad (RT-safe)
├── Resources/
│   ├── Info.plist
│   └── MacEQ.entitlements
└── scripts/bundle.sh                # .app 조립 + codesign
```

---

## Gate A 구현 순서

각 스텝은 **다음 스텝으로 넘어가기 전에 verify가 통과해야 한다.**

### Step 0 — 스캐폴딩

`git init` + `.gitignore`. `Package.swift`(executable `maceq`, platform `.macOS(.v14)`, dependency 0개).

`Resources/Info.plist` — 반드시 포함:
- `CFBundleIdentifier` = `com.maceq.app` (**절대 바꾸지 말 것** — TCC 승인이 bundle ID + 서명 identity에 묶임)
- `CFBundleExecutable` = `maceq`, `CFBundleName` = `MacEQ`, `CFBundlePackageType` = `APPL`
- `LSMinimumSystemVersion` = `14.2`
- `NSAudioCaptureUsageDescription` = "MacEQ는 이퀄라이저를 적용하기 위해 시스템 오디오에 접근합니다. 오디오를 저장하거나 전송하지 않습니다."
- Gate A에서는 `LSUIElement` 미설정(로그 보기 편하게). Gate C에서 `true`로.

`scripts/bundle.sh` — `.build/release/maceq` → `MacEQ.app/Contents/{MacOS,Info.plist}` 조립 후
`codesign --force --sign "Apple Development: ehrktm090@gmail.com (7TFR357KWQ)" --entitlements Resources/MacEQ.entitlements MacEQ.app`.

Gate A entitlements는 **비어있는 dict**로 시작. App Sandbox 켜지 않는다(sandbox + tap은 별개 리스크, Gate D에서 결정). 비-sandbox 앱은 tap에 별도 entitlement 불필요 — usage string + TCC 승인만 필요.

> **verify**: `make bundle && open MacEQ.app` → Console에 "hello" 출력, `codesign -dv MacEQ.app` 에러 없음.

### Step 1 — Core Audio 헬퍼 + 출력 장치 조회

`CoreAudioProperty.swift`: `AudioObjectGetPropertyData` 래핑 제네릭 2개(스칼라, 배열) + `CFString` 반환용. `OutputDevice.swift`: `kAudioHardwarePropertyDefaultOutputDevice` → deviceID → `kAudioDevicePropertyDeviceUID`, `kAudioDevicePropertyStreamFormat`(output scope), `kAudioDevicePropertyNominalSampleRate`.

> **verify**: 실행 시 현재 출력 장치 이름/UID/샘플레이트/채널수 출력. AirPods 연결/해제 후 재실행하면 값이 바뀐다.

### Step 2 — Tap 생성 (권한 프롬프트 지점)

`ProcessTap.swift`:
```swift
// self process object ID
var pid = getpid()
// kAudioHardwarePropertyTranslatePIDToProcessObject 로 AudioObjectID 획득

let desc = CATapDescription(excludingProcesses: [selfObjectID],
                            andDeviceUID: outputUID, withStream: 0)
desc.name = "MacEQ Tap"
desc.uuid = UUID()
desc.isPrivate = true
desc.muteBehavior = .mutedWhenTapped

var tapID = AudioObjectID(kAudioObjectUnknown)
AudioHardwareCreateProcessTap(desc, &tapID)   // ← 여기서 TCC 프롬프트
```
그 다음 `kAudioTapPropertyFormat`으로 실제 `AudioStreamBasicDescription`을 읽고 **가정하지 말고 로그로 확인**(float32 여부, interleaved 여부, 채널 수, 샘플레이트).

> **미확인 지점**: `NS_REFINED_FOR_SWIFT` 때문에 Swift 오버레이 이니셜라이저 시그니처가 위와 다를 수 있다. 컴파일 실패 시 `__initExcludingProcesses(_:andDeviceUID:withStream:)`에 `[NSNumber]`로 호출하는 폴백을 쓴다. 구현 첫 5분에 확정.

> **verify**: `AudioHardwareCreateProcessTap`가 `noErr` 반환. 최초 실행 시 "MacEQ가 시스템 오디오를 녹음하려 합니다" 프롬프트가 뜬다. 승인 후 tap UID(UUID 문자열)와 ASBD가 로그에 찍힌다. 거부 시 에러 코드 확인해서 기록.

### Step 3 — Aggregate device 조립

`TapAggregateDevice.swift`:
```swift
let dict: [String: Any] = [
  kAudioAggregateDeviceNameKey:        "MacEQ Engine",
  kAudioAggregateDeviceUIDKey:         "com.maceq.aggregate." + UUID().uuidString,
  kAudioAggregateDeviceMainSubDeviceKey: outputUID,     // clock master = 물리 출력
  kAudioAggregateDeviceIsPrivateKey:   true,
  kAudioAggregateDeviceIsStackedKey:   false,
  kAudioAggregateDeviceTapAutoStartKey: true,
  kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
  kAudioAggregateDeviceTapListKey:     [[kAudioSubTapUIDKey: tapUUIDString,
                                         kAudioSubTapDriftCompensationKey: true]],
]
AudioHardwareCreateAggregateDevice(dict as CFDictionary, &aggID)
```
`private: true`면 생성 프로세스가 죽을 때 Core Audio가 자동 파괴한다 → PRD §23(crash safety)의 큰 부분이 공짜로 해결된다. 그래도 Step 7에서 startup sweep을 넣는다.

> **verify**: 생성 후 aggregate의 input stream format이 tap format과, output stream format이 물리 장치와 일치. `Audio MIDI Setup`에는 **안 보여야** 정상(private).

### Step 4 — Biquad

`Biquad.swift` — RBJ peaking EQ 계수 + Direct Form II transposed, 채널별 상태 배열. `struct Coeffs { b0,b1,b2,a1,a2: Float }`, `mutating func process(_ x: Float) -> Float`. 할당 없음, 분기 없음.

> **verify**: `swift test` 없이 `#if DEBUG` 셀프체크 하나 — 0 dB 게인일 때 임펄스 응답이 입력과 동일(bit-neutral에 가까움), +12 dB @1 kHz일 때 1 kHz 사인파 RMS가 약 4배(±1%). assert로.

### Step 5 — IOProc 연결 (Gate A 핵심)

`EQEngine.swift`:
- `AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, nil) { _, inData, _, outData, _ in ... }`
- 블록 안: 힙 할당·락·로깅·Swift 런타임 호출 전부 금지. 미리 할당한 상태 버퍼만 만진다.
- 파라미터 전달: `os_unfair_lock_trylock` — 잠겨 있으면 이번 콜백은 이전 계수로 넘어간다.
  ```
  // ponytail: trylock으로 충분. 실패해도 다음 콜백(~5ms)에 반영됨.
  //           lock-free seqlock은 실제 드롭이 관측될 때 도입.
  ```
- 채널 수 mismatch는 `min(inCh, outCh)`로 복사, 남는 출력 채널은 0으로 채운다.
- Gate A는 **1개 밴드만**: 1 kHz peaking, Q=1.0, 게인은 stdin으로 조절.

`main.swift`: 시작 → 로그 → `readLine()` 루프에서 `+`/`-`로 게인 ±1 dB, `b`로 bypass 토글, `q`로 종료. `SIGINT`/`SIGTERM` 핸들러에서 teardown.

> **verify (Gate A 합격 기준)** — Apple Music으로 음악 재생 중:
> 1. 소리가 들린다.
> 2. **에코/더블링이 없다** → `.mutedWhenTapped` 동작 확인.
> 3. **하울링/피드백이 없다** → self-exclusion 동작 확인.
> 4. `+`를 여러 번 눌렀을 때 1 kHz 대역이 뚜렷하게 부스트된다.
> 5. `b`로 bypass 시 원음으로 돌아간다.
> 6. `q` 종료 후 시스템 오디오가 정상으로 복귀한다.
>
> 2번 또는 3번이 실패하면 → 폴백: `muteBehavior`를 `.muted`로 바꿔보고, 그래도 안 되면 device-scoped tap 대신 `initStereoGlobalTapButExcludeProcesses`로 전환해 비교. 결과를 플랜에 기록.

### Step 6 — Teardown / 예외 경로

정상 종료 시 순서: IOProc stop → destroy IOProc → `AudioHardwareDestroyAggregateDevice` → `AudioHardwareDestroyProcessTap`. 각 단계 실패해도 다음 단계 계속 진행(방어).

> **verify**: `q` 종료, `Ctrl-C`, `kill -TERM`, `kill -9` 4가지 모두에서 시스템 오디오가 살아남는다. `kill -9` 직후 다른 앱 소리가 정상인지 확인 — private aggregate 자동 파괴가 실제로 되는지가 여기서 판명된다.

### Step 7 — Stale 리소스 정리

기동 시 `kAudioHardwarePropertyTapList`를 훑어 이름이 "MacEQ Tap"인 고아 tap을 파괴. aggregate도 UID가 `com.maceq.aggregate.`로 시작하는 것을 정리.

> **verify**: `kill -9` 후 재실행 → 정리된 개수가 로그에 찍히고, 두 번째 실행이 정상 동작.

### Gate A 측정 (통과 후 즉시 기록)

- CPU: `top -pid <pid>` 재생 중 평균
- Latency: IOProc buffer frame size × 2 + tap 보고 latency (`kAudioSubTapPropertyExtraLatency`)
- tap ASBD 실측값 (장치별: 내장 스피커 / AirPods / USB DAC)

이 수치가 Gate B 설계의 입력이다.

---

## Gate B~E 로드맵 (요약)

| Gate | 목표 | 주요 산출물 | 최대 리스크 |
|---|---|---|---|
| **B — Production Engine** | 20밴드 + preamp + Auto Headroom + limiter + 장치 hot-swap + sleep/wake + 샘플레이트 변경 복구 | `Equalizer.swift`(20 biquad cascade), `HeadroomManager`, `SafetyLimiter`, `DeviceObserver`(`kAudioHardwarePropertyDefaultOutputDevice` 리스너), `AudioRecoveryManager`(백오프 재시도, 무한루프 금지), `SleepWakeObserver`(`NSWorkspace` 알림) | 파이프라인 rebuild 중 무음 구간 / 재시도 폭주. rebuild는 반드시 직렬 큐 1개에서, 재시도 상한 5회 + 지수 백오프 |
| **C — Product UX** | SwiftUI Home, Curve Editor, Preset, Settings, Menu Bar, 온보딩 | `PresetStore`(JSON, `~/Library/Application Support/MacEQ/`), `SettingsStore`, `MenuBarExtra`, Curve↔Band 양방향 바인딩 | UI 이벤트가 오디오 그래프를 rebuild하는 실수. **파라미터 변경은 계수 갱신만, rebuild 금지**(PRD §30/§42) |
| **D — Reliability** | 권한 거부 UX, BT 재연결, 상태 마이그레이션, 자동 테스트 | `PermissionManager`, `Migration`, DSP 단위 테스트(계수·헤드룸·리미터), 수동 시나리오 체크리스트(PRD §43) | 설정 파일 손상 시 crash. 모든 로드는 `try?` + safe defaults |
| **E — Distribution** | 서명 + DMG + 업데이트 | `scripts/release.sh`, GitHub Actions, (선택) Sparkle 2 | **로컬 앱이므로 notarization은 필수 아님.** Developer ID 없이 Apple Development 서명으로 로컬 배포. 배포 범위 넓히기로 결정하면 그때 Hardened Runtime + notarization 도입 |

---

## 이번 세션에서 하지 않는 것

- SwiftUI 코드 (Gate A 통과 전 금지)
- Per-App EQ, AutoEQ, Spectrum, Parametric — PRD P1/P2
- Sandbox 활성화 판단 — Gate D
- Notarization — 로컬 앱이므로 보류

## 구현 시작 시 즉시 처리할 것

플랜 모드에서는 플랜 파일 외 수정이 금지되어 미뤄진 항목:
1. `~/.claude/projects/-Users-macbook-dev-tools-local-eq/memory/`에 확정 기술 결정 저장(Tap+aggregate+IOProc 아키텍처, bundle ID 고정 이유, 서명 identity) + `MEMORY.md` 인덱스 갱신
2. `local-eq/plan/gate-a.md`에 이 문서 복사

## 미해결 / 구현 중 확정할 것

1. `CATapDescription` Swift 오버레이 이니셜라이저 정확한 시그니처 (Step 2)
2. tap ASBD 실측 포맷 — interleaved 여부 (Step 2)
3. `.mutedWhenTapped` + self-exclusion 조합의 실제 동작 (Step 5, **최대 리스크**)
4. `kill -9` 시 private aggregate 자동 파괴 여부 (Step 6)
5. TCC 재프롬프트용 `tccutil reset` 서비스 이름 (실험으로 확인)

---

# Gate A 실행 결과 (2026-08-26)

## 미해결 항목 해소

| # | 항목 | 결과 |
|---|---|---|
| 1 | `CATapDescription` Swift 시그니처 | **Swift 오버레이 없음.** `CATapDescription(__excludingProcesses: [NSNumber], andDeviceUID:, withStream:)` 사용 |
| 2 | tap ASBD 실측 | 48000 Hz, 2 ch, 32-bit float, **interleaved**, 8 bytes/frame — 물리 장치 포맷과 동일 |
| 3 | `.mutedWhenTapped` + self-exclusion | **동작.** EQ가 out을 +8 dB 올리는 동안 in은 -14.0 dBFS로 고정 → 자기 출력이 탭에 안 잡힘 = 피드백 루프 없음 |
| 4 | `kill -9` 시 private 리소스 자동 파괴 | **파괴됨.** 재기동 시 고아 sweep이 0건 |
| 5 | TCC 서비스 이름 | **`AudioCapture`**. `tccutil reset AudioCapture com.maceq.app` |

## 발견된 함정

1. **권한 없으면 조용히 실패한다.** `AudioHardwareCreateProcessTap`도 `AudioDeviceStart`도 `noErr`를 반환하고, aggregate는 `alive 1`에 스트림도 정상으로 보이는데 **IOProc이 한 번도 안 불린다.** 유일한 증상이 "콜백 0회"라서 `MACEQ_NOTAP` / `MACEQ_DIRECT` 격리 프로브 없이는 원인을 못 찾는다. Gate D의 PermissionManager는 이 무증상 실패를 반드시 탐지해야 한다 — 시작 후 일정 시간 내 콜백이 0이면 권한 미승인으로 판정.
2. **Swift 6 top-level code는 `@MainActor`다.** 시그널/타이머 핸들러를 다른 큐에 붙이면 `dispatch_assert_queue` SIGTRAP으로 죽는다. 핸들러는 main queue에 둔다.
3. **SwiftPM `platforms: [.macOS(.v14)]`로는 부족하다.** tap API가 14.2+라 `.macOS("14.2")` 필요.
4. **Dispatch 시그널은 병합된다.** 빠른 연타가 한 스텝으로 뭉친다. Gate C에서 UI로 대체되면 사라지는 문제.

## 측정값 (release build, 1밴드, 내장 스피커 48 kHz)

| 항목 | 값 | PRD 목표 |
|---|---|---|
| CPU (재생 중) | 0.2 – 0.3 % | < 5 % |
| CPU (무음) | 0.0 % | ~0 % |
| 메모리 RSS | ~6 MB | < 150 MB |
| IOProc 버퍼 | 512 frames (10.7 ms) | — |
| 추가 latency 추정 | ≈ 1 버퍼 ≈ 10.7 ms | ≤ 20 ms |
| 콜백률 | 187–188 / 2 s (= 48 kHz) | — |

debug 빌드는 6.7 %였다. **성능 측정은 반드시 release로 한다.**

## 객관 검증 (1 kHz 사인파, 진폭 0.2 = -13.98 dBFS)

| 상태 | in | out | 판정 |
|---|---|---|---|
| gain 0 dB | -14.0 dBFS | -14.0 dBFS | 통과 — bit 수준 pass-through |
| gain +2 dB | -14.0 dBFS | -12.0 dBFS | 통과 |
| gain +8 dB | -14.0 dBFS | -6.0 dBFS | 통과 |
| bypass ON | -14.0 dBFS | -14.0 dBFS | 통과 |
| teardown (TERM / kill -9) | — | — | 통과, 시스템 오디오 유지 |

biquad 셀프체크: 0 dB pass-through 오차 < 1e-9, +12 dB = 3.981x (이론값 3.981), 1 kHz 부스트의 50 Hz 누설 < 5 %.

## 청취 확인 (사용자, 2026-08-26)

- 에코/더블링 없음 → `.mutedWhenTapped`가 원래 경로를 제대로 끊는다
- 하울링 없음 → self-exclusion 동작
- +8 dB 부스트가 뚜렷하게 들림

## Gate A 판정: 통과

PRD §45 Gate A 조건(시스템 오디오 → Core Audio Tap → EQ → 물리 출력, 한 밴드 변경을 실제 음악으로 확인) 충족.
Gate B 착수 가능.
