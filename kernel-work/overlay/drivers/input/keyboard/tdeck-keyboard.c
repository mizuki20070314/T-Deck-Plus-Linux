// SPDX-License-Identifier: GPL-2.0-only
/*
 * LilyGO T-Deck keyboard MCU (I2C address 0x55).
 *
 * The keyboard's ESP32-C3 returns one ASCII character for each key press.
 * Polling follows LilyGO's Keyboard_T_Deck_Master example; returned ASCII is
 * translated to ordinary Linux EV_KEY press/release pairs.
 *
 * The stock firmware sends nothing when the Mic key or the SYM key is pressed
 * on its own, so their state is polled with the raw key-matrix protocol
 * (firmware command 0x03, five column bitmaps) added upstream on 2025-06-12.
 * This driver probes for it and, when available, reports the Mic key as a
 * holdable Ctrl and a standalone SYM press (released without any other key)
 * as Tab. SYM keeps its modifier role: the firmware sends the symbol
 * characters, and Mic stays Ctrl-free while SYM is held so SYM+Mic still
 * produces '0'.
 */

#include <linux/bits.h>
#include <linux/device.h>
#include <linux/i2c.h>
#include <linux/input.h>
#include <linux/jiffies.h>
#include <linux/kernel.h>
#include <linux/module.h>
#include <linux/property.h>
#include <linux/slab.h>
#include <linux/sysfs.h>
#include <linux/workqueue.h>

#define TDECK_KBD_DEFAULT_POLL_MS	10
#define TDECK_KBD_MIN_POLL_MS		5
#define TDECK_KBD_MAX_POLL_MS		100
#define TDECK_KBD_CMD_BACKLIGHT		0x01
#define TDECK_KBD_CMD_BACKLIGHT_DEFAULT	0x02
#define TDECK_KBD_CMD_MODE_RAW		0x03
#define TDECK_KBD_CMD_MODE_KEY		0x04

/* Raw key-matrix geometry from LilyGO's Keyboard_ESP32C3 firmware. */
#define TDECK_KBD_COLS			5
#define TDECK_KBD_ROWS			7
#define TDECK_KBD_SYM_COL		0
#define TDECK_KBD_SYM_ROW		2
#define TDECK_KBD_MIC_COL		0
#define TDECK_KBD_MIC_ROW		6

struct tdeck_key {
	unsigned short code;
	bool shift;
	bool ctrl;
};

struct tdeck_keyboard {
	struct i2c_client *client;
	struct input_dev *input;
	struct delayed_work poll_work;
	unsigned int poll_interval_ms;
	unsigned int backlight;
	unsigned int backlight_default;
	bool raw_matrix;
	bool mic_held;
	bool ctrl_reported;	/* Ctrl state driven by the Mic key */
	bool sym_held;
	bool sym_alone;
	bool sym_tap_pending;
};

static int tdeck_keyboard_send_command(struct tdeck_keyboard *kbd,
				      u8 command, u8 value)
{
	u8 data[] = { command, value };
	int ret = i2c_master_send(kbd->client, data, sizeof(data));

	if (ret < 0)
		return ret;
	return ret == (int)sizeof(data) ? 0 : -EIO;
}

static int tdeck_keyboard_set_mode(struct tdeck_keyboard *kbd, u8 mode)
{
	int ret = i2c_master_send(kbd->client, &mode, sizeof(mode));

	if (ret < 0)
		return ret;
	return ret == (int)sizeof(mode) ? 0 : -EIO;
}

static ssize_t keyboard_backlight_show(struct device *dev,
				       struct device_attribute *attr, char *buf)
{
	struct tdeck_keyboard *kbd = i2c_get_clientdata(to_i2c_client(dev));

	return sysfs_emit(buf, "%u\n", READ_ONCE(kbd->backlight));
}

