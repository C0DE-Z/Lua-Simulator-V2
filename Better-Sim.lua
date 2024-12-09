-- FPV drone simulator for OpenTX --
-- OG Author: Alexey Stankevich @AlexeyStn
-- Mod by CodeZ

-- Initialize drone position and speed
local drone = {x = 0, y = 0, z = 0}
local speed = {x = 0, y = 0, z = 0}

local lowFps = false
local fpsCounter = 0

local gate = {w = 30, h = 30}
local flag = {w = 6, h = 30}
local track = {w = 50, h = 80}

local rollScale = 50
local pitchScale = 50
local throttleScale = 150

local minSpeed = 3

local objectsN = 2
local objects = {}
local zObjectsStep = 1500

local zScale = 300

local raceTime = 30
local startTime
local finishTime
local countDown

local raceStarted = false
local startTonePlayed = false
local counter = nil

local objectCounter = 0
local bestResultPath = "/SCRIPTS/simulator.txt"
local isNewBest = false

-- Initialize yaw control and gravity
local yawScale = 50
local gravity = 9.81
local deltaTime = 0.02 -- 20ms per frame
local maxTilt = math.rad(45) -- Maximum tilt angle in radians (45 degrees)

-- Add air resistance and max speed
local airResistance = 0.98 -- Air resistance factor (1 = no resistance, 0 = full resistance)
local maxSpeed = 200 -- Maximum speed in units per second

-- Add drone weight variable
local droneWeight = 1.0 -- Default weight

-- Add state variable and parameters for options screen
local state = "title"
local options = {
  {name = "Drone Weight", value = 1.0, min = 0.1, max = 5.0, step = 0.1},
  {name = "Race Time", value = 30, min = 10, max = 300, step = 10},
  -- Add more parameters if needed
}
local selectedOption = 1

-- Add near the top with other state variables
local transitionStart = 0
local transitionDuration = 100 -- 1 second
local transitionText = ""

-- Move this function before it's used
local function applyRotation(x, y, angle)
  local cos = math.cos(angle)
  local sin = math.sin(angle)
  return x * cos - y * sin, x * sin + y * cos
end

-- Helper functions
local function clampAngle(angle)
  return math.max(-maxTilt, math.min(maxTilt, angle))
end

local function loadBestResult()
  local f = io.open(bestResultPath, "r")
  if f == nil then
    return nil
  end
  result = tonumber(io.read(f, 3))
  return result
end

local function saveBestResult(result)
  local f = io.open(bestResultPath, "w")
  io.write(f, tostring(result))  -- Use tostring instead of string.format
  io.close(f)
end

local function drawBorder(x1, y1, x2, y2) -- 1 far, 2 close
  if x1 == x2 then -- vertical
    if y2 >= LCD_H then y2 = LCD_H - 1 end
  else -- diagonal
    a = (y2 - y1) / (x2 - x1)
    b = (y1 * x2 - y2 * x1) / (x2 - x1)
    x0 = 0
    y0 = x0 * a + b
    if a < 0 and y0 < LCD_H and y0 >= (LCD_H/2 + 1) then -- left side
      x2 = x0
      y2 = y0
    else
      x0 = (LCD_W - 1)
      y0 = x0 * a + b
      if a > 0 and y0 < LCD_H and y0 >= (LCD_H/2 + 1) then -- right side
        x2 = x0
        y2 = y0
      else -- bottom side
        p = (LCD_H - 1 - y1) / (y2 - y1)
        y2 = LCD_H - 1
        x2 = x1 + (x2 - x1) * p
        if x2 < 0 then x2 = 0 end
        if x2 >= LCD_W then x2 = LCD_W - 1 end
      end
    end
  end
  lcd.drawLine(x1, y1, x2, y2, DOTTED, FORCE)
end

