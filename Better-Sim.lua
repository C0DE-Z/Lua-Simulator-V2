-- FPV drone simulator for OpenTX --
-- OG Author: Alexey Stankevich @AlexeyStn
-- Mod by CodeZ

local config = {
  gate = {w = 30, h = 30},
  phys = {
    dt = 0.02,
    g = 9.81,
    air = 0.98,
    maxTilt = math.rad(360),  -- Allow full rotation in ACRO
    scale = {roll = 25, pitch = 25, yaw = 5, throttle = 40, gravity = 0.4}, -- Reduced throttle scaling
    maxSpeed = 15, -- ~54 km/h max speed (more realistic)
    maxAltitude = 50,  -- Lower maximum altitude (in meters)
    minAltitude = -5,    -- Minimum altitude (slightly below ground)
    momentum = 0.85, -- Add momentum factor
    groundLevel = 0,  -- Define ground level
  },
  zStep = 1000,  -- Reduced step between gates
  zScale = 300,
  renderDist = 2000,  -- Maximum render distance
  lastFrameTime = 0,
  frameSkip = 0,  -- Current frame skip counter
  menuRefreshRate = 4,  -- Menu updates 4 times per second
  menuLastUpdate = 0,
  menuBuffer = {},      -- Cache for menu items
  display = {
    compass = {
      radius = 8,  -- Smaller compass
      y = 10,  -- Move compass up slightly
      directions = {"N", "E", "S", "W"}
    },
    ground = {
      lines = 12,        -- Increased number of lines
      spacing = 15,      -- Reduced spacing for tighter grid
      gridSize = 200,    -- Size of grid squares
      fadeStep = 0.8,    -- How quickly lines fade with distance
      gridLines = 5      -- Number of horizontal grid lines
    }
  },
}

-- Core state
local drone = {x = 0, y = 0, z = 0, roll = 0, pitch = 0, yaw = 0}
local speed = {x = 0, y = 0, z = 0}
local state = "title"
local counter = 0
local selectedOption = 1  -- Add this line
local editingValue = false  -- Add this line

-- Define activeGates before it's used
local initialGates = {
  {x = 0, y = 0, z = 500, passed = false},  -- Current gate
  {x = 0, y = 0, z = 1500, passed = false}  -- Next gate
}

local activeGates = {}  -- Will be initialized in init_func

-- Add back original options
local options = {
  {name = "Weight", value = 500, min = 100, max = 2000, step = 50},  -- In grams now
  {name = "Time", value = 30, min = 10, max = 300, step = 10},
  {name = "Mode", value = 2, min = 1, max = 3, step = 1,  -- Changed default to 2 (ANGLE)
   labels = {"ACRO", "ANGLE", "HOR"}},
  {name = "Debug", value = 0, min = 0, max = 1, step = 1,
   labels = {"OFF", "ON"}},  -- Fixed labels for binary options
  {name = "FPS Limit", value = 20, min = 10, max = 30, step = 5},  -- New FPS limit option
  {name = "Frame Skip", value = 0, min = 0, max = 2, step = 1},    -- New frame skip option
  {name = "Turn Rate", value = 100, min = 50, max = 200, step = 10},  -- Added turn rate setting
  {name = "Invert Controls", value = 0, min = 0, max = 1, step = 1, labels = {"OFF", "ON"}},  -- Fixed labels for binary options
  {name = "Sound Volume", value = 5, min = 0, max = 10, step = 1},  -- New sound volume setting
  {name = "Vibration Intensity", value = 5, min = 0, max = 10, step = 1},  -- New vibration intensity setting
  {name = "START", isButton = true}
}

-- Add back necessary helper functions
local function applyRotation(x, y, angle)
  local cos = math.cos(angle)
  local sin = math.sin(angle)
  return x * cos - y * sin, x * sin + y * cos
end

-- Add this helper function first
local function calculateSpeed()
  -- Only use horizontal speed components
  return math.sqrt(speed.x^2 + speed.z^2)
end

-- Add race lines state
local raceLines = {}
for i=1, 8 do
  raceLines[i] = {x = (i-4.5)*200, z = -1000}
end

