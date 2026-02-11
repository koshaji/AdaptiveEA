//+------------------------------------------------------------------+
//|                                          AdaptiveRegimeEA.mq5    |
//|                        Adaptive Market Regime Expert Advisor      |
//|                           v6.0 - High Return-to-Risk Overhaul     |
//|                                                                    |
//|  v6.0 Changes:                                                     |
//|  [CRITICAL] Trade management overhaul: let winners run             |
//|    - BE delayed to 2.0 ATR (was 0.8), offset 0.1 (was 0.3)       |
//|    - Trail activation 2.5 ATR (was 1.5), distance 1.5 (was 1.0)  |
//|    - Dynamic trail widened: 4R->0.75, 3R->1.0, 2.5R->1.25       |
//|    - Partial close 25% at 3.0 ATR (was 30% at 2.5)               |
//|  [CRITICAL] Regime-specific trade management profiles              |
//|    - STRONG_TREND/WEAK_TREND/RANGING each have tuned BE/trail     |
//|  [CRITICAL] Regime-specific Kelly sizing (uses per-regime stats)   |
//|  [CRITICAL] Removed WR floor (was masking genuine edge loss)       |
//|  [HIGH]     Self-healing: SafeCopyBuffer with retry + backoff      |
//|  [HIGH]     Indicator handle validation + auto re-creation         |
//|  [HIGH]     Connection drop detection + orphan position recovery   |
//|  [HIGH]     State validation on load (detects corruption)          |
//|  [HIGH]     Regime-aware EV check (per-regime stats when avail)    |
//|  [HIGH]     Regime stats persistence across restarts               |
//|  [MEDIUM]   Kelly reset parameter for fresh start after changes    |
//|  [MEDIUM]   Optional volatile regime trading at reduced size       |
//|  [MEDIUM]   BB touch tolerance parameterized (was hardcoded 0.2%) |
//|  [MEDIUM]   Enhanced trade execution error handling                |
//|  [MEDIUM]   EV tolerance band (10% of risk) for estimation noise  |
//+------------------------------------------------------------------+
#property copyright "AdaptiveRegimeEA v6.0"
#property version   "6.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\AccountInfo.mqh>
#include <Trade\SymbolInfo.mqh>

//+------------------------------------------------------------------+
//| ENUMS                                                              |
//+------------------------------------------------------------------+
enum ENUM_REGIME
{
   REGIME_STRONG_TREND,    // Strong directional trend
   REGIME_WEAK_TREND,      // Weak/developing trend
   REGIME_RANGING,         // Sideways/mean-reverting
   REGIME_VOLATILE,        // High volatility - reduce exposure
   REGIME_UNKNOWN          // Insufficient data
};

enum ENUM_TREND_DIR
{
   TREND_BULLISH,
   TREND_BEARISH,
   TREND_NEUTRAL
};

enum ENUM_SIGNAL
{
   SIGNAL_BUY,
   SIGNAL_SELL,
   SIGNAL_NONE
};

//+------------------------------------------------------------------+
//| INPUT PARAMETERS                                                   |
//+------------------------------------------------------------------+
input group "=== General Settings ==="
input int         InpMagicNumber        = 247901;     // Magic Number
input string      InpTradeComment       = "AREA";     // Trade Comment
input ENUM_TIMEFRAMES InpHTF            = PERIOD_H4;  // Higher Timeframe (trend)
input ENUM_TIMEFRAMES InpMTF            = PERIOD_H1;  // Medium Timeframe (signal)
input ENUM_TIMEFRAMES InpLTF            = PERIOD_M15; // Lower Timeframe (entry)
input bool        InpVerboseLog         = true;       // Verbose Logging
input bool        InpDiagnosticMode     = false;      // DIAGNOSTIC MODE (relaxed filters)

input group "=== Regime Detection ==="
input int         InpADXPeriod          = 14;         // ADX Period
input double      InpADXTrendThresh     = 20.0;       // ADX Trending Threshold
input double      InpADXStrongThresh    = 35.0;       // ADX Strong Trend Threshold
input int         InpBBPeriod           = 20;         // Bollinger Band Period
input double      InpBBDeviation        = 2.0;        // Bollinger Band Deviation
input int         InpRegimeLookback     = 20;         // Regime BBW Lookback (bars)
input int         InpRegimeConfirmBars  = 1;          // Bars to confirm regime change

input group "=== Trend Following ==="
input int         InpFastEMA            = 8;          // Fast EMA Period
input int         InpMedEMA             = 21;         // Medium EMA Period
input int         InpSlowEMA            = 55;         // Slow EMA Period
input int         InpTrendRSIPeriod     = 14;         // RSI Period (trend)
input double      InpTrendRSIOB         = 70.0;       // RSI Overbought (trend)
input double      InpTrendRSIOS         = 30.0;       // RSI Oversold (trend)

input group "=== Mean Reversion ==="
input int         InpMR_RSIPeriod       = 7;          // RSI Period (MR)
input double      InpMR_RSI_OB          = 70.0;       // RSI Overbought (MR) - v5.1: widened from 75
input double      InpMR_RSI_OS          = 30.0;       // RSI Oversold (MR) - v5.1: widened from 25
input int         InpMR_StochK          = 14;         // Stochastic %K
input int         InpMR_StochD          = 3;          // Stochastic %D
input int         InpMR_StochSlow       = 3;          // Stochastic Slowing
input double      InpMR_StochOB         = 75.0;       // Stochastic OB - v5.1: widened from 80
input double      InpMR_StochOS         = 25.0;       // Stochastic OS - v5.1: widened from 20
input double      InpBBTouchTolerance   = 0.005;      // v6: BB touch tolerance (0.5%, was 0.2%)

input group "=== Risk Management ==="
input double      InpRiskPercent        = 1.0;        // Base Risk Per Trade (%)
input double      InpMaxRiskPercent     = 3.0;        // Max Total Portfolio Risk (%)
input double      InpATRMultSL          = 1.5;        // ATR Mult SL (trend)
input double      InpATRMultTP          = 4.5;        // ATR Mult TP (trend) - 3:1 ratio
input double      InpMR_ATRSL           = 1.0;        // ATR Mult SL (mean reversion)
input double      InpMR_ATRTP           = 2.0;        // ATR Mult TP (mean reversion) - 2:1 ratio
input int         InpATRPeriod          = 14;         // ATR Period
input double      InpMaxDailyLossPct    = 3.0;        // Max Daily Loss (%)
input double      InpMaxDrawdownPct     = 10.0;       // Max DD Circuit Breaker (%)
input int         InpMaxPositions       = 3;          // Max Concurrent Positions
input int         InpMaxTradesPerDay    = 8;          // Max Trades Per Day
input bool        InpUseKellyCriterion  = true;       // Use Kelly Criterion Sizing
input double      InpKellyFraction      = 0.25;       // Kelly Safety Factor (0.25 = quarter-Kelly)
input bool        InpUseRegimeKelly     = true;       // v6: Use regime-specific Kelly stats
input int         InpRegimeKellyMinTrades = 15;       // v6: Min trades for regime Kelly
input bool        InpResetKellyOnStart  = false;      // v6: Reset Kelly stats on init

input group "=== Filters ==="
input double      InpMaxSpreadCostPct   = 5.0;        // Max Spread as % of TP (trend)
input double      InpMaxSpreadCostMR    = 3.0;        // Max Spread as % of TP (MR)
input int         InpCooldownBars       = 5;          // Cooldown bars after 2+ consecutive losses
input int         InpMaxConsecLosses    = 3;          // Extended pause after N consecutive losses
input double      InpMinTradeQuality    = 0.55;       // Min Quality Score (0-1) - v5.1: lowered from 0.6

input group "=== Trade Management ==="
input bool        InpUsePartialClose    = true;       // Use Partial Close
input double      InpPartialClosePct    = 25.0;       // Partial Close % (v6: was 30)
input double      InpPartialCloseATR    = 3.0;        // Partial ATR trigger (v6: was 2.5)
input bool        InpPartialOnlyStrong  = false;      // v6: false — regime profiles handle this
input bool        InpUseTrailingStop    = true;       // Use Trailing Stop
input double      InpTrailATRMult       = 1.5;        // Trail ATR distance (v6: was 1.0)
input double      InpTrailActivateATR   = 2.5;        // Trail activate ATR (v6: was 1.5)
input bool        InpUseDynamicTrail    = true;       // Dynamic trailing based on volatility
input bool        InpUseBreakEven       = true;       // Use Break-Even
input double      InpBreakEvenATR       = 2.0;        // Break-Even ATR (v6: was 0.8)
input double      InpBreakEvenOffset    = 0.1;        // Break-Even offset ATR (v6: was 0.3)
input int         InpMaxHoldBars        = 100;        // Max Hold Bars (0=off)

input group "=== Volatile Regime ==="
input bool        InpAllowVolatileTrades = false;     // v6: Allow trades in VOLATILE regime
input double      InpVolatileRiskMult    = 0.50;      // v6: Risk multiplier for VOLATILE

input group "=== Session Filter ==="
input bool        InpUseSessionFilter   = true;       // Use Session Filter
input int         InpSessionStartHour   = 2;          // Start Hour
input int         InpSessionEndHour     = 21;         // End Hour
input bool        InpAvoidFriday        = true;       // Reduce Friday Exposure
input int         InpFridayCutoffHour   = 18;         // Friday Cutoff

input group "=== Display ==="
input bool        InpShowDashboard      = true;       // Show Dashboard
input color       InpDashText           = clrWhite;   // Dashboard Text

//+------------------------------------------------------------------+
//| GLOBAL VARIABLES                                                   |
//+------------------------------------------------------------------+
CTrade         trade;
CPositionInfo  posInfo;
CAccountInfo   accInfo;
CSymbolInfo    symInfo;

int h_ADX_HTF, h_ADX_MTF;
int h_BB_MTF;
int h_EMA_Fast_HTF, h_EMA_Med_HTF, h_EMA_Slow_HTF;
int h_EMA_Fast_MTF, h_EMA_Med_MTF, h_EMA_Slow_MTF;
int h_RSI_MTF, h_RSI_LTF;
int h_ATR_MTF, h_ATR_LTF;
int h_Stoch_MTF;

ENUM_REGIME    currentRegime       = REGIME_UNKNOWN;
ENUM_TREND_DIR currentTrend        = TREND_NEUTRAL;
double         dailyStartBalance   = 0;
double         peakBalance         = 0;
int            tradesToday          = 0;
datetime       lastBarTime          = 0;
datetime       lastDayCheck         = 0;
bool           circuitBreakerActive = false;
bool           dailyLossLimitHit    = false;

// Regime hysteresis
ENUM_REGIME    pendingRegime        = REGIME_UNKNOWN;
int            regimeConfirmCount   = 0;

// Post-loss cooldown
int            consecutiveLosses    = 0;
datetime       lastLossTime         = 0;

// Cached values (computed once per bar, reused in dashboard)
int            cachedPosCount       = 0;
double         cachedTotalRisk      = 0;

// Partial close tracking with GC
struct TradeRecord
{
   ulong          ticket;
   bool           partialDone;
   ENUM_REGIME    regime;
   ENUM_SIGNAL    direction;
   double         openPrice;
   datetime       openTime;
   double         entryATR;      // v5.1: ATR at entry time for consistent R-multiple
   double         maxMAE;        // Maximum Adverse Excursion
   double         maxMFE;        // Maximum Favorable Excursion
   double         qualityScore;  // Trade quality at entry
};
TradeRecord    activeTracker[];
datetime       lastTrackerCleanup   = 0;

// Performance Analytics
struct RegimeStats
{
   int    trades;
   int    wins;
   double totalProfit;
   double totalLoss;
   double avgWin;
   double avgLoss;
   double profitFactor;
   double sharpeRatio;
   // v6: R-multiple tracking for regime-specific Kelly
   double sumWinR;
   double sumLossR;
   int    winCount;
   int    lossCount;
};
RegimeStats stats_StrongTrend, stats_WeakTrend, stats_Ranging;

// Kelly Criterion tracking
double   historicalWinRate     = 0.50;  // v5.1: Bootstrap at 50% (was 75% - too optimistic)
double   historicalAvgWin      = 2.0;   // In R multiples
double   historicalAvgLoss     = 1.0;   // In R multiples
int      totalClosedTrades     = 0;
int      totalWins             = 0;     // v5.1: Simple counters for early trades
double   sumWinR               = 0;     // v5.1: Sum of winning R-multiples
double   sumLossR              = 0;     // v5.1: Sum of losing R-multiples
int      totalLosses           = 0;     // v5.1: Simple loss counter

// Real-time performance
double   todayProfitFactor     = 0;
double   currentSharpe         = 0;
double   maxAdverseExcursion   = 0;

// v6: Self-healing state
datetime lastSuccessfulTick    = 0;
int      connectionDropCount   = 0;
int      handleRecreateCount   = 0;