local function drawLandscape()
  -- Add ground grid for better depth perception
  local gridSize = 50
  local gridLines = 10
  for i = -gridLines, gridLines do
    local x1 = i * gridSize
    local z1 = -100
    local x2 = i * gridSize
    local z2 = 1000
    
    -- Project grid lines with perspective
    local sx1 = (x1 * zScale) / z1 + LCD_W/2
    local sy1 = LCD_H - 10  -- Near line
    local sx2 = (x2 * zScale) / z2 + LCD_W/2
    local sy2 = LCD_H/2 + 20  -- Far line
    
    -- Apply rotation
    sx1, sy1 = applyRotation(sx1 - LCD_W/2, sy1 - LCD_H/2, drone.roll)
    sx2, sy2 = applyRotation(sx2 - LCD_W/2, sy2 - LCD_H/2, drone.roll)
    sx1, sy1 = sx1 + LCD_W/2, sy1 + LCD_H/2
    sx2, sy2 = sx2 + LCD_W/2, sy2 + LCD_H/2
    
    lcd.drawLine(sx1, sy1, sx2, sy2, DOTTED, FORCE)
  end
  
  -- Draw artificial horizon
  -- Apply camera transformation based on drone orientation
  local horizonTilt = -drone.roll
  local horizonShift = drone.pitch * 30  -- Adjust multiplier as needed
  
  -- Draw tilted horizon line
  local x1, y1 = 0, LCD_H/2 + horizonShift
  local x2, y2 = LCD_W-1, LCD_H/2 + horizonShift
  
  -- Rotate horizon line around screen center
  local centerX, centerY = LCD_W/2, LCD_H/2
  x1, y1 = applyRotation(x1 - centerX, y1 - centerY, horizonTilt)
  x2, y2 = applyRotation(x2 - centerX, y2 - centerY, horizonTilt)
  x1, y1 = x1 + centerX, y1 + centerY
  x2, y2 = x2 + centerX, y2 + centerY
  
  lcd.drawLine(x1, y1, x2, y2, DOTTED, FORCE)
  
  -- Draw perspective lines
  -- ...rest of landscape drawing code...
end

local function drawLine(x1, y1, x2, y2, flag)
  if flag == 'h' then
    if y1 < 0 or y1 > LCD_H then return 0 end
    if x1 < 0 and x2 < 0 then return 0 end
    if x1 >= LCD_W and x2 >= LCD_W then return 0 end
    if x1 < 0 then x1 = 0 end
    if x2 < 0 then x2 = 0 end
    if x1 >= LCD_W then x1 = LCD_W - 1 end
    if x2 >= LCD_W then x2 = LCD_W - 1 end
    lcd.drawLine(x1, y1, x2, y2, SOLID, FORCE)
    return 0
  end
  if flag == 'v' then
    if x1 < 0 or x1 > LCD_W then return 0 end
    if y1 < 0 and y2 < 0 then return 0 end
    if y1 >= LCD_H and y2 >= LCD_H then return 0 end
    if y1 < 0 then y1 = 0 end
    if y2 < 0 then y2 = 0 end
    if y1 >= LCD_H then y1 = LCD_H - 1 end
    if y2 >= LCD_H then y2 = LCD_H - 1 end
    lcd.drawLine(x1, y1, x2, y2, SOLID, FORCE)
    return 0
  end
end

local function drawMarker(x, y)
  if x < 0 then x = 1 end
  if x >= LCD_W then x = LCD_W - 2 end
  if y < 0 then yP = 1 end
  if y >= LCD_W then y = LCD_H - 2 end
  lcd.drawLine(x - 1, y - 1, x - 1, y + 1, SOLID, FORCE)
  lcd.drawLine(x    , y - 1, x    , y + 1, SOLID, FORCE)
  lcd.drawLine(x + 1, y - 1, x + 1, y + 1, SOLID, FORCE)
end

