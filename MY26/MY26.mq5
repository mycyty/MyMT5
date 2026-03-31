//+------------------------------------------------------------------+
//|                                                         MY26.mq5 |
//|                                                                  |
//|                                                                  |
//+------------------------------------------------------------------+
#include <Trade/Trade.mqh>

#property copyright ""
#property link      ""
#property version   "1.00"

input string InpSymbol            = "XAUUSD";
input long   InpMagicNumber       = 26026;
input double InpAtrMin            = 1.0;
input int    InpMaFastPeriod      = 60;
input int    InpMaSlowPeriod      = 250;
input int    InpMaTrendBars       = 5;        // 5 根已收盘K线单调上升/下降
input double InpPendingDistance   = 2000.0;   // 价格差（非 points）
input double InpMaSlOffset        = 10.0;     // 价格差（非 points）
input double InpAoExtremeLong     = -1.0;
input double InpAoExtremeShort    = 1.0;

static const ENUM_TIMEFRAMES Tf = PERIOD_M1;

CTrade trade;

int maFastHandle = INVALID_HANDLE;
int maSlowHandle = INVALID_HANDLE;
int atrHandle    = INVALID_HANDLE;
int aoHandle     = INVALID_HANDLE;

datetime lastBarTime = 0;

ulong longTickets[];
ulong shortTickets[];

