//+------------------------------------------------------------------+
//|                MST_YellowCross_Strategy.mq5                      |
//|  Backtestable EA: Yellow (Trend SMA) cross with HMA confirm      |
//|  Filters: ADX, ATR; SL/TP: ATR-based; Trailing: Exit Line        |
//+------------------------------------------------------------------+
#property version   "1.11"
#include <Trade/Trade.mqh>

//-------------------- Inputs (mirror indicator + trading) --------------------
input int      FastEMA_Period       = 12;
input int      SlowEMA_Period       = 26;
input int      HullMA_Period        = 21;         // HMA length (purple)
input int      TrendMA_Period       = 50;         // Yellow line (SMA)
input int      ATR_Period           = 14;         // ATR for SL/exit line
input double   Exit_ATR_Mult        = 2.0;        // exit line offset
input int      Exit_Smoothing_Per   = 5;          // exit smoothing (SMA)

// Filters
input bool     Use_ADX_Filter       = true;
input int      ADX_Period           = 14;
input double   Min_ADX_Main         = 20.0;
input bool     Use_ATR_Min_Filter   = false;
input double   Min_ATR_Points       = 0.0;        // absolute points (0=off)

// Trading
input double   Risk_Percent         = 1.0;        // % of balance risked
input double   SL_ATR_Mult          = 1.5;        // initial SL in ATR
input double   TP_RR                = 2.0;        // take-profit R multiple (0=off)
input bool     Use_ExitLine_Trail   = true;       // trail to exit line
input bool     Trail_On_New_Bar     = true;       // if false, trail on each tick
input int      Trail_Min_Ticks      = 2;          // require this advance to modify
input bool     One_Position_Only    = true;       // netting-like control
input int      Max_Spread_Points    = 0;          // 0 = ignore

//-------------------- Handles --------------------
int hFastEMA   = INVALID_HANDLE;
int hSlowEMA   = INVALID_HANDLE;
int hTrendMA   = INVALID_HANDLE;   // SMA(Trend)
int hATR       = INVALID_HANDLE;
int hWMA_half  = INVALID_HANDLE;   // LWMA(n/2) of close (for HMA)
int hWMA_full  = INVALID_HANDLE;   // LWMA(n)   of close
int hADX       = INVALID_HANDLE;

CTrade trade;

//-------------------- State --------------------
datetime lastBarTime = 0;

//-------------------- Helpers --------------------
double AlignToTick(double price)
{
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickSize<=0.0) return price;
   return MathRound(price / tickSize) * tickSize;
}

bool NewBar()
{
   datetime t[];
   if(CopyTime(_Symbol,_Period,0,1,t)!=1) return false;
   if(t[0]!=lastBarTime)
   {
      lastBarTime = t[0];
      return true;
   }
   return false;
}

bool Copy1(int handle,int buffer,int shift,double &val)
{
   double tmp[];
   if(CopyBuffer(handle,buffer,shift,1,tmp)!=1) return false;
   val = tmp[0];
   return (val!=EMPTY_VALUE);
}

// Hull MA using LWMA half/full handles, then LWMA of derived sequence over sqrt(n)
bool GetHMA(const int bars_shift,double &hma_val)
{
   int n = MathMax(1,HullMA_Period);
   int sqrtLen = (int)MathMax(1, MathRound(MathSqrt((double)n)));
   double wsum = (double)sqrtLen*(sqrtLen+1)/2.0;

   double num=0.0;
   for(int j=0;j<sqrtLen;j++)
   {
      double hHalf, hFull;
      if(!Copy1(hWMA_half,0,bars_shift+j,hHalf)) return false;
      if(!Copy1(hWMA_full,0,bars_shift+j,hFull)) return false;
      double htmp = 2.0*hHalf - hFull;
      num += htmp * (sqrtLen - j);
   }
   hma_val = num/wsum;
   return true;
}

// Exit line at bar: price>Trend? close-ATR*mult : close+ATR*mult, then SMA smoothing
bool GetExitLine(const int bar_shift,double &exit_val)
{
   int p = MathMax(1,Exit_Smoothing_Per);
   double sum=0.0; int cnt=0;
   for(int j=0;j<p;j++)
   {
       double atrv, tr;
       if(!Copy1(hATR,0,bar_shift+j,atrv)) return false;
       if(!Copy1(hTrendMA,0,bar_shift+j,tr)) return false;

       double cl[];
       if(CopyClose(_Symbol,_Period,bar_shift+j,1,cl)!=1) return false;

       double raw_j = (cl[0]>tr) ? (cl[0]-Exit_ATR_Mult*atrv) : (cl[0]+Exit_ATR_Mult*atrv);
       sum += raw_j; cnt++;
   }
   exit_val = sum/((double)cnt);
   return true;
}