static ssize_t keyboard_backlight_store(struct device *dev,
					struct device_attribute *attr,
					const char *buf, size_t count)
{
	struct tdeck_keyboard *kbd = i2c_get_clientdata(to_i2c_client(dev));
	unsigned int brightness;
	int ret;

	ret = kstrtouint(buf, 0, &brightness);
	if (ret)
		return ret;
	if (brightness > 255)
		return -ERANGE;
	ret = tdeck_keyboard_send_command(kbd, TDECK_KBD_CMD_BACKLIGHT,
					  brightness);
	if (ret)
		return ret;
	WRITE_ONCE(kbd->backlight, brightness);
	return count;
}
static DEVICE_ATTR_RW(keyboard_backlight);

static ssize_t keyboard_backlight_default_show(struct device *dev,
					       struct device_attribute *attr,
					       char *buf)
{
	struct tdeck_keyboard *kbd = i2c_get_clientdata(to_i2c_client(dev));

	return sysfs_emit(buf, "%u\n", READ_ONCE(kbd->backlight_default));
}

static ssize_t keyboard_backlight_default_store(struct device *dev,
						struct device_attribute *attr,
						const char *buf, size_t count)
{
	struct tdeck_keyboard *kbd = i2c_get_clientdata(to_i2c_client(dev));
	unsigned int brightness;
	int ret;

	ret = kstrtouint(buf, 0, &brightness);
	if (ret)
		return ret;
	if (brightness < 31 || brightness > 255)
		return -ERANGE;
	ret = tdeck_keyboard_send_command(kbd,
					  TDECK_KBD_CMD_BACKLIGHT_DEFAULT,
					  brightness);
	if (ret)
		return ret;
	WRITE_ONCE(kbd->backlight_default, brightness);
	return count;
}
static DEVICE_ATTR_RW(keyboard_backlight_default);

static struct attribute *tdeck_keyboard_attrs[] = {
	&dev_attr_keyboard_backlight.attr,
	&dev_attr_keyboard_backlight_default.attr,
	NULL,
};

static const struct attribute_group tdeck_keyboard_attr_group = {
	.attrs = tdeck_keyboard_attrs,
};

static const unsigned short tdeck_letter_keys[] = {
	KEY_A, KEY_B, KEY_C, KEY_D, KEY_E, KEY_F, KEY_G, KEY_H, KEY_I,
	KEY_J, KEY_K, KEY_L, KEY_M, KEY_N, KEY_O, KEY_P, KEY_Q, KEY_R,
	KEY_S, KEY_T, KEY_U, KEY_V, KEY_W, KEY_X, KEY_Y, KEY_Z,
};

static const unsigned short tdeck_supported_keys[] = {
	KEY_A, KEY_B, KEY_C, KEY_D, KEY_E, KEY_F, KEY_G, KEY_H, KEY_I,
	KEY_J, KEY_K, KEY_L, KEY_M, KEY_N, KEY_O, KEY_P, KEY_Q, KEY_R,
	KEY_S, KEY_T, KEY_U, KEY_V, KEY_W, KEY_X, KEY_Y, KEY_Z,
	KEY_0, KEY_1, KEY_2, KEY_3, KEY_4, KEY_5, KEY_6, KEY_7, KEY_8,
	KEY_9, KEY_SPACE, KEY_ENTER, KEY_BACKSPACE, KEY_TAB, KEY_ESC,
	KEY_GRAVE, KEY_MINUS, KEY_EQUAL, KEY_LEFTBRACE, KEY_RIGHTBRACE,
	KEY_BACKSLASH, KEY_SEMICOLON, KEY_APOSTROPHE, KEY_COMMA, KEY_DOT,
	KEY_SLASH, KEY_LEFTSHIFT, KEY_LEFTCTRL,
};

