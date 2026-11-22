// SPDX-License-Identifier: GPL-2.0-only
/*
 * ESP32-S3 I2S0/I2S1 ALSA driver for the T-Deck Plus.
 *
 * The controller has no CPU-visible sample FIFO. PCM data is moved by GDMA;
 * its descriptor rings therefore live in the small internal-SRAM area that
 * the Core 0 firmware reserves immediately after the Linux exception vectors.
 * Audio sample buffers remain in PSRAM and are synchronized through the DMA
 * API.
 */

#include <linux/bitfield.h>
#include <linux/clk.h>
#include <linux/delay.h>
#include <linux/dma-mapping.h>
#include <linux/gcd.h>
#include <linux/iopoll.h>
#include <linux/irq.h>
#include <linux/interrupt.h>
#include <linux/io.h>
#include <linux/mfd/syscon.h>
#include <linux/module.h>
#include <linux/of.h>
#include <linux/platform_device.h>
#include <linux/regmap.h>
#include <linux/reset.h>
#include <linux/spinlock.h>

#include <sound/memalloc.h>
#include <sound/pcm_params.h>
#include <sound/soc.h>

#define ESP32S3_I2S0_BASE		0x6000f000
#define ESP32S3_I2S1_BASE		0x6002d000
#define ESP32S3_I2S_RX_CONF		0x20
#define ESP32S3_I2S_TX_CONF		0x24
#define ESP32S3_I2S_RX_CONF1		0x28
#define ESP32S3_I2S_TX_CONF1		0x2c
#define ESP32S3_I2S_RX_CLKM_CONF	0x30
#define ESP32S3_I2S_TX_CLKM_CONF	0x34
#define ESP32S3_I2S_RX_CLKM_DIV_CONF	0x38
#define ESP32S3_I2S_TX_CLKM_DIV_CONF	0x3c
#define ESP32S3_I2S_RX_TDM_CTRL		0x50
#define ESP32S3_I2S_TX_TDM_CTRL		0x54
#define ESP32S3_I2S_RXEOF_NUM		0x64

#define ESP32S3_I2S_RESET		BIT(0)
#define ESP32S3_I2S_FIFO_RESET		BIT(1)
#define ESP32S3_I2S_START		BIT(2)
#define ESP32S3_I2S_UPDATE		BIT(8)
#define ESP32S3_I2S_MSB_SHIFT		BIT(29)
#define ESP32S3_I2S_BCK_NO_DLY		BIT(30)
#define ESP32S3_I2S_PCM_BYPASS		BIT(12)
#define ESP32S3_I2S_TDM_EN		BIT(19)

#define ESP32S3_I2S_WS_WIDTH		GENMASK(6, 0)
#define ESP32S3_I2S_BCK_DIV_NUM		GENMASK(12, 7)
#define ESP32S3_I2S_BITS_MOD		GENMASK(17, 13)
#define ESP32S3_I2S_HALF_SAMPLE_BITS	GENMASK(23, 18)
#define ESP32S3_I2S_TDM_CHAN_BITS	GENMASK(28, 24)
#define ESP32S3_I2S_CLKM_DIV_NUM	GENMASK(7, 0)
#define ESP32S3_I2S_CLK_SEL		GENMASK(28, 27)
#define ESP32S3_I2S_CLK_ACTIVE		BIT(26)
#define ESP32S3_I2S_CLK_EN		BIT(29)
#define ESP32S3_I2S_MCLK_SEL		BIT(29)
#define ESP32S3_I2S_DIV_Z		GENMASK(8, 0)
#define ESP32S3_I2S_DIV_Y		GENMASK(17, 9)
#define ESP32S3_I2S_DIV_X		GENMASK(26, 18)
#define ESP32S3_I2S_DIV_YN1		BIT(27)
#define ESP32S3_I2S_RXEOF_MASK		GENMASK(11, 0)
#define ESP32S3_I2S_TDM_CH_MASK		GENMASK(15, 0)
#define ESP32S3_I2S_TDM_CH_NUM		GENMASK(19, 16)

#define ESP32S3_GDMA_CHANNEL_STRIDE	0xc0
#define ESP32S3_GDMA_IN_CONF0(ch)	(0x000 + (ch) * ESP32S3_GDMA_CHANNEL_STRIDE)
#define ESP32S3_GDMA_IN_CONF1(ch)	(0x004 + (ch) * ESP32S3_GDMA_CHANNEL_STRIDE)
#define ESP32S3_GDMA_IN_INT_RAW(ch)	(0x008 + (ch) * ESP32S3_GDMA_CHANNEL_STRIDE)
#define ESP32S3_GDMA_IN_INT_ENA(ch)	(0x010 + (ch) * ESP32S3_GDMA_CHANNEL_STRIDE)
#define ESP32S3_GDMA_IN_INT_CLR(ch)	(0x014 + (ch) * ESP32S3_GDMA_CHANNEL_STRIDE)
#define ESP32S3_GDMA_IN_LINK(ch)	(0x020 + (ch) * ESP32S3_GDMA_CHANNEL_STRIDE)
#define ESP32S3_GDMA_IN_PERI_SEL(ch)	(0x048 + (ch) * ESP32S3_GDMA_CHANNEL_STRIDE)
#define ESP32S3_GDMA_OUT_CONF0(ch)	(0x060 + (ch) * ESP32S3_GDMA_CHANNEL_STRIDE)
#define ESP32S3_GDMA_OUT_CONF1(ch)	(0x064 + (ch) * ESP32S3_GDMA_CHANNEL_STRIDE)
#define ESP32S3_GDMA_OUT_INT_RAW(ch)	(0x068 + (ch) * ESP32S3_GDMA_CHANNEL_STRIDE)
#define ESP32S3_GDMA_OUT_INT_ENA(ch)	(0x070 + (ch) * ESP32S3_GDMA_CHANNEL_STRIDE)
#define ESP32S3_GDMA_OUT_INT_CLR(ch)	(0x074 + (ch) * ESP32S3_GDMA_CHANNEL_STRIDE)
#define ESP32S3_GDMA_OUT_LINK(ch)	(0x080 + (ch) * ESP32S3_GDMA_CHANNEL_STRIDE)
#define ESP32S3_GDMA_OUT_PERI_SEL(ch)	(0x0a8 + (ch) * ESP32S3_GDMA_CHANNEL_STRIDE)
#define ESP32S3_GDMA_MISC_CONF		0x3c8

