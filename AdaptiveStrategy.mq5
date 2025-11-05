//+------------------------------------------------------------------+
//| Breakout Adaptive EA - M30 Asia/London v8.6 NO-BROKER-SPAM       |
//| Prevents repeated cancel attempts during market-closed periods    |
//+------------------------------------------------------------------+
#property strict

enum Regime { REG_TREND=0, REG_RANGE=1, REG_NEUTRAL=2 };

input ENUM_TIMEFRAMES InpTF            = PERIOD_M30;
input int             ATR_Period       = 14;
input double          ATR_Multiplier   = 2.2;
input double          ATR_Buffer_Mult  = 0.7;
input int             ADX_Period       = 14;
input int             EMA_FastPeriod   = 20;
input int             EMA_SlowPeriod   = 50;
input bool            EnableTrendFilter = true;
input int             LookbackBars     = 28;
input int             BaseEntryBufferPts = 200;
input double          RiskPercent      = 0.30;
input double          TP_Multiplier    = 2.0;
input double          MaxSpreadPts     = 250;
input int             SlippagePts      = 15;
input ulong           Magic            = 20251104;
input double          MinBalanceUSD    = 10.0;
input bool            EnableCloseConfirm = false;
input double          CloseConfirmBufferPct = 0.0;
input bool            EnableStopLimit   = false;
input int             StopLimitOffsetPts = 40;
input double          MinSL_to_Spread_Ratio = 2.0;
input double          MinBuffer_to_Spread_Ratio = 0.8;
enum EntryModeEnum { OCO_Stops=0, Hedged_Market=1 };
input EntryModeEnum   EntryMode        = OCO_Stops;
input bool            UseSessionFilter = false;
input int             Session1_StartHour = 21;
input int             Session1_EndHour   = 24;
input int             Session2_StartHour = 0;
input int             Session2_EndHour   = 11;
input bool            EnablePartialTP  = true;
input double          PartialTPMultiplier = 0.95;
input double          TrailingStopMultiplier = 1.2;
input int             MinimumHoldBars  = 3;
input double          HedgeCommitATR   = 0.5;
input int             OCO_Expiry_Bars  = 1;
input int             Cooloff_Bars     = 3;
input double          RangeChange_Pct  = 2.0;
input int             MaxConsecutiveLosses = 3;
input int             MaxDailyOrders   = 50;
input double          MaxDailyLossPercent = 8;
input double          RegimeThreshold_TrendADX_High = 20.0;
input double          RegimeThreshold_RangeADX_Low = 14.0;
input double          RangeEMA_SlopeThreshold = 80.0;
input int             RollingWindow_Days = 7;
input double          Tighten_OnLoss_Pct = 0.6;
input double          Loosen_OnWin_Pct = 1.2;
input double          AdaptRate_Daily = 0.15;
input bool            EnableDebugLog   = true;
input int             MinRefreshBars   = 1;
input int             MaxRearmsPerHour = 10;
input double          MinADXForTrendOnly = 22.0;
input double          DisableRangeADX  = 25.0;
input double          MinATRk          = 0.8;
input double          MaxATRk          = 2.2;
input double          MinSLSpreadRatioXAU = 2.0;
input int             LossDefenseThreshold = -2;
input int             RegimeHysteresisBar = 2;
input int             MinBarsBtwRegimeSwitch = 0;
input double          HighADXThreshold = 40.0;
input int             IntraDayLossSLThreshold = 3;
input bool            EnableOCO_Refresh = true;
input double          OCO_RefreshBandShift_Pct = 3.0;
input bool            BlockWhenMarketClosed = true;
input int             StaleQuoteMaxSec  = 45;

struct ModeParams {
   double close_confirm_pct;
   double buffer_atr_k;
   double atr_multiplier;
   double risk_pct;
   bool   use_oco;
   string name;
};

struct LogCounter {
   string msg_type;
   int count;
};
LogCounter g_log_counters[50];
int g_log_counter_count = 0;