bool PassedFilters(const int bar_shift)
{
   // ADX main filter
   if(Use_ADX_Filter)
   {
      double adx_main;
      if(!Copy1(hADX,0,bar_shift,adx_main)) return false;
      if(adx_main < Min_ADX_Main) return false;
   }
   // ATR minimum filter
   if(Use_ATR_Min_Filter && Min_ATR_Points>0.0)
   {
      double atrv;
      if(!Copy1(hATR,0,bar_shift,atrv)) return false;
      double point = SymbolInfoDouble(_Symbol,SYMBOL_POINT);
      if(point<=0.0) return false;
      if(atrv/point < Min_ATR_Points) return false;
   }
   // Spread filter (optional)
   if(Max_Spread_Points>0)
   {
      long spr = (long)SymbolInfoInteger(_Symbol,SYMBOL_SPREAD);
      if(spr > Max_Spread_Points) return false;
   }
   return true;
}

double CalcLotsByRisk(const double stop_price_distance)
{
   double balance   = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskMoney = balance * MathMax(0.0,Risk_Percent)/100.0;
   double tickSize  = SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE);
   if(tickSize<=0.0 || tickValue<=0.0 || stop_price_distance<=0.0) return 0.0;

   double stop_ticks  = stop_price_distance / tickSize;
   double riskPerLot  = stop_ticks * tickValue;
   if(riskPerLot<=0.0) return 0.0;

   double rawLots = riskMoney / riskPerLot;

   double vmin = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double vmax = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
   double vstep= SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   if(vstep<=0.0) vstep = vmin;
   double lots = MathFloor(rawLots / vstep) * vstep;
   lots = MathMax(vmin, MathMin(vmax, lots));
   return lots;
}

bool HasOpenPosition(int &pos_type)
{
   if(!PositionSelect(_Symbol)) return false;
   pos_type = (int)PositionGetInteger(POSITION_TYPE);
   return true;
}

// Clamp SL/TP to broker constraints (stops/freezes) and tick size; reject if still invalid
bool AdjustStopsForBroker(int pos_type, double &newSL, double &newTP)
{
   double point    = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   long   stopsLv  = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   long   freezeLv = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);

   // Fallback for floating/zero stop level in tester
   if(stopsLv==0)
   {
      int spr = (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
      stopsLv = MathMax(0, spr*3);
   }

   double minDist = (double)MathMax(stopsLv, freezeLv) * point;

   MqlTick tk;  if(!SymbolInfoTick(_Symbol, tk)) return false;
   double bid = tk.bid, ask = tk.ask;
   if(tickSize<=0.0 || point<=0.0) return false;

   if(pos_type==POSITION_TYPE_BUY)
   {
      if(newSL>0)
      {
         double maxSL = bid - minDist;
         if(newSL > maxSL) newSL = maxSL;
         newSL = AlignToTick(newSL);
         if(bid - newSL < minDist) return false;
      }
      if(newTP>0)
      {
         double minTP = ask + minDist;
         if(newTP < minTP) newTP = minTP;
         newTP = AlignToTick(newTP);
         if(newTP - ask < minDist) return false;
      }
   }
   else if(pos_type==POSITION_TYPE_SELL)
   {
      if(newSL>0)
      {
         double minSL = ask + minDist;
         if(newSL < minSL) newSL = minSL;
         newSL = AlignToTick(newSL);
         if(newSL - ask < minDist) return false;
      }
      if(newTP>0)
      {
         double maxTP = bid - minDist;
         if(newTP > maxTP) newTP = maxTP;
         newTP = AlignToTick(newTP);
         if(bid - newTP < minDist) return false;
      }
   }
   return true;
}

//-------------------- Lifecycle --------------------
int OnInit()
{
   hFastEMA = iMA(_Symbol,_Period,FastEMA_Period,0,MODE_EMA,PRICE_CLOSE);
   hSlowEMA = iMA(_Symbol,_Period,SlowEMA_Period,0,MODE_EMA,PRICE_CLOSE);
   hTrendMA = iMA(_Symbol,_Period,TrendMA_Period,0,MODE_SMA,PRICE_CLOSE);
   hATR     = iATR(_Symbol,_Period,ATR_Period);

   int halfLen = MathMax(1,HullMA_Period/2);
   hWMA_half = iMA(_Symbol,_Period,halfLen,0,MODE_LWMA,PRICE_CLOSE);
   hWMA_full = iMA(_Symbol,_Period,HullMA_Period,0,MODE_LWMA,PRICE_CLOSE);

   if(Use_ADX_Filter)
      hADX = iADX(_Symbol,_Period,ADX_Period);

   if(hFastEMA==INVALID_HANDLE || hSlowEMA==INVALID_HANDLE || hTrendMA==INVALID_HANDLE ||
      hATR==INVALID_HANDLE || hWMA_half==INVALID_HANDLE || hWMA_full==INVALID_HANDLE ||
      (Use_ADX_Filter && hADX==INVALID_HANDLE))
   {
      Print("Handle creation failed. Err=",GetLastError());
      return(INIT_FAILED);
   }
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   if(hFastEMA!=INVALID_HANDLE) IndicatorRelease(hFastEMA);
   if(hSlowEMA!=INVALID_HANDLE) IndicatorRelease(hSlowEMA);
   if(hTrendMA!=INVALID_HANDLE) IndicatorRelease(hTrendMA);
   if(hATR!=INVALID_HANDLE)     IndicatorRelease(hATR);
   if(hWMA_half!=INVALID_HANDLE)IndicatorRelease(hWMA_half);
   if(hWMA_full!=INVALID_HANDLE)IndicatorRelease(hWMA_full);
   if(hADX!=INVALID_HANDLE)     IndicatorRelease(hADX);
}