static bool tdeck_ascii_to_key(u8 ch, struct tdeck_key *key)
{
	key->code = KEY_RESERVED;
	key->shift = false;
	key->ctrl = false;

	if (ch >= 'a' && ch <= 'z') {
		key->code = tdeck_letter_keys[ch - 'a'];
		return true;
	}

	if (ch >= 'A' && ch <= 'Z') {
		key->code = tdeck_letter_keys[ch - 'A'];
		key->shift = true;
		return true;
	}

	if (ch >= '1' && ch <= '9') {
		key->code = KEY_1 + ch - '1';
		return true;
	}

	switch (ch) {
	case '0': key->code = KEY_0; break;
	case ' ': key->code = KEY_SPACE; break;
	case '\t': key->code = KEY_TAB; break;
	case '\r':
	case '\n': key->code = KEY_ENTER; break;
	case '\b':
	case 0x7f: key->code = KEY_BACKSPACE; break;
	case 0x1b: key->code = KEY_ESC; break;
	case '`': key->code = KEY_GRAVE; break;
	case '~': key->code = KEY_GRAVE; key->shift = true; break;
	case '-': key->code = KEY_MINUS; break;
	case '_': key->code = KEY_MINUS; key->shift = true; break;
	case '=': key->code = KEY_EQUAL; break;
	case '+': key->code = KEY_EQUAL; key->shift = true; break;
	case '[': key->code = KEY_LEFTBRACE; break;
	case '{': key->code = KEY_LEFTBRACE; key->shift = true; break;
	case ']': key->code = KEY_RIGHTBRACE; break;
	case '}': key->code = KEY_RIGHTBRACE; key->shift = true; break;
	case '\\': key->code = KEY_BACKSLASH; break;
	case '|': key->code = KEY_BACKSLASH; key->shift = true; break;
	case ';': key->code = KEY_SEMICOLON; break;
	case ':': key->code = KEY_SEMICOLON; key->shift = true; break;
	case '\'': key->code = KEY_APOSTROPHE; break;
	case '"': key->code = KEY_APOSTROPHE; key->shift = true; break;
	case ',': key->code = KEY_COMMA; break;
	case '<': key->code = KEY_COMMA; key->shift = true; break;
	case '.': key->code = KEY_DOT; break;
	case '>': key->code = KEY_DOT; key->shift = true; break;
	case '/': key->code = KEY_SLASH; break;
	case '?': key->code = KEY_SLASH; key->shift = true; break;
	case '!': key->code = KEY_1; key->shift = true; break;
	case '@': key->code = KEY_2; key->shift = true; break;
	case '#': key->code = KEY_3; key->shift = true; break;
	case '$': key->code = KEY_4; key->shift = true; break;
	case '%': key->code = KEY_5; key->shift = true; break;
	case '^': key->code = KEY_6; key->shift = true; break;
	case '&': key->code = KEY_7; key->shift = true; break;
	case '*': key->code = KEY_8; key->shift = true; break;
	case '(': key->code = KEY_9; key->shift = true; break;
	case ')': key->code = KEY_0; key->shift = true; break;
	default:
		/* The C3 firmware uses ASCII control characters for Ctrl+A..Z. */
		if (ch >= 1 && ch <= 26) {
			key->code = tdeck_letter_keys[ch - 1];
			key->ctrl = true;
			break;
		}
		return false;
	}

	return true;
}

static void tdeck_report_key(struct tdeck_keyboard *kbd,
			     struct tdeck_key *key)
{
	/* Ctrl is kept down for as long as the Mic key is held; only a
	 * character's own Ctrl flag (Mic not held) toggles it transiently. */
	bool hold_ctrl = key->ctrl && !kbd->ctrl_reported;

	if (key->shift)
		input_report_key(kbd->input, KEY_LEFTSHIFT, 1);
	if (hold_ctrl)
		input_report_key(kbd->input, KEY_LEFTCTRL, 1);

	input_report_key(kbd->input, key->code, 1);
	input_sync(kbd->input);

	input_report_key(kbd->input, key->code, 0);
	if (hold_ctrl)
		input_report_key(kbd->input, KEY_LEFTCTRL, 0);
	if (key->shift)
		input_report_key(kbd->input, KEY_LEFTSHIFT, 0);
	input_sync(kbd->input);
}

/* Track the Mic and SYM keys from the raw matrix. Mic drives Ctrl while it is
 * held (unless SYM is held, so SYM+Mic keeps producing '0'); a SYM press that
 * ends without any other key or character is reported as Tab. */
