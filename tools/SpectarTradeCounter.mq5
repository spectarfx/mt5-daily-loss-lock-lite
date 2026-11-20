//+------------------------------------------------------------------+
//|                                           SpectarTradeCounter.mq5 |
//|                                       Spectar FX - free MT5 tool |
//|                                                                  |
//| Counts the trades you opened today (from broker server midnight) |
//| and compares them with the maximum you set for yourself.         |
//| Also shows losing trades in a row and today's closed result.     |
//|                                                                  |
//| Read-only: it never opens, modifies or closes anything.          |
//| No DLLs, no web requests. You type every number yourself.        |
//+------------------------------------------------------------------+
#property copyright   "Spectar FX"
#property link        "https://www.mql5.com/en/users/pveliki"
#property version     "1.00"
#property description "Spectar Trade Counter"
#property description "Trades opened today (from broker server midnight) against your own maximum,"
#property description "losing trades in a row and today's closed result. Optional alert."
#property description "Read-only. You type every number yourself; nothing is preset by us."
#property indicator_chart_window
#property indicator_plots 0

//==================================================================
// Inputs - every figure is yours; 0 switches a check off
//==================================================================
input int    InpMaxTrades      = 0;     // Your maximum trades per day (0 = off)
input int    InpMaxLossStreak  = 0;     // Your maximum losing trades in a row (0 = off)
input bool   InpOnlyThisSymbol = false; // Count only the chart symbol
input long   InpMagic          = -1;    // Count only this magic number (-1 = all, 0 = manual)
input bool   InpAlert          = true;  // Pop-up alert when a maximum is reached
input int    InpCorner         = 0;     // Corner: 0 top-left, 1 top-right
input int    InpX              = 12;    // X offset, pixels
input int    InpY              = 24;    // Y offset, pixels
input int    InpFontSize       = 10;    // Font size

#define PFX   "STC_"
#define LINES 7

datetime g_alertDayTrades = 0;
datetime g_alertDayStreak = 0;

//+------------------------------------------------------------------+
datetime ServerDayStart()
  {
   MqlDateTime t;
   TimeToStruct(TimeTradeServer(), t);
   t.hour = 0;
   t.min = 0;
   t.sec = 0;
   return StructToTime(t);
  }

//+------------------------------------------------------------------+
bool DealCounts(ulong ticket)
  {
   long type = HistoryDealGetInteger(ticket, DEAL_TYPE);
   if(type != DEAL_TYPE_BUY && type != DEAL_TYPE_SELL)
      return false;
   if(InpOnlyThisSymbol && HistoryDealGetString(ticket, DEAL_SYMBOL) != _Symbol)
      return false;
   if(InpMagic >= 0 && HistoryDealGetInteger(ticket, DEAL_MAGIC) != InpMagic)
      return false;
   return true;
  }

//+------------------------------------------------------------------+
// Today: trades opened, closed result, wins/losses. Streak: losing exits in a row (last 30 days)
void Stats(int &opened, int &wins, int &losses, double &closed, int &streak)
  {
   opened = 0;
   wins = 0;
   losses = 0;
   closed = 0;
   streak = 0;
   datetime ds = ServerDayStart();
   if(!HistorySelect(ds - 30 * 86400, TimeTradeServer() + 60))
      return;
   int n = HistoryDealsTotal();
   for(int i = 0; i < n; i++)
     {
      ulong tk = HistoryDealGetTicket(i);
      if(!DealCounts(tk))
         continue;
      long entry = HistoryDealGetInteger(tk, DEAL_ENTRY);
      datetime t = (datetime)HistoryDealGetInteger(tk, DEAL_TIME);
      double r = HistoryDealGetDouble(tk, DEAL_PROFIT) + HistoryDealGetDouble(tk, DEAL_SWAP)
                 + HistoryDealGetDouble(tk, DEAL_COMMISSION) + HistoryDealGetDouble(tk, DEAL_FEE);
      if(entry == DEAL_ENTRY_IN && t >= ds)
         opened++;
      if(entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_INOUT || entry == DEAL_ENTRY_OUT_BY)
        {
         if(t >= ds)
           {
            closed += r;
            if(r < 0)
               losses++;
            else
               wins++;
           }
         streak = (r < 0) ? streak + 1 : 0;
        }
     }
  }