int    hATR = INVALID_HANDLE, hADX = INVALID_HANDLE, hEMA_Fast = INVALID_HANDLE, hEMA_Slow = INVALID_HANDLE;
ENUM_ORDER_TYPE_FILLING g_fill = ORDER_FILLING_FOK;
int    g_lastBar_Index     = -1;
bool   g_armedThisBar      = false;
bool   g_abortedThisBar    = false;
int    g_cooloff_EndBar    = -1;
double g_lastOCO_BuyPrice  = 0.0, g_lastOCO_SellPrice = 0.0;
datetime g_lastOCO_Time    = 0;
int    g_lastOCO_RefreshBar = -999;
int    g_rearm_count_hour  = 0;
datetime g_last_hour_reset = 0;
double g_lastRange_BuyPrice= 0.0, g_lastRange_SellPrice= 0.0;
datetime g_lastRange_Time  = 0;
int    g_lastRange_RefreshBar = -999;
int    g_consecutiveLosses = 0;
int    g_dailyOrderCount   = 0;
double g_dailyLossAmount   = 0.0;
bool   g_balanceWarningShown = false;
Regime g_regime = REG_NEUTRAL;
int    g_regime_switch_bar = -999;
ModeParams g_params;
double g_pnl_trend_daily = 0.0, g_pnl_range_daily = 0.0;
int    g_trend_count_daily = 0, g_range_count_daily = 0;
int    g_adaptive_buffer = 200;
double g_adaptive_risk = 0.30;
double g_adaptive_sl_ratio = 2.0;
double g_trend_win_rate = 0.5;
double g_range_win_rate = 0.5;
datetime g_hist_last_sync = 0;
bool   g_loss_defense_active = false;
int    g_loss_defense_day = -1;
datetime g_last_market_check = 0;
bool   g_market_was_open = true;
int    g_session_sl_count = 0;
double g_prev_adx = 0.0;
datetime g_market_suspend_until = 0;
bool   g_cancel_attempted_this_close = false;  // NEW: Block repeated cancel

struct TicketRegime { ulong ticket; Regime regime; };
TicketRegime g_ticket_regime[100];
int g_ticket_regime_count = 0;

ulong g_processedDeals[1024];
int   g_processedDealCount = 0;

void PrintLogOnce(const string msg_type, const string msg_text)
{
   if(!EnableDebugLog) return;
   
   int idx = -1;
   for(int i=0; i<g_log_counter_count; i++){
      if(g_log_counters[i].msg_type == msg_type){
         idx = i;
         break;
      }
   }
   
   if(idx < 0){
      if(g_log_counter_count < 50){
         idx = g_log_counter_count;
         g_log_counters[idx].msg_type = msg_type;
         g_log_counters[idx].count = 0;
         g_log_counter_count++;
      } else {
         Print(msg_text);
         return;
      }
   }
   
   g_log_counters[idx].count++;
   if(g_log_counters[idx].count <= 5){
      Print(msg_text);
   }
   else if(g_log_counters[idx].count == 6){
      PrintFormat("(Suppressing further '%s' messages)", msg_type);
   }
}

void ResetLogCounters(){
   for(int i=0; i<g_log_counter_count; i++){
      g_log_counters[i].count = 0;
   }
}

void MapAdd(ulong ticket, Regime r) { for(int i=0;i<g_ticket_regime_count;i++) if(g_ticket_regime[i].ticket==ticket){ g_ticket_regime[i].regime=r; return; } if(g_ticket_regime_count<100){ g_ticket_regime[g_ticket_regime_count].ticket=ticket; g_ticket_regime[g_ticket_regime_count].regime=r; g_ticket_regime_count++; } }
bool MapGet(ulong ticket, Regime &r) { for(int i=0;i<g_ticket_regime_count;i++) if(g_ticket_regime[i].ticket==ticket){ r=g_ticket_regime[i].regime; return true; } return false; }
void MapRemove(ulong ticket){ for(int i=0;i<g_ticket_regime_count;i++) if(g_ticket_regime[i].ticket==ticket){ for(int j=i;j<g_ticket_regime_count-1;j++) g_ticket_regime[j]=g_ticket_regime[j+1]; g_ticket_regime_count--; return; } }
bool DealSeen(ulong deal){ for(int i=0;i<g_processedDealCount;i++) if(g_processedDeals[i]==deal) return true; return false; }
void MarkDeal(ulong deal){ if(g_processedDealCount<1024) g_processedDeals[g_processedDealCount++]=deal; }

double GetSpreadPts(){ return (SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID))/_Point; }

bool IsSessionOpenNow(const string sym, datetime t0=0)
{
   datetime now = (t0==0 ? TimeCurrent() : t0);
   MqlDateTime dt; TimeToStruct(now, dt);
   ENUM_DAY_OF_WEEK dow = (ENUM_DAY_OF_WEEK)dt.day_of_week;
   for(uint i=0; i<16; ++i){
      datetime from=0, to=0;
      if(!SymbolInfoSessionTrade(sym, dow, i, from, to)) break;
      if(from==0 && to==0) continue;
      if(from <= to){ if(now >= from && now < to) return true; }
      else          { if(now >= from || now < to) return true; }
   }
   return false;
}

bool HasFreshQuote(const string sym, const int max_age_sec)
{
   MqlTick tick; if(!SymbolInfoTick(sym, tick)) return false;
   if(tick.time==0) return false;
   return (int)(TimeCurrent() - tick.time) <= max_age_sec;
}

bool IsMarketTradeableNow()
{
   if(!BlockWhenMarketClosed) return true;
   if(g_market_suspend_until>0 && TimeCurrent() < g_market_suspend_until) return false;
   if(MQLInfoInteger(MQL_TESTER) || MQLInfoInteger(MQL_OPTIMIZATION)) return true;
   if(!TerminalInfoInteger(TERMINAL_CONNECTED)) return false;

   long mode = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE);
   if(mode==SYMBOL_TRADE_MODE_DISABLED || mode==SYMBOL_TRADE_MODE_CLOSEONLY) return false;

   if(!IsSessionOpenNow(_Symbol)) return false;
   if(!HasFreshQuote(_Symbol, StaleQuoteMaxSec)) return false;

   return true;
}

