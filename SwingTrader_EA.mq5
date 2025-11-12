//+------------------------------------------------------------------+
//|                 XAUUSD M15 Swing Strategy (Simplified)           |
//|                 Momentum + Pullback with ATR management          |
//|                 Implements tuning_v5 objectives                  |
//+------------------------------------------------------------------+
#property copyright "2025"
#property version   "2.00"

#include <Trade/Trade.mqh>
#include <Trade/PositionInfo.mqh>

// --- Utility -------------------------------------------------------
inline bool IsFiniteD(const double x){ return (x==x) && (x < DBL_MAX) && (x > -DBL_MAX); }

// --- Inputs --------------------------------------------------------
input group "=== Build ==="
input string   BuildTag                  = "XAUUSD_M15_Swing_tuning_v5";

input group "=== Risk Settings ==="
input double   Risk_Percent              = 1.0;       // fixed percent risk per trade
input ulong    Magic                     = 20251011;   // expert magic number
input double   DayLossCap_R              = -3.0;       // stop trading for the day below this R
input double   WeekLossCap_R             = -12.0;      // stop trading for the week below this R

input group "=== Structure & Trend ==="
input int      EMA_Period_M15            = 50;
input int      EMA_Period_H1_Fast        = 50;
input int      EMA_Period_H1_Slow        = 200;
input int      Swing_HL_Lookback         = 5;          // bars for HH/LL confirmation

input group "=== Momentum Filters ==="
input int      RSI_Period                = 14;
input double   RSI_Long_Threshold        = 55.0;
input double   RSI_Short_Threshold       = 45.0;
input int      MACD_Fast_Normal          = 12;
input int      MACD_Slow_Normal          = 26;
input int      MACD_Fast_HiVol           = 8;
input int      MACD_Slow_HiVol           = 17;
input int      MACD_Signal               = 9;

input group "=== Volatility & Pullback ==="
input int      ATR_Period                = 14;
input int      ATR_Regime_Period         = 50;
input double   HighVolRatio              = 1.30;
input double   Pullback_Base_ATR_Frac    = 0.25;       // base ATR fraction for pullback depth

input group "=== Trade Management ==="
input double   Initial_SL_ATR            = 2.0;        // initial stop in ATR multiples
input double   Trail_ATR_Mult            = 2.0;        // trail multiplier once active
input double   Trail_Start_R             = 0.5;        // trail activation threshold
input double   BreakEven_Trigger_R       = 0.8;        // BE trigger in R
input double   BreakEven_Buffer_Pips     = 5.0;        // BE buffer beyond entry
input double   Partial_Close_Percent     = 50.0;       // partial close percent at 1R
input int      EarlyExit_Bars            = 5;          // early exit window
input double   EarlyExit_Loss_R          = -0.30;      // exit if loss worse than this within window
input int      Max_Bars_In_Trade         = 96;         // time exit safeguard

input group "=== Session Control ==="
input bool     Skip_Asia_Session         = true;       // avoid 23:00-07:00 GMT

input group "=== Diagnostics ==="
input bool     Print_Trade_Updates       = true;

// --- Trade / Risk structures --------------------------------------
struct TradeInfo
{
   bool     active;
   ulong    ticket;
   double   entryPrice;
   double   stopPrice;
   double   atrAtEntry;
   double   oneR_cash;
   double   totalLots;
   double   partialLots;
   bool     partialTaken;
   bool     beMoved;
   datetime entryTime;
   double   maxAdverseR;
};

struct RiskInfo
{
   double   dayR;
   double   weekR;
   double   expectancy;
   int      dayId;
   int      weekId;
   double   tradeHistory[30];
   int      tradeCount;
   int      tradeIndex;
   double   maeHistory[30];
   int      maeCount;
   int      maeIndex;
};

// --- Globals -------------------------------------------------------
CTrade         g_tradeExecutor;
CPositionInfo  g_position;

TradeInfo      g_trade = {false};
RiskInfo       g_risk  = {0};