#define ESP32S3_GDMA_CH_RESET		BIT(0)
#define ESP32S3_GDMA_IN_DSCR_BURST	BIT(2)
#define ESP32S3_GDMA_IN_DATA_BURST	BIT(3)
#define ESP32S3_GDMA_IN_CHECK_OWNER	BIT(12)
#define ESP32S3_GDMA_OUT_AUTO_WRBACK	BIT(2)
#define ESP32S3_GDMA_OUT_EOF_MODE	BIT(3)
#define ESP32S3_GDMA_OUT_DSCR_BURST	BIT(4)
#define ESP32S3_GDMA_OUT_DATA_BURST	BIT(5)
#define ESP32S3_GDMA_OUT_CHECK_OWNER	BIT(12)
#define ESP32S3_GDMA_EXT_MEM_BK_SIZE	GENMASK(14, 13)
#define ESP32S3_GDMA_LINK_ADDR		GENMASK(19, 0)
#define ESP32S3_GDMA_IN_STOP		BIT(21)
#define ESP32S3_GDMA_IN_START		BIT(22)
#define ESP32S3_GDMA_IN_PARK		BIT(24)
#define ESP32S3_GDMA_OUT_STOP		BIT(20)
#define ESP32S3_GDMA_OUT_START		BIT(21)
#define ESP32S3_GDMA_OUT_PARK		BIT(23)
#define ESP32S3_GDMA_CLK_EN		BIT(4)

#define ESP32S3_GDMA_IN_DONE		BIT(0)
#define ESP32S3_GDMA_IN_SUC_EOF		BIT(1)
#define ESP32S3_GDMA_IN_DSCR_ERR	BIT(3)
#define ESP32S3_GDMA_IN_DSCR_EMPTY	BIT(4)
#define ESP32S3_GDMA_IN_FIFO_OVF_L1	BIT(6)
#define ESP32S3_GDMA_OUT_EOF		BIT(1)
#define ESP32S3_GDMA_OUT_DSCR_ERR	BIT(2)
#define ESP32S3_GDMA_OUT_FIFO_ERR	BIT(6)
#define ESP32S3_GDMA_DESC_EOF		BIT(30)
#define ESP32S3_GDMA_DESC_OWNER		BIT(31)

/* In D/IRAM, 0x40380000 (I-bus) aliases 0x3fc90000 (D-bus). GDMA
 * descriptors must be addressed through the D-bus alias. */
#define ESP32S3_IRAM_DRAM_ALIAS_DELTA	0x6f0000
#define ESP32S3_GDMA_DESC_POOL_OFFSET	0x1000
#define ESP32S3_GDMA_DESC_POOL_SIZE	0x1000
#define ESP32S3_GDMA_DESC_POOL_MAGIC	0x54444543 /* "TDEC" */
#define ESP32S3_GDMA_DESC_HEADER_SIZE	0x100
#define ESP32S3_GDMA_DESC_I2S0_OFFSET	0x100
#define ESP32S3_GDMA_DESC_I2S1_OFFSET	0x300
#define ESP32S3_GDMA_DESC_MAX_PERIODS	16
#define ESP32S3_GDMA_DESC_SIZE		12
#define ESP32S3_GDMA_MAX_BUF_LEN		4095
#define ESP32S3_GDMA_EXT_ALIGN		32

#define ESP32S3_PCM_PERIODS_MIN		2
#define ESP32S3_PCM_PERIODS_MAX		16
#define ESP32S3_PCM_PLAYBACK_PERIOD_MAX	4032
#define ESP32S3_PCM_CAPTURE_PERIOD_MAX	1984
#define ESP32S3_PCM_BUFFER_MAX		(ESP32S3_PCM_PLAYBACK_PERIOD_MAX * \
					 ESP32S3_PCM_PERIODS_MAX)

struct esp32s3_gdma_desc {
	u32 control;
	u32 buffer;
	u32 next;
};

struct esp32s3_i2s {
	struct device *dev;
	void __iomem *base;
	struct regmap *gdma;
	void __iomem *desc_pool;
	void __iomem *descs;
	dma_addr_t desc_dma;
	struct clk *i2s_clk;
	struct clk *gdma_clk;
	struct reset_control *reset;
	struct snd_pcm_hardware pcm_hw;
	struct snd_pcm_substream *substream;
	spinlock_t lock;
	void *rx_scratch;
	dma_addr_t rx_scratch_dma;
	size_t rx_scratch_bytes;
	size_t period_bytes;
	size_t dma_period_bytes;
	snd_pcm_uframes_t period_frames;
	snd_pcm_uframes_t buffer_frames;
	unsigned int periods;
	unsigned int period_index;
	unsigned int rate;
	unsigned int requested_mclk;
	unsigned int id;
	unsigned int gdma_channel;
	unsigned int peripheral_id;
	unsigned int tdm_slots;
	int irq;
	bool capture;
	bool running;
};

static u64 esp32s3_i2s_abs_s64(s64 value)
{
	return value < 0 ? -value : value;
}

static int esp32s3_i2s_calc_dividers(unsigned int rate, unsigned int slots,
				     unsigned int slot_width,
				     unsigned int *bck_div,
				     unsigned int *div_int,
				     unsigned int *div_x,
				     unsigned int *div_y,
				     unsigned int *div_z,
				     unsigned int *div_yn1)
{
	const unsigned int source = 160000000;
	unsigned int mclk = rate * 256;
	unsigned int bclk = rate * slots * slot_width;
	unsigned int rem, den, num, best_den = 1, best_num = 0;
	u64 best_err = U64_MAX;

	if (!bclk || mclk % bclk)
		return -EINVAL;
	*bck_div = mclk / bclk;
	if (!*bck_div || *bck_div > 64)
		return -EINVAL;

	*div_int = source / mclk;
	rem = source % mclk;
	if (*div_int < 2 || *div_int > 255)
		return -EINVAL;
	if (!rem) {
		*div_x = 0;
		*div_y = 0;
		*div_z = 0;
		*div_yn1 = 0;
		return 0;
	}

	/* Find the closest fractional divider supported by the 9-bit fields. */
	for (den = 1; den <= 512; den++) {
		u64 scaled = (u64)rem * den;
		u64 rounded = DIV_ROUND_CLOSEST_ULL(scaled, mclk);
		u64 error;

		if (rounded >= den)
			rounded = den - 1;
		num = rounded;
		error = esp32s3_i2s_abs_s64((s64)scaled - (s64)num * mclk);
		if (error * best_den < best_err * den) {
			best_err = error;
			best_num = num;
			best_den = den;
			if (!error)
				break;
		}
	}

	if (!best_num) {
		*div_x = 0;
		*div_y = 0;
		*div_z = 0;
		*div_yn1 = 0;
		return 0;
	}

	den = gcd(best_num, best_den);
	best_num /= den;
	best_den /= den;
	*div_yn1 = best_num * 2 > best_den;
	*div_z = *div_yn1 ? best_den - best_num : best_num;
	if (!*div_z)
		return -EINVAL;
	*div_x = best_den / *div_z - 1;
	*div_y = best_den % *div_z;

	return 0;
}

