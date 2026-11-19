//+------------------------------------------------------------------+
//|                                     SpectarDailyLossLockLite.mq5 |
//|                                       Spectar FX - free lite tool |
//|                                                                  |
//| One job only: when the daily loss limit is reached, the trading  |
//| day locks. All open positions are closed, pending orders are     |
//| deleted, and until the next daily reset any newly opened         |
//| position is closed immediately.                                  |
//|                                                                  |
//| NOTE: an Expert Advisor cannot technically block manual trading  |
//| in MetaTrader 5. While locked, this EA closes new positions and  |
//| deletes new pending orders as soon as it sees them (on the next  |
//| tick / trade event / 1-second timer).                            |
//|                                                                  |
//| No DLLs, no web requests, no external links, no hard-coded       |
//| symbols. Works on hedging and netting accounts.                  |
//+------------------------------------------------------------------+
#property copyright   "Spectar FX"
#property version     "1.02"
#property description "Spectar Daily Loss Lock (Lite)"
#property description "When your daily loss limit is reached: closes positions, deletes"
#property description "pending orders and keeps the day locked until the next daily reset"
#property description "(broker server time). Lock survives EA / terminal restart."

//--- Base value for the percentage limit and for "today's loss"
enum ENUM_SDLL_BASE
  {
   START_OF_DAY_BALANCE       = 0, // Start-of-day balance
   START_OF_DAY_EQUITY_HIGHER = 1  // Higher of start-of-day balance / equity
  };

//==================================================================
// Inputs
//==================================================================
input group "Daily loss limit"
input double         InpDailyLossLimit      = 0.0;   // Daily loss limit, money (0 = off)
input double         InpDailyLossPercent    = 3.0;   // Daily loss limit, % of base (0 = off)
input ENUM_SDLL_BASE InpBaseOn              = START_OF_DAY_BALANCE; // Base for % limit and loss
input double         InpSafetyBufferPercent = 0.10;  // Safety buffer, % of base (acts earlier)

input group "Day and calculation"
input int            InpDayResetHour        = 0;     // Day reset hour, SERVER time (0 = midnight)
input bool           InpIncludeFloating     = true;  // Include floating P/L (prop-firm style)
input bool           InpIgnoreBalanceOps    = true;  // Ignore deposits/withdrawals made today

input group "Enforcement"
input bool           InpCloseAllOnLock      = true;  // Close all open positions when lock triggers
input long           InpMagicFilter         = 0;     // Magic filter (0 = all positions, all symbols)
input int            InpSlippagePoints      = 50;    // Max slippage for closing, points
input int            InpMaxRetries          = 5;     // Close/delete retries per attempt (busy/requote)

input group "Display"
input bool           InpShowPanel           = true;  // Show on-chart panel
input bool           InpAlertOnLock         = true;  // Pop-up alert when the day locks

input group "Share card (PNG image in MQL5/Files, no account data on it)"
input bool           InpMakeCard            = true;  // Save a card when the day locks or a streak milestone is reached
input bool           InpCardButton          = true;  // Show the "Share card" button on the chart
input bool           InpCardOnStart         = false; // Make one card now, when the tool is attached

input group "Strategy Tester only (ignored on live/demo accounts)"
input bool           InpTesterDemoTrades    = true;  // Tester: open demo trades so the lock can be seen
input int            InpTesterHoldMinutes   = 240;   // Tester: close a demo trade after N minutes

//==================================================================
// Constants
//==================================================================
#define SDLL_NAME          "Spectar Daily Loss Lock (Lite)"
#define SDLL_VER           "1.02"
#define SECONDS_PER_DAY    86400
#define FRESH_WINDOW_SEC   300   // equity captured within 5 min after reset = "exact"

//==================================================================
// State (cached in memory, persisted in terminal GlobalVariables)
//==================================================================
long     g_login          = 0;     // account the state belongs to
string   g_prefix         = "";    // GlobalVariable name prefix (per account)
datetime g_dayStart       = 0;     // start of the current trading day (server time)
double   g_sodBalance     = 0.0;   // balance at start of day
double   g_sodEquity      = 0.0;   // equity (without credit) at start of day
bool     g_sodEquityKnown = false; // false = EA was not running at reset -> estimated
datetime g_lockUntil      = 0;     // locked while TimeTradeServer() < g_lockUntil
datetime g_lockTime       = 0;     // moment the lock was triggered

double   g_closedPnl      = 0.0;   // closed trading P/L today (profit+swap+commission+fee)
double   g_balanceOps     = 0.0;   // deposits(+)/withdrawals(-) today
bool     g_histDirty      = true;  // recalc history on next evaluation
bool     g_busy           = false; // re-entrancy guard for enforcement

string   g_warning        = "";    // last warning shown on the panel
int      g_streak         = 0;     // trading days in a row the tool ran and the limit was not reached
string   g_cardInfo       = "";    // last saved share card (shown on the panel)
bool     g_cardStartDone  = false; // InpCardOnStart handled
#define  SDLL_BTN_CARD    "SDLL_btn_card"
#define  SDLL_CARD_PREFIX "SDLL_card_"
#define  SDLL_SITE        "spectarfx.com"
int      g_failedPositions= 0;     // positions we could not close in last pass
int      g_failedOrders   = 0;     // orders we could not delete in last pass
datetime g_lastFailLog    = 0;     // throttle for repeated failure messages

//+------------------------------------------------------------------+
//| GlobalVariable helpers                                           |
//+------------------------------------------------------------------+
string GVName(const string key) { return g_prefix + key; }

