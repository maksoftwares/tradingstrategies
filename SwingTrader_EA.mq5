//+------------------------------------------------------------------+
//|                 XAUUSD M15 Swing Pullback Strategy (EA)         |
//|                 Trend = H1 EMAs, Entry = M15 Pullback+Momentum  |
//|                 Partial TP & ATR SL/Trail                        |
//|                 © 2025 — for educational/backtest use            |
//+------------------------------------------------------------------+
#property copyright "2025"
#property version   "1.00"

#include <Trade/Trade.mqh>

// ------- Realized-R accounting (GLOBAL STATE) -------
double   gR_day  = 0.0;
double   gR_week = 0.0;
int      gDayId  = -1;
int      gWeekId = -1;
datetime gLastTradeTime = 0;

// Small ticket->risk map (single-position EA fits easily)
ulong  gOpenTicket[16];
double gOpenRiskMoney[16];
int    gOpenCount = 0;

void RiskMapPut(ulong ticket, double riskMoney)
{
   for(int i=0;i<gOpenCount;i++)
      if(gOpenTicket[i]==ticket){ gOpenRiskMoney[i]=riskMoney; return; }
   if(gOpenCount<16){
      gOpenTicket[gOpenCount]=ticket;
      gOpenRiskMoney[gOpenCount]=riskMoney;
      gOpenCount++;
   }
}

double RiskMapGet(ulong ticket)
{
   for(int i=0;i<gOpenCount;i++)
      if(gOpenTicket[i]==ticket) return gOpenRiskMoney[i];
   return 0.0;
}

double RiskMapPop(ulong ticket)
{
   for(int i=0;i<gOpenCount;i++)
   {
      if(gOpenTicket[i]==ticket){
         double v=gOpenRiskMoney[i];
         gOpenCount--;
         gOpenTicket[i]=gOpenTicket[gOpenCount];
         gOpenRiskMoney[i]=gOpenRiskMoney[gOpenCount];
         return v;
      }
   }
   return 0.0;
}

input group "=== Core Filters ==="
input int      H1_EMA_Fast     = 50;
input int      H1_EMA_Slow     = 200;
input int      M15_EMA_Pull    = 20;
input int      M15_EMA_Struct  = 50;

input group "=== Momentum Triggers (M15) ==="
input int      RSI_Period      = 14;
input int      MACD_Fast       = 12;
input int      MACD_Slow       = 26;
input int      MACD_Signal     = 9;

input group "=== Risk & Money Management ==="
input double   Risk_Percent    = 0.60;     // % of balance per trade
input double   MaxRiskLotsCap  = 0.10;     // hard cap per trade
input double   MinStop_ATR     = 1.0;      // ensure SL distance >= 1×ATR
input double   MinStop_Points  = 50.0;     // absolute floor in points
input int      ATR_Period      = 14;
input double   ATR_SL_mult     = 2.5;      // SL = max(ATR*mult, swing buffer)
input double   Swing_Buffer_ATR= 0.20;     // extra beyond fractal (as ATR multiple)
input double   TP1_R           = 1.00;     // first partial (tighter for faster risk reduction)
input double   TP2_R           = 2.10;     // second partial / scale-out point
input double   TP3_R           = 3.50;     // runner target
input bool     Use_TP3         = true;     // enable third target
input double   TP1_Close_Pct   = 0.50;     // portion to close at TP1
input double   TP2_Close_Pct   = 0.30;     // portion to close at TP2 (rest trails / TP3)
input bool     Adaptive_R_Targets = true;  // adjust TP2/TP3 with volatility regime
input int      ATR_Regime_Period  = 50;    // ATR SMA period for regime calc
input double   HighVolRatio       = 1.30;  // ATR / ATR_SMA > this => high vol (stretch targets)
input double   LowVolRatio        = 0.85;  // ATR / ATR_SMA < this => low vol (contract targets)
input double   ATR_Regime_Max_Ratio = 1.8;  // skip entries if ATR/ATR_SMA exceeds (too chaotic)
input double   ATR_Regime_Min_Ratio = 0.75; // skip entries if ATR/ATR_SMA below (too quiet)
input double   HighVol_Target_Boost = 0.6; // add to TP2/TP3 R
input double   LowVol_Target_Reduction = 0.25; // subtract from TP2/TP3 R
input bool     Use_Trailing    = true;     // chandelier trail after BE
input double   Trail_ATR_mult  = 2.5;      // base trail
input double   Trail_Tight_ATR_mult = 1.8; // tighter trail beyond trigger R
input double   Trail_Tighten_Trigger_R = 2.0; // tighten trail after this R
input bool     Use_Time_Exit   = true;     // exit stale trades
input int      Max_Bars_In_Trade = 96;     // close if trade exceeds this many M15 bars (~24h)
input bool     Use_Vol_Compress_Exit = true; // exit if volatility collapses
input double   Vol_Compress_Ratio = 0.65;  // ATR(now)/ATR(entry) below => exit if not reached 0.5R

input group "=== Risk Caps & Probes ==="
input bool   Enable_RiskCaps          = true;    // enable budget caps
input double Risk_Percent_Base        = 0.35;    // base % risk per trade (0.35%)
input double DailyLossCap_R           = 1.8;     // stop trading for the day if net closed loss <= -1.8R
input double WeeklyLossCap_R          = 4.0;     // stop trading for the week if net closed loss <= -4R
input bool   Allow_Probe_When_Capped  = true;    // still allow micro lot probe trades under caps
input int    Probe_Max_Per_Day        = 2;       // max probe trades/day
input double Probe_ATR_mult           = 1.0;     // SL for probes
input double Probe_TP_R               = 1.0;     // TP for probes
input double Risk_Throttle_DD_Pct     = 20.0;    // when equity drawdown from peak exceeds this %, throttle risk
input double Risk_Throttle_Pct        = 0.15;    // throttled risk % while in deep DD

// --- Weekly equity cap (prevents overtrading after drawdown weeks)
input bool   Use_Weekly_Risk_Cap   = true;
input double WeeklyRiskCapPct      = 25.0;  // raised threshold
double weekStartEquity = 0.0;
int    lastWeekId = -1;

input group "=== Trade Hygiene ==="
input int      MaxSpreadPoints = 200;      // reject entries if spread too wide
input ulong    Magic           = 20251011; // EA magic

input group "=== Advanced Filters & Sessions ==="
input bool     RequireBothMomentum    = true;  // require both MACD & RSI (false = either)
input double   Min_ATR_Filter         = 6.0;    // Minimum ATR (points) to allow trades
input double   Max_Close_Extension_ATR= 0.9;    // Reject if close is > this * ATR above/below pullback EMA
input bool     Use_Session_Filter     = false;  // Restrict trading to session hours
input bool     Only_London_NY         = false;  // keep false to preserve frequency
input int      Session_Start_Hour     = 6;      // Session start (server time)
input int      Session_End_Hour       = 20;     // Session end
input bool     DelayTrailUntilPartial = true;   // Do not trail until partial profit
input double   Trail_Start_R          = 1.8;    // Start trailing only after this R reached if partial not yet
input group "=== Diagnostics ==="
input bool     Enable_Diagnostics     = true;   // Turn on rejection counting
input int      Diagnostics_Every_Bars = 96;     // Print summary every N processed M15 bars (~1 day if 96)
input bool     Verbose_First_N        = true;   // Print per-bar reasons early
input int      Verbose_Bars_Limit     = 40;     // Only first N bars verbose
input bool     Diagnostics            = true;   // Detailed per-attempt reason logging
input group "=== Trend & Strength Filters ==="
// Trend & Strength Filters
input bool     Use_ADX_Filter         = true;
input int      ADX_Period             = 14;
input double   Min_ADX                = 18.0;  // minimum ADX strength requirement
input bool     Use_EMA200_Slope       = true;
input int      EMA200_Slope_Lookback  = 10;
input double   Min_EMA200_Slope_Pts   = 10.0;  // minimum EMA200 slope in points
input int      SlopeLookback          = 8;       // permissive slope lookback (new flow)
input double   MinSlopePts            = 8;       // permissive minimum slope points (new flow)

input group "=== Momentum Quality Thresholds ==="
input double   RSI_Min_Long           = 52.5;   // require RSI above this for longs
input double   RSI_Max_Short          = 47.5;   // require RSI below this for shorts
input double   MACD_Min_Abs           = 0.10;   // min absolute MACD main beyond zero

input group "=== Pullback / Structure Quality ==="
input double   Min_Pull_Depth_ATR     = 0.12;   // minimum pullback depth as ATR fraction
input double   Structure_Buffer_ATR   = 0.06;   // close must clear structure EMA by this ATR
input bool     Use_Structure_Space    = true;   // Minimum space filter to next structure
input double   MinSpace_ATR           = 0.90;    // minimum ATR headroom
input int      Space_Lookback_Bars    = 80;     // lookback bars to compute highest/lowest structure
input int      SR_Lookback            = 20;     // swing high/low lookback for new flow

input group "=== Confirmation Entry (Stop Orders) ==="
input bool     Use_Stop_Confirmation  = true;   // Use pending stop orders for confirmation
input int      EntryBufferPts         = 14;     // buffer (points) beyond signal candle extreme
input int      PendingOrder_Expiry_Bars = 8;    // cancel pending after N bars
input bool     UseStopOrders          = true;   // New flow toggle (market vs stop)
input double   EntryBufferPts_New     = 14;     // New flow entry buffer

input group "=== Break-Even Logic ==="
input bool     MoveBE_On_StructureBreak = true; // Move to BE only after structure break
input double   BE_Fallback_R          = 1.00;   // fallback R to force BE if no break
input int      Break_Buffer_Points    = 10;     // extra points above/below signal high/low to count break

input group "=== Dynamic Spread & Sessions ==="
input bool     Dynamic_Spread_Cap     = true;   // dynamic spread cap using ATR
input double   Spread_ATR_Fraction    = 0.35;   // allowed spread = % of ATR (points)
input int      HardSpreadCapPts       = 600;    // absolute safety ceiling
input bool     Stage2_IgnoresSpread   = false;  // bypass spread check at stage 2 when no trades yet
input bool     Enhanced_Session_Filter= false;  // refined session rules (DISABLED for 24h trading)
input int      LondonNY_Start_Hour    = 6;      // Session start (0=all day)
input int      LondonNY_End_Hour      = 20;     // Session end (24=all day)
input bool     Skip_Monday_Asian      = true;   // DISABLED for more opportunities
input int      Monday_Skip_Until_Hour = 3;
input bool     Skip_Friday_Late       = true;   // DISABLED for more opportunities
input int      Friday_Cutoff_Hour     = 19;
input bool     Stage2_OverrideSession = true;   // Allow entries at stage 2 regardless of session

input group "=== Loss Streak & Side Control ==="
input bool     LossStreak_Protection  = true;   // pause after loss streak
input int      Max_Loss_Streak        = 2;
input int      Loss_Cooldown_Bars     = 6;      // bars to pause after hitting loss streak
input int      MinBarsForSignals      = 50;    // minimum bars required before allowing signals
// (Adjusted later: default will be reduced to 3 in adaptive frequency changes)
input bool     AllowLongs             = true;   // enable/disable long side
input bool     AllowShorts            = true;   // enable/disable short side
input bool     Use_New_Entry_Flow     = true;   // Activate simplified lenient/quality TryEnter() flow
input int      CI_Max                 = 60;     // Placeholder compression index max (not yet implemented)
input int      MaxSpreadPoints_New    = 180;    // New flow max spread hard cap
input double   MaxSpread_ATR_Frac     = 0.18;   // New flow dynamic spread fraction

input bool   Cooldown_Stage0_Only = true;     // apply cooldown only at stage 0
input bool   Quota_Stage_Acceleration = true; // auto-escalate loosen stage if no trade yet
input int    Quota_Kick_Hour        = 10;     // escalate from this hour (server)
input int    Quota_End_Hour         = 19;     // keep escalated looseness until here

input group "=== Risk Gate (Realized R) ==="
input bool   RiskGate_Enable        = true;
input double RiskGate_MinR_Day      = -2.5;     // lock for rest of day if <= this R
input double RiskGate_MinR_Week     = -6.0;     // lock until new week if <= this R
input int    RiskGate_Unlock_NoTradeBars = 160; // idle unlock threshold (M15 bars)
input bool   RiskGate_ProbeOnce     = true;     // optional micro-probe after unlock
input double RiskGate_ProbeLots     = 0.01;

input group "=== Adaptive Frequency Layer ==="
input bool   AdaptiveLoosen     = true;  // enable dynamic threshold loosening intraday
input int    DailyMinTrades     = 1;     // target minimum trades per day
input int    LoosenHour1        = 12;    // first relax hour (server time)
input int    LoosenHour2        = 16;    // second relax hour
input int    ADX_Min_L0         = 18;    // base strict
input int    ADX_Min_L1         = 16;    // first relax
input int    ADX_Min_L2         = 14;    // second relax
input double CI_Max_L0          = 50.0;  // compression index max stage 0
input double CI_Max_L1          = 60.0;  // compression index max stage 1
input double CI_Max_L2          = 70.0;  // compression index max stage 2
input double MinSpace_ATR_L0    = 0.90;   // structure space stage 0
input double MinSpace_ATR_L1    = 0.60;   // structure space stage 1
input double MinSpace_ATR_L2    = 0.35;   // structure space stage 2
input int    RSI_Mid_L2         = 49;    // slightly easier RSI midline at stage 2

input group "=== Equity Gate & Probe Lane ==="
input bool     Use_EquityGate          = false;  // If true, pause entries when recent win-rate is poor, but auto-grace after N bars.
input int      Gate_Lookback_Trades    = 20;
input double   Gate_Min_Winrate        = 0.33;
input int      Gate_Grace_Bars         = 96;     // ~1 day on M15; after this many bars without an entry, bypass equity gate once.
input bool     Enable_Probe_Trade      = true;
input double   Probe_Risk_Factor       = 0.30;
input double   Probe_ADX_Min           = 22.0;
input double   Probe_H1_Separation_MinPts = 35.0;
input double   Probe_Min_ATR_Points    = 120.0;
input int      Probe_EarlyAbort_Bars   = 2;
input double   Probe_EarlyAbort_R      = 0.50;

input group "=== Daily Trade Quota ==="
input bool     Enable_Daily_Min_Trade   = true;   // master toggle
input int      Quota_Trigger_Hour       = 11;     // start trying from this hour
input int      Quota_Final_Hour         = 18;     // last hour to try
input bool     Quota_Use_Market         = true;   // use market if body is strong; else stop
input int      Quota_EntryBufferPts     = 8;      // stop buffer if not market
input double   Quota_Risk_Factor        = 0.40;   // fraction of normal risk for quota trades
input double   Quota_Min_ATR_Points     = 350.0;  // min ATR(points) to avoid dead markets
input double   Quota_MaxSpread_ATR_Frac = 0.30;   // spread must be <= this * ATR(points)

input group "=== Safety & Quota Guards ==="
input double   DailyRiskMaxPct          = 3.0;    // Max % of BALANCE allowed to lose in a single day; block new entries when exceeded.
input double   WeeklyRiskMaxPct         = 6.0;    // Max % of BALANCE allowed to lose in rolling 5 trading days.
input int      MaxConsecLosses_Day      = 3;      // If we hit this many losses in a single day, pause further entries until next session.
input double   Quota_ADX_Min            = 18.0;   // Minimum ADX on M15 for quota trade.
input double   Quota_H1EMA_Separation_MinPts = 20.0; // Minimum separation between H1 fast/slow EMA in POINTS to allow quota.
input bool     Quota_D1_Filter          = true;   // Require D1 close above/under D1 EMA50 in direction of trade for quota.
input int      Quota_Disable_After_Losses = 2;    // Disable quota for the rest of the day if it loses this many times.
input double   EarlyAbort_R             = 0.6;    // Adverse R threshold to trigger early exit.
input int      EarlyAbort_Bars          = 3;      // If adverse move reaches 0.6R within N bars after entry, bail early.
input bool     Enable_Equity_Filter     = true;   // Sliding window equity filter gate before entries.
input int      Equity_WinRate_Window    = 10;     // Trades window for equity/winrate filter.
input double   Equity_Min_WinRate       = 0.33;   // If win rate in the last N trades falls below, pause entries until next day.

input bool     Enable_MinLot_Probe      = true;
input int      Probe_Fire_Hour          = 16;
input double   Probe_Max_Spread_ATR_Frac= 0.30;

input group "=== Compression Gate ==="
input double CI_Min_L0 = 0.80;  // Stage0: require at least mild compression
input double CI_Min_L1 = 0.60;  // Stage1: easier
input double CI_Min_L2 = 0.00;  // Stage2: disable CI gate


input group "=== Fail-Safe Daily Trade ==="
input double FailSafe_RiskMult  = 0.20;  // risk multiplier on loosened/day-save entries
input int    DC_Period          = 24;    // lookback bars for daily bracket high/low
input double DC_BufferPts       = 14;    // buffer points beyond channel extremes
input bool   Bracket_UseStops   = true;  // submit fail-safe entries as stop orders

input bool   EnableAltSignal        = true;   // alternate continuation path enabled by default
input bool   Alt_UseStopOrders      = true;
input double Stage2_MinSpace_ATR    = 0.20;
input bool   Stage2_IgnoreSlope     = false;
input bool   Stage2_IgnoreStructure = false;
input bool   Stage2_OptionalADX     = true;   // allow ADX to be optional at stage 2
input double Alt_EntryBufferPts     = 14;    // buffer for alt stop entries

//--- handles
int hEMA_H1_fast, hEMA_H1_slow, hEMA_M15_pull, hEMA_M15_struct;
int hRSI_M15, hMACD_M15, hATR_M15, hFractals_M15;
int hADX = INVALID_HANDLE; // ADX for new entry flow
CTrade trade;

