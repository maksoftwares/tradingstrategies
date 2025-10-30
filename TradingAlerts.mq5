//+------------------------------------------------------------------+
//|                    MST_AllLines_YellowTouchAlert.mq5             |
//| Draw Fast EMA, Slow EMA, Hull MA (purple), Trend MA (yellow),    |
//| Exit Line (red/green). Log upward/downward crosses of yellow     |
//| line with purple line confirmation.                              |
//+------------------------------------------------------------------+
#property version   "1.40"
#property indicator_chart_window
#property indicator_buffers 6
#property indicator_plots   6

//-------------------- Inputs (mirror Pine defaults) --------------------
input int      FastEMA_Period      = 12;
input int      SlowEMA_Period      = 26;
input int      HullMA_Period       = 21;         // HMA length (purple)
input int      TrendMA_Period      = 50;         // Yellow line (SMA)
input int      ATR_Period          = 14;         // for exit line
input double   Exit_ATR_Mult       = 2.0;        // exit line offset
input int      Exit_Smoothing_Per  = 5;          // smoothing of exit line (SMA)
input bool     RequireH1Chart      = true;       // recommend H1 (no hard stop)
input bool     EnablePopup         = true;       // Alert()
input bool     EnablePush          = true;       // SendNotification()
input bool     EnableSound         = true;       // PlaySound()
input string   SoundFile           = "alert.wav";// /terminal/sounds
input bool     EnableCrossLog      = true;       // Log crosses to file
input string   LogFileName         = "YellowCross_Log.csv"; // Log file name

//-------------------- Indicator Buffers --------------------
// 0..5 map to plots
double bufFastEMA[];   // 0 - blue
double bufSlowEMA[];   // 1 - orange
double bufHullMA[];    // 2 - purple
double bufTrendMA[];   // 3 - yellow
double bufExitUp[];    // 4 - red   (price > TrendMA)
double bufExitDn[];    // 5 - green (price < TrendMA)

// Work arrays
double atrBuf[];         // ATR buffer
double tmpExitRaw[];     // raw exit before smoothing
double tmpExitSmooth[];  // smoothed exit line

// Handles for built-ins
int hFastEMA   = INVALID_HANDLE;
int hSlowEMA   = INVALID_HANDLE;
int hTrendMA   = INVALID_HANDLE;   // SMA(Trend)
int hATR       = INVALID_HANDLE;

// HMA (purple) via LWMA handles
int hWMA_half  = INVALID_HANDLE;   // LWMA(n/2) of close
int hWMA_full  = INVALID_HANDLE;   // LWMA(n)   of close

// Alert de-duplication
datetime lastAlertBarTime = 0;
datetime lastCrossBarTime = 0;  // Prevent duplicate cross logs

//-------------------- Small helpers --------------------
string TfToString(ENUM_TIMEFRAMES tf)
{
   switch(tf)
   {
      case PERIOD_M1: return "M1";   case PERIOD_M5: return "M5";
      case PERIOD_M15:return "M15";  case PERIOD_M30:return "M30";
      case PERIOD_H1: return "H1";   case PERIOD_H4: return "H4";
      case PERIOD_D1: return "D1";   case PERIOD_W1: return "W1";
      case PERIOD_MN1:return "MN1";
   }
   return "TF";
}

