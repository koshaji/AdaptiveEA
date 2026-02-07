# AdaptiveRegimeEA v5.0 - Optimal Settings Guide

## Quick Start: Recommended Settings for Live Trading

### Conservative Profile (Recommended for beginners)
```
=== Risk Management ===
InpRiskPercent = 0.75           // Start lower until proven
InpUseKellyCriterion = false    // Wait for 50+ trades first
InpKellyFraction = 0.25         // Quarter-Kelly when enabled
InpMaxRiskPercent = 2.5
InpMaxDailyLossPct = 2.0        // Tighter than default
InpMaxDrawdownPct = 8.0

=== Trade Management ===
InpUsePartialClose = false      // Keep it simple initially
InpUseTrailingStop = true
InpUseDynamicTrail = true
InpUseBreakEven = true

=== Filters ===
InpMaxSpreadCostPct = 3.0       // Very strict
InpMaxSpreadCostMR = 2.0        // Very strict
InpMinTradeQuality = 0.65       // Higher threshold
```

### Aggressive Profile (After 100+ profitable trades)
```
=== Risk Management ===
InpRiskPercent = 1.5            // Higher base
InpUseKellyCriterion = true     // Let Kelly optimize
InpKellyFraction = 0.30         // Slightly more aggressive
InpMaxRiskPercent = 4.0
InpMaxDailyLossPct = 3.0
InpMaxDrawdownPct = 10.0

=== Trade Management ===
InpUsePartialClose = true
InpPartialClosePct = 30.0
InpPartialCloseATR = 2.5
InpPartialOnlyStrong = true     // Only in strong trends
InpUseTrailingStop = true
InpUseDynamicTrail = true
InpTrailATRMult = 1.0

=== Filters ===
InpMaxSpreadCostPct = 5.0
InpMaxSpreadCostMR = 3.0
InpMinTradeQuality = 0.60       // Let more trades through
```

### Balanced Profile (Default v5.0 - Best Starting Point)
```
=== Risk Management ===
InpRiskPercent = 1.0
InpUseKellyCriterion = true
InpKellyFraction = 0.25
InpMaxRiskPercent = 3.0
InpMaxDailyLossPct = 3.0
InpMaxDrawdownPct = 10.0

=== Trade Management ===
InpUsePartialClose = true
InpPartialClosePct = 30.0
InpPartialCloseATR = 2.5
InpPartialOnlyStrong = true
InpUseTrailingStop = true
InpUseDynamicTrail = true
InpTrailATRMult = 1.0
InpUseBreakEven = true
InpBreakEvenATR = 0.8

=== Filters ===
InpMaxSpreadCostPct = 5.0
InpMaxSpreadCostMR = 3.0
InpMinTradeQuality = 0.60
```

---

## Settings by Trading Style

### Scalper (High Frequency)
```
InpMinTradeQuality = 0.55       // Lower quality threshold
InpMaxSpreadCostPct = 2.0       // Very tight spread control
InpMaxSpreadCostMR = 1.5
InpUsePartialClose = false      // Get in and out fast
InpATRMultSL = 1.2              // Tighter stops
InpATRMultTP = 3.6              // Maintain 3:1
InpMR_ATRSL = 0.8
InpMR_ATRTP = 1.6
```

### Swing Trader (Position Holding)
```
InpMinTradeQuality = 0.70       // Only best setups
InpMaxSpreadCostPct = 7.0       // More tolerance
InpUsePartialClose = true
InpPartialClosePct = 25.0       // Take less off
InpUseTrailingStop = true
InpUseDynamicTrail = true
InpATRMultSL = 2.0              // Wider stops
InpATRMultTP = 6.0              // 3:1 ratio
InpMaxHoldBars = 200            // Let winners run
```

### Conservative (Capital Preservation)
```
InpRiskPercent = 0.5            // Very low risk
InpMaxRiskPercent = 1.5
InpMaxDailyLossPct = 1.5
InpMinTradeQuality = 0.75       // Only pristine setups
InpUseKellyCriterion = false    // Fixed sizing
InpMaxPositions = 2             // Limit exposure
InpUseBreakEven = true
InpBreakEvenATR = 0.5           // Early breakeven
```

---

## Symbol-Specific Adjustments

### Major Pairs (EURUSD, GBPUSD, USDJPY)
```
InpMaxSpreadCostPct = 5.0       // Default fine
InpMaxSpreadCostMR = 3.0
InpATRPeriod = 14               // Standard
```

### Minor Pairs (EURJPY, GBPJPY, AUDUSD)
```
InpMaxSpreadCostPct = 7.0       // More tolerance
InpMaxSpreadCostMR = 5.0
InpMinTradeQuality = 0.65       // Slightly lower
```

