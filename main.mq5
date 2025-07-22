//+------------------------------------------------------------------+
//|                                                      MartingaleEA.mq5 |
//|                        Copyright 2023, MetaQuotes Software Corp. |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2023, MetaQuotes Software Corp."
#property link      "https://www.mql5.com"
#property version   "1.00"
#property strict

//+------------------------------------------------------------------+
//| Input Parameters                                                 |
//+------------------------------------------------------------------+
input int      MagicNumber = 12345;          // Magic Number
input int      MaxSteps = 5;                 // Max Steps
input double   N = 2.0;                      // N multiplier for ATR
input int      AtrPeriod = 20;               // ATR Period
input int      SmaPeriod = 20;               // SMA Period
input int      StartOrderExpirationBars = 3; // Время истечения ордера на открытие первой позиции

//+------------------------------------------------------------------+
//| Global Variables                                                 |
//+------------------------------------------------------------------+
double         initialDeposit;               // Initial deposit
int            currentStep = 0;              // Current step
ulong          closeOrderTicket = 0;         // Close order ticket
double         initialLot;                   // Initial lot size
int            atrHandle, smaHandle;         // Indicator handles
int            firstOrderExpirationCount = 0;      // счетчик экспирации сигнала на открытие первой ступени
double         lastPositionPrice = 0;   // lastPosition price open

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   // Create indicator handles
   atrHandle = iATR(_Symbol, PERIOD_CURRENT, AtrPeriod);
   smaHandle = iMA(_Symbol, PERIOD_CURRENT, SmaPeriod, 0, MODE_SMA, PRICE_CLOSE);
   
   if(atrHandle == INVALID_HANDLE || smaHandle == INVALID_HANDLE)
   {
      Print("Error creating indicators");
      return(INIT_FAILED);
   }
   
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   // Release indicators
   if(atrHandle != INVALID_HANDLE) IndicatorRelease(atrHandle);
   if(smaHandle != INVALID_HANDLE) IndicatorRelease(smaHandle);
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   // Check for zero values to avoid division by zero
   if(Point() == 0 || SymbolInfoDouble(_Symbol, SYMBOL_TRADE_CONTRACT_SIZE) == 0)
   {
      Print("Error: Point or ContractSize is zero");
      return;
   }
   
   static datetime lastBarTime = 0;
   datetime currentBarTime = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(lastBarTime == currentBarTime) return;
   lastBarTime = currentBarTime;
   firstOrderExpirationCount++;
   double atr[1], sma[1];
   if(CopyBuffer(atrHandle, 0, 1, 1, atr) != 1 ||  CopyBuffer(smaHandle, 0, 1, 1, sma) != 1)
   {
      Print("Error copying indicator data");
      return;
   }
   if(atr[0] <= 0)
   {
      Print("ATR value is zero, using Point");
      atr[0] = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   }
   bool hasPosition = PositionSelect(_Symbol) && PositionGetInteger(POSITION_MAGIC) == MagicNumber;
   bool hasCloseOrder = closeOrderTicket != 0 && OrderSelect(closeOrderTicket) && OrderGetInteger(ORDER_STATE) != ORDER_STATE_CANCELED && OrderGetInteger(ORDER_STATE) != ORDER_STATE_EXPIRED;
   if (!hasCloseOrder) {
      closeOrderTicket = 0;
   }
   if(!hasPosition && currentStep > 0)
   {
      currentStep = 0;
      initialDeposit = 0;
      initialLot = 0;
      DeleteAllLimits();
      Print("Chain reset");
   }
   if(!hasPosition && currentStep == 0 && firstOrderExpirationCount > StartOrderExpirationBars)
   {
      currentStep = 0;
      initialDeposit = 0;
      initialLot = 0;
      DeleteAllLimits();
      Print("Chain reset");
      StartNewChain(sma[0], atr[0]);
   }
   if(hasPosition && !hasCloseOrder)
   {
      UpdateCloseOrder(atr[0]);   
   }
   if(hasPosition && currentStep < MaxSteps && !HasBuyLimitOrders())
   {
      PlaceNextBuyOrder(atr[0]);
   }
}

