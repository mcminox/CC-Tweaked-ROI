local PROTOCOL = "swarm.min.v1"
local HEARTBEAT_TTL = 12
local TARGET_DRONES = 4
local MIN_FUEL = 120
local CHUNK = 16
local MIN_CHUNK = -1
local MAX_CHUNK = 1
local STATE_FILE = "central_state.db"
local SAVE_INTERVAL = 2
local PLAN_INTERVAL = 1.2
local FARM_CX = 4
local FARM_CZ = 4
local FARM_RADIUS = 4
local COBBLE_SOFT_CAP = 192
local COBBLE_NEED_FURNACE = 8
local CHARCOAL_TARGET = 64
local COAL_SOFT_CAP = 128
local FARM_SLOTS = {
  {2, 2}, {2, 4}, {2, 6}, {4, 2}, {4, 4}, {4, 6}, {6, 2}, {6, 4}, {6, 6},
}

local function cloneFarmSlots(slots)
  local out = {}
  for i, row in ipairs(slots or {}) do
    if type(row) == "table" then
      out[i] = {row[1], row[2]}
    end
  end
  return out
end

local state = {
  seq = 0,
  drones = {},
  tasks = {},
  world = {voxels = {}, updatedAt = 0},
  logistics = {
    home = {x = 0, y = 0, z = 0},
    farm = {x = FARM_CX, y = 0, z = FARM_CZ},
    furnace = {x = 2, y = 0, z = 0},
    smeltApproach = {x = 1, y = 0, z = 0},
    nodes = {
      {id = "home", x = 0, z = 0, role = "hub"},
      {id = "farm_gate", x = 3, z = 3, role = "cross"},
      {id = "furnace_yard", x = 1, z = 0, role = "cross"},
      {id = "mine_entry", x = -2, z = 0, role = "cross"},
    },
  },
  chest = {},
  planner = {
    lastPlan = 0,
    mineStripIndex = 0,
    exploreDir = 0,
  },
  farm = {built = false, slots = {}},
}

local function log(msg)
  print(("[CENTRAL %d] %s"):format(os.epoch("utc"), msg))
end

local function openModem()
  local sides = {"top", "bottom", "left", "right", "front", "back"}
  for _, s in ipairs(sides) do
    if peripheral.getType(s) == "modem" then
      rednet.open(s)
      return true
    end
  end
  return false
end

local function loadState()
  if not fs.exists(STATE_FILE) then
    return
  end
  local h = fs.open(STATE_FILE, "r")
  if not h then
    return
  end
  local raw = h.readAll()
  h.close()
  local ok, data = pcall(textutils.unserialize, raw)
  if ok and type(data) == "table" then
    state = data
    state.seq = state.seq or 0
    state.drones = state.drones or {}
    state.tasks = state.tasks or {}
    state.world = state.world or {voxels = {}, updatedAt = 0}
    state.world.voxels = state.world.voxels or {}
    state.logistics = state.logistics or {}
    state.logistics.nodes = state.logistics.nodes or {}
    state.chest = state.chest or {}
    state.planner = state.planner or {lastPlan = 0, mineStripIndex = 0, exploreDir = 0}
    state.farm = state.farm or {built = false, slots = {}}
    if not state.farm.slots or #state.farm.slots == 0 then
      state.farm.slots = cloneFarmSlots(FARM_SLOTS)
    else
      state.farm.slots = cloneFarmSlots(state.farm.slots)
    end
  end
end

local function sanitizeTaskPayloads()
  for _, t in ipairs(state.tasks) do
    if t.payload then
      t.payload.logistics = nil
      t.payload.farm = nil
      if t.payload.slots and type(t.payload.slots) == "table" then
        t.payload.slots = cloneFarmSlots(t.payload.slots)
      end
    end
  end
end

local function saveState()
  local tmp = STATE_FILE .. ".tmp"
  local h = fs.open(tmp, "w")
  if not h then
    return
  end
  h.write(textutils.serialize(state))
  h.close()
  if fs.exists(STATE_FILE) then
    fs.delete(STATE_FILE)
  end
  fs.move(tmp, STATE_FILE)
