// SPDX-License-Identifier: MIT
/*
 * Stand-in for a VM sending TCP through a tap device, the way QEMU/vhost do:
 * frames are written with a virtio_net_hdr (IFF_VNET_HDR).
 *
 *   tapinject -i TAP -c [-N]          create TAP as a persistent tap device
 *                                     (-N: IFF_NAPI, i.e. tap RX goes through GRO)
 *   tapinject -i TAP -s SRC -d DST -m DSTMAC [-N] [-G] [-n SEGS] [-b BURSTS]
 *                                     send BURSTS bursts of SEGS full-size segments of
 *                                     one TCP flow; -G sends each burst as one TSO
 *                                     frame (VM with TSO on), otherwise as SEGS
 *                                     MSS-size frames (VM with TSO off)
 */
#include <arpa/inet.h>
#include <fcntl.h>
#include <linux/if.h>
#include <linux/if_tun.h>
#include <linux/virtio_net.h>
#include <net/ethernet.h>
#include <netinet/ip.h>
#include <netinet/tcp.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/uio.h>
#include <unistd.h>

#define MSS 1188

static uint32_t sum16(const void *data, size_t len, uint32_t sum)
{
	const uint8_t *p = data;

	for (; len > 1; len -= 2, p += 2)
		sum += (p[0] << 8) | p[1];
	if (len)
		sum += p[0] << 8;
	return sum;
}

static uint16_t fold(uint32_t sum)
{
	while (sum >> 16)
		sum = (sum & 0xffff) + (sum >> 16);
	return sum;
}

static int open_tap(const char *name, int napi, int persist)
{
	struct ifreq ifr = {0};
	int fd = open("/dev/net/tun", O_RDWR);

	if (fd < 0) {
		perror("/dev/net/tun");
		exit(1);
	}
	ifr.ifr_flags = IFF_TAP | IFF_NO_PI | IFF_VNET_HDR | (napi ? IFF_NAPI : 0);
	strncpy(ifr.ifr_name, name, IFNAMSIZ - 1);
	if (ioctl(fd, TUNSETIFF, &ifr) < 0) {
		perror("TUNSETIFF");
		exit(1);
	}
	if (persist && ioctl(fd, TUNSETPERSIST, 1) < 0) {
		perror("TUNSETPERSIST");
		exit(1);
	}
	return fd;
}

int main(int argc, char **argv)
{
	const char *ifname = NULL, *src = NULL, *dst = NULL, *mac = NULL;
	int create = 0, napi = 0, tso = 0, segs = 40, bursts = 200, opt;

	while ((opt = getopt(argc, argv, "i:cNGs:d:m:n:b:")) != -1) {
		switch (opt) {
		case 'i': ifname = optarg; break;
		case 'c': create = 1; break;
		case 'N': napi = 1; break;
		case 'G': tso = 1; break;
		case 's': src = optarg; break;
		case 'd': dst = optarg; break;
		case 'm': mac = optarg; break;
		case 'n': segs = atoi(optarg); break;
		case 'b': bursts = atoi(optarg); break;
		default: return 2;
		}
	}
	if (!ifname || (!create && (!src || !dst || !mac)) || segs < 1 || segs > 50) {
		fprintf(stderr, "usage: see the comment at the top of tapinject.c\n");
		return 2;
	}
	if (create) {
		close(open_tap(ifname, napi, 1));
		return 0;
	}

	int fd = open_tap(ifname, napi, 0);
	size_t hdrs = sizeof(struct ether_header) + sizeof(struct iphdr) + sizeof(struct tcphdr);
	size_t maxpay = (size_t)segs * MSS;
	uint8_t *frame = calloc(1, hdrs + maxpay);
	struct ether_header *eth = (void *)frame;
	struct iphdr *ip = (void *)(eth + 1);
	struct tcphdr *tcp = (void *)(ip + 1);
	uint8_t *data = (uint8_t *)(tcp + 1);
	struct virtio_net_hdr vh;

	if (sscanf(mac, "%hhx:%hhx:%hhx:%hhx:%hhx:%hhx", &eth->ether_dhost[0], &eth->ether_dhost[1],
		   &eth->ether_dhost[2], &eth->ether_dhost[3], &eth->ether_dhost[4],
		   &eth->ether_dhost[5]) != 6) {
		fprintf(stderr, "bad MAC %s\n", mac);
		return 2;
	}
	memcpy(eth->ether_shost, "\x02\x00\x00\x00\x00\x02", ETH_ALEN);
	eth->ether_type = htons(ETH_P_IP);
	ip->version = 4;
	ip->ihl = 5;
	ip->frag_off = htons(IP_DF);
	ip->ttl = 64;
	ip->protocol = IPPROTO_TCP;
	inet_pton(AF_INET, src, &ip->saddr);
	inet_pton(AF_INET, dst, &ip->daddr);
	tcp->source = htons(41000);
	tcp->dest = htons(15299);
	tcp->doff = 5;
	tcp->ack = 1;
	tcp->window = htons(65535);
	tcp->ack_seq = htonl(1);
	for (size_t i = 0; i < maxpay; i++)
		data[i] = (uint8_t)i;

	uint32_t seq = 1000;
	uint16_t id = 1;
	long frames = 0;
	for (int b = 0; b < bursts; b++) {
		int nframes = tso ? 1 : segs;
		size_t pay = tso ? maxpay : MSS;

		for (int f = 0; f < nframes; f++) {
			size_t l4 = sizeof(*tcp) + pay;
			uint32_t pseudo = sum16(&ip->saddr, 8, IPPROTO_TCP + l4);

			ip->tot_len = htons(sizeof(*ip) + l4);
			ip->id = htons(id);
			id += tso ? segs : 1;
			ip->check = 0;
			ip->check = htons(~fold(sum16(ip, sizeof(*ip), 0)) & 0xffff);
			tcp->seq = htonl(seq);
			seq += pay;
			memset(&vh, 0, sizeof(vh));
			if (tso) {
				/* CHECKSUM_PARTIAL: the field holds the pseudo-header seed. */
				tcp->check = htons(fold(pseudo));
				vh.flags = VIRTIO_NET_HDR_F_NEEDS_CSUM;
				vh.gso_type = VIRTIO_NET_HDR_GSO_TCPV4;
				vh.hdr_len = hdrs;
				vh.gso_size = MSS;
				vh.csum_start = sizeof(*eth) + sizeof(*ip);
				vh.csum_offset = offsetof(struct tcphdr, check);
			} else {
				tcp->check = 0;
				tcp->check = htons(~fold(sum16(tcp, l4, pseudo)) & 0xffff);
			}
			struct iovec iov[2] = { { &vh, sizeof(vh) }, { frame, hdrs + pay } };
			if (writev(fd, iov, 2) < 0) {
				perror("writev");
				return 1;
			}
			frames++;
		}
		usleep(20000);
	}
	printf("tapinject: wrote %ld frames (%d bursts, %s, %d segs each, %s tap)\n", frames, bursts,
	       tso ? "TSO" : "MSS-size", segs, napi ? "IFF_NAPI" : "plain");
	return 0;
}