//+------------------------------------------------------------------+
void Label(int i, string text, color c)
  {
   string name = PFX + IntegerToString(i);
   int pw = InpFontSize * 36;
   if(ObjectFind(0, name) < 0)
     {
      ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, name, OBJPROP_CORNER, InpCorner == 1 ? CORNER_RIGHT_UPPER : CORNER_LEFT_UPPER);
      ObjectSetInteger(0, name, OBJPROP_ANCHOR, ANCHOR_LEFT_UPPER);
      ObjectSetString(0, name, OBJPROP_FONT, "Consolas");
      ObjectSetInteger(0, name, OBJPROP_FONTSIZE, InpFontSize);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
     }
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, InpCorner == 1 ? InpX + pw - 10 : InpX + 10);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, InpY + 8 + i * (InpFontSize + 9));
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetInteger(0, name, OBJPROP_COLOR, c);
  }

//+------------------------------------------------------------------+
void Background()
  {
   string name = PFX + "bg";
   int w = InpFontSize * 36;
   int h = 16 + LINES * (InpFontSize + 9);
   if(ObjectFind(0, name) < 0)
     {
      ObjectCreate(0, name, OBJ_RECTANGLE_LABEL, 0, 0, 0);
      ObjectSetInteger(0, name, OBJPROP_CORNER, InpCorner == 1 ? CORNER_RIGHT_UPPER : CORNER_LEFT_UPPER);
      ObjectSetInteger(0, name, OBJPROP_BGCOLOR, C'16,24,48');
      ObjectSetInteger(0, name, OBJPROP_BORDER_TYPE, BORDER_FLAT);
      ObjectSetInteger(0, name, OBJPROP_COLOR, C'212,169,55');
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
     }
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, InpCorner == 1 ? InpX + w : InpX);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, InpY);
   ObjectSetInteger(0, name, OBJPROP_XSIZE, w);
   ObjectSetInteger(0, name, OBJPROP_YSIZE, h);
  }

//+------------------------------------------------------------------+
color Level(int used, int limit)
  {
   if(limit <= 0)
      return clrWhite;
   if(used >= limit)
      return clrTomato;
   if(used >= limit - 1)
      return clrOrange;
   return C'46,204,113';
  }

//+------------------------------------------------------------------+
void Draw()
  {
   int opened, wins, losses, streak;
   double closed;
   Stats(opened, wins, losses, closed, streak);
   datetime ds = ServerDayStart();

   Background();
   int i = 0;
   Label(i++, "SPECTAR TRADE COUNTER", C'212,169,55');
   Label(i++, "Trades opened today  " + IntegerToString(opened) +
         (InpMaxTrades > 0 ? " of " + IntegerToString(InpMaxTrades) : ""), Level(opened, InpMaxTrades));
   Label(i++, "Closed today ....... " + IntegerToString(wins) + " won, " + IntegerToString(losses) + " lost", clrWhite);
   Label(i++, "Closed result ...... " + (closed >= 0 ? "+" : "") + DoubleToString(closed, 2) + " " +
         AccountInfoString(ACCOUNT_CURRENCY), closed >= 0 ? C'46,204,113' : clrTomato);
   Label(i++, "Losing in a row .... " + IntegerToString(streak) +
         (InpMaxLossStreak > 0 ? " of " + IntegerToString(InpMaxLossStreak) : ""), Level(streak, InpMaxLossStreak));
   Label(i++, "Day from server 00:00, " + TimeToString(ds, TIME_DATE), clrSilver);
   Label(i++, "Free tool by Spectar FX", C'212,169,55');

   if(InpAlert)
     {
      if(InpMaxTrades > 0 && opened >= InpMaxTrades && g_alertDayTrades != ds)
        {
         g_alertDayTrades = ds;
         Alert("Spectar Trade Counter: ", opened, " trades today, your maximum is ", InpMaxTrades);
        }
      if(InpMaxLossStreak > 0 && streak >= InpMaxLossStreak && g_alertDayStreak != ds)
        {
         g_alertDayStreak = ds;
         Alert("Spectar Trade Counter: ", streak, " losing trades in a row, your maximum is ", InpMaxLossStreak);
        }
     }
   ChartRedraw();
  }

//+------------------------------------------------------------------+
int OnInit()
  {
   EventSetTimer(2);
   Draw();
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   EventKillTimer();
   ObjectsDeleteAll(0, PFX);
  }

//+------------------------------------------------------------------+
void OnTimer()
  {
   Draw();
  }

//+------------------------------------------------------------------+
int OnCalculate(const int rates_total, const int prev_calculated, const datetime &time[],
                const double &open[], const double &high[], const double &low[], const double &close[],
                const long &tick_volume[], const long &volume[], const int &spread[])
  {
   return rates_total;
  }
//+------------------------------------------------------------------+
