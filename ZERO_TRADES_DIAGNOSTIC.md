# Zero Trades Diagnostic Guide

## Problem
Your EA compiled successfully but isn't generating any trading signals ("zero trades").

## Changes Made

I've added comprehensive diagnostic logging and a **DIAGNOSTIC MODE** to help identify which filter is blocking signals.

### New Features

1. **Enhanced Verbose Logging** - Shows exactly why signals are blocked
2. **Diagnostic Mode** - Temporarily relaxes strict filters to identify bottlenecks
3. **Step-by-step filter logging** - Traces signal evaluation flow

---

## How to Diagnose

### Step 1: Compile the Updated EA

1. Open MetaEditor
2. Open [AdaptiveRegimeEA.mq5](AdaptiveRegimeEA.mq5)
3. Click **Compile** (F7)
4. Verify "0 errors, 0 warnings"

### Step 2: Run with Verbose Logging

1. Attach EA to chart (EURUSD H1 recommended for testing)
2. Ensure **InpVerboseLog = true** (already default)
3. Watch the **Experts** tab in Terminal for diagnostic messages
4. Wait for at least 3-5 new H1 bars (3-5 hours)

### Step 3: Analyze the Log Messages

Look for these diagnostic messages in your log:

#### A. Pre-Signal Checks
```
--- NEW BAR 2026.02.07 14:00 ---
BLOCKED: Outside session hours
BLOCKED: Circuit breaker or daily loss limit
BLOCKED: Max trades per day reached (8/8)
BLOCKED: Max positions reached (3/3)
BLOCKED: Max risk reached (3.5%/3.0%)
BLOCKED: Cooldown active
```

**If you see any of these:** Adjust the relevant parameter
- Session filter: Set `InpUseSessionFilter = false`
- Max trades: Increase `InpMaxTradesPerDay`
- Max positions: Increase `InpMaxPositions`
- Circuit breaker: Reset by restarting EA

#### B. Regime Detection
```
Regime: ADX_H=18.5 ADX_M=22.3 BBW=3.245
STATE: Regime=VOLATILE | Trend=NEUTRAL
STATE: Regime=UNKNOWN | Trend=NEUTRAL
NO SIGNAL: Regime is VOLATILE (VOLATILE or UNKNOWN)
```

**If regime is stuck in VOLATILE or UNKNOWN:**
- Markets may genuinely be choppy (wait for clearer conditions)
- Or ADX thresholds too high: Lower `InpADXTrendThresh` from 20.0 to 18.0
- Or ADX thresholds too low: Raise if ADX constantly above 35

#### C. Signal Generation

**For Trend Signals:**
```
T_BUY: pulled=false above=true recov=true !OB=true rsi=true mom=false
NO TREND SIGNAL generated
```

**If momentum=false is blocking:** Enable diagnostic mode (see Step 4)

**For Mean Reversion Signals:**
```
MR_BUY: rsiOS=true stOS=false rsiT=true stT=true
NO MR SIGNAL generated
```

**If one indicator is always false:** Markets may not be in mean-reversion mode

#### D. Spread Filter
```
SPREAD REJECT: cost=6.8% of TP > 5%
BLOCKED: Spread filter rejected signal
```

**If spread is rejecting:**
- Check broker spread: `InpMaxSpreadCostPct = 7.0` (increase to 7%)
- Or trade during low-spread hours (London/NY session)

#### E. Quality Filter
```
BLOCKED: Quality filter: 0.58 < 0.60
```

**If quality score is close (0.55-0.59):** Lower `InpMinTradeQuality = 0.55`

**If quality score is very low (< 0.50):** Markets don't meet setup criteria

---

## Step 4: Enable Diagnostic Mode

If still no signals, enable diagnostic mode to temporarily relax filters:

### Settings:
```
InpDiagnosticMode = true   // Enable relaxed filters
```

### What Diagnostic Mode Does:
- **Momentum confirmation:** Bypassed (always passes)
- **Quality threshold:** Lowered from 0.60 to 0.45
- **Spread filter:** Doubled tolerance (10% for trend, 6% for MR)

### Expected Result:
- If signals appear: Filters were too strict
- If still no signals: Issue is with regime detection or signal generation logic

---

## Step 5: Most Likely Causes & Solutions

### Cause #1: Momentum Confirmation Too Strict (MOST LIKELY)

**Symptom:**
```
T_BUY: pulled=true above=true recov=true !OB=true rsi=true mom=false
```

**Solution:**
```cpp
// Temporarily disable momentum check (manual edit):
// Line ~789: Change to:
bool momentum = true; // Diagnostic: bypass momentum
```

Or just enable `InpDiagnosticMode = true`

---

### Cause #2: Spread Too Wide

**Symptom:**
```
SPREAD REJECT: cost=6.8% of TP > 5%
```

**Solution:**
```
InpMaxSpreadCostPct = 7.0    // Increase from 5.0
InpMaxSpreadCostMR = 4.0     // Increase from 3.0
```

**Or trade during best hours:**
- London session: 8:00-16:00 GMT
- NY session: 13:00-21:00 GMT
- London+NY overlap: 13:00-16:00 GMT (best)

---

### Cause #3: Quality Threshold Too High

**Symptom:**
```
BLOCKED: Quality filter: 0.58 < 0.60
```

**Solution:**
```
InpMinTradeQuality = 0.55    // Lower from 0.60
```

