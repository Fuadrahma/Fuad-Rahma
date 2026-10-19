//+------------------------------------------------------------------+
//|                 NEXORA_IndexOpposite_Reversal_EA_v1.00.mq5       |
//|        USTECc vs US500c | Z-Score Ratio Pair | Claude Edition    |
//+------------------------------------------------------------------+
#property copyright   "Fuad - NEXORA (Claude Edition)"
#property version     "1.00"
#property description "REVERSAL: نفس بوت IndexOpposite لكن معكوس الاتجاه - يتبع التباعد بدل الرهان على العودة"
#property description "ناسداك أعلى (Z فوق الصفر) = شراء A / بيع B ، ناسداك أسفل = بيع A / شراء B"
#property description "لوت متوازن + فتح متكرر + جني 50 سنت + تعزيز بشرط خسارة الجهتين + التحكم الكامل"

#include <Trade/Trade.mqh>

enum ENUM_PANEL_SIDE
  {
   PANEL_RIGHT = 0, // يمين الشارت
   PANEL_LEFT  = 1  // يسار الشارت
  };

enum ENUM_ENTRY_MODE
  {
   ENTRY_SIGNAL     = 0, // إشارة Z + RSI (الأصلي)
   ENTRY_CONT_ZSIDE = 1, // متكرر: حسب الأعلى/الأسفل (إشارة Z)
   ENTRY_CONT_FIXED = 2  // متكرر: اتجاه ثابت
  };

enum ENUM_FIXED_DIR
  {
   FIXED_BUY_A  = 1,  // A شراء دائم / B بيع دائم
   FIXED_SELL_A = -1  // A بيع دائم / B شراء دائم
  };

enum ENUM_TP_MODE
  {
   TP_FIXED_USC = 0, // هدف ثابت للسلة بالسنت
   TP_PER_LAYER = 1  // هدف × عدد الطبقات
  };

enum ENUM_LOT_MODE
  {
   LOT_AUTO   = 0, // متوازن مع الوسيط: لوت A + B محسوب بالقيمة
   LOT_MANUAL = 1  // ثابت يدوي: لوت A ولوت B كما تكتبهما
  };

enum ENUM_HEDGE_MODE
  {
   HEDGE_DOLLAR = 0, // متعادل نقدياً (قيمة حركة 1%)
   HEDGE_VOL    = 1  // متعادل تذبذبياً (ATR)
  };

//==================================================================== INPUTS
input group "══════ التشغيل ══════"
input bool            EnableTrading      = false;        // تفعيل التداول الفعلي
input bool            InpFullControl     = true;         // التحكم الكامل: فحص الوسيط قبل الفتح، وعند الرفض لا يفتح ويتوقف
input bool            InpLocalLotCheck   = false;        // فحص المنيموم محلياً (false = لا يرفض البوت أي لوت، الوسيط يقرر)
input ulong           MagicBase          = 880200;       // الرقم السحري (مختلف عن البوت الأصلي 880100)
input string          InpSymA            = "USTECc";     // الساق A (ناسداك)
input string          InpSymB            = "US500c";     // الساق B (S&P 500)
input int             InpSlippage        = 30;           // الانزلاق (نقاط)

input group "══════ وضع الدخول ══════"
input ENUM_ENTRY_MODE InpEntryMode       = ENTRY_CONT_ZSIDE; // وضع الدخول (افتراضي: متكرر حسب الأعلى/الأسفل)
input ENUM_FIXED_DIR  InpFixedDir        = FIXED_BUY_A;   // الاتجاه الثابت (للوضع الثابت)
input double          InpContMinZ        = 0.0;           // متكرر/أعلى-أسفل: أقل |Z| للفتح (0 = دائماً)
input int             InpReopenDelaySec  = 0;             // انتظار بعد الجني قبل إعادة الفتح (ثانية، 0 = فوراً)
input int             InpRetrySec        = 30;            // انتظار بعد فشل الفتح (ثانية)

input group "══════ الإشارة ══════"
input ENUM_TIMEFRAMES InpTF              = PERIOD_M15;   // فريم الحساب
input int             InpLookback        = 200;          // شموع الإحصاء (حد أقصى 5000)
input double          InpEntryZ          = 2.0;          // Z الدخول
input bool            InpUseRSIFilter    = true;         // فلتر تباعد RSI
input int             InpRSIPeriod       = 14;           // فترة RSI
input double          InpRSIGap          = 8.0;          // أقل فرق RSI باتجاه الإشارة

input group "══════ الحجم ══════"
input ENUM_LOT_MODE   InpLotMode         = LOT_AUTO;     // وضع اللوت (افتراضي: متوازن مع الوسيط)
input double          InpBaseLotA        = 0.05;         // لوت الساق A - كل الطبقات (USTECc)
input double          InpBaseLotB        = 0.14;         // لوت الساق B - للوضع الثابت فقط (US500c)
input double          InpMarginBuffer    = 1.5;          // الهامش الحر المطلوب × هامش الطبقة

input group "══════ التعزيز (خسارة الجهتين) ══════"
input bool            InpUseReinforce    = true;         // تفعيل التعزيز
input int             InpMaxLayers       = 8;            // أقصى طبقات (0 = بلا حد)
input double          InpMinLegLoss      = 0.0;          // كل ساق خاسرة بأكثر من (USC)
input double          InpZStep           = 0.5;          // تمدد Z إضافي لكل طبقة (0 = تعطيل)
input int             InpMinBarsBetween  = 4;            // أقل شموع بين الطبقات

input group "══════ الفتح اليدوي من اللوحة ══════"
input bool            InpManualConfirm   = true;         // تأكيد قبل الفتح اليدوي
input bool            InpManualIgnoreFlt = true;         // الفتح اليدوي يتجاهل فلاتر الجلسة والسبريد

input group "══════ الخروج (بالربح فقط) ══════"
input ENUM_TP_MODE    InpTPMode          = TP_FIXED_USC; // طريقة الهدف
input double          InpBasketTP_USC    = 50.0;         // جني الأرباح للسلة (سنت USC)
input double          InpTPPerBase       = 10.0;         // هدف لكل طبقة أساس (USC) - لطريقة × الطبقات
input double          InpTrailGivePct    = 0.0;          // التتبّع: التنازل من القمة % (0 = إغلاق فوري عند الهدف)
input bool            InpUseZExit        = false;        // خروج عند عودة Z للمتوسط (معطّل: الخروج بالهدف فقط)
input double          InpExitZ           = 0.3;          // مستوى Z للخروج
input double          InpZExitMinProfit  = 2.0;          // أقل ربح لخروج Z (USC)

input group "══════ الفلاتر ══════"
input double          InpSpreadMult      = 2.5;          // السبريد ≤ متوسطه ×
input int             InpSpreadEMA       = 200;          // فترة متوسط السبريد
input bool            InpAvoidBreak      = true;         // تجنّب استراحة/تبييت السيرفر
input int             InpBreakStartHour  = 21;           // بداية الاستراحة (سيرفر)
input int             InpBreakEndHour    = 22;           // نهاية الاستراحة (سيرفر)
input int             InpBreakPadMin     = 15;           // هامش قبل/بعد (دقائق)
input int             InpFridayStopHour  = 19;           // لا دخول الجمعة بعد الساعة

input group "══════ اللوحة والتنبيهات ══════"
input bool            InpLockLots        = false;        // قفل خانات اللوت في اللوحة عند التشغيل
input bool            InpShowPanel       = true;         // إظهار اللوحة
input ENUM_PANEL_SIDE InpPanelSide       = PANEL_RIGHT;  // موضع اللوحة (يمين / يسار)
input int             InpPanelX          = 10;           // إزاحة X
input int             InpPanelY          = 20;           // إزاحة Y
input int             InpFontSize        = 9;            // حجم الخط
input bool            InpAlerts          = true;         // تنبيهات المنصة
input bool            InpPush            = false;        // إشعارات الجوال

//==================================================================== FIXED INTERNALS (no auto sizing)
const ENUM_HEDGE_MODE InpHedgeMode = HEDGE_DOLLAR;   // used only for the info line
const int             InpATRPeriod = 14;

//==================================================================== GLOBALS
CTrade   trade;
string   SA, SB;
int      hRsiA = INVALID_HANDLE, hRsiB = INVALID_HANDLE;
int      hAtrA = INVALID_HANDLE, hAtrB = INVALID_HANDLE;

double   g_mean = 0, g_sd = 0, g_zClosed = 0, g_zLive = 0, g_rsiA = 50, g_rsiB = 50;
bool     g_statsOK = false;
datetime g_lastBar = 0;

int      g_dir = 0, g_layersA = 0, g_layersB = 0;   // dir: +1 = Buy A/Sell B , -1 = Sell A/Buy B
double   g_lotsA = 0, g_lotsB = 0, g_pnlA = 0, g_pnlB = 0, g_lastZ = 0;
datetime g_lastLayerTime = 0;

