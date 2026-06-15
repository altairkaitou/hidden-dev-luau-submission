-- Connected Discord-GitHub
--!strict
--[[
    Ability Training Arena

    This is a single-script Roblox Luau demonstration for the HiddenDevs
    Luau Scripter role. It is intentionally standalone: paste this Script into
    ServerScriptService and it will build a small arena, spawn training dummies,
    give each player a combat tool, and run a server-authoritative ground wave.

    The design borrows the shape of my ENTRO ARPG combat work without copying
    its private modules: cast validation, cooldown gates, CFrame directional
    math, overlap hit detection, ARPG-style damage calculation, physics feedback,
    transient VFX cleanup, and readable class-like tables through metatables.
]]

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")
local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")

-- All tunable combat and presentation values live in CONFIG so the behavior is
-- easy to audit without hunting through the implementation for magic numbers.
local CONFIG = {
	RootFolderName = "AbilityTrainingArena_Demo",
	ArenaRadius = 72,
	ToolName = "Earth Shatter",
	CastCooldown = 1.75,
	CastLockDuration = 0.28,
	DummyRespawnTime = 1.4,
	DummyHealth = 420,
	DummyCount = 5,
	DummyTag = "HD_TargetDummy",
	Wave = {
		LaneCount = 3,
		LaneSpreadDegrees = 28,
		StepCount = 11,
		StepDelay = 0.045,
		StartOffset = 7,
		StepDistance = 4.3,
		BoxWidth = 7,
		BoxDepth = 5.8,
		BoxHeight = 8,
		BaseDamage = 42,
		DamageFalloffPerStep = 0.025,
		KnockbackForce = 72,
		UpwardForce = 20,
	},
	PlayerStats = {
		Strength = 13,
		Intelligence = 8,
		FlatPhysicalDamage = 8,
		FlatSpellDamage = 0,
		IncreasedDamagePercent = 0.22,
		CritChance = 0.18,
		CritMultiplier = 1.75,
	},
	DummyStats = {
		Armor = 18,
		FireResist = 0,
		ColdResist = 0,
		LightningResist = 0,
	},
	Colors = {
		Ground = Color3.fromRGB(41, 35, 30),
		Trim = Color3.fromRGB(126, 94, 62),
		Accent = Color3.fromRGB(255, 142, 52),
		Crit = Color3.fromRGB(255, 221, 92),
		Dummy = Color3.fromRGB(158, 112, 80),
		DummyHit = Color3.fromRGB(255, 86, 62),
		UIBack = Color3.fromRGB(16, 15, 14),
		UIText = Color3.fromRGB(238, 230, 214),
	},
}

type PlayerStats = typeof(CONFIG.PlayerStats)
type DummyStats = typeof(CONFIG.DummyStats)
type DamageResult = {
	amount: number,
	isCrit: boolean,
	raw: number,
	mitigation: number,
}
type HudRefs = {
	Root: ScreenGui,
	Status: TextLabel,
	Cooldown: TextLabel,
	Damage: TextLabel,
}
type CooldownData = { [number]: { [string]: number } }

local rng = Random.new()
local rootFolder: Folder
local arenaFolder: Folder
local dummyFolder: Folder
local effectsFolder: Folder
local hudByPlayer: { [Player]: HudRefs } = {}
local playerToolConnections: { [Player]: { RBXScriptConnection } } = {}
local activeCastTokens: { [number]: { cancelled: boolean } } = {}

-- The live demo does not trust arbitrary character state: every cast re-checks
-- finite vectors, a living Humanoid, arena bounds, and cooldown ownership.
local function isFiniteNumber(value: number): boolean
	return value == value and value ~= math.huge and value ~= -math.huge
end

local function isFiniteVector3(value: Vector3): boolean
	return isFiniteNumber(value.X) and isFiniteNumber(value.Y) and isFiniteNumber(value.Z)
end

local function clamp(value: number, minimum: number, maximum: number): number
	return math.max(minimum, math.min(maximum, value))
end

local function rounded(value: number): number
	return math.floor(value + 0.5)
end

local function clearChildrenByName(parent: Instance, name: string)
	local existing = parent:FindFirstChild(name)
	if existing then
		existing:Destroy()
	end
end

local function makeFolder(parent: Instance, name: string): Folder
	local folder = Instance.new("Folder")
	folder.Name = name
	folder.Parent = parent
	return folder
