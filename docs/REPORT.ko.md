# VXLAN 터널 GSO 재분할 시 outer UDP checksum 손상

[English](REPORT.md) | **한국어**

- 작성: [Elice Inc.](https://elice.io/ko)
- 작성일: 2026-10-05
- 확인 커널: Ubuntu 22.04 / 24.04 / 26.04 LTS (5.15 \~ 7.0), upstream v5.15 \~ v7.0 동일 코드

## 요약

- **현상**: VXLAN 터널(UDP checksum 사용)로 TCP 트래픽(UDP GRO 포워딩을 켰다면 UDP 트래픽도)을 **포워딩하는 리눅스 호스트**가, 특정 장치 구성에서 **outer UDP checksum이 틀린 패킷**을 내보낸다. 수신측은 이 패킷을 UDP checksum 오류(`Udp: InCsumErrors`)로 버린다. 그 결과 TCP 재전송이 늘고 처리량이 크게 떨어진다.
- **원인**: 커널이 이미 한 번 터널 GSO를 거친 skb를 하위 장치에서 **다시 SW GSO할 때**, `__skb_udp_tunnel_segment()`가 outer UDP checksum 필드를 잘못된 형태로 해석한다(아래 "원인" 절).
- **영향 범위**: Ubuntu 22.04(5.15, HWE 6.8), 24.04(6.8, HWE 7.0), 26.04(7.0)에서 모두 재현했다. NIC TX checksum offload의 on/off와 무관하다. upstream v7.0에도 같은 코드가 있다.
- **수정**: 재분할 진입 시점에 outer UDP checksum을 표준 pseudo-header seed로 정규화하는 20줄 정도의 패치다(`fix/udp-gso-fix.patch`). 모든 커널, 모든 경로에서 오류가 0이 되는 것을 확인했다.
- **기존 workaround**: vxlan 장치의 TSO를 끄거나 `gso_max_segs`를 낮추면 오류가 사라진다. 둘 다 터널 GSO skb가 이 경로에 오지 않게 막는 방식이다(아래 "workaround 분석" 절).
- **재현**: QEMU VM 한 대 안에서 실제 NIC 없이, 실행할 때마다 확실히(결정적으로) 재현된다.

## 영향을 받는 환경

### 전형적인 구성

TCP 트래픽을 받아 VXLAN으로 캡슐화해 다른 호스트로 보내는 **라우터/게이트웨이 역할 호스트**에서 일어난다. 송신측 장치 스택은 다음과 같다.

```
   TCP traffic from another host
              |
              v
   +-----------------------+
   |  RX NIC  (GRO on)     |   (a)
   +-----------------------+
              |  IP forwarding
              v
   +-----------------------+
   |  vxlan  (udpcsum)     |   (b)
   +-----------------------+
              |
              v
   +-----------------------+
   |  upper device         |   (c)  1st software GSO
   |  e.g. macvlan, bond   |
   +-----------------------+
              |
              v
   +-----------------------+
   |  lower device         |   (d)  2nd software GSO  <-- checksum corrupted here
   |  e.g. VLAN, NIC       |
   +-----------------------+
              |
              v
   wire: bad outer UDP checksum -> dropped by the receiver
```

- (a) 수신 NIC의 GRO가 같은 flow의 TCP 세그먼트 여러 개를 frag_list skb 하나로 합친다.
- (b) vxlan이 이 skb를 터널 GSO skb(`gso_type = TCPV4 | UDP_TUNNEL_CSUM`)로 캡슐화한다.
- (c) `NETIF_F_FRAGLIST`가 없는 상위 장치가 1차 SW GSO를 한다. frag_list skb가 완전히 분할되지 않고 "아직 GSO인 skb 여러 개"로 나뉜다.
- (d) 하위 장치가 그 GSO skb를 그대로 받지 못해 2차 SW GSO를 한다. 이때 outer UDP checksum이 잘못 계산된다.

### 발생 조건 (모두 충족해야 함)

| # | 조건 | 의미 | 회피 방법 (성능 trade-off 있음) |
|---|---|---|---|
| 1 | 포워딩 호스트의 수신 NIC에서 **GRO가 frag_list skb**를 만든다 | GRO 블록(드라이버마다 다름, igb 18 segs, mlx5 약 7 segs로 추정)이 2개 이상 모일 때 생긴다. 고처리량 TCP에서 흔하다. 포워딩되는 UDP는 `rx-udp-gro-forwarding on`일 때만 GRO된다("inner 프로토콜: TCP와 UDP" 참고). | 수신 NIC GRO off |
| 2 | VXLAN에서 **outer UDP checksum을 사용**한다 | IPv4 VXLAN은 `udpcsum` 옵션을 켰을 때 해당한다. IPv6 underlay는 기본으로 checksum을 쓴다(IPv6는 미검증). | `noudpcsum` |
| 3 | **vxlan 장치가 TSO로 GSO skb를 그대로 내려보낸다** | vxlan TSO가 꺼져 있으면 캡슐화 전에 분할되어 터널 GSO skb가 생기지 않는다. | **vxlan TSO off** |
| 4 | vxlan의 `gso_max_segs`가 GRO skb 크기 이상이다 | 그보다 큰 skb는 vxlan 단계에서 미리 완전 분할되어 이 경로에 오지 않는다. | **`gso_max_segs` N < 2 × GRO 블록** (예: mlx5 환경에서 13) |
| 5 | VXLAN과 NIC 사이에 **FRAGLIST가 없고, 터널 skb에 대해 SG와 TSO feature를 가진 장치**가 있다 | macvlan과 bond는 항상 해당한다. VLAN은 하위 장치 feature가 바뀌기 전에만 해당한다("VLAN의 이력 의존성" 참고). 이 장치가 1차 분할 지점이 된다. | 구조 변경 |
| 6 | 그 아래 장치가 1차 분할 결과(GSO skb)를 **다시 SW GSO**한다 | NIC TX checksum off, NIC에 터널 TSO가 없음, 또는 NIC가 UDP 터널 checksum을 GSO_PARTIAL 방식으로만 지원하는 경우(mlx5, igb 등). | - |

최초 관찰 환경: Ubuntu 24.04 `6.8.0-100-generic` 포워딩 호스트(mlx5 ConnectX-5, bond, VLAN, macvlan, VXLAN udpcsum)에서 Intel i40e 수신 호스트로 보내는 구성이었다. 수신측 RX checksum offload가 켜져 있으면 i40e가 오류를 가릴 수 있어, RX offload를 끄고 확인했다.

## 장치 경로별 결과

VXLAN 장치와 wire 사이의 송신측 장치 스택별 결과다. 결정적 재현기(40-seg 버스트 × 200), 6.8.0-100, KVM 환경이다. 값은 수신측 `Udp: InCsumErrors` 증가량이다. TX offload on을 먼저 측정한 뒤 off로 바꿔 측정했다. 원본 데이터: `docs/data/device-paths.txt`.

| VXLAN 아래 장치 경로 | 1차 분할 지점 | TX on | TX off |
|---|---|---|---|
| macvlan → VLAN → NIC | macvlan | **7204** | **7295** |
| macvlan → NIC | macvlan | **7678** | **7605** |
| macvlan → VLAN → bond → NIC | macvlan | **7451** | **7372** |
| bond → NIC | bond | **7593** | **7677** |
| VLAN → NIC | VLAN (NIC feature 변경 전만) | **7385** | 0 ¹ |
| VLAN → bond → NIC | 없음 ² | 0 | 0 |
| NIC 직결 | 없음 ³ | 0 | 0 |

- NIC가 mlx5처럼 GSO_PARTIAL 터널 TSO를 쓰는 설정(igb `tx-tcp-mangleid-segmentation on`)에서도 모든 경로의 재현 여부가 같았다(수치 7195\~7761).
- ¹ TX off로 바꾸는 순간 NIC feature가 바뀌면서 VLAN이 SG를 잃는다. TX off 자체가 아니라 feature 변경 이력 때문에 재현되지 않은 것이다.
- ² VLAN 아래 bond는 slave link-up 시점(VLAN 생성 이후)에 feature를 다시 계산한다. 이 때문에 VLAN이 항상 SG를 잃는다.
- ³ NIC가 직접 분할하면 그 결과가 곧바로 NIC로 나가므로 2차 분할(재진입)이 일어나지 않는다.

## inner 프로토콜: TCP와 UDP

터널 분할 경로는 inner 프로토콜과 무관하므로 inner UDP도 테스트했다. 결정적 재현기로 같은 flow의 같은 크기 UDP datagram 40개씩 200회를 보냈다(6.8.0-100, KVM, 기본 경로). 원본 데이터: `docs/data/inner-udp.txt`.

| inner 트래픽 | router NIC GRO 모드 | `UdpInCsumErrors` TX on / off | inner datagram 전달 (8000개 중) TX on / off | 터널 skb `gso_type` |
|---|---|---|---|---|
| TCP (대조군) | 기본 | **7675 / 7719** | - | `TCPV4 \| UDP_TUNNEL_CSUM` |
| UDP | 기본 | 0 / 0 | 8000 / 8000 | (GSO 없음) |
| UDP | **`rx-udp-gro-forwarding on`** | **7722 / 7601** | **278 / 399** | `UDP_L4 \| UDP_TUNNEL_CSUM` |
| UDP | `rx-gro-list on` | 0 / 0 | 8000 / 8000 | `FRAGLIST \| UDP_L4 \| UDP_TUNNEL_CSUM` |
| UDP + 수정 | `rx-udp-gro-forwarding on` | 0 / 0 | 8000 / 8000 | `UDP_L4 \| UDP_TUNNEL_CSUM` |

- **기본 설정**: 포워딩되는 UDP는 GRO되지 않으므로 GSO skb가 없고 영향도 없다.
- **`rx-udp-gro-forwarding on`**: UDP GRO도 TCP와 같은 `skb_gro_receive()`로 frag_list skb를 만든다. 상위 장치가 `skb_segment()`로 split하고, 하위 장치에서 `__skb_udp_tunnel_segment()`에 재진입하는 과정이 TCP와 똑같다. datagram의 약 95\~97%가 수신측에서 버려졌고, 수정을 적용하면 0이 된다.
- **`rx-gro-list on`** (fraglist GRO): 상위 장치가 `skb_segment_list()`로 곧바로 개별 패킷까지 분할하므로 2차 분할이 없다.

### VLAN의 이력 의존성

`register_netdevice()`는 새 장치의 `hw_enc_features`에 `NETIF_F_SG`를 넣는다. 그래서 VLAN은 생성 직후에는 터널 skb에 대해 SG를 가지며 1차 분할 지점이 될 수 있다. 하지만 하위 장치에서 feature 변경 이벤트(`NETDEV_FEAT_CHANGE`)가 오면 `vlan_transfer_features()`가 `hw_enc_features = vlan_tnl_features(real_dev)`로 덮어쓰고, 이 값에는 SG가 없다. 따라서 VLAN 경로의 재현 여부는 **VLAN 생성 이후 하위 NIC나 bond의 feature가 바뀐 적이 있는지**(`ethtool -K` 실행, bond slave 변화 등)에 달려 있다. macvlan과 bond에는 이런 이력 의존성이 없다.

## 원인

커널 소스(6.8.12 기준, 5.15와 7.0도 동일)와 kprobe 계측으로 확인한 흐름이다.

1. **GRO**: 포워딩 호스트의 수신 NIC가 같은 flow의 TCP 세그먼트를 frag_list skb로 합친다. 랩(igb)에서는 head가 18 segs(linear 1 + page frag 17)이고, frag_list 멤버도 각각 18 segs다.
2. **캡슐화**: vxlan이 이 skb를 `gso_type = TCPV4 | UDP_TUNNEL_CSUM`인 터널 GSO skb로 만든다. outer UDP checksum 필드에는 표준 pseudo-header seed가 들어간다.
3. **1차 SW GSO (상위 장치)**: `validate_xmit_skb()`에서 장치에 FRAGLIST가 없으므로 GSO가 일어난다. 장치 features에 SG, csum, TSO, UDP_TUNNEL_CSUM이 있고 다음 조건이 맞으면, `skb_segment()`는 "Try to split the SKB to multiple GSO SKBs with no frag_list" 경로를 탄다.
   - 마지막을 제외한 frag_list 멤버의 길이가 모두 같다
   - 멤버에 non-head_frag linear 데이터가 없다
   - **head payload 길이 == 첫 멤버 길이**

   결과는 완전히 분할된 패킷이 아니라 **아직 GSO 상태인 skb 여러 개**다.
4. 이 출력 skb들은 `ip_summed=CHECKSUM_PARTIAL`, `encapsulation=1`, `encap_hdr_csum=1`이다. `__skb_udp_tunnel_segment()` 출력 루프는 이 skb의 outer UDP checksum 필드에 `gso_make_checksum()`으로 계산한 **완성된 LCO checksum**을 쓴다. HW(TSO)가 그대로 받아 처리한다면 문제없는 값이다.
5. **2차 SW GSO (하위 장치)**: 하위 장치가 이 GSO skb를 그대로 받지 못하면 GSO가 다시 일어난다.
   - TX checksum off나 터널 TSO 미지원이면 터널 GSO feature가 없다.
   - GSO_PARTIAL NIC에서는 skb에 `SKB_GSO_PARTIAL` 비트가 없으므로 `gso_features_check()`가 `dev->gso_partial_features`(UDP_TUNNEL_CSUM)를 제거한다.
6. 재진입한 `__skb_udp_tunnel_segment()`는 입력 skb의 outer checksum 필드가 2번의 **pseudo-header seed**라고 가정하고 계산한다.
   ```c
   partial = csum_sub(csum_unfold(uh->check), htonl(skb->len));
   ```
   실제로는 4번의 완성된 checksum이 들어 있으므로, 이 skb에서 나온 **모든 자식 패킷의 outer UDP checksum이 틀린다.** 자식도 `encapsulation=1`이라 커널이 outer checksum을 직접 계산하므로, NIC TX checksum offload를 켜도 HW가 바로잡지 않는다.

계측에서는 모든 실행에서 수신측 오류 수가 "seed 형태가 아닌 입력으로 재진입한 횟수 × 그 skb의 segs"와 일치했다.

### 수정

재분할 소비자인 `__skb_udp_tunnel_segment()`의 진입 시점(`pskb_may_pull()` 뒤, `partial` 계산 전)에서, 재진입 skb의 outer checksum을 표준 seed로 정규화한다. 전체 패치는 `fix/udp-gso-fix.patch`이고, Ubuntu 6.8.0-100.100, upstream 6.8.12, 7.0에 그대로 적용된다. 5.15는 include 문맥이 달라 손으로 옮겨야 한다.

```c
if ((skb_shinfo(skb)->gso_type & SKB_GSO_UDP_TUNNEL_CSUM) &&
    skb->encap_hdr_csum) {
	if (is_ipv6) {
		const struct ipv6hdr *ip6h = ipv6_hdr(skb);

		uh->check = ~udp_v6_check(skb->len, &ip6h->saddr, &ip6h->daddr, 0);
	} else {
		const struct iphdr *iph = ip_hdr(skb);

		uh->check = ~udp_v4_check(skb->len, iph->saddr, iph->daddr, 0);
	}
}
```

커널을 다시 빌드할 수 없는 호스트에는 `fix/dkms/`가 같은 수정을 kprobe 모듈로 제공한다. DKMS로 설치하며, 방법은 `README.ko.md`의 "수정 설치" 절에 있다.

1차 분할의 **출력**을 고치는 방식은 쓰면 안 된다. 그 값은 HW TSO 소비자에게는 올바르기 때문에, 출력을 seed로 바꾸면 TX offload 경로가 깨진다. 이전 조사에서 실제로 실패를 확인했다.

### 왜 일반 트래픽에서는 간헐적으로 보이는가

split 경로는 GRO skb가 **블록 2개 이상**(head 길이 = 첫 멤버 길이)일 때만 탄다. 랩에서 iperf를 30초씩 3회 돌렸을 때, frag_list skb 약 1만 건 중 99.5%는 블록 1개 + 일부(19\~35 segs)라 split이 일어나지 않았다(`docs/data/iperf-split-analysis.txt`). GRO skb 크기는 NAPI poll 한 번에 도착한 버스트 크기에 달려 있으므로, 트래픽 패턴과 부하에 따라 발생 빈도가 달라진다.

## workaround 분석

기존에 쓰던 두 workaround가 왜 효과가 있는지, 비용은 무엇인지 정리한다. 측정: 6.8.0-100, KVM, 기본 경로(macvlan → VLAN → NIC).

| 설정 | 버스트: TX on / off | iperf: TX on / off | 1차 split | 재진입 |
|---|---|---|---|---|
| 기본 | 7170 / 7330 | 3347 / 2648 오류 | 372 | 1107 |
| **vxlan TSO off** (`ethtool -K <vxlan> tso off`) | 0 / 0 | 0 / 0 | 0 | 0 |
| **vxlan `gso_max_segs 13`** | 0 / 0 | 0 / 0 | 0 | 0 |
| 수정 적용 | 0 / 0 | 0 / 0 | 317 | 894 (모두 정규화) |

**vxlan TSO off가 효과 있는 이유.** vxlan 장치에 TSO가 없으면 vxlan의 `validate_xmit_skb()`가 GRO skb를 **캡슐화하기 전에** MSS 크기의 일반 TCP 패킷으로 분할한다. vxlan은 이 패킷들을 하나씩 캡슐화하므로 `SKB_GSO_UDP_TUNNEL_CSUM` skb가 아예 만들어지지 않는다. 그 결과 1차 split도 재진입도 일어나지 않는다(위 표에서 split 0, 재진입 0).

**`gso_max_segs` 제한이 효과 있는 이유.** `gso_features_check()`는 `gso_segs > dev->gso_max_segs`인 skb에서 GSO feature를 제거한다. 그래서 큰 GRO skb는 vxlan 단계에서 TSO off와 똑같이 처리된다. 작은 skb는 GSO를 유지하지만 블록 2개 미만이라 split 조건을 만족하지 못한다. 최초 관찰 환경에서 13은 정상, 14부터 오류였던 것은 mlx5 GRO 블록이 7 segs(2×7=14)라는 해석과 맞는다(블록 크기는 관찰값에서 추정). 다만 이 값은 NIC 드라이버의 GRO 블록 크기에 의존하므로 다른 NIC에는 그대로 옮길 수 없다(igb는 블록이 18이므로 계산상 35 이하가 필요하다).

**비용.** 두 workaround 모두 vxlan 아래 장치 스택(vxlan 캡슐화, route/neighbor 처리, macvlan, VLAN, bond, qdisc, 드라이버)을 **GSO skb 단위가 아니라 MSS 패킷 단위로** 지나가게 만든다. 따라서 패킷 처리 CPU 비용이 GRO 집적 배수만큼 늘고, NIC TSO 이점도 사라진다. TSO off는 모든 skb에, `gso_max_segs`는 한도를 넘는 skb에만 적용되므로 `gso_max_segs` 쪽이 비용이 작다. 이 랩의 iperf 처리량(약 200\~270 Mbps)은 에뮬레이션 NIC가 병목이라 이 CPU 차이를 보여 주지 못한다(`docs/data/workarounds.txt`). 실제 비용은 실 장비에서 CPU 사용률로 측정해야 한다. 반면 수정 패치는 터널 GSO를 그대로 유지하고, 재분할 skb마다 수십 ns만 더한다("수정 방식별 성능" 절).

## 영향 커널

결정적 재현기(40-seg 버스트), NIC는 igb(패치된 QEMU 모델)를 사용했다. 원본 데이터: `docs/data/kernels.txt`.

| LTS | 커널 | TX offload off | TX offload on | 수정 적용 (off / on) |
|---|---|---|---|---|
| 22.04 GA | 5.15.0-198 | **6544** | **6252** | 0 / 0 |
| 22.04 HWE | 6.8.0-138 (`~22.04.1`) | **6018** | **6288** | 0 / 0 |
| 24.04 GA | 6.8.0-100 | **5031** | **5536** | 0 / 0 |
| 24.04 GA | 6.8.0-146 | **5648** | **6235** | 0 / 0 |
| 24.04 HWE / 26.04 GA | 7.0.0-38 | **6343** | **6585** | 0 / 0 |

수치는 수신측 `Udp: InCsumErrors` 증가량이다. upstream v5.15, v6.8.12, v7.0의 `__skb_udp_tunnel_segment()`(partial 계산)와 `skb_segment()`(split 조건)는 동일하다. 같은 함수를 쓰는 다른 UDP 터널(GENEVE 등)도 영향을 받을 가능성이 높지만 검증하지 않았다.

## 수정 방식별 성능: kprobe vs livepatch

수정을 kprobe pre-handler로 넣는 방식(`fix/dkms/`)과 livepatch로 함수를 교체하는 방식(`fix/livepatch-6.8.0-100/`)의 호출당 비용을 측정했다.

- 커널 내 마이크로벤치(`lab/kmod/bench/gso_bench.c`)가 VXLAN GSO skb를 만들어 `skb_gso_segment()`를 반복 호출한다.
- 같은 부팅 안에서 "수정 없음 → kprobe → livepatch"를 교대로 10회 반복했다(KVM, 6.8.0-100, 2 segs skb, 회당 200k 호출의 중앙값). 원본 데이터: `docs/data/perf-kprobe-vs-livepatch*.txt`.
- 두 방식 모두 x86에서는 함수 진입점의 ftrace(fentry)를 쓴다. kprobe는 `kprobes/list`에서 `[FTRACE]`로 등록된 것을 확인했다.

| | 호출당 시간 | 수정 없음 대비 |
|---|---|---|
| 수정 없음 | 1302 ns (sd 18) | - |
| kprobe | 1372 ns (sd 16) | **+70 ns** |
| livepatch (`klp_patch`로 함수 교체) | 1338 ns (sd 6) | **+36 ns** |

- 측정에 쓴 두 모듈은 모두 결정적 재현기(TX on/off)에서 오류를 0으로 만드는 것을 따로 확인했다.
- 수정 조건이 참일 때(실제로 seed를 다시 계산할 때)와 거짓일 때의 차이는 0\~4 ns로, 수정 로직 자체의 비용은 무시할 수 있다. 비용은 거의 전부 hook 진입 비용이다.
- 7 segs와 14 segs skb(호출당 3.8\~6.7 µs)에서는 두 방식의 차이가 측정 노이즈(±50\~200 ns)에 묻혔다.
- 이 함수는 패킷마다가 아니라 **SW로 터널 GSO되는 skb마다 한 번** 불린다. 최초 관찰 환경에서는 초당 약 1만 3천 회였으므로, kprobe라도 CPU 코어 하나의 0.1% 미만이다. 초당 100만 회라고 가정해도 kprobe 약 7%, livepatch 약 4%(코어 하나 기준)다.

따라서 **성능은 선택 기준이 되지 않는다.** 운영 측면의 차이가 더 중요하다.

| | kprobe | livepatch |
|---|---|---|
| 빌드 | 커널 헤더만 있으면 된다 | 정확한 소스, vmlinux, 컴파일러가 필요하다(kpatch-build). 이 저장소의 livepatch는 6.8.0-100.100 함수 본문을 옮겨 직접 작성했다 |
| 인자 접근 | 레지스터에서 직접 읽는다(`regs->di`, `regs->r8`). ABI나 클론(`.isra`/`.constprop`)이 바뀌면 조용히 오작동한다 | 소스 수준이라 컴파일러가 보장한다 |
| 수정 위치 | 함수 진입점(`pskb_may_pull()` 이전)만 가능하다 | 정확한 위치(`pskb_may_pull()` 이후)에 넣을 수 있다 |
| 무력화 위험 | 같은 함수를 다른 livepatch가 교체하면 kprobe가 더 이상 불리지 않는다. 함수가 inline된 빌드에서는 등록에 실패한다 | 패치 스택과 transition 모델이 정의되어 있다 |

## 재현 랩

### 구성

QEMU VM 한 대 안에 네트워크 namespace를 나눠 두 호스트를 흉내 낸다. 두 에뮬레이션 NIC(igb)는 QEMU hub(가상 스위치)로 연결된다.

```
+------------------------------+        +--------------------------------------+
| client ns                    |  TCP   | router ns + evn ns                   |
|                              |        |                                      |
| generator (iperf3/burst) ----|--------|> nic0 (igb #1, GRO on)               |
|                              |        |    v  IP forwarding                  |
|                              |        |  vxlan0 (udpcsum, TSO)               |
|                              | VXLAN  |    v                                 |
| vlan444 <--------------------|--------|-- macvlan -> vlan444 -> nic0         |
|   v                          |        |  (stack below vxlan0 varies)         |
| vxlan-rx -> bridge -> veth --|---+    +--------------------------------------+
|                              |   |
| UdpInCsumErrors counted here |   |    +-------------------+
| (RX checksum offload off)    |   +--->| server ns         |
+------------------------------+        | TCP sink (iperf3) |
                                        +-------------------+
```

- **client ns**는 TCP를 보내는 쪽이면서, VXLAN 패킷을 받아 checksum을 검증하는 수신 호스트 역할도 한다. RX checksum offload를 꺼서 SW로 검증한다.
- **router ns / evn ns**가 문제의 포워딩 호스트다. NIC와 VLAN은 router ns에, macvlan과 vxlan은 evn ns에 있다. 스크립트 변수 `NA_*`가 이쪽 설정이다.
- 커널은 Ubuntu `.deb`를 설치 없이 풀어서 diskless initramfs로 부팅한다(`scripts/fetch-kernel.py`).
- NIC는 QEMU `igb`(Intel 82576)다. Linux igb 드라이버는 mlx5처럼 UDP 터널 checksum을 GSO_PARTIAL 방식으로 광고한다. veth만으로 구성하면 재현되지 않는다(2차 분할이 일어나지 않음).
- **결정적 재현기** (`lab/tools/burst.c`): client에서 AF_PACKET으로 같은 flow의 연속 TCP 세그먼트(1188 B, ACK, PSH 없음)를 40개씩 200회 보낸다. router NIC의 `rx-usecs=2000`으로 버스트 하나가 GRO 한 번에 묶이게 해서, 매번 18+18+4 구조의 frag_list skb를 만든다. 버스트의 75\~99%가 split 경로를 탄다.
- **계측** (`lab/kmod/trace/gso_entry_reseed.c`, kprobe): `skb_segment()`의 split 판정 이유와 GRO 블록 구조, `__skb_udp_tunnel_segment()` 호출별 진입 상태(장치, seed 여부)를 기록한다. `mode=1`이면 수정을 적용한다.

### QEMU igb 모델 수정 (TX offload on 재현에 필요)

QEMU 8.2 igb 모델은 TX descriptor의 헤더 위치 정보(`MACLEN/IPLEN/L4LEN`)를 무시하고, 자체 파싱한 **가장 바깥 L4 헤더**로 checksum과 TSO를 처리한다. VXLAN 패킷이면 실제 82576과 달리 inner TCP 대신 outer UDP를 다룬다. 그래서 TX offload on에서는 다음 문제가 있었다.
- inner TCP checksum이 비어 있는 채로 나가 처리량이 무너졌다.
- QEMU가 outer UDP checksum을 다시 계산해 버그를 가렸다.

`lab/qemu/igb-desc-offload.patch`는 igb에 `x-desc-offload=on` 속성을 추가해, 실제 HW처럼 descriptor 위치 기준으로 checksum과 TSO를 처리한다.
- TSO는 `MACLEN+IPLEN+L4LEN` 헤더를 복제한다. IP 헤더는 길이와 ID를 갱신하고 IPLEN 범위 checksum을 다시 계산하며, TCP는 seq, flag, checksum을 갱신한다.
- outer UDP는 HW처럼 손대지 않는다.
- 수정 후 송신 프레임의 inner TCP checksum 불량은 0건이었고, TX offload on에서도 위 표처럼 재현과 수정 효과가 확인됐다(`docs/data/tx-offload-on.txt`).
- 수신측 GRO를 끄고 캡처한 pcap을 `lab/tools/pcap-csum.py`로 검사하면, TX offload on에서 wire의 불량 outer UDP 프레임 수(7797)가 수신측 `UdpInCsumErrors`(7797)와 정확히 일치한다.

### 실행 방법

저장소 루트의 `README.ko.md`를 참고한다. KVM(`/dev/kvm` 쓰기 권한)이 있으면 KVM, 없으면 TCG로 실행한다. 재현과 수정 결과는 가속기와 무관하다. 영향 커널 표는 TCG, 나머지 표는 KVM에서 얻은 값이다. 성능 측정은 반드시 KVM에서 해야 한다(TCG에서는 호출 하나에 수십 µs가 걸려 의미가 없다).

## 조건별 상세 결과 (6.8.0-100, TX offload off, TCG)

원본 데이터: `docs/data/conditions.txt`.

| 조합 | UdpInCsumErrors | split / 200 버스트 |
|---|---|---|
| 기본 (macvlan → VLAN → NIC) | 7354 | 189 |
| GSO_PARTIAL off | 7148 | 184 |
| NIC 터널 TSO feature off | 6817 | 178 |
| VLAN sg off | 6603 | 172 |
| **router NIC GRO off** | **0** | 0 |
| **VXLAN noudpcsum** | **0** | 0 |
| **vxlan gso_max_segs 13** | **0** | 0 |
| **수정 적용** | **0** | 194 |

36-seg 버스트에서는 GRO 집적이 대부분 35 segs(블록 1개 + 17)가 되어 split이 1회뿐이었다. "블록 2개 이상" 조건과 맞는다.

## 한계

- 조건 매트릭스는 조합당 1회 실행이다. 결정적 재현기라 차이(수천 건 대 0건)는 분명하다.
- GRO 블록 크기 18은 igb의 2 KB rx buffer 구조에서 나온다. mlx5의 블록 7은 관찰값에서 추정한 것이다.
- workaround의 CPU 비용은 이 랩(에뮬레이션 NIC)에서 측정할 수 없다.
- IPv6 underlay와 VXLAN 외의 UDP 터널은 검증하지 않았다. inner UDP는 6.8.0-100, 기본 경로에서만 테스트했다.
- QEMU 패치는 IPv4/IPv6 TCP와 UDP의 TSO/TXSM을 대상으로 한다. SCTP와 VMDq/loopback은 기존 동작을 쓴다.