double   g_peak = 0;
bool     g_trailOn = false;
double   g_spEmaA = 0, g_spEmaB = 0;
bool     g_paused = false;
string   g_event = "—";

bool     g_cLossA = false, g_cLossB = false, g_cZ = false, g_cBars = false, g_cMax = true;
int      g_barsSince = 0;
double   g_needZ = 0;
bool     g_forced = false;    // basket started by manual (forced) open
double   g_lotA = 0.05, g_lotB = 0.14;   // live lot settings (editable from panel)
int      g_lotMode = 0;          // 0 = balanced with broker, 1 = fixed manual
bool     g_lotLock = false;
bool     g_mixed = false;        // positions of this magic in conflicting directions
string   GV_INST, GV_HB;
string   g_reject = "";          // last broker rejection (full control)
string   g_lastSendErr = "";
bool     g_minWarnA = false, g_minWarnB = false;
string   GV_LOTA, GV_LOTB, GV_LMODE;
bool     g_cont   = false;    // basket started by continuous mode
datetime g_nextTry = 0;       // continuous: earliest next open (local time)
int      g_cycles = 0;        // closed baskets since attach
double   g_cyclesPnl = 0;     // their realised net (approx, USC)
double   g_firstZ = 0;        // directional Z of layer 1

const string PFX = "NXIR_";
string   GV_PEAK, GV_TRAIL;

#define PW        420
#define RH        18
#define ROWS      29
#define VAL_X     150

const color CBg   = C'20,20,20';
const color CBrd  = C'60,60,60';
const color CPos  = C'0,200,120';
const color CNeg  = C'235,80,80';
const color CWarn = C'240,190,40';
const color CTxt  = C'230,230,230';
const color CKey  = C'160,160,160';
const color CGold = C'255,200,60';

//==================================================================== HELPERS
double Bid(string s) { MqlTick t; return SymbolInfoTick(s, t) ? t.bid : 0.0; }
double Ask(string s) { MqlTick t; return SymbolInfoTick(s, t) ? t.ask : 0.0; }

double Buf(int h, int shift = 1)
  {
   if(h == INVALID_HANDLE) return -1;
   double v[];
   if(CopyBuffer(h, 0, shift, 1, v) != 1) return -1;
   return v[0];
  }

ENUM_ORDER_TYPE_FILLING GetSupportedFilling(string s)
  {
   long f = SymbolInfoInteger(s, SYMBOL_FILLING_MODE);
   if((f & SYMBOL_FILLING_FOK) == SYMBOL_FILLING_FOK) return ORDER_FILLING_FOK;
   if((f & SYMBOL_FILLING_IOC) == SYMBOL_FILLING_IOC) return ORDER_FILLING_IOC;
   return ORDER_FILLING_RETURN;
  }

double NormLot(string s, double v)
  {
   double step = SymbolInfoDouble(s, SYMBOL_VOLUME_STEP);
   double mn   = SymbolInfoDouble(s, SYMBOL_VOLUME_MIN);
   double mx   = SymbolInfoDouble(s, SYMBOL_VOLUME_MAX);
   if(step <= 0) step = 0.01;
   v = MathRound(v / step) * step;
   if(v < mn) v = mn;
   if(v > mx) v = mx;
   int d = (int)MathMax(0, MathCeil(-MathLog10(step) - 1e-9));
   return NormalizeDouble(v, d);
  }

double SpreadPts(string s)
  {
   MqlTick t;
   if(!SymbolInfoTick(s, t)) return 0;
   double pt = SymbolInfoDouble(s, SYMBOL_POINT);
   return (pt > 0) ? (t.ask - t.bid) / pt : 0;
  }

void Notify(string msg)
  {
   Print("NEXORA IOR | ", msg);
   if(MQLInfoInteger(MQL_TESTER)) return;
   if(InpAlerts) Alert("NEXORA IOR: ", msg);
   if(InpPush)   SendNotification("NEXORA IOR: " + msg);
  }

void SaveLots()
  {
   GlobalVariableSet(GV_LOTA, g_lotA);
   GlobalVariableSet(GV_LOTB, g_lotB);
   GlobalVariableSet(GV_LMODE, g_lotMode);
  }

double VMin(string s)  { return SymbolInfoDouble(s, SYMBOL_VOLUME_MIN); }
double VStep(string s) { double v = SymbolInfoDouble(s, SYMBOL_VOLUME_STEP); return (v > 0) ? v : 0.01; }
double VMax(string s)  { return SymbolInfoDouble(s, SYMBOL_VOLUME_MAX); }

// strict check: never raises/lowers your lot - only snaps to the broker step
bool ValidLot(string s, double v, double &out, string &msg)
  {
   double mn = VMin(s), mx = VMax(s), st = VStep(s);
   if(v <= 0)            { msg = "قيمة غير صالحة"; return false; }
   if(InpLocalLotCheck)
     {
      if(v < mn - 1e-9)     { msg = "أقل من المنيموم " + DoubleToString(mn, 2); return false; }
      if(mx > 0 && v > mx)  { msg = "أكبر من الحد الأقصى " + DoubleToString(mx, 2); return false; }
     }
   int d = (int)MathMax(0, MathCeil(-MathLog10(st) - 1e-9));
   out = NormalizeDouble(MathRound(v / st) * st, d);
   if(out <= 0)          { msg = "أصغر من خطوة الوسيط " + DoubleToString(st, d); return false; }
   msg = "";
   if(MathAbs(out - v) > 1e-9) msg = "قُرّب للخطوة " + DoubleToString(out, d);
   if(!InpLocalLotCheck && out < mn - 1e-9)
      msg += (msg != "" ? " | " : "") + "أقل من منيموم المنصة " + DoubleToString(mn, 2) + " - الوسيط يقرر";
   return true;
  }

void SaveTrail()
  {
   GlobalVariableSet(GV_PEAK, g_peak);
   GlobalVariableSet(GV_TRAIL, g_trailOn ? 1.0 : 0.0);
  }

// directional Z: how far Z is stretched AGAINST the basket (positive = against, needs mean reversion)
double DirZ(double z, int dir) { return (dir < 0) ? z : -z; }

string M2(double v)  { return DoubleToString(v, 2); }
string YN(bool b)    { return b ? "نعم" : "لا"; }
color  YC(bool b)    { return b ? CPos : CNeg; }
color  PC(double v)  { return v > 0 ? CPos : (v < 0 ? CNeg : CTxt); }