//--- state
datetime lastM15BarTime = 0;
bool     partialTaken   = false;
bool     secondPartialTaken = false;
double   entryATRPoints = 0.0;      // ATR points at entry
double   entryStopPoints= 0.0;      // stop distance at entry (points)
double   entryTP2_R     = 0.0;      // stored adapted TP2 R
double   entryTP3_R     = 0.0;      // stored adapted TP3 R
int      probeBarsSinceEntry = 0;
double   probeStopPts = 0.0;
ulong    rej_equityGate=0;
ulong    probeEntries=0;
datetime entryTime      = 0;        // entry time for time/vol exits
int      WinsLong30     = 0, TradesLong30 = 0, WinsShort30 = 0, TradesShort30 = 0;
bool     AllowLongsAuto = true, AllowShortsAuto = true;
int      longResults[30];
int      shortResults[30];
int      longRollingIdx  = 0, shortRollingIdx = 0;
int      longRollingCount= 0, shortRollingCount = 0;
double   dayStartBalance = 0.0;
double   weekStartBalance = 0.0;
int      dayLossCount = 0;
int      quotaLossCount = 0;
double   lastEntryStopPts = 0.0;
int      barsSinceEntry = 0;
double   recentWinsLosses[32]; // rolling performance window (+1/-1)
int      rwlIndex = 0;
int      rwlCount = 0;
int      weekAnchorDayOfYear = -1;
ulong    quotaPendingTicket = 0;
bool     quotaTradeActive = false;
datetime lastEntryBarTime = 0;

// --- Risk cap accounting (R-units) ---
double R_today = 0.0;         // closed PnL in R for current day
double R_week  = 0.0;         // closed PnL in R for current week
int    day_id  = -1;          // yyyyMMdd of last update
int    week_id = -1;          // ISO week of year
int    probe_trades_today = 0;
double peak_equity = 0.0;
double activeTradeRiskCash = 0.0;        // total monetary risk recorded at entry
double activeTradeOneRCashPerLot = 0.0;  // 1R cash value per lot at entry
double activeTradeInitialLots = 0.0;     // original position size (lots)
double activeTradeRemainingLots = 0.0;   // lots still open for current trade
ulong  activeTradePositionId = 0;        // position identifier to map closes

// --- diagnostics counters ---
ulong barsProcessed=0;
ulong rej_spread=0, rej_positionOpen=0, rej_session=0, rej_atrQuiet=0;
ulong rej_trend=0, rej_pullback=0, rej_structure=0, rej_momentum=0, rej_candle=0, rej_extension=0;
ulong rej_misc=0;

// additional rejection counters
ulong rej_space=0, rej_cooldown=0, rej_spreadDynamic=0, rej_side=0, rej_slope=0;

// confirmation entry & structure break
ulong    pendingTicket  = 0;
int      pendingExpiryBars = 0;
int      pendingDirection = -1; // 1=long, 0=short, -1 none
double   signalHigh=0.0, signalLow=0.0;
bool     structureBreakOccurred=false;
bool     beMoved=false;

// loss streak
int consecutiveLosses=0;
int cooldownBarsRemaining=0;
int TradesToday = 0;        // daily trade counter
int LastTradeDate = -1;     // last date (day of month) we recorded trades

// forward declarations for new helpers
int  LoosenStage();
void ResetDailyCounters();
int  BarsSinceLastEntry();
double ComputeCompressionIndex(int lookback=20);
void PrintStageInfo(int stage);
bool LogAndReturnFalse(const string why);
bool SessionAllowed();
bool HasOpenPosition();
double LotsFromRisk(double stopPts);
double LotsByRiskSafe(double stopPts);
bool EquityFilterOK();
bool ComputeRecentWinrate(int lookback, double &wr_out);
bool EquityGateAllows(string &why);
bool RiskBudgetOK();
bool QuotaEnvironmentOK();
bool AtrRegimeAcceptable();
bool EnforceProbeTrade();
double GetVolDigits(double step);
bool NormalizeVolume(double &vol);
bool SafeOrderSend(MqlTradeRequest &rq, MqlTradeResult &rs);
bool PlacePendingOrMarket(bool isLong, double lots, double pendPrice, double sl, double tp, const string tag);
bool ProbeAllowed();
bool TryProbeEntry();
void DayWeekIds(const datetime t, int &d_out, int &w_out);
void ResetRiskWindowsIfNeeded();
double CurrentRiskPercent();
void RecordClosedTradeR(const ulong deal_id);
bool CapsAllowTrading(bool &probe_mode_out);
void BumpProbeCounter(bool probe_mode);
bool TryEnter_WithProbe(bool probe_mode);
bool RiskGateBlocksEntry();

void DiagnosticsPrintSummary(){
   if(!Enable_Diagnostics) return;
   double totalRej = (double)(rej_spread+rej_positionOpen+rej_session+rej_atrQuiet+rej_trend+rej_pullback+rej_structure+rej_momentum+rej_candle+rej_extension+rej_misc);
   if(totalRej==0) totalRej=1; // avoid div0
   Print("[Diag] Bars=",barsProcessed,
         " Spread=",rej_spread,
         " PositionPresent=",rej_positionOpen,
         " Session=",rej_session,
         " ATRQuiet=",rej_atrQuiet,
         " Trend=",rej_trend,
         " Pullback=",rej_pullback,
         " Structure=",rej_structure,
         " Momentum=",rej_momentum,
         " Candle=",rej_candle,
         " Extension=",rej_extension,
         " Misc=",rej_misc,
         " Space=",rej_space,
         " Cooldown=",rej_cooldown,
         " DynSpread=",rej_spreadDynamic,
         " Side=",rej_side,
         " Slope=",rej_slope);
   Print(" [GateEq]", rej_equityGate, " [Probe]", probeEntries);
}

void DiagnosticsCount(const string tag){
   if(!Enable_Diagnostics) return;
   if(tag=="spread") rej_spread++;
   else if(tag=="position") rej_positionOpen++;
   else if(tag=="session") rej_session++;
   else if(tag=="atrQuiet") rej_atrQuiet++;
   else if(tag=="trend") rej_trend++;
   else if(tag=="pullback") rej_pullback++;
   else if(tag=="structure") rej_structure++;
   else if(tag=="momentum") rej_momentum++;
   else if(tag=="candle") rej_candle++;
   else if(tag=="extension") rej_extension++;
      else if(tag=="space") rej_space++;
      else if(tag=="cooldown") rej_cooldown++;
      else if(tag=="dynSpread") rej_spreadDynamic++;
      else if(tag=="side") rej_side++;
      else if(tag=="slope") rej_slope++;
   else rej_misc++;
}

// ---------- New Flow Helpers ---------- //
void AppendReason(string &acc, const string why){
   if(!Diagnostics) return;
   if(StringLen(acc)>0) acc += " | ";
   acc += why;
}

double LastSwingLow(int lookback=20){ double low=DBL_MAX; for(int i=1;i<=lookback;i++){ double v=iLow(_Symbol,PERIOD_M15,i); if(v<low) low=v; } return (low==DBL_MAX?0.0:low); }
double LastSwingHigh(int lookback=20){ double high=-DBL_MAX; for(int i=1;i<=lookback;i++){ double v=iHigh(_Symbol,PERIOD_M15,i); if(v>high) high=v; } return (high==-DBL_MAX?0.0:high); }

bool SpreadOK_Dynamic(double atr){
   double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK), bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   if(ask==0||bid==0) return false;
   double spPts=(ask-bid)/_Point;
   
   // Fallback when ATR not ready
   if(atr<=0.0) return spPts <= (double)HardSpreadCapPts;
   
   double atrPts=atr/_Point;
   double dynByAtr = Spread_ATR_Fraction * atrPts;
   
   // Combine fixed and ATR-based caps, then clamp by hard ceiling
   double cap = MathMin((double)HardSpreadCapPts, MathMax((double)MaxSpreadPoints_New, dynByAtr));
   
   bool result = spPts <= cap;
   
   // Diagnostic output
   if(Diagnostics && !result){
      PrintFormat("[SPREAD] REJECT pts=%.1f cap=%.1f (MaxPts=%d ATRfrac=%.2f Hard=%d)", 
                  spPts, cap, MaxSpreadPoints_New, Spread_ATR_Fraction, HardSpreadCapPts);
   }
   
   return result;
}

bool TrendSlopeOK(bool longSide,double emaSlowNow){
   double emaPast; if(!GetValue(hEMA_H1_slow,0,1+SlopeLookback,emaPast)) return true; // permissive
   double deltaPts = PointsFromPrice(emaSlowNow - emaPast);
   if(longSide) return (deltaPts > MinSlopePts);
   return (deltaPts < -MinSlopePts);
}

bool AtrRegimeAcceptable(){
   double atrNow=0.0;
   if(!GetValue(hATR_M15,0,1,atrNow))
      return true;

   int n = MathMax(ATR_Regime_Period, 30);
   double arr[];
   ArraySetAsSeries(arr, true);
   if(CopyBuffer(hATR_M15,0,1,n,arr) != n)
      return true;

   double sum=0.0;
   for(int i=0;i<n;i++)
      sum+=arr[i];

   double sma = (n>0 ? sum/n : atrNow);
   if(sma<=0.0)
      return true;

   double ratio = atrNow / sma;
   return (ratio >= ATR_Regime_Min_Ratio && ratio <= ATR_Regime_Max_Ratio);
}

int BarsSinceLastEntry()
{
   datetime t=iTime(_Symbol,PERIOD_M15,0);
   if(lastEntryBarTime==0 || t==0) return 9999;
   int s = (int)((t - lastEntryBarTime) / PeriodSeconds(PERIOD_M15));
   return (s<0? 9999: s);
}

bool ComputeRecentWinrate(int lookback, double &wr_out)
{
   wr_out = 1.0;
   if(lookback<=0) return true;
   datetime to=TimeCurrent(), from=to-86400*120; // 120d window
   if(!HistorySelect(from,to)) return false;
   int wins=0, total=0;
   int deals=(int)HistoryDealsTotal();
   for(int i=deals-1; i>=0 && total<lookback; --i){
      ulong ticket=HistoryDealGetTicket(i);
      if(!HistoryDealSelect(ticket)) continue;
      if((ulong)HistoryDealGetInteger(ticket,DEAL_MAGIC)!=Magic) continue;
      if((string)HistoryDealGetString(ticket,DEAL_SYMBOL)!=_Symbol) continue;
      long e=(long)HistoryDealGetInteger(ticket,DEAL_ENTRY);
      if(e!=DEAL_ENTRY_OUT) continue;
      double p=HistoryDealGetDouble(ticket,DEAL_PROFIT)+HistoryDealGetDouble(ticket,DEAL_SWAP)+HistoryDealGetDouble(ticket,DEAL_COMMISSION);
      total++;
      if(p>0) wins++;
   }
   if(total>0) wr_out = (double)wins/(double)total;
   return true;
}

bool EquityGateAllows(string &why)
{
   if(!Use_EquityGate) return true;
   double wr=1.0; if(!ComputeRecentWinrate(Gate_Lookback_Trades,wr)) return true;
   int bs = BarsSinceLastEntry();
   bool blocked = (wr < Gate_Min_Winrate) && (bs < Gate_Grace_Bars);
   if(blocked){ rej_equityGate++; if(Diagnostics) AppendReason(why, StringFormat("equity-gate wr=%.2f bs=%d",wr,bs)); }
   return !blocked;
}

bool EnforceProbeTrade(){
   if(!Enable_Probe_Trade) return false;
   if(TradesToday >= 1) return false;
   if(HasOpenPosition()) return false;
   if(pendingTicket>0) return false;
   double atr=0.0; if(!GetValue(hATR_M15,0,1,atr)) return false;
   double atrPts = atr/_Point; if(atrPts < Probe_Min_ATR_Points) return false;
   if(hADX!=INVALID_HANDLE){ double a0[]; if(CopyBuffer(hADX,0,0,1,a0)>0){ if(a0[0] < Probe_ADX_Min) return false; } }
   double f=0,s=0; if(!GetValue(hEMA_H1_fast,0,1,f) || !GetValue(hEMA_H1_slow,0,1,s)) return false;
   if(MathAbs(PointsFromPrice(f-s)) < Probe_H1_Separation_MinPts) return false;
   MqlRates m15[3]; if(!GetRates(PERIOD_M15,3,m15)) return false;
   double ema50=0; if(!GetValue(hEMA_M15_struct,0,1,ema50)) return false;
   double rsi=0, macd=0; if(!GetValue(hRSI_M15,0,1,rsi) || !GetValue(hMACD_M15,0,1,macd)) return false;
   double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK), bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   if(ask==0||bid==0) return false;
   bool up=(f>s), dn=(f<s);
   bool wantLong  = up && (rsi>=50 || macd>0) && (m15[1].close>ema50);
   bool wantShort = dn && (rsi<=50 || macd<0) && (m15[1].close<ema50);
   if(!wantLong && !wantShort) return false;
   int stopLevel=(int)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL);
   double useStopPts = MathMax((double)stopLevel+5.0, ATR_SL_mult * atrPts);
   probeStopPts = useStopPts;
   double lots = LotsFromRisk(useStopPts) * Probe_Risk_Factor;
   NormalizeVolume(lots);
   if(lots <= 0.0) return false;
   double sl_buy  = NormalizePrice(ask - PriceFromPoints(useStopPts));
   double sl_sell = NormalizePrice(bid + PriceFromPoints(useStopPts));
   double tpR = MathMax(2.0, TP2_R);
   double tp_buy  = NormalizePrice(ask + PriceFromPoints(useStopPts*tpR));
   double tp_sell = NormalizePrice(bid - PriceFromPoints(useStopPts*tpR));
   MqlTradeRequest rq; MqlTradeResult rs; ZeroMemory(rq); ZeroMemory(rs);
   rq.action=TRADE_ACTION_PENDING; rq.symbol=_Symbol; rq.volume=lots; rq.deviation=50; rq.magic=Magic; rq.type_filling=ORDER_FILLING_FOK;
   if(wantLong){
      rq.type=ORDER_TYPE_BUY_STOP; rq.price=NormalizePrice(m15[1].high + PriceFromPoints(12));
      if(PointsFromPrice(rq.price-ask) < stopLevel+10) rq.price=NormalizePrice(ask+PriceFromPoints(stopLevel+10));
      rq.sl=sl_buy; rq.tp=tp_buy; if(SafeOrderSend(rq,rs)){ pendingTicket=rs.order; pendingExpiryBars=PendingOrder_Expiry_Bars; pendingDirection=1; signalHigh=m15[1].high; signalLow=m15[1].low; entryStopPoints=useStopPts; entryATRPoints=atrPts; entryTime=TimeCurrent(); structureBreakOccurred=false; beMoved=false; partialTaken=false; secondPartialTaken=false; probeBarsSinceEntry=0; probeEntries++; return true; }
   }
   if(wantShort){
      rq.type=ORDER_TYPE_SELL_STOP; rq.price=NormalizePrice(m15[1].low - PriceFromPoints(12));
      if(PointsFromPrice(bid-rq.price) < stopLevel+10) rq.price=NormalizePrice(bid-PriceFromPoints(stopLevel+10));
      rq.sl=sl_sell; rq.tp=tp_sell; if(SafeOrderSend(rq,rs)){ pendingTicket=rs.order; pendingExpiryBars=PendingOrder_Expiry_Bars; pendingDirection=0; signalHigh=m15[1].high; signalLow=m15[1].low; entryStopPoints=useStopPts; entryATRPoints=atrPts; entryTime=TimeCurrent(); structureBreakOccurred=false; beMoved=false; partialTaken=false; secondPartialTaken=false; probeBarsSinceEntry=0; probeEntries++; return true; }
   }
   return false;
}

// (TryEnter moved below utility function definitions)

bool GetValue(int handle,int buffer,int shift,double &out){
   double tmp[];
   if(CopyBuffer(handle,buffer,shift,1,tmp)<=0) return false;
   out = tmp[0];
   return true;
}

bool GetRates(ENUM_TIMEFRAMES tf,int count,MqlRates &out_rates[]){
   ArraySetAsSeries(out_rates,true);
   int copied = CopyRates(_Symbol,tf,0,count,out_rates);
   return (copied==count);
}

double GetLastFractal(bool wantLow,int lookback,int startShift=2){
   // wantLow=true -> down fractal (buffer 1); wantLow=false -> up fractal (buffer 0)
   int buffer = (wantLow?1:0);
   double arr[];
   if(CopyBuffer(hFractals_M15,buffer,startShift,lookback,arr)<=0) return 0.0;
   for(int i=0;i<ArraySize(arr);i++){
      if(arr[i]!=0.0 && arr[i]!=EMPTY_VALUE) return arr[i];
   }
   return 0.0;
}

double PointsFromPrice(double price_diff){
   return price_diff/_Point;
}

double PriceFromPoints(double points){
   return points*_Point;
}

double CurrentSpreadPoints(){
   double a=0,b=0;
   SymbolInfoDouble(_Symbol,SYMBOL_ASK,a);
   SymbolInfoDouble(_Symbol,SYMBOL_BID,b);
   return (a-b)/_Point;
}

double NormalizePrice(double p){
   return NormalizeDouble(p,(int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS));
}

// Return yyyymmdd and yyyyWW (approx) for supplied time.
void DayWeekIds(const datetime t, int &d_out, int &w_out){
   MqlDateTime dt; TimeToStruct(t, dt);
   d_out = dt.year*10000 + dt.mon*100 + dt.day;
   // Approx week-id using day-of-year; avoids TimeDayOfYear dependency.
   MqlDateTime jan1; jan1.year=dt.year; jan1.mon=1; jan1.day=1; jan1.hour=0; jan1.min=0; jan1.sec=0;
   datetime d0 = StructToTime(jan1);
   int doy = (int)((t - d0) / 86400) + 1; // 1..366
   int wnum = doy / 7;                    // coarse ISO-like bucket
   w_out = dt.year*100 + wnum;
}

void ResetDailyCounters(){
   int dId, wId;
   DayWeekIds(TimeCurrent(), dId, wId);
   if(gDayId!=dId){ gDayId=dId; gR_day=0.0; TradesToday=0; cooldownBarsRemaining=0; }
   if(gWeekId!=wId){ gWeekId=wId; gR_week=0.0; }
}

