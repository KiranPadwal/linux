#include "ops.h"
#include "stdio.h"
#include "io.h"
#include <libfdt.h>
#include "../include/asm/opal-api.h"

/* Global OPAL struct used by opal-call.S */
struct opal {
	u64 base;
	u64 entry;
} opal;

static u32 opal_con_id;

/* Some OPAL calls definitions */
int64_t opal_console_write(int64_t term_number, uint64_t *length,
			   const uint8_t *buffer);
int64_t opal_console_read(int64_t term_number, uint64_t *length,
			  uint8_t *buffer);
int64_t opal_console_write_buffer_space(int64_t term_number,
					uint64_t *length);
int64_t opal_console_flush(int64_t term_number);
int64_t opal_poll_events(uint64_t *outstanding_event_mask);


static int opal_con_open(void)
{
	return 0;
}

static void opal_con_putc(unsigned char c)
{
	int64_t rc;
	uint64_t olen, len;

	do {
		rc = opal_console_write_buffer_space(opal_con_id, &olen);
		len = be64_to_cpu(olen);
		if (rc)
			return;
		opal_poll_events(NULL);
	} while (len < 1);


	olen = cpu_to_be64(1);
	opal_console_write(opal_con_id, &olen, &c);
}

static void opal_con_close(void)
{
	opal_console_flush(opal_con_id);
}

int opal_console_init(void *devp, struct serial_console_data *scdp)
{
	int n;

	if (devp) {
		n = getprop(devp, "reg", &opal_con_id, sizeof(u32));
		if (n != sizeof(u32))
			return -1;
		opal_con_id = be32_to_cpu(opal_con_id);
	} else
		opal_con_id = 0;

	scdp->open = opal_con_open;
	scdp->putc = opal_con_putc;
	scdp->close = opal_con_close;
	return 0;
}

void opal_init(void)
{
	void *opal_node;

	opal_node = finddevice("/ibm,opal");
	if (!opal_node)
		return;
	if (getprop(opal_node, "opal-base-address", &opal.base, sizeof(u64)) < 0)
		return;
	opal.base = be64_to_cpu(opal.base);
	if (getprop(opal_node, "opal-entry-address", &opal.entry, sizeof(u64)) < 0)
		return;
	opal.entry = be64_to_cpu(opal.entry);
}