//==================================================================== INIT
int OnInit()
  {
   // ---- single-instance lock: only ONE chart may run this MagicBase
   GV_INST = "NXIR_INST_" + (string)MagicBase;
   GV_HB   = "NXIR_HB_"   + (string)MagicBase;
   if(!MQLInfoInteger(MQL_TESTER) && GlobalVariableCheck(GV_INST) && GlobalVariableCheck(GV_HB))
     {
      long other = (long)GlobalVariableGet(GV_INST);
      double age = (double)TimeLocal() - GlobalVariableGet(GV_HB);
      if(other != ChartID() && age < 15)
        {
         Alert("NEXORA IOR: يوجد بوت آخر يعمل بنفس الرقم السحري ", MagicBase,
               " على شارت آخر. أزله أولاً أو غيّر MagicBase - لن يعمل هذا البوت.");
         return INIT_FAILED;
        }
     }
   GlobalVariableSet(GV_INST, (double)ChartID());
   GlobalVariableSet(GV_HB, (double)TimeLocal());

   SA = InpSymA;
   SB = InpSymB;
   if(!SymbolSelect(SA, true) || !SymbolSelect(SB, true))
     {
      Alert("NEXORA IOR: الرمز غير موجود: ", SA, " / ", SB);
      return INIT_FAILED;
     }
   if((ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE) != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
     {
      Alert("NEXORA IOR: الحساب ليس Hedge - البوت يحتاج حساب تحوّط");
      return INIT_FAILED;
     }

   hRsiA = iRSI(SA, InpTF, InpRSIPeriod, PRICE_CLOSE);
   hRsiB = iRSI(SB, InpTF, InpRSIPeriod, PRICE_CLOSE);
   hAtrA = iATR(SA, InpTF, InpATRPeriod);
   hAtrB = iATR(SB, InpTF, InpATRPeriod);
   if(hRsiA == INVALID_HANDLE || hRsiB == INVALID_HANDLE || hAtrA == INVALID_HANDLE || hAtrB == INVALID_HANDLE)
     {
      Alert("NEXORA IOR: فشل إنشاء المؤشرات");
      return INIT_FAILED;
     }

   trade.SetExpertMagicNumber(MagicBase);
   trade.SetDeviationInPoints(InpSlippage);
   trade.SetAsyncMode(false);

   GV_PEAK  = "NXIR_PEAK_"  + (string)MagicBase;
   GV_TRAIL = "NXIR_TRAIL_" + (string)MagicBase;
   if(GlobalVariableCheck(GV_PEAK))  g_peak    = GlobalVariableGet(GV_PEAK);
   if(GlobalVariableCheck(GV_TRAIL)) g_trailOn = (GlobalVariableGet(GV_TRAIL) > 0.5);

   // lot settings: inputs win after a parameter change, otherwise keep what was set on the panel
   GV_LOTA  = "NXIR_LOTA3_"  + (string)MagicBase;
   GV_LOTB  = "NXIR_LOTB3_"  + (string)MagicBase;
   GV_LMODE = "NXIR_LMODE3_" + (string)MagicBase;
   string mA = "", mB = "";
   double vA = 0, vB = 0;
   if(!ValidLot(SA, InpBaseLotA, vA, mA) || !ValidLot(SB, InpBaseLotB, vB, mB))
     {
      Alert("NEXORA IOR: لوت غير صالح | ", SA, ": ", (mA == "" ? "OK" : mA), " | ", SB, ": ", (mB == "" ? "OK" : mB));
      return INIT_PARAMETERS_INCORRECT;
     }
   g_lotA = vA; g_lotB = vB; g_lotMode = (int)InpLotMode;
   if(_UninitReason != REASON_PARAMETERS && GlobalVariableCheck(GV_LOTA) && GlobalVariableCheck(GV_LOTB))
     {
      double ga = 0, gb = 0;
      string x1 = "", x2 = "";
      if(ValidLot(SA, GlobalVariableGet(GV_LOTA), ga, x1) && ValidLot(SB, GlobalVariableGet(GV_LOTB), gb, x2))
        { g_lotA = ga; g_lotB = gb; }
      if(GlobalVariableCheck(GV_LMODE)) g_lotMode = (int)GlobalVariableGet(GV_LMODE);
     }
   g_lotLock = InpLockLots;
   SaveLots();
   PrintFormat("NEXORA IOR | %s: min %.2f step %.2f max %.2f | %s: min %.2f step %.2f max %.2f",
               SA, SymbolInfoDouble(SA, SYMBOL_VOLUME_MIN), SymbolInfoDouble(SA, SYMBOL_VOLUME_STEP), SymbolInfoDouble(SA, SYMBOL_VOLUME_MAX),
               SB, SymbolInfoDouble(SB, SYMBOL_VOLUME_MIN), SymbolInfoDouble(SB, SYMBOL_VOLUME_STEP), SymbolInfoDouble(SB, SYMBOL_VOLUME_MAX));

   SyncFromPositions();
   CalcStats();
   g_lastBar = iTime(SA, InpTF, 0);   // first decision on the NEXT bar close, never at attach

   if(InpShowPanel) BuildPanel();
   EventSetTimer(1);
   g_nextTry = TimeLocal() + 5;
   g_event = EnableTrading ? "جاهز - التداول مفعّل" : "جاهز - التداول معطّل";
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   EventKillTimer();
   if(GV_INST != "" && GlobalVariableCheck(GV_INST) && (long)GlobalVariableGet(GV_INST) == ChartID())
     {
      GlobalVariableDel(GV_INST);
      GlobalVariableDel(GV_HB);
     }
   ObjectsDeleteAll(0, PFX);
   if(hRsiA != INVALID_HANDLE) IndicatorRelease(hRsiA);
   if(hRsiB != INVALID_HANDLE) IndicatorRelease(hRsiB);
   if(hAtrA != INVALID_HANDLE) IndicatorRelease(hAtrA);
   if(hAtrB != INVALID_HANDLE) IndicatorRelease(hAtrB);
   ChartRedraw();
  }

void OnTick()  { Process(); }
void OnTimer()
  {
   if(GV_HB != "") GlobalVariableSet(GV_HB, (double)TimeLocal());   // heartbeat for the instance lock
   Process();
  }

//==================================================================== CORE LOOP
void Process()
  {
   static bool busy = false;
   if(busy) return;
   busy = true;

   UpdateSpreadEMA();
   SyncFromPositions();

   datetime tA = iTime(SA, InpTF, 0);
   datetime tB = iTime(SB, InpTF, 0);
   if(tA > 0 && tA == tB && tA != g_lastBar)
     {
      if(g_lastBar == 0)
        {
         g_lastBar = tA;
         CalcStats();
        }
      else if(CalcStats())
        {
         g_lastBar = tA;
         OnNewBar();
        }
     }

   UpdateLiveZ();
   ManageExits();
   TryContinuous();
   if(InpShowPanel) UpdatePanel();

   busy = false;
  }

//==================================================================== STATS
bool CalcStats()
  {
   int n = MathMin(MathMax(InpLookback, 30), 5000);
   MqlRates ra[];
   ArraySetAsSeries(ra, true);
   if(CopyRates(SA, InpTF, 1, n, ra) < n) { g_statsOK = false; return false; }
   if(iBarShift(SB, InpTF, ra[0].time, true) < 0) { g_statsOK = false; return false; }

   double x[];
   ArrayResize(x, n);
   int m = 0;
   for(int i = 0; i < n; i++)
     {
      int sh = iBarShift(SB, InpTF, ra[i].time, true);
      if(sh < 0) continue;
      double cb = iClose(SB, InpTF, sh);
      if(cb <= 0 || ra[i].close <= 0) continue;
      x[m++] = MathLog(ra[i].close / cb);
     }
   if(m < (int)(n * 0.8)) { g_statsOK = false; return false; }

   double sum = 0;
   for(int i = 0; i < m; i++) sum += x[i];
   double mean = sum / m;
   double var = 0;
   for(int i = 0; i < m; i++) var += (x[i] - mean) * (x[i] - mean);
   double sd = MathSqrt(var / (m - 1));
   if(sd <= 1e-12) { g_statsOK = false; return false; }

   g_mean    = mean;
   g_sd      = sd;
   g_zClosed = (x[0] - mean) / sd;

   double ra1 = Buf(hRsiA, 1), rb1 = Buf(hRsiB, 1);
   if(ra1 >= 0) g_rsiA = ra1;
   if(rb1 >= 0) g_rsiB = rb1;

   g_statsOK = true;
   return true;
  }

void UpdateLiveZ()
  {
   if(!g_statsOK) return;
   double a = Bid(SA), b = Bid(SB);
   if(a > 0 && b > 0) g_zLive = (MathLog(a / b) - g_mean) / g_sd;
  }

void UpdateSpreadEMA()
  {
   double a = SpreadPts(SA), b = SpreadPts(SB);
   double k = 2.0 / (MathMax(InpSpreadEMA, 2) + 1.0);
   if(a > 0) g_spEmaA = (g_spEmaA <= 0) ? a : g_spEmaA + k * (a - g_spEmaA);
   if(b > 0) g_spEmaB = (g_spEmaB <= 0) ? b : g_spEmaB + k * (b - g_spEmaB);
  }

//==================================================================== SYNC (restart-safe)
void SyncFromPositions()
  {
   g_layersA = 0; g_layersB = 0;
   g_lotsA = 0;   g_lotsB = 0;
   g_pnlA = 0;    g_pnlB = 0;
   int dirA = 0, dirB = 0;
   bool aBuy = false, aSell = false, bBuy = false, bSell = false;
   datetime lt = 0, ft = 0;
   double lz = 0, fz = 0;
   bool   lzOK = false, fzOK = false, forced = false, cont = false;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != MagicBase) continue;
      string s   = PositionGetString(POSITION_SYMBOL);
      double vol = PositionGetDouble(POSITION_VOLUME);
      double pl  = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      long   typ = PositionGetInteger(POSITION_TYPE);
      if(s == SA)
        {
         g_layersA++; g_lotsA += vol; g_pnlA += pl;
         dirA = (typ == POSITION_TYPE_BUY) ? 1 : -1;
         if(typ == POSITION_TYPE_BUY) aBuy = true; else aSell = true;
         datetime t = (datetime)PositionGetInteger(POSITION_TIME);
         string c = PositionGetString(POSITION_COMMENT);
         int pz = StringFind(c, "Z");
         bool hasZ = (pz >= 0);
         double cz = hasZ ? StringToDouble(StringSubstr(c, pz + 1)) : 0;
         if(t >= lt) { lt = t; lz = cz; lzOK = hasZ; }
         if(ft == 0 || t < ft)
           {
            ft = t; fz = cz; fzOK = hasZ;
            forced = (StringFind(c, "F ") >= 0);   // "NXIO L1F Z.."
            cont   = (StringFind(c, "C ") >= 0);   // "NXIO L1C Z.."
           }
        }
      else if(s == SB)
        {
         g_layersB++; g_lotsB += vol; g_pnlB += pl;
         dirB = (typ == POSITION_TYPE_BUY) ? -1 : 1;
         if(typ == POSITION_TYPE_BUY) bBuy = true; else bSell = true;
        }
     }

   g_dir = (dirA != 0) ? dirA : dirB;
   // mixed basket: both directions on one leg, or both legs on the same side
   g_mixed = (aBuy && aSell) || (bBuy && bSell) || (dirA != 0 && dirB != 0 && dirA != dirB);
   g_lastLayerTime = lt;
   if(g_layersA > 0 && !lzOK) lz = InpEntryZ + (g_layersA - 1) * InpZStep;
   if(g_layersA > 0 && !fzOK) fz = InpEntryZ;
   g_lastZ  = (g_layersA > 0) ? lz : 0;
   g_firstZ = (g_layersA > 0) ? fz : 0;
   g_forced = (g_layersA > 0) && forced;
   g_cont   = (g_layersA > 0) && cont;

   if(g_layersA == 0 && g_layersB == 0 && (g_trailOn || g_peak != 0))
     {
      g_trailOn = false;
      g_peak = 0;
      SaveTrail();
     }
  }

