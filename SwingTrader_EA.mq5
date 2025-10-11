//+------------------------------------------------------------------+
//|                 XAUUSD M15 Swing Pullback Strategy (EA)         |
//|                 Trend = H1 EMAs, Entry = M15 Pullback+Momentum  |
//|                 Partial TP & ATR SL/Trail                        |
//|                 © 2025 — for educational/backtest use            |
//+------------------------------------------------------------------+
#property copyright "2025"
#property version   "1.00"

#include <Trade/Trade.mqh>

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
input double   Risk_Percent    = 1.00;     // % of balance per trade
input double   MaxRiskLotsCap  = 0.10;     // hard cap per trade
input double   MinStop_ATR     = 1.0;      // ensure SL distance >= 1×ATR
input double   MinStop_Points  = 50.0;     // absolute floor in points
input int      ATR_Period      = 14;
input double   ATR_SL_mult     = 2.5;      // SL = max(ATR*mult, swing buffer)
input double   Swing_Buffer_ATR= 0.20;     // extra beyond fractal (as ATR multiple)
input double   TP1_R           = 1.05;     // first partial (tighter for faster risk reduction)
input double   TP2_R           = 1.9;      // second partial / scale-out point
input double   TP3_R           = 3.2;      // runner target
input bool     Use_TP3         = true;     // enable third target
input double   TP1_Close_Pct   = 0.45;     // portion to close at TP1
input double   TP2_Close_Pct   = 0.35;     // portion to close at TP2 (rest trails / TP3)
input bool     Adaptive_R_Targets = true;  // adjust TP2/TP3 with volatility regime
input int      ATR_Regime_Period  = 50;    // ATR SMA period for regime calc
input double   HighVolRatio       = 1.25;  // ATR / ATR_SMA > this => high vol (stretch targets)
input double   LowVolRatio        = 0.85;  // ATR / ATR_SMA < this => low vol (contract targets)
input double   HighVol_Target_Boost = 0.5; // add to TP2/TP3 R
input double   LowVol_Target_Reduction = 0.3; // subtract from TP2/TP3 R
input bool     Use_Trailing    = true;     // chandelier trail after BE
input double   Trail_ATR_mult  = 3.0;      // base trail
input double   Trail_Tight_ATR_mult = 2.4; // tighter trail beyond trigger R
input double   Trail_Tighten_Trigger_R = 2.3; // tighten trail after this R
input bool     Use_Time_Exit   = true;     // exit stale trades
input int      Max_Bars_In_Trade = 120;    // close if trade exceeds this many M15 bars (~30h)
input bool     Use_Vol_Compress_Exit = true; // exit if volatility collapses
input double   Vol_Compress_Ratio = 0.65;  // ATR(now)/ATR(entry) below => exit if not reached 0.5R

input group "=== Trade Hygiene ==="
input int      MaxSpreadPoints = 200;      // reject entries if spread too wide
input ulong    Magic           = 20251011; // EA magic

input group "=== Advanced Filters & Sessions ==="
input bool     RequireBothMomentum    = false;  // require both MACD & RSI (false = either)
input double   Min_ATR_Filter         = 5.0;    // Minimum ATR (points) to allow trades
input double   Max_Close_Extension_ATR= 0.9;    // Reject if close is > this * ATR above/below pullback EMA
input bool     Use_Session_Filter     = false;  // Restrict trading to session hours
input int      Session_Start_Hour     = 6;      // Session start (server time)
input int      Session_End_Hour       = 20;     // Session end
input bool     DelayTrailUntilPartial = true;   // Do not trail until partial profit
input double   Trail_Start_R          = 2.0;    // Start trailing only after this R reached if partial not yet
input group "=== Diagnostics ==="
input bool     Enable_Diagnostics     = true;   // Turn on rejection counting
input int      Diagnostics_Every_Bars = 96;     // Print summary every N processed M15 bars (~1 day if 96)
input bool     Verbose_First_N        = true;   // Print per-bar reasons early
input int      Verbose_Bars_Limit     = 20;     // Only first N bars verbose
input bool     Diagnostics            = true;   // Detailed per-attempt reason logging
input group "=== Trend & Strength Filters ==="
// Trend & Strength Filters
input bool     Use_ADX_Filter         = true;
input int      ADX_Period             = 14;
input double   Min_ADX                = 14.0;  // was 20 — keep light
input bool     Use_EMA200_Slope       = true;
input int      EMA200_Slope_Lookback  = 8;
input double   Min_EMA200_Slope_Pts   = 10.0;  // was 15.0
input int      SlopeLookback          = 8;       // permissive slope lookback (new flow)
input double   MinSlopePts            = 8;       // permissive minimum slope points (new flow)