bool EquityFilterOK(){
   if(!Enable_Equity_Filter) return true;
   if(Equity_WinRate_Window <= 0) return true;
   int window = (int)MathMin(Equity_WinRate_Window,32);
   if(rwlCount < window) return true;
   int wins=0;
   for(int i=0;i<window;i++)
   {
      int idx = (rwlIndex - 1 - i + 32) % 32;
      if(recentWinsLosses[idx] > 0) wins++;
   }
   double wr = (window>0 ? (double)wins / (double)window : 1.0);
   bool ok = (wr >= Equity_Min_WinRate);
   if(!ok && Enable_Diagnostics)
      PrintFormat("[Gate] Equity filter paused winrate=%.2f thresh=%.2f", wr, Equity_Min_WinRate);
   return ok;
}

bool RiskBudgetOK(){
   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   if(dayStartBalance>0.0){
      double ddDay = 100.0 * (dayStartBalance - bal) / dayStartBalance;
      if(ddDay >= DailyRiskMaxPct){
         if(Enable_Diagnostics) PrintFormat("[Gate] Daily risk cap hit: %.2f%%", ddDay);
         return false;
      }
   }
   if(weekStartBalance>0.0){
      double ddW = 100.0 * (weekStartBalance - bal) / weekStartBalance;
      if(ddW >= WeeklyRiskMaxPct){
         if(Enable_Diagnostics) PrintFormat("[Gate] Weekly risk cap hit: %.2f%%", ddW);
         return false;
      }
   }
   if(MaxConsecLosses_Day>0 && dayLossCount >= MaxConsecLosses_Day){
      if(Enable_Diagnostics) Print("[Gate] Day loss streak cap");
      return false;
   }
   return true;
}

bool QuotaEnvironmentOK(){
   if(hADX!=INVALID_HANDLE)
   {
      double a0[];
      if(CopyBuffer(hADX,0,0,1,a0)>0)
      {
         if(a0[0] < Quota_ADX_Min) return false;
      }
   }

   double f=0.0,s=0.0;
   if(!GetValue(hEMA_H1_fast,0,1,f) || !GetValue(hEMA_H1_slow,0,1,s)) return false;
   if(MathAbs(PointsFromPrice(f-s)) < Quota_H1EMA_Separation_MinPts) return false;

   if(Quota_D1_Filter)
   {
      int h=iMA(_Symbol,PERIOD_D1,50,0,MODE_EMA,PRICE_CLOSE);
      double emaD1=0.0;
      if(!GetValue(h,0,1,emaD1))
      {
         IndicatorRelease(h);
         return false;
      }
      double closeD1=iClose(_Symbol,PERIOD_D1,1);
      IndicatorRelease(h);
      bool bullish = (f>s && closeD1>emaD1);
      bool bearish = (f<s && closeD1<emaD1);
      if(!(bullish || bearish)) return false;
   }
   return true;
}

int LoosenStage(){
   if(!AdaptiveLoosen) return 0;
   if(TradesToday >= DailyMinTrades) return 0;
   // bar-drought based escalation
   if(BarsSinceLastEntry() >= 64) return 2;
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   if(dt.hour >= LoosenHour2) return 2;
   if(dt.hour >= LoosenHour1) return 1;
   return 0;
}

bool EnforceDailyTradeQuota(){
   if(!Enable_Daily_Min_Trade) return false;
   if(TradesToday >= DailyMinTrades) return false;
   if(!RiskBudgetOK() || !EquityFilterOK()) return false;
   if(Quota_Disable_After_Losses>0 && quotaLossCount >= Quota_Disable_After_Losses) return false;
   if(!QuotaEnvironmentOK()) return false;

   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   if(dt.hour < Quota_Trigger_Hour || dt.hour > Quota_Final_Hour) return false;
   if(HasOpenPosition()) return false;

   MqlRates m15[3]; if(!GetRates(PERIOD_M15,3,m15)) return false;
   double atr=0.0; if(!GetValue(hATR_M15,0,1,atr)) return false;
   double atrPts = (atr>0.0 ? atr/_Point : 0.0);
   if(atrPts < Quota_Min_ATR_Points) return false;

   double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK), bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   if(ask==0.0 || bid==0.0) return false;
   double spPts=(ask-bid)/_Point;
   if(spPts > Quota_MaxSpread_ATR_Frac * atrPts) return false;

   double emaStruct_1=0.0; if(!GetValue(hEMA_M15_struct,0,1,emaStruct_1)) return false;
   double rsi=0.0, macd=0.0; if(!GetValue(hRSI_M15,0,1,rsi) || !GetValue(hMACD_M15,0,1,macd)) return false;
   double f=0.0,s=0.0; if(!GetValue(hEMA_H1_fast,0,1,f) || !GetValue(hEMA_H1_slow,0,1,s)) return false;
   bool up=(f>s), dn=(f<s);
   double emaStructAdj = emaStruct_1 + 0.04*atr;
   bool wantLong  = up && (rsi>=51.0 || macd>0.0) && m15[1].close > emaStructAdj;
   bool wantShort = dn && (rsi<=49.0 || macd<0.0) && m15[1].close < emaStruct_1 - 0.04*atr;
   if(!wantLong && !wantShort) return false;

   int stopLevel = (int)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL);
   double useStopPts = MathMax((double)stopLevel+5.0, ATR_SL_mult * atrPts);
   if(useStopPts <= 0.0) return false;
   double baseLots = LotsFromRisk(useStopPts);
   double lots = baseLots * Quota_Risk_Factor;
   double minLot = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double stepLot = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   if(stepLot>0.0)
      lots = stepLot * MathFloor(lots/stepLot + 0.5);
   lots = MathMax(minLot, MathMin(baseLots, lots));
   if(lots <= 0.0) return false;
   NormalizeVolume(lots);

   double sl_buy  = NormalizePrice(ask - PriceFromPoints(useStopPts));
   double sl_sell = NormalizePrice(bid + PriceFromPoints(useStopPts));
   double tpR = TP2_R;
   double tp_buy  = NormalizePrice(ask + PriceFromPoints(useStopPts*tpR));
   double tp_sell = NormalizePrice(bid - PriceFromPoints(useStopPts*tpR));

   MqlTradeRequest rq; MqlTradeResult rs; ZeroMemory(rq); ZeroMemory(rs);
   rq.action=TRADE_ACTION_PENDING; rq.symbol=_Symbol; rq.volume=lots; rq.deviation=50; rq.magic=Magic; rq.type_filling=ORDER_FILLING_FOK;

   bool placed=false;
   if(wantLong)
   {
      rq.type = ORDER_TYPE_BUY_STOP;
      rq.price = NormalizePrice(m15[1].high + PriceFromPoints(MathMax(EntryBufferPts,10)));
      if(PointsFromPrice(rq.price-ask) < stopLevel+10)
         rq.price = NormalizePrice(ask + PriceFromPoints(stopLevel+10));
      rq.sl = sl_buy;
      rq.tp = tp_buy;
      if(SafeOrderSend(rq,rs))
      {
         pendingTicket=rs.order;
         pendingExpiryBars=PendingOrder_Expiry_Bars;
         pendingDirection=1;
         signalHigh=m15[1].high;
         signalLow=m15[1].low;
         partialTaken=false;
         secondPartialTaken=false;
         entryStopPoints=useStopPts;
         entryATRPoints=atrPts;
         entryTime=TimeCurrent();
         structureBreakOccurred=false;
         beMoved=false;
         quotaPendingTicket=rs.order;
         quotaTradeActive=false;
         probeStopPts=0.0;
         probeBarsSinceEntry=0;
         placed=true;
      }
   }
   if(!placed && wantShort)
   {
      rq.type = ORDER_TYPE_SELL_STOP;
      rq.price = NormalizePrice(m15[1].low - PriceFromPoints(MathMax(EntryBufferPts,10)));
      if(PointsFromPrice(bid-rq.price) < stopLevel+10)
         rq.price = NormalizePrice(bid - PriceFromPoints(stopLevel+10));
      rq.sl = sl_sell;
      rq.tp = tp_sell;
      if(SafeOrderSend(rq,rs))
      {
         pendingTicket=rs.order;
         pendingExpiryBars=PendingOrder_Expiry_Bars;
         pendingDirection=0;
         signalHigh=m15[1].high;
         signalLow=m15[1].low;
         partialTaken=false;
         secondPartialTaken=false;
         entryStopPoints=useStopPts;
         entryATRPoints=atrPts;
         entryTime=TimeCurrent();
         structureBreakOccurred=false;
         beMoved=false;
         quotaPendingTicket=rs.order;
         quotaTradeActive=false;
         probeStopPts=0.0;
         probeBarsSinceEntry=0;
         placed=true;
      }
   }
   if(!placed) quotaPendingTicket=0;
   return placed;
}

// Simple compression index: average (high-low) over lookback vs ATR; lower ranges => higher compression value
double ComputeCompressionIndex(int lookback){
   if(lookback < 5) lookback = 5;
   double sum=0; int count=0;
   for(int i=1;i<=lookback;i++){
      double hi=iHigh(_Symbol,PERIOD_M15,i);
      double lo=iLow(_Symbol,PERIOD_M15,i);
      if(hi==0 || lo==0) continue;
      sum += (hi - lo);
      count++;
   }
   if(count==0) return 0.0;
   double avgRange = sum / count;

   double atr=0.0;
   if(!GetValue(hATR_M15,0,1,atr) || atr<=0.0) return 0.0;

   // Define CI so LOWER ranges => HIGHER CI (true "compression").
   // If avgRange is small vs ATR, CI gets large.
   // Example: avgRange=0.5*ATR => CI = 2.0 (compressed); avgRange=1.5*ATR => CI ≈ 0.67 (expanded).
   double ci = (atr / avgRange);
   return ci;
}

void PrintStageInfo(int stage){
   if(!Diagnostics) return;
   int    adxMin   = (stage==2? ADX_Min_L2 : stage==1? ADX_Min_L1 : ADX_Min_L0);
   double ciMax    = (stage==2? CI_Max_L2  : stage==1? CI_Max_L1  : CI_Max_L0);
   double spaceATR = (stage==2? MinSpace_ATR_L2 : stage==1? MinSpace_ATR_L1 : MinSpace_ATR_L0);
   int    rsiMid   = (stage==2? RSI_Mid_L2 : 50);
   PrintFormat("[Stage] dayTrades=%d stage=%d adxMin=%d ciMax=%.1f spaceATR=%.2f rsiMid=%d",
               TradesToday, stage, adxMin, ciMax, spaceATR, rsiMid);
}

// Wrapper to allow probe-mode trading under caps
bool TryEnter_WithProbe(bool probe_mode){
   if(!probe_mode) return TryEnter();
   if(RiskGateBlocksEntry()) return false;
   // Probe: relax momentum (still trend-aligned), min lot, ATR*Probe_ATR_mult SL, TP=Probe_TP_R
   if(HasOpenPosition()) return false;
   MqlRates m15[3]; if(!GetRates(PERIOD_M15,3,m15)) return false;
   double atr; if(!GetValue(hATR_M15,0,1,atr)) return false;
   double atrPts = (atr>0.0? atr/_Point : 0.0);
   double emaFastH1, emaSlowH1; if(!GetValue(hEMA_H1_fast,0,1,emaFastH1)||!GetValue(hEMA_H1_slow,0,1,emaSlowH1)) return false;
   bool up = (emaFastH1>emaSlowH1), dn = (emaFastH1<emaSlowH1);
   double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK), bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   int stopLevel=(int)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL);
   double sl_pts = MathMax(stopLevel+5, Probe_ATR_mult*(atr/_Point));
   double lots = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   NormalizeVolume(lots);
   trade.SetExpertMagicNumber(Magic); trade.SetDeviationInPoints(50);
   if(up){
      double sl = NormalizeDouble(ask - sl_pts*_Point,(int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS));
      double tp = NormalizeDouble(ask + sl_pts*Probe_TP_R*_Point,(int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS));
      if(trade.Buy(lots,NULL,ask,sl,tp,"PROBE_LONG")){
         partialTaken=false; secondPartialTaken=false; entryTime=TimeCurrent(); entryStopPoints=sl_pts; entryATRPoints=atrPts; signalHigh=m15[1].high; signalLow=m15[1].low; structureBreakOccurred=false; beMoved=false; probeStopPts=sl_pts; probeBarsSinceEntry=0; BumpProbeCounter(true); return true;
      }
   }else if(dn){
      double sl = NormalizeDouble(bid + sl_pts*_Point,(int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS));
      double tp = NormalizeDouble(bid - sl_pts*Probe_TP_R*_Point,(int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS));
      if(trade.Sell(lots,NULL,bid,sl,tp,"PROBE_SHORT")){
         partialTaken=false; secondPartialTaken=false; entryTime=TimeCurrent(); entryStopPoints=sl_pts; entryATRPoints=atrPts; signalHigh=m15[1].high; signalLow=m15[1].low; structureBreakOccurred=false; beMoved=false; probeStopPts=sl_pts; probeBarsSinceEntry=0; BumpProbeCounter(true); return true;
      }
   }
   return false;
}

bool TryEnter(){
   string why="";

   // Equity gate with stall-grace
   if(!EquityGateAllows(why)) return LogAndReturnFalse(why);

   // Budget cannot be bypassed
   if(!RiskBudgetOK()) return LogAndReturnFalse("budget-gate");

   // Weekly equity budget gate (raised threshold & visible reason)
   if(Use_Weekly_Risk_Cap && weekStartEquity>0.0){
      double ddPct = 100.0 * (weekStartEquity - AccountInfoDouble(ACCOUNT_EQUITY)) / weekStartEquity;
      if(ddPct > WeeklyRiskCapPct){
         if(Diagnostics) Print("[Gate] Weekly risk cap hit: ", DoubleToString(ddPct,2), "% > ", WeeklyRiskCapPct, "%");
         return LogAndReturnFalse("budget-gate");
      }
   }

   if(RiskGateBlocksEntry()) return LogAndReturnFalse("riskGate");

   // --- MinBars Guard: Prevent early-begin history artifact ---
   if(Bars(_Symbol,PERIOD_M15) < MinBarsForSignals){ AppendReason(why,"minBars"); return LogAndReturnFalse(why); }

   // --- Data prerequisites ---
   MqlRates m15[3];
   if(!GetRates(PERIOD_M15,3,m15)) { AppendReason(why,"rates"); return LogAndReturnFalse(why); }
   double body = MathAbs(m15[1].close - m15[1].open);
   double range= (m15[1].high - m15[1].low);
   bool   bodyOK = (range>0 && (body/range) >= 0.35);
   if(!bodyOK) { AppendReason(why,"weakBody"); return LogAndReturnFalse(why); }
   double atr;
   if(!GetValue(hATR_M15,0,1,atr)) { AppendReason(why,"atr"); return LogAndReturnFalse(why); }
   
   // Spread check: stage 2 can optionally bypass
   int stage = LoosenStage();
   if(!(Stage2_IgnoresSpread && stage==2)){
      if(!SpreadOK_Dynamic(atr)) { AppendReason(why,"spread>cap"); return LogAndReturnFalse(why); }
   } else if(Diagnostics) {
      PrintFormat("[Stage2] Bypassing spread check (stage=%d, trades=%d)", stage, TradesToday);
   }
   
   if(!SessionAllowed()) { AppendReason(why,"session"); return LogAndReturnFalse(why); }
   if(HasOpenPosition()) { AppendReason(why,"openPos"); return LogAndReturnFalse(why); }
   int stage_for_cd = LoosenStage();
   if(LossStreak_Protection && cooldownBarsRemaining>0) {
      if(TradesToday==0 && stage_for_cd==2) { cooldownBarsRemaining=0; }
      else if(!Cooldown_Stage0_Only || stage_for_cd==0) { AppendReason(why,"cooldown"); return LogAndReturnFalse(why); }
   }

   double emaPull_1, emaStruct_1, emaFastH1, emaSlowH1;
   if(!GetValue(hEMA_M15_pull,0,1,emaPull_1) || !GetValue(hEMA_M15_struct,0,1,emaStruct_1) || !GetValue(hEMA_H1_fast,0,1,emaFastH1) || !GetValue(hEMA_H1_slow,0,1,emaSlowH1)) { AppendReason(why,"ema"); return LogAndReturnFalse(why); }

   bool trendUp = emaFastH1 > emaSlowH1;
   bool trendDown = emaFastH1 < emaSlowH1;
   if(Use_EMA200_Slope){
      if(trendUp && !TrendSlopeOK(true, emaSlowH1)){ AppendReason(why,"slopeLong"); trendUp=false; }
      if(trendDown && !TrendSlopeOK(false, emaSlowH1)){ AppendReason(why,"slopeShort"); trendDown=false; }
   }

   double macd_curr, macd_prev, rsi_curr, rsi_prev;
   if(!GetValue(hMACD_M15,0,1,macd_curr) || !GetValue(hMACD_M15,0,2,macd_prev) || !GetValue(hRSI_M15,0,1,rsi_curr) || !GetValue(hRSI_M15,0,2,rsi_prev)) { AppendReason(why,"momData"); return LogAndReturnFalse(why); }

   stage = LoosenStage();
   bool failSafeActive = (stage>0 && TradesToday < DailyMinTrades);
   bool allowLongManual = AllowLongs;
   bool allowShortManual = AllowShorts;
   bool allowLongSide = allowLongManual;
   bool allowShortSide = allowShortManual;
   if(!AllowLongsAuto) allowLongSide=false;
   if(!AllowShortsAuto) allowShortSide=false;
   bool macdUp = (macd_prev<=0 && macd_curr>0);
   bool macdDown=(macd_prev>=0 && macd_curr<0);
   bool rsiUp = (rsi_prev<50 && rsi_curr>50);
   bool rsiDown=(rsi_prev>50 && rsi_curr<50);
   bool longMomentum = RequireBothMomentum ? (macdUp && rsiUp) : (macdUp || rsiUp);
   bool shortMomentum= RequireBothMomentum ? (macdDown && rsiDown) : (macdDown || rsiDown);

   double macdSig_1=0.0;
   if(!GetValue(hMACD_M15,1,1,macdSig_1)) macdSig_1=macd_curr;
   double macdHist_now = macd_curr - macdSig_1;

   double sigPrev1[]; double macdSig_2=macdSig_1;
   if(CopyBuffer(hMACD_M15,1,2,1,sigPrev1)>0) macdSig_2=sigPrev1[0];
   double macdHist_prev= macd_prev - macdSig_2;

   bool macdRising  = (macdHist_now > macdHist_prev);
   bool macdFalling = (macdHist_now < macdHist_prev);

   double rsi_3=0.0;
   if(!GetValue(hRSI_M15,0,3,rsi_3)) rsi_3=rsi_prev;
   bool rsiSlopeUp   = (rsi_curr > rsi_3 + 0.8);
   bool rsiSlopeDown = (rsi_curr < rsi_3 - 0.8);

   longMomentum  = longMomentum  && macdRising  && rsiSlopeUp   && rsi_curr >= RSI_Min_Long;
   shortMomentum = shortMomentum && macdFalling && rsiSlopeDown && rsi_curr <= RSI_Max_Short;

   bool pullLong = (m15[1].low <= emaPull_1) && ((emaPull_1 - m15[1].low) >= Min_Pull_Depth_ATR * atr);
   bool pullShort= (m15[1].high >= emaPull_1) && ((m15[1].high - emaPull_1) >= Min_Pull_Depth_ATR * atr);
   bool aboveStruct = m15[1].close > emaStruct_1 + Structure_Buffer_ATR * atr;
   bool belowStruct = m15[1].close < emaStruct_1 - Structure_Buffer_ATR * atr;

   bool strengthUp=true,strengthDown=true; // permissive default
   if(hADX!=INVALID_HANDLE){
      double b0[],b1[],b2[];
      if(CopyBuffer(hADX,0,0,1,b0)>0 && CopyBuffer(hADX,1,0,1,b1)>0 && CopyBuffer(hADX,2,0,1,b2)>0){
         double adx0=b0[0], diPlus0=b1[0], diMinus0=b2[0];
         strengthUp   = (adx0 >= Min_ADX && diPlus0 > diMinus0);
         strengthDown = (adx0 >= Min_ADX && diMinus0 > diPlus0);
      }
   }

   int    adxMin   = (stage==2? ADX_Min_L2 : stage==1? ADX_Min_L1 : ADX_Min_L0);
   double ciMax    = (stage==2? CI_Max_L2  : stage==1? CI_Max_L1  : CI_Max_L0);
   double spaceATR = (stage==2? MinSpace_ATR_L2 : stage==1? MinSpace_ATR_L1 : MinSpace_ATR_L0);
   int    rsiMidRef= 50; if(stage==2) rsiMidRef = RSI_Mid_L2; // midline easing only stage2

   double swingH=LastSwingHigh(SR_Lookback), swingL=LastSwingLow(SR_Lookback);
   double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK), bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   bool spaceLong = (swingH>0 && ask>0 ? (swingH-ask) >= spaceATR*atr : true);
   bool spaceShort= (swingL>0 && bid>0 ? (bid-swingL) >= spaceATR*atr : true);

