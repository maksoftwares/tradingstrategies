//+------------------------------------------------------------------+
//|          MST_YellowCross_Strategy_TSL_V3.mq5                     |
//|  Yellow SMA cross + HMA confirm; Breakeven + ATR + Fixed Trail   |
//|  Enhanced logging for Journal/Strategy Tester diagnostics        |
//+------------------------------------------------------------------+
#property version   "1.50"
#include <Trade/Trade.mqh>

//================== INPUTS ==================
//--- Signal
input int      FastEMA_Period       = 12;
input int      SlowEMA_Period       = 26;
input int      HullMA_Period        = 21;
input int      TrendMA_Period       = 50;
//--- ATR
input int      ATR_Period           = 14;
input double   SL_ATR_Mult          = 1.5;
input double   TP_RR                = 2.0;
//--- Exit line
input double   Exit_ATR_Mult        = 2.0;
input int      Exit_Smoothing_Per   = 5;
input bool     Use_ExitLine_Trail   = true;
input int      Trail_Min_Ticks      = 2;
//--- Breakeven
input bool     Use_Breakeven        = true;
input double   BE_Trigger_RR        = 1.0;
input int      BE_Offset_Points     = 0;
//--- ATR Trailing
input bool     Use_ATR_Trailing     = true;
input double   ATR_Trail_Mult       = 1.0;
input int      ATR_Trail_Step_Ticks = 2;
//--- Fixed Trailing
input bool     Use_Fixed_Trailing   = false;
input int      Fixed_Trail_Points   = 300;
//--- Filters
input bool     Use_ADX_Filter       = true;
input int      ADX_Period           = 14;
input double   Min_ADX_Main         = 20.0;
input double   Risk_Percent         = 1.0;
input bool     One_Position_Only    = true;
input int      Safety_Ticks_Backoff = 1;
input bool     Verbose_Logging      = true;   // Enable/disable detailed logs

//================== HANDLES ==================
int hFastEMA, hSlowEMA, hTrendMA, hATR, hWMA_half, hWMA_full, hADX;
CTrade trade;
datetime lastBarTime = 0;
int tradeCount = 0;

//================== HELPERS ==================
void LogMsg(string msg)
{
   if(Verbose_Logging)
      Print("[" + _Symbol + " " + StringFormat("%.0f", _Period/60) + "H " + TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS) + "] " + msg);
}

double AlignToTick(double price)
{
   double ts = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(ts <= 0.0) return price;
   return MathRound(price / ts) * ts;
}

bool NewBar()
{
   datetime t[];
   if(CopyTime(_Symbol, _Period, 0, 1, t) != 1) return false;
   if(t[0] != lastBarTime)
   {
      lastBarTime = t[0];
      return true;
   }
   return false;
}

bool Copy1(int h, int buf, int shift, double &val)
{
   double tmp[];
   if(CopyBuffer(h, buf, shift, 1, tmp) != 1) return false;
   val = tmp[0];
   return (val != EMPTY_VALUE);
}

bool GetHMA(int shift, double &hma)
{
   int n = MathMax(1, HullMA_Period);
   int sqrtLen = (int)MathMax(1, MathRound(MathSqrt((double)n)));
   double wsum = (double)sqrtLen * (sqrtLen + 1) / 2.0;
   double num = 0.0;
   
   for(int j = 0; j < sqrtLen; j++)
   {
      double a, b;
      if(!Copy1(hWMA_half, 0, shift + j, a)) return false;
      if(!Copy1(hWMA_full, 0, shift + j, b)) return false;
      num += (2.0 * a - b) * (sqrtLen - j);
   }
   hma = num / wsum;
   return true;
}