double GVGet(const string key, const double def)
  {
   string n = GVName(key);
   if(GlobalVariableCheck(n))
      return GlobalVariableGet(n);
   return def;
  }

void GVSet(const string key, const double value)
  {
   GlobalVariableSet(GVName(key), value);
  }

//+------------------------------------------------------------------+
//| Start of the trading day that contains server time t             |
//+------------------------------------------------------------------+
datetime DayStartFor(const datetime t)
  {
   MqlDateTime s;
   TimeToStruct(t, s);
   s.hour = InpDayResetHour;
   s.min  = 0;
   s.sec  = 0;
   datetime ds = StructToTime(s);
   if(t < ds)
      ds -= SECONDS_PER_DAY;
   return ds;
  }

//+------------------------------------------------------------------+
//| Equity without broker credit (credit is not trader's money)      |
//+------------------------------------------------------------------+
double EquityNoCredit()
  {
   return AccountInfoDouble(ACCOUNT_EQUITY) - AccountInfoDouble(ACCOUNT_CREDIT);
  }

//+------------------------------------------------------------------+
//| Sum today's deals (account-wide, all symbols, all magics).       |
//| Trading P/L = profit + swap + commission + fee of all non-balance |
//| deals. Balance operations (deposit/withdrawal/bonus) kept apart. |
//| Credit deals are ignored (credit is removed from equity anyway). |
//+------------------------------------------------------------------+
bool CalcTodayHistory(const datetime from, double &pnl, double &balOps, int &tradeDeals)
  {
   pnl = 0.0;
   balOps = 0.0;
   tradeDeals = 0;
   if(!HistorySelect(from, TimeTradeServer() + SECONDS_PER_DAY))
      return false;

   int total = HistoryDealsTotal();
   for(int i = 0; i < total; i++)
     {
      ulong tk = HistoryDealGetTicket(i);
      if(tk == 0)
         continue;
      if((datetime)HistoryDealGetInteger(tk, DEAL_TIME) < from)
         continue;

      long   type   = HistoryDealGetInteger(tk, DEAL_TYPE);
      double amount = HistoryDealGetDouble(tk, DEAL_PROFIT)
                      + HistoryDealGetDouble(tk, DEAL_SWAP)
                      + HistoryDealGetDouble(tk, DEAL_COMMISSION)
                      + HistoryDealGetDouble(tk, DEAL_FEE);

      if(type == DEAL_TYPE_BALANCE || type == DEAL_TYPE_BONUS)
         balOps += amount;
      else if(type == DEAL_TYPE_CREDIT)
         continue;
      else
        {
         pnl += amount;
         if(type == DEAL_TYPE_BUY || type == DEAL_TYPE_SELL)
            tradeDeals++;
        }
     }
   return true;
  }

//+------------------------------------------------------------------+
//| Make sure state belongs to the current account and trading day.  |
//| Returns false if the account is not ready yet.                   |
//+------------------------------------------------------------------+
bool EnsureDay()
  {
   long login = AccountInfoInteger(ACCOUNT_LOGIN);
   if(login == 0 || AccountInfoDouble(ACCOUNT_BALANCE) <= 0.0)
      return false;                       // terminal not connected / not logged in yet

   if(login != g_login)                   // first run or account switched
     {
      g_login    = login;
      g_prefix   = "SDLL_" + IntegerToString(login) + "_";
      g_dayStart = 0;
     }

   datetime now = TimeTradeServer();
   datetime ds  = DayStartFor(now);

   // Lock state is always re-read: another instance may have locked the day.
   g_lockUntil = (datetime)GVGet("lockuntil", 0);
   g_lockTime  = (datetime)GVGet("locktime", 0);

   if(ds == g_dayStart)
      return true;

   //--- New trading day (or first evaluation after start)
   bool firstRun = (g_dayStart == 0);
   if(!firstRun)
      PrintFormat("%s: new trading day started at %s (server). Start values captured.",
                  SDLL_NAME, TimeToString(ds, TIME_DATE | TIME_MINUTES));

   if((datetime)GVGet("day", 0) == ds && GlobalVariableCheck(GVName("sodbal")))
     {
      // EA restarted mid-day: reuse the values stored earlier today.
      g_sodBalance     = GVGet("sodbal", 0);
      g_sodEquity      = GVGet("sodeq", 0);
      g_sodEquityKnown = (GVGet("eqknown", 0) > 0.5);
      g_streak         = (int)GVGet("streak", 0);
     }
   else
     {
      double pnl, balOps;
      int    tradeDeals;
      if(!CalcTodayHistory(ds, pnl, balOps, tradeDeals))
         return false;                    // history not available yet, retry next second

      // Balance at reset is exact: current balance minus everything booked since reset.
      g_sodBalance = AccountInfoDouble(ACCOUNT_BALANCE) - pnl - balOps;

      // Equity at reset is only known if we are at/near the reset with no trades since,
      // or if there were no positions at all (then equity == balance).
      bool nearReset = (now - ds) <= FRESH_WINDOW_SEC && tradeDeals == 0;
      bool flatAllDay = (tradeDeals == 0 && PositionsTotal() == 0);
      if(nearReset)
        {
         g_sodEquity      = EquityNoCredit() - balOps;
         g_sodEquityKnown = true;
        }
      else if(flatAllDay)
        {
         g_sodEquity      = g_sodBalance;
         g_sodEquityKnown = true;
        }
      else
        {
         g_sodEquity      = g_sodBalance;   // unknown -> fall back to balance
         g_sodEquityKnown = false;
        }

      // Streak: the previous stored day was the last trading day (weekend gap allowed) and was not locked.
      datetime prevDay  = (datetime)GVGet("day", 0);
      datetime lockDay  = (datetime)GVGet("lastlockday", 0);
      int      streak   = (int)GVGet("streak", 0);
      if(prevDay > 0 && ds > prevDay)
        {
         bool consecutive = ((ds - prevDay) <= 4 * SECONDS_PER_DAY);
         if(lockDay == prevDay)
            streak = 0;
         else if(consecutive)
            streak++;
         else
            streak = 0;                    // the tool was not running: the streak is unknown, start again
         GVSet("streak", (double)streak);
         if(InpMakeCard && (streak == 5 || streak == 10 || streak == 20 || (streak >= 30 && streak % 30 == 0)))
            MakeCard(false, streak);
        }
      g_streak = streak;

      GVSet("day", (double)ds);
      GVSet("sodbal", g_sodBalance);
      GVSet("sodeq", g_sodEquity);
      GVSet("eqknown", g_sodEquityKnown ? 1.0 : 0.0);
      GlobalVariablesFlush();
     }

   g_dayStart  = ds;
   g_histDirty = true;
   return true;
  }

