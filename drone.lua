local PROTOCOL = "swarm.min.v1"
local CHUNK = 16
local MIN_CHUNK = -1
local MAX_CHUNK = 1
local FUEL_RETURN = 160
local MIN_FUEL_REFUEL = 120

local stateFile = "swarm_state.db"
local state = {server = nil, task = nil, pos = {x = 0, y = 0, z = 0, dir = 0}, hbTick = 0}
local protectedFragments = {
  "computercraft:computer",
  "computercraft:turtle",
  "computercraft:disk_drive",
  "computercraft:monitor",
  "computercraft:cable",
  "computercraft:modem",
  "minecraft:chest",
  "minecraft:barrel",
  "minecraft:furnace",
  "minecraft:blast_furnace",
  "minecraft:smoker",
}

local function log(msg)
  print(("[DRONE #%d] %s"):format(os.getComputerID(), msg))
end

local recipes = {
  furnace = {
    [1] = "minecraft:cobblestone", [2] = "minecraft:cobblestone", [3] = "minecraft:cobblestone",
    [4] = "minecraft:cobblestone", [6] = "minecraft:cobblestone",
    [7] = "minecraft:cobblestone", [8] = "minecraft:cobblestone", [9] = "minecraft:cobblestone",
  },
  disk = {[1] = "minecraft:redstone", [2] = "minecraft:paper", [3] = "minecraft:redstone"},
  disk_drive = {[1] = "minecraft:stone",[2] = "minecraft:stone",[3] = "minecraft:stone",[4] = "minecraft:stone",[5] = "minecraft:redstone",[6] = "minecraft:stone",[7] = "minecraft:stone",[8] = "minecraft:iron_ingot",[9] = "minecraft:stone"},
  wireless_modem_normal = {[1] = "minecraft:stone",[2] = "minecraft:stone",[3] = "minecraft:stone",[4] = "minecraft:stone",[5] = "minecraft:ender_pearl",[6] = "minecraft:stone",[7] = "minecraft:stone",[8] = "minecraft:stone",[9] = "minecraft:stone"},
  computer_advanced = {[1] = "minecraft:gold_ingot",[2] = "minecraft:gold_ingot",[3] = "minecraft:gold_ingot",[4] = "minecraft:gold_ingot",[5] = "minecraft:redstone",[6] = "minecraft:gold_ingot",[7] = "minecraft:gold_ingot",[8] = "minecraft:glass_pane",[9] = "minecraft:gold_ingot"},
  turtle_advanced = {[1] = "minecraft:gold_ingot",[2] = "minecraft:gold_ingot",[3] = "minecraft:gold_ingot",[4] = "minecraft:gold_ingot",[5] = "computercraft:computer_advanced",[6] = "minecraft:gold_ingot",[7] = "minecraft:gold_ingot",[8] = "minecraft:chest",[9] = "minecraft:gold_ingot"},
}

local function save()
  local h = fs.open(stateFile, "w")
  h.write(textutils.serialize(state))
  h.close()
end

local function load()
  if not fs.exists(stateFile) then return end
  local h = fs.open(stateFile, "r")
  local d = textutils.unserialize(h.readAll())
  h.close()
  if type(d) == "table" then state = d end
end

local function openModem()
  local sides = {"top","bottom","left","right","front","back"}
  for _, s in ipairs(sides) do
    if peripheral.getType(s) == "modem" then
      rednet.open(s)
      return true
    end
  end
  return false
end

local function inBounds()
  local cx = math.floor(state.pos.x / CHUNK)
  local cz = math.floor(state.pos.z / CHUNK)
  return cx >= MIN_CHUNK and cx <= MAX_CHUNK and cz >= MIN_CHUNK and cz <= MAX_CHUNK
end

local function send(kind, data)
  if not state.server then return end
  rednet.send(state.server, {p = PROTOCOL, k = kind, d = data or {}, ts = os.epoch("utc")}, PROTOCOL)
end

local function recv(timeout)
  local id, msg = rednet.receive(PROTOCOL, timeout)
  if type(msg) ~= "table" or msg.p ~= PROTOCOL then return nil end
  return id, msg
end

local function computeCapabilities()
  local c = {craft = false, mine = true, farm = true}
  local lbl = string.lower(tostring(os.getComputerLabel() or ""))
  if fs.exists("crafter") or string.find(lbl, "craft", 1, true) or string.find(lbl, "крафт", 1, true) then
    c.craft = true
  end
  return c
end

local function discover()
  if state.server then return state.server end
  local ids = {rednet.lookup(PROTOCOL)}
  if #ids > 0 then
    state.server = ids[1]
    log("discovered central via lookup id=" .. tostring(state.server))
    return state.server
  end
  log("broadcast discovery")
  rednet.broadcast("who_is_central", "swarm.min.discovery")
  local id, msg = rednet.receive("swarm.min.discovery", 1.5)
  if id and msg == "central_here" then
    state.server = id
    log("discovered central via broadcast id=" .. tostring(state.server))
  end
  return state.server
end