// Compression Index gating (now MIN-style: higher is more compressed)
double ci = ComputeCompressionIndex(20);
if(LoosenStage()==2) ci = 0.0; // bypass CI at stage 2
double ciMin = (stage==2 ? CI_Min_L2 : (stage==1 ? CI_Min_L1 : CI_Min_L0));
// If ciMin <= 0, disable gate
bool ciOK = (ciMin <= 0.0) ? true : (ci >= ciMin);

   // Adjust ADX gating to stage thresholds (permissive)
   if(hADX!=INVALID_HANDLE){
      double b0[],b1[],b2[];
      if(CopyBuffer(hADX,0,0,1,b0)>0 && CopyBuffer(hADX,1,0,1,b1)>0 && CopyBuffer(hADX,2,0,1,b2)>0){
         double adx0=b0[0], diPlus0=b1[0], diMinus0=b2[0];
         strengthUp   = (adx0 >= adxMin && diPlus0 > diMinus0);
         strengthDown = (adx0 >= adxMin && diMinus0 > diPlus0);
      }
   }
   bool canLong = allowLongSide && trendUp && longMomentum && pullLong && aboveStruct && spaceLong && strengthUp && ciOK;
   bool canShort= allowShortSide && trendDown && shortMomentum && pullShort && belowStruct && spaceShort && strengthDown && ciOK;

   if(!canLong && !canShort){
      if(!allowLongSide){
         if(!allowLongManual) AppendReason(why,"longDisabled");
         else if(!AllowLongsAuto) AppendReason(why,"longAutoGuard");
      }
      if(!trendUp) AppendReason(why,"noTrendLong");
      if(!longMomentum) AppendReason(why,"noMomLong");
      if(!pullLong) AppendReason(why,"noPullLong");
      if(!aboveStruct) AppendReason(why,"noStructLong");
      if(!spaceLong) AppendReason(why,"noSpaceLong");
      if(!strengthUp) AppendReason(why,"adxLong");
      if(!ciOK) AppendReason(why,"ci");
      if(!allowShortSide){
         if(!allowShortManual) AppendReason(why,"shortDisabled");
         else if(!AllowShortsAuto) AppendReason(why,"shortAutoGuard");
      }
      if(!trendDown) AppendReason(why,"noTrendShort");
      if(!shortMomentum) AppendReason(why,"noMomShort");
      if(!pullShort) AppendReason(why,"noPullShort");
      if(!belowStruct) AppendReason(why,"noStructShort");
      if(!spaceShort) AppendReason(why,"noSpaceShort");
      if(!strengthDown) AppendReason(why,"adxShort");
      if(!ciOK) AppendReason(why,"ci");
      // If no normal entry and day is dry, place one strict reduced-risk probe
      if(Enable_Probe_Trade && TradesToday<DailyMinTrades){
         // accelerate looseness by bar-drought, not only by clock
         if(BarsSinceLastEntry() >= 64){
            if(EnforceProbeTrade()) return true;
         }
      }
      return LogAndReturnFalse(why);
   }

   if(Enable_Daily_Min_Trade && TradesToday < DailyMinTrades){
      if(EnforceDailyTradeQuota()) return true;
   }

   int stopLevel=(int)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL);
   double minStopPts=stopLevel+5;
   double atrPts = (atr>0.0 ? atr/_Point : 0.0);
   double atrStopPts=ATR_SL_mult*atrPts;

   // --- Long Entry ---
   if(canLong){
      double structSLPrice=(swingL>0? swingL - Swing_Buffer_ATR*atr : ask - PriceFromPoints(atrStopPts));
      double defaultSLPrice=ask-PriceFromPoints(atrStopPts);
      double finalSLPrice=(swingL>0? MathMin(structSLPrice,defaultSLPrice):defaultSLPrice);
      double rawStopPts = PointsFromPrice(ask - finalSLPrice);
      double minStopPtsFloor = MathMax(minStopPts, MathMax(MinStop_Points, MinStop_ATR * (atrPts>0.0? atrPts : MinStop_Points)));
      double stopPts=MathMax(rawStopPts, minStopPtsFloor);
      const double MAX_SL_PTS = 4000;
      if(stopPts > MAX_SL_PTS) stopPts = MAX_SL_PTS;
      double stopDistPrice=PriceFromPoints(stopPts);
      double lots=LotsByRiskSafe(stopPts);
      lots = ApplyFailSafeRisk(lots, failSafeActive);
      if(lots<=0){ AppendReason(why,"noLots"); return LogAndReturnFalse(why); }
      NormalizeVolume(lots);
      double sl=NormalizePrice(ask-stopDistPrice);
      double tpR=TP2_R;
      double tp=NormalizePrice(ask+PriceFromPoints(stopPts*tpR));
      if(UseStopOrders){
         double pendingPrice=NormalizePrice(m15[1].high + PriceFromPoints(EntryBufferPts_New));
         if(PointsFromPrice(pendingPrice-ask) < stopLevel+10) pendingPrice=NormalizePrice(ask+PriceFromPoints(stopLevel+10));
         MqlTradeRequest rq; MqlTradeResult rs; ZeroMemory(rq); ZeroMemory(rs);
         rq.action=TRADE_ACTION_PENDING; rq.type=ORDER_TYPE_BUY_STOP; rq.symbol=_Symbol; rq.volume=lots; rq.price=pendingPrice; rq.sl=sl; rq.tp=tp; rq.magic=Magic; rq.deviation=50; rq.type_filling=ORDER_FILLING_FOK;
         if(SafeOrderSend(rq,rs)){
            pendingTicket=rs.order; pendingExpiryBars=PendingOrder_Expiry_Bars; pendingDirection=1; signalHigh=m15[1].high; signalLow=m15[1].low; entryStopPoints=stopPts; entryATRPoints=atrPts; entryTime=TimeCurrent(); structureBreakOccurred=false; beMoved=false; probeStopPts=0.0; probeBarsSinceEntry=0; return true;
         } else AppendReason(why,"buyStopFail");
      } else {
         trade.SetExpertMagicNumber(Magic); trade.SetDeviationInPoints(50);
         if(trade.Buy(lots,NULL,ask,sl,tp,"NF_Long")){
            partialTaken=false; secondPartialTaken=false; entryTime=TimeCurrent(); entryStopPoints=stopPts; entryATRPoints=atrPts; signalHigh=m15[1].high; signalLow=m15[1].low; structureBreakOccurred=false; beMoved=false; TradesToday++; probeStopPts=0.0; probeBarsSinceEntry=0; return true;
         } else AppendReason(why,"buyFail");
      }
   }

   // --- Short Entry ---
   if(canShort){
      double structSLPrice=(swingH>0? swingH + Swing_Buffer_ATR*atr : bid + PriceFromPoints(atrStopPts));
      double defaultSLPrice=bid+PriceFromPoints(atrStopPts);
      double finalSLPrice=(swingH>0? MathMax(structSLPrice,defaultSLPrice):defaultSLPrice);
      double rawStopPts = PointsFromPrice(finalSLPrice - bid);
      double minStopPtsFloor = MathMax(minStopPts, MathMax(MinStop_Points, MinStop_ATR * (atrPts>0.0? atrPts : MinStop_Points)));
      double stopPts=MathMax(rawStopPts, minStopPtsFloor);
      const double MAX_SL_PTS = 4000;
      if(stopPts > MAX_SL_PTS) stopPts = MAX_SL_PTS;
      double stopDistPrice=PriceFromPoints(stopPts);
      double lots=LotsByRiskSafe(stopPts);
      lots = ApplyFailSafeRisk(lots, failSafeActive);
      if(lots<=0){ AppendReason(why,"noLots"); return LogAndReturnFalse(why); }
      NormalizeVolume(lots);
      double sl=NormalizePrice(bid+stopDistPrice);
      double tpR=TP2_R; double tp=NormalizePrice(bid-PriceFromPoints(stopPts*tpR));
      if(UseStopOrders){
         double pendingPrice=NormalizePrice(m15[1].low - PriceFromPoints(EntryBufferPts_New));
         if(PointsFromPrice(bid - pendingPrice) < stopLevel+10) pendingPrice=NormalizePrice(bid-PriceFromPoints(stopLevel+10));
         MqlTradeRequest rq; MqlTradeResult rs; ZeroMemory(rq); ZeroMemory(rs);
         rq.action=TRADE_ACTION_PENDING; rq.type=ORDER_TYPE_SELL_STOP; rq.symbol=_Symbol; rq.volume=lots; rq.price=pendingPrice; rq.sl=sl; rq.tp=tp; rq.magic=Magic; rq.deviation=50; rq.type_filling=ORDER_FILLING_FOK;
         if(SafeOrderSend(rq,rs)){
            pendingTicket=rs.order; pendingExpiryBars=PendingOrder_Expiry_Bars; pendingDirection=0; signalHigh=m15[1].high; signalLow=m15[1].low; entryStopPoints=stopPts; entryATRPoints=atrPts; entryTime=TimeCurrent(); structureBreakOccurred=false; beMoved=false; probeStopPts=0.0; probeBarsSinceEntry=0; return true;
         } else AppendReason(why,"sellStopFail");
      } else {
         trade.SetExpertMagicNumber(Magic); trade.SetDeviationInPoints(50);
         if(trade.Sell(lots,NULL,bid,sl,tp,"NF_Short")){
            partialTaken=false; secondPartialTaken=false; entryTime=TimeCurrent(); entryStopPoints=stopPts; entryATRPoints=atrPts; signalHigh=m15[1].high; signalLow=m15[1].low; structureBreakOccurred=false; beMoved=false; TradesToday++; probeStopPts=0.0; probeBarsSinceEntry=0; return true;
         } else AppendReason(why,"sellFail");
      }
   }

   // Secondary continuation-style permissive path (only if stage>0 and still below daily min trades)
   if(EnableAltSignal && stage>0 && TradesToday < DailyMinTrades){
      // Basic continuation conditions
      bool altBuy = false, altSell=false;
      
      // Adaptive thresholds based on stage
      int    adxMinAlt   = (stage==2? ADX_Min_L2 : ADX_Min_L1);
      double ciMaxAlt    = (stage==2? CI_Max_L2  : CI_Max_L1);
      double spaceATRAlt = (stage==2? Stage2_MinSpace_ATR : MinSpace_ATR_L1);
      double rsiMidLine  = (stage==2? (double)RSI_Mid_L2 : 50.0);
      
      // ADX gate (can be optional if Stage2_OptionalADX enabled)
      bool adxOKAlt = true;
      if(!(Stage2_OptionalADX && stage==2)){
         if(hADX!=INVALID_HANDLE){
            double b0[],b1[],b2[];
            if(CopyBuffer(hADX,0,0,1,b0)>0 && CopyBuffer(hADX,1,0,1,b1)>0 && CopyBuffer(hADX,2,0,1,b2)>0){
               double adx0=b0[0], diPlus0=b1[0], diMinus0=b2[0];
               adxOKAlt = (adx0 >= adxMinAlt);
            }
         }
      }
      
      // Slope optional at stage 2
      bool slopeUpOKAlt = (Stage2_IgnoreSlope && stage==2) ? true : TrendSlopeOK(true, emaSlowH1);
      bool slopeDnOKAlt = (Stage2_IgnoreSlope && stage==2) ? true : TrendSlopeOK(false, emaSlowH1);
      
      // Price relations
      double ema50=emaStruct_1; // using structure EMA as proxy 50

      bool longAlt  = ( (macd_curr>macd_prev && macd_curr>0) && (rsi_curr>rsiMidLine+2.0) );
      bool shortAlt = ( (macd_curr<macd_prev && macd_curr<0) && (rsi_curr<rsiMidLine-2.0) );
      
      // Re-evaluate simple momentum presence with adaptive filters
      altBuy  = (longAlt && m15[1].close > ema50 && emaFastH1>emaSlowH1 && adxOKAlt && ciOK && slopeUpOKAlt);
      altSell = (shortAlt && m15[1].close < ema50 && emaFastH1<emaSlowH1 && adxOKAlt && ciOK && slopeDnOKAlt);

      if(!allowLongSide)  altBuy=false;
      if(!allowShortSide) altSell=false;
      
      // Structure space check (optional at stage 2)
      if(!(Stage2_IgnoreStructure && stage==2)){
         if(altBuy && !spaceLong) { AppendReason(why,"alt:no-space-long"); altBuy=false; }
         if(altSell && !spaceShort) { AppendReason(why,"alt:no-space-short"); altSell=false; }
      } else {
         // Even at stage 2, do minimal space check with relaxed threshold
         double swingHAlt=LastSwingHigh(SR_Lookback), swingLAlt=LastSwingLow(SR_Lookback);
         if(altBuy && swingHAlt>0 && ask>0){
            if((swingHAlt-ask) < spaceATRAlt*atr) { AppendReason(why,"alt:minimal-space-long"); altBuy=false; }
         }
         if(altSell && swingLAlt>0 && bid>0){
            if((bid-swingLAlt) < spaceATRAlt*atr) { AppendReason(why,"alt:minimal-space-short"); altSell=false; }
         }
      }
      if(altBuy || altSell){
         bool diAligned = true;
         if(hADX != INVALID_HANDLE){
            double adx0[],dip[],dim[];
            if(CopyBuffer(hADX,0,0,1,adx0)>0 && CopyBuffer(hADX,1,0,1,dip)>0 && CopyBuffer(hADX,2,0,1,dim)>0){
               if(altBuy)  diAligned = diAligned && (dip[0] > dim[0]);
               if(altSell) diAligned = diAligned && (dim[0] > dip[0]);
            }
         }
         double swingHalt=LastSwingHigh(SR_Lookback), swingLalt=LastSwingLow(SR_Lookback);
         if(altBuy  && (swingHalt - ask) < 0.15*atr) altBuy=false;
         if(altSell && (bid - swingLalt) < 0.15*atr) altSell=false;
         altBuy  = altBuy  && diAligned;
         altSell = altSell && diAligned;
      }
      if(altBuy || altSell){
         int stopLevel2=(int)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL);
         double atrPtsAlt = (atr>0.0 ? atr/_Point : 0.0);
         double rawStopPts = MathMax((double)stopLevel2+5.0, ATR_SL_mult * atrPtsAlt);
         double minStopPtsFloor = MathMax((double)stopLevel2+5.0, MathMax(MinStop_Points, MinStop_ATR * (atrPtsAlt>0.0? atrPtsAlt : MinStop_Points)));
         double stopPts = MathMax(rawStopPts, minStopPtsFloor);
         double stopDistPrice = PriceFromPoints(stopPts);
         double ask2=ask, bid2=bid; double slLong=NormalizePrice(ask2-stopDistPrice); double slShort=NormalizePrice(bid2+stopDistPrice);
         double lotsAlt = LotsByRiskSafe(stopPts);
         lotsAlt = ApplyFailSafeRisk(lotsAlt, failSafeActive);
         if(lotsAlt>0){
            NormalizeVolume(lotsAlt);
            bool usePending = Alt_UseStopOrders || (Bracket_UseStops && failSafeActive);
            if(usePending){
               double hi1=m15[1].high, lo1=m15[1].low;
               double bufPts = (double)Alt_EntryBufferPts;
               double channelHigh = hi1;
               double channelLow  = lo1;
               if(failSafeActive && DC_Period>0){
                  int highestIndex = iHighest(_Symbol,PERIOD_M15,MODE_HIGH,DC_Period,1);
                  if(highestIndex!=-1){
                     double hiTemp = iHigh(_Symbol,PERIOD_M15,highestIndex);
                     if(hiTemp>0.0) channelHigh = MathMax(channelHigh, hiTemp);
                  }
                  int lowestIndex = iLowest(_Symbol,PERIOD_M15,MODE_LOW,DC_Period,1);
                  if(lowestIndex!=-1){
                     double loTemp = iLow(_Symbol,PERIOD_M15,lowestIndex);
                     if(loTemp>0.0) channelLow = MathMin(channelLow, loTemp);
                  }
                  bufPts = MathMax(bufPts, DC_BufferPts);
               }
               double buf=PriceFromPoints(bufPts);
               if(altBuy){
                  MqlTradeRequest rq; MqlTradeResult rs; ZeroMemory(rq); ZeroMemory(rs);
                  rq.action=TRADE_ACTION_PENDING; rq.type=ORDER_TYPE_BUY_STOP; rq.symbol=_Symbol; rq.volume=lotsAlt; rq.price=NormalizePrice(channelHigh+buf);
                  if(PointsFromPrice(rq.price-ask2)<stopLevel2+10)
                     rq.price=NormalizePrice(ask2+PriceFromPoints(stopLevel2+10));
                  rq.sl=slLong; rq.tp=0; rq.deviation=50; rq.magic=Magic; rq.type_filling=ORDER_FILLING_FOK;
                  if(SafeOrderSend(rq,rs)){
                     pendingTicket=rs.order;
                     pendingExpiryBars=PendingOrder_Expiry_Bars;
                     pendingDirection=1;
                     signalHigh=m15[1].high;
                     signalLow=m15[1].low;
                     probeStopPts=0.0;
                     probeBarsSinceEntry=0;
                  }
               }
               if(altSell){
                  MqlTradeRequest rq; MqlTradeResult rs; ZeroMemory(rq); ZeroMemory(rs);
                  rq.action=TRADE_ACTION_PENDING; rq.type=ORDER_TYPE_SELL_STOP; rq.symbol=_Symbol; rq.volume=lotsAlt; rq.price=NormalizePrice(channelLow-buf);
                  if(PointsFromPrice(bid2-rq.price)<stopLevel2+10)
                     rq.price=NormalizePrice(bid2-PriceFromPoints(stopLevel2+10));
                  rq.sl=slShort; rq.tp=0; rq.deviation=50; rq.magic=Magic; rq.type_filling=ORDER_FILLING_FOK;
                  if(SafeOrderSend(rq,rs)){
                     pendingTicket=rs.order;
                     pendingExpiryBars=PendingOrder_Expiry_Bars;
                     pendingDirection=0;
                     signalHigh=m15[1].high;
                     signalLow=m15[1].low;
                     probeStopPts=0.0;
                     probeBarsSinceEntry=0;
                  }
               }
            } else {
               trade.SetExpertMagicNumber(Magic); trade.SetDeviationInPoints(50);
               if(altBuy){ if(trade.Buy(lotsAlt,NULL,ask2,slLong,0,"Alt_Long")){ TradesToday++; return true; } }
               if(altSell){ if(trade.Sell(lotsAlt,NULL,bid2,slShort,0,"Alt_Short")){ TradesToday++; return true; } }
            }
         }
      }
   }

   // --- Quota/Probe trade to ensure at least 1/day when clean signals absent ---
   if(Enable_Daily_Min_Trade && TradesToday==0){
      MqlDateTime dtQuota; TimeToStruct(TimeCurrent(), dtQuota);
      if(dtQuota.hour>=Quota_Trigger_Hour && dtQuota.hour<=Quota_Final_Hour){
         double atrQuota=0.0;
         if(GetValue(hATR_M15,0,1,atrQuota)){
            double atrPtsQuota = (atrQuota>0.0 ? atrQuota/_Point : 0.0);
            double askQuota=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
            double bidQuota=SymbolInfoDouble(_Symbol,SYMBOL_BID);
            if(askQuota>0.0 && bidQuota>0.0 && atrPtsQuota>=Quota_Min_ATR_Points){
               double spreadPtsQuota = (askQuota-bidQuota)/_Point;
               bool spreadOk = SpreadOK_Dynamic(atrQuota);
               if(atrPtsQuota>0.0 && Quota_MaxSpread_ATR_Frac>0.0 && spreadPtsQuota > Quota_MaxSpread_ATR_Frac * atrPtsQuota)
                  spreadOk = false;
               if(spreadOk){
                  double emaFastH1=0.0, emaSlowH1=0.0;
                  if(GetValue(hEMA_H1_fast,0,1,emaFastH1) && GetValue(hEMA_H1_slow,0,1,emaSlowH1)){
                     bool upQuota = (emaFastH1>emaSlowH1);
                     bool dnQuota = (emaFastH1<emaSlowH1);
                     if(upQuota || dnQuota){
                        int stopLevelQuota=(int)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL);
                        double stopPtsQuota = MathMax((double)stopLevelQuota+5.0, ATR_SL_mult * atrPtsQuota);
                        if(stopPtsQuota > 0.0){
                           double baseLots = LotsFromRisk(stopPtsQuota);
                           double lotsQuota = baseLots * Quota_Risk_Factor;
                           double minLot = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
                           double maxLot = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
                           double stepLot = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
                           if(stepLot>0.0)
                              lotsQuota = stepLot * MathFloor(lotsQuota/stepLot + 1e-6);
                           lotsQuota = MathMin(lotsQuota, baseLots);
                           lotsQuota = MathMax(minLot, MathMin(maxLot, lotsQuota));
                           NormalizeVolume(lotsQuota);
                           if(lotsQuota >= minLot && lotsQuota <= maxLot){
                              double slBuy  = NormalizePrice(askQuota-PriceFromPoints(stopPtsQuota));
                              double slSell = NormalizePrice(bidQuota+PriceFromPoints(stopPtsQuota));
                              double tpQuota = 0.0;
                              if(Quota_Use_Market){
                                 trade.SetExpertMagicNumber(Magic);
                                 trade.SetDeviationInPoints(50);
                                 if(upQuota){
                                    if(trade.Buy(lotsQuota,NULL,askQuota,slBuy,tpQuota,"QuotaBuy")){
                                       TradesToday++;
                                       partialTaken=false;
                                       secondPartialTaken=false;
                                       entryTime=TimeCurrent();
                                       entryStopPoints=stopPtsQuota;
                                       entryATRPoints=atrPtsQuota;
                                       signalHigh=m15[1].high;
                                       signalLow=m15[1].low;
                                       structureBreakOccurred=false;
                                       beMoved=false;
                                       quotaTradeActive=true;
                                       quotaPendingTicket=0;
                                       probeStopPts=0.0;
                                       probeBarsSinceEntry=0;
                                       return true;
                                    }
                                 } else if(dnQuota){
                                    if(trade.Sell(lotsQuota,NULL,bidQuota,slSell,tpQuota,"QuotaSell")){
                                       TradesToday++;
                                       partialTaken=false;
                                       secondPartialTaken=false;
                                       entryTime=TimeCurrent();
                                       entryStopPoints=stopPtsQuota;
                                       entryATRPoints=atrPtsQuota;
                                       signalHigh=m15[1].high;
                                       signalLow=m15[1].low;
                                       structureBreakOccurred=false;
                                       beMoved=false;
                                       quotaTradeActive=true;
                                       quotaPendingTicket=0;
                                       probeStopPts=0.0;
                                       probeBarsSinceEntry=0;
                                       return true;
                                    }
                                 }
                              } else {
                                 MqlRates ratesQuota[2];
                                 if(GetRates(PERIOD_M15,2,ratesQuota)){
                                    MqlTradeRequest rq; MqlTradeResult rs; ZeroMemory(rq); ZeroMemory(rs);
                                    rq.action=TRADE_ACTION_PENDING;
                                    rq.symbol=_Symbol;
                                    rq.volume=lotsQuota;
                                    rq.sl = (upQuota? slBuy : slSell);
                                    rq.tp = tpQuota;
                                    rq.magic=Magic;
                                    rq.deviation=50;
                                    rq.type_filling=ORDER_FILLING_FOK;
                                    rq.type = (upQuota? ORDER_TYPE_BUY_STOP : ORDER_TYPE_SELL_STOP);
                                    rq.comment = (upQuota? "QuotaBuy" : "QuotaSell");
                                    double trigger = (upQuota? NormalizePrice(ratesQuota[1].high + PriceFromPoints(Quota_EntryBufferPts))
                                                           : NormalizePrice(ratesQuota[1].low  - PriceFromPoints(Quota_EntryBufferPts)));
                                    if(upQuota && PointsFromPrice(trigger-askQuota) < stopLevelQuota+10)
                                       trigger = NormalizePrice(askQuota + PriceFromPoints(stopLevelQuota+10));
                                    if(dnQuota && PointsFromPrice(bidQuota-trigger) < stopLevelQuota+10)
                                       trigger = NormalizePrice(bidQuota - PriceFromPoints(stopLevelQuota+10));
                                    rq.price = trigger;
                                    if(SafeOrderSend(rq,rs)){
                                       pendingTicket = rs.order;
                                       pendingDirection = (upQuota?1:0);
                                       pendingExpiryBars = PendingOrder_Expiry_Bars;
                                       signalHigh = m15[1].high;
                                       signalLow  = m15[1].low;
                                       partialTaken=false;
                                       secondPartialTaken=false;
                                       entryStopPoints=stopPtsQuota;
                                       entryATRPoints=atrPtsQuota;
                                       entryTime=TimeCurrent();
                                       structureBreakOccurred=false;
                                       beMoved=false;
                                       quotaPendingTicket = rs.order;
                                       quotaTradeActive=false;
                                       probeStopPts=0.0;
                                       probeBarsSinceEntry=0;
                                       return true;
                                    }
                                 }
                              }
                           }
                        }
                     }
                  }
               }
            }
         }
      }
   }

   if(TryProbeEntry()) return true;

   // If we reach here, no entry was possible
   return LogAndReturnFalse(why);
}