//-------------------- OnInit --------------------
int OnInit()
{
   // Map buffers to plots
   SetIndexBuffer(0, bufFastEMA, INDICATOR_DATA);
   SetIndexBuffer(1, bufSlowEMA, INDICATOR_DATA);
   SetIndexBuffer(2, bufHullMA,  INDICATOR_DATA);
   SetIndexBuffer(3, bufTrendMA, INDICATOR_DATA);
   SetIndexBuffer(4, bufExitUp,  INDICATOR_DATA);
   SetIndexBuffer(5, bufExitDn,  INDICATOR_DATA);

   // Plot styles
   PlotIndexSetString(0, PLOT_LABEL, "Fast EMA");
   PlotIndexSetInteger(0, PLOT_DRAW_TYPE, DRAW_LINE);
   PlotIndexSetInteger(0, PLOT_LINE_COLOR, clrBlue);
   PlotIndexSetInteger(0, PLOT_LINE_WIDTH, 1);

   PlotIndexSetString(1, PLOT_LABEL, "Slow EMA");
   PlotIndexSetInteger(1, PLOT_DRAW_TYPE, DRAW_LINE);
   PlotIndexSetInteger(1, PLOT_LINE_COLOR, clrOrange);
   PlotIndexSetInteger(1, PLOT_LINE_WIDTH, 1);

   PlotIndexSetString(2, PLOT_LABEL, "Hull MA");
   PlotIndexSetInteger(2, PLOT_DRAW_TYPE, DRAW_LINE);
   PlotIndexSetInteger(2, PLOT_LINE_COLOR, clrPurple);
   PlotIndexSetInteger(2, PLOT_LINE_WIDTH, 2);

   PlotIndexSetString(3, PLOT_LABEL, "Trend MA");
   PlotIndexSetInteger(3, PLOT_DRAW_TYPE, DRAW_LINE);
   PlotIndexSetInteger(3, PLOT_LINE_COLOR, clrYellow);
   PlotIndexSetInteger(3, PLOT_LINE_WIDTH, 2);

   PlotIndexSetString(4, PLOT_LABEL, "Exit Line (Up)");
   PlotIndexSetInteger(4, PLOT_DRAW_TYPE, DRAW_LINE);
   PlotIndexSetInteger(4, PLOT_LINE_COLOR, clrRed);
   PlotIndexSetInteger(4, PLOT_LINE_WIDTH, 2);

   PlotIndexSetString(5, PLOT_LABEL, "Exit Line (Down)");
   PlotIndexSetInteger(5, PLOT_DRAW_TYPE, DRAW_LINE);
   PlotIndexSetInteger(5, PLOT_LINE_COLOR, clrGreen);
   PlotIndexSetInteger(5, PLOT_LINE_WIDTH, 2);

   IndicatorSetString(INDICATOR_SHORTNAME, "MST All Lines + BUY/SELL Cross Log");

   // Built-in handles
   hFastEMA = iMA(_Symbol, _Period, FastEMA_Period, 0, MODE_EMA, PRICE_CLOSE);
   hSlowEMA = iMA(_Symbol, _Period, SlowEMA_Period, 0, MODE_EMA, PRICE_CLOSE);
   hTrendMA = iMA(_Symbol, _Period, TrendMA_Period, 0, MODE_SMA, PRICE_CLOSE);
   hATR     = iATR(_Symbol, _Period, ATR_Period);

   if(hFastEMA==INVALID_HANDLE || hSlowEMA==INVALID_HANDLE || hTrendMA==INVALID_HANDLE || hATR==INVALID_HANDLE)
   {
      Print("ERROR creating EMA/SMA/ATR handles. Code=", GetLastError());
      return(INIT_FAILED);
   }

   // HMA via LWMA handles
   int halfLen = MathMax(1, HullMA_Period/2);
   hWMA_half = iMA(_Symbol, _Period, halfLen,        0, MODE_LWMA, PRICE_CLOSE);
   hWMA_full = iMA(_Symbol, _Period, HullMA_Period,  0, MODE_LWMA, PRICE_CLOSE);
   if(hWMA_half==INVALID_HANDLE || hWMA_full==INVALID_HANDLE)
   {
      Print("ERROR creating LWMA handles for HMA. Code=", GetLastError());
      return(INIT_FAILED);
   }

   // Ensure series orientation for our arrays (index 0 = newest)
   ArraySetAsSeries(bufFastEMA,   true);
   ArraySetAsSeries(bufSlowEMA,   true);
   ArraySetAsSeries(bufHullMA,    true);
   ArraySetAsSeries(bufTrendMA,   true);
   ArraySetAsSeries(bufExitUp,    true);
   ArraySetAsSeries(bufExitDn,    true);
   ArraySetAsSeries(atrBuf,       true);
   ArraySetAsSeries(tmpExitRaw,   true);
   ArraySetAsSeries(tmpExitSmooth,true);

   return(INIT_SUCCEEDED);
}