//+------------------------------------------------------------------+
//| Base value used for the % limit and for today's loss             |
//+------------------------------------------------------------------+
double BaseValue()
  {
   if(InpBaseOn == START_OF_DAY_EQUITY_HIGHER)
      return MathMax(g_sodBalance, g_sodEquity);
   return g_sodBalance;
  }

//+------------------------------------------------------------------+
//| Effective limit in money: the stricter of the active limits      |
//+------------------------------------------------------------------+
double LimitMoney(const double base)
  {
   double limit = 0.0;
   if(InpDailyLossLimit > 0.0)
      limit = InpDailyLossLimit;
   if(InpDailyLossPercent > 0.0 && base > 0.0)
     {
      double pctLimit = base * InpDailyLossPercent / 100.0;
      limit = (limit > 0.0) ? MathMin(limit, pctLimit) : pctLimit;
     }
   return limit;
  }

//+------------------------------------------------------------------+
//| Today's loss (positive = loss, negative = profit)                |
//+------------------------------------------------------------------+
double TodayLoss(const double base)
  {
   if(InpIncludeFloating)
     {
      double eq = EquityNoCredit();
      if(InpIgnoreBalanceOps)
         eq -= g_balanceOps;                // a deposit is not profit, a withdrawal is not a loss
      return base - eq;
     }
   // Closed P/L only (balance-based); balance operations are never part of g_closedPnl.
   return -g_closedPnl;
  }

bool IsLocked() { return (g_lockUntil > 0 && TimeTradeServer() < g_lockUntil); }

//+------------------------------------------------------------------+
//| Activate the lock until the next daily reset (persistent)        |
//+------------------------------------------------------------------+
void ActivateLock(const double loss, const double limit)
  {
   datetime now = TimeTradeServer();
   g_lockUntil = g_dayStart + SECONDS_PER_DAY;
   g_lockTime  = now;
   GVSet("lockuntil", (double)g_lockUntil);
   GVSet("locktime", (double)g_lockTime);
   GVSet("lastlockday", (double)g_dayStart);
   GVSet("streak", 0.0);
   g_streak = 0;
   GlobalVariablesFlush();                  // write to disk now, survive a crash

   string msg = StringFormat("%s: DAILY LOSS LIMIT REACHED (loss %.2f %s, limit %.2f). Day locked until %s server time.",
                             SDLL_NAME, loss, AccountInfoString(ACCOUNT_CURRENCY), limit,
                             TimeToString(g_lockUntil, TIME_DATE | TIME_MINUTES));
   Print(msg);
   if(InpAlertOnLock && !MQLInfoInteger(MQL_TESTER))
      Alert(msg);
   if(InpMakeCard)
      MakeCard(true, 0);
  }

//+------------------------------------------------------------------+
//| Share card: a PNG image the trader can post. No account number,  |
//| no balance, no amounts - only the fact, the date and the tool.   |
//+------------------------------------------------------------------+
void CardLabel(const string id, const string text, const int x, const int y, const int size,
               const color clr, const string font)
  {
   string name = SDLL_CARD_PREFIX + id;
   ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, size);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetString(0, name, OBJPROP_FONT, font);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetInteger(0, name, OBJPROP_BACK, false);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
   ObjectSetInteger(0, name, OBJPROP_ZORDER, 10);
  }

