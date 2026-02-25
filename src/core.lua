local PWB = PizzaWorldBuffs
PWB.core = {}

setfenv(1, PWB:GetEnv())

local BUFF_CD_HOURS = 2

-- Encode the provided timer as a string that can be shared with other addon users.
--
-- Encoded timer format:
--   FACTION-BOSS-HH-MM-WITNESS
--
--   FACTION    'A' for Alliance or 'H' for Horde
--   BOSS       'O' for Onyxia or 'N' for Nefarian
--   TIME       The server time at which the head will go down again, in HH-MM format
--   WITNESS    Name of the player who originally witnessed the buff
--
-- Example:
--   A-O-16-37-Pizzahawaii
function PWB.core.encode(faction, boss, h, m, witness, witnessServerH, witnessServerM)
  if not faction or not boss or not h or not m or not witness then return end
  if witnessServerH and witnessServerM then
    return string.format('%s-%s-%.2d-%.2d-%s-%.2d-%.2d', faction, boss, h, m, witness, witnessServerH, witnessServerM)
  else
    -- Backward compatibility: old format without server time
    return string.format('%s-%s-%.2d-%.2d-%s', faction, boss, h, m, witness)
  end
end

-- Encode all of our timers as strings, separated by semicolon.
function PWB.core.encodeAll()
  local timersStr
  for _, timers in pairs(PWB_timers) do
    for _, timer in pairs(timers) do
      local faction, boss, h, m, witness = timer.faction, timer.boss, timer.h, timer.m, timer.witness
      -- When sharing, send our CURRENT server time (login + elapsed), not the witness time
      -- This allows receivers to compare their current time with ours
      local currentServerH, currentServerM = PWB.utils.getServerTime()
      local encoded = PWB.core.encode(faction, boss, h, m, witness, currentServerH, currentServerM)
      if PWB_config and PWB_config.log then
        if currentServerH and currentServerM then
          PWB:Print('Encoding timer with current server time: ' .. encoded)
        else
          PWB:Print('Encoding timer WITHOUT server time (old format): ' .. encoded)
        end
      end
      timersStr = (timersStr and timersStr .. ';' or '') .. encoded
    end
  end
  return timersStr
end

-- Decode the provided timer string into a timer table.
-- Supports both new format (with server time) and old format (without server time) for backward compatibility.
function PWB.core.decode(timerStr)
  -- Try new format first: FACTION-BOSS-HH-MM-WITNESS-WITNESSSERVERH-WITNESSSERVERM
  local _, _, faction, boss, hStr, mStr, witness, witnessServerHStr, witnessServerMStr = string.find(timerStr, '(.*)%-(.*)%-(.*)%-(.*)%-(.*)%-(.*)%-(.*)')
  if faction and boss and hStr and mStr and witness and witnessServerHStr and witnessServerMStr then
    return faction, boss, tonumber(hStr), tonumber(mStr), witness, tonumber(witnessServerHStr), tonumber(witnessServerMStr)
  end
  
  -- Fall back to old format: FACTION-BOSS-HH-MM-WITNESS
  local _, _, faction, boss, hStr, mStr, witness = string.find(timerStr, '(.*)%-(.*)%-(.*)%-(.*)%-(.*)')
  if faction and boss and hStr and mStr and witness then
    return faction, boss, tonumber(hStr), tonumber(mStr), witness, nil, nil
  end
  
  return nil, nil, nil, nil, nil, nil, nil
end
-- LOCATION-SECONDSAGO-WITNESS
function PWB.core.encodeDmf()
  if not PWB_dmf or not PWB_dmf.location or not PWB_dmf.seenAt or not PWB_dmf.witness then
    return
  end

  local secondsAgo = math.floor(time() - PWB_dmf.seenAt)
  return string.format('%s-%d-%s', PWB_dmf.location, secondsAgo, PWB_dmf.witness)
end

function PWB.core.decodeDmf(dmfStr)
  local _, _, location, secondsAgoStr, witness = string.find(dmfStr, '(.*)%-(.*)%-(.*)')
  local seenAt = time() - tonumber(secondsAgoStr)
  return location, seenAt, witness
