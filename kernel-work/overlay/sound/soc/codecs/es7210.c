// SPDX-License-Identifier: GPL-2.0-only
/*
 * Everest Semiconductor ES7210 four-channel ADC codec driver.
 *
 * The T-Deck Plus routes the ADC's SDOUT1 pin to I2S1 and uses four-slot
 * TDM. Its populated microphones are MIC1 and MIC3; the I2S CPU DAI extracts
 * those slots and exposes them as a two-channel ALSA capture stream.
 */

#include <linux/delay.h>
#include <linux/i2c.h>
#include <linux/module.h>
#include <linux/regmap.h>

#include <sound/pcm_params.h>
#include <sound/soc.h>
#include <sound/tlv.h>

#define ES7210_RESET_REG		0x00
#define ES7210_CLOCK_OFF_REG		0x01
#define ES7210_MAINCLK_REG		0x02
#define ES7210_LRCK_DIVH_REG		0x04
#define ES7210_LRCK_DIVL_REG		0x05
#define ES7210_POWER_DOWN_REG		0x06
#define ES7210_OSR_REG			0x07
#define ES7210_MODE_CONFIG_REG		0x08
#define ES7210_TIME_CONTROL0_REG	0x09
#define ES7210_TIME_CONTROL1_REG	0x0a
#define ES7210_SDP_INTERFACE1_REG	0x11
#define ES7210_SDP_INTERFACE2_REG	0x12
#define ES7210_ADC34_HPF2_REG		0x20
#define ES7210_ADC34_HPF1_REG		0x21
#define ES7210_ADC12_HPF1_REG		0x22
#define ES7210_ADC12_HPF2_REG		0x23
#define ES7210_ANALOG_REG		0x40
#define ES7210_MIC12_BIAS_REG		0x41
#define ES7210_MIC34_BIAS_REG		0x42
#define ES7210_MIC1_GAIN_REG		0x43
#define ES7210_MIC2_GAIN_REG		0x44
#define ES7210_MIC3_GAIN_REG		0x45
#define ES7210_MIC4_GAIN_REG		0x46
#define ES7210_MIC1_POWER_REG		0x47
#define ES7210_MIC2_POWER_REG		0x48
#define ES7210_MIC3_POWER_REG		0x49
#define ES7210_MIC4_POWER_REG		0x4a
#define ES7210_MIC12_POWER_REG		0x4b
#define ES7210_MIC34_POWER_REG		0x4c

#define ES7210_I2S_WORD_LEN_16		0x60
#define ES7210_I2S_FORMAT_MASK		GENMASK(1, 0)
#define ES7210_I2S_WORD_LEN_MASK	GENMASK(7, 5)
#define ES7210_TDM_I2S_MODE		0x02
#define ES7210_MIC_ENABLE		BIT(4)
#define ES7210_MIC_GAIN_MASK		GENMASK(3, 0)

struct es7210_priv {
	struct regmap *regmap;
	unsigned int sysclk;
	unsigned int dai_fmt;
	bool active;
};

static const DECLARE_TLV_DB_SCALE(es7210_capture_tlv, 0, 300, 0);

static const struct snd_kcontrol_new es7210_controls[] = {
	SOC_SINGLE_TLV("MIC1 Capture Volume", ES7210_MIC1_GAIN_REG, 0, 14, 0,
		       es7210_capture_tlv),
	SOC_SINGLE_TLV("MIC3 Capture Volume", ES7210_MIC3_GAIN_REG, 0, 14, 0,
		       es7210_capture_tlv),
};

static const struct snd_soc_dapm_widget es7210_widgets[] = {
	SND_SOC_DAPM_INPUT("MIC1"),
	SND_SOC_DAPM_INPUT("MIC3"),
	SND_SOC_DAPM_ADC("ADC", "Capture", SND_SOC_NOPM, 0, 0),
};

static const struct snd_soc_dapm_route es7210_routes[] = {
	{ "ADC", NULL, "MIC1" },
	{ "ADC", NULL, "MIC3" },
};

static const struct regmap_config es7210_regmap_config = {
	.reg_bits = 8,
	.val_bits = 8,
	.max_register = ES7210_MIC34_POWER_REG,
	.cache_type = REGCACHE_NONE,
};