//+------------------------------------------------------------------+
//| Start new chain                                                  |
//+------------------------------------------------------------------+
void StartNewChain(double sma, double atr)
{
   double price = sma - N * atr;
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double minDist = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * point;
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(price >= bid) {
      price = bid - atr;
   }
   if(price <= minDist || price >= bid - minDist)
   {
      Print("Invalid price for new chain: ", price);
      return;
   }
   initialDeposit = AccountInfoDouble(ACCOUNT_EQUITY);
   initialLot = CalculateInitialLot();
   if(initialLot <= 0)
   {
      Print("Invalid initial lot: ", initialLot);
      return;
   }
   MqlTradeRequest request;
   MqlTradeResult result;
   ZeroMemory(request);
   ZeroMemory(result);
   
   request.action = TRADE_ACTION_PENDING;
   request.symbol = _Symbol;
   request.volume = initialLot;
   request.price = NormalizePrice(price);
   request.type = ORDER_TYPE_BUY_LIMIT;
   request.sl = 0.0;
   request.type_filling = ORDER_FILLING_RETURN;
   request.magic = MagicNumber;
   
   // Calculate initial TP
   double lotSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_CONTRACT_SIZE);
   double tpPrice = 0;
   request.tp = tpPrice;
   request.comment = "Step 0. deposit: " + DoubleToString(initialDeposit, 2);
   
   if(!OrderSend(request, result))
   {
      Print("Failed to place initial order. Error: ", GetLastError());
      return;
   }
   firstOrderExpirationCount = 0;
   Print("New chain started. Price: ", request.price, " Lot: ", initialLot, " TP: ", tpPrice);
}

//+------------------------------------------------------------------+
//| Update close order                                               |
//+------------------------------------------------------------------+
void UpdateCloseOrder(double atr)
{
   // Remove existing close order
   if(closeOrderTicket != 0)
   {
      MqlTradeRequest request;
      MqlTradeResult result;
      ZeroMemory(request);
      ZeroMemory(result);
      
      request.action = TRADE_ACTION_REMOVE;
      request.order = closeOrderTicket;
      
      if(OrderSend(request, result))
      {
         Print("Close order removed: ", closeOrderTicket);
         closeOrderTicket = 0;
      }
   }
   
   // Get current position
   if(!PositionSelect(_Symbol)) 
   {
      Print("No position found for update");
      return;
   }
   
   double volume = PositionGetDouble(POSITION_VOLUME);
   double avgPrice = PositionGetDouble(POSITION_PRICE_OPEN);
   double lotSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_CONTRACT_SIZE);
   
   // Check for zero values
   if(volume <= 0 || lotSize <= 0)
   {
      Print("Invalid values for TP calculation: Volume=", volume, " LotSize=", lotSize);
      return;
   }
   
   // Calculate new TP price
   double tpPrice = avgPrice + N * atr;
   tpPrice = NormalizePrice(tpPrice);
   
   // Place new close order
   MqlTradeRequest request;
   MqlTradeResult result;
   ZeroMemory(request);
   ZeroMemory(result);
   
   request.action = TRADE_ACTION_PENDING;
   request.symbol = _Symbol;
   request.volume = volume;
   request.price = tpPrice;
   request.type = ORDER_TYPE_SELL_LIMIT;
   request.sl = 0.0;
   request.type_filling = ORDER_FILLING_IOC;
   request.magic = MagicNumber;
   double tpMoney = (tpPrice-tpPrice) * lotSize * volume;
   
   string comment = "TP: " + DoubleToString(tpMoney, 2) + " (" + DoubleToString(tpMoney / initialDeposit * 100, 2) + "%) Step: " + IntegerToString(currentStep);
   request.comment = comment;
   
   if(OrderSend(request, result))
   {
      closeOrderTicket = result.order;
      Print("Close order updated. Price: ", tpPrice, " Volume: ", volume);
   }
   else
   {
      Print("Failed to update close order. Error: ", GetLastError());
   }
}