ENUM_ORDER_TYPE_FILLING fillingType = ORDER_FILLING_RETURN;

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool IsTargetSymbol()
  {
   return (Symbol() == InpSymbol);
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
ENUM_ORDER_TYPE_FILLING DetectFillingType()
  {
   long mode = 0;
   if(!SymbolInfoInteger(InpSymbol, SYMBOL_FILLING_MODE, mode))
      return ORDER_FILLING_RETURN;

   if(mode == SYMBOL_FILLING_FOK)
      return ORDER_FILLING_FOK;
   if(mode == SYMBOL_FILLING_IOC)
      return ORDER_FILLING_IOC;
   return ORDER_FILLING_RETURN;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
double NormalizePrice(double price)
  {
   int digits = (int)SymbolInfoInteger(InpSymbol, SYMBOL_DIGITS);
   return NormalizeDouble(price, digits);
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool IsNewBarM1()
  {
   datetime t = iTime(InpSymbol, Tf, 0);
   if(t == 0)
      return false;
   if(t != lastBarTime)
     {
      lastBarTime = t;
      return true;
     }
   return false;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
double NormalizeVolume(double vol)
  {
   double vmin  = SymbolInfoDouble(InpSymbol, SYMBOL_VOLUME_MIN);
   double vmax  = SymbolInfoDouble(InpSymbol, SYMBOL_VOLUME_MAX);
   double vstep = SymbolInfoDouble(InpSymbol, SYMBOL_VOLUME_STEP);

   if(vol < vmin)
      return 0.0;
   if(vol > vmax)
      vol = vmax;

   if(vstep > 0.0)
      vol = MathFloor(vol / vstep) * vstep;

   int volDigits = (int)MathRound(-MathLog10(vstep));
   if(volDigits < 0)
      volDigits = 2;
   return NormalizeDouble(vol, volDigits);
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool Copy1(int handle, int startShift, int count, double &out[])
  {
   ArraySetAsSeries(out, true);
   int copied = CopyBuffer(handle, 0, startShift, count, out);
   return (copied == count);
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool IsMonotonicUp(const double &series[], int startShift, int bars)
  {
// series is Series array (0 newest). Use closed bars: startShift..startShift+bars-1
   for(int s = startShift; s < startShift + bars - 1; s++)
     {
      if(!(series[s] > series[s + 1]))
         return false;
     }
   return true;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool IsMonotonicDown(const double &series[], int startShift, int bars)
  {
   for(int s = startShift; s < startShift + bars - 1; s++)
     {
      if(!(series[s] < series[s + 1]))
         return false;
     }
   return true;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool IsAoGreen(const double &ao[], int shift)
  {
// 绿色：AO[i] > AO[i+1]，仅比较已收盘柱（避免用到 shift=0）
   return (ao[shift] > ao[shift + 1]);
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool HasOurPosition(ENUM_POSITION_TYPE type)
  {
   int total = PositionsTotal();
   for(int i = 0; i < total; i++)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(!PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != InpSymbol)
         continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
         continue;
      ENUM_POSITION_TYPE t = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      if(t == type)
         return true;
     }
   return false;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void SyncTracked()
  {
// 删除不再存在的票据（只针对本 EA 魔术号）
   int longCount = ArraySize(longTickets);
   for(int i = longCount - 1; i >= 0; i--)
     {
      ulong ticket = longTickets[i];
      if(!PositionSelectByTicket(ticket))
        {
         ArrayRemove(longTickets, i, 1);
         continue;
        }
      if(PositionGetString(POSITION_SYMBOL) != InpSymbol || (long)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
         ArrayRemove(longTickets, i, 1);
     }

   int shortCount = ArraySize(shortTickets);
   for(int j = shortCount - 1; j >= 0; j--)
     {
      ulong ticket = shortTickets[j];
      if(!PositionSelectByTicket(ticket))
        {
         ArrayRemove(shortTickets, j, 1);
         continue;
        }
      if(PositionGetString(POSITION_SYMBOL) != InpSymbol || (long)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
         ArrayRemove(shortTickets, j, 1);
     }
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool HasTrackedDirection(ENUM_POSITION_TYPE type)
  {
   SyncTracked();
   if(type == POSITION_TYPE_BUY)
      return (ArraySize(longTickets) > 0);
   return (ArraySize(shortTickets) > 0);
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool PendingGate(double &lotsLong, double &lotsShort, bool &allowLong, bool &allowShort)
  {
   lotsLong = 0.0;
   lotsShort = 0.0;
   allowLong = false;
   allowShort = false;

   int total = OrdersTotal();
   if(total <= 0)
      return false; // 没有任何挂单：完全不交易

   double bid = SymbolInfoDouble(InpSymbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(InpSymbol, SYMBOL_ASK);
   if(bid <= 0 || ask <= 0)
      return false;

   double refLong = ask;
   double refShort = bid;

   for(int i = 0; i < total; i++)
     {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0)
         continue;
      if(!OrderSelect(ticket))
         continue;
      if(OrderGetString(ORDER_SYMBOL) != InpSymbol)
         continue;

      ENUM_ORDER_TYPE type = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      double price = OrderGetDouble(ORDER_PRICE_OPEN);
      double vol = OrderGetDouble(ORDER_VOLUME_CURRENT);

      bool isBuyPending =
         (type == ORDER_TYPE_BUY_LIMIT || type == ORDER_TYPE_BUY_STOP || type == ORDER_TYPE_BUY_STOP_LIMIT);
      bool isSellPending =
         (type == ORDER_TYPE_SELL_LIMIT || type == ORDER_TYPE_SELL_STOP || type == ORDER_TYPE_SELL_STOP_LIMIT);

      if(isBuyPending)
        {
         if(price < (refLong - InpPendingDistance))
            lotsLong += vol;
        }
      else
         if(isSellPending)
           {
            if(price > (refShort + InpPendingDistance))
               lotsShort += vol;
           }
     }

   if(lotsLong > 0.0)
      allowLong = true;
   if(lotsShort > 0.0)
      allowShort = true;

   return true; // 有挂单（无论是否满足两侧距离条件）
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool OpenBuy(double vol, double tp, double sl)
  {
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetTypeFilling(fillingType);
   bool ok = trade.Buy(vol, InpSymbol, 0.0, NormalizePrice(sl), NormalizePrice(tp), "MY26 buy");
   if(!ok)
      return false;

// 记录最新持仓票据（用 identifier/ticket 对齐更稳）
// 尝试从当前持仓中找出本 EA 最新的 BUY 票据
   ulong newest = 0;
   datetime newestTime = 0;
   int total = PositionsTotal();
   for(int i = 0; i < total; i++)
     {
      ulong pt = PositionGetTicket(i);
      if(pt == 0)
         continue;
      if(!PositionSelectByTicket(pt))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != InpSymbol)
         continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
         continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != POSITION_TYPE_BUY)
         continue;
      datetime t = (datetime)PositionGetInteger(POSITION_TIME);
      if(t >= newestTime)
        {
         newestTime = t;
         newest = pt;
        }
     }
   if(newest != 0)
     {
      int n = ArraySize(longTickets);
      ArrayResize(longTickets, n + 1);
      longTickets[n] = newest;
     }
   return true;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool OpenSell(double vol, double tp, double sl)
  {
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetTypeFilling(fillingType);
   bool ok = trade.Sell(vol, InpSymbol, 0.0, NormalizePrice(sl), NormalizePrice(tp), "MY26 sell");
   if(!ok)
      return false;

   ulong newest = 0;
   datetime newestTime = 0;
   int total = PositionsTotal();
   for(int i = 0; i < total; i++)
     {
      ulong pt = PositionGetTicket(i);
      if(pt == 0)
         continue;
      if(!PositionSelectByTicket(pt))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != InpSymbol)
         continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
         continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != POSITION_TYPE_SELL)
         continue;
      datetime t = (datetime)PositionGetInteger(POSITION_TIME);
      if(t >= newestTime)
        {
         newestTime = t;
         newest = pt;
        }
     }
   if(newest != 0)
     {
      int n = ArraySize(shortTickets);
      ArrayResize(shortTickets, n + 1);
      shortTickets[n] = newest;
     }
   return true;
  }

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
  {
   if(!IsTargetSymbol())
      return(INIT_FAILED);

   trade.SetExpertMagicNumber(InpMagicNumber);
   fillingType = DetectFillingType();

   maFastHandle = iMA(InpSymbol, Tf, InpMaFastPeriod, 0, MODE_LWMA, PRICE_CLOSE);
   maSlowHandle = iMA(InpSymbol, Tf, InpMaSlowPeriod, 0, MODE_LWMA, PRICE_CLOSE);
   atrHandle = iATR(InpSymbol, Tf, 5);
   aoHandle = iAO(InpSymbol, Tf);

   if(maFastHandle == INVALID_HANDLE || maSlowHandle == INVALID_HANDLE || atrHandle == INVALID_HANDLE || aoHandle == INVALID_HANDLE)
      return(INIT_FAILED);

   ArrayResize(longTickets, 0);
   ArrayResize(shortTickets, 0);
   lastBarTime = 0;

   return(INIT_SUCCEEDED);
  }
//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(maFastHandle != INVALID_HANDLE)
      IndicatorRelease(maFastHandle);
   if(maSlowHandle != INVALID_HANDLE)
      IndicatorRelease(maSlowHandle);
   if(atrHandle != INVALID_HANDLE)
      IndicatorRelease(atrHandle);
   if(aoHandle != INVALID_HANDLE)
      IndicatorRelease(aoHandle);
  }
//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
  {
   if(!IsTargetSymbol())
      return;
   if(!IsNewBarM1())
      return;

   SyncTracked();

// 挂单门控
   double lotsLong = 0.0, lotsShort = 0.0;
   bool allowLong = false, allowShort = false;
   bool hasAnyPending = PendingGate(lotsLong, lotsShort, allowLong, allowShort);
   if(!hasAnyPending)
      return; // 无挂单：完全不交易

// 两侧同时满足或两侧都不满足：不交易
   if((allowLong && allowShort) || (!allowLong && !allowShort))
      return;

// 指标取值：至少需要到 shift= (1 + trendBars) 与 AO shift+3
   int need = MathMax(InpMaTrendBars + 2, 8);
   double maFast[], maSlow[], atr[], ao[];
   if(!Copy1(maFastHandle, 0, need, maFast))
      return;
   if(!Copy1(maSlowHandle, 0, need, maSlow))
      return;
   if(!Copy1(atrHandle, 0, need, atr))
      return;
   if(!Copy1(aoHandle, 0, need, ao))
      return;

// ATR 过滤（用最近已收盘柱 shift=1）
   double atrVal = atr[1];
   if(atrVal < InpAtrMin)
      return;

// MA 趋势（最近 5 根已收盘：shift 1..trendBars）
   bool maUp = IsMonotonicUp(maFast, 1, InpMaTrendBars) && IsMonotonicUp(maSlow, 1, InpMaTrendBars);
   bool maDown = IsMonotonicDown(maFast, 1, InpMaTrendBars) && IsMonotonicDown(maSlow, 1, InpMaTrendBars);

   bool maBull = (maFast[1] > maSlow[1]) && maUp;
   bool maBear = (maFast[1] < maSlow[1]) && maDown;

// AO 变色判定：在已收盘柱 shift=1 上发生颜色切换
// 绿色：AO[shift] > AO[shift+1]；红色反之
   bool aoGreen1 = IsAoGreen(ao, 1);
   bool aoGreen2 = IsAoGreen(ao, 2);
   bool aoRed1 = !aoGreen1;
   bool aoRed2 = !aoGreen2;

   bool longTrigger = (ao[1] < 0.0) && aoGreen1 && aoRed2;
   bool shortTrigger = (ao[1] > 0.0) && aoRed1 && aoGreen2;

// AO 极值（语义：变色柱往前数第二根已收盘柱）
// 在 Series 下，往“更旧”方向是 +，因此用 shift=3（相对变色柱 shift=1 往前两根）
   double aoExtreme = ao[3];

// 同向只开一笔（仅看本 EA 的持仓）
   bool hasBuy = HasOurPosition(POSITION_TYPE_BUY) || HasTrackedDirection(POSITION_TYPE_BUY);
   bool hasSell = HasOurPosition(POSITION_TYPE_SELL) || HasTrackedDirection(POSITION_TYPE_SELL);

   double ask = SymbolInfoDouble(InpSymbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(InpSymbol, SYMBOL_BID);
   if(ask <= 0 || bid <= 0)
      return;

   if(allowLong && !hasBuy && maBull && longTrigger && (aoExtreme < InpAoExtremeLong))
     {
      double vol = NormalizeVolume(lotsLong);
      if(vol <= 0.0)
         return;

      double entry = ask;
      double tp = NormalizePrice(entry + atrVal / 2.0);
      double sl = NormalizePrice(maSlow[1] - InpMaSlOffset);
      if(!(sl < entry && tp > entry))
         return;
      OpenBuy(vol, tp, sl);
      return;
     }

   if(allowShort && !hasSell && maBear && shortTrigger && (aoExtreme > InpAoExtremeShort))
     {
      double vol = NormalizeVolume(lotsShort);
      if(vol <= 0.0)
         return;

      double entry = bid;
      double tp = NormalizePrice(entry - atrVal / 2.0);
      double sl = NormalizePrice(maSlow[1] + InpMaSlOffset);
      if(!(sl > entry && tp < entry))
         return;
      OpenSell(vol, tp, sl);
      return;
     }
  }
//+------------------------------------------------------------------+
//| Trade function                                                   |
//+------------------------------------------------------------------+
void OnTrade()
  {
   SyncTracked();
  }
//+------------------------------------------------------------------+
//| TradeTransaction function                                        |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction& trans,
                        const MqlTradeRequest& request,
                        const MqlTradeResult& result)
  {
   SyncTracked();
  }
//+------------------------------------------------------------------+