int            hATR_Fast = INVALID_HANDLE;
int            hATR_Slow = INVALID_HANDLE;
int            hRSI      = INVALID_HANDLE;
int            hMACD_Normal = INVALID_HANDLE;
int            hMACD_Fast   = INVALID_HANDLE;
int            hEMA_M15  = INVALID_HANDLE;
int            hEMA_H1_Fast = INVALID_HANDLE;
int            hEMA_H1_Slow = INVALID_HANDLE;
int            hADX      = INVALID_HANDLE;

datetime       g_lastBarTime = 0;

// --- Helper prototypes ---------------------------------------------
void     DayWeekIds(const datetime t, int &d_out, int &w_out);
void     ResetRiskCounters();
double   OneRCashNow();
void     UpdateRiskStats(double r, double maeR);
void     UpdateExpectancy(double r);
void     UpdateMAEStats(double maeR);
bool     IsTradingSession();
bool     TryEnter();
bool     SetupEntry(const bool wantLong, const double atr, const double atrSlow, const double riskPercent);
void     ManageOpenPosition();
double   GetIndicatorValue(const int handle, const int buffer, const int shift);
int      SelectMACDHandle(const double atr, const double atrSlow);
bool     TrendBias(bool wantLong, const MqlRates &bar1, const double emaM15, const double emaH1Fast, const double emaH1Slow);
bool     PullbackOK(bool wantLong, const MqlRates &bar1, const double emaPull, const double atr, const double atrSlow);
bool     MomentumOK(bool wantLong, const double rsi, const double macdHist);
double   ComputeRiskLots(double stopPoints, double riskPercent, double &oneR_cash_out);
void     CancelGatePendings();

//+------------------------------------------------------------------+
//| Expert initialization                                            |
//+------------------------------------------------------------------+
int OnInit()
{
   Print("[Build] ", BuildTag);

   hATR_Fast    = iATR(_Symbol, PERIOD_M15, ATR_Period);
   hATR_Slow    = iATR(_Symbol, PERIOD_M15, ATR_Regime_Period);
   hRSI         = iRSI(_Symbol, PERIOD_M15, RSI_Period, PRICE_CLOSE);
   hMACD_Normal = iMACD(_Symbol, PERIOD_M15, MACD_Fast_Normal, MACD_Slow_Normal, MACD_Signal, PRICE_CLOSE);
   hMACD_Fast   = iMACD(_Symbol, PERIOD_M15, MACD_Fast_HiVol, MACD_Slow_HiVol, MACD_Signal, PRICE_CLOSE);
   hEMA_M15     = iMA(_Symbol, PERIOD_M15, EMA_Period_M15, 0, MODE_EMA, PRICE_CLOSE);
   hEMA_H1_Fast = iMA(_Symbol, PERIOD_H1, EMA_Period_H1_Fast, 0, MODE_EMA, PRICE_CLOSE);
   hEMA_H1_Slow = iMA(_Symbol, PERIOD_H1, EMA_Period_H1_Slow, 0, MODE_EMA, PRICE_CLOSE);
   hADX         = iADX(_Symbol, PERIOD_M15, 14);

   if(hATR_Fast==INVALID_HANDLE || hATR_Slow==INVALID_HANDLE ||
      hRSI==INVALID_HANDLE || hMACD_Normal==INVALID_HANDLE || hMACD_Fast==INVALID_HANDLE ||
      hEMA_M15==INVALID_HANDLE || hEMA_H1_Fast==INVALID_HANDLE || hEMA_H1_Slow==INVALID_HANDLE ||
      hADX==INVALID_HANDLE)
   {
      Print("[Error] Indicator handle creation failed");
      return INIT_FAILED;
   }

   g_tradeExecutor.SetExpertMagicNumber(Magic);
   g_tradeExecutor.SetDeviationInPoints(50);
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int)
{
   if(hATR_Fast!=INVALID_HANDLE) IndicatorRelease(hATR_Fast);
   if(hATR_Slow!=INVALID_HANDLE) IndicatorRelease(hATR_Slow);
   if(hRSI!=INVALID_HANDLE) IndicatorRelease(hRSI);
   if(hMACD_Normal!=INVALID_HANDLE) IndicatorRelease(hMACD_Normal);
   if(hMACD_Fast!=INVALID_HANDLE) IndicatorRelease(hMACD_Fast);
   if(hEMA_M15!=INVALID_HANDLE) IndicatorRelease(hEMA_M15);
   if(hEMA_H1_Fast!=INVALID_HANDLE) IndicatorRelease(hEMA_H1_Fast);
   if(hEMA_H1_Slow!=INVALID_HANDLE) IndicatorRelease(hEMA_H1_Slow);
   if(hADX!=INVALID_HANDLE) IndicatorRelease(hADX);
}

