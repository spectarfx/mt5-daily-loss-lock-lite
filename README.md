# MT5 Daily Loss Lock (Lite)

A small, open-source Expert Advisor for MetaTrader 5 with one job: when your daily loss limit is reached, the trading day locks.

When the lock triggers, it closes open positions, deletes pending orders, and until the next daily reset it closes any new position and deletes any new pending order as soon as it sees them. The lock is stored in terminal global variables, so it survives an EA or terminal restart.

Single file: [`SpectarDailyLossLockLite.mq5`](SpectarDailyLossLockLite.mq5). No DLLs, no web requests, no external links, no hard-coded symbols. Works on hedging and netting accounts.

## What it does

- Captures the start-of-day values at the daily reset (broker **server** time, hour of your choice).
- Computes today's loss, either from equity (closed and floating P/L) or from closed P/L only.
- Compares that loss with your limit: a money amount, a percentage of the start-of-day base, or both (the stricter one applies).
- Acts slightly before the limit if you set a safety buffer.
- On lock: closes positions (optionally only those with a given magic number), deletes pending orders, shows a pop-up alert and keeps the day locked until the next reset.
- Shows an on-chart panel with the start values, today's loss, the limit and the lock state, and warns you when Algo Trading is switched off.

## What it does not do

- It does not open trades (outside the Strategy Tester demo mode described below).
- It does not technically block manual trading. MetaTrader 5 does not allow an Expert Advisor to do that. While locked, the EA closes new positions and deletes new orders as soon as it sees them: on the next tick, trade event or one-second timer.
- It does not know your firm's or broker's own rules. You enter the limit and the reset hour yourself.
- It does not guarantee that your account will never go past the limit (see Limitations).

## How the day-start values are computed

- **Start-of-day balance** is exact: current balance minus every deal booked since the reset (profit, swap, commission and fee), minus deposits and withdrawals since the reset.
- **Start-of-day equity** is only known exactly if the EA is running within five minutes after the reset with no trades since, or if the account has been flat all day (then equity equals balance). Otherwise the EA falls back to the start-of-day balance and says so on the panel.
- Broker credit is removed from equity, because credit is not the trader's money.
- Deposits and withdrawals made today are not counted as profit or loss (switchable).

The base for the percentage limit is either the start-of-day balance or the higher of start-of-day balance and equity.

## Installation

1. In MetaTrader 5 (desktop), open **File > Open Data Folder**, then go to `MQL5\Experts\`.
2. Copy `SpectarDailyLossLockLite.mq5` there.
3. Open it in MetaEditor and press **Compile** (F7). You should get 0 errors.
4. Back in MetaTrader 5, refresh the Navigator, then drag the EA onto **one** chart of the account you want to protect. One instance per account is enough; it watches all symbols.
5. In **Tools > Options > Expert Advisors**, tick "Allow algorithmic trading", and make sure the **Algo Trading** button in the toolbar is green. Without it the EA cannot close anything.
6. Set the inputs to your own numbers. The defaults are only placeholders.

## Inputs

| Input | Meaning |
|---|---|
| Daily loss limit, money | Limit in account currency (0 = off) |
| Daily loss limit, % of base | Limit as a percentage of the base (0 = off) |
| Base for % limit and loss | Start-of-day balance, or the higher of start-of-day balance and equity |
| Safety buffer, % of base | Triggers the lock this much earlier |
| Day reset hour, SERVER time | 0 = server midnight |
| Include floating P/L | On = equity-based; off = closed P/L only |
| Ignore deposits/withdrawals made today | Balance operations are not counted as P/L |
| Close all open positions when lock triggers | On by default |
| Magic filter | 0 = all positions on all symbols |
| Max slippage for closing, points | Deviation allowed on close orders |
| Close/delete retries | Retries on busy/requote |
| Show on-chart panel / Pop-up alert | Display options |
| Strategy Tester only | Opens demo trades in the tester so the lock can be seen; ignored on live and demo accounts |

## Limitations (please read)

- **Floating P/L moves fast.** With floating P/L included, the lock triggers on equity. A fast market can move equity past the limit between two checks.
- **Slippage and gaps.** Closing orders are market orders. A gap or slippage at your broker can close positions at a worse price than the limit.
- **Server midnight.** The day resets at the hour you set, in broker **server** time, not your local time. If your firm or broker resets the day at a different hour, set the reset hour to match, or the EA and your account will measure different days.
- **Start-of-day equity can be an estimate.** If the EA was not running at the reset and positions were open, it uses the start-of-day balance instead (shown on the panel).
- **Desktop only.** An Expert Advisor runs only in the MetaTrader 5 desktop terminal. It does not run in the MetaTrader 5 mobile apps. Trades you place from a phone are handled only while the desktop terminal with this EA is running and connected.
- **The terminal must stay on.** If the computer or VPS sleeps, loses power or loses connection, nothing is checked and nothing is closed.
- **Not a manual-trading block.** See "What it does not do".
- Always test on a demo account first.

## License

MIT. See [LICENSE](LICENSE).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

---

Spectar FX also offers a gold trading service: https://spectarfx.com/gh

Free hosted build, guide and calculator: https://spectarfx.com/gh

Trading involves high risk of loss. Service only - no signals, no advice.