bool IsAsiaLondonSessionOK(){
   if(!UseSessionFilter) return true;
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   int h=dt.hour;
   return ((h>=Session1_StartHour && h<Session1_EndHour) || (h>=Session2_StartHour && h<Session2_EndHour));
}

bool IsSymbolTrading(){ return SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE) == SYMBOL_TRADE_MODE_FULL; }

int CountPositionsByMagic(int typeFilter=-1){
   int c=0;
   for(int i=0; i<PositionsTotal(); i++){
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != Magic) continue;
      if(typeFilter >= 0 && (int)PositionGetInteger(POSITION_TYPE) != typeFilter) continue;
      c++;
   }
   return c;
}

int CountOrdersByMagic(int typeFilter=-1){
   int c=0;
   for(int i=0;i<OrdersTotal();i++){
      ulong ticket = OrderGetTicket(i);
      if(ticket==0) continue;
      if(OrderGetString(ORDER_SYMBOL)!=_Symbol) continue;
      if((ulong)OrderGetInteger(ORDER_MAGIC)!=Magic) continue;
      if(typeFilter>=0 && (int)OrderGetInteger(ORDER_TYPE)!=typeFilter) continue;
      c++;
   }
   return c;
}

double NormalizeVolume(double lots){
   double vmin=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN), vmax=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX), vstep=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   lots=MathMax(vmin,MathMin(lots,vmax)); return MathFloor(lots/vstep)*vstep;
}

double CalcRiskLots(double stopPts,double riskPct=-1.0){
   if(stopPts<=0) return 0.0; if(riskPct<0) riskPct=g_adaptive_risk;
   double equity=AccountInfoDouble(ACCOUNT_EQUITY), riskAmt=equity*(riskPct/100.0);
   double tickVal=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE), tickSize=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   if(tickSize<=0) return 0.0; double valuePerPointPerLot = tickVal*(_Point/tickSize); if(valuePerPointPerLot<=0) return 0.0;
   return NormalizeVolume(riskAmt/(stopPts*valuePerPointPerLot));
}

bool GetATR(double &atr){ if(hATR==INVALID_HANDLE) return false; double b[]; ArraySetAsSeries(b,true); if(CopyBuffer(hATR,0,0,2,b)<2) return false; atr=b[0]; return atr>0; }
bool GetADX(double &adx){ if(hADX==INVALID_HANDLE) return false; double b[]; ArraySetAsSeries(b,true); if(CopyBuffer(hADX,0,0,2,b)<2) return false; adx=b[0]; return adx>=0; }
bool GetEMAs(double &f,double &s){ if(hEMA_Fast==INVALID_HANDLE||hEMA_Slow==INVALID_HANDLE) return false; double fb[],sb[]; ArraySetAsSeries(fb,true); ArraySetAsSeries(sb,true); if(CopyBuffer(hEMA_Fast,0,0,2,fb)<2) return false; if(CopyBuffer(hEMA_Slow,0,0,2,sb)<2) return false; f=fb[0]; s=sb[0]; return true; }

bool ComputeBands(double &hi,double &lo){
   double hs[],ls[]; ArraySetAsSeries(hs,true); ArraySetAsSeries(ls,true);
   if(CopyHigh(_Symbol,InpTF,1,LookbackBars,hs)<LookbackBars) return false;
   if(CopyLow (_Symbol,InpTF,1,LookbackBars,ls)<LookbackBars) return false;
   hi=hs[ArrayMaximum(hs,0,LookbackBars)]; lo=ls[ArrayMinimum(ls,0,LookbackBars)]; return hi>lo;
}

Regime DetectRegime(double adx,double ema_fast,double ema_slow){
   bool trendAligned = (ema_fast>ema_slow)||(ema_fast<ema_slow);
   if(g_lastBar_Index - g_regime_switch_bar < RegimeHysteresisBar && g_regime != REG_NEUTRAL) return g_regime;
   if(adx >= RegimeThreshold_TrendADX_High && trendAligned) return REG_TREND;
   if(adx <= RegimeThreshold_RangeADX_Low && !trendAligned) return REG_RANGE;
   return REG_NEUTRAL;
}

double CalcATRBuffer_K(double adx){
   if(adx < 15.0) return MinATRk;
   if(adx > 40.0) return MaxATRk;
   return MinATRk + (MaxATRk - MinATRk) * (adx - 15.0) / 25.0;
}

double CalcATRBuffer_Pts(double atr, double adx){
   double k = CalcATRBuffer_K(adx);
   return k * atr / _Point;
}

