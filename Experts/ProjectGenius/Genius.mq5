//+------------------------------------------------------------------+
//|                                                       Genius.mq5 |
//|                                                    ProjectGenius |
//+------------------------------------------------------------------+
#property copyright "Gorizont"
#property version   "1.09"

#include <ProjectGenius\Defines.mqh>
#include <ProjectGenius\CsvWriter.mqh>
#include <ProjectGenius\DataStructs.mqh>
#include <ProjectGenius\StateService.mqh>
#include <ProjectGenius\TradeManager.mqh>
#include <ProjectGenius\SignalService.mqh> // <--- ВЕРНУЛИ

// --- ВХОДНЫЕ ПАРАМЕТРЫ ---
input double InpLot          = 0.01; 
input double InpTakeProfit   = 5.0;  
input int    InpMaxSpread       = 20;
input int    InpStartHour       = 4;
input int    InpEndHour         = 23;
input double InpSignalThreshold = 20.0; // <--- НОВЫЙ ПАРАМЕТР (Поставь 20 для теста)

// Новые фильтры дальности (твоя идея)
input int    InpMinDistance  = 10;   // Мин. отступ от открытия (чтобы не флэт)
input int    InpMaxDistance  = 200;  // Макс. отступ (если больше - значит улетели, не входим)

// --- ГЛОБАЛЬНЫЕ ОБЪЕКТЫ ---
CCsvWriter     Writer;
TSeriesData    CurrentSeries;
CStateService  StateService("state.csv");
CTradeManager  TradeManager;
CSignalService Signal; // <--- ВЕРНУЛИ

//+------------------------------------------------------------------+
//| Init                                                             |
//+------------------------------------------------------------------+
int OnInit()
  {
   TradeManager.Init(EXPERT_MAGIC);
   
   // Инициализируем индикатор
   if(!Signal.Init(_Symbol, _Period)) return(INIT_FAILED);

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
//| Profit Calc                                                      |
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
   // Округляем прибыль до 2 знаков для красоты
   return(NormalizeDouble(profit, 2));
  }

//+------------------------------------------------------------------+
//| Проверка дистанции от Open Day                                   |
//+------------------------------------------------------------------+
bool CheckDistance(string direction)
  {
   double dayOpen = iOpen(_Symbol, PERIOD_D1, 0);
   double currentPrice = (direction == "BUY") ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   
   // Считаем дистанцию в Пунктах (Points)
   double diffPoints = MathAbs(currentPrice - dayOpen) / _Point;
   
   // 1. Если цена слишком близко к открытию (флэт)
   if(diffPoints < InpMinDistance) return(false);
   
   // 2. Если цена улетела в космос (твоя стратегия "не покупать на хаях")
   if(diffPoints > InpMaxDistance) 
     {
      // Можно вывести в лог, что мы пропускаем вход
      // Print("Genius: Фильтр! Цена улетела на ", diffPoints, " пт. Ждем откат.");
      return(false);
     }
     
   return(true);
  }
//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
  {
   // --- 1. СБОР ДАННЫХ ---
   MqlDateTime dt; TimeCurrent(dt);
   long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   
   // Получаем сигнал и строку отладки
   ENUM_SIGNAL_TYPE sig = Signal.CheckSignal(InpSignalThreshold); 
   string indDebug = Signal.GetDebugString();

   // --- 2. ЭКРАН ---
   string status = "ACTIVE";
   if(dt.hour < InpStartHour || dt.hour >= InpEndHour) status = "SLEEPING (Time)";
   else if(spread > InpMaxSpread)                      status = "FILTER (Spread)";
   
   Comment("=== GENIUS DEBUG ===",
           "\nStatus:  ", status,
           "\nTime:    ", dt.hour, ":", dt.min,
           "\nSpread:  ", spread, 
           "\nSignal:  ", indDebug,
           "\nThreshold: ", InpSignalThreshold,
           "\nState: ", EnumToString(CurrentSeries.state)
           );

   // --- 3. ЛОГИКА ---
   
   // Если спим - выходим
   if(status != "ACTIVE" && CurrentSeries.state == STATE_WAIT_SIGNAL) return;

   switch(CurrentSeries.state)
     {
      case STATE_WAIT_SIGNAL:
        {
         // ПРОВЕРКА: Почему не входим?
         if(sig == SIGNAL_NONE) 
           {
            // Это нормально, сигнала просто нет
            return; 
           }
           
         if(sig == SIGNAL_WAIT_EXHAUSTED)
           {
            Print("Genius: Сигнал пропущен (Рынок выдохся > 50%)");
            return;
           }

         // Если мы здесь - значит сигнал ЕСТЬ (BUY или SELL)
         // Проверяем фильтр дистанции
         
         if(sig == SIGNAL_BUY)
           {
            Print("Genius: ЕСТЬ СИГНАЛ BUY! Проверяем дистанцию...");
            if(CheckDistance("BUY"))
              {
               Print("Genius: Дистанция ОК! Пытаюсь открыть BUY...");
               if(TradeManager.OpenBuy(InpLot, _Symbol)) StartNewSeries();
              }
            else
              {
               Print("Genius: Отказ по дистанции (слишком близко или далеко).");
              }
           }
         else if(sig == SIGNAL_SELL)
           {
            Print("Genius: ЕСТЬ СИГНАЛ SELL! Проверяем дистанцию...");
            if(CheckDistance("SELL"))
              {
               Print("Genius: Дистанция ОК! Пытаюсь открыть SELL...");
               if(TradeManager.OpenSell(InpLot, _Symbol)) StartNewSeries();
              }
            else
              {
               Print("Genius: Отказ по дистанции.");
              }
           }
         break;
        }

      case STATE_IN_SERIES:
        {
         double profit = CalculateSeriesFloatingProfit();
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