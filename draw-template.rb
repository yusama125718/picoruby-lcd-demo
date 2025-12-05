require 'spi'
require 'gpio'

# --- SPI 初期化（SPI1, 配線に合わせる） ---
spi = SPI.new(
  unit:     :RP2040_SPI1,
  frequency: 40_000_000, # とりあえず 40MHz
  mode:     0,
  sck_pin:  10,          # GP10 (14番ピン) -> SCL
  copi_pin: 11,          # GP11 (15番ピン) -> SDA (MOSI)
  cipo_pin: 8,           # GP8 を SPI1 RX に割り当て（配線しない）
  cs_pin:   13           # GP13 (17番ピン) -> CS
)

dc = GPIO.new(12, GPIO::OUT)  # GP12 (16番ピン) -> DC

# --- ST7789 用ヘルパー ---

def lcd_cmd(spi, dc, val)
  dc.write 0
  spi.select
  spi.write(val)    # 1バイト
  spi.deselect
end

def lcd_data(spi, dc, *vals)
  dc.write 1
  spi.select
  spi.write(*vals)  # 可変長バイト列
  spi.deselect
end

# オフセット（このモジュールは Y=80 スタートの個体が多い）
WIDTH  = 240
HEIGHT = 240
X_OFFSET = 0
Y_OFFSET = 0   # 何も映らなければ 0 にして試す

def set_window(spi, dc, x0, y0, x1, y1)
  x0 += X_OFFSET
  x1 += X_OFFSET
  y0 += Y_OFFSET
  y1 += Y_OFFSET

  # CASET（列範囲）
  lcd_cmd(spi, dc, 0x2A)
  lcd_data(spi, dc,
           (x0 >> 8) & 0xFF, x0 & 0xFF,
           (x1 >> 8) & 0xFF, x1 & 0xFF)

  # RASET（行範囲）
  lcd_cmd(spi, dc, 0x2B)
  lcd_data(spi, dc,
           (y0 >> 8) & 0xFF, y0 & 0xFF,
           (y1 >> 8) & 0xFF, y1 & 0xFF)
end

def lcd_init(spi, dc)
  # ソフトウェアリセット（RESピンは3.3V固定のため）
  lcd_cmd(spi, dc, 0x01)  # SWRESET
  sleep_ms 150

  # スリープ解除
  lcd_cmd(spi, dc, 0x11)  # SLPOUT
  sleep_ms 150

  # 16bitカラー RGB565
  lcd_cmd(spi, dc, 0x3A)  # COLMOD
  lcd_data(spi, dc, 0x55) # 16bit/pixel

  # 画面向き（必要に応じて 0x00,0x60,0xC0,0xA0 を試す）
  lcd_cmd(spi, dc, 0x36)  # MADCTL
  lcd_data(spi, dc, 0x00)

  # 表示ON
  lcd_cmd(spi, dc, 0x29)  # DISPON
  sleep_ms 50
end

# --- テンプレート描画 ---

def draw_hline(spi, dc, x0, x1, y, color)
  return if y < 0 || y >= HEIGHT
  x0, x1 = x1, x0 if x0 > x1
  x0 = 0 if x0 < 0
  x1 = WIDTH - 1 if x1 >= WIDTH
  return if x0 > x1

  set_window(spi, dc, x0, y, x1, y)

  hi = (color >> 8) & 0xFF
  lo = color & 0xFF

  lcd_cmd(spi, dc, 0x2C)

  dc.write 1
  spi.select
  (x1 - x0 + 1).times do
    spi.write(hi, lo)
  end
  spi.deselect
end

def fill_circle(spi, dc, xc, yc, r, color)
  x = 0
  y = r
  d = 3 - 2 * r

  while y >= x
    # 上下対称に 4本の横線で塗る
    draw_hline(spi, dc, xc - x, xc + x, yc + y, color)
    draw_hline(spi, dc, xc - x, xc + x, yc - y, color)
    draw_hline(spi, dc, xc - y, xc + y, yc + x, color)
    draw_hline(spi, dc, xc - y, xc + y, yc - x, color)

    x += 1
    if d > 0
      y -= 1
      d += 4 * (x - y) + 10
    else
      d += 4 * x + 6
    end
  end
end

# 四角形描画
def fill_square(spi, dc, x1, x2, y1, y2, color)
  i = y1

  while i < y2 
    draw_hline(spi, dc, x1, x2, i, color)
    i += 1
  end
end

def fill_color(spi, dc, color)
  set_window(spi, dc, 0, 0, WIDTH - 1, HEIGHT - 1)

  hi = (color >> 8) & 0xFF
  lo = color & 0xFF

  # RAMWR 開始
  lcd_cmd(spi, dc, 0x2C)

  dc.write 1
  spi.select

  # メモリ節約のため、大きなバッファは持たず 1ピクセルずつ送る
  (WIDTH * HEIGHT).times do
    spi.write(hi, lo)
  end

  spi.deselect
end

# --- 動作 ---

interrupt_flag = false
state = 0

# IRQの登録
button = GPIO.new(16, GPIO::IN|GPIO::PULL_UP)
$button_handler = button.irq(GPIO::EDGE_RISE) do |peripheral, event_type|
  interrupt_flag = true
end

lcd_init(spi, dc)
fill_color(spi, dc, 0x0000)

loop do
  IRQ.process

  if interrupt_flag
    interrupt_flag = false
    fill_color(spi, dc, 0x0000)
    case state
    when 0
      state = 1
      fill_circle(spi, dc, 120, 120, 50, 0x07E0)
    when 1
      state = 2
      fill_square(spi, dc, 60, 150, 60, 150, 0xF800)
    when 2
      state = 0
      fill_circle(spi, dc, 120, 120, 50, 0x001F)
    end
  end

  sleep_ms(10)
end