### Exotic Pairs (USDMXN, USDZAR, etc.)
```
InpMaxSpreadCostPct = 10.0      // High spread tolerance
InpMaxSpreadCostMR = 8.0
InpRiskPercent = 0.75           // Reduce risk
InpMinTradeQuality = 0.70       // Be selective
InpUseKellyCriterion = false    // Less reliable
```

---

## Time of Day Optimization

### London Session (8:00-16:00 GMT)
```
InpSessionStartHour = 8
InpSessionEndHour = 16
InpMinTradeQuality = 0.60       // Best liquidity
```

### New York Session (13:00-21:00 GMT)
```
InpSessionStartHour = 13
InpSessionEndHour = 21
InpMinTradeQuality = 0.60
```

### London+NY Overlap (13:00-16:00 GMT) - BEST
```
InpSessionStartHour = 13
InpSessionEndHour = 16
InpMinTradeQuality = 0.55       // Can be more aggressive
InpMaxSpreadCostPct = 3.0       // Tight spreads expected
```

### Asian Session (0:00-8:00 GMT)
```
InpSessionStartHour = 0
InpSessionEndHour = 8
InpMinTradeQuality = 0.70       // Be selective
InpATRMultSL = 1.8              // Wider stops (low volatility)
InpATRMultTP = 5.4              // Maintain 3:1
```

---

## Regime-Specific Optimization

### Trending Markets (ADX > 25 consistently)
```
InpMinTradeQuality = 0.55       // More opportunities
InpUsePartialClose = true
InpPartialOnlyStrong = false    // Use in weak trends too
InpATRMultTP = 5.0              // Aim higher
InpMaxHoldBars = 150            // Let trends develop
```

### Ranging Markets (ADX < 20 consistently)
```
InpMinTradeQuality = 0.70       // Be selective
InpMR_ATRTP = 1.8               // More conservative TP
InpUsePartialClose = false      // Take full profit
InpMaxHoldBars = 50             // Don't overstay
```

### Volatile Markets (High ATR)
```
InpRiskPercent = 0.75           // Reduce risk
InpATRMultSL = 2.0              // Wider stops
InpATRMultTP = 6.0              // Maintain 3:1
InpUseBreakEven = true
InpBreakEvenATR = 0.6           // Earlier protection
```

---

## Performance Tuning

### To Increase Win Rate (at cost of profit factor)
```
InpMinTradeQuality = 0.75       // Very selective
InpRegimeConfirmBars = 2        // More confirmation
InpCooldownBars = 8             // Longer cooldown
InpUsePartialClose = false      // Full TP only
```

### To Increase Profit Factor (at cost of trade frequency)
```
InpATRMultTP = 6.0              // Bigger targets
InpUseDynamicTrail = true       // Lock profits
InpPartialClosePct = 20.0       // Take less off
InpMinTradeQuality = 0.65
InpMaxSpreadCostPct = 3.0       // Only best spread
```

### To Increase Trade Frequency (at cost of quality)
```
InpMinTradeQuality = 0.50       // Lower threshold
InpRegimeConfirmBars = 1        // Faster response
InpMaxSpreadCostPct = 7.0       // More tolerance
InpMaxTradesPerDay = 12         // Allow more
```

---

## Critical Don'ts

### ❌ NEVER Change These (Breaks v5.0 Math)
```
InpATRMultSL and InpATRMultTP ratio MUST stay 3:1
InpMR_ATRSL and InpMR_ATRTP ratio MUST stay 2:1

Bad Examples:
InpATRMultSL = 2.0, InpATRMultTP = 4.0  ← 2:1 not 3:1
InpMR_ATRSL = 1.5, InpMR_ATRTP = 2.0    ← 1.33:1 not 2:1

If you want tighter stops, scale proportionally:
InpATRMultSL = 1.2, InpATRMultTP = 3.6  ✓ (3:1 maintained)
InpMR_ATRSL = 0.8, InpMR_ATRTP = 1.6    ✓ (2:1 maintained)
```

### ❌ Don't Increase Regime Position Sizing
```
// v4.0 had this (REMOVED in v5.0):
REGIME_STRONG_TREND: riskScale = 1.0
REGIME_WEAK_TREND:   riskScale = 0.65  ← DO NOT ADD BACK
REGIME_RANGING:      riskScale = 0.50  ← DO NOT ADD BACK

// Keep uniform sizing in v5.0
```

### ❌ Don't Weaken Spread Filter
```
InpMaxSpreadCostPct = 15.0  ❌ WAY TOO HIGH
InpMaxSpreadCostPct = 10.0  ❌ STILL TOO HIGH
InpMaxSpreadCostPct = 7.0   ⚠️ Maximum acceptable
InpMaxSpreadCostPct = 5.0   ✓ Recommended
InpMaxSpreadCostPct = 3.0   ✓✓ Best for tight markets
```