-- Add these helper functions after the existing helpers
local function drawArrow(x, y, angle, size)
  local cos = math.cos(angle)
  local sin = math.sin(angle)
  
  local x1 = x + size * cos
  local y1 = y + size * sin
  local x2 = x + size/2 * math.cos(angle + math.rad(140))
  local y2 = y + size/2 * math.sin(angle + math.rad(140))
  local x3 = x + size/2 * math.cos(angle - math.rad(140))
  local y3 = y + size/2 * math.sin(angle - math.rad(140))
  
  lcd.drawLine(x, y, x1, y1, SOLID, FORCE)
  lcd.drawLine(x1, y1, x2, y2, SOLID, FORCE)
  lcd.drawLine(x1, y1, x3, y3, SOLID, FORCE)
end

-- Replace existing drawObject function
local function drawGate(gate)
  if not gate or gate.z <= drone.z then return end
  
  local x, z = gate.x - drone.x, gate.z - drone.z
  -- Quick distance check
  if z > config.renderDist then return end
  
  x, z = applyRotation(x, z, -drone.yaw)
  if z <= 0 then return end
  
  local scale = config.zScale / math.max(1, z)  -- Prevent division by zero
  local sx = x * scale + LCD_W/2
  local sy = LCD_H/2 + (drone.y - gate.y) * scale  -- Fix vertical perspective
  
  -- Quick screen bounds check
  if sx < -50 or sx > LCD_W + 50 then return end
  
  local w = config.gate.w * scale / 2
  local h = config.gate.h * scale
  
  -- Simplified gate drawing
  lcd.drawLine(sx - w, sy, sx + w, sy, SOLID, FORCE)
  lcd.drawLine(sx - w, sy - h, sx + w, sy - h, SOLID, FORCE)
  lcd.drawLine(sx - w, sy, sx - w, sy - h, SOLID, FORCE)
  lcd.drawLine(sx + w, sy, sx + w, sy - h, SOLID, FORCE)
end

-- Fix updatePhysics function
local function updatePhysics()
  local thr = getValue('thr') / 512
  local roll = getValue('ail') / 512
  local pitch = getValue('ele') / 512
  local yaw = getValue('rud') / 512
  
  -- Apply invert controls if enabled
  if options[8].value == 1 then
    roll = -roll
    pitch = -pitch
    yaw = -yaw
  end
  
  -- Scale inputs
  thr = thr * config.phys.scale.throttle
  roll = roll * config.phys.scale.roll
  pitch = pitch * config.phys.scale.pitch
  yaw = yaw * config.phys.scale.yaw * (options[7].value / 100)
  
  local mode = options[3].value
  if mode == 1 then -- ACRO
    -- Full freedom of movement
    drone.roll = (drone.roll + roll * config.phys.dt) % (2 * math.pi)
    drone.pitch = (drone.pitch + pitch * config.phys.dt) % (2 * math.pi)
  else -- ANGLE/HOR
    -- Restrict movement to left/right/forward/back
    local targetRoll = roll * math.rad(30)  -- Max 30 degree tilt
    local targetPitch = pitch * math.rad(30)
    drone.roll = drone.roll * 0.85 + targetRoll * 0.15
    drone.pitch = 0  -- Lock pitch for level flight
  end
  
  -- Update yaw
  drone.yaw = (drone.yaw + yaw * config.phys.dt) % (2 * math.pi)
  
  -- Calculate forces
  local thrust = math.max(0, thr) * config.phys.dt * 8
  local gravity = config.phys.g * config.phys.scale.gravity * config.phys.dt
  
  -- Update velocities based on mode
  if mode == 1 then -- ACRO
    -- Full physics
    speed.x = (speed.x + thrust * math.sin(drone.roll)) * config.phys.air
    speed.y = (speed.y + thrust * math.cos(drone.roll) - gravity) * config.phys.air
    speed.z = (speed.z + thrust * math.sin(drone.pitch)) * config.phys.air
  else -- ANGLE/HOR
    -- Simplified movement
    speed.x = (roll * config.phys.scale.roll) * config.phys.air
    speed.y = (thrust - gravity) * config.phys.air
    speed.z = (-pitch * config.phys.scale.pitch) * config.phys.air
  end
  
  -- Add speed cap
  local currentSpeed = math.sqrt(speed.x^2 + speed.y^2 + speed.z^2)
  if currentSpeed > config.phys.maxSpeed then
    local factor = config.phys.maxSpeed / currentSpeed
    speed.x = speed.x * factor
    speed.y = speed.y * factor
    speed.z = speed.z * factor
  end

  -- Update position with ground and altitude constraints
  drone.x = drone.x + speed.x
  drone.y = math.min(config.phys.maxAltitude,
                    math.max(config.phys.groundLevel, 
                    drone.y + speed.y))
  drone.z = drone.z + speed.z
  
  -- Ground collision
  if drone.y <= config.phys.groundLevel then
    speed.y = 0
    drone.y = config.phys.groundLevel
  end
  
  -- Optimized gate collision check
  for i, gate in ipairs(activeGates) do
    if not gate.passed and 
       math.abs(gate.z - drone.z) < config.gate.w and
       math.abs(gate.x - drone.x) < config.gate.w and
       math.abs(gate.y - drone.y) < config.gate.h then
      gate.passed = true
      counter = counter + 1
      playGateSound()
      
      -- Move gate ahead efficiently
      gate.z = math.max(activeGates[1].z, activeGates[2].z) + config.zStep
      gate.x = math.random(-100, 100)
      gate.y = config.phys.groundLevel
      gate.passed = false
    end
  end
