# Trepang2 Co-op — журнал разработки

Всё, что узнали о движке и игре, по шагам. Читать перед правкой кода.

## Окружение
- Игра: `C:\Program Files (x86)\Steam\steamapps\common\Trepang2` (копия A, хост).
- Копия B для тестов на одном ПК: `C:\Users\PC\Trepang2_B` — свои `Binaries\Win64` (exe + UE4SS),
  а `Engine`, `CPPFPS\Content`, `CPPFPS\Plugins` — junction-ссылки на копию A (места не занимает).
- UE4SS experimental `v3.0.1-1218-g560411f1` (dwmapi.dll + папка ue4ss в Win64).
  В `UE4SS-settings.ini`: `DefaultExecuteInGameThreadMethod = ProcessEvent` (EngineTick переставал работать после смены карты).
- Конфиг игры: `%LOCALAPPDATA%\CPPFPS\Saved\Config\WindowsNoEditor\Engine.ini`
  (бэкап: `Engine.ini.bak_before_coop`). Добавлено `[OnlineSubsystem] DefaultPlatformService=Null`.
  Секция NetDriverDefinitions в этом ini НЕ применяется — драйвер меняем из Lua.

## Инструменты (`tools/`)
- `launch.ps1 -Which A,B -Kill` — запуск копий в окне 1280x720 рядом.
- `t2.ps1 -Inst A|B -Cmd "..." [-Mod T2Coop]` — команда в игру через файл `Mods/<Mod>/cmd.txt` + новые строки лога.
  T2Dev: консольная команда или `lua:<код>`; T2Coop: Lua внутри мода (таблица `T2C`).
- `shot.ps1 -ProcId N -Out file.png` — скриншот окна игры даже под другими окнами (PrintWindow).
- `key.ps1 -ProcId N -Vk 0x20` — нажать клавишу в окне игры (PostMessage).
- `deploy.ps1` — копирует `mod/*` в обе копии и включает в mods.txt.
- `test_coop.ps1` — полный тест: деплой, перезапуск, хост на A, вход с B, логи, краши, скриншоты.
- `natives.py`, `disasm.py` — разбор крашей по exe (таблица нативов, дизассемблер по .pdata).

## Факты о движке/игре
- UE 4.27.2, Shipping, модуль игры `CPPFPS`. В C++ игры нет RPC/OnRep.
- `GameEngine.NetDriverDefinitions`: GameNetDriver = `OnlineSubsystemGOG.NetDriverGOG` (fallback IpNetDriver).
  С подсистемой GOG listen не работает. Нужно: Null-подсистема + DriverClassName = IpNetDriver (из Lua).
- Экран «НАЖМИТЕ ЛЮБУЮ КЛАВИШУ» — загрузочный экран GameInstance (`CurrentLoadingWidget`);
  пока он висит, travel/OpenLevel не выполняются. `GameInstanceBP_C:ForceStopLoadingScreen()` + `SetBootFlowFinished()`.
- Консольный `open <короткое имя>` не находит карты. Работает `GameplayStatics:OpenLevel(world, FName("/Game/Maps/..."), true, "listen")`.
  FName создавать с `EFindName.FNAME_Add`.
- Карты «Орды»: `/Game/Maps/HordeMode/Horde_*`, `/HordeB/`, `/HordeC/`, `/Patch01/` (список — через AssetRegistry:GetAssetsByPath).
- На картах нет PlayerStart. Пешка игрока стоит в уровне (`PlayerBP_2`, AutoPossessPlayer=Player0).
- `god` не работает. Бессмертие: `ABasePlayer:SetInvulnerableState(true)`.
- При смерти игрока игра перезапускает уровень (OpenLevel без `?listen`) → сервер пропадает.
- Каждый Lua-мод UE4SS — отдельное Lua-окружение, глобалы между модами не видны.

## Решённые проблемы
1. **Пешка клиента отнимала управление у хоста.** CDO `PlayerBP_C.AutoPossessPlayer = Player0`, и любая
   заспавненная сервером пешка захватывает контроллер №0 (хоста). Хост падал под карту в (0,0,0).
   Решение: после загрузки уровня ставить CDO.AutoPossessPlayer=0, перед следующей загрузкой — вернуть 1
   (пешки уровня читают значение из CDO при загрузке). Пешку клиента ставим рядом с хостом.
2. **Краш клиента EXCEPTION_ACCESS_VIOLATION 0x2b8** в нативном тике `ABasePlayer` (RVA 0x11aa330, вызывается из 0x11d3827):
   `Cast<APlayerController>(Pawn->Controller)->PlayerCameraManager` без проверки на null.
   На клиенте у чужой пешки контроллера нет никогда, у своей — первые кадры.
   Решение: в BeginPlay-хуке на клиенте выключаем тик пешке игрока без готового контроллера, включаем, когда появился.

3. **UE4SS-циклы умирали на хосте.** `LoopAsync`+`ExecuteInGameThread`, а потом и `LoopInGameThreadWithDelay`
   переставали выполняться (оба мода сразу), обычно после того как задача вызвала игровую функцию
   (ApplyDamage и т.п.). Хуки при этом работают всегда. Решение: «пульс» = хук на
   `PlayerControllerBP_C:ReceiveTick` (локальный контроллер), из него наш планировщик `S.every(ms, fn)`.
   Запасной цикл UE4SS работает, только когда пульса нет >1 c (меню на паузе — контроллер не тикает).
   Хуки сами ничего не вызывают в движке: только кладут события в очередь, разбор — в планировщике.
4. **Ввод клиента не двигал пешку.** Оси движения привязаны к PlayerControllerBP (`Move Forward` и т.д.),
   он шлёт ввод в `MyPlayer`, а `MyPlayer` заполняется в `ReceivePossess` — только на сервере.
5. **Клиент не мог стрелять.** Пешка и оружие клиента приходят с сервера сетевыми копиями
   (оружие Role=SimulatedProxy), а нативный код стрельбы работает только с локальными объектами.
   Решение — **локальная пешка клиента**: клиент спавнит свой `PlayerBP_C` (Role=Authority, своё оружие),
   прячет серверную копию («марионетку»), делает `pc:ClientRestart(localPawn)` и `pc.MyPlayer = localPawn`.
   Хост присылает точку появления (`S`), клиент 20 раз/с шлёт позу (`P`), хост двигает марионетку.
6. **Отладка:** «Fatal error» клиента и зависания хоста часто были вызваны МОИМИ диагностическими
   хуками/перебором объектов. Перед выводами — чистый перезапуск `test_coop.ps1`.

7. **Без пистолета в руках у локальной пешки клиента.** `APawn::IsPlayerControlled()` = «есть PlayerState».
   Решение: отложенный спавн (`BeginDeferredActorSpawnFromClass`), до `FinishSpawningActor` выставить
   `Controller = pc` и `PlayerState = pc.PlayerState`. Тогда BeginPlay настраивает оружие от первого лица.
   HUD (`PlayerHUD2_C.Player`, `PlayerBP.PlayerHud`) перенаправляем на локальную пешку.
8. **Чёрно-белая картинка клиента** — PostProcess-компоненты (DeathPP, LowHealthPP, SlowMo...) чужих
   пешек игроков действуют на весь экран; их никто не обновляет. Выключаем у всех пешек, кроме своей.
9. **«GRAB HOSTAGE» на напарника** — `bCanBeTakenHostage = false` у всех BasePlayer.
10. **Нельзя вызывать из Lua `Die()` (и хук на `Die`)** — UE4SS перестаёт выполнять оба мода.
    Смерти врагов на хосте ищем опросом `bIsDead`; на клиенте копию «убиваем» визуально:
    урон + `bIsDead=true` + `StartLiveRagdoll`. Поиск врага по позиции — только живых (трупы ближе).
11. **Смерть игрока = перезапуск уровня = конец сессии.** Сделано «ранение»: при HP ≤ 30% игрок
    неуязвим и не двигается; напарник рядом (260 ед.) 3 с — подъём с 50% HP. `SetDamageLimit(45)` —
    урон за попадание ограничен, чтобы не умереть с >30% за один выстрел. Все ранены → хост
    перезапускает арену (`?listen`), клиенты переподключаются сами (сообщение `RJ` + автоповтор).

12. **Пауза хоста замораживала напарника.** Пока есть подключённые, хост снимает паузу
    (`GameplayStatics:SetGamePaused(false)`): меню открыто, мир идёт.
13. **«Начать уровень сначала» / автоперезапуск игры** грузят карту без `?listen` → сессия молча
    умирает. Сторож на хосте: если мы хостим, а на загруженной арене нет NetDriver — хостим заново;
    клиенты возвращаются сами. Ушли в меню/убежище (другое имя уровня) — хостинг выключается.
    Имя уровня брать `GameplayStatics:GetCurrentLevelName`, НЕ `World:GetFullName` (крашило UE4SS при смене карты).
14. **Краши UE4SS во время смены карты** — задачи мода успевали работать, пока старый мир
    разбирался. Между LoadMap pre и post (+1.5 c) планировщик стоит (`S.loading`, `S.graceMs`).
15. **Engine.ini**: игра пересохраняет его при выходе и выкидывает значения, равные значениям по
    умолчанию; мод сам дописывает `DefaultPlatformService=Null`, если его нет (работает со следующего запуска).
    С `DefaultPlatformService=Steam` listen-сервер не стартует (проверено). Исходно в игре: Steam.
16. Горячие клавиши UE4SS (`RegisterKeyBind`) не ловят PostMessage в окно без фокуса, а
    `PlayerController:IsInputKeyDown` ловит — мод опрашивает F5–F8 обоими способами.

17. **Враги стреляют по марионетке клиента на хосте**, а урон до клиента не доходил (марионетка была
    бессмертной). Теперь марионетка уязвима, `SetDamageLimit(45)`, каждый кадр хост досылает клиенту
    потерянное здоровье (`H|урон`) и доливает марионетке HP до 1000. Первый замер HP марионетки не шлём.
18. Табличка «NONE / NONE - 0» у хоста при взгляде на напарника — это `FriendlyCharacterName` /
    `FriendlySquadText` в PlayerHUD2 (подпись союзника). Источник имени не найден, оставлено.
19. На клиенте `SideMissionStatusUI` сам переписывает поля в своём Tick — значения хоста
    переприменяем каждые 100 мс.
20. PowerShell 5 `Set-Content -Encoding utf8` пишет BOM — Lua его не понимает. Правки .lua — только без BOM.