end

local function makePart(name: string, size: Vector3, cframe: CFrame, color: Color3, material: Enum.Material, parent: Instance): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.CFrame = cframe
	part.Color = color
	part.Material = material
	part.Anchored = true
	part.CanCollide = true
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = parent
	return part
end

local function weld(part0: BasePart, part1: BasePart)
	local weldConstraint = Instance.new("WeldConstraint")
	weldConstraint.Part0 = part0
	weldConstraint.Part1 = part1
	weldConstraint.Parent = part0
end

local function getCharacterParts(player: Player): (Model?, Humanoid?, BasePart?)
	local character = player.Character
	if not character then
		return nil, nil, nil
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not humanoid or not rootPart or not rootPart:IsA("BasePart") then
		return character, humanoid, nil
	end

	return character, humanoid, rootPart
end

local function flattenLookVector(rootPart: BasePart): Vector3
	local look = rootPart.CFrame.LookVector
	local flat = Vector3.new(look.X, 0, look.Z)
	if flat.Magnitude < 0.05 then
		return Vector3.new(0, 0, -1)
	end
	return flat.Unit
end

local function cframeFromForward(position: Vector3, forward: Vector3): CFrame
	local flat = Vector3.new(forward.X, 0, forward.Z)
	if flat.Magnitude < 0.05 then
		flat = Vector3.new(0, 0, -1)
	end
	return CFrame.lookAt(position, position + flat.Unit)
end

local function rotateAroundY(vector: Vector3, radians: number): Vector3
	return CFrame.Angles(0, radians, 0):VectorToWorldSpace(vector)
end

local function getArenaCenter(): Vector3
	local center = rootFolder:GetAttribute("ArenaCenter")
	if typeof(center) == "Vector3" then
		return center
	end
	return Vector3.new(0, 2, 0)
end

local function getArenaDistance(position: Vector3): number
	local center = getArenaCenter()
	local delta = Vector3.new(position.X - center.X, 0, position.Z - center.Z)
	return delta.Magnitude
end

local function createBillboard(parent: BasePart, title: string, size: UDim2, yOffset: number): TextLabel
	local gui = Instance.new("BillboardGui")
	gui.Name = title .. "Billboard"
	gui.AlwaysOnTop = true
	gui.Size = size
	gui.StudsOffsetWorldSpace = Vector3.new(0, yOffset, 0)
	gui.Parent = parent

	local label = Instance.new("TextLabel")
	label.Name = "Label"
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.Font = Enum.Font.GothamBold
	label.Text = title
	label.TextColor3 = CONFIG.Colors.UIText
	label.TextStrokeTransparency = 0.35
	label.TextScaled = true
	label.Parent = gui
	return label
end

local function showDamagePopup(adornee: BasePart, amount: number, isCrit: boolean)
	local gui = Instance.new("BillboardGui")
	gui.Name = "DamagePopup"
	gui.AlwaysOnTop = true
	gui.Size = UDim2.fromOffset(if isCrit then 120 else 92, 40)
	gui.StudsOffsetWorldSpace = Vector3.new(rng:NextNumber(-0.8, 0.8), 3.4, rng:NextNumber(-0.4, 0.4))
	gui.Parent = effectsFolder
	gui.Adornee = adornee

	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.Font = Enum.Font.GothamBlack
	label.Text = if isCrit then `CRIT {rounded(amount)}` else tostring(rounded(amount))
	label.TextColor3 = if isCrit then CONFIG.Colors.Crit else Color3.fromRGB(255, 245, 230)
	label.TextStrokeTransparency = 0.25
	label.TextScaled = true
	label.Parent = gui

	TweenService:Create(gui, TweenInfo.new(0.75, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		StudsOffsetWorldSpace = gui.StudsOffsetWorldSpace + Vector3.new(0, 2.4, 0),
	}):Play()
	TweenService:Create(label, TweenInfo.new(0.75, Enum.EasingStyle.Linear), {
		TextTransparency = 1,
		TextStrokeTransparency = 1,
	}):Play()
	Debris:AddItem(gui, 0.85)
end