//==================================================================== FILTERS
bool SessionOK(string &why)
  {
   MqlDateTime d;
   TimeToStruct(TimeCurrent(), d);
   int m = d.hour * 60 + d.min;
   int bs = InpBreakStartHour * 60 - InpBreakPadMin;
   int be = InpBreakEndHour * 60 + InpBreakPadMin;

   if(d.day_of_week == 6) { why = "عطلة نهاية الأسبوع"; return false; }
   if(d.day_of_week == 0 && m < be) { why = "قبل افتتاح الأسبوع"; return false; }
   if(d.day_of_week == 5 && d.hour >= InpFridayStopHour) { why = "الجمعة بعد ساعة الإيقاف"; return false; }
   if(InpAvoidBreak && m >= bs && m < be) { why = "نافذة الاستراحة/التبييت"; return false; }
   return true;
  }

bool SpreadOK(string s, double ema)
  {
   double cur = SpreadPts(s);
   if(ema <= 0) return true;
   return cur <= ema * InpSpreadMult;
  }

bool EntryAllowed(string &why)
  {
   if(g_paused) { why = "موقوف مؤقتاً"; return false; }
   if(!SessionOK(why)) return false;
   if(!SpreadOK(SA, g_spEmaA)) { why = "سبريد " + SA + " مرتفع"; return false; }
   if(!SpreadOK(SB, g_spEmaB)) { why = "سبريد " + SB + " مرتفع"; return false; }
   if(EnableTrading && !TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)) { why = "التداول الآلي مغلق في المنصة"; return false; }
   return true;
  }

//==================================================================== SIGNAL / REINFORCE
int SignalDir()
  {
   if(!g_statsOK) return 0;
   // REVERSAL: Z high => A leading => FOLLOW it: Buy A / Sell B
   if(g_zClosed >= InpEntryZ && (!InpUseRSIFilter || g_rsiA - g_rsiB >= InpRSIGap))  return 1;
   if(g_zClosed <= -InpEntryZ && (!InpUseRSIFilter || g_rsiB - g_rsiA >= InpRSIGap)) return -1;
   return 0;
  }

void EvalReinforce()
  {
   g_cLossA = (g_layersA > 0 && g_pnlA < -InpMinLegLoss);
   g_cLossB = (g_layersB > 0 && g_pnlB < -InpMinLegLoss);
   g_needZ  = g_lastZ + InpZStep;
   if(InpZStep <= 0) g_cZ = true;
   else              g_cZ = (DirZ(g_zClosed, g_dir) >= g_needZ);
   g_barsSince = (g_lastLayerTime > 0) ? iBarShift(SA, InpTF, g_lastLayerTime, false) : 9999;
   g_cBars = (g_barsSince >= InpMinBarsBetween);
   g_cMax  = (InpMaxLayers <= 0 || g_layersA < InpMaxLayers);
  }

bool ReinforceReady()
  {
   EvalReinforce();
   return (g_cLossA && g_cLossB && g_cZ && g_cBars && g_cMax);
  }

void OnNewBar()
  {
   string why = "";
   if(g_layersA == 0 && g_layersB == 0)
     {
      if(InpEntryMode != ENTRY_SIGNAL) return;   // continuous modes open from TryContinuous()
      int sig = SignalDir();
      if(sig == 0) return;
      if(!EntryAllowed(why)) { g_event = "إشارة مرفوضة: " + why; return; }
      OpenLayer(sig, 1);
     }
   else if(InpUseReinforce && g_layersA > 0 && g_layersA == g_layersB && !g_mixed)
     {
      if(!ReinforceReady()) return;
      if(!EntryAllowed(why)) { g_event = "تعزيز مؤجل: " + why; return; }
      OpenLayer(g_dir, g_layersA + 1);
     }
  }

//==================================================================== CONTINUOUS RE-OPEN
int ContDir()
  {
   if(InpEntryMode == ENTRY_CONT_FIXED) return (int)InpFixedDir;
   if(!g_statsOK) return 0;
   if(MathAbs(g_zClosed) < InpContMinZ) return 0;
   return (g_zClosed >= 0) ? 1 : -1;   // REVERSAL: A above (Z>=0) => Buy A / Sell B ; A below => Sell A / Buy B
  }

void TryContinuous()
  {
   if(InpEntryMode == ENTRY_SIGNAL) return;
   if(g_layersA > 0 || g_layersB > 0) return;
   if(g_mixed) return;
   if(TimeLocal() < g_nextTry) return;

   string why = "";
   if(!EntryAllowed(why)) { g_event = "متكرر بانتظار: " + why; return; }
   int dir = ContDir();
   if(dir == 0)
     {
      g_event = g_statsOK ? "متكرر بانتظار: |Z| أقل من " + M2(InpContMinZ) : "متكرر بانتظار: تحميل البيانات";
      return;
     }
   if(!EnableTrading)
     {
      g_event = "متكرر (معطّل): كان سيفتح " + ((dir > 0) ? "شراء A / بيع B" : "بيع A / شراء B");
      g_nextTry = TimeLocal() + 60;
      return;
     }
   if(!OpenLayer(dir, 1, false, true)) g_nextTry = TimeLocal() + MathMax(InpRetrySec, 5);
  }

//==================================================================== SIZING
// money value of a price move (account currency). Falls back to contract-size math when the
// broker reports tick value 0 (seen on Exness cent indices: Tick size 0.00 / Tick value 0)
double MoveValue(string s, double lots, double from, double to)
  {
   double v = 0;
   if(OrderCalcProfit(ORDER_TYPE_BUY, s, lots, from, to, v) && v != 0) return v;
   double cs = SymbolInfoDouble(s, SYMBOL_TRADE_CONTRACT_SIZE);
   if(cs <= 0) return 0;
   v = (to - from) * cs * lots;                       // profit currency (USD)
   string acc = AccountInfoString(ACCOUNT_CURRENCY);
   string pc  = SymbolInfoString(s, SYMBOL_CURRENCY_PROFIT);
   if((acc == "USC" || acc == "USc") && pc == "USD") v *= 100.0;   // cent account
   return v;
  }

double HedgeRatio()
  {
   double pA = Bid(SA), pB = Bid(SB);
   if(pA <= 0 || pB <= 0) return 0;
   double vA = 0, vB = 0;
   if(InpHedgeMode == HEDGE_DOLLAR)
     {
      vA = MoveValue(SA, 1.0, pA, pA * 1.01);
      vB = MoveValue(SB, 1.0, pB, pB * 1.01);
     }
   else
     {
      double aA = Buf(hAtrA, 1), aB = Buf(hAtrB, 1);
      if(aA <= 0 || aB <= 0) return 0;
      vA = MoveValue(SA, 1.0, pA, pA + aA);
      vB = MoveValue(SB, 1.0, pB, pB + aB);
     }
   return (vA > 0 && vB > 0) ? vA / vB : 0;
  }

bool CalcLots(int layer, double &lotA, double &lotB)
  {
   // same lots on every layer (no multiplier)
   g_minWarnA = false; g_minWarnB = false;
   string m = "";
   if(!ValidLot(SA, g_lotA, lotA, m)) { g_minWarnA = true; return false; }
   if(g_lotMode == LOT_AUTO)
     {
      // balanced: B carries the same money per 1% move as A (from broker contract data)
      double r = HedgeRatio();
      if(r <= 0) return false;
      if(!ValidLot(SB, lotA * r, lotB, m)) { g_minWarnB = true; return false; }
      return true;
     }
   if(!ValidLot(SB, g_lotB, lotB, m)) { g_minWarnB = true; return false; }
   return true;
  }

double ValueOnePct()   // what a 1% divergence pays on a base layer (USC)
  {
   double la, lb;
   if(!CalcLots(1, la, lb)) return 0;
   double pA = Bid(SA), pB = Bid(SB), vA = 0, vB = 0;
   if(pA <= 0 || pB <= 0) return 0;
   vA = MoveValue(SA, la, pA, pA * 1.01);
   vB = MoveValue(SB, lb, pB, pB * 1.01);
   return (vA + vB) / 2.0;
  }