local function drawObject(object, markerFlag)
  x = object.x - drone.x
  y = object.y - drone.y
  z = object.z - drone.z
  if object.t == "gateGround" then
    xDispLeft = ((x - gate.w/2) * zScale) / z + LCD_W/2
    xDispRight = ((x + gate.w/2) * zScale) / z + LCD_W/2
    yDispTop = ((y - gate.h) * zScale) / z + LCD_H/2
    yDispBottom = ((y + 0) * zScale) / z + LCD_H/2
    xDispMarker = (x * zScale) / z + LCD_W/2
    yDispMarker = ((y - gate.h/2) * zScale) / z + LCD_H/2
    drawLine(xDispLeft, yDispBottom, xDispLeft, yDispTop, 'v')
    drawLine(xDispRight, yDispBottom, xDispRight, yDispTop, 'v')
    drawLine(xDispLeft, yDispTop, xDispRight, yDispTop, 'h')
  elseif object.t == "gateAir" then
    xDispLeft = ((x - gate.w/2) * zScale) / z + LCD_W/2
    xDispRight = ((x + gate.w/2) * zScale) / z + LCD_W/2
    yDispTop = ((y - gate.h*2) * zScale) / z + LCD_H/2
    yDispMid = ((y - gate.h) * zScale) / z + LCD_H/2
    yDispBottom = ((y + 0) * zScale) / z + LCD_H/2
    xDispMarker = (x * zScale) / z + LCD_W/2
    yDispMarker = ((y - gate.h*3/2) * zScale) / z + LCD_H/2
    drawLine(xDispLeft, yDispBottom, xDispLeft, yDispTop, 'v')
    drawLine(xDispRight, yDispBottom, xDispRight, yDispTop, 'v')
    drawLine(xDispLeft, yDispTop, xDispRight, yDispTop, 'h')
    drawLine(xDispLeft, yDispMid, xDispRight, yDispMid, 'h')
  elseif object.t == "flagLeft" then
    xDispLeft = ((x - flag.w/2) * zScale) / z + LCD_W/2
    xDispRight = ((x + flag.w/2) * zScale) / z + LCD_W/2
    yDispTop = ((y - gate.h*2) * zScale) / z + LCD_H/2
    yDispMid = ((y - gate.h) * zScale) / z + LCD_H/2
    yDispBottom = ((y + 0) * zScale) / z + LCD_H/2
    xDispMarker = ((x + flag.w*2) * zScale) / z + LCD_W/2
    yDispMarker = ((y - gate.h*3/2) * zScale) / z + LCD_H/2
    drawLine(xDispLeft, yDispMid, xDispLeft, yDispTop, 'v')
    drawLine(xDispRight, yDispBottom, xDispRight, yDispTop, 'v')
    drawLine(xDispLeft, yDispTop, xDispRight, yDispTop, 'h')
    drawLine(xDispLeft, yDispMid, xDispRight, yDispMid, 'h')
  elseif object.t == "flagRight" then
    xDispLeft = ((x - flag.w/2) * zScale) / z + LCD_W/2
    xDispRight = ((x + flag.w/2) * zScale) / z + LCD_W/2
    yDispTop = ((y - gate.h*2) * zScale) / z + LCD_H/2
    yDispMid = ((y - gate.h) * zScale) / z + LCD_H/2
    yDispBottom = ((y + 0) * zScale) / z + LCD_H/2
    xDispMarker = ((x - flag.w*2) * zScale) / z + LCD_W/2
    yDispMarker = ((y - gate.h*3/2) * zScale) / z + LCD_H/2
    drawLine(xDispLeft, yDispBottom, xDispLeft, yDispTop, 'v')
    drawLine(xDispRight, yDispMid, xDispRight, yDispTop, 'v')
    drawLine(xDispLeft, yDispTop, xDispRight, yDispTop, 'h')
    drawLine(xDispLeft, yDispMid, xDispRight, yDispMid, 'h')
  end
  if markerFlag then
    drawMarker(xDispMarker, yDispMarker)
  end
end

local function generateObject()
  objectCounter = objectCounter + 1
  distance = objectCounter * zObjectsStep
  object = {x = math.random(-track.w, track.w), y = 0, z = distance}
  typeId = math.random(1,6)
  if typeId == 1 or typeId == 2 then
    object.t = "gateGround"
  elseif typeId == 3 or typeId == 4 then
    object.t = "gateAir"
  elseif typeId == 5 then
    object.t = "flagRight"
    object.x = - math.abs(object.x) - track.w
  elseif typeId == 6 then
    object.t = "flagLeft"
    object.x = math.abs(object.x) + track.w
  end
  return object
