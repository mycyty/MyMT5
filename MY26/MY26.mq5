//+------------------------------------------------------------------+
//|                                                         MY26.mq5 |
//|                                                                  |
//|                                                                  |
//+------------------------------------------------------------------+
#include <Trade/Trade.mqh>

#property copyright ""
#property link      ""
#property version   "1.00"

input string InpSymbol            = "XAUUSDm";
input long   InpMagicNumber       = 26026;
input double InpAtrMin            = 2.0;
input int    InpMaFastPeriod      = 60;
input int    InpMaSlowPeriod      = 250;
input int    InpMaTrendBars       = 5;        // 5 根已收盘K线单调上升/下降
input double InpSlAtrMult         = 16.0;     // 止损距离 = 该系数 × ATR(shift=1 已收盘)
input double InpTpAtrMult         = 0.5;      // 止盈距离 = 该系数 × ATR(shift=1 已收盘)
input double InpAoExtremeLong     = -1.0;
input double InpAoExtremeShort    = 1.0;

//--- 邮件通知（默认关闭，不改变交易逻辑；收件人实际以终端「工具→选项→邮件」为准）
input bool   InpEmailEnable       = false;                   // 启用邮件
input string InpEmailAddress      = "mycyty2@163.com";       // 备注用收件邮箱（SendMail 仍走终端配置）
input bool   InpEmailPriceNotify  = false;                   // 价格跨区间通知（每 tick，与 InpSymbol 一致）

static const ENUM_TIMEFRAMES Tf = PERIOD_M1;

// 挂单与现价最小距离（价格差，非 points）
const double PENDING_DISTANCE = 2000.0;

// 邮件子选项（源码常量，非输入参数）
const bool   g_EmailNotifyOpen        = true;    // 开仓成交通知
const bool   g_EmailNotifyClose       = true;    // 平仓成交通知
const bool   g_EmailNotifyModify      = false;   // 修改/对冲类成交（INOUT）
const bool   InpEmailPriceNotify       = false;   // 价格跨区间通知（每 tick，与 InpSymbol 一致）
const int    g_EmailPriceIntervalMin  = 5;      // 价格邮件最小间隔（分钟）
const double g_EmailPriceStep         = 5.0;    // 价格区间步长

// 无挂单时: 0=不交易, 1=仅允许多, -1=仅允许空（量化测试）
const int g_InpNoPendingDirection = 1;

// true：开仓要求快线在最近 InpMaTrendBars 根已收盘K上方向单调；false：不检查快线单调，仅慢线单调仍参与
bool g_RequireFastMaMonotonic = false;

CTrade trade;

int maFastHandle = INVALID_HANDLE;
int maSlowHandle = INVALID_HANDLE;
int atrHandle    = INVALID_HANDLE;
int aoHandle     = INVALID_HANDLE;

datetime lastBarTime = 0;