//+------------------------------------------------------------------+
void OnTick()
{
   ResetRiskCounters();

   ManageOpenPosition();

   datetime barTime = iTime(_Symbol, PERIOD_M15, 0);
   if(barTime == g_lastBarTime)
      return;
   g_lastBarTime = barTime;

   if(!IsTradingSession())
      return;

   if(g_position.Select(_Symbol) && g_position.Magic()==Magic)
      return; // already in position

   TryEnter();
}

//+------------------------------------------------------------------+
void ManageOpenPosition()
{
   if(!g_position.Select(_Symbol) || g_position.Magic()!=Magic)
   {
      if(g_trade.active)
      {
         g_trade.active = false;
         g_trade.maxAdverseR = 0.0;
      }
      return;
   }

   double price = (g_position.PositionType()==POSITION_TYPE_BUY ?
                   SymbolInfoDouble(_Symbol, SYMBOL_BID) :
                   SymbolInfoDouble(_Symbol, SYMBOL_ASK));
   double riskPts = MathAbs(g_position.PriceOpen() - g_position.SL()) / _Point;
   if(riskPts <= 0.0)
      return;
   double movePts = (g_position.PositionType()==POSITION_TYPE_BUY ?
                     (price - g_position.PriceOpen()) / _Point :
                     (g_position.PriceOpen() - price) / _Point);
   double rNow = (riskPts>0.0 ? movePts / riskPts : 0.0);

   if(g_trade.active)
   {
      if(rNow < g_trade.maxAdverseR)
         g_trade.maxAdverseR = rNow;
   }

   // Early exit check
   if(g_trade.active && EarlyExit_Bars>0)
   {
      int barsHeld = (int)((TimeCurrent() - g_trade.entryTime) / PeriodSeconds(PERIOD_M15));
      if(barsHeld <= EarlyExit_Bars && rNow <= EarlyExit_Loss_R)
      {
         if(Print_Trade_Updates) Print("[Exit] Early loss cut");
         g_tradeExecutor.PositionClose(_Symbol);
         return;
      }
   }

   // Time exit safeguard
   if(g_trade.active && Max_Bars_In_Trade>0)
   {
      int barsHeld = (int)((TimeCurrent() - g_trade.entryTime) / PeriodSeconds(PERIOD_M15));
      if(barsHeld >= Max_Bars_In_Trade)
      {
         if(Print_Trade_Updates) Print("[Exit] Max bars reached");
         g_tradeExecutor.PositionClose(_Symbol);
         return;
      }
   }

   // Partial close at 1R
   if(g_trade.active && !g_trade.partialTaken && rNow >= 1.0)
   {
      double lotsToClose = g_trade.partialLots;
      double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
      double stepLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
      if(stepLot>0.0 && lotsToClose>0.0)
         lotsToClose = MathFloor(lotsToClose/stepLot)*stepLot;
      if(lotsToClose >= minLot && lotsToClose > 0.0)
      {
         g_tradeExecutor.PositionClosePartial(_Symbol, lotsToClose);
         if(Print_Trade_Updates) Print("[Partial] Closed ", DoubleToString(lotsToClose,2));
      }
      g_trade.partialTaken = true;
   }

   // Break-even adjustment
   if(g_trade.active && !g_trade.beMoved && rNow >= BreakEven_Trigger_R)
   {
      double buffer = BreakEven_Buffer_Pips * _Point;
      int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
      double newSL = (g_position.PositionType()==POSITION_TYPE_BUY ? g_trade.entryPrice + buffer : g_trade.entryPrice - buffer);
      newSL = NormalizeDouble(newSL, digits);
      g_tradeExecutor.PositionModify(_Symbol, newSL, g_position.TP());
      g_trade.beMoved = true;
      if(Print_Trade_Updates) Print("[BE] Stop moved to protect costs");
   }

   // Trailing stop activation
   if(g_trade.active && rNow >= Trail_Start_R && Trail_ATR_Mult>0.0)
   {
      double atr = GetIndicatorValue(hATR_Fast,0,0);
      double atrSlow = GetIndicatorValue(hATR_Slow,0,0);
      if(atr>0.0)
      {
         double trailMult = Trail_ATR_Mult;
         if(atrSlow>0.0 && atr/atrSlow >= HighVolRatio)
            trailMult *= 0.8;
         double trail = trailMult * atr;
         int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
         double newSL = (g_position.PositionType()==POSITION_TYPE_BUY ? price - trail : price + trail);
         newSL = NormalizeDouble(newSL, digits);
         if(g_position.PositionType()==POSITION_TYPE_BUY && (g_position.SL()<=0.0 || newSL > g_position.SL()))
            g_tradeExecutor.PositionModify(_Symbol, newSL, g_position.TP());
         if(g_position.PositionType()==POSITION_TYPE_SELL && (g_position.SL()<=0.0 || newSL < g_position.SL()))
            g_tradeExecutor.PositionModify(_Symbol, newSL, g_position.TP());
      }
   }
}

