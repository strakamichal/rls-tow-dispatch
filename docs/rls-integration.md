# RLS 2.8.0 integration reference (Tow & Repo Hub)

Reference for the implementation steps in `docs/spec.md`. Everything here was read from the
RLS 2.8.0 source checked out at `.cache/rls` (`gameplay/overhaul/version.json`:
`version_string "2.8.0"`, `source_sha cc89a2ae…`).

Conventions:

- Paths without a prefix are relative to `.cache/rls/lua/ge/extensions/overhaul/` (written `OV/`
  where ambiguous). `gameplay/…`, `ui/…`, `lua/vehicle/…` and `levels/…` are relative to `.cache/rls`.
- `file:NN` is a line number in 2.8.0. Line numbers will drift in later RLS versions.
- Engine globals (`core_*`, `gameplay_*`, `be`, `map`, `guihooks`, `extensions`, `util_*`,
  `core_vehicleBridge`) are not in the tree. This document shows only how RLS calls them.
- **UNCONFIRMED** means the source does not prove it and it must be checked in game.
- Every RLS module listed here is internal. None of them is a documented or stable API. Guard each
  call (`if overhaul_x and overhaul_x.fn then`), the way RLS guards its own cross-module calls.

---

## 1. Phone apps from another mod

### 1.1 App manifest: `gameplay/overhaul/phone/apps/<id>.json`

Real example, `gameplay/overhaul/phone/apps/offroad-recovery.json`:

```json
{ "id": "offroad-recovery", "name": "Off-Road Recovery", "icon": "tow", "iconTile": "offroad-recovery.png",
  "route": "/overhaul/phone-offroad-recovery", "color": "#805329", "iconColor": "#ffffff", "category": "Jobs",
  "storeTagline": "Remote vehicle recovery", "storeDescription": "Extract stranded vehicles ...",
  "defaultPage": 0, "defaultPosition": 5,
  "uiRoutes": [{ "name": "phone-offroad-recovery", "path": "phone-offroad-recovery",
    "component": "/ui/ui-vue/mods/rls_career_overhaul/overhaul/modules/career/views/phone/PhoneOffroadRecovery.vue",
    "uiOrder": 71, "luaOrder": 53, "backTarget": "phone-main" }] }
```

`repo.json` has the same shape: route `/overhaul/phone-repo`, component `PhoneRepo.vue`,
`uiOrder` 72, `luaOrder` 59.

Fields used across the 33 shipped manifests:

| Group | Fields |
|---|---|
| Core | `id`, `name`, `route`, `color`, `iconColor`, `category`, `defaultPage`, `defaultPosition`, `uiRoutes` |
| Icon | `icon` (stock icon name, or a list where the first existing one wins), `iconTile`, `iconImage`, `iconImageFit`, `iconVariant` |
| Store | `storeTagline`, `storeDescription`, `description`, `hideFromStore`, `showInStoreWhenLocked`, `lockedMessage` |
| Gating | `unlock` (`{type: careerActive \| optionalFeature \| businessSkillNode \| lua, …}`), `careerOnly` |
| Layout | `systemApp`, `defaultDock` (0–3), `defaultHome` (`{slot 0–15, required}`), `opensFromBalance` |
| Other | `notifications` (`[{key,label,default,description,order,pending}]`), `notificationSources`, `onInstall` (`{extension, call, loadOnlyInCareer}`) |
| `uiRoutes[]` | `name`, `path`, `component`, `uiOrder`, `luaOrder`, `backTarget`, `title`, `props`, `parent`; the validator also accepts `order`, `meta`, `luaMeta` |
| Top level, rare | `namespace`, `component` |

Lua validation is in `lib/phone/appDiscovery.lua`:

- `M.dir = "/gameplay/overhaul/phone/apps/"`. `M.scan()` (79–101) calls
  `FS:findFiles(dir, "*.json", 0, false, false)`, so only one directory level is scanned.
- Required fields (`requiredFieldsProblem`, 43–53):
  - `id` matches `^[%w][%w%._%-]*$` and **equals the file name**;
  - `name` is a non-empty string;
  - a valid `route` (starts with `/`) **or** a top-level `component` (`/…​.vue`);
  - at least one of `icon`, `iconTile` or `iconImage`.
- `uiRoutes` is checked with `lib/ui/routeValidation.lua` (see 1.2).
- Optional-field problems only log a warning (56–63). An unknown `unlock.type` keeps the app locked.
- When two files share an `id`, the first file in alphabetical order wins. The scan returns
  `apps, rejected[{file, reason}]`.

`lib/phone/appCatalog.lua`:

- `M.scan()` (52) wraps appDiscovery.
- `M.scanScripts()` (67–76) lists `/ui/ui-vue/mods/*/phoneApps/*.js`, skipping `index.js`.
- `M.listForUi()` (86–105) is the single entry point for the UI and never throws. It returns
  `{apps, scripts, rejected, routes, uiOwners, routeRejected, routeError}`.
- `M.derive(apps)` (166–192) builds notification channels, dock slots and home slots.