-- This mirrors an ARPG-style server damage pipeline: base skill damage is
-- modified by attacker stats, crits, distance falloff, then defender mitigation.
local function calculateDamage(baseDamage: number, attacker: PlayerStats, defender: DummyStats, stepIndex: number): DamageResult
	local falloff = math.max(0.65, 1 - (stepIndex - 1) * CONFIG.Wave.DamageFalloffPerStep)
	local flatBonus = attacker.FlatPhysicalDamage + attacker.Strength * 1.35
	local increased = math.max(0, 1 + attacker.IncreasedDamagePercent)
	local rawDamage = (baseDamage + flatBonus) * increased * falloff
	local isCrit = rng:NextNumber() < clamp(attacker.CritChance, 0, 1)
	if isCrit then
		rawDamage *= math.max(1, attacker.CritMultiplier)
	end

	local armor = math.max(0, defender.Armor)
	local mitigation = clamp(armor / (armor + 120), 0, 0.75)
	return {
		amount = math.max(1, rawDamage * (1 - mitigation)),
		isCrit = isCrit,
		raw = rawDamage,
		mitigation = mitigation,
	}
end

local CooldownTracker = {}
CooldownTracker.__index = CooldownTracker

-- CooldownTracker is intentionally keyed by UserId and ability name so the
-- server owns rate limiting even though the activation comes from a Tool click.
function CooldownTracker.new(duration: number)
	return setmetatable({
		duration = duration,
		lastUsed = {} :: CooldownData,
	}, CooldownTracker)
end

function CooldownTracker:CanUse(player: Player, key: string): (boolean, number)
	local userCooldowns = self.lastUsed[player.UserId]
	if not userCooldowns then
		return true, 0
	end

	local last = userCooldowns[key]
	if not last then
		return true, 0
	end

	local elapsed = os.clock() - last
	local remaining = self.duration - elapsed
	if remaining <= 0 then
		return true, 0
	end
	return false, remaining
end

function CooldownTracker:Stamp(player: Player, key: string)
	local userCooldowns = self.lastUsed[player.UserId]
	if not userCooldowns then
		userCooldowns = {}
		self.lastUsed[player.UserId] = userCooldowns
	end
	userCooldowns[key] = os.clock()
end

function CooldownTracker:Clear(player: Player)
	self.lastUsed[player.UserId] = nil
end

local TargetDummy = {}
TargetDummy.__index = TargetDummy

-- TargetDummy wraps the model, health display, physics knockback, and respawn
-- lifecycle behind methods so hit resolution does not need to know model internals.
type TargetDummyObject = typeof(setmetatable({} :: {
	Model: Model,
	Root: BasePart,
	Humanoid: Humanoid,
	SpawnCFrame: CFrame,
	Label: TextLabel,
	HitCount: number,
	Alive: boolean,
}, TargetDummy))

local dummiesByModel: { [Model]: TargetDummyObject } = {}

function TargetDummy.new(index: number, spawnCFrame: CFrame): TargetDummyObject
	local model = Instance.new("Model")
	model.Name = `TrainingDummy_{index}`
	model.Parent = dummyFolder

	local root = Instance.new("Part")
	root.Name = "HumanoidRootPart"
	root.Size = Vector3.new(2.2, 3.4, 1.35)
	root.CFrame = spawnCFrame
	root.Color = CONFIG.Colors.Dummy
	root.Material = Enum.Material.SmoothPlastic
	root.CanCollide = true
	root.CustomPhysicalProperties = PhysicalProperties.new(1.8, 0.75, 0.08, 1, 1)
	root.Parent = model

	local torso = Instance.new("Part")
	torso.Name = "Torso"
	torso.Size = Vector3.new(2.6, 3.0, 1.15)
	torso.CFrame = root.CFrame
	torso.Color = CONFIG.Colors.Dummy
	torso.Material = Enum.Material.Wood
	torso.CanCollide = false
	torso.Massless = true
	torso.Parent = model
	weld(root, torso)

	local head = Instance.new("Part")
	head.Name = "Head"
	head.Shape = Enum.PartType.Ball
	head.Size = Vector3.new(1.45, 1.45, 1.45)
	head.CFrame = root.CFrame * CFrame.new(0, 2.25, 0)
	head.Color = Color3.fromRGB(195, 143, 92)
	head.Material = Enum.Material.SmoothPlastic
	head.CanCollide = false
	head.Massless = true
	head.Parent = model
	weld(root, head)

	local humanoid = Instance.new("Humanoid")
	humanoid.Name = "Humanoid"
	humanoid.MaxHealth = CONFIG.DummyHealth
	humanoid.Health = CONFIG.DummyHealth
	humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	humanoid.Parent = model

	model.PrimaryPart = root
	model:SetAttribute("TrainingDummy", true)
	CollectionService:AddTag(model, CONFIG.DummyTag)
	pcall(function()
		root:SetNetworkOwner(nil)
	end)

	local label = createBillboard(root, `Dummy {index} | {CONFIG.DummyHealth} HP`, UDim2.fromOffset(190, 34), 4.2)
	local self = setmetatable({
		Model = model,
		Root = root,
		Humanoid = humanoid,
		SpawnCFrame = spawnCFrame,
		Label = label,
		HitCount = 0,
		Alive = true,
	}, TargetDummy)
	dummiesByModel[model] = self
	return self