input group "=== Momentum Quality Thresholds ==="
input double   RSI_Min_Long           = 50.5;   // require RSI above this for longs
input double   RSI_Max_Short          = 49.5;   // require RSI below this for shorts
input double   MACD_Min_Abs           = 0.04;   // min absolute MACD main beyond zero

input group "=== Pullback / Structure Quality ==="
input double   Min_Pull_Depth_ATR     = 0.10;   // minimum pullback depth as ATR fraction
input double   Structure_Buffer_ATR   = 0.03;   // close must clear structure EMA by this ATR
input bool     Use_Structure_Space    = true;   // Minimum space filter to next structure
input double   MinSpace_ATR           = 0.30;    // minimum ATR headroom
input int      Space_Lookback_Bars    = 60;     // lookback bars to compute highest/lowest structure
input int      SR_Lookback            = 20;     // swing high/low lookback for new flow

input group "=== Confirmation Entry (Stop Orders) ==="
input bool     Use_Stop_Confirmation  = false;   // Use pending stop orders for confirmation
input int      EntryBufferPts         = 12;     // buffer (points) beyond signal candle extreme
input int      PendingOrder_Expiry_Bars = 10;    // cancel pending after N bars
input bool     UseStopOrders          = false;  // New flow toggle (market vs stop)
input double   EntryBufferPts_New     = 15;     // New flow entry buffer

input group "=== Break-Even Logic ==="
input bool     MoveBE_On_StructureBreak = true; // Move to BE only after structure break
input double   BE_Fallback_R          = 1.10;   // fallback R to force BE if no break
input int      Break_Buffer_Points    = 10;     // extra points above/below signal high/low to count break

input group "=== Dynamic Spread & Sessions ==="
input bool     Dynamic_Spread_Cap     = true;   // dynamic spread cap using ATR
input double   Spread_ATR_Fraction    = 0.30;   // allowed spread = % of ATR (points) - LENIENT
input int      HardSpreadCapPts       = 600;    // absolute safety ceiling
input bool     Stage2_IgnoresSpread   = false;  // bypass spread check at stage 2 when no trades yet
input bool     Enhanced_Session_Filter= true;   // refined session rules (DISABLED for 24h trading)
input int      LondonNY_Start_Hour    = 5;      // Session start (0=all day)
input int      LondonNY_End_Hour      = 22;     // Session end (24=all day)
input bool     Skip_Monday_Asian      = true;   // DISABLED for more opportunities
input int      Monday_Skip_Until_Hour = 3;
input bool     Skip_Friday_Late       = true;   // DISABLED for more opportunities
input int      Friday_Cutoff_Hour     = 19;
input bool     Stage2_OverrideSession = true;   // Allow entries at stage 2 regardless of session

input group "=== Loss Streak & Side Control ==="
input bool     LossStreak_Protection  = true;   // pause after loss streak
input int      Max_Loss_Streak        = 3;
input int      Loss_Cooldown_Bars     = 2;      // reduced to 2 for maximum opportunity frequency
input int      MinBarsForSignals      = 50;    // minimum bars required before allowing signals
// (Adjusted later: default will be reduced to 3 in adaptive frequency changes)
input bool     AllowLongs             = true;   // enable/disable long side
input bool     AllowShorts            = true;   // enable/disable short side
input bool     Use_New_Entry_Flow     = true;   // Activate simplified lenient/quality TryEnter() flow
input int      CI_Max                 = 60;     // Placeholder compression index max (not yet implemented)
input int      MaxSpreadPoints_New    = 200;    // New flow max spread hard cap
input double   MaxSpread_ATR_Frac     = 0.30;   // New flow dynamic spread fraction

input bool   Cooldown_Stage0_Only = true;     // apply cooldown only at stage 0
input bool   Quota_Stage_Acceleration = true; // auto-escalate loosen stage if no trade yet
input int    Quota_Kick_Hour        = 10;     // escalate from this hour (server)
input int    Quota_End_Hour         = 19;     // keep escalated looseness until here

input group "=== Adaptive Frequency Layer ==="
input bool   AdaptiveLoosen     = true;  // enable dynamic threshold loosening intraday
input int    DailyMinTrades     = 1;     // target minimum trades per day
input int    LoosenHour1        = 12;    // first relax hour (server time)
input int    LoosenHour2        = 16;    // second relax hour
input int    ADX_Min_L0         = 20;    // base strict
input int    ADX_Min_L1         = 18;    // first relax
input int    ADX_Min_L2         = 14;    // second relax
input double CI_Max_L0          = 50.0;  // compression index max stage 0
input double CI_Max_L1          = 60.0;  // compression index max stage 1
input double CI_Max_L2          = 70.0;  // compression index max stage 2
input double MinSpace_ATR_L0    = 0.60;   // structure space stage 0
input double MinSpace_ATR_L1    = 0.30;   // structure space stage 1
input double MinSpace_ATR_L2    = 0.15;   // structure space stage 2
input int    RSI_Mid_L2         = 49;    // slightly easier RSI midline at stage 2