//+------------------------------------------------------------------+
bool TryEnter()
{
   MqlRates m15[3];
   if(CopyRates(_Symbol, PERIOD_M15, 1, 3, m15) != 3)
      return false;

   if(g_risk.dayR <= DayLossCap_R)
   {
      if(Print_Trade_Updates) Print("[Gate] Day loss cap active");
      return false;
   }
   if(g_risk.weekR <= WeekLossCap_R)
   {
      if(Print_Trade_Updates) Print("[Gate] Week loss cap active");
      return false;
   }

   double atr = GetIndicatorValue(hATR_Fast,0,1);
   double atrSlow = GetIndicatorValue(hATR_Slow,0,1);
   if(atr <= 0.0 || atrSlow <= 0.0)
      return false;

   double emaM15 = GetIndicatorValue(hEMA_M15,0,1);
   double emaH1Fast = GetIndicatorValue(hEMA_H1_Fast,0,0);
   double emaH1Slow = GetIndicatorValue(hEMA_H1_Slow,0,0);

   int macdHandle = SelectMACDHandle(atr, atrSlow);
   double macdMain = GetIndicatorValue(macdHandle,0,1);
   double macdSignal = GetIndicatorValue(macdHandle,1,1);
   double macdHist = macdMain - macdSignal;
   double rsi = GetIndicatorValue(hRSI,0,1);

   double adx = GetIndicatorValue(hADX,0,1);
   double riskPct = Risk_Percent;
   if(adx>0.0 && adx < 20.0)
      riskPct *= 0.5; // weaker trend => size down
   if(g_risk.expectancy < 0.3 && g_risk.tradeCount >= 10)
      riskPct *= 0.5;
   riskPct = MathMax(0.1, riskPct);

   bool trendLong = TrendBias(true, m15[1], emaM15, emaH1Fast, emaH1Slow);
   bool trendShort = TrendBias(false, m15[1], emaM15, emaH1Fast, emaH1Slow);

   bool pullLong = PullbackOK(true, m15[1], emaM15, atr, atrSlow);
   bool pullShort = PullbackOK(false, m15[1], emaM15, atr, atrSlow);

   bool momLong = MomentumOK(true, rsi, macdHist);
   bool momShort = MomentumOK(false, rsi, macdHist);

   bool canLong = trendLong && pullLong && momLong;
   bool canShort = trendShort && pullShort && momShort;

   if(!canLong && !canShort)
      return false;

   CancelGatePendings();

   if(canLong)
   {
      if(SetupEntry(true, atr, atrSlow, riskPct))
         return true;
   }
   if(canShort)
   {
      if(SetupEntry(false, atr, atrSlow, riskPct))
         return true;
   }

   return false;
}

