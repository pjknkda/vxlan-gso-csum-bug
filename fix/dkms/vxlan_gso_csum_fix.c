// SPDX-License-Identifier: GPL-2.0
/*
 * vxlan_gso_csum_fix: the fix from fix/udp-gso-fix.patch applied at runtime
 * through a kprobe on __skb_udp_tunnel_segment(), for kernels that do not
 * carry the patch. See docs/REPORT.md.
 */
#include <linux/module.h>
#include <linux/kprobes.h>
#include <linux/skbuff.h>
#include <linux/ip.h>
#include <linux/ipv6.h>
#include <net/ip6_checksum.h>
#include <net/udp.h>

static int pre(struct kprobe *p, struct pt_regs *regs)
{
	struct sk_buff *skb = (struct sk_buff *)regs->di;
	/* (skb, features, gso_inner_segment, new_protocol, is_ipv6) */
	bool is_ipv6 = regs->r8 & 1;
	struct udphdr *uh;

	if (!(skb_shinfo(skb)->gso_type & SKB_GSO_UDP_TUNNEL_CSUM) ||
	    !skb->encap_hdr_csum)
		return 0;

	uh = udp_hdr(skb);
	if (is_ipv6) {
		const struct ipv6hdr *ip6h = ipv6_hdr(skb);

		uh->check = ~udp_v6_check(skb->len, &ip6h->saddr, &ip6h->daddr, 0);
	} else {
		const struct iphdr *iph = ip_hdr(skb);

		uh->check = ~udp_v4_check(skb->len, iph->saddr, iph->daddr, 0);
	}
	return 0;
}

static struct kprobe kp = {
	.symbol_name = "__skb_udp_tunnel_segment",
	.pre_handler = pre,
};

static int __init kp_init(void)
{
	int ret = register_kprobe(&kp);

	if (ret) {
		pr_err("vxlan_gso_csum_fix: cannot probe __skb_udp_tunnel_segment (%d)\n", ret);
		return ret;
	}
	pr_info("vxlan_gso_csum_fix: active\n");
	return 0;
}

static void __exit kp_exit(void)
{
	unregister_kprobe(&kp);
	pr_info("vxlan_gso_csum_fix: removed\n");
}

module_init(kp_init);
module_exit(kp_exit);
MODULE_LICENSE("GPL");
MODULE_AUTHOR("Elice Inc.");
MODULE_DESCRIPTION("Fix outer UDP checksum of re-segmented UDP tunnel GSO skbs");
MODULE_VERSION("1.0.0");