void SetParamsByRegime(Regime r, double atr, double adx){
   double k = CalcATRBuffer_K(adx);
   if(r==REG_TREND){ g_params.close_confirm_pct=0.0; g_params.buffer_atr_k=k;   g_params.atr_multiplier=1.8; g_params.risk_pct=g_adaptive_risk;        g_params.use_oco=true;  g_params.name="TREND"; }
   else if(r==REG_RANGE){ g_params.close_confirm_pct=0.0; g_params.buffer_atr_k=k*0.7; g_params.atr_multiplier=1.0; g_params.risk_pct=g_adaptive_risk*0.8;  g_params.use_oco=false; g_params.name="RANGE"; }
   else { g_params.close_confirm_pct=0.0; g_params.buffer_atr_k=k;   g_params.atr_multiplier=1.4; g_params.risk_pct=g_adaptive_risk*0.6;  g_params.use_oco=false; g_params.name="NEUTRAL"; }
}

bool TrendFilterOK(double f,double s,bool &allowBuy,bool &allowSell){
   allowBuy=true; allowSell=true; if(!EnableTrendFilter) return true;
   if(f>s){ allowBuy=true; allowSell=false; } else if(f<s){ allowBuy=false; allowSell=true; } return (allowBuy||allowSell);
}

bool RangeNotDrifting(double f, double s){
   double dist=MathAbs(f-s); return (dist < RangeEMA_SlopeThreshold*_Point);
}

ENUM_ORDER_TYPE_FILLING ResolveFilling(){ uint fm=(uint)SymbolInfoInteger(_Symbol,SYMBOL_FILLING_MODE);
   if((fm&SYMBOL_FILLING_FOK)==SYMBOL_FILLING_FOK) return ORDER_FILLING_FOK;
   if((fm&SYMBOL_FILLING_IOC)==SYMBOL_FILLING_IOC) return ORDER_FILLING_IOC;
   return ORDER_FILLING_RETURN;
}

bool CheckPendingDistance(double price,ENUM_ORDER_TYPE type){
   ulong stopsLevel=(ulong)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL);
   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID), ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   if(stopsLevel==0) return true;
   if(type==ORDER_TYPE_BUY_STOP || type==ORDER_TYPE_BUY_STOP_LIMIT)  return ((price-ask) > stopsLevel*_Point);
   if(type==ORDER_TYPE_SELL_STOP|| type==ORDER_TYPE_SELL_STOP_LIMIT) return ((bid-price) > stopsLevel*_Point);
   return true;
}

bool ValidateSpread_to_Stop(double slPts,double spreadPts, double adx){
   double minRatio = MinSL_to_Spread_Ratio;
   if(adx > HighADXThreshold) minRatio = MathMax(1.5, MinSLSpreadRatioXAU);
   return (slPts >= minRatio * spreadPts);
}

bool SendOrder(ENUM_ORDER_TYPE type,double price,double sl,double tp,double lots,string comment,double stoplimit=0)
{
   if(!IsMarketTradeableNow()){
      PrintLogOnce("MARKET_CLOSED", "⏸ Market not tradeable. Order BLOCKED.");
      return false;
   }

   if(!TerminalInfoInteger(TERMINAL_CONNECTED)){
      PrintLogOnce("TERMINAL_DISCONNECTED", "No terminal connection. Order BLOCKED.");
      g_market_suspend_until = TimeCurrent() + 60;
      return false;
   }

   MqlTradeRequest req; MqlTradeResult res; ZeroMemory(req); ZeroMemory(res);
   req.action = (type==ORDER_TYPE_BUY_STOP || type==ORDER_TYPE_SELL_STOP ||
                 type==ORDER_TYPE_BUY_LIMIT|| type==ORDER_TYPE_SELL_LIMIT||
                 type==ORDER_TYPE_BUY_STOP_LIMIT || type==ORDER_TYPE_SELL_STOP_LIMIT)
                 ? TRADE_ACTION_PENDING : TRADE_ACTION_DEAL;
   req.symbol=_Symbol;
   req.magic=Magic;
   req.type=type;
   req.volume=lots;
   req.price=price;
   req.sl=sl;
   req.tp=tp;
   req.deviation=SlippagePts;
   req.type_filling=g_fill;
   req.comment=comment;
   if(stoplimit>0) req.stoplimit=stoplimit;

   if(!OrderSend(req,res)){
      int err = GetLastError();
      PrintLogOnce("ORDER_SEND_FAIL", StringFormat("OrderSend failed (err=%d). Pausing 60s.", err));
      g_market_was_open=false;
      g_market_suspend_until = TimeCurrent() + 60;
      return false;
   }

   bool placed = (res.order>0 || res.deal>0);
   if(!placed){
      PrintLogOnce("ORDER_REJECTED", StringFormat("Order rejected (retcode=%d). Pausing 60s.", (int)res.retcode));
      g_market_was_open=false;
      g_market_suspend_until = TimeCurrent() + 60;
      return false;
   }

   return true;
}