static void esp32s3_i2s_set_mclk(struct esp32s3_i2s *i2s,
				 unsigned int div_int, unsigned int div_x,
				 unsigned int div_y, unsigned int div_z,
				 unsigned int div_yn1)
{
	unsigned int conf_reg = i2s->capture ? ESP32S3_I2S_RX_CLKM_CONF :
							 ESP32S3_I2S_TX_CLKM_CONF;
	unsigned int div_reg = i2s->capture ?
				       ESP32S3_I2S_RX_CLKM_DIV_CONF :
				       ESP32S3_I2S_TX_CLKM_DIV_CONF;
	u32 conf, frac;

	/* The S3 requires a short divider before changing the fractional fields. */
	conf = readl(i2s->base + conf_reg);
	conf &= ~ESP32S3_I2S_CLKM_DIV_NUM;
	conf |= FIELD_PREP(ESP32S3_I2S_CLKM_DIV_NUM, 2);
	writel(conf, i2s->base + conf_reg);
	writel(FIELD_PREP(ESP32S3_I2S_DIV_Y, 1), i2s->base + div_reg);

	frac = FIELD_PREP(ESP32S3_I2S_DIV_X, div_x) |
	       FIELD_PREP(ESP32S3_I2S_DIV_Y, div_y) |
	       FIELD_PREP(ESP32S3_I2S_DIV_Z, div_z);
	if (div_yn1)
		frac |= ESP32S3_I2S_DIV_YN1;
	writel(frac, i2s->base + div_reg);

	conf = readl(i2s->base + conf_reg);
	conf &= ~(ESP32S3_I2S_CLKM_DIV_NUM | ESP32S3_I2S_CLK_SEL |
		  ESP32S3_I2S_CLK_ACTIVE);
	conf |= FIELD_PREP(ESP32S3_I2S_CLKM_DIV_NUM, div_int) |
		FIELD_PREP(ESP32S3_I2S_CLK_SEL, 2) |
		ESP32S3_I2S_CLK_ACTIVE;
	if (i2s->capture)
		conf |= ESP32S3_I2S_MCLK_SEL;
	else
		conf |= ESP32S3_I2S_CLK_EN;
	writel(conf, i2s->base + conf_reg);
}

static int esp32s3_i2s_update(struct esp32s3_i2s *i2s, unsigned int reg)
{
	u32 val;

	writel(readl(i2s->base + reg) | ESP32S3_I2S_UPDATE,
	       i2s->base + reg);
	return readl_poll_timeout_atomic(i2s->base + reg, val,
					!(val & ESP32S3_I2S_UPDATE), 1, 1000);
}

static void esp32s3_i2s_reset_dir(struct esp32s3_i2s *i2s)
{
	unsigned int reg = i2s->capture ? ESP32S3_I2S_RX_CONF :
						 ESP32S3_I2S_TX_CONF;
	u32 val = readl(i2s->base + reg);

	writel(val | ESP32S3_I2S_RESET | ESP32S3_I2S_FIFO_RESET,
	       i2s->base + reg);
	writel(val & ~(ESP32S3_I2S_RESET | ESP32S3_I2S_FIFO_RESET),
	       i2s->base + reg);
}

static int esp32s3_i2s_configure(struct esp32s3_i2s *i2s,
				 struct snd_pcm_hw_params *params)
{
	unsigned int rate = params_rate(params);
	unsigned int slots = i2s->capture ? i2s->tdm_slots : 2;
	unsigned int slot_width = 16;
	unsigned int bck_div, div_int, div_x, div_y, div_z, div_yn1;
	unsigned int conf_reg, conf1_reg, tdm_reg;
	u32 conf1, tdm, conf;
	int ret;

	if (params_format(params) != SNDRV_PCM_FORMAT_S16_LE ||
	    params_channels(params) != 2)
		return -EINVAL;
	if (i2s->capture && rate != 16000)
		return -EINVAL;
	if (i2s->requested_mclk && i2s->requested_mclk != rate * 256)
		return -EINVAL;

	ret = esp32s3_i2s_calc_dividers(rate, slots, slot_width, &bck_div,
					&div_int, &div_x, &div_y, &div_z,
					&div_yn1);
	if (ret)
		return ret;

	esp32s3_i2s_reset_dir(i2s);
	esp32s3_i2s_set_mclk(i2s, div_int, div_x, div_y, div_z, div_yn1);

	if (i2s->capture) {
		conf_reg = ESP32S3_I2S_RX_CONF;
		conf1_reg = ESP32S3_I2S_RX_CONF1;
		tdm_reg = ESP32S3_I2S_RX_TDM_CTRL;
		conf1 = FIELD_PREP(ESP32S3_I2S_WS_WIDTH,
				   slots * slot_width / 2 - 1) |
			FIELD_PREP(ESP32S3_I2S_BCK_DIV_NUM, bck_div - 1) |
			FIELD_PREP(ESP32S3_I2S_BITS_MOD, 15) |
			FIELD_PREP(ESP32S3_I2S_HALF_SAMPLE_BITS,
				   slots * slot_width / 2 - 1) |
			FIELD_PREP(ESP32S3_I2S_TDM_CHAN_BITS, slot_width - 1) |
			ESP32S3_I2S_MSB_SHIFT;
		tdm = ((1U << slots) - 1) |
		      FIELD_PREP(ESP32S3_I2S_TDM_CH_NUM, slots - 1);
		conf = ESP32S3_I2S_PCM_BYPASS | ESP32S3_I2S_TDM_EN;
	} else {
		conf_reg = ESP32S3_I2S_TX_CONF;
		conf1_reg = ESP32S3_I2S_TX_CONF1;
		tdm_reg = ESP32S3_I2S_TX_TDM_CTRL;
		conf1 = FIELD_PREP(ESP32S3_I2S_WS_WIDTH, slot_width - 1) |
			FIELD_PREP(ESP32S3_I2S_BCK_DIV_NUM, bck_div - 1) |
			FIELD_PREP(ESP32S3_I2S_BITS_MOD, 15) |
			FIELD_PREP(ESP32S3_I2S_HALF_SAMPLE_BITS,
				   slot_width - 1) |
			FIELD_PREP(ESP32S3_I2S_TDM_CHAN_BITS, slot_width - 1) |
			ESP32S3_I2S_MSB_SHIFT | ESP32S3_I2S_BCK_NO_DLY;
		tdm = FIELD_PREP(ESP32S3_I2S_TDM_CH_MASK, 0x03) |
		      FIELD_PREP(ESP32S3_I2S_TDM_CH_NUM, 1);
		conf = ESP32S3_I2S_PCM_BYPASS | ESP32S3_I2S_TDM_EN;
	}