end

function TargetDummy:RefreshLabel()
	local hp = math.max(0, rounded(self.Humanoid.Health))
	self.Label.Text = `{self.Model.Name} | {hp}/{CONFIG.DummyHealth} HP | Hits {self.HitCount}`
	self.Label.TextColor3 = if self.Alive then CONFIG.Colors.UIText else Color3.fromRGB(180, 180, 180)
end

function TargetDummy:Flash()
	local original = self.Root.Color
	self.Root.Color = CONFIG.Colors.DummyHit
	TweenService:Create(self.Root, TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Color = original,
	}):Play()
end

function TargetDummy:ApplyKnockback(origin: Vector3, forward: Vector3)
	if not self.Root.Parent then
		return
	end

	local away = self.Root.Position - origin
	local flatAway = Vector3.new(away.X, 0, away.Z)
	local direction = if flatAway.Magnitude > 0.1 then flatAway.Unit else forward
	local mass = self.Root.AssemblyMass
	self.Root:ApplyImpulse((direction * CONFIG.Wave.KnockbackForce + Vector3.yAxis * CONFIG.Wave.UpwardForce) * mass)
	self.Root.AssemblyAngularVelocity = Vector3.new(rng:NextNumber(-2, 2), rng:NextNumber(-5, 5), rng:NextNumber(-2, 2))
end

function TargetDummy:RespawnAfterDelay()
	self.Alive = false
	self:RefreshLabel()
	task.delay(CONFIG.DummyRespawnTime, function()
		if not self.Model.Parent then
			return
		end
		self.Root.AssemblyLinearVelocity = Vector3.zero
		self.Root.AssemblyAngularVelocity = Vector3.zero
		self.Model:PivotTo(self.SpawnCFrame)
		self.Humanoid.Health = CONFIG.DummyHealth
		self.Alive = true
		self:RefreshLabel()
	end)
end

function TargetDummy:TakeHit(result: DamageResult, origin: Vector3, forward: Vector3): boolean
	if not self.Alive or self.Humanoid.Health <= 0 then
		return false
	end

	self.HitCount += 1
	self.Humanoid.Health = math.max(0, self.Humanoid.Health - result.amount)
	self:ApplyKnockback(origin, forward)
	self:Flash()
	showDamagePopup(self.Root, result.amount, result.isCrit)
	self:RefreshLabel()

	if self.Humanoid.Health <= 0 then
		self:RespawnAfterDelay()
	end
	return true
end

local Ability = {}
Ability.__index = Ability

local setHud: (Player, "Status" | "Cooldown" | "Damage", string, Color3) -> ()

-- Ability coordinates validation, cooldowns, CFrame wave math, overlap queries,
-- damage application, VFX, and HUD feedback as one cohesive gameplay system.
type AbilityObject = typeof(setmetatable({} :: {
	Name: string,
	Cooldowns: any,
	TotalDamageByPlayer: { [number]: number },
	HitCountByPlayer: { [number]: number },
}, Ability))

function Ability.new(name: string, cooldowns: any): AbilityObject
	return setmetatable({
		Name = name,
		Cooldowns = cooldowns,
		TotalDamageByPlayer = {},
		HitCountByPlayer = {},
	}, Ability)
end

function Ability:GetTotalDamage(player: Player): number
	return self.TotalDamageByPlayer[player.UserId] or 0
end

function Ability:GetHitCount(player: Player): number
	return self.HitCountByPlayer[player.UserId] or 0
end