bool MakeCard(const bool lockedCard, const int streak)
  {
   if(MQLInfoInteger(MQL_TESTER))
      return false;                         // screenshots are not available in the Strategy Tester
   const int W = 800, H = 420;
   Comment("");
   if(ObjectFind(0, SDLL_BTN_CARD) >= 0)
      ObjectSetInteger(0, SDLL_BTN_CARD, OBJPROP_TIMEFRAMES, OBJ_NO_PERIODS);   // keep the button out of the image
   const long hadPrice = ChartGetInteger(0, CHART_SHOW_PRICE_SCALE);
   const long hadDate  = ChartGetInteger(0, CHART_SHOW_DATE_SCALE);
   ChartSetInteger(0, CHART_SHOW_PRICE_SCALE, false);                           // scales would cover the card
   ChartSetInteger(0, CHART_SHOW_DATE_SCALE, false);

   string bg = SDLL_CARD_PREFIX + "bg";
   ObjectCreate(0, bg, OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, bg, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, bg, OBJPROP_XDISTANCE, 0);
   ObjectSetInteger(0, bg, OBJPROP_YDISTANCE, 0);
   ObjectSetInteger(0, bg, OBJPROP_XSIZE, W);
   ObjectSetInteger(0, bg, OBJPROP_YSIZE, H);
   ObjectSetInteger(0, bg, OBJPROP_BGCOLOR, C'16,20,34');
   ObjectSetInteger(0, bg, OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, bg, OBJPROP_COLOR, C'212,175,55');
   ObjectSetInteger(0, bg, OBJPROP_WIDTH, 3);
   ObjectSetInteger(0, bg, OBJPROP_BACK, false);
   ObjectSetInteger(0, bg, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, bg, OBJPROP_HIDDEN, true);
   ObjectSetInteger(0, bg, OBJPROP_ZORDER, 9);

   string day = TimeToString(TimeTradeServer(), TIME_DATE);
   string head, line1, line2, kind;
   if(lockedCard)
     {
      kind  = "locked";
      head  = "DAY LOCKED";
      line1 = "My daily loss limit was reached.";
      line2 = "The day is closed until the next reset. No more trades today.";
     }
   else if(streak <= 0)
     {
      kind  = "on";
      head  = "MY LIMIT IS SET";
      line1 = "I trade with a daily loss limit.";
      line2 = "If I reach it, the day closes itself until the next reset.";
     }
   else
     {
      kind  = "streak";
      head  = IntegerToString(streak) + (streak == 1 ? " DAY" : " DAYS") + " INSIDE MY LIMIT";
      line1 = "No daily loss limit breach for " + IntegerToString(streak)
              + (streak == 1 ? " trading day." : " trading days in a row.");
      line2 = "The limit is my own number. The tool only holds me to it.";
     }
   CardLabel("tag",  "DAILY LOSS LIMIT", 40, 34, 13, C'212,175,55', "Arial Bold");
   CardLabel("head", head, 40, 84, 26, clrWhite, "Arial Black");
   CardLabel("l1",   line1, 42, 168, 16, C'225,228,238', "Arial");
   CardLabel("l2",   line2, 42, 204, 13, C'170,176,196', "Arial");
   CardLabel("day",  day + "  (broker server date)", 42, 262, 12, C'170,176,196', "Arial");
   CardLabel("foot", "Spectar Daily Loss Lock  |  free MT5 tool  |  " + SDLL_SITE, 40, 356, 14, C'212,175,55', "Arial Bold");
   CardLabel("risk", "A setting, not a promise. Trading involves risk.", 42, 386, 9, C'120,126,146', "Arial");
   ChartRedraw(0);

   string d = day;
   StringReplace(d, ".", "");
   string file = "SpectarCard_" + kind + "_" + d + ".png";
   bool ok = ChartScreenShot(0, file, W, H, ALIGN_LEFT);

   ObjectsDeleteAll(0, SDLL_CARD_PREFIX);
   ChartSetInteger(0, CHART_SHOW_PRICE_SCALE, hadPrice);
   ChartSetInteger(0, CHART_SHOW_DATE_SCALE, hadDate);
   if(ObjectFind(0, SDLL_BTN_CARD) >= 0)
      ObjectSetInteger(0, SDLL_BTN_CARD, OBJPROP_TIMEFRAMES, OBJ_ALL_PERIODS);
   ChartRedraw(0);
   if(ok)
     {
      g_cardInfo = "MQL5/Files/" + file;
      PrintFormat("%s: share card saved: %s (File -> Open Data Folder -> MQL5 -> Files)", SDLL_NAME, file);
     }
   else
      PrintFormat("%s: share card could not be saved (error %d).", SDLL_NAME, GetLastError());
   return ok;
  }

void CardButton()
  {
   if(!InpCardButton || MQLInfoInteger(MQL_TESTER))
      return;
   if(ObjectFind(0, SDLL_BTN_CARD) >= 0)
      return;
   ObjectCreate(0, SDLL_BTN_CARD, OBJ_BUTTON, 0, 0, 0);
   ObjectSetInteger(0, SDLL_BTN_CARD, OBJPROP_CORNER, CORNER_RIGHT_LOWER);
   ObjectSetInteger(0, SDLL_BTN_CARD, OBJPROP_XDISTANCE, 130);
   ObjectSetInteger(0, SDLL_BTN_CARD, OBJPROP_YDISTANCE, 40);
   ObjectSetInteger(0, SDLL_BTN_CARD, OBJPROP_XSIZE, 120);
   ObjectSetInteger(0, SDLL_BTN_CARD, OBJPROP_YSIZE, 26);
   ObjectSetInteger(0, SDLL_BTN_CARD, OBJPROP_FONTSIZE, 9);
   ObjectSetInteger(0, SDLL_BTN_CARD, OBJPROP_COLOR, clrBlack);
   ObjectSetInteger(0, SDLL_BTN_CARD, OBJPROP_BGCOLOR, C'212,175,55');
   ObjectSetString(0, SDLL_BTN_CARD, OBJPROP_TEXT, "Share card");
   ObjectSetInteger(0, SDLL_BTN_CARD, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, SDLL_BTN_CARD, OBJPROP_HIDDEN, true);
  }