input group "=== Daily Trade Quota ==="
input bool     Enable_Daily_Min_Trade   = true;   // master toggle
input int      Quota_Trigger_Hour       = 13;     // start trying from this hour
input int      Quota_Final_Hour         = 18;     // last hour to try
input bool     Quota_Use_Market         = true;   // use market if body is strong; else stop
input int      Quota_EntryBufferPts     = 8;      // stop buffer if not market
input double   Quota_Risk_Factor        = 0.75;   // fraction of normal risk for quota trades
input double   Quota_Min_ATR_Points     = 400.0;  // min ATR(points) to avoid dead markets
input double   Quota_MaxSpread_ATR_Frac = 0.40;   // spread must be <= this * ATR(points)

input group "=== Compression Gate ==="
input double CI_Min_L0 = 0.80;  // Stage0: require at least mild compression
input double CI_Min_L1 = 0.60;  // Stage1: easier
input double CI_Min_L2 = 0.00;  // Stage2: disable CI gate


input group "=== Fail-Safe Daily Trade ==="
input double FailSafe_RiskMult  = 0.20;  // risk multiplier on loosened/day-save entries
input int    DC_Period          = 24;    // lookback bars for daily bracket high/low
input double DC_BufferPts       = 14;    // buffer points beyond channel extremes
input bool   Bracket_UseStops   = true;  // submit fail-safe entries as stop orders

input bool   EnableAltSignal        = true;
input bool   Alt_UseStopOrders      = true;
input double Stage2_MinSpace_ATR    = 0.10;
input bool   Stage2_IgnoreSlope     = true;
input bool   Stage2_IgnoreStructure = true;
input bool   Stage2_OptionalADX     = true;   // keep true; ADX optional in stage 2
input double Alt_EntryBufferPts     = 6;    // buffer for alt stop entries

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
datetime entryTime      = 0;        // entry time for time/vol exits
int      WinsLong30     = 0, TradesLong30 = 0, WinsShort30 = 0, TradesShort30 = 0;
bool     AllowLongsAuto = true, AllowShortsAuto = true;
int      longResults[30];
int      shortResults[30];
int      longRollingIdx  = 0, shortRollingIdx = 0;
int      longRollingCount= 0, shortRollingCount = 0;

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
double ComputeCompressionIndex(int lookback=20);
void PrintStageInfo(int stage);
bool LogAndReturnFalse(const string why);
bool SessionAllowed();
bool HasOpenPosition();

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
   
   // Lenient: take max of fixed and ATR-based, then clamp by hard ceiling
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

void ResetDailyCounters(){
   MqlDateTime dt;
   TimeCurrent(dt);
   int d = dt.day;
   if(LastTradeDate != d){
      TradesToday = 0;
      LastTradeDate = d;
   }
}

int LoosenStage(){
   if(!AdaptiveLoosen) return 0;
   // Base escalation with hours
   MqlDateTime dt; TimeCurrent(dt);
   int h = dt.hour;
   int stage = 0;
   if(h >= LoosenHour1) stage = 1;
   if(h >= LoosenHour2) stage = 2;
   // Quota-driven acceleration when we still need a trade
   if(Quota_Stage_Acceleration && TradesToday < DailyMinTrades && h >= Quota_Kick_Hour && h <= Quota_End_Hour)
      stage = 2;
   return stage;
}