int CancelAllMagicPendings(){
   if(!IsMarketTradeableNow()){
      return 0;
   }

   int rem=0;
   for(int i=OrdersTotal()-1;i>=0;i--){
      ulong ticket = OrderGetTicket(i);
      if(ticket==0) continue;
      if(OrderGetString(ORDER_SYMBOL)!=_Symbol) continue;
      if((ulong)OrderGetInteger(ORDER_MAGIC)!=Magic) continue;
      MqlTradeRequest r; MqlTradeResult s; ZeroMemory(r); ZeroMemory(s);
      r.action=TRADE_ACTION_REMOVE; r.order=ticket;
      if(OrderSend(r,s)) rem++;
   }
   return rem;
}

int CancelOppositePendingType(ENUM_ORDER_TYPE delType){
   if(!IsMarketTradeableNow()) return 0;
   
   int rem=0;
   for(int i=OrdersTotal()-1; i>=0; i--){
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0) continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol) continue;
      if((ulong)OrderGetInteger(ORDER_MAGIC) != Magic) continue;
      if((ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE) == delType){
         MqlTradeRequest r; MqlTradeResult s; ZeroMemory(r); ZeroMemory(s);
         r.action = TRADE_ACTION_REMOVE; r.order = ticket;
         if(OrderSend(r, s)) rem++;
      }
   }
   return rem;
}

bool DeleteOppositePendingIfOneTriggered(){
   if(CountPositionsByMagic(-1) != 1) return false;
   int openType = -1;
   for(int i=0; i<PositionsTotal(); i++){
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != Magic) continue;
      openType = (int)PositionGetInteger(POSITION_TYPE);
      break;
   }
   if(openType < 0) return false;
   ENUM_ORDER_TYPE delType = (openType == POSITION_TYPE_BUY) ? ORDER_TYPE_SELL_STOP : ORDER_TYPE_BUY_STOP;
   int deleted = CancelOppositePendingType(delType);
   if(deleted > 0) g_cooloff_EndBar = g_lastBar_Index + Cooloff_Bars;
   return deleted > 0;
}

bool ShouldRefreshOCO_Adaptive(double newBuyPrice, double newSellPrice, double adx){
   if(!EnableOCO_Refresh) return false;
   if(g_lastBar_Index - g_lastOCO_RefreshBar < MinRefreshBars) return false;
   if(g_lastOCO_BuyPrice <= 0.0) return true;
   double buyChange_pct = MathAbs(newBuyPrice - g_lastOCO_BuyPrice) / g_lastOCO_BuyPrice * 100.0;
   double sellChange_pct = MathAbs(newSellPrice - g_lastOCO_SellPrice) / g_lastOCO_SellPrice * 100.0;
   if(buyChange_pct > OCO_RefreshBandShift_Pct || sellChange_pct > OCO_RefreshBandShift_Pct) return true;
   return false;
}

bool ShouldRefreshRange(double newBuyLimit, double newSellLimit){
   if(g_lastBar_Index - g_lastRange_RefreshBar < MinRefreshBars) return false;
   if(g_lastRange_BuyPrice <= 0.0) return true;
   double buyChange_pct = MathAbs(newBuyLimit - g_lastRange_BuyPrice) / g_lastRange_BuyPrice * 100.0;
   double sellChange_pct = MathAbs(newSellLimit - g_lastRange_SellPrice) / g_lastRange_SellPrice * 100.0;
   if(buyChange_pct > RangeChange_Pct || sellChange_pct > RangeChange_Pct) return true;
   return false;
}

bool CanRearmThisHour(){
   datetime now = TimeCurrent();
   if(g_last_hour_reset == 0) g_last_hour_reset = now;
   if((now - g_last_hour_reset) > 3600){ g_rearm_count_hour = 0; g_last_hour_reset = now; }
   if(g_rearm_count_hour >= MaxRearmsPerHour) return false;
   return true;
}

