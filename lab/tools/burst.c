// SPDX-License-Identifier: MIT
/*
 * Deterministic GRO feeder: send bursts of back-to-back, full-size TCP
 * segments (or, with -u, equal-size UDP datagrams) of one flow from an
 * AF_PACKET socket, so the receiver's NAPI GRO builds the same skb layout
 * every time. No connection is needed; the forwarded packets only have to
 * reach the VXLAN receiver.
 *
 *   burst -i IFACE -s SRC_IP -d DST_IP -m DST_MAC [-u] [-n SEGS] [-b BURSTS]
 *         [-l PAYLOAD] [-g GAP_US]
 */
#include <arpa/inet.h>
#include <linux/if_packet.h>
#include <net/ethernet.h>
#include <net/if.h>
#include <netinet/ip.h>
#include <netinet/tcp.h>
#include <netinet/udp.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <unistd.h>

static uint16_t csum(const void *data, size_t len, uint32_t sum)
{
	const uint8_t *p = data;

	for (; len > 1; len -= 2, p += 2)
		sum += (p[0] << 8) | p[1];
	if (len)
		sum += p[0] << 8;
	while (sum >> 16)
		sum = (sum & 0xffff) + (sum >> 16);
	return htons(~sum & 0xffff);
}

int main(int argc, char **argv)
{
	const char *ifname = NULL, *src = NULL, *dst = NULL, *mac = NULL;
	int segs = 40, bursts = 100, payload = 1188, gap = 20000, udp = 0, opt;

	while ((opt = getopt(argc, argv, "i:s:d:m:n:b:l:g:u")) != -1) {
		switch (opt) {
		case 'u': udp = 1; break;
		case 'i': ifname = optarg; break;
		case 's': src = optarg; break;
		case 'd': dst = optarg; break;
		case 'm': mac = optarg; break;
		case 'n': segs = atoi(optarg); break;
		case 'b': bursts = atoi(optarg); break;
		case 'l': payload = atoi(optarg); break;
		case 'g': gap = atoi(optarg); break;
		default: return 2;
		}
	}
	if (!ifname || !src || !dst || !mac || payload <= 0 || payload > 8000) {
		fprintf(stderr, "usage: %s -i IF -s SRC -d DST -m DSTMAC [-u] [-n segs] [-b bursts] [-l payload] [-g gap_us]\n", argv[0]);
		return 2;
	}

	int fd = socket(AF_PACKET, SOCK_RAW, htons(ETH_P_IP));
	if (fd < 0) { perror("socket"); return 1; }
	struct ifreq ifr = {0};
	strncpy(ifr.ifr_name, ifname, IFNAMSIZ - 1);
	if (ioctl(fd, SIOCGIFHWADDR, &ifr) < 0) { perror("SIOCGIFHWADDR"); return 1; }
	struct sockaddr_ll sll = { .sll_family = AF_PACKET, .sll_ifindex = if_nametoindex(ifname),
				   .sll_halen = ETH_ALEN };
	if (sscanf(mac, "%hhx:%hhx:%hhx:%hhx:%hhx:%hhx", &sll.sll_addr[0], &sll.sll_addr[1],
		   &sll.sll_addr[2], &sll.sll_addr[3], &sll.sll_addr[4], &sll.sll_addr[5]) != 6) {
		fprintf(stderr, "bad MAC %s\n", mac);
		return 2;
	}

	size_t l4len = udp ? sizeof(struct udphdr) : sizeof(struct tcphdr);
	size_t flen = sizeof(struct ether_header) + sizeof(struct iphdr) + l4len + payload;
	uint8_t *frame = calloc(1, flen);
	struct ether_header *eth = (void *)frame;
	struct iphdr *ip = (void *)(eth + 1);
	struct tcphdr *tcp = (void *)(ip + 1);
	struct udphdr *uh = (void *)(ip + 1);
	uint8_t *data = (uint8_t *)(ip + 1) + l4len;

	memcpy(eth->ether_dhost, sll.sll_addr, ETH_ALEN);
	memcpy(eth->ether_shost, ifr.ifr_hwaddr.sa_data, ETH_ALEN);
	eth->ether_type = htons(ETH_P_IP);
	ip->version = 4;
	ip->ihl = 5;
	ip->tot_len = htons(sizeof(*ip) + l4len + payload);
	ip->frag_off = htons(IP_DF);
	ip->ttl = 64;
	ip->protocol = udp ? IPPROTO_UDP : IPPROTO_TCP;
	inet_pton(AF_INET, src, &ip->saddr);
	inet_pton(AF_INET, dst, &ip->daddr);
	if (udp) {
		uh->source = htons(40000);
		uh->dest = htons(15299);
		uh->len = htons(l4len + payload);
	} else {
		tcp->source = htons(40000);
		tcp->dest = htons(15299);
		tcp->doff = 5;
		tcp->ack = 1;
		tcp->window = htons(65535);
		tcp->ack_seq = htonl(1);
	}
	for (int i = 0; i < payload; i++)
		data[i] = (uint8_t)i;

	uint32_t seq = 1000, id = 1;
	long sent = 0;
	for (int b = 0; b < bursts; b++) {
		for (int s = 0; s < segs; s++) {
			ip->id = htons(id++);
			ip->check = 0;
			ip->check = csum(ip, sizeof(*ip), 0);
			uint32_t pseudo = 0;
			pseudo += ntohs(ip->saddr & 0xffff) + ntohs(ip->saddr >> 16);
			pseudo += ntohs(ip->daddr & 0xffff) + ntohs(ip->daddr >> 16);
			pseudo += ip->protocol + l4len + payload;
			if (udp) {
				/* Vary the payload so every datagram has its own checksum. */
				memcpy(data, &seq, sizeof(seq));
				seq++;
				uh->check = 0;
				uh->check = csum(uh, l4len + payload, pseudo);
				if (!uh->check)
					uh->check = 0xffff;
			} else {
				tcp->seq = htonl(seq);
				seq += payload;
				tcp->check = 0;
				tcp->check = csum(tcp, l4len + payload, pseudo);
			}
			if (sendto(fd, frame, flen, 0, (struct sockaddr *)&sll, sizeof(sll)) < 0) {
				perror("sendto");
				return 1;
			}
			sent++;
		}
		usleep(gap);
	}
	printf("burst: sent %ld %s frames (%d bursts x %d segs x %d bytes)\n", sent, udp ? "UDP" : "TCP",
	       bursts, segs, payload);
	return 0;
}
