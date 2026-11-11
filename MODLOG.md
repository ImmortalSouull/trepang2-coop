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