function Ability:AddDamage(player: Player, damage: number)
	self.TotalDamageByPlayer[player.UserId] = self:GetTotalDamage(player) + damage
	self.HitCountByPlayer[player.UserId] = self:GetHitCount(player) + 1
end

function Ability:Validate(player: Player): (boolean, string, Model?, Humanoid?, BasePart?)
	local character, humanoid, rootPart = getCharacterParts(player)
	if not character or not humanoid or not rootPart then
		return false, "Character not ready.", character, humanoid, rootPart
	end

	if humanoid.Health <= 0 then
		return false, "You cannot cast while defeated.", character, humanoid, rootPart
	end

	if not isFiniteVector3(rootPart.Position) then
		return false, "Invalid character position.", character, humanoid, rootPart
	end

	if getArenaDistance(rootPart.Position) > CONFIG.ArenaRadius then
		return false, "Move into the arena before casting.", character, humanoid, rootPart
	end

	local canUse, remaining = self.Cooldowns:CanUse(player, self.Name)
	if not canUse then
		return false, `Cooldown: {string.format("%.1f", remaining)}s`, character, humanoid, rootPart
	end

	return true, "Ready.", character, humanoid, rootPart
end

function Ability:StartCooldownHud(player: Player)
	task.spawn(function()
		while player.Parent do
			local _, remaining = self.Cooldowns:CanUse(player, self.Name)
			if remaining <= 0 then
				setHud(player, "Cooldown", "Cooldown ready", Color3.fromRGB(116, 230, 150))
				break
			end
			setHud(player, "Cooldown", `Cooldown {string.format("%.1f", remaining)}s`, CONFIG.Colors.Crit)
			task.wait(0.1)
		end
	end)
end

function Ability:ApplyCastLock(humanoid: Humanoid)
	local originalSpeed = humanoid.WalkSpeed
	local originalJump = humanoid.JumpPower
	humanoid.WalkSpeed = math.max(4, originalSpeed * 0.28)
	humanoid.JumpPower = 0
	task.delay(CONFIG.CastLockDuration, function()
		if humanoid.Parent then
			humanoid.WalkSpeed = originalSpeed
			humanoid.JumpPower = originalJump
		end
	end)
end

function Ability:ComputeLaneAngles(): { number }
	local laneAngles = {}
	local count = CONFIG.Wave.LaneCount
	for lane = 1, count do
		local t = if count > 1 then (lane - 1) / (count - 1) - 0.5 else 0
		table.insert(laneAngles, math.rad(t * 2 * CONFIG.Wave.LaneSpreadDegrees))
	end
	return laneAngles
end

function Ability:SpawnStepVisual(stepCFrame: CFrame, laneIndex: number, stepIndex: number)
	local sizeScale = 1 + stepIndex / CONFIG.Wave.StepCount
	local slab = Instance.new("Part")
	slab.Name = "GroundWaveHitboxVisual"
	slab.Anchored = true
	slab.CanCollide = false
	slab.CanTouch = false
	slab.CanQuery = false
	slab.Material = Enum.Material.Neon
	slab.Color = CONFIG.Colors.Accent
	slab.Transparency = 0.42
	slab.Size = Vector3.new(CONFIG.Wave.BoxWidth * sizeScale, 0.18, CONFIG.Wave.BoxDepth)
	slab.CFrame = stepCFrame * CFrame.new(0, -2.65, 0)
	slab.Parent = effectsFolder

	TweenService:Create(slab, TweenInfo.new(0.32, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Transparency = 1,
		Size = slab.Size + Vector3.new(2.5, 0, 2.5),
	}):Play()
	Debris:AddItem(slab, 0.38)

	if stepIndex % 2 == 0 and laneIndex == 2 then
		self:SpawnDebris(stepCFrame.Position)
	end
end