//+------------------------------------------------------------------+
//| Filling mode candidates for a symbol: allowed modes first        |
//+------------------------------------------------------------------+
ENUM_ORDER_TYPE_FILLING FillingFor(const string sym, const int variant)
  {
   ENUM_ORDER_TYPE_FILLING list[3];
   int  n  = 0;
   long fm = SymbolInfoInteger(sym, SYMBOL_FILLING_MODE);
   long ex = SymbolInfoInteger(sym, SYMBOL_TRADE_EXEMODE);

   if((fm & SYMBOL_FILLING_FOK) != 0)
      list[n++] = ORDER_FILLING_FOK;
   if((fm & SYMBOL_FILLING_IOC) != 0)
      list[n++] = ORDER_FILLING_IOC;
   if(ex != SYMBOL_TRADE_EXECUTION_MARKET)
      list[n++] = ORDER_FILLING_RETURN;

   // Fallbacks (some brokers report flags inaccurately)
   ENUM_ORDER_TYPE_FILLING all[3] = {ORDER_FILLING_FOK, ORDER_FILLING_IOC, ORDER_FILLING_RETURN};
   for(int k = 0; k < 3 && n < 3; k++)
     {
      bool present = false;
      for(int j = 0; j < n; j++)
         if(list[j] == all[k])
            present = true;
      if(!present)
         list[n++] = all[k];
     }
   return list[variant % 3];
  }

//+------------------------------------------------------------------+
//| Is this trade server return code worth retrying right away?      |
//+------------------------------------------------------------------+
bool IsRetryable(const uint rc)
  {
   return (rc == TRADE_RETCODE_REQUOTE || rc == TRADE_RETCODE_PRICE_CHANGED ||
           rc == TRADE_RETCODE_PRICE_OFF || rc == TRADE_RETCODE_TIMEOUT ||
           rc == TRADE_RETCODE_CONNECTION || rc == TRADE_RETCODE_TOO_MANY_REQUESTS ||
           rc == TRADE_RETCODE_LOCKED || rc == TRADE_RETCODE_REJECT ||
           rc == TRADE_RETCODE_ERROR || rc == TRADE_RETCODE_INVALID_PRICE ||
           rc == TRADE_RETCODE_FROZEN || rc == 0);
  }

//+------------------------------------------------------------------+
//| Close one position by ticket (hedging and netting).              |
//| Splits volume above SYMBOL_VOLUME_MAX. Returns true when gone.   |
//+------------------------------------------------------------------+
bool ClosePosition(const ulong ticket)
  {
   int fails = 0, variant = 0, guard = 0;
   while(fails < InpMaxRetries && guard < 50 && !IsStopped())
     {
      guard++;
      if(!PositionSelectByTicket(ticket))
         return true;                       // already closed (by us, SL/TP or another instance)

      string sym  = PositionGetString(POSITION_SYMBOL);
      double vol  = PositionGetDouble(POSITION_VOLUME);
      long   type = PositionGetInteger(POSITION_TYPE);
      double vmax = SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX);
      if(vmax > 0.0 && vol > vmax)
         vol = vmax;

      MqlTick tick;
      if(!SymbolInfoTick(sym, tick))
        {
         fails++;
         Sleep(200);
         continue;
        }

      MqlTradeRequest req;
      MqlTradeResult  res;
      ZeroMemory(req);
      ZeroMemory(res);
      req.action       = TRADE_ACTION_DEAL;
      req.position     = ticket;
      req.symbol       = sym;
      req.volume       = vol;
      req.type         = (type == POSITION_TYPE_BUY) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
      req.price        = (type == POSITION_TYPE_BUY) ? tick.bid : tick.ask;
      req.deviation    = (ulong)MathMax(InpSlippagePoints, 0);
      req.magic        = (ulong)PositionGetInteger(POSITION_MAGIC);
      req.comment      = "SDLL lock";
      req.type_filling = FillingFor(sym, variant);

      ResetLastError();
      bool sent = OrderSend(req, res);
      uint rc   = res.retcode;

      if(sent && (rc == TRADE_RETCODE_DONE || rc == TRADE_RETCODE_DONE_PARTIAL || rc == TRADE_RETCODE_PLACED))
        {
         // Partial / split close: loop again for the remaining volume.
         continue;
        }
      if(rc == TRADE_RETCODE_POSITION_CLOSED)
         return true;
      if(rc == TRADE_RETCODE_INVALID_FILL)
        {
         variant++;                          // try the next filling mode
         fails++;
         continue;
        }
      if(rc == TRADE_RETCODE_MARKET_CLOSED || rc == TRADE_RETCODE_TRADE_DISABLED ||
         rc == TRADE_RETCODE_CLIENT_DISABLES_AT || rc == TRADE_RETCODE_SERVER_DISABLES_AT)
        {
         LogFailure(StringFormat("cannot close #%I64u %s now (retcode %u) - will keep retrying every second",
                                 ticket, sym, rc));
         return false;                      // no point hammering now; timer retries
        }
      if(IsRetryable(rc))
        {
         fails++;
         Sleep(250);
         continue;
        }
      // Unexpected code: count it and retry a limited number of times.
      fails++;
      LogFailure(StringFormat("close #%I64u %s failed, retcode %u, error %d", ticket, sym, rc, GetLastError()));
      Sleep(250);
     }
   return !PositionSelectByTicket(ticket);
  }