bool PlaceOCO_Atomic(double atr,double lots,double spreadPts,double adx,double ema_fast,double ema_slow){
   double hi,lo; if(!ComputeBands(hi,lo)) return false;
   double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK), bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double buffer_pts = CalcATRBuffer_Pts(atr, adx);
   double buyPrice=hi+buffer_pts*_Point, sellPrice=lo-buffer_pts*_Point;
   if(buyPrice<=ask || sellPrice>=bid) return false;
   double slPts = MathMax(g_params.atr_multiplier*atr/_Point, 40.0);
   double tpPts=TP_Multiplier*slPts;
   double buySL=buyPrice-slPts*_Point, buyTP=buyPrice+tpPts*_Point, sellSL=sellPrice+slPts*_Point, sellTP=sellPrice-tpPts*_Point;
   if(!ValidateSpread_to_Stop(slPts,spreadPts, adx)) return false;
   bool allowBuy=true,allowSell=true; TrendFilterOK(ema_fast,ema_slow,allowBuy,allowSell);
   bool bOk=false,sOk=false;
   if(allowBuy && CheckPendingDistance(buyPrice,ORDER_TYPE_BUY_STOP))  bOk=SendOrder(ORDER_TYPE_BUY_STOP, buyPrice,buySL,buyTP,lots,"TREND_BUY", 0);
   if(allowSell&& CheckPendingDistance(sellPrice,ORDER_TYPE_SELL_STOP)) sOk=SendOrder(ORDER_TYPE_SELL_STOP,sellPrice,sellSL,sellTP,lots,"TREND_SELL", 0);
   if(!(bOk||sOk)) return false;
   if(bOk||sOk){
      g_lastOCO_BuyPrice=buyPrice; g_lastOCO_SellPrice=sellPrice; g_lastOCO_Time=iTime(_Symbol,InpTF,0);
      g_lastOCO_RefreshBar = g_lastBar_Index; g_dailyOrderCount++; g_rearm_count_hour++;
      if(EnableDebugLog) PrintFormat("✓ OCO PLACED: Buy@%.2f SL=%.2f TP=%.2f | Sell@%.2f SL=%.2f TP=%.2f | Buffer=%.0f pts (ADX=%.1f ATR=%.2f)", buyPrice, buySL, buyTP, sellPrice, sellSL, sellTP, buffer_pts, adx, atr);
   }
   return true;
}

bool PlaceRangeReversion(double atr,double spreadPts,double ema_fast,double ema_slow, double adx){
   if(adx >= DisableRangeADX) return false;
   if(!RangeNotDrifting(ema_fast, ema_slow)) return false;
   double hi,lo; if(!ComputeBands(hi,lo)) return false; double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK), bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double buffer_pts = CalcATRBuffer_Pts(atr, adx) * 0.7;
   double slPts=MathMax(g_params.atr_multiplier*atr/_Point, 35.0);
   double tpPts=1.2*slPts;
   double sellLimit=hi-buffer_pts*_Point, buyLimit=lo+buffer_pts*_Point;
   if(!ValidateSpread_to_Stop(slPts,GetSpreadPts(), adx)) return false;
   double lots=CalcRiskLots(slPts,g_params.risk_pct); if(lots<=0.0) return false;
   bool sOk=false,bOk=false;
   if(sellLimit>bid) sOk=SendOrder(ORDER_TYPE_SELL_LIMIT,sellLimit,sellLimit+slPts*_Point,sellLimit-tpPts*_Point,lots,"RANGE_SELL");
   if(buyLimit<ask) bOk=SendOrder(ORDER_TYPE_BUY_LIMIT, buyLimit, buyLimit -slPts*_Point,buyLimit +tpPts*_Point,lots,"RANGE_BUY");
   if(sOk||bOk){
      g_lastRange_BuyPrice=buyLimit; g_lastRange_SellPrice=sellLimit; g_lastRange_Time=iTime(_Symbol,InpTF,0);
      g_lastRange_RefreshBar = g_lastBar_Index; g_dailyOrderCount++; g_rearm_count_hour++;
      if(EnableDebugLog) PrintFormat("✓ RANGE PLACED: Buy@%.2f SL=%.2f TP=%.2f | Sell@%.2f SL=%.2f TP=%.2f", buyLimit, buyLimit-slPts*_Point, buyLimit+tpPts*_Point, sellLimit, sellLimit+slPts*_Point, sellLimit-tpPts*_Point);
   }
   return (sOk||bOk);
}

void Ledger_SyncOpenPositions(){ for(int i=0; i<PositionsTotal(); i++){ ulong ticket = PositionGetTicket(i); if(ticket == 0) continue; if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue; if((ulong)PositionGetInteger(POSITION_MAGIC) != Magic) continue; Regime r; if(!MapGet(ticket, r)){ MapAdd(ticket, g_regime); if(g_regime == REG_TREND) g_trend_count_daily++; else g_range_count_daily++; if(EnableDebugLog) PrintFormat("✓ ENTRY: #%I64u Regime=%s", ticket, (g_regime==REG_TREND?"TREND":"RANGE")); }} }