//+------------------------------------------------------------------+
bool SetupEntry(const bool wantLong, const double atr, const double atrSlow, const double riskPercent)
{
   double price = wantLong ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(price<=0.0) return false;

   double atrMultiplier = Initial_SL_ATR;
   double atrRatio = atrSlow>0.0 ? atr/atrSlow : 1.0;
   if(atrRatio >= HighVolRatio)
      atrMultiplier *= 0.8; // tighten by 20% in high vol

   // adjust by MAE average
   double maeAvg = 0.0;
   if(g_risk.maeCount>0)
   {
      double sum=0.0;
      for(int i=0;i<MathMin(g_risk.maeCount,30);++i)
         sum += g_risk.maeHistory[i];
      maeAvg = sum / g_risk.maeCount;
      if(maeAvg > 0.0)
         atrMultiplier *= MathMin(1.2, 1.0 + 0.2*(maeAvg - 0.5));
   }

   double stopDistance = atrMultiplier * atr;
   if(stopDistance <= 0.0)
      return false;

   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double stopPrice = wantLong ? price - stopDistance : price + stopDistance;
   stopPrice = NormalizeDouble(stopPrice, digits);
   double stopPoints = MathAbs(price - stopPrice) / _Point;
   double oneR_cash = 0.0;
   double lots = ComputeRiskLots(stopPoints, riskPercent, oneR_cash);
   if(lots <= 0.0)
      return false;

   g_tradeExecutor.SetExpertMagicNumber(Magic);
   bool ok = false;
   if(wantLong)
      ok = g_tradeExecutor.Buy(lots, NULL, 0.0, stopPrice, 0.0);
   else
      ok = g_tradeExecutor.Sell(lots, NULL, 0.0, stopPrice, 0.0);

   if(!ok)
      return false;

   g_trade.active = true;
   g_trade.ticket = 0;
   g_trade.entryPrice = price;
   g_trade.stopPrice = stopPrice;
   g_trade.atrAtEntry = atr;
   g_trade.oneR_cash = oneR_cash;
   g_trade.totalLots = lots;
   g_trade.partialLots = lots * (Partial_Close_Percent/100.0);
   g_trade.partialLots = MathMax(0.0, MathMin(g_trade.partialLots, g_trade.totalLots));
   g_trade.partialTaken = false;
   g_trade.beMoved = false;
   g_trade.entryTime = TimeCurrent();
   g_trade.maxAdverseR = 0.0;

   if(g_position.Select(_Symbol) && g_position.Magic()==Magic)
      g_trade.ticket = g_position.Ticket();

   if(Print_Trade_Updates)
      PrintFormat("[Entry] %s lots=%.2f SL=%.2f ATR=%.2f", wantLong?"BUY":"SELL", lots, stopPrice, atr);

   return true;
}

//+------------------------------------------------------------------+
bool MomentumOK(bool wantLong, const double rsi, const double macdHist)
{
   if(wantLong)
      return (rsi >= RSI_Long_Threshold || macdHist > 0.0);
   return (rsi <= RSI_Short_Threshold || macdHist < 0.0);
}

