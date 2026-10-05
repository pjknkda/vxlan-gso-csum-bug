// SPDX-License-Identifier: GPL-2.0
/*
 * Microbenchmark: build a VXLAN (IPv4, udpcsum) TCP GSO skb and time
 * skb_gso_segment() on it. Every call goes through __skb_udp_tunnel_segment(),
 * so loaded kprobe/livepatch fixes add their per-call cost here.
 *   encap_hdr=0: fix condition false (fresh tunnel skb)
 *   encap_hdr=1: fix condition true  (re-entry; fix recomputes the seed)
 */
#include <linux/module.h>
#include <linux/skbuff.h>
#include <linux/netdevice.h>
#include <linux/ip.h>
#include <linux/tcp.h>
#include <linux/udp.h>
#include <linux/if_ether.h>
#include <linux/ktime.h>
#include <linux/sort.h>
#include <net/net_namespace.h>
#include <net/gso.h>
#include <net/ip.h>
#include <net/tcp.h>
#include <net/udp.h>

static int iters = 100000, segs = 7, encap_hdr, rounds = 7, alloc_only;
module_param(alloc_only, int, 0444);
module_param(iters, int, 0444);
module_param(segs, int, 0444);
module_param(encap_hdr, int, 0444);
module_param(rounds, int, 0444);

#define MSS 1188
#define OUTER (ETH_HLEN + 20 + 8 + 8)	/* eth ip udp vxlan */
#define HDRS (OUTER + ETH_HLEN + 20 + 20)	/* + inner eth ip tcp */

static u8 *tmpl;
static unsigned int total;

static void build_template(void)
{
	__be32 s = htonl(0x0a16900b), d = htonl(0x0a16906b);
	__be32 is = htonl(0xc6120001), id = htonl(0xc6120002);
	struct iphdr *ip, *iip;
	struct udphdr *uh;
	struct tcphdr *th;
	u8 *p = tmpl;

	memset(p, 0, total);
	memset(p, 0x02, 12);
	*(__be16 *)(p + 12) = htons(ETH_P_IP);
	ip = (void *)(p + ETH_HLEN);
	ip->version = 4; ip->ihl = 5; ip->ttl = 64; ip->protocol = IPPROTO_UDP;
	ip->tot_len = htons(total - ETH_HLEN); ip->saddr = s; ip->daddr = d;
	ip->frag_off = htons(IP_DF);
	ip->check = ip_fast_csum(ip, 5);
	uh = (void *)(ip + 1);
	uh->source = htons(50000); uh->dest = htons(4789);
	uh->len = htons(total - ETH_HLEN - 20);
	uh->check = ~udp_v4_check(total - ETH_HLEN - 20, s, d, 0);
	p[OUTER - 8] = 0x08;			/* VXLAN I flag */
	memset(p + OUTER, 0x04, 12);
	*(__be16 *)(p + OUTER + 12) = htons(ETH_P_IP);
	iip = (void *)(p + OUTER + ETH_HLEN);
	iip->version = 4; iip->ihl = 5; iip->ttl = 64; iip->protocol = IPPROTO_TCP;
	iip->tot_len = htons(total - OUTER - ETH_HLEN); iip->saddr = is; iip->daddr = id;
	iip->frag_off = htons(IP_DF);
	iip->check = ip_fast_csum(iip, 5);
	th = (void *)(iip + 1);
	th->source = htons(40000); th->dest = htons(5201); th->doff = 5; th->ack = 1;
	th->seq = htonl(1); th->window = htons(512);
	th->check = ~tcp_v4_check(total - HDRS + 20, is, id, 0);
}

static struct sk_buff *build_skb_once(struct net_device *dev)
{
	struct sk_buff *skb = alloc_skb(NET_SKB_PAD + total, GFP_KERNEL);

	if (!skb)
		return NULL;
	skb_reserve(skb, NET_SKB_PAD);
	skb_put_data(skb, tmpl, total);
	skb_reset_mac_header(skb);
	skb_set_network_header(skb, ETH_HLEN);
	skb_set_transport_header(skb, ETH_HLEN + 20);
	skb->mac_len = ETH_HLEN;
	skb_set_inner_mac_header(skb, OUTER);
	skb_set_inner_network_header(skb, OUTER + ETH_HLEN);
	skb_set_inner_transport_header(skb, OUTER + ETH_HLEN + 20);
	skb_set_inner_protocol(skb, htons(ETH_P_TEB));
	skb->encapsulation = 1;
	skb->encap_hdr_csum = encap_hdr;
	skb->protocol = htons(ETH_P_IP);
	skb->ip_summed = CHECKSUM_PARTIAL;
	skb->csum_start = skb_inner_transport_header(skb) - skb->head;
	skb->csum_offset = offsetof(struct tcphdr, check);
	skb_shinfo(skb)->gso_size = MSS;
	skb_shinfo(skb)->gso_segs = segs;
	skb_shinfo(skb)->gso_type = SKB_GSO_TCPV4 | SKB_GSO_UDP_TUNNEL_CSUM;
	skb->dev = dev;
	return skb;
}

static int cmp_u64(const void *a, const void *b)
{
	u64 x = *(const u64 *)a, y = *(const u64 *)b;

	return x < y ? -1 : x > y;
}

static int __init bench_init(void)
{
	struct net_device *dev = init_net.loopback_dev;
	netdev_features_t features = NETIF_F_SG | NETIF_F_HW_CSUM;
	u64 *res;
	int r, i;

	if (segs < 2 || segs > 40 || rounds < 1 || rounds > 50)
		return -EINVAL;
	total = HDRS + segs * MSS;
	tmpl = kmalloc(total, GFP_KERNEL);
	res = kcalloc(rounds, sizeof(*res), GFP_KERNEL);
	if (!tmpl || !res)
		goto nomem;
	build_template();

	for (r = 0; r < rounds; r++) {
		u64 t0 = ktime_get_ns();

		for (i = 0; i < iters; i++) {
			struct sk_buff *skb = build_skb_once(dev), *seg;

			if (!skb)
				goto nomem;
			if (alloc_only) {
				consume_skb(skb);
				continue;
			}
			local_bh_disable();
			seg = skb_gso_segment(skb, features);
			local_bh_enable();
			if (IS_ERR_OR_NULL(seg)) {
				pr_err("gso_bench: segmentation failed %ld\n", PTR_ERR(seg));
				kfree_skb(skb);
				goto out;
			}
			kfree_skb_list(seg);
			consume_skb(skb);
			if (!(i & 1023))
				cond_resched();
		}
		res[r] = div_u64(ktime_get_ns() - t0, iters);
	}
	sort(res, rounds, sizeof(*res), cmp_u64, NULL);
	pr_info("gso_bench: alloc_only=%d segs=%d encap_hdr=%d iters=%d rounds=%d ns_per_call min=%llu median=%llu max=%llu\n",
		alloc_only, segs, encap_hdr, iters, rounds, res[0], res[rounds / 2], res[rounds - 1]);
out:
	kfree(res);
	kfree(tmpl);
	return 0;
nomem:
	kfree(res);
	kfree(tmpl);
	return -ENOMEM;
}

static void __exit bench_exit(void)
{
}

module_init(bench_init);
module_exit(bench_exit);
MODULE_LICENSE("GPL");
