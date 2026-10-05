// SPDX-License-Identifier: GPL-2.0
/*
 * vxlan_gso_csum_fix: the fix from fix/udp-gso-fix.patch applied at runtime
 * through a kprobe on __skb_udp_tunnel_segment(), for kernels that do not
 * carry the patch. See docs/REPORT.md.
 *
 * Counters (cumulative, read from /sys/module/vxlan_gso_csum_fix/parameters/):
 *   matched            skbs that met the fix condition (checksum recomputed)
 *   corrected          of those, skbs whose outer checksum was actually wrong
 *   corrected_packets  packets (GSO segments) in the corrected skbs
 * Every report_interval seconds (0 = off) the totals are logged if they changed.
 */
#include <linux/module.h>
#include <linux/kprobes.h>
#include <linux/skbuff.h>
#include <linux/ip.h>
#include <linux/ipv6.h>
#include <net/ip6_checksum.h>
#include <net/udp.h>
#include <linux/percpu.h>
#include <linux/workqueue.h>

static DEFINE_PER_CPU(u64, n_matched);
static DEFINE_PER_CPU(u64, n_corrected);
static DEFINE_PER_CPU(u64, n_corrected_packets);

static u64 total(u64 __percpu *counter)
{
	u64 sum = 0;
	int cpu;

	for_each_possible_cpu(cpu)
		sum += *per_cpu_ptr(counter, cpu);
	return sum;
}

#define COUNTER_PARAM(name, counter)						\
	static int get_##name(char *buf, const struct kernel_param *kp)		\
	{									\
		return scnprintf(buf, PAGE_SIZE, "%llu\n", total(&counter));	\
	}									\
	static const struct kernel_param_ops name##_ops = { .get = get_##name };	\
	module_param_cb(name, &name##_ops, NULL, 0444)

COUNTER_PARAM(matched, n_matched);
MODULE_PARM_DESC(matched, "skbs that met the fix condition (read-only)");
COUNTER_PARAM(corrected, n_corrected);
MODULE_PARM_DESC(corrected, "skbs whose outer UDP checksum was wrong and was corrected (read-only)");
COUNTER_PARAM(corrected_packets, n_corrected_packets);
MODULE_PARM_DESC(corrected_packets, "packets (GSO segments) in corrected skbs (read-only)");

static unsigned int report_interval = 60;
module_param(report_interval, uint, 0644);
MODULE_PARM_DESC(report_interval, "seconds between counter reports in the kernel log (0 = off)");

static int pre(struct kprobe *p, struct pt_regs *regs)
{
	struct sk_buff *skb = (struct sk_buff *)regs->di;
	/* (skb, features, gso_inner_segment, new_protocol, is_ipv6) */
	bool is_ipv6 = regs->r8 & 1;
	struct udphdr *uh;
	__sum16 seed;

	if (!(skb_shinfo(skb)->gso_type & SKB_GSO_UDP_TUNNEL_CSUM) ||
	    !skb->encap_hdr_csum)
		return 0;

	uh = udp_hdr(skb);
	if (is_ipv6) {
		const struct ipv6hdr *ip6h = ipv6_hdr(skb);

		seed = ~udp_v6_check(skb->len, &ip6h->saddr, &ip6h->daddr, 0);
	} else {
		const struct iphdr *iph = ip_hdr(skb);

		seed = ~udp_v4_check(skb->len, iph->saddr, iph->daddr, 0);
	}
	/* kprobe handlers run with preemption disabled. */
	this_cpu_inc(n_matched);
	if (uh->check != seed) {
		this_cpu_inc(n_corrected);
		this_cpu_add(n_corrected_packets, skb_shinfo(skb)->gso_segs);
	}
	uh->check = seed;
	return 0;
}

static struct kprobe kp = {
	.symbol_name = "__skb_udp_tunnel_segment",
	.pre_handler = pre,
};

static u64 last_matched, last_corrected, last_packets;

static void log_counters(const char *when)
{
	u64 matched = total(&n_matched), corrected = total(&n_corrected);
	u64 packets = total(&n_corrected_packets);

	pr_info("vxlan_gso_csum_fix: %s: matched=%llu corrected=%llu corrected_packets=%llu (+%llu/+%llu/+%llu)\n",
		when, matched, corrected, packets, matched - last_matched,
		corrected - last_corrected, packets - last_packets);
	last_matched = matched;
	last_corrected = corrected;
	last_packets = packets;
}

static void report(struct work_struct *work);
static DECLARE_DELAYED_WORK(report_work, report);

static void report(struct work_struct *work)
{
	unsigned int interval = READ_ONCE(report_interval);

	if (interval && total(&n_matched) != last_matched)
		log_counters("report");
	/* With reporting off, check again in a minute in case it is turned on. */
	schedule_delayed_work(&report_work, (interval ?: 60) * HZ);
}

static int __init kp_init(void)
{
	int ret = register_kprobe(&kp);

	if (ret) {
		pr_err("vxlan_gso_csum_fix: cannot probe __skb_udp_tunnel_segment (%d)\n", ret);
		return ret;
	}
	pr_info("vxlan_gso_csum_fix: active (report_interval=%us)\n", report_interval);
	schedule_delayed_work(&report_work, (report_interval ?: 60) * HZ);
	return 0;
}

static void __exit kp_exit(void)
{
	unregister_kprobe(&kp);
	cancel_delayed_work_sync(&report_work);
	log_counters("removed");
}

module_init(kp_init);
module_exit(kp_exit);
MODULE_LICENSE("GPL");
MODULE_AUTHOR("Elice Inc.");
MODULE_DESCRIPTION("Fix outer UDP checksum of re-segmented UDP tunnel GSO skbs");
/* Filled in from the git tag by fix/dkms/version.sh when the source is packaged. */
MODULE_VERSION("@VERSION@");
