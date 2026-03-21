## BACKTESTER — `backtest.py`

Tests trading strategies against real historical data before risking money.

### Install
```
pip install yfinance backtesting pandas numpy
```

### Run
```
python backtest.py
```

### What it tests
- **EMA Crossover (9/21)** — buy when fast EMA crosses above slow EMA
- **RSI Mean Reversion** — buy oversold, sell overbought
- **EMA + RSI Filter** — trend confirmed by EMA, filtered by RSI (usually best)

### Customize
Edit the top of `backtest.py`:
```python
TICKER   = "SPY"    # Try: TSLA, QQQ, AAPL, MSFT, ES=F (futures)
PERIOD   = "6mo"    # 1mo, 3mo, 6mo, 1y, 2y
INTERVAL = "1h"     # 1m, 5m, 15m, 30m, 1h, 1d
CASH     = 25_000   # Starting capital
```

### Output
- Console summary table comparing all strategies
- `backtest_results.html` — interactive chart of the best strategy