void Ledger_HarvestClosedPnL(){
   if(g_hist_last_sync == 0) g_hist_last_sync = TimeCurrent() - 86400*30;
   datetime to = TimeCurrent();
   HistorySelect(g_hist_last_sync, to);
   int total = HistoryDealsTotal();
   for(int i = total-1; i >= 0; i--){
      ulong deal = HistoryDealGetTicket(i);
      if(DealSeen(deal)) continue;
      string sym = HistoryDealGetString(deal, DEAL_SYMBOL);
      if(sym != _Symbol) { MarkDeal(deal); continue; }
      long dmagic = HistoryDealGetInteger(deal, DEAL_MAGIC);
      if(dmagic != (long)Magic) { MarkDeal(deal); continue; }
      long entry = HistoryDealGetInteger(deal, DEAL_ENTRY);
      if(entry != 1 && entry != 2){ MarkDeal(deal); continue; }
      ulong pos_id = (ulong)HistoryDealGetInteger(deal, DEAL_POSITION_ID);
      double profit = HistoryDealGetDouble(deal, DEAL_PROFIT);
      double comm   = HistoryDealGetDouble(deal, DEAL_COMMISSION);
      double swap   = HistoryDealGetDouble(deal, DEAL_SWAP);
      double pnl    = profit + comm + swap;
      Regime r; if(!MapGet(pos_id, r)) r = REG_NEUTRAL;
      if(r == REG_TREND) g_pnl_trend_daily += pnl; else g_pnl_range_daily += pnl;
      if(pnl < -50.0) g_session_sl_count++;
      MapRemove(pos_id); MarkDeal(deal);
      if(EnableDebugLog) PrintFormat("✓ EXIT: #%I64u Regime=%s PnL=%.2f", pos_id, (r==REG_TREND?"TREND":"RANGE"), pnl);
   }
   g_hist_last_sync = to;
}

void UpdateIntraDayDefense(){
   if(g_session_sl_count >= IntraDayLossSLThreshold){
      double old_risk = g_adaptive_risk;
      g_adaptive_risk = MathMin(0.12, g_adaptive_risk * 0.6);
      if(EnableDebugLog && old_risk != g_adaptive_risk) PrintFormat("⚡ INTRA-DAY DEFENSE: %d SLs → Risk=%.2f%%", g_session_sl_count, g_adaptive_risk);
   }
}

void UpdateDailyLearning(){
   static int lastDay=-1; MqlDateTime dt; TimeToStruct(iTime(_Symbol,InpTF,0),dt);
   if(dt.day==lastDay) return;
   if(EnableDebugLog) PrintFormat("📊 Day: TREND=%.2f$(%d) | RANGE=%.2f$(%d) | Total=%.2f$", g_pnl_trend_daily, g_trend_count_daily, g_pnl_range_daily, g_range_count_daily, g_pnl_trend_daily+g_pnl_range_daily);
   double daily_pnl = g_pnl_trend_daily + g_pnl_range_daily;
   double bal = MathMax(AccountInfoDouble(ACCOUNT_BALANCE),1.0);
   double daily_pct = (daily_pnl/bal)*100.0;
   if(daily_pct <= LossDefenseThreshold){ g_adaptive_buffer = (int)(BaseEntryBufferPts * Tighten_OnLoss_Pct); g_adaptive_risk = RiskPercent * Tighten_OnLoss_Pct; g_loss_defense_active = true; g_loss_defense_day = dt.day; if(EnableDebugLog) PrintFormat("🛡️ LOSS DEFENSE: Buf=%d Risk=%.2f%%", g_adaptive_buffer, g_adaptive_risk); }
   else if(g_loss_defense_active && dt.day > g_loss_defense_day + 1){ g_loss_defense_active = false; }
   double trend_wins = (g_pnl_trend_daily>0)?1.0:0.0; double range_wins = (g_pnl_range_daily>0)?1.0:0.0; double alpha=0.3;
   if(g_trend_count_daily>0) g_trend_win_rate = (1-alpha)*g_trend_win_rate + alpha*trend_wins;
   if(g_range_count_daily>0) g_range_win_rate = (1-alpha)*g_range_win_rate + alpha*range_wins;
   if(!g_loss_defense_active){
      if(daily_pct < -1.0) { g_adaptive_buffer = (int)(BaseEntryBufferPts * Tighten_OnLoss_Pct); g_adaptive_risk = RiskPercent * Tighten_OnLoss_Pct; }
      else if(daily_pct > 1.5) { g_adaptive_buffer = (int)(BaseEntryBufferPts * Loosen_OnWin_Pct); g_adaptive_risk = RiskPercent * Loosen_OnWin_Pct; }
   }
   if(EnableDebugLog) PrintFormat("🎯 WR: TREND=%.0f%% RANGE=%.0f%% | Buf=%d Risk=%.2f%%", g_trend_win_rate*100.0, g_range_win_rate*100.0, g_adaptive_buffer, g_adaptive_risk);
   g_pnl_trend_daily=0.0; g_pnl_range_daily=0.0; g_trend_count_daily=0; g_range_count_daily=0; g_session_sl_count=0; ResetLogCounters(); lastDay=dt.day;
}

