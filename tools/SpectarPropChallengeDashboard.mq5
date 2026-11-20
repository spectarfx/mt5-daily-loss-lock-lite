//+------------------------------------------------------------------+
//|                                 SpectarPropChallengeDashboard.mq5 |
//|                                       Spectar FX - free MT5 tool |
//|                                                                  |
//| One panel with the numbers a prop-style challenge is judged on:  |
//|  - today's result from broker server midnight, closed + floating |
//|  - room left to your own daily loss limit                        |
//|  - overall loss floor, static or trailing, and room left to it   |
//|  - profit target progress                                        |
//|  - trading days counted since the start date                     |
//|                                                                  |
//| Read-only: it never opens, modifies or closes anything.          |
//| No DLLs, no web requests. You type every number yourself.        |
//+------------------------------------------------------------------+
#property copyright   "Spectar FX"
#property link        "https://www.mql5.com/en/users/pveliki"
#property version     "1.00"
#property description "Spectar Prop Challenge Dashboard"
#property description "Daily loss from server midnight (closed + floating), overall floor"
#property description "(static or trailing), profit target and trading days in one panel."
#property description "Read-only. You type every number yourself; nothing is preset by us."
#property indicator_chart_window
#property indicator_plots 0

enum ENUM_DAILY_BASE
  {
   BASE_BALANCE = 0, // Balance at server midnight
   BASE_HIGHER  = 1  // Higher of balance and equity at server midnight
  };

enum ENUM_FLOOR_TYPE
  {
   FLOOR_STATIC   = 0, // Static: start balance minus max loss
   FLOOR_TRAILING = 1  // Trailing: highest closed balance minus max loss
  };

//==================================================================
// Inputs - every figure is yours; 0 switches a line off
//==================================================================
input double          InpStartBalance   = 0;            // Start balance of the account (0 = off)
input datetime        InpStartDate      = D'2026.01.01'; // Challenge start date (server time)
input double          InpDailyLossLimit = 0;            // Daily loss limit, account currency (0 = off)
input ENUM_DAILY_BASE InpDailyBase      = BASE_BALANCE; // Daily limit is measured from
input double          InpMaxLoss        = 0;            // Overall max loss, account currency (0 = off)
input ENUM_FLOOR_TYPE InpFloorType      = FLOOR_STATIC; // Overall floor type
input bool            InpTrailStopAtStart = true;       // Trailing floor stops at start balance
input double          InpProfitTarget   = 0;            // Profit target, account currency (0 = off)
input int             InpMinDays        = 0;            // Minimum trading days (0 = off)
input double          InpWarnPercent    = 70;           // Warn when this % of a limit is used
input int             InpCorner         = 0;            // Corner: 0 top-left, 1 top-right
input int             InpX              = 12;           // X offset, pixels
input int             InpY              = 24;           // Y offset, pixels
input int             InpFontSize       = 10;           // Font size

#define PFX "SPCD_"
#define LINES 11

string g_gvEq;         // equity snapshot at server midnight (if the panel ran then)
datetime g_dayStart = 0;

//+------------------------------------------------------------------+
datetime ServerDayStart()
  {
   MqlDateTime t;
   TimeToStruct(TimeTradeServer(), t);
   t.hour = 0; t.min = 0; t.sec = 0;
   return StructToTime(t);
  }

//+------------------------------------------------------------------+
// Closed result (profit + swap + commission + fee) of deals in [from, now]
double ClosedSince(datetime from)
  {
   if(!HistorySelect(from, TimeTradeServer() + 60))
      return 0;
   double s = 0;
   int n = HistoryDealsTotal();
   for(int i = 0; i < n; i++)
     {
      ulong tk = HistoryDealGetTicket(i);
      long type = HistoryDealGetInteger(tk, DEAL_TYPE);
      if(type != DEAL_TYPE_BUY && type != DEAL_TYPE_SELL)
         continue;
      s += HistoryDealGetDouble(tk, DEAL_PROFIT) + HistoryDealGetDouble(tk, DEAL_SWAP)
           + HistoryDealGetDouble(tk, DEAL_COMMISSION) + HistoryDealGetDouble(tk, DEAL_FEE);
     }
   return s;
  }

//+------------------------------------------------------------------+
// Walks the history from the start date: highest closed balance and trading days
void HistoryStats(double &peak, int &days)
  {
   peak = InpStartBalance;
   days = 0;
   if(!HistorySelect(InpStartDate, TimeTradeServer() + 60))
      return;
   double bal = InpStartBalance;
   string lastDay = "";
   int n = HistoryDealsTotal();
   for(int i = 0; i < n; i++)
     {
      ulong tk = HistoryDealGetTicket(i);
      long type = HistoryDealGetInteger(tk, DEAL_TYPE);
      if(type != DEAL_TYPE_BUY && type != DEAL_TYPE_SELL)
         continue;
      bal += HistoryDealGetDouble(tk, DEAL_PROFIT) + HistoryDealGetDouble(tk, DEAL_SWAP)
             + HistoryDealGetDouble(tk, DEAL_COMMISSION) + HistoryDealGetDouble(tk, DEAL_FEE);
      if(bal > peak)
         peak = bal;
      if(HistoryDealGetInteger(tk, DEAL_ENTRY) == DEAL_ENTRY_IN)
        {
         string d = TimeToString((datetime)HistoryDealGetInteger(tk, DEAL_TIME), TIME_DATE);
         if(d != lastDay)
           {
            days++;
            lastDay = d;
           }
        }
     }
  }