//+------------------------------------------------------------------+
//| Filling mode auto-detect                                          |
//+------------------------------------------------------------------+
ENUM_ORDER_TYPE_FILLING DetectFillingMode()
{
   long fillMode = 0;
   if(!SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE, fillMode))
      return ORDER_FILLING_IOC;
   if((fillMode & SYMBOL_FILLING_FOK) == SYMBOL_FILLING_FOK)
      return ORDER_FILLING_FOK;
   if((fillMode & SYMBOL_FILLING_IOC) == SYMBOL_FILLING_IOC)
      return ORDER_FILLING_IOC;
   return ORDER_FILLING_RETURN;
}

//+------------------------------------------------------------------+
//| v6: SafeCopyBuffer with retry + exponential backoff               |
//+------------------------------------------------------------------+
int SafeCopyBuffer(int handle, int buffer_num, int start, int count, double &buffer[])
{
   for(int attempt = 1; attempt <= 3; attempt++)
   {
      int copied = CopyBuffer(handle, buffer_num, start, count, buffer);
      if(copied >= count) return copied;
      if(attempt < 3)
      {
         if(InpVerboseLog)
            Print("CopyBuffer retry ", attempt, "/3 handle=", handle,
                  " buf=", buffer_num, " err=", GetLastError());
         Sleep(50 * attempt);
         ResetLastError();
      }
   }
   Print("WARNING: CopyBuffer FAILED after 3 retries, handle=", handle, " buf=", buffer_num);
   return -1;
}

//+------------------------------------------------------------------+
//| v6: Safe CopyClose/CopyHigh/CopyLow wrappers                    |
//+------------------------------------------------------------------+
int SafeCopyClose(string sym, ENUM_TIMEFRAMES tf, int start, int count, double &buffer[])
{
   for(int attempt = 1; attempt <= 3; attempt++)
   {
      int copied = CopyClose(sym, tf, start, count, buffer);
      if(copied >= count) return copied;
      if(attempt < 3) { Sleep(50 * attempt); ResetLastError(); }
   }
   return -1;
}

int SafeCopyHigh(string sym, ENUM_TIMEFRAMES tf, int start, int count, double &buffer[])
{
   for(int attempt = 1; attempt <= 3; attempt++)
   {
      int copied = CopyHigh(sym, tf, start, count, buffer);
      if(copied >= count) return copied;
      if(attempt < 3) { Sleep(50 * attempt); ResetLastError(); }
   }
   return -1;
}

int SafeCopyLow(string sym, ENUM_TIMEFRAMES tf, int start, int count, double &buffer[])
{
   for(int attempt = 1; attempt <= 3; attempt++)
   {
      int copied = CopyLow(sym, tf, start, count, buffer);
      if(copied >= count) return copied;
      if(attempt < 3) { Sleep(50 * attempt); ResetLastError(); }
   }
   return -1;
}

//+------------------------------------------------------------------+
//| v6: Create all indicator handles (shared by OnInit + self-heal)  |
//+------------------------------------------------------------------+
bool CreateIndicatorHandles()
{
   h_ADX_HTF      = iADX(_Symbol, InpHTF, InpADXPeriod);
   h_EMA_Fast_HTF = iMA(_Symbol, InpHTF, InpFastEMA, 0, MODE_EMA, PRICE_CLOSE);
   h_EMA_Med_HTF  = iMA(_Symbol, InpHTF, InpMedEMA, 0, MODE_EMA, PRICE_CLOSE);
   h_EMA_Slow_HTF = iMA(_Symbol, InpHTF, InpSlowEMA, 0, MODE_EMA, PRICE_CLOSE);
   h_ADX_MTF      = iADX(_Symbol, InpMTF, InpADXPeriod);
   h_BB_MTF       = iBands(_Symbol, InpMTF, InpBBPeriod, 0, InpBBDeviation, PRICE_CLOSE);
   h_EMA_Fast_MTF = iMA(_Symbol, InpMTF, InpFastEMA, 0, MODE_EMA, PRICE_CLOSE);
   h_EMA_Med_MTF  = iMA(_Symbol, InpMTF, InpMedEMA, 0, MODE_EMA, PRICE_CLOSE);
   h_EMA_Slow_MTF = iMA(_Symbol, InpMTF, InpSlowEMA, 0, MODE_EMA, PRICE_CLOSE);
   h_RSI_MTF      = iRSI(_Symbol, InpMTF, InpTrendRSIPeriod, PRICE_CLOSE);
   h_ATR_MTF      = iATR(_Symbol, InpMTF, InpATRPeriod);
   h_Stoch_MTF    = iStochastic(_Symbol, InpMTF, InpMR_StochK, InpMR_StochD, InpMR_StochSlow, MODE_SMA, STO_LOWHIGH);
   h_RSI_LTF      = iRSI(_Symbol, InpLTF, InpMR_RSIPeriod, PRICE_CLOSE);
   h_ATR_LTF      = iATR(_Symbol, InpLTF, InpATRPeriod);

   return (h_ADX_HTF != INVALID_HANDLE && h_ADX_MTF != INVALID_HANDLE &&
           h_BB_MTF != INVALID_HANDLE && h_EMA_Fast_HTF != INVALID_HANDLE &&
           h_EMA_Med_HTF != INVALID_HANDLE && h_EMA_Slow_HTF != INVALID_HANDLE &&
           h_EMA_Fast_MTF != INVALID_HANDLE && h_EMA_Med_MTF != INVALID_HANDLE &&
           h_EMA_Slow_MTF != INVALID_HANDLE && h_RSI_MTF != INVALID_HANDLE &&
           h_ATR_MTF != INVALID_HANDLE && h_Stoch_MTF != INVALID_HANDLE &&
           h_RSI_LTF != INVALID_HANDLE && h_ATR_LTF != INVALID_HANDLE);
}

//+------------------------------------------------------------------+
//| v6: Release all indicator handles safely                         |
//+------------------------------------------------------------------+
void ReleaseIndicatorHandles()
{
   if(h_ADX_HTF != INVALID_HANDLE) IndicatorRelease(h_ADX_HTF);
   if(h_ADX_MTF != INVALID_HANDLE) IndicatorRelease(h_ADX_MTF);
   if(h_BB_MTF != INVALID_HANDLE) IndicatorRelease(h_BB_MTF);
   if(h_EMA_Fast_HTF != INVALID_HANDLE) IndicatorRelease(h_EMA_Fast_HTF);
   if(h_EMA_Med_HTF != INVALID_HANDLE) IndicatorRelease(h_EMA_Med_HTF);
   if(h_EMA_Slow_HTF != INVALID_HANDLE) IndicatorRelease(h_EMA_Slow_HTF);
   if(h_EMA_Fast_MTF != INVALID_HANDLE) IndicatorRelease(h_EMA_Fast_MTF);
   if(h_EMA_Med_MTF != INVALID_HANDLE) IndicatorRelease(h_EMA_Med_MTF);
   if(h_EMA_Slow_MTF != INVALID_HANDLE) IndicatorRelease(h_EMA_Slow_MTF);
   if(h_RSI_MTF != INVALID_HANDLE) IndicatorRelease(h_RSI_MTF);
   if(h_ATR_MTF != INVALID_HANDLE) IndicatorRelease(h_ATR_MTF);
   if(h_Stoch_MTF != INVALID_HANDLE) IndicatorRelease(h_Stoch_MTF);
   if(h_RSI_LTF != INVALID_HANDLE) IndicatorRelease(h_RSI_LTF);
   if(h_ATR_LTF != INVALID_HANDLE) IndicatorRelease(h_ATR_LTF);
}

//+------------------------------------------------------------------+
//| v6: Validate handles and auto-recreate if invalid                |
//+------------------------------------------------------------------+
bool ValidateIndicatorHandles()
{
   bool allValid = (h_ADX_HTF != INVALID_HANDLE && h_ADX_MTF != INVALID_HANDLE &&
                    h_BB_MTF != INVALID_HANDLE && h_EMA_Fast_HTF != INVALID_HANDLE &&
                    h_EMA_Med_HTF != INVALID_HANDLE && h_EMA_Slow_HTF != INVALID_HANDLE &&
                    h_EMA_Fast_MTF != INVALID_HANDLE && h_EMA_Med_MTF != INVALID_HANDLE &&
                    h_EMA_Slow_MTF != INVALID_HANDLE && h_RSI_MTF != INVALID_HANDLE &&
                    h_ATR_MTF != INVALID_HANDLE && h_Stoch_MTF != INVALID_HANDLE &&
                    h_RSI_LTF != INVALID_HANDLE && h_ATR_LTF != INVALID_HANDLE);

   if(allValid) return true;

   Print("SELF-HEAL: Invalid indicator handle detected, recreating all...");
   ReleaseIndicatorHandles();
   bool ok = CreateIndicatorHandles();
   if(ok)
   {
      handleRecreateCount++;
      Print("SELF-HEAL SUCCESS: Handles recreated (total: ", handleRecreateCount, ")");
   }
   else
      Print("SELF-HEAL FAILED: Could not recreate indicator handles");
   return ok;
}

//+------------------------------------------------------------------+
//| v6: Recover orphan positions not in activeTracker                |
//+------------------------------------------------------------------+
void ReconcilePositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!posInfo.SelectByIndex(i)) continue;
      if(posInfo.Magic() != InpMagicNumber || posInfo.Symbol() != _Symbol) continue;

      ulong ticket = posInfo.Ticket();
      bool found = false;
      for(int t = 0; t < ArraySize(activeTracker); t++)
      {
         if(activeTracker[t].ticket == ticket) { found = true; break; }
      }
      if(found) continue;

      // Orphan: estimate entry ATR from current ATR
      double atr_v[];
      ArraySetAsSeries(atr_v, true);
      double atr = 0;
      if(SafeCopyBuffer(h_ATR_MTF, 0, 0, 1, atr_v) >= 1) atr = atr_v[0];

      // Parse regime from trade comment (format: "AREA|REGIME_NAME")
      ENUM_REGIME estRegime = REGIME_UNKNOWN;
      string comment = PositionGetString(POSITION_COMMENT);
      if(StringFind(comment, "STRONG_TREND") >= 0) estRegime = REGIME_STRONG_TREND;
      else if(StringFind(comment, "WEAK_TREND") >= 0) estRegime = REGIME_WEAK_TREND;
      else if(StringFind(comment, "RANGING") >= 0) estRegime = REGIME_RANGING;
      else if(StringFind(comment, "VOLATILE") >= 0) estRegime = REGIME_VOLATILE;

      ENUM_SIGNAL dir = (posInfo.PositionType() == POSITION_TYPE_BUY) ? SIGNAL_BUY : SIGNAL_SELL;
      AddTradeRecord(ticket, estRegime, dir, posInfo.PriceOpen(), 0.5, atr);
      Print("ORPHAN RECOVERY: #", ticket, " Regime=", RegimeToString(estRegime),
            " ATR=", DoubleToString(atr, _Digits));
   }
}

//+------------------------------------------------------------------+
//| v6: Get regime-specific Kelly parameters                         |
//| Returns true if regime has enough data, fills p_out and b_out    |
//+------------------------------------------------------------------+
bool GetRegimeKelly(ENUM_REGIME regime, double &p_out, double &b_out)
{
   if(!InpUseRegimeKelly) return false;

   RegimeStats rs;
   if(regime == REGIME_STRONG_TREND) rs = stats_StrongTrend;
   else if(regime == REGIME_WEAK_TREND) rs = stats_WeakTrend;
   else if(regime == REGIME_RANGING) rs = stats_Ranging;
   else return false;

   int totalRegimeTrades = rs.winCount + rs.lossCount;
   if(totalRegimeTrades < InpRegimeKellyMinTrades) return false;
   if(rs.winCount == 0 || rs.lossCount == 0) return false;

   p_out = (double)rs.winCount / totalRegimeTrades;
   double avgW = rs.sumWinR / rs.winCount;
   double avgL = rs.sumLossR / rs.lossCount;
   if(avgL <= 0) return false;
   b_out = avgW / avgL;
   return true;
}

//+------------------------------------------------------------------+
//| State persistence via GlobalVariables                             |
//+------------------------------------------------------------------+
string GVPrefix()
{
   return "AREA_" + IntegerToString(InpMagicNumber) + "_" + _Symbol + "_";
}