//-------------------- OnDeinit --------------------
void OnDeinit(const int reason)
{
   if(hFastEMA   != INVALID_HANDLE) IndicatorRelease(hFastEMA);
   if(hSlowEMA   != INVALID_HANDLE) IndicatorRelease(hSlowEMA);
   if(hTrendMA   != INVALID_HANDLE) IndicatorRelease(hTrendMA);
   if(hATR       != INVALID_HANDLE) IndicatorRelease(hATR);
   if(hWMA_half  != INVALID_HANDLE) IndicatorRelease(hWMA_half);
   if(hWMA_full  != INVALID_HANDLE) IndicatorRelease(hWMA_full);
   Comment("");
}

//-------------------- OnCalculate --------------------
int OnCalculate(const int rates_total,
                const int prev_calculated,
                const datetime &time[],
                const double &open[],
                const double &high[],
                const double &low[],
                const double &close[],
                const long &tick_volume[],
                const long &volume[],
                const int &spread[])
{
   // FIX: Set input arrays as series for consistent indexing
   ArraySetAsSeries(time, true);
   ArraySetAsSeries(open, true);
   ArraySetAsSeries(high, true);
   ArraySetAsSeries(low, true);
   ArraySetAsSeries(close, true);

   // Recommend H1 but don't block drawing
   if(RequireH1Chart && _Period != PERIOD_H1)
      Comment("⚠ Recommended timeframe: H1. Current: ", TfToString(_Period));
   else
      Comment("");

   // Enough bars?
   int need = MathMax(TrendMA_Period, MathMax(SlowEMA_Period, MathMax(FastEMA_Period, MathMax(ATR_Period, HullMA_Period))));
   if(rates_total < need + 5) return(prev_calculated);

   // Resize working arrays
   ArrayResize(atrBuf,        rates_total);
   ArrayResize(tmpExitRaw,    rates_total);
   ArrayResize(tmpExitSmooth, rates_total);

   // Copy built-in buffers
   if(CopyBuffer(hFastEMA, 0, 0, rates_total, bufFastEMA) < 0) { Print("CopyBuffer FastEMA failed ", GetLastError()); return(prev_calculated); }
   if(CopyBuffer(hSlowEMA, 0, 0, rates_total, bufSlowEMA) < 0) { Print("CopyBuffer SlowEMA failed ", GetLastError()); return(prev_calculated); }
   if(CopyBuffer(hTrendMA, 0, 0, rates_total, bufTrendMA) < 0) { Print("CopyBuffer TrendMA failed ", GetLastError()); return(prev_calculated); }
   if(CopyBuffer(hATR,     0, 0, rates_total, atrBuf)     < 0) { Print("CopyBuffer ATR failed ", GetLastError());     return(prev_calculated); }

   // ---------------- Hull MA (HMA) via LWMA handles ----------------
   // HMA = LWMA( 2*LWMA(close, n/2) - LWMA(close, n), sqrt(n) )
   static double wHalf[];  static double wFull[]; static double hmaTmp[];
   ArrayResize(wHalf, rates_total);
   ArrayResize(wFull, rates_total);
   ArrayResize(hmaTmp, rates_total);
   ArraySetAsSeries(wHalf,  true);
   ArraySetAsSeries(wFull,  true);
   ArraySetAsSeries(hmaTmp, true);

   if(CopyBuffer(hWMA_half, 0, 0, rates_total, wHalf) < 0) { Print("CopyBuffer WMA half failed ", GetLastError()); return(prev_calculated); }
   if(CopyBuffer(hWMA_full, 0, 0, rates_total, wFull) < 0) { Print("CopyBuffer WMA full failed ", GetLastError()); return(prev_calculated); }

   for(int i=0; i<rates_total; i++)
   {
      if(wHalf[i]==EMPTY_VALUE || wFull[i]==EMPTY_VALUE) { hmaTmp[i]=EMPTY_VALUE; continue; }
      hmaTmp[i] = 2.0*wHalf[i] - wFull[i];
   }

   int sqrtLen = (int)MathMax(1, MathRound(MathSqrt((double)MathMax(1, HullMA_Period))));
   // Final HMA = LWMA(hmaTmp, sqrtLen) computed inline on series
   {
      const double wsum = (double)sqrtLen * (sqrtLen + 1) / 2.0;
      for(int i=0; i<rates_total; i++)
      {
         if(i + sqrtLen - 1 >= rates_total) { bufHullMA[i] = EMPTY_VALUE; continue; }
         double num = 0.0;
         // j=0 newest (weight sqrtLen), j=sqrtLen-1 oldest (weight 1)
         for(int j=0; j<sqrtLen; j++)
            num += hmaTmp[i + j] * (sqrtLen - j);
         bufHullMA[i] = num / wsum;
      }
   }

   // ---------------- Exit Line (ATR offset, smoothed) ----------------
   // rawExit: price > TrendMA ? close - ATR*mult : close + ATR*mult
   for(int i=0; i<rates_total; i++)
   {
      if(bufTrendMA[i]==EMPTY_VALUE || atrBuf[i]==EMPTY_VALUE) { tmpExitRaw[i]=EMPTY_VALUE; continue; }
      bool priceAbove = (close[i] > bufTrendMA[i]);
      double offset   = atrBuf[i] * Exit_ATR_Mult;
      tmpExitRaw[i]   = priceAbove ? (close[i] - offset) : (close[i] + offset);
   }

   // Smooth raw exit line with simple SMA over series
   int p = MathMax(1, Exit_Smoothing_Per);
   // naive but clear series-SMA
   for(int i=0; i<rates_total; i++)
   {
      if(i + p - 1 >= rates_total) { tmpExitSmooth[i] = EMPTY_VALUE; continue; }
      double sum = 0.0;
      for(int j=0; j<p; j++) sum += tmpExitRaw[i + j];
      tmpExitSmooth[i] = sum / (double)p;
   }

   // Split exit into Up/Down colored plots (red when price>TrendMA, green otherwise)
   for(int i=0; i<rates_total; i++)
   {
      if(tmpExitSmooth[i]==EMPTY_VALUE || bufTrendMA[i]==EMPTY_VALUE)
      {
         bufExitUp[i] = EMPTY_VALUE;
         bufExitDn[i] = EMPTY_VALUE;
         continue;
      }
      bool above = (close[i] > bufTrendMA[i]);
      if(above) { bufExitUp[i] = tmpExitSmooth[i]; bufExitDn[i] = EMPTY_VALUE; }
      else      { bufExitUp[i] = EMPTY_VALUE;      bufExitDn[i] = tmpExitSmooth[i]; }
   }

   /* ============================================================
      COMMENTED OUT: Yellow Trend MA touch alert (last closed bar)
      ============================================================
   int iBar = 1; // Last closed bar (series indexing: 0=current, 1=last closed)
   if(iBar < rates_total && bufTrendMA[iBar] != EMPTY_VALUE)
   {
      bool touched = (low[iBar] <= bufTrendMA[iBar] && high[iBar] >= bufTrendMA[iBar]);
      
      // Check AND update lastAlertBarTime to prevent duplicates
      if(touched && time[iBar] != lastAlertBarTime)
      {
         lastAlertBarTime = time[iBar]; 
         
         string msg = StringFormat("[%s %s] Bar touched Trend MA @ %.5f (MA=%.5f)",
                                   _Symbol, TfToString(_Period), close[iBar], bufTrendMA[iBar]);
         if(EnablePopup)  Alert(msg);
         if(EnableSound)  PlaySound(SoundFile);
         if(EnablePush)   SendNotification(msg);
      }
   }
   ============================================================ */

   // ---------------- BUY/SELL CROSS DETECTION & LOGGING ----------------
   if(EnableCrossLog && rates_total >= 3)
   {
      int checkBar = 1;  // Last closed bar
      int prevBar  = 2;  // Bar before that
      
      // Ensure we have valid data for both bars
      if(bufTrendMA[checkBar] != EMPTY_VALUE && bufTrendMA[prevBar] != EMPTY_VALUE &&
         bufHullMA[checkBar]  != EMPTY_VALUE && bufHullMA[prevBar]  != EMPTY_VALUE)
      {
         // Detect UPWARD cross (BUY): previous bar below Yellow, current bar above Yellow
         bool crossedUp = (close[prevBar] < bufTrendMA[prevBar]) && 
                          (close[checkBar] > bufTrendMA[checkBar]);
         
         // Detect DOWNWARD cross (SELL): previous bar above Yellow, current bar below Yellow
         bool crossedDown = (close[prevBar] > bufTrendMA[prevBar]) && 
                            (close[checkBar] < bufTrendMA[checkBar]);
         
         // BUY condition: price crossed up AND is above Purple Hull MA
         bool buySignal = crossedUp && (close[checkBar] > bufHullMA[checkBar]);
         
         // SELL condition: price crossed down AND is below Purple Hull MA
         bool sellSignal = crossedDown && (close[checkBar] < bufHullMA[checkBar]);
         
         // Log the signal only once per bar
         if((buySignal || sellSignal) && time[checkBar] != lastCrossBarTime)
         {
            lastCrossBarTime = time[checkBar];
            
            // Determine signal type and format message
            string signalType = buySignal ? "BUY" : "SELL";
            string priceStr = DoubleToString(close[checkBar], _Digits);
            string logMsg = signalType + " - " + priceStr;
            
            // Open log file in append mode
            int fileHandle = FileOpen(LogFileName, FILE_READ|FILE_WRITE|FILE_CSV|FILE_ANSI, ',');
            
            if(fileHandle != INVALID_HANDLE)
            {
               // Move to end of file for appending
               FileSeek(fileHandle, 0, SEEK_END);
               
               // Format: Symbol, Timeframe, DateTime, Signal (BUY/SELL - Price), Yellow MA, Purple Hull MA
               string timestamp = TimeToString(time[checkBar], TIME_DATE|TIME_SECONDS);
               FileWrite(fileHandle, 
                        _Symbol, 
                        TfToString(_Period), 
                        timestamp,
                        logMsg,
                        DoubleToString(bufTrendMA[checkBar], _Digits),
                        DoubleToString(bufHullMA[checkBar], _Digits));
               
               FileClose(fileHandle);
               
               // Terminal log for immediate feedback
               Print(StringFormat("[%s] %s %s at %s | Yellow: %.5f | Purple: %.5f",
                                 signalType, _Symbol, TfToString(_Period), timestamp, 
                                 bufTrendMA[checkBar], bufHullMA[checkBar]));
               
               // Optional alerts
               if(EnablePopup)
               {
                  string alertMsg = StringFormat("[%s %s] %s signal at %.5f", 
                                                 _Symbol, TfToString(_Period), signalType, close[checkBar]);
                  Alert(alertMsg);
               }
               if(EnableSound) PlaySound(SoundFile);
               if(EnablePush)
               {
                  string pushMsg = StringFormat("[%s %s] %s - %.5f", 
                                                _Symbol, TfToString(_Period), signalType, close[checkBar]);
                  SendNotification(pushMsg);
               }
            }
            else
            {
               Print("ERROR: Failed to open log file ", LogFileName, ". Error code: ", GetLastError());
            }
         }
      }
   }

   return(rates_total);
}
//+------------------------------------------------------------------+