// 邮件：去重与价格区间状态（仅 InpEmailEnable 时使用）
datetime mailLastDealTime           = 0;
datetime mailLastPriceNotifyTime    = 0;
int      mailPriceLevel             = 0;
bool     mailPriceMonitorInitialized = false;

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
     {
      if(g_InpNoPendingDirection == 0)
         return false;
      double minLot = SymbolInfoDouble(InpSymbol, SYMBOL_VOLUME_MIN);
      if(minLot <= 0.0)
         return false;
      if(g_InpNoPendingDirection == 1)
        {
         allowLong = true;
         lotsLong = minLot;
        }
      else
         if(g_InpNoPendingDirection == -1)
           {
            allowShort = true;
            lotsShort = minLot;
           }
         else
            return false;
      return true;
     }

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
         if(price < (refLong - PENDING_DISTANCE))
            lotsLong += vol;
        }
      else
         if(isSellPending)
           {
            if(price > (refShort + PENDING_DISTANCE))
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
//| 邮件：仅通知本 EA 魔术号 + InpSymbol 的成交（与 TradeMailNotification 同源逻辑） |
//+------------------------------------------------------------------+
void MailNotif_SendTrade(ulong dealTicket, const string action, ENUM_DEAL_TYPE dealType, datetime dealTime)
  {
   string symbol = HistoryDealGetString(dealTicket, DEAL_SYMBOL);
   double volume = HistoryDealGetDouble(dealTicket, DEAL_VOLUME);
   double price = HistoryDealGetDouble(dealTicket, DEAL_PRICE);

   string dealTypeStr = "";
   switch(dealType)
     {
      case DEAL_TYPE_BUY:
         dealTypeStr = "买入";
         break;
      case DEAL_TYPE_SELL:
         dealTypeStr = "卖出";
         break;
      case DEAL_TYPE_BALANCE:
         dealTypeStr = "余额";
         break;
      case DEAL_TYPE_CREDIT:
         dealTypeStr = "信用";
         break;
      case DEAL_TYPE_CHARGE:
         dealTypeStr = "费用";
         break;
      case DEAL_TYPE_CORRECTION:
         dealTypeStr = "修正";
         break;
      case DEAL_TYPE_BONUS:
         dealTypeStr = "奖金";
         break;
      case DEAL_TYPE_COMMISSION:
         dealTypeStr = "佣金";
         break;
      case DEAL_TYPE_COMMISSION_DAILY:
         dealTypeStr = "每日佣金";
         break;
      case DEAL_TYPE_COMMISSION_MONTHLY:
         dealTypeStr = "每月佣金";
         break;
      case DEAL_TYPE_COMMISSION_AGENT_DAILY:
         dealTypeStr = "代理每日佣金";
         break;
      case DEAL_TYPE_COMMISSION_AGENT_MONTHLY:
         dealTypeStr = "代理每月佣金";
         break;
      case DEAL_TYPE_INTEREST:
         dealTypeStr = "利息";
         break;
      case DEAL_TYPE_BUY_CANCELED:
         dealTypeStr = "买入取消";
         break;
      case DEAL_TYPE_SELL_CANCELED:
         dealTypeStr = "卖出取消";
         break;
      default:
         dealTypeStr = "未知类型";
     }

   string timeStr = TimeToString(dealTime, TIME_DATE | TIME_SECONDS);
   string subject = StringFormat("黄金成交%.2f手 价格%d", volume, (int)price);
   string body = StringFormat(
                    "MY26 交易通知\n\n" +
                    "账户: %s\n" +
                    "品种: %s\n" +
                    "动作: %s\n" +
                    "类型: %s\n" +
                    "时间: %s\n" +
                    "手数: %.2f\n" +
                    "价格: %.5f\n" +
                    "成交号: %I64u\n\n" +
                    "---\n" +
                    "由 MY26 EA 发送",
                    AccountInfoString(ACCOUNT_NAME),
                    symbol,
                    action,
                    dealTypeStr,
                    timeStr,
                    volume,
                    price,
                    dealTicket
                 );

   if(SendMail(subject, body))
      Print("MY26 邮件已发送: ", subject);
   else
     {
      Print("MY26 邮件发送失败, err=", GetLastError(), " 请检查终端邮件设置");
     }
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void MailNotif_ProcessDeals()
  {
   if(!InpEmailEnable)
      return;

   datetime currentTime = TimeCurrent();
   if(!HistorySelect(0, currentTime))
      return;

   int totalDeals = HistoryDealsTotal();
   if(totalDeals <= 0)
      return;

// History 按时间升序：从旧到新遍历，避免同一批多笔成交时漏通知
   datetime maxSeen = mailLastDealTime;

   for(int i = 0; i < totalDeals; i++)
     {
      ulong dealTicket = HistoryDealGetTicket(i);
      if(dealTicket == 0)
         continue;

      datetime dealTime = (datetime)HistoryDealGetInteger(dealTicket, DEAL_TIME);
      if(dealTime <= mailLastDealTime)
         continue;

      long dealMagic = HistoryDealGetInteger(dealTicket, DEAL_MAGIC);
      if(dealMagic != InpMagicNumber)
         continue;

      if(HistoryDealGetString(dealTicket, DEAL_SYMBOL) != InpSymbol)
         continue;

      ENUM_DEAL_TYPE dealType = (ENUM_DEAL_TYPE)HistoryDealGetInteger(dealTicket, DEAL_TYPE);
      ENUM_DEAL_ENTRY dealEntry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(dealTicket, DEAL_ENTRY);

      bool want = (g_EmailNotifyOpen && dealEntry == DEAL_ENTRY_IN) ||
                  (g_EmailNotifyClose && dealEntry == DEAL_ENTRY_OUT) ||
                  (g_EmailNotifyModify && dealEntry == DEAL_ENTRY_INOUT);
      if(!want)
         continue;

      if(dealEntry == DEAL_ENTRY_IN)
         MailNotif_SendTrade(dealTicket, "开仓(IN)", dealType, dealTime);
      else
         if(dealEntry == DEAL_ENTRY_OUT)
            MailNotif_SendTrade(dealTicket, "平仓(OUT)", dealType, dealTime);
         else
            MailNotif_SendTrade(dealTicket, "INOUT", dealType, dealTime);

      if(dealTime > maxSeen)
         maxSeen = dealTime;
     }

   if(maxSeen > mailLastDealTime)
      mailLastDealTime = maxSeen;
  }

//+------------------------------------------------------------------+
//| 初始化邮件去重时间：避免加载 EA 时对历史成交批量发信              |
//+------------------------------------------------------------------+
void MailNotif_SeedLastDealTime()
  {
   mailLastDealTime = 0;
   if(!HistorySelect(0, TimeCurrent()))
      return;

   int n = HistoryDealsTotal();
   datetime maxT = 0;
   for(int i = 0; i < n; i++)
     {
      ulong t = HistoryDealGetTicket(i);
      if(t == 0)
         continue;
      if(HistoryDealGetInteger(t, DEAL_MAGIC) != InpMagicNumber)
         continue;
      if(HistoryDealGetString(t, DEAL_SYMBOL) != InpSymbol)
         continue;
      datetime dt = (datetime)HistoryDealGetInteger(t, DEAL_TIME);
      if(dt > maxT)
         maxT = dt;
     }
   mailLastDealTime = maxT;
  }

//+------------------------------------------------------------------+
//| 价格跨区间邮件（使用 InpSymbol 的 BID）                          |
//+------------------------------------------------------------------+
void MailNotif_SendPriceInterval(double currentPrice, double oldLevelPrice, double newLevelPrice,
                                 const string direction, datetime notifyTime)
  {
   string timeStr = TimeToString(notifyTime, TIME_DATE | TIME_SECONDS);
   string subject = StringFormat("黄金价格%d", (int)currentPrice);

   double priceChange = currentPrice - oldLevelPrice;
   double priceChangePercent = 0.0;
   if(oldLevelPrice > 0.0)
      priceChangePercent = (priceChange / oldLevelPrice) * 100.0;

   string body = StringFormat(
                    "MY26 价格区间变化\n\n" +
                    "账户: %s\n" +
                    "品种: %s\n" +
                    "方向: %s\n" +
                    "时间: %s\n\n" +
                    "当前价: %.5f\n" +
                    "原区间参考: %.5f\n" +
                    "新区间参考: %.5f\n" +
                    "变化: %.5f (%.2f%%)\n\n" +
                    "区间步长: %.5f\n" +
                    "最小间隔: %d 分钟\n\n" +
                    "---\n由 MY26 EA 发送",
                    AccountInfoString(ACCOUNT_NAME),
                    InpSymbol,
                    direction,
                    timeStr,
                    currentPrice,
                    oldLevelPrice,
                    newLevelPrice,
                    priceChange,
                    priceChangePercent,
                    g_EmailPriceStep,
                    g_EmailPriceIntervalMin
                 );

   if(!SendMail(subject, body))
      Print("MY26 价格邮件失败, err=", GetLastError());
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void MailNotif_CheckPriceInterval()
  {
   if(!InpEmailEnable || !InpEmailPriceNotify)
      return;

   double step = g_EmailPriceStep;
   if(step <= 0.0)
      return;

   double currentPrice = SymbolInfoDouble(InpSymbol, SYMBOL_BID);
   if(currentPrice <= 0.0)
      return;

   int newLevel = (int)MathFloor(currentPrice / step);

   if(!mailPriceMonitorInitialized)
     {
      mailPriceLevel = newLevel;
      mailPriceMonitorInitialized = true;
      Print("MY26 价格邮件监控已初始化: ", InpSymbol, " 价=", currentPrice, " 级别=", mailPriceLevel);
      return;
     }

   if(newLevel == mailPriceLevel)
      return;

   datetime now = TimeCurrent();
   int minSec = g_EmailPriceIntervalMin * 60;
   int elapsed = (int)(now - mailLastPriceNotifyTime);

   double oldRef = mailPriceLevel * step;
   double newRef = newLevel * step;

   if(elapsed >= minSec || mailLastPriceNotifyTime == 0)
     {
      string dir = (newLevel > mailPriceLevel) ? "上涨" : "下跌";
      MailNotif_SendPriceInterval(currentPrice, oldRef, newRef, dir, now);
      mailPriceLevel = newLevel;
      mailLastPriceNotifyTime = now;
     }
   else
     {
      mailPriceLevel = newLevel;
     }
  }

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
  {
   if(!IsTargetSymbol())
      return(INIT_FAILED);

   if(InpEmailEnable)
     {
      int lenAddr = StringLen(InpEmailAddress);
      if(lenAddr > 0 && StringFind(InpEmailAddress, "@") < 0)
        {
         Alert("MY26: 备注邮箱格式无效（含 @）");
         return(INIT_PARAMETERS_INCORRECT);
        }
      if(!TerminalInfoInteger(TERMINAL_EMAIL_ENABLED))
         Alert("MY26: 终端邮件未启用，请在 工具->选项->邮件 中配置 SMTP 与收件邮箱");
     }

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

   mailLastPriceNotifyTime = 0;
   mailPriceLevel = 0;
   mailPriceMonitorInitialized = false;
   if(InpEmailEnable)
      MailNotif_SeedLastDealTime();
   else
      mailLastDealTime = 0;

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

// 价格区间邮件需每 tick 检查；交易逻辑仍在下方 IsNewBarM1 门控内
   MailNotif_CheckPriceInterval();

   if(!IsNewBarM1())
      return;

   SyncTracked();

// 挂单门控（无挂单时可通过 g_InpNoPendingDirection 强制单侧测试）
   double lotsLong = 0.0, lotsShort = 0.0;
   bool allowLong = false, allowShort = false;
   if(!PendingGate(lotsLong, lotsShort, allowLong, allowShort))
      return;

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

// MA 趋势（最近 5 根已收盘：shift 1..trendBars）；快线单调由 g_RequireFastMaMonotonic 控制
   bool slowUp = IsMonotonicUp(maSlow, 1, InpMaTrendBars);
   bool slowDown = IsMonotonicDown(maSlow, 1, InpMaTrendBars);
   bool fastUp = IsMonotonicUp(maFast, 1, InpMaTrendBars);
   bool fastDown = IsMonotonicDown(maFast, 1, InpMaTrendBars);
   bool maUp = slowUp && (g_RequireFastMaMonotonic ? fastUp : true);
   bool maDown = slowDown && (g_RequireFastMaMonotonic ? fastDown : true);

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
      double tp = NormalizePrice(entry + InpTpAtrMult * atrVal);
      double sl = NormalizePrice(entry - InpSlAtrMult * atrVal);
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
      double tp = NormalizePrice(entry - InpTpAtrMult * atrVal);
      double sl = NormalizePrice(entry + InpSlAtrMult * atrVal);
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
   MailNotif_ProcessDeals();
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