function Ability:SpawnDebris(position: Vector3)
	for _ = 1, 3 do
		local chunk = Instance.new("Part")
		chunk.Name = "PhysicsDebris"
		chunk.Size = Vector3.new(rng:NextNumber(0.35, 0.9), rng:NextNumber(0.2, 0.55), rng:NextNumber(0.35, 0.9))
		chunk.Material = Enum.Material.Rock
		chunk.Color = Color3.fromRGB(rng:NextInteger(70, 105), rng:NextInteger(54, 75), rng:NextInteger(38, 56))
		chunk.CFrame = CFrame.new(position + Vector3.new(rng:NextNumber(-2, 2), 1.2, rng:NextNumber(-2, 2)))
			* CFrame.Angles(rng:NextNumber(0, math.pi), rng:NextNumber(0, math.pi), rng:NextNumber(0, math.pi))
		chunk.CanCollide = true
		chunk.Parent = effectsFolder
		chunk.AssemblyLinearVelocity = Vector3.new(rng:NextNumber(-12, 12), rng:NextNumber(16, 28), rng:NextNumber(-12, 12))
		chunk.AssemblyAngularVelocity = Vector3.new(rng:NextNumber(-12, 12), rng:NextNumber(-12, 12), rng:NextNumber(-12, 12))
		task.delay(0.8, function()
			if chunk.Parent then
				TweenService:Create(chunk, TweenInfo.new(0.35), { Transparency = 1 }):Play()
			end
		end)
		Debris:AddItem(chunk, 1.3)
	end
end

function Ability:ResolveHits(player: Player, stepCFrame: CFrame, stepIndex: number, hitModels: { [Model]: boolean }, forward: Vector3)
	-- OverlapParams limits the expensive spatial query to the dummy folder, and
	-- hitModels prevents one cast from multi-hitting the same dummy through lanes.
	local overlap = OverlapParams.new()
	overlap.FilterType = Enum.RaycastFilterType.Include
	overlap.FilterDescendantsInstances = { dummyFolder }

	local boxSize = Vector3.new(CONFIG.Wave.BoxWidth, CONFIG.Wave.BoxHeight, CONFIG.Wave.BoxDepth)
	local parts = Workspace:GetPartBoundsInBox(stepCFrame, boxSize, overlap)
	for _, part in ipairs(parts) do
		local model = part:FindFirstAncestorOfClass("Model")
		if not model or hitModels[model] then
			continue
		end

		local dummy = dummiesByModel[model]
		if not dummy then
			continue
		end

		hitModels[model] = true
		local damageResult = calculateDamage(CONFIG.Wave.BaseDamage, CONFIG.PlayerStats, CONFIG.DummyStats, stepIndex)
		if dummy:TakeHit(damageResult, stepCFrame.Position, forward) then
			self:AddDamage(player, damageResult.amount)
			setHud(player, "Damage", `Total damage {rounded(self:GetTotalDamage(player))} | Hits {self:GetHitCount(player)}`, CONFIG.Colors.UIText)
		end
	end
end

function Ability:Cast(player: Player)
	local isValid, reason, _character, humanoid, rootPart = self:Validate(player)
	if not isValid or not humanoid or not rootPart then
		setHud(player, "Status", reason, Color3.fromRGB(255, 120, 90))
		return
	end

	self.Cooldowns:Stamp(player, self.Name)
	self:StartCooldownHud(player)
	self:ApplyCastLock(humanoid)
	setHud(player, "Status", "Earth Shatter cast accepted by server.", Color3.fromRGB(116, 230, 150))

	local userId = player.UserId
	local previous = activeCastTokens[userId]
	if previous then
		previous.cancelled = true
	end
	local token = { cancelled = false }
	activeCastTokens[userId] = token

	local origin = rootPart.Position
	local forward = flattenLookVector(rootPart)
	local castCFrame = cframeFromForward(origin, forward)
	local laneAngles = self:ComputeLaneAngles()
	local hitModels: { [Model]: boolean } = {}

	task.spawn(function()
		for stepIndex = 1, CONFIG.Wave.StepCount do
			if token.cancelled then
				break
			end

			for laneIndex, angle in ipairs(laneAngles) do
				local laneForward = rotateAroundY(forward, angle).Unit
				local distance = CONFIG.Wave.StartOffset + stepIndex * CONFIG.Wave.StepDistance
				local stepPosition = castCFrame.Position + laneForward * distance
				local stepCFrame = cframeFromForward(stepPosition, laneForward)
				self:SpawnStepVisual(stepCFrame, laneIndex, stepIndex)
				self:ResolveHits(player, stepCFrame, stepIndex, hitModels, laneForward)
			end

			task.wait(CONFIG.Wave.StepDelay)
		end

		if activeCastTokens[userId] == token then
			activeCastTokens[userId] = nil
		end
	end)
end

local cooldowns = CooldownTracker.new(CONFIG.CastCooldown)
local earthShatter = Ability.new("earth_shatter", cooldowns)