//+------------------------------------------------------------------+
//| Delete one pending order by ticket                               |
//+------------------------------------------------------------------+
bool DeleteOrder(const ulong ticket)
  {
   for(int attempt = 0; attempt < InpMaxRetries && !IsStopped(); attempt++)
     {
      if(!OrderSelect(ticket))
         return true;                       // already gone

      MqlTradeRequest req;
      MqlTradeResult  res;
      ZeroMemory(req);
      ZeroMemory(res);
      req.action = TRADE_ACTION_REMOVE;
      req.order  = ticket;

      ResetLastError();
      bool sent = OrderSend(req, res);
      uint rc   = res.retcode;
      if(sent && (rc == TRADE_RETCODE_DONE || rc == TRADE_RETCODE_PLACED))
         return true;
      if(rc == TRADE_RETCODE_MARKET_CLOSED || rc == TRADE_RETCODE_TRADE_DISABLED ||
         rc == TRADE_RETCODE_CLIENT_DISABLES_AT || rc == TRADE_RETCODE_SERVER_DISABLES_AT)
        {
         LogFailure(StringFormat("cannot delete order #%I64u now (retcode %u) - will keep retrying", ticket, rc));
         return false;
        }
      Sleep(250);
     }
   return !OrderSelect(ticket);
  }

//+------------------------------------------------------------------+
//| Print failures at most once every 30 seconds                     |
//+------------------------------------------------------------------+
void LogFailure(const string text)
  {
   datetime now = TimeLocal();
   if(now - g_lastFailLog >= 30)
     {
      PrintFormat("%s: %s", SDLL_NAME, text);
      g_lastFailLog = now;
     }
  }

//+------------------------------------------------------------------+
//| Does a position / order pass the magic filter?                   |
//+------------------------------------------------------------------+
bool MagicMatches(const long magic) { return (InpMagicFilter == 0 || magic == InpMagicFilter); }

//+------------------------------------------------------------------+
//| While locked: close positions, delete pending orders             |
//+------------------------------------------------------------------+
void Enforce()
  {
   if(g_busy)
      return;
   g_busy = true;

   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) || !MQLInfoInteger(MQL_TRADE_ALLOWED))
     {
      g_warning = "Algo Trading is OFF - the EA CANNOT close positions! Enable Algo Trading.";
      g_busy = false;
      return;
     }

   g_failedPositions = 0;
   g_failedOrders    = 0;

   //--- positions (iterate backwards: the list shrinks while closing)
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(!MagicMatches(PositionGetInteger(POSITION_MAGIC)))
         continue;
      // CloseAllOnLock = false: positions opened BEFORE the lock are left to the trader;
      // anything opened at/after the lock moment is closed.
      if(!InpCloseAllOnLock && (datetime)PositionGetInteger(POSITION_TIME) < g_lockTime)
         continue;
      if(!ClosePosition(ticket))
         g_failedPositions++;
     }

   //--- pending orders: always deleted while locked (they could open new exposure)
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0)
         continue;
      if(!MagicMatches(OrderGetInteger(ORDER_MAGIC)))
         continue;
      ENUM_ORDER_TYPE ot = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if(ot == ORDER_TYPE_BUY || ot == ORDER_TYPE_SELL)
         continue;                          // market order in flight, not a pending order
      if(!DeleteOrder(ticket))
         g_failedOrders++;
     }

   if(g_failedPositions > 0 || g_failedOrders > 0)
      g_warning = StringFormat("Could not close %d position(s) / delete %d order(s) yet (market closed or busy). Retrying every second.",
                               g_failedPositions, g_failedOrders);
   else
      g_warning = "";

   g_busy = false;
  }

//+------------------------------------------------------------------+
//| On-chart panel                                                   |
//+------------------------------------------------------------------+
void UpdatePanel(const double base, const double loss, const double limit, const double trigger, const bool locked)
  {
   if(!InpShowPanel)
      return;
   string cur = AccountInfoString(ACCOUNT_CURRENCY);
   string baseName = (InpBaseOn == START_OF_DAY_EQUITY_HIGHER) ? "SoD max(balance, equity)" : "SoD balance";
   if(InpBaseOn == START_OF_DAY_EQUITY_HIGHER && !g_sodEquityKnown)
      baseName += " [equity unknown - using balance]";

   double room = MathMax(trigger - loss, 0.0);
   string status = locked
                   ? "LOCKED until " + TimeToString(g_lockUntil, TIME_DATE | TIME_MINUTES) + " (server)"
                   : "OK - trading allowed";

   string txt = "";
   txt += SDLL_NAME + "  v" + SDLL_VER + "\n";
   txt += "STATUS:            " + status + "\n";
   txt += "Server time:       " + TimeToString(TimeTradeServer(), TIME_DATE | TIME_SECONDS) + "\n";
   txt += "Start value:       " + DoubleToString(base, 2) + " " + cur + "  (" + baseName + ")\n";
   txt += "Today's loss:      " + DoubleToString(MathMax(loss, 0.0), 2) + " " + cur
          + "  (today's P/L " + (loss <= 0 ? "+" : "") + DoubleToString(-loss, 2)
          + (InpIncludeFloating ? ", incl. floating)" : ", closed trades only)") + "\n";
   txt += "Limit:             " + DoubleToString(limit, 2) + " " + cur
          + "  (acts at " + DoubleToString(trigger, 2) + ", buffer " + DoubleToString(limit - trigger, 2) + ")\n";
   txt += "Room left:         " + DoubleToString(room, 2) + " " + cur + "\n";
   txt += "Next reset:        " + TimeToString(g_dayStart + SECONDS_PER_DAY, TIME_DATE | TIME_MINUTES) + " (server)\n";
   txt += "Scope:             " + (InpMagicFilter == 0 ? "all positions, all symbols" : "magic " + IntegerToString(InpMagicFilter) + " only") + "\n";
   txt += "Streak:            " + IntegerToString(g_streak) + (g_streak == 1 ? " trading day" : " trading days") + " inside the limit\n";
   if(g_cardInfo != "")
      txt += "Share card saved:  " + g_cardInfo + "\n";
   if(g_warning != "")
      txt += "WARNING: " + g_warning + "\n";
   txt += "Free tool by Spectar FX  |  " + SDLL_SITE + "\n";
   Comment(txt);
  }