//+------------------------------------------------------------------+
//| Place next buy order                                             |
//+------------------------------------------------------------------+
void PlaceNextBuyOrder(double atr)
{
   double lastDealPrice = PositionGetDouble(POSITION_PRICE_OPEN);
   if(lastDealPrice <= 0)
   {
      Print("Invalid last deal price");
      return;
   }
   
   double price = lastDealPrice - N * atr;
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double minDist = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * point;
   
   // Check price validity
   if(price <= minDist)
   {
      Print("Invalid price for next order: ", price);
      return;
   }
   
   double volume = initialLot * MathPow(2, currentStep);
   volume = NormalizeVolume(volume);
   
   if(volume <= 0)
   {
      Print("Invalid volume for next order: ", volume);
      return;
   }
   
   MqlTradeRequest request;
   MqlTradeResult result;
   ZeroMemory(request);
   ZeroMemory(result);
   
   request.action = TRADE_ACTION_PENDING;
   request.symbol = _Symbol;
   request.volume = volume;
   request.price = NormalizePrice(price);
   request.type = ORDER_TYPE_BUY_LIMIT;
   request.sl = 0.0;
   request.type_filling = ORDER_FILLING_RETURN;
   request.magic = MagicNumber;
   request.comment = "Step " + IntegerToString(currentStep+1);
   
   if(!OrderSend(request, result))
   {
      Print("Failed to place next order. Error: ", GetLastError());
      return;
   }
   
   Print("Next order placed. Step: ", ++currentStep, " Price: ", request.price, " Volume: ", volume);
}
//+------------------------------------------------------------------+
//| Trade function                                                   |
//+------------------------------------------------------------------+
void OnTrade()
{    
    if (PositionSelect(_Symbol) && PositionGetInteger(POSITION_MAGIC) == MagicNumber && lastPositionPrice != PositionGetDouble(POSITION_PRICE_OPEN)) {
        Print("пересчет take profit");
        double curPositionPrice = PositionGetDouble(POSITION_PRICE_OPEN);
        lastPositionPrice = PositionGetDouble(POSITION_PRICE_OPEN);
        DeleteAllLimits();
    }
}

//+------------------------------------------------------------------+
//| Helper Functions                                                 |
//+------------------------------------------------------------------+
double CalculateInitialLot()
{
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double lotSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_CONTRACT_SIZE);
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   
   // Check for zero values
   if(equity <= 0 || price <= 0 || lotSize <= 0 || lotStep <= 0)
   {
      Print("Invalid values for lot calculation");
      return 0;
   }
   
   // Calculate total lots for all steps
   double totalLots = 0;
   for(int i = 0; i < MaxSteps; i++)
   {
      totalLots += MathPow(2, i);
   }
   
   // Calculate initial lot
   double lot = (equity * 0.9) / (price * lotSize * totalLots);
   lot = NormalizeVolume(lot);
   
   // Validate lot size
   if(lot < minLot) lot = minLot;
   if(lot > maxLot) lot = maxLot;
   
   return lot;
}

double NormalizePrice(double price)
{
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickSize > 0)
      return NormalizeDouble(MathRound(price / tickSize) * tickSize, _Digits);
   return NormalizeDouble(price, _Digits);
}

double NormalizeVolume(double volume)
{
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(step > 0)
      return step * MathFloor(volume / step);
   return volume;
}

bool HasBuyLimitOrders()
{
    for(int i = 0; i < OrdersTotal(); i++)
    {
        ulong ticket = OrderGetTicket(i);
        if(ticket > 0)
        {
            if(OrderGetString(ORDER_SYMBOL) == _Symbol && 
               OrderGetInteger(ORDER_MAGIC) == MagicNumber &&
               OrderGetInteger(ORDER_TYPE) == ORDER_TYPE_BUY_LIMIT)
            {
                return true;
            }
        }
    }
    return false;
}

void DeleteAllLimits()
{
    for(int i = OrdersTotal()-1; i >= 0; i--)
    {
        ulong ticket = OrderGetTicket(i);
        if(ticket <= 0) continue;
        
        if(OrderGetString(ORDER_SYMBOL) == _Symbol && 
           OrderGetInteger(ORDER_MAGIC) == MagicNumber)
        {
            MqlTradeRequest request = {};
            MqlTradeResult result = {};
            request.action = TRADE_ACTION_REMOVE;
            request.order = ticket;
            
            if(!OrderSend(request, result))
            {
                Print("Failed to delete order #", ticket, " Error:", GetLastError());
            }
        }
    }
}
//+------------------------------------------------------------------+