bool GetExitLine(int shift, double &out)
{
   int p = MathMax(1, Exit_Smoothing_Per);
   double sum = 0.0;
   
   for(int j = 0; j < p; j++)
   {
      double atrv, tr;
      if(!Copy1(hATR, 0, shift + j, atrv)) return false;
      if(!Copy1(hTrendMA, 0, shift + j, tr)) return false;
      
      double cl[];
      if(CopyClose(_Symbol, _Period, shift + j, 1, cl) != 1) return false;
      
      double raw = (cl[0] > tr) ? (cl[0] - Exit_ATR_Mult * atrv) : (cl[0] + Exit_ATR_Mult * atrv);
      sum += raw;
   }
   out = sum / p;
   return true;
}

bool PassedFilters(int shift)
{
   if(Use_ADX_Filter)
   {
      double adx;
      if(!Copy1(hADX, 0, shift, adx)) return false;
      if(adx < Min_ADX_Main)
      {
         LogMsg("FILTER REJECT: ADX=" + StringFormat("%.2f", adx) + " < Min_ADX_Main=" + StringFormat("%.2f", Min_ADX_Main));
         return false;
      }
      LogMsg("FILTER PASS: ADX=" + StringFormat("%.2f", adx));
   }
   return true;
}

double CalcLotsByRisk(double stopDist)
{
   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   double risk = bal * MathMax(0.0, Risk_Percent) / 100.0;
   double ts = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tv = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   
   if(ts <= 0.0 || tv <= 0.0 || stopDist <= 0.0)
   {
      LogMsg("LOT CALC ERROR: ts=" + StringFormat("%.8f", ts) + " tv=" + StringFormat("%.8f", tv) + " stopDist=" + StringFormat("%.5f", stopDist));
      return 0.0;
   }
   
   double ticks = stopDist / ts;
   double perLot = ticks * tv;
   if(perLot <= 0.0)
   {
      LogMsg("LOT CALC ERROR: perLot=" + StringFormat("%.5f", perLot));
      return 0.0;
   }
   
   double raw = risk / perLot;
   double vmin = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double vmax = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double vstep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(vstep <= 0.0) vstep = vmin;
   
   double lots = MathFloor(raw / vstep) * vstep;
   lots = MathMax(vmin, MathMin(vmax, lots));
   
   LogMsg("LOT CALC: raw=" + StringFormat("%.6f", raw) + " => lots=" + StringFormat("%.6f", lots) + 
          " (balance=" + StringFormat("%.2f", bal) + " risk=" + StringFormat("%.2f", risk) + ")");
   return lots;
}