	writel(conf1, i2s->base + conf1_reg);
	writel(tdm, i2s->base + tdm_reg);
	writel(conf, i2s->base + conf_reg);
	ret = esp32s3_i2s_update(i2s, conf_reg);
	if (ret)
		return dev_err_probe(i2s->dev, ret,
				     "I2S configuration update timed out\n");

	i2s->rate = rate;
	return 0;
}

static u32 esp32s3_gdma_reg(struct esp32s3_i2s *i2s, unsigned int base)
{
	return base + i2s->gdma_channel * ESP32S3_GDMA_CHANNEL_STRIDE;
}

static u32 esp32s3_gdma_read(struct esp32s3_i2s *i2s, unsigned int reg)
{
	unsigned int val = 0;

	regmap_read(i2s->gdma, reg, &val);
	return val;
}

static void esp32s3_gdma_write(struct esp32s3_i2s *i2s, unsigned int reg,
			       u32 val)
{
	regmap_write(i2s->gdma, reg, val);
}

static void esp32s3_gdma_reset(struct esp32s3_i2s *i2s)
{
	unsigned int conf0 = i2s->capture ?
		esp32s3_gdma_reg(i2s, ESP32S3_GDMA_IN_CONF0(0)) :
		esp32s3_gdma_reg(i2s, ESP32S3_GDMA_OUT_CONF0(0));
	u32 val = esp32s3_gdma_read(i2s, conf0);

	esp32s3_gdma_write(i2s, conf0, val | ESP32S3_GDMA_CH_RESET);
	esp32s3_gdma_write(i2s, conf0, val & ~ESP32S3_GDMA_CH_RESET);
}

static unsigned int esp32s3_gdma_int_raw_reg(struct esp32s3_i2s *i2s)
{
	return esp32s3_gdma_reg(i2s, i2s->capture ?
				ESP32S3_GDMA_IN_INT_RAW(0) :
				ESP32S3_GDMA_OUT_INT_RAW(0));
}

static unsigned int esp32s3_gdma_int_ena_reg(struct esp32s3_i2s *i2s)
{
	return esp32s3_gdma_reg(i2s, i2s->capture ?
				ESP32S3_GDMA_IN_INT_ENA(0) :
				ESP32S3_GDMA_OUT_INT_ENA(0));
}

static unsigned int esp32s3_gdma_int_clr_reg(struct esp32s3_i2s *i2s)
{
	return esp32s3_gdma_reg(i2s, i2s->capture ?
				ESP32S3_GDMA_IN_INT_CLR(0) :
				ESP32S3_GDMA_OUT_INT_CLR(0));
}

static unsigned int esp32s3_gdma_link_reg(struct esp32s3_i2s *i2s)
{
	return esp32s3_gdma_reg(i2s, i2s->capture ?
				ESP32S3_GDMA_IN_LINK(0) :
				ESP32S3_GDMA_OUT_LINK(0));
}

static void esp32s3_i2s_write_desc(struct esp32s3_i2s *i2s,
				  unsigned int index, dma_addr_t buffer,
				  dma_addr_t next)
{
	void __iomem *desc = i2s->descs + index * ESP32S3_GDMA_DESC_SIZE;
	u32 len = i2s->dma_period_bytes;
	u32 control = ESP32S3_GDMA_DESC_OWNER | len;

	if (!i2s->capture)
		control |= ESP32S3_GDMA_DESC_EOF | (len << 12);

	iowrite32(control, desc);
	iowrite32(lower_32_bits(buffer), desc + 4);
	iowrite32(lower_32_bits(next), desc + 8);
}

static int esp32s3_i2s_prepare_dma(struct esp32s3_i2s *i2s,
				  struct snd_pcm_substream *substream)
{
	struct snd_pcm_runtime *runtime = substream->runtime;
	dma_addr_t buffer_dma;
	size_t pcm_bytes, hardware_buffer_bytes;
	unsigned int i, link_reg, conf0, conf1, peri_reg, int_ena;
	u32 conf0_val, conf1_val;

	i2s->period_frames = runtime->period_size;
	i2s->buffer_frames = runtime->buffer_size;
	i2s->periods = runtime->periods;
	if (i2s->periods < ESP32S3_PCM_PERIODS_MIN ||
	    i2s->periods > ESP32S3_GDMA_DESC_MAX_PERIODS ||
	    !i2s->period_frames ||
	    i2s->buffer_frames != i2s->period_frames * i2s->periods)
		return -EINVAL;

	i2s->period_bytes = frames_to_bytes(runtime, i2s->period_frames);
	if (!IS_ALIGNED(i2s->period_bytes, ESP32S3_GDMA_EXT_ALIGN))
		return -EINVAL;

	pcm_bytes = frames_to_bytes(runtime, i2s->buffer_frames);
	if (i2s->capture) {
		i2s->dma_period_bytes = i2s->period_bytes * 2;
		hardware_buffer_bytes = pcm_bytes * 2;
		if (!i2s->rx_scratch ||
		    hardware_buffer_bytes > i2s->rx_scratch_bytes ||
		    i2s->dma_period_bytes > ESP32S3_GDMA_MAX_BUF_LEN ||
		    i2s->dma_period_bytes / 2 > ESP32S3_I2S_RXEOF_MASK + 1)
			return -EINVAL;
		buffer_dma = i2s->rx_scratch_dma;
		writel(i2s->dma_period_bytes / 2 - 1,
		       i2s->base + ESP32S3_I2S_RXEOF_NUM);
	} else {
		i2s->dma_period_bytes = i2s->period_bytes;
		hardware_buffer_bytes = pcm_bytes;
		if (!runtime->dma_area || !runtime->dma_addr ||
		    i2s->dma_period_bytes > ESP32S3_GDMA_MAX_BUF_LEN)
			return -EINVAL;
		buffer_dma = runtime->dma_addr;
	}
	if (!IS_ALIGNED(buffer_dma, ESP32S3_GDMA_EXT_ALIGN) ||
	    !IS_ALIGNED(i2s->dma_period_bytes, ESP32S3_GDMA_EXT_ALIGN))
		return -EINVAL;

	for (i = 0; i < i2s->periods; i++) {
		dma_addr_t next_dma = i2s->desc_dma +
			((i + 1) % i2s->periods) * ESP32S3_GDMA_DESC_SIZE;

		esp32s3_i2s_write_desc(i2s, i,
				      buffer_dma + i * i2s->dma_period_bytes,
				      next_dma);
	}
	dma_wmb();