end

local showDebug = false
local currentFlightMode = "ACRO"
local currentSpeed = 0

local function drawLandscape()
  -- Simple ground reference
  lcd.drawLine(0, LCD_H/2, LCD_W, LCD_H/2, DOTTED, FORCE)
  lcd.drawLine(LCD_W/2, LCD_H/2-5, LCD_W/2, LCD_H/2+5, SOLID, FORCE)
end

local function drawDebugInfo()
  lcd.drawText(2, 12, "X:" .. math.floor(drone.x), SMLSIZE)
  lcd.drawText(2, 22, "Y:" .. math.floor(drone.y), SMLSIZE)
  lcd.drawText(2, 32, "Z:" .. math.floor(drone.z), SMLSIZE)
end

local function drawRaceLines()
  for _, line in ipairs(raceLines) do
    local x, z = line.x - drone.x, line.z - drone.z
    x, z = applyRotation(x, z, -drone.yaw)
    if z > 0 then
      local scale = config.zScale / z
      local sx = x * scale + LCD_W/2
      if sx >= 0 and sx <= LCD_W then
        lcd.drawLine(sx, LCD_H/2-5, sx, LCD_H/2+5, DOTTED, FORCE)
      end
    end
  end
end

-- Add feedback functions
local function playGateSound()
  -- Adjust sound volume based on setting
  local volume = options[9].value * 100
  playTone(1500, 100, 0, volume)
  
  -- Adjust vibration intensity based on setting
  local intensity = options[10].value * 2
  playHaptic(intensity, 0, 0)
end

local function playSettingHaptic()
  -- Adjust vibration intensity based on setting
  local intensity = options[10].value
  playHaptic(intensity, 0, 0)
end

-- Add power optimization helpers after config
local function shouldUpdateMenu()
  local now = getTime()
  if now - config.menuLastUpdate >= (500 / config.menuRefreshRate) then
    config.menuLastUpdate = now
    return true
  end
  return false
end

-- Add horizon line drawing function
local function drawHorizon()
  local roll = drone.roll
  local pitch = drone.pitch
  local length = LCD_W * 0.8
  local cx = LCD_W/2
  local cy = LCD_H/2
  
  -- Draw artificial horizon
  local dx = math.sin(roll) * length/2
  local dy = math.cos(roll) * length/2
  local py = pitch * 10  -- Pitch sensitivity
  
  lcd.drawLine(cx - dx, cy - dy + py, cx + dx, cy + dy + py, SOLID, FORCE)
end

