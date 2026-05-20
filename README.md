# CryptoTickerBar

轻量 macOS 菜单栏工具，用于显示 `BTC/USDT`、`ETH/USDT`、`BNB/USDT`、`SOL/USDT` 现货价格，并在价格触达阈值时发送系统通知。

## 特性

- 原生 AppKit 菜单栏应用，不引入第三方依赖。
- 默认每 15 秒轮询一次公共现货价格接口。
- 支持 BTC/USDT、ETH/USDT、BNB/USDT、SOL/USDT，可同时选择最多 2 个显示在顶栏。
- 支持 OKX、MEXC、Gate.io、Binance 多价格源自动兜底。
- 支持上限、下限阈值通知。
- 阈值和刷新间隔使用 `UserDefaults` 保存。
- 触发通知后有 5 分钟冷却，避免价格持续越线时刷屏。

## 运行

推荐打包成真正的 macOS app 运行，这样通知会以 `CryptoTickerBar` 出现在系统通知设置里：

```bash
chmod +x Scripts/build-app.sh
Scripts/build-app.sh
open .build/CryptoTickerBar.app
```

开发调试也可以直接运行：

```bash
swift run CryptoTickerBar
```

启动后应用会出现在 macOS 顶栏。点击价格文本可以：

- `Fetch Now`：立即刷新。
- `Test Notification`：发送一条测试系统通知。
- `Settings...`：选择顶栏显示币种（最多 2 个）、添加报警规则并设置刷新间隔。
- `Quit`：退出。

## 阈值设置

- 点击 `Alerts` 旁边的 `+` 添加一条报警规则。
- 每条规则单独选择币种、方向（`<=` 或 `>=`）和价格。
- 报警规则不需要对应币种显示在顶栏。例如顶栏显示 BTC/ETH，也可以添加一条 SOL 报警。

触发后会发送 macOS 系统通知，并在顶栏短暂显示 `ALERT`。每条报警规则有 5 分钟冷却时间，避免价格持续越线时一直通知。

如果顶栏显示了 `ALERT` 但没有横幅弹出，优先使用上面的 `.app` 运行方式，然后在 macOS `系统设置 -> 通知 -> CryptoTickerBar` 中允许通知，并把提醒样式设为 `横幅` 或 `提醒`。同时确认没有开启专注模式。改完设置后，可以点击菜单里的 `Test Notification` 立即验证。

如果已经授权但测试通知仍不弹，先退出旧进程，重新打包并打开新 app：

```bash
Scripts/build-app.sh
open .build/CryptoTickerBar.app
```

打包脚本会对 `.app` 做 ad-hoc 签名，避免 macOS 通知系统把未签名 bundle 当成不稳定身份。

## 资源策略

这个工具不使用 WebSocket，也不做后台复杂计算。默认 15 秒一次 HTTPS 请求，`Timer` 设置了容忍时间，让系统可以合并唤醒，降低能耗。如果你希望更低资源占用，可以把刷新间隔调到 30 秒或更高。

## 价格源

价格源按下面顺序自动尝试，某个接口不可达时会继续请求下一个：

- OKX: `https://www.okx.com/api/v5/market/ticker?instId=BTC-USDT`
- MEXC: `https://api.mexc.com/api/v3/ticker/price?symbol=BTCUSDT`
- Gate.io: `https://api.gateio.ws/api/v4/spot/tickers?currency_pair=BTC_USDT`
- Binance: `https://api.binance.com/api/v3/ticker/price?symbol=BTCUSDT`

这些接口都不需要 API key。本工具不读取钱包、不交易，也不保存任何密钥。

## 运行说明

`swift run CryptoTickerBar` 会直接启动一个 SwiftPM 裸可执行文件，不是完整 `.app` bundle。这种方式下 macOS 不一定会给它完整的通知权限入口，所以代码会用 `/usr/bin/osascript` 发送通知作为兜底。`.app` 运行方式会使用 `UNUserNotificationCenter`，系统设置中会出现 `CryptoTickerBar`，通知横幅行为也更可控。