static void tdeck_keyboard_update_modifiers(struct tdeck_keyboard *kbd,
					    const u8 *matrix, bool have_char)
{
	bool mic_held = matrix[TDECK_KBD_MIC_COL] & BIT(TDECK_KBD_MIC_ROW);
	bool sym_held = matrix[TDECK_KBD_SYM_COL] & BIT(TDECK_KBD_SYM_ROW);
	bool other_key = false;
	bool want_ctrl;
	int col;

	for (col = 0; col < TDECK_KBD_COLS; col++) {
		u8 mask = matrix[col];

		if (col == TDECK_KBD_SYM_COL)
			mask &= ~BIT(TDECK_KBD_SYM_ROW);
		if (mask)
			other_key = true;
	}

	want_ctrl = mic_held && !sym_held;
	if (want_ctrl != kbd->ctrl_reported) {
		kbd->ctrl_reported = want_ctrl;
		input_report_key(kbd->input, KEY_LEFTCTRL, want_ctrl);
		input_sync(kbd->input);
	}
	kbd->mic_held = mic_held;

	if (sym_held) {
		if (!kbd->sym_held) {
			kbd->sym_held = true;
			kbd->sym_alone = !have_char;
		}
		if (other_key || have_char)
			kbd->sym_alone = false;
	} else if (kbd->sym_held) {
		kbd->sym_held = false;
		if (kbd->sym_alone && !have_char)
			kbd->sym_tap_pending = true;
	}
}

static void tdeck_keyboard_poll(struct work_struct *work)
{
	struct tdeck_keyboard *kbd =
		container_of(to_delayed_work(work), struct tdeck_keyboard,
			     poll_work);
	u8 matrix[TDECK_KBD_COLS];
	struct tdeck_key key;
	u8 value = 0;
	bool have_char = false;

	if (kbd->raw_matrix) {
		int ret;

		tdeck_keyboard_set_mode(kbd, TDECK_KBD_CMD_MODE_KEY);
		ret = i2c_master_recv(kbd->client, &value, sizeof(value));
		/* The firmware answers every key-mode read with one byte, 0x00
		 * when no character is pending; treat 0 as "no character" so a
		 * standalone SYM press still qualifies as Tab. */
		if (ret == (int)sizeof(value) && value)
			have_char = true;

		tdeck_keyboard_set_mode(kbd, TDECK_KBD_CMD_MODE_RAW);
		ret = i2c_master_recv(kbd->client, matrix, sizeof(matrix));
		if (ret == (int)sizeof(matrix))
			tdeck_keyboard_update_modifiers(kbd, matrix, have_char);
		tdeck_keyboard_set_mode(kbd, TDECK_KBD_CMD_MODE_KEY);

		/* A Tab for a standalone SYM press waits one poll so that a
		 * symbol character still in flight cancels it. */
		if (kbd->sym_tap_pending) {
			kbd->sym_tap_pending = false;
			if (!have_char) {
				struct tdeck_key tab = { .code = KEY_TAB };

				tdeck_report_key(kbd, &tab);
			}
		}
	} else {
		int ret = i2c_master_recv(kbd->client, &value, sizeof(value));

		if (ret == (int)sizeof(value))
			have_char = true;
	}

	if (have_char && value && tdeck_ascii_to_key(value, &key)) {
		if (kbd->ctrl_reported)
			key.ctrl = true;
		if (kbd->sym_held)
			kbd->sym_alone = false;
		tdeck_report_key(kbd, &key);
	}

	schedule_delayed_work(&kbd->poll_work,
			      msecs_to_jiffies(kbd->poll_interval_ms));
}