//+------------------------------------------------------------------+
bool TrendBias(bool wantLong, const MqlRates &bar1, const double emaM15, const double emaH1Fast, const double emaH1Slow)
{
   bool emaTrend = wantLong ? (bar1.close > emaM15 && emaH1Fast > emaH1Slow)
                            : (bar1.close < emaM15 && emaH1Fast < emaH1Slow);
   if(!emaTrend) return false;

   // Higher highs / lower lows confirmation
   int lookback = MathMax(2, Swing_HL_Lookback);
   int highIdx = iHighest(_Symbol, PERIOD_M15, MODE_HIGH, lookback, 1);
   int lowIdx  = iLowest (_Symbol, PERIOD_M15, MODE_LOW,  lookback, 1);
   if(highIdx < 0 || lowIdx < 0)
      return false;
   double high = iHigh(_Symbol, PERIOD_M15, highIdx);
   double low  = iLow (_Symbol, PERIOD_M15, lowIdx);
   if(wantLong)
      return bar1.high >= high && bar1.low >= low;
   return bar1.low <= low && bar1.high <= high;
}

//+------------------------------------------------------------------+
bool PullbackOK(bool wantLong, const MqlRates &bar1, const double emaPull, const double atr, const double atrSlow)
{
   double atrRatio = atrSlow>0.0 ? MathMin(2.0, atr/atrSlow) : 1.0;
   double depthReq = Pullback_Base_ATR_Frac * atr * atrRatio;
   double diff = wantLong ? (emaPull - bar1.low) : (bar1.high - emaPull);
   return diff >= depthReq;
}

//+------------------------------------------------------------------+
double ComputeRiskLots(double stopPoints, double riskPercent, double &oneR_cash_out)
{
   if(stopPoints <= 0.0)
      return 0.0;

   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickValue<=0.0 || tickSize<=0.0)
      return 0.0;

   double riskCash = AccountInfoDouble(ACCOUNT_BALANCE) * (riskPercent / 100.0);
   if(riskCash <= 0.0)
      return 0.0;

   double pointsValuePerLot = (tickValue / tickSize);
   double stopCashPerLot = stopPoints * pointsValuePerLot;
   if(stopCashPerLot <= 0.0)
      return 0.0;

   double lots = riskCash / stopCashPerLot;
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double stepLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(stepLot > 0.0)
      lots = MathFloor(lots / stepLot) * stepLot;
   lots = MathMax(minLot, MathMin(lots, maxLot));
   oneR_cash_out = lots * stopCashPerLot;
   return lots;
}

//+------------------------------------------------------------------+
int SelectMACDHandle(const double atr, const double atrSlow)
{
   if(atrSlow <= 0.0) return hMACD_Normal;
   double ratio = atr / atrSlow;
   if(ratio >= HighVolRatio)
      return hMACD_Fast;
   return hMACD_Normal;
}

//+------------------------------------------------------------------+
double GetIndicatorValue(const int handle, const int buffer, const int shift)
{
   if(handle==INVALID_HANDLE) return 0.0;
   double data[];
   if(CopyBuffer(handle, buffer, shift, 1, data) != 1)
      return 0.0;
   return data[0];
}

//+------------------------------------------------------------------+
void DayWeekIds(const datetime t, int &d_out, int &w_out)
{
   MqlDateTime dt; TimeToStruct(t, dt);
   d_out = dt.year*10000 + dt.mon*100 + dt.day;
   MqlDateTime jan1; jan1.year=dt.year; jan1.mon=1; jan1.day=1; jan1.hour=0; jan1.min=0; jan1.sec=0;
   int doy = (int)((t - StructToTime(jan1)) / 86400) + 1;
   int wnum = doy / 7;
   w_out = dt.year*100 + wnum;
}

//+------------------------------------------------------------------+
void ResetRiskCounters()
{
   int dId,wId; DayWeekIds(TimeCurrent(), dId, wId);
   if(g_risk.dayId != dId)
   {
      g_risk.dayId = dId;
      g_risk.dayR = 0.0;
   }
   if(g_risk.weekId != wId)
   {
      g_risk.weekId = wId;
      g_risk.weekR = 0.0;
   }
}

//+------------------------------------------------------------------+
double OneRCashNow()
{
   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   return bal * (Risk_Percent / 100.0);
}

