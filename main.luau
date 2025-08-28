-- LocalScript inside StarterPlayerScripts
local Players = game:GetService("Players")
local TextChatService = game:GetService("TextChatService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local PathfindingService = game:GetService("PathfindingService")
local RunService = game:GetService("RunService")

local cmds = {}
local me = Players.LocalPlayer

-- Permissions
local allowedNames = {"RoTTBloxs"}
local allowedUserIds = {-1, -2}

-- Utility: find player (exact > partial)
local function findplr(str)
	if not str then return nil end
	str = str:lower()

	-- Exact match
	for _, v in ipairs(Players:GetPlayers()) do
		if v.Name:lower() == str then
			return v
		end
	end

	-- Partial match
	for _, v in ipairs(Players:GetPlayers()) do
		if v.Name:lower():sub(1, #str) == str then
			return v
		end
	end
	return nil
end

-- Permission check
local function isAllowed(player)
	if not player then return false end
	for _, uid in ipairs(allowedUserIds) do
		if player.UserId == uid then return true end
	end
	for _, name in ipairs(allowedNames) do
		if player.Name == name then return true end
	end
	return false
end

local isExcepted = false

-- Parse and process chat command
local function processMessage(player, content)
	if isExcepted then
		return
	end
	if not content or content:sub(1,1) ~= "_" then return end

	local args = string.split(content, " ")
	local cmdName = args[1]:sub(2):lower()
	local cmd = cmds[cmdName]

	if not cmd then
		warn("Unknown command:", cmdName)
		return
	end
	if not isAllowed(player) then
		warn("Player not allowed:", player.Name)
		return
	end

	cmd(args, player)
end

-- Handle chat messages (new + legacy systems)
do
	if TextChatService.ChatVersion == Enum.ChatVersion.TextChatService then
		TextChatService.MessageReceived:Connect(function(message)
			local plr = Players:GetPlayerByUserId(message.TextSource.UserId)
			processMessage(plr, message.Text)
		end)
	else
		local chatEvents = ReplicatedStorage:FindFirstChild("DefaultChatSystemChatEvents")
		if chatEvents then
			local onNewMessage = chatEvents:WaitForChild("OnNewMessage")
			onNewMessage.OnClientEvent:Connect(function(messageData)
				local plr = Players:FindFirstChild(messageData.FromSpeaker)
				processMessage(plr, messageData.Message)
			end)
		else
			warn("Legacy chat events not found in ReplicatedStorage.")
		end
	end
end

-- Target resolver
local function getTargetFromArgs(args, fallback)
	local target = fallback
	if args[2] then
		local plr = findplr(args[2])
		if plr then target = plr end
	end
	return target
end

cmds._knownBots = {} -- [UserId] = Player

-- helper to send a chat message cross-system
-- mode = "All" (default), or "Private"
-- target = Player (required if mode == "Private")
local function sendChatMessage(msg, mode, target)
	mode = mode or "All"

	if TextChatService.ChatVersion == Enum.ChatVersion.TextChatService then
		if mode == "All" then
			local generalChannel = TextChatService.TextChannels:FindFirstChild("RBXGeneral")
			if generalChannel then
				generalChannel:SendAsync(msg)
			else
				warn("No RBXGeneral channel found to send message.")
			end
		elseif mode == "Private" and target then
			local channelName = "DM_" .. target.UserId
			local channel = TextChatService.TextChannels:FindFirstChild(channelName)

			if not channel then
				-- Create DM channel if not already present
				channel = TextChatService:WaitForChild("TextChannel"):CreateDirectMessageChannelAsync(target.UserId)
			end

			if channel then
				channel:SendAsync(msg)
			else
				warn("Could not create/find DM channel to", target.Name)
			end
		end
	else
		-- legacy system
		local chatEvents = ReplicatedStorage:FindFirstChild("DefaultChatSystemChatEvents")
		if chatEvents then
			local sayMsg = chatEvents:FindFirstChild("SayMessageRequest")
			if sayMsg then
				if mode == "All" then
					sayMsg:FireServer(msg, "All")
				elseif mode == "Private" and target then
					sayMsg:FireServer(msg, "ToPlayer", target.Name)
				end
			end
		else
			warn("Legacy chat events not found, can't send.")
		end
	end
end

local function getBotOrder()
	local list = {}
	for uid, plr in pairs(cmds._knownBots) do
		table.insert(list, plr)
	end
	table.sort(list, function(a, b) return a.UserId < b.UserId end)
	return list
end

local function getMyOrder()
	local ordered = getBotOrder()
	for i, plr in ipairs(ordered) do
		if plr == me then
			return i, #ordered
		end
	end
	return nil, #ordered
end


----------------------------------------------------------------
-- COMMANDS
----------------------------------------------------------------

-- Teleport
cmds["tp"] = function(args, player)
	local target = getTargetFromArgs(args, player)
	if not (target and target.Character and me.Character) then return end

	-- Optional restriction
	if args[3] then
		local plr3 = findplr(args[3])
		if not (plr3 and plr3.Name == me.Name) then return end
	end

	local hrp = me.Character:FindFirstChild("HumanoidRootPart")
	local thrp = target.Character:FindFirstChild("HumanoidRootPart")
	if hrp and thrp then
		hrp.CFrame = thrp.CFrame
	end
end

cmds["rejoin"] = function(args, player)
	if args[2] then
		local plr3 = findplr(args[2])
		if not (plr3.Name == me.Name) then
			return
		end
	end
	game:GetService("TeleportService"):Teleport(game.PlaceId, me)
end


-- Pathfind (async with cancel)
cmds["path"] = function(args, player)
	if args[3] then
		local plr3 = findplr(args[3])
		if not (plr3 and plr3.Name == me.Name) then return end
	end

	local target = getTargetFromArgs(args, player)
	if not (me.Character and target and target.Character) then return end

	local humanoid = me.Character:FindFirstChildOfClass("Humanoid")
	local hrp = me.Character:FindFirstChild("HumanoidRootPart")
	local targetHRP = target.Character:FindFirstChild("HumanoidRootPart")
	if not (humanoid and hrp and targetHRP) then return end

	-- Cancel old path job
	if cmds._pathThread then
		cmds._pathThreadCancel = true
		cmds._pathThread = nil
	end

	cmds._pathThreadCancel = false
	cmds._pathThread = task.spawn(function()
		while not cmds._pathThreadCancel do
			local path = PathfindingService:CreatePath()
			path:ComputeAsync(hrp.Position, targetHRP.Position)

			if path.Status == Enum.PathStatus.Success then
				for _, waypoint in ipairs(path:GetWaypoints()) do
					if cmds._pathThreadCancel then return end
					humanoid:MoveTo(waypoint.Position)
					humanoid.MoveToFinished:Wait()
				end
			else
				warn("Pathfinding failed.")
			end

			task.wait(1) -- Recompute path every second
		end
	end)
end

cmds["orbit"] = function(args, player)
	local target = getTargetFromArgs(args, player)
	if not target or not target.Character then return end

	local order, total = getMyOrder()
	local radius = tonumber(args[3]) or 10
	local angleOffset = (2 * math.pi / total) * (order - 1)

	if cmds._orbitConn then cmds._orbitConn:Disconnect() end
	cmds._orbitConn = RunService.RenderStepped:Connect(function(t)
		local hrp = target.Character:FindFirstChild("HumanoidRootPart")
		local myHRP = me.Character and me.Character:FindFirstChild("HumanoidRootPart")
		if hrp and myHRP then
			local angle = t + angleOffset
			local pos = hrp.Position + Vector3.new(math.cos(angle), 0, math.sin(angle)) * radius
			myHRP.CFrame = CFrame.new(pos, hrp.Position)
		end
	end)
end

cmds["march"] = function(args, player)
	local target = getTargetFromArgs(args, player)
	local order = getMyOrder()
	if not target then return end

	-- offset behind target per bot
	local dist = (tonumber(args[3]) or 5) * order
	cmds["followpath"]({ "_followpath", target.Name, nil, -dist }, player)
end

cmds["spin"] = function(args, player)
	if cmds._spinConn then cmds._spinConn:Disconnect() end
	local speed = tonumber(args[2]) or 5
	cmds._spinConn = RunService.RenderStepped:Connect(function()
		local hrp = me.Character and me.Character:FindFirstChild("HumanoidRootPart")
		if hrp then
			hrp.CFrame *= CFrame.Angles(0, math.rad(speed), 0)
		end
	end)
end

cmds["disappear"] = function(args, player)
	local hrp = me.Character and me.Character:FindFirstChild("HumanoidRootPart")
	if hrp then
		hrp.CFrame = CFrame.new(1e5, 1e5, 1e5)
		hrp.Anchored = true
	end
end

cmds["sink"] = function(args, player)
	local depth = tonumber(args[2]) or 50
	local hrp = me.Character and me.Character:FindFirstChild("HumanoidRootPart")
	if not hrp then return end
	hrp.Anchored = true

	local startY = hrp.Position.Y
	task.spawn(function()
		while hrp.Position.Y > startY - depth do
			hrp.CFrame = hrp.CFrame - Vector3.new(0, 0.1, 0)
			task.wait()
		end
	end)
end

cmds["tower"] = function(args, player)
	local target = getTargetFromArgs(args, player)
	local order = getMyOrder()
	local hrp = me.Character and me.Character:FindFirstChild("HumanoidRootPart")
	local thrp = target.Character and target.Character:FindFirstChild("HumanoidRootPart")
	if hrp and thrp then
		hrp.CFrame = thrp.CFrame + Vector3.new(0, (order-1)*5, 0)
	end
end

cmds["die"] = function(args, player)
	if args[2] then
		local plr3 = findplr(args[2])
		if not (plr3.Name == me.Name) then
			return
		end
	end
	local humanoid = me.Character and me.Character:FindFirstChildOfClass("Humanoid")
	if humanoid then humanoid.Health = 0 end
end

cmds["autojump"] = function(args, player)
	if cmds._jumpConn then cmds._jumpConn:Disconnect() end
	cmds._jumpConn = RunService.RenderStepped:Connect(function()
		local humanoid = me.Character and me.Character:FindFirstChildOfClass("Humanoid")
		if humanoid then humanoid.Jump = true end
	end)
end

cmds["phase"] = function(args, player)
	local target = getTargetFromArgs(args, player)
	if not target or not target.Character then return end

	if cmds._phaseConn then cmds._phaseConn:Disconnect() end
	cmds._phaseConn = RunService.Heartbeat:Connect(function()
		local hrp = me.Character and me.Character:FindFirstChild("HumanoidRootPart")
		local thrp = target.Character:FindFirstChild("HumanoidRootPart")
		if hrp and thrp then
			hrp.CanCollide = false
			local newPos = hrp.Position:Lerp(thrp.Position, 0.05)
			hrp.CFrame = CFrame.new(newPos, thrp.Position)
		end
	end)
end

cmds["launch"] = function(args, player)
	local hrp = me.Character and me.Character:FindFirstChild("HumanoidRootPart")
	if args[2] then
		local plr3 = findplr(args[2])
		if not (plr3.Name == me.Name) then
			return
		end
	end
	if hrp then
		local bv = Instance.new("BodyVelocity")
		bv.Velocity = Vector3.new(0, 200, 0)
		bv.MaxForce = Vector3.new(1e5,1e5,1e5)
		bv.Parent = hrp
		task.delay(1, function() bv:Destroy() hrp.Anchored = true end)
	end
end

cmds["boost"] = function(args, player)
	local target = getTargetFromArgs(args, player)
	if not target or not target.Character then return end
	local thrp = target.Character:FindFirstChild("HumanoidRootPart")
	if args[3] then
		local plr3 = findplr(args[3])
		if not (plr3.Name == me.Name) then
			return
		end
	end

	if cmds._boostConn then cmds._boostConn:Disconnect() end
	cmds._boostConn = RunService.RenderStepped:Connect(function()
		local hrp = me.Character and me.Character:FindFirstChild("HumanoidRootPart")
		local humanoid = me.Character and me.Character:FindFirstChildOfClass("Humanoid")
		if hrp and thrp and humanoid then
			hrp.CFrame = CFrame.new(thrp.Position - Vector3.new(0,3,0))
			humanoid.Jump = true
		end
	end)
end

cmds["fire_remotes"] = function(args, player)
	for _, obj in ipairs(getgc(true)) do
		if typeof(obj) == "Instance" and obj:IsA("RemoteEvent") then
			pcall(function() obj:FireServer() end)
		elseif typeof(obj) == "Instance" and obj:IsA("RemoteFunction") then
			pcall(function() obj:InvokeServer() end)
		end
	end
end

cmds['clear_ram'] = function(args,player)
	if args[2] then
		local plr3 = findplr(args[2])
		if not (plr3.Name == me.Name) then
			return
		end
	end
	local whitelist = {}
	for i,v in pairs(Players:GetPlayers()) do 
		whitelist[v.Character] = true
	end
	for i,v in pairs(workspace:GetChildren()) do 
		if not whitelist[v] then
			pcall(function()
				v:Destroy()
				end)
		end
	end
	me.Character.HumanoidRootPart.Anchored = true
	workspace.Gravity = 0
	--maybe do UI as well
end

-- Movement recording and playback system
local recordedMovements = {}
local isRecording = false
local recordingConnection = nil
local playbackConnection = nil

-- Helper function to get the player's HRP
local function getPlayerHRP(player)
	if player and player.Character then
		return player.Character:FindFirstChild("HumanoidRootPart")
	end
	return nil
end

-- Record command
cmds["record"] = function(args, player)
	local target = getTargetFromArgs(args, player)
	if not target then
		target = player  -- Default to the command sender if no target specified
	end

	if isRecording then
		-- Stop any current recording
		if recordingConnection then
			recordingConnection:Disconnect()
			recordingConnection = nil
		end
		isRecording = false
		return
	end

	-- Start new recording
	recordedMovements = {}
	isRecording = true
	local startTime = tick()

	recordingConnection = RunService.Heartbeat:Connect(function()
		local hrp = getPlayerHRP(target)
		if not hrp then
			recordingConnection:Disconnect()
			recordingConnection = nil
			isRecording = false
			return
		end

		table.insert(recordedMovements, {
			time = tick() - startTime,
			position = hrp.Position,
			cframe = hrp.CFrame
		})
	end)
end

-- Unrecord command
cmds["unrecord"] = function(args, player)
	if recordingConnection then
		recordingConnection:Disconnect()
		recordingConnection = nil
	end
	isRecording = false
end

local isLooping = false
local loopPlaybackConnection = nil

-- Loop playback command
cmds["loopplayback"] = function(args, player)
	if #recordedMovements == 0 then
		return  -- No recorded movements to play back
	end

	-- Stop any current playback or loop
	if playbackConnection then
		playbackConnection:Disconnect()
		playbackConnection = nil
	end
	if loopPlaybackConnection then
		loopPlaybackConnection:Disconnect()
		loopPlaybackConnection = nil
	end

	isLooping = true

	-- Function to handle a single playback iteration
	local function playBackIteration()
		local myHRP = getPlayerHRP(me)
		if not myHRP then return end

		-- Get the initial position from the recording
		local initialPosition = recordedMovements[1].position

		-- Use pathfinding to move to the initial position first (only on first iteration)
		if not isLooping then return end

		local path = PathfindingService:CreatePath({
			AgentRadius = 2,
			AgentHeight = 5,
			AgentCanJump = true
		})

		path:ComputeAsync(myHRP.Position, initialPosition)

		if path.Status == Enum.PathStatus.Success then
			local waypoints = path:GetWaypoints()
			local humanoid = me.Character:FindFirstChildOfClass("Humanoid")

			if humanoid then
				-- Move to each waypoint
				for _, waypoint in ipairs(waypoints) do
					if not isLooping then break end

					humanoid:MoveTo(waypoint.Position)
					local reached = false
					local connection

					connection = humanoid.MoveToFinished:Connect(function(reached)
						if reached then
							connection:Disconnect()
						end
					end)

					-- Wait until we reach the waypoint or timeout after 5 seconds
					local startWait = tick()
					while not reached and tick() - startWait < 5 and isLooping do
						task.wait(0.1)
						reached = (myHRP.Position - waypoint.Position).Magnitude < 3
					end

					if not reached then
						-- Teleport if we can't reach the waypoint
						myHRP.CFrame = CFrame.new(waypoint.Position)
						break
					end
				end
			end
		else
			-- If pathfinding fails, teleport directly
			myHRP.CFrame = CFrame.new(initialPosition)
		end

		-- Once at the starting position, play back the recorded movements
		if not isLooping then return end

		local startTime = tick()
		local currentIndex = 1
		myHRP.Anchored = true  -- Anchor to prevent physics interference

		-- Create a new connection for this playback iteration
		local iterationConnection = nil
		iterationConnection = RunService.Heartbeat:Connect(function()
			if not isLooping then
				iterationConnection:Disconnect()
				myHRP.Anchored = false
				return
			end

			local currentTime = tick() - startTime

			-- Find the next movement in the recording
			while currentIndex <= #recordedMovements and recordedMovements[currentIndex].time <= currentTime do
				currentIndex = currentIndex + 1
			end

			if currentIndex > #recordedMovements then
				-- Finished this iteration, restart
				iterationConnection:Disconnect()
				myHRP.Anchored = false
				playBackIteration()  -- Start next iteration
				return
			end

			-- Interpolate between the previous and next position for smoother movement
			local prevIndex = math.max(1, currentIndex - 1)
			local nextIndex = math.min(#recordedMovements, currentIndex)

			local prevMovement = recordedMovements[prevIndex]
			local nextMovement = recordedMovements[nextIndex]

			local alpha = (currentTime - prevMovement.time) / (nextMovement.time - prevMovement.time)
			alpha = math.clamp(alpha, 0, 1)

			-- Interpolate position and rotation
			local interpolatedPosition = prevMovement.position:Lerp(nextMovement.position, alpha)
			local interpolatedCFrame = prevMovement.cframe:Lerp(nextMovement.cframe, alpha)

			-- Apply the interpolated movement
			myHRP.CFrame = CFrame.new(interpolatedPosition) * interpolatedCFrame.Rotation
		end)
	end

	-- Start the first iteration
	playBackIteration()
end

-- Unloop command to stop looping playback
cmds["unloopplayback"] = function(args, player)
	isLooping = false

	-- Disconnect any active playback connections
	if playbackConnection then
		playbackConnection:Disconnect()
		playbackConnection = nil
	end

	if loopPlaybackConnection then
		loopPlaybackConnection:Disconnect()
		loopPlaybackConnection = nil
	end

	-- Unanchor the character
	local myHRP = getPlayerHRP(me)
	if myHRP then
		myHRP.Anchored = false
	end
end

-- Playback command
cmds["playback"] = function(args, player)
	if #recordedMovements == 0 then
		return  -- No recorded movements to play back
	end

	-- Stop any current playback
	if playbackConnection then
		playbackConnection:Disconnect()
		playbackConnection = nil
	end

	local myHRP = getPlayerHRP(me)
	if not myHRP then return end

	-- Get the initial position from the recording
	local initialPosition = recordedMovements[1].position

	-- Use pathfinding to move to the initial position first
	local path = PathfindingService:CreatePath({
		AgentRadius = 2,
		AgentHeight = 5,
		AgentCanJump = true
	})

	path:ComputeAsync(myHRP.Position, initialPosition)

	if path.Status == Enum.PathStatus.Success then
		local waypoints = path:GetWaypoints()
		local humanoid = me.Character:FindFirstChildOfClass("Humanoid")

		if humanoid then
			-- Move to each waypoint
			for _, waypoint in ipairs(waypoints) do
				humanoid:MoveTo(waypoint.Position)
				local reached = false
				local connection

				connection = humanoid.MoveToFinished:Connect(function(reached)
					if reached then
						connection:Disconnect()
					end
				end)

				-- Wait until we reach the waypoint or timeout after 5 seconds
				local startWait = tick()
				while not reached and tick() - startWait < 5 do
					task.wait(0.1)
					reached = (myHRP.Position - waypoint.Position).Magnitude < 3
				end

				if not reached then
					-- Teleport if we can't reach the waypoint
					myHRP.CFrame = CFrame.new(waypoint.Position)
					break
				end
			end
		end
	else
		-- If pathfinding fails, teleport directly
		myHRP.CFrame = CFrame.new(initialPosition)
	end

	-- Once at the starting position, play back the recorded movements
	local startTime = tick()
	local currentIndex = 1
	myHRP.Anchored = true  -- Anchor to prevent physics interference

	playbackConnection = RunService.Heartbeat:Connect(function()
		local currentTime = tick() - startTime

		-- Find the next movement in the recording
		while currentIndex <= #recordedMovements and recordedMovements[currentIndex].time <= currentTime do
			currentIndex = currentIndex + 1
		end

		if currentIndex > #recordedMovements then
			-- Finished playback
			playbackConnection:Disconnect()
			playbackConnection = nil
			myHRP.Anchored = false
			return
		end

		-- Interpolate between the previous and next position for smoother movement
		local prevIndex = math.max(1, currentIndex - 1)
		local nextIndex = math.min(#recordedMovements, currentIndex)

		local prevMovement = recordedMovements[prevIndex]
		local nextMovement = recordedMovements[nextIndex]

		local alpha = (currentTime - prevMovement.time) / (nextMovement.time - prevMovement.time)
		alpha = math.clamp(alpha, 0, 1)

		-- Interpolate position and rotation
		local interpolatedPosition = prevMovement.position:Lerp(nextMovement.position, alpha)
		local interpolatedCFrame = prevMovement.cframe:Lerp(nextMovement.cframe, alpha)

		-- Apply the interpolated movement
		myHRP.CFrame = CFrame.new(interpolatedPosition) * interpolatedCFrame.Rotation
	end)
end

-- Unplayback command
cmds["unplayback"] = function(args, player)
	if playbackConnection then
		playbackConnection:Disconnect()
		playbackConnection = nil
	end

	local myHRP = getPlayerHRP(me)
	if myHRP then
		myHRP.Anchored = false
	end
end

cmds["unorbit"] = function(args, player)
	if cmds._orbitConn then
		cmds._orbitConn:Disconnect()
		cmds._orbitConn = nil
	end
end

cmds["unmarch"] = function(args, player)
	cmds._followPathCancel = true
end

cmds["unspin"] = function(args, player)
	if cmds._spinConn then
		cmds._spinConn:Disconnect()
		cmds._spinConn = nil
	end
end

cmds["unsink"] = function(args, player)
	local hrp = me.Character and me.Character:FindFirstChild("HumanoidRootPart")
	if hrp then
		hrp.Anchored = false
	end
end

cmds["unautojump"] = function(args, player)
	if cmds._jumpConn then
		cmds._jumpConn:Disconnect()
		cmds._jumpConn = nil
	end
end

cmds["unphase"] = function(args, player)
	if cmds._phaseConn then
		cmds._phaseConn:Disconnect()
		cmds._phaseConn = nil
	end
	local hrp = me.Character and me.Character:FindFirstChild("HumanoidRootPart")
	if hrp then
		hrp.CanCollide = true
	end
end

cmds["unboost"] = function(args, player)
	if cmds._boostConn then
		cmds._boostConn:Disconnect()
		cmds._boostConn = nil
	end
end



cmds["unpath"] = function(args, player)
	if cmds._pathThread then
		cmds._pathThreadCancel = true
		cmds._pathThread = nil
	end
end

-- Follow (using MoveTo instead of CFrame teleport)
cmds["follow"] = function(args, player)
	if args[3] then
		local plr3 = findplr(args[3])
		if not (plr3 and plr3.Name == me.Name) then return end
	end

	local target = getTargetFromArgs(args, player)
	if not target then return end

	if cmds._followConnection then
		cmds._followConnection:Disconnect()
		cmds._followConnection = nil
	end

	cmds._followConnection = RunService.RenderStepped:Connect(function()
		local char = me.Character
		if not (char and target.Character) then return end

		local hrp = char:FindFirstChild("HumanoidRootPart")
		local targetHRP = target.Character:FindFirstChild("HumanoidRootPart")
		local humanoid = char:FindFirstChildOfClass("Humanoid")
		if not (hrp and targetHRP and humanoid) then return end

		local distance = tonumber(args[4]) or -3
		local followPos = targetHRP.CFrame + targetHRP.CFrame.LookVector * distance
		targetHRP.CFrame = followPos
	end)
end

cmds["unfollow"] = function(args, player)
	if cmds._followConnection then
		cmds._followConnection:Disconnect()
		cmds._followConnection = nil
	end
	if cmds._followPathThread then
		cmds._followPathCancel = true
		cmds._followPathThread = nil
	end
end

-- Quickreset
cmds["quickreset"] = function(args, player)
	if args[2] then
		local plr2 = findplr(args[2])
		if not (plr2 and plr2.Name == me.Name) then return end
	end

	if cmds._QRConnection then
		cmds._QRConnection:Disconnect()
		cmds._QRConnection = nil
	end

	cmds._QRConnection = RunService.RenderStepped:Connect(function()
		local char = me.Character
		if not char then return end
		local humanoid = char:FindFirstChildOfClass("Humanoid")
		if humanoid and humanoid.Health > 0 and humanoid.Health < humanoid.MaxHealth then
			humanoid.Health = 0
		end
	end)
end

cmds["unQR"] = function(args, player)
	if cmds._QRConnection then
		cmds._QRConnection:Disconnect()
		cmds._QRConnection = nil
	end
end

-- FollowPath (pathfinding-based follow)
cmds["followpath"] = function(args, player)
	if args[3] then
		local plr3 = findplr(args[3])
		if not (plr3 and plr3.Name == me.Name) then return end
	end

	local target = getTargetFromArgs(args, player)
	if not target then return end

	local char = me.Character
	if not (char and target.Character) then return end

	local humanoid = char:FindFirstChildOfClass("Humanoid")
	local hrp = char:FindFirstChild("HumanoidRootPart")
	local targetHRP = target.Character:FindFirstChild("HumanoidRootPart")
	if not (humanoid and hrp and targetHRP) then return end

	-- Cancel old followpath job
	if cmds._followPathThread then
		cmds._followPathCancel = true
		cmds._followPathThread = nil
	end

	cmds._followPathCancel = false
	local distance = tonumber(args[4]) or -3

	cmds._followPathThread = task.spawn(function()
		while not cmds._followPathCancel do
			if not (me.Character and target.Character) then return end
			humanoid = me.Character:FindFirstChildOfClass("Humanoid")
			hrp = me.Character:FindFirstChild("HumanoidRootPart")
			targetHRP = target.Character:FindFirstChild("HumanoidRootPart")
			if not (humanoid and hrp and targetHRP) then return end

			-- Compute target position slightly behind
			local followPos = targetHRP.Position + targetHRP.CFrame.LookVector * distance

			-- Pathfind to that position
			local path = PathfindingService:CreatePath()
			path:ComputeAsync(hrp.Position, followPos)
			if path.Status == Enum.PathStatus.Success then
				for _, waypoint in ipairs(path:GetWaypoints()) do
					if cmds._followPathCancel then return end
					humanoid:MoveTo(waypoint.Position)
					humanoid.MoveToFinished:Wait()
				end
			end

			task.wait(1) -- recompute path every second
		end
	end)
end

cmds['except'] = function(args, player)
	
	local target = getTargetFromArgs(args,player)
	if target.Name == me.Name then
		isExcepted = true
	end
	
end

----------------------------------------------------------------
-- IDENTIFY COMMAND
----------------------------------------------------------------



cmds["identify"] = function(args, player)
	-- Example usage: _identify mashpotatos 2
	local keyword = args[2]
	local timeout = tonumber(args[3]) or 2
	if not keyword then return end

	cmds._knownBots = {}
	print("IDENTIFY started with keyword:", keyword, "timeout:", timeout)

	-- Step 1: send the keyword into chat so others hear it
	sendChatMessage(keyword)

	-- Step 2: listen for responses
	local responses = {}
	local connection

	if TextChatService.ChatVersion == Enum.ChatVersion.TextChatService then
		connection = TextChatService.MessageReceived:Connect(function(message)
			local txt = tostring(message.Text)
			if txt == keyword then
				local plr = Players:GetPlayerByUserId(message.TextSource.UserId)
				if plr then
					responses[plr.UserId] = plr
					print("Identify: bot detected ->", plr.Name)
				end
			end
		end)
	else
		local chatEvents = ReplicatedStorage:FindFirstChild("DefaultChatSystemChatEvents")
		if chatEvents then
			local onNewMessage = chatEvents:FindFirstChild("OnNewMessage")
			if onNewMessage then
				connection = onNewMessage.OnClientEvent:Connect(function(messageData)
					if messageData.Message == keyword then
						local plr = Players:FindFirstChild(messageData.FromSpeaker)
						if plr then
							responses[plr.UserId] = plr
							print("Identify: bot detected ->", plr.Name)
						end
					end
				end)
			end
		end
	end

	-- Step 3: finalize after timeout
	task.delay(timeout, function()
		if connection then connection:Disconnect() end
		cmds._knownBots = responses
		print("IDENTIFY finished. Bots found:")
		for _, plr in pairs(cmds._knownBots) do
			print(" -", plr.Name)
		end
	end)
end


warn(cmds)