-- Move compass drawing function before run_func
local function drawCompass()
  local cx = LCD_W/2
  local cy = config.display.compass.y
  local r = config.display.compass.radius
  
  -- Draw compass circle
  if lcd.drawCircle then
    lcd.drawCircle(cx, cy, r)
  else
    -- Fallback if drawCircle not available
    local steps = 16
    local angleStep = 2 * math.pi / steps
    local x1, y1 = cx + r, cy
    for i = 1, steps do
      local angle = i * angleStep
      local x2 = cx + r * math.cos(angle)
      local y2 = cy + r * math.sin(angle)
      lcd.drawLine(x1, y1, x2, y2, SOLID, FORCE)
      x1, y1 = x2, y2
    end
  end
  
  -- Draw cardinal directions
  local yaw = drone.yaw
  for i, dir in ipairs(config.display.compass.directions) do
    local angle = math.rad((i-1) * 90) - yaw
    local x = cx + math.sin(angle) * r
    local y = cy - math.cos(angle) * r
    -- Highlight north
    lcd.drawText(x-2, y-3, dir, dir == "N" and INVERS or 0)
  end
end

-- Improved ground drawing
local function drawGround()
  -- Draw horizon line
  lcd.drawLine(0, LCD_H/2, LCD_W, LCD_H/2, SOLID, FORCE)
  
  -- Draw perspective lines (vertical)
  local spacing = config.display.ground.spacing
  for i=1, config.display.ground.lines do
    local y = LCD_H/2 + i * spacing
    local x1 = LCD_W/2 - (i * spacing * 1.5)  -- Wider spread
    local x2 = LCD_W/2 + (i * spacing * 1.5)
    -- Fade lines with distance
    local intensity = math.max(0, 1 - (i/config.display.ground.lines) * config.display.ground.fadeStep)
    if intensity > 0.3 then  -- Only draw visible lines
      lcd.drawLine(x1, y, x2, y, DOTTED, FORCE)
    end
  end
  
  -- Draw grid lines (horizontal)
  local gridSpacing = config.display.ground.gridSize
  for i=1, config.display.ground.gridLines do
    local z = i * gridSpacing
    local scale = config.zScale / z
    local y = LCD_H/2 + (z * 0.2)  -- Perspective scaling
    
    -- Draw multiple horizontal lines for grid effect
    for j=-3, 3 do
      local x1 = LCD_W/2 + (j * gridSpacing * scale)
      local x2 = LCD_W/2 + ((j+1) * gridSpacing * scale)
      if y < LCD_H then  -- Only draw if in view
        lcd.drawLine(x1, y, x2, y, DOTTED, FORCE)
      end
    end
  end
  
  -- Add center reference line
  lcd.drawLine(LCD_W/2, LCD_H/2, LCD_W/2, LCD_H, SOLID, FORCE)
end