//+------------------------------------------------------------------+
void UpdateExpectancy(double r)
{
   g_risk.tradeHistory[g_risk.tradeIndex % 30] = r;
   g_risk.tradeIndex++;
   if(g_risk.tradeCount < 30) g_risk.tradeCount++;

   double sum = 0.0;
   for(int i=0;i<g_risk.tradeCount;++i)
      sum += g_risk.tradeHistory[i];
   g_risk.expectancy = (g_risk.tradeCount>0 ? sum / g_risk.tradeCount : 0.0);
}

//+------------------------------------------------------------------+
void UpdateMAEStats(double maeR)
{
   double v = MathAbs(maeR);
   g_risk.maeHistory[g_risk.maeIndex % 30] = v;
   g_risk.maeIndex++;
   if(g_risk.maeCount < 30) g_risk.maeCount++;
}

//+------------------------------------------------------------------+
void UpdateRiskStats(double r, double maeR)
{
   if(!IsFiniteD(r))
      return;
   g_risk.dayR  += r;
   g_risk.weekR += r;
   UpdateExpectancy(r);
   if(maeR>0.0) UpdateMAEStats(maeR);
   if(Print_Trade_Updates)
      PrintFormat("[Perf] R_day=%.2f R_week=%.2f Expectancy=%.2f", g_risk.dayR, g_risk.weekR, g_risk.expectancy);
}

//+------------------------------------------------------------------+
bool IsTradingSession()
{
   if(!Skip_Asia_Session)
      return true;
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   int hour = dt.hour;
   if(hour >= 23 || hour < 7)
      return false;
   return true;
}

//+------------------------------------------------------------------+
void CancelGatePendings()
{
   for (int i = OrdersTotal() - 1; i >= 0; --i)
   {
      ulong ticket = OrderGetTicket(i);
      if (ticket == 0)               continue;
      if (!OrderSelect(ticket))      continue;

      if ((ulong)OrderGetInteger(ORDER_MAGIC) != Magic) continue;

      ENUM_ORDER_TYPE type  = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      bool isPending = (type == ORDER_TYPE_BUY_LIMIT  || type == ORDER_TYPE_SELL_LIMIT ||
                        type == ORDER_TYPE_BUY_STOP   || type == ORDER_TYPE_SELL_STOP);
      if (!isPending) continue;

      ENUM_ORDER_STATE state = (ENUM_ORDER_STATE)OrderGetInteger(ORDER_STATE);
      if (!(state == ORDER_STATE_PLACED || state == ORDER_STATE_STARTED)) continue;

      MqlTradeRequest req;  MqlTradeResult res;
      ZeroMemory(req); ZeroMemory(res);
      req.action = TRADE_ACTION_REMOVE;
      req.order  = ticket;

      if (!OrderSend(req, res))
      {
         PrintFormat("[CancelGatePendings] REMOVE failed ticket=%I64u err=%d",
                     ticket, GetLastError());
      }
   }
}

//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction& trans,const MqlTradeRequest& request,const MqlTradeResult& result)
{
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD)
      return;

   ulong deal = trans.deal;
   if(!HistoryDealSelect(deal))
      return;
   if((ulong)HistoryDealGetInteger(deal, DEAL_MAGIC) != Magic)
      return;
   if(HistoryDealGetInteger(deal, DEAL_ENTRY) != DEAL_ENTRY_OUT)
      return;

   double profit = HistoryDealGetDouble(deal, DEAL_PROFIT) +
                   HistoryDealGetDouble(deal, DEAL_SWAP) +
                   HistoryDealGetDouble(deal, DEAL_COMMISSION);
   double oneR = g_trade.oneR_cash;
   if(oneR <= 0.0)
      oneR = OneRCashNow();
   double r = (oneR>0.0 ? profit / oneR : 0.0);

   double maeR = MathAbs(g_trade.maxAdverseR);
   UpdateRiskStats(r, maeR);

   if(Print_Trade_Updates)
      PrintFormat("[CLOSE] profit=%.2f R=%.2f", profit, r);

   if(!g_position.Select(_Symbol) || g_position.Magic()!=Magic)
   {
      g_trade.active = false;
      g_trade.maxAdverseR = 0.0;
   }
}