void SaveState()
{
   // v5.1: Never persist state during backtesting (causes stale data leaks)
   if(MQLInfoInteger(MQL_TESTER)) return;

   string pfx = GVPrefix();
   GlobalVariableSet(pfx + "peakBalance",       peakBalance);
   GlobalVariableSet(pfx + "dailyStartBal",     dailyStartBalance);
   GlobalVariableSet(pfx + "tradesToday",        (double)tradesToday);
   GlobalVariableSet(pfx + "lastDayCheck",       (double)lastDayCheck);
   GlobalVariableSet(pfx + "circuitBreaker",     circuitBreakerActive ? 1.0 : 0.0);
   GlobalVariableSet(pfx + "dailyLossHit",       dailyLossLimitHit ? 1.0 : 0.0);
   GlobalVariableSet(pfx + "lastBarTime",        (double)lastBarTime);
   GlobalVariableSet(pfx + "consecLosses",       (double)consecutiveLosses);
   GlobalVariableSet(pfx + "lastLossTime",       (double)lastLossTime);
   GlobalVariableSet(pfx + "winRate",            historicalWinRate);
   GlobalVariableSet(pfx + "avgWin",             historicalAvgWin);
   GlobalVariableSet(pfx + "avgLoss",            historicalAvgLoss);
   GlobalVariableSet(pfx + "totalTrades",        (double)totalClosedTrades);
   // v6: Persist global Kelly counters (needed for simple average in first 30 trades)
   GlobalVariableSet(pfx + "totalWins",         (double)totalWins);
   GlobalVariableSet(pfx + "totalLosses",       (double)totalLosses);
   GlobalVariableSet(pfx + "sumWinR",           sumWinR);
   GlobalVariableSet(pfx + "sumLossR",          sumLossR);

   // v6: Persist regime stats for regime-specific Kelly
   GlobalVariableSet(pfx + "ST_winCount",  (double)stats_StrongTrend.winCount);
   GlobalVariableSet(pfx + "ST_lossCount", (double)stats_StrongTrend.lossCount);
   GlobalVariableSet(pfx + "ST_sumWinR",   stats_StrongTrend.sumWinR);
   GlobalVariableSet(pfx + "ST_sumLossR",  stats_StrongTrend.sumLossR);
   GlobalVariableSet(pfx + "ST_trades",    (double)stats_StrongTrend.trades);
   GlobalVariableSet(pfx + "ST_wins",      (double)stats_StrongTrend.wins);
   GlobalVariableSet(pfx + "ST_profit",    stats_StrongTrend.totalProfit);
   GlobalVariableSet(pfx + "ST_loss",      stats_StrongTrend.totalLoss);

   GlobalVariableSet(pfx + "WT_winCount",  (double)stats_WeakTrend.winCount);
   GlobalVariableSet(pfx + "WT_lossCount", (double)stats_WeakTrend.lossCount);
   GlobalVariableSet(pfx + "WT_sumWinR",   stats_WeakTrend.sumWinR);
   GlobalVariableSet(pfx + "WT_sumLossR",  stats_WeakTrend.sumLossR);
   GlobalVariableSet(pfx + "WT_trades",    (double)stats_WeakTrend.trades);
   GlobalVariableSet(pfx + "WT_wins",      (double)stats_WeakTrend.wins);
   GlobalVariableSet(pfx + "WT_profit",    stats_WeakTrend.totalProfit);
   GlobalVariableSet(pfx + "WT_loss",      stats_WeakTrend.totalLoss);

   GlobalVariableSet(pfx + "RG_winCount",  (double)stats_Ranging.winCount);
   GlobalVariableSet(pfx + "RG_lossCount", (double)stats_Ranging.lossCount);
   GlobalVariableSet(pfx + "RG_sumWinR",   stats_Ranging.sumWinR);
   GlobalVariableSet(pfx + "RG_sumLossR",  stats_Ranging.sumLossR);
   GlobalVariableSet(pfx + "RG_trades",    (double)stats_Ranging.trades);
   GlobalVariableSet(pfx + "RG_wins",      (double)stats_Ranging.wins);
   GlobalVariableSet(pfx + "RG_profit",    stats_Ranging.totalProfit);
   GlobalVariableSet(pfx + "RG_loss",      stats_Ranging.totalLoss);
}

void LoadState()
{
   // v5.1: Never load stale state in Strategy Tester (prevents unreproducible results)
   if(MQLInfoInteger(MQL_TESTER)) return;

   string pfx = GVPrefix();
   if(!GlobalVariableCheck(pfx + "peakBalance")) return;

   double savedPeak = GlobalVariableGet(pfx + "peakBalance");
   peakBalance = (savedPeak > accInfo.Balance()) ? savedPeak : accInfo.Balance();

   datetime savedDay = (datetime)(long)GlobalVariableGet(pfx + "lastDayCheck");
   MqlDateTime dt;
   TimeCurrent(dt);
   datetime today = StringToTime(IntegerToString(dt.year) + "." +
                                  IntegerToString(dt.mon) + "." +
                                  IntegerToString(dt.day));
   if(savedDay == today)
   {
      dailyStartBalance = GlobalVariableGet(pfx + "dailyStartBal");
      tradesToday       = (int)GlobalVariableGet(pfx + "tradesToday");
      dailyLossLimitHit = (GlobalVariableGet(pfx + "dailyLossHit") > 0.5);
      lastDayCheck      = savedDay;
   }

   circuitBreakerActive = (GlobalVariableGet(pfx + "circuitBreaker") > 0.5);
   lastBarTime          = (datetime)(long)GlobalVariableGet(pfx + "lastBarTime");
   consecutiveLosses    = (int)GlobalVariableGet(pfx + "consecLosses");
   lastLossTime         = (datetime)(long)GlobalVariableGet(pfx + "lastLossTime");

   if(GlobalVariableCheck(pfx + "winRate"))
   {
      historicalWinRate  = GlobalVariableGet(pfx + "winRate");
      historicalAvgWin   = GlobalVariableGet(pfx + "avgWin");
      historicalAvgLoss  = GlobalVariableGet(pfx + "avgLoss");
      totalClosedTrades  = (int)GlobalVariableGet(pfx + "totalTrades");
      // v6: Restore global Kelly counters
      totalWins          = (int)GlobalVariableGet(pfx + "totalWins");
      totalLosses        = (int)GlobalVariableGet(pfx + "totalLosses");
      sumWinR            = GlobalVariableGet(pfx + "sumWinR");
      sumLossR           = GlobalVariableGet(pfx + "sumLossR");
   }

   // v6: Load regime stats
   if(GlobalVariableCheck(pfx + "ST_winCount"))
   {
      stats_StrongTrend.winCount  = (int)GlobalVariableGet(pfx + "ST_winCount");
      stats_StrongTrend.lossCount = (int)GlobalVariableGet(pfx + "ST_lossCount");
      stats_StrongTrend.sumWinR   = GlobalVariableGet(pfx + "ST_sumWinR");
      stats_StrongTrend.sumLossR  = GlobalVariableGet(pfx + "ST_sumLossR");
      stats_StrongTrend.trades    = (int)GlobalVariableGet(pfx + "ST_trades");
      stats_StrongTrend.wins      = (int)GlobalVariableGet(pfx + "ST_wins");
      stats_StrongTrend.totalProfit = GlobalVariableGet(pfx + "ST_profit");
      stats_StrongTrend.totalLoss = GlobalVariableGet(pfx + "ST_loss");

      stats_WeakTrend.winCount  = (int)GlobalVariableGet(pfx + "WT_winCount");
      stats_WeakTrend.lossCount = (int)GlobalVariableGet(pfx + "WT_lossCount");
      stats_WeakTrend.sumWinR   = GlobalVariableGet(pfx + "WT_sumWinR");
      stats_WeakTrend.sumLossR  = GlobalVariableGet(pfx + "WT_sumLossR");
      stats_WeakTrend.trades    = (int)GlobalVariableGet(pfx + "WT_trades");
      stats_WeakTrend.wins      = (int)GlobalVariableGet(pfx + "WT_wins");
      stats_WeakTrend.totalProfit = GlobalVariableGet(pfx + "WT_profit");
      stats_WeakTrend.totalLoss = GlobalVariableGet(pfx + "WT_loss");

      stats_Ranging.winCount  = (int)GlobalVariableGet(pfx + "RG_winCount");
      stats_Ranging.lossCount = (int)GlobalVariableGet(pfx + "RG_lossCount");
      stats_Ranging.sumWinR   = GlobalVariableGet(pfx + "RG_sumWinR");
      stats_Ranging.sumLossR  = GlobalVariableGet(pfx + "RG_sumLossR");
      stats_Ranging.trades    = (int)GlobalVariableGet(pfx + "RG_trades");
      stats_Ranging.wins      = (int)GlobalVariableGet(pfx + "RG_wins");
      stats_Ranging.totalProfit = GlobalVariableGet(pfx + "RG_profit");
      stats_Ranging.totalLoss = GlobalVariableGet(pfx + "RG_loss");
   }

   // v6: State validation — detect corruption
   if(historicalWinRate < 0.05 || historicalWinRate > 0.99)
   {
      Print("STATE CORRUPT: WinRate=", historicalWinRate, " -- resetting to bootstrap");
      historicalWinRate = 0.50; historicalAvgWin = 2.0; historicalAvgLoss = 1.0;
      totalClosedTrades = 0;
   }
   if(historicalAvgWin <= 0 || historicalAvgLoss <= 0)
   {
      Print("STATE CORRUPT: AvgWin=", historicalAvgWin, " AvgLoss=", historicalAvgLoss, " -- resetting");
      historicalAvgWin = 2.0; historicalAvgLoss = 1.0;
   }
   if(peakBalance > accInfo.Balance() * 5.0)
   {
      Print("STATE SUSPECT: peakBalance=", peakBalance, " >> balance -- resetting");
      peakBalance = accInfo.Balance();
   }

   Print("STATE RESTORED: peak=", DoubleToString(peakBalance, 2),
         " trades=", tradesToday,
         " circuitBreaker=", circuitBreakerActive,
         " consecLosses=", consecutiveLosses,
         " | Kelly: WR=", DoubleToString(historicalWinRate*100, 1), "% closed=", totalClosedTrades);
}

//+------------------------------------------------------------------+
//| OnInit                                                             |
//+------------------------------------------------------------------+
int OnInit()
{
   if(InpRiskPercent <= 0 || InpRiskPercent > 5)
   { Print("ERROR: Risk% must be 0-5"); return INIT_PARAMETERS_INCORRECT; }
   if(InpATRMultSL <= 0 || InpMaxPositions <= 0)
   { Print("ERROR: Invalid parameters"); return INIT_PARAMETERS_INCORRECT; }

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(30);
   trade.SetMarginMode();
   trade.SetTypeFilling(DetectFillingMode());

   symInfo.Name(_Symbol);
   symInfo.Refresh();

   // v6: Use shared handle creation function
   if(!CreateIndicatorHandles())
   { Print("ERROR: Indicator handle creation failed"); return INIT_FAILED; }

   LoadState();
   if(peakBalance <= 0)       peakBalance = accInfo.Balance();
   if(dailyStartBalance <= 0) dailyStartBalance = accInfo.Balance();

   // v6: Kelly reset for fresh start after major changes
   if(InpResetKellyOnStart)
   {
      Print("KELLY RESET: Clearing all stats for fresh start");
      historicalWinRate = 0.50;
      historicalAvgWin = 2.0;
      historicalAvgLoss = 1.0;
      totalClosedTrades = 0;
      totalWins = 0;
      totalLosses = 0;
      sumWinR = 0;
      sumLossR = 0;
      ZeroMemory(stats_StrongTrend);
      ZeroMemory(stats_WeakTrend);
      ZeroMemory(stats_Ranging);
   }

   // v6: Recover any orphan positions not in tracker
   ReconcilePositions();

   Print("=== AdaptiveRegimeEA v6.0 initialized ===");
   Print("Symbol=", _Symbol, " | Fill=", EnumToString(DetectFillingMode()),
         " | Tester=", (MQLInfoInteger(MQL_TESTER) ? "YES" : "NO"));
   Print("Risk=", InpRiskPercent, "% | Kelly=", (InpUseKellyCriterion ? "ON" : "OFF"),
         " (", DoubleToString(InpKellyFraction*100, 0), "%) RegimeKelly=",
         (InpUseRegimeKelly ? "ON" : "OFF"));
   Print("R:R Ratios: Trend ", DoubleToString(InpATRMultTP/InpATRMultSL, 1), ":1",
         " | MR ", DoubleToString(InpMR_ATRTP/InpMR_ATRSL, 1), ":1");
   Print("Trade Mgmt: BE=", InpBreakEvenATR, "ATR Trail=", InpTrailActivateATR,
         "ATR Partial=", InpPartialCloseATR, "ATR");

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| OnDeinit                                                           |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   SaveState();
   ReleaseIndicatorHandles();
   ObjectsDeleteAll(0, "AREA_");
   Comment("");
}