-- Simplified run function
local function run_func(event)
  if event == nil then event = 0 end  -- Add this line
  
  -- Skip frame timing for title screen
  if state == "title" then
    lcd.clear()
    lcd.drawText(LCD_W/2 - 47, 28, "Lua FPV Simulator V2", BOLD)
    lcd.drawText(LCD_W/2 - 47, 40, "Mod By CodeZ!")
    lcd.drawText(LCD_W/2 - 59, 54, "Press [Enter] to continue")
    if event == EVT_ENTER_BREAK then state = "options" end
    
  -- Optimize menu state
  elseif state == "options" then
    -- Only update menu on event or refresh timer
    if event == 0 and not shouldUpdateMenu() then
      return 0
    end
    
    lcd.clear()
    -- Draw settings header
    lcd.drawText(LCD_W/2 - 30, 2, "Settings", BOLD + INVERS)
    
    -- Calculate visible options
    local visibleOptions = 4
    local startIdx = math.max(1, math.min(selectedOption - visibleOptions + 1, #options - visibleOptions + 1))
    local endIdx = math.min(startIdx + visibleOptions - 1, #options)
    
    -- Draw options
    for i = startIdx, endIdx do
      local option = options[i]
      local y = 15 + (i - startIdx) * 12
      local attr = (i == selectedOption) and (editingValue and BLINK or INVERS) or 0
      
      if option.isButton then
        -- Draw button
        if i == selectedOption then
          lcd.drawFilledRectangle(5, y-1, LCD_W-10, 11, INVERS)
          lcd.drawText(LCD_W/2 - 20, y, option.name, 0)
        else
          lcd.drawText(LCD_W/2 - 20, y, option.name, 0)
        end
      else
        -- Draw normal option
        lcd.drawText(10, y, option.name .. ":", 0)
        if option.labels then
          local label = option.labels[option.value] or "?"
          lcd.drawText(LCD_W - 20, y, label, attr)
        else
          lcd.drawNumber(LCD_W - 20, y, option.value * (option.name == "Weight" and 10 or 1), 
                        attr + (option.name == "Weight" and PREC1 or 0))
        end
      end
    end

    -- Handle input
    if event == EVT_ENTER_BREAK then
      if options[selectedOption].isButton then
        playSettingHaptic()
        state = "race"
      else
        editingValue = not editingValue
      end
    elseif event == EVT_EXIT_BREAK then
      if editingValue then
        editingValue = false
      else
        selectedOption = 1
        state = "title"
      end
    elseif editingValue then
      local option = options[selectedOption]
      local oldValue = option.value
      if event == EVT_ROT_RIGHT or event == EVT_PLUS_BREAK then
        option.value = math.min(option.value + option.step, option.max)
        if oldValue ~= option.value then playSettingHaptic() end
      elseif event == EVT_ROT_LEFT or event == EVT_MINUS_BREAK then
        option.value = math.max(option.value - option.step, option.min)
        if oldValue ~= option.value then playSettingHaptic() end
      end
    else
      local oldSelection = selectedOption
      if event == EVT_ROT_RIGHT or event == EVT_PLUS_BREAK then
        selectedOption = math.min(selectedOption + 1, #options)
      elseif event == EVT_ROT_LEFT or event == EVT_MINUS_BREAK then
        selectedOption = math.max(selectedOption - 1, 1)
      end
    end
  
  -- Race state remains largely unchanged
  elseif state == "race" then
    -- Apply normal frame timing
    local currentTime = getTime()
    local frameTime = 1000 / options[5].value
    if (currentTime - config.lastFrameTime) < frameTime then
      return 0
    end
    config.frameSkip = options[6].value
    config.lastFrameTime = currentTime

    lcd.clear()
    updatePhysics()
    drawGround()  -- Now this will work
    drawCompass()  -- Make sure this matches the function name exactly
    drawLandscape()
    
    -- Draw orientation aids
    if options[3].value == 1 then  -- ACRO mode
      drawHorizon()  -- Show artificial horizon
    end
    
    drawRaceLines() -- Add race lines
    
    -- Update flight mode based on options
    currentFlightMode = options[3].labels[options[3].value]
    showDebug = (options[4].value == 1)
    
    -- Only draw active gates
    for _, gate in ipairs(activeGates) do
      drawGate(gate)
    end
    
    -- Show HUD
    if showDebug then
      drawDebugInfo()
      -- Add attitude information
      lcd.drawText(2, 42, "Roll:" .. math.floor(math.deg(drone.roll)), SMLSIZE)
      lcd.drawText(2, 52, "Pitch:" .. math.floor(math.deg(drone.pitch)), SMLSIZE)
    end
    lcd.drawText(2, LCD_H-8, currentFlightMode, SMLSIZE + INVERS)
    lcd.drawNumber(3, 2, counter, 0)
    
    -- Draw speedometer
    local speed_kmh = math.floor(calculateSpeed() * 3.6) -- Convert m/s to km/h
    lcd.drawText(LCD_W-45, 2, speed_kmh .. "km/h", SMLSIZE + INVERS)
  end
  
  return 0  -- Make sure this is always the last line
end

-- Minimal init
local function init_func()
  -- Create fresh copies of gates
  activeGates = {}
  for i, gate in ipairs(initialGates) do
    activeGates[i] = {
      x = gate.x,
      y = gate.y,
      z = gate.z,
      passed = gate.passed
    }
  end

  -- Reset gates positions
  activeGates[1].x = math.random(-100, 100)
  activeGates[2].x = math.random(-100, 100)
  activeGates[1].z = 500
  activeGates[2].z = 1500
  activeGates[1].passed = false
  activeGates[2].passed = false
  
  -- Reset other state
  drone = {x = 0, y = 0, z = 0, roll = 0, pitch = 0, yaw = 0}
  speed = {x = 0, y = 0, z = 0}
  counter = 0
end

return { init=init_func, run=run_func }