bool AdjustStopsForBroker(int ptype, double &sl, double &tp)
{
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double ts = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   long stops = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   long freeze = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   
   if(stops == 0)
   {
      int spr = (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
      stops = MathMax(0, spr * 3);
      LogMsg("STOPS_LEVEL=0, using fallback: 3*spread=" + (string)stops);
   }
   
   double minDist = (double)MathMax(stops, freeze) * point;
   
   MqlTick tk;
   if(!SymbolInfoTick(_Symbol, tk)) return false;
   if(ts <= 0.0 || point <= 0.0) return false;
   
   double bid = tk.bid, ask = tk.ask;
   
   LogMsg("BROKER ADJUST: ptype=" + (string)ptype + " stops_level=" + (string)stops + " freeze=" + (string)freeze + 
          " minDist=" + StringFormat("%.5f", minDist) + " Bid=" + StringFormat("%.5f", bid) + " Ask=" + StringFormat("%.5f", ask));
   
   if(ptype == POSITION_TYPE_BUY)
   {
      if(sl > 0)
      {
         double maxSL = bid - minDist;
         double oldSL = sl;
         if(sl > maxSL) sl = maxSL;
         sl = AlignToTick(sl);
         if(bid - sl < minDist)
         {
            LogMsg("BROKER ADJUST REJECT BUY SL: " + StringFormat("%.5f", oldSL) + " -> " + StringFormat("%.5f", sl) + 
                   " (Bid-SL=" + StringFormat("%.5f", bid-sl) + " < minDist=" + StringFormat("%.5f", minDist) + ")");
            return false;
         }
         LogMsg("BROKER ADJUST BUY SL OK: " + StringFormat("%.5f", oldSL) + " -> " + StringFormat("%.5f", sl));
      }
      if(tp > 0)
      {
         double minTP = ask + minDist;
         double oldTP = tp;
         if(tp < minTP) tp = minTP;
         tp = AlignToTick(tp);
         if(tp - ask < minDist)
         {
            LogMsg("BROKER ADJUST REJECT BUY TP: " + StringFormat("%.5f", oldTP) + " -> " + StringFormat("%.5f", tp));
            return false;
         }
         LogMsg("BROKER ADJUST BUY TP OK: " + StringFormat("%.5f", oldTP) + " -> " + StringFormat("%.5f", tp));
      }
   }
   else if(ptype == POSITION_TYPE_SELL)
   {
      if(sl > 0)
      {
         double minSL = ask + minDist;
         double oldSL = sl;
         if(sl < minSL) sl = minSL;
         sl = AlignToTick(sl);
         if(sl - ask < minDist)
         {
            LogMsg("BROKER ADJUST REJECT SELL SL: " + StringFormat("%.5f", oldSL) + " -> " + StringFormat("%.5f", sl));
            return false;
         }
         LogMsg("BROKER ADJUST SELL SL OK: " + StringFormat("%.5f", oldSL) + " -> " + StringFormat("%.5f", sl));
      }
      if(tp > 0)
      {
         double maxTP = bid - minDist;
         double oldTP = tp;
         if(tp > maxTP) tp = maxTP;
         tp = AlignToTick(tp);
         if(bid - tp < minDist)
         {
            LogMsg("BROKER ADJUST REJECT SELL TP: " + StringFormat("%.5f", oldTP) + " -> " + StringFormat("%.5f", tp));
            return false;
         }
         LogMsg("BROKER ADJUST SELL TP OK: " + StringFormat("%.5f", oldTP) + " -> " + StringFormat("%.5f", tp));
      }
   }
   return true;
}

bool HasPosition(int &ptype)
{
   if(!PositionSelect(_Symbol)) return false;
   ptype = (int)PositionGetInteger(POSITION_TYPE);
   return true;
}

//================== TRAILING ==================
void ManageTrailing()
{
   if(!(Use_ExitLine_Trail || Use_Breakeven || Use_ATR_Trailing || Use_Fixed_Trailing))
      return;
   
   if(!PositionSelect(_Symbol)) return;
   
   int ptype = (int)PositionGetInteger(POSITION_TYPE);
   double openPx = PositionGetDouble(POSITION_PRICE_OPEN);
   double curSL = PositionGetDouble(POSITION_SL);
   double curTP = PositionGetDouble(POSITION_TP);
   double ts = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(ts <= 0.0) return;
   
   MqlTick tk;
   if(!SymbolInfoTick(_Symbol, tk)) return;
   
   // Profit buffer check
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int spr = (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   double need = spr * point * 1.0;
   
   if(ptype == POSITION_TYPE_BUY)
   {
      if((tk.bid - openPx) <= need)
      {
         LogMsg("TRAIL SKIP: BUY not enough profit yet (Bid-Entry=" + StringFormat("%.5f", tk.bid-openPx) + " <= need=" + StringFormat("%.5f", need) + ")");
         return;
      }
   }
   else if(ptype == POSITION_TYPE_SELL)
   {
      if((openPx - tk.ask) <= need)
      {
         LogMsg("TRAIL SKIP: SELL not enough profit yet (Entry-Ask=" + StringFormat("%.5f", openPx-tk.ask) + " <= need=" + StringFormat("%.5f", need) + ")");
         return;
      }
   }
   
   double candSL = (curSL > 0.0) ? curSL : 0.0;
   
   LogMsg("TRAIL START: ptype=" + (string)ptype + " Entry=" + StringFormat("%.5f", openPx) + " curSL=" + StringFormat("%.5f", curSL) + 
          " Bid=" + StringFormat("%.5f", tk.bid) + " Ask=" + StringFormat("%.5f", tk.ask));
   
   // 1) Breakeven
   if(Use_Breakeven)
   {
      double atr1;
      if(!Copy1(hATR, 0, 1, atr1)) atr1 = 0.0;
      
      double initStop = SL_ATR_Mult * atr1;
      double trigger = BE_Trigger_RR * initStop;
      
      if(ptype == POSITION_TYPE_BUY)
      {
         if(tk.bid >= (openPx + trigger))
         {
            double beSL = openPx + BE_Offset_Points * point;
            LogMsg("  BREAKEVEN BUY: Bid=" + StringFormat("%.5f", tk.bid) + " >= trigger=" + StringFormat("%.5f", openPx+trigger) + 
                   " => beSL=" + StringFormat("%.5f", beSL));
            candSL = MathMax(candSL, beSL);
         }
      }
      else if(ptype == POSITION_TYPE_SELL)
      {
         if(tk.ask <= (openPx - trigger))
         {
            double beSL = openPx - BE_Offset_Points * point;
            LogMsg("  BREAKEVEN SELL: Ask=" + StringFormat("%.5f", tk.ask) + " <= trigger=" + StringFormat("%.5f", openPx-trigger) + 
                   " => beSL=" + StringFormat("%.5f", beSL));
            if(candSL > 0.0)
               candSL = MathMin(candSL, beSL);
            else
               candSL = beSL;
         }
      }
   }
   
   // 2) ATR Trailing
   if(Use_ATR_Trailing)
   {
      double atrv;
      if(Copy1(hATR, 0, 0, atrv))
      {
         double dist = atrv * ATR_Trail_Mult;
         
         if(ptype == POSITION_TYPE_BUY)
         {
            double atrSL = AlignToTick(tk.bid - dist);
            double advance = atrSL - curSL;
            LogMsg("  ATR_TRAIL BUY: atrv=" + StringFormat("%.5f", atrv) + " dist=" + StringFormat("%.5f", dist) + 
                   " atrSL=" + StringFormat("%.5f", atrSL) + " advance=" + StringFormat("%.5f", advance) + 
                   " vs minStep=" + StringFormat("%.5f", MathMax(1, ATR_Trail_Step_Ticks)*ts));
            if(curSL <= 0.0 || advance >= MathMax(1, ATR_Trail_Step_Ticks) * ts)
               candSL = MathMax(candSL, atrSL);
            else
               LogMsg("    SKIP: advance too small");
         }
         else if(ptype == POSITION_TYPE_SELL)
         {
            double atrSL = AlignToTick(tk.ask + dist);
            double advance = curSL - atrSL;
            LogMsg("  ATR_TRAIL SELL: atrv=" + StringFormat("%.5f", atrv) + " dist=" + StringFormat("%.5f", dist) + 
                   " atrSL=" + StringFormat("%.5f", atrSL) + " advance=" + StringFormat("%.5f", advance));
            if(curSL <= 0.0 || advance >= MathMax(1, ATR_Trail_Step_Ticks) * ts)
            {
               if(candSL > 0.0)
                  candSL = MathMin(candSL, atrSL);
               else
                  candSL = atrSL;
            }
            else
               LogMsg("    SKIP: advance too small");
         }
      }
   }
   
   // 3) Fixed Points Trailing
   if(Use_Fixed_Trailing && Fixed_Trail_Points > 0)
   {
      if(ptype == POSITION_TYPE_BUY)
      {
         double fxSL = AlignToTick(tk.bid - Fixed_Trail_Points * point);
         LogMsg("  FIXED_TRAIL BUY: Fixed_Points=" + (string)Fixed_Trail_Points + " fxSL=" + StringFormat("%.5f", fxSL));
         if(curSL <= 0.0 || (fxSL - curSL) >= MathMax(1, Trail_Min_Ticks) * ts)
            candSL = MathMax(candSL, fxSL);
      }
      else if(ptype == POSITION_TYPE_SELL)
      {
         double fxSL = AlignToTick(tk.ask + Fixed_Trail_Points * point);
         LogMsg("  FIXED_TRAIL SELL: Fixed_Points=" + (string)Fixed_Trail_Points + " fxSL=" + StringFormat("%.5f", fxSL));
         if(curSL <= 0.0 || (curSL - fxSL) >= MathMax(1, Trail_Min_Ticks) * ts)
         {
            if(candSL > 0.0)
               candSL = MathMin(candSL, fxSL);
            else
               candSL = fxSL;
         }
      }
   }
   
   // 4) Exit Line Trailing
   if(Use_ExitLine_Trail)
   {
      double ex;
      if(GetExitLine(0, ex))
      {
         LogMsg("  EXIT_LINE_TRAIL: ex=" + StringFormat("%.5f", ex));
         if(ptype == POSITION_TYPE_BUY)
         {
            if(curSL <= 0.0 || (ex - curSL) >= MathMax(1, Trail_Min_Ticks) * ts)
               candSL = MathMax(candSL, ex);
         }
         else if(ptype == POSITION_TYPE_SELL)
         {
            if(curSL <= 0.0 || (curSL - ex) >= MathMax(1, Trail_Min_Ticks) * ts)
            {
               if(candSL > 0.0)
                  candSL = MathMin(candSL, ex);
               else
                  candSL = ex;
            }
         }
      }
   }
   
   // Check if we have a new candidate
   if(candSL <= 0.0)
   {
      LogMsg("TRAIL END: no valid candSL");
      return;
   }
   if(curSL > 0.0 && MathAbs(candSL - curSL) < MathMax(1, Trail_Min_Ticks) * ts)
   {
      LogMsg("TRAIL END: candSL=" + StringFormat("%.5f", candSL) + " diff from curSL too small");
      return;
   }
   
   LogMsg("TRAIL CANDIDATE: candSL=" + StringFormat("%.5f", candSL));
   
   // Safety backoff and broker adjust
   double adjSL = candSL, adjTP = curTP;
   double backoff = MathMax(0, Safety_Ticks_Backoff) * ts;
   
   if(ptype == POSITION_TYPE_BUY)
      adjSL = AlignToTick(adjSL - backoff);
   else if(ptype == POSITION_TYPE_SELL)
      adjSL = AlignToTick(adjSL + backoff);
   
   LogMsg("TRAIL BACKOFF: adjSL=" + StringFormat("%.5f", adjSL) + " (backoff=" + StringFormat("%.5f", backoff) + ")");
   
   if(!AdjustStopsForBroker(ptype, adjSL, adjTP))
   {
      LogMsg("TRAIL BROKER ADJUST FAILED");
      return;
   }
   
   if(curSL <= 0.0 || MathAbs(adjSL - curSL) >= MathMax(1, Trail_Min_Ticks) * ts)
   {
      LogMsg("TRAIL MODIFY: curSL=" + StringFormat("%.5f", curSL) + " -> adjSL=" + StringFormat("%.5f", adjSL));
      trade.PositionModify(_Symbol, adjSL, adjTP);
      LogMsg("TRAIL MODIFY SENT");
   }
}

//================== LIFECYCLE ==================
int OnInit()
{
   LogMsg("OnInit: Creating handles");
   
   hFastEMA = iMA(_Symbol, _Period, FastEMA_Period, 0, MODE_EMA, PRICE_CLOSE);
   hSlowEMA = iMA(_Symbol, _Period, SlowEMA_Period, 0, MODE_EMA, PRICE_CLOSE);
   hTrendMA = iMA(_Symbol, _Period, TrendMA_Period, 0, MODE_SMA, PRICE_CLOSE);
   hATR = iATR(_Symbol, _Period, ATR_Period);
   
   int halfLen = MathMax(1, HullMA_Period / 2);
   hWMA_half = iMA(_Symbol, _Period, halfLen, 0, MODE_LWMA, PRICE_CLOSE);
   hWMA_full = iMA(_Symbol, _Period, HullMA_Period, 0, MODE_LWMA, PRICE_CLOSE);
   
   if(Use_ADX_Filter)
      hADX = iADX(_Symbol, _Period, ADX_Period);
   
   if(hFastEMA == INVALID_HANDLE || hSlowEMA == INVALID_HANDLE || hTrendMA == INVALID_HANDLE ||
      hATR == INVALID_HANDLE || hWMA_half == INVALID_HANDLE || hWMA_full == INVALID_HANDLE ||
      (Use_ADX_Filter && hADX == INVALID_HANDLE))
   {
      LogMsg("ERROR: Handle creation failed");
      return INIT_FAILED;
   }
   
   LogMsg("OnInit: All handles created successfully");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   LogMsg("OnDeinit: Cleaning up handles (reason=" + (string)reason + ")");
   if(hFastEMA != INVALID_HANDLE) IndicatorRelease(hFastEMA);
   if(hSlowEMA != INVALID_HANDLE) IndicatorRelease(hSlowEMA);
   if(hTrendMA != INVALID_HANDLE) IndicatorRelease(hTrendMA);
   if(hATR != INVALID_HANDLE) IndicatorRelease(hATR);
   if(hWMA_half != INVALID_HANDLE) IndicatorRelease(hWMA_half);
   if(hWMA_full != INVALID_HANDLE) IndicatorRelease(hWMA_full);
   if(hADX != INVALID_HANDLE) IndicatorRelease(hADX);
}

void OnTick()
{
   bool isNew = NewBar();
   
   // Trailing on cadence
   if(isNew) ManageTrailing();
   
   if(!isNew) return;
   
   LogMsg("BAR_NEW: Processing new bar");
   
   // Entry logic
   double c[];
   if(CopyClose(_Symbol, _Period, 1, 2, c) != 2)
   {
      LogMsg("ERROR: CopyClose failed");
      return;
   }
   
   double tr1, tr2, h1, atr1;
   if(!Copy1(hTrendMA, 0, 1, tr1)) { LogMsg("ERROR: Copy1 hTrendMA shift 1"); return; }
   if(!Copy1(hTrendMA, 0, 2, tr2)) { LogMsg("ERROR: Copy1 hTrendMA shift 2"); return; }
   if(!GetHMA(1, h1)) { LogMsg("ERROR: GetHMA shift 1"); return; }
   if(!Copy1(hATR, 0, 1, atr1)) { LogMsg("ERROR: Copy1 hATR"); return; }
   
   LogMsg("SIGNAL DATA: c[0]=" + StringFormat("%.5f", c[0]) + " tr1=" + StringFormat("%.5f", tr1) + 
          " c[1]=" + StringFormat("%.5f", c[1]) + " tr2=" + StringFormat("%.5f", tr2) + 
          " h1=" + StringFormat("%.5f", h1) + " atr1=" + StringFormat("%.5f", atr1));
   
   bool crossUp = (c[1] < tr2) && (c[0] > tr1);
   bool crossDn = (c[1] > tr2) && (c[0] < tr1);
   bool buySignal = crossUp && (c[0] > h1);
   bool sellSignal = crossDn && (c[0] < h1);
   
   if(!(buySignal || sellSignal))
   {
      LogMsg("NO SIGNAL: crossUp=" + (string)crossUp + " crossDn=" + (string)crossDn + 
             " buySignal=" + (string)buySignal + " sellSignal=" + (string)sellSignal);
      return;
   }
   
   LogMsg("SIGNAL DETECTED: " + (buySignal ? "BUY" : "SELL"));
   
   if(!PassedFilters(1))
   {
      LogMsg("SIGNAL REJECTED: Filters failed");
      return;
   }
   
   int posType;
   bool hasPos = HasPosition(posType);
   
   if(One_Position_Only && hasPos)
   {
      LogMsg("EXISTING POSITION: type=" + (string)posType);
      if((buySignal && posType == POSITION_TYPE_SELL) || (sellSignal && posType == POSITION_TYPE_BUY))
      {
         LogMsg("CLOSING OPPOSITE POSITION");
         trade.PositionClose(_Symbol);
      }
      else
      {
         LogMsg("SIGNAL IGNORED: One_Position_Only and same side");
         return;
      }
   }
   
   MqlTick tk;
   if(!SymbolInfoTick(_Symbol, tk))
   {
      LogMsg("ERROR: SymbolInfoTick failed");
      return;
   }
   
   double entry = buySignal ? tk.ask : tk.bid;
   double stopD = SL_ATR_Mult * atr1;
   double sl = buySignal ? (entry - stopD) : (entry + stopD);
   double tp = 0.0;
   if(TP_RR > 0.0)
      tp = buySignal ? (entry + TP_RR * stopD) : (entry - TP_RR * stopD);
   
   LogMsg("ENTRY CALC: entry=" + StringFormat("%.5f", entry) + " stopD=" + StringFormat("%.5f", stopD) + 
          " sl=" + StringFormat("%.5f", sl) + " tp=" + StringFormat("%.5f", tp));
   
   double lots = CalcLotsByRisk(stopD);
   if(lots <= 0.0)
   {
      LogMsg("ERROR: Invalid lots calculated");
      return;
   }
   
   int ptype = buySignal ? POSITION_TYPE_BUY : POSITION_TYPE_SELL;
   double adjSL = sl, adjTP = tp;
   
   if(!AdjustStopsForBroker(ptype, adjSL, adjTP))
   {
      LogMsg("BROKER ADJUST FAILED: Using no SL/TP");
      adjSL = 0.0;
      adjTP = 0.0;
   }
   
   LogMsg("SENDING ORDER: " + (buySignal ? "BUY" : "SELL") + " lots=" + StringFormat("%.6f", lots) + 
          " adjSL=" + StringFormat("%.5f", adjSL) + " adjTP=" + StringFormat("%.5f", adjTP));
   
   if(buySignal)
   {
      trade.Buy(lots, _Symbol, 0.0, adjSL, adjTP);
      LogMsg("BUY ORDER SENT");
   }
   else if(sellSignal)
   {
      trade.Sell(lots, _Symbol, 0.0, adjSL, adjTP);
      LogMsg("SELL ORDER SENT");
   }
   
   tradeCount++;
   LogMsg("TRADE_COUNT: " + (string)tradeCount);
}

double OnTester()
{
   double profit = TesterStatistics(STAT_PROFIT);
   double maxDD = TesterStatistics(STAT_BALANCE_DD);
   double pf = TesterStatistics(STAT_PROFIT_FACTOR);
   double sharpe = TesterStatistics(STAT_SHARPE_RATIO);
   double trades = TesterStatistics(STAT_TRADES);
   
   LogMsg("ONTESTER: profit=" + StringFormat("%.2f", profit) + " maxDD=" + StringFormat("%.2f", maxDD) + 
          " pf=" + StringFormat("%.2f", pf) + " sharpe=" + StringFormat("%.2f", sharpe) + " trades=" + StringFormat("%.0f", trades));
   
   if(trades < 15) return -1.0;
   if(pf <= 1.05) return -1.0;
   
   double dd_pen = (maxDD <= 0.0) ? 1.0 : 1.0 / (1.0 + maxDD);
   double score = (profit * 0.004) * dd_pen + (MathMin(pf, 3.0) / 3.0 * 0.3) + (MathMin(sharpe, 3.0) / 3.0 * 0.3);
   
   LogMsg("ONTESTER SCORE: " + StringFormat("%.6f", score));
   return score;
}
//+------------------------------------------------------------------+