double SwapMoney(string s, double lots, bool isLong)
  {
   if(lots <= 0) return 0;
   if(SymbolInfoInteger(s, SYMBOL_SWAP_MODE) != SYMBOL_SWAP_MODE_POINTS) return 0;
   double pts = SymbolInfoDouble(s, isLong ? SYMBOL_SWAP_LONG : SYMBOL_SWAP_SHORT);
   if(pts == 0) return 0;
   double p = Bid(s), pt = SymbolInfoDouble(s, SYMBOL_POINT), v = 0;
   if(p <= 0) return 0;
   v = MoveValue(s, lots, p, p + pts * pt);
   return v;
  }

double TargetUSC()
  {
   if(InpTPMode == TP_FIXED_USC) return InpBasketTP_USC;
   if(g_lotA <= 0) return 0;
   return InpTPPerBase * (g_lotsA / g_lotA);
  }

//==================================================================== FULL CONTROL (broker pre-check)
string RetcodeAr(uint rc)
  {
   switch(rc)
     {
      case 10004: return "إعادة تسعير";
      case 10006: return "الطلب مرفوض من الوسيط";
      case 10013: return "طلب غير صالح";
      case 10014: return "حجم اللوت غير مقبول";
      case 10015: return "سعر غير صالح";
      case 10016: return "وقف/هدف غير صالح";
      case 10017: return "التداول معطّل على الرمز";
      case 10018: return "السوق مغلق";
      case 10019: return "رصيد/هامش غير كافٍ";
      case 10020: return "تغيّر السعر";
      case 10021: return "لا توجد أسعار";
      case 10024: return "طلبات كثيرة جداً";
      case 10026: return "التداول الآلي معطّل من السيرفر";
      case 10027: return "التداول الآلي معطّل في المنصة";
      case 10030: return "نوع التنفيذ غير مدعوم";
      case 10031: return "لا يوجد اتصال بالسيرفر";
      case 10033: return "تجاوز حد الأوامر المعلقة";
      case 10034: return "تجاوز حد الحجم على الرمز";
      case 10040: return "تجاوز حد عدد الصفقات";
      case 10042: return "مسموح الشراء فقط";
      case 10043: return "مسموح البيع فقط";
      case 10044: return "مسموح الإغلاق فقط";
     }
   return "رمز " + IntegerToString(rc);
  }

bool PreCheckLeg(string s, ENUM_ORDER_TYPE t, double lot, string &why)
  {
   MqlTradeRequest req;
   MqlTradeCheckResult cr;
   ZeroMemory(req);
   ZeroMemory(cr);
   req.action       = TRADE_ACTION_DEAL;
   req.symbol       = s;
   req.volume       = lot;
   req.type         = t;
   req.price        = (t == ORDER_TYPE_BUY) ? Ask(s) : Bid(s);
   req.deviation    = InpSlippage;
   req.magic        = MagicBase;
   req.type_filling = GetSupportedFilling(s);
   if(req.price <= 0) { why = s + ": لا توجد أسعار"; return false; }
   if(!OrderCheck(req, cr))
     {
      // volume verdict comes from the terminal's symbol data; with local lot check OFF the real server decides
      if(!InpLocalLotCheck && (cr.retcode == 10014 || cr.retcode == 10034))
        {
         PrintFormat("NEXORA IOR | فحص المنصة اعترض على لوت %s %.2f (%u) - يُرسل للوسيط ليقرر", s, lot, cr.retcode);
         return true;
        }
      why = s + " " + DoubleToString(lot, 2) + ": " + RetcodeAr(cr.retcode) + " (" + IntegerToString(cr.retcode) + ")";
      return false;
     }
   return true;
  }

void Reject(string why)
  {
   g_reject = TimeToString(TimeCurrent(), TIME_MINUTES) + " " + why;
   g_event  = "رفض: " + why;
   if(InpFullControl)
     {
      g_paused = true;   // stop auto entries/reinforcement until you press resume
      g_event += " - البوت متوقف، اضغط استئناف";
     }
   Notify(g_event);
  }

//==================================================================== EXECUTION
bool SendLeg(string s, ENUM_ORDER_TYPE t, double lot, string cmt, ulong &posId)
  {
   posId = 0;
   trade.SetTypeFilling(GetSupportedFilling(s));
   double price = (t == ORDER_TYPE_BUY) ? Ask(s) : Bid(s);
   if(price <= 0) return false;
   g_lastSendErr = "";
   if(!trade.PositionOpen(s, t, lot, price, 0, 0, cmt))
     {
      g_lastSendErr = s + ": " + RetcodeAr(trade.ResultRetcode()) + " (" + IntegerToString(trade.ResultRetcode()) + ")";
      PrintFormat("NEXORA IOR | فشل فتح %s %s %.2f rc=%u %s", s, EnumToString(t), lot,
                  trade.ResultRetcode(), trade.ResultRetcodeDescription());
      return false;
     }
   uint rc = trade.ResultRetcode();
   if(rc != TRADE_RETCODE_DONE && rc != TRADE_RETCODE_DONE_PARTIAL)
     {
      g_lastSendErr = s + ": " + RetcodeAr(rc) + " (" + IntegerToString(rc) + ")";
      return false;
     }
   ulong deal = trade.ResultDeal();
   if(deal > 0 && HistoryDealSelect(deal)) posId = (ulong)HistoryDealGetInteger(deal, DEAL_POSITION_ID);
   if(posId == 0) posId = trade.ResultOrder();
   return true;
  }

bool ClosePos(ulong tk)
  {
   if(!PositionSelectByTicket(tk)) return true;
   trade.SetTypeFilling(GetSupportedFilling(PositionGetString(POSITION_SYMBOL)));
   if(!trade.PositionClose(tk, InpSlippage)) return false;
   uint rc = trade.ResultRetcode();
   return (rc == TRADE_RETCODE_DONE || rc == TRADE_RETCODE_DONE_PARTIAL);
  }

bool OpenLayer(int dir, int layer, bool forced = false, bool cont = false)
  {
   double lotA, lotB;
   if(!CalcLots(layer, lotA, lotB))
     {
      if(InpFullControl) Reject("لوت غير صالح (خارج حدود الوسيط)");
      else g_event = "فشل حساب اللوت";
      return false;
     }

   ENUM_ORDER_TYPE tA = (dir > 0) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   ENUM_ORDER_TYPE tB = (dir > 0) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
   string dA = (dir > 0) ? "شراء" : "بيع";
   string dB = (dir > 0) ? "بيع" : "شراء";

   double mA = 0, mB = 0;
   double pA = (tA == ORDER_TYPE_BUY) ? Ask(SA) : Bid(SA);
   double pB = (tB == ORDER_TYPE_BUY) ? Ask(SB) : Bid(SB);
   if(!OrderCalcMargin(tA, SA, lotA, pA, mA) || !OrderCalcMargin(tB, SB, lotB, pB, mB))
     { g_event = "فشل حساب الهامش"; return false; }
   if(AccountInfoDouble(ACCOUNT_MARGIN_FREE) < (mA + mB) * InpMarginBuffer)
     {
      string w = StringFormat("هامش غير كافٍ للطبقة %d (مطلوب %.2f × %.1f، المتاح %.2f)",
                              layer, mA + mB, InpMarginBuffer, AccountInfoDouble(ACCOUNT_MARGIN_FREE));
      if(InpFullControl) Reject(w);
      else { g_event = w; Notify(g_event); }
      return false;
     }

   string info = StringFormat("%sطبقة %d: %s A %.2f / %s B %.2f | Z %.2f",
                              forced ? "يدوي - " : (cont ? "متكرر - " : ""), layer, dA, lotA, dB, lotB, g_zClosed);
   if(!EnableTrading)
     {
      g_event = "إشارة (معطّل) " + info;
      Notify(g_event);
      return false;
     }

   // FULL CONTROL: broker checks BOTH legs before anything is sent
   if(InpFullControl)
     {
      string why = "";
      if(!PreCheckLeg(SA, tA, lotA, why) || !PreCheckLeg(SB, tB, lotB, why))
        {
         Reject("الوسيط رفض قبل الفتح - " + why);
         return false;
        }
     }

   string cmt = StringFormat("NXIR L%d%s Z%.2f", layer, forced ? "F" : (cont ? "C" : ""), DirZ(g_zClosed, dir));
   ulong posA = 0, posB = 0;
   if(!SendLeg(SA, tA, lotA, cmt, posA))
     {
      if(InpFullControl) Reject("فشل الساق A - " + g_lastSendErr);
      else { g_event = "فشل فتح الساق A " + g_lastSendErr; Notify(g_event); }
      return false;
     }

   bool okB = false;
   int triesB = InpFullControl ? 1 : 3;   // full control: no retries
   for(int i = 0; i < triesB && !okB; i++)
     {
      okB = SendLeg(SB, tB, lotB, cmt, posB);
      if(!okB) Sleep(300);
     }
   if(!okB)
     {
      bool c = false;
      for(int i = 0; i < 3 && !c; i++)
        {
         c = ClosePos(posA);
         if(!c) Sleep(300);
        }
      string w = (c ? "فشل الساق B - أُغلقت A ولم يُفتح شيء | " : "تحذير: الساق A مفتوحة وحدها! | ") + g_lastSendErr;
      SyncFromPositions();
      if(InpFullControl) Reject(w);
      else { g_event = w; Notify(g_event); }
      return false;
     }

   if(layer == 1) { g_peak = 0; g_trailOn = false; SaveTrail(); }
   g_event = info;
   Notify("فتح " + info);
   SyncFromPositions();
   return true;
  }

