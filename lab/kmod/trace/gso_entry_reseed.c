// SPDX-License-Identifier: GPL-2.0
/*
 * Lab equivalent of the production udp-gso-fix livepatch, as a kprobe.
 * mode=0: only count what the fix would change. mode=1: apply the fix.
 * Condition and placement: __skb_udp_tunnel_segment() entry, before uh->check
 * is consumed by the partial checksum adjustment.
 */
#include <linux/module.h>
#include <linux/kprobes.h>
#include <linux/skbuff.h>
#include <linux/ip.h>
#include <linux/ipv6.h>
#include <linux/udp.h>
#include <net/ip6_checksum.h>
#include <net/udp.h>
#include <linux/netdevice.h>
#include <linux/spinlock.h>

static int mode;
module_param(mode, int, 0444);

static atomic64_t match, same, changed;

/* Histogram of every __skb_udp_tunnel_segment() call, keyed by entry state. */
struct hkey {
	char dev[IFNAMSIZ];
	unsigned int gso_type;
	u8 ip_summed, encap, encap_hdr_csum, linear, fraglist, canonical;
	u8 f_partial, f_tso, f_csum, f_sg, f_tnl_csum, f_fraglist;
};
#define NKEYS 64
static struct { struct hkey k; u64 n; u64 segs; } hist[NKEYS];
static int nhist;
static u64 overflow;
static DEFINE_SPINLOCK(hist_lock);

static void record(const struct hkey *k, unsigned int segs)
{
	unsigned long flags;
	int i;

	spin_lock_irqsave(&hist_lock, flags);
	for (i = 0; i < nhist; i++)
		if (!memcmp(&hist[i].k, k, sizeof(*k)))
			break;
	if (i == nhist) {
		if (nhist == NKEYS) {
			overflow++;
			goto out;
		}
		hist[nhist++].k = *k;
	}
	hist[i].n++;
	hist[i].segs += segs;
out:
	spin_unlock_irqrestore(&hist_lock, flags);
}

static int pre(struct kprobe *p, struct pt_regs *regs)
{
	struct sk_buff *skb = (struct sk_buff *)regs->di;
	netdev_features_t f = regs->si;
	struct hkey k = {};
	/* 5th argument: (skb, features, gso_inner_segment, new_protocol, is_ipv6) */
	bool is_ipv6 = regs->r8 & 1;
	struct udphdr *uh = udp_hdr(skb);
	__sum16 check;

	if (is_ipv6) {
		const struct ipv6hdr *ip6h = ipv6_hdr(skb);

		check = ~udp_v6_check(skb->len, &ip6h->saddr, &ip6h->daddr, 0);
	} else {
		const struct iphdr *iph = ip_hdr(skb);

		check = ~udp_v4_check(skb->len, iph->saddr, iph->daddr, 0);
	}
	if (skb->dev)
		strscpy(k.dev, skb->dev->name, IFNAMSIZ);
	k.gso_type = skb_shinfo(skb)->gso_type;
	k.ip_summed = skb->ip_summed;
	k.encap = skb->encapsulation;
	k.encap_hdr_csum = skb->encap_hdr_csum;
	k.linear = !skb->data_len;
	k.fraglist = skb_has_frag_list(skb);
	k.canonical = check == uh->check;
	k.f_partial = !!(f & NETIF_F_GSO_PARTIAL);
	k.f_tso = !!(f & NETIF_F_TSO);
	k.f_csum = !!(f & NETIF_F_CSUM_MASK);
	k.f_sg = !!(f & NETIF_F_SG);
	k.f_tnl_csum = !!(f & NETIF_F_GSO_UDP_TUNNEL_CSUM);
	k.f_fraglist = !!(f & NETIF_F_FRAGLIST);
	record(&k, skb_shinfo(skb)->gso_segs);

	if (!(skb_shinfo(skb)->gso_type & SKB_GSO_UDP_TUNNEL_CSUM) ||
	    !skb->encap_hdr_csum)
		return 0;
	atomic64_inc(&match);
	atomic64_inc(check == uh->check ? &same : &changed);
	if (mode)
		uh->check = check;
	return 0;
}

/*
 * skb_segment() frag_list split decision (6.8.12 net/core/skbuff.c), mirrored
 * for UDP_TUNNEL_CSUM skbs with a frag_list: why a GRO skb was or was not
 * split into several still-GSO skbs.
 */
enum { SPLIT, NO_SG_CSUM, PARTIAL_FEAT, GSO_NOT_OK, MEMBER_LEN, MEMBER_LINEAR, HEAD_LEN, NREASON };
static const char *const reason_name[NREASON] = {
	"split", "no_sg_or_csum", "gso_partial_feature", "net_gso_not_ok",
	"member_len_mismatch", "member_linear", "head_len_mismatch",
};
struct skey {
	u8 reason;
	u16 head_segs, head_frags, member_segs, member_frags, nmembers, last_segs, total_segs;
	u16 head_rem, member_rem;
};
#define NSKEYS 96
static struct { struct skey k; u64 n; } shist[NSKEYS];
static int nshist;
static u64 soverflow, sreason[NREASON];