static int es7210_set_fmt(struct snd_soc_dai *dai, unsigned int fmt)
{
	struct es7210_priv *es7210 = snd_soc_dai_get_drvdata(dai);

	if ((fmt & SND_SOC_DAIFMT_FORMAT_MASK) != SND_SOC_DAIFMT_I2S)
		return -EINVAL;

	if ((fmt & SND_SOC_DAIFMT_INV_MASK) != SND_SOC_DAIFMT_NB_NF)
		return -EINVAL;

	/* The ESP32-S3 I2S controller supplies MCLK, BCLK and WS. */
	if ((fmt & SND_SOC_DAIFMT_CLOCK_PROVIDER_MASK) !=
	    SND_SOC_DAIFMT_CBC_CFC)
		return -EINVAL;

	es7210->dai_fmt = fmt;
	return 0;
}

static int es7210_set_sysclk(struct snd_soc_dai *dai, int clk_id,
			     unsigned int freq, int dir)
{
	struct es7210_priv *es7210 = snd_soc_dai_get_drvdata(dai);

	if (clk_id || dir != SND_SOC_CLOCK_IN)
		return -EINVAL;

	es7210->sysclk = freq;
	return 0;
}

static int es7210_select_tdeck_mics(struct es7210_priv *es7210)
{
	struct regmap *map = es7210->regmap;
	unsigned int reg;
	int ret;

	/* Start with all four analog inputs disabled, then enable MIC1 and MIC3. */
	ret = regmap_write(map, ES7210_MIC12_POWER_REG, 0xff);
	if (ret)
		return ret;
	ret = regmap_write(map, ES7210_MIC34_POWER_REG, 0xff);
	if (ret)
		return ret;
	for (reg = ES7210_MIC1_GAIN_REG; reg <= ES7210_MIC4_GAIN_REG; reg++) {
		ret = regmap_update_bits(map, reg, ES7210_MIC_ENABLE, 0);
		if (ret)
			return ret;
	}

	/* MIC1 and MIC2 share one bias/ADC power group. */
	ret = regmap_update_bits(map, ES7210_CLOCK_OFF_REG, 0x0b, 0);
	if (ret)
		return ret;
	ret = regmap_write(map, ES7210_MIC12_POWER_REG, 0x00);
	if (ret)
		return ret;
	ret = regmap_update_bits(map, ES7210_MIC1_GAIN_REG,
				 ES7210_MIC_ENABLE, ES7210_MIC_ENABLE);
	if (ret)
		return ret;

	/* MIC3 and MIC4 use the other power group. */
	ret = regmap_update_bits(map, ES7210_CLOCK_OFF_REG, 0x15, 0);
	if (ret)
		return ret;
	ret = regmap_write(map, ES7210_MIC34_POWER_REG, 0x00);
	if (ret)
		return ret;
	return regmap_update_bits(map, ES7210_MIC3_GAIN_REG,
				  ES7210_MIC_ENABLE, ES7210_MIC_ENABLE);
}

static int es7210_hw_params(struct snd_pcm_substream *substream,
			    struct snd_pcm_hw_params *params,
			    struct snd_soc_dai *dai)
{
	struct es7210_priv *es7210 = snd_soc_dai_get_drvdata(dai);
	struct regmap *map = es7210->regmap;
	unsigned int rate = params_rate(params);
	int ret;

	/* The board's microphone example uses 16 kHz, 16-bit data and 4-slot TDM. */
	if (rate != 16000 || params_format(params) != SNDRV_PCM_FORMAT_S16_LE ||
	    params_channels(params) != 2)
		return -EINVAL;

	if (es7210->sysclk && es7210->sysclk != rate * 256)
		return -EINVAL;

	/* ES7210 coefficient set for MCLK=4.096 MHz, LRCK=16 kHz. */
	ret = regmap_write(map, ES7210_CLOCK_OFF_REG, 0x1f);
	if (ret)
		return ret;
	ret = regmap_write(map, ES7210_MAINCLK_REG, 0xc1);
	if (ret)
		return ret;
	ret = regmap_write(map, ES7210_OSR_REG, 0x20);
	if (ret)
		return ret;
	ret = regmap_write(map, ES7210_LRCK_DIVH_REG, 0x01);
	if (ret)
		return ret;
	ret = regmap_write(map, ES7210_LRCK_DIVL_REG, 0x00);
	if (ret)
		return ret;
	ret = regmap_update_bits(map, ES7210_SDP_INTERFACE1_REG,
				 ES7210_I2S_FORMAT_MASK | ES7210_I2S_WORD_LEN_MASK,
				 ES7210_I2S_WORD_LEN_16);
	if (ret)
		return ret;
	ret = regmap_write(map, ES7210_SDP_INTERFACE2_REG,
			   ES7210_TDM_I2S_MODE);
	if (ret)
		return ret;

