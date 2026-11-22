# 診断用ハーネス（暗転の切り分けに使ったもの。最終のカーネルには入れない）

2026-10-30、最初のビルドで画面が真っ暗だった原因（CS が常時 Low）を探すため、`amoled-qspi-fb.c` と `spi-esp32.c` に一時的に足したもの。
原因を直したあと `overlay\` からは外してある。別のボードで SPI やピンの切り分けをするときの手本として残す。

## `amoled-qspi-fb.c.with-debug`

最終版の `amoled-qspi-fb.c` に、`#if AMOLED_ESP32_DEBUG` で囲んだ診断コードを足したもの（先頭の `#define AMOLED_ESP32_DEBUG 1`）。
使うときは `overlay\drivers\video\fbdev\amoled-qspi-fb.c` を別名で退避してから、これを重ねて `wsl-run-amoled.sh` でビルドする。使い終えたら必ず最終版に戻す（最終版は `patches\0003-*.patch` の中身と同じ）。

`/sys/bus/spi/devices/spi0.0/` に増える属性:

| 属性 | 内容 |
|---|---|
| `regdump` | GPIO9〜14・21・42 の IO_MUX、GPIO マトリクスの出力選択、GPIO と SPI2 のレジスタ、各パッドの現在のレベル |
| `padtest` | 各ピンを High / Low に駆動して読み戻す（ショートやプルの確認）。駆動していないときの読み値は残留電荷で、外付けプルの証拠にならない |
| `cstest` `oe_force` `misc_sweep` `in_connect` `engine_probe` | SPI2 エンジンを手でプログラムする実験。MISC / USER の各ビットが CS のレベルにどう効くか、1MHz の転送で CS・CLK を観察する |
| `cstrace` | 本物のドライバ経由で NOP の書き込みを1回行い、CS / CLK / D0 のレベルを µs 付きで並べる（下の `spi-esp32.c` のフックが必要） |
| `bbinit` `bbcmd` | SPI エンジンを使わず、6本のピンを手で動かして初期化 / 1コマンドを送る（ピンや電源の問題と SPI エンジンの問題の切り分け） |

`scripts\` は、これらの属性を実機で叩いた診断スクリプト（`diag_*.sh`。`scp -O` で `/tmp` に置いて `sh` で実行）。最終版のカーネルでは属性が無いので動かない。

## `spi-esp32.c` に足していたトレース

`cstrace` が使うフック。CS（GPIO9）・CLK（GPIO10）・D0（GPIO11）の入力レベルを、`set_cs` の前後、転送の開始・終了、完了待ちループでサンプルしていた。
`amoled-qspi-fb.c` 側がカーネル内の `ioremap` したGPIO_IN（0x60004000+0x3c）のアドレスを `esp32_spi_dbg_gpio_in` に入れると有効になる。

```c
#include <linux/io.h>
#include <linux/ktime.h>

struct esp32_spi_dbg_event {
	u32 us;
	u8 pins;
	char tag;
};
void __iomem *esp32_spi_dbg_gpio_in;
struct esp32_spi_dbg_event esp32_spi_dbg_ev[128];
unsigned int esp32_spi_dbg_n;

static void esp32_spi_dbg(char tag)
{
	struct esp32_spi_dbg_event *e;
	u8 pins;

	if (!esp32_spi_dbg_gpio_in || esp32_spi_dbg_n >= ARRAY_SIZE(esp32_spi_dbg_ev))
		return;
	pins = (readl(esp32_spi_dbg_gpio_in) >> 9) & 7;
	if (tag == 'w' && esp32_spi_dbg_n &&
	    esp32_spi_dbg_ev[esp32_spi_dbg_n - 1].pins == pins)
		return;
	e = &esp32_spi_dbg_ev[esp32_spi_dbg_n++];
	e->us = ktime_to_us(ktime_get());
	e->pins = pins;
	e->tag = tag;
}
```

呼ぶ場所:

| タグ | 場所 |
|---|---|
| `A` / `D` | `esp32_spi_set_cs()` の先頭（CS を assert / deassert しようとしている） |
| `a` / `d` | `esp32_spi_set_cs()` の末尾（SPI_UPDATE の完了後） |
| `S` / `E` | `esp32_spi_transfer_one()` の `esp32_spi_start_transfer()` の前 / `esp32_spi_wait()` の後 |
| `w` | `esp32_spi_wait_bit()` のループ内（前回と同じレベルなら記録しない） |

正常な1回の書き込みは `A`(CS High) → `a`(CS Low) → `S` → `w`…(CLK が動く) → `E` → `D`(まだ Low) → `d`(CS High) になる。
