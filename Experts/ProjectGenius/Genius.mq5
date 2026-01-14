//+------------------------------------------------------------------+
//|                                                       Genius.mq5 |
//|                                                    ProjectGenius |
//+------------------------------------------------------------------+
#property copyright "Gorizont"
#property version   "1.07"

#include <ProjectGenius\Defines.mqh>
#include <ProjectGenius\CsvWriter.mqh>
#include <ProjectGenius\DataStructs.mqh>
#include <ProjectGenius\StateService.mqh>
#include <ProjectGenius\TradeManager.mqh>
#include <ProjectGenius\SignalService.mqh>

// --- ВХОДНЫЕ ПАРАМЕТРЫ ---
input double InpLot        = 0.01; // Стартовый лот
input double InpTakeProfit = 5.0;  // Цель в деньгах ($)
input int    InpMaxSpread  = 14;   // Максимальный спред (в пунктах терминала)
input int    InpStartHour  = 4;    // Час начала торговли
input int    InpEndHour    = 23;   // Час окончания торговли (до 23:00)

// --- ГЛОБАЛЬНЫЕ ОБЪЕКТЫ ---
CCsvWriter     Writer;
TSeriesData    CurrentSeries;
CStateService  StateService("state.csv");
CTradeManager  TradeManager;
CSignalService Signal;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
  {
   Print("Genius: Инициализация...");
   TradeManager.Init(EXPERT_MAGIC);
   
   if(!Signal.Init(_Symbol, _Period)) return(INIT_FAILED);

   if(!StateService.Load(CurrentSeries))
     {
      CurrentSeries.Reset();
     }
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   StateService.Save(CurrentSeries);
  }

//+------------------------------------------------------------------+
//| ПРОВЕРКА ФИЛЬТРОВ (Время + Спред)                                |
//+------------------------------------------------------------------+
bool CheckFilters()
  {
   // 1. Проверка времени
   MqlDateTime dt;
   TimeCurrent(dt);
   
   // Если час меньше старта ИЛИ больше либо равен концу -> выход запрещен
   if(dt.hour < InpStartHour || dt.hour >= InpEndHour)
     {
      return(false); // Не торговое время
     }

   // 2. Проверка спреда
   long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(spread > InpMaxSpread)
     {
      // Можно выводить в коммент, чтобы видеть, почему молчим
      // Comment("Filter: Spread too high: ", spread);
      return(false);
     }
     
   return(true);
  }

void StartNewSeries()
  {
   CurrentSeries.state       = STATE_IN_SERIES;
   CurrentSeries.startTime   = TimeCurrent();
   CurrentSeries.totalTrades = 1;
   CurrentSeries.netProfit   = 0.0;
   StateService.Save(CurrentSeries);
  }

//+------------------------------------------------------------------+
//| Подсчет текущей плавающей прибыли серии                          |
//+------------------------------------------------------------------+
double CalculateSeriesFloatingProfit()
  {
   double profit = 0.0;
   int total = PositionsTotal();
   
   for(int i = 0; i < total; i++)
     {
      ulong ticket = PositionGetTicket(i);
      // Проверяем, что ордер принадлежит нашему советнику (Magic)
      if(PositionGetInteger(POSITION_MAGIC) == EXPERT_MAGIC)
        {
         // Суммируем чистую прибыль и своп
         profit += PositionGetDouble(POSITION_PROFIT);
         profit += PositionGetDouble(POSITION_SWAP);
         
         // POSITION_COMMISSION убрали, так как она устарела.
         // На большинстве счетов она уже учтена в балансе или не видна в позициях.
        }
     }
   return(profit);
  }
//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
  {
   switch(CurrentSeries.state)
     {
      // --- ОЖИДАНИЕ ---
      case STATE_WAIT_SIGNAL:
        {
         // 1. Сначала проверяем фильтры (чтобы не дергать индикатор зря)
         if(!CheckFilters())
           {
            Comment("State: WAIT (Filter Active)\nTime: ", InpStartHour, "-", InpEndHour, 
                    "\nMaxSpread: ", InpMaxSpread, " Current: ", SymbolInfoInteger(_Symbol, SYMBOL_SPREAD));
            return;
           }
        
         // 2. Если фильтры пройдены, смотрим сигнал
         ENUM_SIGNAL_TYPE sig = Signal.CheckSignal();
         Comment("State: WAIT (Searching)\n", Signal.GetDebugString());

         if(sig == SIGNAL_BUY)
           {
            if(TradeManager.OpenBuy(InpLot, _Symbol)) StartNewSeries();
           }
         else if(sig == SIGNAL_SELL)
           {
            if(TradeManager.OpenSell(InpLot, _Symbol)) StartNewSeries();
           }
         break;
        }

      // --- В РАБОТЕ ---
      case STATE_IN_SERIES:
        {
         double currentProfit = CalculateSeriesFloatingProfit();
         
         // Показываем статистику
         Comment("State: IN SERIES\nOrders: ", PositionsTotal(), "\nProfit: ", DoubleToString(currentProfit, 2));

         // Выход по Тейку
         if(currentProfit >= InpTakeProfit)
           {
            Print("Genius: Тейк-профит достигнут! $", currentProfit);
            TradeManager.CloseAll("TP Reached");
            CurrentSeries.netProfit = currentProfit;
            CurrentSeries.state = STATE_FINISHED;
            StateService.Save(CurrentSeries);
           }
         break;
        }

      // --- ЗАВЕРШЕНО ---
      case STATE_FINISHED:
        {
         CurrentSeries.Reset();
         StateService.Save(CurrentSeries);
         break;
        }
     }
  }
//+------------------------------------------------------------------+