	/* Use the two populated board microphones in TDM slots 1 and 3. */
	ret = es7210_select_tdeck_mics(es7210);
	if (ret)
		return ret;
	ret = regmap_update_bits(map, ES7210_MIC1_GAIN_REG,
				 ES7210_MIC_GAIN_MASK, 0);
	if (ret)
		return ret;
	ret = regmap_update_bits(map, ES7210_MIC3_GAIN_REG,
				 ES7210_MIC_GAIN_MASK, 14);
	if (ret)
		return ret;

	/* Power up the ADC after the I2S CPU DAI has configured MCLK. */
	ret = regmap_write(map, ES7210_POWER_DOWN_REG, 0x00);
	if (ret)
		return ret;
	ret = regmap_write(map, ES7210_MIC1_POWER_REG, 0x00);
	if (ret)
		return ret;
	ret = regmap_write(map, ES7210_MIC2_POWER_REG, 0xff);
	if (ret)
		return ret;
	ret = regmap_write(map, ES7210_MIC3_POWER_REG, 0x00);
	if (ret)
		return ret;
	ret = regmap_write(map, ES7210_MIC4_POWER_REG, 0xff);
	if (ret)
		return ret;
	ret = regmap_write(map, ES7210_CLOCK_OFF_REG, 0x00);
	if (ret)
		return ret;

	es7210->active = true;
	return 0;
}

static int es7210_power_down(struct es7210_priv *es7210)
{
	int ret;

	if (!es7210->active)
		return 0;

	ret = regmap_write(es7210->regmap, ES7210_MIC1_POWER_REG, 0xff);
	if (ret)
		return ret;
	ret = regmap_write(es7210->regmap, ES7210_MIC2_POWER_REG, 0xff);
	if (ret)
		return ret;
	ret = regmap_write(es7210->regmap, ES7210_MIC3_POWER_REG, 0xff);
	if (ret)
		return ret;
	ret = regmap_write(es7210->regmap, ES7210_MIC4_POWER_REG, 0xff);
	if (ret)
		return ret;
	ret = regmap_write(es7210->regmap, ES7210_MIC12_POWER_REG, 0xff);
	if (ret)
		return ret;
	ret = regmap_write(es7210->regmap, ES7210_MIC34_POWER_REG, 0xff);
	if (ret)
		return ret;
	ret = regmap_write(es7210->regmap, ES7210_CLOCK_OFF_REG, 0x7f);
	if (ret)
		return ret;
	ret = regmap_write(es7210->regmap, ES7210_POWER_DOWN_REG, 0x07);
	if (!ret)
		es7210->active = false;

	return ret;
}

static int es7210_hw_free(struct snd_pcm_substream *substream,
			  struct snd_soc_dai *dai)
{
	struct es7210_priv *es7210 = snd_soc_dai_get_drvdata(dai);

	return es7210_power_down(es7210);
}

static const struct snd_soc_dai_ops es7210_dai_ops = {
	.set_fmt = es7210_set_fmt,
	.set_sysclk = es7210_set_sysclk,
	.hw_params = es7210_hw_params,
	.hw_free = es7210_hw_free,
};

static struct snd_soc_dai_driver es7210_dai = {
	.name = "ES7210 HiFi",
	.capture = {
		.stream_name = "Capture",
		.channels_min = 2,
		.channels_max = 2,
		.rates = SNDRV_PCM_RATE_16000,
		.formats = SNDRV_PCM_FMTBIT_S16_LE,
	},
	.ops = &es7210_dai_ops,
};

