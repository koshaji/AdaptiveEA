# Adaptive Regime EA - Strategy Guide

## Philosophy

This EA is built on one core insight: **markets alternate between trending and ranging regimes, and each regime requires a fundamentally different strategy.** Applying a trend-following strategy in a range (or vice versa) is the primary source of losses for most systematic traders.

The EA detects the current regime and applies the appropriate strategy, while aggressive risk management preserves capital during uncertain conditions.

---

## Architecture

```
┌─────────────────────────────────────────────┐
│              MARKET REGIME DETECTOR          │
│         (ADX + Bollinger Band Width)         │
│                                              │
│   STRONG_TREND │ WEAK_TREND │ RANGING │ VOL  │
└──────┬─────────┴─────┬──────┴────┬────┴──┬───┘
       │               │           │       │
       ▼               ▼           ▼       ▼
┌──────────────┐ ┌──────────┐ ┌────────┐ ┌─────┐
│ TREND FOLLOW │ │ TREND    │ │ MEAN   │ │ NO  │
│ (aggressive) │ │ (cautious│ │ REVERT │ │TRADE│
└──────┬───────┘ └────┬─────┘ └───┬────┘ └─────┘
       │              │           │
       ▼              ▼           ▼
┌─────────────────────────────────────────────┐
│           RISK MANAGEMENT LAYER             │
│  ATR sizing │ Circuit breaker │ Daily limit │
└──────────────────────┬──────────────────────┘
                       ▼
┌─────────────────────────────────────────────┐
│          TRADE MANAGEMENT LAYER             │
│  Partial close │ Trailing stop │ Break-even │
└─────────────────────────────────────────────┘
```

---

## Component Details

### 1. Market Regime Detection

Uses two complementary indicators:

- **ADX (Average Directional Index)** on HTF and MTF:
  - ADX ≥ 40 (both TFs): Strong Trend
  - ADX ≥ 25: Weak/Developing Trend
  - ADX < 25: Ranging Market

- **Bollinger Band Width (BBW)** on MTF:
  - BBW expanding > 1.8x average: Volatile regime (no trade)
  - BBW stable/contracting: Confirms range or calm trend

The regime must be stable across the lookback period to avoid whipsaw during transitions.

### 2. Multi-Timeframe Trend Direction

Three-timeframe EMA alignment (8/21/55):
- **HTF (H4)**: Establishes the dominant trend direction
- **MTF (H1)**: Confirms alignment with HTF
- **LTF (M15)**: Fine-tunes entry timing

Full alignment (Fast > Med > Slow on both HTF+MTF, with slope confirmation) = high-conviction direction.

### 3. Trend Following Strategy (Pullback Entry)

**When:** Strong or Weak Trend regime detected.

**Logic:** Instead of chasing breakouts, waits for pullbacks to dynamic support/resistance (medium EMA), then enters when momentum resumes:

- Price pulls back to/near 21 EMA on MTF
- RSI in pullback zone (not overbought for longs, not oversold for shorts)
- LTF RSI shows momentum shifting back in trend direction
- Price showing recovery candle

**Why this works:** Pullback entries provide better risk/reward than breakout entries. The stop loss is naturally tight (below the pullback low), while the profit target rides the trend.

### 4. Mean Reversion Strategy

**When:** Ranging regime detected.

**Logic:** Fades moves to Bollinger Band extremes with momentum confirmation:

- Price touches/pierces outer Bollinger Band
- RSI at extreme (oversold for buys, overbought for sells)
- Stochastic cross confirms reversal
- Price shows recovery from extreme

**Why this works:** In confirmed ranges, prices oscillate between support and resistance. Band touches with momentum divergence provide high-probability reversal entries. Shorter TP targets (1.5 ATR vs 3.0 ATR) match the ranging environment.

### 5. Risk Management

| Feature | Default | Purpose |
|---------|---------|---------|
| Risk per trade | 1% of balance | Fixed fractional sizing |
| Max total risk | 2% | Caps total exposure |
| ATR-based SL | 2x ATR | Adapts to volatility |
| Daily loss limit | 3% | Prevents tilt trading |
| Max drawdown | 8% | Circuit breaker |
| Max positions | 3 | Diversification cap |
| Max trades/day | 6 | Overtrading prevention |
| Session filter | 02:00-20:00 | Avoids low-liquidity hours |
| Friday cutoff | 16:00 | Reduces weekend gap risk |

### 6. Trade Management

- **Partial Close (50% at 1.5 ATR):** Locks in profit, lets remainder run
- **Break-Even Stop (at 1.0 ATR):** Eliminates risk once trade moves favorably
- **Trailing Stop (1.5 ATR distance):** Captures extended moves in trends
- **Time Exit (100 bars):** Closes stale positions consuming capital

---

## Optimization Guide

### Recommended Backtesting Approach

1. **Out-of-sample testing**: Use walk-forward analysis. Train on 2 years, test on 6 months, repeat.
2. **Multi-symbol testing**: Test on at least 5-6 major pairs to confirm robustness.
3. **Monte Carlo simulation**: Run 1000+ randomized permutations of trade order.

### Parameters to Optimize (in order of importance)

1. **InpATRMultSL (1.5 - 3.0)**: Most impactful. Tighter stops = more trades stopped out. Wider stops = larger losses per trade.
2. **InpATRMultTP (2.0 - 4.0)**: Directly affects reward:risk ratio. Wider TP captures more in trends but wins less often.
3. **InpADXTrendThresh (20 - 30)**: Controls regime classification sensitivity.
4. **InpRiskPercent (0.5 - 2.0)**: Affects compounding speed vs drawdown.
5. **EMA periods**: Keep ratios consistent (fast ~1/3 of slow).

### Parameters to NOT Optimize (overfitting risk)

- RSI exact values (keep defaults)
- Stochastic periods (keep defaults)
- Session hours (use known liquid hours)
- Regime lookback (10 is robust)

### Expected Performance Characteristics

- **Win rate**: 40-55% (trend following has lower win rate, compensated by larger wins)
- **Profit factor**: Target > 1.5
- **Sharpe ratio**: Target > 1.0
- **Max drawdown**: Should stay under 15% with default settings
- **Recovery factor**: Target > 3.0

### Recommended Symbols

Best suited for liquid pairs with clear regime alternation:
- EURUSD, GBPUSD, USDJPY (majors with good trends)
- AUDUSD, NZDUSD (commodity currencies with mean-reversion tendency)
- Gold (XAUUSD) - excellent trend-following candidate

---

## Installation

1. Copy `AdaptiveRegimeEA.mq5` to `MQL5/Experts/`
2. Compile in MetaEditor
3. Attach to chart with desired timeframe (MTF is the primary signal timeframe)
4. Configure inputs as needed
5. Enable AutoTrading

## Risk Disclaimer

Past performance does not guarantee future results. Always test thoroughly in demo before live trading. Start with minimum position sizes and increase gradually as you verify the strategy works with your broker's conditions.