	esp32s3_gdma_reset(i2s);
	if (i2s->capture) {
		conf0 = esp32s3_gdma_reg(i2s, ESP32S3_GDMA_IN_CONF0(0));
		conf1 = esp32s3_gdma_reg(i2s, ESP32S3_GDMA_IN_CONF1(0));
		peri_reg = esp32s3_gdma_reg(i2s, ESP32S3_GDMA_IN_PERI_SEL(0));
		link_reg = esp32s3_gdma_link_reg(i2s);
		int_ena = esp32s3_gdma_int_ena_reg(i2s);
		conf0_val = ESP32S3_GDMA_IN_DSCR_BURST |
			    ESP32S3_GDMA_IN_DATA_BURST;
		conf1_val = ESP32S3_GDMA_IN_CHECK_OWNER |
			    FIELD_PREP(ESP32S3_GDMA_EXT_MEM_BK_SIZE, 1);
	} else {
		conf0 = esp32s3_gdma_reg(i2s, ESP32S3_GDMA_OUT_CONF0(0));
		conf1 = esp32s3_gdma_reg(i2s, ESP32S3_GDMA_OUT_CONF1(0));
		peri_reg = esp32s3_gdma_reg(i2s, ESP32S3_GDMA_OUT_PERI_SEL(0));
		link_reg = esp32s3_gdma_link_reg(i2s);
		int_ena = esp32s3_gdma_int_ena_reg(i2s);
		conf0_val = ESP32S3_GDMA_OUT_AUTO_WRBACK |
			    ESP32S3_GDMA_OUT_EOF_MODE |
			    ESP32S3_GDMA_OUT_DSCR_BURST |
			    ESP32S3_GDMA_OUT_DATA_BURST;
		conf1_val = ESP32S3_GDMA_OUT_CHECK_OWNER |
			    FIELD_PREP(ESP32S3_GDMA_EXT_MEM_BK_SIZE, 1);
	}
	esp32s3_gdma_write(i2s, conf0, conf0_val);
	esp32s3_gdma_write(i2s, conf1, conf1_val);
	esp32s3_gdma_write(i2s, peri_reg, i2s->peripheral_id);
	esp32s3_gdma_write(i2s, esp32s3_gdma_int_clr_reg(i2s), 0xffffffff);
	esp32s3_gdma_write(i2s, int_ena, 0);
	esp32s3_gdma_write(i2s, link_reg,
			   lower_32_bits(i2s->desc_dma) & ESP32S3_GDMA_LINK_ADDR);

	i2s->period_index = 0;
	i2s->running = false;
	i2s->substream = substream;
	return 0;
}

static void esp32s3_i2s_rearm_desc(struct esp32s3_i2s *i2s,
				  unsigned int index)
{
	void __iomem *desc = i2s->descs + index * ESP32S3_GDMA_DESC_SIZE;
	u32 control = i2s->dma_period_bytes | ESP32S3_GDMA_DESC_OWNER;

	if (!i2s->capture)
		control |= ESP32S3_GDMA_DESC_EOF |
			   (i2s->dma_period_bytes << 12);
	iowrite32(control, desc);
	dma_wmb();
}

static int esp32s3_i2s_start(struct esp32s3_i2s *i2s,
			     struct snd_pcm_substream *substream)
{
	unsigned int link_reg = esp32s3_gdma_link_reg(i2s);
	unsigned int conf_reg = i2s->capture ? ESP32S3_I2S_RX_CONF :
						ESP32S3_I2S_TX_CONF;
	unsigned int int_mask = i2s->capture ?
		(ESP32S3_GDMA_IN_SUC_EOF | ESP32S3_GDMA_IN_DSCR_ERR |
		 ESP32S3_GDMA_IN_DSCR_EMPTY | ESP32S3_GDMA_IN_FIFO_OVF_L1) :
		(ESP32S3_GDMA_OUT_EOF | ESP32S3_GDMA_OUT_DSCR_ERR |
		 ESP32S3_GDMA_OUT_FIFO_ERR);
	unsigned long flags;
	int ret;

	if (i2s->capture) {
		dma_sync_single_for_device(i2s->dev, i2s->rx_scratch_dma,
					   i2s->dma_period_bytes * i2s->periods,
					   DMA_FROM_DEVICE);
	} else {
		if (substream->runtime->dma_buffer_p)
			snd_dma_buffer_sync(substream->runtime->dma_buffer_p,
					    SNDRV_DMA_SYNC_DEVICE);
	}

	esp32s3_gdma_write(i2s, esp32s3_gdma_int_clr_reg(i2s), 0xffffffff);
	esp32s3_gdma_write(i2s, esp32s3_gdma_int_ena_reg(i2s), int_mask);
	spin_lock_irqsave(&i2s->lock, flags);
	i2s->substream = substream;
	i2s->period_index = 0;
	i2s->running = true;
	spin_unlock_irqrestore(&i2s->lock, flags);

	ret = esp32s3_i2s_update(i2s, conf_reg);
	if (ret) {
		dev_err(i2s->dev, "I2S start update timed out\n");
		return ret;
	}

	/* Start GDMA first so it is listening before the I2S clocks begin. */
	esp32s3_gdma_write(i2s, link_reg,
			   (lower_32_bits(i2s->desc_dma) &
			    ESP32S3_GDMA_LINK_ADDR) |
			   (i2s->capture ? ESP32S3_GDMA_IN_START :
			    ESP32S3_GDMA_OUT_START));
	writel(readl(i2s->base + conf_reg) | ESP32S3_I2S_START,
	       i2s->base + conf_reg);

	return 0;
}

static void esp32s3_i2s_stop(struct esp32s3_i2s *i2s)
{
	unsigned int link_reg = esp32s3_gdma_link_reg(i2s);
	unsigned int conf_reg = i2s->capture ? ESP32S3_I2S_RX_CONF :
						ESP32S3_I2S_TX_CONF;
	unsigned int stop = i2s->capture ? ESP32S3_GDMA_IN_STOP :
					   ESP32S3_GDMA_OUT_STOP;
	unsigned long flags;
	unsigned int poll;
	u32 val;

	spin_lock_irqsave(&i2s->lock, flags);
	i2s->running = false;
	i2s->substream = NULL;
	spin_unlock_irqrestore(&i2s->lock, flags);

	val = readl(i2s->base + conf_reg) & ~ESP32S3_I2S_START;
	writel(val, i2s->base + conf_reg);
	esp32s3_i2s_update(i2s, conf_reg);

	esp32s3_gdma_write(i2s, link_reg,
			   esp32s3_gdma_read(i2s, link_reg) | stop);
	for (poll = 0; poll < 1000; poll++) {
		val = esp32s3_gdma_read(i2s, link_reg);
		if (val & (i2s->capture ? ESP32S3_GDMA_IN_PARK :
			   ESP32S3_GDMA_OUT_PARK))
			break;
		udelay(1);
	}
	esp32s3_gdma_write(i2s, esp32s3_gdma_int_ena_reg(i2s), 0);
	esp32s3_gdma_write(i2s, esp32s3_gdma_int_clr_reg(i2s), 0xffffffff);
	esp32s3_gdma_reset(i2s);
}