---

## Testing Protocol

### Backtest Settings
```
Testing Period: 5+ years minimum
Modeling: Every tick (most accurate)
Spread: Real spread if available
Slippage: 1-2 pips (realistic)
Commission: Your broker's actual rate

Critical Metrics to Watch:
- Profit Factor > 1.8
- Sharpe Ratio > 1.5
- Max DD < 12%
- Win Rate 65-75%
- Recovery Factor > 3.0
```

### Demo Testing Requirements
```
Duration: 2-4 weeks minimum
Trades: 30+ trades executed
Capital: Same as intended live

Success Criteria:
- Positive P/L
- Max DD < InpMaxDrawdownPct
- Kelly parameters stabilizing
- Regime stats balanced (not all one regime)
- Quality scores averaging 0.60-0.70
```

### Live Testing Progression
```
Week 1-2:   0.25% risk per trade
Week 3-4:   0.50% risk per trade
Week 5-8:   0.75% risk per trade
Week 9-12:  1.00% risk per trade (full)

Enable Kelly Criterion after 50+ profitable trades
```

---

## Troubleshooting Common Issues

### "Not Taking Any Trades"
```
Check:
1. InpMinTradeQuality too high → Lower to 0.55
2. InpMaxSpreadCostPct too low → Increase to 7.0
3. Session filter too restrictive → Widen hours
4. Cooldown active → Check consecutiveLosses count
```

### "Taking Too Many Losing Trades"
```
Adjust:
1. InpMinTradeQuality → Increase to 0.70
2. InpRegimeConfirmBars → Increase to 2
3. Check spread filter → Lower to 3.0%
4. Review regime detection → May be in wrong regime
```

### "Winners Getting Cut Short"
```
Fix:
1. InpUsePartialClose → Set false or reduce %
2. InpPartialCloseATR → Increase to 3.0
3. InpTrailATRMult → Increase to 1.5 (less tight)
4. InpUseDynamicTrail → Set false (fixed trailing)
```

### "Losers Running Too Large"
```
Fix:
1. InpUseBreakEven → Ensure true
2. InpBreakEvenATR → Lower to 0.6 (earlier activation)
3. Check broker stops are actually respected
4. Review ATR multipliers (may be too wide for symbol)
```

### "Kelly Sizing Too Aggressive/Conservative"
```
Tune:
1. InpKellyFraction = 0.15 (more conservative)
2. InpKellyFraction = 0.25 (balanced - default)
3. InpKellyFraction = 0.35 (more aggressive)
4. Or disable: InpUseKellyCriterion = false
```

---

## Monitoring Checklist

### Daily Review
- [ ] Dashboard shows "ALL SYSTEMS GO"
- [ ] No circuit breaker or daily limit hit
- [ ] Consecutive losses < 3
- [ ] Daily P/L within expectations
- [ ] Open positions within max limit

### Weekly Review
- [ ] Win rate 65-75% range
- [ ] Profit factor > 1.8
- [ ] Kelly parameters trending correctly
- [ ] Regime stats balanced (not stuck in one)
- [ ] Average quality score > 0.60

### Monthly Review
- [ ] Cumulative profit positive
- [ ] Max DD below threshold
- [ ] Sharpe ratio > 1.0
- [ ] Trade frequency as expected (6-12/week typical)
- [ ] No systematic issues by regime/time/day

---

## Support & Resources

### Log Analysis
Enable verbose logging:
```
InpVerboseLog = true
```

Check for:
- "NEGATIVE EV" warnings → Adjust quality or spread filter
- "Quality filter" rejections → May need lower threshold
- "SKIP: MinLot risk exceeds budget" → Spread too high
- MAE/MFE patterns → Optimize exits

### Journal Export
All trades logged in format:
```
TRADE_JOURNAL|regime=STRONG_TREND|profit=72.50|rMultiple=2.8|mae=0.0015|mfe=0.0042|quality=0.72|closePrice=1.08453|posId=12345
```

Import into spreadsheet for analysis:
- Regime performance breakdown
- Quality score vs outcome correlation
- MAE/MFE optimization opportunities
- Time of day patterns

---

## Version History

**v5.0**: Best-in-class implementation
- 3:1 trend, 2:1 MR ratios
- Kelly Criterion sizing
- Quality filtering
- Dynamic trailing
- Regime analytics

**v4.0**: Original (losing system)
- 1.5:1 trend, 1:1 MR ratios
- Fixed sizing with regime reduction
- No quality filter
- Fixed trailing

---

**Remember**: Stick to the math. The v5.0 improvements are based on proven financial engineering principles. Trust the system, follow the risk limits, and let compound growth work for you.

**Golden Rule**: Never risk more than you can afford to lose. Start small, prove profitability, then scale up using Kelly Criterion guidance.