// Helper function to log and return false
bool LogAndReturnFalse(const string why){
   if(Diagnostics && StringLen(why)>0)
      PrintFormat("NO-ENTRY %s %s: %s", _Symbol, TimeToString(TimeCurrent(), TIME_DATE|TIME_MINUTES), why);
   return false;
}

double GetVolDigits(double step)
{
   if(step<=0.0) return 2;
   return (int)MathRound(-MathLog10(step));
}

bool NormalizeVolume(double &vol)
{
   double minV = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxV = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(minV<=0 || step<=0){ minV=0.01; step=0.01; }
   vol = MathMax(minV, MathMin(maxV, MathCeil(vol/step)*step));
   vol = NormalizeDouble(vol, (int)GetVolDigits(step));
   return (vol >= minV && vol <= maxV);
}

bool SafeOrderSend(MqlTradeRequest &rq, MqlTradeResult &rs)
{
   MqlTradeCheckResult cr;
   if(!OrderCheck(rq, cr)){
      if(cr.retcode == TRADE_RETCODE_INVALID_VOLUME){
         double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
         if(step<=0) step=0.01;
         rq.volume = rq.volume + step;
         NormalizeVolume(rq.volume);
      } else {
         return false;
      }
   }
   return OrderSend(rq, rs);
}

double LotsFromRisk(double stop_points){
   if(stop_points<=0) return 0.0;
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double risk_pct = CurrentRiskPercent();
   double risk_money = balance * (risk_pct/100.0);

   double tick_value = SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE);
   double tick_size  = SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   double stop_price = stop_points*_Point;
   double ticks = stop_price / MathMax(1e-10, tick_size);
   double risk_per_lot = ticks * tick_value;

   double lots = (risk_per_lot>0.0 ? risk_money / risk_per_lot : 0.0);

   double minLot  = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);

   if(lots < minLot) lots = minLot;
   if(lots > maxLot) lots = maxLot;

   if(lotStep<=0.0) lotStep = MathMax(0.01, minLot);

   // step align
   lots = MathFloor((lots+1e-12)/lotStep)*lotStep;
   if(lots < minLot) lots = minLot;
   if(lots > maxLot) lots = maxLot;
   lots = NormalizeDouble(lots, (int)MathMin(8.0, MathMax(0.0, MathRound(-MathLog10(lotStep)))));
   return lots;
}

// Compute lot size from % risk and stop distance (in points)
double LotsByRiskSafe(double stopPts){
   if(stopPts<=0.0) return 0.0;

   double atr=0.0;
   double atrBuf[1];
   if(CopyBuffer(hATR_M15,0,1,1,atrBuf)==1)
      atr = atrBuf[0];

   double atrPts = (atr>0.0 ? atr/_Point : 0.0);
   double minStopFloor = MathMax(MinStop_Points, MinStop_ATR * (atrPts>0.0 ? atrPts : MinStop_Points));
   stopPts = MathMax(stopPts, minStopFloor);

   double bid = SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double moneyPerPoint=0.0;
   double prof=0.0;
   if(OrderCalcProfit(ORDER_TYPE_SELL,_Symbol,1.0,bid,bid-_Point,prof))
      moneyPerPoint = MathAbs(prof);

   if(moneyPerPoint<=0.0){
      double tv = SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE);
      double ts = SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
      if(ts>0.0)
         moneyPerPoint = (tv/ts)*_Point;
   }

   if(moneyPerPoint<=0.0) return 0.0;

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskMoney = equity*(CurrentRiskPercent()/100.0);
   double lossPerLot = moneyPerPoint*stopPts;
   if(lossPerLot<=0.0) return 0.0;

   double lots = riskMoney / lossPerLot;

   double minLot = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
   double step  = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);

   lots = MathMax(minLot, MathMin(MathMin(maxLot, MaxRiskLotsCap), lots));

   if(step>0.0)
      lots = MathFloor(lots/step) * step;

   lots = MathMax(minLot, MathMin(MathMin(maxLot, MaxRiskLotsCap), lots));

   return NormalizeDouble(lots,2);
}

bool PlacePendingOrMarket(bool isLong, double lots, double pendPrice, double sl, double tp, const string tag)
{
   NormalizeVolume(lots);
   MqlTradeRequest rq; MqlTradeResult rs; ZeroMemory(rq); ZeroMemory(rs);
   rq.action=TRADE_ACTION_PENDING;
   rq.type = (isLong? ORDER_TYPE_BUY_STOP: ORDER_TYPE_SELL_STOP);
   rq.symbol=_Symbol; rq.volume=lots; rq.price=pendPrice; rq.sl=sl; rq.tp=tp; rq.deviation=50; rq.magic=Magic; rq.type_filling=ORDER_FILLING_FOK;
   if(SafeOrderSend(rq,rs)) return true;
   // fallback once: market order (avoid ternary on member calls in MQL5)
   CTrade tr;
   tr.SetExpertMagicNumber(Magic);
   tr.SetDeviationInPoints(50);
   bool ok=false;
   if(isLong) ok = tr.Buy(lots, NULL, 0.0, sl, tp, tag);
   else       ok = tr.Sell(lots, NULL, 0.0, sl, tp, tag);
   return ok;
}

bool ProbeAllowed()
{
   if(!Enable_MinLot_Probe) return false;
   if(TradesToday >= DailyMinTrades) return false;
   if(HasOpenPosition()) return false;
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   if(dt.hour < Probe_Fire_Hour) return false;
   return true;
}

bool TryProbeEntry()
{
   if(!ProbeAllowed()) return false;
   double atr=0.0; if(!GetValue(hATR_M15,0,1,atr)) return false;
   double atrPts = atr/_Point; if(atrPts<=0) return false;
   double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK), bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double spreadPts = (ask-bid)/_Point;
   if(spreadPts > Probe_Max_Spread_ATR_Frac * atrPts) return false;
   double f=0,s=0, ema50=0, rsi=0, macd=0;
   if(!GetValue(hEMA_H1_fast,0,1,f) || !GetValue(hEMA_H1_slow,0,1,s)) return false;
   if(!GetValue(hEMA_M15_struct,0,1,ema50)) return false;
   if(!GetValue(hRSI_M15,0,1,rsi) || !GetValue(hMACD_M15,0,1,macd)) return false;
   bool up=(f>s), dn=(f<s);
   MqlRates m15[3]; if(!GetRates(PERIOD_M15,3,m15)) return false;
   bool wantLong  = up && (rsi>=50 || macd>0) && (m15[1].close>ema50);
   bool wantShort = dn && (rsi<=50 || macd<0) && (m15[1].close<ema50);
   if(!wantLong && !wantShort) return false;
   double lots = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   NormalizeVolume(lots);
   int stopLevel=(int)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL);
   double useStopPts = MathMax((double)stopLevel+5.0, ATR_SL_mult * atrPts);
   double sl = (wantLong? NormalizePrice(ask-PriceFromPoints(useStopPts)) : NormalizePrice(bid+PriceFromPoints(useStopPts)));
   double tp = (wantLong? NormalizePrice(ask+PriceFromPoints(useStopPts*TP2_R)) : NormalizePrice(bid-PriceFromPoints(useStopPts*TP2_R)));
   double pend = (wantLong? NormalizePrice(m15[1].high + PriceFromPoints(EntryBufferPts)) : NormalizePrice(m15[1].low - PriceFromPoints(EntryBufferPts)));
   bool ok = PlacePendingOrMarket(wantLong, lots, pend, sl, tp, (wantLong? "ProbeLong" : "ProbeShort"));
   if(ok){ TradesToday++; BumpProbeCounter(true); return true; }
   return false;
}