static void esp32s3_i2s_copy_tdm_period(struct esp32s3_i2s *i2s,
					struct snd_pcm_runtime *runtime,
					unsigned int index)
{
	u16 *src = i2s->rx_scratch + index * i2s->dma_period_bytes;
	u16 *dst = (u16 *)(runtime->dma_area + index * i2s->period_bytes);
	unsigned int frame;

	/* ES7210 TDM slots are MIC1, MIC2, MIC3, MIC4. Keep MIC1 and MIC3. */
	for (frame = 0; frame < i2s->period_frames; frame++) {
		dst[frame * 2] = src[frame * 4];
		dst[frame * 2 + 1] = src[frame * 4 + 2];
	}
}

static irqreturn_t esp32s3_i2s_dma_irq(int irq, void *data)
{
	struct esp32s3_i2s *i2s = data;
	struct snd_pcm_substream *substream;
	struct snd_pcm_runtime *runtime;
	unsigned long flags;
	unsigned int raw, index;
	bool period_done, error;

	raw = esp32s3_gdma_read(i2s, esp32s3_gdma_int_raw_reg(i2s));
	if (!raw)
		return IRQ_NONE;
	esp32s3_gdma_write(i2s, esp32s3_gdma_int_clr_reg(i2s), raw);

	if (i2s->capture) {
		period_done = raw & ESP32S3_GDMA_IN_SUC_EOF;
		error = raw & (ESP32S3_GDMA_IN_DSCR_ERR |
			       ESP32S3_GDMA_IN_DSCR_EMPTY |
			       ESP32S3_GDMA_IN_FIFO_OVF_L1);
	} else {
		period_done = raw & ESP32S3_GDMA_OUT_EOF;
		error = raw & (ESP32S3_GDMA_OUT_DSCR_ERR |
			       ESP32S3_GDMA_OUT_FIFO_ERR);
	}

	spin_lock_irqsave(&i2s->lock, flags);
	substream = i2s->running ? i2s->substream : NULL;
	index = i2s->period_index;
	if (period_done && substream && i2s->periods)
		i2s->period_index = (index + 1) % i2s->periods;
	spin_unlock_irqrestore(&i2s->lock, flags);

	if (!substream)
		return IRQ_HANDLED;
	if (error) {
		dev_err_ratelimited(i2s->dev, "GDMA channel %u error: %#x\n",
				    i2s->gdma_channel, raw);
		esp32s3_i2s_stop(i2s);
		snd_pcm_stop_xrun(substream);
		return IRQ_HANDLED;
	}
	if (!period_done)
		return IRQ_HANDLED;

	runtime = substream->runtime;
	if (i2s->capture) {
		dma_sync_single_range_for_cpu(i2s->dev, i2s->rx_scratch_dma,
					      index * i2s->dma_period_bytes,
					      i2s->dma_period_bytes,
					      DMA_FROM_DEVICE);
		esp32s3_i2s_copy_tdm_period(i2s, runtime, index);
		dma_sync_single_range_for_device(i2s->dev, i2s->rx_scratch_dma,
						 index * i2s->dma_period_bytes,
						 i2s->dma_period_bytes,
						 DMA_FROM_DEVICE);
		esp32s3_i2s_rearm_desc(i2s, index);
	} else {
		esp32s3_i2s_rearm_desc(i2s, index);
	}

	snd_pcm_period_elapsed(substream);
	return IRQ_HANDLED;
}

static int esp32s3_i2s_set_fmt(struct snd_soc_dai *dai, unsigned int fmt)
{
	if ((fmt & SND_SOC_DAIFMT_FORMAT_MASK) != SND_SOC_DAIFMT_I2S ||
	    (fmt & SND_SOC_DAIFMT_INV_MASK) != SND_SOC_DAIFMT_NB_NF ||
	    (fmt & SND_SOC_DAIFMT_CLOCK_PROVIDER_MASK) !=
	    SND_SOC_DAIFMT_CBP_CFP)
		return -EINVAL;

	return 0;
}

static int esp32s3_i2s_set_sysclk(struct snd_soc_dai *dai, int clk_id,
				 unsigned int freq, int dir)
{
	struct esp32s3_i2s *i2s = snd_soc_dai_get_drvdata(dai);

	if (clk_id || dir != SND_SOC_CLOCK_OUT)
		return -EINVAL;
	i2s->requested_mclk = freq;
	return 0;
}

static int esp32s3_i2s_dai_hw_params(struct snd_pcm_substream *substream,
					    struct snd_pcm_hw_params *params,
					    struct snd_soc_dai *dai)
{
	struct esp32s3_i2s *i2s = snd_soc_dai_get_drvdata(dai);

	return esp32s3_i2s_configure(i2s, params);
}

static const struct snd_soc_dai_ops esp32s3_i2s_dai_ops = {
	.set_fmt = esp32s3_i2s_set_fmt,
	.set_sysclk = esp32s3_i2s_set_sysclk,
	.hw_params = esp32s3_i2s_dai_hw_params,
};

static int esp32s3_pcm_open(struct snd_soc_component *component,
			    struct snd_pcm_substream *substream)
{
	struct esp32s3_i2s *i2s = snd_soc_component_get_drvdata(component);
	int ret;

	if ((i2s->capture && substream->stream != SNDRV_PCM_STREAM_CAPTURE) ||
	    (!i2s->capture && substream->stream != SNDRV_PCM_STREAM_PLAYBACK))
		return -EINVAL;

	snd_soc_set_runtime_hwparams(substream, &i2s->pcm_hw);
	ret = snd_pcm_hw_constraint_step(substream->runtime, 0,
					 SNDRV_PCM_HW_PARAM_PERIOD_BYTES,
					 ESP32S3_GDMA_EXT_ALIGN);
	if (ret)
		return ret;
	substream->runtime->private_data = i2s;
	return 0;
}

static int esp32s3_pcm_close(struct snd_soc_component *component,
			     struct snd_pcm_substream *substream)
{
	struct esp32s3_i2s *i2s = snd_soc_component_get_drvdata(component);

	esp32s3_i2s_stop(i2s);
	synchronize_irq(i2s->irq);
	return 0;
}