end

-- Generate a time table representing the duration from now until the provided
-- timer will run out.
function PWB.core.getTimeLeft(h, m)
  local sh, sm = PWB.utils.getServerTime()

  if sh > h and h < BUFF_CD_HOURS then
    -- now is before and deadline is after midnight. Let's just fix the diff
    -- calculation by adding 24 hours to the deadline time.
    h = h + 24
  end

  local diff = PWB.utils.toMinutes(h, m) - PWB.utils.toMinutes(sh, sm)

  local isExpired = diff < 0
  local isInvalid = diff > BUFF_CD_HOURS * 60
  if isExpired or isInvalid then return end

  return PWB.utils.toTime(diff)
end

-- Check if the provided timer is valid. A timer is only valid if all of the following
-- conditions apply:
--
--   1. The timer is less than 2 hours in the future.
--   2. The timer has not expired, i.e. it's not in the past.
--   3. We received/stored the timer no more than 2 hours ago.
function PWB.core.isValid(h, m, acceptedAt)
  local now = time()
  local twoHours = 2 * 60 * 60

  -- Mark timer as invalid if we accepted/stored it more than 2 hours ago. This prevents an
  -- issue that's due to the timers containing only the time, not the date. Without this, if
  -- you log off at e.g. 7 pm with 1 hour left on Ony buff and then log back in the next day
  -- at 7 pm, the addon will just resume the old timer because it doesn't know it's from
  -- the day before.
  if not acceptedAt or acceptedAt > now or acceptedAt < now - twoHours then
    return false
  end

  return PWB.core.getTimeLeft(h, m) ~= nil
end

-- These are the NPC yell triggers we use to detect that one of the buffs has dropped.
local yellTriggers = {
  A = {
    O = T['YELL_TRIGGER_ALLIANCE_ONYXIA'],
    N = T['YELL_TRIGGER_ALLIANCE_NEFARIAN'],
  },
  H = {
    O = T['YELL_TRIGGER_HORDE_ONYXIA'],
    N = T['YELL_TRIGGER_HORDE_NEFARIAN'],
  },
}

-- Given an NPC's yell message, check if it's one of the triggers for a buff being dropped.
-- If yes, return the boss and faction. Otherwise, return nil.
function PWB.core.parseMonsterYell(yellMsg)
  for faction, bossTriggers in pairs(yellTriggers) do
    for boss, yellTrigger in pairs(bossTriggers) do
      local found = string.find(yellMsg, yellTrigger)
      if found then
        return boss, faction
      end
    end
  end
end

function PWB.core.setDmfLocation(location, seenAt, witness)
  _G.PWB_dmf = {
    location = location,
    seenAt = seenAt,
    witness = witness,
  }
end

-- Get our current timer for the provided faction and boss.
function PWB.core.getTimer(faction, boss)
  return PWB_timers[faction][boss]
end

-- Store the provided timer locally.
function PWB.core.setTimer(faction, boss, h, m, witness, receivedFrom)
  _G.PWB_timers[faction][boss] = {
    faction = faction,
    boss = boss,
    h = h,
    m = m,
    witness = witness,
    receivedFrom = receivedFrom,
    acceptedAt = time(),
  }
end

-- Remove the provided timer from our local timer store.
function PWB.core.clearTimer(timer)
  _G.PWB_timers[timer.faction][timer.boss] = nil
end

-- Clear all invalid timers from our local timer store.
function PWB.core.clearExpiredTimers()
  -- Initialize timers if they somehow haven't been initialized yet
  if not PWB_timers then PWB.core.clearAllTimers() end

  PWB.utils.forEachTimer(function (timer)
    if not PWB.core.isValid(timer.h, timer.m, timer.acceptedAt) then
      PWB.core.clearTimer(timer)
    end
  end)
end

-- Clear all local timers, even valid ones.
function PWB.core.clearAllTimers()
  _G.PWB_timers = {
    A = {},
    H = {},
  }