end

local function inBounds(x, z)
  local cx = math.floor((x or 0) / CHUNK)
  local cz = math.floor((z or 0) / CHUNK)
  return cx >= MIN_CHUNK and cx <= MAX_CHUNK and cz >= MIN_CHUNK and cz <= MAX_CHUNK
end

local function voxelKey(x, y, z)
  return tostring(x) .. ":" .. tostring(y) .. ":" .. tostring(z)
end

local function parseKey(k)
  local a, b, c = k:match("^(-?%d+):(-?%d+):(-?%d+)$")
  if not a then
    return nil
  end
  return tonumber(a), tonumber(b), tonumber(c)
end

local function inFarmZone(x, z)
  local dx = (x or 0) - FARM_CX
  local dz = (z or 0) - FARM_CZ
  return (dx * dx + dz * dz) <= (FARM_RADIUS * FARM_RADIUS)
end

local function voxelAt(x, y, z)
  return state.world.voxels[voxelKey(x, y, z)]
end

local function blockNameAt(x, y, z)
  local v = voxelAt(x, y, z)
  if not v then
    return nil
  end
  return v.t
end

local function isLogName(name)
  if not name then
    return false
  end
  return string.find(name, "log", 1, true) ~= nil
end

local function mapCountKnown()
  local n = 0
  for _ in pairs(state.world.voxels) do
    n = n + 1
  end
  return n
end

local function findNearestLogOutsideFarm(fromX, fromZ)
  local bestD = nil
  local bestX, bestZ, bestY = nil, nil, nil
  for k, v in pairs(state.world.voxels) do
    local x, y, z = parseKey(k)
    if x and isLogName(v.t) and not inFarmZone(x, z) then
      local d = math.abs(x - fromX) + math.abs(z - fromZ) + math.abs(y or 0) * 0
      if not bestD or d < bestD then
        bestD = d
        bestX, bestZ, bestY = x, z, y or 0
      end
    end
  end
  return bestX, bestZ, bestY, bestD
end

local function furnacePlacedOnMap()
  for k, v in pairs(state.world.voxels) do
    local x, y, z = parseKey(k)
    if x and v.t and string.find(v.t, "furnace", 1, true) then
      local fx = state.logistics.furnace.x
      local fz = state.logistics.furnace.z
      if math.abs(x - fx) <= 1 and math.abs(z - fz) <= 1 and (y or 0) == 0 then
        return true
      end
    end
  end
  return false
end

local function chestCount(name)
  return state.chest[name] or 0
end

local function mergeChest(summary)
  if type(summary) ~= "table" then
    return
  end
  state.chest = {}
  for k, v in pairs(summary) do
    state.chest[k] = v
  end
end

local function chestSaplingCount()
  local n = 0
  for name, c in pairs(state.chest) do
    if string.find(name, "sapling", 1, true) then
      n = n + (c or 0)
    end
  end
  return n
end

local function droneRole(id)
  if (id % 2) == 0 then
    return "farmer"
  end
  return "miner"
end

local function effectivePrio(t, droneId)
  local p = t.prio or 0
  local r = droneRole(droneId)
  local k = t.kind or ""
  if r == "farmer" and (k == "farm_build" or k == "farm_cycle" or k == "farm_replant" or k == "farm_harvest") then
    p = p + 12
  end
  if r == "miner" and (k == "mine" or k == "mine_cobble" or k == "gather_log") then
    p = p + 10
  end
  return p
end

local function taskId(kind)
  state.seq = state.seq + 1
  return kind .. ":" .. tostring(os.epoch("utc")) .. ":" .. tostring(state.seq)
end

local function openTaskByKind(kind)
  for _, t in ipairs(state.tasks) do
    if t.kind == kind and (t.status == "queued" or t.status == "assigned") then
      return t
    end
  end
  return nil
end