static int esp32s3_pcm_prepare(struct snd_soc_component *component,
			       struct snd_pcm_substream *substream)
{
	struct esp32s3_i2s *i2s = snd_soc_component_get_drvdata(component);
	int ret;

	ret = esp32s3_i2s_prepare_dma(i2s, substream);
	if (ret)
		return ret;
	return 0;
}

static int esp32s3_pcm_trigger(struct snd_soc_component *component,
			       struct snd_pcm_substream *substream, int cmd)
{
	struct esp32s3_i2s *i2s = snd_soc_component_get_drvdata(component);

	switch (cmd) {
	case SNDRV_PCM_TRIGGER_START:
	case SNDRV_PCM_TRIGGER_RESUME:
		return esp32s3_i2s_start(i2s, substream);
	case SNDRV_PCM_TRIGGER_STOP:
	case SNDRV_PCM_TRIGGER_SUSPEND:
		esp32s3_i2s_stop(i2s);
		return 0;
	default:
		return -EINVAL;
	}
}

static int esp32s3_pcm_ack(struct snd_soc_component *component,
			   struct snd_pcm_substream *substream)
{
	struct snd_pcm_runtime *runtime = substream->runtime;

	if (!runtime->dma_buffer_p)
		return 0;
	if (substream->stream == SNDRV_PCM_STREAM_PLAYBACK)
		snd_dma_buffer_sync(runtime->dma_buffer_p,
				    SNDRV_DMA_SYNC_DEVICE);
	return 0;
}

static snd_pcm_uframes_t
esp32s3_pcm_pointer(struct snd_soc_component *component,
		    struct snd_pcm_substream *substream)
{
	struct esp32s3_i2s *i2s = snd_soc_component_get_drvdata(component);
	unsigned long flags;
	unsigned int period;

	spin_lock_irqsave(&i2s->lock, flags);
	period = i2s->period_index;
	spin_unlock_irqrestore(&i2s->lock, flags);

	if (!i2s->periods || !i2s->period_frames)
		return 0;
	return (period * i2s->period_frames) % substream->runtime->buffer_size;
}

static int esp32s3_pcm_new(struct snd_soc_component *component,
			   struct snd_soc_pcm_runtime *rtd)
{
	struct esp32s3_i2s *i2s = snd_soc_component_get_drvdata(component);
	int type = i2s->capture ? SNDRV_DMA_TYPE_VMALLOC :
					 SNDRV_DMA_TYPE_NONCOHERENT;
	struct device *dev = i2s->capture ? NULL : i2s->dev;

	return snd_pcm_set_managed_buffer_all(rtd->pcm, type, dev,
					      i2s->pcm_hw.buffer_bytes_max,
					      i2s->pcm_hw.buffer_bytes_max);
}

static const struct snd_soc_component_driver esp32s3_i2s_component = {
	.name = "esp32s3-i2s",
	.open = esp32s3_pcm_open,
	.close = esp32s3_pcm_close,
	.prepare = esp32s3_pcm_prepare,
	.trigger = esp32s3_pcm_trigger,
	.pointer = esp32s3_pcm_pointer,
	.ack = esp32s3_pcm_ack,
	.pcm_new = esp32s3_pcm_new,
	.legacy_dai_naming = 1,
};

static void esp32s3_i2s_free_rx_scratch(void *data)
{
	struct esp32s3_i2s *i2s = data;

	if (i2s->rx_scratch)
		dma_free_noncoherent(i2s->dev, i2s->rx_scratch_bytes,
				     i2s->rx_scratch, i2s->rx_scratch_dma,
				     DMA_FROM_DEVICE);
}