bool CloseAll(string reason)
  {
   double netBefore = g_pnlA + g_pnlB;
   bool hadPos = (g_layersA > 0 || g_layersB > 0);
   bool all = true;
   for(int pass = 0; pass < 3; pass++)
     {
      ulong tks[];
      int n = 0;
      for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
         ulong tk = PositionGetTicket(i);
         if(tk == 0) continue;
         if((ulong)PositionGetInteger(POSITION_MAGIC) != MagicBase) continue;
         string s = PositionGetString(POSITION_SYMBOL);
         if(s != SA && s != SB) continue;
         ArrayResize(tks, n + 1);
         tks[n++] = tk;
        }
      if(n == 0) break;
      all = true;
      for(int i = 0; i < n; i++)
         if(!ClosePos(tks[i])) all = false;
      if(all) break;
      Sleep(300);
     }
   g_peak = 0;
   g_trailOn = false;
   SaveTrail();
   SyncFromPositions();
   if(hadPos) { g_cycles++; g_cyclesPnl += netBefore; }
   g_nextTry = TimeLocal() + MathMax(InpReopenDelaySec, 0);   // 0 = re-open on the same tick
   g_event = (all ? "إغلاق: " : "إغلاق جزئي! ") + reason;
   Notify(g_event);
   return all;
  }

//==================================================================== EXITS (profit only)
void ManageExits()
  {
   if(g_layersA == 0 && g_layersB == 0) return;
   double net = g_pnlA + g_pnlB;
   double tp  = TargetUSC();

   if(!g_trailOn && tp > 0 && net >= tp)
     {
      if(InpTrailGivePct <= 0) { CloseAll("هدف السلة " + M2(net) + " USC"); return; }
      g_trailOn = true;
      g_peak = net;
      SaveTrail();
      g_event = "بدأ تتبّع الربح عند " + M2(net);
     }

   if(g_trailOn)
     {
      if(net > g_peak) { g_peak = net; SaveTrail(); }
      double floorV = g_peak * (1.0 - InpTrailGivePct / 100.0);
      if(net <= floorV)
        {
         if(net > 0) { CloseAll("تتبّع: قمة " + M2(g_peak) + " / إغلاق " + M2(net)); return; }
         g_trailOn = false;   // gap into loss: no stop, keep holding
         g_peak = 0;
         SaveTrail();
        }
     }

   // Z-exit only if the basket was opened on the stretched side (a manual open near/against the mean uses target+trail only)
   if(InpUseZExit && g_statsOK && g_dir != 0 && g_firstZ > InpExitZ)
     {
      bool rev = (DirZ(g_zLive, g_dir) <= InpExitZ);
      if(rev && net >= InpZExitMinProfit) { CloseAll("عودة Z (" + M2(g_zLive) + ") بربح " + M2(net)); return; }
     }
  }

//==================================================================== MANUAL (FORCED) OPEN
// direction from the market right now: Nasdaq above (Z>=0) => Sell A / Buy B, below => Buy A / Sell B
int MarketDir() { return g_statsOK ? ((g_zLive >= 0) ? 1 : -1) : 0; }   // REVERSAL

string MarketBtnText()
  {
   int d = MarketDir();
   if(d == 0) return "فتح حسب السوق (جاري تحميل البيانات)";
   return "فتح حسب السوق: " + ((d > 0) ? "شراء A / بيع B" : "بيع A / شراء B") + "   (Z " + DoubleToString(g_zLive, 2) + ")";
  }

void ManualOpen(int dir)
  {
   string side = (dir > 0) ? "شراء A / بيع B" : "بيع A / شراء B";
   if(g_layersA > 0 || g_layersB > 0)
     {
      g_event = "فتح يدوي مرفوض: توجد سلة مفتوحة - التعزيز يتولاه البوت";
      return;
     }
   if(!EnableTrading) { g_event = "فتح يدوي مرفوض: التداول معطّل (EnableTrading)"; return; }
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)) { g_event = "فتح يدوي مرفوض: التداول الآلي مغلق في المنصة"; return; }
   if(!InpManualIgnoreFlt)
     {
      string why = "";
      if(!SessionOK(why)) { g_event = "فتح يدوي مرفوض: " + why; return; }
      if(!SpreadOK(SA, g_spEmaA) || !SpreadOK(SB, g_spEmaB)) { g_event = "فتح يدوي مرفوض: سبريد مرتفع"; return; }
     }
   if(InpManualConfirm && !MQLInfoInteger(MQL_TESTER))
     {
      string q = "فتح يدوي إجباري: " + side + "\nZ الحالي = " + M2(g_zClosed) +
                 "\nبعد الفتح يتولى البوت التعزيز والخروج تلقائياً. متابعة؟";
      if(MessageBox(q, "NEXORA IndexOpposite Reversal", MB_YESNO | MB_ICONQUESTION) != IDYES) return;
     }
   OpenLayer(dir, 1, true);
  }

//==================================================================== PANEL
// Layout is defined right-to-left (xr = distance of an element's RIGHT edge from the panel side).
// For the left side the same layout is mirrored, so the Arabic RTL look is kept.
bool PanelLeft() { return InpPanelSide == PANEL_LEFT; }
ENUM_BASE_CORNER PanelCorner() { return PanelLeft() ? CORNER_LEFT_UPPER : CORNER_RIGHT_UPPER; }

int LblX(int xr)              // right-anchored label: x of its right edge
  {
   return PanelLeft() ? (2 * InpPanelX + PW - xr) : xr;
  }

int BoxX(int xr, int w)       // rect/button: XDISTANCE for the active corner
  {
   return PanelLeft() ? (2 * InpPanelX + PW - xr - w) : (xr + w);
  }

void Lbl(string id, string txt, int xr, int y, color c, int sz, string font = "Arial")
  {
   string n = PFX + id;
   if(ObjectFind(0, n) < 0)
     {
      ObjectCreate(0, n, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, n, OBJPROP_CORNER, PanelCorner());
      ObjectSetInteger(0, n, OBJPROP_ANCHOR, ANCHOR_RIGHT_UPPER);
      ObjectSetInteger(0, n, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, n, OBJPROP_HIDDEN, true);
     }
   ObjectSetInteger(0, n, OBJPROP_XDISTANCE, LblX(xr));
   ObjectSetInteger(0, n, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, n, OBJPROP_COLOR, c);
   ObjectSetInteger(0, n, OBJPROP_FONTSIZE, sz);
   ObjectSetString(0, n, OBJPROP_FONT, font);
   ObjectSetString(0, n, OBJPROP_TEXT, (txt == "") ? " " : txt);
  }

void Rect(string id, int xr, int y, int w, int h, color bg, color brd)
  {
   string n = PFX + id;
   if(ObjectFind(0, n) < 0)
     {
      ObjectCreate(0, n, OBJ_RECTANGLE_LABEL, 0, 0, 0);
      ObjectSetInteger(0, n, OBJPROP_CORNER, PanelCorner());
      ObjectSetInteger(0, n, OBJPROP_BORDER_TYPE, BORDER_FLAT);
      ObjectSetInteger(0, n, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, n, OBJPROP_HIDDEN, true);
     }
   ObjectSetInteger(0, n, OBJPROP_XDISTANCE, BoxX(xr, w));
   ObjectSetInteger(0, n, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, n, OBJPROP_XSIZE, w);
   ObjectSetInteger(0, n, OBJPROP_YSIZE, h);
   ObjectSetInteger(0, n, OBJPROP_BGCOLOR, bg);
   ObjectSetInteger(0, n, OBJPROP_COLOR, brd);
  }

void Btn(string id, string txt, int xr, int y, int w, int h, color bg)
  {
   string n = PFX + id;
   if(ObjectFind(0, n) < 0) ObjectCreate(0, n, OBJ_BUTTON, 0, 0, 0);
   ObjectSetInteger(0, n, OBJPROP_CORNER, PanelCorner());
   ObjectSetInteger(0, n, OBJPROP_XDISTANCE, BoxX(xr, w));
   ObjectSetInteger(0, n, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, n, OBJPROP_XSIZE, w);
   ObjectSetInteger(0, n, OBJPROP_YSIZE, h);
   ObjectSetInteger(0, n, OBJPROP_BGCOLOR, bg);
   ObjectSetInteger(0, n, OBJPROP_BORDER_COLOR, CBrd);
   ObjectSetInteger(0, n, OBJPROP_COLOR, clrWhite);
   ObjectSetInteger(0, n, OBJPROP_FONTSIZE, InpFontSize);
   ObjectSetString(0, n, OBJPROP_FONT, "Arial Bold");
   ObjectSetString(0, n, OBJPROP_TEXT, txt);
   ObjectSetInteger(0, n, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, n, OBJPROP_HIDDEN, true);
   ObjectSetInteger(0, n, OBJPROP_STATE, false);
  }