// --- Helpers: day-of-year & day/week ids (no TimeDayOfYear in MQL5) ---
int DayOfYear(datetime t) {
   MqlDateTime dt; TimeToStruct(t, dt);
   MqlDateTime jan1;
   jan1.year=dt.year; jan1.mon=1; jan1.day=1;
   jan1.hour=0; jan1.min=0; jan1.sec=0;
   jan1.day_of_week=0; jan1.day_of_year=0;
   datetime d0=StructToTime(jan1);
   return (int)((t - d0) / 86400) + 1;
}
void ResetRiskWindowsIfNeeded(){
   int d,w; DayWeekIds(TimeCurrent(), d, w);
   if(day_id != d){ day_id = d; R_today = 0.0; probe_trades_today = 0; }
   if(week_id != w){ week_id = w; R_week = 0.0; }
}

bool RiskGateBlocksEntry(){
   if(!RiskGate_Enable) return false;
   ResetDailyCounters();
   if(!MathIsValidNumber(gR_day))  gR_day=0.0;
   if(!MathIsValidNumber(gR_week)) gR_week=0.0;

   static int barsSinceTrade=0;
   barsSinceTrade++;
   if(gLastTradeTime>0){
      int barsIdle = int((TimeCurrent() - gLastTradeTime)/PeriodSeconds(PERIOD_M15));
      barsSinceTrade = MathMax(0, barsIdle);
   }
   if(barsSinceTrade >= RiskGate_Unlock_NoTradeBars){
      if(Enable_Diagnostics) Print("[Gate] idle-unlock after ",barsSinceTrade," bars");
      return false;
   }

   bool blocked = (gR_day <= RiskGate_MinR_Day) || (gR_week <= RiskGate_MinR_Week);
   if(blocked && Enable_Diagnostics)
      PrintFormat("[Gate] Risk cap active: R_today=%.2f R_week=%.2f", gR_day, gR_week);
   return blocked;
}

double CurrentRiskPercent(){
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   if(peak_equity <= 0.0) peak_equity = eq;
   if(eq > peak_equity) peak_equity = eq;
   double dd_pct = 100.0 * (peak_equity - eq) / MathMax(1.0, peak_equity);
   double base = Risk_Percent_Base;
   if(dd_pct >= Risk_Throttle_DD_Pct) base = MathMin(base, Risk_Throttle_Pct);
   return base;
}

void RecordClosedTradeR(const ulong deal_id){
   ResetRiskWindowsIfNeeded();
   if(!HistoryDealSelect(deal_id)) return;
   long magic = (long)HistoryDealGetInteger(deal_id, DEAL_MAGIC);
   if((ulong)magic != Magic) return;

   long entryType = HistoryDealGetInteger(deal_id, DEAL_ENTRY);
   if(entryType != DEAL_ENTRY_OUT) return;

   // Profit in account currency
   double profit = HistoryDealGetDouble(deal_id, DEAL_PROFIT)
                 + HistoryDealGetDouble(deal_id, DEAL_SWAP)
                 + HistoryDealGetDouble(deal_id, DEAL_COMMISSION);

   ulong positionId = (ulong)HistoryDealGetInteger(deal_id, DEAL_POSITION_ID);
   double riskCash = activeTradeRiskCash;
   if(positionId != 0 && activeTradePositionId != 0 && positionId != activeTradePositionId)
      riskCash = 0.0;

   if(riskCash <= 0.0){
      double stop_pts = entryStopPoints;
      if(stop_pts <= 0.0) stop_pts = probeStopPts;
      if(stop_pts <= 0.0){
         double atrLast=0.0;
         if(GetValue(hATR_M15,0,1,atrLast)) stop_pts = MathMax(1.0, atrLast/_Point);
      }
      double tick_value = SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE);
      double tick_size  = SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
      double baseLots = (activeTradeInitialLots>0.0? activeTradeInitialLots : HistoryDealGetDouble(deal_id, DEAL_VOLUME));
      double one_r_cash_per_lot = activeTradeOneRCashPerLot;
      if(one_r_cash_per_lot <= 0.0 && stop_pts>0.0 && tick_value>0.0 && tick_size>0.0)
         one_r_cash_per_lot = (stop_pts*_Point/MathMax(1e-10, tick_size)) * tick_value;
      if(one_r_cash_per_lot>0.0 && baseLots>0.0)
         riskCash = one_r_cash_per_lot * baseLots;
   }

   if(riskCash <= 0.0) return;

   double r_units = (riskCash!=0.0 ? profit/riskCash : 0.0);

   R_today += r_units;
   R_week  += r_units;

   if(positionId != 0 && positionId == activeTradePositionId){
      double closedVol = HistoryDealGetDouble(deal_id, DEAL_VOLUME);
      activeTradeRemainingLots = MathMax(0.0, activeTradeRemainingLots - closedVol);
      if(activeTradeRemainingLots <= 0.0 || !PositionSelect(_Symbol)){
         activeTradeRiskCash = 0.0;
         activeTradeOneRCashPerLot = 0.0;
         activeTradeInitialLots = 0.0;
         activeTradeRemainingLots = 0.0;
         activeTradePositionId = 0;
      }
   } else if(!PositionSelect(_Symbol)){
      activeTradeRiskCash = 0.0;
      activeTradeOneRCashPerLot = 0.0;
      activeTradeInitialLots = 0.0;
      activeTradeRemainingLots = 0.0;
      activeTradePositionId = 0;
   }
}

// Daily/weekly risk caps (approx R-based and balance-based)
// Track realized PnL of EA deals today/this week and block new entries if caps exceeded.
// (Skeleton; wire to your existing counters if present.)
// Example thresholds via inputs: DailyRiskMaxPct, WeeklyRiskMaxPct, MaxConsecLosses_Day.
// At entry time: if(today_loss_pct >= DailyRiskMaxPct || weekly_loss_pct >= WeeklyRiskMaxPct || consec_losses_today >= MaxConsecLosses_Day)
// block TryEnter() unless Allow_Probe_When_Capped is true with min lot.
bool CapsAllowTrading(bool &probe_mode_out){
   ResetRiskWindowsIfNeeded();
   probe_mode_out = false;
   if(!Enable_RiskCaps) return true;
   bool day_ok   = (R_today > -DailyLossCap_R);
   bool week_ok  = (R_week  > -WeeklyLossCap_R);
   if(day_ok && week_ok) return true;
   if(Allow_Probe_When_Capped && probe_trades_today < Probe_Max_Per_Day){
      probe_mode_out = true; return true;
   }
   return false;
}

void BumpProbeCounter(bool probe_mode){
   if(probe_mode) probe_trades_today++;
}

double ApplyFailSafeRisk(double lots, bool apply){
   if(!apply || lots<=0.0) return lots;
   double mult = FailSafe_RiskMult;
   if(mult >= 0.995) return lots;
   if(mult < 0.0) mult = 0.0;
   double minLot = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
   double step  = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   double scaled = lots * mult;
   if(step>0.0 && scaled>0.0)
      scaled = MathFloor(scaled/step) * step;
   if(scaled < minLot)
      scaled = minLot;
   if(scaled > maxLot)
      scaled = maxLot;
   if(scaled > MaxRiskLotsCap)
      scaled = MaxRiskLotsCap;
   return NormalizeDouble(MathMin(lots, scaled), 2);
}

void UpdateSidePerformance(bool isBuy, bool win){
   int val = (win ? 1 : 0);
   if(isBuy){
      if(longRollingCount < 30){
         longResults[longRollingCount] = val;
         longRollingCount++;
         if(val) WinsLong30++;
      } else {
         if(longResults[longRollingIdx]) WinsLong30--;
         longResults[longRollingIdx] = val;
         if(val) WinsLong30++;
         longRollingIdx = (longRollingIdx+1) % 30;
      }
      TradesLong30 = (int)MathMin(longRollingCount,30);
   } else {
      if(shortRollingCount < 30){
         shortResults[shortRollingCount] = val;
         shortRollingCount++;
         if(val) WinsShort30++;
      } else {
         if(shortResults[shortRollingIdx]) WinsShort30--;
         shortResults[shortRollingIdx] = val;
         if(val) WinsShort30++;
         shortRollingIdx = (shortRollingIdx+1) % 30;
      }
      TradesShort30 = (int)MathMin(shortRollingCount,30);
   }

   double wrL = (TradesLong30>=10 ? (100.0*WinsLong30/TradesLong30) : 100.0);
   double wrS = (TradesShort30>=10 ? (100.0*WinsShort30/TradesShort30) : 100.0);
   AllowLongsAuto  = (wrL >= 45.0);
   AllowShortsAuto = (wrS >= 45.0);
}

bool NewM15Bar(){
   datetime t=iTime(_Symbol,PERIOD_M15,0);
   if(t!=0 && t!=lastM15BarTime){
      lastM15BarTime=t;
      return true;
   }
   return false;
}

bool HasOpenPosition(){
   if(PositionSelect(_Symbol)==false) return false;
   if((ulong)PositionGetInteger(POSITION_MAGIC)!=Magic) return false;
   return true;
}

bool SessionAllowed(){
   if(Only_London_NY){
      MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
      if(!(dt.hour>=7 && dt.hour<20)) return false;
   }
   if(!Use_Session_Filter) return true; // hard bypass to avoid session starvation
   // Stage 2 override: allow entries late in day regardless of session
   if(Stage2_OverrideSession && LoosenStage()==2) return true;

   if(Enhanced_Session_Filter){
      MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
      if(Skip_Monday_Asian && dt.day_of_week==1 && dt.hour < Monday_Skip_Until_Hour) return false;
      if(Skip_Friday_Late && dt.day_of_week==5 && dt.hour >= Friday_Cutoff_Hour) return false;
      if(dt.hour < LondonNY_Start_Hour || dt.hour >= LondonNY_End_Hour) return false;
      return true;
   }
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   if(Session_Start_Hour <= Session_End_Hour)
      return (dt.hour >= Session_Start_Hour && dt.hour < Session_End_Hour);
   return (dt.hour >= Session_Start_Hour || dt.hour < Session_End_Hour);
}

void ManagePartialAndTrail(){
   static datetime lastBarCountTime=0;
   if(!PositionSelect(_Symbol)) { partialTaken=false; secondPartialTaken=false; probeBarsSinceEntry=0; probeStopPts=0.0; lastBarCountTime=0; return; }
   if((ulong)PositionGetInteger(POSITION_MAGIC)!=Magic){ lastBarCountTime=0; return; }

   probeBarsSinceEntry++;
   if(probeStopPts>0 && probeBarsSinceEntry<=Probe_EarlyAbort_Bars){
      long t = (long)PositionGetInteger(POSITION_TYPE);
      double openP = PositionGetDouble(POSITION_PRICE_OPEN);
      double bidP=SymbolInfoDouble(_Symbol,SYMBOL_BID), askP=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
      double curP = (t==POSITION_TYPE_BUY? bidP: askP);
      double adversePts = PointsFromPrice(MathMax(0.0, (t==POSITION_TYPE_BUY? openP-curP : curP-openP)));
      if(adversePts >= Probe_EarlyAbort_R * probeStopPts){
         trade.SetExpertMagicNumber(Magic); trade.PositionClose(_Symbol); return;
      }
   }

   datetime currentBarTime = iTime(_Symbol,PERIOD_M15,0);
   if(lastBarCountTime==0)
      lastBarCountTime = currentBarTime;
   else if(currentBarTime > lastBarCountTime)
   {
      int periodSec = PeriodSeconds(PERIOD_M15);
      int delta = 1;
      if(periodSec>0)
         delta = (int)MathMax(1.0, (double)(currentBarTime - lastBarCountTime) / (double)periodSec);
      barsSinceEntry += delta;
      lastBarCountTime = currentBarTime;
   }

   long type  = (long)PositionGetInteger(POSITION_TYPE);
   double vol = PositionGetDouble(POSITION_VOLUME);
   double open= PositionGetDouble(POSITION_PRICE_OPEN);
   double sl  = PositionGetDouble(POSITION_SL);
   double tp  = PositionGetDouble(POSITION_TP);

   if(barsSinceEntry <= EarlyAbort_Bars && lastEntryStopPts>0.0)
   {
      double bidEarly=SymbolInfoDouble(_Symbol,SYMBOL_BID);
      double askEarly=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
      double curPrice = (type==POSITION_TYPE_BUY? bidEarly : askEarly);
      double adversePts = PointsFromPrice(MathMax(0.0, (type==POSITION_TYPE_BUY? open-curPrice : curPrice-open)));
      if(adversePts >= EarlyAbort_R * lastEntryStopPts)
      {
         trade.SetExpertMagicNumber(Magic);
         trade.PositionClose(_Symbol);
         partialTaken=false;
         secondPartialTaken=false;
         return;
      }
   }

   // compute R based on current SL distance (may have moved to BE / trailed)
   double stop_points = MathMax(1.0, PointsFromPrice(MathAbs(open - sl)));
   double tp1_points  = stop_points * TP1_R;
   double useTP2_R    = (entryTP2_R>0? entryTP2_R : TP2_R);
   double useTP3_R    = (entryTP3_R>0? entryTP3_R : TP3_R);
   double tp2_points  = stop_points * useTP2_R;
   double tp3_points  = stop_points * useTP3_R;

   double bid=0,ask=0;
   SymbolInfoDouble(_Symbol,SYMBOL_BID,bid);
   SymbolInfoDouble(_Symbol,SYMBOL_ASK,ask);

   // --- Detect structure break (based on stored signal extremes) ---
   if(MoveBE_On_StructureBreak && !structureBreakOccurred){
      MqlRates rates[2];
      if(GetRates(PERIOD_M15,2,rates)){
         double bufferPrice = PriceFromPoints(Break_Buffer_Points);
         if(type==POSITION_TYPE_BUY && signalHigh>0){ if(rates[1].high >= signalHigh + bufferPrice) structureBreakOccurred=true; }
         if(type==POSITION_TYPE_SELL && signalLow>0){ if(rates[1].low  <= signalLow  - bufferPrice) structureBreakOccurred=true; }
      }
   }

   // current R relative to initial stop distance
   double currentPriceInitial = (type==POSITION_TYPE_BUY ? bid : ask);
   double gainInitialPts = PointsFromPrice(MathAbs(currentPriceInitial - open));
   double currentRInitial = (entryStopPoints>0 ? gainInitialPts / entryStopPoints : 0.0);

   // --- First Partial (TP1) ---
   if(!partialTaken){
      if(type==POSITION_TYPE_BUY){
         if(bid >= open + PriceFromPoints(tp1_points)){
            double closeVol = NormalizeDouble(vol * TP1_Close_Pct,2);
            trade.SetExpertMagicNumber(Magic);
            if(closeVol>=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN)){
               if(trade.PositionClosePartial(_Symbol, closeVol)){
                  partialTaken=true;
               }
            }else{
               partialTaken=true; // can't partial due to min volume
            }
         }
      }else if(type==POSITION_TYPE_SELL){
         if(ask <= open - PriceFromPoints(tp1_points)){
            double closeVol = NormalizeDouble(vol * TP1_Close_Pct,2);
            trade.SetExpertMagicNumber(Magic);
            if(closeVol>=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN)){
               if(trade.PositionClosePartial(_Symbol, closeVol)){
                  partialTaken=true;
               }
            }else{
               partialTaken=true;
            }
         }
      }
   }

   // --- Second Partial (TP2) ---
   if(partialTaken && !secondPartialTaken){
      if(type==POSITION_TYPE_BUY){
         if(bid >= open + PriceFromPoints(tp2_points)){
            double closeVol = NormalizeDouble(vol * TP2_Close_Pct,2);
            trade.SetExpertMagicNumber(Magic);
            if(closeVol>=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN)){
               if(trade.PositionClosePartial(_Symbol, closeVol)){
                  secondPartialTaken=true;
               }
            } else secondPartialTaken=true;
         }
      }else if(type==POSITION_TYPE_SELL){
         if(ask <= open - PriceFromPoints(tp2_points)){
            double closeVol = NormalizeDouble(vol * TP2_Close_Pct,2);
            trade.SetExpertMagicNumber(Magic);
            if(closeVol>=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN)){
               if(trade.PositionClosePartial(_Symbol, closeVol)){
                  secondPartialTaken=true;
               }
            } else secondPartialTaken=true;
         }
      }
   }

   // --- Optional Hard TP3 (runner close) ---
   if(Use_TP3 && secondPartialTaken){
      if(type==POSITION_TYPE_BUY){
         if(bid >= open + PriceFromPoints(tp3_points)){
            trade.SetExpertMagicNumber(Magic);
            trade.PositionClose(_Symbol);
            return;
         }
      }else if(type==POSITION_TYPE_SELL){
         if(ask <= open - PriceFromPoints(tp3_points)){
            trade.SetExpertMagicNumber(Magic);
            trade.PositionClose(_Symbol);
            return;
         }
      }
   }

   // --- Conditional Break-Even Move ---
   if(partialTaken && !beMoved){
      bool allowMoveBE = true;
      if(MoveBE_On_StructureBreak){
         allowMoveBE = (structureBreakOccurred || currentRInitial >= BE_Fallback_R);
      }
      if(allowMoveBE){
         double newSL = NormalizePrice(open);
         trade.PositionModify(_Symbol,newSL,tp);
         beMoved=true;
      }
   }

   // --- Early abort: cut losers quickly in dead flow ---
   if(entryTime>0){
      int periodSec = PeriodSeconds(PERIOD_M15);
      int barsHeld = (periodSec>0 ? (int)((TimeCurrent() - entryTime) / periodSec) : 0);
      if(barsHeld <= EarlyAbort_Bars){
         double bidEA=0.0, askEA=0.0; SymbolInfoDouble(_Symbol,SYMBOL_BID,bidEA); SymbolInfoDouble(_Symbol,SYMBOL_ASK,askEA);
         double cur = (type==POSITION_TYPE_BUY ? bidEA : askEA);
         double riskPts = MathMax(1.0, MathAbs(open-sl)/_Point);
         double movePts = MathAbs(cur-open)/_Point;
         bool adverse = (type==POSITION_TYPE_BUY ? cur < open : cur > open);
         if(adverse && movePts < EarlyAbort_R * riskPts){
            trade.SetExpertMagicNumber(Magic);
            if(trade.PositionClose(_Symbol)){
               partialTaken=false;
               secondPartialTaken=false;
               return;
            }
         }
      }
   }

   // Optional chandelier trail after BE
   if(Use_Trailing){
      double atr=0.0;
      if(!GetValue(hATR_M15,0,1,atr)) return; // last closed bar ATR
      // dynamic trail tightening beyond trigger R
      double bidNow=0, askNow=0; SymbolInfoDouble(_Symbol,SYMBOL_BID,bidNow); SymbolInfoDouble(_Symbol,SYMBOL_ASK,askNow);
      double currentPrice = (type==POSITION_TYPE_BUY ? bidNow : askNow);
      double riskPoints = PointsFromPrice(MathAbs(open - sl));
      double gainPoints = PointsFromPrice(MathAbs(currentPrice - open));
      double currentR = (riskPoints>0 ? gainPoints / riskPoints : 0);
      double chosenTrailMult = (currentR >= Trail_Tighten_Trigger_R ? Trail_Tight_ATR_mult : Trail_ATR_mult);
      double trail_dist = chosenTrailMult * atr;

      // If we delay trailing until partial OR a certain R achieved
      if(DelayTrailUntilPartial && !partialTaken){
         // compute current R
         double bidNow=0, askNow=0; SymbolInfoDouble(_Symbol,SYMBOL_BID,bidNow); SymbolInfoDouble(_Symbol,SYMBOL_ASK,askNow);
         double currentPrice = (type==POSITION_TYPE_BUY ? bidNow : askNow);
         double riskPoints = PointsFromPrice(MathAbs(open - sl));
         double gainPoints = PointsFromPrice(MathAbs(currentPrice - open));
         double currentR = (riskPoints>0 ? gainPoints / riskPoints : 0);
         if(currentR < Trail_Start_R) return; // too early to trail
      }

      if(type==POSITION_TYPE_BUY){
         double newSL = MathMax(sl, (bid - trail_dist));
         // never below BE once BE moved
         if(beMoved) newSL = MathMax(newSL, open);
         // honor stop level
         int stopLevel=(int)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL);
         double minDist = PriceFromPoints(stopLevel + 5);
         if((bid - newSL) < minDist) newSL = bid - minDist;
         newSL = NormalizePrice(newSL);
         if(newSL > sl + PriceFromPoints(2)) trade.PositionModify(_Symbol, newSL, tp);
      }else{
         double newSL = MathMin(sl, (ask + trail_dist));
         if(beMoved) newSL = MathMin(newSL, open);
         int stopLevel=(int)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL);
         double minDist = PriceFromPoints(stopLevel + 5);
         if((newSL - ask) < minDist) newSL = ask + minDist;
         newSL = NormalizePrice(newSL);
         if(newSL < sl - PriceFromPoints(2)) trade.PositionModify(_Symbol, newSL, tp);
      }
   }

   // --- Time & Volatility Compression Exit ---
   if(entryTime>0 && Use_Time_Exit){
      datetime now = TimeCurrent();
      int barsHeld = (int)((now - entryTime) / PeriodSeconds(PERIOD_M15));
      if(barsHeld >= Max_Bars_In_Trade){
         trade.SetExpertMagicNumber(Magic);
         trade.PositionClose(_Symbol);
         return;
      }
      if(barsHeld >= 48){
         double atrNow=0.0; if(GetValue(hATR_M15,0,1,atrNow)){
            double bid2=0, ask2=0; SymbolInfoDouble(_Symbol,SYMBOL_BID,bid2); SymbolInfoDouble(_Symbol,SYMBOL_ASK,ask2);
            double priceNow = (type==POSITION_TYPE_BUY? bid2: ask2);
            double progress = PointsFromPrice(MathAbs(priceNow - open)) / MathMax(1.0, PointsFromPrice(MathAbs(open - sl)));
            if(atrNow < 0.7*PriceFromPoints(entryATRPoints) && progress < 0.30){
               trade.SetExpertMagicNumber(Magic);
               trade.PositionClose(_Symbol);
               return;
            }
         }
      }
   }
}