//+------------------------------------------------------------------+
//| OnTick                                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   symInfo.Refresh();
   symInfo.RefreshRates();

   // v6: Connection drop detection
   datetime now = TimeCurrent();
   if(lastSuccessfulTick > 0 && (now - lastSuccessfulTick) > 300)
   {
      connectionDropCount++;
      Print("CONNECTION: Gap of ", (now - lastSuccessfulTick),
            "s detected (drop #", connectionDropCount, ")");
      if(!ValidateIndicatorHandles())
      {
         Print("CONNECTION RECOVERY: Handle validation failed, skipping");
         lastSuccessfulTick = now;
         return;
      }
      ReconcilePositions();
   }
   lastSuccessfulTick = now;

   CheckNewDay();

   double bal = accInfo.Balance();
   if(bal > peakBalance) peakBalance = bal;

   CheckCircuitBreakers();
   ManageOpenPositions();

   // New bar gate (MTF)
   datetime barTime = iTime(_Symbol, InpMTF, 0);
   if(barTime == lastBarTime) return;
   lastBarTime = barTime;

   // v6: Validate indicator handles on each new bar
   if(!ValidateIndicatorHandles())
   {
      Print("BLOCKED: Indicator handles invalid, waiting for self-heal");
      return;
   }

   if(InpVerboseLog) Print("--- NEW BAR ", TimeToString(barTime), " ---");

   // Pre-signal checks
   if(InpUseSessionFilter && !IsWithinSession())
   {
      if(InpVerboseLog) Print("BLOCKED: Outside session hours");
      return;
   }
   if(circuitBreakerActive || dailyLossLimitHit)
   {
      if(InpVerboseLog) Print("BLOCKED: Circuit breaker or daily loss limit");
      return;
   }
   if(tradesToday >= InpMaxTradesPerDay)
   {
      if(InpVerboseLog) Print("BLOCKED: Max trades per day reached (", tradesToday, "/", InpMaxTradesPerDay, ")");
      return;
   }

   cachedPosCount = CountPositions();
   if(cachedPosCount >= InpMaxPositions)
   {
      if(InpVerboseLog) Print("BLOCKED: Max positions reached (", cachedPosCount, "/", InpMaxPositions, ")");
      return;
   }

   cachedTotalRisk = GetTotalRiskPercent();
   if(cachedTotalRisk >= InpMaxRiskPercent)
   {
      if(InpVerboseLog) Print("BLOCKED: Max risk reached (", DoubleToString(cachedTotalRisk, 2), "%/", InpMaxRiskPercent, "%)");
      return;
   }

   if(IsCooldownActive())
   {
      if(InpVerboseLog) Print("BLOCKED: Cooldown active");
      return;
   }

   // --- CORE LOGIC ---
   currentRegime = DetectRegime();
   currentTrend  = DetectTrendDirection();

   if(InpVerboseLog)
      Print("STATE: Regime=", RegimeToString(currentRegime), " | Trend=", TrendToString(currentTrend));

   ENUM_SIGNAL signal = SIGNAL_NONE;
   if(currentRegime == REGIME_STRONG_TREND || currentRegime == REGIME_WEAK_TREND)
   {
      signal = GenerateTrendSignal();
      if(InpVerboseLog && signal == SIGNAL_NONE)
         Print("NO TREND SIGNAL generated");
   }
   else if(currentRegime == REGIME_RANGING)
   {
      signal = GenerateMeanReversionSignal();
      if(InpVerboseLog && signal == SIGNAL_NONE)
         Print("NO MR SIGNAL generated");
   }
   else if(currentRegime == REGIME_VOLATILE && InpAllowVolatileTrades)
   {
      signal = GenerateTrendSignal();
      if(InpVerboseLog && signal != SIGNAL_NONE)
         Print("VOLATILE SIGNAL: ", (signal == SIGNAL_BUY ? "BUY" : "SELL"), " (reduced size)");
      else if(InpVerboseLog && signal == SIGNAL_NONE)
         Print("NO VOLATILE SIGNAL generated");
   }
   else
   {
      if(InpVerboseLog)
         Print("NO SIGNAL: Regime is ", RegimeToString(currentRegime), " (VOLATILE or UNKNOWN)");
   }

   // Spread-cost gate
   if(signal != SIGNAL_NONE && !IsSpreadAcceptable())
   {
      if(InpVerboseLog) Print("BLOCKED: Spread filter rejected signal");
      signal = SIGNAL_NONE;
   }

   // Quality scoring filter
   double quality = 0;
   if(signal != SIGNAL_NONE)
   {
      quality = CalculateTradeQuality(signal);
      double qualityThreshold = InpDiagnosticMode ? 0.40 : InpMinTradeQuality;
      if(quality < qualityThreshold)
      {
         Print("BLOCKED: Quality filter: ", DoubleToString(quality, 2), " < ", DoubleToString(qualityThreshold, 2),
               (InpDiagnosticMode ? " [DIAG MODE]" : ""));
         signal = SIGNAL_NONE;
      }
      else
      {
         if(InpVerboseLog) Print("Quality OK: ", DoubleToString(quality, 2), " >= ", DoubleToString(qualityThreshold, 2));
      }
   }

   if(signal != SIGNAL_NONE)
   {
      Print(">>> SIGNAL: ", (signal == SIGNAL_BUY ? "BUY" : "SELL"),
            " | Regime=", RegimeToString(currentRegime),
            " | Trend=", TrendToString(currentTrend),
            " | Quality=", DoubleToString(quality, 2));
      ExecuteTrade(signal, quality);
   }

   if(InpShowDashboard) DrawDashboard();
}

//+------------------------------------------------------------------+
//| OnTradeTransaction - Track wins/losses for cooldown + journal     |
//| v5.1: Uses entry ATR, skips partial closes for Kelly updates      |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;
   ulong dealTicket = trans.deal;
   if(dealTicket == 0) return;

   if(!HistoryDealSelect(dealTicket)) return;

   long dealMagic  = HistoryDealGetInteger(dealTicket, DEAL_MAGIC);
   long dealEntry  = HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
   string dealSym  = HistoryDealGetString(dealTicket, DEAL_SYMBOL);

   if(dealMagic != InpMagicNumber || dealSym != _Symbol) return;
   if(dealEntry != DEAL_ENTRY_OUT && dealEntry != DEAL_ENTRY_OUT_BY) return;

   double profit = HistoryDealGetDouble(dealTicket, DEAL_PROFIT)
                 + HistoryDealGetDouble(dealTicket, DEAL_SWAP)
                 + HistoryDealGetDouble(dealTicket, DEAL_COMMISSION);

   // Find regime this trade was opened under + analytics
   ulong posId = (ulong)HistoryDealGetInteger(dealTicket, DEAL_POSITION_ID);
   ENUM_REGIME tradeRegime = REGIME_UNKNOWN;
   double mae = 0, mfe = 0, quality = 0;
   double entryATR = 0;

   for(int i = 0; i < ArraySize(activeTracker); i++)
   {
      if(activeTracker[i].ticket == posId)
      {
         tradeRegime = activeTracker[i].regime;
         mae = activeTracker[i].maxMAE;
         mfe = activeTracker[i].maxMFE;
         quality = activeTracker[i].qualityScore;
         entryATR = activeTracker[i].entryATR;
         break;
      }
   }

   // v5.1: Calculate SL distance using ENTRY ATR (not current ATR)
   double slDist = 0;
   if(entryATR > 0)
      slDist = (tradeRegime == REGIME_RANGING) ? entryATR * InpMR_ATRSL : entryATR * InpATRMultSL;

   // Calculate R-multiple
   double rMultiple = 0;
   if(slDist > 0)
   {
      double tv = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
      double ts = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
      double vol = HistoryDealGetDouble(dealTicket, DEAL_VOLUME);
      if(ts > 0 && tv > 0 && vol > 0)
         rMultiple = profit / ((slDist / ts) * tv * vol);
   }

   // v5.1: Check if this is a partial close (position still exists)
   bool isPartialClose = PositionSelectByTicket(posId);

   // v5.1: Only update Kelly stats on FINAL close (not partial closes)
   if(!isPartialClose && slDist > 0)
   {
      totalClosedTrades++;

      // v5.1: Use simple running average for first 30 trades, then EMA
      if(totalClosedTrades <= 30)
      {
         // Simple arithmetic average (stable with small samples)
         if(profit > 0)
         {
            totalWins++;
            sumWinR += MathAbs(rMultiple);
         }
         else
         {
            totalLosses++;
            sumLossR += MathAbs(rMultiple);
         }
         historicalWinRate = (double)totalWins / totalClosedTrades;
         if(totalWins > 0) historicalAvgWin = sumWinR / totalWins;
         if(totalLosses > 0) historicalAvgLoss = sumLossR / totalLosses;
      }
      else
      {
         // EMA with fixed small alpha (stable)
         double alpha = 0.05;
         if(profit > 0)
         {
            historicalWinRate = historicalWinRate * (1.0 - alpha) + alpha * 1.0;
            historicalAvgWin = historicalAvgWin * (1.0 - alpha) + alpha * MathAbs(rMultiple);
         }
         else
         {
            historicalWinRate = historicalWinRate * (1.0 - alpha) + alpha * 0.0;
            historicalAvgLoss = historicalAvgLoss * (1.0 - alpha) + alpha * MathAbs(rMultiple);
         }
      }
      // v6: Removed WR floor — with fixed b-ratio (>1.5), even 45% WR is profitable.
      // The floor masked genuine edge loss and prevented Kelly from properly sizing down.
   }

   // Update regime-specific statistics (include partial closes for P&L tracking)
   // v6: Also accumulate R-multiples for regime-specific Kelly
   if(tradeRegime == REGIME_STRONG_TREND)
   {
      stats_StrongTrend.trades++;
      if(profit > 0)
      {
         stats_StrongTrend.wins++; stats_StrongTrend.totalProfit += profit;
         if(!isPartialClose && slDist > 0) { stats_StrongTrend.winCount++; stats_StrongTrend.sumWinR += MathAbs(rMultiple); }
      }
      else
      {
         stats_StrongTrend.totalLoss += MathAbs(profit);
         if(!isPartialClose && slDist > 0) { stats_StrongTrend.lossCount++; stats_StrongTrend.sumLossR += MathAbs(rMultiple); }
      }
      stats_StrongTrend.avgWin = (stats_StrongTrend.wins > 0) ? stats_StrongTrend.totalProfit / stats_StrongTrend.wins : 0;
      stats_StrongTrend.avgLoss = ((stats_StrongTrend.trades - stats_StrongTrend.wins) > 0) ? stats_StrongTrend.totalLoss / (stats_StrongTrend.trades - stats_StrongTrend.wins) : 0;
      stats_StrongTrend.profitFactor = (stats_StrongTrend.totalLoss > 0) ? stats_StrongTrend.totalProfit / stats_StrongTrend.totalLoss : 0;
   }
   else if(tradeRegime == REGIME_WEAK_TREND)
   {
      stats_WeakTrend.trades++;
      if(profit > 0)
      {
         stats_WeakTrend.wins++; stats_WeakTrend.totalProfit += profit;
         if(!isPartialClose && slDist > 0) { stats_WeakTrend.winCount++; stats_WeakTrend.sumWinR += MathAbs(rMultiple); }
      }
      else
      {
         stats_WeakTrend.totalLoss += MathAbs(profit);
         if(!isPartialClose && slDist > 0) { stats_WeakTrend.lossCount++; stats_WeakTrend.sumLossR += MathAbs(rMultiple); }
      }
      stats_WeakTrend.avgWin = (stats_WeakTrend.wins > 0) ? stats_WeakTrend.totalProfit / stats_WeakTrend.wins : 0;
      stats_WeakTrend.avgLoss = ((stats_WeakTrend.trades - stats_WeakTrend.wins) > 0) ? stats_WeakTrend.totalLoss / (stats_WeakTrend.trades - stats_WeakTrend.wins) : 0;
      stats_WeakTrend.profitFactor = (stats_WeakTrend.totalLoss > 0) ? stats_WeakTrend.totalProfit / stats_WeakTrend.totalLoss : 0;
   }
   else if(tradeRegime == REGIME_RANGING)
   {
      stats_Ranging.trades++;
      if(profit > 0)
      {
         stats_Ranging.wins++; stats_Ranging.totalProfit += profit;
         if(!isPartialClose && slDist > 0) { stats_Ranging.winCount++; stats_Ranging.sumWinR += MathAbs(rMultiple); }
      }
      else
      {
         stats_Ranging.totalLoss += MathAbs(profit);
         if(!isPartialClose && slDist > 0) { stats_Ranging.lossCount++; stats_Ranging.sumLossR += MathAbs(rMultiple); }
      }
      stats_Ranging.avgWin = (stats_Ranging.wins > 0) ? stats_Ranging.totalProfit / stats_Ranging.wins : 0;
      stats_Ranging.avgLoss = ((stats_Ranging.trades - stats_Ranging.wins) > 0) ? stats_Ranging.totalLoss / (stats_Ranging.trades - stats_Ranging.wins) : 0;
      stats_Ranging.profitFactor = (stats_Ranging.totalLoss > 0) ? stats_Ranging.totalProfit / stats_Ranging.totalLoss : 0;
   }

   // Consecutive loss tracking (only on final close)
   if(!isPartialClose)
   {
      if(profit < 0)
      {
         consecutiveLosses++;
         lastLossTime = TimeCurrent();
         Print("LOSS #", consecutiveLosses, ": $", DoubleToString(profit, 2),
               " | R=", DoubleToString(rMultiple, 2),
               " | Regime=", RegimeToString(tradeRegime));
      }
      else if(profit > 0)
      {
         if(consecutiveLosses > 0)
            Print("Win streak reset (was ", consecutiveLosses, " consecutive losses)");
         consecutiveLosses = 0;
         Print("WIN: $", DoubleToString(profit, 2),
               " | R=", DoubleToString(rMultiple, 2),
               " | MFE=", DoubleToString(mfe, _Digits),
               " | MAE=", DoubleToString(mae, _Digits));
      }
   }

   // Structured trade journal
   Print("TRADE_JOURNAL|", (isPartialClose ? "PARTIAL|" : "FINAL|"),
         "regime=", RegimeToString(tradeRegime),
         "|profit=", DoubleToString(profit, 2),
         "|rMultiple=", DoubleToString(rMultiple, 2),
         "|mae=", DoubleToString(mae, _Digits),
         "|mfe=", DoubleToString(mfe, _Digits),
         "|quality=", DoubleToString(quality, 2),
         "|posId=", posId);

   SaveState();
}