setHud = function(player: Player, key: "Status" | "Cooldown" | "Damage", text: string, color: Color3)
	local hud = hudByPlayer[player]
	if not hud then
		return
	end

	local label = hud[key]
	label.Text = text
	label.TextColor3 = color
end

local function createHud(player: Player)
	local playerGui = player:FindFirstChildOfClass("PlayerGui") or player:WaitForChild("PlayerGui", 10)
	if not playerGui then
		return
	end

	clearChildrenByName(playerGui, "AbilityTrainingArenaHud")

	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "AbilityTrainingArenaHud"
	screenGui.ResetOnSpawn = false
	screenGui.Parent = playerGui

	local frame = Instance.new("Frame")
	frame.Name = "Panel"
	frame.AnchorPoint = Vector2.new(0, 1)
	frame.Position = UDim2.new(0, 18, 1, -18)
	frame.Size = UDim2.fromOffset(360, 126)
	frame.BackgroundColor3 = CONFIG.Colors.UIBack
	frame.BackgroundTransparency = 0.08
	frame.BorderSizePixel = 0
	frame.Parent = screenGui

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = frame

	local stroke = Instance.new("UIStroke")
	stroke.Color = CONFIG.Colors.Trim
	stroke.Thickness = 1
	stroke.Transparency = 0.25
	stroke.Parent = frame

	local function line(name: string, y: number, text: string, size: number): TextLabel
		local label = Instance.new("TextLabel")
		label.Name = name
		label.BackgroundTransparency = 1
		label.Position = UDim2.fromOffset(14, y)
		label.Size = UDim2.new(1, -28, 0, size)
		label.Font = Enum.Font.GothamMedium
		label.TextXAlignment = Enum.TextXAlignment.Left
		label.TextSize = size
		label.TextColor3 = CONFIG.Colors.UIText
		label.Text = text
		label.Parent = frame
		return label
	end

	local title = line("Title", 10, "Ability Training Arena", 18)
	title.Font = Enum.Font.GothamBold
	local status = line("Status", 38, "Equip Earth Shatter, face the dummies, click to cast.", 14)
	local cooldown = line("Cooldown", 66, "Cooldown ready", 14)
	local damage = line("Damage", 92, "Total damage 0 | Hits 0", 14)

	hudByPlayer[player] = {
		Root = screenGui,
		Status = status,
		Cooldown = cooldown,
		Damage = damage,
	}
end

local function makeTool(): Tool
	local tool = Instance.new("Tool")
	tool.Name = CONFIG.ToolName
	tool.ToolTip = "Server-authoritative CFrame ground wave"
	tool.RequiresHandle = true
	tool.CanBeDropped = false

	local handle = Instance.new("Part")
	handle.Name = "Handle"
	handle.Size = Vector3.new(0.55, 4.4, 0.55)
	handle.Material = Enum.Material.Metal
	handle.Color = Color3.fromRGB(95, 79, 66)
	handle.Parent = tool

	local cap = Instance.new("Part")
	cap.Name = "StoneHead"
	cap.Size = Vector3.new(1.7, 1.0, 1.05)
	cap.Material = Enum.Material.Slate
	cap.Color = CONFIG.Colors.Trim
	cap.CFrame = handle.CFrame * CFrame.new(0, 1.65, 0)
	cap.Parent = tool
	weld(handle, cap)
	return tool
end

local function disconnectToolConnections(player: Player)
	local connections = playerToolConnections[player]
	if not connections then
		return
	end

	for _, connection in ipairs(connections) do
		connection:Disconnect()
	end
	playerToolConnections[player] = nil
end

local function giveTool(player: Player)
	disconnectToolConnections(player)

	local backpack = player:FindFirstChildOfClass("Backpack") or player:WaitForChild("Backpack", 10)
	if not backpack then
		return
	end

	for _, container in ipairs({ backpack, player.Character }) do
		if container then
			local oldTool = container:FindFirstChild(CONFIG.ToolName)
			if oldTool then
				oldTool:Destroy()
			end
		end
	end

	local tool = makeTool()
	tool.Parent = backpack
	playerToolConnections[player] = {
		tool.Activated:Connect(function()
			earthShatter:Cast(player)
		end),
	}
end

