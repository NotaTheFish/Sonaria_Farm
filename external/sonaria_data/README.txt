Папка sonaria_data — снимки мест Roblox
========================================

  Файлы
  -----
  - ``*.rbxl`` — бинарный формат (в редакторе не открывается как текст).
  - ``14119723130 Trade Realm.rbxlx`` — Trade Realm (XML, удобно grep по репо).
  - ``5233782396 Creatures of Sonaria Survive Kaiju Animals (1).rbxlx`` — основной мир.

  Связь с universal_sonaria_bot.lua
  ---------------------------------
  Скрипт в игре НЕ читает эти файлы с диска. По содержимому .rbxlx в коде бота
  реализовано (см. ``openTradeWorld``):
  - ``require(ReplicatedStorage.Sonar)`` → ``RemoteUtils.GetRemoteFunction("TeleportToRemote")``
  - ``InvokeServer("ToPlaceType", "Trade", {})``, при отказе — ``ToPlaceId`` с live PlaceId
    ``14119723130`` (переопределение: JSON ``trade_realm_place_id`` / ``trade_realm_place_id_test``).
  - Проверка ``Constants.IsTradeRealm`` / текущий ``game.PlaceId`` — если уже в трейд-мире, телепорт не вызывается.

  Трейд между игроками в CoS: парный ``RemoteFunction``
  ``<имя1>-<имя2>TradeRemote`` и ``PlayerGui.TradeGui`` — в ``universal_sonaria_bot.lua``
  реализованы ``AcceptTrade`` / ``DeclineTrade`` через ``InvokeServer``, опрос ``AcceptButton``,
  цикл ``handlers.receive`` (whitelist ``bound_farmers``). Выкладка своей стороны: ``AddTradeItem``
  (поля ``ItemType``, ``Name``, ``Amount``, ``Overwrite``) — гриб как ``Currency``/``Mushroom``,
  токены фермера как ``Tokens``/имя; параметр ``storage_gives`` в JSON задаёт количество грибов.

  Координаты лавы для фермера — в ``universal_sonaria_bot.lua`` (volcano_x/y/z).