21. **Лут.** Патроны/аптечки (`BasePickup`) не сетевые — у каждого своя копия арены. Оружие на полу у клиента —
    сетевые копии (Role=1), из них не стреляют. Клиент кладёт свой локальный дубль поверх каждой
    «свободной» копии (через 1.5 c, чтобы упала), копию прячет; взял дубль → `WT` → хост удаляет оригинал;
    оригинал взяли/исчез → дубль удаляется. Из Lua `SwapWeapon`/`ForceEquipWeapon` на клиенте НЕ работают
    (подбор только настоящим F) — проверено подменой владельца (`SetOwner`).
22. **Деньги «Орды»** начисляет `HordeModeActor_C:OnPlayerKilledOther` (привязан к убийствам хоста).
    Для убийств напарника хост вызывает его сам (`nil` вместо DamageType — работает).
23. **Метка напарника**: `BP_ObjectiveIcon_C` (+`OwningPlayer`, `K2_AttachToActor`, `Sickle_ShowIcon`,
    `HackOverrideSubtitle`). Заголовок «ПРИОРИТЕТНАЯ ЗАДАЧА» не меняется без локализованного класса.
24. Копия игры **C** (`C:\Users\PC\Trepang2_C`) для теста на 3 игроках; инструменты знают A/B/C.

25. **Урон по копиям врагов у клиента невозможен**: `APawn::ShouldTakeDamage` требует Authority и GameMode.
    Пули игрока — мгновенный луч из нативного кода (никакие UFunction оружия не вызываются, перехватить нечего).
    Решение: клиент на каждый выстрел (падение патронов) шлёт `SH|камера|yaw|pitch|выстрелов|класс оружия`;
    хост делает `KismetSystemLibrary:LineTraceSingle` (канал 0 — попадает в капсулу, без кости), урон =
    `GetDamage()` CDO оружия, дробь — `GetBulletCount()` лучей в конусе 4°, голова = точка удара выше
    центра капсулы на 55 → умножаем на `HeadshotDamageMultiplier` CDO; `ApplyPointDamage` с инициатором-напарником.
    Старый путь `D` (OnSpawnedProjectileDamagedOther) по-настоящему никогда не срабатывал.
26. Трассировки по каналам 2–5 и `Mesh:GetSocketLocation` из Lua уронили хост внутри UE4SS — не использовать.

27. **Гранаты напарника**: граната, созданная из Lua (и на хосте, и на клиенте), не взводится — урона нет.
    Клиент следит за своими гранатами (`BaseGrenadeProjectile_C`: GrenadeBaseDamage/MinDamage/DamageRadius,
    DamageClass); когда граната исчезла — `EX|точка|база|мин|радиус|класс`. Хост: `ApplyDamage` каждому
    врагу в радиусе с линейным спадом. `ApplyRadialDamageWithFalloff` из Lua остановил UE4SS на хосте — не использовать.

28. **Steam-режим.** В игре вкомпилированы OnlineSubsystemSteam и `SteamNetDriver`. По умолчанию игра
    и так на Steam (при сохранении Engine.ini выкидывает строки, равные умолчанию, — поэтому для Steam
    достаточно убрать нашу строку `Null`). Steam-сервер слушает только Steam P2P: клиент по IP к нему не
    подключается, подключение — `open steam.<SteamID64>`. На одном аккаунте P2P сам к себе не работает →
    режим не проверен (нужен второй аккаунт). Один раз при первом Steam-хостинге упал UE4SS, повтор — нет.
29. **Ники.** С Null-подсистемой движок знает только имя компьютера; Steam-ник читаем из
    `Steam/config/loginusers.vdf` (MostRecent). `ServerChangeName` (наш канал) затирает имя в PlayerState —
    хост возвращает `PlayerNamePrivate` раз в 250 мс, все игнорируют имена вида `T2C|...`.
    Клиент, ушедший в меню, висит у хоста до тайм-аута движка (~1 мин): 5 с без сообщений = вышел.
30. **Меню F4** собрано из Lua внутри экземпляра `UI_HordeMusicPopup_C` (корень — CanvasPanel):
    `StaticConstructObject` TextBlock/Button/Border/EditableTextBox с Outer = WidgetTree, `AddChildToCanvas`.
    Набор VerticalBox + SetPadding + SetVisibility уронил UE4SS — не использовать. Кнопки опрашиваются
    (`IsPressed` → отпущена над кнопкой = клик). Размер экрана сразу после заставки = 0 — позицию
    пересчитываем при каждом обновлении. Масштаб — `SetRenderScale` корня.

31. **Steam API из Lua.** Сессии движка (Create/Find/JoinSession proxy) отдают результат только через
    делегаты — из Lua не получить. Вместо них `t2coop_steam.dll`: собирается `tools/build_steamdll.py`
    (сам ассемблирует x64 и пишет PE — компилятора на машине нет, ставить нельзя). Lua грузит её через
    `package.loadlib` (есть в UE4SS), экспорт `t2s_run` берёт команду из `%TMP%/t2coop_cmd.txt` и пишет
    ответ в `t2coop_out.txt`; Lua C API из UE4SS не экспортирован, поэтому через файлы. Steam доступен
    и в IP-режиме (Null). Игра крутит `SteamAPI_RunCallbacks` (не manual dispatch) — колбэк
    `GameRichPresenceJoinRequested_t` (337) регистрируем сами. Rich presence `connect` =
    `-t2coopjoin=<SteamID64>` (с минусом: строка без минуса в командной строке UE — это URL карты).
    Оверлей Steam есть только если игру запустил Steam (`steam://rungameid/1164940`), не exe напрямую.
    В строке путей Lua `\t` — это табуляция: пути к TMP писать через `/`.

32. **Engine.ini: строка не в той секции.** У хоста оказалось `DefaultPlatformService=Null` под `[Core.System]`
    (а `[OnlineSubsystem]` пропала) — проверка «строка есть» проходила, а хостинг по IP молча не работал
    (OpenLevel ?listen → игра возвращалась в меню). Теперь мод и установщик ищут её только внутри
    `[OnlineSubsystem]`, лишнюю строку удаляют.
33. **Кампания: хост «ведёт» группу.** Игра грузит уровни сама (BP_MissionLib: `Trepang Start Level`,
    `Trepang End Level`, `Trepang Load Last Save`, `Trepang Restart Level` → `GameplayStatics:OpenLevel(короткое
    имя, true, "")` без listen). Нативный post-хук на `OpenLevel` тут же повторяет тот же переход с
    `?listen` (OpenLevel лишь запоминает TravelURL на следующий кадр — последний вызов выигрывает).
    Клиенты теряют сервер и переподключаются сами (~30–40 с). Прочитать/поменять FURL в хуке LoadMap
    UE4SS не умеет (проба уронила игру). У клиента свой OpenLevel (кроме выхода в меню при живом
    соединении) перенаправляется на `open <хост>`. Миссия из убежища:
    `GameInstanceBP:SafehouseMissionSelected(Mission_X_C)`, `BP_HelicopterStartMission_C:SetMissionReady(cls)`,
    `StartMissionSequence()`. Классы миссий `/Game/UI/CampaignMenuV2/Missions/Mission_*.Mission_*_C` (поле MapName).
    Карты: `/Game/Maps/Campaign/<...>/*_Persistent`, сайд-миссии `/Game/Maps/SideMissions/...`.
    «Host» в меню F4 внутри кампании = перезагрузить этот уровень с последнего чекпоинта уже с сервером.
34. **Сюжетные триггеры** — `BaseTriggerOnce_C` (`/Game/Blueprint/Tool/Triggers/BaseTriggerOnce`) и дети
    (Trigger_AutoSave, Trigger_SpawnSquad, Trigger_ShowObjText, Trigger_CultistHubDoor, SkyTransition...).
    Имена одинаковые у всех; поля `NumTimesTriggered`, `TriggerDisabled`, функция `TryTrigger(actor, out)`.
    Марионетка напарника у хоста задевает триггеры хоста (напарник тоже двигает сюжет). У клиента
    включены только локальные (небо/музыка/подсказки), остальные выключены; хост шлёт `TR|имя|n`, клиент
    повторяет свою копию (кроме сохранений/спавна) не раньше 3 с после готовности своей пешки.
    Стриминг подуровней реплицируется движком сам; отряды врагов хоста приходят клиенту копиями.
    Нереплицируемые актёры уровня у клиента имеют Role=0. Локальных NPC (Role=3) у клиента удаляем,
    кроме `NPC_Bullseye_*` — это цели ИИ для вертолётов, их удаление роняло игру.