//+------------------------------------------------------------------+
//| REGIME DETECTION WITH HYSTERESIS                                   |
//| v5.1: Eliminated UNKNOWN dead zone - HTF/MTF disagreement now     |
//| classifies as WEAK_TREND instead of UNKNOWN                        |
//+------------------------------------------------------------------+
ENUM_REGIME DetectRegime()
{
   double adx_htf[], adx_mtf[];
   double bb_upper[], bb_lower[], bb_mid[];
   ArraySetAsSeries(adx_htf, true); ArraySetAsSeries(adx_mtf, true);
   ArraySetAsSeries(bb_upper, true); ArraySetAsSeries(bb_lower, true); ArraySetAsSeries(bb_mid, true);

   int need = InpRegimeLookback + 1;
   if(SafeCopyBuffer(h_ADX_HTF, 0, 0, need, adx_htf) < need) return currentRegime;
   if(SafeCopyBuffer(h_ADX_MTF, 0, 0, need, adx_mtf) < need) return currentRegime;
   if(SafeCopyBuffer(h_BB_MTF, 1, 0, need, bb_upper) < need) return currentRegime;
   if(SafeCopyBuffer(h_BB_MTF, 2, 0, need, bb_lower) < need) return currentRegime;
   if(SafeCopyBuffer(h_BB_MTF, 0, 0, need, bb_mid)   < need) return currentRegime;

   // Use bar[1] - last COMPLETED bar
   double adxNow = adx_htf[1];
   double adxMTF = adx_mtf[1];

   double bbWidth = 0;
   if(bb_mid[1] > 0)
      bbWidth = (bb_upper[1] - bb_lower[1]) / bb_mid[1] * 100.0;

   double avgBBW = 0;
   int cnt = 0;
   for(int i = 1; i <= InpRegimeLookback; i++)
   {
      if(bb_mid[i] > 0)
      { avgBBW += (bb_upper[i] - bb_lower[i]) / bb_mid[i] * 100.0; cnt++; }
   }
   if(cnt > 0) avgBBW /= cnt;

   if(InpVerboseLog)
      Print("Regime: ADX_H=", DoubleToString(adxNow, 1),
            " ADX_M=", DoubleToString(adxMTF, 1),
            " BBW=", DoubleToString(bbWidth, 3));

   // Raw classification - v5.1: No more UNKNOWN dead zones
   ENUM_REGIME rawRegime;
   if(bbWidth > avgBBW * 2.0 && adxNow > InpADXStrongThresh)
      rawRegime = REGIME_VOLATILE;
   else if(adxNow >= InpADXStrongThresh)
      rawRegime = REGIME_STRONG_TREND;
   else if(adxNow >= InpADXTrendThresh && adxMTF >= InpADXTrendThresh)
      rawRegime = REGIME_WEAK_TREND;
   else if(adxNow < InpADXTrendThresh && adxMTF < InpADXTrendThresh)
      rawRegime = REGIME_RANGING;
   // v5.1: When HTF/MTF ADX disagree (one trending, one not) -> WEAK_TREND
   else if(adxNow >= InpADXTrendThresh || adxMTF >= InpADXTrendThresh)
      rawRegime = REGIME_WEAK_TREND;
   else
      rawRegime = REGIME_RANGING;

   // VOLATILE is immediate (safety override)
   if(rawRegime == REGIME_VOLATILE)
   { pendingRegime = rawRegime; regimeConfirmCount = InpRegimeConfirmBars; return REGIME_VOLATILE; }

   // Hysteresis
   if(rawRegime == pendingRegime)
      regimeConfirmCount++;
   else
   { pendingRegime = rawRegime; regimeConfirmCount = 1; }

   if(regimeConfirmCount >= InpRegimeConfirmBars)
   {
      if(currentRegime != pendingRegime)
         Print("REGIME CHANGE: ", RegimeToString(currentRegime), " -> ", RegimeToString(pendingRegime));
      return pendingRegime;
   }

   return currentRegime; // Not yet confirmed
}

//+------------------------------------------------------------------+
//| TREND DIRECTION - Multi-TF EMA (bar[1] only)                     |
//| v5.1: Tier 3 granted to STRONG_TREND + Tier 4 EMA slope fallback |
//+------------------------------------------------------------------+
ENUM_TREND_DIR DetectTrendDirection()
{
   double emaFast_H[], emaMed_H[], emaSlow_H[];
   double emaFast_M[], emaMed_M[];
   ArraySetAsSeries(emaFast_H, true); ArraySetAsSeries(emaMed_H, true); ArraySetAsSeries(emaSlow_H, true);
   ArraySetAsSeries(emaFast_M, true); ArraySetAsSeries(emaMed_M, true);

   if(SafeCopyBuffer(h_EMA_Fast_HTF, 0, 0, 3, emaFast_H) < 3) return TREND_NEUTRAL;
   if(SafeCopyBuffer(h_EMA_Med_HTF,  0, 0, 3, emaMed_H)  < 3) return TREND_NEUTRAL;
   if(SafeCopyBuffer(h_EMA_Slow_HTF, 0, 0, 3, emaSlow_H) < 3) return TREND_NEUTRAL;
   if(SafeCopyBuffer(h_EMA_Fast_MTF, 0, 0, 3, emaFast_M) < 3) return TREND_NEUTRAL;
   if(SafeCopyBuffer(h_EMA_Med_MTF,  0, 0, 3, emaMed_M)  < 3) return TREND_NEUTRAL;

   // Use bar[1] for completed data
   bool htfBull = (emaFast_H[1] > emaMed_H[1] && emaMed_H[1] > emaSlow_H[1]);
   bool htfBear = (emaFast_H[1] < emaMed_H[1] && emaMed_H[1] < emaSlow_H[1]);
   bool mtfBull = (emaFast_M[1] > emaMed_M[1]);
   bool mtfBear = (emaFast_M[1] < emaMed_M[1]);

   double close_htf[];
   ArraySetAsSeries(close_htf, true);
   if(SafeCopyClose(_Symbol, InpHTF, 0, 2, close_htf) < 2) return TREND_NEUTRAL;
   bool priceAbove = (close_htf[1] > emaSlow_H[1]);
   bool priceBelow = (close_htf[1] < emaSlow_H[1]);

   // Tier 1: Full EMA fan + MTF confirmation (strongest)
   if(htfBull && mtfBull) return TREND_BULLISH;
   if(htfBear && mtfBear) return TREND_BEARISH;

   // Tier 2: HTF fan + price position
   if(htfBull && priceAbove) return TREND_BULLISH;
   if(htfBear && priceBelow) return TREND_BEARISH;

   // Tier 3: Price position + MTF alignment (v5.1: now available for ALL trending regimes)
   if(currentRegime == REGIME_STRONG_TREND || currentRegime == REGIME_WEAK_TREND)
   {
      if(priceAbove && mtfBull) return TREND_BULLISH;
      if(priceBelow && mtfBear) return TREND_BEARISH;
   }

   // v5.1 Tier 4: EMA55 slope + price position (for STRONG_TREND during pullbacks)
   if(currentRegime == REGIME_STRONG_TREND)
   {
      bool slowRising  = (emaSlow_H[1] > emaSlow_H[2]);
      bool slowFalling = (emaSlow_H[1] < emaSlow_H[2]);
      if(priceAbove && slowRising)  return TREND_BULLISH;
      if(priceBelow && slowFalling) return TREND_BEARISH;
   }

   return TREND_NEUTRAL;
}

//+------------------------------------------------------------------+
//| TREND SIGNAL - Pullback entry (bar[1]/[2] only, no look-ahead)   |
//| v5.2: Extended wasAbove/Below lookback to bars 2-6 (was 3-4),    |
//| lowered rsiOK buy threshold to 35, raised sell to 65              |
//+------------------------------------------------------------------+
ENUM_SIGNAL GenerateTrendSignal()
{
   if(currentTrend == TREND_NEUTRAL) return SIGNAL_NONE;

   double rsi_mtf[], rsi_ltf[], emaFast_M[], emaMed_M[];
   double close_m[], high_m[], low_m[], atr_m[];
   ArraySetAsSeries(rsi_mtf, true); ArraySetAsSeries(rsi_ltf, true);
   ArraySetAsSeries(emaFast_M, true); ArraySetAsSeries(emaMed_M, true);
   ArraySetAsSeries(close_m, true); ArraySetAsSeries(high_m, true);
   ArraySetAsSeries(low_m, true); ArraySetAsSeries(atr_m, true);

   if(SafeCopyBuffer(h_RSI_MTF, 0, 0, 8, rsi_mtf) < 8) return SIGNAL_NONE;
   if(SafeCopyBuffer(h_RSI_LTF, 0, 0, 8, rsi_ltf) < 8) return SIGNAL_NONE;
   if(SafeCopyBuffer(h_EMA_Fast_MTF, 0, 0, 8, emaFast_M) < 8) return SIGNAL_NONE;
   if(SafeCopyBuffer(h_EMA_Med_MTF, 0, 0, 8, emaMed_M) < 8) return SIGNAL_NONE;
   if(SafeCopyBuffer(h_ATR_MTF, 0, 0, 8, atr_m) < 8) return SIGNAL_NONE;
   if(SafeCopyClose(_Symbol, InpMTF, 0, 8, close_m) < 8) return SIGNAL_NONE;
   if(SafeCopyHigh(_Symbol, InpMTF, 0, 8, high_m)  < 8) return SIGNAL_NONE;
   if(SafeCopyLow(_Symbol, InpMTF, 0, 8, low_m)    < 8) return SIGNAL_NONE;

   // v5.1: Widened pullback zone from 1.0 to 1.5 ATR
   double pullbackATR = InpDiagnosticMode ? atr_m[2] * 2.0 : atr_m[2] * 1.5;

   // BULLISH: bar[2] pulled back near EMA21, bar[1] recovered
   if(currentTrend == TREND_BULLISH)
   {
      double zone = emaMed_M[2] + pullbackATR;
      bool pulledBack    = (low_m[2] <= zone);
      // v5.2: Extended lookback to bars 2-6 (was 3-4) to survive multi-bar pullbacks
      bool wasAbove      = (close_m[2] > emaMed_M[2]) || (close_m[3] > emaMed_M[3])
                        || (close_m[4] > emaMed_M[4]) || (close_m[5] > emaMed_M[5])
                        || (close_m[6] > emaMed_M[6]);
      bool recovered     = (close_m[1] > close_m[2]);
      bool notOverbought = (rsi_mtf[1] < InpTrendRSIOB);
      // v5.2: Lowered from 40 to 35 (RSI 35-40 during pullback is a buy signal, not a reject)
      bool rsiOK         = (rsi_ltf[1] > 35);

      if(InpVerboseLog)
         Print("T_BUY: pulled=", pulledBack, " above=", wasAbove,
               " recov=", recovered, " !OB=", notOverbought, " rsi=", rsiOK,
               (InpDiagnosticMode ? " [DIAG MODE]" : ""));

      // v5.1: Removed momentum candle shape filter (redundant with recovered, too restrictive)
      if(pulledBack && wasAbove && recovered && notOverbought && rsiOK)
         return SIGNAL_BUY;
   }

   // BEARISH: bar[2] pulled back near EMA21, bar[1] fell
   if(currentTrend == TREND_BEARISH)
   {
      double zone = emaMed_M[2] - pullbackATR;
      bool pulledBack  = (high_m[2] >= zone);
      // v5.2: Extended lookback to bars 2-6 (was 3-4) to survive multi-bar pullbacks
      bool wasBelow    = (close_m[2] < emaMed_M[2]) || (close_m[3] < emaMed_M[3])
                      || (close_m[4] < emaMed_M[4]) || (close_m[5] < emaMed_M[5])
                      || (close_m[6] < emaMed_M[6]);
      bool fell        = (close_m[1] < close_m[2]);
      bool notOversold = (rsi_mtf[1] > InpTrendRSIOS);
      // v5.2: Raised from 60 to 65 (RSI 60-65 during pullback is a sell signal, not a reject)
      bool rsiOK       = (rsi_ltf[1] < 65);

      if(InpVerboseLog)
         Print("T_SELL: pulled=", pulledBack, " below=", wasBelow,
               " fell=", fell, " !OS=", notOversold, " rsi=", rsiOK,
               (InpDiagnosticMode ? " [DIAG MODE]" : ""));

      // v5.1: Removed momentum candle shape filter
      if(pulledBack && wasBelow && fell && notOversold && rsiOK)
         return SIGNAL_SELL;
   }
   return SIGNAL_NONE;
}