//+------------------------------------------------------------------+
//| Main evaluation: called on tick, timer and trade events          |
//+------------------------------------------------------------------+
void Evaluate()
  {
   if(!EnsureDay())
     {
      if(InpShowPanel)
         Comment(SDLL_NAME + ": waiting for account connection / history...");
      return;
     }

   if(g_histDirty)
     {
      double pnl, balOps;
      int    tradeDeals;
      if(CalcTodayHistory(g_dayStart, pnl, balOps, tradeDeals))
        {
         g_closedPnl  = pnl;
         g_balanceOps = balOps;
         g_histDirty  = false;
        }
     }

   double sodBase = BaseValue();
   double loss    = TodayLoss(sodBase);
   // Deposits/withdrawals made today move the base for the % limit too
   // (an account funded today would otherwise have a start value of 0).
   double base    = sodBase + (InpIgnoreBalanceOps ? g_balanceOps : 0.0);
   double limit   = LimitMoney(base);
   double buffer  = (base > 0.0) ? base * InpSafetyBufferPercent / 100.0 : 0.0;
   double trigger = limit - buffer;
   if(trigger <= 0.0)
      trigger = limit;                      // buffer larger than the limit: ignore buffer

   bool locked = IsLocked();
   if(!locked && limit > 0.0 && loss >= trigger)
     {
      ActivateLock(loss, limit);
      locked = true;
     }

   if(locked)
      Enforce();
   else if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) || !MQLInfoInteger(MQL_TRADE_ALLOWED))
      g_warning = "Algo Trading is OFF - the EA will NOT be able to close positions at the limit!";
   else if(limit <= 0.0)
      g_warning = "Start value is 0 - the % limit cannot work today. Set a money limit.";
   else
      g_warning = "";

   UpdatePanel(base, loss, limit, trigger, locked);
  }

//+------------------------------------------------------------------+
//| STRATEGY TESTER ONLY: demo trades.                               |
//| This utility never trades on a real or demo account. In the      |
//| Strategy Tester there is nobody to place trades, so the EA opens |
//| one demo position at a time on the chart symbol, holds it for    |
//| InpTesterHoldMinutes and closes it. This makes the daily lock    |
//| visible in a backtest. Every order is checked first (trade mode, |
//| volume min/max/step/limit, free margin, OrderCheck), so nothing  |
//| is sent that the server would reject.                            |
//+------------------------------------------------------------------+
bool     g_isTester      = false;
datetime g_demoNextTry   = 0;

bool DemoAllowed()
  {
   return (g_isTester && InpTesterDemoTrades && !MQLInfoInteger(MQL_OPTIMIZATION));
  }

//--- round a volume DOWN to the symbol step and check the symbol limits
double DemoNormalizeVolume(const string sym, double vol)
  {
   double vmin  = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
   double vmax  = SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX);
   double vstep = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
   if(vmin <= 0.0 || vstep <= 0.0)
      return 0.0;
   if(vmax > 0.0 && vol > vmax)
      vol = vmax;
   vol = MathFloor(vol / vstep + 1e-9) * vstep;
   int digits = (int)MathMax(0, MathCeil(-MathLog10(vstep) - 1e-9));
   vol = NormalizeDouble(vol, digits);
   if(vol < vmin)
      return 0.0;

   // total volume limit per symbol (0 = no limit)
   double vlimit = SymbolInfoDouble(sym, SYMBOL_VOLUME_LIMIT);
   if(vlimit > 0.0)
     {
      double used = 0.0;
      for(int i = PositionsTotal() - 1; i >= 0; i--)
         if(PositionGetTicket(i) > 0 && PositionGetString(POSITION_SYMBOL) == sym)
            used += PositionGetDouble(POSITION_VOLUME);
      for(int i = OrdersTotal() - 1; i >= 0; i--)
         if(OrderGetTicket(i) > 0 && OrderGetString(ORDER_SYMBOL) == sym)
            used += OrderGetDouble(ORDER_VOLUME_CURRENT);
      if(used + vol > vlimit)
         return 0.0;
     }
   return vol;
  }

