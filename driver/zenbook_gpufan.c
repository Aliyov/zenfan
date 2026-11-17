// zenbook_gpufan - GPU fan full-speed control for ASUS Zenbook UX535QE.
//
// The BIOS "GPU fan" WMI command writes the CPU fan's EC byte (0x30) by
// mistake. The GPU fan's own control byte is EC RAM 0x37; bit 0x40 forces it
// to full speed (verified: 1900 -> 5700 RPM, restores cleanly).
//
//   /proc/zenbook_gpufan   read: 0 = auto, 1 = full speed
//                          write (root): "1" full speed, "0" auto
//
// Safety: loads only on UX535QE and only if EC 0x37 has the known value
// (0x8b / 0xcb). The ONLY write possible is toggling bit 0x40 of 0x37, using
// the BIOS's own ACPI methods (RRAM/WRAM). Unloading restores auto.
//
// NOTE: rewriting the EC fan-curve tables was tried and FAILED (EC stopped
// the fans). Do not add table writes. See experiments/fancurve_FAILED/.
#include <linux/module.h>
#include <linux/acpi.h>
#include <linux/dmi.h>
#include <linux/proc_fs.h>
#include <linux/seq_file.h>
#include <linux/uaccess.h>

#define EC_ADDR   0x37
#define FULL_BIT  0x40
#define BASE_VAL  0x8b

static DEFINE_MUTEX(lock);

static int ec_read37(void)
{
	union acpi_object a[2] = {
		{ .integer = { .type = ACPI_TYPE_INTEGER, .value = 0xCC } },
		{ .integer = { .type = ACPI_TYPE_INTEGER, .value = EC_ADDR } },
	};
	struct acpi_object_list l = { .count = 2, .pointer = a };
	unsigned long long v;

	if (ACPI_FAILURE(acpi_evaluate_integer(NULL, "\\_SB.PCI0.SBRG.EC0.RRAM", &l, &v)) || v > 0xff)
		return -EIO;
	return v;
}

static int set_full(bool on)
{
	union acpi_object a[3] = {
		{ .integer = { .type = ACPI_TYPE_INTEGER, .value = 0xCD } },
		{ .integer = { .type = ACPI_TYPE_INTEGER, .value = EC_ADDR } },
		{ .integer = { .type = ACPI_TYPE_INTEGER, .value = on ? BASE_VAL | FULL_BIT : BASE_VAL } },
	};
	struct acpi_object_list l = { .count = 3, .pointer = a };
	int cur = ec_read37();

	/* never write if the byte is not what we know */
	if (cur < 0 || (cur & ~FULL_BIT) != BASE_VAL)
		return -EINVAL;
	if (ACPI_FAILURE(acpi_evaluate_object(NULL, "\\_SB.PCI0.SBRG.EC0.WRAM", &l, NULL)))
		return -EIO;
	return 0;
}

static int show(struct seq_file *m, void *v)
{
	int cur = ec_read37();

	if (cur < 0)
		return cur;
	seq_printf(m, "%d\n", !!(cur & FULL_BIT));
	return 0;
}

static int open_(struct inode *i, struct file *f) { return single_open(f, show, NULL); }

static ssize_t write_(struct file *f, const char __user *buf, size_t n, loff_t *pos)
{
	char c;
	int rc;

	if (n < 1 || get_user(c, buf))
		return -EFAULT;
	if (c != '0' && c != '1')
		return -EINVAL;
	mutex_lock(&lock);
	rc = set_full(c == '1');
	mutex_unlock(&lock);
	return rc ? rc : n;
}

static const struct proc_ops ops = {
	.proc_open = open_, .proc_read = seq_read, .proc_lseek = seq_lseek,
	.proc_release = single_release, .proc_write = write_,
};

static int __init init_(void)
{
	const char *product = dmi_get_system_info(DMI_PRODUCT_NAME);
	int cur;

	if (!product || !strstr(product, "UX535QE"))
		return -ENODEV;
	cur = ec_read37();
	if (cur < 0 || (cur & ~FULL_BIT) != BASE_VAL) {
		pr_err("zenbook_gpufan: EC 0x37 = %#x, expected 0x8b/0xcb - refusing\n", cur);
		return -ENODEV;
	}
	if (!proc_create("zenbook_gpufan", 0644, NULL, &ops))
		return -ENOMEM;
	pr_info("zenbook_gpufan: ready (EC 0x37 = %#x)\n", cur);
	return 0;
}

static void __exit exit_(void)
{
	remove_proc_entry("zenbook_gpufan", NULL);
	mutex_lock(&lock);
	set_full(false);
	mutex_unlock(&lock);
}

module_init(init_);
module_exit(exit_);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("GPU fan full-speed control for ASUS Zenbook UX535QE");
MODULE_ALIAS("dmi:*:svnASUSTeKCOMPUTERINC.:pnZenbookUX535QE_UM535QE:*");