bool EnforceDailyTradeQuota(){
   if(!Enable_Daily_Min_Trade) return false;
   // Only 1 quota attempt per day
   MqlDateTime dt; TimeCurrent(dt);
   if(dt.hour < Quota_Trigger_Hour || dt.hour > Quota_Final_Hour) return false;
   if(TradesToday >= DailyMinTrades) return false;
   if(HasOpenPosition()) return false;

   // Data ready
   MqlRates m15[3]; if(!GetRates(PERIOD_M15,3,m15)) return false;
   double atr=0.0; if(!GetValue(hATR_M15,0,1,atr)) return false;
   double atrPts = atr/_Point; if(atrPts < Quota_Min_ATR_Points) return false;

   // Spread gate (tighter than normal)
   double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK), bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   if(ask==0 || bid==0) return false;
   double spPts=(ask-bid)/_Point;
   if(spPts > Quota_MaxSpread_ATR_Frac * atrPts) return false;

   // Trend from H1 EMAs
   double emaFastH1=0, emaSlowH1=0;
   if(!GetValue(hEMA_H1_fast,0,1,emaFastH1) || !GetValue(hEMA_H1_slow,0,1,emaSlowH1)) return false;
   bool up = (emaFastH1 > emaSlowH1);
   bool dn = (emaFastH1 < emaSlowH1);
   if(!up && !dn) return false;

   int stopLevel = (int)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL);
   double useStopPts = MathMax((double)stopLevel+5.0, ATR_SL_mult * atrPts);
   double lots = LotsByRiskSafe(useStopPts) * Quota_Risk_Factor;
   if(lots <= 0.0) return false;

   double sl_buy  = NormalizePrice(ask - PriceFromPoints(useStopPts));
   double sl_sell = NormalizePrice(bid + PriceFromPoints(useStopPts));
   double tpR = TP2_R;
   double tp_buy  = NormalizePrice(ask + PriceFromPoints(useStopPts*tpR));
   double tp_sell = NormalizePrice(bid - PriceFromPoints(useStopPts*tpR));

   // Decide entry method
   double body = MathAbs(m15[1].close - m15[1].open);
   double range= (m15[1].high - m15[1].low);
   bool strongBody = (range>0 && body/range >= 0.40);

   trade.SetExpertMagicNumber(Magic);
   trade.SetDeviationInPoints(50);

   if(Quota_Use_Market && strongBody){
      if(up){
         if(trade.Buy(lots,NULL,ask,sl_buy,tp_buy)){ TradesToday++; return true; }
      } else if(dn){
         if(trade.Sell(lots,NULL,bid,sl_sell,tp_sell)){ TradesToday++; return true; }
      }
   } else {
      MqlTradeRequest rq; MqlTradeResult rs; ZeroMemory(rq); ZeroMemory(rs);
      rq.action=TRADE_ACTION_PENDING; rq.symbol=_Symbol; rq.volume=lots; rq.deviation=50; rq.magic=Magic; rq.type_filling=ORDER_FILLING_FOK;
      if(up){
         rq.type = ORDER_TYPE_BUY_STOP;
         rq.price = NormalizePrice(m15[1].high + PriceFromPoints(Quota_EntryBufferPts));
         rq.sl = sl_buy; rq.tp = tp_buy;
         if(PointsFromPrice(rq.price-ask) < stopLevel+10) rq.price = NormalizePrice(ask + PriceFromPoints(stopLevel+10));
         if(OrderSend(rq,rs)){ pendingTicket=rs.order; pendingExpiryBars=PendingOrder_Expiry_Bars; pendingDirection=1; signalHigh=m15[1].high; signalLow=m15[1].low; return true; }
      } else if(dn){
         rq.type = ORDER_TYPE_SELL_STOP;
         rq.price = NormalizePrice(m15[1].low - PriceFromPoints(Quota_EntryBufferPts));
         rq.sl = sl_sell; rq.tp = tp_sell;
         if(PointsFromPrice(bid - rq.price) < stopLevel+10) rq.price = NormalizePrice(bid - PriceFromPoints(stopLevel+10));
         if(OrderSend(rq,rs)){ pendingTicket=rs.order; pendingExpiryBars=PendingOrder_Expiry_Bars; pendingDirection=0; signalHigh=m15[1].high; signalLow=m15[1].low; return true; }
      }
   }
   return false;
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