void EditBox(string id, string txt, int xr, int y, int w, int h, bool ro)
  {
   string n = PFX + id;
   bool isNew = (ObjectFind(0, n) < 0);
   if(isNew) ObjectCreate(0, n, OBJ_EDIT, 0, 0, 0);
   ObjectSetInteger(0, n, OBJPROP_CORNER, PanelCorner());
   ObjectSetInteger(0, n, OBJPROP_XDISTANCE, BoxX(xr, w));
   ObjectSetInteger(0, n, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, n, OBJPROP_XSIZE, w);
   ObjectSetInteger(0, n, OBJPROP_YSIZE, h);
   ObjectSetInteger(0, n, OBJPROP_BGCOLOR, ro ? C'45,45,45' : C'35,45,60');
   ObjectSetInteger(0, n, OBJPROP_BORDER_COLOR, ro ? CBrd : CGold);
   ObjectSetInteger(0, n, OBJPROP_COLOR, ro ? CKey : clrWhite);
   ObjectSetInteger(0, n, OBJPROP_FONTSIZE, InpFontSize);
   ObjectSetString(0, n, OBJPROP_FONT, "Arial Bold");
   ObjectSetInteger(0, n, OBJPROP_ALIGN, ALIGN_CENTER);
   ObjectSetInteger(0, n, OBJPROP_READONLY, ro);
   ObjectSetInteger(0, n, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, n, OBJPROP_HIDDEN, true);
   ObjectSetString(0, n, OBJPROP_TEXT, txt);
  }

int CtrlY() { return InpPanelY + 32 + ROWS * RH + 4; }

void DrawLotControls()
  {
   int y = CtrlY();
   Lbl("cLA", "لوت A", InpPanelX + 10,  y + 4, CKey, InpFontSize);
   EditBox("edLotA", M2(g_lotA), InpPanelX + 58, y, 66, 22, g_lotLock);
   Lbl("cLB", "لوت B", InpPanelX + 132, y + 4, CKey, InpFontSize);
   bool bal = (g_lotMode == LOT_AUTO);
   string bTxt = M2(g_lotB);
   if(bal) { double la = 0, lb = 0; bTxt = CalcLots(1, la, lb) ? M2(lb) : "—"; }
   EditBox("edLotB", bTxt, InpPanelX + 180, y, 66, 22, g_lotLock || bal);
   Btn("btnLotMode", bal ? "متوازن" : "ثابت", InpPanelX + 254, y - 1, 74, 24, bal ? C'40,70,110' : C'110,80,20');
   Btn("btnLotLock", g_lotLock ? "مقفل" : "قفل", InpPanelX + 334, y - 1, 76, 24, g_lotLock ? C'150,40,40' : C'60,60,60');
  }

int RowY(int i) { return InpPanelY + 32 + i * RH; }

void Row(int i, string key, string val, color vc, color kc = C'160,160,160')
  {
   Lbl("k" + (string)i, key, InpPanelX + 10,    RowY(i), kc, InpFontSize);
   Lbl("v" + (string)i, val, InpPanelX + VAL_X, RowY(i), vc, InpFontSize);
  }

void DrawBar(int y, double p)
  {
   int bw = 200;
   Rect("barbg", InpPanelX + VAL_X, y + 3, bw, 11, C'45,45,45', C'70,70,70');
   int fw = (int)MathMax(1, MathRound(bw * p));
   color fc = (p >= 1.0) ? CGold : C'0,140,200';
   if(p <= 0) fc = C'45,45,45';
   Rect("barfg", InpPanelX + VAL_X, y + 3, fw, 11, fc, fc);
  }

void BuildPanel()
  {
   int h = 32 + ROWS * RH + 136;
   Rect("bg", InpPanelX, InpPanelY, PW, h, CBg, CBrd);
   Lbl("title", "NEXORA IndexOpposite REVERSAL v1.00", InpPanelX + 10, InpPanelY + 7, CGold, InpFontSize + 2, "Arial Bold");
   DrawLotControls();
   int by = RowY(ROWS) + 38;
   Btn("btnClose", "إغلاق الكل",          InpPanelX + 10,  by, 130, 24, C'150,40,40');
   Btn("btnPause", "إيقاف مؤقت / استئناف", InpPanelX + 150, by, 160, 24, C'50,60,80');
   Btn("btnBuyA",  "فتح يدوي: شراء A / بيع B", InpPanelX + 10,  by + 32, 195, 24, C'0,110,70');
   Btn("btnSellA", "فتح يدوي: بيع A / شراء B", InpPanelX + 215, by + 32, 195, 24, C'140,45,45');
   Btn("btnMarket", MarketBtnText(), InpPanelX + 10, by + 64, 400, 26, C'20,90,200');
   UpdatePanel();
  }