end

local function init_func()
  if lowFps then
    rollScale = rollScale / 2
    pitchScale = pitchScale / 2
    throttleScale = throttleScale / 2
  end
  bestResult = loadBestResult()
  state = "title"
end

-- Add near the top with other event handlers
local EVT_VIRTUAL_NEXT = EVT_VIRTUAL_INC -- Scroll wheel next
local EVT_VIRTUAL_PREV = EVT_VIRTUAL_DEC -- Scroll wheel previous

local function run_func(event)
  if state == "title" then
    -- Display title screen
    lcd.clear()
    lcd.drawText(LCD_W/2 - 47, 28, "Lua FPV Simulator V2", BOLD)
    lcd.drawText(LCD_W/2 - 47, 40, "Mod By CodeZ!")
    lcd.drawText(LCD_W/2 - 59, 54, "Press [Enter] to continue")

    if event == EVT_ENTER_BREAK then
      state = "options"
    end

  elseif state == "options" then
    lcd.clear()
    -- Center align title
    lcd.drawText(LCD_W/2 - 30, 2, "Settings", BOLD + INVERS)
    
    -- Draw options more to the left and centered vertically
    local startY = LCD_H/2 - (#options * 10)
    for i, option in ipairs(options) do
      local y = startY + (i - 1) * 20 -- Increased spacing between options
      local attr = (i == selectedOption) and INVERS or 0
      -- Draw option name left-aligned
      lcd.drawText(10, y, option.name .. ":", attr)
      -- Draw value right-aligned
      lcd.drawNumber(LCD_W - 20, y, option.value * (option.name == "Drone Weight" and 10 or 1), 
                    attr + (option.name == "Drone Weight" and PREC1 or 0))
    end
    
    -- Center align bottom instruction
    lcd.drawText(LCD_W/2 - 50, LCD_H - 8, "ENTER: Start  EXIT: Back", 0)

    -- Handle navigation including scroll wheel
    if event == EVT_MINUS_BREAK or event == EVT_VIRTUAL_PREV then
      selectedOption = (selectedOption > 1) and (selectedOption - 1) or #options
    elseif event == EVT_PLUS_BREAK or event == EVT_VIRTUAL_NEXT then
      selectedOption = (selectedOption < #options) and (selectedOption + 1) or 1
    elseif event == EVT_VIRTUAL_INC then -- Scroll wheel right
      local option = options[selectedOption]
      option.value = math.min(option.value + option.step, option.max)
    elseif event == EVT_VIRTUAL_DEC then -- Scroll wheel left
      local option = options[selectedOption]
      option.value = math.max(option.value - option.step, option.min)
    elseif event == EVT_UP_BREAK then
      local option = options[selectedOption]
      option.value = math.min(option.value + option.step, option.max)
    elseif event == EVT_DOWN_BREAK then
      local option = options[selectedOption]
      option.value = math.max(option.value - option.step, option.min)
    elseif event == EVT_ENTER_BREAK then
      -- Apply adjusted parameters
      droneWeight = options[1].value
      raceTime = options[2].value
      state = "countdown"
      -- Initialize race variables
      startTime = getTime() + 300 -- 3 seconds countdown
      finishTime = startTime + raceTime * 100
      countDown = 3
      -- Reset drone position and speed
      drone.x = 0
      drone.y = 0
      drone.z = 0
      speed.x = 0
      speed.y = 0
      speed.z = 0
      drone.roll = 0
      drone.pitch = 0
      drone.yaw = 0
      -- Generate initial objects
      objectCounter = 0
      objects = {}
      for i = 1, objectsN do
        objects[i] = generateObject()
      end
      counter = 0
      startTonePlayed = false
    end

    if event == EVT_EXIT_BREAK then
      state = "title"
    end

  elseif state == "countdown" then
    lcd.clear()
    local cnt = math.floor((startTime - getTime()) / 100) + 1
    if cnt ~= countDown then
      playTone(1500, 100, 0)
      countDown = cnt
    end
    if cnt <= 0 then
      state = "transition"
      transitionStart = getTime()
      transitionText = "LIFTOFF!"
      playTone(2250, 500, 0)
    else
      lcd.drawText(LCD_W/2 - 6, LCD_H/2 - 8, tostring(cnt), DBLSIZE + BOLD)
    end

  elseif state == "transition" then
    lcd.clear()
    local progress = (getTime() - transitionStart) / transitionDuration
    
    -- Calculate scaling effect (starts big, shrinks to normal)
    local scale = 3 - (2 * progress) -- Scale from 3x to 1x
    if scale < 1 then scale = 1 end
    
    -- Calculate alpha (fade in then out)
    local alpha = math.sin(progress * math.pi) * 15
    if alpha < 0 then alpha = 0 end
    
    -- Draw centered text with effect
    local textWidth = #transitionText * (8 * scale) -- Approximate width
    local x = LCD_W/2 - textWidth/2
    local y = LCD_H/2 - (8 * scale)
    lcd.drawText(x, y, transitionText, DBLSIZE + BOLD + INVERS)
    
    -- Transition to race state when done
    if progress >= 1.0 then
      state = "race"
    end

  elseif state == "race" then
    if lowFps then
      -- skip frames to maintain performance
      fpsCounter = fpsCounter + 1
      if fpsCounter == 2 then
        fpsCounter = 0
        return 0
      end
    end
    lcd.clear()
    currentTime = getTime()
    if currentTime < startTime then
      -- Countdown before race starts
      local cnt = (startTime - currentTime) / 100 + 1
      if cnt < countDown then
        playTone(1500, 100, 0)
        countDown = countDown - 1
      end
      lcd.drawNumber(LCD_W/2 - 2, LCD_H - LCD_H/3, cnt, BOLD)
    elseif currentTime < finishTime then
      if (currentTime - startTime) < 100 then
        lcd.drawText(LCD_W/2 - 6, 48, 'GO!', BOLD)
        if not startTonePlayed then
          playTone(2250, 500, 0)
          startTonePlayed = true
        end
      end
      -- Read control inputs and scale them appropriately
      local throttleInput = (getValue('thr') / 512) * throttleScale
      local rollInput = (getValue('ail') / 512) * rollScale
      local pitchInput = (getValue('ele') / 512) * pitchScale
      local yawInput = (getValue('rud') / 512) * yawScale

      -- Update drone orientation
      drone.roll = clampAngle(drone.roll + rollInput * deltaTime)
      drone.pitch = clampAngle(drone.pitch - pitchInput * deltaTime)  -- Inverted for intuitive control
      drone.yaw = drone.yaw + yawInput * deltaTime

      -- Calculate thrust vector
      local thrust = throttleInput * deltaTime
      
      -- Calculate movement based on orientation
      local forwardThrust = thrust * math.cos(drone.roll) * math.sin(-drone.pitch) * 2 -- Increased multiplier
      local lateralThrust = thrust * math.sin(drone.roll)
      local verticalThrust = thrust * math.cos(drone.roll) * math.cos(drone.pitch)

      -- Apply yaw rotation to horizontal movement
      local rotatedX, rotatedZ = applyRotation(forwardThrust, lateralThrust, drone.yaw)
      
      -- Update velocities with thrust and gravity
      speed.x = (speed.x + rotatedX) * airResistance
      speed.y = (speed.y + verticalThrust - gravity * deltaTime) * airResistance
      speed.z = (speed.z + rotatedZ) * airResistance * 2 -- Increased forward momentum

      -- Clamp speeds to maximum
      local currentSpeed = math.sqrt(speed.x^2 + speed.y^2 + speed.z^2)
      if currentSpeed > maxSpeed then
          local factor = maxSpeed / currentSpeed
          speed.x = speed.x * factor
          speed.y = speed.y * factor
          speed.z = speed.z * factor
      end

      -- Update drone position
      drone.x = drone.x + speed.x * deltaTime
      drone.y = drone.y + speed.y * deltaTime
      drone.z = drone.z + speed.z * deltaTime

      -- Prevent drone from going below ground level
      if drone.y > 0 then
        drone.y = 0
        speed.y = 0
        -- Add some ground friction
        speed.x = speed.x * 0.8
        speed.z = speed.z * 0.8
      end

      -- Display drone position and orientation
      lcd.drawText(LCD_W - 60, 2, "X: " .. math.floor(drone.x*10)/10, SMLSIZE)
      lcd.drawText(LCD_W - 60, 10, "Y: " .. math.floor(drone.y*10)/10, SMLSIZE)
      lcd.drawText(LCD_W - 60, 18, "Z: " .. math.floor(drone.z*10)/10, SMLSIZE)
      lcd.drawText(LCD_W - 60, 26, "Yaw: " .. math.floor(math.deg(drone.yaw)*10)/10, SMLSIZE)
      lcd.drawText(LCD_W - 60, 34, "Pitch: " .. math.floor(math.deg(drone.pitch)*10)/10, SMLSIZE)  
      lcd.drawText(LCD_W - 60, 42, "Roll: " .. math.floor(math.deg(drone.roll)*10)/10, SMLSIZE)
    else
      -- Race finished, check for new best result
      if (not bestResult) or (counter > bestResult) then
        isNewBest = true
        saveBestResult(counter)
        bestResult = counter
      end
      raceStarted = false
      state = "results"  -- Transition to results screen
    end
    remainingTime = (finishTime - currentTime)/100 + 1
    if remainingTime > raceTime then remainingTime = raceTime end
    lcd.drawTimer(LCD_W - 25, 2, remainingTime)
    local closestDist = drone.z + zObjectsStep * objectsN
    for i = 1, objectsN do
      if objects[i].z < closestDist and objects[i].z > (drone.z + speed.z) then
        closestN = i
        closestDist = objects[i].z
      end
    end
    for i = 1, objectsN do
      if drone.z >= objects[i].z then
        success = false
        if objects[i].t == "gateGround" then
          if (math.abs(objects[i].x - drone.x) <= gate.w/2) and (drone.y > -gate.h) then
            success = true
          end
        elseif objects[i].t == "gateAir" then
          if (math.abs(objects[i].x - drone.x) <= gate.w/2) and (drone.y < -gate.h) and (drone.y > -2*gate.h) then
            success = true
          end
        elseif objects[i].t == "flagLeft" then
          if (objects[i].x < drone.x) and (drone.y > -2*gate.h) then
            success = true
          end
        elseif objects[i].t == "flagRight" then
          if (objects[i].x > drone.x) and (drone.y > -2*gate.h) then
            success = true
          end
        end
        if success then
          counter = counter + 1
          playTone(1000, 100, 0)
        else
          counter = counter - 1
          playTone(500, 300, 0)
        end
        objects[i] = generateObject()
      else
        drawObject(objects[i], i == closestN)
      end
    end
    drawLandscape()
    lcd.drawNumber(3, 2, counter)
    if event == EVT_EXIT_BREAK then
      raceStarted = false
      counter = nil
    end
    -- Add visual direction indicator
    local arrowSize = 10
    local centerX = LCD_W/2
    local centerY = LCD_H/2
    lcd.drawLine(centerX - arrowSize, centerY, centerX + arrowSize, centerY, SOLID, FORCE)
    lcd.drawLine(centerX, centerY - arrowSize, centerX, centerY + arrowSize, SOLID, FORCE)
  elseif state == "results" then
    -- Display results
    lcd.clear()
    lcd.drawText(LCD_W/2 - 27, 20, "Result:", 0)
    lcd.drawNumber(LCD_W/2 + 12, 20, counter, DBLSIZE)
    if isNewBest then
      lcd.drawText(LCD_W/2 - 42, 2, "New best score!", 0)
    else
      lcd.drawText(LCD_W/2 - 37, 2, "Best score:", 0)
      lcd.drawNumber(LCD_W/2 + 30, 2, bestResult, 0)
    end
    lcd.drawText(LCD_W/2 - 50, LCD_H - 12, "Press [Enter] to restart", 0)

    if event == EVT_ENTER_BREAK or event == EVT_EXIT_BREAK then
      state = "title"
    end

  end

  return 0
end

return { init=init_func, run=run_func }