int OnInit(){
   PrintFormat("[VOL] min=%.3f step=%.3f max=%.3f",
               SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN),
               SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP),
               SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX));
   trade.SetExpertMagicNumber(Magic);
   ArrayInitialize(longResults,0);
   ArrayInitialize(shortResults,0);
   WinsLong30=WinsShort30=TradesLong30=TradesShort30=0;
   AllowLongsAuto=AllowShortsAuto=true;
   longRollingIdx=shortRollingIdx=0;
   longRollingCount=shortRollingCount=0;
   ArrayInitialize(recentWinsLosses,0.0);
   rwlIndex=0; rwlCount=0;

   hEMA_H1_fast   = iMA(_Symbol,PERIOD_H1,H1_EMA_Fast,0,MODE_EMA,PRICE_CLOSE);
   hEMA_H1_slow   = iMA(_Symbol,PERIOD_H1,H1_EMA_Slow,0,MODE_EMA,PRICE_CLOSE);
   hEMA_M15_pull  = iMA(_Symbol,PERIOD_M15,M15_EMA_Pull,0,MODE_EMA,PRICE_CLOSE);
   hEMA_M15_struct= iMA(_Symbol,PERIOD_M15,M15_EMA_Struct,0,MODE_EMA,PRICE_CLOSE);
   hRSI_M15       = iRSI(_Symbol,PERIOD_M15,RSI_Period,PRICE_CLOSE);
   hMACD_M15      = iMACD(_Symbol,PERIOD_M15,MACD_Fast,MACD_Slow,MACD_Signal,PRICE_CLOSE);
   hATR_M15       = iATR(_Symbol,PERIOD_M15,ATR_Period);
   hFractals_M15  = iFractals(_Symbol,PERIOD_M15);
   hADX           = iADX(_Symbol,PERIOD_M15,ADX_Period);

   if(hEMA_H1_fast==INVALID_HANDLE || hEMA_H1_slow==INVALID_HANDLE ||
      hEMA_M15_pull==INVALID_HANDLE || hEMA_M15_struct==INVALID_HANDLE ||
      hRSI_M15==INVALID_HANDLE || hMACD_M15==INVALID_HANDLE ||
      hATR_M15==INVALID_HANDLE || hFractals_M15==INVALID_HANDLE || hADX==INVALID_HANDLE){
      Print("Indicator handle creation failed");
      return(INIT_FAILED);
   }
   // Visibility sanity
   int stopLevel=(int)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL);
   int freezeLevel=(int)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_FREEZE_LEVEL);
   Print("[Init] StopLevel=",stopLevel," FreezeLevel=",freezeLevel," Point=",DoubleToString(_Point,Digits())," Digits=",(int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS));
   PrintFormat("[ENV] %s: Digits=%d Point=%g StopLevel=%d FreezeLevel=%d",
               _Symbol,
               (int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS),
               SymbolInfoDouble(_Symbol,SYMBOL_POINT),
               (int)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL),
               (int)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_FREEZE_LEVEL));
   lastM15BarTime = iTime(_Symbol,PERIOD_M15,0);
   dayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   if(weekStartBalance<=0.0) weekStartBalance = dayStartBalance;
   MqlDateTime initDt; TimeCurrent(initDt); weekAnchorDayOfYear = initDt.day_of_year;
   dayLossCount = 0; quotaLossCount = 0;
   quotaPendingTicket = 0;
   quotaTradeActive = false;
   lastEntryBarTime = 0;
   ResetRiskWindowsIfNeeded();
   peak_equity = AccountInfoDouble(ACCOUNT_EQUITY);
   // Initialize weekly equity anchor
   MqlDateTime d; TimeToStruct(TimeCurrent(), d);
   int weekId = (int)(d.year*100 + (d.day_of_year/7));
   lastWeekId = weekId;
   weekStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason){
   if(hEMA_H1_fast!=INVALID_HANDLE)   IndicatorRelease(hEMA_H1_fast);
   if(hEMA_H1_slow!=INVALID_HANDLE)   IndicatorRelease(hEMA_H1_slow);
   if(hEMA_M15_pull!=INVALID_HANDLE)  IndicatorRelease(hEMA_M15_pull);
   if(hEMA_M15_struct!=INVALID_HANDLE)IndicatorRelease(hEMA_M15_struct);
   if(hRSI_M15!=INVALID_HANDLE)       IndicatorRelease(hRSI_M15);
   if(hMACD_M15!=INVALID_HANDLE)      IndicatorRelease(hMACD_M15);
   if(hATR_M15!=INVALID_HANDLE)       IndicatorRelease(hATR_M15);
   if(hFractals_M15!=INVALID_HANDLE)  IndicatorRelease(hFractals_M15);
   if(hADX!=INVALID_HANDLE)           IndicatorRelease(hADX);
}

void OnTradeTransaction(const MqlTradeTransaction& trans,const MqlTradeRequest& request,const MqlTradeResult& result){
   if(trans.type!=TRADE_TRANSACTION_DEAL_ADD) return;
   if(!HistoryDealSelect(trans.deal)) return;

   long  magic = (long)HistoryDealGetInteger(trans.deal, DEAL_MAGIC);
   if((ulong)magic != Magic) return;

   long  entryType = HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
   string sym      = HistoryDealGetString(trans.deal, DEAL_SYMBOL);
   double volume   = HistoryDealGetDouble(trans.deal, DEAL_VOLUME);
   ulong  ticket   = (ulong)HistoryDealGetInteger(trans.deal, DEAL_POSITION_ID);

   if(entryType == DEAL_ENTRY_IN){
      double sl = HistoryDealGetDouble(trans.deal, DEAL_SL);
      double price = HistoryDealGetDouble(trans.deal, DEAL_PRICE);
      double riskMoney = 0.0;
      if(sl>0 && volume>0){
         double tick_value = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE);
         double tick_size  = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
         double stop_price = MathAbs(price - sl);
         double ticks      = (tick_size>0? stop_price / tick_size : 0);
         double riskMoneyPerLot = ticks * tick_value;
         riskMoney = riskMoneyPerLot * volume;
      }
      if(riskMoney<=0){
         double stopPts = entryStopPoints;
         if(stopPts <= 0.0) stopPts = probeStopPts;
         if(stopPts <= 0.0){
            double atrLast=0.0;
            if(GetValue(hATR_M15,0,1,atrLast)) stopPts = MathMax(1.0, atrLast/_Point);
         }
         double tick_value = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE);
         double tick_size  = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
         if(stopPts>0.0 && tick_value>0.0 && tick_size>0.0 && volume>0.0){
            double perLot = (stopPts*_Point/MathMax(1e-10, tick_size)) * tick_value;
            riskMoney = perLot * MathMax(volume, SymbolInfoDouble(sym,SYMBOL_VOLUME_MIN));
         }
      }
      if(riskMoney>0) RiskMapPut(ticket, riskMoney);
      activeTradeRiskCash = riskMoney;
      activeTradeOneRCashPerLot = (volume>0.0 ? riskMoney/volume : 0.0);
      activeTradeInitialLots = volume;
      activeTradeRemainingLots = volume;
      activeTradePositionId = ticket;
      gLastTradeTime = TimeCurrent();

      TradesToday++;
      barsSinceEntry = 0;
      lastEntryStopPts = entryStopPoints;
      lastEntryBarTime = iTime(_Symbol,PERIOD_M15,0);
      probeBarsSinceEntry = 0;
      string dealComment = HistoryDealGetString(trans.deal, DEAL_COMMENT);
      bool commentQuota = (StringFind(dealComment, "Quota") >= 0);
      if(quotaPendingTicket>0 && trans.order == quotaPendingTicket){
         quotaTradeActive = true;
         quotaPendingTicket = 0;
      } else {
         quotaTradeActive = commentQuota;
      }
      return;
   }

   if(entryType != DEAL_ENTRY_OUT) return;

   RecordClosedTradeR(trans.deal);

   double profit = HistoryDealGetDouble(trans.deal, DEAL_PROFIT)
                 + HistoryDealGetDouble(trans.deal, DEAL_SWAP)
                 + HistoryDealGetDouble(trans.deal, DEAL_COMMISSION);
   long dealType = HistoryDealGetInteger(trans.deal, DEAL_TYPE);
   bool isBuy = (dealType==DEAL_TYPE_BUY);
   bool win = (profit > 0.0);
   UpdateSidePerformance(isBuy, win);

   double outcome = (profit>0.0 ? 1.0 : (profit<0.0 ? -1.0 : 0.0));
   recentWinsLosses[rwlIndex] = outcome;
   rwlIndex = (rwlIndex+1) % 32;
   rwlCount = (int)MathMin(rwlCount+1,32);
   if(profit < 0.0){
      dayLossCount++;
      if(quotaTradeActive) quotaLossCount++;
   } else if(profit > 0.0){
      dayLossCount = 0;
   }

   double riskMoney = RiskMapGet(ticket);
   if(riskMoney<=0){
      double fallback = AccountInfoDouble(ACCOUNT_BALANCE) * (Risk_Percent/100.0);
      riskMoney = MathMax(0.01, fallback);
   }
   double r = (riskMoney>0.0 ? profit / riskMoney : 0.0);
   if(MathIsValidNumber(r)){
      gR_day  += r;
      gR_week += r;
   }

   bool positionGone = (!PositionSelect(sym) || (ulong)PositionGetInteger(POSITION_MAGIC)!=Magic);
   if(positionGone) RiskMapPop(ticket);

   if(profit < 0){
      consecutiveLosses++;
      if(LossStreak_Protection && consecutiveLosses >= Max_Loss_Streak){
         cooldownBarsRemaining = Loss_Cooldown_Bars;
         if(Enable_Diagnostics) Print("[Diag] Loss streak triggered cooldown bars=",cooldownBarsRemaining);
         consecutiveLosses = 0;
      }
   } else if(profit > 0){
      consecutiveLosses = 0;
   }

   quotaTradeActive = false;
   barsSinceEntry = 0;
   lastEntryStopPts = 0.0;
   probeBarsSinceEntry = 0;
   probeStopPts = 0.0;
   gLastTradeTime = TimeCurrent();
}