//+------------------------------------------------------------------+
//| MEAN REVERSION SIGNAL                                              |
//| v5.1: Relaxed from AND(4) to BB_touch + OR(oscillator) + OR(turn)|
//+------------------------------------------------------------------+
ENUM_SIGNAL GenerateMeanReversionSignal()
{
   double bb_u[], bb_l[], bb_m[], rsi[], stK[], stD[], cl[];
   ArraySetAsSeries(bb_u, true); ArraySetAsSeries(bb_l, true); ArraySetAsSeries(bb_m, true);
   ArraySetAsSeries(rsi, true); ArraySetAsSeries(stK, true); ArraySetAsSeries(stD, true);
   ArraySetAsSeries(cl, true);

   if(SafeCopyBuffer(h_BB_MTF, 1, 0, 4, bb_u) < 4) return SIGNAL_NONE;
   if(SafeCopyBuffer(h_BB_MTF, 2, 0, 4, bb_l) < 4) return SIGNAL_NONE;
   if(SafeCopyBuffer(h_BB_MTF, 0, 0, 4, bb_m) < 4) return SIGNAL_NONE;
   if(SafeCopyBuffer(h_RSI_LTF, 0, 0, 4, rsi) < 4) return SIGNAL_NONE;
   if(SafeCopyBuffer(h_Stoch_MTF, 0, 0, 4, stK) < 4) return SIGNAL_NONE;
   if(SafeCopyBuffer(h_Stoch_MTF, 1, 0, 4, stD) < 4) return SIGNAL_NONE;
   if(SafeCopyClose(_Symbol, InpMTF, 0, 4, cl) < 4) return SIGNAL_NONE;

   // BUY: bar[2] touched lower BB, bar[1] shows reversal
   // v6: Parameterized tolerance (was hardcoded 0.2%)
   bool touchLow = (cl[2] <= bb_l[2] * (1.0 + InpBBTouchTolerance));
   if(touchLow)
   {
      bool rsiOS     = (rsi[2] < InpMR_RSI_OS);
      bool stochOS   = (stK[2] < InpMR_StochOS);
      bool rsiTurn   = (rsi[1] > rsi[2]);
      bool stochTurn = (stK[1] > stK[2]);

      // v5.1: Require BB touch + at least ONE oscillator extreme + at least ONE turning
      bool hasExtreme = (rsiOS || stochOS);
      bool hasTurn    = (rsiTurn || stochTurn);

      if(InpVerboseLog)
         Print("MR_BUY: rsiOS=", rsiOS, " stOS=", stochOS,
               " rsiT=", rsiTurn, " stT=", stochTurn,
               " | extreme=", hasExtreme, " turn=", hasTurn);

      if(hasExtreme && hasTurn)
         return SIGNAL_BUY;
   }

   // SELL: bar[2] touched upper BB, bar[1] shows reversal
   // v6: Parameterized tolerance (was hardcoded 0.2%)
   bool touchHi = (cl[2] >= bb_u[2] * (1.0 - InpBBTouchTolerance));
   if(touchHi)
   {
      bool rsiOB     = (rsi[2] > InpMR_RSI_OB);
      bool stochOB   = (stK[2] > InpMR_StochOB);
      bool rsiFall   = (rsi[1] < rsi[2]);
      bool stochFall = (stK[1] < stK[2]);

      // v5.1: Require BB touch + at least ONE oscillator extreme + at least ONE turning
      bool hasExtreme = (rsiOB || stochOB);
      bool hasTurn    = (rsiFall || stochFall);

      if(InpVerboseLog)
         Print("MR_SELL: rsiOB=", rsiOB, " stOB=", stochOB,
               " rsiF=", rsiFall, " stF=", stochFall,
               " | extreme=", hasExtreme, " turn=", hasTurn);

      if(hasExtreme && hasTurn)
         return SIGNAL_SELL;
   }
   return SIGNAL_NONE;
}

//+------------------------------------------------------------------+
//| SPREAD COST FILTER                                                |
//+------------------------------------------------------------------+
bool IsSpreadAcceptable()
{
   double atr_v[];
   ArraySetAsSeries(atr_v, true);
   if(SafeCopyBuffer(h_ATR_MTF, 0, 0, 1, atr_v) < 1) return false;
   double atr = atr_v[0];
   if(atr <= 0) return false;

   double spread = symInfo.Spread() * _Point;
   double tpMult = (currentRegime == REGIME_RANGING) ? InpMR_ATRTP : InpATRMultTP;
   double expectedTP = atr * tpMult;
   if(expectedTP <= 0) return false;

   double costPct = (spread / expectedTP) * 100.0;
   double maxCost = (currentRegime == REGIME_RANGING) ? InpMaxSpreadCostMR : InpMaxSpreadCostPct;

   if(InpDiagnosticMode) maxCost *= 2.0;

   if(costPct > maxCost)
   {
      Print("SPREAD REJECT: cost=", DoubleToString(costPct, 1),
            "% of TP > ", DoubleToString(maxCost, 0), "%");
      return false;
   }
   return true;
}

//+------------------------------------------------------------------+
//| TRADE QUALITY SCORING (0-1 scale)                                |
//| v5.1: Uses bar[1] for ATR, session-aware bonus instead of        |
//| hardcoded hours                                                    |
//+------------------------------------------------------------------+
double CalculateTradeQuality(ENUM_SIGNAL signal)
{
   double score = 0.5; // Base score

   double adx[], rsi[], atr[];
   ArraySetAsSeries(adx, true); ArraySetAsSeries(rsi, true); ArraySetAsSeries(atr, true);

   if(SafeCopyBuffer(h_ADX_HTF, 0, 0, 3, adx) < 3) return score;
   if(SafeCopyBuffer(h_RSI_MTF, 0, 0, 3, rsi) < 3) return score;
   if(SafeCopyBuffer(h_ATR_MTF, 0, 0, 10, atr) < 10) return score;

   // 1. Trend strength (0-0.25 points)
   if(adx[1] >= InpADXStrongThresh) score += 0.25;
   else if(adx[1] >= InpADXTrendThresh) score += 0.15;

   // 2. RSI positioning (0-0.15 points)
   if(signal == SIGNAL_BUY)
   {
      if(rsi[1] > 40 && rsi[1] < 60) score += 0.15;
      else if(rsi[1] < 40) score += 0.10;
   }
   else
   {
      if(rsi[1] > 40 && rsi[1] < 60) score += 0.15;
      else if(rsi[1] > 60) score += 0.10;
   }

   // 3. Volatility stability (0-0.10 points) - v5.1: use bar[1] to avoid look-ahead
   double avgATR = 0;
   for(int i = 1; i <= 9; i++) avgATR += atr[i];
   avgATR /= 9;
   double atrRatio = (avgATR > 0) ? atr[1] / avgATR : 1.0;
   if(atrRatio > 0.8 && atrRatio < 1.3) score += 0.10;

   // 4. Regime confidence (0-0.10 points)
   if(regimeConfirmCount >= InpRegimeConfirmBars) score += 0.10;

   // 5. Session awareness (0-0.10 points) - v5.1: uses session filter config
   MqlDateTime dt; TimeCurrent(dt);
   if(dt.hour >= InpSessionStartHour && dt.hour < InpSessionEndHour)
      score += 0.05;
   // Bonus for overlap hours (typically highest liquidity)
   if(dt.hour >= 13 && dt.hour <= 16)
      score += 0.05;

   return MathMin(score, 1.0);
}

//+------------------------------------------------------------------+
//| EXPECTED VALUE CHECK                                              |
//| v5.2: Added 10% tolerance band for estimation noise. With ~60     |
//| trades, WR/avgW/avgL estimates have significant variance — a      |
//| marginally negative EV (e.g. -$0.30) is indistinguishable from   |
//| breakeven. Only block when EV is meaningfully negative.            |
//+------------------------------------------------------------------+
bool IsPositiveExpectedValue(double riskAmt, ENUM_REGIME regime = REGIME_UNKNOWN)
{
   if(totalClosedTrades < 30) return true;

   double wr = historicalWinRate;
   double aw = historicalAvgWin;
   double al = historicalAvgLoss;

   // v6: Use regime-specific stats when available
   if(InpUseRegimeKelly && regime != REGIME_UNKNOWN)
   {
      double regWR, regB;
      if(GetRegimeKelly(regime, regWR, regB))
      {
         wr = regWR;
         aw = regB;  // GetRegimeKelly returns b-ratio (avgWin/avgLoss)
         al = 1.0;   // Normalize: avgLoss=1.0, avgWin=b
      }
   }

   double avgWinDollars = riskAmt * aw;
   double avgLossDollars = riskAmt * al;

   double ev = (wr * avgWinDollars) - ((1.0 - wr) * avgLossDollars);

   // v5.2: Tolerance band — allow EV down to -10% of risk amount (noise margin)
   double tolerance = riskAmt * 0.10;

   if(InpVerboseLog && ev < -tolerance)
      Print("NEGATIVE EV: $", DoubleToString(ev, 2),
            " (tol=$", DoubleToString(-tolerance, 2), ")",
            " WR=", DoubleToString(wr*100,1), "%",
            " avgW=", DoubleToString(aw, 2),
            " avgL=", DoubleToString(al, 2),
            " regime=", RegimeToString(regime),
            " trades=", totalClosedTrades);

   return ev > -tolerance;
}

//+------------------------------------------------------------------+
//| POST-LOSS COOLDOWN                                                |
//| v5.1: Capped multiplier at 2x (was 3x - too aggressive)          |
//+------------------------------------------------------------------+
bool IsCooldownActive()
{
   if(consecutiveLosses < 2) return false;
   // v5.1: Cap at 2x (was 3x - 15 bars was too long, missed recovery moves)
   int mult = (consecutiveLosses >= InpMaxConsecLosses) ? 2 : 1;
   int bars = InpCooldownBars * mult;
   if(lastLossTime > 0)
   {
      int elapsed = Bars(_Symbol, InpMTF, lastLossTime, TimeCurrent()) - 1;
      if(elapsed < bars)
      {
         if(InpVerboseLog)
            Print("COOLDOWN: ", consecutiveLosses, " losses, ",
                  elapsed, "/", bars, " bars");
         return true;
      }
      consecutiveLosses = 0;
   }
   return false;
}