//+------------------------------------------------------------------+
void Label(int i, string text, color c)
  {
   string name = PFX + IntegerToString(i);
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
   int pw = (int)(InpFontSize * 44);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, InpCorner == 1 ? InpX + pw - 10 : InpX + 10);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, InpY + 8 + i * (InpFontSize + 9));
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetInteger(0, name, OBJPROP_COLOR, c);
  }

//+------------------------------------------------------------------+
void Background()
  {
   string name = PFX + "bg";
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
   int w = (int)(InpFontSize * 44), h = 16 + LINES * (InpFontSize + 9);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, InpCorner == 1 ? InpX + w : InpX);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, InpY);
   ObjectSetInteger(0, name, OBJPROP_XSIZE, w);
   ObjectSetInteger(0, name, OBJPROP_YSIZE, h);
  }

//+------------------------------------------------------------------+
color Level(double used, double limit)
  {
   if(limit <= 0)
      return clrSilver;
   double p = 100.0 * used / limit;
   if(p >= 100)
      return clrTomato;
   if(p >= InpWarnPercent)
      return clrOrange;
   return C'46,204,113';
  }

string M(double v) { return DoubleToString(v, 2); }

//+------------------------------------------------------------------+
void Draw()
  {
   string cur = AccountInfoString(ACCOUNT_CURRENCY);
   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   double eq  = AccountInfoDouble(ACCOUNT_EQUITY);
   datetime ds = ServerDayStart();

   // equity snapshot at the first update of a new server day
   if(ds != g_dayStart)
     {
      g_dayStart = ds;
      if(!GlobalVariableCheck(g_gvEq) || (datetime)GlobalVariableTime(g_gvEq) < ds)
         GlobalVariableSet(g_gvEq, eq);
     }

   double closedToday = ClosedSince(ds);
   double balMidnight = bal - closedToday;
   double base = balMidnight;
   if(InpDailyBase == BASE_HIGHER && GlobalVariableCheck(g_gvEq) && (datetime)GlobalVariableTime(g_gvEq) >= ds)
      base = MathMax(balMidnight, GlobalVariableGet(g_gvEq));
   double today = eq - base;               // closed + floating since midnight
   double lossToday = MathMax(0, -today);

   double peak; int days;
   HistoryStats(peak, days);

   Background();
   int i = 0;
   Label(i++, "SPECTAR PROP CHALLENGE DASHBOARD", C'212,169,55');
   Label(i++, "Day start (server)  " + TimeToString(ds, TIME_DATE) + "  " + M(base) + " " + cur, clrWhite);
   Label(i++, "Today (closed+open)  " + (today >= 0 ? "+" : "") + M(today), today >= 0 ? C'46,204,113' : clrTomato);

   if(InpDailyLossLimit > 0)
     {
      double room = InpDailyLossLimit - lossToday;
      Label(i++, "Daily limit room ... " + M(room) + " of " + M(InpDailyLossLimit), Level(lossToday, InpDailyLossLimit));
      Label(i++, "Daily floor equity . " + M(base - InpDailyLossLimit), clrSilver);
     }
   else
     {
      Label(i++, "Daily limit ........ off (type your figure)", clrSilver);
      Label(i++, " ", clrSilver);
     }

   if(InpMaxLoss > 0 && InpStartBalance > 0)
     {
      double floorV = InpStartBalance - InpMaxLoss;
      if(InpFloorType == FLOOR_TRAILING)
        {
         floorV = peak - InpMaxLoss;
         if(InpTrailStopAtStart)
            floorV = MathMin(floorV, InpStartBalance);
        }
      double roomAll = eq - floorV;
      Label(i++, (InpFloorType == FLOOR_TRAILING ? "Trailing floor ..... " : "Static floor ....... ") + M(floorV), clrSilver);
      Label(i++, "Room to floor ...... " + M(roomAll), Level(InpMaxLoss - roomAll, InpMaxLoss));
     }
   else
     {
      Label(i++, "Overall floor ...... off (type start + max loss)", clrSilver);
      Label(i++, " ", clrSilver);
     }

   if(InpProfitTarget > 0 && InpStartBalance > 0)
     {
      double gained = eq - InpStartBalance;
      double pct = 100.0 * gained / InpProfitTarget;
      Label(i++, "Profit target ...... " + M(gained) + " / " + M(InpProfitTarget) + "  (" + DoubleToString(MathMax(0, pct), 0) + "%)",
            pct >= 100 ? C'46,204,113' : clrWhite);
     }
   else
      Label(i++, "Profit target ...... off", clrSilver);

   if(InpMinDays > 0)
      Label(i++, "Trading days ....... " + IntegerToString(days) + " / " + IntegerToString(InpMinDays),
            days >= InpMinDays ? C'46,204,113' : clrWhite);
   else
      Label(i++, "Trading days ....... " + IntegerToString(days) + " since " + TimeToString(InpStartDate, TIME_DATE), clrWhite);

   Label(i++, "Read-only. Check your firm's exact rules.", clrSilver);
   Label(i++, "Free tool by Spectar FX", C'212,169,55');
   ChartRedraw();
  }

//+------------------------------------------------------------------+
int OnInit()
  {
   g_gvEq = "SPCD_" + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)) + "_eq0";
   EventSetTimer(1);
   Draw();
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   EventKillTimer();
   ObjectsDeleteAll(0, PFX);
  }

void OnTimer() { Draw(); }

int OnCalculate(const int rates_total, const int prev_calculated, const datetime &time[],
                const double &open[], const double &high[], const double &low[], const double &close[],
                const long &tick_volume[], const long &volume[], const int &spread[])
  {
   return rates_total;
  }
//+------------------------------------------------------------------+