void OnTick(){
   ResetDailyCounters();
   ResetRiskWindowsIfNeeded();
   double eqNow = AccountInfoDouble(ACCOUNT_EQUITY);
   if(peak_equity <= 0.0) peak_equity = eqNow;
   if(eqNow > peak_equity) peak_equity = eqNow;
   // Reset weekly anchor on new week
   MqlDateTime _dt; TimeToStruct(TimeCurrent(), _dt);
   int _weekId = (int)(_dt.year*100 + (_dt.day_of_year/7));
   if(_weekId != lastWeekId) { lastWeekId = _weekId; weekStartEquity = AccountInfoDouble(ACCOUNT_EQUITY); }
   // manage open trade each tick
   ManagePartialAndTrail();

   // detect pending order filled (reset tracking variables)
   if(pendingTicket>0){
      if(PositionSelect(_Symbol) && (ulong)PositionGetInteger(POSITION_MAGIC)==Magic){
         // pending converted to position
         pendingTicket=0; pendingDirection=-1; entryTime=TimeCurrent(); entryATRPoints=0; // ATR set later when partial mgmt needs
      }
   }

   if(!NewM15Bar()) return; // only evaluate entries once per new M15 bar
   // cooldown tick-down on each new bar
   if(LossStreak_Protection && cooldownBarsRemaining>0) cooldownBarsRemaining--;
   barsProcessed++; bool verboseBar = (Enable_Diagnostics && Verbose_First_N && (barsProcessed <= (ulong)Verbose_Bars_Limit));
   if(Diagnostics) PrintStageInfo(LoosenStage());

   bool probeMode=false;
   if(!CapsAllowTrading(probeMode)){
      if(Enable_Diagnostics) Print("[Gate] Risk cap active: R_today=",DoubleToString(R_today,2)," R_week=",DoubleToString(R_week,2));
      if(Enable_Diagnostics && Diagnostics_Every_Bars>0 && (barsProcessed % (ulong)Diagnostics_Every_Bars)==0) DiagnosticsPrintSummary();
      return;
   }

   if(probeMode){
      TryEnter_WithProbe(true);
      if(Enable_Diagnostics && Diagnostics_Every_Bars>0 && (barsProcessed % (ulong)Diagnostics_Every_Bars)==0) DiagnosticsPrintSummary();
      return;
   }

   // New entry flow (lenient/quality presets)
   if(Use_New_Entry_Flow){
      TryEnter_WithProbe(false);
      // still run diagnostics summary cadence
      if(Enable_Diagnostics && Diagnostics_Every_Bars>0 && (barsProcessed % (ulong)Diagnostics_Every_Bars)==0) DiagnosticsPrintSummary();
      return; // skip legacy pipeline
   }

   if(!RiskBudgetOK() || !EquityFilterOK()){
      if(Enable_Diagnostics) Print("[Gate] budget/equity-gate (legacy)");
      return;
   }

   // session window
   if(!SessionAllowed()){ DiagnosticsCount("session"); if(verboseBar) Print("[Diag] Reject session window"); return; }

   // fetch price data
   MqlRates m15[3]; if(!GetRates(PERIOD_M15,3,m15)){ DiagnosticsCount("misc"); if(verboseBar) Print("[Diag] CopyRates fail"); return; }
   double emaPull_1, emaStruct_1, emaH1_fast_1, emaH1_slow_1;
   if(!GetValue(hEMA_M15_pull,0,1,emaPull_1) || !GetValue(hEMA_M15_struct,0,1,emaStruct_1) || !GetValue(hEMA_H1_fast,0,1,emaH1_fast_1) || !GetValue(hEMA_H1_slow,0,1,emaH1_slow_1)) { DiagnosticsCount("misc"); return; }

   // ATR for dynamic spread and volatility filters
   double atr_1; if(!GetValue(hATR_M15,0,1,atr_1)){ DiagnosticsCount("misc"); if(verboseBar) Print("[Diag] ATR fail"); return; }
   double atr_points = PointsFromPrice(atr_1);
   if(atr_points < Min_ATR_Filter){ DiagnosticsCount("atrQuiet"); if(verboseBar) Print("[Diag] Reject ATR quiet"); return; }

   // dynamic spread
   double preAtrPts = PointsFromPrice(atr_1); int dynCap = MaxSpreadPoints; if(Dynamic_Spread_Cap && preAtrPts>0) dynCap=(int)MathMin((double)MaxSpreadPoints, Spread_ATR_Fraction*preAtrPts);
   double curSpread = CurrentSpreadPoints(); if(curSpread > dynCap){ DiagnosticsCount(Dynamic_Spread_Cap?"dynSpread":"spread"); if(verboseBar) Print("[Diag] Reject spread cur=",curSpread," cap=",dynCap); return; }

   // loss streak cooldown gating
   if(LossStreak_Protection && cooldownBarsRemaining>0){ DiagnosticsCount("cooldown"); if(verboseBar) Print("[Diag] Cooldown active barsRemaining=",cooldownBarsRemaining); return; }

   // no new entry if position already open
   if(HasOpenPosition()){ DiagnosticsCount("position"); if(verboseBar) Print("[Diag] Reject existing position"); return; }

   int stageLegacy = LoosenStage();
   bool failSafeLegacy = (stageLegacy>0 && TradesToday < DailyMinTrades);
   bool allowLongSide = (AllowLongs && AllowLongsAuto);
   bool allowShortSide = (AllowShorts && AllowShortsAuto);

   // trend determination
   bool trendUp = (emaH1_fast_1 > emaH1_slow_1);
   bool trendDown = (emaH1_fast_1 < emaH1_slow_1);

   // momentum values
   double macd_curr, macd_prev, rsi_curr, rsi_prev;
   if(!GetValue(hMACD_M15,0,1,macd_curr) || !GetValue(hMACD_M15,0,2,macd_prev) || !GetValue(hRSI_M15,0,1,rsi_curr) || !GetValue(hRSI_M15,0,2,rsi_prev)) { DiagnosticsCount("momentum"); return; }
   bool macdCrossUp = (macd_prev<=0.0 && macd_curr>0.0);
   bool macdCrossDown = (macd_prev>=0.0 && macd_curr<0.0);
   bool rsiCrossUp = (rsi_prev<50.0 && rsi_curr>50.0);
   bool rsiCrossDown = (rsi_prev>50.0 && rsi_curr<50.0);

   // pullback depth
   double pullDepthLong = (emaPull_1 - m15[1].low);
   double pullDepthShort = (m15[1].high - emaPull_1);
   bool touchedPullLong = (m15[1].low <= emaPull_1) && (pullDepthLong >= Min_Pull_Depth_ATR * atr_1);
   bool touchedPullShort= (m15[1].high >= emaPull_1) && (pullDepthShort >= Min_Pull_Depth_ATR * atr_1);

   // structure with buffer
   bool aboveStruct = (m15[1].close > emaStruct_1 + Structure_Buffer_ATR * atr_1);
   bool belowStruct = (m15[1].close < emaStruct_1 - Structure_Buffer_ATR * atr_1);

   bool momentumLongOK = RequireBothMomentum ? (macdCrossUp && rsiCrossUp) : (macdCrossUp || rsiCrossUp);
   if(momentumLongOK && (rsi_curr < RSI_Min_Long || macd_curr < MACD_Min_Abs)) momentumLongOK=false;
   bool momentumShortOK = RequireBothMomentum ? (macdCrossDown && rsiCrossDown) : (macdCrossDown || rsiCrossDown);
   if(momentumShortOK && (rsi_curr > RSI_Max_Short || macd_curr > -MACD_Min_Abs)) momentumShortOK=false;

   // candle confirmation & extension
   double lastClose = m15[1].close;
   double emaPullDistPts = PointsFromPrice(MathAbs(lastClose - emaPull_1));
   double extensionATR = (atr_points>0? emaPullDistPts / atr_points : 0.0);
   bool bullCandle = m15[1].close > m15[1].open;
   bool bearCandle = m15[1].close < m15[1].open;

   // ADX and slope + structure space
   bool adxOK=true; double adxMain=0, diPlus=0, diMinus=0; if(Use_ADX_Filter){ int hADX_temp=iADX(_Symbol,PERIOD_H1,ADX_Period); if(GetValue(hADX_temp,2,1,adxMain)&&GetValue(hADX_temp,0,1,diPlus)&&GetValue(hADX_temp,1,1,diMinus)) adxOK=(adxMain>=Min_ADX); else adxOK=false; IndicatorRelease(hADX_temp);} 
   bool slopeOK=true; if(Use_EMA200_Slope){ double ema200Past; if(GetValue(hEMA_H1_slow,0,1+EMA200_Slope_Lookback,ema200Past)){ double slopePts=PointsFromPrice(emaH1_slow_1-ema200Past); if(MathAbs(slopePts)<Min_EMA200_Slope_Pts) slopeOK=false; if(trendUp && slopePts<0) trendUp=false; if(trendDown && slopePts>0) trendDown=false; } else slopeOK=false; }
   bool spaceOKLong=true, spaceOKShort=true; if(Use_Structure_Space){ double highest=m15[1].high, lowest=m15[1].low; for(int i=2;i<Space_Lookback_Bars+2 && i<300;i++){ double hh=iHigh(_Symbol,PERIOD_M15,i); if(hh>highest) highest=hh; double ll=iLow(_Symbol,PERIOD_M15,i); if(ll<lowest) lowest=ll; } double headroomLong=highest-m15[1].close; double headroomShort=m15[1].close-lowest; double minSpace = MinSpace_ATR*atr_1; if(headroomLong<minSpace) spaceOKLong=false; if(headroomShort<minSpace) spaceOKShort=false; }

   int stopLevel=(int)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL); double minStopDistPts = MathMax(5.0,(double)stopLevel+5.0);

   // LONG ENTRY
   if(!allowLongSide){
      DiagnosticsCount("side");
      if(verboseBar) Print("[Diag] Long side guarded (auto=",AllowLongsAuto,")");
   } else if(trendUp && aboveStruct && touchedPullLong && momentumLongOK && bullCandle && extensionATR <= Max_Close_Extension_ATR){
      if(!adxOK){ DiagnosticsCount("momentum"); if(verboseBar) Print("[Diag] ADX fail long"); }
      else if(!slopeOK){ DiagnosticsCount("slope"); if(verboseBar) Print("[Diag] Slope fail long"); }
      else if(!spaceOKLong){ DiagnosticsCount("space"); if(verboseBar) Print("[Diag] Space fail long"); }
      else {
         double lastSwingLow = GetLastFractal(true,30,2);
         double bid,ask; SymbolInfoDouble(_Symbol,SYMBOL_BID,bid); SymbolInfoDouble(_Symbol,SYMBOL_ASK,ask);
         double baseSLpts = MathMax(ATR_SL_mult * atr_points, minStopDistPts);
         double swingSLprice=0.0; if(lastSwingLow>0){ double buffer=Swing_Buffer_ATR*atr_1; swingSLprice=lastSwingLow-buffer; }
         double defaultSLprice = ask - PriceFromPoints(baseSLpts);
         double chosenSLprice = (swingSLprice>0? MathMin(defaultSLprice,swingSLprice): defaultSLprice);
         double rawStopPts = PointsFromPrice(ask - chosenSLprice);
         double minStopPtsFloor = MathMax(minStopDistPts, MathMax(MinStop_Points, MinStop_ATR * (atr_points>0.0? atr_points : MinStop_Points)));
         double stopPts = MathMax(rawStopPts, minStopPtsFloor);
         double stopDistPrice = PriceFromPoints(stopPts);
         double lots = LotsByRiskSafe(stopPts);
         lots = ApplyFailSafeRisk(lots, failSafeLegacy);
         if(lots>0){
            NormalizeVolume(lots);
            entryTP2_R=TP2_R; entryTP3_R=TP3_R; if(Adaptive_R_Targets){ double atrArr[]; ArraySetAsSeries(atrArr,true); int need=MathMax(ATR_Regime_Period,10); if(CopyBuffer(hATR_M15,0,1,need,atrArr)==need){ double sum=0; for(int i=0;i<need;i++) sum+=atrArr[i]; double sma=sum/need; double ratio=(sma>0? atr_1/sma:1.0); if(ratio>HighVolRatio){ entryTP2_R+=HighVol_Target_Boost; entryTP3_R+=HighVol_Target_Boost;} else if(ratio<LowVolRatio){ entryTP2_R-=LowVol_Target_Reduction; entryTP3_R-=LowVol_Target_Reduction;} } if(entryTP2_R < TP1_R+0.1) entryTP2_R=TP1_R+0.1; if(entryTP3_R < entryTP2_R+0.2) entryTP3_R=entryTP2_R+0.2; }
            double finalR = (Use_TP3? entryTP3_R: entryTP2_R);
            double sl = NormalizePrice(ask - stopDistPrice);
            double tp = NormalizePrice(ask + PriceFromPoints(stopPts * finalR));
            if(Use_Stop_Confirmation){
               double pendingPrice=NormalizePrice(m15[1].high + PriceFromPoints(EntryBufferPts));
               NormalizeVolume(lots);
               if(PlacePendingOrMarket(true, lots, pendingPrice, sl, tp, "LongFB")){
                  pendingTicket=0;
                  pendingDirection=-1;
                  pendingExpiryBars=0;
                  signalHigh=m15[1].high;
                  signalLow=m15[1].low;
                  structureBreakOccurred=false;
                  beMoved=false;
                  partialTaken=false;
                  secondPartialTaken=false;
                  entryStopPoints=stopPts;
                  entryATRPoints=atr_points;
                  entryTime=TimeCurrent();
                  probeStopPts=0.0;
                  probeBarsSinceEntry=0;
                  return;
               }
            }
            else {
               trade.SetExpertMagicNumber(Magic);
               trade.SetDeviationInPoints(50);
               if(trade.Buy(lots,NULL,ask,sl,tp,"M15SwingLong")){
                  partialTaken=false;
                  secondPartialTaken=false;
                  entryTime=TimeCurrent();
                  entryStopPoints=stopPts;
                  entryATRPoints=atr_points;
                  signalHigh=m15[1].high;
                  signalLow=m15[1].low;
                  structureBreakOccurred=false;
                  beMoved=false;
                  return;
               }
            }
         }
      }
   } else {
      if(trendUp){ if(!aboveStruct) DiagnosticsCount("structure"); else if(!touchedPullLong) DiagnosticsCount("pullback"); else if(!momentumLongOK) DiagnosticsCount("momentum"); else if(!bullCandle) DiagnosticsCount("candle"); else if(extensionATR>Max_Close_Extension_ATR) DiagnosticsCount("extension"); else if(!spaceOKLong) DiagnosticsCount("space"); else if(!adxOK) DiagnosticsCount("momentum"); else if(!slopeOK) DiagnosticsCount("slope"); }
      else DiagnosticsCount("trend");
      if(verboseBar) Print("[Diag] Long reject tUp=",trendUp," above=",aboveStruct," pull=",touchedPullLong," mom=",momentumLongOK," bull=",bullCandle," ext=",DoubleToString(extensionATR,2));
   }

   // SHORT ENTRY
   if(!allowShortSide){
      DiagnosticsCount("side");
      if(verboseBar) Print("[Diag] Short side guarded (auto=",AllowShortsAuto,")");
   } else if(trendDown && belowStruct && touchedPullShort && momentumShortOK && bearCandle && extensionATR <= Max_Close_Extension_ATR){
      if(!adxOK){ DiagnosticsCount("momentum"); if(verboseBar) Print("[Diag] ADX fail short"); }
      else if(!slopeOK){ DiagnosticsCount("slope"); if(verboseBar) Print("[Diag] Slope fail short"); }
      else if(!spaceOKShort){ DiagnosticsCount("space"); if(verboseBar) Print("[Diag] Space fail short"); }
      else {
         double lastSwingHigh = GetLastFractal(false,30,2);
         double bid,ask; SymbolInfoDouble(_Symbol,SYMBOL_BID,bid); SymbolInfoDouble(_Symbol,SYMBOL_ASK,ask);
         double baseSLpts = MathMax(ATR_SL_mult * atr_points, minStopDistPts);
         double swingSLprice=0.0; if(lastSwingHigh>0){ double buffer=Swing_Buffer_ATR*atr_1; swingSLprice=lastSwingHigh+buffer; }
         double defaultSLprice = bid + PriceFromPoints(baseSLpts);
         double chosenSLprice = (swingSLprice>0? MathMax(defaultSLprice,swingSLprice): defaultSLprice);
         double rawStopPts = PointsFromPrice(chosenSLprice - bid);
         double minStopPtsFloor = MathMax(minStopDistPts, MathMax(MinStop_Points, MinStop_ATR * (atr_points>0.0? atr_points : MinStop_Points)));
         double stopPts = MathMax(rawStopPts, minStopPtsFloor);
         double stopDistPrice = PriceFromPoints(stopPts);
         double lots = LotsByRiskSafe(stopPts);
         lots = ApplyFailSafeRisk(lots, failSafeLegacy);
         if(lots>0){
            NormalizeVolume(lots);
            entryTP2_R=TP2_R; entryTP3_R=TP3_R; if(Adaptive_R_Targets){ double atrArr[]; ArraySetAsSeries(atrArr,true); int need=MathMax(ATR_Regime_Period,10); if(CopyBuffer(hATR_M15,0,1,need,atrArr)==need){ double sum=0; for(int i=0;i<need;i++) sum+=atrArr[i]; double sma=sum/need; double ratio=(sma>0? atr_1/sma:1.0); if(ratio>HighVolRatio){ entryTP2_R+=HighVol_Target_Boost; entryTP3_R+=HighVol_Target_Boost;} else if(ratio<LowVolRatio){ entryTP2_R-=LowVol_Target_Reduction; entryTP3_R-=LowVol_Target_Reduction;} } if(entryTP2_R < TP1_R+0.1) entryTP2_R=TP1_R+0.1; if(entryTP3_R < entryTP2_R+0.2) entryTP3_R=entryTP2_R+0.2; }
            double finalR = (Use_TP3? entryTP3_R: entryTP2_R);
            double sl = NormalizePrice(bid + stopDistPrice);
            double tp = NormalizePrice(bid - PriceFromPoints(stopPts * finalR));
            if(Use_Stop_Confirmation){
               double pendingPrice=NormalizePrice(m15[1].low - PriceFromPoints(EntryBufferPts));
               NormalizeVolume(lots);
               if(PlacePendingOrMarket(false, lots, pendingPrice, sl, tp, "ShortFB")){
                  pendingTicket=0;
                  pendingDirection=-1;
                  pendingExpiryBars=0;
                  signalHigh=m15[1].high;
                  signalLow=m15[1].low;
                  structureBreakOccurred=false;
                  beMoved=false;
                  partialTaken=false;
                  secondPartialTaken=false;
                  entryStopPoints=stopPts;
                  entryATRPoints=atr_points;
                  entryTime=TimeCurrent();
                  probeStopPts=0.0;
                  probeBarsSinceEntry=0;
                  return;
               }
            }
            else {
               trade.SetExpertMagicNumber(Magic);
               trade.SetDeviationInPoints(50);
               if(trade.Sell(lots,NULL,bid,sl,tp,"M15SwingShort")){
                  partialTaken=false;
                  secondPartialTaken=false;
                  entryTime=TimeCurrent();
                  entryStopPoints=stopPts;
                  entryATRPoints=atr_points;
                  signalHigh=m15[1].high;
                  signalLow=m15[1].low;
                  structureBreakOccurred=false;
                  beMoved=false;
                  return;
               }
            }
         }
      }
   } else {
      if(trendDown){ if(!belowStruct) DiagnosticsCount("structure"); else if(!touchedPullShort) DiagnosticsCount("pullback"); else if(!momentumShortOK) DiagnosticsCount("momentum"); else if(!bearCandle) DiagnosticsCount("candle"); else if(extensionATR>Max_Close_Extension_ATR) DiagnosticsCount("extension"); else if(!spaceOKShort) DiagnosticsCount("space"); else if(!adxOK) DiagnosticsCount("momentum"); else if(!slopeOK) DiagnosticsCount("slope"); }
      else DiagnosticsCount("trend");
      if(verboseBar) Print("[Diag] Short reject tDn=",trendDown," below=",belowStruct," pull=",touchedPullShort," mom=",momentumShortOK," bear=",bearCandle," ext=",DoubleToString(extensionATR,2));
   }

   if(TryProbeEntry()) return;

   // pending order expiry (evaluate once per bar)
   if(pendingTicket>0){
      if(pendingExpiryBars<=0){
         if(OrderSelect(pendingTicket)){
            if(OrderGetInteger(ORDER_STATE)==ORDER_STATE_PLACED){ MqlTradeRequest rr; MqlTradeResult rres; ZeroMemory(rr); ZeroMemory(rres); rr.action=TRADE_ACTION_REMOVE; rr.order=pendingTicket; bool orderSent = OrderSend(rr,rres); if(!orderSent){ Print("[Error] Failed to cancel pending order #",pendingTicket," Error:",GetLastError()); } }
         }
         if(verboseBar) Print("[Diag] Pending expired #",pendingTicket);
         pendingTicket=0; pendingDirection=-1;
      } else pendingExpiryBars--;
   }

   if(Enable_Diagnostics && Diagnostics_Every_Bars>0 && (barsProcessed % (ulong)Diagnostics_Every_Bars)==0) DiagnosticsPrintSummary();
}