bool TryEnter(){
   string why="";

   // --- MinBars Guard: Prevent early-begin history artifact ---
   if(Bars(_Symbol,PERIOD_M15) < MinBarsForSignals){ AppendReason(why,"minBars"); return LogAndReturnFalse(why); }

   // --- Data prerequisites ---
   MqlRates m15[3];
   if(!GetRates(PERIOD_M15,3,m15)) { AppendReason(why,"rates"); return LogAndReturnFalse(why); }
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
   if(LossStreak_Protection && cooldownBarsRemaining>0 && (!Cooldown_Stage0_Only || stage_for_cd==0)){
      AppendReason(why,"cooldown");
      return LogAndReturnFalse(why);
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
      return LogAndReturnFalse(why);
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
      double stopDistPrice=PriceFromPoints(stopPts);
      double lots=LotsByRiskSafe(stopPts);
      lots = ApplyFailSafeRisk(lots, failSafeActive);
      if(lots<=0){ AppendReason(why,"noLots"); return LogAndReturnFalse(why); }
      double sl=NormalizePrice(ask-stopDistPrice);
      double tpR=TP2_R;
      double tp=NormalizePrice(ask+PriceFromPoints(stopPts*tpR));
      if(UseStopOrders){
         double pendingPrice=NormalizePrice(m15[1].high + PriceFromPoints(EntryBufferPts_New));
         if(PointsFromPrice(pendingPrice-ask) < stopLevel+10) pendingPrice=NormalizePrice(ask+PriceFromPoints(stopLevel+10));
         MqlTradeRequest rq; MqlTradeResult rs; ZeroMemory(rq); ZeroMemory(rs);
         rq.action=TRADE_ACTION_PENDING; rq.type=ORDER_TYPE_BUY_STOP; rq.symbol=_Symbol; rq.volume=lots; rq.price=pendingPrice; rq.sl=sl; rq.tp=tp; rq.magic=Magic; rq.deviation=50; rq.type_filling=ORDER_FILLING_FOK;
         if(OrderSend(rq,rs)){
            pendingTicket=rs.order; pendingExpiryBars=PendingOrder_Expiry_Bars; pendingDirection=1; signalHigh=m15[1].high; signalLow=m15[1].low; entryStopPoints=stopPts; entryATRPoints=atrPts; entryTime=TimeCurrent(); structureBreakOccurred=false; beMoved=false; return true;
         } else AppendReason(why,"buyStopFail");
      } else {
         trade.SetExpertMagicNumber(Magic); trade.SetDeviationInPoints(50);
         if(trade.Buy(lots,NULL,ask,sl,tp,"NF_Long")){
            partialTaken=false; secondPartialTaken=false; entryTime=TimeCurrent(); entryStopPoints=stopPts; entryATRPoints=atrPts; signalHigh=m15[1].high; signalLow=m15[1].low; structureBreakOccurred=false; beMoved=false; TradesToday++; return true;
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
      double stopDistPrice=PriceFromPoints(stopPts);
      double lots=LotsByRiskSafe(stopPts);
      lots = ApplyFailSafeRisk(lots, failSafeActive);
      if(lots<=0){ AppendReason(why,"noLots"); return LogAndReturnFalse(why); }
      double sl=NormalizePrice(bid+stopDistPrice);
      double tpR=TP2_R; double tp=NormalizePrice(bid-PriceFromPoints(stopPts*tpR));
      if(UseStopOrders){
         double pendingPrice=NormalizePrice(m15[1].low - PriceFromPoints(EntryBufferPts_New));
         if(PointsFromPrice(bid - pendingPrice) < stopLevel+10) pendingPrice=NormalizePrice(bid-PriceFromPoints(stopLevel+10));
         MqlTradeRequest rq; MqlTradeResult rs; ZeroMemory(rq); ZeroMemory(rs);
         rq.action=TRADE_ACTION_PENDING; rq.type=ORDER_TYPE_SELL_STOP; rq.symbol=_Symbol; rq.volume=lots; rq.price=pendingPrice; rq.sl=sl; rq.tp=tp; rq.magic=Magic; rq.deviation=50; rq.type_filling=ORDER_FILLING_FOK;
         if(OrderSend(rq,rs)){
            pendingTicket=rs.order; pendingExpiryBars=PendingOrder_Expiry_Bars; pendingDirection=0; signalHigh=m15[1].high; signalLow=m15[1].low; entryStopPoints=stopPts; entryATRPoints=atrPts; entryTime=TimeCurrent(); structureBreakOccurred=false; beMoved=false; return true;
         } else AppendReason(why,"sellStopFail");
      } else {
         trade.SetExpertMagicNumber(Magic); trade.SetDeviationInPoints(50);
         if(trade.Sell(lots,NULL,bid,sl,tp,"NF_Short")){
            partialTaken=false; secondPartialTaken=false; entryTime=TimeCurrent(); entryStopPoints=stopPts; entryATRPoints=atrPts; signalHigh=m15[1].high; signalLow=m15[1].low; structureBreakOccurred=false; beMoved=false; TradesToday++; return true;
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
      
      // ADX optional at stage 2
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
                  rq.action=TRADE_ACTION_PENDING; rq.type=ORDER_TYPE_BUY_STOP; rq.symbol=_Symbol; rq.volume=lotsAlt; rq.price=NormalizePrice(channelHigh+buf); if(PointsFromPrice(rq.price-ask2)<stopLevel2+10) rq.price=NormalizePrice(ask2+PriceFromPoints(stopLevel2+10)); rq.sl=slLong; rq.tp=0; rq.deviation=50; rq.magic=Magic; rq.type_filling=ORDER_FILLING_FOK; if(OrderSend(rq,rs)){ pendingTicket=rs.order; pendingExpiryBars=PendingOrder_Expiry_Bars; pendingDirection=1; signalHigh=m15[1].high; signalLow=m15[1].low; }
               }
               if(altSell){
                  MqlTradeRequest rq; MqlTradeResult rs; ZeroMemory(rq); ZeroMemory(rs);
                  rq.action=TRADE_ACTION_PENDING; rq.type=ORDER_TYPE_SELL_STOP; rq.symbol=_Symbol; rq.volume=lotsAlt; rq.price=NormalizePrice(channelLow-buf); if(PointsFromPrice(bid2-rq.price)<stopLevel2+10) rq.price=NormalizePrice(bid2-PriceFromPoints(stopLevel2+10)); rq.sl=slShort; rq.tp=0; rq.deviation=50; rq.magic=Magic; rq.type_filling=ORDER_FILLING_FOK; if(OrderSend(rq,rs)){ pendingTicket=rs.order; pendingExpiryBars=PendingOrder_Expiry_Bars; pendingDirection=0; signalHigh=m15[1].high; signalLow=m15[1].low; }
               }
            } else {
               trade.SetExpertMagicNumber(Magic); trade.SetDeviationInPoints(50);
               if(altBuy){ if(trade.Buy(lotsAlt,NULL,ask2,slLong,0,"Alt_Long")){ TradesToday++; return true; } }
               if(altSell){ if(trade.Sell(lotsAlt,NULL,bid2,slShort,0,"Alt_Short")){ TradesToday++; return true; } }
            }
         }
      }
   }

   // If no normal entry, try quota trade once conditions are OK
   if(Enable_Daily_Min_Trade && TradesToday < DailyMinTrades){
      if(EnforceDailyTradeQuota()) return true;
   }

   // If we reach here, no entry was possible
   return LogAndReturnFalse(why);
}