void ManageTrailingExitLine()
{
   if(!Use_ExitLine_Trail) return;
   if(!PositionSelect(_Symbol)) return;

   int ptype = (int)PositionGetInteger(POSITION_TYPE);
   double sl = PositionGetDouble(POSITION_SL);
   double tp = PositionGetDouble(POSITION_TP);

   // compute exit line at current bar (shift 0)
   double exit0;
   if(!GetExitLine(0,exit0)) return;

   double tickSize = SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   if(tickSize<=0.0) return;

   double newSL = sl;
   if(ptype==POSITION_TYPE_BUY)
   {
      newSL = MathMax(sl, exit0); // push up SL
      // require a minimum advance
      if(sl>0 && (newSL - sl) < MathMax(1,Trail_Min_Ticks)*tickSize) return;
   }
   else if(ptype==POSITION_TYPE_SELL)
   {
      newSL = (sl<=0.0) ? exit0 : MathMin(sl, exit0); // pull down SL
      if(sl>0 && (sl - newSL) < MathMax(1,Trail_Min_Ticks)*tickSize) return;
   }
   else return;

   double adjSL=newSL, adjTP=tp;
   if(!AdjustStopsForBroker(ptype, adjSL, adjTP)) return;

   // If after adjust there is still an improvement vs current SL, modify
   if(sl<=0.0 || MathAbs(adjSL - sl) >= MathMax(1,Trail_Min_Ticks)*tickSize)
      trade.PositionModify(_Symbol, adjSL, adjTP);
}

void OnTick()
{
   bool isNew = NewBar();

   // trailing management
   if(Use_ExitLine_Trail)
   {
      if(Trail_On_New_Bar)
      {
         if(isNew) ManageTrailingExitLine();
      }
      else
      {
         ManageTrailingExitLine();
      }
   }

   if(!isNew) return;

   // read last two closes on closed bars 1 and 2
   double c[];
   if(CopyClose(_Symbol,_Period,1,2,c)!=2) return; // c[0]=bar1, c[1]=bar2

   // MAs and ATR at bars 1 and 2
   double tr1,tr2, h1, atr1;
   if(!Copy1(hTrendMA,0,1,tr1)) return;
   if(!Copy1(hTrendMA,0,2,tr2)) return;
   if(!GetHMA(1,h1)) return;
   if(!Copy1(hATR,0,1,atr1)) return;

   // cross detection on closed bars
   bool crossedUp   = (c[1] < tr2) && (c[0] > tr1);
   bool crossedDown = (c[1] > tr2) && (c[0] < tr1);
   bool buySignal  = crossedUp   && (c[0] > h1);
   bool sellSignal = crossedDown && (c[0] < h1);

   if(!(buySignal || sellSignal)) return;
   if(!PassedFilters(1)) return;

   // Position control
   int existingType;
   bool hasPos = HasOpenPosition(existingType);
   if(One_Position_Only && hasPos)
   {
      // If opposite, close then proceed; else return
      if( (buySignal && existingType==POSITION_TYPE_SELL) ||
          (sellSignal && existingType==POSITION_TYPE_BUY) )
      {
         trade.PositionClose(_Symbol);
      }
      else
         return;
   }

   // market prices
   MqlTick tick; if(!SymbolInfoTick(_Symbol,tick)) return;
   double bid=tick.bid, ask=tick.ask;

   // compute initial SL/TP
   double entry   = buySignal ? ask : bid;
   double stopDist= SL_ATR_Mult * atr1;
   double sl      = buySignal ? (entry - stopDist) : (entry + stopDist);
   double tp      = 0.0;
   if(TP_RR>0.0)  tp = buySignal ? (entry + TP_RR*stopDist) : (entry - TP_RR*stopDist);

   // risk-based lots
   double lots = CalcLotsByRisk(stopDist);
   if(lots<=0.0) return;

   // adjust stops to broker constraints using current side
   int ptype = buySignal ? POSITION_TYPE_BUY : POSITION_TYPE_SELL;
   double adjSL=sl, adjTP=tp;
   if(!AdjustStopsForBroker(ptype, adjSL, adjTP))
   {
      // fallback: place without SL/TP, trailing will attach later
      adjSL = 0.0; adjTP = 0.0;
   }

   // send order
   if(buySignal) trade.Buy(lots,_Symbol,0.0,adjSL,adjTP);
   if(sellSignal) trade.Sell(lots,_Symbol,0.0,adjSL,adjTP);
}

// Optional: custom optimization metric (e.g., NetProfit / MaxDrawdown)
double OnTester()
{
   double netProfit = TesterStatistics(STAT_PROFIT);
   double maxDD     = TesterStatistics(STAT_BALANCE_DD);
   if(maxDD<=0.0) return netProfit;
   return netProfit/maxDD;
}
//+------------------------------------------------------------------+