local function openTaskByExclusive(key)
  if not key then
    return nil
  end
  for _, t in ipairs(state.tasks) do
    if t.exclusive == key and (t.status == "queued" or t.status == "assigned") then
      return t
    end
  end
  return nil
end

local function enqueue(kind, payload, prio, exclusive)
  state.tasks[#state.tasks + 1] = {
    id = taskId(kind),
    kind = kind,
    payload = payload or {},
    prio = prio or 10,
    status = "queued",
    retries = 0,
    exclusive = exclusive,
  }
  log("enqueue " .. kind .. " prio=" .. tostring(prio or 10) .. (exclusive and (" ex=" .. exclusive) or ""))
end

local function removeTasksWhere(pred)
  local out = {}
  for _, t in ipairs(state.tasks) do
    if not pred(t) then
      out[#out + 1] = t
    end
  end
  state.tasks = out
end

local function pruneStaleMining()
  local cob = chestCount("minecraft:cobblestone") + chestCount("minecraft:stone")
  if cob > COBBLE_SOFT_CAP then
    removeTasksWhere(function(t)
      return (t.kind == "mine" or t.kind == "mine_cobble") and t.status == "queued"
    end)
  end
end

local function onlineDroneCount()
  local n = 0
  for _, d in pairs(state.drones) do
    if d.online then
      n = n + 1
    end
  end
  return n
end

local function droneBusyKind(droneId)
  for _, t in ipairs(state.tasks) do
    if t.status == "assigned" and t.assignedTo == droneId then
      return t.kind
    end
  end
  return nil
end

local function planNeeds()
  local fuelLow = false
  for _, d in pairs(state.drones) do
    if d.online and (d.fuel or 0) < MIN_FUEL then
      fuelLow = true
      break
    end
  end
  local coal = chestCount("minecraft:coal") + chestCount("minecraft:charcoal")
  local logs = 0
  for name, c in pairs(state.chest) do
    if string.find(name, "log", 1, true) then
      logs = logs + (c or 0)
    end
  end
  local cobble = chestCount("minecraft:cobblestone")
  local needCharcoal = fuelLow and coal < 16
  local needCobbleForFurnace = not furnacePlacedOnMap() and cobble < COBBLE_NEED_FURNACE and not openTaskByKind("mine_cobble")
  local needWoodForSmelt = needCharcoal and logs < 8 and not openTaskByKind("gather_log")
  local lx, lz, ly, dist = findNearestLogOutsideFarm(0, 0)
  local canTargetLog = lx ~= nil
  return {
    fuelLow = fuelLow,
    coal = coal,
    logs = logs,
    cobble = cobble,
    needCharcoal = needCharcoal,
    needCobbleForFurnace = needCobbleForFurnace,
    needWoodForSmelt = needWoodForSmelt,
    logX = lx,
    logZ = lz,
    logY = ly,
    logDist = dist,
    canTargetLog = canTargetLog,
  }
end

local function planTick()
  pruneStaleMining()
  local n = onlineDroneCount()
  if n == 0 then
    return
  end
  local needs = planNeeds()
  local cobble = needs.cobble
  local coal = needs.coal
  if needs.fuelLow and not openTaskByKind("refuel") then
    enqueue("refuel", {}, 98, nil)
  end
  if needs.needCharcoal then
    if not furnacePlacedOnMap() then
      if not openTaskByExclusive("furnace_line") then
        enqueue("setup_furnace", {fx = state.logistics.furnace.x, fz = state.logistics.furnace.z, ax = state.logistics.smeltApproach.x, az = state.logistics.smeltApproach.z}, 92, "furnace_line")
      end
    else
      if not openTaskByExclusive("smelt_charcoal") and chestCount("minecraft:charcoal") < CHARCOAL_TARGET then
        enqueue("smelt_charcoal", {batches = 8, ax = state.logistics.smeltApproach.x, az = state.logistics.smeltApproach.z}, 90, "smelt_charcoal")
      end
    end
    if needs.needWoodForSmelt and needs.canTargetLog and not openTaskByExclusive("gather_log") then
      enqueue("gather_log", {tx = needs.logX, tz = needs.logZ, ty = needs.logY or 0}, 88, "gather_log")
    end
  end
  if needs.needCobbleForFurnace and not openTaskByExclusive("mine_cobble_strip") then
    state.planner.mineStripIndex = (state.planner.mineStripIndex or 0) + 1
    local idx = state.planner.mineStripIndex
    local gateX = -2
    for _, node in ipairs(state.logistics.nodes) do
      if node.id == "mine_entry" then
        gateX = node.x
        break
      end
    end
    enqueue("mine_cobble", {steps = 10, strip = idx, gateX = gateX}, 75, "mine_cobble_strip")
  end
  if cobble > COBBLE_SOFT_CAP * 0.5 and coal > COAL_SOFT_CAP then
    if not openTaskByKind("explore") and mapCountKnown() < 120 then
      state.planner.exploreDir = (state.planner.exploreDir + 1) % 4
      enqueue("explore", {steps = 6, preferDir = state.planner.exploreDir}, 35, nil)
    end
  else
    if not openTaskByKind("mine") and cobble < COBBLE_SOFT_CAP then
      enqueue("mine", {steps = 8, strip = (state.planner.mineStripIndex or 0)}, 55, nil)
    end
  end
  state.farm = state.farm or {built = false, slots = cloneFarmSlots(FARM_SLOTS)}
  if not state.farm.slots or #state.farm.slots == 0 then
    state.farm.slots = cloneFarmSlots(FARM_SLOTS)
  end
  if not state.farm.built then
    if chestSaplingCount() >= 6 and chestCount("minecraft:dirt") >= 20 and not openTaskByExclusive("farm_build") then
      enqueue("farm_build", {slots = cloneFarmSlots(state.farm.slots)}, 87, "farm_build")
    end
    if not openTaskByKind("farm_replant") then
      enqueue("farm_replant", {x = FARM_CX, z = FARM_CZ}, 54, nil)
    end
    if not openTaskByKind("farm_harvest") then
      enqueue("farm_harvest", {x = FARM_CX, z = FARM_CZ}, 52, nil)
    end
  else
    if not openTaskByExclusive("farm_cycle") then
      enqueue("farm_cycle", {slots = cloneFarmSlots(state.farm.slots)}, 64, "farm_cycle")
    end
  end
  local canCraftAdvanced = chestCount("minecraft:redstone") > 0 and chestCount("minecraft:glass_pane") > 0
  if canCraftAdvanced and not openTaskByExclusive("craft_computer_advanced") then
    enqueue("craft", {recipe = "computer_advanced"}, 50, "craft_computer_advanced")
  end
  if chestCount("computercraft:computer_advanced") > 0 and chestCount("minecraft:chest") > 0 and not openTaskByExclusive("craft_turtle_advanced") then
    enqueue("craft", {recipe = "turtle_advanced"}, 48, "craft_turtle_advanced")
  end
  if chestCount("minecraft:redstone") > 2 and chestCount("minecraft:paper") > 0 and not openTaskByExclusive("craft_disk") then
    enqueue("craft", {recipe = "disk"}, 45, "craft_disk")
  end
  if chestCount("minecraft:iron_ingot") > 0 and chestCount("minecraft:stone") > 8 and not openTaskByExclusive("craft_drive") then
    enqueue("craft", {recipe = "disk_drive"}, 44, "craft_drive")
  end
  if chestCount("minecraft:stone") > 8 and chestCount("minecraft:ender_pearl") > 0 and not openTaskByExclusive("craft_modem") then
    enqueue("craft", {recipe = "wireless_modem_normal"}, 43, "craft_modem")
  end
  if n < TARGET_DRONES and chestCount("computercraft:turtle_advanced") > 0 and not openTaskByExclusive("bootstrap") then
    enqueue("bootstrap", {}, 40, "bootstrap")
  end
end

local function recoverOffline()
  local now = os.epoch("utc")
  for id, d in pairs(state.drones) do
    if d.last and now - d.last > HEARTBEAT_TTL * 1000 then
      if d.online then
        log("drone offline id=" .. tostring(id))
      end
      d.online = false
      d.busy = nil
      for _, t in ipairs(state.tasks) do
        if t.status == "assigned" and t.assignedTo == id then
          t.status = "queued"
          t.assignedTo = nil
        end
      end
    end
  end
end

local function pickTask(drone)
  local d = state.drones[drone.id]
  local busy = droneBusyKind(drone.id)
  if busy then
    return nil
  end
  table.sort(state.tasks, function(a, b)
    return effectivePrio(a, drone.id) > effectivePrio(b, drone.id)
  end)
  for _, t in ipairs(state.tasks) do
    if t.status == "queued" then
      local p = t.payload or {}
      local x = p.x or p.tx or p.fx or p.ax or 0
      local z = p.z or p.tz or p.fz or p.az or 0
      if p.slots and type(p.slots) == "table" and #p.slots > 0 and p.slots[1] and p.slots[1][1] then
        x = p.slots[1][1]
        z = p.slots[1][2] or 0
      end
      if inBounds(x, z) then
        local skip = false
        if t.kind == "gather_log" and (not d or (d.fuel or 0) < MIN_FUEL + 40) then
          skip = true
        end
        if t.kind == "farm_build" and (not d or (d.fuel or 0) < MIN_FUEL + 100) then
          skip = true
        end
        if t.kind == "farm_cycle" and (not d or (d.fuel or 0) < MIN_FUEL + 60) then
          skip = true
        end
        if not skip and (t.kind == "mine_cobble" or t.kind == "mine") and d and (d.fuel or 0) < MIN_FUEL + 20 then
          skip = true
        end
        if not skip then
          t.status = "assigned"
          t.assignedTo = drone.id
          t.assignedAt = os.epoch("utc")
          if d then
            d.busy = t.kind
          end
          log("assign " .. t.kind .. " -> " .. tostring(drone.id))
          return t
        end
      end
    end
  end
  return nil
end

local function send(to, kind, payload)
  rednet.send(to, {p = PROTOCOL, k = kind, d = payload or {}, ts = os.epoch("utc")}, PROTOCOL)
end

local function upsertDrone(id, data)
  state.drones[id] = state.drones[id] or {
    id = id,
    online = true,
    fuel = 0,
    pos = {x = 0, y = 0, z = 0, dir = 0},
    canon = {x = 0, y = 0, z = 0, dir = 0},
    drift = 0,
    chestSummary = nil,
  }
  local d = state.drones[id]
  d.online = true
  d.last = os.epoch("utc")
  if data and data.fuel then
    d.fuel = data.fuel
  end
  if data and data.chestSummary then
    d.chestSummary = data.chestSummary
    mergeChest(data.chestSummary)
  end
  if data and data.pos then
    d.pos = data.pos
    if data.anchorHome then
      d.canon = {x = 0, y = 0, z = 0, dir = data.pos.dir or d.canon.dir or 0}
    else
      d.canon = d.canon or {x = 0, y = 0, z = 0, dir = 0}
      d.canon.x = data.pos.x or d.canon.x
      d.canon.y = data.pos.y or d.canon.y
      d.canon.z = data.pos.z or d.canon.z
      d.canon.dir = data.pos.dir or d.canon.dir
    end
    local dx = math.abs((d.pos.x or 0) - (d.canon.x or 0))
    local dy = math.abs((d.pos.y or 0) - (d.canon.y or 0))
    local dz = math.abs((d.pos.z or 0) - (d.canon.z or 0))
    d.drift = dx + dy + dz
  end
  return d
end

local function applyMapDelta(delta)
  local count = 0
  for _, v in ipairs(delta or {}) do
    if inBounds(v.x, v.z) then
      state.world.voxels[voxelKey(v.x, v.y, v.z)] = {
        t = v.t or "unknown",
        by = v.by,
        ts = os.epoch("utc"),
      }
      count = count + 1
    end
  end
  if count > 0 then
    state.world.updatedAt = os.epoch("utc")
  end
  return count
end

local function markTaskDone(taskId, droneId)
  for _, t in ipairs(state.tasks) do
    if t.id == taskId then
      t.status = "done"
      t.doneAt = os.epoch("utc")
      if t.kind == "farm_build" then
        state.farm.built = true
        if t.payload and t.payload.slots and #t.payload.slots > 0 then
          state.farm.slots = cloneFarmSlots(t.payload.slots)
        else
          state.farm.slots = cloneFarmSlots(state.farm.slots or FARM_SLOTS)
        end
        log("farm_build finished slots=" .. tostring(#state.farm.slots))
      end
      log("done " .. t.kind .. " by " .. tostring(droneId))
      local dd = state.drones[droneId]
      if dd then
        dd.busy = nil
      end
      return
    end
  end
end

local function markTaskFail(taskId, droneId, reason)
  for _, t in ipairs(state.tasks) do
    if t.id == taskId then
      t.retries = (t.retries or 0) + 1
      if t.retries >= 5 then
        t.status = "failed"
      else
        t.status = "queued"
      end
      log("fail " .. t.kind .. " by " .. tostring(droneId) .. " reason=" .. tostring(reason or "unknown") .. " retries=" .. tostring(t.retries))
      local dd = state.drones[droneId]
      if dd then
        dd.busy = nil
      end
      return
    end
  end
end

local function handle(id, msg)
  if type(msg) ~= "table" or msg.p ~= PROTOCOL then
    return
  end
  local payload = msg.d or {}
  local d = upsertDrone(id, payload)
  if msg.k == "register" then
    log("register drone=" .. tostring(id) .. " mapCells=" .. tostring(mapCountKnown()))
    send(id, "register_ack", {
      ok = true,
      canonPos = d.canon,
      base = {x = 0, y = 0, z = 0},
      logistics = state.logistics,
    })
    return
  end
  if msg.k == "heartbeat" then
    send(id, "heartbeat_ack", {ok = true, canonPos = d.canon, drift = d.drift or 0, logistics = state.logistics})
    if (d.fuel or 0) < MIN_FUEL then
      enqueue("refuel", {}, 99, nil)
    end
    return
  end
  if msg.k == "map" then
    local n = applyMapDelta(payload.delta)
    send(id, "map_ack", {ok = true, stored = n, knownCells = mapCountKnown()})
    return
  end
  if msg.k == "need_task" then
    local t = pickTask({id = id})
    if not t then
      log("no_task_for drone=" .. tostring(id))
    end
    send(id, "task", {task = t, canonPos = d.canon})
    return
  end
  if msg.k == "done" then
    markTaskDone(payload.taskId, id)
    send(id, "done_ack", {ok = true})
    return
  end
  if msg.k == "fail" then
    markTaskFail(payload.taskId, id, payload.reason)
    send(id, "fail_ack", {ok = true})
  end
end

if not openModem() then
  error("No modem")
end
loadState()
sanitizeTaskPayloads()
rednet.host(PROTOCOL, "central")
log("Swarm central online mapCells=" .. tostring(mapCountKnown()))
local lastTick = os.clock()
local lastSave = os.clock()
while true do
  local mid, msg = rednet.receive(PROTOCOL, 0.2)
  if mid then
    handle(mid, msg)
  end
  local eid, ping = rednet.receive("swarm.min.discovery", 0)
  if eid and ping == "who_is_central" then
    rednet.send(eid, "central_here", "swarm.min.discovery")
  end
  if os.clock() - lastTick > 1 then
    recoverOffline()
    if os.clock() - (state.planner.lastPlan or 0) > PLAN_INTERVAL then
      planTick()
      state.planner.lastPlan = os.clock()
    end
    lastTick = os.clock()
  end
  if os.clock() - lastSave > SAVE_INTERVAL then
    saveState()
    lastSave = os.clock()
  end
end