local function turnRight()
  turtle.turnRight()
  state.pos.dir = (state.pos.dir + 1) % 4
  save()
end

local function turnLeft()
  turtle.turnLeft()
  state.pos.dir = (state.pos.dir + 3) % 4
  save()
end

local function faceDir(want)
  local s = 0
  while state.pos.dir ~= want and s < 8 do
    turnRight()
    s = s + 1
  end
end

local function updateForward(sign)
  if state.pos.dir == 0 then state.pos.z = state.pos.z - sign end
  if state.pos.dir == 1 then state.pos.x = state.pos.x + sign end
  if state.pos.dir == 2 then state.pos.z = state.pos.z + sign end
  if state.pos.dir == 3 then state.pos.x = state.pos.x - sign end
end

local function isProtectedName(name)
  if not name then return false end
  for _, f in ipairs(protectedFragments) do
    if string.find(name, f, 1, true) then
      return true
    end
  end
  return false
end

local function inspectFront()
  local ok, data = turtle.inspect()
  if not ok then return nil end
  return data and data.name
end

local function inspectDown()
  local ok, data = turtle.inspectDown()
  if not ok then return nil end
  return data and data.name
end

local function frontOffset()
  if state.pos.dir == 0 then return 0, 0, -1 end
  if state.pos.dir == 1 then return 1, 0, 0 end
  if state.pos.dir == 2 then return 0, 0, 1 end
  return -1, 0, 0
end

local function posEquals(a, b)
  if not a or not b then return false end
  return (a.x or 0) == (b.x or 0) and (a.y or 0) == (b.y or 0) and (a.z or 0) == (b.z or 0) and (a.dir or 0) == (b.dir or 0)
end

local function applyCanonical(canon)
  if not canon then return end
  if not posEquals(state.pos, canon) then
    log("sync pos from central")
    state.pos = {x = canon.x or 0, y = canon.y or 0, z = canon.z or 0, dir = canon.dir or 0}
    save()
  end
end

local function safeDigFront()
  local name = inspectFront()
  if not name then return true end
  if isProtectedName(name) then
    log("protected front block=" .. name)
    return false, "protected_front:" .. name
  end
  turtle.dig()
  return true
end

local function safeDigUp()
  local ok, data = turtle.inspectUp()
  if not ok then return true end
  local name = data and data.name
  if isProtectedName(name) then
    return false, "protected_up:" .. tostring(name)
  end
  turtle.digUp()
  return true
end

local function safeDigDown()
  local name = inspectDown()
  if not name then return true end
  if isProtectedName(name) then
    return false, "protected_down:" .. name
  end
  turtle.digDown()
  return true
end

local function forward()
  if turtle.detect() then
    local ok, err = safeDigFront()
    if not ok then return false, err end
  end
  if turtle.forward() then
    updateForward(1)
    if not inBounds() then
      turtle.back()
      updateForward(-1)
      save()
      return false, "chunk_limit"
    end
    save()
    return true
  end
  return false, "blocked"
end

local function up()
  if turtle.detectUp() then
    local ok, err = safeDigUp()
    if not ok then return false, err end
  end
  if turtle.up() then state.pos.y = state.pos.y + 1 save() return true end
  return false
end

local function down()
  if turtle.detectDown() then
    local ok, err = safeDigDown()
    if not ok then return false, err end
  end
  if turtle.down() then state.pos.y = state.pos.y - 1 save() return true end
  return false
end

local function goHome()
  while state.pos.y > 0 do
    if not down() then break end
  end
  while state.pos.y < 0 do
    if not up() then break end
  end
  while state.pos.x ~= 0 do
    if state.pos.x > 0 then faceDir(3) else faceDir(1) end
    forward()
  end
  while state.pos.z ~= 0 do
    if state.pos.z > 0 then faceDir(0) else faceDir(2) end
    forward()
  end
end