//+------------------------------------------------------------------+
//| EXECUTE TRADE with retry logic                                     |
//| v5.1: Kelly negative -> reduce risk, EV blocking re-enabled       |
//+------------------------------------------------------------------+
void ExecuteTrade(ENUM_SIGNAL signal, double qualityScore = 0.7)
{
   if(signal == SIGNAL_NONE) return;
   ENUM_POSITION_TYPE dir = (signal == SIGNAL_BUY) ? POSITION_TYPE_BUY : POSITION_TYPE_SELL;
   if(HasPositionInDirection(dir)) return;

   double atr_v[];
   ArraySetAsSeries(atr_v, true);
   if(SafeCopyBuffer(h_ATR_MTF, 0, 0, 1, atr_v) < 1) return;
   double atr = atr_v[0];
   if(atr <= 0) return;

   // Regime-specific SL/TP
   double slDist, tpDist;
   if(currentRegime == REGIME_RANGING)
   { slDist = atr * InpMR_ATRSL; tpDist = atr * InpMR_ATRTP; }
   else
   { slDist = atr * InpATRMultSL; tpDist = atr * InpATRMultTP; }

   // Validate broker min stop
   long stopsLvl = 0;
   SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL, stopsLvl);
   double minStop = stopsLvl * _Point;
   if(slDist < minStop && minStop > 0) slDist = minStop * 1.1;

   // Kelly Criterion position sizing — v6: regime-specific when available
   double adjRisk = InpRiskPercent;

   if(InpUseKellyCriterion && totalClosedTrades >= 30)
   {
      double p = historicalWinRate;
      double b = (historicalAvgLoss > 0) ? historicalAvgWin / historicalAvgLoss : 2.0;
      string kellySource = "global";

      // v6: Try regime-specific Kelly first
      if(InpUseRegimeKelly)
      {
         double regWR, regB;
         if(GetRegimeKelly(currentRegime, regWR, regB))
         {
            p = regWR;
            b = regB;
            kellySource = RegimeToString(currentRegime);
         }
      }

      double q = 1.0 - p;
      double kellyPct = (p * b - q) / b;
      if(kellyPct > 0)
      {
         adjRisk = kellyPct * 100.0 * InpKellyFraction;
         adjRisk = MathMin(adjRisk, InpRiskPercent * 1.5); // Cap at 1.5x base
         adjRisk = MathMax(adjRisk, InpRiskPercent * 0.1);  // Minimum 10% of base

         if(InpVerboseLog)
            Print("Kelly[", kellySource, "]: WR=", DoubleToString(p*100,1), "% b=", DoubleToString(b,2),
                  " kelly=", DoubleToString(kellyPct*100,1), "% adj=", DoubleToString(adjRisk,2), "%");
      }
      else
      {
         adjRisk = InpRiskPercent * 0.25;
         if(InpVerboseLog)
            Print("Kelly NEGATIVE[", kellySource, "]: WR=", DoubleToString(p*100,1), "% b=", DoubleToString(b,2),
                  " -> reduced to ", DoubleToString(adjRisk,2), "%");
      }
   }

   // v6: Apply volatile regime risk multiplier
   if(currentRegime == REGIME_VOLATILE && InpAllowVolatileTrades)
      adjRisk *= InpVolatileRiskMult;

   double lotSize = CalcLots(slDist, adjRisk);
   if(lotSize <= 0) return;

   // v5.1: EV check re-enabled as blocking filter (inputs now corrected)
   double riskAmt = accInfo.Balance() * adjRisk / 100.0;
   if(!IsPositiveExpectedValue(riskAmt, currentRegime))
   {
      Print("SKIP: Negative expected value (WR=", DoubleToString(historicalWinRate*100,1),
            "% regime=", RegimeToString(currentRegime),
            " trades=", totalClosedTrades, ")");
      return;
   }

   // MinLot safety
   double minLot = symInfo.LotsMin();
   if(lotSize <= minLot)
   {
      double tv = symInfo.TickValue(); double ts = symInfo.TickSize();
      if(ts > 0 && tv > 0)
      {
         double actual = (slDist / ts) * tv * lotSize;
         double budget = accInfo.Balance() * adjRisk / 100.0;
         if(actual > budget * 1.5)
         { Print("SKIP: MinLot risk exceeds budget"); return; }
      }
   }

   string comment = InpTradeComment + "|" + RegimeToString(currentRegime);

   // Retry loop
   for(int attempt = 1; attempt <= 3; attempt++)
   {
      symInfo.RefreshRates();
      double entry, sl, tp;
      if(signal == SIGNAL_BUY)
      { entry = symInfo.Ask(); sl = NormalizeDouble(entry - slDist, _Digits); tp = NormalizeDouble(entry + tpDist, _Digits); }
      else
      { entry = symInfo.Bid(); sl = NormalizeDouble(entry + slDist, _Digits); tp = NormalizeDouble(entry - tpDist, _Digits); }

      Print("Attempt ", attempt, ": ", (signal == SIGNAL_BUY ? "BUY" : "SELL"),
            " @", DoubleToString(entry, _Digits), " SL=", DoubleToString(sl, _Digits),
            " TP=", DoubleToString(tp, _Digits), " Lots=", DoubleToString(lotSize, 2));

      bool ok;
      if(signal == SIGNAL_BUY) ok = trade.Buy(lotSize, _Symbol, 0, sl, tp, comment);
      else                     ok = trade.Sell(lotSize, _Symbol, 0, sl, tp, comment);

      uint rc = trade.ResultRetcode();
      if(ok && rc == TRADE_RETCODE_DONE)
      {
         tradesToday++;
         ulong ticket = trade.ResultOrder();
         Print("SUCCESS: ticket=", ticket);
         AddTradeRecord(ticket, currentRegime, signal, entry, qualityScore, atr);
         SaveState();
         return;
      }

      if(rc == TRADE_RETCODE_REQUOTE || rc == TRADE_RETCODE_PRICE_CHANGED || rc == TRADE_RETCODE_PRICE_OFF)
      { Print("Transient (", rc, "), retrying..."); Sleep(100 * attempt); continue; }

      if(rc == TRADE_RETCODE_INVALID_FILL)
      { trade.SetTypeFilling(ORDER_FILLING_RETURN); continue; }

      // v6: Specific handling for common permanent errors
      if(rc == TRADE_RETCODE_NO_MONEY)
      {
         Print("NO_MONEY: FreeMargin=$", DoubleToString(accInfo.FreeMargin(), 2),
               " Balance=$", DoubleToString(accInfo.Balance(), 2),
               " Lots=", DoubleToString(lotSize, 2));
         return;
      }
      if(rc == TRADE_RETCODE_MARKET_CLOSED)
      {
         Print("MARKET_CLOSED: resetting lastBarTime to force re-eval next bar");
         lastBarTime = 0;
         return;
      }

      Print("FAILED (permanent): ", rc, " ", trade.ResultRetcodeDescription());
      return;
   }
   Print("ABANDONED after 3 attempts");
}

//+------------------------------------------------------------------+
//| POSITION SIZING                                                    |
//+------------------------------------------------------------------+
double CalcLots(double slDist, double riskPct)
{
   if(slDist <= 0) return 0;
   double balance = accInfo.Balance();
   double riskAmt = balance * riskPct / 100.0;
   double tv = symInfo.TickValue(); double ts = symInfo.TickSize();
   if(tv <= 0 || ts <= 0) return 0;
   double slTicks = slDist / ts;
   if(slTicks <= 0) return 0;
   double lots = riskAmt / (slTicks * tv);
   double step = symInfo.LotsStep();
   if(step <= 0) step = 0.01;
   lots = MathFloor(lots / step) * step;
   lots = MathMax(lots, symInfo.LotsMin());
   lots = MathMin(lots, symInfo.LotsMax());
   return NormalizeDouble(lots, 2);
}

//+------------------------------------------------------------------+
//| MANAGE POSITIONS                                                   |
//| v5.1: Uses entry ATR + entry regime, skips redundant BE           |
//+------------------------------------------------------------------+
void ManageOpenPositions()
{
   PruneTracker();

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!posInfo.SelectByIndex(i)) continue;
      if(posInfo.Magic() != InpMagicNumber || posInfo.Symbol() != _Symbol) continue;

      ulong ticket = posInfo.Ticket();
      double openP = posInfo.PriceOpen();
      double curSL = posInfo.StopLoss();
      double curTP = posInfo.TakeProfit();
      ENUM_POSITION_TYPE pType = posInfo.PositionType();
      double curPrice = (pType == POSITION_TYPE_BUY) ? symInfo.Bid() : symInfo.Ask();
      double dist = (pType == POSITION_TYPE_BUY) ? (curPrice - openP) : (openP - curPrice);

      // v5.1: Look up entry ATR and entry regime from tracker
      double entryAtr = 0;
      ENUM_REGIME entryRegime = REGIME_UNKNOWN;
      for(int t = 0; t < ArraySize(activeTracker); t++)
      {
         if(activeTracker[t].ticket == ticket)
         {
            entryAtr = activeTracker[t].entryATR;
            entryRegime = activeTracker[t].regime;
            // Track MAE/MFE
            double mae = (pType == POSITION_TYPE_BUY) ? (openP - curPrice) : (curPrice - openP);
            double mfe = dist;
            if(mae > activeTracker[t].maxMAE) activeTracker[t].maxMAE = mae;
            if(mfe > activeTracker[t].maxMFE) activeTracker[t].maxMFE = mfe;
            break;
         }
      }

      // Fallback: if entry ATR not found, use current ATR
      if(entryAtr <= 0)
      {
         double atr_v[];
         ArraySetAsSeries(atr_v, true);
         if(SafeCopyBuffer(h_ATR_MTF, 0, 0, 1, atr_v) >= 1)
            entryAtr = atr_v[0];
         if(entryAtr <= 0) continue;
      }

      // 1. TIME EXIT (first - if closing, skip rest)
      if(InpMaxHoldBars > 0)
      {
         int held = Bars(_Symbol, InpMTF, posInfo.Time(), TimeCurrent()) - 1;
         if(held >= InpMaxHoldBars)
         {
            if(trade.PositionClose(ticket))
               Print("Time exit: #", ticket, " held ", held, " bars");
            else
               Print("Time exit FAILED: #", ticket, " rc=", trade.ResultRetcode());
            continue;
         }
      }

      // v6: Regime-specific trade management parameters
      double localBE_ATR     = InpBreakEvenATR;
      double localTrailAct   = InpTrailActivateATR;
      double localTrailDist  = InpTrailATRMult;
      double localPartialPct = InpPartialClosePct;
      double localPartialATR = InpPartialCloseATR;

      if(entryRegime == REGIME_STRONG_TREND)
      {
         localBE_ATR     = 2.5;
         localTrailAct   = 3.0;
         localTrailDist  = 1.5;
         localPartialPct = 25.0;
         localPartialATR = 3.5;
      }
      else if(entryRegime == REGIME_WEAK_TREND)
      {
         localBE_ATR     = 2.0;
         localTrailAct   = 2.5;
         localTrailDist  = 1.25;
         localPartialPct = 25.0;
         localPartialATR = 3.0;
      }
      else if(entryRegime == REGIME_RANGING)
      {
         localBE_ATR     = 1.0;
         localTrailAct   = 1.5;
         localTrailDist  = 0.5;
         localPartialPct = 0.0;  // No partial — TP too close at 2.0 ATR
         localPartialATR = 99.0; // Effectively disabled
      }
      // REGIME_UNKNOWN / REGIME_VOLATILE: use input defaults

      // 2. PARTIAL CLOSE - v6: Uses regime-specific parameters
      if(InpUsePartialClose && !IsPartialDone(ticket) && localPartialPct > 0)
      {
         bool allowPartial = true;
         if(InpPartialOnlyStrong && entryRegime != REGIME_STRONG_TREND)
            allowPartial = false;

         if(allowPartial && dist >= entryAtr * localPartialATR)
         {
            double cLots = NormalizeDouble(posInfo.Volume() * localPartialPct / 100.0, 2);
            double ml = symInfo.LotsMin();
            double ls = symInfo.LotsStep();
            if(ls > 0) cLots = MathFloor(cLots / ls) * ls;
            cLots = MathMax(cLots, ml);
            if(cLots < posInfo.Volume() && (posInfo.Volume() - cLots) >= ml)
            {
               if(trade.PositionClosePartial(ticket, cLots))
               { MarkPartialDone(ticket); Print("Partial: #", ticket, " ", cLots, " lots at +", DoubleToString(dist/entryAtr, 2), "R"); }
            }
            else MarkPartialDone(ticket);
         }
      }

      // v6: Determine if trailing will also fire (avoid redundant BE modify)
      bool trailingWillFire = (InpUseTrailingStop && dist >= entryAtr * localTrailAct);

      // 3. BREAK-EVEN - v6: Regime-specific threshold, skip if trailing fires
      if(InpUseBreakEven && !trailingWillFire && dist >= entryAtr * localBE_ATR)
      {
         double beOff = entryAtr * InpBreakEvenOffset;
         double newSL;
         bool mod = false;
         if(pType == POSITION_TYPE_BUY)
         { newSL = NormalizeDouble(openP + beOff, _Digits); mod = (curSL < newSL); }
         else
         { newSL = NormalizeDouble(openP - beOff, _Digits); mod = (curSL > newSL || curSL == 0); }
         if(mod)
         {
            if(trade.PositionModify(ticket, newSL, curTP))
               curSL = newSL;
         }
      }

      // 4. TRAILING STOP - v6: Regime-specific base trail, relaxed dynamic tightening
      if(trailingWillFire)
      {
         double trDist = entryAtr * localTrailDist;
         double rMultiple = dist / entryAtr;

         // v6: Relaxed dynamic trail — only tighten above 2.5R
         if(InpUseDynamicTrail)
         {
            if(rMultiple >= 4.0)      trDist = entryAtr * 0.75;
            else if(rMultiple >= 3.0) trDist = entryAtr * 1.0;
            else if(rMultiple >= 2.5) trDist = entryAtr * 1.25;
            // Below 2.5R: use localTrailDist (regime-specific base)
         }

         double newSL;
         bool mod = false;
         if(pType == POSITION_TYPE_BUY)
         { newSL = NormalizeDouble(curPrice - trDist, _Digits); mod = (newSL > curSL && newSL > openP); }
         else
         { newSL = NormalizeDouble(curPrice + trDist, _Digits); mod = ((newSL < curSL || curSL == 0) && newSL < openP); }
         if(mod)
         {
            if(trade.PositionModify(ticket, newSL, curTP))
               Print("Trail: #", ticket, " SL->", DoubleToString(newSL, _Digits), " @", DoubleToString(rMultiple, 1), "R");
         }
      }
   }
}

