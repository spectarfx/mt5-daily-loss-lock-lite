//+------------------------------------------------------------------+
//|                                         SpectarServerDayClock.mq5 |
//|                                       Spectar FX - free MT5 tool |
//|                                                                  |
//| Daily loss limits on prop-style accounts usually reset at        |
//| broker server midnight, not at your local midnight. This panel   |
//| shows server time, your local time, the offset between them and  |
//| a countdown to the next server day and to the weekly close.      |
//|                                                                  |
//| Read-only: it never opens, modifies or closes anything.          |
//| No DLLs, no web requests.                                        |
//+------------------------------------------------------------------+
#property copyright   "Spectar FX"
#property link        "https://www.mql5.com/en/users/pveliki"
#property version     "1.00"
#property description "Spectar Server Day Clock"
#property description "Broker server time, your local time, the offset, and countdowns to the next"
#property description "server day (when daily limits usually reset) and to the weekly close."
#property description "Optional alert a few minutes before the weekly close. Read-only."
#property indicator_chart_window
#property indicator_plots 0

//==================================================================
// Inputs
//==================================================================
input int    InpFridayCloseHour = 23; // Weekly close on Friday, server hour (check your broker)
input int    InpFridayCloseMin  = 55; // Weekly close on Friday, server minute
input int    InpWarnMinutes     = 30; // Alert this many minutes before the weekly close (0 = off)
input int    InpCorner          = 0;  // Corner: 0 top-left, 1 top-right
input int    InpX               = 12; // X offset, pixels
input int    InpY               = 24; // Y offset, pixels
input int    InpFontSize        = 10; // Font size

#define PFX   "SSDC_"
#define LINES 8

datetime g_warned = 0;

//+------------------------------------------------------------------+
string Span(long sec)
  {
   if(sec < 0)
      sec = 0;
   long d = sec / 86400;
   long h = (sec % 86400) / 3600;
   long m = (sec % 3600) / 60;
   long s = sec % 60;
   string out = (d > 0 ? IntegerToString(d) + "d " : "");
   return out + StringFormat("%02d:%02d:%02d", h, m, s);
  }

//+------------------------------------------------------------------+
void Label(int i, string text, color c)
  {
   string name = PFX + IntegerToString(i);
   int pw = InpFontSize * 34;
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
   int w = InpFontSize * 34;
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
void Draw()
  {
   datetime srv = TimeTradeServer();
   datetime loc = TimeLocal();
   long offsetMin = (long)MathRound((double)(srv - loc) / 60.0);

   MqlDateTime t;
   TimeToStruct(srv, t);
   datetime midnight = srv - (t.hour * 3600 + t.min * 60 + t.sec) + 86400;

   // next Friday close (server time)
   int daysToFri = (5 - t.day_of_week + 7) % 7;
   datetime friday = srv - (t.hour * 3600 + t.min * 60 + t.sec) + daysToFri * 86400
                     + InpFridayCloseHour * 3600 + InpFridayCloseMin * 60;
   if(friday <= srv)
      friday += 7 * 86400;
   long toClose = (long)(friday - srv);
   bool weekend = (t.day_of_week == 6 || t.day_of_week == 0);

   Background();
   int i = 0;
   Label(i++, "SPECTAR SERVER DAY CLOCK", C'212,169,55');
   Label(i++, "Server time ...... " + TimeToString(srv, TIME_DATE | TIME_SECONDS), clrWhite);
   Label(i++, "Your local time .. " + TimeToString(loc, TIME_DATE | TIME_SECONDS), clrWhite);
   Label(i++, "Server vs local .. " + (offsetMin >= 0 ? "+" : "-") +
         StringFormat("%d:%02d h", (int)(MathAbs(offsetMin) / 60), (int)(MathAbs(offsetMin)) % 60), clrSilver);
   Label(i++, "New server day in  " + Span((long)(midnight - srv)), C'46,204,113');
   Label(i++, "Local time then .. " + TimeToString(loc + (midnight - srv), TIME_MINUTES), clrSilver);
   Label(i++, weekend ? "Market closed for the weekend" : "Weekly close in .. " + Span(toClose),
         (!weekend && InpWarnMinutes > 0 && toClose <= InpWarnMinutes * 60) ? clrOrange : clrWhite);
   Label(i++, "Free tool by Spectar FX", C'212,169,55');

   if(!weekend && InpWarnMinutes > 0 && toClose <= InpWarnMinutes * 60 && g_warned != friday)
     {
      g_warned = friday;
      Alert("Spectar Server Day Clock: weekly close in ", toClose / 60, " minutes (", PositionsTotal(), " open positions)");
     }
   ChartRedraw();
  }

//+------------------------------------------------------------------+
int OnInit()
  {
   EventSetTimer(1);
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