local function buildArena()
	-- The script rebuilds only its own demo folder, leaving the rest of the copied
	-- place untouched while still providing a complete working demonstration.
	clearChildrenByName(Workspace, CONFIG.RootFolderName)
	rootFolder = makeFolder(Workspace, CONFIG.RootFolderName)
	rootFolder:SetAttribute("ArenaCenter", Vector3.new(0, 3, 0))
	arenaFolder = makeFolder(rootFolder, "Arena")
	dummyFolder = makeFolder(rootFolder, "Dummies")
	effectsFolder = makeFolder(rootFolder, "TransientEffects")

	makePart("ArenaFloor", Vector3.new(120, 1, 120), CFrame.new(0, 0, 0), CONFIG.Colors.Ground, Enum.Material.Slate, arenaFolder)
	makePart("CastPad", Vector3.new(14, 0.28, 14), CFrame.new(0, 0.68, 22), CONFIG.Colors.Trim, Enum.Material.WoodPlanks, arenaFolder)
	makePart("BackWall", Vector3.new(124, 10, 2), CFrame.new(0, 5, -61), CONFIG.Colors.Trim, Enum.Material.Rock, arenaFolder)
	makePart("LeftWall", Vector3.new(2, 10, 124), CFrame.new(-61, 5, 0), CONFIG.Colors.Trim, Enum.Material.Rock, arenaFolder)
	makePart("RightWall", Vector3.new(2, 10, 124), CFrame.new(61, 5, 0), CONFIG.Colors.Trim, Enum.Material.Rock, arenaFolder)

	local spawn = Instance.new("SpawnLocation")
	spawn.Name = "SubmissionSpawn"
	spawn.Size = Vector3.new(8, 1, 8)
	spawn.CFrame = CFrame.new(0, 1.1, 31)
	spawn.Color = Color3.fromRGB(65, 95, 82)
	spawn.Material = Enum.Material.Neon
	spawn.Anchored = true
	spawn.Neutral = true
	spawn.Duration = 0
	spawn.Parent = arenaFolder

	local signPart = makePart("InstructionSign", Vector3.new(18, 8, 0.6), CFrame.new(0, 6, 41), Color3.fromRGB(24, 22, 20), Enum.Material.Wood, arenaFolder)
	createBillboard(signPart, "Face dummies and click Earth Shatter", UDim2.fromOffset(360, 42), 5.8)

	for i = 1, CONFIG.DummyCount do
		local spread = (i - (CONFIG.DummyCount + 1) / 2) * 9
		local depth = -8 - math.abs(i - 3) * 3
		local spawnCFrame = CFrame.new(spread, 3.1, depth) * CFrame.Angles(0, math.rad(180), 0)
		TargetDummy.new(i, spawnCFrame)
	end
end

local function setupPlayer(player: Player)
	-- Player setup is repeated on respawn because PlayerGui and Backpack are
	-- recreated by Roblox; old tool connections are cleaned before a new tool is given.
	createHud(player)
	giveTool(player)

	player.CharacterAdded:Connect(function(character)
		task.wait(0.25)
		local rootPart = character:FindFirstChild("HumanoidRootPart")
		if rootPart and rootPart:IsA("BasePart") then
			rootPart.CFrame = CFrame.lookAt(Vector3.new(0, 4, 31), Vector3.new(0, 4, -10))
		end
		createHud(player)
		giveTool(player)
	end)
end

local function cleanupPlayer(player: Player)
	disconnectToolConnections(player)
	hudByPlayer[player] = nil
	cooldowns:Clear(player)
	local token = activeCastTokens[player.UserId]
	if token then
		token.cancelled = true
	end
	activeCastTokens[player.UserId] = nil
end

local function printStartupSummary()
	local sourceCount = 0
	for _, instance in ipairs(game:GetDescendants()) do
		if instance:IsA("LuaSourceContainer") then
			sourceCount += 1
		end
	end

	warn(`[AbilityTrainingArena] Ready. Source containers in place: {sourceCount}. Running server mode: {RunService:IsServer()}.`)
	warn("[AbilityTrainingArena] The demo is intentionally one Script; all modules from the copied project were removed.")
end

buildArena()

Players.PlayerAdded:Connect(setupPlayer)
Players.PlayerRemoving:Connect(cleanupPlayer)

for _, player in ipairs(Players:GetPlayers()) do
	task.spawn(setupPlayer, player)
end

printStartupSummary()