static int es7210_component_probe(struct snd_soc_component *component)
{
	struct es7210_priv *es7210 = snd_soc_component_get_drvdata(component);
	int ret;

	snd_soc_component_init_regmap(component, es7210->regmap);

	ret = regmap_write(es7210->regmap, ES7210_RESET_REG, 0xff);
	if (ret)
		goto err_exit_regmap;
	usleep_range(1000, 2000);
	ret = regmap_write(es7210->regmap, ES7210_RESET_REG, 0x41);
	if (ret)
		goto err_exit_regmap;
	ret = regmap_write(es7210->regmap, ES7210_CLOCK_OFF_REG, 0x1f);
	if (ret)
		goto err_exit_regmap;
	ret = regmap_write(es7210->regmap, ES7210_TIME_CONTROL0_REG, 0x30);
	if (ret)
		goto err_exit_regmap;
	ret = regmap_write(es7210->regmap, ES7210_TIME_CONTROL1_REG, 0x30);
	if (ret)
		goto err_exit_regmap;
	ret = regmap_write(es7210->regmap, ES7210_ANALOG_REG, 0xc3);
	if (ret)
		goto err_exit_regmap;
	ret = regmap_write(es7210->regmap, ES7210_MIC12_BIAS_REG, 0x70);
	if (ret)
		goto err_exit_regmap;
	ret = regmap_write(es7210->regmap, ES7210_MIC34_BIAS_REG, 0x70);
	if (ret)
		goto err_exit_regmap;
	ret = regmap_write(es7210->regmap, ES7210_ADC34_HPF2_REG, 0x0a);
	if (ret)
		goto err_exit_regmap;
	ret = regmap_write(es7210->regmap, ES7210_ADC34_HPF1_REG, 0x2a);
	if (ret)
		goto err_exit_regmap;
	ret = regmap_write(es7210->regmap, ES7210_ADC12_HPF1_REG, 0x0a);
	if (ret)
		goto err_exit_regmap;
	ret = regmap_write(es7210->regmap, ES7210_ADC12_HPF2_REG, 0x2a);
	if (ret)
		goto err_exit_regmap;

	return 0;

err_exit_regmap:
	snd_soc_component_exit_regmap(component);
	return ret;
}

static void es7210_component_remove(struct snd_soc_component *component)
{
	struct es7210_priv *es7210 = snd_soc_component_get_drvdata(component);

	if (es7210->active)
		es7210_power_down(es7210);
	snd_soc_component_exit_regmap(component);
}

static const struct snd_soc_component_driver es7210_component_driver = {
	.probe = es7210_component_probe,
	.remove = es7210_component_remove,
	.controls = es7210_controls,
	.num_controls = ARRAY_SIZE(es7210_controls),
	.dapm_widgets = es7210_widgets,
	.num_dapm_widgets = ARRAY_SIZE(es7210_widgets),
	.dapm_routes = es7210_routes,
	.num_dapm_routes = ARRAY_SIZE(es7210_routes),
	.endianness = 1,
};

static int es7210_i2c_probe(struct i2c_client *i2c)
{
	struct es7210_priv *es7210;

	es7210 = devm_kzalloc(&i2c->dev, sizeof(*es7210), GFP_KERNEL);
	if (!es7210)
		return -ENOMEM;

	es7210->regmap = devm_regmap_init_i2c(i2c, &es7210_regmap_config);
	if (IS_ERR(es7210->regmap))
		return dev_err_probe(&i2c->dev, PTR_ERR(es7210->regmap),
				     "failed to initialize regmap\n");

	i2c_set_clientdata(i2c, es7210);

	return devm_snd_soc_register_component(&i2c->dev,
					       &es7210_component_driver,
					       &es7210_dai, 1);
}

static const struct of_device_id es7210_of_match[] = {
	{ .compatible = "everest,es7210" },
	{}
};
MODULE_DEVICE_TABLE(of, es7210_of_match);

static const struct i2c_device_id es7210_i2c_id[] = {
	{ "es7210", 0 },
	{}
};
MODULE_DEVICE_TABLE(i2c, es7210_i2c_id);

static struct i2c_driver es7210_i2c_driver = {
	.driver = {
		.name = "es7210",
		.of_match_table = es7210_of_match,
	},
	.probe = es7210_i2c_probe,
	.id_table = es7210_i2c_id,
};
module_i2c_driver(es7210_i2c_driver);

MODULE_DESCRIPTION("Everest Semiconductor ES7210 audio ADC codec driver");
MODULE_LICENSE("GPL");