Or enable diagnostic mode (auto-lowers to 0.45)

---

### Cause #4: Wrong Regime (Stuck in VOLATILE/UNKNOWN)

**Symptom:**
```
STATE: Regime=VOLATILE | Trend=NEUTRAL
NO SIGNAL: Regime is VOLATILE (VOLATILE or UNKNOWN)
```

**Why it happens:**
- BBW > 2x average AND ADX > 35 triggers VOLATILE
- ADX < 20 on both timeframes = RANGING
- ADX 20-35 = WEAK_TREND
- ADX > 35 = STRONG_TREND

**Solution:**
- Wait for markets to stabilize (VOLATILE is safety feature)
- Or check if BBW expansion is temporary noise
- Monitor: "REGIME CHANGE: VOLATILE -> STRONG_TREND" in logs

---

### Cause #5: Pullback Logic Too Strict

**Symptom:** (Trend mode)
```
T_BUY: pulled=false above=true recov=true !OB=true rsi=true mom=true
```

**Why:** Price didn't pull back to EMA21 ± 0.5 ATR

**Solution:** Wait for actual pullback setup (this is working as designed)

---

### Cause #6: Mean Reversion Conditions Not Met

**Symptom:** (Ranging mode)
```
MR_BUY: rsiOS=true stOS=false rsiT=true stT=true
```

**Why:** Stochastic not oversold (<20)

**Solution:**
```
InpMR_StochOS = 25.0   // Increase from 20.0 (more lenient)
InpMR_StochOB = 75.0   // Decrease from 80.0
```

---

## Step 6: Recommended Quick Fix

**For immediate testing**, apply these relaxed settings:

```
=== DIAGNOSTIC SETTINGS ===
InpDiagnosticMode = true         // Enable diagnostic mode
InpMinTradeQuality = 0.50        // Lower quality threshold
InpMaxSpreadCostPct = 7.0        // More spread tolerance
InpMaxSpreadCostMR = 4.0
InpADXTrendThresh = 18.0         // Lower ADX threshold (more signals)
InpRegimeConfirmBars = 1         // Already optimal
```

**Expected:** You should see at least 1-2 signals per week on EURUSD H1

---

## Step 7: Interpreting Successful Signal

When a signal IS generated, you'll see:
```
>>> SIGNAL: BUY | Regime=STRONG_TREND | Trend=BULLISH | Quality=0.67
Attempt 1: BUY @1.08234 SL=1.08089 TP=1.08524 Lots=0.10
```

If signal generated but trade fails:
- Check account balance
- Check margin requirements
- Check broker allows hedging (if positions exist)
- Check "SKIP: MinLot risk exceeds budget"

---

## What the Logs Will Tell You

After running for 3-5 hours with verbose logging, you should see:

### Healthy Activity:
```
--- NEW BAR 2026.02.07 14:00 ---
STATE: Regime=WEAK_TREND | Trend=BULLISH
T_BUY: pulled=true above=true recov=true !OB=true rsi=true mom=true
Quality OK: 0.62 >= 0.60
>>> SIGNAL: BUY | Regime=WEAK_TREND | Trend=BULLISH | Quality=0.62
```

### Problem Pattern (example):
```
--- NEW BAR 2026.02.07 14:00 ---
STATE: Regime=STRONG_TREND | Trend=BULLISH
T_BUY: pulled=true above=true recov=true !OB=true rsi=true mom=false
NO TREND SIGNAL generated
```
☝️ **Momentum check failing = Enable diagnostic mode**

---

## Summary: Troubleshooting Flowchart

1. **Check logs for "BLOCKED:" messages**
   - If session filter → Disable or widen hours
   - If spread filter → Increase tolerance or trade better hours
   - If quality filter → Lower threshold
   - If cooldown → Wait or reset

2. **Check regime detection**
   - If stuck in VOLATILE → Wait for market stabilization
   - If stuck in UNKNOWN → Check data/indicators loading

3. **Check signal generation**
   - If momentum=false → Enable diagnostic mode
   - If other conditions=false → Wait for proper setup or relax thresholds

4. **Enable diagnostic mode** as temporary measure
   - InpDiagnosticMode = true
   - Should see signals within 24-48 hours
   - If signals appear, gradually tighten filters

5. **If still no signals in diagnostic mode**
   - Check timeframe: Must be attached to H1 chart
   - Check symbol: Major pairs (EURUSD, GBPUSD) work best
   - Check market hours: Friday night/weekend won't generate signals
   - Check data: Ensure broker provides tick data

---

## Expected Signal Frequency

With current settings on EURUSD H1:
- **Normal mode:** 1-2 signals per week (very selective)
- **Diagnostic mode:** 2-4 signals per week (relaxed)
- **Optimal conditions:** 3-6 signals per week (London/NY sessions)

**If zero signals after 2 weeks in diagnostic mode:**
- Issue is with regime detection or data
- Check "Regime:" log messages
- Ensure ADX, BB, EMA indicators are loading (no errors in log)

---

## Next Steps

1. Compile updated EA
2. Attach to EURUSD H1 chart
3. Enable `InpDiagnosticMode = true` for initial testing
4. Monitor logs for 24-48 hours
5. Share log snippets showing what's blocking signals
6. Once signals appear, gradually tighten filters back to normal

The diagnostic logging will tell us exactly which filter is the bottleneck!
