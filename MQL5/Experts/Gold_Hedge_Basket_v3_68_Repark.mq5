//+------------------------------------------------------------------+
//| Gold_Hedge_Basket_v3_68_Repark.mq5                               |
//| BUY+SELL seed hedge, graduated pending grid and individual targets.       |
//| MT5 HEDGING only. NEW Magic + isolated state for 40 pending slots.|
//+------------------------------------------------------------------+
#property strict
#property version   "3.68"
#property description "v3.68: parked side follows the losing side. v3.67: lock fix (no forced loss close on flat basket, no lock churn), guarded restart. v3.66 adaptive trend engine, dashboard, trend guard, net TP, auto fit."

#include <Trade/Trade.mqh>
#define LIMIT_PER_SIDE 40
#define LIMIT_SLOTS 80
CTrade trade;

// v3.54: ACCOUNT SCALING. The strategy was designed on an Exness CENT account
// (balance in USC, 1 cent lot = 0.01 standard lot). On a STANDARD USD account
// every lot and every money target is multiplied by 0.01 so the trades are
// IDENTICAL in real dollars. Prices, spacing, timing and logic do not change.
enum ENUM_GHB_SCALE
{
   GHB_SCALE_AUTO=0,      // FULL AUTO: measured from broker contract + account currency
   GHB_SCALE_CENT=1,      // CENT: original values x1
   GHB_SCALE_STANDARD=2,  // STANDARD: lots and money x0.01
   GHB_SCALE_CUSTOM=3     // CUSTOM: use the two factors below
};
input group "00 - Account scaling (strategy unchanged)"
input ENUM_GHB_SCALE InpAccountScaleMode = GHB_SCALE_AUTO;
input double InpCustomLotScale   = 0.01; // CUSTOM only: multiplier for every lot
input double InpCustomMoneyScale = 0.01; // CUSTOM only: multiplier for every money target
input bool   InpAutoFitToMargin  = true; // AUTO only: shrink size (same ratios) until it fits free margin
input double InpAutoFitUseFreeMargin = 0.80; // AUTO-FIT budget: share of free margin for seed check + rungs 1..10 of one side
double g_lot_scale=1.0;
double g_money_scale=1.0;

// v3.59 TREND GUARD - staged protection on FLOATING drawdown, no stop loss.
// v3.61: thresholds are REAL US cents of floating loss, independent of the
// auto-fit size: 200 = 200 USC on a cent account, 2.00 on a USD account.
input group "10 - Trend guard (no SL, no panic button)"
input bool   InpGuardEnabled        = true;
input double InpGuardStage1Design   = 200.0; // Stage 1: park trend-side pendings + stop cooling on that side
input double InpGuardStage2Design   = 400.0; // Stage 2: overlap closing (losers paid by profits) + break-even side exit
input double InpGuardStage3Design   = 600.0; // Stage 3: overlap/BE accept zero buffer (faster de-risking)
input double InpGuardStage4Design   = 800.0; // Stage 4: partial hedge lock
input double InpGuardExitRatio      = 0.50;  // Hysteresis: a stage ends only below threshold x this
input double InpParkDistancePrice   = 10.00; // Parked side pendings kept this far beyond normal (gold price units)
input double InpOverlapBufferDesign = 5.0;   // Stage 2 overlap must leave at least this net (real US cents)
input double InpLockRatio           = 0.60;  // Lock covers this share of net open exposure
input int    InpLockCooldownMinutes = 5;     // Minimum time between lock close and a new lock
// v3.67 LOCK FIX. On 2026-10-14 two locks were dumped at about -1,058 USC each the
// moment the grid went flat, and overlap kept cashing a winning lock only to
// re-open it at a worse price five minutes later.
input group "10b - v3.67 lock fix"
input int    InpMaxLocksPerEpisode     = 1;      // Locks opened per drawdown episode (0 = unlimited, old behaviour)
input bool   InpLockAsOverlapWinner    = false;  // Old behaviour: overlap may cash a winning lock
input double InpOrphanLockMaxLossDesign = 1500.0; // Lock left alone after the grid went flat: close at break-even, or at this loss (real US cents; 0 = no cap)
input int    InpRestartAfterGuardMinutes = 15;   // After a guarded basket goes flat, wait this long before a new basket
input bool   InpRestartOnlyInRange     = true;   // New basket only while the trend engine reads RANGE
// v3.68: the parked side was chosen once at stage 0->1 and never revisited. On
// 2026-10-14 16:2x SELL was parked, gold reversed, and BUY rungs kept filling
// against the move all the way to stage 4.
input group "10c - v3.68 re-park"
input bool   InpGuardRepark        = true;  // Parked side follows whichever side is losing more
input double InpReparkMinGapRatio  = 0.25;  // Switch only when the other side is worse by stage-1 threshold x this
int  g_guard_stage=0;
int  g_park_side=-1;   // -1 none, 0 BUY side parked, 1 SELL side parked
int      g_locks_this_episode=0;
datetime g_guard_flat_at=0;   // last time a basket went flat with the guard active
// v3.66 adaptive trend engine
input group "14 - Adaptive trend engine"
input bool   InpTrendEngine        = true;  // Detect trends and adapt (range behaviour unchanged)
input double InpTrendSlopeAtr      = 0.60;  // M15 EMA50 slope over 5 bars, in ATR units (2 points)
input double InpTrendAdxMin        = 25.0;  // ADX(14,M15) with matching DI (1 point)
input double InpTrendAtrExpansion  = 1.30;  // ATR14/ATR100 on M5 (1 point)
input int    InpTrendBurstFills    = 3;     // Rungs of one side filled within the window (1 point)
input int    InpTrendBurstMinutes  = 10;
input int    InpTrendScoreOn       = 3;     // Score to switch trend mode ON (max 5)
input int    InpTrendScoreOff      = 1;     // Score at/below which trend mode ends
input double InpTrendSpacingMult   = 2.0;   // Adverse-side limit spacing x this during a trend (1 = off)
input bool   InpMomentumLeg        = true;  // With-trend STOP leg during trends
input double InpMomLotDesign       = 1.0;   // Momentum lot, design units (scaled like the grid)
input double InpMomStopDistance    = 0.50;  // Stop entry distance beyond market (gold price units)
input double InpMomStepPrice       = 1.00;  // Next leg at least this far beyond the last filled leg
input double InpMomTPPrice         = 1.50;  // Momentum take profit distance (no SL; joins guard overlap)
input int    InpMomMaxOpen         = 3;     // Max open momentum legs
int g_trend_dir=0; // +1 up, -1 down, 0 range
double MomStopDistance() {return InpMomStopDistance;}
double MomStepDistance() {return InpMomStepPrice;}
double MomTPDistance()   {return InpMomTPPrice;}
// v3.60 dashboard state + event feed
input group "11 - Dashboard"
input bool InpDashboard = true; // Professional on-chart panel
input int  InpDashX     = 8;
input int  InpDashY     = 22;
input int  InpDashFont  = 9;    // 8 = compact, 10 = large
string   g_ev[8];
int      g_ev_n=0;
// v3.62 speed: batch refill, history cache, performance counters
input group "12 - Execution speed"
input int  InpRefillBatchMax   = 40;  // Rungs placed per pass before ONE geometry sweep (was 1)
input int  InpTickThrottleMs   = 250; // Full OnTick management at most every N ms (timer still every 1 s)
input bool InpHistoryCache     = true;// Reuse identical history selections inside one pass
input bool InpAsyncGridModify  = true;// v3.63: send grid moves without waiting ~1 s per order
input int  InpModifyBatchPerPass = 40;// Max grid modify requests sent per pass
input int    InpLiveWindowPerSide = 10;  // v3.64: nearest N rungs per side follow price exactly (40 = old behaviour)
input double InpFarLagPrice       = 2.50;// Far rungs move only if closer than plan, or this much farther (gold price units)
int g_far_lazy=0;

// v3.65 BACKTEST SUPPORT
input group "13 - Backtest / research"
input int  InpRungLotCapDesign = 10;   // Max rung lot in design units (10 = original 1..10). Change only on a NEW basket or in the tester
input bool InpWriteTestReport  = true; // Write a detailed report file when the test (or EA) stops
bool     g_tester=false, g_visual=true;
double   g_st_peak_eq=0, g_st_max_eq_dd=0, g_st_max_eq_dd_pct=0, g_st_min_float=0;
double   g_st_max_lots_buy=0, g_st_max_lots_sell=0, g_st_max_net_lots=0;
int      g_st_max_pos=0, g_st_max_pos_side=0;
long     g_st_stage_secs[5];
int      g_st_stage_hits[5];
int      g_st_overlaps=0, g_st_be_exits=0, g_st_locks=0, g_st_refills=0, g_st_seeds=0, g_st_pauses=0;
datetime g_st_last_t=0, g_st_start=0;
double   g_st_start_bal=0, g_st_min_margin_level=1e18;
datetime g_st_max_dd_time=0;

// v3.64 LIVE WINDOW. Rungs ranked beyond the window keep their broker price
// while they are safely BEHIND their plan (farther from market). They are
// moved only if they would sit closer than planned (never jump the queue) or
// if they lag more than InpFarLagPrice. Near rungs are always exact.
double FarLagDistance() {return InpFarLagPrice;}
bool FarRungAcceptable(const bool buy,const int rank,const double oldPrice,const double plan,const double tick)
{
   if(InpLiveWindowPerSide<=0 || InpLiveWindowPerSide>=LIMIT_PER_SIDE || rank<=InpLiveWindowPerSide) return false;
   double behind=(buy?plan-oldPrice:oldPrice-plan); // >0 = farther from market than plan
   return behind>-tick*0.5 && behind<=FarLagDistance()+tick*0.5;
}
ulong    g_mod_ticket[LIMIT_SLOTS]; double g_mod_price[LIMIT_SLOTS]; ulong g_mod_ms[LIMIT_SLOTS];
int      g_async_inflight=0, g_async_sent_total=0;
ulong    g_hs_ms=0; datetime g_hs_from=0, g_hs_to=0; int g_hs_deals=-1, g_hs_orders=-1;
ulong    g_hs_hits=0, g_hs_miss=0;
double   g_perf_tick_ema=0, g_perf_timer_ema=0, g_perf_tick_max=0, g_perf_timer_max=0;
datetime g_perf_max_reset=0;
int      g_req_this_min=0, g_req_last_min=0; datetime g_req_min_start=0;
datetime g_refill_times[64]; int g_refill_pos=0;
ulong    g_tp_ok_ids[256]; int g_tp_ok_pos=0;
ulong    g_last_tick_run_ms=0;
string   g_block_reason="";
datetime g_block_time=0;
bool     g_geo_verified=false, g_geo_prev=true;
bool GHBHistorySelect(const datetime from,const datetime to)
{
   ulong nowms=GetTickCount64();
   if(InpHistoryCache && !g_tester && from==g_hs_from && to<=g_hs_to && nowms-g_hs_ms<250 &&
      HistoryDealsTotal()==g_hs_deals && HistoryOrdersTotal()==g_hs_orders)
   {g_hs_hits++;return true;}
   bool ok=HistorySelect(from,to);
   g_hs_miss++;
   if(ok)
   {
      g_hs_ms=nowms;g_hs_from=from;g_hs_to=MathMax(to,TimeCurrent()+60);
      g_hs_deals=HistoryDealsTotal();g_hs_orders=HistoryOrdersTotal();
   }
   else g_hs_ms=0;
   return ok;
}
void GHBHistoryInvalidate() {g_hs_ms=0;}
void GHBCountRequest()
{
   datetime now=TimeCurrent();
   if(g_req_min_start==0) g_req_min_start=now;
   if(now-g_req_min_start>=60) {g_req_last_min=g_req_this_min;g_req_this_min=0;g_req_min_start=now;}
   g_req_this_min++;
}
void GHBPerf(const bool timer,const ulong us)
{
   double ms=us/1000.0;
   datetime now=TimeCurrent();
   if(now-g_perf_max_reset>=60) {g_perf_tick_max=0;g_perf_timer_max=0;g_perf_max_reset=now;}
   if(timer) {g_perf_timer_ema=(g_perf_timer_ema<=0?ms:g_perf_timer_ema*0.9+ms*0.1); g_perf_timer_max=MathMax(g_perf_timer_max,ms);}
   else      {g_perf_tick_ema=(g_perf_tick_ema<=0?ms:g_perf_tick_ema*0.9+ms*0.1);   g_perf_tick_max=MathMax(g_perf_tick_max,ms);}
}
int GHBRefillsLast(const int seconds)
{
   int n=0; datetime now=TimeCurrent();
   for(int i=0;i<64;i++) if(g_refill_times[i]>0 && now-g_refill_times[i]<=seconds) n++;
   return n;
}

void GHBEvent(const string m)
{
   for(int i=7;i>0;i--) g_ev[i]=g_ev[i-1];
   g_ev[0]=TimeToString(TimeCurrent(),TIME_SECONDS)+"  "+m;
   if(g_ev_n<8) g_ev_n++;
}
double ParkDistance() {return InpParkDistancePrice;}

// Scale a design (cent) lot and round it to a volume the broker accepts.
double ScaledLot(const double design_lot)
{
   double step=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   double minlot=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double v=design_lot*g_lot_scale;
   if(step>0.0) v=MathRound(v/step)*step;
   if(v<minlot) v=minlot;
   return NormalizeDouble(v,8);
}
double ScaledMoney(const double design_money)
{
   return design_money*g_money_scale;
}

// v3.56 FULL AUTO. Reference design = Exness XAUUSDc cent: 1 lot moving 1.00
// in price = 100 USC = 1.00 real USD. Lot scale keeps the same REAL dollars per
// move; money scale keeps the same PRICE distance to every TP. Works for any
// broker, suffix (c/m/.pc/...), contract size and account currency.
#define GHB_DESIGN_ACCT_PER_LOT_MOVE 100.0 // USC per 1 lot per 1.00 move
#define GHB_DESIGN_USD_PER_LOT_MOVE  1.0   // real USD per 1 lot per 1.00 move

// Real USD value of ONE unit of account currency (USC = 0.01).
double AccountUnitUSD(const string cur,string &how)
{
   string c=cur; StringToUpper(c);
   if(c=="USD") {how="USD";return 1.0;}
   if(c=="USC" || c=="USX") {how="USD cent";return 0.01;}
   string base=c;
   double unit=1.0;
   if(StringLen(c)==3 && StringSubstr(c,2,1)=="C" && c!="CHF" && c!="CNC")
   {
      // EUC, GBC ... = cents of EUR, GBP
      string full[]={"EUR","GBP","AUD","NZD","CAD","JPY"};
      for(int i=0;i<ArraySize(full);i++)
         if(StringSubstr(full[i],0,2)==StringSubstr(c,0,2)) {base=full[i];unit=0.01;break;}
   }
   string sfx="";
   int n=StringLen(_Symbol);
   if(n>6) sfx=StringSubstr(_Symbol,6); // broker suffix, e.g. "m", "c", ".pc"
   string tries[4];
   tries[0]=base+"USD"+sfx; tries[1]=base+"USD"; tries[2]="USD"+base+sfx; tries[3]="USD"+base;
   for(int i=0;i<4;i++)
   {
      double b=0.0;
      if(SymbolSelect(tries[i],true) && SymbolInfoDouble(tries[i],SYMBOL_BID,b) && b>0.0)
      {
         how=(i<2?"rate ":"inverse rate ")+tries[i];
         return unit*(i<2?b:1.0/b);
      }
   }
   how="no FX rate found, unit assumed 1 USD";
   return unit;
}

// Snap 0.0099.. / 1.0003.. to clean powers of ten when within 3%.
double SnapScale(const double v)
{
   if(v<=0.0) return v;
   double p=MathPow(10.0,MathRound(MathLog10(v)));
   return (MathAbs(v/p-1.0)<=0.03 ? p : v);
}

bool DetectAccountScale(double &lot_scale,double &money_scale,string &detail)
{
   string cur=AccountInfoString(ACCOUNT_CURRENCY);
   MqlTick t;
   double acctPerLotMove=0.0;
   if(SymbolInfoTick(_Symbol,t) && t.bid>0.0)
   {
      double prof=0.0;
      if(OrderCalcProfit(ORDER_TYPE_BUY,_Symbol,1.0,t.bid,t.bid+1.0,prof) && prof>0.0)
         acctPerLotMove=prof;
   }
   if(acctPerLotMove<=0.0)
   {
      double tv=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE);
      double ts=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
      if(tv>0.0 && ts>0.0) acctPerLotMove=tv/ts;
   }
   if(acctPerLotMove<=0.0) {detail="broker profit data not ready";return false;}
   string how="";
   double unitUSD=AccountUnitUSD(cur,how);
   double usdPerLotMove=acctPerLotMove*unitUSD;
   lot_scale=SnapScale(GHB_DESIGN_USD_PER_LOT_MOVE/usdPerLotMove);
   money_scale=SnapScale(lot_scale*acctPerLotMove/GHB_DESIGN_ACCT_PER_LOT_MOVE);
   detail=StringFormat("currency=%s (%s, 1 unit=%.4f USD) contract=%.2f 1lot/1.00move=%.4f %s = %.4f USD",
                       cur,how,unitUSD,SymbolInfoDouble(_Symbol,SYMBOL_TRADE_CONTRACT_SIZE),
                       acctPerLotMove,cur,usdPerLotMove);
   return true;
}

// v3.57 NET TARGETS. Every individual target becomes NET: the TP distance is
// widened by the round-trip commission/fee of that volume, and an open
// position's TP is widened again by any negative swap it has accrued.
// Zero-commission swap-free accounts (Exness cent/standard) are unchanged.
input group "00b - Net targets (commission + swap)"
input bool   InpNetOfCommission        = true; // TP covers round-trip commission + fees
input double InpCommissionPerLotManual = 0.0;  // Round-trip cost per 1.00 lot, account currency; 0 = auto-measure
input bool   InpNetOfSwap              = true; // Open positions: TP also recovers accrued negative swap
double   g_comm_per_lot=0.0;   // round-trip cost per 1.00 lot, account currency (>=0)
string   g_comm_source="none yet";
datetime g_comm_last_update=0;

double CommissionCostForVolume(const double volume)
{
   if(!InpNetOfCommission || volume<=0.0) return 0.0;
   return g_comm_per_lot*volume;
}

// Measure from this symbol's own deal history (last 30 days, any magic).
// Per-side brokers charge on entry and exit; others charge round-trip on
// entry. Without exit deals yet, assume exit = entry (conservative).
void UpdateCommissionEstimate(const bool force=false)
{
   datetime now=TimeCurrent();
   if(!force && now-g_comm_last_update<60) return;
   g_comm_last_update=now;
   double old=g_comm_per_lot;
   if(InpCommissionPerLotManual>0.0)
   {
      g_comm_per_lot=InpCommissionPerLotManual;
      g_comm_source="manual input";
   }
   else
   {
      if(!GHBHistorySelect(now-30*86400,now+60)) return;
      double costIn=0.0,volIn=0.0,costOut=0.0,volOut=0.0;
      int total=HistoryDealsTotal();
      for(int i=total-1;i>=0 && i>=total-2000;i--)
      {
         ulong d=HistoryDealGetTicket(i);
         if(d==0 || HistoryDealGetString(d,DEAL_SYMBOL)!=_Symbol) continue;
         ENUM_DEAL_TYPE dt=(ENUM_DEAL_TYPE)HistoryDealGetInteger(d,DEAL_TYPE);
         if(dt!=DEAL_TYPE_BUY && dt!=DEAL_TYPE_SELL) continue;
         double vol=HistoryDealGetDouble(d,DEAL_VOLUME);
         if(vol<=0.0) continue;
         double cost=-(HistoryDealGetDouble(d,DEAL_COMMISSION)+HistoryDealGetDouble(d,DEAL_FEE));
         ENUM_DEAL_ENTRY en=(ENUM_DEAL_ENTRY)HistoryDealGetInteger(d,DEAL_ENTRY);
         if(en==DEAL_ENTRY_IN) {costIn+=cost;volIn+=vol;}
         else if(en==DEAL_ENTRY_OUT || en==DEAL_ENTRY_OUT_BY) {costOut+=cost;volOut+=vol;}
      }
      if(volIn<=0.0 && volOut<=0.0) {g_comm_source="no deals yet (0 until first fill)";return;}
      double rIn=(volIn>0.0?costIn/volIn:0.0);
      double rOut=(volOut>0.0?costOut/volOut:rIn);
      double est=MathMax(0.0,rIn)+MathMax(0.0,rOut);
      // ignore tiny churn so TPs are not re-sent for rounding noise
      if(old>0.0 && MathAbs(est-old)<=old*0.02) return;
      g_comm_per_lot=est;
      g_comm_source=StringFormat("measured: entry %.4f + exit %.4f per lot%s",rIn,rOut,volOut>0.0?"":" (exit assumed = entry)");
   }
   if(force || MathAbs(g_comm_per_lot-old)>1e-9)
      PrintFormat("HBv3.57 NET COST | commission round-trip=%.4f %s per 1.00 lot (%s) | netCommission=%s netSwap=%s",
                  g_comm_per_lot,AccountInfoString(ACCOUNT_CURRENCY),g_comm_source,
                  InpNetOfCommission?"ON":"OFF",InpNetOfSwap?"ON":"OFF");
}

input group "01 - Orders"
double InpSeedLot = 2.00; // First market BUY and SELL only
double InpFixedLot             = 2.00;       // Third/fourth new entries; ignore old 0.10 presets
input int    InpMaxPositionsPerSide  = 3;          // 3 same-side maximum: BUY+SELL+2 winning-side adds
input double InpGridStepPrice       = 2.00;       // From seed to third leg, gold price units
input double InpFourthStepPrice     = 0.80;       // From third to fourth leg, same direction
input int    InpMinSecondsBetweenAdds = 8;
const long   InpMagic                = 26101344; // NEW Magic: old 10+10 slot state is incompatible with 20+20
input int    InpDeviationPoints      = 30;

input group "01a - Parallel Magic coexistence (HIGH RISK)"
const bool InpAllowParallelMagic = false; // OFF: no coexistence with older EAs; old positions/orders remain untouched.

input group "01a3 - Verified upgrade from earlier GHB 10+10 network"
// Keep OFF until ALL old EA instances (local + MT5 VPS) have been stopped.
// When ON, and ONLY when NO positions exist on this symbol, delete one strictly
// verified v3.26 pending order per interval. Never touch open positions,
// manual trades or orders belonging to unknown EA/Magic. New network starts
// only after the broker confirms the entire OLD pending set is gone.
const bool InpPermitFlatLegacyPendingMigration = false; // Explicit opt-in for broker order cancellations
input long InpVerifiedLegacyGridMagic = 26100914; // GHB v3.25/v3.26 old 10+10 network; not current 26100915
input int InpLegacyMigrationIntervalSeconds = 5;

input group "01a2 - TAKEOVER of previous Gold Hedge Basket versions"
const bool InpTakeoverCancelLegacyPendings = false; // Delete only VERIFIED old-GHB pendings; STOP old EA first; old LIVE untouched
const bool InpTakeoverUpdateLegacyLiveTP = false; // SAFE DEFAULT: legacy OPEN TP unchanged; opt-in only after testing
input long InpTakeoverOldMagicMin = 26100901; // Inclusive historic GHB range; current InpMagic always excluded.
input long InpTakeoverOldMagicMax = 26100913; // Adjust only if you KNOW your old EA used another MAGIC.
input bool InpTakeoverBlockOnForeignPendings = true; // Block any NEW EA entry when unknown foreign pendings remain.
input int InpTakeoverActionsPerPass = 4; // Throttle broker cancellations/TP edits on VPS; at most 4 each scan.

// Existing pending orders from other Magic numbers can still fill at the broker.
// The 300% margin filter below is kept, but does not cap future pending exposure.

input group "01b - Independent original hedge targets (ACCOUNT currency)"
double InpSeedTakeProfitMoney = 50.00; // Fixed individual gross target, ACCOUNT currency (USC)
double InpRepeatTakeProfitMoney = 50.00; // Fixed individual gross target, ACCOUNT currency (USC)
double InpTrendTakeProfitMoney = 50.00; // Fixed individual gross target, ACCOUNT currency (USC)
const bool InpRepeatOriginalOnTP = false; // After original/replacement closes at TP, place same-side LIMIT again
input double InpRepeatDistancePrice = 10.00; // BUY=TP-10 XAUUSD price units; SELL=TP+10
input int    InpRepeatRetrySeconds = 15; // On invalid quote, margin or rejected order, retry later

input group "02 - Basket risk (ACCOUNT currency)"
input double InpBasketTakeProfit    = 50.00;       // Basket TP only if opt-in switch below ON (OFF by default)
input double InpExitCostReserve     = 1.00;       // Conservative exit reserve (account currency)
input double InpReversalExitPrice   = 1.50;       // Exit basket after reversal from last added position
const bool InpIndividualTPOnly = true; // Do not close winning pairs or entire baskets for profit; close each verified non-seed only at its OWN USC target
const bool InpCloseWholeOnProfit = false;           // OFF: counter reaches its own TP without liquidating core
const bool InpCloseWholeOnGiveback = false;         // OFF: peak-profit retrace does not liquidate basket
const bool InpCloseWholeOnReversal = false;         // OFF: small price retrace does not liquidate basket
input double InpProfitLockArm      = 8.00;       // Optional basket peak protection arm
input double InpProfitLockGiveback = 5.00;       // Close if profit falls this much from peak
input int    InpMaxBasketMinutes    = 0;          // 0: no forced timed closure; basket risk still applies
input int    InpCooldownSeconds     = 180;         // After a basket closes
input group "02b - Restart after all basket positions have closed"
input bool   InpAutoRestartFlatBasket = true; // Start fresh BUY+SELL and 20+20 only when fully flat
input int    InpFlatConfirmSeconds = 4;       // Require stable broker-reported flat state before cancel/rebuild
input int    InpFlatRestartCooldownSeconds = 5; // Extra wait after verified old pending cancellation
input bool   InpFlatRestartRequireCleanSymbol = true; // Never restart over positions/orders owned by other Magic

input group "04 - Temporary countertrade (NO position Stop Loss)"
input bool   InpEnableCounterTrade      = true;       // One countertrade per basket only
input double InpCounterLotDesign     = 0.20;       // SECOND buy/sell WITH OWN TP; CORE remains 0.10
double InpCounterTakeProfitMoney = 50.00; // Fixed individual gross target, ACCOUNT currency (USC)
input int    InpCounterWaitSeconds      = 8;          // Minimum wait after THIRD is opened
input double InpCounterMinAdvancePrice  = 0.30;       // Price must advance in grid direction first
input double InpCounterRetracePrice     = 0.50;       // Actual pullback from best price after third
input int    InpCounterConfirmSeconds   = 2;          // Pullback must last this long

input group "05 - Follow trend after profitable counter"
input bool   InpEnableFollowAfterCounter = true;  // ONE follow only when counter booked net profit > 0
input double InpFollowLotDesign        = 0.40;    // Twice counter lot (0.20 * 2)
double InpFollowTakeProfitMoney = 50.00; // Fixed individual gross target, ACCOUNT currency (USC)
input int    InpFollowMinDelaySeconds = 0;       // 0 = next tick after profitable counter closes

input group "06 - Close same-side winning pairs"
const bool InpEnableProfitablePairs = false; // Individual-target mode: no early two-position pair exits
input double InpPairMinEachMoney      = 1.00;    // Each position should have +1.00 in ACCOUNT currency
input double InpPairMinTotalMoney     = 3.00;    // Both positions' floating gross P/L >= 3.00
input bool   InpProtectPairRemainder   = true;    // Never close winning pair if it strands a balanced/naked opposite side
input bool   InpKeepOriginalHedgeOpen = true;    // Original BUY/SELL never closed by profitable-pair routine


input group "07 - Fixed broker grid (40 BUY + 40 SELL)"
const bool InpEnableBrokerLimits = true; // Forty BUY LIMIT below and forty SELL LIMIT above fixed basket midpoint
// Old parameters are used ONLY to recognize v3.16 tickets/positions during safe upgrade.
input double InpLimitBaseLot            = 0.10; // LEGACY original-lot base; don't change during migration
input double InpLimitIntermediateBaseLot= 0.05; // LEGACY midpoint-lot base; don't change during migration
// Fixed ladder: rung 1=1 lot, rung 2=2 lots, ... rung 40=40 lots.
const bool InpUpgradeExistingGridPendings = false; // Upgrade existing owned broker pendings ONE by ONE; never resize an open position
const bool InpAllowExistingPendingLotUpsize = false; // SAFE DEFAULT: never automatically increase an existing pending lot
input int    InpLotUpgradeIntervalSeconds = 30; // Throttle broker cancellations/replacements
input bool   InpPreserveExistingLiveTP = true; // Compatibility: applies only when explicit TP enforcement switch below is OFF
const bool   InpEnforceConfiguredTP = true; // NEW: correct an incorrect broker TP on verified OWN-MAGIC tracked positions despite old saved .set flags; other Magic untouched
input bool   InpPreservePositionSL = true; // Do not wipe a pre-existing SL while repairing a missing live TP

input double InpLimitFirstDistancePrice = 2.50; // LEGACY saved .set input, ignored while tight-grid switch is ON
input double InpLimitSpacingPrice       = 2.50; // LEGACY saved .set input, ignored while tight-grid switch is ON
// v3.26 NEW inputs override previous .set files carrying the old 2.50 distances.
// Change ONLY these new options for market-anchored tighter geometry.
input bool   InpUseTightMarketGrid       = true;
input double InpMarketFirstDistancePrice = 0.50;  // first LIMIT at market midpoint +/- 0.50
input double InpMarketTierSpacingPrice   = 0.50;  // 40 levels span 0.50,1.00,...,20.00 gold PRICE units

double GridFirstDistance()
{
   return 0.50; // immutable price units from the basket-start midpoint
}
double GridSpacing()
{
   return 0.50; // immutable gap between successive levels
}

input group "07a2 - Target for each rung, account currency USC (BUY/SELL identical)"
const double InpTierTP01 = 50.00; // Fixed individual gross target, ACCOUNT currency (USC)
const double InpTierTP02 = 50.00; // Fixed individual gross target, ACCOUNT currency (USC)
const double InpTierTP03 = 50.00; // Fixed individual gross target, ACCOUNT currency (USC)
const double InpTierTP04 = 50.00; // Fixed individual gross target, ACCOUNT currency (USC)
const double InpTierTP05 = 50.00; // Fixed individual gross target, ACCOUNT currency (USC)
const double InpTierTP06 = 50.00; // Fixed individual gross target, ACCOUNT currency (USC)
const double InpTierTP07 = 50.00; // Fixed individual gross target, ACCOUNT currency (USC)
const double InpTierTP08 = 50.00; // Fixed individual gross target, ACCOUNT currency (USC)
const double InpTierTP09 = 50.00; // Fixed individual gross target, ACCOUNT currency (USC)
const double InpTierTP10 = 50.00; // Fixed individual gross target, ACCOUNT currency (USC)
const double InpTierTP11 = 50.00; // Fixed individual gross target, ACCOUNT currency (USC)
const double InpTierTP12 = 50.00; // Fixed individual gross target, ACCOUNT currency (USC)
const double InpTierTP13 = 50.00; // Fixed individual gross target, ACCOUNT currency (USC)
const double InpTierTP14 = 50.00; // Fixed individual gross target, ACCOUNT currency (USC)
const double InpTierTP15 = 50.00; // Fixed individual gross target, ACCOUNT currency (USC)
const double InpTierTP16 = 50.00; // Fixed individual gross target, ACCOUNT currency (USC)
const double InpTierTP17 = 50.00; // Fixed individual gross target, ACCOUNT currency (USC)
const double InpTierTP18 = 50.00; // Fixed individual gross target, ACCOUNT currency (USC)
const double InpTierTP19 = 50.00; // Fixed individual gross target, ACCOUNT currency (USC)
const double InpTierTP20 = 50.00; // Fixed individual gross target, ACCOUNT currency (USC)
const int InpLimitExpiryMinutes = 0;    // 0 = broker GTC
input int    InpLimitRefillRetrySeconds = 15;   // Retry if broker rejects replacement
const int InpMaxActiveLimitPositions = LIMIT_SLOTS;   // Hard safety cap on FILLED live LIMIT trades, not pending tiers
input int    InpMinimumRefillCycles     = 10;   // Informational goal, not a guarantee; refill continues after 10

input group "07b - Timed market pending-grid recenter"
const bool InpEnableConditionalRecenter = true; // Modify ONLY THIS EA's active LIMIT pendings; never market positions
const int InpRecenterEveryMinutes = 1;    // Re-evaluate positions each 5 minutes; set 10 for slower updates
input double InpRecenterMinMovePrice      = 0.00; // Check all pending levels at every due review, even for a small market move
input int    InpRecenterRetrySeconds      = 30;   // Throttle rejected broker modification attempts
// New inputs override older saved .set settings: current-price review MUST run every 5m.
const bool InpForceCurrentMarketRecenter = true;
const int InpCurrentMarketRecenterMinutes = 1;

bool MarketRecenterActive()
{
   return true; // pending orders recentered every 60 seconds
}
int GridRecenterMinutes()
{
   return 1; // fixed policy, independent of old saved presets
}
double GridMinimumMove()
{
   return 0.0;
}

input group "08 - Execution filters"
input double InpMaxSpreadPrice      = 0.25;       // Ask-Bid price units; 0 disables
input double InpMaxSeedSpreadCost   = 5.00; // Pair spread-cost allowance per 0.10 seed lot; scales with seed volume
input double InpMinFreeMarginFactor = 2.00;       // Free margin / standalone estimated order margin
input double InpNoNewOrderBelowMarginLevel = 150.0; // Minimum PROJECTED account margin % after the new order (v3.58: was 300 current level)
input int    InpMinSecondsBetweenSeedAttempts = 15;
input int    InpPrintStatusEverySeconds = 30;
input int    InpEntryDiagnosticsSeconds = 20; // Log why a new basket is blocked

input group "09 - ADDITIONAL SIDE-LOSS COOLING (USC ACCOUNT CURRENCY)"
input bool   InpEnableSideLossCooling = true; // Additional feature; existing 20+20 grid and open trades remain managed
input double InpCoolingStartLossUSC = 500.0; // Legacy compatibility only; not an entry trigger
input double InpCoolingLossStepDesign = 100.0; // Fixed price spacing: this loss on the first cooling lot
input int    InpCoolingStartPositions = 8; // First cooling at 8 original positions of the same direction; excludes cooling positions
input double InpCoolingFirstLotDesign = 1.0; // First market cooling lot; subsequent tiers add LotStep up to MaxLot
input double InpCoolingLotStepDesign = 1.0;
input double InpCoolingMaxLotDesign = 10.0; // Hard ceiling; broker volume limits still apply
double InpCoolingTakeProfitUSC = 100.00; // Fixed individual gross target, ACCOUNT currency (USC)
input int    InpCoolingMinSecondsBetweenTrades = 20; // Avoid rapid catch-up bursts
input int    InpCoolingMaxOpenTrades = 10;
// v3.54 runtime values (design inputs above x account scale, set in OnInit)
double InpCounterLot=0.20, InpFollowLot=0.40;
double InpCoolingLossStepUSC=100.0, InpCoolingFirstLot=1.0, InpCoolingLotStep=1.0, InpCoolingMaxLot=10.0; // Maximum simultaneous cooling positions
input double InpCoolingMinMarginLevel = 500.0; // Additional margin guard

bool     g_exit_in_progress = false;
bool     g_technical_pause = false;
string   g_technical_reason = "";
datetime g_last_technical_log = 0;
bool     g_had_positions = false;
// Flat-cycle rollover survives VPS restart; no duplicate basket while old GTC orders exist.
string   g_flat_restart_key = "";
bool     g_flat_restart_pending = false;
datetime g_flat_detected_at = 0;
datetime g_flat_last_log = 0;
datetime g_last_exit_time = 0;
datetime g_last_seed_attempt = 0;
datetime g_last_add_attempt = 0;
datetime g_last_lot_upgrade_attempt = 0;
// v3.22: one verified occupied-rung pending deletion per safety interval.
datetime g_last_tier_quarantine_action = 0;
datetime g_last_recenter_decision_log = 0;
datetime g_last_close_attempt = 0;
datetime g_last_status = 0;
datetime g_last_entry_diag = 0;
// v3.19 foreign legacy pending cleanup and classified live-TP migration throttle.
datetime g_last_legacy_takeover_scan = 0;
datetime g_last_legacy_takeover_log = 0;
// Separate persistent stage counters: retain the basket's Magic/state namespace
// so the revised EA can continue managing already-open v3.30 trades and pendings.
string   g_cooling_buy_stage_key = "";
string   g_cooling_sell_stage_key = "";
string   g_cooling_last_time_key = "";
datetime g_cooling_last_open_time = 0;

datetime g_last_parallel_warning = 0;
string   g_exit_key = "";
string   g_start_key = "";
string   g_stage_key = "";
string   g_peak_key = "";
string   g_force_key = "";
string   g_seed_buy_key = "";
string   g_seed_sell_key = "";
string   g_direction_key = "";
string   g_counter_id_key = "";
string   g_counter_once_key = "";
string   g_counter_best_key = "";
string   g_counter_third_price_key = "";
string   g_counter_third_time_key = "";
string   g_third_id_key = "";
string   g_fourth_id_key = "";
string   g_follow_id_key = "";
string   g_follow_once_key = "";
ulong    g_third_id = 0;
ulong    g_fourth_id = 0;
ulong    g_follow_id = 0;
bool     g_follow_once = false;

ulong    g_counter_id = 0;
bool     g_counter_placed = false;
double   g_counter_best = 0.0;
double   g_counter_third_price = 0.0;
datetime g_counter_third_time = 0;
datetime g_counter_retrace_since = 0;
ulong    g_seed_buy_id = 0;
ulong    g_seed_sell_id = 0;
int      g_grid_direction = 0; // +1 BUY adds; -1 SELL adds; 0 before third
 datetime g_last_trail_error = 0;
datetime g_basket_start = 0;
int      g_expected_positions = 0; // stage: total orders ever opened in current basket
double   g_peak_net = -1e100;
// Twenty broker-side LIMIT slots: ten BUY and ten SELL. Each slot holds
// one pending OR the most recent activation awaiting a replacement.
// All previously FILLED live positions use an independent persistent ledger.
ulong    g_limit_order[LIMIT_SLOTS];
ulong    g_limit_position[LIMIT_SLOTS];
string   g_limit_order_key[LIMIT_SLOTS];
string   g_limit_position_key[LIMIT_SLOTS];
datetime g_limit_last_retry[LIMIT_SLOTS];
datetime g_limit_last_non_tp_log[LIMIT_SLOTS]; // no rearm after manual/negative exit
// Persist all filled LIMIT identifiers independently of their pending-order slots.
// Without this ledger, replacing a pending on fill would lose track of live positions.
ulong g_limit_filled_ids[];
int   g_limit_filled_slots[];
string g_limit_filled_prefix="";
// v3.22: old-Magic live positions block the same rung until broker-proven profitable TP.
string g_legacy_tier_hold_prefix="";
datetime g_legacy_hold_check_at[LIMIT_SLOTS];
bool g_legacy_hold_check_result[LIMIT_SLOTS];
datetime g_limit_capacity_log=0;
// Per-tier counters are persisted across VPS restarts; no artificial stop at 10.
int      g_limit_refill_cycles[LIMIT_SLOTS];
string   g_limit_refill_cycle_key[LIMIT_SLOTS];
int      g_limit_tp_cycles[LIMIT_SLOTS];
string   g_limit_tp_cycle_key[LIMIT_SLOTS];
string   g_tp_deal_seen_prefix="";
double   g_limit_seed_buy_price=0.0;
double   g_limit_seed_sell_price=0.0;
string   g_limit_seed_buy_key="";
string   g_limit_seed_sell_key="";
// Outer edge is persisted: existing orders never move. TP rearm uses the live
// quote and still goes beyond the outermost rung, never into the middle.
double   g_limit_outer_buy=0.0;
double   g_limit_outer_sell=0.0;
string   g_limit_outer_buy_key="";
string   g_limit_outer_sell_key="";
// Recenter state belongs to THIS basket only. Seed prices stay immutable so
// the M1 third/fourth grid logic never changes reference after a pending move.
double   g_recenter_anchor_mid=0.0;
datetime g_recenter_last_time=0;
datetime g_recenter_last_attempt=0;
bool g_grid_geometry_dirty=true; // startup, additions and incomplete broker updates
string   g_recenter_anchor_key="";
string   g_recenter_time_key="";
// Two independent cycles of the ORIGINAL hedge (not part of 5+5 LIMIT ladder).
// Per-side position identifiers, pending broker order tickets and last TP
// are persisted so a VPS migration cannot create duplicate re-entry orders.
ulong    g_repeat_position[2]; // 0 BUY, 1 SELL; starts with original seed identifier
ulong    g_repeat_order[2];    // broker pending BUY LIMIT / SELL LIMIT
ulong    g_repeat_armed_for[2]; // position id whose TP already produced a pending
string   g_repeat_pos_key[2];
string   g_repeat_order_key[2];
string   g_repeat_armed_key[2];
string   g_repeat_tp_key[2];
double   g_repeat_last_tp[2];
datetime g_repeat_attempt[2];


bool IsReplacementId(const ulong id)
{
   if(id==0) return false;
   for(int s=0;s<2;s++)
      if(g_repeat_position[s]==id && id!=g_seed_buy_id && id!=g_seed_sell_id) return true;
   return false;
}

int LimitSlotForPositionId(const ulong id)
{
   if(id==0) return -1;
   for(int j=0;j<LIMIT_SLOTS;j++) if(g_limit_position[j]==id) return j;
   for(int j=0;j<ArraySize(g_limit_filled_ids);j++)
      if(g_limit_filled_ids[j]==id) return g_limit_filled_slots[j];
   return -1;
}

bool IsLimitPositionId(const ulong id)
{
   return LimitSlotForPositionId(id)>=0;
}

// TP counter is informational. Each fill immediately triggers ONE pending
// replacement; TP must never cause a SECOND replacement for the same fill.
// Broker deal ID guards duplicate event delivery.
void RecordLimitTPDeal(const ulong position_id,const ulong deal,const long reason)
{
   if(deal==0 || reason!=DEAL_REASON_TP || g_tp_deal_seen_prefix=="") return;
   int slot=LimitSlotForPositionId(position_id);
   if(slot<0 || slot>=LIMIT_SLOTS) return;
   string seen=g_tp_deal_seen_prefix+IntegerToString((long)deal);
   if(GlobalVariableCheck(seen)) return;
   GlobalVariableSet(seen,1.0);
   g_limit_tp_cycles[slot]++;
   GlobalVariableSet(g_limit_tp_cycle_key[slot],(double)g_limit_tp_cycles[slot]);
   PrintFormat("HBv3.30 LIMIT TP CYCLE | %s rung=%d TPcount=%d refillCount=%d",
               slot<LIMIT_PER_SIDE?"BUY":"SELL",slot%LIMIT_PER_SIDE+1,
               g_limit_tp_cycles[slot],g_limit_refill_cycles[slot]);
}

void RegisterFilledLimit(const ulong id,const int slot)
{
   if(id==0 || slot<0 || slot>=LIMIT_SLOTS) return;
   for(int j=0;j<ArraySize(g_limit_filled_ids);j++)
      if(g_limit_filled_ids[j]==id) return;
   int n=ArraySize(g_limit_filled_ids);
   ArrayResize(g_limit_filled_ids,n+1);
   ArrayResize(g_limit_filled_slots,n+1);
   g_limit_filled_ids[n]=id;
   g_limit_filled_slots[n]=slot;
   GlobalVariableSet(g_limit_filled_prefix+IntegerToString((long)id),(double)(slot+1));
   PrintFormat("HBv3.30 LIMIT FILLED TRACKED | side=%s rung=%d position=%I64u openPositions=%d",
               slot<LIMIT_PER_SIDE?"BUY":"SELL",slot%LIMIT_PER_SIDE+1,id,n+1);
}

void RestoreFilledLimitLedger()
{
   // Existing open positions are restored after VPS restart; closed IDs are discarded.
   for(int i=GlobalVariablesTotal()-1;i>=0;i--)
   {
      string name=GlobalVariableName(i);
      if(StringFind(name,g_limit_filled_prefix)!=0) continue;
      ulong id=(ulong)StringToInteger(StringSubstr(name,StringLen(g_limit_filled_prefix)));
      int slot=(int)GlobalVariableGet(name)-1;
      if(id==0 || slot<0 || slot>=LIMIT_SLOTS || !IsPositionIdOpen(id))
      {
         GlobalVariableDel(name);
         continue;
      }
      RegisterFilledLimit(id,slot);
   }
}

void PurgeClosedFilledLimits()
{
   for(int i=ArraySize(g_limit_filled_ids)-1;i>=0;i--)
   {
      if(IsPositionIdOpen(g_limit_filled_ids[i])) continue;
      GlobalVariableDel(g_limit_filled_prefix+IntegerToString((long)g_limit_filled_ids[i]));
      int last=ArraySize(g_limit_filled_ids)-1;
      if(i!=last)
      {
         g_limit_filled_ids[i]=g_limit_filled_ids[last];
         g_limit_filled_slots[i]=g_limit_filled_slots[last];
      }
      ArrayResize(g_limit_filled_ids,last);
      ArrayResize(g_limit_filled_slots,last);
   }
}

int OpenLimitPositionCount()
{
   int n=0;
   for(int p=0;p<PositionsTotal();p++)
   {
      ulong ticket=PositionGetTicket(p);
      if(!IsOwnPosition(ticket)) continue;
      if(IsLimitPositionId((ulong)PositionGetInteger(POSITION_IDENTIFIER))) n++;
   }
   return n;
}

// Each rung has an independent, user-adjustable lot (same for BUY and SELL).
// Historical v3.16/v3.17 orders retain their original volume until replaced.
double LimitLotForSlot(const int slot)
{
   if(slot<0 || slot>=LIMIT_SLOTS) return 0.0;
   return ScaledLot((double)MathMin(slot%LIMIT_PER_SIDE+1,MathMax(1,MathMin(10,InpRungLotCapDesign))));
}

double LegacyLimitLotForSlot(const int slot)
{
   if(slot<0 || slot>=LIMIT_SLOTS) return 0.0;
   int level=slot%LIMIT_PER_SIDE;
   if(level>=10) return 0.0;
   int band=level/2;
   double base=((level%2)==0 ? InpLimitIntermediateBaseLot : InpLimitBaseLot);
   return NormalizeDouble(base*(double)(1<<band),8);
}

// Recognize broker-side orders/positions placed by the immediately previous
// v3.20 tier schedule.  This does NOT change their live lot or cancel them.
double PreviousV320LimitLotForSlot(const int slot)
{
   if(slot<0 || slot>=LIMIT_SLOTS || slot%LIMIT_PER_SIDE>=10) return 0.0;
   switch(slot%LIMIT_PER_SIDE)
   {
      case 0: return 0.10;
      case 1: return 0.20;
      case 2: return 0.30;
      case 3: return 0.50;
      case 4: return 0.80;
      case 5: return 1.20;
      case 6: return 1.80;
      case 7: return 2.70;
      case 8: return 3.80;
      case 9: return 5.00;
   }
   return 0.0;
}

bool LimitVolumeMatchesSlot(const int slot,const double vol)
{
   if(slot<0 || slot>=LIMIT_SLOTS || vol<=0.0) return false;
   double tolerance=MathMax(1e-7,SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP)*0.1);
   // Keep old exact-rung volumes recognizable during migration; new sends
   // always use LimitLotForSlot. Never resize an already-filled position.
   return MathAbs(vol-LimitLotForSlot(slot))<=tolerance ||
          MathAbs(vol-(double)(slot%LIMIT_PER_SIDE+1)*g_lot_scale)<=tolerance;
}

// Twenty user-adjustable gross profit goals in ACCOUNT CURRENCY.
// Both directions share the SAME target for the corresponding rung.
// Original core hedge (first BUY/SELL) is separately fixed to 80 USC.
double LimitTargetForSlot(const int slot)
{
   if(slot<0 || slot>=LIMIT_SLOTS) return 0.0;
   return ScaledMoney(slot%LIMIT_PER_SIDE>=9 ? 100.0 : 50.0); // both sides: rungs 10..40 TP100
}

double LimitLotForPositionId(const ulong id)
{
   if(id==0) return 0.0;
   int slot=LimitSlotForPositionId(id);
   return slot>=0 ? LimitLotForSlot(slot) : 0.0;
}


// Diagnose entry blocks without flooding the MT5 Experts journal.
// This routine never alters a trading decision or disables protection.
void EntryBlocked(const string reason)
{
   datetime now=TimeCurrent();
   g_block_reason=reason; g_block_time=now; // v3.60 dashboard
   if(InpEntryDiagnosticsSeconds>0 && g_last_entry_diag!=0 &&
      now-g_last_entry_diag<InpEntryDiagnosticsSeconds) return;
   g_last_entry_diag=now;
   PrintFormat("HBv3.30 NO ENTRY | %s | %s currency=%s equity=%.2f freeMargin=%.2f marginLevel=%.1f%%",
               reason,_Symbol,AccountInfoString(ACCOUNT_CURRENCY),
               AccountInfoDouble(ACCOUNT_EQUITY),AccountInfoDouble(ACCOUNT_MARGIN_FREE),
               AccountInfoDouble(ACCOUNT_MARGIN_LEVEL));
}

void SetExpectedPositions(const int n)
{
   g_expected_positions=n;
   GlobalVariableSet(g_stage_key,(double)n);
}

void RequestBasketExit()
{
   // Individual exits only. An incomplete/invalid basket pauses new entries
   // rather than creating a persistent command to liquidate unrelated legs.
   g_exit_in_progress=false;
   if(g_force_key!="") GlobalVariableDel(g_force_key);
   PauseForTechnicalAudit("BULK_EXIT_DISABLED: inspect basket state; individual TP remains active");
}

// Do not market-close all positions for a transient bookkeeping or transaction
// synchronization problem. Pause NEW decisions until state reconciles. Existing
// broker TPs continue, and pending orders already accepted stay at the broker.
void PauseForTechnicalAudit(const string reason)
{
   datetime now=TimeCurrent();
   if(!g_technical_pause || g_technical_reason!=reason ||
      now-g_last_technical_log>=30)
   {
      PrintFormat("HBv3.30 TECHNICAL PAUSE, NO POSITION CLOSED | %s | broker pending=%d; investigate Experts log",
                  reason,OrdersTotal());
      g_last_technical_log=now;
   }
   if(!g_technical_pause || g_technical_reason!=reason) {GHBEvent("PAUSE: "+reason); g_st_pauses++;}
   g_technical_pause=true;
   g_technical_reason=reason;
}

void ResumeAfterAudit()
{
   if(g_technical_pause)
   {
      PrintFormat("HBv3.30 TECHNICAL PAUSE CLEARED | earlier=%s",g_technical_reason);
      GHBEvent("Audit pause cleared");
   }
   g_technical_pause=false;
   g_technical_reason="";
}

void ResetBasketState()
{
   // TP deal markers are scoped to one basket and only discarded after flat.
   for(int v=GlobalVariablesTotal()-1;v>=0;v--)
   {
      string keyname=GlobalVariableName(v);
      if(g_tp_deal_seen_prefix!="" && StringFind(keyname,g_tp_deal_seen_prefix)==0)
         GlobalVariableDel(keyname);
   }
   for(int i=0;i<LIMIT_SLOTS;i++)
   {
      if(g_limit_refill_cycle_key[i]!="") GlobalVariableDel(g_limit_refill_cycle_key[i]);
      if(g_limit_tp_cycle_key[i]!="") GlobalVariableDel(g_limit_tp_cycle_key[i]);
      g_limit_refill_cycles[i]=0;
      g_limit_tp_cycles[i]=0;
      g_limit_last_non_tp_log[i]=0;
   }
   for(int j=0;j<ArraySize(g_limit_filled_ids);j++)
      GlobalVariableDel(g_limit_filled_prefix+IntegerToString((long)g_limit_filled_ids[j]));
   ArrayResize(g_limit_filled_ids,0);
   ArrayResize(g_limit_filled_slots,0);
   g_technical_pause=false;
   g_technical_reason="";
   g_basket_start=0;
   g_expected_positions=0;
   g_peak_net=-1e100;
   GlobalVariableDel(g_start_key);
   GlobalVariableDel(g_stage_key);
   GlobalVariableDel(g_peak_key);
   GlobalVariableDel(g_force_key);
   GlobalVariableDel(g_seed_buy_key);
   GlobalVariableDel(g_seed_sell_key);
   GlobalVariableDel(g_direction_key);
   GlobalVariableDel(g_counter_id_key);
   GlobalVariableDel(g_counter_once_key);
   GlobalVariableDel(g_counter_best_key);
   GlobalVariableDel(g_counter_third_price_key);
   GlobalVariableDel(g_counter_third_time_key);
   GlobalVariableDel(g_third_id_key);
   GlobalVariableDel(g_fourth_id_key);
   GlobalVariableDel(g_follow_id_key);
   GlobalVariableDel(g_follow_once_key);
   g_third_id=0;
   g_fourth_id=0;
   g_follow_id=0;
   g_follow_once=false;
   g_counter_id=0;
   g_counter_placed=false;
   g_counter_best=0.0;
   g_counter_third_price=0.0;
   g_counter_third_time=0;
   g_counter_retrace_since=0;
   g_seed_buy_id=0;
   g_seed_sell_id=0;
   for(int side=0;side<2;side++)
   {
      if(g_repeat_pos_key[side]!="") GlobalVariableDel(g_repeat_pos_key[side]);
      if(g_repeat_order_key[side]!="") GlobalVariableDel(g_repeat_order_key[side]);
      if(g_repeat_armed_key[side]!="") GlobalVariableDel(g_repeat_armed_key[side]);
      if(g_repeat_tp_key[side]!="") GlobalVariableDel(g_repeat_tp_key[side]);
      g_repeat_position[side]=0;
      g_repeat_order[side]=0;
      g_repeat_armed_for[side]=0;
      g_repeat_last_tp[side]=0;
      g_repeat_attempt[side]=0;
   }
   g_grid_direction=0;
   g_limit_seed_buy_price=0.0;
   g_limit_seed_sell_price=0.0;
   g_limit_outer_buy=0.0;
   g_limit_outer_sell=0.0;
   g_recenter_anchor_mid=0.0;
   g_recenter_last_time=0;
   g_recenter_last_attempt=0;
   if(g_recenter_anchor_key!="") GlobalVariableDel(g_recenter_anchor_key);
   if(g_recenter_time_key!="") GlobalVariableDel(g_recenter_time_key);
   if(g_limit_seed_buy_key!="") GlobalVariableDel(g_limit_seed_buy_key);
   if(g_limit_seed_sell_key!="") GlobalVariableDel(g_limit_seed_sell_key);
   if(g_limit_outer_buy_key!="") GlobalVariableDel(g_limit_outer_buy_key);
   if(g_limit_outer_sell_key!="") GlobalVariableDel(g_limit_outer_sell_key);
   for(int i=0;i<LIMIT_SLOTS;i++)
   {
      if(g_limit_order_key[i]!="") GlobalVariableDel(g_limit_order_key[i]);
      if(g_limit_position_key[i]!="") GlobalVariableDel(g_limit_position_key[i]);
      g_limit_order[i]=0;
      g_limit_position[i]=0;
   }
}


struct BasketState
{
   int      buys;
   int      sells;
   int      count;
   double   buy_volume;
   double   sell_volume;
   double   floating_net;
   double   last_buy_price;
   double   last_sell_price;
   long     last_buy_msc;
   long     last_sell_msc;
   datetime oldest_open;
   datetime newest_open;
   ulong    identifiers[128];
   int      id_count;
};

bool CanTradeNow();
bool PendingLimitTPForAccountProfit(const ENUM_ORDER_TYPE side,
                                   const double entry,const double volume,
                                   const double target,double &out_tp);

bool IsCoolingPositionComment(const string comment)
{
   return StringFind(comment,"HB COOL ")==0;
}

bool IsCoolingPositionId(const ulong id)
{
   if(id==0) return false;
   // Preserve caller selection: looking up another position must never change
   // which trade supplies volume, open price or floating profit to the caller.
   ulong previous=(ulong)PositionGetInteger(POSITION_TICKET);
   bool found=false;
   for(int i=0;i<PositionsTotal();i++)
   {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol ||
         PositionGetInteger(POSITION_MAGIC)!=InpMagic) continue;
      if((ulong)PositionGetInteger(POSITION_IDENTIFIER)==id)
      {
         found=IsCoolingPositionComment(PositionGetString(POSITION_COMMENT));
         break;
      }
   }
   if(previous>0 && !PositionSelectByTicket(previous)) return false;
   return found;
}

int CoolingOpenCount()
{
   int n=0;
   for(int i=0;i<PositionsTotal();i++)
   {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL)==_Symbol &&
         PositionGetInteger(POSITION_MAGIC)==InpMagic &&
         IsCoolingPositionComment(PositionGetString(POSITION_COMMENT))) n++;
   }
   return n;
}

// Net floating P/L for one direction only. The trigger is the aggregate loss
// of BUYs or SELLs as a group (profits in that same direction offset losses).
// Values are in the account's native currency, which is USC on this account.
// Count live non-cooling positions for this EA and direction only.
// Cooling orders must not increase their own trigger count.
int CoolingBasePositions(const ENUM_POSITION_TYPE side)
{
   int n=0;
   for(int i=0;i<PositionsTotal();i++)
   {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol ||
         PositionGetInteger(POSITION_MAGIC)!=InpMagic ||
         (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE)!=side ||
         IsCoolingPositionComment(PositionGetString(POSITION_COMMENT))) continue;
      n++;
   }
   return n;
}

double SideLossUSC(const ENUM_POSITION_TYPE side)
{
   double net=0.0;
   for(int i=0;i<PositionsTotal();i++)
   {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol ||
         PositionGetInteger(POSITION_MAGIC)!=InpMagic ||
         (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE)!=side) continue;
      net+=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
   }
   return (net<0.0 ? -net : 0.0);
}

bool CoolingMarginOK(const ENUM_ORDER_TYPE side,const double lot)
{
   if(AccountInfoDouble(ACCOUNT_MARGIN)>0.0 &&
      AccountInfoDouble(ACCOUNT_MARGIN_LEVEL)<InpCoolingMinMarginLevel) return false;
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol,tick) || tick.ask<=0 || tick.bid<=0) return false;
   double margin=0.0;
   if(!OrderCalcMargin(side,_Symbol,lot,(side==ORDER_TYPE_BUY?tick.ask:tick.bid),margin)) return false;
   return AccountInfoDouble(ACCOUNT_MARGIN_FREE)>=margin*InpMinFreeMarginFactor;
}

// Recover executed tiers, including already closed trades, for the current basket.
// Weighted fill prices handle partial execution without counting a tier twice.
bool CoolingExecutionState(const int side,int &stage,double &first,double &last)
{
   stage=0; first=0.0; last=0.0;
   if(!GHBHistorySelect(g_basket_start,TimeCurrent())) return false;
   double volumes[11],values[11];
   ArrayInitialize(volumes,0.0); ArrayInitialize(values,0.0);
   string prefix=(side==0?"HB COOL BUY L":"HB COOL SELL L");
   for(int i=0;i<HistoryDealsTotal();i++)
   {
      ulong deal=HistoryDealGetTicket(i);
      if(deal==0 || HistoryDealGetString(deal,DEAL_SYMBOL)!=_Symbol ||
         HistoryDealGetInteger(deal,DEAL_MAGIC)!=InpMagic ||
         HistoryDealGetInteger(deal,DEAL_ENTRY)!=DEAL_ENTRY_IN ||
         HistoryDealGetInteger(deal,DEAL_TYPE)!=(side==0?DEAL_TYPE_BUY:DEAL_TYPE_SELL)) continue;
      string comment=HistoryDealGetString(deal,DEAL_COMMENT);
      if(StringFind(comment,prefix)!=0)
         comment=HistoryOrderGetString((ulong)HistoryDealGetInteger(deal,DEAL_ORDER),ORDER_COMMENT);
      if(StringFind(comment,prefix)!=0) continue;
      int tier=(int)StringToInteger(StringSubstr(comment,StringLen(prefix)));
      if(tier<1 || tier>10) return false;
      double volume=HistoryDealGetDouble(deal,DEAL_VOLUME);
      volumes[tier]+=volume;
      values[tier]+=volume*HistoryDealGetDouble(deal,DEAL_PRICE);
      stage=MathMax(stage,tier);
   }
   if(stage==0) return true;
   for(int tier=1;tier<=stage;tier++) if(volumes[tier]<=0.0) return false;
   first=values[1]/volumes[1]; last=values[stage]/volumes[stage];
   return first>0.0 && last>0.0;
}

// Convert account-currency loss to an adverse price distance once per sequence.
// Use broker OrderCalcProfit, not an assumed gold contract size or USD conversion.
bool CoolingFixedDistance(const ENUM_ORDER_TYPE side,const double entry,double &distance)
{
   double ticksize=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   if(ticksize<=0.0 || entry<=0.0) return false;
   double lo=0.0,hi=ticksize,profit=0.0;
   bool bracketed=false;
   for(int i=0;i<60;i++)
   {
      double price=entry+(side==ORDER_TYPE_BUY?-hi:hi);
      if(price<=0.0 || !OrderCalcProfit(side,_Symbol,InpCoolingFirstLot,entry,price,profit)) return false;
      if(-profit>=InpCoolingLossStepUSC) { bracketed=true; break; }
      hi*=2.0;
   }
   if(!bracketed) return false;
   for(int i=0;i<60;i++)
   {
      double mid=(lo+hi)*0.5;
      if(!OrderCalcProfit(side,_Symbol,InpCoolingFirstLot,entry,
                         entry+(side==ORDER_TYPE_BUY?-mid:mid),profit)) return false;
      if(-profit>=InpCoolingLossStepUSC) hi=mid; else lo=mid;
   }
   distance=MathCeil(hi/ticksize-1e-8)*ticksize;
   return distance>0.0;
}

// Eight base trades arm the first market entry. Later entries depend only on
// adverse distance from the last executed cooling entry, never on base count.
// One entry per interval; stop after tier 10 (no repeated capped 10-lot entries).
void ManageSideLossCooling()
{
   if(!InpEnableSideLossCooling || g_basket_start<=0 || g_exit_in_progress ||
      g_technical_pause || !CanTradeNow()) return;
   datetime now=TimeCurrent();
   if(g_cooling_last_open_time>0 && now-g_cooling_last_open_time<InpCoolingMinSecondsBetweenTrades) return;
   if(CoolingOpenCount()>=InpCoolingMaxOpenTrades) return;
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol,tick) || tick.ask<=0 || tick.bid<=0) return;
   if(InpMaxSpreadPrice>0 && tick.ask-tick.bid>InpMaxSpreadPrice) return;

   for(int side=0;side<2;side++)
   {
      if(g_park_side==side) continue; // v3.59: no averaging into the parked trend side
      if((side==0 && g_trend_dir<0) || (side==1 && g_trend_dir>0)) continue; // v3.66 trend mode
      ENUM_POSITION_TYPE pside=(side==0?POSITION_TYPE_BUY:POSITION_TYPE_SELL);
      ENUM_ORDER_TYPE otype=(side==0?ORDER_TYPE_BUY:ORDER_TYPE_SELL);
      int baseCount=CoolingBasePositions(pside);
      double loss=SideLossUSC(pside); // diagnostics only; not a trigger
      string stageKey=(side==0?g_cooling_buy_stage_key:g_cooling_sell_stage_key);
      if(stageKey=="") continue;
      string epochKey=stageKey+".epoch",gapKey=stageKey+".gap";
      string sentKey=stageKey+".sent",orderKey=stageKey+".order";
      if(!GlobalVariableCheck(epochKey) || (datetime)GlobalVariableGet(epochKey)!=g_basket_start)
      {
         GlobalVariableSet(epochKey,(double)g_basket_start);
         GlobalVariableDel(gapKey); GlobalVariableDel(sentKey); GlobalVariableDel(orderKey);
      }
      int stage=0; double first=0.0,last=0.0;
      if(!CoolingExecutionState(side,stage,first,last)) continue;
      // A still-live market order or unconfirmed fill must not submit twice.
      ulong outstanding=GlobalVariableCheck(orderKey)?(ulong)GlobalVariableGet(orderKey):0;
      if(outstanding>0 && OrderSelect(outstanding)) continue;
      int sentStage=GlobalVariableCheck(sentKey)?(int)GlobalVariableGet(sentKey):0;
      if(sentStage>stage)
      {
         if(outstanding==0 || !HistoryOrderSelect(outstanding)) continue;
         ENUM_ORDER_STATE state=(ENUM_ORDER_STATE)HistoryOrderGetInteger(outstanding,ORDER_STATE);
         if(state!=ORDER_STATE_CANCELED && state!=ORDER_STATE_REJECTED && state!=ORDER_STATE_EXPIRED) continue;
         GlobalVariableSet(sentKey,(double)stage);
      }
      if(stage>=10) continue;
      if(stage==0 && baseCount<InpCoolingStartPositions) continue;
      int due=stage+1;
      double lot=InpCoolingFirstLot+(due-1)*InpCoolingLotStep;
      if(lot>InpCoolingMaxLot+1e-8) continue;
      double gap=GlobalVariableCheck(gapKey)?GlobalVariableGet(gapKey):0.0;
      if(gap<=0.0)
      {
         double anchor=(stage>0?first:(side==0?tick.ask:tick.bid));
         if(!CoolingFixedDistance(otype,anchor,gap)) continue;
         // Only lock the distance after a real first execution exists.
         if(stage>0) GlobalVariableSet(gapKey,gap);
      }
      double entryQuote=(side==0?tick.ask:tick.bid);
      if(stage>0)
      {
         double adverse=(side==0?last-entryQuote:entryQuote-last);
         if(adverse+1e-9<gap) continue;
      }
      double minlot=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
      double maxlot=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
      double volstep=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
      if(volstep<=0 || lot<minlot-1e-8 || lot>maxlot+1e-8 ||
         MathAbs(lot/volstep-MathRound(lot/volstep))>1e-6)
      {
         PrintFormat("HBv3.31 COOLING BLOCKED | side=%s loss=%.2f USC step=%d lot=%.2f broker min=%.2f max=%.2f step=%.3f; stage not consumed",
                     side==0?"BUY":"SELL",loss,due,lot,minlot,maxlot,volstep);
         continue;
      }
      if(!CoolingMarginOK(otype,lot))
      {
         PrintFormat("HBv3.31 COOLING MARGIN BLOCK | side=%s loss=%.2f USC requestedLot=%.2f freeMargin=%.2f marginLevel=%.2f%%; stage not consumed",
                     side==0?"BUY":"SELL",loss,lot,AccountInfoDouble(ACCOUNT_MARGIN_FREE),AccountInfoDouble(ACCOUNT_MARGIN_LEVEL));
         continue;
      }
      double entry=(side==0?tick.ask:tick.bid),tp=0.0;
      if(!PendingLimitTPForAccountProfit(otype,entry,lot,InpCoolingTakeProfitUSC,tp))
      {
         PrintFormat("HBv3.31 COOLING TP CALC FAILED | side=%s lot=%.2f target=%.2f USC",side==0?"BUY":"SELL",lot,InpCoolingTakeProfitUSC);
         continue;
      }
      string comment=StringFormat("HB COOL %s L%02d",side==0?"BUY":"SELL",due);
      bool sent=(side==0?trade.Buy(lot,_Symbol,0.0,0.0,tp,comment):trade.Sell(lot,_Symbol,0.0,0.0,tp,comment));
      uint ret=trade.ResultRetcode();
      if(sent && (ret==TRADE_RETCODE_DONE || ret==TRADE_RETCODE_PLACED || ret==TRADE_RETCODE_DONE_PARTIAL))
      {
         GlobalVariableSet(sentKey,(double)due);
         GlobalVariableSet(orderKey,(double)trade.ResultOrder());
         // History provides the actual fill price, including slippage, next tick.
         g_cooling_last_open_time=now;
         GlobalVariableSet(g_cooling_last_time_key,(double)now);
         PrintFormat("HBv3.41 COOLING ACCEPTED | side=%s baseCount=%d step=%d lot=%.2f fixedGap=%.5f previousFill=%.5f TP=%.5f target=%.2f USC",
                     side==0?"BUY":"SELL",baseCount,due,lot,gap,last,tp,InpCoolingTakeProfitUSC);
         return;
      }
      PrintFormat("HBv3.31 COOLING ORDER REJECTED | side=%s loss=%.2f USC step=%d lot=%.2f ret=%u %s",
                  side==0?"BUY":"SELL",loss,due,lot,ret,trade.ResultRetcodeDescription());
      return;
   }
}

bool IsOwnPosition(ulong ticket)
{
   if(ticket==0 || !PositionSelectByTicket(ticket)) return false;
   if(PositionGetString(POSITION_SYMBOL)!=_Symbol) return false;
   if(PositionGetInteger(POSITION_MAGIC)!=InpMagic) return false;
   return true;
}

void ScanBasket(BasketState &b,const bool include_counter=false)
{
   ZeroMemory(b);
   b.oldest_open=0;
   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket=PositionGetTicket(i);
      if(!IsOwnPosition(ticket)) continue;
      if(!include_counter)
      {
         ulong sid=(ulong)PositionGetInteger(POSITION_IDENTIFIER);
         if((g_counter_id!=0 && sid==g_counter_id) ||
            (g_follow_id!=0 && sid==g_follow_id) || IsLimitPositionId(sid) || IsReplacementId(sid) ||
            IsCoolingPositionComment(PositionGetString(POSITION_COMMENT))) continue;
      }
      b.count++;
      datetime opened=(datetime)PositionGetInteger(POSITION_TIME);
      long opened_msc=(long)PositionGetInteger(POSITION_TIME_MSC);
      long identifier=(long)PositionGetInteger(POSITION_IDENTIFIER);
      double vol=PositionGetDouble(POSITION_VOLUME);
      double price=PositionGetDouble(POSITION_PRICE_OPEN);
      b.floating_net += PositionGetDouble(POSITION_PROFIT)
                      + PositionGetDouble(POSITION_SWAP);
      if(b.oldest_open==0 || opened<b.oldest_open) b.oldest_open=opened;
      if(opened>b.newest_open) b.newest_open=opened;
      if(b.id_count<ArraySize(b.identifiers))
         b.identifiers[b.id_count++]=(ulong)identifier;
      if(PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY)
      {
         b.buys++;
         b.buy_volume+=vol;
         if(opened_msc>=b.last_buy_msc)
         {
            b.last_buy_msc=opened_msc;
            b.last_buy_price=price;
         }
      }
      else if(PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_SELL)
      {
         b.sells++;
         b.sell_volume+=vol;
         if(opened_msc>=b.last_sell_msc)
         {
            b.last_sell_msc=opened_msc;
            b.last_sell_price=price;
         }
      }
   }
}

// Persist the permanent position identifiers, not tickets: broker service
// operations can reassign tickets while the position identifier stays stable.
bool CanTradeNow();
void CloseAll(const string reason);
// Uses actual gold contract size and the native account currency.
bool PendingLimitTPForAccountProfit(const ENUM_ORDER_TYPE side,
                                   const double entry,const double volume,
                                   const double target,double &out_tp);

bool IsSeedOpen(const ulong seed_identifier)
{
   if(seed_identifier==0) return false;
   for(int i=0;i<PositionsTotal();i++)
   {
      ulong ticket=PositionGetTicket(i);
      if(!IsOwnPosition(ticket)) continue;
      if((ulong)PositionGetInteger(POSITION_IDENTIFIER)==seed_identifier) return true;
   }
   return false;
}

bool IsCounterPresent()
{
   if(g_counter_id==0) return false;
   for(int i=0;i<PositionsTotal();i++)
   {
      ulong t=PositionGetTicket(i);
      if(!IsOwnPosition(t)) continue;
      if((ulong)PositionGetInteger(POSITION_IDENTIFIER)==g_counter_id) return true;
   }
   return false;
}

// A generic position identifier lookup, insensitive to broker ticket changes.
bool IsPositionIdOpen(const ulong id)
{
   if(id==0) return false;
   for(int i=0;i<PositionsTotal();i++)
   {
      ulong ticket=PositionGetTicket(i);
      if(!IsOwnPosition(ticket)) continue;
      if((ulong)PositionGetInteger(POSITION_IDENTIFIER)==id) return true;
   }
   return false;
}

bool IsTrackedId(const ulong id)
{
   return (id!=0 && (id==g_seed_buy_id || id==g_seed_sell_id ||
           id==g_third_id || id==g_fourth_id ||
           id==g_counter_id || id==g_follow_id || IsLimitPositionId(id) || IsReplacementId(id) || IsCoolingPositionId(id)));
}

// True only for a fully CLOSED trade with booked net > 0 (including fees and swap).
// Partial exits are not accepted because the identity must no longer be open.
bool ClosedPositionReport(const ulong id,double &net,datetime &exited)
{
   net=0.0;
   exited=0;
   if(id==0 || g_basket_start<=0 || IsPositionIdOpen(id)) return false;
   if(!HistorySelectByPosition(id)) return false;
   bool entered=false,closed=false;
   for(int i=0;i<HistoryDealsTotal();i++)
   {
      ulong d=HistoryDealGetTicket(i);
      if(d==0 || (ulong)HistoryDealGetInteger(d,DEAL_POSITION_ID)!=id ||
         HistoryDealGetString(d,DEAL_SYMBOL)!=_Symbol) continue;
      ENUM_DEAL_ENTRY t=(ENUM_DEAL_ENTRY)HistoryDealGetInteger(d,DEAL_ENTRY);
      if(t==DEAL_ENTRY_IN || t==DEAL_ENTRY_INOUT) entered=true;
      if(t==DEAL_ENTRY_OUT || t==DEAL_ENTRY_OUT_BY || t==DEAL_ENTRY_INOUT)
      {
         closed=true;
         datetime when=(datetime)HistoryDealGetInteger(d,DEAL_TIME);
         if(when>exited) exited=when;
      }
      net+=HistoryDealGetDouble(d,DEAL_PROFIT)
          +HistoryDealGetDouble(d,DEAL_SWAP)
          +HistoryDealGetDouble(d,DEAL_COMMISSION)
          +HistoryDealGetDouble(d,DEAL_FEE);
   }
   return entered && closed;
}

// A CLOSED original leg need not have closed at a profit. Earlier versions
// wrongly treated a verified losing close as missing ledger data and disabled
// replenishment of unrelated broker LIMIT orders indefinitely. This checks
// only that the lifecycle is ACCOUNTED FOR, not that its P/L was positive.
bool TrackedPositionHealthy(const ulong id,const bool was_opened)
{
   if(!was_opened) return true;
   if(id==0) return false;
   if(IsPositionIdOpen(id)) return true;
   double booked=0.0;
   datetime exited=0;
   if(!ClosedPositionReport(id,booked,exited)) return false;
   if(booked<=0.0)
   {
      static datetime last_warn=0;
      if(TimeCurrent()-last_warn>=60)
      {
         last_warn=TimeCurrent();
         PrintFormat("HBv3.30 VERIFIED CLOSED LOSING LEG | id=%I64u PnL=%.2f %s | other positions and pending orders are not liquidated",
                     id,booked,AccountInfoString(ACCOUNT_CURRENCY));
      }
   }
   return true;
}

// Records newly opened position's stable identifier; never infer from ticket number.
bool FindNewOwnedPositionId(const BasketState &before,ulong &newid)
{
   newid=0;
   int found=0;
   for(int i=0;i<PositionsTotal();i++)
   {
      ulong t=PositionGetTicket(i);
      if(!IsOwnPosition(t)) continue;
      ulong id=(ulong)PositionGetInteger(POSITION_IDENTIFIER);
      bool was=false;
      for(int j=0;j<before.id_count;j++) if(before.identifiers[j]==id) {was=true;break;}
      if(was) continue;
      newid=id;
      found++;
   }
   return found==1 && newid!=0;
}

// A missing ORIGINAL seed is permitted only after the third trade, only on
// its winning side, and only if its booked P/L is positive.  An unrelated
// disappearance or an emergency stop at a loss still exits the entire basket.
bool SeedWasClosedInProfit(const ulong seed_identifier)
{
   if(seed_identifier==0 || g_basket_start==0) return false;
   if(!GHBHistorySelect(g_basket_start-2,TimeCurrent()+60)) return false;
   bool found_entry=false, found_exit=false;
   double booked=0.0;
   for(int i=0;i<HistoryDealsTotal();i++)
   {
      ulong d=HistoryDealGetTicket(i);
      if(d==0 || (ulong)HistoryDealGetInteger(d,DEAL_POSITION_ID)!=seed_identifier) continue;
      if(HistoryDealGetString(d,DEAL_SYMBOL)!=_Symbol) continue;
      ENUM_DEAL_ENTRY entry=(ENUM_DEAL_ENTRY)HistoryDealGetInteger(d,DEAL_ENTRY);
      if(entry==DEAL_ENTRY_IN || entry==DEAL_ENTRY_INOUT) found_entry=true;
      if(entry==DEAL_ENTRY_OUT || entry==DEAL_ENTRY_OUT_BY || entry==DEAL_ENTRY_INOUT)
         found_exit=true;
      booked += HistoryDealGetDouble(d,DEAL_PROFIT)
              + HistoryDealGetDouble(d,DEAL_SWAP)
              + HistoryDealGetDouble(d,DEAL_COMMISSION)
              + HistoryDealGetDouble(d,DEAL_FEE);
   }
   return found_entry && found_exit && booked>0.0;
}

// Find the exact price representing a target GROSS trade profit. Uses
// OrderCalcProfit rather than assuming XAUUSD contract size or account FX.




// Full P/L: floating positions + realized trades, swaps and fees already booked
// since this basket was created. The persisted start time includes earlier TP exits.
// Cannot estimate future commissions or slippage; use InpExitCostReserve.
bool BasketNetPnL(const BasketState &b,double &net)
{
   net=b.floating_net;
   if(g_basket_start<=0) return false;
   if(!GHBHistorySelect(g_basket_start-2,TimeCurrent()+60)) return false;
   ulong owned_ids[];
   int deals=HistoryDealsTotal();
   for(int i=0;i<deals;i++)
   {
      ulong deal=HistoryDealGetTicket(i);
      if(deal==0 || HistoryDealGetString(deal,DEAL_SYMBOL)!=_Symbol) continue;
      if(HistoryDealGetInteger(deal,DEAL_MAGIC)!=InpMagic) continue;
      ENUM_DEAL_ENTRY entry=(ENUM_DEAL_ENTRY)HistoryDealGetInteger(deal,DEAL_ENTRY);
      if(entry!=DEAL_ENTRY_IN && entry!=DEAL_ENTRY_INOUT) continue;
      ulong id=(ulong)HistoryDealGetInteger(deal,DEAL_POSITION_ID);
      bool existing=false;
      for(int j=0;j<ArraySize(owned_ids);j++) if(owned_ids[j]==id) {existing=true;break;}
      if(!existing)
      {
         int n=ArraySize(owned_ids);
         ArrayResize(owned_ids,n+1);
         owned_ids[n]=id;
      }
   }
   // SL/TP deals can carry a broker-specific magic number; use position IDs.
   for(int i=0;i<deals;i++)
   {
      ulong deal=HistoryDealGetTicket(i);
      if(deal==0 || HistoryDealGetString(deal,DEAL_SYMBOL)!=_Symbol) continue;
      ulong id=(ulong)HistoryDealGetInteger(deal,DEAL_POSITION_ID);
      bool belongs=false;
      for(int j=0;j<ArraySize(owned_ids);j++) if(owned_ids[j]==id) {belongs=true;break;}
      if(!belongs) continue;
      net+=HistoryDealGetDouble(deal,DEAL_PROFIT)
           +HistoryDealGetDouble(deal,DEAL_SWAP)
           +HistoryDealGetDouble(deal,DEAL_COMMISSION)
           +HistoryDealGetDouble(deal,DEAL_FEE);
   }
   return ArraySize(owned_ids)>0;
}

// Existing live trades from older EA versions can have a different volume
// from the current ladder. A trusted POSITION_IDENTIFIER by itself is not
// sufficient to waive volume checks: also verify the CURRENT Magic, symbol,
// side, and original broker entry deal(s) by stable position ID.
// Only validation of an ALREADY OPEN trade is relaxed; no new placement lot
// is changed. Missing/inconsistent broker history still fails closed.
bool BrokerVerifiedExistingVolume(const ulong id,const double liveVolume,
                                  const ENUM_POSITION_TYPE side)
{
   if(id==0 || liveVolume<=0.0 || !HistorySelectByPosition(id)) return false;
   double original=0.0;
   int entries=0;
   for(int i=0;i<HistoryDealsTotal();i++)
   {
      ulong deal=HistoryDealGetTicket(i);
      if(deal==0 || (ulong)HistoryDealGetInteger(deal,DEAL_POSITION_ID)!=id ||
         HistoryDealGetString(deal,DEAL_SYMBOL)!=_Symbol ||
         HistoryDealGetInteger(deal,DEAL_MAGIC)!=InpMagic) continue;
      ENUM_DEAL_ENTRY entry=(ENUM_DEAL_ENTRY)HistoryDealGetInteger(deal,DEAL_ENTRY);
      if(entry!=DEAL_ENTRY_IN && entry!=DEAL_ENTRY_INOUT) continue;
      ENUM_DEAL_TYPE type=(ENUM_DEAL_TYPE)HistoryDealGetInteger(deal,DEAL_TYPE);
      if(type!=(side==POSITION_TYPE_BUY?DEAL_TYPE_BUY:DEAL_TYPE_SELL)) return false;
      original+=HistoryDealGetDouble(deal,DEAL_VOLUME);
      entries++;
   }
   double tolerance=MathMax(1e-7,SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP)*0.1);
   return entries>0 && original>0.0 && liveVolume<=original+tolerance;
}

// Validate each currently open position; old lots are accepted only when
// the broker volume AND the exact historical entry are independently valid.
bool BasketVolumesValid()
{
   double tolerance=MathMax(1e-7,SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP)*0.1);
   for(int i=0;i<PositionsTotal();i++)
   {
      ulong t=PositionGetTicket(i);
      if(!IsOwnPosition(t)) continue;
      ulong id=(ulong)PositionGetInteger(POSITION_IDENTIFIER);
      // Snapshot before helper lookups: they can change MT5's selected position.
      double actual_lot=PositionGetDouble(POSITION_VOLUME);
      ENUM_POSITION_TYPE actual_side=(ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      bool is_cooling=IsCoolingPositionComment(PositionGetString(POSITION_COMMENT));
      bool is_counter=(g_counter_id!=0 && id==g_counter_id);
      bool is_follow=(g_follow_id!=0 && id==g_follow_id);
      if(!IsTrackedId(id))
      {
         PrintFormat("HBv3.37 VOLUME AUDIT | ticket=%I64u id=%I64u role=UNTRACKED volume=%.2f",t,id,actual_lot);
         return false;
      }
      if(is_cooling) continue; // cooling uses independent staged 1..10 lot sizes
      int limit_slot=LimitSlotForPositionId(id);
      if(limit_slot>=0)
      {
         // Grandfather verified open positions that were entered by v3.16.
         if(!LimitVolumeMatchesSlot(limit_slot,actual_lot))
         {
            // Legacy filled LIMIT positions may have smaller lots than the
            // currently configured ladder. The ID has already been verified
            // by IsTrackedId and LimitSlotForPositionId. Never upsize live
            // positions, and do not relax validation for pending orders.
            double minLot=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
            double maxLot=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
            double stepLot=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
            bool brokerVolume=(stepLot>0.0 && actual_lot>=minLot-tolerance &&
               actual_lot<=maxLot+tolerance &&
               MathAbs(actual_lot/stepLot-MathRound(actual_lot/stepLot))<=0.00001);
            bool legacySmaller=(actual_lot<LimitLotForSlot(limit_slot)-tolerance);
            if(!brokerVolume || (!legacySmaller &&
               !BrokerVerifiedExistingVolume(id,actual_lot,
                  actual_side)))
            {
               PrintFormat("HBv3.38 VOLUME INVALID | ticket=%I64u id=%I64u slot=%d actual=%.2f expected=%.2f brokerOK=%d",t,id,limit_slot,actual_lot,LimitLotForSlot(limit_slot),(int)brokerVolume);
               return false;
            }
            // Accepted only for an already-open, identified LIMIT position.
            // Its actual volume is not changed.

         }
         continue;
      }
      // REPEAT positions are a separate tracked role, not original core legs.
      // Accept an already-open legacy smaller lot only for its exact mapped ID
      // and direction, with valid broker volume. New repeats still use InpFixedLot.
      if(IsReplacementId(id))
      {
         int repeatSide=(g_repeat_position[0]==id?0:1);
         double minLot=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
         double maxLot=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
         double stepLot=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
         bool brokerOK=(stepLot>0.0 && actual_lot>=minLot-tolerance &&
            actual_lot<=maxLot+tolerance &&
            MathAbs(actual_lot/stepLot-MathRound(actual_lot/stepLot))<=0.00001);
         bool sideOK=(actual_side==(repeatSide==0?POSITION_TYPE_BUY:POSITION_TYPE_SELL));
         bool sizeOK=(actual_lot<=InpFixedLot+tolerance);
         if(!sizeOK && brokerOK && sideOK)
            sizeOK=BrokerVerifiedExistingVolume(id,actual_lot,actual_side);
         if(!brokerOK || !sideOK || !sizeOK)
         {
            PrintFormat("HBv3.42 REPEAT VOLUME INVALID | ticket=%I64u id=%I64u actual=%.2f configured=%.2f brokerOK=%d sideOK=%d",
                        t,id,actual_lot,InpFixedLot,(int)brokerOK,(int)sideOK);
            return false;
         }
         continue;
      }
      double correct_lot=(is_counter ? InpCounterLot :
                         (is_follow ? InpFollowLot :
                          ((id==g_seed_buy_id || id==g_seed_sell_id)?InpSeedLot:InpFixedLot)));
      if(MathAbs(actual_lot-correct_lot)>tolerance)
      {
         // An identified, pre-existing core leg can retain its old smaller
         // volume after an EA upgrade. Never resize it or treat it as a new
         // order. This exception applies ONLY to tracked core identifiers.
         bool verifiedCore=(id==g_seed_buy_id || id==g_seed_sell_id ||
                            id==g_third_id || id==g_fourth_id ||
                            is_counter || is_follow);
         double minLot=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
         double maxLot=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
         double stepLot=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
         bool validBrokerLot=(stepLot>0.0 && actual_lot>=minLot-tolerance &&
            actual_lot<=maxLot+tolerance &&
            MathAbs(actual_lot/stepLot-MathRound(actual_lot/stepLot))<=0.00001);
         bool legacySmaller=(actual_lot<correct_lot-tolerance);
         if(!verifiedCore || !validBrokerLot || (!legacySmaller &&
            !BrokerVerifiedExistingVolume(id,actual_lot,
               actual_side)))
         {
            PrintFormat("HBv3.39 CORE VOLUME INVALID | ticket=%I64u id=%I64u actual=%.2f expected=%.2f verified=%d brokerOK=%d",t,id,actual_lot,correct_lot,(int)verifiedCore,(int)validBrokerLot);
            return false;
         }
         // Keep broker position intact; accepting its historical lot size
         // does not override the remaining ledger and margin protections.
      }
   }
   return true;
}

// Today realized P/L including broker TP or SL exits where the exit deal's
// magic may differ from the entry order's magic. Historical lookback allows
// basket entries before midnight to be attributed to this EA by position ID.
double TodayRealizedPnL()
{
   static datetime cache_time=0;
   static double cached=0.0;
   datetime now=TimeCurrent();
   if(now==cache_time) return cached;
   MqlDateTime parts;
   TimeToStruct(now,parts);
   parts.hour=0; parts.min=0; parts.sec=0;
   datetime day_start=StructToTime(parts);
   // Basket maximum age defaults to 45min. Look back two days for overnight
   // entries; only DEaLS belonging to this magic's opening position ID count.
   if(!GHBHistorySelect(day_start-2*86400,now)) return 0.0;
   ulong ids[];
   int count=HistoryDealsTotal();
   for(int i=0;i<count;i++)
   {
      ulong d=HistoryDealGetTicket(i);
      if(d==0 || HistoryDealGetString(d,DEAL_SYMBOL)!=_Symbol ||
         HistoryDealGetInteger(d,DEAL_MAGIC)!=InpMagic) continue;
      ENUM_DEAL_ENTRY entry=(ENUM_DEAL_ENTRY)HistoryDealGetInteger(d,DEAL_ENTRY);
      if(entry!=DEAL_ENTRY_IN && entry!=DEAL_ENTRY_INOUT) continue;
      ulong id=(ulong)HistoryDealGetInteger(d,DEAL_POSITION_ID);
      bool found=false;
      for(int j=0;j<ArraySize(ids);j++) if(ids[j]==id) {found=true;break;}
      if(!found) {int n=ArraySize(ids);ArrayResize(ids,n+1);ids[n]=id;}
   }
   double total=0.0;
   for(int i=0;i<count;i++)
   {
      ulong d=HistoryDealGetTicket(i);
      if(d==0 || HistoryDealGetString(d,DEAL_SYMBOL)!=_Symbol ||
         (datetime)HistoryDealGetInteger(d,DEAL_TIME)<day_start) continue;
      ulong id=(ulong)HistoryDealGetInteger(d,DEAL_POSITION_ID);
      bool ours=false;
      for(int j=0;j<ArraySize(ids);j++) if(ids[j]==id) {ours=true;break;}
      if(!ours) continue;
      total += HistoryDealGetDouble(d,DEAL_PROFIT)
              +HistoryDealGetDouble(d,DEAL_SWAP)
              +HistoryDealGetDouble(d,DEAL_COMMISSION)
              +HistoryDealGetDouble(d,DEAL_FEE);
   }
   cache_time=now;
   cached=total;
   return total;
}

bool CanTradeNow()
{
   return (TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)!=0 &&
           MQLInfoInteger(MQL_TRADE_ALLOWED)!=0 &&
           AccountInfoInteger(ACCOUNT_TRADE_ALLOWED)!=0 &&
           AccountInfoInteger(ACCOUNT_TRADE_EXPERT)!=0);
}

bool SpreadOK(const MqlTick &tick)
{
   if(tick.ask<=0 || tick.bid<=0 || tick.ask<tick.bid) return false;
   if(InpMaxSpreadPrice<=0) return true;
   return (tick.ask-tick.bid)<=InpMaxSpreadPrice;
}

// Do not mistake a balanced BUY+SELL pair for a market-neutral free trade.
// Two legs each pay a spread, plus fees and possibly swap.
bool EstimatedSeedCostOK(const MqlTick &tick)
{
   double buy_pl=0, sell_pl=0;
   if(!OrderCalcProfit(ORDER_TYPE_BUY,_Symbol,InpSeedLot,tick.ask,tick.bid,buy_pl) ||
      !OrderCalcProfit(ORDER_TYPE_SELL,_Symbol,InpSeedLot,tick.bid,tick.ask,sell_pl))
   {
      EntryBlocked("SEED_COST_CALC_FAILED: broker cannot calculate seed PnL");
      return false;
   }
   double cost=MathMax(0.0,-buy_pl-sell_pl);
   double allowed=InpMaxSeedSpreadCost*(InpSeedLot/0.10);
   if(cost>allowed)
   {
      EntryBlocked(StringFormat("SEED_SPREAD_COST cost=%.2f allowed=%.2f seedLot=%.2f (reference cap per 0.10 lot=%.2f)",cost,allowed,InpSeedLot,InpMaxSeedSpreadCost));
      return false;
   }
   return true;
}

bool HasOtherPositionsOnSymbol()
{
   for(int i=0;i<PositionsTotal();i++)
   {
      ulong t=PositionGetTicket(i);
      if(t==0 || !PositionSelectByTicket(t)) continue;
      if(PositionGetString(POSITION_SYMBOL)==_Symbol &&
         PositionGetInteger(POSITION_MAGIC)!=InpMagic &&
         PositionGetInteger(POSITION_MAGIC)!=InpMagic+2000000) return true; // v3.66 momentum is ours
   }
   return false;
}

// Prevent overlapping a new ladder on top of outstanding GTC orders from old EAs.
bool HasOtherPendingOrdersOnSymbol()
{
   for(int i=0;i<OrdersTotal();i++)
   {
      ulong ticket=OrderGetTicket(i);
      if(ticket==0 || !OrderSelect(ticket)) continue;
      if(OrderGetString(ORDER_SYMBOL)==_Symbol &&
         OrderGetInteger(ORDER_MAGIC)!=InpMagic &&
         OrderGetInteger(ORDER_MAGIC)!=InpMagic+2000000) return true; // v3.66 momentum is ours
   }
   return false;
}

// v3.29: OPTIONAL one-at-a-time removal of an OBSOLETE v3.26 10+10 broker
// pending ladder. This is explicitly opt-in; only pending orders, never fills.
// IMPORTANT: stop/synchronize ALL old EA terminals/VPS before enabling it.
// Refuses to act if ANY position exists on the gold symbol, regardless of Magic.
// Preflights the ENTIRE order inventory before every delete; any ambiguous
// ticket or foreign Magic blocks the migration without deleting that order.
datetime g_last_verified_legacy_migration_action=0;
datetime g_last_verified_legacy_migration_diag=0;

bool VerifiedOldPendingForMigration(const ulong ticket,
                                    bool &seenBuy[],bool &seenSell[],
                                    bool &repeatBuySeen,bool &repeatSellSeen)
{
   if(ticket==0 || !OrderSelect(ticket)) return false;
   if(OrderGetString(ORDER_SYMBOL)!=_Symbol ||
      OrderGetInteger(ORDER_MAGIC)!=InpVerifiedLegacyGridMagic) return false;
   ENUM_ORDER_TYPE type=(ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
   bool buy=(type==ORDER_TYPE_BUY_LIMIT);
   bool sell=(type==ORDER_TYPE_SELL_LIMIT);
   if(!buy && !sell) return false;
   double price=OrderGetDouble(ORDER_PRICE_OPEN);
   double tp=OrderGetDouble(ORDER_TP);
   double volume=OrderGetDouble(ORDER_VOLUME_CURRENT);
   if(price<=0 || tp<=0 || volume<=0 || volume>5.0000001 ||
      (buy && tp<=price) || (sell && tp>=price)) return false;
   string comment=OrderGetString(ORDER_COMMENT);
   for(int k=0;k<10;k++)
   {
      if(comment==StringFormat("HB L%s%d",buy?"B":"S",k+1))
      {
         if(buy)
         {
            if(seenBuy[k]) return false;
            seenBuy[k]=true;
         }
         else
         {
            if(seenSell[k]) return false;
            seenSell[k]=true;
         }
         return true;
      }
   }
   if(buy && (comment=="HB REPEAT BUY 50" || comment=="HB REPEAT BUY 80" ||
              comment=="HB REPEAT BUY 30") && !repeatBuySeen &&
      MathAbs(volume-0.10)<=1e-7)
   {
      repeatBuySeen=true;
      return true;
   }
   if(sell && (comment=="HB REPEAT SELL 50" || comment=="HB REPEAT SELL 80" ||
               comment=="HB REPEAT SELL 30") && !repeatSellSeen &&
      MathAbs(volume-0.10)<=1e-7)
   {
      repeatSellSeen=true;
      return true;
   }
   return false;
}

// Call before WaitForCleanSymbol in timer/ticks. Returns true if an action was
// executed or if old orders are still in the account and must remain isolated.
// This function NEVER places a new order, never closes an open position.
bool ProcessVerifiedFlatLegacyPendingMigration()
{
   if(!InpPermitFlatLegacyPendingMigration) return false;
   datetime now=TimeCurrent();
   // Once OUR new 40-slot network is active, migration never interrupts normal
   // management even when its own legitimate BUY/SELL positions are open.
   if(g_basket_start>0) return false;
   // Do not dismantle older pendings while any open symbol position depends
   // on the grid.
   for(int p=0;p<PositionsTotal();p++)
   {
      ulong position=PositionGetTicket(p);
      if(position==0 || !PositionSelectByTicket(position)) continue;
      if(PositionGetString(POSITION_SYMBOL)==_Symbol)
      {
         if(now-g_last_verified_legacy_migration_diag>=30)
         {
            g_last_verified_legacy_migration_diag=now;
            PrintFormat("HBv3.30 MIGRATION WAIT LIVE POSITION | ticket=%I64u: do not cancel old pending hedge/grid while ANY position exists",position);
         }
         return true;
      }
   }
   bool seenBuy[10],seenSell[10];
   for(int r=0;r<10;r++) {seenBuy[r]=false; seenSell[r]=false;}
   bool repeatBuySeen=false,repeatSellSeen=false;
   ulong firstCandidate=0;
   int oldCount=0;
   for(int i=0;i<OrdersTotal();i++)
   {
      ulong ticket=OrderGetTicket(i);
      if(ticket==0 || !OrderSelect(ticket)) continue;
      if(OrderGetString(ORDER_SYMBOL)!=_Symbol) continue;
      if(OrderGetInteger(ORDER_MAGIC)!=InpVerifiedLegacyGridMagic ||
         !VerifiedOldPendingForMigration(ticket,seenBuy,seenSell,repeatBuySeen,repeatSellSeen))
      {
         if(now-g_last_verified_legacy_migration_diag>=30)
         {
            g_last_verified_legacy_migration_diag=now;
            PrintFormat("HBv3.30 MIGRATION BLOCK UNKNOWN ORDER | ticket=%I64u magic=%I64d comment=%s; nothing canceled this pass",
                        ticket,OrderGetInteger(ORDER_MAGIC),OrderGetString(ORDER_COMMENT));
         }
         return true;
      }
      if(firstCandidate==0) firstCandidate=ticket;
      oldCount++;
   }
   if(oldCount==0) return false; // clean symbol: normal 20+20 entry allowed
   if(now-g_last_verified_legacy_migration_action<InpLegacyMigrationIntervalSeconds) return true;
   g_last_verified_legacy_migration_action=now;
   if(!CanTradeNow())
   {
      Print("HBv3.30 MIGRATION WAIT | automated trading is not permitted");
      return true;
   }
   if(firstCandidate==0 || !OrderSelect(firstCandidate)) return true;
   // Strictly reselect the same fully preflighted ticket before destructive call.
   if(OrderGetInteger(ORDER_MAGIC)!=InpVerifiedLegacyGridMagic ||
      OrderGetString(ORDER_SYMBOL)!=_Symbol) return true;
   bool sent=trade.OrderDelete(firstCandidate);
   uint ret=trade.ResultRetcode();
   if(!sent || ret!=TRADE_RETCODE_DONE)
   {
      PrintFormat("HBv3.30 MIGRATION DELETE REJECT | ticket=%I64u ret=%u %s; no new network",
                  firstCandidate,ret,trade.ResultRetcodeDescription());
      return true;
   }
   if(OrderSelect(firstCandidate))
   {
      PrintFormat("HBv3.30 MIGRATION VERIFY WAIT | ticket=%I64u still open at broker; no new network",firstCandidate);
      return true;
   }
   PrintFormat("HBv3.30 MIGRATION DELETED VERIFIED OLD PENDING | ticket=%I64u oldMagic=%I64d remainingBeforeDelete=%d; no positions were closed",
               firstCandidate,InpVerifiedLegacyGridMagic,oldCount);
   return true; // wait next tick/timer to revalidate entire symbol inventory
}

// v3.29: v3.26 leftovers must NOT unload the EA from the chart.
// Stay ATTACHED, do not manage/cancel foreign orders or open a new grid.
// Recheck on every tick and timer; once the symbol is actually clean,
// normal logic resumes with the isolated 40-slot state namespace.
datetime g_clean_symbol_wait_last_log=0;
bool WaitForCleanSymbol()
{
   ulong foreign_position=0,foreign_pending=0;
   long foreign_position_magic=0,foreign_pending_magic=0;
   for(int j=0;j<PositionsTotal();j++)
   {
      ulong ticket=PositionGetTicket(j);
      if(ticket==0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL)==_Symbol &&
         PositionGetInteger(POSITION_MAGIC)!=InpMagic &&
         PositionGetInteger(POSITION_MAGIC)!=InpMagic+1000000 &&
         PositionGetInteger(POSITION_MAGIC)!=InpMagic+2000000) // v3.59 lock, v3.66 momentum
      {
         foreign_position=ticket;
         foreign_position_magic=PositionGetInteger(POSITION_MAGIC);
         break;
      }
   }
   for(int j=0;j<OrdersTotal();j++)
   {
      ulong ticket=OrderGetTicket(j);
      if(ticket==0 || !OrderSelect(ticket)) continue;
      if(OrderGetString(ORDER_SYMBOL)==_Symbol &&
         OrderGetInteger(ORDER_MAGIC)!=InpMagic &&
         OrderGetInteger(ORDER_MAGIC)!=InpMagic+2000000)
      {
         foreign_pending=ticket;
         foreign_pending_magic=OrderGetInteger(ORDER_MAGIC);
         break;
      }
   }
   if(foreign_position!=0 || foreign_pending!=0)
   {
      datetime now=TimeCurrent();
      if(g_clean_symbol_wait_last_log==0 || now-g_clean_symbol_wait_last_log>=30)
      {
         g_clean_symbol_wait_last_log=now;
         PrintFormat("HBv3.30 WAIT CLEAN SYMBOL | attached but trading paused on %s; foreignPosition=%I64u magic=%I64d foreignPending=%I64u magic=%I64d; review old EA orders manually, no auto cancellation or closing",
                     _Symbol,foreign_position,foreign_position_magic,
                     foreign_pending,foreign_pending_magic);
      }
      return true;
   }
   if(g_clean_symbol_wait_last_log!=0)
   {
      g_clean_symbol_wait_last_log=0;
      Print("HBv3.30 CLEAN SYMBOL VERIFIED | old-Magic exposure cleared; normal 20+20 rules may resume");
   }
   return false;
}

// --- v3.19: Account-wide takeover for old Gold Hedge Basket Magic numbers. ---
// IMPORTANT: The old EA process cannot be shut down via MT5 trading API.
// Stop/remove earlier versions on the terminal AND synchronize the MT5 VPS.
// This manager acts only on the CURRENT SYMBOL and VERIFIED old GHB roles.
// Other EAs and manual orders (magic=0) are NOT silently canceled.
// Existing open legacy positions are NEVER closed and their SL is preserved.
bool IsHistoricBasketMagic(const long magic)
{
   return (magic>0 && magic!=InpMagic &&
           magic>=InpTakeoverOldMagicMin && magic<=InpTakeoverOldMagicMax);
}

int LegacyBasketLevelFromComment(const string comment,const bool buy)
{
   for(int i=0;i<LIMIT_PER_SIDE;i++)
      if(comment==StringFormat("HB L%s%d",buy?"B":"S",i+1)) return i;
   return -1;
}

bool ClassifyHistoricBasketRole(const string comment,const bool buy,double &money)
{
   money=0.0;
   int rung=LegacyBasketLevelFromComment(comment,buy);
   if(rung>=0) { money=LimitTargetForSlot(rung); return true; }
   if(comment==(buy?"HB START BUY":"HB START SELL"))
      {money=InpSeedTakeProfitMoney;return true;}
   if((buy && (comment=="HB THIRD BUY" || comment=="HB FOURTH BUY")) ||
      (!buy && (comment=="HB THIRD SELL" || comment=="HB FOURTH SELL")))
      {money=InpTrendTakeProfitMoney;return true;}
   if((buy && (comment=="HB REPEAT BUY 30" || comment=="HB REPEAT BUY 50" || comment=="HB REPEAT BUY 80")) ||
      (!buy && (comment=="HB REPEAT SELL 30" || comment=="HB REPEAT SELL 50" || comment=="HB REPEAT SELL 80")))
      {money=InpRepeatTakeProfitMoney;return true;}
   if(comment==(buy?"HB COUNTER BUY TP NO SL":"HB COUNTER SELL TP NO SL"))
      {money=InpCounterTakeProfitMoney;return true;}
   if(comment==(buy?"HB FOLLOW BUY TP":"HB FOLLOW SELL TP"))
      {money=InpFollowTakeProfitMoney;return true;}
   return false;
}

// Verified pending comments: only old grid and original-repeat BUY/SELL LIMIT.
bool IsVerifiedHistoricPending(const ulong ticket)
{
   if(ticket==0 || !OrderSelect(ticket) ||
      OrderGetString(ORDER_SYMBOL)!=_Symbol ||
      !IsHistoricBasketMagic(OrderGetInteger(ORDER_MAGIC))) return false;
   ENUM_ORDER_TYPE typ=(ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
   if(typ!=ORDER_TYPE_BUY_LIMIT && typ!=ORDER_TYPE_SELL_LIMIT) return false;
   bool buy=(typ==ORDER_TYPE_BUY_LIMIT);
   string comment=OrderGetString(ORDER_COMMENT);
   if(LegacyBasketLevelFromComment(comment,buy)>=0) return true;
   if(buy && (comment=="HB REPEAT BUY 30" || comment=="HB REPEAT BUY 50" || comment=="HB REPEAT BUY 80")) return true;
   if(!buy && (comment=="HB REPEAT SELL 30" || comment=="HB REPEAT SELL 50" || comment=="HB REPEAT SELL 80")) return true;
   return false;
}

bool RunHistoricBasketTakeover()
{
   if(!InpTakeoverCancelLegacyPendings && !InpTakeoverUpdateLegacyLiveTP)
      return !(InpTakeoverBlockOnForeignPendings && HasOtherPendingOrdersOnSymbol());
   datetime now=TimeCurrent();
   // Up to 4 broker changes every 3 seconds, even during many OnTick calls.
   if(g_last_legacy_takeover_scan>0 && now-g_last_legacy_takeover_scan<3)
      return !(InpTakeoverBlockOnForeignPendings && HasOtherPendingOrdersOnSymbol());
   g_last_legacy_takeover_scan=now;
   const bool can=CanTradeNow();
   int removed=0,updated=0,oldRemaining=0,otherRemaining=0,unclassifiedPositions=0;
   int limit=InpTakeoverActionsPerPass;

   if(InpTakeoverCancelLegacyPendings)
   {
      // Iterate backwards: trade.OrderDelete() changes OrdersTotal().
      for(int i=OrdersTotal()-1;i>=0;i--)
      {
         ulong ticket=OrderGetTicket(i);
         if(ticket==0 || !OrderSelect(ticket) || OrderGetString(ORDER_SYMBOL)!=_Symbol ||
            OrderGetInteger(ORDER_MAGIC)==InpMagic) continue;
         long mag=OrderGetInteger(ORDER_MAGIC);
         if(!IsVerifiedHistoricPending(ticket))
         {
            if(now-g_last_legacy_takeover_log>=30)
               PrintFormat("HBv3.30 TAKEOVER UNTOUCHED FOREIGN PENDING | ticket=%I64u magic=%I64d comment=%s; manual/unknown orders never canceled",
                           ticket,mag,OrderGetString(ORDER_COMMENT));
            continue;
         }
         if(!can || removed>=limit) continue;
         string comment=OrderGetString(ORDER_COMMENT);
         // Deleting requires BROKER ACK; any failed/unacknowledged order remains blocking.
         bool submitted=trade.OrderDelete(ticket);
         uint result=trade.ResultRetcode();
         if(submitted && result==TRADE_RETCODE_DONE && !OrderSelect(ticket))
         {
            removed++;
            PrintFormat("HBv3.30 TAKEOVER OLD PENDING DELETED | ticket=%I64u oldMagic=%I64d comment=%s",ticket,mag,comment);
         }
         else
            PrintFormat("HBv3.30 TAKEOVER OLD PENDING RETRY | ticket=%I64u code=%u %s",ticket,result,trade.ResultRetcodeDescription());
      }
   }

   if(InpTakeoverUpdateLegacyLiveTP && can)
   {
      MqlTick q;
      if(SymbolInfoTick(_Symbol,q) && q.bid>0 && q.ask>q.bid)
      {
         double step=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
         if(step<=0) step=_Point;
         double minGap=(double)MathMax((int)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL),
                  (int)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_FREEZE_LEVEL))*_Point+2*step;
         for(int i=PositionsTotal()-1;i>=0;i--)
         {
            ulong ticket=PositionGetTicket(i);
            if(ticket==0 || !PositionSelectByTicket(ticket) ||
               PositionGetString(POSITION_SYMBOL)!=_Symbol ||
               !IsHistoricBasketMagic(PositionGetInteger(POSITION_MAGIC))) continue;
            ENUM_POSITION_TYPE pt=(ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
            if(pt!=POSITION_TYPE_BUY && pt!=POSITION_TYPE_SELL) continue;
            bool buy=(pt==POSITION_TYPE_BUY);
            string comment=PositionGetString(POSITION_COMMENT);
            double cash=0;
            if(!ClassifyHistoricBasketRole(comment,buy,cash))
            {
               unclassifiedPositions++;
               if(now-g_last_legacy_takeover_log>=30)
                  PrintFormat("HBv3.30 TAKEOVER TP SKIP UNKNOWN ROLE | ticket=%I64u magic=%I64d comment=%s",
                              ticket,PositionGetInteger(POSITION_MAGIC),comment);
               continue;
            }
            double oldSL=PositionGetDouble(POSITION_SL);
            double oldTP=PositionGetDouble(POSITION_TP);
            double entry=PositionGetDouble(POSITION_PRICE_OPEN);
            double lots=PositionGetDouble(POSITION_VOLUME);
            double tp=0;
            if(!PendingLimitTPForAccountProfit(buy?ORDER_TYPE_BUY:ORDER_TYPE_SELL,entry,lots,cash,tp)) continue;
            if(oldTP>0 && MathAbs(oldTP-tp)<step*0.5) continue;
            // Do NOT turn a historical profit target that price passed into a market exit.
            if((buy && tp<=q.bid+minGap) || (!buy && tp>=q.ask-minGap))
            {
               if(now-g_last_legacy_takeover_log>=30)
                  PrintFormat("HBv3.30 TAKEOVER TP WAIT MARKET | ticket=%I64u target=%.2f %s desired=%.3f; old TP preserved",
                              ticket,cash,AccountInfoString(ACCOUNT_CURRENCY),tp);
               continue;
            }
            if(updated>=limit) continue;
            // Keep existing SL exactly (including zero); only change TP.
            bool sent=trade.PositionModify(ticket,oldSL,tp);
            uint ret=trade.ResultRetcode();
            if(sent && (ret==TRADE_RETCODE_DONE || ret==TRADE_RETCODE_NO_CHANGES) &&
               PositionSelectByTicket(ticket) && MathAbs(PositionGetDouble(POSITION_TP)-tp)<step*0.5)
            {
               updated++;
               PrintFormat("HBv3.30 TAKEOVER LEGACY TP UPDATED | ticket=%I64u old=%.3f new=%.3f target=%.2f %s SL_unchanged=%.3f role=%s",
                           ticket,oldTP,tp,cash,AccountInfoString(ACCOUNT_CURRENCY),oldSL,comment);
            }
            else
               PrintFormat("HBv3.30 TAKEOVER TP MODIFY REJECT | ticket=%I64u code=%u %s",ticket,ret,trade.ResultRetcodeDescription());
         }
      }
   }

   // Mandatory post-trade broker scan: never trust the local ticket ledger for foreign Magic.
   for(int i=0;i<OrdersTotal();i++)
   {
      ulong ticket=OrderGetTicket(i);
      if(ticket==0 || !OrderSelect(ticket) || OrderGetString(ORDER_SYMBOL)!=_Symbol ||
         OrderGetInteger(ORDER_MAGIC)==InpMagic) continue;
      if(IsVerifiedHistoricPending(ticket)) oldRemaining++;
      else otherRemaining++;
   }
   if((oldRemaining>0 || otherRemaining>0 || unclassifiedPositions>0) &&
      now-g_last_legacy_takeover_log>=30)
   {
      g_last_legacy_takeover_log=now;
      PrintFormat("HBv3.30 TAKEOVER STATUS | oldPending=%d otherPending=%d unclassifiedOldPositions=%d deletedThisPass=%d TPchangedThisPass=%d | blockNew=%s",
                  oldRemaining,otherRemaining,unclassifiedPositions,removed,updated,
                  (oldRemaining>0 || (otherRemaining>0 && InpTakeoverBlockOnForeignPendings))?"YES":"NO");
   }
   // When a known old EA is still creating broker orders, block new EA entries.
   if(oldRemaining>0) return false;
   if(InpTakeoverBlockOnForeignPendings && otherRemaining>0) return false;
   return true;
}

// Only report foreign exposure; this routine never selects/manages/changes its tickets.
void ReportParallelMagicExposure()
{
   if(!InpAllowParallelMagic) return;
   datetime now=TimeCurrent();
   if(g_last_parallel_warning!=0 && now-g_last_parallel_warning<60) return;
   int positions=0,pendings=0;
   double positionLots=0.0,pendingLots=0.0;
   for(int i=0;i<PositionsTotal();i++)
   {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol ||
         PositionGetInteger(POSITION_MAGIC)==InpMagic) continue;
      positions++;
      positionLots+=PositionGetDouble(POSITION_VOLUME);
   }
   for(int i=0;i<OrdersTotal();i++)
   {
      ulong ticket=OrderGetTicket(i);
      if(ticket==0 || !OrderSelect(ticket)) continue;
      if(OrderGetString(ORDER_SYMBOL)!=_Symbol ||
         OrderGetInteger(ORDER_MAGIC)==InpMagic) continue;
      pendings++;
      pendingLots+=OrderGetDouble(ORDER_VOLUME_CURRENT);
   }
   if(positions==0 && pendings==0) return;
   g_last_parallel_warning=now;
   PrintFormat("HBv3.30 PARALLEL EXPOSURE WARNING | otherMagic positions=%d lots=%.2f pendings=%d lots=%.2f | verified old GHB pending orders will be canceled and TPs migrated; unrelated orders remain unmanaged; margin risk remains",
               positions,positionLots,pendings,pendingLots);
}

// OrderCalcMargin estimates a standalone order, not the exact additional hedged margin.
// Deliberately conservative: seed checks two standalone legs.
bool MarginOK(const ENUM_ORDER_TYPE direction,const double count,const double specified_volume=0.0)
{
   double marginUsed=AccountInfoDouble(ACCOUNT_MARGIN);
   double level=AccountInfoDouble(ACCOUNT_MARGIN_LEVEL);
   double free=AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   double volume=(specified_volume>0.0?specified_volume:InpFixedLot);
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol,tick) || tick.ask<=0 || tick.bid<=0) return false;
   double estimated=0.0;
   ResetLastError();
   bool calculated=OrderCalcMargin(direction,_Symbol,volume,
                                   direction==ORDER_TYPE_BUY?tick.ask:tick.bid,estimated);
   int error=GetLastError();
   double required=estimated*count*InpMinFreeMarginFactor;
   // v3.58: judge the account level AFTER this order, so a small new order is
   // not blocked just because other EAs already use some margin.
   double equityNow=AccountInfoDouble(ACCOUNT_EQUITY);
   double usedAfter=marginUsed+estimated*count;
   double levelAfter=(usedAfter>0.0 ? equityNow/usedAfter*100.0 : 1e9);
   bool levelOK=(levelAfter>=InpNoNewOrderBelowMarginLevel);
   level=levelAfter; // logged as projected level
   bool ok=calculated && estimated>0 && levelOK && free>=required;
   if(!ok)
   {
      static datetime lastLog=0;
      datetime now=TimeCurrent();
      if(now-lastLog>=15)
      {
         lastLog=now;
         PrintFormat("HBv3.47 MARGIN DETAIL | side=%s lot=%.2f free=%.2f standalone=%.2f count=%.1f factor=%.2f required=%.2f level=%.1f minLevel=%.1f calcOK=%d error=%d currency=%s",
                     direction==ORDER_TYPE_BUY?"BUY":"SELL",volume,free,estimated,count,InpMinFreeMarginFactor,required,
                     level,InpNoNewOrderBelowMarginLevel,(int)calculated,error,AccountInfoString(ACCOUNT_CURRENCY));
      }
   }
   return ok;
}





bool Filled(bool submitted)
{
   // Partial fills remain pending reconciliation; never close the other seed.
   return submitted && trade.ResultRetcode()==TRADE_RETCODE_DONE;
}

void LogTradeError(const string tag)
{
   PrintFormat("HEDGE BASKET %s failed retcode=%u details=%s",
               tag, trade.ResultRetcode(), trade.ResultRetcodeDescription());
}

// Initial BUY and SELL each get an independent 50-USC broker TP.
// All later re-entries, THIRD and FOURTH get independent 50-USC broker TP.
bool OpenOriginalHedge(const ENUM_ORDER_TYPE side,const string comment)
{
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol,tick) || tick.bid<=0 || tick.ask<=0) return false;
   const bool buy=(side==ORDER_TYPE_BUY);
   const double estimated=(buy ? tick.ask : tick.bid);
   double tp=0.0;
   if(!PendingLimitTPForAccountProfit(side,estimated,InpSeedLot,InpSeedTakeProfitMoney,tp))
   {
      PrintFormat("HBv3.30 SEED TP BLOCKED | %s cannot calculate TP for %.2f %s",
                  buy?"BUY":"SELL",InpSeedTakeProfitMoney,AccountInfoString(ACCOUNT_CURRENCY));
      return false; // Never silently open an original without requested TP.
   }
   string requestKey=g_start_key+(buy?".seedBuyRequest":".seedSellRequest");
   GlobalVariableSet(requestKey,(double)g_basket_start);
   GlobalVariablesFlush();
   const bool sent=(buy ? trade.Buy(InpSeedLot,_Symbol,0.0,0.0,tp,comment) :
                          trade.Sell(InpSeedLot,_Symbol,0.0,0.0,tp,comment));
   uint code=trade.ResultRetcode();
   // Only definitive rejection releases the request. TIMEOUT/CONNECTION,
   // PLACED and partial fills require broker reconciliation, never a blind retry.
   if(code==TRADE_RETCODE_REJECT || code==TRADE_RETCODE_REQUOTE ||
      code==TRADE_RETCODE_INVALID || code==TRADE_RETCODE_INVALID_VOLUME ||
      code==TRADE_RETCODE_INVALID_PRICE || code==TRADE_RETCODE_INVALID_STOPS ||
      code==TRADE_RETCODE_TRADE_DISABLED || code==TRADE_RETCODE_MARKET_CLOSED ||
      code==TRADE_RETCODE_NO_MONEY || code==TRADE_RETCODE_PRICE_CHANGED ||
      code==TRADE_RETCODE_PRICE_OFF || code==TRADE_RETCODE_TOO_MANY_REQUESTS ||
      code==TRADE_RETCODE_INVALID_FILL || code==TRADE_RETCODE_SERVER_DISABLES_AT ||
      code==TRADE_RETCODE_CLIENT_DISABLES_AT)
      GlobalVariableDel(requestKey);
   if(!Filled(sent)) {LogTradeError(comment);return false;}
   PrintFormat("HBv3.30 SEED %s OPEN | volume=%.2f brokerTP=%.3f targetGross=%.2f %s (other seed is independent)",
               buy?"BUY":"SELL",InpSeedLot,tp,InpSeedTakeProfitMoney,AccountInfoString(ACCOUNT_CURRENCY));
   return true;
}

// A saved .set can carry InpPreserveExistingLiveTP=YES from old versions.
// In individual-TP mode we explicitly enforce the configured target for
// VERIFIED current-MAGIC tracked positions. No other-MAGIC/manual TP is touched.
bool NeedOwnedBrokerTPCorrection(const double existing,const double expected,const double step)
{
   if(expected<=0.0) return false;
   if(existing<=0.0) return true;
   if(MathAbs(existing-expected)<step*0.5) return false;
   return (InpEnforceConfiguredTP || !InpPreserveExistingLiveTP);
}

// Broker entry price can differ slightly from quoted price. Update only the
// corresponding original position by TICKET, preserving its zero SL.
void ReconcileOriginalTakeProfit(const ulong id,const ENUM_ORDER_TYPE side)
{
   if(id==0 || !CanTradeNow()) return;
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong ticket=PositionGetTicket(i);
      if(!IsOwnPosition(ticket) || (ulong)PositionGetInteger(POSITION_IDENTIFIER)!=id) continue;
      if((side==ORDER_TYPE_BUY && PositionGetInteger(POSITION_TYPE)!=POSITION_TYPE_BUY) ||
         (side==ORDER_TYPE_SELL && PositionGetInteger(POSITION_TYPE)!=POSITION_TYPE_SELL)) return;
      const double open_price=PositionGetDouble(POSITION_PRICE_OPEN);
      const double vol=PositionGetDouble(POSITION_VOLUME);
      // This function also checks post-TP repeated positions. NEVER give a repeat
      // the original's 80 USC target: original IDs alone are entitled to TP80.
      const double target=((id==g_seed_buy_id || id==g_seed_sell_id) ?
                           InpSeedTakeProfitMoney : InpRepeatTakeProfitMoney);
      double desired=0.0;
      if(!PendingLimitTPForAccountProfit(side,open_price,vol,target,desired)) return;
      double ticksize=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
      if(ticksize<=0) ticksize=_Point;
      double current=PositionGetDouble(POSITION_TP);
      double oldSL=PositionGetDouble(POSITION_SL);
      if(!NeedOwnedBrokerTPCorrection(current,desired,ticksize)) return;
      MqlTick tick;
      if(!SymbolInfoTick(_Symbol,tick)) return;
      // Do not submit invalid TP modifications once market passed the level.
      double min_gap=(double)MathMax((int)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL),
                                     (int)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_FREEZE_LEVEL))*_Point+2*ticksize;
      if((side==ORDER_TYPE_BUY && desired<=tick.bid+min_gap) ||
         (side==ORDER_TYPE_SELL && desired>=tick.ask-min_gap)) return;
      bool sent=trade.PositionModify(ticket,oldSL,desired);
      if(sent && (trade.ResultRetcode()==TRADE_RETCODE_DONE || trade.ResultRetcode()==TRADE_RETCODE_NO_CHANGES) &&
         PositionSelectByTicket(ticket) &&
         MathAbs(PositionGetDouble(POSITION_TP)-desired)<ticksize*0.5 &&
         MathAbs(PositionGetDouble(POSITION_SL)-oldSL)<ticksize*0.5)
         PrintFormat("HBv3.30 SEED TP RECONCILED | ticket=%I64u TP=%.3f %s",
                     ticket,desired,AccountInfoString(ACCOUNT_CURRENCY));
      else
      {
         static datetime last_warn=0;
         if(TimeCurrent()-last_warn>=20)
         {
            last_warn=TimeCurrent();
            PrintFormat("HBv3.30 SEED TP RECONCILE FAILED | ticket=%I64u ret=%u %s; priorTP=%.3f",
                        ticket,trade.ResultRetcode(),trade.ResultRetcodeDescription(),current);
         }
      }
      return;
   }
}

// Add TP at broker with the market entry, not later: preserves independent
// exits even if EA is temporarily disconnected. No individual stop loss.
bool OpenTrendGridPosition(const ENUM_ORDER_TYPE side,const string comment)
{
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol,tick) || tick.bid<=0 || tick.ask<=0) return false;
   const bool buy=(side==ORDER_TYPE_BUY);
   const double estimated=(buy ? tick.ask : tick.bid);
   double tp=0.0;
   if(!PendingLimitTPForAccountProfit(side,estimated,InpFixedLot,InpTrendTakeProfitMoney,tp))
   {
      PrintFormat("HBv3.30 TREND TP BLOCKED | %s could not calculate %.2f %s",
                  comment,InpTrendTakeProfitMoney,AccountInfoString(ACCOUNT_CURRENCY));
      return false; // Never open a third/fourth position with missing requested TP.
   }
   const bool submitted=(buy ? trade.Buy(InpFixedLot,_Symbol,0.0,0.0,tp,comment) :
                               trade.Sell(InpFixedLot,_Symbol,0.0,0.0,tp,comment));
   if(!Filled(submitted)) {LogTradeError(comment);return false;}
   PrintFormat("HBv3.30 TREND ENTRY | %s lot=%.2f independentTP=%.3f grossTarget=%.2f %s",
               comment,InpFixedLot,tp,InpTrendTakeProfitMoney,AccountInfoString(ACCOUNT_CURRENCY));
   return true;
}

bool OpenBuy(const string comment) {return OpenTrendGridPosition(ORDER_TYPE_BUY,comment);}
bool OpenSell(const string comment) {return OpenTrendGridPosition(ORDER_TYPE_SELL,comment);}

// Reconcile the TP using the ACTUAL filled opening price and the position's ID.
// Never modify another leg's SL or TP, and never force-close the basket.
void ReconcileTrendTakeProfit(const ulong position_id,const ENUM_ORDER_TYPE side)
{
   if(position_id==0 || !CanTradeNow()) return;
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong ticket=PositionGetTicket(i);
      if(!IsOwnPosition(ticket) || (ulong)PositionGetInteger(POSITION_IDENTIFIER)!=position_id) continue;
      if((side==ORDER_TYPE_BUY && PositionGetInteger(POSITION_TYPE)!=POSITION_TYPE_BUY) ||
         (side==ORDER_TYPE_SELL && PositionGetInteger(POSITION_TYPE)!=POSITION_TYPE_SELL)) return;
      double entry=PositionGetDouble(POSITION_PRICE_OPEN);
      double volume=PositionGetDouble(POSITION_VOLUME);
      double desired=0.0;
      if(!PendingLimitTPForAccountProfit(side,entry,volume,InpTrendTakeProfitMoney,desired)) return;
      double ticksize=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
      if(ticksize<=0) ticksize=_Point;
      double current=PositionGetDouble(POSITION_TP);
      double oldSL=PositionGetDouble(POSITION_SL);
      if(!NeedOwnedBrokerTPCorrection(current,desired,ticksize)) return;
      MqlTick tick;
      if(!SymbolInfoTick(_Symbol,tick)) return;
      double minGap=(double)MathMax((int)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL),
                                    (int)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_FREEZE_LEVEL))*_Point+2*ticksize;
      if((side==ORDER_TYPE_BUY && desired<=tick.bid+minGap) ||
         (side==ORDER_TYPE_SELL && desired>=tick.ask-minGap)) return;
      bool submitted=trade.PositionModify(ticket,oldSL,desired);
      if(submitted && (trade.ResultRetcode()==TRADE_RETCODE_DONE || trade.ResultRetcode()==TRADE_RETCODE_NO_CHANGES) &&
         PositionSelectByTicket(ticket) &&
         MathAbs(PositionGetDouble(POSITION_TP)-desired)<ticksize*0.5 &&
         MathAbs(PositionGetDouble(POSITION_SL)-oldSL)<ticksize*0.5)
         PrintFormat("HBv3.30 TREND TP RECONCILED | ticket=%I64u actualEntry=%.3f TP=%.3f",
                     ticket,entry,desired);
      else
      {
         static datetime lastWarn=0;
         if(TimeCurrent()-lastWarn>=20)
         {
            lastWarn=TimeCurrent();
            PrintFormat("HBv3.30 TREND TP MODIFY FAILED | ticket=%I64u ret=%u %s priorTP=%.3f",
                        ticket,trade.ResultRetcode(),trade.ResultRetcodeDescription(),current);
         }
      }
      return;
   }
}


// MQL5 broker-side pending order helpers.
// The ticket (not an on-chart line) is the authoritative order identity.
int OwnedLimitPendingCount()
{
   int count=0;
   for(int k=0;k<LIMIT_SLOTS;k++)
   {
      ulong id=g_limit_order[k];
      if(id!=0 && OrderSelect(id) && OrderGetString(ORDER_SYMBOL)==_Symbol &&
         OrderGetInteger(ORDER_MAGIC)==InpMagic) count++;
   }
   return count;
}

int OwnedPendingCount()
{
   int count=0;
   for(int i=0;i<OrdersTotal();i++)
   {
      ulong id=OrderGetTicket(i);
      if(id==0 || !OrderSelect(id)) continue;
      if(OrderGetString(ORDER_SYMBOL)==_Symbol && OrderGetInteger(ORDER_MAGIC)==InpMagic)
         count++;
   }
   return count;
}

void CancelOwnPendingOrders()
{
   for(int i=OrdersTotal()-1;i>=0;i--)
   {
      ulong id=OrderGetTicket(i);
      if(id==0 || !OrderSelect(id)) continue;
      if(OrderGetString(ORDER_SYMBOL)!=_Symbol || OrderGetInteger(ORDER_MAGIC)!=InpMagic) continue;
      if(!CanTradeNow())
      {
         PrintFormat("HBv3.30 PENDING DELETE WAIT | ticket=%I64u trading is disabled",id);
         continue;
      }
      bool ok=trade.OrderDelete(id);
      if(!ok || trade.ResultRetcode()!=TRADE_RETCODE_DONE)
         PrintFormat("HBv3.30 PENDING DELETE FAILED | ticket=%I64u retcode=%u %s",
                     id,trade.ResultRetcode(),trade.ResultRetcodeDescription());
      else
         PrintFormat("HBv3.30 PENDING CANCELED | ticket=%I64u",id);
   }
}

// Returns a confirmed TP close of a full position (not manual close, not SL).
// Close price is fallback only: normal re-entry reference is the saved broker TP.
bool RepeatClosedAtProfitableTP(const ulong id,double &exit_price)
{
   exit_price=0.0;
   if(id==0 || IsPositionIdOpen(id) || g_basket_start<=0) return false;
   if(!GHBHistorySelect(g_basket_start-60,TimeCurrent()+60)) return false;
   bool entered=false, exited=false;
   ulong lastDeal=0;
   long lastMsc=-1;
   double net=0.0;
   for(int i=0;i<HistoryDealsTotal();i++)
   {
      ulong d=HistoryDealGetTicket(i);
      if(d==0 || (ulong)HistoryDealGetInteger(d,DEAL_POSITION_ID)!=id ||
         HistoryDealGetString(d,DEAL_SYMBOL)!=_Symbol) continue;
      ENUM_DEAL_ENTRY e=(ENUM_DEAL_ENTRY)HistoryDealGetInteger(d,DEAL_ENTRY);
      if(e==DEAL_ENTRY_IN || e==DEAL_ENTRY_INOUT) entered=true;
      if(e==DEAL_ENTRY_OUT || e==DEAL_ENTRY_OUT_BY || e==DEAL_ENTRY_INOUT)
      {
         exited=true;
         long msc=(long)HistoryDealGetInteger(d,DEAL_TIME_MSC);
         if(msc>=lastMsc) {lastMsc=msc;lastDeal=d;}
      }
      net+=HistoryDealGetDouble(d,DEAL_PROFIT)+HistoryDealGetDouble(d,DEAL_SWAP)+
           HistoryDealGetDouble(d,DEAL_COMMISSION)+HistoryDealGetDouble(d,DEAL_FEE);
   }
   if(!entered || !exited || lastDeal==0 || net<=0.0 ||
      HistoryDealGetInteger(lastDeal,DEAL_REASON)!=DEAL_REASON_TP) return false;
   exit_price=HistoryDealGetDouble(lastDeal,DEAL_PRICE);
   return exit_price>0.0;
}

void RefreshRepeatTPFromLive(const int side)
{
   ulong id=g_repeat_position[side];
   if(id==0) return;
   for(int i=0;i<PositionsTotal();i++)
   {
      ulong ticket=PositionGetTicket(i);
      if(!IsOwnPosition(ticket) ||
         (ulong)PositionGetInteger(POSITION_IDENTIFIER)!=id) continue;
      double tp=PositionGetDouble(POSITION_TP);
      if(tp>0 && MathAbs(tp-g_repeat_last_tp[side])>_Point*0.1)
      {
         g_repeat_last_tp[side]=tp;
         GlobalVariableSet(g_repeat_tp_key[side],tp);
      }
      return;
   }
}

// The pending is owned by the BROKER, not by a local OnTick order counter.
// Recover a fill from history even if VPS was restarted between execution events.
void ReconcileRepeatFill(const int side)
{
   ulong order=g_repeat_order[side];
   if(order==0) return;
   if(OrderSelect(order)) return; // still pending
   if(!GHBHistorySelect(g_basket_start-60,TimeCurrent()+60)) return;
   ulong newId=0;
   for(int k=0;k<HistoryDealsTotal();k++)
   {
      ulong deal=HistoryDealGetTicket(k);
      if(deal==0 || (ulong)HistoryDealGetInteger(deal,DEAL_ORDER)!=order ||
         HistoryDealGetString(deal,DEAL_SYMBOL)!=_Symbol) continue;
      ENUM_DEAL_ENTRY e=(ENUM_DEAL_ENTRY)HistoryDealGetInteger(deal,DEAL_ENTRY);
      if(e!=DEAL_ENTRY_IN && e!=DEAL_ENTRY_INOUT) continue;
      newId=(ulong)HistoryDealGetInteger(deal,DEAL_POSITION_ID);
      if(newId>0) break;
   }
   if(newId>0)
   {
      g_repeat_position[side]=newId;
      g_repeat_order[side]=0;
      GlobalVariableSet(g_repeat_pos_key[side],(double)newId);
      GlobalVariableSet(g_repeat_order_key[side],0.0);
      PrintFormat("HBv3.30 REPEAT FILLED | %s order=%I64u newId=%I64u target=%.2f %s",
                  side==0?"BUY":"SELL",order,newId,InpRepeatTakeProfitMoney,
                  AccountInfoString(ACCOUNT_CURRENCY));
      return;
   }
   // Deliberately do NOT replace a canceled/expired order without explicit
   // TP: user cancellation must not cause unexpected re-entry.
   static datetime warn[2];
   if(TimeCurrent()-warn[side]>=30)
   {
      warn[side]=TimeCurrent();
      PrintFormat("HBv3.30 REPEAT ORDER MISSING (no fill) | %s order=%I64u; no duplicate sent",
                  side==0?"BUY":"SELL",order);
   }
}

bool ArmRepeatPending(const int side,const double closed_at)
{
   ulong lastId=g_repeat_position[side];
   if(lastId==0 || g_repeat_order[side]!=0 ||
      g_repeat_armed_for[side]==lastId || !CanTradeNow()) return false;
   MqlTick q;
   if(!SymbolInfoTick(_Symbol,q) || q.ask<=0 || q.bid<=0) return false;
   ENUM_ORDER_TYPE direction=(side==0 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL);
   double step=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   if(step<=0) step=_Point;
   // TP of the closed original/replacement; execution-price fallback if needed.
   double ref=(g_repeat_last_tp[side]>0 ? g_repeat_last_tp[side] : closed_at);
   double raw=(side==0 ? ref-InpRepeatDistancePrice : ref+InpRepeatDistancePrice);
   double price=(side==0 ? MathFloor(raw/step+1e-8)*step : MathCeil(raw/step-1e-8)*step);
   price=NormalizeDouble(price,(int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS));
   double minD=(double)MathMax((int)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL),
                               (int)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_FREEZE_LEVEL))*_Point+2*step;
   if(price<=0 || (side==0 && price>=q.ask-minD) ||
      (side==1 && price<=q.bid+minD))
   {
      PrintFormat("HBv3.30 REPEAT WAIT PRICE | %s TP=%.3f wanted=%.3f market=%.3f; not marketable LIMIT",
                  side==0?"BUY":"SELL",ref,price,side==0?q.ask:q.bid);
      return false;
   }
   double tp=0.0;
   if(!PendingLimitTPForAccountProfit(direction,price,InpFixedLot,
                                     InpRepeatTakeProfitMoney,tp) ||
      !MarginOK(direction,1.0,InpFixedLot))
   {
      PrintFormat("HBv3.30 REPEAT WAIT TARGET/MARGIN | side=%s entry=%.3f",
                  side==0?"BUY":"SELL",price);
      return false;
   }
   bool sent=(side==0 ? trade.BuyLimit(InpFixedLot,price,_Symbol,0.0,tp,ORDER_TIME_GTC,0,
                                       "HB REPEAT BUY 50") :
                        trade.SellLimit(InpFixedLot,price,_Symbol,0.0,tp,ORDER_TIME_GTC,0,
                                        "HB REPEAT SELL 50"));
   ulong order=trade.ResultOrder();
   uint ret=trade.ResultRetcode();
   if(!sent || order==0 || (ret!=TRADE_RETCODE_PLACED && ret!=TRADE_RETCODE_DONE))
   {
      PrintFormat("HBv3.30 REPEAT REJECTED | side=%s ret=%u %s",
                  side==0?"BUY":"SELL",ret,trade.ResultRetcodeDescription());
      return false;
   }
   // Persist the ticket and which TP already caused re-entry before returning.
   g_repeat_order[side]=order;
   g_repeat_armed_for[side]=lastId;
   g_repeat_last_tp[side]=tp; // planned TP for next cycle
   GlobalVariableSet(g_repeat_order_key[side],(double)order);
   GlobalVariableSet(g_repeat_armed_key[side],(double)lastId);
   GlobalVariableSet(g_repeat_tp_key[side],tp);
   PrintFormat("HBv3.30 REPEAT PLACED | %s afterTP=%.3f pending=%I64u entry=%.3f nextTP=%.3f lot=%.2f",
               side==0?"BUY":"SELL",ref,order,price,tp,InpFixedLot);
   return true;
}

void ManageRepeatSeedEntries()
{
   if(!InpRepeatOriginalOnTP || g_basket_start<=0 || g_exit_in_progress ||
      g_technical_pause) return;
   for(int side=0;side<2;side++)
   {
      ReconcileRepeatFill(side);
      if(g_repeat_order[side]!=0) continue;
      ulong id=g_repeat_position[side];
      if(id==0) continue;
      if(IsPositionIdOpen(id)) {RefreshRepeatTPFromLive(side);continue;}
      if(g_repeat_armed_for[side]==id) continue;
      double closedPrice=0.0;
      if(!RepeatClosedAtProfitableTP(id,closedPrice)) continue;
      if(g_repeat_attempt[side]!=0 &&
         TimeCurrent()-g_repeat_attempt[side]<InpRepeatRetrySeconds) continue;
      g_repeat_attempt[side]=TimeCurrent();
      ArmRepeatPending(side,closedPrice);
   }
}

bool RepeatRearmOutstanding()
{
   if(!InpRepeatOriginalOnTP || g_basket_start<=0) return false;
   for(int side=0;side<2;side++)
   {
      if(g_repeat_order[side]!=0) return true;
      ulong id=g_repeat_position[side];
      if(id==0 || g_repeat_armed_for[side]==id) continue;
      double closed=0.0;
      if(RepeatClosedAtProfitableTP(id,closed)) return true;
   }
   return false;
}

// Recover LIMIT position identifiers from broker history after a pending order
// triggers. Deals may arrive out of transaction order; checking on every tick
// and after restarts avoids false 'unknown position' basket liquidations.
void ReconcileLimitFills()
{
   if(g_basket_start<=0) return;
   if(!GHBHistorySelect(g_basket_start-60,TimeCurrent()+60)) return;
   for(int k=0;k<LIMIT_SLOTS;k++)
   {
      if(g_limit_order[k]==0 || g_limit_position[k]!=0) continue;
      for(int n=HistoryDealsTotal()-1;n>=0;n--)
      {
         ulong deal=HistoryDealGetTicket(n);
         if(deal==0 || (ulong)HistoryDealGetInteger(deal,DEAL_ORDER)!=g_limit_order[k] ||
            HistoryDealGetString(deal,DEAL_SYMBOL)!=_Symbol) continue;
         ENUM_DEAL_ENTRY entry=(ENUM_DEAL_ENTRY)HistoryDealGetInteger(deal,DEAL_ENTRY);
         if(entry!=DEAL_ENTRY_IN && entry!=DEAL_ENTRY_INOUT) continue;
         ulong id=(ulong)HistoryDealGetInteger(deal,DEAL_POSITION_ID);
         if(id==0) continue;
         g_limit_position[k]=id;
         GlobalVariableSet(g_limit_position_key[k],(double)id);
         RegisterFilledLimit(id,k);
         PrintFormat("HBv3.30 LIMIT FILLED | rung=%d %s order=%I64u pos_id=%I64u",
                     k+1,(k<LIMIT_PER_SIDE?"BUY":"SELL"),g_limit_order[k],id);
         break;
      }
   }
}

// Restore a slot from the broker's ACTIVE pending orders or its COMPLETED
// order history, even if a VPS migration missed a DEAL_ADD event. Do not use
// merely the absence of an order as proof that it filled: rejected/canceled
// orders and delayed broker history are handled separately.
void RecoverLimitSlotState()
{
   if(g_basket_start<=0 || !InpEnableBrokerLimits) return;
   datetime now=TimeCurrent();
   static datetime last_wait=0;
   for(int k=0;k<LIMIT_SLOTS;k++)
   {
      bool buy=(k<LIMIT_PER_SIDE);
      int rung=k%LIMIT_PER_SIDE+1;
      string expected=StringFormat("HB L%s%d",buy?"B":"S",rung);
      // The broker may still have the pending, but local terminal state lost
      // its ticket. Re-bind by MAGIC, exact comment and expected volume.
      if(g_limit_order[k]==0)
      {
         ulong found=0;
         for(int n=0;n<OrdersTotal();n++)
         {
            ulong t=OrderGetTicket(n);
            if(t==0 || !OrderSelect(t)) continue;
            if(OrderGetString(ORDER_SYMBOL)!=_Symbol ||
               OrderGetInteger(ORDER_MAGIC)!=InpMagic ||
               OrderGetString(ORDER_COMMENT)!=expected ||
               !LimitVolumeMatchesSlot(k,OrderGetDouble(ORDER_VOLUME_CURRENT))) continue;
            if(found!=0) {found=0; break;} // ambiguous; never guess
            found=t;
         }
         if(found!=0)
         {
            g_limit_order[k]=found;
            g_limit_position[k]=0;
            GlobalVariableSet(g_limit_order_key[k],(double)found);
            GlobalVariableSet(g_limit_position_key[k],0.0);
            PrintFormat("HBv3.30 RECOVER PENDING | %s rung=%d order=%I64u",buy?"BUY":"SELL",rung,found);
         }
         continue;
      }
      if(g_limit_position[k]!=0 || LimitOrderTicketOpen(g_limit_order[k])) continue;
      // Existing ReconcileLimitFills() searches DEAL_ORDER. An additional
      // authoritative fallback is historical ORDER_POSITION_ID.
      ulong order=g_limit_order[k];
      if(!HistoryOrderSelect(order))
      {
         if(now-last_wait>=30)
            PrintFormat("HBv3.30 REFILL WAIT HISTORY | %s rung=%d order=%I64u pending missing; broker order history not ready",
                        buy?"BUY":"SELL",rung,order);
         continue;
      }
      ENUM_ORDER_STATE state=(ENUM_ORDER_STATE)HistoryOrderGetInteger(order,ORDER_STATE);
      if(state!=ORDER_STATE_FILLED) continue; // cancelled/expired handled elsewhere
      ulong id=(ulong)HistoryOrderGetInteger(order,ORDER_POSITION_ID);
      if(id==0)
      {
         if(now-last_wait>=30)
            PrintFormat("HBv3.30 REFILL WAIT POSITION ID | %s rung=%d filledOrder=%I64u",
                        buy?"BUY":"SELL",rung,order);
         continue;
      }
      g_limit_position[k]=id;
      GlobalVariableSet(g_limit_position_key[k],(double)id);
      RegisterFilledLimit(id,k);
      PrintFormat("HBv3.30 RECOVER FILLED | %s rung=%d order=%I64u posId=%I64u",buy?"BUY":"SELL",rung,order,id);
   }
   if(now-last_wait>=30) last_wait=now;
}

// Ensure a recovered THIRD/FOURTH comment identifies one and only one LIVE
// position owned by this EA. Multiple open positions of the same core role
// mean the basket is ambiguous and require a technical pause, NOT a guess.
int CountLiveCoreRoleCandidates(const string expected_comment,
                                const long expected_side,
                                const double expected_volume)
{
   int count=0;
   double tolerance=MathMax(1e-7,SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP)*0.1);
   for(int i=0;i<PositionsTotal();i++)
   {
      ulong t=PositionGetTicket(i);
      if(!IsOwnPosition(t)) continue;
      if(PositionGetString(POSITION_COMMENT)!=expected_comment) continue;
      if(PositionGetInteger(POSITION_TYPE)!=expected_side) continue;
      if(MathAbs(PositionGetDouble(POSITION_VOLUME)-expected_volume)>tolerance) continue;
      count++;
   }
   return count;
}

// Recover live LIMIT and original re-entry positions by verified broker entry
// records, instead of trusting terminal GlobalVariables alone after a VPS
// migration. Unknown positions are NEVER guessed or adopted by volume alone.
// Only broker entry orders with our exact MAGIC, exact strategy comment,
// expected side and expected volume can be safely assigned a role.
void RecoverOpenTradeRolesFromHistory()
{
   if(g_basket_start<=0) return;
   if(!GHBHistorySelect(g_basket_start-60,TimeCurrent()+60)) return;
   for(int i=0;i<PositionsTotal();i++)
   {
      ulong ticket=PositionGetTicket(i);
      if(!IsOwnPosition(ticket)) continue;
      ulong id=(ulong)PositionGetInteger(POSITION_IDENTIFIER);
      if(id==0 || IsTrackedId(id)) continue;
      if(!IsOwnPosition(ticket)) continue;
      datetime opened=(datetime)PositionGetInteger(POSITION_TIME);
      double lots=PositionGetDouble(POSITION_VOLUME);
      long type=PositionGetInteger(POSITION_TYPE);
      string confirmed="";
      int entryMatches=0;
      for(int d=HistoryDealsTotal()-1;d>=0;d--)
      {
         ulong deal=HistoryDealGetTicket(d);
         if(deal==0 || (ulong)HistoryDealGetInteger(deal,DEAL_POSITION_ID)!=id ||
            HistoryDealGetString(deal,DEAL_SYMBOL)!=_Symbol ||
            HistoryDealGetInteger(deal,DEAL_MAGIC)!=InpMagic) continue;
         ENUM_DEAL_ENTRY how=(ENUM_DEAL_ENTRY)HistoryDealGetInteger(deal,DEAL_ENTRY);
         if(how!=DEAL_ENTRY_IN && how!=DEAL_ENTRY_INOUT) continue;
         ulong ord=(ulong)HistoryDealGetInteger(deal,DEAL_ORDER);
         string comment=HistoryDealGetString(deal,DEAL_COMMENT);
         if(ord>0 && HistoryOrderSelect(ord))
         {
            string original=HistoryOrderGetString(ord,ORDER_COMMENT);
            if(original!="") comment=original;
         }
         if(confirmed!="" && confirmed!=comment) {entryMatches=2;break;}
         confirmed=comment;
         entryMatches=1;
      }
      if(entryMatches!=1) continue;
      // Recover only a unique, broker-proven initial hedge role. No adoption
      // from lot size alone and no replacement of another still-live seed.
      bool seedBuy=(confirmed=="HB START BUY" && type==POSITION_TYPE_BUY);
      bool seedSell=(confirmed=="HB START SELL" && type==POSITION_TYPE_SELL);
      double seedTolerance=MathMax(1e-7,SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP)*0.1);
      if((seedBuy || seedSell) && opened>=g_basket_start-2 &&
         MathAbs(lots-InpSeedLot)<=seedTolerance &&
         CountLiveCoreRoleCandidates(confirmed,type,InpSeedLot)==1)
      {
         ulong oldSeed=(seedBuy?g_seed_buy_id:g_seed_sell_id);
         if(oldSeed!=0 && IsPositionIdOpen(oldSeed)) continue;
         bool verifiedSeed=BrokerVerifiedExistingVolume(id,lots,(ENUM_POSITION_TYPE)type);
         if(!GHBHistorySelect(g_basket_start-60,TimeCurrent()+60)) return;
         if(!verifiedSeed) continue;
         if(seedBuy)
         {
            g_seed_buy_id=id;
            GlobalVariableSet(g_seed_buy_key,(double)id);
         }
         else
         {
            g_seed_sell_id=id;
            GlobalVariableSet(g_seed_sell_key,(double)id);
         }
         int seedSide=seedBuy?0:1;
         if(g_repeat_position[seedSide]==0 || g_repeat_position[seedSide]==oldSeed)
         {
            g_repeat_position[seedSide]=id;
            GlobalVariableSet(g_repeat_pos_key[seedSide],(double)id);
         }
         PrintFormat("HBv3.48 RESTORED SEED | side=%s id=%I64u oldId=%I64u lot=%.2f brokerEntryVerified=YES; position unchanged",
                     seedBuy?"BUY":"SELL",id,oldSeed,lots);
         // HistorySelectByPosition narrowed the deal list; restore for remaining roles.
         if(!GHBHistorySelect(g_basket_start-60,TimeCurrent()+60)) return;
         continue;
      }
      bool found=false;
      for(int slot=0;slot<LIMIT_SLOTS;slot++)
      {
         bool buy=slot<LIMIT_PER_SIDE;
         int rung=slot%LIMIT_PER_SIDE+1;
         string expected=StringFormat("HB L%s%d",buy?"B":"S",rung);
         if(confirmed!=expected || (type==POSITION_TYPE_BUY)!=buy ||
            !LimitVolumeMatchesSlot(slot,lots))
            continue;
         RegisterFilledLimit(id,slot);
         PrintFormat("HBv3.30 RESTORED LIVE LIMIT | position=%I64u %s rung=%d",id,buy?"BUY":"SELL",rung);
         found=true;
         break;
      }
      if(found) continue;
      for(int side=0;side<2;side++)
      {
         string expected=(side==0?"HB REPEAT BUY 50":"HB REPEAT SELL 50");
         string legacy30=(side==0?"HB REPEAT BUY 30":"HB REPEAT SELL 30");
         string legacy80=(side==0?"HB REPEAT BUY 80":"HB REPEAT SELL 80");
         if((confirmed!=expected && confirmed!=legacy30 && confirmed!=legacy80) || (type==POSITION_TYPE_BUY)!=(side==0) ||
            MathAbs(lots-InpFixedLot)>MathMax(1e-7,SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP)*0.1)) continue;
         if(IsPositionIdOpen(g_repeat_position[side])) continue; // ambiguous concurrent repeat
         ulong previous=g_repeat_position[side];
         g_repeat_position[side]=id;
         g_repeat_order[side]=0;
         GlobalVariableSet(g_repeat_pos_key[side],(double)id);
         GlobalVariableSet(g_repeat_order_key[side],0.0);
         PrintFormat("HBv3.30 RESTORED LIVE REPEAT | %s oldId=%I64u newId=%I64u",side==0?"BUY":"SELL",previous,id);
         found=true;
         break;
      }
      if(found) continue;

      // BROKER-VERIFIED CORE RECOVERY: older builds sometimes sent a THIRD
      // market order successfully but restarted before persisting stage=3.
      // In that case THIRD was incorrectly reported as UNKNOWN, permanently
      // pausing ALL ten SELL (or BUY) pending replacements. Admit the role
      // only when order/deal MAGIC and exact comment have been verified above,
      // volume and direction agree and it is unique among live positions.
      double tolerance=MathMax(1e-7,SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP)*0.1);
      bool third_buy=(confirmed=="HB THIRD BUY");
      bool third_sell=(confirmed=="HB THIRD SELL");
      bool fourth_buy=(confirmed=="HB FOURTH BUY");
      bool fourth_sell=(confirmed=="HB FOURTH SELL");
      bool is_buy=(type==POSITION_TYPE_BUY);
      bool role_side_ok=((third_buy || fourth_buy) && is_buy) ||
                        ((third_sell || fourth_sell) && !is_buy);
      bool safe_entry_time=((datetime)PositionGetInteger(POSITION_TIME)>=g_basket_start-2);
      // Restore both new 2-lot and verified legacy 0.10-lot trend roles.
      // Entry comment/magic/history were checked above; never resize a live leg.
      bool trendLotOK=(MathAbs(lots-InpFixedLot)<=tolerance || MathAbs(lots-0.10)<=tolerance);
      if(role_side_ok && safe_entry_time && trendLotOK)
      {
         int candidates=CountLiveCoreRoleCandidates(confirmed,type,InpFixedLot)+
                        CountLiveCoreRoleCandidates(confirmed,type,0.10);
         if(candidates==1 && (third_buy || third_sell) &&
            g_expected_positions==2 && g_third_id==0 &&
            (g_grid_direction==0 || g_grid_direction==(third_buy ? 1 : -1)))
         {
            g_third_id=id;
            g_grid_direction=(third_buy ? 1 : -1);
            GlobalVariableSet(g_third_id_key,(double)id);
            GlobalVariableSet(g_direction_key,(double)g_grid_direction);
            SetExpectedPositions(3);
            // Do NOT synthesize a historical price high/low or countertrade
            // entry signal: recovered older THIRD is not a fresh breakout.
            // Leave previously confirmed counter-trade state intact.
            if(!g_counter_placed)
            {
               g_counter_third_time=0;
               g_counter_third_price=0.0;
               g_counter_best=0.0;
               GlobalVariableDel(g_counter_third_time_key);
               GlobalVariableDel(g_counter_third_price_key);
               GlobalVariableDel(g_counter_best_key);
            }
            PrintFormat("HBv3.30 RESTORED CORE THIRD | id=%I64u comment=%s direction=%s stage=3 historicalCounter=DISABLED",
                        id,confirmed,third_buy?"BUY":"SELL");
            found=true;
         }
         else if(candidates==1 && (fourth_buy || fourth_sell) &&
                 g_expected_positions==3 && g_third_id!=0 && g_fourth_id==0 &&
                 g_grid_direction==(fourth_buy ? 1 : -1))
         {
            g_fourth_id=id;
            GlobalVariableSet(g_fourth_id_key,(double)id);
            SetExpectedPositions(4);
            PrintFormat("HBv3.30 RESTORED CORE FOURTH | id=%I64u comment=%s stage=4",id,confirmed);
            found=true;
         }
         else if(candidates!=1)
         {
            PrintFormat("HBv3.30 CORE ROLE AMBIGUOUS | role=%s candidates=%d; no new order will be sent by this recovery",confirmed,candidates);
         }
      }
      if(found) continue;
      if(!found)
      {
         static datetime last_unknown=0;
         if(TimeCurrent()-last_unknown>=30)
         {
            last_unknown=TimeCurrent();
            PrintFormat("HBv3.30 UNKNOWN LIVE POSITION | id=%I64u lots=%.2f comment=%s | new entries remain blocked until identified",
                        id,lots,confirmed);
         }
      }
   }
}

// One-line audit for the Experts tab. Counts refer to broker ACTIVE orders,
// not filled positions. The last marker explains why restoring a slot waits.
void AuditLimitRefills()
{
   if(g_basket_start<=0 || !InpEnableBrokerLimits) return;
   static datetime prev=0;
   datetime now=TimeCurrent();
   if(prev!=0 && now-prev<20) return;
   prev=now;
   int buy=0,sell=0,occupiedBuy=0,occupiedSell=0;
   for(int k=0;k<LIMIT_SLOTS;k++)
   {
      if(LimitOrderTicketOpen(g_limit_order[k]))
      {
         if(k<LIMIT_PER_SIDE) buy++;else sell++;
      }
      if(OpenLimitPositionsAtLevel(k)>0)
      {
         if(k<LIMIT_PER_SIDE) occupiedBuy++;else occupiedSell++;
      }
   }
   string reason="READY";
   if(g_technical_pause) reason="TECHNICAL_PAUSE:"+g_technical_reason;
   else if(g_exit_in_progress) reason="EXIT_REQUESTED";
   else if(!CanTradeNow()) reason="ALGO_TRADING_DISABLED";
   else if(OpenLimitPositionCount()>=InpMaxActiveLimitPositions) reason="ACTIVE_LIMIT_CAP";
   else if(g_limit_outer_buy<=0 || g_limit_outer_sell<=0) reason="OUTER_EDGE_MISSING";
   else if(g_grid_geometry_dirty) reason="GEOMETRY_REPAIR";
   int waitingRefill=0;
   for(int k=0;k<LIMIT_SLOTS;k++)
      if(g_limit_position[k]!=0 && !LimitOrderTicketOpen(g_limit_order[k]) &&
         !IsPositionIdOpen(g_limit_position[k])) waitingRefill++;
   MqlTick sq;
   double spreadNow=(SymbolInfoTick(_Symbol,sq)?sq.ask-sq.bid:-1.0);
   int cb=0,cs=0,tb=0,ts=0;
   for(int k=0;k<LIMIT_SLOTS;k++)
   {
      if(k<LIMIT_PER_SIDE) {cb+=g_limit_refill_cycles[k];tb+=g_limit_tp_cycles[k];}
      else {cs+=g_limit_refill_cycles[k];ts+=g_limit_tp_cycles[k];}
   }
   PrintFormat("HBv3.55 BUILD | waitingRefill=%d spread=%.3f max=%.3f anchor=%.3f anchorAge=%ds",
               waitingRefill,spreadNow,InpMaxSpreadPrice,g_recenter_anchor_mid,(int)(now-g_recenter_last_time));
   PrintFormat("HBv3.40 REFILL STATUS | BUY pending=%d/40 occupied=%d SELL pending=%d/40 occupied=%d active=%d/%d mode=%s cyclesBUY=%d cyclesSELL=%d TPbuy=%d TPsell=%d refillGoalPerTier=%d equity=%.2f %s",
               buy,occupiedBuy,sell,occupiedSell,OpenLimitPositionCount(),InpMaxActiveLimitPositions,reason,
               cb,cs,tb,ts,InpMinimumRefillCycles,
               AccountInfoDouble(ACCOUNT_EQUITY),AccountInfoString(ACCOUNT_CURRENCY));
}

// Set the take profit from the PENDING ENTRY, not the current market bid/ask.
// Profit values are in the exact ACCOUNT currency displayed by MetaTrader 5.
// Uses the broker's real contract specifications via OrderCalcProfit.
bool PendingLimitTPForAccountProfit(const ENUM_ORDER_TYPE side,
                                   const double entry,const double volume,
                                   const double target_net,double &out_tp)
{
   if(entry<=0 || volume<=0 || target_net<=0) return false;
   double target=target_net+CommissionCostForVolume(volume); // v3.57 gross needed for NET target
   double ticksize=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   if(ticksize<=0) ticksize=_Point;
   double distance=ticksize,profit=0.0;
   bool bracketed=false;
   for(int k=0;k<60;k++)
   {
      double test=entry+(side==ORDER_TYPE_BUY ? distance : -distance);
      if(test<=0 || !OrderCalcProfit(side,_Symbol,volume,entry,test,profit)) return false;
      if(profit>=target) {bracketed=true;break;}
      distance*=1.7;
   }
   if(!bracketed) return false;
   double lo=0.0,hi=distance;
   for(int k=0;k<45;k++)
   {
      double mid=(lo+hi)*0.5;
      double test=entry+(side==ORDER_TYPE_BUY ? mid : -mid);
      if(test<=0 || !OrderCalcProfit(side,_Symbol,volume,entry,test,profit)) return false;
      if(profit>=target) hi=mid;
      else lo=mid;
   }
   // Pending TP minimum broker distance is relative to the pending entry.
   double mindist=(double)MathMax((int)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL),
                                   (int)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_FREEZE_LEVEL))*_Point+2.0*ticksize;
   double offset=MathMax(hi,mindist);
   double price=entry+(side==ORDER_TYPE_BUY ? offset : -offset);
   double rounded=(side==ORDER_TYPE_BUY ? MathCeil(price/ticksize-1e-8)*ticksize :
                                            MathFloor(price/ticksize+1e-8)*ticksize);
   out_tp=NormalizeDouble(rounded,(int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS));
   if(out_tp<=0 || (side==ORDER_TYPE_BUY && out_tp<=entry) ||
      (side==ORDER_TYPE_SELL && out_tp>=entry)) return false;
   double gross=0.0;
   return OrderCalcProfit(side,_Symbol,volume,entry,out_tp,gross) && gross+0.00001>=target;
}

bool LimitOrderTicketOpen(const ulong ticket)
{
   if(ticket==0 || !OrderSelect(ticket)) return false;
   return OrderGetString(ORDER_SYMBOL)==_Symbol && OrderGetInteger(ORDER_MAGIC)==InpMagic;
}

// Filled positions stay tied to their original rung. An active rung must NOT
// be refilled, even if a broker later reports a duplicate / delayed event.
// v3.22: a local ledger can lose historical IDs after a VPS switch.
// Count the broker's actual LIVE positions too.  Only exact GHB rung
// comments, the matching direction, and OUR/HISTORIC GHB magic qualify.
// An unrelated EA or a same-sized core/repeat trade cannot occupy a rung.
int OpenLimitPositionsAtLevel(const int slot)
{
   if(slot<0 || slot>=LIMIT_SLOTS) return 0;
   ulong identities[];
   ulong current=g_limit_position[slot];
   if(current!=0 && IsPositionIdOpen(current))
   {
      ArrayResize(identities,1);
      identities[0]=current;
   }
   for(int i=0;i<ArraySize(g_limit_filled_ids);i++)
   {
      if(g_limit_filled_slots[i]!=slot || !IsPositionIdOpen(g_limit_filled_ids[i])) continue;
      ulong id=g_limit_filled_ids[i];
      bool found=false;
      for(int j=0;j<ArraySize(identities);j++) if(identities[j]==id) {found=true;break;}
      if(!found) {int n=ArraySize(identities);ArrayResize(identities,n+1);identities[n]=id;}
   }
   bool buy=(slot<LIMIT_PER_SIDE);
   string comment=StringFormat("HB L%s%d",buy?"B":"S",slot%LIMIT_PER_SIDE+1);
   for(int p=0;p<PositionsTotal();p++)
   {
      ulong ticket=PositionGetTicket(p);
      if(ticket==0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      long magic=PositionGetInteger(POSITION_MAGIC);
      if(magic!=InpMagic && !IsHistoricBasketMagic(magic)) continue;
      if(PositionGetString(POSITION_COMMENT)!=comment) continue;
      ENUM_POSITION_TYPE type=(ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      if(type!=(buy?POSITION_TYPE_BUY:POSITION_TYPE_SELL)) continue;
      ulong id=(ulong)PositionGetInteger(POSITION_IDENTIFIER);
      if(id==0) continue;
      bool found=false;
      for(int j=0;j<ArraySize(identities);j++) if(identities[j]==id) {found=true;break;}
      if(!found) {int n=ArraySize(identities);ArrayResize(identities,n+1);identities[n]=id;}
   }
   return ArraySize(identities);
}

// Search the broker before every replacement; never send a second pending for
// the same level on a delayed or duplicated transaction notification.
int PendingCountAtLevel(const int slot,ulong &ticket)
{
   ticket=0;
   if(slot<0 || slot>=LIMIT_SLOTS) return 0;
   bool buy=(slot<LIMIT_PER_SIDE);
   string comment=StringFormat("HB L%s%d",buy?"B":"S",slot%LIMIT_PER_SIDE+1);
   int found=0;
   for(int i=0;i<OrdersTotal();i++)
   {
      ulong candidate=OrderGetTicket(i);
      if(candidate==0 || !OrderSelect(candidate)) continue;
      if(OrderGetString(ORDER_SYMBOL)!=_Symbol ||
         OrderGetInteger(ORDER_MAGIC)!=InpMagic ||
         (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE)!=(buy?ORDER_TYPE_BUY_LIMIT:ORDER_TYPE_SELL_LIMIT) ||
         OrderGetString(ORDER_COMMENT)!=comment) continue; // Even a stale-size pending occupies the rung.
      found++;
      ticket=candidate;
   }
   return found;
}

// Record only verified historical GHB positions, never another EA's trades.
// One GlobalVariable per historic POSITION_IDENTIFIER allows multiple older
// 0.05 trades at the same rung to survive a VPS restart without losing guard.
void RememberHistoricLiveTierPositions()
{
   if(g_legacy_tier_hold_prefix=="") return;
   for(int i=0;i<PositionsTotal();i++)
   {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0 || !PositionSelectByTicket(ticket) ||
         PositionGetString(POSITION_SYMBOL)!=_Symbol ||
         !IsHistoricBasketMagic(PositionGetInteger(POSITION_MAGIC))) continue;
      bool buy=(PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY);
      ENUM_POSITION_TYPE type=(ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      if(type!=POSITION_TYPE_BUY && type!=POSITION_TYPE_SELL) continue;
      int rung=LegacyBasketLevelFromComment(PositionGetString(POSITION_COMMENT),buy);
      if(rung<0) continue;
      int slot=(buy?0:LIMIT_PER_SIDE)+rung;
      ulong id=(ulong)PositionGetInteger(POSITION_IDENTIFIER);
      if(id==0) continue;
      string name=g_legacy_tier_hold_prefix+IntegerToString((long)id);
      if(GlobalVariableCheck(name)) continue;
      GlobalVariableSet(name,(double)(slot+1));
      g_legacy_hold_check_at[slot]=0;
      PrintFormat("HBv3.30 LEGACY TIER HOLD ADDED | side=%s rung=%d position=%I64u magic=%I64d; block new pending until verified broker TP",
                  buy?"BUY":"SELL",rung+1,id,PositionGetInteger(POSITION_MAGIC));
   }
}

// Check broker history for this exact POSITION_IDENTIFIER (not just last
// ticket). A manual/negative/unknown exit does NOT unlock the protected rung.
bool HistoricPositionProfitableTP(const ulong id)
{
   if(id==0 || IsPositionIdOpen(id) || !HistorySelectByPosition(id)) return false;
   bool entry=false,exit=false;
   datetime latest=0;
   long reason=-1;
   double net=0.0;
   for(int i=0;i<HistoryDealsTotal();i++)
   {
      ulong deal=HistoryDealGetTicket(i);
      if(deal==0 || (ulong)HistoryDealGetInteger(deal,DEAL_POSITION_ID)!=id ||
         HistoryDealGetString(deal,DEAL_SYMBOL)!=_Symbol) continue;
      ENUM_DEAL_ENTRY e=(ENUM_DEAL_ENTRY)HistoryDealGetInteger(deal,DEAL_ENTRY);
      if(e==DEAL_ENTRY_IN || e==DEAL_ENTRY_INOUT) entry=true;
      if(e==DEAL_ENTRY_OUT || e==DEAL_ENTRY_OUT_BY || e==DEAL_ENTRY_INOUT)
      {
         exit=true;
         datetime when=(datetime)HistoryDealGetInteger(deal,DEAL_TIME);
         if(when>=latest) {latest=when;reason=HistoryDealGetInteger(deal,DEAL_REASON);}
      }
      net+=HistoryDealGetDouble(deal,DEAL_PROFIT)+HistoryDealGetDouble(deal,DEAL_SWAP)+
           HistoryDealGetDouble(deal,DEAL_COMMISSION)+HistoryDealGetDouble(deal,DEAL_FEE);
   }
   return entry && exit && reason==DEAL_REASON_TP && net>0.0;
}

bool LegacyTierHoldBlocks(const int slot)
{
   if(slot<0 || slot>=LIMIT_SLOTS || g_legacy_tier_hold_prefix=="") return false;
   datetime now=TimeCurrent();
   if(g_legacy_hold_check_at[slot]>0 && now-g_legacy_hold_check_at[slot]<15)
      return g_legacy_hold_check_result[slot];
   g_legacy_hold_check_at[slot]=now;
   int blockers=0;
   for(int i=GlobalVariablesTotal()-1;i>=0;i--)
   {
      string name=GlobalVariableName(i);
      if(StringFind(name,g_legacy_tier_hold_prefix)!=0) continue;
      if((int)GlobalVariableGet(name)-1!=slot) continue;
      ulong id=(ulong)StringToInteger(StringSubstr(name,StringLen(g_legacy_tier_hold_prefix)));
      if(id==0) {blockers++;continue;}
      if(IsPositionIdOpen(id)) {blockers++;continue;}
      if(!HistoricPositionProfitableTP(id)) {blockers++;continue;}
      GlobalVariableDel(name);
      PrintFormat("HBv3.30 LEGACY TIER TP VERIFIED | side=%s rung=%d position=%I64u; guard released",
                  slot<LIMIT_PER_SIDE?"BUY":"SELL",slot%LIMIT_PER_SIDE+1,id);
   }
   g_legacy_hold_check_result[slot]=(blockers>0);
   return blockers>0;
}

// v3.22: a live position can predate this magic or survive a VPS ledger loss.
// One per-rung broker pending is canceled ONLY after exact MAGIC, comment,
// direction and expected/legacy lot are re-verified. No live trade is closed.
// The occupied rung is not rearmed until the live trade has exited and the
// existing TP/refill rules separately permit it.
void QuarantineOccupiedTierPendings()
{
   return; // v3.44: accepted grid orders remain fixed; no refill or cancellation
}

// v3.36: Per-side opposite-grid proximity rule. 100 USC means account-currency
// P/L of the specific pending order volume, calculated with broker contract specs.
input int InpOppositeGuardTriggerPositions = 5;
input double InpOppositeGuardDistanceUSC = 100.0;
// Virtual grid safeguard. At this many SAME-SIDE non-cooling positions,
// no further same-side grid LIMIT stays at the broker. It is reconsidered
// locally on future ticks only AFTER capacity is again available.
const bool InpVirtualGridAfterEight = false;
input int  InpVirtualGridSideCap = 8;
input int  InpVirtualGridMaxCancelPerPass = 8;
int GridSideOpenCount(const bool buy)
{
   int count=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong t=PositionGetTicket(i);
      if(t==0 || !PositionSelectByTicket(t)) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol || PositionGetInteger(POSITION_MAGIC)!=InpMagic) continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE)!=(buy?POSITION_TYPE_BUY:POSITION_TYPE_SELL)) continue;
      string c=PositionGetString(POSITION_COMMENT);
      if(StringFind(c,"HB COOL")==0) continue;
      count++;
   }
   return count;
}
bool OppositeGridDistanceAllowed(const bool buy,const double pendingPrice,const double volume)
{
   return true; // fixed geometry replaces the former opposite-side spacing filter
}

// v3.40 BROKER SAFETY SWEEP: when a direction already has eight non-cooling
// positions, the REMAINING grid rungs are virtual, not resting at broker.
// Enforce the 5-opposite/100-USC rule on ALREADY resting broker orders too.
// Cancel only individually verified GRID tickets of our own exact Magic and
// exact rung comment; never touch repeat, manual, another EA or live positions.
// A canceled rung remains represented by its 0..39 slot and will be
// re-evaluated by RetryMissingSeedLimits/RefillActivatedLimits.
// Return true if any broker changes were attempted (caller resynchronizes).
bool EnforceBrokerGridExposure()
{
   return false; // all 80 levels live at broker; eight-position trigger is cooling only
}

bool FixedRungCommitted(const int k)
{
   if(k<0 || k>=LIMIT_SLOTS || g_basket_start<=0) return false;
   string stamp=g_limit_order_key[k]+".once";
   if(GlobalVariableCheck(stamp) && (datetime)GlobalVariableGet(stamp)==g_basket_start) return true;
   if(g_limit_order[k]!=0 || g_limit_position[k]!=0 || g_limit_tp_cycles[k]>0)
   {
      GlobalVariableSet(stamp,(double)g_basket_start);
      return true;
   }
   return false;
}
void CommitFixedRung(const int k)
{
   GlobalVariableSet(g_limit_order_key[k]+".once",(double)g_basket_start);
}
bool FixedNetworkPendingOrIncomplete()
{
   // Only real broker pending exposure keeps a flat network alive.
   // Never-accepted rungs are not live exposure and cannot block a new cycle.
   return OwnedPendingCount()>0;
}

bool PlaceLimitRung(const int k,const double buy_seed,const double sell_seed,const bool from_market)
{
   if(k<0 || k>=LIMIT_SLOTS || !CanTradeNow() || g_exit_in_progress) return false;
   if(!from_market && FixedRungCommitted(k)) return false;
   // Never put a new pending in a rung while its trade is still open.
   if(OpenLimitPositionsAtLevel(k)>0 || LegacyTierHoldBlocks(k)) return false;
   ulong existing=0;
   if(PendingCountAtLevel(k,existing)>0) return false;
   MqlTick q;
   if(!SymbolInfoTick(_Symbol,q) || q.ask<=q.bid || q.bid<=0) return false;
   bool buy=(k<LIMIT_PER_SIDE);
   if(g_park_side==(buy?0:1)) return false; // v3.59: parked trend side gets no new rung
   if(InpVirtualGridAfterEight && GridSideOpenCount(buy)>=InpVirtualGridSideCap)
      return false; // This tier is local/virtual while the side is saturated.
   int rung=(k%LIMIT_PER_SIDE)+1;
   double ticksize=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   if(ticksize<=0) ticksize=_Point;
   if(g_recenter_anchor_mid<=0.0) return false;
   double raw=g_recenter_anchor_mid+(buy?-GridFirstDistance():GridFirstDistance());
   bool haveEdge=false;
   double outer=0.0;
   for(int oi=0;oi<OrdersTotal();oi++)
   {
      ulong other=OrderGetTicket(oi);
      if(other==0 || !OrderSelect(other)) continue;
      if(OrderGetString(ORDER_SYMBOL)!=_Symbol || OrderGetInteger(ORDER_MAGIC)!=InpMagic ||
         (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE)!=(buy?ORDER_TYPE_BUY_LIMIT:ORDER_TYPE_SELL_LIMIT) ||
         StringFind(OrderGetString(ORDER_COMMENT),buy?"HB LB":"HB LS")!=0) continue;
      double entry=OrderGetDouble(ORDER_PRICE_OPEN);
      if(!haveEdge) outer=entry;
      else outer=buy?MathMin(outer,entry):MathMax(outer,entry);
      haveEdge=true;
   }
   if(haveEdge) raw=outer+(buy?-GridSpacing():GridSpacing());
   else if(from_market)
   {
      double mid=MathRound(((q.ask+q.bid)*0.5)/ticksize)*ticksize;
      raw=mid+(buy?-GridFirstDistance():GridFirstDistance());
   }
   double price=buy ? MathFloor(raw/ticksize+1e-8)*ticksize :
                      MathCeil(raw/ticksize-1e-8)*ticksize;
   price=NormalizeDouble(price,(int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS));
   double minimum=((double)MathMax((int)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL),
                                    (int)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_FREEZE_LEVEL)))*_Point+2*ticksize;
   if(price<=0 || (buy && price>=q.ask-minimum) || (!buy && price<=q.bid+minimum))
   {
      PrintFormat("HBv3.30 LIMIT INVALID | %s %d price=%.3f minDist=%.3f",buy?"BUY":"SELL",rung,price,minimum);
      return false;
   }
   double tp=0.0;
   ENUM_ORDER_TYPE direction=buy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   double rungLot=LimitLotForSlot(k);
   double cash=LimitTargetForSlot(k);
   if(!OppositeGridDistanceAllowed(buy,price,rungLot)) return false;
   if(rungLot<=0 || cash<=0 || !PendingLimitTPForAccountProfit(direction,price,rungLot,cash,tp))
   {
      PrintFormat("HBv3.30 LIMIT TP UNAVAILABLE | side=%s rung=%d lot=%.2f target=%.2f %s",buy?"BUY":"SELL",rung,rungLot,cash,AccountInfoString(ACCOUNT_CURRENCY));
      return false;
   }
   // A broker-side TP must be favourably beyond the entry by its minimum distance.
   if((buy && tp+1e-8<price+minimum) || (!buy && tp-1e-8>price-minimum)) return false;
   if(!MarginOK(direction,1.0,rungLot))
   {
      PrintFormat("HBv3.30 LIMIT WAIT MARGIN | %s rung=%d",buy?"BUY":"SELL",rung);
      return false;
   }
   long modes=SymbolInfoInteger(_Symbol,SYMBOL_EXPIRATION_MODE);
   bool timed=InpLimitExpiryMinutes>0 && (modes & SYMBOL_EXPIRATION_SPECIFIED)!=0;
   ENUM_ORDER_TYPE_TIME time_type=timed ? ORDER_TIME_SPECIFIED : ORDER_TIME_GTC;
   datetime expire=timed ? TimeCurrent()+InpLimitExpiryMinutes*60 : 0;
   string comment=StringFormat("HB L%s%d",buy?"B":"S",rung);
   bool sent=(buy ? trade.BuyLimit(rungLot,price,_Symbol,0.0,tp,time_type,expire,comment) :
                    trade.SellLimit(rungLot,price,_Symbol,0.0,tp,time_type,expire,comment));
   ulong order=trade.ResultOrder();
   uint result=trade.ResultRetcode();
   if(!sent || order==0 || (result!=TRADE_RETCODE_PLACED && result!=TRADE_RETCODE_DONE))
   {
      PrintFormat("HBv3.30 LIMIT REJECT | %s rung=%d retcode=%u %s",buy?"BUY":"SELL",rung,result,trade.ResultRetcodeDescription());
      return false;
   }
   g_grid_geometry_dirty=true;
   CommitFixedRung(k);
   g_limit_order[k]=order;
   g_limit_position[k]=0;
   GlobalVariableSet(g_limit_order_key[k],(double)order);
   GlobalVariableSet(g_limit_position_key[k],0.0);
   if(buy)
   {
      if(g_limit_outer_buy<=0 || price<g_limit_outer_buy)
      {
         g_limit_outer_buy=price;
         GlobalVariableSet(g_limit_outer_buy_key,price);
      }
   }
   else
   {
      if(g_limit_outer_sell<=0 || price>g_limit_outer_sell)
      {
         g_limit_outer_sell=price;
         GlobalVariableSet(g_limit_outer_sell_key,price);
      }
   }
   if(from_market)
   {
      g_limit_refill_cycles[k]++;
      GlobalVariableSet(g_limit_refill_cycle_key[k],(double)g_limit_refill_cycles[k]);
      PrintFormat("HBv3.30 REFILL CYCLE | %s rung=%d cycle=%d minimum=%d pendingOrder=%I64u",
                  buy?"BUY":"SELL",rung,g_limit_refill_cycles[k],InpMinimumRefillCycles,order);
      if(g_limit_refill_cycles[k]==InpMinimumRefillCycles)
         PrintFormat("HBv3.30 MINIMUM TEN REFILLS MET | %s rung=%d count=%d; rearming remains enabled",
                     buy?"BUY":"SELL",rung,g_limit_refill_cycles[k]);
   }
   PrintFormat("HBv3.30 LIMIT %s | %s originalSlot=%d order=%I64u entry=%.3f TP=%.3f profitTarget=%.2f %s lot=%.2f SL=NONE outerBuy=%.3f outerSell=%.3f",
               from_market?"APPENDED_LAST":"PLACED",buy?"BUY":"SELL",rung,order,price,tp,cash,AccountInfoString(ACCOUNT_CURRENCY),rungLot,g_limit_outer_buy,g_limit_outer_sell);
   return true;
}

bool PlaceSeedLimitOrders(const double buy_seed_price,const double sell_seed_price)
{
   if(!InpEnableBrokerLimits) return true;
   int placed=0;
   for(int k=0;k<LIMIT_SLOTS;k++)
   {
      g_limit_last_retry[k]=TimeCurrent();
      if(PlaceLimitRung(k,buy_seed_price,sell_seed_price,false))
      {
         placed++;
         g_limit_last_retry[k]=0;
      }
   }
   PrintFormat("HBv3.30 INITIAL PENDINGS %d/%d accepted; any rejected rung retries later if account has margin",placed,LIMIT_SLOTS);
   return true; // Rejected pendings must not trigger liquidation of original hedge
}

// Original BUY/SELL re-entries also use BUY_LIMIT or SELL_LIMIT,
// the SAME MAGIC, but are not one of the 40 tier slots. Confirm their identity
// independently: they MUST remain untouched during grid re-centering.
// If the terminal lost the repeat ticket, adopt it only if exactly one broker
// pending has the expected signature AND a verifiable profitable seed exit.
bool IsVerifiedOriginalRepeatPending(const ulong ticket)
{
   if(!InpRepeatOriginalOnTP || ticket==0 || !OrderSelect(ticket)) return false;
   if(OrderGetString(ORDER_SYMBOL)!=_Symbol ||
      OrderGetInteger(ORDER_MAGIC)!=InpMagic) return false;
   ENUM_ORDER_TYPE ty=(ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
   double vol=OrderGetDouble(ORDER_VOLUME_INITIAL);
   double tol=MathMax(1e-7,SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP)*0.1);
   if(MathAbs(vol-InpFixedLot)>tol || OrderGetDouble(ORDER_TP)<=0) return false;
   string comment=OrderGetString(ORDER_COMMENT);
   for(int side=0;side<2;side++)
   {
      if(ty!=(side==0 ? ORDER_TYPE_BUY_LIMIT : ORDER_TYPE_SELL_LIMIT)) continue;
      if(comment!=(side==0 ? "HB REPEAT BUY 50" : "HB REPEAT SELL 50") &&
         comment!=(side==0 ? "HB REPEAT BUY 30" : "HB REPEAT SELL 30") &&
         comment!=(side==0 ? "HB REPEAT BUY 80" : "HB REPEAT SELL 80")) continue;
      if(g_repeat_order[side]==ticket) return true; // already tracked, exact match
      // A different tracked ticket is NOT license to adopt another one.
      if(g_repeat_order[side]!=0 || g_repeat_position[side]==0 ||
         IsPositionIdOpen(g_repeat_position[side])) return false;
      double closedPrice=0.0;
      if(!RepeatClosedAtProfitableTP(g_repeat_position[side],closedPrice)) return false;
      // A legitimate repeat is at the TP of its previous position +/- 10
      // gold-price units. Use the broker-recorded close as independent evidence.
      double expected=closedPrice+(side==0 ? -InpRepeatDistancePrice : InpRepeatDistancePrice);
      double price=OrderGetDouble(ORDER_PRICE_OPEN);
      double tickSize=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
      if(tickSize<=0) tickSize=_Point;
      if(MathAbs(expected-price)>MathMax(0.15,5.0*tickSize)) return false;
      // Do not infer ownership if two active repeat orders have same signature.
      int matching=0;
      for(int j=0;j<OrdersTotal();j++)
      {
         ulong cand=OrderGetTicket(j);
         if(cand==0 || !OrderSelect(cand)) continue;
         if(OrderGetString(ORDER_SYMBOL)==_Symbol &&
            OrderGetInteger(ORDER_MAGIC)==InpMagic &&
            OrderGetInteger(ORDER_TYPE)==ty &&
            OrderGetString(ORDER_COMMENT)==comment &&
            MathAbs(OrderGetDouble(ORDER_VOLUME_INITIAL)-InpFixedLot)<=tol)
            matching++;
      }
      if(matching!=1) return false;
      g_repeat_order[side]=ticket;
      g_repeat_armed_for[side]=g_repeat_position[side];
      GlobalVariableSet(g_repeat_order_key[side],(double)ticket);
      GlobalVariableSet(g_repeat_armed_key[side],(double)g_repeat_armed_for[side]);
      PrintFormat("HBv3.30 RECOVERED ORIGINAL REPEAT | %s ticket=%I64u sourceId=%I64u entry=%.3f (NOT grid tier)",
                  side==0 ? "BUY" : "SELL",ticket,g_repeat_position[side],price);
      return true;
   }
   return false;
}

// Re-center only this EA's ACTIVE broker LIMIT pendings. Never move positions,
// original hedge re-entry orders, or pending orders owned by another Magic.
// Modify by ticket so a rejected request leaves the existing pending in place;
// NO cancellation/replacement race and no duplicate requests for that ticket.
// This diagnostic does not alter order execution. A due review does NOT
// guarantee broker modification: quote, spread, identity and freeze checks apply.
void LogRecenterDecision(const string reason)
{
   if(!InpEnableBrokerLimits || !MarketRecenterActive() || g_basket_start<=0) return;
   datetime now=TimeTradeServer();
   if(now<=0) now=TimeCurrent();
   if(g_recenter_last_time>0 && now-g_recenter_last_time<GridRecenterMinutes()*60) return;
   if(g_last_recenter_decision_log>0 && now-g_last_recenter_decision_log<30) return;
   g_last_recenter_decision_log=now;
   MqlTick q;
   double mid=0.0,spread=0.0;
   if(SymbolInfoTick(_Symbol,q) && q.bid>0 && q.ask>=q.bid)
   {mid=(q.bid+q.ask)*0.5;spread=q.ask-q.bid;}
   PrintFormat("HBv3.30 RECENTER DECISION | due=YES every=%dmin reason=%s marketMid=%.3f lastAnchor=%.3f ageSeconds=%d spread=%.3f pending=%d liveLimit=%d",
               GridRecenterMinutes(),reason,mid,g_recenter_anchor_mid,
               (int)(now-g_recenter_last_time),spread,OwnedLimitPendingCount(),OpenLimitPositionCount());
}

bool PendingRecenterDue(const datetime now,const datetime last)
{
   return last<=0 || now-last>=60;
}

double PendingRecenterPrice(const bool buy,const int rank,const double mid,const double ticksize)
{
   if(rank<1 || rank>LIMIT_PER_SIDE || mid<=0.0 || ticksize<=0.0) return 0.0;
   double anchor=MathRound(mid/ticksize)*ticksize;
   double sp=GridSpacing();
   if((buy && g_trend_dir<0) || (!buy && g_trend_dir>0)) sp*=MathMax(1.0,InpTrendSpacingMult); // v3.66 adverse side
   sp=MathRound(sp/ticksize)*ticksize;
   double raw=anchor+(buy?-1.0:1.0)*(GridFirstDistance()+(rank-1)*sp);
   if(g_park_side==(buy?0:1)) raw+=(buy?-1.0:1.0)*ParkDistance(); // v3.59 parked trend side
   return NormalizeDouble(MathRound(raw/ticksize)*ticksize,(int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS));
}

// Snapshot broker orders, not just cached ticket IDs. A partial/ambiguous
// rung prevents a geometry sweep rather than being silently omitted from it.
bool SnapshotGridGeometry(ulong &tickets[])
{
   ArrayInitialize(tickets,0);
   for(int i=0;i<OrdersTotal();i++)
   {
      ulong ticket=OrderGetTicket(i);
      if(ticket==0 || !OrderSelect(ticket)) return false;
      if(OrderGetString(ORDER_SYMBOL)!=_Symbol || OrderGetInteger(ORDER_MAGIC)!=InpMagic) continue;
      string comment=OrderGetString(ORDER_COMMENT);
      int slot=-1;
      for(int k=0;k<LIMIT_SLOTS;k++)
         if(comment==StringFormat("HB L%s%d",k<LIMIT_PER_SIDE?"B":"S",k%LIMIT_PER_SIDE+1))
         {slot=k;break;}
      if(slot<0) continue; // unrelated repeat orders are not part of this grid
      bool buy=slot<LIMIT_PER_SIDE;
      if(tickets[slot]!=0 ||
         (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE)!=(buy?ORDER_TYPE_BUY_LIMIT:ORDER_TYPE_SELL_LIMIT) ||
         !LimitVolumeMatchesSlot(slot,OrderGetDouble(ORDER_VOLUME_INITIAL)) ||
         MathAbs(OrderGetDouble(ORDER_VOLUME_INITIAL)-OrderGetDouble(ORDER_VOLUME_CURRENT))>1e-8 ||
         (ENUM_ORDER_STATE)OrderGetInteger(ORDER_STATE)==ORDER_STATE_PARTIAL) return false;
      tickets[slot]=ticket;
   }
   return true;
}

int GridPendingRank(const int slot,const ulong &tickets[])
{
   if(slot<0 || slot>=LIMIT_SLOTS || tickets[slot]==0) return 0;
   int rank=0;
   for(int k=slot<LIMIT_PER_SIDE?0:LIMIT_PER_SIDE;k<=slot;k++)
      if(tickets[k]!=0) rank++;
   return rank;
}

void MaybeRecenterPendingGrid()
{
   if(!InpEnableBrokerLimits || g_basket_start<=0 || g_exit_in_progress ||
      g_technical_pause || !CanTradeNow()) return;
   datetime now=TimeCurrent();
   bool due=PendingRecenterDue(now,g_recenter_last_time);
   if(!due && !g_grid_geometry_dirty) return;
   if(g_recenter_last_attempt>0 && now-g_recenter_last_attempt<3) return;
   g_recenter_last_attempt=now;
   MqlTick quote;
   if(!SymbolInfoTick(_Symbol,quote) || quote.ask<=quote.bid || quote.bid<=0) return;
   if(!SpreadOK(quote))
   {
      static datetime lastSpreadLog=0;
      if(now-lastSpreadLog>=30)
      {
         lastSpreadLog=now;
         PrintFormat("HBv3.55 GRID WAIT SPREAD | spread=%.3f max=%.3f; recenter and refills paused until spread normal",
                     quote.ask-quote.bid,InpMaxSpreadPrice);
      }
      return;
   }
   double ticksize=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   if(ticksize<=0) return;
   g_grid_geometry_dirty=true;
   // New market anchor every 60 seconds. Repairs between reviews retain the
   // same anchor; failed orders cannot indefinitely postpone the next review.
   double newMid=MathRound(((quote.ask+quote.bid)*0.5)/ticksize)*ticksize;
   if(due && g_recenter_anchor_mid>0 && InpRecenterMinMovePrice>0 &&
      MathAbs(newMid-g_recenter_anchor_mid)<InpRecenterMinMovePrice && !g_grid_geometry_dirty)
   {
      g_recenter_last_time=now; // v3.63 optional: small move, keep grid where it is
      GlobalVariableSet(g_recenter_time_key,(double)now);
      return;
   }
   if(due || g_recenter_anchor_mid<=0)
   {
      g_recenter_anchor_mid=newMid;
      g_recenter_last_time=now;
      GlobalVariableSet(g_recenter_anchor_key,g_recenter_anchor_mid);
      GlobalVariableSet(g_recenter_time_key,(double)now);
   }
   double mid=g_recenter_anchor_mid;
   ulong tickets[LIMIT_SLOTS];
   if(!SnapshotGridGeometry(tickets))
   {EntryBlocked("GRID GEOMETRY WAIT: duplicate, partial or unverified pending; retry in 3 seconds");return;}
   int moved=0,unchanged=0,blocked=0,held=0,buyCount=0,sellCount=0,inflight=0,sentNow=0,deferred=0,lazy=0;
   ulong nowms=GetTickCount64();
   // v3.55: after a fill, price sits on the next rank-1 level, so that one
   // pending cannot be moved there yet. Earlier versions counted it as a
   // failure, the sweep never verified, and every refill stayed frozen.
   // Such a ticket now keeps its current price until the next 60s review.
   bool marketHeld[LIMIT_SLOTS];
   for(int h=0;h<LIMIT_SLOTS;h++) marketHeld[h]=false;
   for(int k=0;k<LIMIT_SLOTS;k++)
   {
      ulong ticket=tickets[k];
      if(ticket==0) continue;
      bool buy=k<LIMIT_PER_SIDE;
      if(buy) buyCount++;else sellCount++;
      if(!OrderSelect(ticket)) {blocked++;continue;}
      if(MathAbs(OrderGetDouble(ORDER_VOLUME_INITIAL)-OrderGetDouble(ORDER_VOLUME_CURRENT))>1e-8 ||
         (ENUM_ORDER_STATE)OrderGetInteger(ORDER_STATE)==ORDER_STATE_PARTIAL) {blocked++;continue;}
      int rank=GridPendingRank(k,tickets);
      double volume=OrderGetDouble(ORDER_VOLUME_INITIAL);
      double price=PendingRecenterPrice(buy,rank,mid,ticksize),tp=0.0;
      if(price<=0 || !PendingLimitTPForAccountProfit(buy?ORDER_TYPE_BUY:ORDER_TYPE_SELL,price,volume,LimitTargetForSlot(k),tp))
      {blocked++;continue;}
      // Re-select after the calculation: read fields from this exact ticket.
      if(!OrderSelect(ticket)) {blocked++;continue;}
      double oldPrice=OrderGetDouble(ORDER_PRICE_OPEN),oldTP=OrderGetDouble(ORDER_TP);
      if(MathAbs(price-oldPrice)<ticksize*0.5 && MathAbs(tp-oldTP)<ticksize*0.5)
      {unchanged++;continue;}
      if(FarRungAcceptable(buy,rank,oldPrice,price,ticksize)) {unchanged++;lazy++;continue;} // v3.64
      MqlTick live;
      if(!SymbolInfoTick(_Symbol,live)) {blocked++;continue;}
      double freeze=(double)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_FREEZE_LEVEL)*_Point;
      double stop=(double)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL)*_Point;
      double gap=MathMax(freeze,stop)+2*ticksize;
      bool frozen=freeze>0 && (buy?live.ask-oldPrice:oldPrice-live.bid)<=freeze;
      if(frozen || (buy?price>=live.ask-gap:price<=live.bid+gap))
      {marketHeld[k]=true;held++;continue;}
      if(buy?tp<price+gap:tp>price-gap)
      {blocked++;continue;}
      double sl=OrderGetDouble(ORDER_SL);
      ENUM_ORDER_TYPE_TIME duration=(ENUM_ORDER_TYPE_TIME)OrderGetInteger(ORDER_TYPE_TIME);
      datetime expiry=(datetime)OrderGetInteger(ORDER_TIME_EXPIRATION);
      if(InpAsyncGridModify && !g_tester)
      {
         // same target already requested and still in flight: do not resend
         if(g_mod_ticket[k]==ticket && MathAbs(g_mod_price[k]-price)<ticksize*0.5 && nowms-g_mod_ms[k]<8000)
         {inflight++;continue;}
         if(sentNow>=MathMax(1,InpModifyBatchPerPass)) {deferred++;continue;}
         trade.SetAsyncMode(true);
         bool asent=trade.OrderModify(ticket,price,sl,tp,duration,expiry,0.0);
         uint aret=trade.ResultRetcode();
         trade.SetAsyncMode(false);
         if(asent)
         {
            g_mod_ticket[k]=ticket;g_mod_price[k]=price;g_mod_ms[k]=nowms;
            sentNow++;inflight++;g_async_sent_total++;
         }
         else
         {
            blocked++;
            PrintFormat("HBv3.63 ASYNC MODIFY REJECT | ticket=%I64u rank=%d entry=%.3f code=%u",ticket,rank,price,aret);
         }
         continue;
      }
      bool sent=trade.OrderModify(ticket,price,sl,tp,duration,expiry,0.0);
      uint ret=trade.ResultRetcode();
      if(sent && (ret==TRADE_RETCODE_DONE || ret==TRADE_RETCODE_NO_CHANGES) &&
         OrderSelect(ticket) && MathAbs(OrderGetDouble(ORDER_PRICE_OPEN)-price)<ticksize*0.5 &&
         MathAbs(OrderGetDouble(ORDER_TP)-tp)<ticksize*0.5) moved++;
      else
      {
         blocked++;
         PrintFormat("HBv3.52 GRID MODIFY WAIT | ticket=%I64u rank=%d entry=%.3f TP=%.3f code=%u",
                     ticket,rank,price,tp,ret);
      }
   }
   // A sweep is successful only if the broker still has exactly the same
   // snapshot, and EVERY entry + TP matches the common ranked plan.
   g_async_inflight=inflight;
   g_far_lazy=lazy;
   if(inflight>0 || deferred>0)
   {
      // v3.63: broker is still applying async moves; verify on the next 3 s pass
      PrintFormat("HBv3.63 GRID ASYNC | sentNow=%d inFlight=%d deferred=%d unchanged=%d held=%d blocked=%d",
                  sentNow,inflight,deferred,unchanged,held,blocked);
      g_geo_verified=false;
      return; // g_grid_geometry_dirty stays true
   }
   ulong after[LIMIT_SLOTS];
   bool verified=SnapshotGridGeometry(after);
   for(int k=0;k<LIMIT_SLOTS && verified;k++)
   {
      if(after[k]!=tickets[k]) {verified=false;break;}
      if(after[k]==0 || marketHeld[k]) continue;
      if(!OrderSelect(after[k])) {verified=false;break;}
      bool buy=k<LIMIT_PER_SIDE;
      int vrank=GridPendingRank(k,after);
      double price=PendingRecenterPrice(buy,vrank,mid,ticksize),tp=0.0;
      if(!OrderSelect(after[k])) {verified=false;break;}
      if(FarRungAcceptable(buy,vrank,OrderGetDouble(ORDER_PRICE_OPEN),price,ticksize)) continue; // v3.64 lazy far rung
      double volume=OrderGetDouble(ORDER_VOLUME_INITIAL);
      if(!PendingLimitTPForAccountProfit(buy?ORDER_TYPE_BUY:ORDER_TYPE_SELL,price,volume,LimitTargetForSlot(k),tp) ||
         !OrderSelect(after[k])) {verified=false;break;}
      if(MathAbs(OrderGetDouble(ORDER_PRICE_OPEN)-price)>=ticksize*0.5 ||
         MathAbs(OrderGetDouble(ORDER_TP)-tp)>=ticksize*0.5) verified=false;
   }
   g_grid_geometry_dirty=!verified;
   g_geo_verified=verified; if(verified!=g_geo_prev){GHBEvent(verified?"Grid geometry verified":"Grid geometry repair started");g_geo_prev=verified;}
   PrintFormat("HBv3.55 GRID GEOMETRY | anchor=%.3f BUY=%d SELL=%d moved=%d unchanged=%d heldAtMarket=%d blocked=%d spacing=0.50 verified=%s retry=%s",
               mid,buyCount,sellCount,moved,unchanged,held,blocked,verified?"YES":"NO",verified?"60s market review":"3s repair");
}

// Optional controlled migration from the old v3.16 or v3.17 pending volumes.
// Never modify order volume in-place (MT5 does not support that).
// Delete ONE verified old pending, get a broker ACK, then let the existing
// normal retry/recenter logic create ONE new pending with the new rung lot.
// Defaults OFF to avoid increasing exposure without explicit opt-in.
void UpgradeOneExistingGridPending()
{
   if(!InpUpgradeExistingGridPendings || !InpEnableBrokerLimits ||
      g_basket_start<=0 || g_exit_in_progress || g_technical_pause || !CanTradeNow()) return;
   datetime now=TimeCurrent();
   if(g_last_lot_upgrade_attempt!=0 &&
      now-g_last_lot_upgrade_attempt<InpLotUpgradeIntervalSeconds) return;
   for(int k=0;k<LIMIT_SLOTS;k++)
   {
      if(OpenLimitPositionsAtLevel(k)>0 || g_limit_position[k]!=0) continue;
      ulong ticket=g_limit_order[k];
      if(!LimitOrderTicketOpen(ticket) || !OrderSelect(ticket)) continue;
      bool buy=(k<LIMIT_PER_SIDE);
      string expected=StringFormat("HB L%s%d",buy?"B":"S",k%LIMIT_PER_SIDE+1);
      ENUM_ORDER_TYPE type=(ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      double vol=OrderGetDouble(ORDER_VOLUME_CURRENT);
      if(OrderGetString(ORDER_SYMBOL)!=_Symbol ||
         OrderGetInteger(ORDER_MAGIC)!=InpMagic ||
         type!=(buy?ORDER_TYPE_BUY_LIMIT:ORDER_TYPE_SELL_LIMIT) ||
         OrderGetString(ORDER_COMMENT)!=expected || !LimitVolumeMatchesSlot(k,vol))
      {
         PauseForTechnicalAudit("LOT UPGRADE: tracked pending ticket identity mismatch");
         return;
      }
      double next_lot=LimitLotForSlot(k);
      double volume_tol=MathMax(1e-7,SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP)*0.1);
      if(MathAbs(next_lot-vol)<=volume_tol) continue;
      // Never silently increase a pending volume; user must explicitly opt in.
      // Continue scanning lower-risk rungs rather than blocking all upgrades.
      if(next_lot>vol+volume_tol && !InpAllowExistingPendingLotUpsize)
      {
         static datetime last_upsize_warning=0;
         if(now-last_upsize_warning>=60)
         {
            last_upsize_warning=now;
            PrintFormat("HBv3.30 LOT UPGRADE HELD UPSIZE | %s rung=%d liveOrder=%I64u existing=%.2f requested=%.2f; no volume increase without opt-in",
                        buy?"BUY":"SELL",k%LIMIT_PER_SIDE+1,ticket,vol,next_lot);
         }
         continue;
      }
      g_last_lot_upgrade_attempt=now;
      // Do not cancel unless the corresponding replacement passes the
      // account's current per-order margin protections.
      if(!MarginOK(buy?ORDER_TYPE_BUY:ORDER_TYPE_SELL,1.0,next_lot))
      {
         PrintFormat("HBv3.30 LOT UPGRADE WAIT MARGIN | %s level=%d old=%.2f new=%.2f",
                     buy?"BUY":"SELL",k%LIMIT_PER_SIDE+1,vol,next_lot);
         return;
      }
      bool sent=trade.OrderDelete(ticket);
      uint ret=trade.ResultRetcode();
      if(!sent || ret!=TRADE_RETCODE_DONE)
      {
         PrintFormat("HBv3.30 LOT UPGRADE DELETE REJECT | ticket=%I64u result=%u %s",
                     ticket,ret,trade.ResultRetcodeDescription());
         return;
      }
      // Persist the cleared ticket only after broker confirms cancellation;
      // regular retry logic will recover / recreate on the next event.
      g_limit_order[k]=0;
      GlobalVariableSet(g_limit_order_key[k],0.0);
      g_limit_last_retry[k]=0;
      PrintFormat("HBv3.30 LOT UPGRADE CANCELLED | %s level=%d ticket=%I64u old=%.2f new=%.2f; retry will place new LIMIT",
                  buy?"BUY":"SELL",k%LIMIT_PER_SIDE+1,ticket,vol,next_lot);
      return;
   }
}

// Reduce only verified, fully unfilled old 11..40-lot grid orders.
// Persist cancellation intent; replacement requires broker CANCELLED history.
// This operation is separate from price/TP recentering (volume is not mutable).
bool ReduceOneGridPendingLot()
{
   if(g_basket_start<=0 || g_exit_in_progress || g_technical_pause ||
      g_grid_geometry_dirty || !CanTradeNow()) return false;
   static datetime lastAttempt=0;
   if(lastAttempt>0 && TimeCurrent()-lastAttempt<3) return false;
   // Finish any previous cancellation/replacement before selecting another.
   for(int pass=0;pass<2;pass++)
   for(int k=0;k<LIMIT_SLOTS;k++)
   {
      if(k%LIMIT_PER_SIDE<10) continue; // rung 10 already has volume 10
      string key=g_limit_order_key[k]+".cap10";
      bool pending=GlobalVariableCheck(key);
      if((pass==0 && !pending) || (pass==1 && pending)) continue;
      ulong ticket=pending?(ulong)GlobalVariableGet(key):g_limit_order[k];
      if(ticket==0) continue;
      bool buy=k<LIMIT_PER_SIDE;
      string comment=StringFormat("HB L%s%d",buy?"B":"S",k%LIMIT_PER_SIDE+1);
      if(pending && !OrderSelect(ticket))
      {
         lastAttempt=TimeCurrent();
         if(!HistoryOrderSelect(ticket)) return true;
         if(HistoryOrderGetString(ticket,ORDER_SYMBOL)!=_Symbol ||
            HistoryOrderGetInteger(ticket,ORDER_MAGIC)!=InpMagic ||
            HistoryOrderGetString(ticket,ORDER_COMMENT)!=comment) return true;
         long state=HistoryOrderGetInteger(ticket,ORDER_STATE);
         if(state==ORDER_STATE_FILLED || OpenLimitPositionsAtLevel(k)>0)
         {GlobalVariableDel(key);return true;} // fill race: preserve position, no replacement
         if(state!=ORDER_STATE_CANCELED) return true;
         ulong existing=0;
         int matches=PendingCountAtLevel(k,existing);
         if(matches>1) {PauseForTechnicalAudit("cap10 duplicate pending rung");return true;}
         if(matches==1)
         {
            if(OrderSelect(existing) && MathAbs(OrderGetDouble(ORDER_VOLUME_INITIAL)-LimitLotForSlot(k))<1e-7)
            {g_limit_order[k]=existing;GlobalVariableSet(g_limit_order_key[k],(double)existing);GlobalVariableDel(key);}
            return true;
         }
         // Cancellation is now broker-confirmed. Preserve the rung identity
         // and let the normal placement function enforce margin, stops and TP.
         if(g_limit_order[k]==ticket) {g_limit_order[k]=0;GlobalVariableSet(g_limit_order_key[k],0.0);}
         if(PlaceLimitRung(k,0.0,0.0,true))
         {
            GlobalVariableDel(key);
            PrintFormat("HBv3.53 LOT CAP REPLACED | rung=%d side=%s oldTicket=%I64u newTicket=%I64u lot=10 TP=100",
                        k%LIMIT_PER_SIDE+1,buy?"BUY":"SELL",ticket,g_limit_order[k]);
         }
         return true;
      }
      if(!OrderSelect(ticket)) continue;
      if(OrderGetString(ORDER_SYMBOL)!=_Symbol || OrderGetInteger(ORDER_MAGIC)!=InpMagic ||
         OrderGetString(ORDER_COMMENT)!=comment ||
         (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE)!=(buy?ORDER_TYPE_BUY_LIMIT:ORDER_TYPE_SELL_LIMIT)) continue;
      double volume=OrderGetDouble(ORDER_VOLUME_INITIAL);
      if(volume<=10.0*g_lot_scale+1e-7 || MathAbs(volume-(k%LIMIT_PER_SIDE+1)*g_lot_scale)>1e-7 ||
         MathAbs(volume-OrderGetDouble(ORDER_VOLUME_CURRENT))>1e-7 ||
         (ENUM_ORDER_STATE)OrderGetInteger(ORDER_STATE)==ORDER_STATE_PARTIAL ||
         OpenLimitPositionsAtLevel(k)>0) continue;
      lastAttempt=TimeCurrent();
      GlobalVariableSet(key,(double)ticket);
      GlobalVariablesFlush();
      bool sent=trade.OrderDelete(ticket);
      PrintFormat("HBv3.53 LOT CAP CANCEL REQUEST | ticket=%I64u oldLot=%.2f targetLot=10 sent=%d code=%u; awaiting broker history before replacement",
                  ticket,volume,(int)sent,trade.ResultRetcode());
      g_grid_geometry_dirty=true;
      return true;
   }
   return false;
}

void RetryMissingSeedLimits()
{
   if(g_grid_geometry_dirty) return; // finish broker geometry before adding another rung
   if(!InpEnableBrokerLimits || g_exit_in_progress || g_basket_start<=0 ||
      g_technical_pause || !CanTradeNow() || g_recenter_anchor_mid<=0) return;
   for(int k=0;k<LIMIT_SLOTS;k++)
   {
      if(FixedRungCommitted(k)) continue;
      // Recover acknowledgements before retrying a never-accepted initial order.
      if(g_limit_order[k]!=0 || g_limit_position[k]!=0 || OpenLimitPositionsAtLevel(k)>0)
      { CommitFixedRung(k); continue; }
      ulong existing=0;
      int matches=PendingCountAtLevel(k,existing);
      if(matches>1) { PauseForTechnicalAudit("duplicate fixed grid rung"); return; }
      if(matches==1)
      {
         g_limit_order[k]=existing;
         GlobalVariableSet(g_limit_order_key[k],(double)existing);
         CommitFixedRung(k); continue;
      }
      if(g_limit_last_retry[k]>0 && TimeCurrent()-g_limit_last_retry[k]<InpLimitRefillRetrySeconds) continue;
      g_limit_last_retry[k]=TimeCurrent();
      if(PlaceLimitRung(k,g_recenter_anchor_mid,g_recenter_anchor_mid,false))
      {
         static int retryPlaced=0; retryPlaced++;
         if(retryPlaced%MathMax(1,InpRefillBatchMax)==0) return; // v3.62 batch
      }
   }
}

// Refill a slot ONLY on a broker's TP close and a positive booked NET result.
// A manual, stopped-out, or closed-by-EA position is NOT re-armed.
bool LimitReachedProfitableTP(const ulong position_id)
{
   if(position_id==0 || IsPositionIdOpen(position_id) || g_basket_start<=0) return false;
   for(int c=0;c<256;c++) if(g_tp_ok_ids[c]==position_id) return true; // v3.62 proven before
   GHBHistoryInvalidate();
   if(!HistorySelectByPosition(position_id)) return false; // v3.62: only this position's deals
   bool found_entry=false,found_exit=false;
   datetime last_exit_time=0;
   long last_reason=-1;
   double total=0.0;
   for(int i=0;i<HistoryDealsTotal();i++)
   {
      ulong d=HistoryDealGetTicket(i);
      if(d==0 || HistoryDealGetString(d,DEAL_SYMBOL)!=_Symbol ||
         (ulong)HistoryDealGetInteger(d,DEAL_POSITION_ID)!=position_id) continue;
      ENUM_DEAL_ENTRY entry=(ENUM_DEAL_ENTRY)HistoryDealGetInteger(d,DEAL_ENTRY);
      if(entry==DEAL_ENTRY_IN || entry==DEAL_ENTRY_INOUT) found_entry=true;
      if(entry==DEAL_ENTRY_OUT || entry==DEAL_ENTRY_OUT_BY || entry==DEAL_ENTRY_INOUT)
      {
         found_exit=true;
         datetime when=(datetime)HistoryDealGetInteger(d,DEAL_TIME);
         if(when>=last_exit_time)
         { last_exit_time=when;last_reason=HistoryDealGetInteger(d,DEAL_REASON); }
      }
      total+=HistoryDealGetDouble(d,DEAL_PROFIT)+HistoryDealGetDouble(d,DEAL_SWAP)+
             HistoryDealGetDouble(d,DEAL_COMMISSION)+HistoryDealGetDouble(d,DEAL_FEE);
   }
   int slot=LimitSlotForPositionId(position_id);
   bool targetClose=(slot>=0 && GlobalVariableCheck(g_limit_order_key[slot]+".targetExit") &&
      (ulong)GlobalVariableGet(g_limit_order_key[slot]+".targetExit")==position_id);
   bool overlapClose=(slot>=0 && GlobalVariableCheck(g_limit_order_key[slot]+".overlapExit") &&
      (ulong)GlobalVariableGet(g_limit_order_key[slot]+".overlapExit")==position_id);
   bool okTP=found_entry && found_exit &&
          ((total>0.0 && (last_reason==DEAL_REASON_TP || (last_reason==DEAL_REASON_EXPERT && targetClose))) ||
           (overlapClose && last_reason==DEAL_REASON_EXPERT)); // v3.59 overlap: rung re-armed
   if(okTP) {g_tp_ok_ids[g_tp_ok_pos]=position_id;g_tp_ok_pos=(g_tp_ok_pos+1)%256;}
   return okTP;
}

void RefillActivatedLimits()
{
   if(g_grid_geometry_dirty) return; // finish broker geometry before adding another rung
   if(!InpEnableBrokerLimits || g_basket_start<=0 || g_exit_in_progress || g_technical_pause || !CanTradeNow()) return;
   MqlTick quote;
   if(!SymbolInfoTick(_Symbol,quote) || !SpreadOK(quote)) return;
   int placedThisPass=0; // v3.62: batch, then ONE geometry sweep
   for(int k=0;k<LIMIT_SLOTS;k++)
   {
      if(placedThisPass>=MathMax(1,InpRefillBatchMax)) return;
      ulong previous=g_limit_position[k];
      if(previous==0 || LimitOrderTicketOpen(g_limit_order[k])) continue;
      if(IsPositionIdOpen(previous) || OpenLimitPositionsAtLevel(k)>0 || LegacyTierHoldBlocks(k)) continue;
      if(!LimitReachedProfitableTP(previous)) continue;
      ulong existing=0;
      int count=PendingCountAtLevel(k,existing);
      if(count>1) { PauseForTechnicalAudit("duplicate pending at refill tier"); return; }
      if(count==1)
      {
         g_limit_order[k]=existing;g_limit_position[k]=0;
         GlobalVariableSet(g_limit_order_key[k],(double)existing);
         GlobalVariableSet(g_limit_position_key[k],0.0);
         continue;
      }
      if(g_limit_last_retry[k]>0 && TimeCurrent()-g_limit_last_retry[k]<InpLimitRefillRetrySeconds) continue;
      g_limit_last_retry[k]=TimeCurrent();
      if(PlaceLimitRung(k,0.0,0.0,true))
      {
         placedThisPass++;
         g_refill_times[g_refill_pos]=TimeCurrent();g_refill_pos=(g_refill_pos+1)%64; g_st_refills++;
         GlobalVariableDel(g_limit_order_key[k]+".targetExit");
         GlobalVariableDel(g_limit_order_key[k]+".overlapExit");
         GHBEvent(StringFormat("Refill %s rung %d after TP",k<LIMIT_PER_SIDE?"BUY":"SELL",k%LIMIT_PER_SIDE+1));
         PrintFormat("HBv3.49 REFILL AFTER TARGET | side=%s rung=%d oldPosition=%I64u newOrder=%I64u lot=%.2f TP=50; other positions unchanged",
                     k<LIMIT_PER_SIDE?"BUY":"SELL",k%LIMIT_PER_SIDE+1,previous,g_limit_order[k],LimitLotForSlot(k));
      }
   }
}

// Broker may cancel a pending independently of a TP/fill. Recover only
// confirmed canceled/rejected/expired orders; wait on FILLED until deal is known.
void ReconcileCancelledLimitOrders()
{
   for(int k=0;k<LIMIT_SLOTS;k++)
   {
      ulong ticket=g_limit_order[k];
      if(ticket==0 || g_limit_position[k]!=0 || LimitOrderTicketOpen(ticket)) continue;
      if(!HistoryOrderSelect(ticket)) continue;
      ENUM_ORDER_STATE state=(ENUM_ORDER_STATE)HistoryOrderGetInteger(ticket,ORDER_STATE);
      if(state!=ORDER_STATE_CANCELED && state!=ORDER_STATE_EXPIRED && state!=ORDER_STATE_REJECTED) continue;
      PrintFormat("HBv3.30 PENDING REMOVED BY BROKER | slot=%d order=%I64u state=%s",
                  k,ticket,EnumToString(state));
      g_limit_order[k]=0;
      GlobalVariableSet(g_limit_order_key[k],0.0);
      g_limit_last_retry[k]=0;
   }
}

// Expired GTC orders should not be allowed to fill long after the basket opens.
void ExpireLimitOrdersIfNeeded()
{
   return; // v3.44: accepted grid orders remain fixed; no refill or cancellation
}

// Counter TP is sent to the broker with the order; this leg deliberately has
// No individual SL. Independent broker TP remains active.
bool CounterTPPrice(const ENUM_ORDER_TYPE side,const double open_price,
                    const double money_net,double &out_tp,const double specified_volume=0.0)
{
   if(money_net<=0 || open_price<=0) return false;
   double v=(specified_volume>0.0 ? specified_volume : InpCounterLot);
   double money=money_net+CommissionCostForVolume(v); // v3.57 gross needed for NET target
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol,tick) || tick.ask<=0 || tick.bid<=0) return false;
   double step=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   if(step<=0) step=_Point;
   double distance=step, pnl=0.0;
   bool bracket=false;
   for(int k=0;k<60;k++)
   {
      double candidate=open_price+(side==ORDER_TYPE_BUY ? distance : -distance);
      if(candidate<=0 || !OrderCalcProfit(side,_Symbol,v,open_price,candidate,pnl)) return false;
      if(pnl>=money) {bracket=true;break;}
      distance*=1.7;
   }
   if(!bracket) return false;
   double lo=0.0,hi=distance;
   for(int i=0;i<40;i++)
   {
      double mid=(lo+hi)*0.5;
      double test=open_price+(side==ORDER_TYPE_BUY ? mid : -mid);
      if(!OrderCalcProfit(side,_Symbol,v,open_price,test,pnl)) return false;
      if(pnl>=money) hi=mid;
      else lo=mid;
   }
   double raw=open_price+(side==ORDER_TYPE_BUY ? hi : -hi);
   double minDistance=(double)MathMax((int)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL),
                                      (int)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_FREEZE_LEVEL))*_Point+2.0*step;
   if(side==ORDER_TYPE_BUY)
   {
      raw=MathMax(raw,tick.bid+minDistance);
      out_tp=MathCeil(raw/step-1e-8)*step;
   }
   else
   {
      raw=MathMin(raw,tick.ask-minDistance);
      out_tp=MathFloor(raw/step+1e-8)*step;
   }
   out_tp=NormalizeDouble(out_tp,(int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS));
   return out_tp>0;
}

bool IdentifierInBasket(const BasketState &b,const ulong id)
{
   for(int i=0;i<b.id_count;i++) if(b.identifiers[i]==id) return true;
   return false;
}

void OpenOnePullbackCounter(const BasketState &core,const MqlTick &tick)
{
   if(g_technical_pause || !InpEnableCounterTrade || g_counter_placed || g_expected_positions<3 ||
      g_grid_direction==0 || g_counter_third_time<=0 || !CanTradeNow() ||
      (!IsPositionIdOpen(g_third_id) && !IsPositionIdOpen(g_fourth_id))) return;
   datetime now=TimeCurrent();
   if(now-g_counter_third_time<InpCounterWaitSeconds) return;
   if(!SpreadOK(tick)) return;
   ENUM_ORDER_TYPE side=(g_grid_direction==1 ? ORDER_TYPE_SELL : ORDER_TYPE_BUY);
   if(!MarginOK(side,1.0,InpCounterLot)) return;
   if(g_counter_best<=0 || g_counter_third_price<=0) return;
   double advance=(g_grid_direction==1 ? g_counter_best-g_counter_third_price :
                                           g_counter_third_price-g_counter_best);
   double retrace=(g_grid_direction==1 ? g_counter_best-tick.bid :
                                           tick.ask-g_counter_best);
   if(advance+_Point*0.0001<InpCounterMinAdvancePrice ||
      retrace+_Point*0.0001<InpCounterRetracePrice)
   {
      g_counter_retrace_since=0;
      return;
   }
   if(g_counter_retrace_since==0) g_counter_retrace_since=now;
   if(now-g_counter_retrace_since<InpCounterConfirmSeconds) return;

   double estimated_price=(side==ORDER_TYPE_BUY ? tick.ask : tick.bid), tp=0.0;
   if(!CounterTPPrice(side,estimated_price,InpCounterTakeProfitMoney,tp))
   { Print("HBv3.30 COUNTER BLOCKED: cannot calculate target price");return; }

   BasketState before;
   ScanBasket(before,true);
   // Persist 'once' BEFORE sending. If acknowledgment is lost, we MUST NOT
   // mistakenly open a duplicate counter after restart.
   g_counter_placed=true;
   GlobalVariableSet(g_counter_once_key,1.0);
   bool sent=(side==ORDER_TYPE_BUY ?
              trade.Buy(InpCounterLot,_Symbol,0.0,0.0,tp,"HB COUNTER BUY TP NO SL") :
              trade.Sell(InpCounterLot,_Symbol,0.0,0.0,tp,"HB COUNTER SELL TP NO SL"));
   bool accepted=Filled(sent);
   BasketState after;
   ScanBasket(after,true);
   int new_count=0;
   ulong new_id=0,new_ticket=0;
   for(int i=0;i<PositionsTotal();i++)
   {
      ulong ticket=PositionGetTicket(i);
      if(!IsOwnPosition(ticket)) continue;
      ulong id=(ulong)PositionGetInteger(POSITION_IDENTIFIER);
      if(IdentifierInBasket(before,id)) continue;
      new_id=id;
      new_ticket=ticket;
      new_count++;
   }
   // Only an unambiguously filled NEW position can be managed separately.
   if(!accepted || new_count!=1 || after.count!=before.count+1)
   {
      LogTradeError("COUNTER FILL / TRACKING");
      PauseForTechnicalAudit("cannot prove unique counter leg fill");
      return;
   }
   g_counter_id=new_id;
   GlobalVariableSet(g_counter_id_key,(double)new_id);
   if(!PositionSelectByTicket(new_ticket))
   {
      PauseForTechnicalAudit("counter ticket disappeared during initialization"); return;
   }
   double actual_open=PositionGetDouble(POSITION_PRICE_OPEN);
   double finalTP=0.0;
   if(CounterTPPrice(side,actual_open,InpCounterTakeProfitMoney,finalTP))
   {
      // Reconcile target with actual filled open price. Existing TP stays
      // available if broker rejects this improvement.
      double oldTP=PositionGetDouble(POSITION_TP);
      if(MathAbs(oldTP-finalTP)>=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE)*0.5)
      {
         if(!trade.PositionModify(new_ticket,PositionGetDouble(POSITION_SL),finalTP) ||
            trade.ResultRetcode()!=TRADE_RETCODE_DONE)
            PrintFormat("HBv3.30 counter TP fine-tune rejected, broker TP remains %.3f",oldTP);
      }
   }
   if(PositionSelectByTicket(new_ticket) && (PositionGetDouble(POSITION_SL)>0 ||
                                            PositionGetDouble(POSITION_TP)<=0))
   {
      PauseForTechnicalAudit("counter does not have valid TP attributes"); return;
   }
   PrintFormat("HBv3.30 COUNTER %s OPEN id=%I64u lot=%.2f TP=%.3f (no SL) advance=%.3f pullback=%.3f",
               side==ORDER_TYPE_BUY ? "BUY" : "SELL",new_id,InpCounterLot,
               (PositionSelectByTicket(new_ticket) ? PositionGetDouble(POSITION_TP) : tp),advance,retrace);
}

void UpdateCounterReversalExtreme(const MqlTick &tick)
{
   if(g_expected_positions<3 || g_counter_placed || g_grid_direction==0 ||
      g_counter_third_price<=0) return;
   double price=(g_grid_direction==1 ? tick.bid : tick.ask);
   if(g_counter_best<=0 || (g_grid_direction==1 && price>g_counter_best) ||
      (g_grid_direction==-1 && price<g_counter_best))
   {
      g_counter_best=price;
      GlobalVariableSet(g_counter_best_key,price);
      g_counter_retrace_since=0;
   }
}

// The follow order is sent only ONCE, after the counter position is fully
// closed at POSITIVE net profit. It shares the original one-way grid direction.
// Broker TP is independent. No SL is attached to the follow trade.
void OpenFollowAfterCounter()
{
   if(g_technical_pause || !InpEnableFollowAfterCounter || g_follow_once || !g_counter_placed ||
      g_counter_id==0 || g_grid_direction==0 || g_expected_positions<3 ||
      IsCounterPresent() || !CanTradeNow()) return;
   double booked=0.0; datetime closed_at=0;
   if(!ClosedPositionReport(g_counter_id,booked,closed_at) || booked<=0.0) return;
   if(TimeCurrent()-closed_at<InpFollowMinDelaySeconds) return;
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol,tick) || !SpreadOK(tick)) return;
   ENUM_ORDER_TYPE direction=(g_grid_direction==1 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL);
   if(!MarginOK(direction,1.0,InpFollowLot)) return;
   double estimated=(direction==ORDER_TYPE_BUY ? tick.ask : tick.bid);
   double tp=0.0;
   if(!CounterTPPrice(direction,estimated,InpFollowTakeProfitMoney,tp,InpFollowLot))
   { Print("HBv3.30 FOLLOW blocked: cannot calculate TP");return; }
   BasketState before;ScanBasket(before,true);
   // Persist attempt BEFORE submit. On ambiguous fill never send a duplicate.
   g_follow_once=true;
   GlobalVariableSet(g_follow_once_key,1.0);
   bool sent=(direction==ORDER_TYPE_BUY ?
      trade.Buy(InpFollowLot,_Symbol,0.0,0.0,tp,"HB FOLLOW BUY TP") :
      trade.Sell(InpFollowLot,_Symbol,0.0,0.0,tp,"HB FOLLOW SELL TP"));
   bool accepted=Filled(sent);
   BasketState after;ScanBasket(after,true);
   ulong id=0;
   bool unique=FindNewOwnedPositionId(before,id);
   if(!accepted || !unique || after.count!=before.count+1)
   {
      // Uncertain send result: fail safe. No automatic duplicate on restart.
      PrintFormat("HBv3.30 FOLLOW fill ambiguous accepted=%s new_position=%s",
                  accepted?"YES":"NO",unique?"YES":"NO");
      PauseForTechnicalAudit("follow order fill/identification failure");
      return;
   }
   g_follow_id=id;
   GlobalVariableSet(g_follow_id_key,(double)id);
   PrintFormat("HBv3.30 FOLLOW %s OPEN lot=%.2f after COUNTER net=%.2f (%s), TP=%.3f NO SL id=%I64u",
               g_grid_direction==1?"BUY":"SELL",InpFollowLot,booked,
               AccountInfoString(ACCOUNT_CURRENCY),tp,id);
}

// Include already-booked entry fees in each open position's net estimate.
// Future close fees and slippage cannot be known before broker execution.
double SelectedPositionNetBeforeExit()
{
   ulong id=(ulong)PositionGetInteger(POSITION_IDENTIFIER);
   double net=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
   if(id==0 || g_basket_start<=0) return net;
   if(!GHBHistorySelect(g_basket_start-5,TimeCurrent()+60)) return -1e99;
   for(int i=0;i<HistoryDealsTotal();i++)
   {
      ulong d=HistoryDealGetTicket(i);
      if(d==0 || (ulong)HistoryDealGetInteger(d,DEAL_POSITION_ID)!=id) continue;
      ENUM_DEAL_ENTRY e=(ENUM_DEAL_ENTRY)HistoryDealGetInteger(d,DEAL_ENTRY);
      if(e==DEAL_ENTRY_IN || e==DEAL_ENTRY_INOUT)
         net+=HistoryDealGetDouble(d,DEAL_COMMISSION)+HistoryDealGetDouble(d,DEAL_FEE);
   }
   return net;
}

// Closing two winning positions can expose a losing opposite seed or leave a
// locked zero-delta hedge. Keep positive directional volume on the same side
// after the pair is removed whenever any opposite positions remain.
// This is a risk/structure guard, not a profit guarantee.
bool SafeToCloseWinningPair(const ulong ticket_a,const ulong ticket_b,const long pair_side)
{
   if(!InpProtectPairRemainder) return true;
   double same_volume=0.0,opposite_volume=0.0;
   for(int i=0;i<PositionsTotal();i++)
   {
      ulong ticket=PositionGetTicket(i);
      if(!IsOwnPosition(ticket) || ticket==ticket_a || ticket==ticket_b) continue;
      double volume=PositionGetDouble(POSITION_VOLUME);
      if(PositionGetInteger(POSITION_TYPE)==pair_side) same_volume+=volume;
      else opposite_volume+=volume;
   }
   double epsilon=MathMax(1e-8,SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP)*0.10);
   if(opposite_volume>epsilon && same_volume<=opposite_volume+epsilon)
   {
      // Avoid flooding a VPS journal on every market tick.
      static datetime last_notice=0;
      datetime now=TimeCurrent();
      if(now-last_notice>=30)
      {
         last_notice=now;
         PrintFormat("HBv3.30 PAIR BLOCKED: removing two %s would leave remaining same=%.2f opposite=%.2f (naked/locked hedge)",
                     pair_side==POSITION_TYPE_BUY?"BUY":"SELL",same_volume,opposite_volume);
      }
      return false;
   }
   return true;
}

// CLOSE BOTH positions only if EACH is in profit. The minimum thresholds are
// positive native-account-currency amounts, to avoid near-zero spread churn.
// Pair closing is independent of basket TP; the remaining trades stay open.
void CloseProfitableSameSidePair()
{
   return; // individual target exits only; pair closure permanently disabled
}

// Close by individual ticket (never by symbol) in a hedging account.
// If any broker close fails, continue retrying on subsequent ticks.
void CloseAll(const string reason)
{
   // Hard backstop, including stale requests and startup rollback paths:
   // never close other tickets or cancel their orders because one trade exits.
   g_exit_in_progress=false;
   if(g_force_key!="") GlobalVariableDel(g_force_key);
   PauseForTechnicalAudit("BULK_EXIT_BLOCKED: "+reason);
}

// 0=not yet sent/filled, 1=verified full seed, -1=ambiguous/partial.
// Read entry history as well as live positions: a seed's independent TP may
// execute before the opposite send is confirmed. Do not reopen that seed.
int InitialSeedEvidence(const bool buy,ulong &id,double &price)
{
   id=0;price=0.0;
   string role=buy?"HB START BUY":"HB START SELL";
   if(!GHBHistorySelect(g_basket_start,TimeCurrent()+60)) return -1;
   double volume=0.0,weighted=0.0;
   for(int i=0;i<HistoryDealsTotal();i++)
   {
      ulong d=HistoryDealGetTicket(i);
      if(d==0 || HistoryDealGetString(d,DEAL_SYMBOL)!=_Symbol ||
         HistoryDealGetInteger(d,DEAL_MAGIC)!=InpMagic ||
         HistoryDealGetInteger(d,DEAL_ENTRY)!=DEAL_ENTRY_IN ||
         HistoryDealGetString(d,DEAL_COMMENT)!=role) continue;
      if(HistoryDealGetInteger(d,DEAL_TYPE)!=(buy?DEAL_TYPE_BUY:DEAL_TYPE_SELL)) return -1;
      ulong found=(ulong)HistoryDealGetInteger(d,DEAL_POSITION_ID);
      if(found==0 || (id!=0 && id!=found)) return -1;
      id=found;
      double v=HistoryDealGetDouble(d,DEAL_VOLUME);
      volume+=v;weighted+=v*HistoryDealGetDouble(d,DEAL_PRICE);
   }
   for(int p=0;p<PositionsTotal();p++)
   {
      ulong ticket=PositionGetTicket(p);
      if(!IsOwnPosition(ticket)) continue;
      // During incomplete initialization no grid or unrelated own role is allowed.
      string c=PositionGetString(POSITION_COMMENT);
      long side=PositionGetInteger(POSITION_TYPE);
      if((c!="HB START BUY" && c!="HB START SELL") ||
         (c=="HB START BUY" && side!=POSITION_TYPE_BUY) ||
         (c=="HB START SELL" && side!=POSITION_TYPE_SELL)) return -1;
      if(c!=role) continue;
      if(id==0 || (ulong)PositionGetInteger(POSITION_IDENTIFIER)!=id ||
         MathAbs(PositionGetDouble(POSITION_VOLUME)-InpSeedLot)>1e-7) return -1;
   }
   if(id==0) return 0;
   if(MathAbs(volume-InpSeedLot)>1e-7) return -1;
   price=weighted/volume;
   return price>0.0?1:-1;
}

void StartHedgeBasket()
{
   datetime now=TimeCurrent();
   g_last_seed_attempt=now;
   MqlTick q;
   if(!CanTradeNow() || HasOtherPositionsOnSymbol() || HasOtherPendingOrdersOnSymbol() ||
      !SymbolInfoTick(_Symbol,q) || !SpreadOK(q) || !EstimatedSeedCostOK(q)) return;
   if(g_basket_start<=0)
   {
      // v3.58: each new basket re-fits its size to the free margin of the moment
      if(InpAccountScaleMode==GHB_SCALE_AUTO && InpAutoFitToMargin && !HasOwnedExposure())
      {
         static double lastLogged=-1.0;
         double before=g_lot_scale;
         if(FitScaleToMargin(false) && MathAbs(g_lot_scale-lastLogged)>1e-12)
         {
            lastLogged=g_lot_scale;
            FitScaleToMargin(true);
         }
         if(MathAbs(before-g_lot_scale)>1e-12) g_grid_geometry_dirty=true;
      }
      if(!MarginOK(ORDER_TYPE_BUY,2.0,InpSeedLot) || !MarginOK(ORDER_TYPE_SELL,2.0,InpSeedLot))
      {EntryBlocked("SEED_PAIR_MARGIN_BLOCK");return;}
      g_basket_start=now;
      GlobalVariableSet(g_start_key,(double)now);
      SetExpectedPositions(0); // persisted incomplete pair; resume missing side only
      g_peak_net=-1e100;
      GlobalVariableDel(g_peak_key);
   }
   if(g_expected_positions!=0 || OwnedPendingCount()>0) return;
   double seedPrices[2];
   for(int side=0;side<2;side++)
   {
      bool buy=side==0;
      ulong id=0;double price=0.0;
      string key=g_start_key+(buy?".seedBuyRequest":".seedSellRequest");
      int evidence=InitialSeedEvidence(buy,id,price);
      if(evidence<0) {EntryBlocked("SEED_PAIR_WAIT: partial, duplicate or unsynchronized broker history");return;}
      if(evidence==0)
      {
         if(GlobalVariableCheck(key) && (datetime)GlobalVariableGet(key)==g_basket_start)
         {EntryBlocked("SEED_PAIR_WAIT: request outcome not confirmed; no duplicate send");return;}
         if(!MarginOK(buy?ORDER_TYPE_BUY:ORDER_TYPE_SELL,1.0,InpSeedLot)) return;
         if(!OpenOriginalHedge(buy?ORDER_TYPE_BUY:ORDER_TYPE_SELL,buy?"HB START BUY":"HB START SELL"))
         {EntryBlocked(buy?"SEED BUY pending retry/reconciliation":"SEED SELL pending retry/reconciliation");return;}
         evidence=InitialSeedEvidence(buy,id,price);
         if(evidence!=1) {EntryBlocked("SEED_PAIR_WAIT: fill sent, waiting for entry history");return;}
      }
      GlobalVariableDel(key);
      if(buy) {g_seed_buy_id=id;GlobalVariableSet(g_seed_buy_key,(double)id);}
      else {g_seed_sell_id=id;GlobalVariableSet(g_seed_sell_key,(double)id);}
      seedPrices[side]=price;
   }
   if(g_seed_buy_id==0 || g_seed_sell_id==0 || g_seed_buy_id==g_seed_sell_id) return;
   if(!TrackedPositionHealthy(g_seed_buy_id,true) || !TrackedPositionHealthy(g_seed_sell_id,true))
   {EntryBlocked("SEED_PAIR_WAIT: verify live seeds or their independent profitable exits");return;}
   ResumeAfterAudit();
   GHBEvent("Seed pair opened, 40+40 grid enabled"); g_st_seeds++;
   PrintFormat("HBv3.50 SEED PAIR VERIFIED | BUY id=%I64u SELL id=%I64u lots=2 each; enabling 40+40 grid, first=0.50 spacing=0.50 TP=50 for rungs 1..9, TP=100 for rungs 10..40",
               g_seed_buy_id,g_seed_sell_id);
   BasketState seeded;ScanBasket(seeded);
   GlobalVariableSet(g_seed_buy_key,(double)g_seed_buy_id);
   GlobalVariableSet(g_seed_sell_key,(double)g_seed_sell_id);
   ReconcileOriginalTakeProfit(g_seed_buy_id,ORDER_TYPE_BUY);
   ReconcileOriginalTakeProfit(g_seed_sell_id,ORDER_TYPE_SELL);
   for(int side=0;side<2;side++)
   {
      g_repeat_position[side]=(side==0 ? g_seed_buy_id : g_seed_sell_id);
      g_repeat_order[side]=0;
      g_repeat_armed_for[side]=0;
      g_repeat_last_tp[side]=0;
      g_repeat_attempt[side]=0;
      GlobalVariableSet(g_repeat_pos_key[side],(double)g_repeat_position[side]);
      GlobalVariableSet(g_repeat_order_key[side],0.0);
      GlobalVariableSet(g_repeat_armed_key[side],0.0);
      RefreshRepeatTPFromLive(side);
   }

   g_grid_direction=0;
   GlobalVariableSet(g_direction_key,0.0);
   g_counter_id=0;
   g_counter_placed=false;
   g_counter_best=0.0;
   g_counter_third_price=0.0;
   g_counter_third_time=0;
   g_counter_retrace_since=0;
   g_third_id=0;
   g_fourth_id=0;
   g_follow_id=0;
   g_follow_once=false;
   GlobalVariableDel(g_third_id_key);
   GlobalVariableDel(g_fourth_id_key);
   GlobalVariableDel(g_follow_id_key);
   GlobalVariableDel(g_follow_once_key);
   GlobalVariableDel(g_counter_id_key);
   GlobalVariableDel(g_counter_once_key);
   GlobalVariableDel(g_counter_best_key);
   GlobalVariableDel(g_counter_third_price_key);
   GlobalVariableDel(g_counter_third_time_key);
   SetExpectedPositions(2);
   g_last_add_attempt=now;
   PrintFormat("HEDGE BASKET initialized: BUY=%.2f SELL=%.2f",seeded.buy_volume,seeded.sell_volume);
   // Reference quotes for original 5+5 ladder are persistent across EA restarts.
   g_limit_seed_buy_price=seedPrices[0];
   g_limit_seed_sell_price=seedPrices[1];
   GlobalVariableSet(g_limit_seed_buy_key,g_limit_seed_buy_price);
   GlobalVariableSet(g_limit_seed_sell_key,g_limit_seed_sell_price);
   // Reserve the initial fifth tier as the first outer boundary even if the
   // broker initially rejects some pending placements due to margin/stops.
   // This avoids appending into a reserved/missing tier later.
   double finalOffset=GridFirstDistance()+(LIMIT_PER_SIDE-1)*GridSpacing();
   MqlTick initial;
   if(SymbolInfoTick(_Symbol,initial) && initial.ask>initial.bid && initial.bid>0)
      g_recenter_anchor_mid=(initial.ask+initial.bid)*0.5;
   else
      g_recenter_anchor_mid=(g_limit_seed_buy_price+g_limit_seed_sell_price)*0.5;
   // A NEW network also uses the current market MID rather than anchoring BUY
   // to the original ask and SELL to the original bid. Preserve original seed
   // reference prices above for the existing third/fourth trend logic.
   double anchorTick=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   g_recenter_anchor_mid=NormalizeDouble(MathRound(g_recenter_anchor_mid/anchorTick)*anchorTick,
                                       (int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS));
   double gridBuyBasis=g_recenter_anchor_mid;
   double gridSellBasis=g_recenter_anchor_mid;
   g_limit_outer_buy=gridBuyBasis-finalOffset;
   g_limit_outer_sell=gridSellBasis+finalOffset;
   g_recenter_last_time=now;
   GlobalVariableSet(g_recenter_anchor_key,g_recenter_anchor_mid);
   GlobalVariableSet(g_recenter_time_key,(double)g_recenter_last_time);
   GlobalVariableSet(g_limit_outer_buy_key,g_limit_outer_buy);
   GlobalVariableSet(g_limit_outer_sell_key,g_limit_outer_sell);
   PlaceSeedLimitOrders(gridBuyBasis,gridSellBasis);
   // Seed orders were verified as one BUY + one SELL. The fresh network is
   // now tracked by the existing magic/state; end the restart transition.
   g_flat_restart_pending=false;
   GlobalVariableDel(g_flat_restart_key);
   int gridBuy=0,gridSell=0;
   for(int k=0;k<LIMIT_SLOTS;k++)
   {
      if(!LimitOrderTicketOpen(g_limit_order[k])) continue;
      if(k<LIMIT_PER_SIDE) gridBuy++;
      else gridSell++;
   }
   PrintFormat("HBv3.30 NEW NETWORK STARTED | BUY=%.2f SELL=%.2f gridBUY=%d/40 gridSELL=%d/40; rungs 1..9 TP50 / 10..40 TP100 USC; recenter interval=%d minute",
               seeded.buy_volume,seeded.sell_volume,gridBuy,gridSell,GridRecenterMinutes());
}

bool ResumeIncompleteSeedPair()
{
   if(g_basket_start<=0 || g_expected_positions!=0) return false;
   if(OwnedPendingCount()>0)
   {EntryBlocked("INCOMPLETE_SEED_WITH_PENDING: broker audit required");return true;}
   if(g_last_seed_attempt==0 || TimeCurrent()-g_last_seed_attempt>=InpMinSecondsBetweenSeedAttempts)
      StartHedgeBasket();
   return true;
}

// v3.58: derive every lot/money value from g_lot_scale and g_money_scale.
void ApplyScale()
{
   InpSeedLot=ScaledLot(2.00);
   InpFixedLot=ScaledLot(2.00);
   InpCounterLot=ScaledLot(InpCounterLotDesign);
   InpFollowLot=ScaledLot(InpFollowLotDesign);
   InpCoolingFirstLot=ScaledLot(InpCoolingFirstLotDesign);
   InpCoolingLotStep=InpCoolingLotStepDesign*g_lot_scale;
   InpCoolingMaxLot=ScaledLot(InpCoolingMaxLotDesign);
   InpSeedTakeProfitMoney=ScaledMoney(50.00);
   InpRepeatTakeProfitMoney=ScaledMoney(50.00);
   InpTrendTakeProfitMoney=ScaledMoney(50.00);
   InpCounterTakeProfitMoney=ScaledMoney(50.00);
   InpFollowTakeProfitMoney=ScaledMoney(50.00);
   InpCoolingTakeProfitUSC=ScaledMoney(100.00);
   InpCoolingLossStepUSC=ScaledMoney(InpCoolingLossStepDesign);
}

double g_detect_lot_scale=1.0, g_detect_money_scale=1.0; // full-size values from AUTO detect

string FitKey()
{
   return StringFormat("GHB.FIT.%I64d.%s.%I64d",AccountInfoInteger(ACCOUNT_LOGIN),_Symbol,(long)InpMagic);
}

bool HasOwnedExposure()
{
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong t=PositionGetTicket(i);
      if(t!=0 && PositionSelectByTicket(t) && PositionGetString(POSITION_SYMBOL)==_Symbol &&
         PositionGetInteger(POSITION_MAGIC)==InpMagic) return true;
   }
   for(int i=OrdersTotal()-1;i>=0;i--)
   {
      ulong t=OrderGetTicket(i);
      if(t!=0 && OrderSelect(t) && OrderGetString(ORDER_SYMBOL)==_Symbol &&
         OrderGetInteger(ORDER_MAGIC)==InpMagic) return true;
   }
   return false;
}

// Largest size (full, 1/2, 1/5, 1/10 ... 1/100 of full) whose seed margin check
// plus rungs 1..10 of ONE side fit inside the free-margin budget. Ratios, spacing,
// TP distances and every rule stay identical; only the size shrinks.
bool FitScaleToMargin(const bool log_it)
{
   double minlot=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double step=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   MqlTick t;
   double perLot=0.0;
   if(!SymbolInfoTick(_Symbol,t) || t.ask<=0.0 ||
      !OrderCalcMargin(ORDER_TYPE_BUY,_Symbol,1.0,t.ask,perLot) || perLot<=0.0) return false;
   double budget=AccountInfoDouble(ACCOUNT_MARGIN_FREE)*MathMax(0.05,MathMin(1.0,InpAutoFitUseFreeMargin));
   double ratio=g_detect_money_scale/g_detect_lot_scale;
   double fr[7]={1.0,0.5,0.2,0.1,0.05,0.02,0.01};
   double chosen=-1.0,smallest=-1.0,need=0.0;
   for(int i=0;i<7;i++)
   {
      double sc=g_detect_lot_scale*fr[i];
      double unit=sc; // design lot 1.00 at this size
      if(unit<minlot-1e-9) continue;
      if(step>0.0 && MathAbs(unit/step-MathRound(unit/step))>1e-6) continue;
      smallest=sc;
      double seedNeed=perLot*(2.0*sc)*2.0*InpMinFreeMarginFactor; // two legs x safety factor
      double gridNeed=perLot*(55.0*sc);                          // rungs 1..10 one side
      if(seedNeed+gridNeed<=budget) {chosen=sc;need=seedNeed+gridNeed;break;}
   }
   bool fits=(chosen>0.0);
   if(!fits) chosen=smallest;
   if(chosen<=0.0) return false;
   g_lot_scale=chosen;
   g_money_scale=chosen*ratio;
   ApplyScale();
   GlobalVariableSet(FitKey(),g_lot_scale);
   if(log_it)
      PrintFormat("HBv3.58 AUTO-FIT | free=%.2f budget=%.2f marginPerLot=%.2f -> size=%.0f%% of full (lotScale=%.4f) seed=%.2f grid=%.2f..%.2f TP=%.2f %s%s",
                  AccountInfoDouble(ACCOUNT_MARGIN_FREE),budget,perLot,100.0*chosen/g_detect_lot_scale,
                  g_lot_scale,InpSeedLot,ScaledLot(1.0),ScaledLot(10.0),InpSeedTakeProfitMoney,
                  AccountInfoString(ACCOUNT_CURRENCY),fits?"":" | even smallest size exceeds budget: margin guard will wait");
   return true;
}

int OnInit()
{
   g_tester=(MQLInfoInteger(MQL_TESTER)!=0 || MQLInfoInteger(MQL_OPTIMIZATION)!=0);
   g_visual=(!g_tester || MQLInfoInteger(MQL_VISUAL_MODE)!=0);
   ArrayInitialize(g_st_stage_secs,0); ArrayInitialize(g_st_stage_hits,0);
   if(g_tester) Print("HBv3.65 TESTER MODE | async/cache/throttle off for exact simulation; dashboard only in visual mode");
   if((ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE)
      !=ACCOUNT_MARGIN_MODE_RETAIL_HEDGING || !AccountInfoInteger(ACCOUNT_HEDGE_ALLOWED))
   {
      Print("ERROR: This EA requires an MT5 HEDGING account allowing opposing positions.");
      return INIT_FAILED;
   }
   // v3.54: resolve account scale BEFORE any validation or state restore.
   {
      string cur=AccountInfoString(ACCOUNT_CURRENCY);
      if(InpAccountScaleMode==GHB_SCALE_CENT) {g_lot_scale=1.0;g_money_scale=1.0;}
      else if(InpAccountScaleMode==GHB_SCALE_STANDARD) {g_lot_scale=0.01;g_money_scale=0.01;}
      else if(InpAccountScaleMode==GHB_SCALE_CUSTOM) {g_lot_scale=InpCustomLotScale;g_money_scale=InpCustomMoneyScale;}
      else
      {
         string detail="";
         bool ok=false;
         for(int attempt=0;attempt<20 && !ok;attempt++)
         {
            ok=DetectAccountScale(g_lot_scale,g_money_scale,detail);
            if(!ok) Sleep(250);
         }
         if(!ok)
         {
            PrintFormat("HBv3.56 AUTO SCALE FAILED | %s; reload the EA once quotes are live",detail);
            return INIT_FAILED;
         }
         PrintFormat("HBv3.56 AUTO DETECT | %s -> lotScale=%.4f moneyScale=%.4f",detail,g_lot_scale,g_money_scale);
         g_detect_lot_scale=g_lot_scale;
         g_detect_money_scale=g_money_scale;
         if(InpAutoFitToMargin)
         {
            if(HasOwnedExposure() && GlobalVariableCheck(FitKey()))
            {
               // live basket: keep the size its orders were built with
               double kept=GlobalVariableGet(FitKey());
               if(kept>0.0)
               {
                  g_money_scale=kept*(g_detect_money_scale/g_detect_lot_scale);
                  g_lot_scale=kept;
                  PrintFormat("HBv3.58 AUTO-FIT RESTORED | live basket keeps lotScale=%.4f",g_lot_scale);
               }
            }
            else if(HasOwnedExposure())
               PrintFormat("HBv3.58 AUTO-FIT SKIPPED | live basket from older version keeps full detected lotScale=%.4f",g_lot_scale);
            else
               FitScaleToMargin(true);
         }
      }
      UpdateCommissionEstimate(true);
      if(g_lot_scale<=0.0 || g_money_scale<=0.0)
      {
         Print("HBv3.54 INIT BLOCK: account scale factors must be positive");
         return INIT_PARAMETERS_INCORRECT;
      }
      ApplyScale();
      PrintFormat("HBv3.54 ACCOUNT SCALE | currency=%s mode=%s lotScale=%.4f moneyScale=%.4f | seed=%.2f grid=%.2f..%.2f counter=%.2f follow=%.2f cooling=%.2f..%.2f | TP seed/grid=%.2f grid10+=%.2f cooling=%.2f %s",
                  cur,EnumToString(InpAccountScaleMode),g_lot_scale,g_money_scale,
                  InpSeedLot,ScaledLot(1.0),ScaledLot(10.0),InpCounterLot,InpFollowLot,
                  InpCoolingFirstLot,InpCoolingMaxLot,InpSeedTakeProfitMoney,ScaledMoney(100.0),
                  InpCoolingTakeProfitUSC,cur);
      if(MathAbs(InpCounterLot-InpCounterLotDesign*g_lot_scale)>1e-9 ||
         MathAbs(InpFollowLot-InpFollowLotDesign*g_lot_scale)>1e-9)
         PrintFormat("HBv3.54 NOTE | counter/follow design lots %.4f/%.4f are below broker step; rounded to %.2f/%.2f",
                     InpCounterLotDesign*g_lot_scale,InpFollowLotDesign*g_lot_scale,InpCounterLot,InpFollowLot);
   }
   // v3.26 stored SELL tier tickets in slots 10..19. v3.27 uses those slots
   // for BUY tiers 11..20. An old .set Magic would corrupt interpretation.
   if(InpVirtualGridSideCap<1 || InpVirtualGridSideCap>LIMIT_PER_SIDE ||
      InpVirtualGridMaxCancelPerPass<1 || InpVirtualGridMaxCancelPerPass>LIMIT_SLOTS ||
      InpOppositeGuardTriggerPositions<1 || InpOppositeGuardDistanceUSC<=0.0)
   {
      Print("HBv3.40 invalid virtual grid / opposite-distance inputs");
      return INIT_PARAMETERS_INCORRECT;
   }
   if(InpMagic!=26101344)
   {
      Print("HBv3.30 INIT BLOCK: 80-slot state requires new Magic 26101344. Do not load old .set Magic numbers.");
      return INIT_PARAMETERS_INCORRECT;
   }
   double gridTick=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   if(gridTick<=0 || MathAbs(0.50/gridTick-MathRound(0.50/gridTick))>1e-7)
   {
      Print("HBv3.44 INIT BLOCK: broker price tick cannot represent exact 0.50 grid spacing");
      return INIT_PARAMETERS_INCORRECT;
   }
   long pendingLimit=AccountInfoInteger(ACCOUNT_LIMIT_ORDERS);
   if(pendingLimit>0 && pendingLimit<LIMIT_SLOTS)
   {
      PrintFormat("HBv3.44 INIT BLOCK: broker permits only %d pending orders, required=80",(int)pendingLimit);
      return INIT_PARAMETERS_INCORRECT;
   }
   // Previous GHB versions may leave broker-side orders in place even after
   // detaching their EA. Report them, remain attached and wait safely.
   // OnTick/OnTimer repeat this guard until the symbol is clean.
   if(WaitForCleanSymbol())
      Print("HBv3.30 STARTUP WAIT | EA remains on chart; no new positions or pending orders while an older Magic is present");
   if(InpTakeoverCancelLegacyPendings || InpTakeoverUpdateLegacyLiveTP || InpAllowParallelMagic)
   {
      Print("HBv3.30 INIT BLOCK: legacy takeover / parallel Magic must remain OFF in this clean-start migration.");
      return INIT_PARAMETERS_INCORRECT;
   }
   if(InpVerifiedLegacyGridMagic!=26100914 || InpLegacyMigrationIntervalSeconds<3)
   {
      Print("HBv3.30 INIT BLOCK: migration only recognizes verified old Magic 26100914 and interval >= 3 seconds");
      return INIT_PARAMETERS_INCORRECT;
   }
   if(InpTakeoverOldMagicMin<1 || InpTakeoverOldMagicMax<InpTakeoverOldMagicMin ||
      InpTakeoverActionsPerPass<1 || InpTakeoverActionsPerPass>10)
   {
      Print("HBv3.30 invalid legacy takeover settings");
      return INIT_PARAMETERS_INCORRECT;
   }
   if(GridMinimumMove()<0 || GridRecenterMinutes()<1 || InpRecenterRetrySeconds<1 ||
      InpLotUpgradeIntervalSeconds<10 || InpFlatConfirmSeconds<2 ||
      InpFlatRestartCooldownSeconds<0)
   {
      Print("HBv3.30 invalid timed recenter settings");
      return INIT_PARAMETERS_INCORRECT;
   }
   if((InpEnableBrokerLimits && (InpLimitBaseLot<=0 || InpLimitIntermediateBaseLot<=0 || GridFirstDistance()<=0 ||
      GridSpacing()<=0)) || InpLimitExpiryMinutes<0 || InpLimitRefillRetrySeconds<1 ||
      InpMaxActiveLimitPositions<1 || InpMaxActiveLimitPositions>LIMIT_SLOTS ||
      InpMinimumRefillCycles<10 ||
      InpSeedTakeProfitMoney<=0 || InpRepeatTakeProfitMoney<=0 || InpTrendTakeProfitMoney<=0 ||
      InpRepeatDistancePrice<=0 || InpRepeatRetrySeconds<1 || InpFixedLot<=0 || InpCounterLot<=0 || InpFollowLot<=0 || InpFollowTakeProfitMoney<=0 ||
      InpPairMinEachMoney<=0 || InpPairMinTotalMoney<2.0*InpPairMinEachMoney ||
      InpFollowMinDelaySeconds<0 || InpGridStepPrice<=0 || InpFourthStepPrice<=0 || InpMaxPositionsPerSide!=3 ||
      InpMaxPositionsPerSide>20 || InpBasketTakeProfit<=0 ||  InpMaxBasketMinutes<0 || InpCooldownSeconds<0 ||
      InpMinSecondsBetweenAdds<0 || InpMinSecondsBetweenSeedAttempts<1 ||
      InpDeviationPoints<0 || InpMaxSpreadPrice<0 || InpPrintStatusEverySeconds<0 || InpEntryDiagnosticsSeconds<0 || InpMagic<=0 ||
      InpExitCostReserve<0 || InpReversalExitPrice<=0 ||
      InpProfitLockArm<=0 || InpProfitLockGiveback<=0 ||
      InpMaxSeedSpreadCost<=0 || InpMinFreeMarginFactor<1.0 ||
      InpNoNewOrderBelowMarginLevel<100.0 || InpCounterTakeProfitMoney<=0 || InpCounterWaitSeconds<0 ||
      InpCounterMinAdvancePrice<0 || InpCounterRetracePrice<=0 ||
      InpCounterConfirmSeconds<0 ||
      InpCoolingStartLossUSC<=0 || InpCoolingLossStepUSC<=0 || InpCoolingStartPositions<1 ||
      InpCoolingFirstLot<=0 || InpCoolingLotStep<0 || InpCoolingMaxLot<InpCoolingFirstLot ||
      InpCoolingTakeProfitUSC<=0 || InpCoolingMinSecondsBetweenTrades<1 ||
      InpCoolingMaxOpenTrades<1 || InpCoolingMaxOpenTrades>20 || InpCoolingMinMarginLevel<100.0)
   {
      Print("ERROR: Invalid input settings."); return INIT_PARAMETERS_INCORRECT;
   }
   double minlot=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double maxlot=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
   double step=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   if(step<=0 || InpFixedLot<minlot-1e-8 || InpFixedLot>maxlot+1e-8 ||
      MathAbs(InpFixedLot/step-MathRound(InpFixedLot/step))>1e-6)
   {
      PrintFormat("ERROR: lot %.3f is incompatible with symbol volume min=%.3f max=%.3f step=%.3f",
                  InpFixedLot,minlot,maxlot,step);
      return INIT_PARAMETERS_INCORRECT;
   }
   if(InpSeedLot<minlot-1e-8 || InpSeedLot>maxlot+1e-8 ||
      MathAbs(InpSeedLot/step-MathRound(InpSeedLot/step))>1e-6)
   {
      PrintFormat("HBv3.45 INIT ERROR: broker does not accept seed volume %.2f lots",InpSeedLot);
      return INIT_PARAMETERS_INCORRECT;
   }
   if(InpCounterLot<minlot-1e-8 || InpCounterLot>maxlot+1e-8 ||
      MathAbs(InpCounterLot/step-MathRound(InpCounterLot/step))>1e-6)
   {
      PrintFormat("ERROR: counter lot %.3f incompatible with min=%.3f max=%.3f step=%.3f",
                  InpCounterLot,minlot,maxlot,step);
      return INIT_PARAMETERS_INCORRECT;
   }
   if(InpFollowLot<minlot-1e-8 || InpFollowLot>maxlot+1e-8 ||
      MathAbs(InpFollowLot/step-MathRound(InpFollowLot/step))>1e-6)
   {
      PrintFormat("ERROR: follow lot %.3f incompatible with min %.3f max %.3f step %.3f",
                  InpFollowLot,minlot,maxlot,step);
      return INIT_PARAMETERS_INCORRECT;
   }
   if(InpEnableBrokerLimits)
   {
      if(GridSpacing()<=0 || GridFirstDistance()<=0)
      {
         Print("HBv3.30 invalid grid spacing / first offset");
         return INIT_PARAMETERS_INCORRECT;
      }
      for(int level=0;level<LIMIT_PER_SIDE;level++)
      {
         double lot=LimitLotForSlot(level);
         if(LimitTargetForSlot(level)<=0.0)
         {
            PrintFormat("HBv3.30 INIT ERROR: grid rung=%d requires positive gross TP target",level+1);
            return INIT_PARAMETERS_INCORRECT;
         }
         if(lot<minlot-1e-8 || lot>maxlot+1e-8 ||
            MathAbs(lot/step-MathRound(lot/step))>1e-6)
         {
            PrintFormat("HBv3.30 INIT ERROR: LIMIT level=%d lot=%.2f violates symbol min=%.2f max=%.2f step=%.2f",level+1,lot,minlot,maxlot,step);
            return INIT_PARAMETERS_INCORRECT;
         }
      }
   }
   string key="GHBv344."+IntegerToString((long)AccountInfoInteger(ACCOUNT_LOGIN))+"."+_Symbol+"."+IntegerToString(InpMagic);
   g_limit_filled_prefix=key+".LF.";
   g_cooling_buy_stage_key=key+".coolCountBuyStage";
   g_cooling_sell_stage_key=key+".coolCountSellStage";
   g_cooling_last_time_key=key+".coolLastOpen";
   if(GlobalVariableCheck(g_cooling_last_time_key)) g_cooling_last_open_time=(datetime)GlobalVariableGet(g_cooling_last_time_key);
   g_legacy_tier_hold_prefix=key+".oldRungHold.";
   g_tp_deal_seen_prefix=key+".TPdeal.";
   g_flat_restart_key=key+".flat_reseed";
   if(GlobalVariableCheck(g_flat_restart_key))
      g_flat_restart_pending=(GlobalVariableGet(g_flat_restart_key)>0.5);
   g_exit_key=key+".exit";
   g_start_key=key+".start";
   g_stage_key=key+".stage";
   g_peak_key=key+".peak";
   g_force_key=key+".force";
   g_seed_buy_key=key+".seedbuy";
   g_seed_sell_key=key+".seedsell";
   g_direction_key=key+".direction";
   g_counter_id_key=key+".counterid";
   g_counter_once_key=key+".counteronce";
   g_counter_best_key=key+".counterbest";
   g_counter_third_price_key=key+".thirdprice";
   g_counter_third_time_key=key+".thirdtime";
   g_third_id_key=key+".thirdid";
   g_fourth_id_key=key+".fourthid";
   g_follow_id_key=key+".followid";
   g_follow_once_key=key+".followonce";
   g_limit_seed_buy_key=key+".seed_limit_buy_price";
   g_limit_seed_sell_key=key+".seed_limit_sell_price";
   g_limit_outer_buy_key=key+".outer_buy";
   g_limit_outer_sell_key=key+".outer_sell";
   g_recenter_anchor_key=key+".recenter_mid";
   g_recenter_time_key=key+".recenter_time";
   for(int side=0;side<2;side++)
   {
      string suffix=(side==0?"buy":"sell");
      g_repeat_pos_key[side]=key+".repeat_pos_"+suffix;
      g_repeat_order_key[side]=key+".repeat_order_"+suffix;
      g_repeat_armed_key[side]=key+".repeat_armed_"+suffix;
      g_repeat_tp_key[side]=key+".repeat_tp_"+suffix;
      g_repeat_position[side]=GlobalVariableCheck(g_repeat_pos_key[side])?
         (ulong)GlobalVariableGet(g_repeat_pos_key[side]):0;
      g_repeat_order[side]=GlobalVariableCheck(g_repeat_order_key[side])?
         (ulong)GlobalVariableGet(g_repeat_order_key[side]):0;
      g_repeat_armed_for[side]=GlobalVariableCheck(g_repeat_armed_key[side])?
         (ulong)GlobalVariableGet(g_repeat_armed_key[side]):0;
      g_repeat_last_tp[side]=GlobalVariableCheck(g_repeat_tp_key[side])?
         GlobalVariableGet(g_repeat_tp_key[side]):0.0;
   }

   if(GlobalVariableCheck(g_limit_seed_buy_key)) g_limit_seed_buy_price=GlobalVariableGet(g_limit_seed_buy_key);
   if(GlobalVariableCheck(g_limit_seed_sell_key)) g_limit_seed_sell_price=GlobalVariableGet(g_limit_seed_sell_key);
   if(GlobalVariableCheck(g_limit_outer_buy_key)) g_limit_outer_buy=GlobalVariableGet(g_limit_outer_buy_key);
   if(GlobalVariableCheck(g_limit_outer_sell_key)) g_limit_outer_sell=GlobalVariableGet(g_limit_outer_sell_key);
   if(GlobalVariableCheck(g_recenter_anchor_key)) g_recenter_anchor_mid=GlobalVariableGet(g_recenter_anchor_key);
   if(GlobalVariableCheck(g_recenter_time_key)) g_recenter_last_time=(datetime)GlobalVariableGet(g_recenter_time_key);
   // Fail closed (no new orders) on lost outer-edge state, rather than risk
   // creating a duplicate in the middle of an active broker-side ladder.
   for(int k=0;k<LIMIT_SLOTS;k++)
   {
      g_limit_order_key[k]=key+".limitorder"+IntegerToString(k);
      g_limit_position_key[k]=key+".limitposition"+IntegerToString(k);
      g_limit_refill_cycle_key[k]=key+".refillcycles"+IntegerToString(k);
      g_limit_tp_cycle_key[k]=key+".tpcycles"+IntegerToString(k);
      g_limit_refill_cycles[k]=(GlobalVariableCheck(g_limit_refill_cycle_key[k])?
         (int)GlobalVariableGet(g_limit_refill_cycle_key[k]):0);
      g_limit_tp_cycles[k]=(GlobalVariableCheck(g_limit_tp_cycle_key[k])?
         (int)GlobalVariableGet(g_limit_tp_cycle_key[k]):0);
      g_limit_order[k]=(GlobalVariableCheck(g_limit_order_key[k])?
         (ulong)GlobalVariableGet(g_limit_order_key[k]):0);
      g_limit_position[k]=(GlobalVariableCheck(g_limit_position_key[k])?
         (ulong)GlobalVariableGet(g_limit_position_key[k]):0);
   }
   if(GlobalVariableCheck(g_exit_key)) g_last_exit_time=(datetime)GlobalVariableGet(g_exit_key);
   if(GlobalVariableCheck(g_start_key)) g_basket_start=(datetime)GlobalVariableGet(g_start_key);
   if(GlobalVariableCheck(g_stage_key)) g_expected_positions=(int)GlobalVariableGet(g_stage_key);
   if(GlobalVariableCheck(g_peak_key)) g_peak_net=GlobalVariableGet(g_peak_key);
   // Do not resume a liquidation request left by an older version.
   g_exit_in_progress=false;
   if(GlobalVariableCheck(g_force_key))
   {
      GlobalVariableDel(g_force_key);
      Print("HBv3.43 OLD BULK EXIT CLEARED | individual ticket targets only");
   }
   if(GlobalVariableCheck(g_seed_buy_key)) g_seed_buy_id=(ulong)GlobalVariableGet(g_seed_buy_key);
   if(GlobalVariableCheck(g_seed_sell_key)) g_seed_sell_id=(ulong)GlobalVariableGet(g_seed_sell_key);
   if(GlobalVariableCheck(g_direction_key)) g_grid_direction=(int)GlobalVariableGet(g_direction_key);
   if(GlobalVariableCheck(g_counter_id_key)) g_counter_id=(ulong)GlobalVariableGet(g_counter_id_key);
   if(GlobalVariableCheck(g_counter_once_key)) g_counter_placed=GlobalVariableGet(g_counter_once_key)>0.5;
   if(GlobalVariableCheck(g_counter_best_key)) g_counter_best=GlobalVariableGet(g_counter_best_key);
   if(GlobalVariableCheck(g_counter_third_price_key)) g_counter_third_price=GlobalVariableGet(g_counter_third_price_key);
   if(GlobalVariableCheck(g_counter_third_time_key)) g_counter_third_time=(datetime)GlobalVariableGet(g_counter_third_time_key);
   if(GlobalVariableCheck(g_third_id_key)) g_third_id=(ulong)GlobalVariableGet(g_third_id_key);
   if(GlobalVariableCheck(g_fourth_id_key)) g_fourth_id=(ulong)GlobalVariableGet(g_fourth_id_key);
   if(GlobalVariableCheck(g_follow_id_key)) g_follow_id=(ulong)GlobalVariableGet(g_follow_id_key);
   if(GlobalVariableCheck(g_follow_once_key)) g_follow_once=(GlobalVariableGet(g_follow_once_key)>0.5);
   if(g_basket_start>0)
   {
      g_had_positions=true;
      if(g_repeat_position[0]==0 && g_seed_buy_id>0) g_repeat_position[0]=g_seed_buy_id;
      if(g_repeat_position[1]==0 && g_seed_sell_id>0) g_repeat_position[1]=g_seed_sell_id;
   }
   RestoreFilledLimitLedger();
   // Persist only ladder geometry. A new spacing schedule needs an immediate
   // broker-side review of the EXISTING verified pending tickets, not new trades.
   string firstKey=key+".geometry_first";
   string spacingKey=key+".geometry_spacing";
   bool geometryChanged=(!GlobalVariableCheck(firstKey) || !GlobalVariableCheck(spacingKey) ||
      MathAbs(GlobalVariableGet(firstKey)-GridFirstDistance())>1e-7 ||
      MathAbs(GlobalVariableGet(spacingKey)-GridSpacing())>1e-7);
   if(geometryChanged && g_basket_start>0 && g_recenter_anchor_mid>0 && g_recenter_last_time>0)
   {
      datetime clock=TimeTradeServer();
      if(clock<=0) clock=TimeCurrent();
      g_recenter_last_time=clock-GridRecenterMinutes()*60;
      GlobalVariableSet(g_recenter_time_key,(double)g_recenter_last_time);
      PrintFormat("HBv3.30 GEOMETRY CHANGE | first=%.2f step=%.2f recenter due now; existing live positions untouched",
                  GridFirstDistance(),GridSpacing());
   }
   GlobalVariableSet(firstKey,GridFirstDistance());
   GlobalVariableSet(spacingKey,GridSpacing());
   PrintFormat("HBv3.30 RESTORE | start=%s stage=%d seedBUY=%I64u seedSELL=%I64u pendings=%d filledLedger=%d",
               TimeToString(g_basket_start),g_expected_positions,g_seed_buy_id,g_seed_sell_id,
               OwnedLimitPendingCount(),ArraySize(g_limit_filled_ids));
   if(g_basket_start>0 && (g_limit_outer_buy<=0 || g_limit_outer_sell<=0))
      Print("HBv3.30 ROLLING OUTER EDGE STATE MISSING: new activation refills will pause rather than guess prices");
   PrintFormat("HBv3.30 PARALLEL MAGIC MODE | enabled=%s | this EA owns Magic=%I64d only; older GHB orders and positions are NOT touched; clean-symbol start required; other Magic/manual remain unmanaged; NO SL: serious margin risk",
               InpAllowParallelMagic?"YES":"NO",InpMagic);
   trade.SetExpertMagicNumber((ulong)InpMagic);
   trade.SetDeviationInPoints((ulong)InpDeviationPoints);
   trade.SetAsyncMode(false);
   trade.SetTypeFillingBySymbol(_Symbol);
   PrintFormat("HBv3.30 VERIFIED OLD-PENDING MIGRATION | enabled=%s oldMagic=%I64d every=%dsec; requires ALL positions on symbol closed AND old EA stopped; only verified v3.26 LIMIT/repeat pending; never a live position or unknown order",
               InpPermitFlatLegacyPendingMigration?"YES":"NO",InpVerifiedLegacyGridMagic,InpLegacyMigrationIntervalSeconds);
   PrintFormat("HBv3.30 CYCLE MODE | restartWhenFlat=%s confirm=%dsec restartCooldown=%dsec cleanSymbol=%s; old pending canceled+verified before NEW BUY+SELL hedge and grid",
               InpAutoRestartFlatBasket?"YES":"NO",InpFlatConfirmSeconds,
               InpFlatRestartCooldownSeconds,InpFlatRestartRequireCleanSymbol?"YES":"NO");
   PrintFormat("HBv3.31 READY | %s account=%s | CORE=%.2f COUNTER=%.2f FOLLOW=%.2f | cooling=%s unusedLegacyLoss=%.2f fixedGapLossOnFirstLot=%.2f lot=%.2f..%.2f TP=%.2f USC; v3.30 grid and state preserved",
               _Symbol,AccountInfoString(ACCOUNT_CURRENCY),InpFixedLot,InpCounterLot,InpFollowLot,
               InpEnableSideLossCooling?"ON":"OFF",InpCoolingStartLossUSC,InpCoolingLossStepUSC,
               InpCoolingFirstLot,InpCoolingMaxLot,InpCoolingTakeProfitUSC);
   PrintFormat("HBv3.30 RULES: follow after profitable counter %s lot=%.2f TP=%.2f; pair exits %s each>=%.2f total>=%.2f account currency",
               InpEnableFollowAfterCounter?"ON":"OFF",InpFollowLot,InpFollowTakeProfitMoney,
               InpEnableProfitablePairs?"ON":"OFF",InpPairMinEachMoney,InpPairMinTotalMoney);
   Print("HBv3.30 MIGRATION | NEW Magic/GHBv327 state. Previous v3.26 tickets are NOT imported; optional one-at-a-time cancellation of strictly verified old pendings can be enabled explicitly when symbol is flat. Never close positions to migrate. New pending lots 0.01..10.00. Live positions never resized; verified current-Magic live TP is reconciled to configured targets; other Magic remains untouched by default. Never run prior EAs concurrently.");
   PrintFormat("HBv3.30 LOT MIGRATION | upgradeExistingPendings=%s one each >=%d seconds; MT5 pending LOT cannot be modified in-place; broker cancellation MUST be acknowledged",
               InpUpgradeExistingGridPendings?"YES":"NO",InpLotUpgradeIntervalSeconds);
   PrintFormat("HBv3.30 TARGET POLICY | original seed BUY=%.2f SELL=%.2f USC; repeats=%.2f additional legs remain 50; LIMIT per-level target 10..100 USC; basket profit close remains %s; pair routine remains %s",
               InpSeedTakeProfitMoney,InpSeedTakeProfitMoney,InpRepeatTakeProfitMoney,
               InpCloseWholeOnProfit?"ON":"OFF",InpEnableProfitablePairs?"ON":"OFF");
   PrintFormat("HBv3.30 ORIGINAL TARGETS | each original BUY and SELL has independent broker TP %.2f %s; closing one does NOT close the other",
               InpSeedTakeProfitMoney,AccountInfoString(ACCOUNT_CURRENCY));
   PrintFormat("HBv3.30 TREND TARGETS | third/fourth each own broker TP %.2f %s; other orders unaffected",
               InpTrendTakeProfitMoney,AccountInfoString(ACCOUNT_CURRENCY));
   Print("HBv3.30 SAFETY | Original seed BUY and SELL are excluded from pair TP; technical inconsistencies PAUSE entry instead of liquidating. NO LOSS STOP: margin closeout risk remains.");
   PrintFormat("HBv3.30 INDIVIDUAL TARGET POLICY | enabled=%s pairsEffective=%s basketProfitCloseEffective=%s; non-seed monitored per position (gross USC), original BUY/SELL broker TP %.2f USC; no stop loss",
               InpIndividualTPOnly?"YES":"NO",(InpEnableProfitablePairs && !InpIndividualTPOnly)?"ON":"OFF",
               (InpCloseWholeOnProfit && !InpIndividualTPOnly)?"ON":"OFF",InpSeedTakeProfitMoney);
   PrintFormat("HBv3.30 LIMIT RULES | BUY40/SELL40 firstOffset=%.2f step=%.2f BUY TP=%.2f SELL TP=%.2f USC; lot progression 1 through 40; new isolated Magic/state, no legacy takeover; upgradeOldPendingLots=%s",
               GridFirstDistance(),GridSpacing(),LimitTargetForSlot(0),LimitTargetForSlot(LIMIT_PER_SIDE),
               InpUpgradeExistingGridPendings?"YES":"NO");
   for(int k=0;k<LIMIT_PER_SIDE;k++)
      PrintFormat("HBv3.30 LIMIT LEVEL %d | distance=%.2f | lot=%.2f | TPprofit=%.2f %s",
                  k+1,GridFirstDistance()+k*GridSpacing(),
                  LimitLotForSlot(k),LimitTargetForSlot(k),AccountInfoString(ACCOUNT_CURRENCY));
   PrintFormat("HBv3.30 ORIGINAL REPEAT | enabled=%s BUY LIMIT at previous BUY TP - %.2f; SELL LIMIT at previous SELL TP + %.2f | lot=%.2f each target=%.2f %s",
               InpRepeatOriginalOnTP?"YES":"NO",InpRepeatDistancePrice,InpRepeatDistancePrice,
               InpFixedLot,InpRepeatTakeProfitMoney,AccountInfoString(ACCOUNT_CURRENCY));
   PrintFormat("HBv3.30 REPEAT MODE | CONTINUOUS 80-tier network; refill after individual target; minimum cycle goal=%d",
               InpMinimumRefillCycles);
   PrintFormat("HBv3.30 RECENTER MODE | enabled=%s every=%d minutes minMove=%.2f in gold PRICE | tracked grid LIMIT tickets only; verified REPEAT orders remain untouched",
               MarketRecenterActive()?"YES":"NO",GridRecenterMinutes(),GridMinimumMove());
   PrintFormat("HBv3.30 TAKEOVER POLICY | cancelVerifiedOldPendings=%s migrateVerifiedOldLiveTP=%s MagicRange=%I64d..%I64d currentMagic=%I64d; manual/other EA never changed; STOPS preserved; must stop old EAs on VPS",
               InpTakeoverCancelLegacyPendings?"YES":"NO",InpTakeoverUpdateLegacyLiveTP?"YES":"NO",
               InpTakeoverOldMagicMin,InpTakeoverOldMagicMax,InpMagic);
   PrintFormat("HBv3.30 OWN TP FIX POLICY | enforceConfiguredTP=%s savedPreserveFlag=%s; only tracked current-Magic positions are eligible; broker acknowledgement + TP/SL readback required; original80 other targets independent", 
               InpEnforceConfiguredTP?"YES":"NO",InpPreserveExistingLiveTP?"YES":"NO");
   PrintFormat("HBv3.30 SAFETY MIGRATION | newTierLots=0.01..10.00 existingPendingUpgrade=%s autoUpsize=%s savedPreserveFlag=%s legacyLiveTPmigration=%s; current Magic=%I64d",
               InpUpgradeExistingGridPendings?"ON":"OFF",InpAllowExistingPendingLotUpsize?"YES":"NO",
               InpPreserveExistingLiveTP?"YES":"NO",InpTakeoverUpdateLegacyLiveTP?"ON":"OFF",InpMagic);
   PrintFormat("HBv3.40 VIRTUAL GRID | sameSideLimit=%d enabled=%s oppositeStart=%d oppositeDistance=%.2f %s; legacy guards disabled; accepted fixed broker grid is not cancelled",
               InpVirtualGridSideCap,InpVirtualGridAfterEight?"ON":"OFF",
               InpOppositeGuardTriggerPositions,InpOppositeGuardDistanceUSC,AccountInfoString(ACCOUNT_CURRENCY));
   Print("HBv3.43 TARGET POLICY | grid BUY TP=50 / SELL TP=50; seed lots=2 each TP=50; other non-cooling legs TP=50; cooling TP=100 account currency; fixed constants ignore old target presets; bulk and pair exits disabled");
   Print("HBv3.46 MOVING PENDING GRID | 40 BUY + 40 SELL; lots 1..9 then 10 for rungs 10..40 each side; spacing=0.50; gridTP=50 for rungs 1..9 and 100 for rungs 10..40 USC, seedLots=2 seedTP=50, cooling=100; recenter=60sec; existing positions untouched; refill after individual target; no virtual cancellation");
   PrintFormat("HBv3.47 STARTUP | seedLot=%.2f pairSpreadAllowance=%.2f %s; flat restart checks actual broker exposure; margin filters retained",
               InpSeedLot,InpMaxSeedSpreadCost*(InpSeedLot/0.10),AccountInfoString(ACCOUNT_CURRENCY));
   ArrayInitialize(g_refill_times,0); ArrayInitialize(g_tp_ok_ids,0); // v3.62
   ArrayInitialize(g_mod_ticket,0); ArrayInitialize(g_mod_price,0.0); ArrayInitialize(g_mod_ms,0); // v3.63
   if(!TrendInitHandles()) Print("HBv3.66 TREND ENGINE | indicator handles unavailable; trend mode stays off");
   GuardLoad(); // v3.59
   EventSetTimer(1); // Individual targets and initial-rejection retries only.
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   TrendReleaseHandles(); // v3.66
   GHBWriteReport(); // v3.65 (before handles are released)
   Comment("");
   ObjectsDeleteAll(0,"GHBD_");
   EventKillTimer();
}

// v3.18: synchronize 20 tier TP targets on VERIFIED, OWNED pending orders and live positions.
// These are GROSS TP targets in account currency. Never close a position
// to "force" profit when the broker cannot accept a TP at its entry-based level.
// Verified historical GHB Magic positions are migrated separately; unrelated Magic/manual remain untouched.
void ReconcileAllOwnedTargets()
{
   if(g_basket_start<=0 || g_exit_in_progress || g_technical_pause || !CanTradeNow()) return;
   static datetime last_check=0;
   datetime now=TimeCurrent();
   if(last_check>0 && now-last_check<15) return;
   last_check=now;
   MqlTick q;
   if(!SymbolInfoTick(_Symbol,q) || q.bid<=0 || q.ask<=q.bid) return;
   double step=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   if(step<=0) step=_Point;
   double gap=(double)MathMax((int)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL),
                               (int)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_FREEZE_LEVEL))*_Point+2*step;

   // Live positions including original, trend, counter, follow, repeated seeds
   // and occupied grid rungs. Apply only after verifying tracked POSITION_ID.
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong ticket=PositionGetTicket(i);
      if(!IsOwnPosition(ticket)) continue;
      ulong id=(ulong)PositionGetInteger(POSITION_IDENTIFIER);
      if(!IsTrackedId(id)) continue;
      if(!IsOwnPosition(ticket)) continue; // restore after identity helper selection
      ENUM_POSITION_TYPE type=(ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      if(type!=POSITION_TYPE_BUY && type!=POSITION_TYPE_SELL) continue;
      ENUM_ORDER_TYPE direction=(type==POSITION_TYPE_BUY?ORDER_TYPE_BUY:ORDER_TYPE_SELL);
      double target=InpTrendTakeProfitMoney;
      if(id==g_seed_buy_id || id==g_seed_sell_id)
         target=InpSeedTakeProfitMoney;
      else if(IsReplacementId(id))
         target=InpRepeatTakeProfitMoney;
      else if(id==g_third_id || id==g_fourth_id)
         target=InpTrendTakeProfitMoney;
      else if(id==g_counter_id)
         target=InpCounterTakeProfitMoney;
      else if(id==g_follow_id)
         target=InpFollowTakeProfitMoney;
      else if(IsCoolingPositionId(id))
         target=InpCoolingTakeProfitUSC;
      else
      {
         int slot=LimitSlotForPositionId(id);
         if(slot<0) continue;
         target=LimitTargetForSlot(slot);
      }
      if(!IsOwnPosition(ticket)) continue; // restore after cooling role lookup
      double entry=PositionGetDouble(POSITION_PRICE_OPEN);
      double volume=PositionGetDouble(POSITION_VOLUME);
      if(InpNetOfSwap) target+=MathMax(0.0,-PositionGetDouble(POSITION_SWAP)); // v3.57
      double tp=0.0;
      if(!PendingLimitTPForAccountProfit(direction,entry,volume,target,tp)) continue;
      double old=PositionGetDouble(POSITION_TP);
      double oldSL=PositionGetDouble(POSITION_SL);
      if(!NeedOwnedBrokerTPCorrection(old,tp,step)) continue;
      // Never convert a passed TP target into an immediate market close.
      if((direction==ORDER_TYPE_BUY && tp<=q.bid+gap) ||
         (direction==ORDER_TYPE_SELL && tp>=q.ask-gap))
      {
         PrintFormat("HBv3.30 TP LIVE WAIT | ticket=%I64u target=%.2f %s price=%.3f market already too close/past TP",
                     ticket,target,AccountInfoString(ACCOUNT_CURRENCY),tp);
         continue;
      }
      bool sent=trade.PositionModify(ticket,oldSL,tp);
      if(sent && (trade.ResultRetcode()==TRADE_RETCODE_DONE || trade.ResultRetcode()==TRADE_RETCODE_NO_CHANGES) &&
         PositionSelectByTicket(ticket) &&
         MathAbs(PositionGetDouble(POSITION_TP)-tp)<step*0.5 &&
         MathAbs(PositionGetDouble(POSITION_SL)-oldSL)<step*0.5)
         PrintFormat("HBv3.30 TP LIVE UPDATED | ticket=%I64u old=%.3f new=%.3f gross=%.2f %s",
                     ticket,old,tp,target,AccountInfoString(ACCOUNT_CURRENCY));
      else
         PrintFormat("HBv3.30 TP LIVE REJECT | ticket=%I64u code=%u %s",
                     ticket,trade.ResultRetcode(),trade.ResultRetcodeDescription());
   }

   // Only the configured TP can be reconciled; grid entry prices remain immutable.
   // v3.45: apply the explicitly requested SELL target change to already
   // accepted owned grid orders. Entry price, lot and expiry remain fixed.
   // Pending grid tiers and verified original repeats. No price move:
   // only update their broker-side TP; preserve entry, order type and expiry.
   for(int i=OrdersTotal()-1;i>=0;i--)
   {
      ulong ticket=OrderGetTicket(i);
      if(ticket==0 || !OrderSelect(ticket)) continue;
      if(OrderGetString(ORDER_SYMBOL)!=_Symbol || OrderGetInteger(ORDER_MAGIC)!=InpMagic) continue;
      ENUM_ORDER_TYPE ty=(ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if(ty!=ORDER_TYPE_BUY_LIMIT && ty!=ORDER_TYPE_SELL_LIMIT) continue;
      int slot=-1;
      for(int k=0;k<LIMIT_SLOTS;k++) if(g_limit_order[k]==ticket) {slot=k;break;}
      bool repeat=false;
      if(slot<0) repeat=IsVerifiedOriginalRepeatPending(ticket);
      if(slot<0 && !repeat) continue;
      if(!OrderSelect(ticket)) continue;
      double vol=OrderGetDouble(ORDER_VOLUME_INITIAL);
      ENUM_ORDER_TYPE direction=(ty==ORDER_TYPE_BUY_LIMIT?ORDER_TYPE_BUY:ORDER_TYPE_SELL);
      double target=repeat ? InpRepeatTakeProfitMoney : LimitTargetForSlot(slot);
      if(slot>=0)
      {
         bool buy=(slot<LIMIT_PER_SIDE);
         string expected=StringFormat("HB L%s%d",buy?"B":"S",slot%LIMIT_PER_SIDE+1);
         if(ty!=(buy?ORDER_TYPE_BUY_LIMIT:ORDER_TYPE_SELL_LIMIT) ||
            OrderGetString(ORDER_COMMENT)!=expected ||
            !LimitVolumeMatchesSlot(slot,vol)) continue;
      }
      double entry=OrderGetDouble(ORDER_PRICE_OPEN);
      double old=OrderGetDouble(ORDER_TP);
      double tp=0.0;
      if(!PendingLimitTPForAccountProfit(direction,entry,vol,target,tp)) continue;
      if(old>0 && MathAbs(old-tp)<step*0.5) continue;
      ENUM_ORDER_TYPE_TIME duration=(ENUM_ORDER_TYPE_TIME)OrderGetInteger(ORDER_TYPE_TIME);
      datetime expiry=(datetime)OrderGetInteger(ORDER_TIME_EXPIRATION);
      bool sent=trade.OrderModify(ticket,entry,OrderGetDouble(ORDER_SL),tp,duration,expiry,0.0);
      if(sent && (trade.ResultRetcode()==TRADE_RETCODE_DONE ||
                  trade.ResultRetcode()==TRADE_RETCODE_NO_CHANGES))
      {
         if(!OrderSelect(ticket) || MathAbs(OrderGetDouble(ORDER_TP)-tp)>step*0.5)
         {
            PrintFormat("HBv3.30 TP PENDING VERIFY WAIT | ticket=%I64u",ticket);
            continue;
         }
         PrintFormat("HBv3.30 TP PENDING UPDATED | ticket=%I64u old=%.3f new=%.3f gross=%.2f %s",
                     ticket,old,tp,target,AccountInfoString(ACCOUNT_CURRENCY));
         if(repeat)
         {
            for(int side=0;side<2;side++)
               if(g_repeat_order[side]==ticket)
               {
                  g_repeat_last_tp[side]=tp;
                  GlobalVariableSet(g_repeat_tp_key[side],tp);
               }
         }
      }
      else
         PrintFormat("HBv3.30 TP PENDING REJECT | ticket=%I64u code=%u %s",
                     ticket,trade.ResultRetcode(),trade.ResultRetcodeDescription());
   }
}

// Restart only a VERIFIED, FULLY FLAT basket. Never add a second basket on top
// of existing GTC orders: delete own prior LIMIT and seed-repeat pendings first,
// wait for the broker to confirm zero pending AND zero positions, then rebuild
// through the existing StartHedgeBasket() procedure on a subsequent tick.
// This handler deliberately does not close or modify ANY live position.
bool HandleFlatBasketRestart()
{
   BasketState live;
   ScanBasket(live,true);
   int pending=OwnedPendingCount();
   if(live.count>0 || pending>0)
   {
      g_flat_detected_at=0;
      return false; // keep normal position management and minute recenter running
   }
   if(!InpAutoRestartFlatBasket || g_basket_start<=0) return false;
   if(!CanTradeNow()) return true;
   if(HasOtherPositionsOnSymbol() || HasOtherPendingOrdersOnSymbol())
   {
      g_flat_detected_at=0;
      return true; // no foreign-order cancellation, no duplicate network
   }
   datetime now=TimeCurrent();
   // v3.67: do not re-seed straight into the move that just forced the guard.
   if(InpRestartAfterGuardMinutes>0 && g_guard_flat_at>0 && now-g_guard_flat_at<InpRestartAfterGuardMinutes*60)
   {
      g_flat_detected_at=0;
      return true;
   }
   if(InpRestartOnlyInRange && InpTrendEngine && g_trend_dir!=0)
   {
      g_flat_detected_at=0;
      return true;
   }
   if(g_flat_detected_at<=0)
   {
      g_flat_detected_at=now;
      PrintFormat("HBv3.47 FLAT CONFIRM | live=0 pending=0; unused/rejected rungs do not block restart; wait=%d sec",InpFlatConfirmSeconds);
      return true;
   }
   if(now-g_flat_detected_at<InpFlatConfirmSeconds) return true;
   // Recheck broker state immediately before discarding only our old local ledger.
   ScanBasket(live,true);
   if(live.count>0 || OwnedPendingCount()>0 || HasOtherPositionsOnSymbol() || HasOtherPendingOrdersOnSymbol())
   {
      g_flat_detected_at=0;
      return false;
   }
   g_flat_restart_pending=true;
   GlobalVariableSet(g_flat_restart_key,1.0);
   ResetBasketState();
   g_exit_in_progress=false;
   g_had_positions=false;
   g_last_exit_time=now;
   GlobalVariableSet(g_exit_key,(double)now);
   g_flat_detected_at=0;
   PrintFormat("HBv3.47 FLAT RESET DONE | no positions/orders closed or deleted; new seed BUY=2 SELL=2 after cooldown=%d sec",InpFlatRestartCooldownSeconds);
   return true;
}


// v3.25: Independent TP safeguard. Broker-side TP is the primary exit; this
// backup checks the same displayed MT5 gross floating POSITION_PROFIT in USC.
// Close ONE VERIFIED OWNED position by ticket, never the basket, and never
// another EA/manual trade. Do not change other positions, SL, orders or lots.
// Pre-existing broker TPs are respected; this only acts after the target is met.
bool CloseOneOwnedAtIndividualTarget()
{
   if(!InpIndividualTPOnly || g_basket_start<=0 || g_exit_in_progress || !CanTradeNow()) return false;
   static datetime next_retry_at=0;
   datetime now=TimeCurrent();
   if(now<next_retry_at) return false;
   for(int p=PositionsTotal()-1;p>=0;p--)
   {
      ulong ticket=PositionGetTicket(p);
      if(ticket==0 || !IsOwnPosition(ticket)) continue;
      ulong id=(ulong)PositionGetInteger(POSITION_IDENTIFIER);
      if(!IsTrackedId(id)) continue; // no guesses during restart/recovery
      double target=0.0;
      if(id==g_seed_buy_id || id==g_seed_sell_id) target=InpSeedTakeProfitMoney;
      else if(id==g_third_id || id==g_fourth_id) target=InpTrendTakeProfitMoney;
      else if(id==g_counter_id) target=InpCounterTakeProfitMoney;
      else if(id==g_follow_id) target=InpFollowTakeProfitMoney;
      else if(IsReplacementId(id)) target=InpRepeatTakeProfitMoney;
      else if(IsCoolingPositionId(id)) target=InpCoolingTakeProfitUSC;
      else
      {
         int slot=LimitSlotForPositionId(id);
         if(slot<0 || slot>=LIMIT_SLOTS) continue;
         target=LimitTargetForSlot(slot);
      }
      if(target<=0.0) continue;
      if(!IsOwnPosition(ticket)) continue; // read profit of the ticket being closed
      double profit=PositionGetDouble(POSITION_PROFIT); // gross; matches the displayed MT5 Profit field
      // v3.57: NET = gross + swap - round-trip commission of this volume
      double netNow=profit-CommissionCostForVolume(PositionGetDouble(POSITION_VOLUME));
      if(InpNetOfSwap) netNow+=MathMin(0.0,PositionGetDouble(POSITION_SWAP));
      if(netNow+0.00001<target) continue;
      // Throttle rejects/uncertain acknowledgments; no repeated instant close calls.
      next_retry_at=now+3;
      bool submitted=trade.PositionClose(ticket); // ticket, never symbol (hedging account)
      uint ret=trade.ResultRetcode();
      if(submitted && ret==TRADE_RETCODE_DONE)
      {
         int closedSlot=LimitSlotForPositionId(id);
         if(closedSlot>=0) GlobalVariableSet(g_limit_order_key[closedSlot]+".targetExit",(double)id);
         GHBEvent(StringFormat("Target close #%I64u gross %.2f",ticket,profit));
         PrintFormat("HBv3.30 INDIVIDUAL TP CLOSE SENT | ticket=%I64u id=%I64u observedGross=%.2f target=%.2f %s; others untouched",
                     ticket,id,profit,target,AccountInfoString(ACCOUNT_CURRENCY));
      }
      else
         PrintFormat("HBv3.30 INDIVIDUAL TP CLOSE RETRY | ticket=%I64u observedGross=%.2f target=%.2f code=%u %s",
                     ticket,profit,target,ret,trade.ResultRetcodeDescription());
      // Whether confirmed or rejected, stop this iteration and resync before
      // any other trade modification. Recheck at next Tick/Timer.
      return true;
   }
   return false;
}


// ======================= v3.59 TREND GUARD =======================
long     GuardLockMagic() {return InpMagic+1000000;}
datetime g_guard_episode=0;      // realized-pool start (stage 2+)
datetime g_guard_last_action=0;
datetime g_lock_last_close=0;
double   g_guard_dd=0.0, g_guard_pool=0.0;

string GuardKey() {return g_start_key+".guard";}
void GuardSave()
{
   if(g_start_key=="") return;
   GlobalVariableSet(GuardKey()+".stage",(double)g_guard_stage);
   GlobalVariableSet(GuardKey()+".park",(double)g_park_side);
   GlobalVariableSet(GuardKey()+".episode",(double)g_guard_episode);
   GlobalVariableSet(GuardKey()+".lockClose",(double)g_lock_last_close);
   GlobalVariableSet(GuardKey()+".locksEpisode",(double)g_locks_this_episode);
   GlobalVariableSet(GuardKey()+".flatAt",(double)g_guard_flat_at);
}
void GuardLoad()
{
   if(g_start_key=="") return;
   if(GlobalVariableCheck(GuardKey()+".stage"))    g_guard_stage=(int)GlobalVariableGet(GuardKey()+".stage");
   if(GlobalVariableCheck(GuardKey()+".park"))     g_park_side=(int)GlobalVariableGet(GuardKey()+".park");
   if(GlobalVariableCheck(GuardKey()+".episode"))  g_guard_episode=(datetime)GlobalVariableGet(GuardKey()+".episode");
   if(GlobalVariableCheck(GuardKey()+".lockClose")) g_lock_last_close=(datetime)GlobalVariableGet(GuardKey()+".lockClose");
   if(GlobalVariableCheck(GuardKey()+".locksEpisode")) g_locks_this_episode=(int)GlobalVariableGet(GuardKey()+".locksEpisode");
   if(GlobalVariableCheck(GuardKey()+".flatAt"))  g_guard_flat_at=(datetime)GlobalVariableGet(GuardKey()+".flatAt");
   if(g_guard_stage<0 || g_guard_stage>4) g_guard_stage=0;
   if(g_park_side<-1 || g_park_side>1) g_park_side=-1;
   PrintFormat("HBv3.59 GUARD RESTORED | stage=%d park=%s episode=%s",g_guard_stage,
               g_park_side==0?"BUY":(g_park_side==1?"SELL":"none"),
               g_guard_episode>0?TimeToString(g_guard_episode):"-");
}

// v3.61: real US cents -> account currency (USC 1:1, USD /100, EUR via rate)
double GuardMoney(const double real_cents)
{
   static double unit=0.0;
   if(unit<=0.0)
   {
      string how="";
      unit=AccountUnitUSD(AccountInfoString(ACCOUNT_CURRENCY),how);
      if(unit<=0.0) unit=1.0;
   }
   return real_cents*0.01/unit;
}

double GuardThreshold(const int stage)
{
   double d=0.0;
   if(stage==1) d=InpGuardStage1Design;
   else if(stage==2) d=InpGuardStage2Design;
   else if(stage==3) d=InpGuardStage3Design;
   else if(stage==4) d=InpGuardStage4Design;
   return GuardMoney(d);
}

// Net of the SELECTED position: gross + swap - round-trip commission estimate.
double SelectedPositionNet()
{
   return PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP)-
          CommissionCostForVolume(PositionGetDouble(POSITION_VOLUME));
}

bool GuardFloating(double &total,double &buyNet,double &sellNet,double &buyLots,double &sellLots,int &own,int &locks)
{
   total=0;buyNet=0;sellNet=0;buyLots=0;sellLots=0;own=0;locks=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong t=PositionGetTicket(i);
      if(t==0 || !PositionSelectByTicket(t) || PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      long mg=PositionGetInteger(POSITION_MAGIC);
      if(mg!=InpMagic && mg!=GuardLockMagic() && mg!=InpMagic+2000000) continue;
      double net=SelectedPositionNet();
      total+=net;
      if(mg==GuardLockMagic()) {locks++;continue;}
      if(mg==InpMagic+2000000) continue; // v3.66 momentum: in DD, not in grid side lots
      own++;
      bool buy=((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY);
      double v=PositionGetDouble(POSITION_VOLUME);
      if(buy) {buyNet+=net;buyLots+=v;} else {sellNet+=net;sellLots+=v;}
   }
   return true;
}

double GuardRealizedSince(const datetime from)
{
   if(from<=0 || !GHBHistorySelect(from,TimeCurrent()+60)) return 0.0;
   double sum=0.0;
   for(int i=HistoryDealsTotal()-1;i>=0;i--)
   {
      ulong d=HistoryDealGetTicket(i);
      if(d==0 || HistoryDealGetString(d,DEAL_SYMBOL)!=_Symbol) continue;
      long mg=HistoryDealGetInteger(d,DEAL_MAGIC);
      if(mg!=InpMagic && mg!=GuardLockMagic() && mg!=InpMagic+2000000) continue;
      sum+=HistoryDealGetDouble(d,DEAL_PROFIT)+HistoryDealGetDouble(d,DEAL_SWAP)+
           HistoryDealGetDouble(d,DEAL_COMMISSION)+HistoryDealGetDouble(d,DEAL_FEE);
   }
   return sum;
}

bool GuardCloseLocks(const string why)
{
   bool any=false;
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong t=PositionGetTicket(i);
      if(t==0 || !PositionSelectByTicket(t) || PositionGetString(POSITION_SYMBOL)!=_Symbol ||
         PositionGetInteger(POSITION_MAGIC)!=GuardLockMagic()) continue;
      double net=SelectedPositionNet();
      if(trade.PositionClose(t) && trade.ResultRetcode()==TRADE_RETCODE_DONE)
      {
         any=true;
         GHBEvent(StringFormat("Lock closed net %.2f (%s)",net,why));
         PrintFormat("HBv3.59 LOCK CLOSED | ticket=%I64u net=%.2f %s reason=%s",t,net,AccountInfoString(ACCOUNT_CURRENCY),why);
      }
   }
   if(any) {g_lock_last_close=TimeCurrent();GuardSave();}
   return any;
}

// v3.67: lock still open after every grid position closed.
void GuardManageOrphanLock()
{
   if(!CanTradeNow()) return;
   static datetime last=0;
   datetime now=TimeCurrent();
   if(now-last<3) return;
   double net=0.0; int n=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong t=PositionGetTicket(i);
      if(t==0 || !PositionSelectByTicket(t) || PositionGetString(POSITION_SYMBOL)!=_Symbol ||
         PositionGetInteger(POSITION_MAGIC)!=GuardLockMagic()) continue;
      net+=SelectedPositionNet(); n++;
   }
   if(n==0) return;
   double cap=(InpOrphanLockMaxLossDesign>0.0 ? GuardMoney(InpOrphanLockMaxLossDesign) : 0.0);
   string why="";
   if(net>=0.0) why="orphan break-even";
   else if(cap>0.0 && net<=-cap) why=StringFormat("orphan loss cap %.2f",cap);
   if(why=="")
   {
      static datetime lastLog=0;
      if(now-lastLog>=60)
      {
         lastLog=now;
         PrintFormat("HBv3.67 ORPHAN LOCK WAIT | net=%.2f %s cap=%.2f; no new basket until it closes",
                     net,AccountInfoString(ACCOUNT_CURRENCY),cap);
      }
      return;
   }
   last=now;
   if(GuardCloseLocks(why)) {g_guard_flat_at=now;GuardSave();} // restart delay counts from here
}

void GuardUpdateStage()
{
   if(!InpGuardEnabled) {if(g_guard_stage!=0||g_park_side!=-1){g_guard_stage=0;g_park_side=-1;g_grid_geometry_dirty=true;GuardSave();} return;}
   double total,bn,sn,bl,sl; int own,locks;
   GuardFloating(total,bn,sn,bl,sl,own,locks);
   if(own==0)
   {
      // v3.67: the lock used to be dumped here at any loss. An orphan lock now
      // waits for break-even, or is cut at InpOrphanLockMaxLossDesign. The flat
      // restart stays blocked while it is open (lock magic is foreign there).
      if(locks>0) GuardManageOrphanLock();
      if(g_guard_stage!=0 || g_park_side!=-1 || g_guard_episode!=0)
      {
         g_guard_flat_at=TimeCurrent();
         g_guard_stage=0;g_park_side=-1;g_guard_episode=0;g_grid_geometry_dirty=true;
         if(locks==0) g_locks_this_episode=0;
         GuardSave();
         Print("HBv3.59 GUARD RESET | basket flat");
      }
      else if(locks==0 && g_locks_this_episode!=0) {g_locks_this_episode=0;GuardSave();}
      g_guard_dd=0.0;
      return;
   }
   g_guard_dd=MathMax(0.0,-total);
   int old=g_guard_stage, st=g_guard_stage;
   while(st<4 && g_guard_dd>=GuardThreshold(st+1)) st++;
   double ratio=MathMax(0.05,MathMin(0.95,InpGuardExitRatio));
   while(st>0 && g_guard_dd<GuardThreshold(st)*ratio) st--;
   if(InpGuardRepark && old>=1 && st>=1 && g_park_side>=0)
   {
      int want=(bn<=sn?0:1);
      if(want!=g_park_side && MathAbs(bn-sn)>=GuardThreshold(1)*MathMax(0.0,InpReparkMinGapRatio))
      {
         g_park_side=want;
         g_grid_geometry_dirty=true;
         GuardSave();
         GHBEvent(StringFormat("Re-park %s side",want==0?"BUY":"SELL"));
         PrintFormat("HBv3.68 REPARK | parked=%s BUYnet=%.2f SELLnet=%.2f stage=%d",
                     want==0?"BUY":"SELL",bn,sn,st);
      }
   }
   if(st==old) return;
   g_guard_stage=st;
   if(old==0 && st>=1)
   {
      g_park_side=(bn<=sn?0:1);
      g_grid_geometry_dirty=true;
   }
   if(st==0)
   {
      g_park_side=-1;g_guard_episode=0;g_grid_geometry_dirty=true;
      if(locks==0) g_locks_this_episode=0; // v3.67
   }
   if(st>=2 && g_guard_episode==0) g_guard_episode=TimeCurrent();
   GuardSave();
   GHBEvent(StringFormat("Guard stage %d -> %d, DD %.2f",old,st,g_guard_dd)); if(st>old) for(int hs=old+1;hs<=st;hs++) g_st_stage_hits[hs]++;
   PrintFormat("HBv3.59 GUARD STAGE %d -> %d | floatingDD=%.2f %s thresholds=%.2f/%.2f/%.2f/%.2f exit x%.2f | parked=%s BUYnet=%.2f SELLnet=%.2f",
               old,st,g_guard_dd,AccountInfoString(ACCOUNT_CURRENCY),GuardThreshold(1),GuardThreshold(2),
               GuardThreshold(3),GuardThreshold(4),ratio,
               g_park_side==0?"BUY":(g_park_side==1?"SELL":"none"),bn,sn);
}

// Close one candidate by ticket; mark grid rungs so they can be re-armed later.
bool GuardClose(const ulong ticket,const bool loser,const string tag)
{
   if(!PositionSelectByTicket(ticket)) return false;
   long mg=PositionGetInteger(POSITION_MAGIC);
   ulong id=(ulong)PositionGetInteger(POSITION_IDENTIFIER);
   double net=SelectedPositionNet(),vol=PositionGetDouble(POSITION_VOLUME);
   if(mg==InpMagic)
   {
      int slot=LimitSlotForPositionId(id);
      if(slot>=0) GlobalVariableSet(g_limit_order_key[slot]+(loser?".overlapExit":".targetExit"),(double)id);
   }
   bool ok=trade.PositionClose(ticket) && trade.ResultRetcode()==TRADE_RETCODE_DONE;
   PrintFormat("HBv3.59 %s %s | ticket=%I64u vol=%.2f net=%.2f %s result=%s",tag,loser?"LOSER":"WINNER",
               ticket,vol,net,AccountInfoString(ACCOUNT_CURRENCY),ok?"DONE":trade.ResultRetcodeDescription());
   if(ok && mg==GuardLockMagic()) {g_lock_last_close=TimeCurrent();GuardSave();}
   return ok;
}

// Stage 2+: break-even exit of the parked side, else one overlap group.
bool GuardDeRisk()
{
   if(!InpGuardEnabled || g_guard_stage<2 || g_exit_in_progress || g_technical_pause || !CanTradeNow()) return false;
   datetime now=TimeCurrent();
   if(now-g_guard_last_action<3) return false;
   g_guard_pool=GuardRealizedSince(g_guard_episode);
   double buffer=(g_guard_stage>=3 ? 0.0 : GuardMoney(InpOverlapBufferDesign));
   ulong tk[]; double nt[]; int sd[];
   int n=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong t=PositionGetTicket(i);
      if(t==0 || !PositionSelectByTicket(t) || PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      long mg=PositionGetInteger(POSITION_MAGIC);
      if(mg!=InpMagic && mg!=GuardLockMagic() && mg!=InpMagic+2000000) continue;
      ulong id=(ulong)PositionGetInteger(POSITION_IDENTIFIER);
      double net=SelectedPositionNet();
      int side=((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY?0:1);
      if(mg==InpMagic && !IsLimitPositionId(id) && !IsCoolingPositionId(id)) continue; // core roles stay with their own rules
      if(mg==GuardLockMagic() && (net<=0.0 || !InpLockAsOverlapWinner)) continue; // v3.67: cashing the lock un-hedges, then it is re-bought worse
      ArrayResize(tk,n+1);ArrayResize(nt,n+1);ArrayResize(sd,n+1);
      tk[n]=t;nt[n]=net;sd[n]=(mg==InpMagic?side:2);n++; // lock/momentum never part of a BE side exit
   }
   if(n==0) return false;
   // (a) break-even exit: whole parked side + pool >= buffer
   if(g_park_side>=0)
   {
      double sideSum=0;int cnt=0;
      for(int i=0;i<n;i++) if(sd[i]==g_park_side) {sideSum+=nt[i];cnt++;}
      if(cnt>0 && sideSum<0.0 && g_guard_pool+sideSum>=buffer)
      {
         g_guard_last_action=now;
         GHBEvent(StringFormat("BE exit %s side, %d positions",g_park_side==0?"BUY":"SELL",cnt)); g_st_be_exits++;
         PrintFormat("HBv3.59 BE SIDE EXIT | side=%s positions=%d sideNet=%.2f pool=%.2f buffer=%.2f",
                     g_park_side==0?"BUY":"SELL",cnt,sideSum,g_guard_pool,buffer);
         for(int i=0;i<n;i++) if(sd[i]==g_park_side) GuardClose(tk[i],nt[i]<0.0,"BE EXIT");
         return true;
      }
   }
   // (b) overlap: biggest loser that pool + floating winners can pay
   double winners=0;
   for(int i=0;i<n;i++) if(nt[i]>0.0) winners+=nt[i];
   int best=-1;
   for(int i=0;i<n;i++)
   {
      if(nt[i]>=0.0) continue;
      if(g_guard_pool+winners+nt[i]<buffer) continue;
      if(best<0 || nt[i]<nt[best]) best=i;
   }
   if(best<0) return false;
   g_guard_last_action=now;
   double need=buffer-g_guard_pool-nt[best];
   GHBEvent(StringFormat("Overlap: closing loser %.2f",nt[best])); g_st_overlaps++;
   PrintFormat("HBv3.59 OVERLAP | loser=%.2f pool=%.2f winnersAvail=%.2f buffer=%.2f winnersNeeded=%.2f",
               nt[best],g_guard_pool,winners,buffer,MathMax(0.0,need));
   GuardClose(tk[best],true,"OVERLAP");
   double covered=0;
   while(covered<need)
   {
      int w=-1;
      for(int i=0;i<n;i++) if(nt[i]>0.0 && (w<0 || nt[i]>nt[w])) w=i;
      if(w<0) break;
      if(GuardClose(tk[w],false,"OVERLAP")) covered+=nt[w];
      nt[w]=0.0;
   }
   return true;
}

// Stage 4: one partial lock against net exposure; closed when stage <= 2.
void GuardLock()
{
   if(!InpGuardEnabled || !CanTradeNow() || g_technical_pause) return;
   double total,bn,sn,bl,sl; int own,locks;
   GuardFloating(total,bn,sn,bl,sl,own,locks);
   // v3.67: own>0 - an orphan lock (grid flat) is handled by GuardManageOrphanLock.
   if(locks>0 && own>0 && g_guard_stage<=2) {GuardCloseLocks("stage recovered to "+IntegerToString(g_guard_stage));return;}
   if(g_guard_stage<4 || locks>0 || own==0) return;
   if(InpMaxLocksPerEpisode>0 && g_locks_this_episode>=InpMaxLocksPerEpisode) return;
   datetime now=TimeCurrent();
   if(g_lock_last_close>0 && now-g_lock_last_close<InpLockCooldownMinutes*60) return;
   double net=bl-sl;
   double step=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP),minlot=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double vol=MathAbs(net)*MathMax(0.1,MathMin(1.0,InpLockRatio));
   if(step>0) vol=MathFloor(vol/step+1e-9)*step;
   if(vol<minlot-1e-9) return;
   bool lockSell=(net>0.0);
   trade.SetExpertMagicNumber((ulong)GuardLockMagic());
   bool ok=(lockSell ? trade.Sell(vol,_Symbol,0.0,0.0,0.0,"HB LOCK") : trade.Buy(vol,_Symbol,0.0,0.0,0.0,"HB LOCK"));
   uint rc=trade.ResultRetcode();
   trade.SetExpertMagicNumber((ulong)InpMagic);
   g_lock_last_close=now; // also throttles retries after a reject
   if(ok && rc==TRADE_RETCODE_DONE) g_locks_this_episode++; // v3.67
   GuardSave();
   GHBEvent(StringFormat("Lock %s %.2f opened",lockSell?"SELL":"BUY",vol)); g_st_locks++;
   PrintFormat("HBv3.59 LOCK OPEN | %s %.2f vs net exposure %.2f (BUY %.2f / SELL %.2f) ratio=%.2f result=%s",
               lockSell?"SELL":"BUY",vol,net,bl,sl,InpLockRatio,ok&&rc==TRADE_RETCODE_DONE?"DONE":trade.ResultRetcodeDescription());
}

void GuardPanel()
{
   static datetime last=0;
   datetime now=TimeCurrent();
   if(now==last) return;
   last=now;
   string cur=AccountInfoString(ACCOUNT_CURRENCY);
   string next=(g_guard_stage<4?StringFormat("next stage at %.2f",GuardThreshold(g_guard_stage+1)):"max stage");
   Comment(StringFormat("GHB TREND GUARD  |  stage %d/4  |  floating DD %.2f %s  |  %s\nparked side: %s  |  realized pool: %.2f  |  lock: %s",
           g_guard_stage,g_guard_dd,cur,next,
           g_park_side==0?"BUY":(g_park_side==1?"SELL":"none"),g_guard_pool,
           g_lock_last_close>0 && g_guard_stage>=4 ? "active/cooldown" : "off"));
}



// ======================= v3.66 ADAPTIVE TREND ENGINE =======================
// Range: nothing changes (limit grid as designed).
// Trend detected: adverse-side limit spacing widens, cooling stops on that
// side, and a small with-trend STOP leg (own magic) rides the move; its
// profits feed the guard overlap that pays down stuck limit positions.
long MomMagic() {return InpMagic+2000000;}
int  g_h_ema=INVALID_HANDLE, g_h_atr_fast=INVALID_HANDLE, g_h_atr_slow=INVALID_HANDLE, g_h_adx=INVALID_HANDLE;
double g_tr_slope=0, g_tr_adx=0, g_tr_atr_ratio=0;
int    g_tr_burst_dir=0, g_tr_score=0, g_tr_raw_dir=0;
datetime g_tr_last_calc=0, g_tr_since=0, g_mom_last_manage=0;
int    g_st_trend_on=0, g_st_mom_fills=0;
double g_mom_net=0; int g_mom_open=0; bool g_mom_pending=false;

bool TrendInitHandles()
{
   g_h_ema=iMA(_Symbol,PERIOD_M15,50,0,MODE_EMA,PRICE_CLOSE);
   g_h_atr_fast=iATR(_Symbol,PERIOD_M5,14);
   g_h_atr_slow=iATR(_Symbol,PERIOD_M5,100);
   g_h_adx=iADX(_Symbol,PERIOD_M15,14);
   return g_h_ema!=INVALID_HANDLE && g_h_atr_fast!=INVALID_HANDLE && g_h_atr_slow!=INVALID_HANDLE && g_h_adx!=INVALID_HANDLE;
}
void TrendReleaseHandles()
{
   if(g_h_ema!=INVALID_HANDLE) IndicatorRelease(g_h_ema);
   if(g_h_atr_fast!=INVALID_HANDLE) IndicatorRelease(g_h_atr_fast);
   if(g_h_atr_slow!=INVALID_HANDLE) IndicatorRelease(g_h_atr_slow);
   if(g_h_adx!=INVALID_HANDLE) IndicatorRelease(g_h_adx);
}

// Burst: rung positions of one side opened during the last N minutes.
int TrendFillBurst()
{
   datetime from=TimeCurrent()-InpTrendBurstMinutes*60;
   int nb=0,ns=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong t=PositionGetTicket(i);
      if(t==0 || !PositionSelectByTicket(t) || PositionGetString(POSITION_SYMBOL)!=_Symbol ||
         PositionGetInteger(POSITION_MAGIC)!=InpMagic) continue;
      if((datetime)PositionGetInteger(POSITION_TIME)<from) continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY) nb++; else ns++;
   }
   // BUY limits filling fast = market falling (down trend), and vice versa
   if(nb>=InpTrendBurstFills && nb>ns) return -1;
   if(ns>=InpTrendBurstFills && ns>nb) return 1;
   return 0;
}

void TrendCompute()
{
   if(!InpTrendEngine) {if(g_trend_dir!=0){g_trend_dir=0;g_grid_geometry_dirty=true;} return;}
   datetime now=TimeCurrent();
   if(now-g_tr_last_calc<5) return;
   g_tr_last_calc=now;
   double ema[],af[],as[],adx[],pdi[],mdi[];
   if(CopyBuffer(g_h_ema,0,1,6,ema)<6 || CopyBuffer(g_h_atr_fast,0,1,1,af)<1 ||
      CopyBuffer(g_h_atr_slow,0,1,1,as)<1 || CopyBuffer(g_h_adx,0,1,1,adx)<1 ||
      CopyBuffer(g_h_adx,1,1,1,pdi)<1 || CopyBuffer(g_h_adx,2,1,1,mdi)<1) return;
   // series copied oldest->newest: ema[5] is the last closed bar
   double atr15=af[0]>0?af[0]*1.7:0.0; // M5 ATR scaled ~ to M15
   g_tr_slope=(atr15>0?(ema[5]-ema[0])/atr15:0.0);
   g_tr_adx=adx[0];
   g_tr_atr_ratio=(as[0]>0?af[0]/as[0]:1.0);
   g_tr_burst_dir=TrendFillBurst();
   int dir=(g_tr_slope>0?1:(g_tr_slope<0?-1:0));
   int score=0;
   if(MathAbs(g_tr_slope)>=InpTrendSlopeAtr) score+=2;
   if(g_tr_adx>=InpTrendAdxMin && ((dir>0 && pdi[0]>mdi[0]) || (dir<0 && mdi[0]>pdi[0]))) score++;
   if(g_tr_atr_ratio>=InpTrendAtrExpansion) score++;
   if(g_tr_burst_dir!=0 && g_tr_burst_dir==dir) score++;
   g_tr_score=score; g_tr_raw_dir=dir;
   int old=g_trend_dir, next=old;
   if(old==0 && score>=InpTrendScoreOn && dir!=0) next=dir;
   else if(old!=0 && (score<=InpTrendScoreOff || dir==-old)) next=0;
   if(next==old) return;
   g_trend_dir=next;
   g_grid_geometry_dirty=true; // adverse spacing changes
   if(next!=0) {g_tr_since=now; g_st_trend_on++;}
   string msg=(next==0?"Trend OFF (range mode)":StringFormat("Trend %s ON (score %d)",next>0?"UP":"DOWN",score));
   GHBEvent(msg);
   PrintFormat("HBv3.66 TREND %s | slopeATR=%.2f ADX=%.1f atrRatio=%.2f burst=%d score=%d",
               msg,g_tr_slope,g_tr_adx,g_tr_atr_ratio,g_tr_burst_dir,score);
}

// ---- momentum STOP leg (own magic, outside the grid ledger) ----
void MomScan(int &open,double &net,ulong &pending,double &pendPrice,double &lastEntry)
{
   open=0;net=0;pending=0;pendPrice=0;lastEntry=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong t=PositionGetTicket(i);
      if(t==0 || !PositionSelectByTicket(t) || PositionGetString(POSITION_SYMBOL)!=_Symbol ||
         PositionGetInteger(POSITION_MAGIC)!=MomMagic()) continue;
      open++; net+=SelectedPositionNet();
      double e=PositionGetDouble(POSITION_PRICE_OPEN);
      bool buy=((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY);
      if(lastEntry==0 || (buy?e>lastEntry:e<lastEntry)) lastEntry=e; // most advanced entry
   }
   for(int i=OrdersTotal()-1;i>=0;i--)
   {
      ulong t=OrderGetTicket(i);
      if(t==0 || !OrderSelect(t) || OrderGetString(ORDER_SYMBOL)!=_Symbol || OrderGetInteger(ORDER_MAGIC)!=MomMagic()) continue;
      pending=t; pendPrice=OrderGetDouble(ORDER_PRICE_OPEN);
   }
}

void MomManage()
{
   if(!InpTrendEngine || !InpMomentumLeg || g_basket_start<=0 || g_technical_pause || !CanTradeNow()) return;
   datetime now=TimeCurrent();
   if(now-g_mom_last_manage<5) return;
   g_mom_last_manage=now;
   int open; double net,pendPrice,lastEntry; ulong pending;
   MomScan(open,net,pending,pendPrice,lastEntry);
   g_mom_open=open; g_mom_net=net; g_mom_pending=(pending!=0);
   MqlTick q; if(!SymbolInfoTick(_Symbol,q) || q.bid<=0) return;
   int digits=(int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS);
   double tick=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE); if(tick<=0) tick=_Point;
   bool want=(g_trend_dir!=0 && open<InpMomMaxOpen && SpreadOK(q));
   if(!want)
   {
      if(pending!=0 && trade.OrderDelete(pending)) GHBEvent("Momentum stop cancelled");
      return;
   }
   bool up=(g_trend_dir>0);
   double dist=MomStopDistance();
   double price=up?q.ask+dist:q.bid-dist;
   // pyramid: next entry must be at least one step beyond the last filled leg
   if(open>0 && lastEntry>0) price=up?MathMax(price,lastEntry+MomStepDistance()):MathMin(price,lastEntry-MomStepDistance());
   price=NormalizeDouble(MathRound(price/tick)*tick,digits);
   double tp=NormalizeDouble(MathRound((up?price+MomTPDistance():price-MomTPDistance())/tick)*tick,digits);
   double lot=ScaledLot(InpMomLotDesign);
   if(pending!=0)
   {
      if(MathAbs(pendPrice-price)<MathMax(tick*2,dist*0.25)) return; // close enough, no churn
      if(!OrderSelect(pending)) return;
      trade.OrderModify(pending,price,0.0,tp,ORDER_TIME_GTC,0,0.0);
      return;
   }
   if(!MarginOK(up?ORDER_TYPE_BUY:ORDER_TYPE_SELL,1.0,lot)) return;
   trade.SetExpertMagicNumber((ulong)MomMagic());
   bool ok=(up?trade.BuyStop(lot,price,_Symbol,0.0,tp,ORDER_TIME_GTC,0,"HB MOM"):
               trade.SellStop(lot,price,_Symbol,0.0,tp,ORDER_TIME_GTC,0,"HB MOM"));
   trade.SetExpertMagicNumber((ulong)InpMagic);
   if(ok) GHBEvent(StringFormat("Momentum %s STOP %.2f @ %s",up?"BUY":"SELL",lot,DoubleToString(price,digits)));
}

void TrendTick()
{
   TrendCompute();
   MomManage();
}

// ======================= v3.60 DASHBOARD =======================
#define GHBD "GHBD_"
color DC_BG=C'14,18,26', DC_PANEL=C'22,28,40', DC_HEAD=C'34,44,64', DC_LINE=C'52,64,90';
color DC_TXT=C'200,208,222', DC_DIM=C'120,132,156', DC_OK=C'64,200,120', DC_BAD=C'240,84,84';
color DC_WARN=C'245,180,60', DC_ACC=C'90,170,255', DC_BUY=C'70,160,255', DC_SELL=C'255,110,110';

int  DRowH() {return (int)MathRound(InpDashFont*1.95);}
int  DColW() {return InpDashFont*40;}

void DRect(const string id,const int x,const int y,const int w,const int h,const color bg,const color border)
{
   string n=GHBD+id;
   if(ObjectFind(0,n)<0)
   {
      ObjectCreate(0,n,OBJ_RECTANGLE_LABEL,0,0,0);
      ObjectSetInteger(0,n,OBJPROP_CORNER,CORNER_LEFT_UPPER);
      ObjectSetInteger(0,n,OBJPROP_BORDER_TYPE,BORDER_FLAT);
      ObjectSetInteger(0,n,OBJPROP_SELECTABLE,false);
      ObjectSetInteger(0,n,OBJPROP_HIDDEN,true);
      ObjectSetInteger(0,n,OBJPROP_BACK,false);
   }
   ObjectSetInteger(0,n,OBJPROP_XDISTANCE,x);
   ObjectSetInteger(0,n,OBJPROP_YDISTANCE,y);
   ObjectSetInteger(0,n,OBJPROP_XSIZE,w);
   ObjectSetInteger(0,n,OBJPROP_YSIZE,h);
   ObjectSetInteger(0,n,OBJPROP_BGCOLOR,bg);
   ObjectSetInteger(0,n,OBJPROP_COLOR,border);
}

void DText(const string id,const int x,const int y,const string txt,const color c,
           const bool right=false,const bool bold=false,const int size=0)
{
   string n=GHBD+id;
   if(ObjectFind(0,n)<0)
   {
      ObjectCreate(0,n,OBJ_LABEL,0,0,0);
      ObjectSetInteger(0,n,OBJPROP_CORNER,CORNER_LEFT_UPPER);
      ObjectSetInteger(0,n,OBJPROP_SELECTABLE,false);
      ObjectSetInteger(0,n,OBJPROP_HIDDEN,true);
      ObjectSetInteger(0,n,OBJPROP_BACK,false);
   }
   ObjectSetInteger(0,n,OBJPROP_XDISTANCE,x);
   ObjectSetInteger(0,n,OBJPROP_YDISTANCE,y);
   ObjectSetInteger(0,n,OBJPROP_ANCHOR,right?ANCHOR_RIGHT_UPPER:ANCHOR_LEFT_UPPER);
   ObjectSetString(0,n,OBJPROP_FONT,bold?"Consolas Bold":"Consolas");
   ObjectSetInteger(0,n,OBJPROP_FONTSIZE,size>0?size:InpDashFont);
   ObjectSetInteger(0,n,OBJPROP_COLOR,c);
   ObjectSetString(0,n,OBJPROP_TEXT,txt==""?" ":txt);
}

// column layout helpers
int g_dx[2], g_dy0=0;
void DHead(const int col,const int row,const string title)
{
   int x=g_dx[col], y=g_dy0+row*DRowH();
   DRect(StringFormat("h%d_%d",col,row),x,y+1,DColW(),DRowH()-2,DC_HEAD,DC_HEAD);
   DText(StringFormat("ht%d_%d",col,row),x+6,y+2,title,DC_ACC,false,true);
}
void DRow(const int col,const int row,const string key,const string val,const color vc)
{
   int x=g_dx[col], y=g_dy0+row*DRowH();
   DText(StringFormat("k%d_%d",col,row),x+8,y+2,key,DC_DIM);
   DText(StringFormat("v%d_%d",col,row),x+DColW()-8,y+2,val,vc,true);
}
void DLine(const int col,const int row,const string txt,const color c)
{
   int x=g_dx[col], y=g_dy0+row*DRowH();
   DText(StringFormat("k%d_%d",col,row),x+8,y+2,txt,c);
   DText(StringFormat("v%d_%d",col,row),x+DColW()-8,y+2," ",c,true);
}
void DCheck(const int col,const int row,const string name,const bool ok,const string detail,const bool relevant=true)
{
   color c=!relevant?DC_DIM:(ok?DC_OK:DC_BAD);
   string mark=!relevant?"[ - ]":(ok?"[ OK ]":"[FAIL]");
   int x=g_dx[col], y=g_dy0+row*DRowH();
   DText(StringFormat("k%d_%d",col,row),x+8,y+2,mark+" "+name,c);
   DText(StringFormat("v%d_%d",col,row),x+DColW()-8,y+2,detail,relevant?DC_TXT:DC_DIM,true);
}
// progress bar inside a row
void DBar(const int col,const int row,const double frac,const color c,const string label)
{
   int x=g_dx[col]+8, y=g_dy0+row*DRowH()+3, w=DColW()-16, h=DRowH()-6;
   double f=MathMax(0.0,MathMin(1.0,frac));
   DRect(StringFormat("b%d_%d",col,row),x,y,w,h,DC_BG,DC_LINE);
   DRect(StringFormat("bf%d_%d",col,row),x+1,y+1,MathMax(1,(int)((w-2)*f)),h-2,c,c);
   DText(StringFormat("bt%d_%d",col,row),x+w/2-StringLen(label)*InpDashFont*3/8,y,label,DC_TXT);
}

string Money(const double v) {return StringFormat("%s%.2f",v>=0?"+":"",v);}
string SideName(const int s) {return s==0?"BUY":(s==1?"SELL":"none");}

void DashboardDraw()
{
   if(!InpDashboard || !g_visual) return;
   datetime now=TimeCurrent();
   string cur=AccountInfoString(ACCOUNT_CURRENCY);
   int digits=(int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS);
   MqlTick q; bool haveTick=SymbolInfoTick(_Symbol,q) && q.bid>0;
   double spread=haveTick?q.ask-q.bid:0.0;
   bool spreadOK=haveTick && SpreadOK(q);

   // ---------- positions ----------
   int nb=0,ns=0,nRung=0,nCool=0,nCore=0,nLock=0;
   double lb=0,ls=0,pb=0,ps=0,lockVol=0,lockNet=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong t=PositionGetTicket(i);
      if(t==0 || !PositionSelectByTicket(t) || PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      long mg=PositionGetInteger(POSITION_MAGIC);
      if(mg!=InpMagic && mg!=GuardLockMagic()) continue; // momentum shown in its own row
      double net=SelectedPositionNet(), v=PositionGetDouble(POSITION_VOLUME);
      bool buy=((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY);
      ulong id=(ulong)PositionGetInteger(POSITION_IDENTIFIER);
      if(mg==GuardLockMagic()) {nLock++;lockVol+=v;lockNet+=net;continue;}
      if(buy){nb++;lb+=v;pb+=net;} else {ns++;ls+=v;ps+=net;}
      if(IsLimitPositionId(id)) nRung++; else if(IsCoolingPositionId(id)) nCool++; else nCore++;
   }
   // ---------- pendings ----------
   int ob=0,os=0; double nearB=0,nearS=0;
   for(int i=OrdersTotal()-1;i>=0;i--)
   {
      ulong t=OrderGetTicket(i);
      if(t==0 || !OrderSelect(t) || OrderGetString(ORDER_SYMBOL)!=_Symbol || OrderGetInteger(ORDER_MAGIC)!=InpMagic) continue;
      ENUM_ORDER_TYPE ty=(ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      double pr=OrderGetDouble(ORDER_PRICE_OPEN);
      if(ty==ORDER_TYPE_BUY_LIMIT){ob++; if(nearB==0||pr>nearB) nearB=pr;}
      else if(ty==ORDER_TYPE_SELL_LIMIT){os++; if(nearS==0||pr<nearS) nearS=pr;}
   }
   int waitingRefill=0;
   for(int k=0;k<LIMIT_SLOTS;k++)
      if(g_limit_position[k]!=0 && !LimitOrderTicketOpen(g_limit_order[k]) && !IsPositionIdOpen(g_limit_position[k])) waitingRefill++;

   // ---------- account / margin ----------
   double bal=AccountInfoDouble(ACCOUNT_BALANCE), eq=AccountInfoDouble(ACCOUNT_EQUITY);
   double fm=AccountInfoDouble(ACCOUNT_MARGIN_FREE), used=AccountInfoDouble(ACCOUNT_MARGIN);
   double lvl=AccountInfoDouble(ACCOUNT_MARGIN_LEVEL);
   double floating=pb+ps+lockNet;
   double seedMargin=0.0;
   if(haveTick && !OrderCalcMargin(ORDER_TYPE_BUY,_Symbol,InpSeedLot,q.ask,seedMargin)) seedMargin=0.0;
   double seedNeed=seedMargin*2.0*InpMinFreeMarginFactor;
   double projLvl=(used+seedMargin*2.0>0?eq/(used+seedMargin*2.0)*100.0:0.0);
   bool basket=(g_basket_start>0);
   bool trade_ok=CanTradeNow();
   bool clean=(g_clean_symbol_wait_last_log==0);
   bool ledger=!g_technical_pause;
   int nextRecenter=(int)MathMax(0,60-(now-g_recenter_last_time));
   int seedRetry=(int)MathMax(0,InpMinSecondsBetweenSeedAttempts-(now-g_last_seed_attempt));

   // ---------- guard ----------
   int st=g_guard_stage;
   double ratio=MathMax(0.05,MathMin(0.95,InpGuardExitRatio));
   double thrNext=(st<4?GuardThreshold(st+1):0.0);
   double exitAt=(st>0?GuardThreshold(st)*ratio:0.0);
   double sideSum=(g_park_side==0?pb:(g_park_side==1?ps:0.0));
   double buffer=(st>=3?0.0:GuardMoney(InpOverlapBufferDesign));

   // ---------- status / current / next ----------
   string status; color sc;
   if(!trade_ok){status="ALGO TRADING OFF";sc=DC_BAD;}
   else if(!clean){status="WAIT: FOREIGN ORDERS ON SYMBOL";sc=DC_BAD;}
   else if(g_technical_pause){status="PAUSED (AUDIT)";sc=DC_BAD;}
   else if(!basket){status="WAITING FOR SEED";sc=DC_WARN;}
   else if(st>=4){status="GUARD STAGE 4 - LOCK";sc=DC_BAD;}
   else if(st>0){status=StringFormat("GUARD STAGE %d",st);sc=DC_WARN;}
   else {status="GRID RUNNING";sc=DC_OK;}

   string curStep="",next1="",next2="";
   if(!trade_ok) {curStep="Trading disabled in terminal/account"; next1="Enable Algo Trading"; }
   else if(!clean) {curStep="Another magic has orders on "+_Symbol; next1="Remove foreign orders/positions manually";}
   else if(g_technical_pause) {curStep="Audit pause: "+g_technical_reason; next1="Waits for broker/ledger to reconcile";}
   else if(!basket)
   {
      curStep="Preparing BUY+SELL seed "+DoubleToString(InpSeedLot,2)+" lots";
      if(!spreadOK) next1=StringFormat("Spread %.3f must be <= %.3f",spread,InpMaxSpreadPrice);
      else if(fm<seedNeed) next1=StringFormat("Need free margin %.2f (have %.2f)",seedNeed,fm);
      else if(projLvl<InpNoNewOrderBelowMarginLevel) next1=StringFormat("Projected level %.0f%% < %.0f%%",projLvl,InpNoNewOrderBelowMarginLevel);
      else if(seedRetry>0) next1=StringFormat("Seed attempt in %ds",seedRetry);
      else next1="Opening seed pair now";
      next2=(g_block_reason!=""?"Last block: "+g_block_reason:"");
   }
   else if(st==0)
   {
      curStep="Grid working: TP closes + refills";
      if(!g_geo_verified) next1="Repairing grid geometry (3s retry)";
      else if(waitingRefill>0) next1=StringFormat("Refill %d rung(s) at next pass",waitingRefill);
      else next1=StringFormat("Recenter grid in %ds",nextRecenter);
      next2=StringFormat("Guard stage 1 if DD >= %.2f (now %.2f)",GuardThreshold(1),g_guard_dd);
   }
   else if(st==1)
   {
      curStep=SideName(g_park_side)+" side parked: no new rungs / cooling";
      next1=StringFormat("Stage 2 (overlap) at DD %.2f",thrNext);
      next2=StringFormat("Back to normal when DD < %.2f",exitAt);
   }
   else if(st<=3)
   {
      curStep=StringFormat("Overlap + BE exit active (buffer %.2f)",buffer);
      double miss=buffer-(g_guard_pool+sideSum);
      next1=(miss>0?StringFormat("BE exit of %s side needs +%.2f more",SideName(g_park_side),miss):"BE exit condition met");
      next2=StringFormat("Stage %d at %.2f | down when < %.2f",st+1,thrNext,exitAt);
   }
   else
   {
      curStep=StringFormat("Lock %.2f lots active, overlap feeding",lockVol);
      next1=StringFormat("Lock closes when DD < %.2f",GuardThreshold(3)*ratio);
      next2=StringFormat("Stage 3 when DD < %.2f",exitAt);
   }

   // ---------- layout ----------
   int rh=DRowH(), cw=DColW(), pad=6;
   g_dx[0]=InpDashX+pad; g_dx[1]=InpDashX+pad*2+cw;
   g_dy0=InpDashY+rh*2+pad;
   int rows=30;
   DRect("bg",InpDashX,InpDashY,cw*2+pad*3,rh*(rows+2)+pad*2,DC_BG,DC_LINE);
   DRect("title",InpDashX+1,InpDashY+1,cw*2+pad*3-2,rh*2,DC_PANEL,DC_PANEL);
   DText("t1",InpDashX+pad+2,InpDashY+4,"HEDGE BASKET  "+_Symbol,DC_TXT,false,true,InpDashFont+2);
   DText("t2",InpDashX+cw*2+pad*2,InpDashY+4,status,sc,true,true,InpDashFont+2);
   DText("t3",InpDashX+pad+2,InpDashY+rh+4,
         StringFormat("v3.68 | magic %I64d | %s | lot scale %.4f (%.0f%% of full) | %s",
                      (long)InpMagic,cur,g_lot_scale,
                      (g_detect_lot_scale>0?100.0*g_lot_scale/g_detect_lot_scale:100.0),
                      TimeToString(now,TIME_SECONDS)),DC_DIM);

   // LEFT column
   int r=0;
   DHead(0,r++,"NOW");
   DLine(0,r++,"> "+curStep,DC_TXT);
   DLine(0,r++,"Next: "+next1,DC_ACC);
   DLine(0,r++,next2==""?" ":"      "+next2,DC_DIM);
   DHead(0,r++,"ACCOUNT");
   DRow(0,r++,"Balance / Equity",StringFormat("%.2f / %.2f %s",bal,eq,cur),DC_TXT);
   DRow(0,r++,"Floating net",Money(floating),floating>=0?DC_OK:DC_BAD);
   DRow(0,r++,"Free margin / Level",StringFormat("%.2f / %s",fm,used>0?StringFormat("%.0f%%",lvl):"--"),
        (used<=0||lvl>=InpNoNewOrderBelowMarginLevel)?DC_TXT:DC_BAD);
   DRow(0,r++,"Commission / lot (rt)",StringFormat("%.2f",g_comm_per_lot),DC_TXT);
   DHead(0,r++,"POSITIONS");
   DRow(0,r++,"BUY  count / lots / net",StringFormat("%d / %.2f / %s",nb,lb,Money(pb)),pb>=0?DC_BUY:DC_BAD);
   DRow(0,r++,"SELL count / lots / net",StringFormat("%d / %.2f / %s",ns,ls,Money(ps)),ps>=0?DC_SELL:DC_BAD);
   DRow(0,r++,"Roles core / rungs / cooling",StringFormat("%d / %d / %d",nCore,nRung,nCool),DC_TXT);
   DRow(0,r++,"Net exposure (lots)",StringFormat("%+.2f",lb-ls),DC_TXT);
   DHead(0,r++,"GRID");
   DRow(0,r++,"Pending BUY / SELL",StringFormat("%d / %d  (of 40 / 40)",ob,os),DC_TXT);
   DRow(0,r++,"Nearest BUY lim / dist",nearB>0&&haveTick?StringFormat("%s / %.3f",DoubleToString(nearB,digits),q.ask-nearB):"--",DC_BUY);
   DRow(0,r++,"Nearest SELL lim / dist",nearS>0&&haveTick?StringFormat("%s / %.3f",DoubleToString(nearS,digits),nearS-q.bid):"--",DC_SELL);
   DRow(0,r++,"Spacing / anchor",StringFormat("%.3f / %s",GridSpacing(),g_recenter_anchor_mid>0?DoubleToString(g_recenter_anchor_mid,digits):"--"),DC_TXT);
   DRow(0,r++,"Next recenter",basket?StringFormat("%ds",nextRecenter):"--",DC_TXT);
   DRow(0,r++,"Rungs waiting refill",IntegerToString(waitingRefill),waitingRefill>0?DC_WARN:DC_TXT);
   DRow(0,r++,"Spread / max",StringFormat("%.3f / %.3f",spread,InpMaxSpreadPrice),spreadOK?DC_OK:DC_BAD);
   DRow(0,r++,"Seed lot / grid lots",StringFormat("%.2f / %.2f..%.2f",InpSeedLot,ScaledLot(1.0),ScaledLot(10.0)),DC_TXT);
   DHead(0,r++,"PERFORMANCE");
   double ping=TerminalInfoInteger(TERMINAL_PING_LAST)/1000.0;
   DRow(0,r++,"Broker ping",StringFormat("%.0f ms",ping),ping<=60?DC_OK:(ping<=120?DC_WARN:DC_BAD));
   DRow(0,r++,"Timer pass avg / max",StringFormat("%.0f / %.0f ms",g_perf_timer_ema,g_perf_timer_max),g_perf_timer_max<500?DC_TXT:DC_WARN);
   DRow(0,r++,"Tick pass avg / max",StringFormat("%.0f / %.0f ms",g_perf_tick_ema,g_perf_tick_max),g_perf_tick_max<500?DC_TXT:DC_WARN);
   DRow(0,r++,"Req/min | in flight | lazy far",StringFormat("%d | %d | %d",MathMax(g_req_last_min,g_req_this_min),g_async_inflight,g_far_lazy),DC_TXT);
   DRow(0,r++,"Refills 1m / 5m | hist cache",StringFormat("%d / %d | %.0f%%",GHBRefillsLast(60),GHBRefillsLast(300),
        (g_hs_hits+g_hs_miss)>0?100.0*g_hs_hits/(g_hs_hits+g_hs_miss):0.0),DC_TXT);
   while(r<rows) DLine(0,r++," ",DC_TXT);

   // RIGHT column
   r=0;
   DHead(1,r++,"CHECKS");
   DCheck(1,r++,"Algo trading",trade_ok,trade_ok?"allowed":"disabled");
   DCheck(1,r++,"Clean symbol",clean,clean?"only own magic":"foreign orders");
   DCheck(1,r++,"Ledger / audit",ledger,ledger?"healthy":"paused");
   DCheck(1,r++,"Spread filter",spreadOK,StringFormat("%.3f <= %.3f",spread,InpMaxSpreadPrice));
   DCheck(1,r++,"Seed free margin",fm>=seedNeed,StringFormat("%.0f / need %.0f",fm,seedNeed),!basket);
   DCheck(1,r++,"Projected margin level",projLvl>=InpNoNewOrderBelowMarginLevel,StringFormat("%.0f%% / min %.0f%%",projLvl,InpNoNewOrderBelowMarginLevel),!basket);
   DCheck(1,r++,"Grid geometry",g_geo_verified,g_geo_verified?"verified":"repairing",basket);
   DCheck(1,r++,"Refills",waitingRefill==0,waitingRefill==0?"none waiting":IntegerToString(waitingRefill)+" waiting",basket);
   DHead(1,r++,"TREND GUARD");
   color stc=(st==0?DC_OK:(st<4?DC_WARN:DC_BAD));
   DRow(1,r++,"Stage",StringFormat("%d / 4%s",st,InpGuardEnabled?"":"  (disabled)"),stc);
   double top=GuardThreshold(4);
   DBar(1,r++,top>0?g_guard_dd/top:0.0,stc,StringFormat("DD %.2f of %.2f",g_guard_dd,top));
   DRow(1,r++,"Thresholds S1/S2/S3/S4",StringFormat("%.0f/%.0f/%.0f/%.0f",GuardThreshold(1),GuardThreshold(2),GuardThreshold(3),GuardThreshold(4)),DC_TXT);
   DRow(1,r++,"Next stage at / exit below",StringFormat("%s / %s",st<4?DoubleToString(thrNext,2):"max",st>0?DoubleToString(exitAt,2):"--"),DC_TXT);
   DRow(1,r++,"Parked side",SideName(g_park_side),g_park_side>=0?DC_WARN:DC_TXT);
   DRow(1,r++,"Realized pool (episode)",st>=2?Money(g_guard_pool):"--",g_guard_pool>=0?DC_OK:DC_BAD);
   DRow(1,r++,"Lock",nLock>0?StringFormat("%.2f lots / %s",lockVol,Money(lockNet)):"none",nLock>0?DC_WARN:DC_TXT);
   DHead(1,r++,"RECENT EVENTS");
   for(int i=0;i<6;i++) DLine(1,r++,i<g_ev_n?g_ev[i]:" ",i==0?DC_TXT:DC_DIM);
   DHead(1,r++,"ADAPTIVE TREND ENGINE");
   string tm=(!InpTrendEngine?"disabled":(g_trend_dir==0?"RANGE":(g_trend_dir>0?"TREND UP":"TREND DOWN")));
   DRow(1,r++,"Mode / score",StringFormat("%s / %d of 5 (on %d)",tm,g_tr_score,InpTrendScoreOn),g_trend_dir==0?DC_OK:DC_WARN);
   DRow(1,r++,"Slope ATR | ADX | ATR ratio",StringFormat("%+.2f | %.0f | %.2f",g_tr_slope,g_tr_adx,g_tr_atr_ratio),DC_TXT);
   DRow(1,r++,"Fill burst | adverse spacing",StringFormat("%s | %.3f",g_tr_burst_dir>0?"SELL side":(g_tr_burst_dir<0?"BUY side":"none"),
        g_trend_dir!=0?GridSpacing()*MathMax(1.0,InpTrendSpacingMult):GridSpacing()),DC_TXT);
   DRow(1,r++,"Momentum legs / stop / net",StringFormat("%d / %s / %s",g_mom_open,g_mom_pending?"armed":"none",Money(g_mom_net)),
        g_mom_open>0?(g_mom_net>=0?DC_OK:DC_BAD):DC_TXT);
   while(r<rows) DLine(1,r++," ",DC_TXT);
   ChartRedraw(0);
}

void GuardTick()
{
   TrendTick(); // v3.66
   GuardUpdateStage();
   GuardLock();
   if(!InpDashboard) GuardPanel();
}

void GHBTimerBody()
{
   UpdateCommissionEstimate(); // v3.57: every 60s; TPs follow on the next sweep
   DashboardDraw();            // v3.60: refresh even while waiting/paused
   if(ProcessVerifiedFlatLegacyPendingMigration()) return;
   // Foreign positions/orders must NOT cause INIT_FAILED or a duplicate grid.
   // An existing VPS EA must be stopped separately; this EA never removes it.
   if(WaitForCleanSymbol()) return;
   GuardTick(); // v3.59 trend guard: stage, lock, panel
   // Run even without our basket: old GHB GTC pending orders outlive old EAs.
   if(!RunHistoricBasketTakeover())
   {LogRecenterDecision("LEGACY_TAKEOVER_BLOCK");return;}
   RememberHistoricLiveTierPositions();
   if(ResumeIncompleteSeedPair()) return;
   if(HandleFlatBasketRestart()) return;
   if(g_basket_start<=0) return;
   ReconcileLimitFills();
   RecoverLimitSlotState();
   RecoverOpenTradeRolesFromHistory();
   PurgeClosedFilledLimits();
   ReconcileCancelledLimitOrders();
   if(HandleFlatBasketRestart()) return;
   if(GuardDeRisk()) return; // v3.59 BE exit / overlap, one group per pass
   // Risk-reducing broker pending cancellation is allowed even if the
   // accounting ledger is paused; no new positions are opened here.
   if(EnforceBrokerGridExposure()) return;
   if(CloseOneOwnedAtIndividualTarget()) return;
   ReconcileAllOwnedTargets();
   QuarantineOccupiedTierPendings();
   if(ReduceOneGridPendingLot()) return;
   MaybeRecenterPendingGrid();
   UpgradeOneExistingGridPending();
   if(!g_technical_pause)
   {
      RefillActivatedLimits();
      RetryMissingSeedLimits();
   }
   AuditLimitRefills();
}

void GHBTickBody()
{
   if(ProcessVerifiedFlatLegacyPendingMigration()) return;
   if(WaitForCleanSymbol()) return;
   // Cancel verified older-grid pendings and migrate existing TP before any
   // new grid, seed, counter or repeat orders can be submitted.
   if(!RunHistoricBasketTakeover()) return;
   RememberHistoricLiveTierPositions();
   if(ResumeIncompleteSeedPair()) return;
   if(g_basket_start>0)
   {
      ReconcileOriginalTakeProfit(g_repeat_position[0],ORDER_TYPE_BUY);
      ReconcileOriginalTakeProfit(g_repeat_position[1],ORDER_TYPE_SELL);
      RefreshRepeatTPFromLive(0);
      RefreshRepeatTPFromLive(1);
      if(g_expected_positions>=3 && g_grid_direction!=0)
      {
         ENUM_ORDER_TYPE trend=(g_grid_direction==1 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL);
         ReconcileTrendTakeProfit(g_third_id,trend);
         if(g_expected_positions>=4) ReconcileTrendTakeProfit(g_fourth_id,trend);
      }
   }
   ReconcileLimitFills();
   RecoverLimitSlotState();
   RecoverOpenTradeRolesFromHistory();
   PurgeClosedFilledLimits();
   ReconcileCancelledLimitOrders();
   if(HandleFlatBasketRestart()) return;
   // Risk-reducing broker pending cancellation is allowed even if the
   // accounting ledger is paused; no new positions are opened here.
   if(EnforceBrokerGridExposure()) return;
   if(CloseOneOwnedAtIndividualTarget()) return;
   ReconcileAllOwnedTargets();
   ExpireLimitOrdersIfNeeded();
   QuarantineOccupiedTierPendings();
   if(ReduceOneGridPendingLot()) return;
   MaybeRecenterPendingGrid();
   ManageRepeatSeedEntries();
   if(!g_technical_pause)
   {
      RefillActivatedLimits();
      RetryMissingSeedLimits();
   }
   AuditLimitRefills();
   BasketState b;ScanBasket(b);           // CORE positions only
   BasketState all;ScanBasket(all,true); // Including the optional countertrade
   datetime now=TimeCurrent();
   // The counter might be the very last trade left. Its profitable TP should
   // still be able to spawn the one-time follow instead of resetting the state.
   if(all.count==0 && g_counter_placed && !g_follow_once && g_basket_start>0)
   {
      OpenFollowAfterCounter();
      if(g_exit_in_progress || g_technical_pause) return;
      ScanBasket(b);
      ScanBasket(all,true);
   }
   if(all.count==0 && HandleFlatBasketRestart()) return;
   if(all.count>0)
   {
      g_had_positions=true;
      if(g_counter_placed && g_counter_id==0)
      {
         PauseForTechnicalAudit("counter submitted but stable identifier not confirmed");
         return;
      }
      // Counter and follow are non-core positions. After counter TP, the new
      // 0.40 follow occupies its own non-core slot: it is NOT an unknown hedge.
      int counter_open=(IsCounterPresent() ? 1 : 0);
      int follow_open=(IsPositionIdOpen(g_follow_id) ? 1 : 0);
      int limit_open=OpenLimitPositionCount();
      int repeat_open=0;
      for(int side=0;side<2;side++)
         if(IsReplacementId(g_repeat_position[side]) && IsPositionIdOpen(g_repeat_position[side])) repeat_open++;
      int cooling_open=CoolingOpenCount();
      if(all.count>LIMIT_SLOTS+18 || all.count-b.count!=counter_open+follow_open+limit_open+repeat_open+cooling_open ||
         (g_follow_once && g_follow_id==0))
      {
         PauseForTechnicalAudit("unknown non-core trade or follow identifier");
         return;
      }
      // Do not misinterpret individually profitable exits as broken hedge legs.
      // Every OPEN position must be tracked; every MISSING previously opened
      // CORE leg must have a confirmed booked profit, otherwise fail safely.
      bool ledger_valid=(g_basket_start>0 && g_expected_positions>=2 &&
         g_expected_positions<=4 && g_seed_buy_id>0 && g_seed_sell_id>0 &&
         (g_expected_positions==2 ? g_grid_direction==0 : g_grid_direction!=0) &&
         (g_expected_positions<3 || g_third_id>0) &&
         (g_expected_positions<4 || g_fourth_id>0) &&
         b.count<=4 && all.count<=LIMIT_SLOTS+18 && BasketVolumesValid() &&
         TrackedPositionHealthy(g_seed_buy_id,true) &&
         TrackedPositionHealthy(g_seed_sell_id,true) &&
         TrackedPositionHealthy(g_third_id,g_expected_positions>=3) &&
         TrackedPositionHealthy(g_fourth_id,g_expected_positions>=4) &&
         TrackedPositionHealthy(g_follow_id,g_follow_once && g_follow_id>0));
      for(int side=0;side<2;side++)
         if(IsReplacementId(g_repeat_position[side]) &&
            !TrackedPositionHealthy(g_repeat_position[side],true)) ledger_valid=false;
      for(int j=0;j<LIMIT_SLOTS;j++)
         if(g_limit_position[j]>0 && !TrackedPositionHealthy(g_limit_position[j],true))
            ledger_valid=false;
      for(int j=0;j<ArraySize(g_limit_filled_ids);j++)
         if(IsPositionIdOpen(g_limit_filled_ids[j]) &&
            !TrackedPositionHealthy(g_limit_filled_ids[j],true)) ledger_valid=false;
      if(!ledger_valid)
      {
         // Keep the full diagnostics but emit them at most every 20 seconds.
         static datetime lastLedgerDetail=0;
         if(now-lastLedgerDetail>=20)
         {
            lastLedgerDetail=now;
         if(!g_technical_pause || now-g_last_technical_log>=30)
            PrintFormat("HBv3.30 LEDGER ERROR | stage=%d core=%d all=%d buyid=%I64u buyOpen=%d sellid=%I64u sellOpen=%d thirdid=%I64u thirdOpen=%d fourthid=%I64u fourthOpen=%d followid=%I64u followOpen=%d",
                     g_expected_positions,b.count,all.count,
                     g_seed_buy_id,IsPositionIdOpen(g_seed_buy_id),
                     g_seed_sell_id,IsPositionIdOpen(g_seed_sell_id),
                     g_third_id,IsPositionIdOpen(g_third_id),
                     g_fourth_id,IsPositionIdOpen(g_fourth_id),
                     g_follow_id,IsPositionIdOpen(g_follow_id));
         // Diagnostic only: never bypass the incomplete-ledger safety pause.
         double legNet=0.0; datetime legExit=0;
         if(g_seed_buy_id>0 && !IsPositionIdOpen(g_seed_buy_id) &&
            !ClosedPositionReport(g_seed_buy_id,legNet,legExit))
            PrintFormat("HBv3.33 MISSING CLOSED HISTORY | seedBUY id=%I64u",g_seed_buy_id);
         if(g_seed_sell_id>0 && !IsPositionIdOpen(g_seed_sell_id) &&
            !ClosedPositionReport(g_seed_sell_id,legNet,legExit))
            PrintFormat("HBv3.33 MISSING CLOSED HISTORY | seedSELL id=%I64u",g_seed_sell_id);
         if(g_third_id>0 && !IsPositionIdOpen(g_third_id) &&
            !ClosedPositionReport(g_third_id,legNet,legExit))
            PrintFormat("HBv3.33 MISSING CLOSED HISTORY | third id=%I64u",g_third_id);
         if(g_fourth_id>0 && !IsPositionIdOpen(g_fourth_id) &&
            !ClosedPositionReport(g_fourth_id,legNet,legExit))
            PrintFormat("HBv3.33 MISSING CLOSED HISTORY | fourth id=%I64u",g_fourth_id);
         // v3.34: report the exact failing condition instead of a generic error.
         // No bypass of ledger protection and no unsafe recovery trades.
         PrintFormat("HBv3.34 LEDGER DETAIL | basket=%d stage=%d grid=%d core=%d all=%d volumes=%d limitOpen=%d repeatOpen=%d coolingOpen=%d seedBuyOK=%d seedSellOK=%d thirdOK=%d fourthOK=%d followOK=%d",
                     (int)(g_basket_start>0),g_expected_positions,g_grid_direction,b.count,all.count,
                     (int)BasketVolumesValid(),limit_open,repeat_open,cooling_open,
                     (int)TrackedPositionHealthy(g_seed_buy_id,true),
                     (int)TrackedPositionHealthy(g_seed_sell_id,true),
                     (int)TrackedPositionHealthy(g_third_id,g_expected_positions>=3),
                     (int)TrackedPositionHealthy(g_fourth_id,g_expected_positions>=4),
                     (int)TrackedPositionHealthy(g_follow_id,g_follow_once && g_follow_id>0));
         for(int j=0;j<LIMIT_SLOTS;j++)
            if(g_limit_position[j]>0 && !TrackedPositionHealthy(g_limit_position[j],true))
               PrintFormat("HBv3.34 LEDGER BAD LIMIT | slot=%d id=%I64u open=%d",j,g_limit_position[j],(int)IsPositionIdOpen(g_limit_position[j]));
         for(int side=0;side<2;side++)
            if(IsReplacementId(g_repeat_position[side]) && !TrackedPositionHealthy(g_repeat_position[side],true))
               PrintFormat("HBv3.34 LEDGER BAD REPEAT | side=%d id=%I64u",side,g_repeat_position[side]);
         PrintFormat("HBv3.35 COOLING PAUSED | BUYcount=%d SELLcount=%d start=%d BUYloss=%.2f SELLloss=%.2f USC; blocked until ledger healthy",
                     CoolingBasePositions(POSITION_TYPE_BUY),CoolingBasePositions(POSITION_TYPE_SELL),InpCoolingStartPositions,
                     SideLossUSC(POSITION_TYPE_BUY),SideLossUSC(POSITION_TYPE_SELL));
         }
         PauseForTechnicalAudit("incomplete ledger or broker report not synchronized");
         return;
      }
      // State successfully reconciled: resume independent LIMIT and trend management.
      ResumeAfterAudit();
      // New feature runs only after the existing live-basket ledger validates.
      ManageSideLossCooling();
      // Exit requests always take priority over the spread/new-order filters.
      if(g_exit_in_progress)
      {
         if(CanTradeNow()) CloseAll("pending close retries");
         return;
      }
      // User-requested NO individual SL: verify only independent TPs where expected.
      for(int p=0;p<PositionsTotal();p++)
      {
         ulong ticket=PositionGetTicket(p);
         if(!IsOwnPosition(ticket)) continue;
         ulong id=(ulong)PositionGetInteger(POSITION_IDENTIFIER);
         bool has_own_tp=(id==g_seed_buy_id || id==g_seed_sell_id ||
                           id==g_third_id || id==g_fourth_id ||
                           id==g_counter_id || id==g_follow_id || IsLimitPositionId(id) || IsReplacementId(id));
         if(has_own_tp && PositionGetDouble(POSITION_TP)<=0)
         {
            PrintFormat("HBv3.30 WARNING: independent TP missing on ticket=%I64u; no auto-liquidation",ticket);
         }
      }
      // On terminal restart, manage existing positions under this EA's magic.
      double net=0.0;
      if(!BasketNetPnL(all,net))
      {
         PauseForTechnicalAudit("cannot verify realized basket PnL");
         return;
      }
      if(net>g_peak_net)
      {
         g_peak_net=net;
         if(g_peak_net>=InpProfitLockArm)
            GlobalVariableSet(g_peak_key,g_peak_net);
      }
      if(!InpIndividualTPOnly && InpCloseWholeOnProfit && net>=InpBasketTakeProfit+InpExitCostReserve)
      {
         RequestBasketExit();
         if(CanTradeNow()) CloseAll("basket profit reached");
         return;
      }
      // Preserve profits produced by the third and fourth legs on reversals.
      if(!InpIndividualTPOnly && InpCloseWholeOnGiveback && g_expected_positions>=3 && g_peak_net>=InpProfitLockArm &&
         net<=g_peak_net-InpProfitLockGiveback)
      {
         RequestBasketExit();
         if(CanTradeNow()) CloseAll("basket profit gave back from peak");
         return;
      }
      // NO financial stop-loss or daily loss cap: exposure remains until TP/manual/technical exit.
      // Both sides may legitimately have multiple winning positions after
      // the counter and follow order. Do not liquidate for that alone.
      MqlTick reversal_tick;
      if(SymbolInfoTick(_Symbol,reversal_tick))
      {
         // Use persistent grid direction, not live side count: after the
         // a winning original closes, stage 3 may have only 1 BUY and 1 SELL.
         if(!InpIndividualTPOnly && InpCloseWholeOnReversal &&
            ((g_grid_direction==1 && reversal_tick.bid<=b.last_buy_price-InpReversalExitPrice) ||
             (g_grid_direction==-1 && reversal_tick.ask>=b.last_sell_price+InpReversalExitPrice)))
         {
            RequestBasketExit();
            if(CanTradeNow()) CloseAll("one-way basket reversed");
            return;
         }
      }
      // A briefly balanced hedge is not an error with independent pair TPs.
      if(!InpIndividualTPOnly && InpMaxBasketMinutes>0 && b.oldest_open>0 &&
         now-b.oldest_open>=InpMaxBasketMinutes*60)
      {
         RequestBasketExit();
         if(CanTradeNow()) CloseAll("basket timed out");
         return;
      }
      // New 0.40 trend follow triggers ONLY after the 0.20 counter is booked
      // as profitable and fully closed. It has an independent broker TP.
      OpenFollowAfterCounter();
      if(g_exit_in_progress || g_technical_pause) return;
      // Winning BUY/BUY or SELL/SELL pairs close independently of the basket.
      if(!InpIndividualTPOnly) CloseProfitableSameSidePair();
      if(g_exit_in_progress) return;
      // Trailing a seed is position-specific and should not depend on
      // the spread filter used only for opening new orders.
      if(!CanTradeNow()) return;
      MqlTick tick;
      if(!SymbolInfoTick(_Symbol,tick) || !SpreadOK(tick)) return;
      // Re-scan after profitable pair exits; never use stale last prices.
      ScanBasket(b);
      // Temporary counter is opportunistic after an observable pullback. It
      // does NOT change the core stage (2/3/4) or the core BUY/SELL counts.
      UpdateCounterReversalExtreme(tick);
      bool counter_was_placed=g_counter_placed;
      OpenOnePullbackCounter(b,tick);
      if(g_exit_in_progress || g_technical_pause || (!counter_was_placed && g_counter_placed)) return;
      datetime last_trade=b.newest_open;
      if(g_last_add_attempt>last_trade) last_trade=g_last_add_attempt;
      if(now-last_trade<InpMinSecondsBetweenAdds) return;
      // Stage 2 -> 3: only after seed breaks out 2.00 gold price units.
      // Stage 3 -> 4: add ONE MORE CORE position to SAME winning side after 0.80.
      // Optional counter is separately managed, with its own TP and no position SL.
      bool attempted=false;
      ENUM_ORDER_TYPE direction=ORDER_TYPE_BUY;
      string comment="";
      double seed_mid=(g_limit_seed_buy_price+g_limit_seed_sell_price)*0.5;
      double price_epsilon=_Point*0.0001; // floating point rounding only
      if(g_expected_positions==2 && (IsPositionIdOpen(g_seed_buy_id) || IsPositionIdOpen(g_seed_sell_id) ||
         IsPositionIdOpen(g_repeat_position[0]) || IsPositionIdOpen(g_repeat_position[1])) &&
         g_limit_seed_buy_price>0 && g_limit_seed_sell_price>0)
      {
         if(tick.bid+price_epsilon>=seed_mid+InpGridStepPrice)
         { attempted=true;direction=ORDER_TYPE_BUY;comment="HB THIRD BUY"; }
         else if(tick.ask-price_epsilon<=seed_mid-InpGridStepPrice)
         { attempted=true;direction=ORDER_TYPE_SELL;comment="HB THIRD SELL"; }
      }
      else if(g_expected_positions==3 && g_grid_direction==1 && IsPositionIdOpen(g_third_id) &&
              tick.bid+price_epsilon>=b.last_buy_price+InpFourthStepPrice)
      { attempted=true;direction=ORDER_TYPE_BUY;comment="HB FOURTH BUY"; }
      else if(g_expected_positions==3 && g_grid_direction==-1 && IsPositionIdOpen(g_third_id) &&
              tick.ask-price_epsilon<=b.last_sell_price-InpFourthStepPrice)
      { attempted=true;direction=ORDER_TYPE_SELL;comment="HB FOURTH SELL"; }
      if(attempted && MarginOK(direction,1.0))
      {
         g_last_add_attempt=now;
         bool filled=(direction==ORDER_TYPE_BUY ? OpenBuy(comment) : OpenSell(comment));
         BasketState after;ScanBasket(after);
         if(!filled || after.count!=b.count+1 || !BasketVolumesValid())
         {
            PauseForTechnicalAudit("unexpected grid fill: failed or partially executed");
         }
         else
         {
            if(g_expected_positions==2)
            {
               g_grid_direction=(direction==ORDER_TYPE_BUY ? 1 : -1);
               GlobalVariableSet(g_direction_key,(double)g_grid_direction);
               // Best-price reversal observation begins from third entry.
               g_counter_third_time=now;
               g_counter_third_price=(g_grid_direction==1 ? after.last_buy_price : after.last_sell_price);
               g_counter_best=(g_grid_direction==1 ? tick.bid : tick.ask);
               g_counter_retrace_since=0;
               GlobalVariableSet(g_counter_third_time_key,(double)g_counter_third_time);
               GlobalVariableSet(g_counter_third_price_key,g_counter_third_price);
               GlobalVariableSet(g_counter_best_key,g_counter_best);
            }
            ulong stage_id=0;
            if(!FindNewOwnedPositionId(b,stage_id))
            {
               PauseForTechnicalAudit("core rung identifier not confirmed"); return;
            }
            if(g_expected_positions==2)
            {
               g_third_id=stage_id;
               GlobalVariableSet(g_third_id_key,(double)stage_id);
            }
            else
            {
               g_fourth_id=stage_id;
               GlobalVariableSet(g_fourth_id_key,(double)stage_id);
            }
            SetExpectedPositions(g_expected_positions+1);
            ReconcileTrendTakeProfit(stage_id,direction);
            PrintFormat("HBv3.30 GRID added %s; stage=%d/4 open=%d BUY=%d SELL=%d",
                        comment,g_expected_positions,after.count,after.buys,after.sells);
         }
      }
      if(InpPrintStatusEverySeconds>0 &&
         now-g_last_status>=InpPrintStatusEverySeconds)
      {
         g_last_status=now;
         PrintFormat("HEDGE BASKET | positions=%d BUY=%d SELL=%d net=%.2f target=%.2f | NO STOP",
                     b.count,b.buys,b.sells,net,InpBasketTakeProfit);
      }
      return;
   }

   // Pending-only is a valid state for the continuously cycling broker ladder.
   // Never delete all ten levels merely because the last filled TP closed.
   if(!g_exit_in_progress && g_basket_start>0 &&
      (OwnedPendingCount()>0 || RepeatRearmOutstanding()))
      return; // auto-enabled flat restart was handled and verified above
   // Fully flat and no remaining pending orders: finish basket and cooldown.
   if(FixedNetworkPendingOrIncomplete()) return;
   if(g_exit_in_progress || g_had_positions || g_basket_start>0 || OwnedPendingCount()>0)
   {
      if(OwnedPendingCount()>0)
      {
         CancelOwnPendingOrders();
         if(OwnedPendingCount()>0) return; // do not forget tickets while still at broker
      }
      g_exit_in_progress=false;
      g_had_positions=false;
      g_last_exit_time=now;
      GlobalVariableSet(g_exit_key,(double)now);
      ResetBasketState();
      Print("HBv3.30 basket now flat (all positions closed); cooldown started.");
      return;
   }
   if(!CanTradeNow())
   {
      EntryBlocked(StringFormat("ALGO_TRADING_DISABLED terminal=%d EA=%d accountTrade=%d accountEA=%d (1=allowed, 0=blocked)",
         (int)TerminalInfoInteger(TERMINAL_TRADE_ALLOWED),(int)MQLInfoInteger(MQL_TRADE_ALLOWED),
         (int)AccountInfoInteger(ACCOUNT_TRADE_ALLOWED),(int)AccountInfoInteger(ACCOUNT_TRADE_EXPERT)));
      return;
   }
   bool foreignPositions=HasOtherPositionsOnSymbol();
   bool foreignOrders=HasOtherPendingOrdersOnSymbol();
   if(!InpAllowParallelMagic && foreignPositions)
   {
      EntryBlocked("SYMBOL_OCCUPIED: another EA/manual position; set InpAllowParallelMagic only if you accept aggregate exposure");
      return;
   }
   if(!InpAllowParallelMagic && foreignOrders)
   {
      EntryBlocked("OLD_PENDING_ORDERS: previous EA GTC orders; coexistence OFF");
      return;
   }
   if(foreignPositions || foreignOrders) ReportParallelMagicExposure();
   int requiredCooldown=(g_flat_restart_pending ? InpFlatRestartCooldownSeconds : InpCooldownSeconds);
   if(g_last_exit_time!=0 && now-g_last_exit_time<requiredCooldown)
   {
      EntryBlocked(StringFormat("COOLDOWN remaining=%d seconds flatRestart=%s",
                                (int)(requiredCooldown-(now-g_last_exit_time)),
                                g_flat_restart_pending?"YES":"NO"));
      return;
   }
   if(g_last_seed_attempt!=0 && now-g_last_seed_attempt<InpMinSecondsBetweenSeedAttempts)
   {
      EntryBlocked(StringFormat("SEED_RETRY_WAIT remaining=%d seconds",(int)(InpMinSecondsBetweenSeedAttempts-(now-g_last_seed_attempt))));
      return;
   }
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol,tick) || tick.bid<=0 || tick.ask<=0)
   {
      EntryBlocked("NO_VALID_TICK: broker quote unavailable");
      return;
   }
   if(!SpreadOK(tick))
   {
      EntryBlocked(StringFormat("SPREAD_TOO_HIGH current=%.3f max=%.3f",tick.ask-tick.bid,InpMaxSpreadPrice));
      return;
   }
   if(!EstimatedSeedCostOK(tick)) return;
   StartHedgeBasket();
}
//+------------------------------------------------------------------+

// Audit actual broker deal reasons. This does not change any trading decisions.
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   GHBHistoryInvalidate(); // v3.62: broker state changed
   if(trans.type==TRADE_TRANSACTION_REQUEST) GHBCountRequest();
   if(trans.type!=TRADE_TRANSACTION_DEAL_ADD || trans.deal==0) return;
   if(!HistoryDealSelect(trans.deal)) return;
   if(HistoryDealGetString(trans.deal,DEAL_SYMBOL)!=_Symbol) return;
   if(HistoryDealGetInteger(trans.deal,DEAL_MAGIC)==InpMagic)
      g_grid_geometry_dirty=true;
   ulong id=(ulong)HistoryDealGetInteger(trans.deal,DEAL_POSITION_ID);
   ulong entry_order=(ulong)HistoryDealGetInteger(trans.deal,DEAL_ORDER);
   ENUM_DEAL_ENTRY deal_entry=(ENUM_DEAL_ENTRY)HistoryDealGetInteger(trans.deal,DEAL_ENTRY);
   if(deal_entry==DEAL_ENTRY_OUT || deal_entry==DEAL_ENTRY_OUT_BY)
   {
      long exitMagic=HistoryDealGetInteger(trans.deal,DEAL_MAGIC);
      long exitReason=HistoryDealGetInteger(trans.deal,DEAL_REASON);
      double exitGross=HistoryDealGetDouble(trans.deal,DEAL_PROFIT);
      double exitVolume=HistoryDealGetDouble(trans.deal,DEAL_VOLUME);
      if(exitMagic==InpMagic || IsTrackedId(id))
         PrintFormat("HBv3.49 EXIT AUDIT | position=%I64u deal=%I64u reason=%s gross=%.2f volume=%.2f; no basket-close requested",
                     id,trans.deal,EnumToString((ENUM_DEAL_REASON)exitReason),exitGross,exitVolume);
   }
   if((deal_entry==DEAL_ENTRY_IN || deal_entry==DEAL_ENTRY_INOUT) && id>0)
   {
      for(int k=0;k<LIMIT_SLOTS;k++)
      {
         if(g_limit_order[k]!=0 && g_limit_order[k]==entry_order && g_limit_position[k]==0)
         {
            g_limit_position[k]=id;
            GlobalVariableSet(g_limit_position_key[k],(double)id);
            RegisterFilledLimit(id,k);
            PrintFormat("HBv3.30 LIMIT ENTRY | side=%s rung=%d order=%I64u id=%I64u",
                        k<LIMIT_PER_SIDE?"BUY":"SELL",(k%LIMIT_PER_SIDE)+1,entry_order,id);
         }
      }
   }
   if((deal_entry==DEAL_ENTRY_IN || deal_entry==DEAL_ENTRY_INOUT) && id>0)
   {
      for(int side=0;side<2;side++)
      {
         if(g_repeat_order[side]!=0 && g_repeat_order[side]==entry_order)
         {
            g_repeat_position[side]=id;
            g_repeat_order[side]=0;
            GlobalVariableSet(g_repeat_pos_key[side],(double)id);
            GlobalVariableSet(g_repeat_order_key[side],0.0);
            PrintFormat("HBv3.30 REPEAT ENTRY EVENT | %s id=%I64u order=%I64u",side==0?"BUY":"SELL",id,entry_order);
         }
      }
   }
   // Count each independent LIMIT TP exactly once (idempotent across restarts).
   RecordLimitTPDeal(id,trans.deal,HistoryDealGetInteger(trans.deal,DEAL_REASON));
   if(!IsTrackedId(id)) return;
   ENUM_DEAL_ENTRY entry=(ENUM_DEAL_ENTRY)HistoryDealGetInteger(trans.deal,DEAL_ENTRY);
   if(entry!=DEAL_ENTRY_OUT && entry!=DEAL_ENTRY_OUT_BY && entry!=DEAL_ENTRY_INOUT) return;
   int reason=(int)HistoryDealGetInteger(trans.deal,DEAL_REASON);
   double profit=HistoryDealGetDouble(trans.deal,DEAL_PROFIT)
                +HistoryDealGetDouble(trans.deal,DEAL_SWAP)
                +HistoryDealGetDouble(trans.deal,DEAL_COMMISSION)
                +HistoryDealGetDouble(trans.deal,DEAL_FEE);
   string role=(IsLimitPositionId(id)?"BROKER_LIMIT":
                id==g_seed_buy_id?"SEED_BUY":
               id==g_seed_sell_id?"SEED_SELL":
               id==g_third_id?"THIRD":
               id==g_fourth_id?"FOURTH":
               id==g_counter_id?"COUNTER":"FOLLOW");
   PrintFormat("HBv3.30 DEAL CLOSED | role=%s id=%I64u deal=%I64u reason=%s(%d) net_deal=%.2f %s",
               role,id,trans.deal,EnumToString((ENUM_DEAL_REASON)reason),reason,
               profit,AccountInfoString(ACCOUNT_CURRENCY));
}


// ======================= v3.65 RESEARCH STATS =======================
void GHBStatsSample()
{
   datetime now=TimeCurrent();
   if(g_st_start==0) {g_st_start=now;g_st_start_bal=AccountInfoDouble(ACCOUNT_BALANCE);g_st_last_t=now;}
   if(now>g_st_last_t) {g_st_stage_secs[MathMax(0,MathMin(4,g_guard_stage))]+=(long)(now-g_st_last_t);g_st_last_t=now;}
   double eq=AccountInfoDouble(ACCOUNT_EQUITY);
   if(eq>g_st_peak_eq) g_st_peak_eq=eq;
   double dd=g_st_peak_eq-eq;
   if(dd>g_st_max_eq_dd) {g_st_max_eq_dd=dd;g_st_max_dd_time=now;}
   if(g_st_peak_eq>0) g_st_max_eq_dd_pct=MathMax(g_st_max_eq_dd_pct,100.0*dd/g_st_peak_eq);
   if(AccountInfoDouble(ACCOUNT_MARGIN)>0) g_st_min_margin_level=MathMin(g_st_min_margin_level,AccountInfoDouble(ACCOUNT_MARGIN_LEVEL));
   double total,bn,sn,bl,sl; int own,locks;
   GuardFloating(total,bn,sn,bl,sl,own,locks);
   g_st_min_float=MathMin(g_st_min_float,total);
   g_st_max_lots_buy=MathMax(g_st_max_lots_buy,bl);
   g_st_max_lots_sell=MathMax(g_st_max_lots_sell,sl);
   g_st_max_net_lots=MathMax(g_st_max_net_lots,MathAbs(bl-sl));
   g_st_max_pos=MathMax(g_st_max_pos,own);
   int nb=0,ns=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong t=PositionGetTicket(i);
      if(t==0 || !PositionSelectByTicket(t) || PositionGetString(POSITION_SYMBOL)!=_Symbol || PositionGetInteger(POSITION_MAGIC)!=InpMagic) continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY) nb++; else ns++;
   }
   g_st_max_pos_side=MathMax(g_st_max_pos_side,MathMax(nb,ns));
}

string GHBReportText()
{
   string cur=AccountInfoString(ACCOUNT_CURRENCY);
   double bal=AccountInfoDouble(ACCOUNT_BALANCE), eq=AccountInfoDouble(ACCOUNT_EQUITY);
   long span=(long)(TimeCurrent()-g_st_start); if(span<=0) span=1;
   string r="";
   r+="==== HEDGE BASKET v3.68 - RESEARCH REPORT ====\r\n";
   r+=StringFormat("Symbol %s | magic %I64d | %s | %s\r\n",_Symbol,(long)InpMagic,g_tester?"STRATEGY TESTER":"LIVE",cur);
   r+=StringFormat("Period %s -> %s (%.1f days)\r\n",TimeToString(g_st_start),TimeToString(TimeCurrent()),span/86400.0);
   r+=StringFormat("Lot scale %.4f | rung lot cap %d | live window %d | guard %s %.0f/%.0f/%.0f/%.0f real cents\r\n",
                   g_lot_scale,InpRungLotCapDesign,InpLiveWindowPerSide,InpGuardEnabled?"ON":"OFF",
                   InpGuardStage1Design,InpGuardStage2Design,InpGuardStage3Design,InpGuardStage4Design);
   r+="\r\n-- RESULT --\r\n";
   r+=StringFormat("Start balance        %.2f\r\nEnd balance          %.2f\r\nEnd equity           %.2f\r\n",g_st_start_bal,bal,eq);
   r+=StringFormat("Net (equity-start)   %+.2f (%+.2f%%)\r\n",eq-g_st_start_bal,g_st_start_bal>0?100.0*(eq-g_st_start_bal)/g_st_start_bal:0.0);
   if(g_tester)
   {
      r+=StringFormat("Profit factor        %.2f\r\n",TesterStatistics(STAT_PROFIT_FACTOR));
      r+=StringFormat("Trades / win %%       %.0f / %.1f%%\r\n",TesterStatistics(STAT_TRADES),
                      TesterStatistics(STAT_TRADES)>0?100.0*TesterStatistics(STAT_PROFIT_TRADES)/TesterStatistics(STAT_TRADES):0.0);
      r+=StringFormat("Recovery factor      %.2f\r\n",TesterStatistics(STAT_RECOVERY_FACTOR));
   }
   r+="\r\n-- RISK --\r\n";
   r+=StringFormat("Max equity drawdown  %.2f (%.2f%%) at %s\r\n",g_st_max_eq_dd,g_st_max_eq_dd_pct,TimeToString(g_st_max_dd_time));
   r+=StringFormat("Worst floating       %.2f\r\n",g_st_min_float);
   r+=StringFormat("Lowest margin level  %s\r\n",g_st_min_margin_level<1e17?StringFormat("%.0f%%",g_st_min_margin_level):"--");
   r+=StringFormat("Max lots BUY / SELL  %.2f / %.2f | max net %.2f\r\n",g_st_max_lots_buy,g_st_max_lots_sell,g_st_max_net_lots);
   r+=StringFormat("Max positions        %d total | %d on one side\r\n",g_st_max_pos,g_st_max_pos_side);
   r+="\r\n-- TREND GUARD --\r\n";
   for(int i=0;i<=4;i++)
      r+=StringFormat("Stage %d              reached %d times | %.1f%% of time\r\n",i,i==0?0:g_st_stage_hits[i],100.0*g_st_stage_secs[i]/span);
   r+=StringFormat("Overlaps / BE exits / locks   %d / %d / %d\r\n",g_st_overlaps,g_st_be_exits,g_st_locks);
   double momReal=0; int momDeals=0;
   if(HistorySelect(g_st_start,TimeCurrent()+60))
      for(int i=HistoryDealsTotal()-1;i>=0;i--)
      {
         ulong d=HistoryDealGetTicket(i);
         if(d==0 || HistoryDealGetString(d,DEAL_SYMBOL)!=_Symbol || HistoryDealGetInteger(d,DEAL_MAGIC)!=MomMagic()) continue;
         momReal+=HistoryDealGetDouble(d,DEAL_PROFIT)+HistoryDealGetDouble(d,DEAL_SWAP)+HistoryDealGetDouble(d,DEAL_COMMISSION)+HistoryDealGetDouble(d,DEAL_FEE);
         if((ENUM_DEAL_ENTRY)HistoryDealGetInteger(d,DEAL_ENTRY)==DEAL_ENTRY_OUT) momDeals++;
      }
   r+="\r\n-- ADAPTIVE TREND ENGINE --\r\n";
   r+=StringFormat("Trend activations    %d\r\n",g_st_trend_on);
   r+=StringFormat("Momentum closed legs %d | realized %+.2f\r\n",momDeals,momReal);
   r+="\r\n-- ENGINE --\r\n";
   r+=StringFormat("Seed pairs %d | refills %d | audit pauses %d\r\n",g_st_seeds,g_st_refills,g_st_pauses);
   r+=StringFormat("Capital needed (max DD x 1.5) ~ %.2f %s\r\n",g_st_max_eq_dd*1.5,cur);
   return r;
}

void GHBWriteReport()
{
   if(!InpWriteTestReport || g_st_start==0) return;
   string txt=GHBReportText();
   Print(txt);
   string name=StringFormat("GHB_Report_%s_%s.txt",_Symbol,g_tester?"tester":"live");
   int h=FileOpen(name,FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON);
   if(h!=INVALID_HANDLE) {FileWriteString(h,txt);FileClose(h);PrintFormat("HBv3.65 REPORT SAVED | Common\\Files\\%s",name);}
}

// Custom optimisation score: net profit per unit of max equity drawdown.
double OnTester()
{
   double dd=MathMax(1.0,g_st_max_eq_dd);
   return (AccountInfoDouble(ACCOUNT_EQUITY)-g_st_start_bal)/dd;
}

// v3.62: measured entry points. OnTick full management is throttled; the
// 1-second timer runs the same reconciliation, so nothing is skipped for long.
void OnTick()
{
   ulong nowms=GetTickCount64();
   if(!g_tester && InpTickThrottleMs>0 && nowms-g_last_tick_run_ms<(ulong)InpTickThrottleMs) return;
   g_last_tick_run_ms=nowms;
   ulong t0=GetMicrosecondCount();
   GHBTickBody();
   GHBStatsSample();
   GHBPerf(false,GetMicrosecondCount()-t0);
}

void OnTimer()
{
   ulong t0=GetMicrosecondCount();
   GHBTimerBody();
   GHBStatsSample();
   GHBPerf(true,GetMicrosecondCount()-t0);
}