local function mapDeltaAtFoot()
  local d = {}
  local px, py, pz = state.pos.x, state.pos.y, state.pos.z
  d[#d + 1] = {x = px, y = py, z = pz, t = "air"}
  local saved = state.pos.dir
  for i = 0, 3 do
    faceDir(i)
    local fn = inspectFront()
    if fn then
      local ox, oy, oz = frontOffset()
      d[#d + 1] = {x = px + ox, y = py + oy, z = pz + oz, t = fn}
    end
  end
  faceDir(saved)
  local uok, udat = turtle.inspectUp()
  if uok and udat and udat.name then
    d[#d + 1] = {x = px, y = py + 1, z = pz, t = udat.name}
  end
  local dn = inspectDown()
  if dn then
    d[#d + 1] = {x = px, y = py - 1, z = pz, t = dn}
  end
  return d
end

local function mapVerticalSteps(upMax, downMax)
  local acc = {}
  local y0 = state.pos.y
  local function merge(t)
    for _, v in ipairs(t) do
      acc[#acc + 1] = v
    end
  end
  merge(mapDeltaAtFoot())
  for _ = 1, upMax do
    if turtle.detectUp() then
      break
    end
    if not turtle.up() then
      break
    end
    state.pos.y = state.pos.y + 1
    merge(mapDeltaAtFoot())
  end
  while state.pos.y > y0 do
    if not turtle.down() then
      break
    end
    state.pos.y = state.pos.y - 1
  end
  for _ = 1, downMax do
    if turtle.detectDown() then
      break
    end
    if not turtle.down() then
      break
    end
    state.pos.y = state.pos.y - 1
    merge(mapDeltaAtFoot())
  end
  while state.pos.y < y0 do
    if not turtle.up() then
      break
    end
    state.pos.y = state.pos.y + 1
  end
  save()
  return acc
end

local function mapDelta()
  if (state.hbTick or 0) % 3 ~= 0 then
    return mapDeltaAtFoot()
  end
  return mapVerticalSteps(12, 4)
end

local function walkToXZ(tx, tz)
  local guard = 0
  while (state.pos.x ~= tx or state.pos.z ~= tz) and guard < 800 do
    guard = guard + 1
    if state.pos.x < tx then faceDir(1)
    elseif state.pos.x > tx then faceDir(3)
    elseif state.pos.z < tz then faceDir(2)
    elseif state.pos.z > tz then faceDir(0)
    end
    local ok, err = forward()
    if not ok then return false, err end
  end
  if state.pos.x ~= tx or state.pos.z ~= tz then
    return false, "walk_timeout"
  end
  return true
end

local function countSaplingsInv()
  local n = 0
  for i = 1, 16 do
    local d = turtle.getItemDetail(i)
    if d and string.find(d.name, "sapling", 1, true) then
      n = n + d.count
    end
  end
  return n
end

local function ensureSaplingsFromChest(need)
  while countSaplingsInv() < need do
    local chest, err = scanChest()
    if not chest then
      return false, err
    end
    local pick = nil
    for name, c in pairs(chest) do
      if string.find(name, "sapling", 1, true) and (c or 0) > 0 then
        pick = name
        break
      end
    end
    if not pick then
      return false, "no_sapling_in_chest"
    end
    local ok, e = ensureItemsFromChest({[pick] = 1})
    if not ok then
      return false, e
    end
  end
  return true
end

local function clearTreeColumn(gx, gz)
  local wok, werr = walkToXZ(gx, gz)
  if not wok then
    return false, werr
  end
  local guard = 0
  while guard < 36 do
    guard = guard + 1
    if turtle.detect() then
      local fn = inspectFront()
      if fn and isProtectedName(fn) then
        break
      end
      turtle.dig()
    elseif turtle.detectUp() then
      local uok, udat = turtle.inspectUp()
      local un = udat and udat.name
      if un and isProtectedName(un) then
        break
      end
      local dg, de = safeDigUp()
      if not dg then
        return false, de
      end
      if not up() then
        break
      end
      if turtle.detect() then
        local f2 = inspectFront()
        if f2 and not isProtectedName(f2) then
          turtle.dig()
        end
      end
    else
      break
    end
  end
  while state.pos.y > 0 do
    if not down() then
      break
    end
  end
  if turtle.detectDown() then
    local dn = inspectDown()
    if dn and not isProtectedName(dn) and not string.find(dn, "dirt", 1, true) and not string.find(dn, "grass", 1, true) and not string.find(dn, "farmland", 1, true) then
      local dd, de = safeDigDown()
      if not dd then
        return false, de
      end
    end
  end
  return true
end

local function tillAndPlantAt(gx, gz)
  local w0, e0 = walkToXZ(gx, gz - 1)
  if not w0 then
    return false, e0
  end
  faceDir(2)
  local fr = inspectFront()
  if fr and isProtectedName(fr) then
    return false, "protected_farm_cell"
  end
  if fr and not string.find(fr, "dirt", 1, true) and not string.find(fr, "grass", 1, true) and not string.find(fr, "farmland", 1, true) then
    local dg, de = safeDigFront()
    if not dg then
      return false, de
    end
  elseif fr and string.find(fr, "grass", 1, true) then
    local dg, de = safeDigFront()
    if not dg then
      return false, de
    end
  end
  local okd, ed = ensureItemsFromChest({["minecraft:dirt"] = 1})
  if not okd then
    return false, ed
  end
  local dirtSlot = findByFragment("dirt")
  if not dirtSlot then
    return false, "no_dirt_inv"
  end
  turtle.select(dirtSlot)
  if not turtle.place() then
    if not turtle.place() then
      return false, "dirt_place_fail"
    end
  end
  local oks, es = ensureSaplingsFromChest(1)
  if not oks then
    return false, es
  end
  local sp = findByFragment("sapling")
  if not sp then
    return false, "no_sapling_inv"
  end
  turtle.select(sp)
  if not turtle.place() then
    return false, "sapling_place_fail"
  end
  return true
end

local function taskFarmBuild(t)
  log("task farm_build")
  ensureItemsFromChest({["minecraft:coal"] = 6})
  local fc = findByFragment("coal")
  if fc then
    turtle.select(fc)
    turtle.refuel(12)
  end
  local slots = (t.payload and t.payload.slots) or {}
  if #slots == 0 then
    return false, "no_slots"
  end
  for i, slot in ipairs(slots) do
    local gx, gz = slot[1], slot[2]
    local ok, err = clearTreeColumn(gx, gz)
    if not ok then
      goHome()
      return false, err
    end
    if i % 3 == 0 then
      depositAllNonFuel()
    end
    if turtle.getFuelLevel() < FUEL_RETURN then
      goHome()
      return false, "fuel_low"
    end
  end
  depositAllNonFuel()
  for _, slot in ipairs(slots) do
    local gx, gz = slot[1], slot[2]
    local okp, errp = tillAndPlantAt(gx, gz)
    if not okp then
      goHome()
      return false, errp
    end
    if turtle.getFuelLevel() < FUEL_RETURN then
      goHome()
      return false, "fuel_low"
    end
  end
  goHome()
  depositAllNonFuel()
  return true
end

local function taskFarmCycle(t)
  log("task farm_cycle")
  ensureItemsFromChest({["minecraft:coal"] = 4})
  local fc = findByFragment("coal")
  if fc then
    turtle.select(fc)
    turtle.refuel(8)
  end
  local slots = (t.payload and t.payload.slots) or {}
  for _, slot in ipairs(slots) do
    local gx, gz = slot[1], slot[2]
    local w1, e1 = walkToXZ(gx, gz - 1)
    if not w1 then
      goHome()
      return false, e1
    end
    faceDir(2)
    if turtle.detect() then
      local fn = inspectFront()
      if fn and string.find(fn, "log", 1, true) and not isProtectedName(fn) then
        turtle.dig()
        local hg = 0
        while turtle.detectUp() and hg < 28 do
          hg = hg + 1
          local dug, derr = safeDigUp()
          if not dug then
            break
          end
          if not up() then
            break
          end
          if turtle.detect() then
            local f2 = inspectFront()
            if f2 and not isProtectedName(f2) then
              turtle.dig()
            end
          end
        end
        while state.pos.y > 0 do
          if not down() then
            break
          end
        end
      end
    end
    faceDir(2)
    if not turtle.detect() then
      local okp, errp = tillAndPlantAt(gx, gz)
      if not okp then
        log("replant skip " .. tostring(errp))
      end
    else
      local fr = inspectFront()
      if fr and string.find(fr, "sapling", 1, true) == nil and string.find(fr, "log", 1, true) == nil then
        if ensureSaplingsFromChest(1) then
          local sp = findByFragment("sapling")
          if sp then
            turtle.select(sp)
            turtle.place()
          end
        end
      end
    end
    if turtle.getFuelLevel() < FUEL_RETURN then
      goHome()
      return false, "fuel_low"
    end
  end
  goHome()
  depositAllNonFuel()
  return true
end

local function findByFragment(name)
  for i = 1, 16 do
    local d = turtle.getItemDetail(i)
    if d and string.find(d.name, name, 1, true) then return i end
  end
  return nil
end

local function findEmptySlot()
  for i = 1, 16 do
    if turtle.getItemCount(i) == 0 then return i end
  end
  return nil
end

local function countByName(name)
  local n = 0
  for i = 1, 16 do
    local d = turtle.getItemDetail(i)
    if d and d.name == name then n = n + d.count end
  end
  return n
end

local function isHomeStorageDown(name)
  if not name then
    return false
  end
  return string.find(name, "chest", 1, true) ~= nil or string.find(name, "barrel", 1, true) ~= nil
end

local function snapCkLogistics(logistics)
  if type(logistics) ~= "table" then
    return
  end
  state.ckLogistics = state.ckLogistics or {}
  if logistics.homeTurtleStandWorld then
    state.ckLogistics.homeTurtleStandWorld = logistics.homeTurtleStandWorld
  end
  if logistics.homeChestWorld then
    state.ckLogistics.homeChestWorld = logistics.homeChestWorld
  end
  if logistics.centralWorld then
    state.ckLogistics.centralWorld = logistics.centralWorld
  end
end

local function walkGpsToward(tx, ty, tz, maxSteps)
  maxSteps = maxSteps or 512
  for _ = 1, maxSteps do
    local gx, gy, gz = gps.locate(2, false)
    if not gx then
      return false
    end
    if gx == tx and gy == ty and gz == tz then
      return true
    end
    if gx < tx then
      faceDir(1)
      local ok = forward()
      if not ok then return false end
    elseif gx > tx then
      faceDir(3)
      local ok = forward()
      if not ok then return false end
    elseif gz < tz then
      faceDir(2)
      local ok = forward()
      if not ok then return false end
    elseif gz > tz then
      faceDir(0)
      local ok = forward()
      if not ok then return false end
    elseif gy < ty then
      if not up() then return false end
    elseif gy > ty then
      if not down() then return false end
    else
      return false
    end
  end
  return false
end

local function ensureHomeChestAccessible()
  goHome()
  local block = inspectDown()
  if block and isHomeStorageDown(block) then
    return true
  end
  local tw = state.ckLogistics and state.ckLogistics.homeTurtleStandWorld
  if not tw or tw.x == nil or tw.y == nil or tw.z == nil then
    return false
  end
  if not walkGpsToward(tw.x, tw.y, tw.z, 512) then
    return false
  end
  state.pos.x = 0
  state.pos.y = 0
  state.pos.z = 0
  save()
  block = inspectDown()
  return block and isHomeStorageDown(block)
end

local function cloneChestList(list)
  if not list then
    return nil
  end
  local out = {}
  for k, item in pairs(list) do
    if item and item.name then
      out[k] = {name = item.name, count = item.count or 0}
    end
  end
  return out
end

local function getChestSnapshot()
  if not ensureHomeChestAccessible() then
    return nil, nil, "home_chest_missing"
  end
  local block = inspectDown()
  if not block or not isHomeStorageDown(block) then
    return nil, nil, "home_chest_missing"
  end
  local inv = peripheral.wrap("bottom")
  if not inv or type(inv.list) ~= "function" then
    return nil, nil, "home_chest_no_inventory_api"
  end
  local list = inv.list()
  local summary = {}
  local totalStacks = 0
  local totalItems = 0
  for _, item in pairs(list) do
    totalStacks = totalStacks + 1
    totalItems = totalItems + (item.count or 0)
    summary[item.name] = (summary[item.name] or 0) + item.count
  end
  log("chest_scan stacks=" .. tostring(totalStacks) .. " items=" .. tostring(totalItems))
  return summary, cloneChestList(list)
end

local function scanChest()
  local s, _, err = getChestSnapshot()
  if err then
    return nil, err
  end
  return s
end

local function pushChestToCentral()
  local sum, slots, err = getChestSnapshot()
  if err then
    log("chest_push skip " .. tostring(err))
    return
  end
  send("chest_scan", {summary = sum, slots = slots})
end

local function findSlotForPull(name)
  for i = 1, 16 do
    local d = turtle.getItemDetail(i)
    if d and d.name == name and turtle.getItemCount(i) < 64 then
      return i
    end
  end
  return findEmptySlot()
end

local function transferNamedFromChest(name, needMore)
  if not ensureHomeChestAccessible() then
    return false
  end
  if needMore <= 0 then
    return true
  end
  local inv = peripheral.wrap("bottom")
  if not inv or type(inv.list) ~= "function" then
    return false
  end
  local list = inv.list()
  for slot, stack in pairs(list) do
    if stack and stack.name == name then
      local pull = math.min(needMore, stack.count)
      if type(inv.pushItems) == "function" then
        local ok, moved = pcall(function()
          return inv.pushItems("up", slot, pull)
        end)
        if ok and type(moved) == "number" and moved > 0 then
          return true
        end
        local dest = findSlotForPull(name)
        if dest then
          ok, moved = pcall(function()
            return inv.pushItems("up", slot, pull, dest)
          end)
          if ok and type(moved) == "number" and moved > 0 then
            return true
          end
        end
      end
      local dest = findSlotForPull(name)
      if not dest then
        return false
      end
      turtle.select(dest)
      return turtle.suckDown(pull)
    end
  end
  return false
end

local function ensureItemsFromChest(req)
  local chest, err = scanChest()
  if not chest then
    return false, err
  end
  for name, needed in pairs(req) do
    local have0 = countByName(name)
    if have0 < needed and (chest[name] or 0) < needed - have0 then
      return false, "missing_in_chest:" .. name
    end
    local tries = 0
    while countByName(name) < needed and tries < 96 do
      tries = tries + 1
      local have = countByName(name)
      if not transferNamedFromChest(name, needed - have) then
        return false, "cannot_pull_required:" .. name
      end
    end
    if countByName(name) < needed then
      return false, "cannot_pull_required:" .. name
    end
  end
  return true
end

local function moveItem(name, slot)
  if turtle.getItemCount(slot) > 0 then turtle.select(slot) turtle.dropDown() end
  for i = 1, 16 do
    local d = turtle.getItemDetail(i)
    if d and d.name == name and i ~= slot then
      turtle.select(i)
      turtle.transferTo(slot, 1)
      return true
    end
  end
  return false
end

local function craft(name)
  local r = recipes[name]
  if not r then return false, "recipe_missing" end
  local req = {}
  for i = 1, 9 do
    if r[i] then req[r[i]] = (req[r[i]] or 0) + 1 end
  end
  local okReq, reqErr = ensureItemsFromChest(req)
  if not okReq then
    return false, reqErr
  end
  for i = 1, 9 do
    if turtle.getItemCount(i) > 0 then turtle.select(i) turtle.dropDown() end
  end
  for i = 1, 9 do
    local item = r[i]
    if item and not moveItem(item, i) then return false, "missing_" .. item end
  end
  turtle.select(1)
  if turtle.craft() then return true end
  return false, "craft_failed"
end

local function consolidateStacks()
  for _ = 1, 2 do
    for dest = 1, 16 do
      if turtle.getItemCount(dest) > 0 then
        local dd = turtle.getItemDetail(dest)
        if dd then
          for src = 1, 16 do
            if src ~= dest and turtle.getItemCount(src) > 0 then
              local sd = turtle.getItemDetail(src)
              if sd and sd.name == dd.name then
                turtle.select(src)
                turtle.transferTo(dest)
              end
            end
          end
        end
      end
    end
  end
end

local function depositAllNonFuel()
  if not ensureHomeChestAccessible() then
    log("deposit skip no home chest")
    return
  end
  consolidateStacks()
  for i = 1, 16 do
    local d = turtle.getItemDetail(i)
    if d and not string.find(d.name, "coal", 1, true) and not string.find(d.name, "charcoal", 1, true) then
      turtle.select(i)
      turtle.dropDown()
    end
  end
end

local function taskMine(t)
  log("task mine")
  ensureItemsFromChest({["minecraft:coal"] = 2})
  local coal = findByFragment("coal")
  if coal then turtle.select(coal) turtle.refuel(1) end
  local steps = (t.payload and t.payload.steps) or 8
  for i = 1, steps do
    local ok, err = forward()
    if not ok then goHome() return false, err end
    if turtle.detectDown() then
      local digOk, digErr = safeDigDown()
      if not digOk then goHome() return false, digErr end
    end
    if i % 2 == 0 and state.server then
      send("map", {delta = mapDeltaAtFoot(), by = os.getComputerID()})
    end
    if turtle.getFuelLevel() < FUEL_RETURN then goHome() return false, "fuel_low" end
  end
  depositAllNonFuel()
  return true
end

local function taskMineCobble(t)
  log("task mine_cobble")
  ensureItemsFromChest({["minecraft:coal"] = 2})
  local c = findByFragment("coal")
  if c then turtle.select(c) turtle.refuel(1) end
  local gx = (t.payload and t.payload.gateX) or -2
  local wok, werr = walkToXZ(gx, 0)
  if not wok then goHome() return false, werr end
  local steps = (t.payload and t.payload.steps) or 10
  for i = 1, steps do
    local ok, err = forward()
    if not ok then goHome() return false, err end
    if turtle.detectDown() then
      local digOk, digErr = safeDigDown()
      if not digOk then goHome() return false, digErr end
    end
    if i % 2 == 0 and state.server then
      send("map", {delta = mapDeltaAtFoot(), by = os.getComputerID()})
    end
    if turtle.getFuelLevel() < FUEL_RETURN then goHome() return false, "fuel_low" end
  end
  depositAllNonFuel()
  return true
end

local function taskExplore(t)
  log("task explore")
  local pd = t.payload or {}
  local steps = pd.steps or 6
  local pref = pd.preferDir or 0
  faceDir(pref % 4)
  for i = 1, steps do
    local ok, err = forward()
    if not ok then goHome() return false, err end
    if state.server and (i % 2 == 0 or i == steps) then
      send("map", {delta = mapVerticalSteps(8, 2), by = os.getComputerID()})
    end
  end
  goHome()
  return true
end

local function taskSurvey(t)
  log("task survey")
  pushChestToCentral()
  local pd = t.payload or {}
  local steps = pd.steps or 16
  local pref = pd.preferDir or 0
  faceDir(pref % 4)
  for i = 1, steps do
    local ok, err = forward()
    if not ok then
      break
    end
    if state.server and (i % 2 == 0 or i == steps) then
      send("map", {delta = mapVerticalSteps(12, 3), by = os.getComputerID()})
    end
  end
  goHome()
  pushChestToCentral()
  return true
end

local function taskReplant()
  log("task farm_replant")
  goHome()
  for _ = 1, 4 do forward() end
  turnRight()
  for _ = 1, 4 do forward() end
  ensureItemsFromChest({["minecraft:dirt"] = 1})
  if not turtle.detectDown() then
    local dirt = findByFragment("dirt")
    if dirt then turtle.select(dirt) turtle.placeDown() end
  end
  ensureItemsFromChest({["minecraft:oak_sapling"] = 1})
  local sap = findByFragment("sapling")
  if sap then turtle.select(sap) if not turtle.detect() then turtle.place() end end
  goHome()
  return true
end

local function taskHarvest()
  log("task farm_harvest")
  goHome()
  for _ = 1, 4 do forward() end
  turnRight()
  for _ = 1, 4 do forward() end
  if turtle.detect() then
    local nm = inspectFront()
    if nm and not isProtectedName(nm) then turtle.dig() end
    local hg = 0
    while turtle.detectUp() and hg < 24 do
      hg = hg + 1
      local dug, derr = safeDigUp()
      if not dug then break end
      if not up() then break end
      if turtle.detect() then
        local fn = inspectFront()
        if fn and not isProtectedName(fn) then turtle.dig() end
      end
    end
    while state.pos.y > 0 do
      if not down() then break end
    end
    local sap = findByFragment("sapling")
    if sap then turtle.select(sap) if not turtle.detect() then turtle.place() end end
  end
  goHome()
  return true
end

local function taskRefuel()
  log("task refuel")
  goHome()
  ensureItemsFromChest({["minecraft:coal"] = 4})
  ensureItemsFromChest({["minecraft:charcoal"] = 1})
  for i = 1, 16 do
    local d = turtle.getItemDetail(i)
    if d and (string.find(d.name, "coal", 1, true) or string.find(d.name, "charcoal", 1, true)) then
      turtle.select(i)
      turtle.refuel(turtle.getItemCount(i))
      if turtle.getFuelLevel() > 900 then return true end
    end
  end
  return turtle.getFuelLevel() > MIN_FUEL_REFUEL
end

local function taskCraft(payload)
  if not state.capabilities or not state.capabilities.craft then
    return false, "no_craft_upgrade"
  end
  local r = payload and payload.recipe
  log("task craft recipe=" .. tostring(r))
  if r == "turtle_advanced" and countByName("computercraft:computer_advanced") == 0 then
    local ok, e = craft("computer_advanced")
    if not ok then return false, e end
    depositAllNonFuel()
  end
  local ok2, e2 = craft(r)
  if not ok2 then return false, e2 end
  depositAllNonFuel()
  return true
end

local function taskSetupFurnace(t)
  log("task setup_furnace")
  local p = t.payload or {}
  local ax, az = p.ax or 1, p.az or 0
  local fx, fz = p.fx or 2, p.fz or 0
  local w1, e1 = walkToXZ(ax, az)
  if not w1 then goHome() return false, e1 end
  if fx > state.pos.x then faceDir(1) elseif fx < state.pos.x then faceDir(3) elseif fz > state.pos.z then faceDir(2) else faceDir(0) end
  local frontN = inspectFront()
  if frontN and string.find(frontN, "furnace", 1, true) then
    goHome()
    return true
  end
  local okc, ec = ensureItemsFromChest({["minecraft:cobblestone"] = 8})
  if not okc then goHome() return false, ec end
  local okf, ef = craft("furnace")
  if not okf then goHome() return false, ef end
  if turtle.detect() then
    local dg, de = safeDigFront()
    if not dg then goHome() return false, de end
  end
  local slot = findByFragment("furnace")
  if not slot then goHome() return false, "no_furnace_item" end
  turtle.select(slot)
  if not turtle.place() then goHome() return false, "place_furnace_failed" end
  goHome()
  return true
end

local function taskSmeltCharcoal(t)
  log("task smelt_charcoal")
  local p = t.payload or {}
  local ax, az = p.ax or 1, p.az or 0
  local batches = p.batches or 4
  local w1, e1 = walkToXZ(ax, az)
  if not w1 then goHome() return false, e1 end
  faceDir(1)
  local fn = inspectFront()
  if not fn or not string.find(fn, "furnace", 1, true) then
    goHome()
    return false, "no_furnace_front"
  end
  ensureItemsFromChest({["minecraft:coal"] = 1})
  local fuel = findByFragment("coal")
  if fuel then turtle.select(fuel) turtle.drop(1) end
  for _ = 1, batches do
    local okl, el = ensureItemsFromChest({["minecraft:oak_log"] = 1})
    if not okl then
      local alts = {"minecraft:spruce_log","minecraft:birch_log","minecraft:jungle_log","minecraft:acacia_log","minecraft:dark_oak_log","minecraft:mangrove_log","minecraft:cherry_log"}
      local got = false
      for _, nm in ipairs(alts) do
        local o2, _ = ensureItemsFromChest({[nm] = 1})
        if o2 then got = true break end
      end
      if not got then goHome() return false, el or "no_logs" end
    end
    local lg = findByFragment("log")
    if not lg then goHome() return false, "no_log_slot" end
    turtle.select(lg)
    turtle.drop(1)
    os.sleep(19)
    for _ = 1, 8 do
      turtle.suck()
    end
  end
  depositAllNonFuel()
  return true
end

local function taskGatherLog(t)
  log("task gather_log")
  local p = t.payload or {}
  local tx, tz = p.tx or 0, p.tz or 0
  local w1, e1 = walkToXZ(tx, tz)
  if not w1 then goHome() return false, e1 end
  local guard = 0
  while turtle.detect() and guard < 32 do
    guard = guard + 1
    local nf = inspectFront()
    if nf and string.find(nf, "log", 1, true) and not isProtectedName(nf) then
      turtle.dig()
    else
      break
    end
  end
  guard = 0
  while turtle.detectUp() and guard < 24 do
    guard = guard + 1
    local uok, udat = turtle.inspectUp()
    local un = udat and udat.name
    if un and string.find(un, "log", 1, true) and not isProtectedName(un) then
      up()
      if turtle.detect() then turtle.dig() end
    else
      break
    end
  end
  while state.pos.y > 0 do
    if state.server then
      send("map", {delta = mapDeltaAtFoot(), by = os.getComputerID()})
    end
    if not down() then break end
  end
  depositAllNonFuel()
  return true
end

local function taskBootstrap()
  if not state.capabilities or not state.capabilities.craft then
    return false, "no_craft_upgrade"
  end
  log("task bootstrap")
  local ok1 = craft("disk")
  local ok2 = craft("disk_drive")
  local ok3 = craft("turtle_advanced")
  if not ok3 then
    return false, "no_turtle_advanced"
  end
  goHome()
  for _ = 1, 2 do forward() end
  local drive = findByFragment("disk_drive")
  if drive then
    turnRight()
    if turtle.detect() then
      local digOk, digErr = safeDigFront()
      if not digOk then turnLeft() goHome() return false, digErr end
    end
    turtle.select(drive)
    turtle.place()
    local disk = findByFragment("disk")
    if disk then turtle.select(disk) turtle.drop() end
    turnLeft()
  end
  local tt = findByFragment("turtle_advanced") or findByFragment("turtle")
  if not tt then goHome() return false, "no_turtle_item" end
  if turtle.detect() then
    local digOk, digErr = safeDigFront()
    if not digOk then goHome() return false, digErr end
  end
  turtle.select(tt)
  local placed = turtle.place()
  local coal = findByFragment("coal")
  if coal then turtle.select(coal) turtle.drop(8) end
  goHome()
  return placed and ok1 and ok2
end

local function execute(task)
  if not task then sleep(1) return true, "idle" end
  if task.kind == "mine" then return taskMine(task) end
  if task.kind == "mine_cobble" then return taskMineCobble(task) end
  if task.kind == "explore" then return taskExplore(task) end
  if task.kind == "survey" then return taskSurvey(task) end
  if task.kind == "farm_build" then return taskFarmBuild(task) end
  if task.kind == "farm_cycle" then return taskFarmCycle(task) end
  if task.kind == "farm_replant" then return taskReplant() end
  if task.kind == "farm_harvest" then return taskHarvest() end
  if task.kind == "refuel" then return taskRefuel() end
  if task.kind == "craft" then return taskCraft(task.payload) end
  if task.kind == "setup_furnace" then return taskSetupFurnace(task) end
  if task.kind == "smelt_charcoal" then return taskSmeltCharcoal(task) end
  if task.kind == "gather_log" then return taskGatherLog(task) end
  if task.kind == "bootstrap" then return taskBootstrap() end
  if task.kind == "return" then goHome() return true end
  return false, "unknown_task"
end

if not openModem() then error("No modem") end
load()
state.capabilities = state.capabilities or computeCapabilities()
if not discover() then
  log("Waiting for central...")
  while not discover() do sleep(1) end
end
log("register to central id=" .. tostring(state.server))
send("register", {pos = state.pos, fuel = turtle.getFuelLevel(), anchorHome = (state.pos.x == 0 and state.pos.y == 0 and state.pos.z == 0), capabilities = state.capabilities})
local regDeadline = os.clock() + 3
while os.clock() < regDeadline do
  local rid, rmsg = recv(0.35)
  if rid and rmsg and rmsg.k == "register_ack" then
    applyCanonical(rmsg.d and rmsg.d.canonPos)
    snapCkLogistics(rmsg.d and rmsg.d.logistics)
    break
  end
end
pushChestToCentral()
local hb = 0
while true do
  if not state.server then discover() end
  if os.clock() - hb >= 3 then
    state.hbTick = (state.hbTick or 0) + 1
    local chestSum = nil
    local chestSlots = nil
    if state.hbTick % 2 == 0 then
      local s, slots, err = getChestSnapshot()
      if not err then
        chestSum = s
        chestSlots = slots
      end
    end
    log("heartbeat fuel=" .. tostring(turtle.getFuelLevel()))
    send("heartbeat", {
      pos = state.pos,
      fuel = turtle.getFuelLevel(),
      anchorHome = (state.pos.x == 0 and state.pos.y == 0 and state.pos.z == 0),
      chestSummary = chestSum,
      chestSlots = chestSlots,
      capabilities = state.capabilities,
    })
    send("map", {delta = mapDelta(), by = os.getComputerID()})
    hb = os.clock()
  end
  if not state.task then
    send("need_task", {pos = state.pos, fuel = turtle.getFuelLevel()})
  end
  local id, msg = recv(0.2)
  if id then
    state.server = id
    if msg.k == "register_ack" or msg.k == "heartbeat_ack" then
      applyCanonical(msg.d and msg.d.canonPos)
      snapCkLogistics(msg.d and msg.d.logistics)
    end
    if msg.k == "task" then
      state.task = msg.d.task
      applyCanonical(msg.d and msg.d.canonPos)
      if state.task then
        log("task " .. tostring(state.task.kind) .. " id=" .. tostring(state.task.id))
      else
        log("no task (idle)")
        sleep(0.6)
      end
    end
  end
  if state.task then
    local ok, err = execute(state.task)
    if ok then
      log("task done id=" .. tostring(state.task.id))
      send("done", {taskId = state.task.id})
    else
      log("task fail id=" .. tostring(state.task.id) .. " reason=" .. tostring(err or "err"))
      send("fail", {taskId = state.task.id, reason = err or "err"})
    end
    state.task = nil
    save()
  end
  sleep(0.1)
end