int OnInit(){
   hATR=iATR(_Symbol,InpTF,ATR_Period); hADX=iADX(_Symbol,InpTF,ADX_Period);
   hEMA_Fast=iMA(_Symbol,InpTF,EMA_FastPeriod,0,MODE_EMA,PRICE_CLOSE);
   hEMA_Slow=iMA(_Symbol,InpTF,EMA_SlowPeriod,0,MODE_EMA,PRICE_CLOSE);
   if(hATR==INVALID_HANDLE||hADX==INVALID_HANDLE||hEMA_Fast==INVALID_HANDLE||hEMA_Slow==INVALID_HANDLE) return INIT_FAILED;
   g_fill=ResolveFilling(); g_adaptive_buffer=BaseEntryBufferPts; g_adaptive_risk=RiskPercent; g_adaptive_sl_ratio=MinSL_to_Spread_Ratio;
   g_hist_last_sync = TimeCurrent()-86400*30;
   Print("=== v8.6 NO-BROKER-SPAM: Persistent cancel flag + One-time clear ===");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason){
   if(hATR!=INVALID_HANDLE) IndicatorRelease(hATR);
   if(hADX!=INVALID_HANDLE) IndicatorRelease(hADX);
   if(hEMA_Fast!=INVALID_HANDLE) IndicatorRelease(hEMA_Fast);
   if(hEMA_Slow!=INVALID_HANDLE) IndicatorRelease(hEMA_Slow);
}

void OnTick()
{
   if(AccountInfoDouble(ACCOUNT_BALANCE)<MinBalanceUSD){ CancelAllMagicPendings(); return; }

   bool market_open_now = IsMarketTradeableNow();

   // NEW: One-time cancel per market-close transition, then block further attempts
   if(!market_open_now && g_market_was_open){
      if(!g_cancel_attempted_this_close){
         PrintLogOnce("MARKET_CLOSED_EVENT", "🔴 Market closed: clearing pendings once.");
         CancelAllMagicPendings();
         g_cancel_attempted_this_close = true;
      }
   }
   
   if(market_open_now && !g_market_was_open){
      PrintLogOnce("MARKET_REOPEN_EVENT", "🟢 Market tradeable: ready to re-arm.");
      g_cancel_attempted_this_close = false;
   }
   g_market_was_open = market_open_now;

   if(!market_open_now) return;

   static datetime lastBar=0; datetime curBar=iTime(_Symbol,InpTF,0); bool newBar=(curBar!=lastBar);
   if(newBar){ lastBar=curBar; g_lastBar_Index++; g_armedThisBar=false; g_abortedThisBar=false; UpdateDailyLearning(); }

   Ledger_SyncOpenPositions();
   Ledger_HarvestClosedPnL();
   UpdateIntraDayDefense();

   if(!IsAsiaLondonSessionOK()) return;
   double spread = GetSpreadPts();
   if(spread > MaxSpreadPts) { PrintLogOnce("SPREAD_EXCEEDED", StringFormat("Spread %.0f > limit %.0f → skip", spread, MaxSpreadPts)); return; }

   double atr=0.0, adx=0.0; if(!GetATR(atr)||!GetADX(adx)) return;
   double ema_f=0.0, ema_s=0.0; if(!GetEMAs(ema_f,ema_s)) return;

   Regime newRegime = DetectRegime(adx,ema_f,ema_s);
   if(newRegime != g_regime){ g_regime = newRegime; g_regime_switch_bar = g_lastBar_Index; }
   SetParamsByRegime(g_regime, atr, adx);

   if(newBar && EnableDebugLog) PrintFormat("📊 Regime=%s | ADX=%.1f | ATR=%.2f | Risk=%.2f%% | Spread=%.1f", g_params.name, adx, atr, g_adaptive_risk, spread);

   if(EntryMode==OCO_Stops){
      int posCount=CountPositionsByMagic(-1), ordCount=CountOrdersByMagic(-1);
      if(g_cooloff_EndBar>=0 && g_lastBar_Index<=g_cooloff_EndBar){ DeleteOppositePendingIfOneTriggered(); return; }
      if(g_cooloff_EndBar>=0) g_cooloff_EndBar=-1;

      if(ordCount > 0 && g_regime == REG_TREND && g_params.use_oco){
         double hi,lo;
         if(ComputeBands(hi,lo)){
            double buffer_pts = CalcATRBuffer_Pts(atr, adx);
            double newBuyPrice=hi+buffer_pts*_Point, newSellPrice=lo-buffer_pts*_Point;
            if(ShouldRefreshOCO_Adaptive(newBuyPrice, newSellPrice, adx)){
               int cancelled = CancelAllMagicPendings();
               if(cancelled > 0){
                  if(EnableDebugLog) PrintFormat("🔄 OCO REFRESH: Cancelled %d old orders, re-placing new OCO", cancelled);
                  ordCount = 0;
               }
            }
         }
      }

      if(posCount==0 && ordCount==0 && !g_armedThisBar && CanRearmThisHour()){
         double slPts=MathMax(g_params.atr_multiplier*atr/_Point, 40.0);
         double lots=CalcRiskLots(slPts,g_params.risk_pct);
         if(lots>0.0){
            if(g_params.use_oco){ if(PlaceOCO_Atomic(atr,lots,spread,adx,ema_f,ema_s)) g_armedThisBar=true; }
            else { if(PlaceRangeReversion(atr,spread,ema_f,ema_s, adx)) g_armedThisBar=true; }
         }
      }
      DeleteOppositePendingIfOneTriggered();
   }

   g_prev_adx = adx;
}