35. **Сохранения.** SaveExtension, слот `%LOCALAPPDATA%\CPPFPS\Saved\SaveGames\0.sav` + `0_data.sav`
    (прогресс миссий — `Unlocks.sav`). Тесты кампании ПЕРЕЗАПИСЫВАЮТ сохранение пользователя — перед
    тестами копия в `C:\Users\PC\Trepang2_SaveBackup\`, после — вернуть. Автосохранение пишет
    состояние ХОСТА (даже если триггер задел напарник). Провал в кампании = `Trepang Load Last Save`
    (нет сохранения → через 6 с `Trepang Restart Level`).
36. **Падения при смене карты (UE4SS).** Хост падал внутри Lua UE4SS сразу после загрузки карты кампании
    (~1 из 4), клиент — в момент подмены пешки (memcpy по 0x2a4 внутри нативного хука UE4SS).
    Найдено и убрано: (а) `RegisterBeginPlayPostHook` — Lua на BeginPlay КАЖДОГО актёра (тысячи вызовов
    при старте карты кампании); теперь его ставит только клиент при первом подключении (у хоста его нет).
    Хук на `PlayerBP_C:ReceiveBeginPlay` не годится: UE4SS выкидывает его, когда класс перегружается с картой; (б) штатный мод UE4SS `CheatManagerEnablerMod` (нативный хук на `ClientRestart`) —
    выключен в deploy/установщике/сборке; (в) сборщик мусора Lua: полный сбор в LoadMapPre и стоп до
    конца «grace» после загрузки (предосторожность). Повтор TR-триггеров у клиента — в очереди после
    готовности пешки.
    Клиент (memcpy по 0x2a4): Lua → `FinishSpawningActor` нашей пешки → BeginPlay → анимационный BP пишет
    в None. Лечение: пешку спавним не раньше 1.5 с после точки появления и когда у контроллера есть
    `PlayerCameraManager`; `ForceStopLoadingScreen` зовём, только пока жив `CurrentLoadingWidget` и пока
    точки появления ещё нет (`T2C.stopLoadingScreen` — тесты тоже через неё). Итог: заход + 10
    перезагрузок подряд без падений (раньше ~1 из 3–4). Проверка стабильности — `tools/test_travels.ps1` (N перезагрузок подряд).

37. **Модели других игроков.** Пешка игрока собрана под вид от первого лица: полное тело `Mesh`
    (CharacterMesh0) у владельца скрыто, видны `MeshLegs` (тело без верха), `Mesh1P` (руки) и оружие
    `Mesh1P`. У клиента пешка хоста выходила «половиной тушки» с висящим пистолетом (оружие `Mesh3P`
    прицеплено к скрытому `ShadowMesh`). Для чужих пешек: показать `Mesh`, скрыть MeshLegs/Mesh1P/Mesh1P2,
    у оружия скрыть Mesh1P, `Mesh3P` прицепить к `Mesh` в сокет `hand_r_align`. У клиента ещё прятать
    локальный (Role=3) пистолет пешки хоста (созданный при загрузке карты) и оружие своей скрытой марионетки.
    Анимация: на хосте у марионетки `Mesh.bOnlyAllowAutonomousTickPose=true` (движок тикает позу только по
    ServerMove) — тело застывало; ставим false. `ABP_TPP_Player_C` для игроков не считает ходьбу: поля
    `Speed`, `Direction`, `Moving`, `PlanarVelocity` пишем сами каждый кадр (скорость по смещению пешки) —
    блюпринт их не перезаписывает. Хук на `BlueprintUpdateAnimation` нельзя: тысячи вызовов, UE4SS падал.
    **Post-хуки UE4SS на функциях блюпринтов не срабатывают** (pre — да); хуки на BP-классах слетают при
    перезагрузке класса с картой. Рамку «NONE» у союзника виджет пишет каждый кадр — прячем рамку
    `MouseOverFriendlyBox` через RenderScale 0 (прозрачность крутит анимация HUD). Скриншоты:
    `tools/face_off.ps1` (игроки друг напротив друга), `tools/crop.ps1` (вырез + яркость).

38. **Модель 106.** Тело игрока по умолчанию — наёмник `rig_character_soldier_light`. Модель 106 есть в игре:
    `/Game/Character/NPC/Special/Light106/rig_Light106` (тот же скелет UE4_Mannequin_Skeleton → все анимации
    работают). `Mesh:SetSkeletalMesh(m,false)` + вернуть материалы 106 (`SetMaterial(i, m.Materials[i].MaterialInterface)`):
    слот 0 у компонента переопределён материалом наёмника. Есть ещё костюмы `/Game/Character/Player/Rig/*_fpv_tpp`
    (107, patriarch, lawyerthug, jigglyboi) и `rig_107` — можно сделать выбор костюма. config.txt `model=106|soldier`.
    Круговая съёмка моделей: `tools/turntable.ps1 -Who host|guest` (лист из 8 ракурсов).
    Мелочь: у хоста рядом с напарником иногда всплывает подсказка «подобрать пистолет» (оружие напарника
    без коллизии, бесхозного рядом нет) — не разобрано.

39. **Анимации напарника.** У каждого игрока его собственное «тело-ноги» (`MeshLegs`, ABP_TPP_Player) считает
    настоящее состояние: Speed/Direction/Moving, Crouching, IsSliding, Jumping, IsOnGround, Stance, LeanStatus,
    AirDuration; спринт — `GetIsSprinting()`, две руки — `CurrentWeapon:GetIsDualWielding()`, дропкик —
    `IsDropkicking`, взгляд — pitch контроллера. Шлём `AS` 15 раз/с (хост пересылает всем по PlayerId) и пишем
    в анимацию полного тела напарника (+ `Char_*`, `AimPitch/AimPitchTarget`). Хват под тип оружия тело берёт
    само по классу оружия в руках. Две руки: у тела от 3-го лица одна модель оружия → в `hand_l_align`
    цепляем копию оружия (не реплицируется, без коллизий); поза всё равно двуручная, пистолеты почти совпадают.
    Удар на земле (ПКМ) — анимация только рук 1-го лица, тело не меняется. Перезарядка тела не показывается.
    Присед в игре — переключатель; присед на бегу = подкат. Выстрелы хоста → клиентам `HF|pid|n`
    (звук, вспышка, анимация оружия), выстрелы клиента другим клиентам хост пересылает так же.
    Инструменты: `tools/anim_probe.ps1` (жмёт клавиши в окне, пишет состояние анимации),
    `tools/action_shots.ps1 -Actor A|B` (лист кадров по действиям), `key.ps1 -Vks/-GapMs/-RClick`.

40. **Внешность игрока (ванильная).** Костюм — `PlayerBP.CurrentOutfit` (EPlayerOutfit 0..7: 0 = 106 обычный,
    1-2 заключённый, 3 = 107, 4 = Патриарх, 5 = Lawyer Thug, 6 = Jigglyboi, 7 = Light 106), сохраняется
    `GameInstance:SavePlayerOutfit`/`GetPlayerSavedOutfit`; одежда — 4 класса `BP_PC_Arms/Gloves/Pants/Shoes_*`
    (`GetSavedPlayerCustomization`/`SetNewPlayerCustomization`, список — CDO `BP_PlayerCustomizationList_C`).
    Полное тело для тени игра собирает в `ShadowMesh` (`SetPlayerOutfit`); цвета одежды кладёт в MID ног
    (`MeshLegs`, родитель `MI_PlayerPants_CustomBase`) и рук (`Mesh1P`: `M_FirstPersonArms/Gloves_CustomBase`).
    На ЧУЖОЙ пешке `SetPlayerOutfit` меняет только ShadowMesh, а `Apply Player Customization Mats` даёт не
    те цвета — поэтому отправитель шлёт готовые параметры своего MID ног (+ цвета рук разложены по зонам
    тела: Camo_01 рукава, Color_Tint_01 нашивка, Camo_03 торс, Color_Tint_02 перчатки; 07 наколенники,
    08 обувь, Camo_02 штаны, Camo_04 маска), получатель создаёт такой же MID на теле. Особые костюмы —
    копия ShadowMesh (меш + материалы). Сообщение `CU`. Меню бункера (`BP_SafeHouseCustomizeInteract`,
    удерживать F) у гостя работает как в одиночке. Эмулированный клик по «Применить» не срабатывает (и у
    хоста тоже) — тестами вызывать `UI_PlayerCustomize_C:ApplySelection()`. Две копии игры делят одно
    сохранение настроек — тесты одежды затирают настройки пользователя (восстанавливать из бэкапа).
    config `look=player|106`.

41. **Катсцены.** Запускает только игровой режим хоста (`BaseGameMode_C`: `Prepare and Play Cutscene`,
    `PlayLevelCutscene(seq, t)` → `CurrentCutscene` = ULevelSequencePlayer, Outer = `LevelSequenceActor`).
    У клиента GameMode нет → свои катсцены не начинаются. Хост 2 раза/с шлёт `CS|имя актёра|секунда`
    (время: `GetCurrentTime()` → (FrameNumber+SubFrame)*Den/Num), `CE` в конце. Клиент: свой
    LevelSequenceActor с тем же именем, `JumpToSeconds`+`Play`, поправка при расхождении > 0.6 с;
    прячет всех игроков (и себя), выключает ввод (`SetIgnoreMove/LookInput`) и HUD (RenderOpacity),
    в конце `GoToEndAndStop`, `ResetIgnoreInputFlags`, `SetViewTargetWithBlend(pawn)`; хост переставляет
    клиентов рядом (S.known = {}). Пока катсцена — у клиента не удаляем «локальных NPC» (спаунаблы).
    Расхождение по времени ~0.1 с. Тест: `tools/cutscene_test.ps1` (кадры хост/гость рядом).
42. **Диалоги** — `BP_ScriptedDialogueActor_C` (массив `ScriptedConversation` из FFScriptedDialogueLineInfo:
    Line_2_..(Sound_6_.., SubtitleFile_12_.., Speaker_3_..), FallbackLines_5_..). Флаги Started/Finished ставит
    внешнее событие, поэтому «идёт реплика» = играет `CurrentSpeakingAudioComp`. Хост шлёт `DL|имя|строка|
    fallback|radio или точка говорящего`, клиент `SpeakLine(speaker, line, fb, 0, sound, subtitle)` своей копией
    (радио: speaker = сам актёр → окно рации + субтитр как у хоста). У клиента коллизия `TriggerColl`
    диалогов-триггеров выключена. Если говорящего нет, игра пропускает реплики мгновенно.
43. **Двери** — `ABaseDoorActor` (`bIsLocked`, `bIsOpen`, `LockDoor/UnlockDoor/OpenDoor(front)`, BP `BP_BaseDoorNew_C`).
    Хост шлёт `DO|имя|locked|open|сторона` при изменении и все запертые/открытые новичку.

44. **Ожидание игроков перед катсценой.** Хост, увидев новую катсцену (t < 1.5 с, игроков > 1): `Pause()`,
    `SetDisableCameraCuts(true)`, каждый кадр ожидания — `SetManualCameraFade(0)` (сцены начинаются с
    чёрного: затемнение остаётся на камере), `ResetIgnoreInputFlags`, пешку показать, вид на пешку
    (`BaseGameMode:SetPlayerCutsceneMode(false,…)` этого НЕ снимает). Точка сбора — последний сработавший
    триггер (< 3 с назад) или место хоста; радиус 700 (`T2C.gatherR` для тестов). Надпись вверху по центру
    (`S.banner`, Border+TextBlock в корне нового UI_HordeMusicPopup, якорь 0.5/0) + `BP_ObjectiveIcon`
    «СБОР»; клиентам `WB|k|n|точка`. Все на месте → `SetPlayerCutsceneMode(true,true)`, камеры обратно,
    `JumpToSeconds(0)`, `Play()`. После смены уровня ждём и переподключающихся (число игроков до смены, 2 мин).
    Язык надписи — `KismetInternationalizationLibrary:GetCurrentCulture()`.

45. **Вражеские облики (skin).** На каждой машине для такого игрока спавним настоящего NPC фракции
    (`BeginDeferredActorSpawnFromClass`, до Finish: `AutoPossessAI=0`, `bReplicates=false`), после: без коллизии,
    тика, движения, `bIsDead=true`, его оружие (Owner = он) удаляем; `Mesh` NPC прицепляем к `Mesh` игрока
    (Snap) + `SetMasterPoseComponent(игрок.Mesh)` — снаряжение (жилет, шлем, подсумки) едет вместе; тело
    игрока `SetHiddenInGame`. Внешность NPC игра выдаёт сама при спавне (MID + аксессуары, как у настоящего).
    16 классов в `S.SKINS`; `T2C.mySkin`, config `skin=`, F4 «LOOK» по кругу; поле в `CU`.
    Мол-копы — `NPC_MallCop_*`; «TTMF» в файлах игры не найдено.
    **Баг 0.6.5–0.7.1:** saveConfig писал `cfg.model` (nil в новом конфиге) → мод падал при загрузке у новых
    установок. Исправлено (look/skin через tostring).
46. **Каталог обликов и превью (v0.7.3).** `S.catalog()`: AssetRegistry `GetAssetsByPath` по /Game/Character/NPC,
    /Game/Blueprint/HVT, /Game/AssetPack → классы `NPC_*` (фильтр CAT_SKIP), фракция = папка после /Type/.
    ~328 вариантов, 30 фракций; id облика = путь класса. Скелет не как у игрока → `S.badSkin`.
    TTMF = `NPC_GuardElite_NVG` / `NPC_Guard_NVG_SMG` (Horizon с ПНВ).
    Превью: фигура (`SetVisibleInSceneCaptureOnly`) + `SceneCapture2D` (show-only список, FinalColorLDR) →
    RT 300x450 → `Image:SetBrushResourceObject`. **Заспавненные PointLight — Stationary: двигать нельзя, они
    оставались в центре фигуры** (светили изнутри → чёрная фигура с бликами). Нужен `SetMobility(2)`.
    Свет на lighting channel 1 (фигура: каналы 0+1) ~100–170 тыс. Фон — куб 0.05x6x7 с
    `/Engine/EngineDebugMaterials/DebugMeshMaterial` + `SetVectorParameterValueOnMaterials("Color", 0.15)`
    (BasicShapeMaterial — клетка, параметра Color у него нет). Фигура «свой наряд» — SkeletalMeshActor, его
    меш = корень (смещение по Z только через актёра); AnimBP игрока без игрока = Т-поза → берём позу
    невидимого ручного NPC (`SetMasterPoseComponent`, `VisibilityBasedAnimTickOption=0`).
47. **Меню F4 в стиле игры.** Плитки = Border (серый край) + Border (заливка) + TextBlock + прозрачный Button
    поверх (клик/наведение опросом). Шрифт/цвет/клиппинг TextBlock пишем ДО AddToViewport (`t.Font.Size`,
    `SetColorAndOpacity`, `Clipping=1`). Масштаб панели под высоту экрана в `layoutMenu`. F5–F8 убраны.
48. **Враги у клиента в позе падения.** Реплицированные копии NPC приходят с `MovementMode=0` (None) →
    AnimBP `IsOnGround=false`. Клиент раз в 0.5 с ставит живым (Health > 0) `SetMovementMode(1)`.
49. **Индикатор гранат** — компонент `BP_CircleGrenadeIndicator` на КАЖДОМ PlayerBP рисует на наш экран.
    Оставляем тик только у своей пешки (у чужих выключаем и чистим `PointDamageIndicators`).
50. **Костюм хоста утекал клиенту** (bReplicates=false до Finish не помог) → `bOnlyRelevantToOwner=true`.
    **Не править main.lua через PowerShell Get-Content/Set-Content** — читает UTF-8 как cp1250, ломает русские строки.
51. **Взаимодействия (клавиша F)** — `UBaseInteractableComponent` (`bAllowInteraction`, `InteractDuration`,
    `bIsCountingDownDuration`, `RemainingDuration`, `Interact(instigator)`, Enable/DisableInteraction). Игра зовёт
    их нативно: хуки Lua на `BasePlayer:Interact`/`BPOnInteract`/`Interact` компонента НЕ срабатывают от нажатия.
    Поэтому опрос своей пешки: `pawn.InteractableComp` = объект в фокусе. Мгновенный (dur ≤ 0) срабатывает на
    нажатии F, и к нашему тику фокус уже пуст, а подобранный предмет уничтожен → запоминаем имена объекта в
    фокусе прошлого тика. Долгий — видим отсчёт (`RemainingDuration` до ~0). Выполнить объект сразу из Lua:
    `InteractDuration=-1` на время вызова `Interact(кто)`. Сцены `BP_PlayerInteraction_C` (тяжёлые двери
    культистов) хост проигрывает марионеткой напарника — камера/ввод хоста не трогаются, сюжет идёт.
    `ExecuteInteractionSequence(pawn)` тоже запускает сцену. Сообщения IA (клиент→хост), IX, IE (вкл/выкл).
    Личное (интел, коллекционное, подборы, ящики, двери, убежище) не синхронизируется.
52. **Метки задач** — `BP_ObjectiveIcon_C` уровня (имена одинаковые), `IconActive`, `Sickle_ShowIcon/HideIcon`,
    тексты `Localized Text 1/2` (классы) → `Override Icon Text`. Сообщение OB. Свои иконки мода — `S.modIcons`.
53. **Заложники (живой щит)** — `BasePlayer.MyHostage/bHasAHostage`, `TakeHostage(npc)`, `ReleaseHostage`,
    `ThrowHostage`; NPC `bIsAHostage`, `StartBeingHostage(holder)/StopBeingHostage`. Марионетка на хосте берёт
    настоящего врага (HG/HR); бросок отличаем по смещению врага через 0.4 с. Имена NPC у хоста и клиента разные.
54. **Огонь** — `NPC.FireComponent` (`OwnerActorStartFire(-1, instigator)`; с 0 не горит). Поле `IsOnFire` из Lua
    читается false даже когда горит → `GetRemainingBurnDuration(out)`. Либа `/Game/Blueprint/Entity/Fire/BP_FireLib`.
    Сообщения FI (клиент→хост), FV (хост→клиенты, для вида). Копии у клиента никого не обжигают.
55. **Счётчик врагов «Орды» у клиента был 0** — post-хук на Tick виджета не срабатывает (BP), Tick пишет 0 каждый
    кадр. Подменили переменную `EnemiesTextBox` на запасной TextBlock (Tick пишет в него), видимый держим сами.
56. **Действия тела (v0.7.5)** — у оружия `WeaponAnimSet` (FWeaponAnimSet): массивы Reload, Reload_Empty, Melee,
    Melee_Impact, Throw_Grenade, Equip... из FWeaponAnim {FPP_Character, FPP_Weapon, TPP_Character, TPP_Weapon}.
    Своя пешка: `Mesh1P:GetAnimInstance():GetCurrentActiveMontage()` → ищем FPP в наборе → `BA|набор|индекс`.
    Получатель: `pawn.Mesh:GetAnimInstance():Montage_Play(TPP_Character, 1, 0, 0, true)` (+ TPP_Weapon на Mesh3P).
    ABP_TPP_Player монтажи проигрывает (перезарядка, замах видны). Fire не шлём (выстрелы — HF).
57. **Сложность под число игроков (v0.7.6)** — у NPC поле `Health` (MaxHealth — только функция GetMaxHealth). Хост
    каждому новому NPC: Health *= 1 + (игроков-1)*enemy_hp/100 (config, по умолчанию 50). Урон проходит как обычно.
58. **Полоса босса (v0.8.0)** — `UI_BossHealthBar_C` (/Game/UI/UI_BossHealthBar): Character, BossName, Stages, Health,
    MaxHealth, `UpdateBar()`. Создаёт игра хоста. Хост → BB|1|xyz|стадии|имя|класс, BB|0 когда пропала. Клиент создаёт
    свой виджет на копии босса и каждые 0.2 с пишет Health/MaxHealth + UpdateBar (событий урона у копии нет).
    MaxHealth виджета = базовое здоровье → при enemy_hp поднимаем до текущего.
59. **HUD гостя был привязан к марионетке** (`PlayerHUD2_C.Player` = чужая пешка): белая полоса здоровья, патроны не
    убывали. Раз в 1 с привязываем видимый HUD к своей пешке.
60. **Индикаторы урона/обнаружения** (`BP_CircleDamageIndicatorComponent`, `BP_CircleDetectionIndicator`) на чужих телах
    рисовали у хоста дуги попаданий по напарнику. Чистим их массивы (элементы бывают null — читать по одному).
    Напарнику хост шлёт в `H` точку стрелявшего (NPC с наибольшим `LastTimeFiredWeapon`, иначе ближайший);
    `AddIndicator(loc, npc, nil)` без NPC ничего не рисует.
61. **Место появления гостя (v0.8.1)** — раньше хост +120 по X (в стену / за карту на сайд-миссиях). Теперь
    `S.freeSpotNear`: 8 направлений (сначала за спиной) на 130–220, путь от хоста свободен (LineTraceSingle) и пол
    под точкой. Сайд-миссии (`/Game/Maps/SideMissions/*/SideMission_*`) хостятся как кампания; в начале Cavern игра
    сама ведёт обоих игроков (вступление).
62. **Управление за меню** — в коопе игра не ставит паузу, Esc-меню (`UI_MainMenu_C`) и F4 пропускали управление.
    Пока открыто: `SetIgnoreMoveInput/LookInput(true)` + `pawn:DisableInput(pc)`; флаги переустанавливаем, если их
    сбросили (меню/конец катсцены). У гостя после подключения висел `UI_MainMenu_C` — первые 15 с убираем.
63. **Проверка боссов HVT (2026-11-11)** — Chronos (`NPC_HVT_Chronos_1Actual`), Hellfire, Biohacker, заспавненные у хоста
    (`world:SpawnActor` + `SpawnDefaultController`): у клиента те же копии, здоровье совпадает (с enemy_hp),
    урон по гостю идёт, снаряды (`BP_HelicopterMissile`, молотов) реплицируются (bReplicates=true). Ошибок нет.
    Полосы здоровья у HVT сайд-миссий нет и в одиночке. Скрипт `tools`-проб: scratchpad spawnboss.lua.
64. **Снаряжение миссии и противогаз (v0.8.2)** — KillGhosts: у хоста SMG (из сохранения/уровня) и противогаз, у гостя
    пистолет. `SwapWeapon`, `ForceEquipWeapon`, `BPInputWantPickupWeapon*` (только события), `WantedWeapon` из Lua
    оружие клиенту НЕ дают — только настоящее удержание F. Поэтому хост шлёт `LW|класс` (не в «Орде»), клиент кладёт
    такое оружие под ноги + уведомление. Противогаз: `bIsWearingGasMask`, `Start/StopWearingGasMask(bInstant)`;
    хост → `GM|1/0` всем и надевает на марионеток. Путь карты: /Game/Maps/Campaign/Ghosts/KillGhosts_Persistent.
65. **KillMothman: клиент падал/зависал при входе (с v0.7.4)** — поиск выключателями `T2C.off.<имя>` (fire, ie, ob, obl,
    hg, ia, hud) до подключения: виновата синхронизация меток (OB). (1) `LoadAsset` классов текста метки во время
    загрузки карты — зависание; теперь только StaticFindObject. (2) SpawnActor своей метки, пока подуровень с копией
    ещё не подгружен и клиент только настраивается, — падение (запись по 0x8 в хуке UE4SS). Теперь OB копятся и
    применяются через 3 с после готовности пешки; свою метку создаём, только если копии нет 5 с. OwningPlayer
    задаём копиям. Карты: Mothman/Version_01/KillMothman_Persistent, Horizon/KillHorizon_Persistent,
    SafeHouse/Story/Cutscene/Safehouse_Betrayal_Sequence/Safehouse_Betrayal_Persistent, Credits/Credits_Persistent —
    все заходят вдвоём. Скрипт: scratchpad mothtest.ps1 -Off "ob,obl".
66. **Prologue: хост падал при входе гостя (v0.8.2–0.8.3)** — блок снаряжения/противогаза: `classPath(hp.CurrentWeapon)`,
    а в начале Prologue у хоста нет оружия → нативное падение в UE4SS (чтение 0x10), pcall не ловит. Всегда
    `valid(w)` перед GetClass. Плюс: к марионетке и своей пешке обращаемся не раньше 5 с после появления / при
    controllerReady; снимать противогаз, которого не было, не зовём. Выключатели хоста: mothtest.ps1 -OffA "gm".
    Случайное (1 раз из 2) зависание хоста при загрузке KillSyndicate — та же нестабильность, что в п. 36.
67. **Наблюдение, пока ранен (v0.9.0)** — через 2 с после ранения `pc:SetViewTargetWithBlend(тело напарника, 0.5)`:
    вид его глазами (камера его пешки). ЛКМ (опрос IsInputKeyDown каждые 30 мс; 100 мс пропускали щелчок) — на себя
    и обратно. После подъёма — вид на свою пешку. Во время катсцены не трогаем.
68. **Прогресс напарника (v0.9.1)** — GameInstance.UnlocksSaveObject: CompletedMissions (FFMissionCompletionInfo:
    `Mission_4_7EA28D0040AFB8097BCF4889ED5885CF`, `Difficulty_7_C28D9D48484BF1C47AE50F8F002D02D3`), KilledHVTs (элементы —
    сами UClass, без :get()), UnlockedIntelFiles. Выходные TArray-параметры (GetCompletedMissions(t)) из Lua пустые —
    читать поля объекта напрямую. Хост → `PG|M|класс|сложность`, `PG|H|класс` при входе и при росте списка. Клиент
    (через 4 с после готовности пешки): миссия — SetLowestDifficultyThisMission + SetCurrentMission(cls) +
    CompleteCurrentMission (+ вернуть текущую); HVT — HVTKilled(cls) (класс грузить LoadAsset); затем SaveUnlocks.
    Проверка: у B до входа очистить списки в памяти (mothtest.ps1 -PreB) → после входа 12/27. Повторное подключение
    после вылета гостя (убить процесс B, запустить, JOIN) работает без доработок.
69. **HUD гостя в сценах-камерах (v0.9.2)** — сцена предательства: у обоих вид через `CineCameraActor`, но HUD у гостя
    оставался. Клиент: пока класс view target содержит "Camera" — `PlayerHud:SetRenderOpacity(0)`, потом 1.
    Стабильность: 4 перезагрузки KillMothman подряд с гостем — без падений.
70. **Проверки 2026-11-12 (v0.9.3)** — 3 игрока (копия C): чужие выстрелы и перезарядка доходят до третьего.
    Запуск хоста + вход гостя подряд: KillSyndicate 4/4, Prologue 3/3, KillGhosts 3/3 — без зависаний/падений
    (scratchpad hostloop.ps1). Хост пропал → гость в меню, 12 попыток по 15 с; теперь с надписями «переподключение
    k/12» и в конце «связь потеряна - F4, JOIN», `S.joined=false`.
71. **Производительность Lua (v0.9.4)** — профилировщик: `T2C.prof = {}` → время каждой задачи S.every (ключ —
    строка + интервал), `T2C.profTop(8)`. Было ~1.7–1.9 с Lua за 20 с боя (≈9%). Главное: `engine()` каждый раз
    `FindFirstOf("GameEngine")` (через netDriver/world почти во всех задачах) — теперь кэш; `localPC()` — кэш на тик
    планировщика (`S.tickId`); задачи «каждый кадр» → 30 мс; ранение-наблюдение выходит сразу, если не ранен;
    взаимодействия не читают клавиши без фокуса; гранаты клиента 100 мс; индикаторы 250 мс; F4 80 мс.
    Стало: хост ~1.07 с, гость ~0.84 с за 20 с (≈4–5%). Функции перепроверены.
72. **Гранаты напарника срабатывали у хоста с задержкой ~20 с** — актёр гранаты (FragGrenadeProjectile_C) после взрыва
    живёт ещё ~20 с (звук/частицы); мы ждали его уничтожения. Признак взрыва: `Mesh:IsVisible()` = false (через ~2 с
    запала). Обработанные — в `S.grenDone`, чтобы не послать дважды. Гранаты у клиента для теста:
    `pawn.GrenadeInventory[1].NumGrenades = 3`, клавиша G.
73. **Прогон старых функций на 0.9.5 (2026-11-12)** — пинок/удар гостя по врагу (MK) 3/3; выстрелы гостя: трасса хоста
    совпадает с трассой самого гостя (scratchpad aimtp.lua + aimdo.lua + ctrace.lua; «за спиной врага» часто ставит
    в стену — целиться спереди и в следующем кадре после телепорта); перезапуск арены, когда все ранены, +
    переподключение гостя; 3 игрока; меню блокируют управление; наблюдение. Новых ошибок нет.
74. **Сквозной цикл кампании (2026-11-12)** — KillCultists: хост `Trepang End Level(w, true,
    FName("/Game/Maps/Campaign/SafeHouse/SafeHouse_Persistent"), nil)` → убежище, гость следом; в убежище
    `SafehouseMissionSelected(Mission_Ghosts_C)` + `BP_HelicopterStartMission_C:SetMissionReady/StartMissionSequence` →
    KillGhosts, гость следом. С FName("None") игра уходит в главное меню (хостинг корректно останавливается).
    Удалить один элемент TArray из Lua (`RemoveAt`) нельзя — index out of range.
75. **Быстрее обратно после смены уровня (v0.9.6)** — переподключение: первая попытка через 4 с, дальше каждые 6 с,
    30 попыток (было 8 / 15 / 12); «хост не отвечает» только с 4-й. Перезапуск KillCultists: гость снова в игре
    через 14 с (было 18–20), KillMothman 14–16 с. Скрипт замера: scratchpad rejointime.ps1.
76. **Фонарик (v0.9.7)** — `BasePlayer.bPlayerFlashlightOn`, `FlashlightOn()/FlashlightOff()` (клавиша T). `FL|1/0`
    клиент→хост (свет на марионетке, пересылка `FL|pid|1/0`), хост → всем; повтор раз в 5 с для новичков.
    Двуручной позы для двух пистолетов в ABP_TPP_Player нет (ELeftHandAnimOverride: None/Shield) — не исправить.
77. **Замедление (v0.9.8)** — у хоста: `bIsSlowMoActive`, глобальная `GetGlobalTimeDilation` = SlowMoFactor 0.35, игрок тоже
    замедлен (CustomTimeDilation 1). Глобальная замедленность хоста реплицируется клиентам (у клиента тоже 0.35).
    У клиента своё замедление НЕ включается (Q, даже с RechargeSlowMo(100)) — игра включает его через сервер. Мод
    читает Q / Gamepad_LeftShoulder у клиента → `SM` → хост `SetGlobalTimeDilation(0.35)` на 5 с (второе Q — стоп,
    перезарядка 10 с). Наблюдение: 2 раза из ~11 гость (B) зависал (кадр стоит, ядро 100%) около замедления хоста;
    не воспроизводилось 9 раз подряд — причина не найдена. Хост 1 раз завис (0% CPU) при загрузке Horde_Killhouse
    после host() — редкая блокировка при загрузке (как п. 36), ~1 из 25 запусков.
78. **Невидимость (v0.9.9)** — `bIsInvisActive` (E). У клиента включается только на своей пешке → враги у хоста
    видели марионетку. `IV|1/0` клиент→хост (`SetIsInvisActive` + `BPStartInvis/BPStopInvis` на марионетке; экран
    хоста не трогает), хост → всем. Облик врага (S.costumes[тело].actor) и `CurrentWeapon` скрываем отдельно
    (SetActorHiddenInGame). Невидимость марионетки кончается по своему таймеру раньше «IV|0» — внешний вид
    применять всегда, не выходить по совпадению bIsInvisActive.
79. **Редкое зависание при загрузке — ПРИЧИНА (v0.9.10)** — инструмент `tools/hangstack.py <pid>` (dbghelp
    StackWalk64, без отладчика): главный поток в FEngineLoop::Tick → Slate (строки "EventWait/Slate",
    "DeferredTickTime") ждёт критическую секцию, второй поток движка ждёт ту же; кода Lua в стеках нет.
    Мод при каждом OpenLevel и 15 с после него звал `GameInstance:ForceStopLoadingScreen()` (снять «нажмите любую
    клавишу») — если экран загрузки ещё рисовался в своём потоке → взаимная блокировка. Теперь
    `gi:BPOnLoadingScreenKeyPressed()` (как нажатие клавиши, путь игры). После: 12 запусков хоста + вход гостя
    (KillCultists 4, Horde 6, …) и 4 перезагрузки — 0 зависаний (было ~1 из 10–25). `T2C.forceStopLS=true` — старый путь.
80. **Обвесы оружия напарника — НЕ делать через Lua**: обход `WeaponCustomizationCategories[i].CustomizationOptions[j]`
    (массив структур в массиве структур; FName/bIsActive внутри) уронил UE4SS (исключение в Lua VM, UE4SS+2be6xx) у
    обоих. Откатено; марионетка держит оружие без обвесов/скина.
81. **Пинг (v0.9.11)** — X / Gamepad_DPad_Left (свободны): луч камеры 60 м → BP_ObjectiveIcon (S.modIcons) с именем
    на 8 с, `PN|имя|xyz` клиент→хост→остальные. Одна метка на имя. Проверка устойчивости после фикса экрана
    загрузки: KillMothman 4/4 запуска.
82. **Здоровье на метке напарника (v0.9.12)** — каждый шлёт свой % (`HP|pct|down`, раз в 5 с или при изменении),
    хост пересылает `HP|pid|pct|down`; `labelFor` подписывает «Имя  60%» / «Имя - DOWN» у всех (раньше DOWN — только хост).
83. **Метка на враге (v0.9.13)** — луч пинга попал в BaseNPC → шлём позицию врага с флагом (`PN|имя|xyz|1`), у получателя
    иконка `K2_AttachToActor(ближайший NPC)` +110 по Z, подпись «Имя: ВРАГ». Тест: у клиента подвинуть СВОЮ копию NPC
    перед камерой (это только локально) и нажать X. `Net PktLag` в shipping не работает (пинг не меняется).
84. **«TO THE HOST» в F4 (v0.9.14)** — клиент `TH` → хост `S.freeSpotNear` + `S|xyz|yaw` (тот же обработчик спавна
    двигает пешку клиента). Откат 10 с. `T2C.onKey(action)` — выполнить действие меню из тестов. Урон по своим:
    выстрелы хоста по марионетке не ранят (счётчик урона марионетки не меняется), клиентские трассы игроков
    пропускают — по своим урона нет. ENEMY HEALTH у гостя: «+50% PER PLAYER - WHEN YOU HOST».
85. **Магазин «Орды» у напарника (v0.9.15)** — деньги = `CPPFPSGameMode.Credits` (только у хоста; SetCredits/
    SubtractCredits). Магазин клиента `UI_BuyZone_C` (CurrentCreditsText — пишем деньги хоста из HUD-сообщения).
    Pre-хук `UI_BuyZone_C:OnItemButtonClicked(Item)` (регистрировать, когда окно видно; класс может перезагрузиться
    — ключ по адресу класса) → `BY|путь товара` → хост: CDO.Price, проверка, SubtractCredits; отряды (FriendlyNPCs) —
    `zone:OnItemPurchased(cls)` у хоста; иначе `BYOK` → клиент спавнит CDO.Contents (UClass-элементы) у себя ЗА
    СПИНОЙ (перед ним ящик — F снова открыл бы магазин). Закрыть магазин у клиента было нельзя (закрытие идёт в
    зону, которой нужен GameMode) — хук на CloseMenu/кнопки закрытия + Esc → RemoveFromParent + GameOnly.
    Проверено и с отрядом: `BY|.../BZ_TF27_AssaultSquad...` от клиента → у хоста +4 NPC, у клиента тоже, −1500.
86. **HP и пинг в списке F4 (v0.9.16)** — свой процент из `myPawn().Health / me.max`, чужие из `S.hpOf[PlayerId]`,
    пинг `PlayerState.Ping * 4` мс. `T2C.playerList()` — текст списка для проверки.
87. **Автоперенос напарника к хосту (v0.9.17)** — хост раз в 250 мс сравнивает своё положение: скачок > 2500 ед.
    (скрипт уровня перенёс его: Backrooms, переходы сцен) → через 1,5 с всех, кто дальше 2500 ед., переносит
    обработчиком `TH` + уведомление. Пока вид на камере сцены (view target ≠ пешка) — ждёт. Выключатель
    `T2C.off.autofollow`. Проверено в Killhouse: перенос хоста к BuyZone → гость рядом через 1,6 с.
88. **Модификации оружия и парное оружие у напарника (v0.9.18)** — `UnlockedWeaponCustomizations` (UClass'ы) →
    `PG|C|класс` → клиент `gi:UnlockWeaponCustomization(cls)`; `DualWieldUnlocked` → `PG|D|dual` → поле = true;
    затем SaveUnlocks. Проверка: у B очистить в памяти (Empty / false) до входа → после входа 21/true, как у хоста.
89. **Хост падал на сайд-миссии BadOil при входе гостя во вражеском облике (v0.9.19)** — `wearCostume` создавал
    NPC-костюм на 5000 ед. НИЖЕ игрока: на BadOil это ниже KillZ → движок убивал NPC → падение в
    `SnapshotPose` (поза смерти; стек через хук UE4SS, чтение 0x0). Теперь +3000 (выше). Проверка: открыть сайд-миссию
    одному, F4 HOST (`T2C.onKey("host")`), вход B — scratchpad sidetest.ps1. Внимание: `T2C.netDriver` не
    существует (локальная функция) — проверять `FindAllOf("IpNetDriver")` / netstat.
90. **Все сайд-миссии вдвоём (v0.9.20)** — список: `GameInstanceBP.RequiredMissionsList:GetCDO()` → CampaignMissions
    (+ BadOil, TeamSpirit), SideMissions (sm_complex, OilRig, Cavern, ServerRoom, WetBasement, GroundedAviation),
    поле `MapName` (короткое имя, `open <имя>` работает). На sm_complex и WetBasement нет PlayerStart →
    `RestartPlayer` пешку не создаёт (гость без пешки; на sm_complex ещё и зависание гостя в SetSkeletalMesh при
    одевании — после исправления пропало). Теперь запасной путь `gm:RestartPlayerAtTransform(pc, рядом с хостом)`.
    Проверено: все 9 карт — хост через F4, вход гостя, гость рядом, без падений/зависаний. Выключатель `T2C.off.dress`.
91. **F4 HOST на картах кампании (2026-11-12, v0.9.20)** — зайти одному, F4 HOST, вход гостя: Prologue, KillMothman,
    KillCultists, KillGhosts, KillHorizon — гость рядом с хостом, без падений/зависаний (scratchpad sidetest.ps1).
92. **Steam-режим просил перезапуск бесконечно (v0.9.21)** — игра при выходе пишет Engine.ini ИЗ ПАМЯТИ: удалённая
    нами строка `DefaultPlatformService=Null` возвращалась. Теперь при смене режима мод запускает
    `Mods/T2Coop/fixini.ps1` (скрытый powershell через os.execute): ждёт, пока все CPPFPS-Win64-Shipping закроются,
    и ставит режим в Engine.ini. Проверено: steam → выход → строки нет → запуск iniOk=true, хост = SteamNetDriver;
    обратно ip → Null вернулась.
93. **Скорость сети (v0.9.21)** — по умолчанию MaxInternetClientRate 10000 Б/с, 30 обновлений/с: через VPN/интернет
    рассинхрон. Хост раз в 2 с: NetDriver MaxClientRate/MaxInternetClientRate = net_rate (config, 200000),
    NetServerMaxTickRate 60, каждому `pc.NetConnection.CurrentNetSpeed`; клиент: `netspeed N` + ServerConnection.
94. **Переподключение после смены арены (v0.9.21)** — попытка, сделанная пока хост ещё грузится, оставляет игру в
    состоянии, где `open <ip>` больше ничего не делает (16 попыток подряд). LEAVE (OpenLevel меню, S.joined=false)
    и JOIN через 10 с — входит всегда. Теперь со 2-й попытки так и делаем (S.rejoinMenuAt), пауза 15 с.
    Проверка: 7 смен арен подряд, гость каждый раз вернулся. Все 47 арен: вход гостя рядом с хостом.
    Автоперенос к хосту сбрасывается при смене уровня (новая точка старта — не «скачок»).
95. **F4 по вкладкам + EXTRAS + F6 (v0.9.21)** — меню перестраивается на вкладку (S.menuTab): CO-OP / LOOK / EXTRAS,
    панель по высоте вкладки. EXTRAS (свои у каждого, Mods/T2Coop/extras.txt): HealthRegenLimit (игра 40 из 200),
    MaxArmor (50), пополнение (Inventory[i].CurrentAmmo += AmmoPerClip, GrenadeInventory[i].NumGrenades +1 до
    MaxGrenades, RechargeSlowMo), за убийство (хук PlayerBP_C:BPDamagedOther bKilled; гостю хост шлёт `KL`),
    лечение за казнь (MyHostage был → пропал и мёртв). Модификации оружия: хук
    `BaseWeapon:SetWeaponCustomizationOptionActive` (его зовёт меню оружия) → extras_mods.txt, на новое оружие
    того же класса ставим по индексу. ЧТЕНИЕ `SavedCustomizations` (массив структур с FName) роняет UE4SS
    (2be607) — не трогать. Номер вне диапазона в SetWeapon...Active безопасен. Читы = cvar из
    `UBaseCheatObject.ConsoleCommand` (cheat.AllWeaponsADS...): игра их сбрасывает при перезапуске игры;
    запоминаем ненулевые (extras_cheats.txt) и ставим через 4 с после загрузки уровня. Рандомайзер: ApplyWeaponSkin
    (AllSkins) + случайные индексы модификаций; оружию врагов случайные скины. F6: BPOpenWeaponCustomizeMenu,
    BP_SafehouseMissionMapInteract:InteractWithMissionMap, BP_SafeHouseCustomizeInteract / BP_SafehouseScreen_Cheats
    (их BndEvt__..OnInteractDelegate, ищем через ForEachFunction), BP_SafeHouseCombatSimulatorInteract:
    InteractCombatSimulator, BP_HordeBuyZone:ShowMenu (у гостя тоже).
96. **Облики врагов, вешающие игру (v0.9.22)** — отзыв с Nexus: часть обликов в F4 вешала игру. 28 классов NPC
    (Hazmat, SSF, рабочие нефтевышки, часть TF63 и др.) навсегда зависают в синхронном LoadAsset (стек: GetAsset,
    tools/hangstack.py). Найдено перебором всех 328 обликов, каждый перепроверен в свежей игре (контрольный облик
    прошёл). Они во встроенном списке S.badSkin. Страховка: loadObj пишет Mods/T2Coop/loading.txt перед
    LoadAsset и удаляет после; если при запуске файл есть — облик заносится в bad_looks.txt. Сохранённый плохой
    облик сбрасывается на свой наряд (одно уведомление).
97. **Падение обеих игр после ~7 открытий LOOK в коопе (v0.9.22)** — рендер-поток (DrawSceneCommand) после
    многократного создания/удаления SceneCapture2D + NPC-фигуры + света. Соло и без превью не воспроизводится.
    Скрытие оружия NPC вместо удаления и удаление камеры первой не помогли. Помогло: при закрытии меню превью
    только ставится на паузу (S.previewPause: bCaptureEveryFrame=false, картинка прозрачная), при открытии с тем
    же обликом — просыпается. 16 повторов — 0 падений; долгий прогон в коопе по всем 300 обликам (оба игрока
    надевают облик, LOOK, ходьба, стрельба; scratchpad coopsweep.ps1): 299/300 без проблем, одно падение обеих
    игр (хост первым, AV) на NPC_HECU_AR2 — при 3 повторах этого облика в свежих играх не повторилось.
98. **Падение гостя при загрузке чекпоинта (v0.9.23)** — `Trepang Load Last Save(w, false, w)` у хоста (3 параметра)
    → гость переподключается и получает пачку DO (все двери), OB, TR, HP в том же кадре, что и точку появления.
    AV (чтение 0x2b8, через UE4SS) у гостя 2 раза из 8 (KillMothman). Двери теперь в очереди S.doQueue —
    применяются через 3 с после готовности пешки (как TR/OB): 15/15 без падений, двери у гостя = у хоста.
    Журнал всех входящих сообщений: переменная окружения T2RX=1 при запуске (S.logRx). Скрипт:
    scratchpad reloadloop.ps1. Хост больше не рассылает наряды (CU) ушедших игроков (S.looks чистится).
    Проверено: Safehouse_Betrayal — сцена у обоих, затем игра сама грузит KillSyndicate, гость следом
    (входит, когда хост закрыл экран загрузки). Телепорт в далёкие части уровня + принудительная загрузка
    подуровней (SetShouldBeLoaded) у хоста НЕ доходит до гостя — гость падает сквозь пол; в игре подуровни
    грузят триггеры, их гость повторяет. Mothman получает урон только по слабым местам (тест на арене
    бессмыслен).
99. **Конец игры (v0.9.24)** — Credits_Persistent: текст и видео у обоих; «нажмите клавишу» у хоста →
    Trigger_EndLevel_Credits → главное меню, у гостя связь рвётся. TR об этом триггере не успевает уйти
    (переход в тот же кадр). Хук GameInstance:HandleNetworkError НЕ вызывается (ни при выходе хоста, ни при
    его падении). Решение: гость помнит уровень (S.clientLevel, раз в 1 с, пока есть связь); потеря хоста на
    уровне Credits* — конец игры, без переподключения, уведомление.
100. **Гость выпал за карту (v0.9.25)** — ниже WorldSettings.KillZ движок уничтожает локальную пешку гостя
    (AActor::FellOutOfWorld: скрыть, без коллизии, Destroy): у гостя белая пустота, pc.Pawn/c.pawn —
    уничтожаемый актёр, TO THE HOST (K2_SetActorLocation по нему) → падение игры. Теперь у гостя раз в
    250 мс: `IsActorBeingDestroyed()` → c.pawn=nil + TH (код появления берёт c.puppet и делает новую пешку);
    z < KillZ+3000 или падение (MovementMode 3) дольше 10 с → TH. У хоста марионетка тоже уничтожается →
    RestartPlayer делает новую, перезапуска уровня нет. Настоящая смерть марионетки (урон без DamageLimit)
    у хоста = смерть игрока → перезапуск арены/чекпоинта (поэтому лимит урона марионетки важен).
    Прогон всех карт кампании: вход гостя + 3 перезапуска уровня — 0 падений (scratchpad mapsweep.ps1).
101. **Лифты (v0.9.26)** — актёры лифтов уровня НЕ реплицируются (bReplicates=false, у клиента Role=0):
    TravelDown у хоста — у гостя лифт стоит. Классы: BP_CultistHubElevator (TravelDown/Up), BP_Finale_Elevator
    (Prologue, x11, TravelToTargetZ/OpenDoor/CloseDoor), BP_GhostElevator, BP_MonolithEnemySpawnElevator,
    BP_ShadowBayCrashElevator, BP_HorizonAtriumElevatorNew, BP_HorizonUnderpassElevator, BP_MothmanElevator,
    BP_ReactorExitElevator (BP_MothmanRooftopElevator — скелетная анимация, не трогаем). Хост раз в 100 мс шлёт
    `EL|имя|xyz` сдвинувшихся (и всех сдвинутых раз в 3 с), гость догоняет за ~0.1 с (K2_SetActorLocation без
    sweep/teleport — стоящий на платформе едет). Двери — компоненты лифта: хост вешает хуки на все функции
    `*Door*` класса (кроме Delegate/Timeline) → `ED|имя|функция`, гость вызывает свою (ForEachProperty у
    UFunction считает и локальные переменные — параметры так не посчитать). Проверено: KillCultists — гость
    доехал с хостом (-2642 у обоих); Prologue — OpenDoor/DisableDoorBlocker у гостя. Выключатель T2C.off.elev.
102. **Повтор функций уровня (v0.9.27)** — то же, что двери лифтов, для MIRROR (класс → шаблоны имён):
    BP_PrologueDroneRollUpDoor (StartRoll*), BP_LaserGate (TurnOnGate/TurnOffGate — с параметром; у гостя
    включённый лазер наносит урон), BP_CaveCollapseSandWall (Activate/Deactivate). Хук получает параметры:
    bool/число уходят в `ED|актёр|функция|b1,n5`, гость вызывает с ними. Хуки ставятся при пересборке списка
    раз в 10 с (класс должен быть загружен; первые ≤10 с после подгрузки подуровня — без повтора).
    Найдено сканом классов (scratchpad movscan.ps1): ворота библиотеки = BP_BaseDoorNew (обычные двери, DO).
103. **Хост ушёл в меню (v0.9.28)** — в хуке OpenLevel хоста (FrontEndMenuMap): S.toClients("BYE") +
    pumpMessages() прямо там (переход случится раньше следующего тика; ClientMessage успевает уйти — в этом
    хуке мы и так вызываем OpenLevel). Гость: S.hostQuitAt → не переподключается, уведомление.
    Концы миссий (scratchpad endchain.ps1, TryTrigger Trigger_EndLevel_C у хоста): KillGhosts и KillSyndicate →
    SafeHouse_Persistent, гость следом. Trigger_EndLevel_Credits_SkipCutsceneInstant (KillSyndicate) → сразу
    FrontEndMenuMap. Prologue/Cultists/Horizon/Mothman — без Trigger_EndLevel (конец через сцены/эвакуацию).
104. **Падения при смене уровня (v0.9.29)** — (1) хост: AV через ~3 с после «host travel» (KillGhosts конец →
    SafeHouse, 2 из 3). Сообщение гостя (AS) лежало в inbox с указателем на PlayerController старого мира и
    обрабатывалось после загрузки новой карты. Теперь inbox очищается в LoadMapPre и LoadMapPost, а задачи
    мода стоят с запроса перехода (S.awaitHostLoad + S.travelReqAt, не дольше 20 с) до загрузки. 8 кругов
    (16 переходов) — 0 падений (scratchpad endloop.ps1, T2RX=1 — журнал входящих). (2) гость: AV 0x2b8 при
    входе на уровень — IE (EnableInteraction/DisableInteraction) и MI (SetCurrentMission) теперь только при
    S.settled(3) (пешка гостя готова ≥3 с; сброс в LoadMapPre). Регрессия к 1.0: 50 арен «Орды» (hordesweep),
    7 сайд-миссий (sidetest), все карты кампании, бои 40+30 раундов — без падений.
105. **Падение гостя после конца миссии (v0.9.30)** — AV 0x2b8 (то же место, что п. 98). tools/dumpstack.py
    (раскрутка x64 по .pdata из минидампа) дал стек: EngineTick → тик актёров → TickActor ([vtable+0x408]) →
    Tick ([vtable+0x460]) → ABaseCharacter (пересчёт CurrentPitchMax: присед/заложник/скольжение) →
    Cast<APlayerController>(Controller)->PlayerCameraManager (+0x2B8) при пустом контроллере. Перебор гипотез
    (нажатие «любой клавиши», катсцена, костюм) не помог; настоящая причина по журналу: попытка входа №1
    (open) ещё шла, когда мод на попытке 2 ушёл в меню (S.joined=false) — соединение всё же завершилось, игра
    на карте хоста, а мод не считает себя гостем (никаких защит) → тик чужой пешки. Теперь: задача раз в
    100 мс — есть NetDriver.ServerConnection, но S.joined=false → S.joined=true («connected after all»);
    BeginPlay-защита работает и при (not S.hosting and netDriver()). Под нагрузкой (запись видео) это было
    почти каждый раз; после — 11/11 без падений (+5 кругов endloop, 6 перезагрузок чекпоинта).
    Заодно у гостя: все пешки игроков, кроме созданной модом (S.spawningOwn при FinishSpawningActor),
    SetActorTickInterval(1e6) + SetActorTickEnabled(false) + PrimaryActorTick.bCanEverTick=false (иначе
    SetActorTickEnabled(true) из скриптов уровня включает тик обратно); у марионетки (Role 2) выключен тик
    CharacterMovement; pc.Pawn/марионетке проставляется Controller. Катсцена хоста: ждёт гостей, которые
    были до перехода, даже если замечена поздно (интро убежища идёт под экраном загрузки, видна с 24 с);
    гость считается «на месте», когда шлёт сообщения ≥3 с (S.firstSeen). Гость подхватывает CS только при
    S.settled(2). Trigger_EndLevel* гость не повторяет. Попытка «гость ждёт конца сцены» (CW) отменена:
    Safehouse_Betrayal — одна длинная сцена, гостя выкидывало раз за разом.
106. **До 4 игроков (после v1.0.0)** — копия D (`C:\Users\PC\Trepang2_D`, как C: Binaries копией, Engine/Content/Plugins —
    junction). Инструменты знают A–D; `tools/test_four.ps1` (хост + B,C,D, кто кого видит, -Restarts N), `tools/bigrun.ps1
    -Players N` (большой прогон всех функций). Жёсткого лимита игроков в моде нет: 4 игрока в Орде и кампании
    (вход + перезапуски) работают. Найдено: (1) список игроков F4 вмещал 3 строки — поле увеличено; (2) наблюдение
    лёжа показывало первого напарника, даже лежачего — теперь стоящие сначала, ЛКМ по кругу: напарник 1 → 2 → … →
    свой вид; (3) хост ~2 раза в секунду пытался дать пешку контроллерам уже закрытых соединений (переподключившийся
    гость оставляет старый) — теперь только живые (NetConnection + PlayerState).
107. **Зависание хоста при запуске (после v1.0.0)** — с 4 копиями хост 1 раз из ~6 вставал на «hosting» (не отвечает).
    `tools/minidump.py <pid>` (свой dbghelp-дамп: rundll32 comsvcs пишет файл с правами только SYSTEM/админов — не
    прочитать и не удалить) + `tools/dumpstack.py <dmp> 30 --threads N`: главный поток в тике (строка "Tick") ждёт
    критическую секцию, рабочий поток движка ждёт ту же — как в п. 79. Видео загрузки — MoviePlayer движка (не
    MediaPlayer; `GetIsLastLoadMoviePlaying()` = true до нажатия). Мод нажимал «любую клавишу» через ~1,5 с после
    загрузки карты — когда видео ещё переходит со своего потока Slate на игровой. Теперь не раньше 4 с (os.clock)
    после LoadMapPost: `tools/hostfreeze.ps1` 14 запусков с 4 копиями — 0 зависаний.
    Но в большом прогоне на 4 игроках хост завис снова (тот же стек). Точнее: 0x16e3250 = FSlateApplication::Tick
    (SlateTickCriticalSection на +0x580; рядом строка "EventWait/Slate" в FEngineLoop::Tick); его же зовёт поток
    экрана загрузки MoviePlayer → игровой поток держит Slate-замок и ждёт второй, поток загрузки держит второй и ждёт
    Slate-замок — гонка при остановке видео. Без нажатий мода (`hostfreeze.ps1 -NoPress`) 0/20. Мод жал «клавишу»
    каждую секунду, пока виджет жив, — повторное нажатие во время остановки видео. Теперь после нажатия 6 с пауза
    (S.lsPressedAt): 20 запусков с 4 копиями и входом гостей — 0 зависаний (всего 0/34).
108. **Падение гостя при приходе в убежище (после v1.0.0)** — большой прогон на 2 игроках, KillMothman → SafeHouse:
    AV запись по 0x230. Стек (dumpstack + natives.py): Lua → execSetSkeletalMesh → UAnimInstance::UpdateAnimation
    ("NativeUpdate"/"BlueprintUpdate") → BP анимации → memcpy в null+0x230. Мод переодевал чужие тела (wearLook →
    SetSkeletalMesh), пока уровень у гостя ещё не устоялся — та же семья «слишком рано», что 0x2b8. Теперь цикл
    тел (showAsThirdPerson, раз в 250 мс) у гостя ждёт S.settled(3), у всех — 3 с после LoadMapPost.
109. **Падение в меню: JOIN + вкладка LOOK (после v1.0.0)** — прогон на 4 игроках: гости в главном меню, подключение ещё
    идёт, скрипт открыл F4 LOOK → предпросмотр облика (SpawnActor фигуры + SetSkeletalMesh) → AV чтение 0xffff…
    Повтор: T2C.join(...) и сразу menuTab("look") + menuOpen() — падение каждый раз. Теперь S.previewUpdate ничего
    не делает (ставит на паузу), пока S.loading / S.awaitHostLoad / гость ещё не S.settled(2); S.join и S.host
    сначала удаляют предпросмотр (S.previewDestroy). Проверка: 3 круга JOIN+LOOK, затем LOOK в игре — работает.
110. **Четвёртого игрока выкидывало раз за разом (после v1.0.0)** — гость D подключался, через 10–15 с связь рвалась,
    мод переподключал, и снова. Замер (подмена T2C.toClients/toClient на 10 с у хоста): ~1285 сообщений за 10 с, из
    них AS (анимация игроков) 1125 — 15 раз/с на КАЖДОГО игрока, каждое отдельным надёжным RPC ClientMessage. Гость,
    который ещё грузит уровень, ничего не подтверждает; >256 неподтверждённых надёжных пакетов → движок закрывает
    соединение. С 4 игроками так выпадал самый медленный. Теперь: (1) AM — состояния всех игроков одним сообщением
    (pid + 7 полей на игрока; клиент понимает и старое AS); (2) рассылки хоста идут только тем, кто уже сам что-то
    прислал (S.firstSeen), личные сообщения (точка появления, состояние уровня) — сразу. 3 захода по 4 игрока — 0
    переподключений. Заодно список F4 пропускает неактивные PlayerState (bIsInactive) ушедших игроков.
111. **Лишние тела после загрузки чекпоинта (после v1.0.0)** — 4 игрока, KillCultists, T2C.loadLastSave: у всех «видно 7».
    У хоста 3 PlayerBP без контроллера там, где стояли гости при прошлом сохранении (Z 3992/991): сохранение игры
    пишет тела партнёров, загрузка их воссоздаёт. Хост теперь раз в секунду удаляет чужие тела игроков без
    контроллера дольше 8 с (не во время загрузки и катсцены; Role 3, не своя пешка), лог «removing a player body
    nobody controls». Проверка урона напарников на 4 игроках: клики key.ps1 без -Focus не доходят до окна без
    фокуса (патроны не убывают) — инструмент; с -Focus урон проходит (C −32 hp, D убил двоих).
112. **Падения гостей на переходах с 4 игроками (после v1.0.0)** — финальный прогон на 4: 3 падения гостей (после «все
    лежат» → рестарт арены; рестарт KillHorizon при переподключении; переход в ServerRoom). Стек B: только поток экрана
    загрузки (0x2a0380d → 0x2a04391 → 0x2a00881 → рекурсия 0x168af13) — тот же поток MoviePlayer, что в п. 107. Стек C
    (dumpstack теперь проходит прыжок в данные: берёт адрес возврата со стека): BP → execSetUserFocus → Slate →
    вызов через освобождённый виджет. Гость жал «клавишу» на ЭКРАНЕ ЗАГРУЗКИ СЛЕДУЮЩЕГО перехода, пока тот только
    поднимался (подключение к хосту / переподключение), — правило «4 с после загрузки» этого не ловило. Теперь
    S.lsKnown: первым же заданием после LoadMapPost запоминаем имя виджета загрузки этого уровня (или ""), нажимаем
    только его; новый виджет (начался следующий переход) не трогаем. Инструменты: t2.ps1 пишет cmd.tmp и
    переименовывает (мод читал полузаписанную длинную команду → «')' expected near <eof>»); launch.ps1 сохраняет
    прошлый лог как UE4SS.prev.log; tools/wipeloop.ps1 (все лежат → рестарт, N кругов).

## Сетевые сообщения T2Coop (строка `T2C|<тип>|поля...`)
- Клиент → хост через `PlayerController:ServerChangeName` (надёжный RPC движка; имя игрока меняется — не страшно).
- Хост → клиент через `PlayerController:ClientMessage`.
- `S|x|y|z|yaw` хост→клиент: где появиться. `P|x|y|z|yaw|pitch|vx|vy|vz` клиент→хост: поза.
- `D|x|y|z|урон|хедшот` клиент→хост: попадание по врагу (ищем ближайшего NPC к точке, `ApplyDamage`).
- `K|x|y|z` хост→клиенты: враг умер (клиент добивает свою копию).
- `U|волна~текст~враги~деньги~таймер` хост→клиенты: HUD «Орды» (клиент держит свою копию SideMissionStatusUI).
- `F|n` клиент→хост: клиент выстрелил n раз (хост играет анимацию выстрела марионетки).
- `H|урон` хост→клиент: по твоей марионетке попали.
- `WP|путь_класса` клиент→хост: оружие в руках (раз в 5 c повтор); хост спавнит его марионетке и ForceEquipWeapon.
- `WT|x|y|z|класс` клиент→хост: я подобрал оружие тут. `NT|текст` хост→клиент: уведомление.
- `NM|ник` клиент→хост (раз в 3 c): имя игрока; хост объявляет «X joined / X left».
- `AS|...` клиент→хост и `AS|pid|...` хост→клиенты: состояние анимации игрока. `HF|pid|n` хост→клиенты: чужой выстрел.
- `TR|имя|n` хост→клиенты: сработал сюжетный триггер. `MI|класс` хост→клиент: текущая миссия.
- `IA|объект|комп` клиент→хост, `IX|объект|комп` / `IE|объект|комп|1/0` / `OB|имя|1/0|xyz|t1|t2|подпись` хост→клиенты.
- `HG|xyz` / `HR|бросок` клиент→хост (заложник), `HH|xyz|xyz` / `HE|xyz` хост→клиенты. `FI|xyz` клиент→хост, `FV|xyz` хост→клиенты (огонь).
- `DN|1/0` клиент→хост: ранен/поднят. `RV` хост→клиент: тебя подняли. `RJ` хост→клиенты: арена перезапускается.

## Статус 2026-11-10 07:00 — v0.4.0
✅ Пули/дробь/хедшоты напарника засчитываются у хоста (луч у хоста). ❌ Гранаты/пинок/меч напарника.

## Статус 2026-11-10 06:30 — v0.3.0
✅ Подбор оружия напарником, деньги за его убийства, метки, уведомления, 3 игрока.

## Статус 2026-11-10 06:06 — v0.2.2 (GitHub: ImmortalSouull/trepang2-coop)
✅ Оружие напарника видно хосту. На клиенте ForceEquipWeapon/SwapWeapon из Lua оружие не меняют (нужен настоящий подбор) — тестировать смену оружия только вживую.

## Статус 2026-11-10 05:46 — v0.2.1
✅ Урон врагов по напарнику (через марионетку), счётчик врагов у напарника, всё из 0.2.0.

## Статус 2026-11-10 01:51 (история) — v0.2.0, пакет `dist/Trepang2-Coop-v0.2.0.zip`
✅ F5/F6/F7/F8, config.txt, уведомления, установщик (проверен на настоящей установке), README.
✅ Пауза хоста не морозит напарника. Перезапуск уровня игрой → автохостинг + автопереподключение.
⏳ Не проверено вживую: игра через интернет, атакуют ли враги клиента наравне с хостом.

## Статус 2026-11-10 01:14 (история)
✅ Всё из статуса 00:47, плюс: пистолет в руках у клиента, нормальные цвета, HUD патронов и «Орды»
   у клиента, смерти врагов синхронизируются, ранение/подъём, перезапуск при провале с автопереподключением.
❌ Не сделано: смена оружия клиента не видна хосту (марионетка всегда с пистолетом), меню/горячие клавиши,
   игра через интернет без проброса порта (Steam), сюжетные миссии.

## Статус 2026-11-10 00:47 (история)
✅ Хост на «Орде» с listen-сервером, клиент подключается, играет своей локальной пешкой.
✅ Ходьба/прыжки клиента, хост видит клиента (марионетка с пистолетом), позиции совпадают.
✅ Клиент стреляет своим оружием; попадание → хост наносит урон настоящему врагу (проверено вызовом
   `OnSpawnedProjectileDamagedOther`; программное прицеливание в тестах пока кривое — это инструмент, не мод).
✅ Враги видны у клиента (движок реплицирует NPC).
❌ HUD клиента: патроны показывают старую пешку, нет счётчика волн. Картинка клиента чёрно-белая.
❌ Урон врагов по клиенту, видимые выстрелы клиента у хоста, смерть/перезапуск уровня — не сделаны.