// Helper function to log and return false
bool LogAndReturnFalse(const string why){
   if(Diagnostics && StringLen(why)>0)
      PrintFormat("NO-ENTRY %s %s: %s", _Symbol, TimeToString(TimeCurrent(), TIME_DATE|TIME_MINUTES), why);
   return false;
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
   double riskMoney = equity*(Risk_Percent/100.0);
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
   // Stage 2 override: allow entries late in day regardless of session
   int stage = LoosenStage();
   if(Stage2_OverrideSession && stage==2) return true;
   
   if(Enhanced_Session_Filter){
      MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
      if(Skip_Monday_Asian && dt.day_of_week==1 && dt.hour < Monday_Skip_Until_Hour) return false;
      if(Skip_Friday_Late && dt.day_of_week==5 && dt.hour >= Friday_Cutoff_Hour) return false;
      if(dt.hour < LondonNY_Start_Hour || dt.hour >= LondonNY_End_Hour) return false;
      return true;
   }
   if(!Use_Session_Filter) return true;
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   if(Session_Start_Hour <= Session_End_Hour)
      return (dt.hour >= Session_Start_Hour && dt.hour < Session_End_Hour);
   return (dt.hour >= Session_Start_Hour || dt.hour < Session_End_Hour);
}

void ManagePartialAndTrail(){
   if(!PositionSelect(_Symbol)) { partialTaken=false; secondPartialTaken=false; return; }
   if((ulong)PositionGetInteger(POSITION_MAGIC)!=Magic) return;

   long type  = (long)PositionGetInteger(POSITION_TYPE);
   double vol = PositionGetDouble(POSITION_VOLUME);
   double open= PositionGetDouble(POSITION_PRICE_OPEN);
   double sl  = PositionGetDouble(POSITION_SL);
   double tp  = PositionGetDouble(POSITION_TP);

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
      if(Use_Vol_Compress_Exit && entryATRPoints>0){
         double atrNow=0.0; if(GetValue(hATR_M15,0,1,atrNow)){
            double atrNowPts = PointsFromPrice(atrNow);
            if(atrNowPts / entryATRPoints < Vol_Compress_Ratio){
               // Evaluate progress R
               double bid2=0, ask2=0; SymbolInfoDouble(_Symbol,SYMBOL_BID,bid2); SymbolInfoDouble(_Symbol,SYMBOL_ASK,ask2);
               double curPrice = (type==POSITION_TYPE_BUY? bid2: ask2);
               double slNow = PositionGetDouble(POSITION_SL);
               double riskPts2 = PointsFromPrice(MathAbs(open - slNow));
               double gainPts2 = PointsFromPrice(MathAbs(curPrice - open));
               double progR = (riskPts2>0? gainPts2 / riskPts2 : 0);
               if(progR < 0.5){
                  trade.SetExpertMagicNumber(Magic);
                  trade.PositionClose(_Symbol);
                  return;
               }
            }
         }
      }
   }
}