static int esp32s3_i2s_probe(struct platform_device *pdev)
{
	struct device *dev = &pdev->dev;
	struct esp32s3_i2s *i2s;
	struct snd_soc_dai_driver *dai;
	struct resource *res;
	phys_addr_t pool_phys;
	unsigned int tdm_slots;
	int ret;

	i2s = devm_kzalloc(dev, sizeof(*i2s), GFP_KERNEL);
	if (!i2s)
		return -ENOMEM;
	i2s->dev = dev;
	spin_lock_init(&i2s->lock);
	platform_set_drvdata(pdev, i2s);

	res = platform_get_resource(pdev, IORESOURCE_MEM, 0);
	if (!res)
		return -EINVAL;
	if (res->start == ESP32S3_I2S0_BASE) {
		i2s->id = 0;
		i2s->capture = false;
		i2s->gdma_channel = 0;
		i2s->peripheral_id = 3; /* GDMA request ID for I2S0 */
		i2s->tdm_slots = 2;
	} else if (res->start == ESP32S3_I2S1_BASE) {
		i2s->id = 1;
		i2s->capture = true;
		i2s->gdma_channel = 1;
		i2s->peripheral_id = 4; /* GDMA request ID for I2S1 */
		ret = device_property_read_u32(dev, "espressif,rx-tdm-slots",
					       &tdm_slots);
		if (ret || tdm_slots != 4)
			return dev_err_probe(dev, -EINVAL,
					     "I2S1 needs four receive TDM slots\n");
		i2s->tdm_slots = tdm_slots;
	} else {
		return dev_err_probe(dev, -EINVAL, "unexpected I2S register base\n");
	}

	i2s->base = devm_platform_ioremap_resource(pdev, 0);
	if (IS_ERR(i2s->base))
		return PTR_ERR(i2s->base);
	i2s->gdma = syscon_regmap_lookup_by_phandle(dev->of_node,
						    "espressif,gdma-syscon");
	if (IS_ERR(i2s->gdma))
		return dev_err_probe(dev, PTR_ERR(i2s->gdma),
				     "GDMA register map unavailable\n");

	i2s->i2s_clk = devm_clk_get_enabled(dev, "i2s");
	if (IS_ERR(i2s->i2s_clk))
		return dev_err_probe(dev, PTR_ERR(i2s->i2s_clk),
				     "I2S clock unavailable\n");
	i2s->gdma_clk = devm_clk_get_enabled(dev, "gdma");
	if (IS_ERR(i2s->gdma_clk))
		return dev_err_probe(dev, PTR_ERR(i2s->gdma_clk),
				     "GDMA clock unavailable\n");

	i2s->reset = devm_reset_control_get_optional_exclusive(dev, NULL);
	if (IS_ERR(i2s->reset))
		return dev_err_probe(dev, PTR_ERR(i2s->reset),
				     "I2S reset unavailable\n");
	/* The ESP32 reset-simple provider supports assert/deassert, but its
	 * reset pulse op is disabled when reset-us is absent from the SoC DTS. */
	ret = reset_control_assert(i2s->reset);
	if (ret)
		return dev_err_probe(dev, ret, "I2S reset assert failed\n");
	udelay(1);
	ret = reset_control_deassert(i2s->reset);
	if (ret)
		return dev_err_probe(dev, ret, "I2S reset deassert failed\n");

	ret = dma_set_mask_and_coherent(dev, DMA_BIT_MASK(32));
	if (ret)
		return dev_err_probe(dev, ret, "32-bit DMA is unavailable\n");

#ifndef CONFIG_VECTORS_ADDR
	return dev_err_probe(dev, -EINVAL,
			     "kernel has no reserved Linux vector address\n");
#else
	pool_phys = (phys_addr_t)CONFIG_VECTORS_ADDR -
		    ESP32S3_IRAM_DRAM_ALIAS_DELTA +
		    ESP32S3_GDMA_DESC_POOL_OFFSET;
#endif
	i2s->desc_pool = devm_ioremap(dev, pool_phys,
				      ESP32S3_GDMA_DESC_POOL_SIZE);
	if (!i2s->desc_pool)
		return dev_err_probe(dev, -ENOMEM,
				     "cannot map internal GDMA descriptor pool\n");
	if (ioread32(i2s->desc_pool) != ESP32S3_GDMA_DESC_POOL_MAGIC)
		return dev_err_probe(dev, -ENODEV,
				     "firmware has not reserved the GDMA descriptor page\n");

	i2s->descs = i2s->desc_pool + (i2s->id ?
					       ESP32S3_GDMA_DESC_I2S1_OFFSET :
					       ESP32S3_GDMA_DESC_I2S0_OFFSET);
	i2s->desc_dma = pool_phys + (i2s->id ?
					ESP32S3_GDMA_DESC_I2S1_OFFSET :
					ESP32S3_GDMA_DESC_I2S0_OFFSET);

	/* Enable the GDMA clock gate without resetting channels owned by firmware. */
	esp32s3_gdma_write(i2s, ESP32S3_GDMA_MISC_CONF,
			   esp32s3_gdma_read(i2s, ESP32S3_GDMA_MISC_CONF) |
			   ESP32S3_GDMA_CLK_EN);

	if (i2s->capture) {
		i2s->pcm_hw.rates = SNDRV_PCM_RATE_16000;
		i2s->pcm_hw.rate_min = 16000;
		i2s->pcm_hw.rate_max = 16000;
		i2s->pcm_hw.period_bytes_max = ESP32S3_PCM_CAPTURE_PERIOD_MAX;
		i2s->rx_scratch_bytes = i2s->pcm_hw.period_bytes_max *
					ESP32S3_PCM_PERIODS_MAX * 2;
		i2s->rx_scratch = dma_alloc_noncoherent(dev,
						 i2s->rx_scratch_bytes,
						 &i2s->rx_scratch_dma,
						 DMA_FROM_DEVICE, GFP_KERNEL);
		if (!i2s->rx_scratch)
			return dev_err_probe(dev, -ENOMEM,
					     "cannot allocate capture scratch buffer\n");
		ret = devm_add_action_or_reset(dev, esp32s3_i2s_free_rx_scratch,
					       i2s);
		if (ret)
			return ret;
	} else {
		i2s->pcm_hw.rates = SNDRV_PCM_RATE_8000_48000;
		i2s->pcm_hw.rate_min = 8000;
		i2s->pcm_hw.rate_max = 48000;
		i2s->pcm_hw.period_bytes_max = ESP32S3_PCM_PLAYBACK_PERIOD_MAX;
	}
	i2s->pcm_hw.info = SNDRV_PCM_INFO_MMAP |
			   SNDRV_PCM_INFO_MMAP_VALID |
			   SNDRV_PCM_INFO_INTERLEAVED |
			   SNDRV_PCM_INFO_BLOCK_TRANSFER;
	i2s->pcm_hw.formats = SNDRV_PCM_FMTBIT_S16_LE;
	i2s->pcm_hw.channels_min = 2;
	i2s->pcm_hw.channels_max = 2;
	i2s->pcm_hw.period_bytes_min = 256;
	i2s->pcm_hw.periods_min = ESP32S3_PCM_PERIODS_MIN;
	i2s->pcm_hw.periods_max = ESP32S3_PCM_PERIODS_MAX;
	i2s->pcm_hw.buffer_bytes_max = i2s->pcm_hw.period_bytes_max *
				      ESP32S3_PCM_PERIODS_MAX;

	i2s->irq = platform_get_irq(pdev, 0);
	if (i2s->irq < 0)
		return i2s->irq;
	ret = devm_request_threaded_irq(dev, i2s->irq, NULL,
					 esp32s3_i2s_dma_irq, IRQF_ONESHOT,
					 dev_name(dev), i2s);
	if (ret)
		return dev_err_probe(dev, ret, "cannot request GDMA interrupt\n");

	dai = devm_kzalloc(dev, sizeof(*dai), GFP_KERNEL);
	if (!dai)
		return -ENOMEM;
	dai->name = "esp32s3-i2s";
	dai->id = i2s->id;
	dai->ops = &esp32s3_i2s_dai_ops;
	if (i2s->capture) {
		dai->capture.stream_name = "Capture";
		dai->capture.channels_min = 2;
		dai->capture.channels_max = 2;
		dai->capture.rates = SNDRV_PCM_RATE_16000;
		dai->capture.formats = SNDRV_PCM_FMTBIT_S16_LE;
	} else {
		dai->playback.stream_name = "Playback";
		dai->playback.channels_min = 2;
		dai->playback.channels_max = 2;
		dai->playback.rates = SNDRV_PCM_RATE_8000_48000;
		dai->playback.formats = SNDRV_PCM_FMTBIT_S16_LE;
	}

	dev_info(dev, "I2S%u %s, GDMA channel %u, descriptor SRAM %#llx\n",
		 i2s->id, i2s->capture ? "capture" : "playback",
		 i2s->gdma_channel, (unsigned long long)i2s->desc_dma);

	return devm_snd_soc_register_component(dev, &esp32s3_i2s_component,
					      dai, 1);
}

static const struct of_device_id esp32s3_i2s_of_match[] = {
	{ .compatible = "espressif,esp32s3-i2s" },
	{}
};
MODULE_DEVICE_TABLE(of, esp32s3_i2s_of_match);

static struct platform_driver esp32s3_i2s_driver = {
	.probe = esp32s3_i2s_probe,
	.driver = {
		.name = "esp32s3-i2s",
		.of_match_table = esp32s3_i2s_of_match,
	},
};
module_platform_driver(esp32s3_i2s_driver);

MODULE_DESCRIPTION("ESP32-S3 I2S audio driver");
MODULE_LICENSE("GPL");