static int seg_pre(struct kprobe *p, struct pt_regs *regs)
{
	struct sk_buff *head = (struct sk_buff *)regs->di;
	netdev_features_t f = regs->si;
	struct sk_buff *list = skb_shinfo(head)->frag_list, *iter;
	unsigned int mss = skb_shinfo(head)->gso_size, len = head->len, frag_len;
	struct skey k = {};
	unsigned long flags;
	int i;

	if (!list || !(skb_shinfo(head)->gso_type & SKB_GSO_UDP_TUNNEL_CSUM) ||
	    !mss || mss == GSO_BY_FRAGS)
		return 0;

	k.reason = SPLIT;
	if (!(f & NETIF_F_SG) || !(f & NETIF_F_CSUM_MASK))
		k.reason = NO_SG_CSUM;
	else if (f & NETIF_F_GSO_PARTIAL)
		k.reason = PARTIAL_FEAT;
	else if (!net_gso_ok(f, skb_shinfo(head)->gso_type))
		k.reason = GSO_NOT_OK;

	frag_len = list->len;
	skb_walk_frags(head, iter) {
		if (k.reason == SPLIT && frag_len != iter->len && iter->next)
			k.reason = MEMBER_LEN;
		if (k.reason == SPLIT && skb_headlen(iter) && !iter->head_frag)
			k.reason = MEMBER_LINEAR;
		len -= iter->len;
		k.nmembers++;
		k.last_segs = DIV_ROUND_UP(iter->len, mss);
	}
	if (k.reason == SPLIT && len != frag_len)
		k.reason = HEAD_LEN;

	/* len is now the head skb's own payload (data already past headers). */
	k.head_segs = DIV_ROUND_UP(len, mss);
	k.head_rem = len % mss;
	k.head_frags = skb_shinfo(head)->nr_frags;
	k.member_segs = DIV_ROUND_UP(list->len, mss);
	k.member_rem = list->len % mss;
	k.member_frags = skb_shinfo(list)->nr_frags;
	k.total_segs = skb_shinfo(head)->gso_segs;

	spin_lock_irqsave(&hist_lock, flags);
	sreason[k.reason]++;
	for (i = 0; i < nshist; i++)
		if (!memcmp(&shist[i].k, &k, sizeof(k)))
			break;
	if (i == nshist) {
		if (nshist == NSKEYS) {
			soverflow++;
			goto out;
		}
		shist[nshist++].k = k;
	}
	shist[i].n++;
out:
	spin_unlock_irqrestore(&hist_lock, flags);
	return 0;
}

static struct kprobe seg_kp = {
	.symbol_name = "skb_segment",
	.pre_handler = seg_pre,
};

static struct kprobe kp = {
	.symbol_name = "__skb_udp_tunnel_segment",
	.pre_handler = pre,
};

static int __init reseed_init(void)
{
	int ret = register_kprobe(&kp);
	int sret = register_kprobe(&seg_kp);

	/* Never block the run: a missing symbol only disables that probe. */
	pr_info("gso_entry_reseed: loaded mode=%d tunnel_probe=%d segment_probe=%d\n",
		mode, ret, sret);
	if (ret)
		kp.addr = NULL;
	if (sret)
		seg_kp.addr = NULL;
	return 0;
}

static void __exit reseed_exit(void)
{
	int i;

	if (kp.addr)
		unregister_kprobe(&kp);
	if (seg_kp.addr)
		unregister_kprobe(&seg_kp);
	pr_info("gso_entry_reseed: mode=%d match=%lld same=%lld changed=%lld\n",
		mode, atomic64_read(&match), atomic64_read(&same),
		atomic64_read(&changed));
	pr_info("gso_entry_reseed: hist dev gso_type summed encap encap_hdr_csum linear fraglist canonical | features partial tso csum sg tnl_csum fraglist | calls avg_segs\n");
	for (i = 0; i < nhist; i++) {
		const struct hkey *k = &hist[i].k;

		pr_info("gso_entry_reseed: hist %s 0x%x %u %u %u %u %u %u | %u %u %u %u %u %u | %llu %llu\n",
			k->dev, k->gso_type, k->ip_summed, k->encap, k->encap_hdr_csum,
			k->linear, k->fraglist, k->canonical, k->f_partial, k->f_tso,
			k->f_csum, k->f_sg, k->f_tnl_csum, k->f_fraglist,
			hist[i].n, hist[i].segs / hist[i].n);
	}
	pr_info("gso_entry_reseed: hist overflow=%llu\n", overflow);
	for (i = 0; i < NREASON; i++)
		pr_info("gso_entry_reseed: split_reason %s=%llu\n", reason_name[i], sreason[i]);
	pr_info("gso_entry_reseed: shist reason head_segs(rem,frags) member_segs(rem,frags) nmembers last_segs total_segs | count\n");
	for (i = 0; i < nshist; i++) {
		const struct skey *k = &shist[i].k;

		pr_info("gso_entry_reseed: shist %s %u(%u,%u) %u(%u,%u) %u %u %u | %llu\n",
			reason_name[k->reason], k->head_segs, k->head_rem, k->head_frags,
			k->member_segs, k->member_rem, k->member_frags, k->nmembers,
			k->last_segs, k->total_segs, shist[i].n);
	}
	pr_info("gso_entry_reseed: shist overflow=%llu\n", soverflow);
}

module_init(reseed_init);
module_exit(reseed_exit);
MODULE_LICENSE("GPL");