static int tdeck_keyboard_probe(struct i2c_client *client)
{
	struct tdeck_keyboard *kbd;
	unsigned int i;
	u32 poll_interval_ms = TDECK_KBD_DEFAULT_POLL_MS;
	u8 scratch[TDECK_KBD_COLS];
	int ret;

	if (!i2c_check_functionality(client->adapter, I2C_FUNC_I2C))
		return dev_err_probe(&client->dev, -EOPNOTSUPP,
				     "adapter does not support raw I2C\n");

	device_property_read_u32(&client->dev, "poll-interval-ms",
			 &poll_interval_ms);
	if (poll_interval_ms < TDECK_KBD_MIN_POLL_MS ||
	    poll_interval_ms > TDECK_KBD_MAX_POLL_MS)
		return dev_err_probe(&client->dev, -EINVAL,
				     "poll-interval-ms must be between %u and %u\n",
				     TDECK_KBD_MIN_POLL_MS,
				     TDECK_KBD_MAX_POLL_MS);

	kbd = devm_kzalloc(&client->dev, sizeof(*kbd), GFP_KERNEL);
	if (!kbd)
		return -ENOMEM;

	kbd->client = client;
	kbd->poll_interval_ms = poll_interval_ms;
	kbd->backlight_default = 127;
	kbd->input = devm_input_allocate_device(&client->dev);
	if (!kbd->input)
		return -ENOMEM;

	kbd->input->name = "LilyGO T-Deck I2C Keyboard";
	kbd->input->phys = "i2c/tdeck-keyboard";
	kbd->input->id.bustype = BUS_I2C;
	kbd->input->dev.parent = &client->dev;
	for (i = 0; i < ARRAY_SIZE(tdeck_supported_keys); i++)
		input_set_capability(kbd->input, EV_KEY,
				     tdeck_supported_keys[i]);

	i2c_set_clientdata(client, kbd);
	ret = devm_device_add_group(&client->dev, &tdeck_keyboard_attr_group);
	if (ret)
		return dev_err_probe(&client->dev, ret,
				     "failed to add keyboard settings sysfs\n");

	/* Probe for the raw key-matrix protocol (firmware 2025-06-12 and
	 * newer). Without it the Mic and SYM keys cannot be seen on their
	 * own, and the driver falls back to character polling only. */
	tdeck_keyboard_set_mode(kbd, TDECK_KBD_CMD_MODE_RAW);
	ret = i2c_master_recv(client, scratch, sizeof(scratch));
	kbd->raw_matrix = ret == (int)sizeof(scratch);
	tdeck_keyboard_set_mode(kbd, TDECK_KBD_CMD_MODE_KEY);
	dev_info(&client->dev, "raw key-matrix protocol %ssupported\n",
		 kbd->raw_matrix ? "" : "un");

	INIT_DELAYED_WORK(&kbd->poll_work, tdeck_keyboard_poll);
	ret = input_register_device(kbd->input);
	if (ret)
		return ret;

	schedule_delayed_work(&kbd->poll_work,
			      msecs_to_jiffies(kbd->poll_interval_ms));
	dev_info(&client->dev, "keyboard polling every %u ms\n",
		 kbd->poll_interval_ms);

	return 0;
}

static void tdeck_keyboard_remove(struct i2c_client *client)
{
	struct tdeck_keyboard *kbd = i2c_get_clientdata(client);

	cancel_delayed_work_sync(&kbd->poll_work);
}

static const struct of_device_id tdeck_keyboard_of_match[] = {
	{ .compatible = "lilygo,t-deck-keyboard" },
	{ }
};
MODULE_DEVICE_TABLE(of, tdeck_keyboard_of_match);

static const struct i2c_device_id tdeck_keyboard_id[] = {
	{ "tdeck-keyboard", 0 },
	{ }
};
MODULE_DEVICE_TABLE(i2c, tdeck_keyboard_id);

static struct i2c_driver tdeck_keyboard_driver = {
	.driver = {
		.name = "tdeck-keyboard",
		.of_match_table = tdeck_keyboard_of_match,
	},
	.probe = tdeck_keyboard_probe,
	.remove = tdeck_keyboard_remove,
	.id_table = tdeck_keyboard_id,
};
module_i2c_driver(tdeck_keyboard_driver);

MODULE_DESCRIPTION("LilyGO T-Deck I2C keyboard driver");
MODULE_AUTHOR("OpenAI");
MODULE_LICENSE("GPL");