end

-- Check if the provided timer should be accepted and stored locally.
function PWB.core.shouldAcceptNewTimer(faction, boss, h, m, witness, receivedFrom)
  local currentTimer = PWB.core.getTimer(faction, boss)

  -- Never accept invalid or expired timers
  if not PWB.core.isValid(h, m, time()) then return false end

  -- Always accept if we currently don't have a timer for this buff
  if not currentTimer then return true end

  -- Always accept if current timer is expired or invalid
  if not PWB.core.isValid(currentTimer.h, currentTimer.m, currentTimer.acceptedAt) then return true end

  -- Always accept new timers that we witnessed ourselves
  if witness == PWB.me then return true end

  -- Never accept other peoples' timers if we currently have a timer that we witnessed ourselves
  if currentTimer.witness == PWB.me then return false end

  -- Otherwise, only accept if the new timer came from a direct witness and our current one didn't
  return receivedFrom == witness and currentTimer.receivedFrom ~= currentTimer.witness
end

local sevenDays = 7 * 24 * 60 * 60
function PWB.core.shouldAcceptDmfLocation(seenAt, remoteVersion)
  -- Don't accept any DMF locations from pre-1.4.1 versions. Version 1.4.0 had a bug because it
  -- also detected DMF when mouseover target was Darkmoon Faire Carnie. These are there even on
  -- Wednesdays when DMF is paused.
  if remoteVersion and remoteVersion < 10401 then return false end

  -- Don't accept any DMF locations older than 7 days.
  if seenAt < (time() - sevenDays) then return false end

  -- Accept any reasonably up-to-date DMF location if we don't have any.
  if not PWB.utils.hasDmf() then return true end

  -- Always accept the most recent DMF location.
  return seenAt > PWB_dmf.seenAt
end

-- Reset the publish delay that we will count down from before we publish our local timers.
function PWB.core.resetPublishDelay()
  local min, max = 10, 60

  -- (Re)set our own publish delay to a random number of seconds.
  local delay = math.random(min, max)
  PWB.nextPublishAt = time() + delay
end

-- Check if we should publish our local data.
function PWB.core.shouldPublish()
  return PWB.nextPublishAt and time() > PWB.nextPublishAt
end

function PWB.core.publishAll()
  PWB.core.publishDmfLocation()
  PWB.core.publishTimers()
  if PWB.tents and PWB.tents.publish then
    PWB.tents.publish()
  end

  PWB.core.resetPublishDelay()
end

-- Publish our local timers by sending them to the hidden PWB chat channel.
--
-- Message format:
--   PizzaWorldBuffs:VERSION:TIMER;TIMER;TIMER;...
-- 
--   VERSION    Our own version of the addon as a single number
--   TIMER      A single encoded timer; see PWB.core.encode() for details
--
-- Example:
--   PizzaWorldBuffs:1337:A-O-13-37-Pizzahawaii;H-N-14-44-Someotherdude
function PWB.core.publishTimers()
  -- Always clear all expired timers (again) right before publishing to make sure we never share
  -- outdated timers.
  PWB.core.clearExpiredTimers()

  if not PWB.utils.hasTimers() or UnitLevel('player') < 5 then
    return
  end

  local pwbChannel = GetChannelName(PWB.channelName)
  if pwbChannel ~= 0 then
    SendChatMessage(PWB.abbrev .. ':' .. PWB.utils.getVersionNumber() .. ':' .. PWB.core.encodeAll(), 'CHANNEL', nil, pwbChannel)
  end
end

function PWB.core.publishDmfLocation()
  if PWB_dmf == nil then
    return
  end

  if not PWB.utils.hasDmf() or UnitLevel('player') < 5 then
    return
  end

  local pwbChannel = GetChannelName(PWB.channelName)
  if pwbChannel ~= 0 then
    SendChatMessage(PWB.abbrevDmf .. ':' .. PWB.utils.getVersionNumber() .. ':' .. PWB.core.encodeDmf(), 'CHANNEL', nil, pwbChannel)
  end
end

