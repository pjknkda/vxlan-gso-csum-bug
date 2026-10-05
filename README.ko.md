# VXLAN 터널 GSO 재분할 시 outer UDP checksum 손상

[English](README.md) | **한국어**

[Elice Inc.](https://elice.io/ko)(엘리스)가 문제를 찾고 해결했습니다.

VXLAN 터널(UDP checksum 사용)로 TCP를(UDP GRO 포워딩을 켰다면 UDP도) 포워딩하는 리눅스 호스트에서, 적층 장치(macvlan, bond 등)가 GRO skb를 "아직 GSO인 skb 여러 개"로 나누고 하위 장치가 이를 다시 소프트웨어로 분할하면 **outer UDP checksum이 틀린 패킷**이 나갑니다. Ubuntu 22.04 / 24.04 / 26.04 커널(5.15 \~ 7.0)에서 재현했고, upstream v7.0에도 같은 코드가 남아 있습니다.

- 전체 분석: [docs/REPORT.ko.md](docs/REPORT.ko.md) ([English](docs/REPORT.md))
- 커널 패치: [fix/udp-gso-fix.patch](fix/udp-gso-fix.patch)
- 리포트 표의 원본 요약: [docs/data/](docs/data/)

## 수정 설치 (DKMS)

영향받는 커널(x86-64, Ubuntu 22.04 / 24.04 / 26.04의 5.15 \~ 7.0 커널)을 쓰는 호스트용입니다. [fix/udp-gso-fix.patch](fix/udp-gso-fix.patch)와 같은 수정을 kprobe로 적용하는 작은 커널 모듈입니다. 새 커널을 설치할 때마다 DKMS가 다시 빌드하고, 부팅 시 자동으로 로드됩니다.

패키지는 [Releases](https://github.com/pjknkda/vxlan-gso-csum-bug/releases) 페이지에서 받을 수 있습니다(`v*` 태그마다 CI가 빌드해 첨부합니다). 직접 빌드할 수도 있습니다(`dpkg-deb`만 있으면 되고 root 권한은 필요 없습니다).

```bash
git clone https://github.com/pjknkda/vxlan-gso-csum-bug.git
vxlan-gso-csum-bug/fix/dkms/build-deb.sh        # -> dist/vxlan-gso-csum-fix_1.0.0_amd64.deb
```

각 호스트에 설치합니다. apt가 `dkms`를 함께 설치하고, 헤더가 있는 모든 커널에 대해 모듈을 빌드한 뒤 바로 로드합니다. 이후 부팅할 때마다 자동으로 로드됩니다.

```bash
sudo apt install linux-headers-$(uname -r) ./vxlan-gso-csum-fix_1.0.0_amd64.deb
```

동작 확인:

```bash
lsmod | grep vxlan_gso_csum_fix
sudo dmesg | grep vxlan_gso_csum_fix     # "vxlan_gso_csum_fix: active"
```

제거: `sudo apt remove vxlan-gso-csum-fix`

패키지 없이 소스에서 바로 설치하려면 `sudo apt install dkms linux-headers-$(uname -r)` 후 `sudo vxlan-gso-csum-bug/fix/dkms/install.sh`를 실행합니다. 제거는 `fix/dkms/uninstall.sh`입니다.

두 방식 모두 실제 Ubuntu 24.04 클라우드 이미지에서 end-to-end로 검증했습니다(`lab/dkms-e2e.sh`, `MODE=deb` 또는 `MODE=script`). 6.8.0-142-generic에 설치한 뒤 HWE 커널 7.0.0-38-generic을 설치하자 DKMS가 모듈을 자동으로 다시 빌드했고, 7.0으로 재부팅하자 자동 로드됐으며, 제거 후 남은 파일이 없었습니다.

참고:
- Secure Boot 환경에서는 DKMS가 머신의 MOK 키로 모듈에 서명합니다. 그 키가 등록되어 있어야 합니다(`dkms`를 처음 설치할 때 Ubuntu가 등록을 안내합니다). Secure Boot는 end-to-end 테스트에 포함되지 않았습니다.
- 이 모듈은 대상 함수의 인자를 레지스터에서 읽습니다. 위 커널들에서는 맞지만, 다른 빌드에 쓰기 전에는 확인이 필요합니다([docs/REPORT.ko.md](docs/REPORT.ko.md#수정-방식별-성능-kprobe-vs-livepatch) 참고).
- 커널에 패치가 들어간 뒤에는 이 모듈이 불필요하지만 해가 되지는 않습니다(정규화는 여러 번 해도 결과가 같습니다). 그때는 제거하면 됩니다.

## 디렉터리 구성

```
fix/
  udp-gso-fix.patch          kernel fix (applies to Ubuntu 6.8.0-100.100, v6.8.12, v7.0)
  dkms/                      same fix as a kprobe module for DKMS (build-deb.sh, install.sh)
  livepatch-6.8.0-100/       same fix as a livepatch for 6.8.0-100-generic only
lab/
  qemu-test.py               boot one kernel in a QEMU guest and run the reproducer
  matrix.py                  run named cases in parallel guests and summarise
  perf.py                    kprobe vs livepatch per-call cost (needs KVM)
  dkms-e2e.sh                install/upgrade/uninstall test of fix/dkms on an Ubuntu cloud image
  guest/                     scripts that run inside the guest
  tools/burst.c              deterministic GRO feeder (same-flow TCP segment bursts)
  tools/tapinject.c          stand-in for a VM sending TCP through a tap device
  tools/pcap-csum.py         check outer UDP / inner TCP checksums in a pcap
  kmod/trace/                tracing kprobe (+ fix with mode=1)
  kmod/bench/                skb_gso_segment() microbenchmark
  qemu/igb-desc-offload.patch  QEMU igb model fix needed for TX-offload-on runs
scripts/                     download / build everything into .cache/ (not committed)
.github/workflows/deb.yml    CI: build the .deb, DKMS-compile it for Ubuntu 24.04 GA and HWE
                             kernels, attach it to a GitHub Release on v* tags
docs/                        report and result summaries
```

다운로드와 빌드 결과는 `.cache/`, 실행 결과는 `results/`에 생기며 둘 다 git에서 제외됩니다.

## 재현 랩: 요구사항

- Ubuntu 24.04 호스트(빌드 의존성은 `apt-get download`로 받으며, 시스템에 설치하지 않습니다)
- `python3`, `gcc`, `make`, `curl`, `dpkg-deb`, `depmod`/`modprobe`(kmod), `busybox`, `iproute2`, `tcpdump`
- KVM 권장(`/dev/kvm` 쓰기 권한). 없으면 TCG로 실행됩니다. 결과는 같지만 느리고, `lab/perf.py`는 의미가 없습니다.
- 커널 하나와 QEMU 기준 약 3 GB의 디스크

## 재현 랩: 빠른 시작

```bash
# 1. 테스트할 커널 -> .cache/sysroots/<release>
scripts/fetch-kernel.py 6.8.0-100-generic --version 6.8.0-100.100      # Launchpad (게시된 모든 빌드)
scripts/fetch-kernel.py 7.0.0-38-generic --suite resolute-updates       # 아카이브의 현재 빌드

# 2. igb 수정이 들어간 QEMU 8.2.2 -> .cache/qemu/bin/qemu-system-x86_64 (약 10분)
scripts/setup-qemu.sh

# 3. 커널별 게스트 바이너리와 모듈 -> .cache/bin, .cache/kmod/<release>
scripts/build.sh 6.8.0-100-generic
scripts/build.sh 7.0.0-38-generic        # GCC 14를 자동으로 받습니다

# 4. 재현, 그리고 수정(kprobe mode=1)으로 오류가 사라지는지 확인
lab/matrix.py --tag smoke base fix
lab/matrix.py --tag smoke-7.0 --release 7.0.0-38-generic base fix
```

기대 결과: `base`는 두 TX offload 모드 모두에서 수천 건의 `UdpInCsumErrors`, `fix`는 0건입니다.

### 케이스

전체 목록은 `lab/matrix.py --help`로 볼 수 있습니다. 주요 묶음은 다음과 같습니다.

| 케이스 | 보여 주는 것 |
|---|---|
| `base`, `fix` | 재현과 수정 (결정적 버스트 트래픽) |
| `udp`, `udp-gro-fwd`, `udp-gro-list`, `fix-udp-gro-*` | inner를 TCP 대신 UDP로, router NIC GRO 모드별 |
| `vxlan-tso-off`, `gso-max-segs-13` | 알려진 workaround 두 가지 |
| `router-gro-off`, `vxlan-nocsum`, `no-gso-partial`, `no-tnl-seg`, `vlan-sg-off`, `tunnel-tso` | 어떤 조건이 필요한지 |
| `path-*` | VXLAN 장치와 wire 사이의 장치 경로별 결과 |
| `vm-tso`, `vm-notso`, `vm-*-napi`, `fix-vm-*` | router의 tap 뒤 VM이 터널로 송신 |
| `<case>+iperf` | 버스트 대신 iperf3 사용 (간헐적 재현, 리포트 참고) |
| `<case>@N` | 같은 케이스 반복 |

기타 도구:

```bash
lab/perf.py --tag perf                                   # kprobe vs livepatch 비용 (KVM 전용)
lab/qemu-test.py --output results/manual --env TRAFFIC=burst --env NA_RX_USECS=2000 \
    --module .cache/kmod/6.8.0-100-generic/gso_entry_reseed.ko --module-args mode=0
lab/tools/pcap-csum.py --src 198.51.100.1 results/<run>/mtu9000/*.pcap
```

## 수정 적용 방법

- **커널 패치**: `fix/udp-gso-fix.patch` (커널 트리에서 `patch -p1`). 5.15는 include 문맥이 달라 같은 hunk를 손으로 적용해야 합니다.
- **kprobe 모듈** (`fix/dkms/`, 위 "수정 설치" 참고): 인자를 레지스터에서 읽습니다(`(skb, features, gso_inner_segment, new_protocol, is_ipv6)` → `rdi`, ..., `r8`). 대상 빌드의 시그니처를 확인한 뒤 사용하세요. 위험 요소는 리포트에 정리되어 있습니다.
- **livepatch** (`fix/livepatch-6.8.0-100/`): Ubuntu 6.8.0-100.100의 함수 본문을 담고 있어 그 빌드에서만 유효합니다. 다른 빌드에는 `fix/udp-gso-fix.patch`로 kpatch-build를 이용해 livepatch를 만드세요.

## 라이선스

Copyright (c) 2026 Elice Inc. 커널 코드와 패치(`fix/`, `lab/kmod/`)는 GPL-2.0, QEMU 패치는 GPL-2.0-or-later, 나머지는 MIT입니다. 자세한 내용은 [LICENSE](LICENSE)를 참고하세요.