//--- open one demo position if everything allows it
void DemoOpen()
  {
   string sym = _Symbol;
   long tm = SymbolInfoInteger(sym, SYMBOL_TRADE_MODE);
   if(tm == SYMBOL_TRADE_MODE_DISABLED || tm == SYMBOL_TRADE_MODE_CLOSEONLY)
      return;
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) || !MQLInfoInteger(MQL_TRADE_ALLOWED))
      return;
   long maxOrders = AccountInfoInteger(ACCOUNT_LIMIT_ORDERS);
   if(maxOrders > 0 && OrdersTotal() >= maxOrders)
      return;

   ENUM_ORDER_TYPE type = (MathRand() % 2 == 0) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   if(tm == SYMBOL_TRADE_MODE_LONGONLY)
      type = ORDER_TYPE_BUY;
   if(tm == SYMBOL_TRADE_MODE_SHORTONLY)
      type = ORDER_TYPE_SELL;

   MqlTick tick;
   if(!SymbolInfoTick(sym, tick) || tick.ask <= 0.0 || tick.bid <= 0.0)
      return;
   double price = (type == ORDER_TYPE_BUY) ? tick.ask : tick.bid;

   // size: about 5 % of free margin (small, but a bad day can still reach the limit)
   double marginOne = 0.0;
   if(!OrderCalcMargin(type, sym, 1.0, price, marginOne) || marginOne <= 0.0)
      return;
   double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   double vol = DemoNormalizeVolume(sym, freeMargin * 0.05 / marginOne);
   if(vol <= 0.0)                              // small account: try the minimum volume
      vol = DemoNormalizeVolume(sym, SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN));
   if(vol <= 0.0)
      return;
   double marginNeed = 0.0;
   if(!OrderCalcMargin(type, sym, vol, price, marginNeed) || marginNeed >= freeMargin * 0.5)
      return;                                  // not enough money: skip silently

   MqlTradeRequest req;
   MqlTradeResult  res;
   MqlTradeCheckResult chk;
   for(int variant = 0; variant < 3; variant++)
     {
      ZeroMemory(req);
      ZeroMemory(res);
      ZeroMemory(chk);
      req.action       = TRADE_ACTION_DEAL;
      req.symbol       = sym;
      req.volume       = vol;
      req.type         = type;
      req.price        = price;
      req.deviation    = (ulong)MathMax(InpSlippagePoints, 0);
      req.magic        = (ulong)InpMagicFilter;
      req.comment      = "SDLL tester demo";
      req.type_filling = FillingFor(sym, variant);
      if(!OrderCheck(req, chk))
        {
         if(chk.retcode == TRADE_RETCODE_INVALID_FILL)
            continue;                          // try the next filling mode
         return;                               // money / volume / market: do not send
        }
      if(OrderSend(req, res) && (res.retcode == TRADE_RETCODE_DONE || res.retcode == TRADE_RETCODE_PLACED))
         return;
      if(res.retcode != TRADE_RETCODE_INVALID_FILL)
         return;
     }
  }

//--- called on every tick in the tester while the day is NOT locked
void DemoTick()
  {
   if(!DemoAllowed() || IsLocked())
      return;
   datetime now = TimeCurrent();

   bool have = false;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong tk = PositionGetTicket(i);
      if(tk == 0 || PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagicFilter)
         continue;
      have = true;
      if(now - (datetime)PositionGetInteger(POSITION_TIME) >= InpTesterHoldMinutes * 60)
        {
         ClosePosition(tk);
         g_histDirty = true;
         g_demoNextTry = now + 60;
        }
     }
   if(have || now < g_demoNextTry)
      return;
   g_demoNextTry = now + 60;                   // at most one attempt per minute
   DemoOpen();
  }

//+------------------------------------------------------------------+
//| Expert initialization                                            |
//+------------------------------------------------------------------+
int OnInit()
  {
   if(InpDailyLossLimit < 0.0 || InpDailyLossPercent < 0.0 || InpDailyLossPercent >= 100.0)
     {
      Print(SDLL_NAME, ": invalid limit inputs (must be >= 0, percent < 100).");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpDailyLossLimit == 0.0 && InpDailyLossPercent == 0.0)
     {
      Print(SDLL_NAME, ": both limits are 0 (off). Set DailyLossLimit and/or DailyLossPercent.");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpDayResetHour < 0 || InpDayResetHour > 23)
     {
      Print(SDLL_NAME, ": DayResetHour must be 0..23.");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpSafetyBufferPercent < 0.0 || InpMaxRetries < 1 || InpSlippagePoints < 0)
     {
      Print(SDLL_NAME, ": invalid buffer / retries / slippage input.");
      return INIT_PARAMETERS_INCORRECT;
     }

   if(InpTesterHoldMinutes < 1)
     {
      Print(SDLL_NAME, ": TesterHoldMinutes must be >= 1.");
      return INIT_PARAMETERS_INCORRECT;
     }

   g_isTester = (MQLInfoInteger(MQL_TESTER) != 0);
   if(g_isTester)
      MathSrand(12345);                     // reproducible demo trades in the tester
   EventSetTimer(g_isTester ? 60 : 1);      // live: every second (also without ticks); tester: ticks drive it
   g_histDirty = true;
   CardButton();
   Evaluate();
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
//| Expert deinitialization                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   EventKillTimer();
   GlobalVariablesFlush();
   ObjectDelete(0, SDLL_BTN_CARD);
   ObjectsDeleteAll(0, SDLL_CARD_PREFIX);
   Comment("");
  }

//+------------------------------------------------------------------+
//| "Share card" button                                              |
//+------------------------------------------------------------------+
void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
  {
   if(id == CHARTEVENT_OBJECT_CLICK && sparam == SDLL_BTN_CARD)
     {
      ObjectSetInteger(0, SDLL_BTN_CARD, OBJPROP_STATE, false);
      MakeCard(IsLocked(), g_streak);
      g_histDirty = true;
      Evaluate();
     }
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   Evaluate();
   DemoTick();                               // Strategy Tester only, does nothing live
  }

//+------------------------------------------------------------------+
void OnTimer()
  {
   g_histDirty = true;                      // refresh closed P/L once per second
   Evaluate();
   if(InpCardOnStart && !g_cardStartDone)
     {
      g_cardStartDone = true;
      MakeCard(IsLocked(), g_streak);
     }
  }

//+------------------------------------------------------------------+
//| Any trade event: refresh history, enforce immediately if locked  |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
  {
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD || trans.type == TRADE_TRANSACTION_HISTORY_ADD)
      g_histDirty = true;
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD || trans.type == TRADE_TRANSACTION_ORDER_ADD ||
      trans.type == TRADE_TRANSACTION_POSITION)
      Evaluate();
  }
//+------------------------------------------------------------------+