int OnInit(){
   trade.SetExpertMagicNumber(Magic);
   ArrayInitialize(longResults,0);
   ArrayInitialize(shortResults,0);
   WinsLong30=WinsShort30=TradesLong30=TradesShort30=0;
   AllowLongsAuto=AllowShortsAuto=true;
   longRollingIdx=shortRollingIdx=0;
   longRollingCount=shortRollingCount=0;

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

   ulong dealId = trans.deal;
   if(!HistorySelect(TimeCurrent()-86400*30, TimeCurrent())) return; // last 30 days
   if(!HistoryDealSelect(dealId)) return;

   long magic = (long)HistoryDealGetInteger(dealId, DEAL_MAGIC);
   if((ulong)magic != Magic) return;

   long entryType = HistoryDealGetInteger(dealId, DEAL_ENTRY);
   double profit = HistoryDealGetDouble(dealId, DEAL_PROFIT) + HistoryDealGetDouble(dealId, DEAL_SWAP) + HistoryDealGetDouble(dealId, DEAL_COMMISSION);

   if(entryType == DEAL_ENTRY_IN){
      TradesToday++;
      return;
   }

   if(entryType != DEAL_ENTRY_OUT) return;

   long dealType = HistoryDealGetInteger(dealId, DEAL_TYPE);
   bool isBuy = (dealType==DEAL_TYPE_BUY);
   bool win = (profit > 0.0);
   UpdateSidePerformance(isBuy, win);

   if(!LossStreak_Protection) return;

   if(profit < 0){
      consecutiveLosses++;
      if(consecutiveLosses >= Max_Loss_Streak){
         cooldownBarsRemaining = Loss_Cooldown_Bars;
         if(Enable_Diagnostics) Print("[Diag] Loss streak triggered cooldown bars=",cooldownBarsRemaining);
         consecutiveLosses = 0; // reset after triggering
      }
   } else if(profit > 0){
      consecutiveLosses = 0; // reset on win
   }
}

