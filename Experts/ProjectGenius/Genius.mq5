//+------------------------------------------------------------------+
//|                                                       Genius.mq5 |
//|                                                    ProjectGenius |
//+------------------------------------------------------------------+
#property copyright "Gorizont"
#property version   "1.08"

#include <ProjectGenius\Defines.mqh>
#include <ProjectGenius\CsvWriter.mqh>
#include <ProjectGenius\DataStructs.mqh>
#include <ProjectGenius\StateService.mqh>
#include <ProjectGenius\TradeManager.mqh>
// #include <ProjectGenius\SignalService.mqh> // Пока отключим, логику пишем тут

// --- ВХОДНЫЕ ПАРАМЕТРЫ ---
input double InpLot        = 0.01; 
input double InpTakeProfit = 5.0;  
input int    InpMaxSpread  = 20;   // Чуть увеличил для теста
input int    InpStartHour  = 4;    // Старт в 04:00
input int    InpEndHour    = 23;   

// --- ГЛОБАЛЬНЫЕ ОБЪЕКТЫ ---
CCsvWriter     Writer;
TSeriesData    CurrentSeries;
CStateService  StateService("state.csv");
CTradeManager  TradeManager;

//+------------------------------------------------------------------+
//| Init                                                             |
//+------------------------------------------------------------------+
int OnInit()
  {
   TradeManager.Init(EXPERT_MAGIC);
   if(!StateService.Load(CurrentSeries)) CurrentSeries.Reset();
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Deinit                                                           |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   StateService.Save(CurrentSeries);
  }

//+------------------------------------------------------------------+
//| Start Series                                                     |
//+------------------------------------------------------------------+
void StartNewSeries()
  {
   CurrentSeries.state       = STATE_IN_SERIES;
   CurrentSeries.startTime   = TimeCurrent();
   CurrentSeries.totalTrades = 1;
   CurrentSeries.netProfit   = 0.0;
   StateService.Save(CurrentSeries);
  }

//+------------------------------------------------------------------+
//| Profit Calc (Исправленная версия)                                |
//+------------------------------------------------------------------+
double CalculateSeriesFloatingProfit()
  {
   double profit = 0.0;
   int total = PositionsTotal();
   for(int i = 0; i < total; i++)
     {
      ulong ticket = PositionGetTicket(i);
      if(PositionGetInteger(POSITION_MAGIC) == EXPERT_MAGIC)
        {
         profit += PositionGetDouble(POSITION_PROFIT);
         profit += PositionGetDouble(POSITION_SWAP);
        }
     }
   return(profit);
  }

//+------------------------------------------------------------------+
//| Логика фильтров и времени                                        |
//+------------------------------------------------------------------+
bool CheckFiltersAndGetSignal(string &signalType)
  {
   signalType = "NONE";

   // 1. Время сервера
   MqlDateTime dt;
   TimeCurrent(dt);
   
   // --- ТОЧКА ОСТАНОВА 1 (Поставь сюда курсор и нажми F9) ---
   // Здесь ты увидишь dt.hour. Если оно < 4, мы выйдем.
   
   if(dt.hour < InpStartHour || dt.hour >= InpEndHour) 
      return(false); // Спим

   // 2. Спред
   long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(spread > InpMaxSpread) 
      return(false); // Спред большой

   // 3. ЛОГИКА "ОТ УРОВНЯ ДНЯ"
   // Получаем цену открытия текущего дня (D1, бар 0)
   double dayOpen = iOpen(_Symbol, PERIOD_D1, 0);
   double currentBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   
   // --- ТОЧКА ОСТАНОВА 2 ---
   // Смотри значения dayOpen и currentBid
   
   if(currentBid > dayOpen + 10*_Point) // Цена выше открытия на 10 пунктов?
     {
      signalType = "BUY";
      return(true);
     }
   
   if(currentBid < dayOpen - 10*_Point) // Цена ниже открытия на 10 пунктов?
     {
      signalType = "SELL";
      return(true);
     }

   return(false); // Время рабочее, но цена топчется на открытии
  }

//+------------------------------------------------------------------+
//| OnTick                                                           |
//+------------------------------------------------------------------+
void OnTick()
  {
   switch(CurrentSeries.state)
     {
      case STATE_WAIT_SIGNAL:
        {
         string signal = "";
         // Проверяем всё в одной функции (удобно для отладки)
         if(CheckFiltersAndGetSignal(signal))
           {
            if(signal == "BUY")
              {
               Print("Genius: Пробой вверх! Покупаем.");
               if(TradeManager.OpenBuy(InpLot, _Symbol)) StartNewSeries();
              }
            else if(signal == "SELL")
              {
               Print("Genius: Пробой вниз! Продаем.");
               if(TradeManager.OpenSell(InpLot, _Symbol)) StartNewSeries();
              }
           }
         else
           {
            // Для визуализации в тестере
            MqlDateTime dt; TimeCurrent(dt);
            Comment("State: WAIT\nHour: ", dt.hour, "\nSignal: NONE");
           }
         break;
        }

      case STATE_IN_SERIES:
        {
         double profit = CalculateSeriesFloatingProfit();
         Comment("State: IN SERIES\nProfit: ", DoubleToString(profit, 2));

         if(profit >= InpTakeProfit)
           {
            TradeManager.CloseAll("TP Reached");
            CurrentSeries.state = STATE_FINISHED;
            StateService.Save(CurrentSeries);
           }
         break;
        }

      case STATE_FINISHED:
        {
         CurrentSeries.Reset();
         StateService.Save(CurrentSeries);
         break;
        }
     }
  }
//+------------------------------------------------------------------+