**Discovery across mods.** There is no mod-id filter. RLS scans the BeamNG virtual file system, so
a manifest shipped in our own zip as `gameplay/overhaul/phone/apps/towRepoHub.json` is picked up.
The JS comments say so too (`phoneAppCatalog.js:1-3`, `phoneAppRegistry.js:11`: "any mod can add
one"). Gotcha: a file at the same path in another mod overrides the RLS file, so prefix our file names.

UI gating (`ui/ui-vue/mods/rls_career_overhaul/overhaul/modules/career/utils/phoneAppCatalog.js`,
`UNLOCK_GATES` 117–178):

- `careerActive` asks `overhaul_phone_apps_layout.getCareerActive()` and falls back to
  `overhaul_career_career.isActive()`.
- `lua` is `{extension, function, args?, load?}`: RLS calls `luaBridge[ext][fn](...args)` and treats
  a truthy result as unlocked. This is the generic gate a third-party app can use.
- There is no level gate. RLS apps report lock state in their own payload (recovery sends
  `locked` and `lockedReason`).

Manifest gotchas:

- A bare `iconTile` or `iconImage` file name resolves to
  `/ui/entrypoints/main/rls_career_overhaul/tiles/<name>` (`phoneAppRegistry.js:52-66`).
  **Use an absolute path** for our own icon.
- `normalizeManifest` (`phoneAppCatalog.js:194-207`) does not pass `unlock`, `onInstall`,
  `defaultHome` or `uiRoutes` into the UI app definition.

### 1.2 Routes and `.vue` components

Route row validation is `lib/ui/routeValidation.lua:14-54`:

- `name` matches `^[%w][%w%._%-]*$`.
- `path` has no `..`, `\` or control characters. An absolute path must start with `/overhaul/`;
  a relative one is prefixed with `/overhaul/`.
- `component` matches `^/ui/ui%-vue/mods/[^/]+/.+%.vue$` (`lib/platform/catalog.lua:18-21`).
  The component must therefore live under `/ui/ui-vue/mods/<ourMod>/…`.
- `parent` must be a known route host. `backTarget` is a route name.
- `order`, `uiOrder` and `luaOrder` are numbers. `props` is a boolean or an object.
- If the manifest sets `namespace`, the `id` must start with `<ns>-` and every route name must start
  with `<ns>-` or `overhaul.<ns>.`.
- A duplicate route name or path is rejected.

`lib/ui/routeDiscovery.lua:123-134` merges the phone manifests with `/gameplay/overhaul/ui/routes/*.json`.
It rejects reserved names taken from the stock career tree, `gameplay/overhaul/ui/coreRouteOwners.json`
and `ui/owners` (`lib/ui/ownerCatalog.lua:12-31`). On conflict the first entry by order, then id,
then file wins. The default `uiOrder` is 10000.

Loading chain:

1. Lua: `ui/routes.lua` (`overhaul_ui_routes`) registers routes with `ui_router_routeManager`
   (`luaOrder`, default 10000, line 249). Phone routes get the `phone-shell` scope tree (172–185).
2. JS: `ui/ui-vue/mods/rls_career_overhaul/index.js` (the stock BeamNG per-mod UI entry point) calls
   `loadPhoneApps()` (`phoneAppCatalog.js:365-403`). That function runs
   `bngApi.engineLua("require('overhaul/lib/phone/appCatalog').listForUi()", cb)` with a 20 s timeout
   and retries with backoff. It then calls `setPhoneRouteManifests` (`utils/uiRouteCatalog.js:23-48`),
   which defaults the parent of phone routes to `phone-shell`. Next, `loadScriptManifests(reply.scripts)`
   loads the `phoneApps/*.js` files. Finally `setPhoneAppManifests` runs. The Lua event
   `OverhaulUiOwnersChanged` triggers a rescan (line 62).
3. `overhaul/registerRoutes.js:12-58` adds the routes with `window.bngRoutes.add(...)`. Each component
   is wrapped in `runtimeRouteComponent(file, {phone})` (`utils/runtimeComponent.js`), which uses
   `loadModule(file)` from `@/services/uiMods` and needs `module.default`. Its timeout is 20 s.
   RLS uses no `import.meta.glob`: `.vue` files are compiled at runtime from the VFS path.
   `<style scoped lang="scss">` works.

Legacy JS manifest `ui/ui-vue/mods/<mod>/phoneApps/<id>.js` (`phoneAppCatalog.js:254-291`):

- Shape: `export default { id, name, icon, route, unlockCondition: async luaBridge => bool, component? }`.
- It overrides a JSON manifest with the same id.
- It **does not register routes**. The app must then use the generic host route.

Generic host: `views/phone/PhoneAppHost.vue`, route `phone-app`, path `/overhaul/phone-app/:appId`
(`gameplay/overhaul/ui/coreUi.json:813`). It renders `<component :is :app="app" :call-lua="callModLua" />`
and handles the states `missing`, `locked` and `error`. Preparation times out after 2.5 s. A manifest
with a top-level `component` and no `route` gets `/overhaul/phone-app/<id>`.

**Minimum for our add-on:**

- `gameplay/overhaul/phone/apps/towRepoHub.json` whose `id` equals the file name;
- a `.vue` file with a default export under `/ui/ui-vue/mods/towRepoHub/…`;
- either `uiRoutes` with a unique prefixed `name`/`path` and `backTarget: "phone-main"`, or a top-level
  `component` that uses the generic host;
- an icon given as an absolute path.

Whether BeamNG 0.40 compiles a `.vue` file from a third-party mod is **UNCONFIRMED** (spec risk; check it in step 1).

### 1.3 Lua <-> Vue

Vue calls Lua in three ways:

| Pattern | Example | Notes |
|---|---|---|
| `import { lua, useBridge } from '@/bridge'`; `lua.overhaul_jobs_repo.requestRepoState()` | `PhoneRepo.vue:164-265` | RLS wraps `lua` in a Proxy (`utils/installLuaBridgeFallbacks.js:284-366`). An unknown namespace resolves only if it is in the generated `MOD_NAMESPACES` list or declared by a `gameplay/overhaul/ui/owners/*.json` with `exports.namespace: true`. For `towRepoHub_*` this is **UNCONFIRMED**. |
| `callModLua('ext.fn', ...args)` returns a Promise with the return value | `PhoneOffroadRecovery.vue:204-215` | Defined at `installLuaBridgeFallbacks.js:236-262`. Safe when the extension is missing (`rawget(_G, root)` returns nil). The generic host passes it in as the `callLua` prop. **Recommended for us.** |
| `window.bngApi.engineLua("<lua expr>", cb)` | `PhoneFacilityWork.vue:181` | The callback receives the value of the expression. |

Lua pushes data to Vue:

- stock `guihooks.trigger(eventName, payload)`;
- `require("overhaul/lib/ui/statePush")` (`lib/ui/statePush.lua`). The state is shared through the
  require cache:
  - `send(eventName, payload)` (35) stores a deep snapshot and always triggers;
  - `refresh(eventName, payload) -> bool` (40) triggers only if the payload differs from the last send.
  - Send every push of a given event through `statePush`, or the comparison goes stale.
  - RLS usage: `recovery.lua:941` calls
    `statePush.send("updateOffroadRecoveryState", M.getState())`, and `onUpdate` calls `refresh` once a
    second (1360–1366). Repo sends `"updateRepoState"` (`repo.lua:1235`).

Vue subscribes with `const { events } = useBridge(); events.on('updateRepoState', fn)` and must call
`events.off(…)` on unmount.

UI scopes (`utils/luaScopes.js`):

- `acquireScope(lua, id)` / `releaseScope(lua, id)` take an id from `gameplay/overhaul/ui/owners/*.json`,
  for example `{"id":"phone.offroadRecovery","stateOwner":"overhaul_jobs_recovery","extensions":["overhaul_jobs_recovery"],"namespace":false,…}`.
- `acquireScope` calls `extensions.load` and then `stateOwner.onUiScopeChanged(id, true)`.
- On the Lua side, `lib/ui/scopeSubscriptions.lua` provides `set(scopes, id, active)` and
  `listening(scopes)`. Recovery pushes state only while the UI is listening (`recovery.lua:933-942`).
- Whether the UI accepts a third-party owner JSON at runtime is **UNCONFIRMED**.

### 1.4 Structure of RLS phone apps

Both files are in `ui/ui-vue/mods/rls_career_overhaul/overhaul/modules/career/views/phone/`.

`PhoneOffroadRecovery.vue` (369 lines, `<script setup>` 130–248):

- No props.
- Imports:
  - `vBngUiNavScroll`, `vBngScopedNav`, `vBngOnUiNav` from `@/common/directives`, and `vBcModalFocus`;
  - `usePhoneAppLayers`, `usePhoneAppFocus` from `./controllerLayers.js`;
  - `MoneyAmount.vue`;
  - `lua`, `useBridge`, `callModLua`, `acquireScope`/`releaseScope`, and `reportUiFailure` (`utils/safeLua`).
- `applyState(payload)` (167–180) maps the pushed state:
  `{locked, lockedReason, skillLevel, payoutBonusPercent, offers[], activeJobs[], otherMapJobs[], activeCount, maxActive, pendingOfferId, yardChoices[], lastCompletion}`.
- Actions are `callModLua('overhaul_jobs_recovery.<fn>', id)` with `beginAcceptOffer`,
  `selectRecoveryYard`, `previewOffer`, `trackJob`, `clearCompletion` and `abandonJob`.
- Lifecycle (220–247):
  - `onMounted` and `onActivated` call `events.on`, then `await acquireScope(lua, 'phone.offroadRecovery')`,
    then `await callModLua('overhaul_jobs_recovery.requestState')`, guarded by an activation token;
  - `onDeactivated` and `onUnmounted` call `events.off` and `releaseScope`.
- Style: `scoped lang="scss"`, Overpass font, hard-coded colours, `padding-top: 48px` under the status
  bar. The shell exposes `--phone-status-bar-height` (`PhoneShell.vue:509`).

`PhoneRepo.vue` (525 lines):

- No props.
- Imports `useMinimapStore`, `BngIcon`, `icons` and `PhoneAppNotice.vue`.
- `onMounted` (256) calls `events.on("updateRepoState")`, `store.acquire()`, `store.mountMap(el)` and
  `lua.overhaul_jobs_repo.requestRepoState()`.
- Actions: `generateJob()`, `cancelJob()`, `completeJob()`.
- The payload is incremental:
  `{state, vehicle:{Brand,Name,year,Mileage}, deliveryLocation, distanceToDestination, totalDistance, reward, isRepoVehicle, disabledReason, repoTag, repoTierLabel, repoSkillLevel, repoPayoutBonusPercent}`.

### 1.5 Detecting the RLS version

RLS has no version getter. It reads the file ad hoc:
`jsonReadFile('/gameplay/overhaul/version.json').version_string` (`world/levelProxy.lua:133-139`,
`career/market/valueCalculator.lua:518`, `testing/hooks.lua:377`).

```lua
local v = jsonReadFile('/gameplay/overhaul/version.json')
local ok = v and type(v.version_string) == "string" and v.version_string:match("^2%.8%.") ~= nil
```

- To check that RLS is present: `require("overhaul/lib/platform/modIdentity").identifyOwnMod()` resolves
  the mod through `core_modmanager.getModFromPath(".../shell/extensionManager.lua")`, with fallbacks to
  the name `rls_career_overhaul` and the tag id `RLSCO24`. The result is also exposed as
  `overhaul_shell_extensionManager.getModData()`.
- RLS itself requires game version 0.40 (`shell/extensionManager.lua:326-338`).

---

## 2. Extension lifecycle

### 2.1 How RLS loads itself

- `scripts/rls_career_overhaul/modScript.lua` (15 lines) defers loading through
  `core_jobsystem.create(... job.sleep(0.25) ...)`. It then calls
  `setExtensionUnloadMode("overhaul_shell_extensionManager", "manual")` and `extensions.load(...)`.
  The reason (comment on lines 9–10): `core_modmanager` temporarily wraps `extensions.load` while
  modScripts run.
- `shell/extensionManager.lua`, `M.onExtensionLoaded = startup` (669–702), loads its scopes in this
  order: careerCore, bootManual, routes, shell, services, vehicleTools, then `reloadUI()`, then guards,
  settings, late.
- `onWorldReadyState(2)` loads the `world`, `freeroamEvents` and `careerWorld` scopes (866–876).
- `onModActivated` / `onModDeactivated` rebuild the roster (774–799), so a mod activated later is picked up.

The roster is data-driven over the VFS (`lib/career/manifest.lua`,
`ownersDir = "/gameplay/overhaul/career/owners/"`):

```json
{ "id": "overhaul_jobs_recovery", "order": 79, "module": "overhaul/jobs/recovery",
  "scopes": [{ "id": "bootManual", "order": 4 }] }
```

- `validateOwner` (242–302) requires `id == extensionName(module)`, an existing
  `/lua/ge/extensions/<module>.lua` file and a numeric `order`.
- Scope ids: careerCore, bootManual, routes, shell, services, vehicleTools, guards, settings, late,
  world, freeroamEvents, careerWorld, owned, children, and a few more (18–35).
- Optional keys: `unload`, `demandLoad`, `saveFiles`, `capability`, `beforeUnload`, `beforeCareerStop`,
  `reloadOnReady`, `inputActions`, `integration`.

Career modules are declared in `/gameplay/overhaul/career/modules/<id>.json` as `{id, order, module}`.
`career/start/transitions.lua:276-311` loads them at career start and calls `mod.onCareerActivated()`
on them directly. It then broadcasts `extensions.hook("onOverhaulModulesActivated", alreadyInLevel)`.
The modules are unloaded when the career stops.

**Options for `lua/ge/extensions/towRepoHub/*.lua`:**

- (a) Ship `gameplay/overhaul/career/owners/towRepoHub_core.json` with scope `bootManual`, as RLS
  does for its own jobs. This is the most RLS-native option, but it is **UNCONFIRMED** that a
  third-party owner loads cleanly.
- (b) Ship `gameplay/overhaul/career/modules/towRepoHub_core.json`. The module is then loaded only
  while a career is active and gets `onCareerActivated`.
- (c) Ship our own `scripts/towRepoHub/modScript.lua` with a deferred `extensions.load("towRepoHub_core")`.
  This copies the RLS pattern and works without RLS registration (**UNCONFIRMED**).

Never call `extensions.load` synchronously inside a modScript.

Extension naming: `lib/career/manifest.lua:61`, `extensionName(path) = path:gsub("_","__"):gsub("/","_")`.
So `towRepoHub/core.lua` becomes `towRepoHub_core`. Avoid underscores in folder names
(`tow_repo/x` would become `tow__repo_x`).

### 2.2 Hooks a third-party extension sees

| Hook | Fired at | Meaning |
|---|---|---|
| `onOverhaulActive(active, newSave)` | `career/career.lua:169` (true), `career/start/transitions.lua:711` (false) | Career on/off. Reset state on `false`. |
| `onOverhaulModulesActivated(alreadyInLevel)` | `transitions.lua:307` | The career modules are up. Recovery loads its save here. |
| `onOverhaulBeforeCareerActivate()`, `onOverhaulActivationReady(health)` | `transitions.lua:615`, `:575` | |
| `onOverhaulBeforeSetProfile()` | `career/saveSystem.lua:671` | The profile is about to change. Drop the loaded state. |
| `onOverhaulCareerSimStep(dtSim)` | `career.lua:420` | |
| stock `onWorldReadyState(state)` | engine | Recovery respawns its targets when `state == 2` and the career is active. |
| stock `onClientEndMission`, `onClientPreStartMission` | engine | Level unload/load. Map-scoped caches are cleared here. |
| stock `onUpdate(dtReal, dtSim)`, `onVehicleDestroyed(vehId)`, `onVehicleSwitched` | engine | |

- **RLS never fires `onCareerActive`** (grep finds no hit). Use `onOverhaulActive` and
  `onOverhaulModulesActivated`.
- `overhaul_career_career.isActive()` is at `career/career.lua:433-435` and returns `session.active`.
  RLS always guards it: `overhaul_career_career and overhaul_career_career.isActive()`.

The recovery lifecycle (`jobs/recovery.lua:1373-1512`) is the template to copy:

```lua
M.dependencies = {"util_configListGenerator"}                -- repo.lua:10 adds "gameplay_parking"
local function onExtensionLoaded() if overhaul_career_career and overhaul_career_career.isActive() then loadState(); worldReady() end; initialized = true end
local function onWorldReadyState(s) if s == 2 and overhaul_career_career and overhaul_career_career.isActive() then worldReady() end end  -- :1373
local function onOverhaulModulesActivated() loadState(); worldReady() end                        -- :1389
local function onOverhaulActive(active) if not active then resetSession() end end
local function onClientEndMission() captureExitState(); pauseJobs() end                          -- :1415
local function onUpdate(dtReal, dtSim) if not initialized or not (overhaul_career_career and overhaul_career_career.isActive()) then return end ... end -- :1317
```

To open a phone route from Lua: `overhaul_phone_phone.openRoute(routeName, params) -> {success, reason}`
(`phone/phone.lua:214-229`).

---

## 3. Money, XP and economy

### 3.1 Payout

`overhaul_career_economy_payment.payout(spec) -> true | false, diagnostic` is defined at
`career/economy/payment.lua:162-225`; the contract comment is at 126–157.

| `spec` field | Meaning |
|---|---|
| `amount` | Finite number. Negative only with `allowNetDebit = true`. Omit it for an XP-only payout. |
| `xp` | `{[attrKey] = n}`. The key cannot be `"money"`. |
| `orgId`, `rep` | Adds the attribute `orgId .. "Reputation"`. |
| `label`, `tags`, `category`, `source`, `description`, `breakdown` | Copied into `reason`. `tags` must be a table. |
| `reason` | Base reason table, overridden by the fields above. |
| `fullReward` | Passed through to `addAttributes(change, reason, fullprice)`. |
| `destination` | Default `"wallet"`. Also `{kind="account", accountId}` or `{kind="heldWages", holder}`. |

- There is no rollback and no deduplication. A `false` result is not a retry signal: RLS logs it and
  completes the job anyway.
- The money goes through `overhaul_career_economy_playerAttributes.addAttributes(change, reason, fullReward)`
  (`career/economy/playerAttributes.lua:345-473`). That function returns nothing and fires
  `onOverhaulPlayerAttributesChanged(change, reason)` and the guihook `OverhaulFinancialHistoryChanged`.
  On a level-up it also fires the logbook event `overhaul.levelUp` and `OpenCareerLevelUpCelebration`.
- Repo and recovery never call `addAttributes` directly. Use `payout`.
- For positive money, `addAttributes` applies `overhaul_career_economy_activityHeat.getDemandFactorForTags(reason.tags)`
  (406–430), mapped by `earningTags` in `gameplay/overhaul/economy/activities/*.json`. `repo.json` has
  `earningTags: ["repo"]`; `offroadRecovery.json` has none. **A `"repo"` tag on our payout therefore
  draws on and is scaled by the repo demand/surge.**
- The tag `"gameplay"` together with money unlocks the `FIRST_ASSIGNMENT` achievement (464).

### 3.2 Finance metadata and Wallet categories

`require("overhaul/lib/finance/metadata")` (`lib/finance/metadata.lua`):

- `tag(reason, category, fields)` (28–41) normalises the category through `lib/ledger/categories.lua`.
  Valid values are the base set `purchase, sale, repair, fuel, fine, insurance, gambling, transfer, loan,
  property, service, business, interest, refund, reward, cheat` or `"activity:<id>"`. It fills
  `reason.finance.*` from `fields`, but only where a field is missing.
- `tagPayout(spec, category, fields)` (43–56) copies `spec` and tags its `reason`.
- When a ledger row is read (`base()`, 134–162), `activity:X` becomes `category = "work_income"`,
  `source = "X"`. Rows without a category fall back to `gameplay/overhaul/finance/legacyWorkTags.json`
  (`"repo":"repo"`, `"offroadRecovery":"recovery"`).
- Wallet names are at 80–88 (`work_income = "Work income"`, `reward = "Rewards"`). New categories can be
  added with `registerCategory(key, {name, accent})` (59–64).
- UI: `walletFinance.js:176` counts a row as work when `amount > 0 && isWork !== false && known(source)`.

The calls RLS makes:

```lua
-- repo.lua:600-607
overhaul_career_economy_payment.payout(require("overhaul/lib/finance/metadata").tagPayout({
  amount = rewardData.money and rewardData.money.amount,
  xp = scaledSkillXp and { [REPO_SKILL_ATTRIBUTE_KEY] = scaledSkillXp.amount } or nil,
  label = rewardText, tags = { "gameplay", "reward", "repo", "recovery" },
  fullReward = true, allowNetDebit = true,
}, "activity:repo", {vehicleRole = "player"}))
-- recovery.lua:747-755: tags {"gameplay","reward","offroadRecovery"}, category "activity:recovery",
-- fields {vehicleObjectId = payoutVehicleId}, fullReward = true, no allowNetDebit.
```

For the hub: category `"activity:repo"` or `"activity:recovery"` lists the payout as Work income /
repo or recovery. Add a hub tag such as `"towRepoHub"` to `tags`. A custom `activity:towRepoHub` source
would probably not count as work until it is known to `walletFinance.js` (**UNCONFIRMED**).

For fines, use a negative `amount` with `allowNetDebit = true` and category `"fine"`. RLS repo and
recovery never fine, so this exact combination is **UNCONFIRMED**.

### 3.3 Skill XP and levels

- Repo and recovery **share one skill**: attribute key `"careerSkills-recovery"`, path ids
  `{"careerSkills-recovery", "recovery"}`, maximum level 50 (`repo.lua:31-33`, `recovery.lua:21-22`,
  `gameplay/overhaul/economy/sections/jobs.json:10-11`).
- Level thresholds are in `gameplay/overhaul/domains/careerSkills/skills/recovery/info.json`
  (`levels[i].requiredValue`: L1 0, L2 200, L3 500, L4 900, L5 1400, L6 1900, L7 2600, L8 3400, …).
  The same file holds the `unlockFlags` and the UI headings ("Low Value Repo", "Budget Repo", …).
- `require("overhaul/lib/progression/skillLookup")` (`lib/progression/skillLookup.lua`):
  - `levelFirstPathOrValue(attrKey, pathIds)` (113–125), used by repo;
  - `levelMaxPathOrValue(attrKey, pathIds)` (131–138), used by recovery;
  - `levelFromValue(value, ref)` (28–35) returns `level, progress, neededForNext, prevThreshold, nextThreshold`;
  - `attributeValue(key)` (38).
- Backend `overhaul_career_progression_skills`: `calcBranchLevelFromValue(value, id)` (308),
  `getBranchLevel(id)` (345), `getXPNeededForLevel(id, level)` (376–382).
- Tier unlock: `overhaul_career_progression_unlockFlags.getFlag(flag) == true` or
  level >= `skillUnlockLevel` (`jobs/repo/vehiclePool.lua:123-133`).

### 3.4 Economy multipliers and difficulty

- `overhaul_career_economyAdjuster.getSectionMultiplier(name)` (`career/economyAdjuster.lua:427-450`)
  returns `typeMultipliers[name]` (default 1.0, clamped 0–10) times a transient surge or cool-down factor
  (clamped 0.5–5.0). It returns **0 when the section is disabled**: repo then turns itself off
  (`repo.lua:316-321`). Challenge mode can also disable repo through
  `activeChallenge.economyAdjuster.repo == 0` (323–330).
- Sections (the `keys` in `gameplay/overhaul/economy/activities/*.json`): `ambulance, beamEats, burnout,
  burnoutComp, bus, criminal, delivery_*, demo, facilityWork, freeroam, offroadRecovery, police, repo,
  taxi`, plus race and taxi types. Calls: `"repo"` at `repo.lua:317`/`516`, `"offroadRecovery"` at
  `recovery.lua:246`.
- Difficulty (`career/economy/difficultyMode.lua:14-19`): easy reward ×3 / XP ×2, normal 1/1,
  hard 0.5/0.5, hardcore 0.5/0.25.
  - The money factor is **already baked into `getSectionMultiplier`**
    (`economyAdjusterPolicy.rebuild()` 281–308).
  - XP is scaled separately with
    `overhaul_career_economy_difficultyMode.scalePaymentRewardData(rewardData, {includeMoney = false})`
    (259–277). It mutates `{key = {amount = n}}` in place and scales only progression keys.
  - Both RLS jobs pass `includeMoney = false`. Do not scale money twice.
- `overhaul_career_economy_globalEconomy.getJobMarketIndex()` (`globalEconomy.lua:601`) is used only for
  races. Repo and recovery ignore it.

### 3.5 Logbook

`lib/progression/logbookFeed.lua:3-16`:

```lua
local recordJob = require("overhaul/lib/progression/logbookFeed").register("overhaul.repoCompleted",
  { title = "Repossession completed", label = "Jobs", icon = "carCoins" }, "jobs/repo.lua")   -- repo.lua:3-5
recordJob({ name = vehicleName, money = paidMoney })                                           -- repo.lua:610
recordJob({ detail = brand .. " " .. name .. " / Vehicle awarded", money = finalCash })        -- recovery.lua:758
```

- The `id` needs a dotted namespace (`logbookRegistry.lua:14`); use `"towRepoHub.jobCompleted"`.
- If another owner already registered the id, `register` logs a warning and returns nil.
- `record(data)` fires `onOverhaulLogbookEvent(id, data)` inside a `pcall`. The renderer accepts
  `{detail|name, money, receipt, facts, related}`.
- RLS records only when `payout` returned true.

### 3.6 Exact RLS formulas (for the pricing tests in step 2)

Repo pay (`repo.lua:499-521`):

```
dist = core_groundMarkers.getPathLength() at generation (m) ; elapsed = max(1, os.time() - jobStartTime)
foundation = floor(((5*sqrt(vehicleValue or 1000)) + dist*2) * (dist/(elapsed*10)) / 4) / 15
payoutBase = floor((foundation + 500) * tier.payMultiplier * (1 + bonus) + 0.5)
reward     = floor(payoutBase * getSectionMultiplier("repo") + 0.5)
bonus (vehiclePool.lua:118-122) = 4 * min(24, floor(clamp(level,0,50)/2)) / 24
```

- Repo XP (`repo.lua:575-581`): `max(1, floor((5 + tier.baseXp + floor(dist/2000 + 0.5)) * 2 + 0.5))`,
  then difficulty-scaled.
- Recovery quote (`jobs/recovery/rewards.lua:18-43`):
  - `base = 1500 + outboundKm*100 + loadedKm*250 + difficultyFee`;
  - `cash = max(0, floor(base * (1 + bonus) * getSectionMultiplier("offroadRecovery") + 0.5))`;
  - `bonus = 2 * (min(22, max(0, floor((L-5)/2)))/22)^2` (`recovery/vehiclePool.lua:15-21`).
  - Outbound is the route yard → target, loaded is target → yard (`routeDistance`).
  - **Spec gap:** `difficultyFee` (12–16) comes from the spot's `customFields.values.difficultyFee`
    (clamped 0–3000). Only when that is missing does it fall back to the spot's `minLevel`
    (L30+ 3000, L10+ 1500, otherwise 0). The fee depends on the spot, not on the player level.
  - The tier `payMultiplier` is stored but does **not** enter the recovery quote.
- Recovery XP (`rewards.lua:121-123`): `max(1, floor((5 + baseXp + floor(loadedM/2000 + 0.5)) * 4 + 0.5))`.
  Note ×4 (repo uses ×2).
- Damage (`rewards.lua:129-148`): `penalty = min(0.5, valueLost / vehicleValue)`. Recovery multiplies
  both cash and XP by `(1 - penalty)` (`recovery.lua:722-731`). See 6.3.

---

## 4. Repo tiers and vehicles

### 4.1 `gameplay/overhaul/repo/repoVehicleFilters.json`

- Path constant `REPO_FILTERS_FILE` (`repo.lua:34`), passed to the factory
  `require("overhaul/jobs/repo/vehiclePool")(file, attrKey, maxLevel, pathIds)` (`repo.lua:35-40`).
- `loadRepoVehicleFilters()` (`vehiclePool.lua:8-36`) uses `jsonReadFile`, keeps only `type == "vehicle"`,
  normalises the entries and sorts them by `priority` descending. Defaults: `unlockTag` = key,
  `priority` 0, `skillUnlockLevel` 50, `payMultiplier` 1, `baseXp` 0, `tierLabel` (or `filterName`
  or `unlockTag`).

| key | unlock flag | L | payMult | baseXp | prio | whiteList |
|---|---|---|---|---|---|---|
| joesJunkVehFilter | repoJunkerVeh | 1 | 0.75 | 120 | 15 | Value 500–25k, Car, Config Type joesjunkcar |
| junkerVehFilter | repoJunkerVeh | 1 | 1.0 | 300 | 10 | Value 1k–25k, Car, 5 brands, Factory |
| smallVehFilter | repoSmallVeh | 5 | 1.0 | 250 | 20 | 25k–50k, Car |
| fleetVehFilter | repoFleetVeh | 10 | 1.15 | 500 | 30 | 40k–100k, Car |
| highEndVehFilter | repoHighEndVeh | 15 | 1.35 | 900 | 40 | 100k–200k, Car |
| exoticVehFilter | repoExoticVeh | 20 | 1.6 | 1400 | 50 | ≥ 200k, Car |
| heavyVehFilter | repoHeavyVeh | 25 | 1.8 | 1800 | 60 | model_key us_semi/citybus/md_series/midtruck, Type Truck/Bus |

- Every tier has `blackList.model_key = [atv, wl40, frameless_dump]` and `subFilters: []`.
- The value bands exist only in these filters. Fleet overlaps Small (40–50k), which is why the spec's
  "overlap resolves to the higher tier" rule is needed.
- Recovery has its own `gameplay/overhaul/offroadRecovery/offroadRecoveryVehicleFilters.json`
  (`recovery.lua:23`) with similar tiers, no brand limits and an extra `recoveryTrailer` tier.

### 4.2 Filter matching

- `doesVehiclePassRepoFilterConfig(vehicleInfo, filterConfig)` (`repo/vehiclePool.lua:134-148`) is
  **local and not exported**.
  - It passes if the base filter or any `base ⊕ subFilter` passes.
  - `doesVehiclePassFilter` (91–96) requires the whole whiteList to pass and the blackList not to.
  - `doesVehiclePassFiltersList` (57–90): `{min,max}` is checked on the field or on `aggregates[key]`;
    lists check `vehicleInfo[key] == opt` or `aggregates[key][opt]`; `Years` uses range overlap;
    `Mileage` is ignored.
- Exports of the repo factory (235–242): `getEligibleRepoVehiclesForDealership`,
  `getRepoPayoutBonusPercent`, `getRepoSkillLevel`, `getRepoStateFields`, `getRepoTagData`,
  `pickWeightedRepoVehicleInfo`.
- The recovery factory exports `matchesFilterConfig` (`recovery/vehiclePool.lua:54-95`). It needs
  `constants.SKILL_ATTRIBUTE`, `SKILL_PATHS`, `FILTERS_FILE`, `MIN/MAX_TARGET_MILEAGE_MI` and
  `METERS_PER_MILE` (`recovery.lua:21-40`).
- Engine alternative: `util_configListGenerator.doesVehiclePassFilter(info, filter)`
  (`career/logistics/generator/offers.lua:80`).

For the hub, the cleanest option is our own repo factory instance:

```lua
local repoPool = require("overhaul/jobs/repo/vehiclePool")("/gameplay/overhaul/repo/repoVehicleFilters.json",
  "careerSkills-recovery", 50, {"careerSkills-recovery", "recovery"})
```

Use it for repo, and copy the ~40 lines of matching logic for tow value bands.

### 4.3 `util_configListGenerator` (engine)

- `require("util/configListGenerator").getEligibleVehicles(false, false)` with the args
  `(allowAuxiliaryVehicles, allowLoadedTrailers)` (`repo/generation.lua:148`, `recovery.lua:95`).
  Both jobs declare `M.dependencies = {"util_configListGenerator"}`.
- `getRandomVehicleInfos(seller, count, eligible, popKey)` is used in the market
  (`career/market/vehicleShopping/stock.lua:410`).
- `vehicleInfo` fields RLS reads:
  - `model_key`, `key` (config key used for the spawn), `Value`, `Type` (Car/Truck/Bus/Trailer),
    `Brand`, `Name`;
  - `Years{min,max}`, `aggregates{…}`, `Population`, `adjustedPopulation`;
  - `"Config Type"`, `"Body Style"`, `BoundingBox` (`[2]` = size x,y,z), `"Fuel Type"`/`Powertrain`.
- **Weight:** repo and recovery never read it. The tuning shop reads `vehicleInfo.Weight`, or
  `aggregates.Weight.min/max` as a fallback (`career/business/tuningShop/shop/persist.lua:351-353`).
  The unit is presumably kg (**UNCONFIRMED**).

### 4.4 How repo picks the destination and the vehicle

`VehicleRepoJob:selectDealership()` (`jobs/repo/generation.lua:136-165`):

- The pool is `overhaul_world_facilities.getFacilities(getCurrentLevelIdentifier()).dealerships` plus
  every `overhaul_career_logistics_generator.getFacilities()` entry with `repoProvider` truthy.
  No shipped data sets `repoProvider`, so it is probably unused in 2.8.0 (**UNCONFIRMED**).
- The pool is shuffled. Dealerships without candidates are skipped; the first one that has candidates wins.

`getEligibleRepoVehiclesForDealership(dealership, eligibleVehicles)` (`vehiclePool.lua:183-203`):

- Uses `dealership.filter` / `subFilters`. With an `associatedOrganization`, the filter comes from the
  org reputation level.
- The vehicle must pass a dealership variant and the first unlocked tier.
- Candidates get `repoTag`, `repoTierLabel` and `repoSubFilterProbability`.

`pickWeightedRepoVehicleInfo(candidates)` (205–225) weighs by
`(adjustedPopulation or Population or 1) * repoSubFilterProbability` and returns a deepcopy.

Vehicle value (`generation.lua:408-466`):

```lua
usedVehicleCondition.generateUsedVehicleCondition({id="private", salesChannel="local"}, info)  -- sets year, Mileage, wearMileage
vehicleValue = overhaul_career_market_valueCalculator.getVehicleCatalogIntrinsicBookValue({
  catalogBaseValue = info.Value, mileageMeters = info.Mileage, age = age, modelName = info.model_key,
  configKey = info.key, logContext = "repo", applyVehicleBuyMarket = false })
-- fallback: getAdjustedVehicleBaseValue(Value, {mileage, age})
```

`lib/market/usedVehicleCondition.lua`: `generateUsedVehicleCondition(seller, info)` (178–195) mutates
`info` and returns it, or nil. Whether repo applies that mileage to the spawned vehicle is **UNCONFIRMED**.

### 4.5 How recovery picks vehicles and rolls condition

- `buildVehiclePool()` (`recovery.lua:89-111`) is cached per skill level. It skips electric and hybrid
  vehicles and `roleplay`/`police` config types. It tags each vehicle with `recoveryTag`,
  `recoveryTierLabel`, `recoveryPayMultiplier` and `recoveryBaseXp`.
- `offers.pickVehicleAndSpot(rewardType)` (`recovery/offers.lua:60-95`) checks the spot's `minLevel` and
  that the vehicle fits the spot (`spot:boxFits` or 0.9 × spot scale). `chooseWeighted`
  (`recovery/vehiclePool.lua:169-200`) picks a model uniformly and then a config by population.
- `rollCondition(vehicleInfo) -> conditionString, missingWheels` (207–213): a trailer always gets
  `"complete"`; other vehicles get 70 % `"complete"` and 30 % `"brokenEngine"`. Recovery does **not**
  use `usedVehicleCondition`.
- `candidateCanSpawn(info)` (298–303) passes when the config is not remembered as unspawnable and
  `targetContentAvailable(model, config)` finds `/vehicles/<model>/`, `info.json`, a root `.jbeam` and
  the `.pc` file.
- `rememberUnspawnable(model, config)` / `isRememberedUnspawnable` (253–260) keep a key `model|config`.
  The memory is a closure table that is **not persisted** and resets on extension reload. It is written
  from `offers.lua:91` and `recovery.lua:1102-1110` (spawn failures other than destroyed/despawned).

---

## 5. Places

### 5.1 Parking spots and sites files

`lib/world/levelData.lua:386`:

```lua
function M.loadCityParkingSpots()
  local sitePath = context.sitesManager().getCurrentLevelSitesFileByName('city')
  if sitePath then
    local siteData = context.sitesManager().loadSites(sitePath, true, true)
    return true, siteData and siteData.parkingSpots
  end
  return false
end
```

- It returns `found, parkingSpots`. The function can return `true, nil`. `parkingSpots` is an engine
  collection with `.objects` (iterate with `pairs`) and `.byName[name]`.
- `require('overhaul/lib/world/sitesManager').sitesManager()` autoloads `gameplay_sites_sitesManager`
  if needed.
- The meaning of the third argument of `loadSites(path, true, true)` is **UNCONFIRMED** (engine).
- `levelData.newMapScope()` (396–418) is a cache that resets when `getCurrentLevelIdentifier()` changes.

Repo fallback (`repo.lua:436-448`): if no city sites file exists, it uses
`(overhaul_integration_services_parking or parking).getParkingSpots()`.

Pickup selection (`repo/generation.lua:375-384`): spots with `spot.pos` that are at least 300 m from the
player **and at least 600 m from the destination** (straight line), then `findReservableSpot`.

Runtime spot fields RLS uses: `pos` (vec3), `rot` (quat), `scl`, `name`, `customFields.tags/values`,
`missing`, `spot:getPath()`, `spot:hasAnyVehicles(ignoreId) -> occupied, ids`, `spot:boxFits(x,y,z)`.

Sites names RLS asks for with `getCurrentLevelSitesFileByName(name)`: `'city'` (levelData, taxi),
`'offroadRecovery'` (`recovery.lua:24,119`), `'facilities'` (`recovery.lua:145`), `'carmeet'`.
Shipped sites exist only for `levels/rls_west_coast/` (city: 424 spots, facilities: 136,
offroadRecovery: 51, plus around 20 others). Stock maps rely on the stock level's `city.sites.json`
(**UNCONFIRMED** per map).

### 5.2 Parking reservation (`lib/parking/reservation.lua`)

Use `require("overhaul/lib/parking/reservation").service`. It is a dispatcher (417–427) that picks the
overhaul provider when `overhaul_shell_gameMode.isActive()` and the vanilla provider otherwise. Repo and
taxi use it.

| Function | Line | Semantics |
|---|---|---|
| `makeReservationToken(prefix?)` | 47 | Returns `"<prefix>:<os.time>:<rand>"`, a plain string used as the owner id. |
| `shuffleSpots(spots)` | 52 | Returns a Fisher–Yates shuffled copy. |
| `resolveLiveSpot(spotOrPathOrName, parkingSpots?)` | 99 | Maps a static sites spot to the live parking-pool spot (by `getPath()`, then `byName`), or nil. |
| `findReservableSpot(candidates, token, options?)` | 349 | For each candidate: resolve, skip if hard-blocked, reserve if empty. Relocatable parked traffic is cleared first. Returns the **live** spot or nil. |
| `reserveSpot(spot, token)` | 303 | Sets `spot.ignoreOthers = true` and `spot._rlsReservationOwner = token`. |
| `releaseSpot(spot, token)` | 317 | Releases only if the owner matches. |
| `releaseAll()` | 331 | Overhaul provider only. Called on `onClientEndMission` by the parking service (`integration/services/parking.lua:1597-1601`). |
| `isSpotHardBlocked(spot, token)` | 225 | Delivery-reserved spots, the `ignoreOthers` tag, or another owner's reservation. |

- There is **no `release()` or `isReserved()`**. "Reserved" means `spot._rlsReservationOwner ~= nil`
  (an internal field).
- `findReservableSpot` returns a different, live object. Pass that object to `releaseSpot`.
- Facility spots may be missing from the live pool. Repo then falls back to the first static facility
  spot without a reservation (`generation.lua:353-364`).
- Repo releases the pickup spot once the target moves faster than 2 m/s within 15 m of the player
  (`repo.lua:1006`), and the delivery spot on completion (401) or cancel (184–185).
- Recovery does **not** use this service. It tracks its spots by `spotName` in its own save.
- Per-activity wrapper: `lib/activity/resources/parking.lua`, `create(owner)` with `reserve`,
  `findAndReserve`, `release`, `releaseAll` (own spots only) and `heldCount`.

### 5.3 Facilities (`overhaul_world_facilities`, `world/facilities.lua`)

| Function | Line | Notes |
|---|---|---|
| `getFacilities(levelName)` | 100 | `{garages={}, dealerships={}, gasStations={}, …}`. The cache is cleared on `onClientPreStartMission` (1060). |
| `getCurrentLevelFacilities()` | 1046 | |
| `getFacilitiesByType(type, levelName?)` | 153 | Returns an array. Types: `"garage"`, `"dealership"`, … |
| `getFacility(type, id, quiet?)`, `getFacilityIfExists(type, id)` | 135 / 1048 | |
| `getGarage(id)`, `getDealership(id)` | 235–237 | |
| `getParkingSpotsForFacility(facility)` | 289 | Static sites spots taken from `facility.parkingSpotNames` (spots with `missing` are skipped). |
| `getZonesForFacility(facility)` | 165 | Zones with `zone:containsPoint2D(pos)`. |
| `getGaragePosRot(poi, veh)` | 322 | |

- Facility fields (`parseFacility` 58–76): `id`, `name`, `type`, `preview`, `sitesFile` (default
  `facilities.sites.json`), `zoneNames`, `parkingSpotNames`, `doors`, `associatedOrganization`, `filter`.
- `dropOffSpots`, `pickUpSpots`, `inspectSpots` and `accessPointsByName` exist only on **logistics**
  facilities (`career/logistics/generator/facilities.lua:576-581`). Repo merges them for `repoProvider`
  facilities (`collectEmploymentDeliverySpots`, `generation.lua:198-210`); a plain dealership uses only
  `getParkingSpotsForFacility`.

### 5.4 Garage ownership (`overhaul_career_garage_garageManager`, logic in `career/garage/garageManager/ownership.lua:209-293`)

| API | Meaning |
|---|---|
| `isPurchasedGarage(id)` | Owned (bundles included). |
| `isNotPurchasableGarage(id, garage?)` | `garage.notPurchasable == true`. |
| `isAccessibleGarage(id)` | Owned **or** rented (`overhaul_career_garage_property_propertyRentals.isRentedGarage(id)`). Returns false for not-purchasable garages. |
| `isGarageForSale(id)`, `isDiscoveredGarage(id)`, `getPurchasedGarages()` | |

- There is no `isGarageOwned` or `isRented`.
- Garage data: `levels/<map>/facilities/facilities.facilities.json` (`defaultPrice`, `capacity`,
  `notPurchasable`). The recovery yard has `isRecoveryYard` and `recoveryDropoffSpotName`.
- **Tow "home" filter:** a garage qualifies when it is not `isNotPurchasableGarage`, not
  `isAccessibleGarage`, is not a recovery yard, and has parking spots. Call it only while the career is active.

### 5.5 Road route length

- `core_groundMarkers.getPathLength()` has no arguments and returns the length of the **currently set**
  GPS route. Repo calls it right after `setPath` (`repo.lua:474-477`). Using it for offers would
  overwrite the player's route. Units are presumably metres (**UNCONFIRMED**).
- Recovery `routeDistance(fromPos, toPos)` (`recovery.lua:249-266`) is local and not exported, but easy to copy:

```lua
local routeFactory = require("/lua/ge/extensions/gameplay/route/route")   -- engine module
local planner = routeFactory()
planner:setRouteParams(nil, 1e3)
planner:setupPath(fromPos, toPos)
local d = planner.path and planner.path[1] and planner.path[1].distToTarget or planner.distance
planner:clear()
-- inside pcall; fallback fromPos:distance(toPos); cached by rounded endpoints; cache cleared on map change (:1302)
```

  The meaning of `1e3` is **UNCONFIRMED** (engine). This route planner does not touch the GPS.
- Alternative: `require('overhaul/lib/logistics/facilityScanner').getDistanceBetweenLocations(a, b)
  -> metres, reliable` (161–186) using `map.findClosestRoad` and `map.getPath`. On error it returns
  `(direct, false)`; do not cache unreliable values.

### 5.6 GPS route: `lib/activity/routeLease.lua`

`require('overhaul/lib/activity/routeLease').new(owner?)` returns a lease:

- `set(pos, opts)` calls `core_groundMarkers.setPath(pos, opts)` and remembers the target and
  `getPathGeneration()`.
- `isCurrent()` is true while our route is still the one shown.
- `clear()` clears **only our own route** (`clearOwnedPath(generation)`).

`integration/patches/groundMarkerOwnership.lua` wraps `core_groundMarkers` to add generations,
`clearOwnedPath` and `claim`/`release` (used by bus). Repo calls
`set(pos, {clearPathOnReachingTarget = true})`; recovery calls `{clearPathOnReachingTarget = false}`
and re-sets the route in `onUpdate` when `not core_groundMarkers.currentlyHasTarget()` (1355). For the
hub's Route button, `lease.set(nextStopPos, {clearPathOnReachingTarget = true})` matches the spec rule
"navigation follows the last route set".

---

## 6. Job flow building blocks

### 6.1 Spawning the target

Repo (`repo.lua:449-486`):

```lua
local newVehicle = core_vehicles.spawnNewVehicle(info.model_key, {
  config = info.key, autoEnterVehicle = false, pos = spot.pos, rot = spot.rot or quat(0,0,0,1),
  cling = true, electrics = { parkingbrake = 0 }, paint = paint, paintName = paintName })
core_vehicle_manager.setVehiclePaintsNames(newVehicle:getID(), {paintName, paintName, paintName})
```

Factory paint: `generation.pickRepoSpawnPaint(model, config)` (476–497) uses
`core_vehiclePaints.getRandomPaints` and keeps non-`custom` classes.

Recovery (`recovery.lua:604-643`) passes `config` as a **table** (the loaded `.pc` with
`isRecovery = true`, `targetVehicle.lua:125-137`), uses `cling = false`, a random paint, and
`pos`/`rot` from saved arrays.

Neither job sets `vehicleName`, `licenseText` or `setDynDataFieldbyName`.

Deferred spawn, the "spawn when stationary" pattern (`repo/generation.lua:86-103`):

- Generation runs in a coroutine pumped from `onUpdate` (`advanceGeneration`, `repo.lua:867-878`).
- Between steps it yields 5 frames (27–31).
- The spawn waits only until the player vehicle is slower than 1 m/s; distance is not checked:

```lua
while not self.spawnedVehicle and be:getPlayerVehicle(0):getVelocity():length() > 1 do coroutine.yield() end
```

Do not resume the coroutine inside `pcall` (comment at `repo.lua:609`: LuaJIT cannot yield across it).

Post-spawn setup used by repo:

| Purpose | Call | Ref |
|---|---|---|
| Keep traffic AI off it | `gameplay_traffic.insertTraffic(id, true)` then `gameplay_traffic.getTrafficData()[id]:setRole("empty")`; undo with `gameplay_traffic.removeTraffic(id)` | `repo.lua:720-750`, 67, 186 |
| Parking brake when the player is within 20 m | `veh:queueLuaCommand('input.event("parkingbrake", 1, "FILTER_DI", nil, nil, nil, nil)')` | 718, 736 |
| Ignition off | `queueLuaCommand("electrics.setIgnitionLevel(0)")` or `core_vehicleBridge.executeAction(veh, 'setIgnitionLevel', 0)` | 972–994, `career/maintenance/fuel.lua:228` |
| Freeze before delete | `core_vehicleBridge.executeAction(veh, "setFreeze", true); veh:delete()` | 65–73 |
| Mark as cargo (rig recovery leaves it in place) | hook `M.onOverhaulIsRecoveryCargo(vehId, answer)` sets `answer.isCargo = true` | `repo.lua:1229`, `recovery.lua:1171`, fired by `lib/logistics/rigRecovery.lua:422-428` |
| Police immunity for the carrier | `require("overhaul/lib/vehicles/policy").registerRole("repo", "repoCarrier", predicate, "loaded")` returns a dispose function | `repo.lua:427-432`, `lib/vehicles/policy.lua:99` |
| Delete on Lua reload | `require("overhaul/lib/vehicles/temporary").declare(owner, releaseFn)` | `repo.lua:1091` |

### 6.2 Delivery and custody detection

Repo (`repo.lua:928-970`, checked once per second):

- Complete when `distance(target, deliveryLocation.pos) <= 3 m` and speed `<= 1 m/s` (employment mode:
  8 m and 0.35 m/s). Within 10 m it shows "Please return the vehicle to the parking spot".
- Completion runs async: `core_jobsystem.create(runRepoCompletion, 1, self, generation)`, with a fade,
  `job.sleep(0.5)`, the payout and `overhaul_career_saveSystem.saveCurrent()`. The
  `completionGeneration` guard prevents a double completion.
- The job starts (custody equivalent) when the player is within 15 m and the target moves faster than
  2 m/s (997–1010).
- If the player gets more than 100 m from the target, a 10 s countdown runs, then the job resets with
  "Someone else has picked up…" and no fine (771–805).
- Standalone repo does not check whether the vehicle is on the truck.

Recovery (`recovery.lua:808-836`, every 0.5 s):

- The phase changes from pickup to delivery once the target moves at least 25 m (2D) from its spot.
- Complete when the target is inside the yard zone (`getZonesForFacility` + `containsPoint2D`) or within
  `DELIVERY_RADIUS_M = 5` (33, 220–235), at speed `<= 1 m/s`.
- The **target** position is measured, loaded or not.

Optional "on the bed" check:
`overhaul_career_logistics_vehicleTasks.isCargoOnHaulerBed(cargoVehId, haulerVehId) -> loaded, supportedNow`
(`career/logistics/vehicleTasks.lua:537`, `vehicleTasks/hauling.lua:265-336`). At least 75 % of the wheels
must rest on the carrier's triangles, with a relative speed below 2.5 m/s. The flag sets after 2.5 s of
support and clears after 3 s without it.

### 6.3 Part condition and the damage penalty

Reading conditions (always async):

- Inventory vehicles: `overhaul_career_garage_inventory.updatePartConditions(vehId, invId, cb)`
  (`career/garage/inventory/bindings.lua:287-345`). The result is stored in `getVehicles()[invId].partConditions`
  and the callback receives **no arguments**.
- Any vehicle:
  `core_vehicleBridge.requestValue(veh, function(res) local conds = res.result end, 'getPartConditions')`
  (`career/business/fleet/condition.lua:62-69`).
- Shape: `conds[partPath] = {odometer, integrityValue (0..1), visualValue, integrityState?}`.

Penalty (`recovery/rewards.lua:129-148`):

```lua
for partPath, base in pairs(job.baselineConditions) do
  local lost = math.max(0, integ(base) - (final[partPath] and integ(final[partPath]) or 0))  -- missing part = fully lost
  local vdata = core_vehicle_manager.getVehicleData(job.vehicleId).vdata
  local partValue = vdata.activePartsData[vdata.activeParts[partPath]].information.value or 700
  valueLost = valueLost + partValue * lost
end
return math.min(valueLost / math.max(job.vehicleValue or 1000, 1), 0.5), valueLost
```

- `job.vehicleValue` is the catalogue book value (`offerVehicleValue`, `recovery/vehiclePool.lua:227-243`).
- Recovery captures the baseline right after the initial condition is applied (`finishNewTarget`,
  `recovery.lua:550-579`).
- The spec instead charges `valueLost` in money, ignores losses below 2 % per part, caps the penalty at
  the quote, and captures the baseline at 30 m. These are our own rules.
- Repo has **no** damage penalty.

### 6.4 Destroyed, abandoned, cleanup and fines

- Recovery `onVehicleDestroyed(vehId)` (`recovery.lua:1481`) maps the id through `runtimeByVehicleId`
  and calls `onTargetSpawnFailed(job, "destroyed")` (1104–1150), which ends in `abandonJob` and the
  message "Recovery target was lost.". A target that disappears without the hook is detected in the
  update loop as `"despawned"` (812–818).
- `M.abandonJob(jobId)` (1068) removes the job and calls `cleanupTemporaryTarget` (661–693). **Copy
  this order when deleting a vehicle that may sit on a flatbed** (otherwise the gooseneck or pintle
  can be torn):
  1. find haulers within 25 m (`targetVehicle.lua:168-203`);
  2. lock their couplers (140–166);
  3. ghost the target, zero its velocity and lift it 60 m (216–231);
  4. after 0.2 s, `inventory.removeVehicleObject(invId, true)` and `removeVehicle(invId)`;
  5. after another 0.15 s, unlock the couplers.
- Repo `cancelJob()` calls `destroy()` and `resetToInitialState()` (303–310). `releaseJobResources`
  (182–195) releases the reservations, calls `removeTraffic`, deletes the vehicle and the marker, and
  clears the route. Repo has no `onVehicleDestroyed`; it polls `checkVehicleExists`.
- **No fines exist** in repo or recovery. The only abandon fines are in broker logistics
  (`career/logistics/broker.lua:1503`).

### 6.5 Map travel blocking

`career/garage/switchMap.lua:799-822`, `switchMap(levelName)`:

```lua
local function getTravelBlockers()            -- :765
  local broker = overhaul_career_logistics_broker
  if not broker then return nil end
  if not broker.hasObligations() then return nil end
  return broker.getObligations()
end
-- blocked: guihooks.trigger("MapTravelBlocked", {destination, blockers={jobs,rentals,totalFine,count}, message})
--          return false, 'Finish or cancel Broker work and return rented equipment before travelling to another map.'  (:9)
-- other refusals: guihooks.trigger("MapTravelUnavailable", {destination, message})
```

- **There is no third-party travel-blocker API.** Only the broker blocks travel; repo and recovery do
  not (recovery pauses its jobs per map).
- The activity registry's `blocks = {"travelJournal", "studioRentals"}` (`lib/activity/definition.lua:17`)
  blocks only those apps, not map travel. Activity manifests are `gameplay/overhaul/activities/<id>.json`
  (`{id, order, extension, definition}`; `jobs/repo/activity.lua` is an example).
- Options for the hub, all **UNCONFIRMED**:
  - wrap `overhaul_career_garage_switchMap.switchMap` after it loads;
  - or wrap `overhaul_career_logistics_broker.hasObligations` / `getObligations` so they include our job.
    The UI blocker text then mentions Broker.
  - The fallback that needs no patching: pause the job on `onClientEndMission`, as recovery does, and
    explain in the app.

---

## 7. Persistence

### 7.1 Recovery save layout

Constants (`recovery.lua:24-36`):

```lua
SAVE_DIR = "/career/rls_career" ; SAVE_FILE = SAVE_DIR .. "/offroadRecovery.json"
DAMAGE_DIR = SAVE_DIR .. "/offroadRecoveryDamage"            -- <jobId>.json
SESSION_DAMAGE_DIR = "/temp/rls_career/offroadRecoveryDamage" ; SAVE_TIMEOUT_S = 15
ASYNC_SAVE_EXTENSION = "offroadRecovery" ; MAX_ACTIVE_PER_MAP = 3
```

- The file lives at `<savePath>/career/rls_career/offroadRecovery.json`, where `savePath` has no trailing
  slash. The RLS save root is `settings/cloud/overhaul/saves/<profile>/<slot>` (`career/saveSystem.lua:27,1117`).
- JSON shape: `{version, nextId, maps: {<levelIdentifier>: {trackedJobId, jobs: [ {id, mapId, spotName,
  originalTargetPos[3], targetPos[3], targetRot[4], model, configKey, …, phase, status, inventoryId,
  vehicleSnapshot{model, config, partConditions}, baselineConditions, energyStorage[…]} ]}}}`.
- State is **per map** under `maps[getCurrentLevelIdentifier()]`. Targets are spawned only when
  `currentMap == job.mapId` (605).
- `serializableState()` (298–309) strips the runtime fields `vehicleId`, `completing` and `spawnPending`,
  and saves `active`/`spawning` jobs as `paused`.
- Rotation is saved as `quat(0,0,1,0) * quat(veh:getRefNodeRotation())` (`recovery/persistence.lua:87`).

Save hooks (`saveSystem.lua:1098-1150`):

1. `onOverhaulSaveCurrentProfileAsyncStart()` fires first.
2. `onOverhaulSaveCurrentProfile(savePath, vehiclesThumbnailUpdate, writer)` follows. This is the main
   save hook; recovery implements it at 1448–1457.
3. `onOverhaulVehicleSaveFinished(savePath)` fires after the inventory has written the vehicles.
4. `onOverhaulSaveFinished()` fires at the end.

RLS does not use the stock `onSaveCurrentSaveSlot`.

Async save (`saveSystem.lua:1039-1055`):

- `registerAsyncSaveExtension(name) -> generation`, `isAsyncSaveExtensionCurrent(name, gen)` and
  `asyncSaveExtensionFinished(name, gen)`.
- The save does not finish while any async extension is pending. A global 45 s timeout is the safety net.
- Recovery registers only when a target is live. It then captures the pose, the energy
  (`core_vehicleBridge.requestValue(veh, cb, "energyStorage")`) and a damage snapshot (VE
  `overhaulDamageState.saveDamageData(path)`). It waits for `onOverhaulVehicleSaveFinished`, with its own
  15 s timeout (`recovery.lua:430-499`, `1439-1446`, `1329-1332`).

Load:

- `local profileName, savePath = overhaul_career_saveSystem.getCurrentProfile()` (`saveSystem.lua:854`).
- Recovery loads in `onOverhaulModulesActivated`, in `onExtensionLoaded` when the career is active, and
  lazily in the save hook.
- It respawns on `onWorldReadyState(2)` through `restoreCurrentMapJobs()` (1245–1289).
- The loaded flag is reset on `onOverhaulBeforeSetProfile` and `onOverhaulActive(false)`.
- `onClientEndMission` captures the exit state into the session temp dir and pauses the jobs.

### 7.2 The save library to reuse: `lib/save/store.lua` + `lib/save/feature.lua`

```lua
local saveStore = require("overhaul/lib/save/store")
local persistence = assert(saveStore.feature("addons.towRepoHub", {           -- key ^[%w_]+%.[%w_.]+$
  owner = "towRepoHub_core", files = {"career/towRepoHub/state.json"},
  root = "slot", phase = "profile", required = false, writer = {pretty = true},
  capture = function(context, writer)
    local dir = context.path():match("^(.*)/[^/]+$"); if not writer.exists(dir) then writer.mkdir(dir) end
    context.write(buildSavePayload())
  end,
  restore = function(context) return context.read() end,
}))
local function onOverhaulSaveCurrentProfile(savePath, _, writer)
  persistence.capture(savePath, writer or overhaul_career_saveSystem.getSaveWriter())
end
-- on unload: persistence.dispose()
```

- This pattern comes from `jobs/miningHaul.lua:421-442,1032-1039`. Descriptor validation is at
  `lib/save/keyRegistry.lua:47-68`:
  - `phase ∈ {profile, vehicleSave, deferred, immediate, import}`;
  - `root ∈ {slot, profile, user}`;
  - `files` are relative paths without `..`;
  - a key belongs to a single owner.
- `required = true` lets a capture error fail the whole save. **Use `false`** for the add-on.
- Add-on manifests are also accepted: `/gameplay/overhaul/save/keys/<id>.json` (default `required = false`,
  `keyRegistry.lua:110-140`).
- `writeSlot` / `writeNow` use `overhaul_career_saveSystem.jsonWriteFileSafe` (temp file + rename,
  queued during a save).
- `saveStore.request(reason)` asks for a save. `saveStore.hold(owner, reason)` blocks saving.
- Saves rotate across 4 autosave folders. Write the file on every save, or a stale file from an older use
  of the folder may be read back (**UNCONFIRMED**).

### 7.3 The inventory handoff (temporary vehicle)

`overhaul_career_garage_inventory.addVehicle(vehId, inventoryId?, options?) -> inventoryId | nil`
(`career/garage/inventory/bindings.lua:147-186`):

- `options`: `owned` (default true), `takesNoInventorySpace` (default from the `.pc`),
  `skipPartConditionInit`, `finalPrice`, `year`, `starter`, `purchaseToken`, `replacingInventoryId`.
- It returns nil with a `ui_message` when the vehicle is owned, takes space and no slot is free (165–168).
- It fires `onOverhaulInventoryBindingsChanged`. `onOverhaulVehicleAdded(invId)` fires **only for numeric ids**.

Recovery's temporary target (`recovery.lua:515-543`):

```lua
job.inventoryId = job.inventoryId or ("offroadRecovery:" .. job.id)        -- string id = temporary
local invId = overhaul_career_garage_inventory.addVehicle(veh:getID(), job.inventoryId, {owned = false, skipPartConditionInit = true})
local record = overhaul_career_garage_inventory.getVehicles()[invId]
record.offroadRecoveryContract = true; record.offroadRecoveryJobId = job.id; record.loanType = nil
```

What a string id gives you:

- It is never written to `career/vehicles/*.json` or `spawnedPlayerVehicles`, and is not shown in the UI
  (`isPersonalInventoryId`, `inventory/persistence.lua:377-380,455,520`).
- Insurance ignores it (`policyChanges.lua:383-398`). It cannot be sold (`operations.lua:220`).
- Map travel does not carry it (`switchMap.lua:35-41`).
- **It does not survive a reload through the inventory.** Recovery respawns it from its own save.
- It may still count toward garage capacity, because `vehicleUsesGarageCapacity`
  (`garageManager.lua:45-52`) checks only `takesNoInventorySpace`. Pass `takesNoInventorySpace = true`
  (**UNCONFIRMED** in game).

Permission lock-out (`recovery.lua:1183-1207`): `M.onOverhaulCheckPermission(tags, permissions, additionalData)`
returns `{permission = "forbidden", label = …}` for our record when `additionalData.inventoryId` matches.
The tags are `interactRefuel, vehicleRepair, vehicleModification, partBuying, partSwapping, painting,
tuning, vehicleStoring, vehicleSelling, vehicleLicensePlate, vehicleFavorite, returnLoanedVehicle,
recoveryTowToGarage, recoveryTowToRoad`. The spec allows refuelling, so leave out `interactRefuel`.

Other helpers:

- `removeVehicle(invId)` (232–248) fires `onOverhaulVehicleRemoved` and returns false if logistics holds
  the vehicle.
- `removeVehicleObject(invId, skipPartConditions)` (198–230).
- `getVehicleIdFromInventoryId(invId)` / `getInventoryIdFromVehicleId(vehId)` (`inventory.lua:898-899`).

Restore after load (`restoreCurrentMapJobs`):

- If `getVehicleIdFromInventoryId(job.inventoryId)` still resolves (a Lua reload in the same session),
  the job rebinds to that vehicle.
- Otherwise `spawnJobTarget` respawns it at the saved pose with `cling = false`. It then calls
  `core_vehicleBridge.executeAction(veh, "initPartConditions", snapshot.partConditions, 0, 1, 1)`, a ping,
  `attachTemporaryInventory` again, `setStoredEnergy` and VE `overhaulDamageState.loadDamageData(path)`.
- The job binds to `job.id`; the vehId is runtime-only.

Promotion to an owned vehicle (`jobs/recovery/handoff.lua`) is not needed by the hub. Note that
`onOverhaulVehicleAddedToInventory(data)` is fired **by the caller**, not by `addVehicle`
(`handoff.lua:44` passes `{inventoryId, purchaseData = {insuranceId = -1}}`).

### 7.4 Vehicles carried on a flatbed

- `lib/vehicles/carriedFrame.lua`:
  - `capture(child, carrier) -> {nodes = {n1, n2, n3}, offset = {...}} | nil` (116–128) uses three
    carrier support nodes under the child;
  - `transform(carrier, relation) -> MatrixF | nil` (130–149) falls back to the carrier ref-node matrix
    and `relation.offset`.
- `career/inventory/travel.lua:196-209`, `placeCarriedVehicle`, calls `veh:setTransform(m)` and
  `veh:resetBrokenFlexMesh()`.
- `switchMap.buildManifest` (572–629) and the inventory save (`inventory/persistence.lua:632-643`,
  `vehicleRelationships` in `career/inventory.json`) store carrier relations **only for numeric
  inventory ids** (`tonumber(inventoryId)` in `travel.lua:17-26`).
- On load, `travel.restoreCarriedVehicles` (461–530) seats the child on its carrier and holds the
  loading screen until that is done.
- **Recovery does not use any of this for its temporary target.** It saves the absolute pose and respawns
  there with `cling = false`. The flatbed is restored independently by the inventory, in an
  unsynchronised order (**UNCONFIRMED** whether the target lands on the deck or collides).
- For the hub "on a flatbed after reload": save `carriedFrame.capture(target, carrier)` together with
  the carrier's numeric inventory id. Once both vehicles exist, call
  `target:setTransform(carriedFrame.transform(carrier, relation))`. This is our own design built on an
  RLS lib; RLS has no such path for temporary vehicles.

---

## 8. Tow faults

| Fault | What RLS has | Use for the hub |
|---|---|---|
| Fuel | Read with `core_vehicleBridge.requestValue(veh, cb, "energyStorage")`; tanks are `{name, energyType, currentEnergy (J), maxEnergy (J)}`. Write with `core_vehicleBridge.executeAction(veh, "setEnergyStorageEnergy", tank.name, joules)`, then confirm with `requestValue(veh, cb, "ping")` (`recovery/targetVehicle.lua:4-51`). Recovery's `setOneLiter` uses J/l: gasoline 31.125e6, diesel 36.112e6, kerosine 34.4e6. | Set a few hundred metres of fuel. **Gotcha:** `overhaul_career_maintenance_fuel.minimumRefuelingCheck(vehId)` (`career/maintenance/fuel.lua:652-660`) tops a tank at or below 1 % up to 5 %; only `overhaul_jobs_recovery.isContractTarget` is exempt (`fuel/fuelSeam.lua:188-191`). It runs after tow-to-garage, repair and inventory spawn; whether it hits our target is **UNCONFIRMED**. Keep the level above 1 %. |
| Flat tyre | VE extension `lua/vehicle/extensions/overhaulTires.lua`: `getRlsTireState() -> {provider, wheels = {{name, remaining, flat, temperature, partPath, …}}}` (730–741), `applyFreshAndInflate`. Deflation is the vanilla `beamstate.deflateTire(index)`, with the index from `wheels.wheelRotators` (486, 493, 559). The GE `career/maintenance/tireSystem.lua` configures **inventory vehicles only** (`tireSystem/context.lua:410-416`). | No GE API exists. Use `veh:queueLuaCommand("beamstate.deflateTire(" .. idx .. ")")`. A temporary inventory vehicle configured with `enabled = false` may get `restoreSoftDeflation` (`tireSystem.lua:557-563`), which re-inflates it (**UNCONFIRMED**). |
| Engine damage | Recovery's "brokenEngine": vlua `partCondition.initConditions(parts, mileage, 1, 1)` with `integrityValue = 0` on parts whose name contains `engine` but not `mount` (`targetVehicle.lua:53-73`); callback `recoveryInitialCondition`. | Ruins the engine; not drivable. Not a spec fault. |
| Overheating | VE `lua/vehicle/extensions/overhaulMaintenance.lua` with categories engine, radiator, transmission: `debugForceFailure(category, "symptom" \| "hard")`; radiator `symptom` = `coolantSeep` (`manager/failures.lua:401-431`). GE bridge `vehicles/maintenanceBridge.lua`, `applyMaintenanceFailure(inventoryId, category, mode)` (509–516), works **only for inventory vehicles with the experimental maintenance on** (124–137). | **No supported way** for a non-inventory vehicle. Candidates: `debugForceFailure("radiator", "symptom")` through `vehicleCommands` (needs `extensions.load('overhaulMaintenance')` in the VE first), or a vanilla radiator damage call. Both **UNCONFIRMED**; this is the spec's known risk. |
| Worn | `partCondition.initConditions(parts, mileage, integrity, visual)` and `core_vehicleBridge.executeAction(veh, "initPartConditions", conds, 0, 1, 1)`. | Pass a high mileage and a lower visual value (**UNCONFIRMED** visual effect). The baseline must be captured after the wear is applied. |

Vehicle-side commands:

- `require('overhaul/lib/vehicles/vehicleCommands')`:
  - `call(ext, fn, ...) -> "ext.fn(lit, …)"` (safe literals only);
  - `queue(veh, ext, fn, ...)` = `veh:queueLuaCommand(call(...))`;
  - `luaLiteral(v)`.

  Example:
  `veh:queueLuaCommand("extensions.load('overhaulDamageState'); if overhaulDamageState then " .. vehicleCommands.call('overhaulDamageState', 'loadDamageData', path) .. " end")`.
- VE → GE replies:
  - GE side: `require('overhaul/lib/vehicles/callbacks').open(id, {owner, vehId, timeout, onFail})` or
    `.query(veh, id, opts, fn)` (153–194).
  - VE side: `obj:queueGameEngineLua(require('vehicle/overhaul/geCallback').reply(rid, 'id', argsString))`.
  - Each callback id must be declared in `gameplay/overhaul/vehicleCallbacks/<owner>.json`:
    `{"id", "order", "callbacks": [{"id", "extension", "fn", "guard"}]}` (see `recovery.json`).
  - A simpler option: vanilla `core_vehicleBridge.requestValue` / `executeAction` with the keys RLS uses:
    `energyStorage`, `ping`, `getPartConditions`, `getOverhaulInventoryVehicleState`, and the actions
    `setEnergyStorageEnergy`, `setIgnitionLevel`, `setFreeze`, `initPartConditions`.

**Not in RLS:**

- a GE tyre-deflation API;
- overheating or failure APIs for non-inventory vehicles;
- a way to exempt our target from `minimumRefuelingCheck`;
- a third-party map-travel blocker;
- fines for repo or recovery;
- a flatbed check in standalone repo;
- `licenseText`/`vehicleName` on job spawns.

---

## Risks and unknowns for in-game verification

1. A third-party `.vue` route loads at runtime from `/ui/ui-vue/mods/towRepoHub/…` (`loadModule`, scoped SCSS).
2. `lua.towRepoHub_*` from Vue: probably needs a `gameplay/overhaul/ui/owners/*.json` with
   `exports.namespace: true`. Otherwise use `callModLua` / `bngApi.engineLua`.
3. Which load path works for our extension: a career owner JSON, a career module JSON, or our own modScript.
4. Map travel blocking needs a wrap of `switchMap` or the broker. Test that it does not break the RLS
   travel UI, or fall back to pausing the job.
5. A temporary string-id target with `takesNoInventorySpace = true` does not count toward garage capacity
   and does not block other RLS flows (logistics `canRemoveLogisticsVehicle`, rig recovery, Carjacking & Theft).
6. A target restored after reload lands on the flatbed (`carriedFrame` relation) instead of colliding with
   it; check the restore order against the inventory.
7. Overheating without real radiator damage, and whether `minimumRefuelingCheck` or `tireSystem` undo
   our fuel and flat-tyre faults.
8. Whether `vehicleInfo.Weight` exists from `getEligibleVehicles` on 0.40, and its unit.
9. A negative `payout` with `allowNetDebit` and category `fine` for custody fines, and how Wallet lists it.
10. Whether the `"repo"` payout tag (activity heat / surge) and a custom hub tag show correctly in Wallet;
    whether `activity:recovery` versus `activity:repo` is the better category.
11. `parkingReservation.service` on stock maps: whether city spots resolve to the live pool. The static
    fallback holds no reservation, so RLS jobs could share that spot.
12. The recovery cap in the spec assumes a level-based difficulty fee, but RLS takes it from the spot's
    `customFields`. Decide which reference to cap against.
13. `routeDistance` with the engine `gameplay/route/route` planner: cost per call (offers need several
    routes) and its fallback to straight-line distance.