void OnTick(){
   ResetDailyCounters();
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
   barsProcessed++; bool verboseBar = (Enable_Diagnostics && Verbose_First_N && (barsProcessed <= (ulong)Verbose_Bars_Limit));
   if(Diagnostics) PrintStageInfo(LoosenStage());

   // New entry flow (lenient/quality presets)
   if(Use_New_Entry_Flow){
      TryEnter();
      // still run diagnostics summary cadence
      if(Enable_Diagnostics && Diagnostics_Every_Bars>0 && (barsProcessed % (ulong)Diagnostics_Every_Bars)==0) DiagnosticsPrintSummary();
      return; // skip legacy pipeline
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
   if(LossStreak_Protection && cooldownBarsRemaining>0){ DiagnosticsCount("cooldown"); if(verboseBar) Print("[Diag] Cooldown active barsRemaining=",cooldownBarsRemaining); cooldownBarsRemaining--; return; }
   if(cooldownBarsRemaining>0) cooldownBarsRemaining--; // passive decrement

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
            entryTP2_R=TP2_R; entryTP3_R=TP3_R; if(Adaptive_R_Targets){ double atrArr[]; ArraySetAsSeries(atrArr,true); int need=MathMax(ATR_Regime_Period,10); if(CopyBuffer(hATR_M15,0,1,need,atrArr)==need){ double sum=0; for(int i=0;i<need;i++) sum+=atrArr[i]; double sma=sum/need; double ratio=(sma>0? atr_1/sma:1.0); if(ratio>HighVolRatio){ entryTP2_R+=HighVol_Target_Boost; entryTP3_R+=HighVol_Target_Boost;} else if(ratio<LowVolRatio){ entryTP2_R-=LowVol_Target_Reduction; entryTP3_R-=LowVol_Target_Reduction;} } if(entryTP2_R < TP1_R+0.1) entryTP2_R=TP1_R+0.1; if(entryTP3_R < entryTP2_R+0.2) entryTP3_R=entryTP2_R+0.2; }
            double finalR = (Use_TP3? entryTP3_R: entryTP2_R);
            double sl = NormalizePrice(ask - stopDistPrice);
            double tp = NormalizePrice(ask + PriceFromPoints(stopPts * finalR));
            if(Use_Stop_Confirmation){ double pendingPrice=NormalizePrice(m15[1].high + PriceFromPoints(EntryBufferPts)); MqlTradeRequest rq; MqlTradeResult rs; ZeroMemory(rq); ZeroMemory(rs); rq.action=TRADE_ACTION_PENDING; rq.type=ORDER_TYPE_BUY_STOP; rq.symbol=_Symbol; rq.volume=lots; rq.price=pendingPrice; rq.sl=sl; rq.tp=tp; rq.deviation=50; rq.magic=Magic; rq.type_filling=ORDER_FILLING_FOK; if(OrderSend(rq,rs)){ pendingTicket=rs.order; pendingExpiryBars=PendingOrder_Expiry_Bars; pendingDirection=1; signalHigh=m15[1].high; signalLow=m15[1].low; structureBreakOccurred=false; beMoved=false; if(verboseBar) Print("[Diag] Placed BuyStop #",pendingTicket," @",pendingPrice); } }
            else { trade.SetExpertMagicNumber(Magic); trade.SetDeviationInPoints(50); if(trade.Buy(lots,NULL,ask,sl,tp,"M15SwingLong")){ partialTaken=false; secondPartialTaken=false; entryTime=TimeCurrent(); entryStopPoints=stopPts; entryATRPoints=atr_points; signalHigh=m15[1].high; signalLow=m15[1].low; structureBreakOccurred=false; beMoved=false; } }
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
            entryTP2_R=TP2_R; entryTP3_R=TP3_R; if(Adaptive_R_Targets){ double atrArr[]; ArraySetAsSeries(atrArr,true); int need=MathMax(ATR_Regime_Period,10); if(CopyBuffer(hATR_M15,0,1,need,atrArr)==need){ double sum=0; for(int i=0;i<need;i++) sum+=atrArr[i]; double sma=sum/need; double ratio=(sma>0? atr_1/sma:1.0); if(ratio>HighVolRatio){ entryTP2_R+=HighVol_Target_Boost; entryTP3_R+=HighVol_Target_Boost;} else if(ratio<LowVolRatio){ entryTP2_R-=LowVol_Target_Reduction; entryTP3_R-=LowVol_Target_Reduction;} } if(entryTP2_R < TP1_R+0.1) entryTP2_R=TP1_R+0.1; if(entryTP3_R < entryTP2_R+0.2) entryTP3_R=entryTP2_R+0.2; }
            double finalR = (Use_TP3? entryTP3_R: entryTP2_R);
            double sl = NormalizePrice(bid + stopDistPrice);
            double tp = NormalizePrice(bid - PriceFromPoints(stopPts * finalR));
            if(Use_Stop_Confirmation){ double pendingPrice=NormalizePrice(m15[1].low - PriceFromPoints(EntryBufferPts)); MqlTradeRequest rq; MqlTradeResult rs; ZeroMemory(rq); ZeroMemory(rs); rq.action=TRADE_ACTION_PENDING; rq.type=ORDER_TYPE_SELL_STOP; rq.symbol=_Symbol; rq.volume=lots; rq.price=pendingPrice; rq.sl=sl; rq.tp=tp; rq.deviation=50; rq.magic=Magic; rq.type_filling=ORDER_FILLING_FOK; if(OrderSend(rq,rs)){ pendingTicket=rs.order; pendingExpiryBars=PendingOrder_Expiry_Bars; pendingDirection=0; signalHigh=m15[1].high; signalLow=m15[1].low; structureBreakOccurred=false; beMoved=false; if(verboseBar) Print("[Diag] Placed SellStop #",pendingTicket," @",pendingPrice); } }
            else { trade.SetExpertMagicNumber(Magic); trade.SetDeviationInPoints(50); if(trade.Sell(lots,NULL,bid,sl,tp,"M15SwingShort")){ partialTaken=false; secondPartialTaken=false; entryTime=TimeCurrent(); entryStopPoints=stopPts; entryATRPoints=atr_points; signalHigh=m15[1].high; signalLow=m15[1].low; structureBreakOccurred=false; beMoved=false; } }
         }
      }
   } else {
      if(trendDown){ if(!belowStruct) DiagnosticsCount("structure"); else if(!touchedPullShort) DiagnosticsCount("pullback"); else if(!momentumShortOK) DiagnosticsCount("momentum"); else if(!bearCandle) DiagnosticsCount("candle"); else if(extensionATR>Max_Close_Extension_ATR) DiagnosticsCount("extension"); else if(!spaceOKShort) DiagnosticsCount("space"); else if(!adxOK) DiagnosticsCount("momentum"); else if(!slopeOK) DiagnosticsCount("slope"); }
      else DiagnosticsCount("trend");
      if(verboseBar) Print("[Diag] Short reject tDn=",trendDown," below=",belowStruct," pull=",touchedPullShort," mom=",momentumShortOK," bear=",bearCandle," ext=",DoubleToString(extensionATR,2));
   }

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