void UpdatePanel()
  {
   int r = 0;
   if(g_layersA > 0) EvalReinforce();

   string st; color sc;
   if(!EnableTrading)  { st = "معطّل - إشارات فقط"; sc = CWarn; }
   else if(g_paused)   { st = "موقوف مؤقتاً (الخروج يعمل)"; sc = CWarn; }
   else                { st = "تداول مفعّل"; sc = CPos; }
   Row(r++, "الحالة", st, sc);
   string em = "إشارة Z + RSI";
   if(InpEntryMode == ENTRY_CONT_ZSIDE) em = "متكرر - أعلى/أسفل";
   if(InpEntryMode == ENTRY_CONT_FIXED) em = (InpFixedDir == FIXED_BUY_A) ? "متكرر - A شراء دائم / B بيع" : "متكرر - A بيع دائم / B شراء";
   Row(r++, "وضع الدخول", em + "  | دورات " + IntegerToString(g_cycles) + " = " + M2(g_cyclesPnl) + " USC",
       (InpEntryMode == ENTRY_SIGNAL) ? CTxt : CGold);
   Row(r++, "الزوج", "A = " + SA + "   |   B = " + SB, CTxt);
   Row(r++, "Z لحظي / مغلق",
       g_statsOK ? DoubleToString(g_zLive, 2) + "  /  " + DoubleToString(g_zClosed, 2) : "جاري التحميل...",
       (MathAbs(g_zLive) >= InpEntryZ) ? CGold : CTxt);
   Row(r++, "RSI", "A " + DoubleToString(g_rsiA, 1) + "   |   B " + DoubleToString(g_rsiB, 1), CTxt);

   // proximity bar
   double p = 0;
   string pk;
   if(g_layersA > 0 && InpZStep > 0)
     {
      double zd = DirZ(g_zLive, g_dir);
      if(g_needZ > 0) p = MathMin(1.0, MathMax(0, zd) / g_needZ);
      else            p = (zd >= g_needZ) ? 1.0 : 0.0;
      pk = "القرب من التعزيز ";
     }
   else
     {
      p  = (InpEntryZ > 0) ? MathMin(1.0, MathAbs(g_zLive) / InpEntryZ) : 0;
      pk = "القرب من الدخول ";
     }
   Row(r, pk + IntegerToString((int)MathRound(p * 100)) + "%", "", CTxt);
   DrawBar(RowY(r), p);
   r++;

   string ds = "لا صفقات - بانتظار الإشارة";
   if(g_dir > 0) ds = "شراء A + بيع B";
   if(g_dir < 0) ds = "بيع A + شراء B";
   if(g_dir != 0) ds += g_forced ? "  (فتح يدوي)" : (g_cont ? "  (متكرر)" : "  (إشارة)");
   Row(r++, "الاتجاه", ds, (g_dir == 0) ? CKey : CGold);
   Row(r++, "الطبقات", IntegerToString(g_layersA) + " / " + (InpMaxLayers > 0 ? IntegerToString(InpMaxLayers) : "بلا حد"), CTxt);
   Row(r++, "اللوتات المفتوحة", "A " + M2(g_lotsA) + "   |   B " + M2(g_lotsB), CTxt);
   Row(r++, InpLocalLotCheck ? "المنيموم / الخطوة" : "منيموم المنصة (للعلم)",
       "A " + M2(VMin(SA)) + " / " + M2(VStep(SA)) + "   |   B " + M2(VMin(SB)) + " / " + M2(VStep(SB)), CTxt);
   double nla = 0, nlb = 0;
   int nextL = g_layersA + 1;
   bool nok = CalcLots(nextL, nla, nlb);
   string nx = nok ? ("L" + IntegerToString(nextL) + ":  A " + M2(nla) + "  |  B " + M2(nlb)) : "—";
   if(!nok) nx = "لوت غير صالح - راجع الخانات";
   Row(r++, (g_lotMode == LOT_AUTO) ? "لوت متوازن لكل طبقة" : "لوت ثابت لكل طبقة", nx, nok ? CTxt : CNeg);
   Row(r++, "ربح الساق A", M2(g_pnlA) + " USC", PC(g_pnlA));
   Row(r++, "ربح الساق B", M2(g_pnlB) + " USC", PC(g_pnlB));
   double net = g_pnlA + g_pnlB;
   Row(r++, "صافي السلة", M2(net) + " USC", PC(net));

   string ts = (g_layersA > 0 || InpTPMode == TP_FIXED_USC) ? M2(TargetUSC()) + " USC" : "—";
   if(g_trailOn) ts += "  | تتبّع: قمة " + M2(g_peak) + " ← " + M2(g_peak * (1.0 - InpTrailGivePct / 100.0));
   Row(r++, "الهدف", ts, g_trailOn ? CGold : CTxt);

   bool inPos = (g_layersA > 0);
   bool ready = inPos && g_cLossA && g_cLossB && g_cZ && g_cBars && g_cMax;
   Row(r++, "شروط التعزيز", !inPos ? "—" : (ready ? "جاهز - عند إغلاق الشمعة" : "غير مكتمل"),
       !inPos ? CKey : (ready ? CGold : CKey), CGold);
   Row(r++, "  خسارة الساق A", inPos ? YN(g_cLossA) : "—", inPos ? YC(g_cLossA) : CKey);
   Row(r++, "  خسارة الساق B", inPos ? YN(g_cLossB) : "—", inPos ? YC(g_cLossB) : CKey);
   Row(r++, "  تمدد Z",
       inPos ? ("مطلوب " + M2(InpZStep > 0 ? g_needZ : 0) + "  |  مغلق " + M2(DirZ(g_zClosed, g_dir))) : "—",
       inPos ? YC(g_cZ) : CKey);
   Row(r++, "  فاصل الشموع", inPos ? (IntegerToString(g_barsSince) + " / " + IntegerToString(InpMinBarsBetween)) : "—",
       inPos ? YC(g_cBars) : CKey);
   Row(r++, "  سقف الطبقات", inPos ? (g_cMax ? "ضمن الحد" : "بلغ الحد") : "—", inPos ? YC(g_cMax) : CKey);

   string sp = "A " + DoubleToString(SpreadPts(SA), 0) + "/" + DoubleToString(g_spEmaA, 0) +
               "   |   B " + DoubleToString(SpreadPts(SB), 0) + "/" + DoubleToString(g_spEmaB, 0);
   bool spOK = SpreadOK(SA, g_spEmaA) && SpreadOK(SB, g_spEmaB);
   Row(r++, "السبريد (حالي/متوسط)", sp, spOK ? CTxt : CNeg);

   string why = "";
   bool sess = SessionOK(why);
   Row(r++, "الجلسة", sess ? "مسموح الدخول" : why, sess ? CPos : CWarn);

   double sw = 0;
   if(g_dir != 0) sw = SwapMoney(SA, g_lotsA, g_dir > 0) + SwapMoney(SB, g_lotsB, g_dir < 0);
   Row(r++, "سواب يومي تقديري", (g_dir != 0) ? M2(sw) + " USC (الجمعة ×3)" : "—", PC(sw));
   Row(r++, "قيمة تباعد 1% للطبقة", M2(ValueOnePct()) + " USC", CTxt);

   bool imb = (g_layersA != g_layersB);
   string bal = "السيقان متوازنة";
   if(imb)     bal = "عدد صفقات A لا يساوي B!";
   if(g_mixed) bal = "سلة مختلطة الاتجاه! تعزيز موقوف - الخروج بالهدف";
   Row(r++, (imb || g_mixed) ? "تحذير" : "التوازن", bal, (imb || g_mixed) ? CNeg : CPos);
   string fc = !InpFullControl ? "معطّل" : (g_reject == "" ? "مفعّل - لا يوجد رفض" : "مفعّل - توقف بسبب رفض");
   Row(r++, "التحكم الكامل", fc, !InpFullControl ? CKey : (g_reject == "" ? CPos : CNeg));
   Row(r++, "سبب الرفض", (g_reject == "") ? "—" : StringSubstr(g_reject, 0, 52), (g_reject == "") ? CKey : CNeg);
   Row(r++, "آخر حدث", StringSubstr(g_event, 0, 52), CTxt);

   for(; r < ROWS; r++) Row(r, "", "", CTxt);
   if(ObjectFind(0, PFX + "btnMarket") >= 0) ObjectSetString(0, PFX + "btnMarket", OBJPROP_TEXT, MarketBtnText());
   if(g_lotMode == LOT_AUTO && ObjectFind(0, PFX + "edLotB") >= 0)
     {
      double l1a = 0, l1b = 0;
      ObjectSetString(0, PFX + "edLotB", OBJPROP_TEXT, CalcLots(1, l1a, l1b) ? M2(l1b) : "—");
     }
   ChartRedraw();
  }

void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
  {
   if(id == CHARTEVENT_OBJECT_ENDEDIT)
     {
      if(sparam == PFX + "edLotA" || sparam == PFX + "edLotB")
        {
         bool isA = (sparam == PFX + "edLotA");
         string sym = isA ? SA : SB;
         string tx = ObjectGetString(0, sparam, OBJPROP_TEXT);
         StringReplace(tx, ",", ".");
         double v = StringToDouble(tx), out = 0;
         string msg = "";
         if(g_lotLock) g_event = "اللوت مقفل - اضغط فتح القفل أولاً";
         else if(!isA && g_lotMode == LOT_AUTO) g_event = "الوضع متوازن: لوت B يُحسب تلقائياً - اضغط «متوازن» للتحويل لثابت";
         else if(!ValidLot(sym, v, out, msg))
            g_event = "لوت " + (isA ? "A" : "B") + " مرفوض: " + msg + " (بقي " + M2(isA ? g_lotA : g_lotB) + ")";
         else
           {
            if(isA) g_lotA = out; else g_lotB = out;
            g_event = "لوت " + (isA ? "A" : "B") + " = " + M2(out) + (msg != "" ? "  (" + msg + ")" : "");
            SaveLots();
           }
         if(InpShowPanel) { DrawLotControls(); UpdatePanel(); }
        }
      return;
     }
   if(id != CHARTEVENT_OBJECT_CLICK) return;
   if(sparam == PFX + "btnLotMode")
     {
      ObjectSetInteger(0, sparam, OBJPROP_STATE, false);
      if(g_lotLock) g_event = "اللوت مقفل - اضغط «مقفل» أولاً";
      else
        {
         g_lotMode = (g_lotMode == LOT_AUTO) ? LOT_MANUAL : LOT_AUTO;
         SaveLots();
         g_event = (g_lotMode == LOT_AUTO) ? "اللوت: متوازن مع الوسيط" : "اللوت: ثابت يدوي";
        }
      DrawLotControls();
     }
   else if(sparam == PFX + "btnLotLock")
     {
      ObjectSetInteger(0, sparam, OBJPROP_STATE, false);
      g_lotLock = !g_lotLock;
      g_event = g_lotLock ? "تم قفل اللوت" : "تم فتح قفل اللوت";
      DrawLotControls();
     }
   else if(sparam == PFX + "btnClose")
     {
      ObjectSetInteger(0, sparam, OBJPROP_STATE, false);
      if(MessageBox("إغلاق كل صفقات البوت الآن؟", "NEXORA IndexOpposite Reversal", MB_YESNO | MB_ICONQUESTION) == IDYES)
         CloseAll("إغلاق يدوي");
     }
   else if(sparam == PFX + "btnMarket")
     {
      ObjectSetInteger(0, sparam, OBJPROP_STATE, false);
      int d = MarketDir();
      if(d == 0) g_event = "فتح حسب السوق: البيانات لم تُحمّل بعد";
      else ManualOpen(d);
     }
   else if(sparam == PFX + "btnBuyA")
     {
      ObjectSetInteger(0, sparam, OBJPROP_STATE, false);
      ManualOpen(1);
     }
   else if(sparam == PFX + "btnSellA")
     {
      ObjectSetInteger(0, sparam, OBJPROP_STATE, false);
      ManualOpen(-1);
     }
   else if(sparam == PFX + "btnPause")
     {
      ObjectSetInteger(0, sparam, OBJPROP_STATE, false);
      g_paused = !g_paused;
      if(!g_paused) g_reject = "";
      g_event = g_paused ? "إيقاف مؤقت - لا دخول ولا تعزيز" : "تم الاستئناف";
     }
   if(InpShowPanel) UpdatePanel();
  }
//+------------------------------------------------------------------+