//+------------------------------------------------------------------+
//| CLOSE ALL with retry + exponential backoff                        |
//+------------------------------------------------------------------+
void CloseAllPositions()
{
   for(int attempt = 0; attempt < 5; attempt++)
   {
      int remaining = 0;
      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         if(!posInfo.SelectByIndex(i)) continue;
         if(posInfo.Magic() != InpMagicNumber || posInfo.Symbol() != _Symbol) continue;
         symInfo.RefreshRates();
         if(trade.PositionClose(posInfo.Ticket()) && trade.ResultRetcode() == TRADE_RETCODE_DONE)
            Print("Emergency close: #", posInfo.Ticket());
         else
            remaining++;
      }
      if(remaining == 0) return;
      Print("WARNING: ", remaining, " positions remain, retry ", attempt + 1);
      Sleep(500 * (int)MathPow(2, attempt));
   }
   Alert("CRITICAL: Failed to close all positions after 5 attempts!");
}

//+------------------------------------------------------------------+
//| CIRCUIT BREAKERS                                                   |
//+------------------------------------------------------------------+
void CheckCircuitBreakers()
{
   double equity = accInfo.Equity();
   if(peakBalance > 0)
   {
      double dd = (peakBalance - equity) / peakBalance * 100.0;
      if(dd >= InpMaxDrawdownPct)
      {
         if(!circuitBreakerActive)
         {
            circuitBreakerActive = true;
            Print("!!! CIRCUIT BREAKER: DD=", DoubleToString(dd, 2), "%");
            CloseAllPositions();
            SaveState();
         }
      }
      else if(dd < InpMaxDrawdownPct * 0.5 && circuitBreakerActive)
      {
         circuitBreakerActive = false;
         Print("Circuit breaker RESET: DD=", DoubleToString(dd, 2), "%");
         SaveState();
      }
   }

   if(dailyStartBalance > 0)
   {
      double dayLoss = (dailyStartBalance - equity) / dailyStartBalance * 100.0;
      if(dayLoss >= InpMaxDailyLossPct && !dailyLossLimitHit)
      {
         dailyLossLimitHit = true;
         Print("!!! DAILY LIMIT: ", DoubleToString(dayLoss, 2), "%");
         CloseAllPositions();
         SaveState();
      }
   }
}

//+------------------------------------------------------------------+
//| CHECK NEW DAY                                                      |
//+------------------------------------------------------------------+
void CheckNewDay()
{
   MqlDateTime dt; TimeCurrent(dt);
   datetime today = StringToTime(IntegerToString(dt.year) + "." +
                                  IntegerToString(dt.mon) + "." +
                                  IntegerToString(dt.day));
   if(today != lastDayCheck)
   {
      lastDayCheck = today;
      dailyStartBalance = accInfo.Balance();
      tradesToday = 0;
      dailyLossLimitHit = false;
      // Reset circuit breaker and peak on new day so DD measurement starts fresh
      if(circuitBreakerActive)
         Print("Circuit breaker RESET on new day (was active)");
      circuitBreakerActive = false;
      peakBalance = accInfo.Balance();
      Print("New day: ", TimeToString(today, TIME_DATE),
            " | Balance: ", DoubleToString(dailyStartBalance, 2));
      SaveState();
   }
}

//+------------------------------------------------------------------+
//| SESSION FILTER                                                     |
//+------------------------------------------------------------------+
bool IsWithinSession()
{
   MqlDateTime dt; TimeCurrent(dt);
   if(InpAvoidFriday && dt.day_of_week == 5 && dt.hour >= InpFridayCutoffHour) return false;
   if(dt.day_of_week == 0 || dt.day_of_week == 6) return false;
   if(InpSessionStartHour <= InpSessionEndHour)
      return (dt.hour >= InpSessionStartHour && dt.hour < InpSessionEndHour);
   return (dt.hour >= InpSessionStartHour || dt.hour < InpSessionEndHour);
}

//+------------------------------------------------------------------+
//| UTILITIES                                                          |
//+------------------------------------------------------------------+
int CountPositions()
{
   int c = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
      if(posInfo.SelectByIndex(i))
         if(posInfo.Magic() == InpMagicNumber && posInfo.Symbol() == _Symbol) c++;
   return c;
}

bool HasPositionInDirection(ENUM_POSITION_TYPE d)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
      if(posInfo.SelectByIndex(i))
         if(posInfo.Magic() == InpMagicNumber && posInfo.Symbol() == _Symbol)
            if(posInfo.PositionType() == d) return true;
   return false;
}

double GetTotalRiskPercent()
{
   double total = 0, balance = accInfo.Balance();
   if(balance <= 0) return 100;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!posInfo.SelectByIndex(i)) continue;
      if(posInfo.Magic() != InpMagicNumber) continue;
      double sl = posInfo.StopLoss(), op = posInfo.PriceOpen();
      if(sl == 0) continue;
      string sym = posInfo.Symbol();
      double tv = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE);
      double ts = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
      if(ts <= 0 || tv <= 0) continue;
      total += (MathAbs(op - sl) / ts) * tv * posInfo.Volume();
   }
   return (total / balance) * 100.0;
}

//+------------------------------------------------------------------+
//| TRADE RECORD TRACKER WITH GC                                      |
//| v5.1: Now stores entry ATR for consistent management/R-multiples  |
//+------------------------------------------------------------------+
void AddTradeRecord(ulong ticket, ENUM_REGIME regime, ENUM_SIGNAL dir, double openP, double quality, double atr)
{
   int s = ArraySize(activeTracker);
   ArrayResize(activeTracker, s + 1, 16);
   activeTracker[s].ticket      = ticket;
   activeTracker[s].partialDone = false;
   activeTracker[s].regime      = regime;
   activeTracker[s].direction   = dir;
   activeTracker[s].openPrice   = openP;
   activeTracker[s].openTime    = TimeCurrent();
   activeTracker[s].entryATR    = atr;
   activeTracker[s].maxMAE      = 0;
   activeTracker[s].maxMFE      = 0;
   activeTracker[s].qualityScore = quality;
}

bool IsPartialDone(ulong ticket)
{
   for(int i = 0; i < ArraySize(activeTracker); i++)
      if(activeTracker[i].ticket == ticket) return activeTracker[i].partialDone;
   return false;
}

void MarkPartialDone(ulong ticket)
{
   for(int i = 0; i < ArraySize(activeTracker); i++)
      if(activeTracker[i].ticket == ticket) { activeTracker[i].partialDone = true; return; }
}

void PruneTracker()
{
   if(TimeCurrent() - lastTrackerCleanup < 60) return;
   lastTrackerCleanup = TimeCurrent();
   int w = 0;
   for(int r = 0; r < ArraySize(activeTracker); r++)
   {
      if(PositionSelectByTicket(activeTracker[r].ticket))
      { if(w != r) activeTracker[w] = activeTracker[r]; w++; }
   }
   int removed = ArraySize(activeTracker) - w;
   if(removed > 0) ArrayResize(activeTracker, w);
}

string RegimeToString(ENUM_REGIME r)
{
   switch(r)
   {
      case REGIME_STRONG_TREND: return "STRONG_TREND";
      case REGIME_WEAK_TREND:   return "WEAK_TREND";
      case REGIME_RANGING:      return "RANGING";
      case REGIME_VOLATILE:     return "VOLATILE";
      default:                  return "UNKNOWN";
   }
}

string TrendToString(ENUM_TREND_DIR t)
{
   switch(t)
   {
      case TREND_BULLISH: return "BULLISH";
      case TREND_BEARISH: return "BEARISH";
      default:            return "NEUTRAL";
   }
}

//+------------------------------------------------------------------+
//| ENHANCED DASHBOARD WITH ANALYTICS                                  |
//+------------------------------------------------------------------+
void DrawDashboard()
{
   int x = 10, y = 30, lh = 16;
   string p = "AREA_";

   DL(p+"t", x, y, "=== ADAPTIVE REGIME EA v6.0 ===", clrGold, 10); y += lh+3;

   double bal = accInfo.Balance(), eq = accInfo.Equity();
   double dd = (peakBalance > 0) ? (peakBalance - eq) / peakBalance * 100.0 : 0;
   double dailyPnL = dailyStartBalance > 0 ? (eq-dailyStartBalance)/dailyStartBalance*100 : 0;

   DL(p+"b", x, y, StringFormat("Bal: $%.2f | Eq: $%.2f", bal, eq), InpDashText, 9); y += lh;
   DL(p+"d", x, y, StringFormat("Peak: $%.2f | DD: %.2f%%", peakBalance, dd),
      (dd > InpMaxDrawdownPct*0.7) ? clrOrangeRed : InpDashText, 9); y += lh;
   DL(p+"dl", x, y, StringFormat("Daily: %.2f%% | Trades: %d/%d",
      dailyPnL, tradesToday, InpMaxTradesPerDay),
      (dailyPnL >= 0) ? clrLimeGreen : clrOrangeRed, 9); y += lh+3;

   color rc = clrGray;
   if(currentRegime == REGIME_STRONG_TREND) rc = clrLime;
   else if(currentRegime == REGIME_WEAK_TREND) rc = clrYellow;
   else if(currentRegime == REGIME_RANGING) rc = clrDodgerBlue;
   else if(currentRegime == REGIME_VOLATILE) rc = clrOrangeRed;
   DL(p+"r", x, y, "Regime: " + RegimeToString(currentRegime), rc, 9); y += lh;

   color tc = clrGray;
   if(currentTrend == TREND_BULLISH) tc = clrLime;
   else if(currentTrend == TREND_BEARISH) tc = clrOrangeRed;
   DL(p+"tr", x, y, "Trend: " + TrendToString(currentTrend), tc, 9); y += lh;

   DL(p+"p", x, y, StringFormat("Pos: %d/%d | Risk: %.1f%% | ConLoss: %d",
      cachedPosCount, InpMaxPositions, cachedTotalRisk, consecutiveLosses), InpDashText, 8); y += lh+3;

   // Kelly Criterion Stats
   if(totalClosedTrades >= 30)
   {
      double kellyPct = 0;
      double p_win = historicalWinRate;
      double q = 1.0 - p_win;
      double b = (historicalAvgLoss > 0) ? historicalAvgWin / historicalAvgLoss : 2.0;
      kellyPct = (p_win * b - q) / b;

      DL(p+"kelly", x, y, StringFormat("KELLY: WR=%.1f%% | W/L=%.2f:%.2f | K=%.1f%%",
         p_win*100, historicalAvgWin, historicalAvgLoss, kellyPct*100),
         (kellyPct > 0) ? clrLimeGreen : clrOrangeRed, 8); y += lh;
   }
   else
   {
      DL(p+"kelly", x, y, StringFormat("Kelly: %d/30 trades (learning...)", totalClosedTrades),
         clrGray, 8); y += lh;
   }

   // Regime Performance Breakdown
   y += 3;
   DL(p+"perfhdr", x, y, "REGIME PERFORMANCE:", clrGold, 9); y += lh;

   if(stats_StrongTrend.trades > 0)
   {
      double wr = (double)stats_StrongTrend.wins / stats_StrongTrend.trades * 100;
      DL(p+"st", x, y, StringFormat("  Strong: %d/%d (%.0f%%) PF=%.2f",
         stats_StrongTrend.wins, stats_StrongTrend.trades, wr, stats_StrongTrend.profitFactor),
         (wr >= 50) ? clrLimeGreen : clrOrange, 8); y += lh;
   }

   if(stats_WeakTrend.trades > 0)
   {
      double wr = (double)stats_WeakTrend.wins / stats_WeakTrend.trades * 100;
      DL(p+"wt", x, y, StringFormat("  Weak: %d/%d (%.0f%%) PF=%.2f",
         stats_WeakTrend.wins, stats_WeakTrend.trades, wr, stats_WeakTrend.profitFactor),
         (wr >= 50) ? clrLimeGreen : clrOrange, 8); y += lh;
   }

   if(stats_Ranging.trades > 0)
   {
      double wr = (double)stats_Ranging.wins / stats_Ranging.trades * 100;
      DL(p+"rg", x, y, StringFormat("  Range: %d/%d (%.0f%%) PF=%.2f",
         stats_Ranging.wins, stats_Ranging.trades, wr, stats_Ranging.profitFactor),
         (wr >= 50) ? clrLimeGreen : clrOrange, 8); y += lh;
   }

   y += 3;
   string alerts = "";
   if(circuitBreakerActive) alerts += "[CIRCUIT BREAKER] ";
   if(dailyLossLimitHit) alerts += "[DAILY LIMIT] ";
   if(consecutiveLosses >= 2) alerts += "[COOLDOWN] ";
   if(alerts == "") alerts = "ALL SYSTEMS GO";
   DL(p+"a", x, y, alerts,
      (alerts != "ALL SYSTEMS GO") ? clrRed : clrGreenYellow, 9);

   ChartRedraw(0);
}

void DL(string name, int x, int y, string text, color clr, int sz)
{
   if(ObjectFind(0, name) < 0)
   {
      ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, name, OBJPROP_ANCHOR, ANCHOR_LEFT_UPPER);
   }
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, sz);
   ObjectSetString(0, name, OBJPROP_FONT, "Consolas");
}
//+------------------------------------------------------------------+
