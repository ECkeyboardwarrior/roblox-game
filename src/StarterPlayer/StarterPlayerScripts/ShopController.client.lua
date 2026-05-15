--!strict
--[[
    ShopController.client.lua
    -------------------------
    Builds the Shop UI at runtime and routes purchase requests/responses.

    Layout:
      * A small "Shop" toggle button bottom-right of the screen.
      * Click it -> a centered panel tweens in with a scrolling list of items.
      * Each row: name, description, cost/owned/maxed state, Buy button.
      * Click Buy -> fires RequestPurchase. Result row flashes green/red.

    All state lives in the player's profile attributes (synced by Main.client),
    so the panel rebuilds itself on every change.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared:WaitForChild("Constants"))
local Remotes   = require(Shared:WaitForChild("Remotes"))
local ShopItems = require(Shared:WaitForChild("ShopItems"))
local WispTypes = require(Shared:WaitForChild("WispTypes"))

local LocalPlayer = Players.LocalPlayer
local playerGui = LocalPlayer:WaitForChild("PlayerGui")
local profile = LocalPlayer:WaitForChild("Profile", 10)

local ownedWispIds: { string } = {}  -- updated via WispRosterChanged

-- ---------- read-only profile snapshot for ShopItems helpers ----------
-- ShopItems.currentTier expects a profile-like table; we can't pass a Folder
-- of attributes directly, so we copy the fields it needs into a plain table.
local function snapshot(): any
    local snap = {
        shards = (profile and profile:GetAttribute("shards")) or 0,
        lanternCapacity = (profile and profile:GetAttribute("lanternCapacity")) or 50,
        wispSlots = (profile and profile:GetAttribute("wispSlots")) or 5,
        ownedWispIds = ownedWispIds,
    }
    return snap
end

-- ---------- root GUI ----------

local screen = Instance.new("ScreenGui")
screen.Name = "SpiritGroveShop"
screen.ResetOnSpawn = false
screen.IgnoreGuiInset = false
screen.Parent = playerGui

-- Toggle button (bottom-right)
local toggleBtn = Instance.new("TextButton")
toggleBtn.Name = "ShopToggle"
toggleBtn.AnchorPoint = Vector2.new(1, 1)
toggleBtn.Position = UDim2.new(1, -16, 1, -16)
toggleBtn.Size = UDim2.fromOffset(120, 40)
toggleBtn.BackgroundColor3 = Color3.fromRGB(60, 90, 130)
toggleBtn.Text = "Shop"
toggleBtn.TextColor3 = Color3.fromRGB(245, 245, 250)
toggleBtn.Font = Enum.Font.GothamBold
toggleBtn.TextSize = 18
toggleBtn.BorderSizePixel = 0
toggleBtn.Parent = screen

local toggleCorner = Instance.new("UICorner")
toggleCorner.CornerRadius = UDim.new(0, 8)
toggleCorner.Parent = toggleBtn

local toggleStroke = Instance.new("UIStroke")
toggleStroke.Color = Color3.fromRGB(140, 190, 230)
toggleStroke.Thickness = 1.5
toggleStroke.Transparency = 0.3
toggleStroke.Parent = toggleBtn

-- Panel (centered, hidden by default)
local panel = Instance.new("Frame")
panel.Name = "Panel"
panel.AnchorPoint = Vector2.new(0.5, 0.5)
panel.Position = UDim2.fromScale(0.5, 0.55)
panel.Size = UDim2.fromOffset(440, 360)
panel.BackgroundColor3 = Color3.fromRGB(22, 25, 35)
panel.BackgroundTransparency = 0.05
panel.BorderSizePixel = 0
panel.Visible = false
panel.Parent = screen

local panelCorner = Instance.new("UICorner")
panelCorner.CornerRadius = UDim.new(0, 12)
panelCorner.Parent = panel

local panelStroke = Instance.new("UIStroke")
panelStroke.Color = Color3.fromRGB(130, 180, 220)
panelStroke.Thickness = 2
panelStroke.Transparency = 0.3
panelStroke.Parent = panel

local panelPad = Instance.new("UIPadding")
panelPad.PaddingTop = UDim.new(0, 12)
panelPad.PaddingBottom = UDim.new(0, 12)
panelPad.PaddingLeft = UDim.new(0, 14)
panelPad.PaddingRight = UDim.new(0, 14)
panelPad.Parent = panel

local header = Instance.new("TextLabel")
header.Name = "Header"
header.BackgroundTransparency = 1
header.Size = UDim2.new(1, 0, 0, 30)
header.Font = Enum.Font.GothamBlack
header.TextSize = 22
header.Text = "Spirit Shrine"
header.TextColor3 = Color3.fromRGB(240, 240, 250)
header.TextXAlignment = Enum.TextXAlignment.Left
header.Parent = panel

local closeBtn = Instance.new("TextButton")
closeBtn.Name = "Close"
closeBtn.AnchorPoint = Vector2.new(1, 0)
closeBtn.Position = UDim2.new(1, 0, 0, 0)
closeBtn.Size = UDim2.fromOffset(32, 32)
closeBtn.BackgroundColor3 = Color3.fromRGB(80, 50, 60)
closeBtn.Text = "X"
closeBtn.TextColor3 = Color3.fromRGB(240, 240, 240)
closeBtn.Font = Enum.Font.GothamBold
closeBtn.TextSize = 16
closeBtn.BorderSizePixel = 0
closeBtn.Parent = panel

local closeCorner = Instance.new("UICorner")
closeCorner.CornerRadius = UDim.new(0, 6)
closeCorner.Parent = closeBtn

local scroll = Instance.new("ScrollingFrame")
scroll.Name = "Items"
scroll.Position = UDim2.new(0, 0, 0, 42)
scroll.Size = UDim2.new(1, 0, 1, -42)
scroll.BackgroundTransparency = 1
scroll.BorderSizePixel = 0
scroll.ScrollBarThickness = 6
scroll.CanvasSize = UDim2.new()
scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
scroll.Parent = panel

local scrollLayout = Instance.new("UIListLayout")
scrollLayout.FillDirection = Enum.FillDirection.Vertical
scrollLayout.Padding = UDim.new(0, 8)
scrollLayout.SortOrder = Enum.SortOrder.LayoutOrder
scrollLayout.Parent = scroll

-- ---------- row factory ----------

type Row = {
    frame: Frame,
    nameLabel: TextLabel,
    descLabel: TextLabel,
    statusLabel: TextLabel,
    buyBtn: TextButton,
}

local rows: { [string]: Row } = {}

local function makeRow(itemId: string, order: number, displayName: string, accent: Color3): Row
    local frame = Instance.new("Frame")
    frame.Name = itemId
    frame.LayoutOrder = order
    frame.Size = UDim2.new(1, -8, 0, 70)
    frame.BackgroundColor3 = Color3.fromRGB(35, 40, 55)
    frame.BorderSizePixel = 0
    frame.Parent = scroll

    local rc = Instance.new("UICorner")
    rc.CornerRadius = UDim.new(0, 8)
    rc.Parent = frame

    local stripe = Instance.new("Frame")
    stripe.Size = UDim2.new(0, 4, 1, 0)
    stripe.BackgroundColor3 = accent
    stripe.BorderSizePixel = 0
    stripe.Parent = frame
    local sc = Instance.new("UICorner")
    sc.CornerRadius = UDim.new(0, 8)
    sc.Parent = stripe

    local rpad = Instance.new("UIPadding")
    rpad.PaddingLeft = UDim.new(0, 14)
    rpad.PaddingRight = UDim.new(0, 10)
    rpad.PaddingTop = UDim.new(0, 8)
    rpad.PaddingBottom = UDim.new(0, 8)
    rpad.Parent = frame

    local name = Instance.new("TextLabel")
    name.BackgroundTransparency = 1
    name.Position = UDim2.fromOffset(0, 0)
    name.Size = UDim2.new(0.65, 0, 0, 22)
    name.Font = Enum.Font.GothamSemibold
    name.TextSize = 16
    name.TextXAlignment = Enum.TextXAlignment.Left
    name.TextColor3 = Color3.fromRGB(240, 240, 245)
    name.Text = displayName
    name.Parent = frame

    local desc = Instance.new("TextLabel")
    desc.BackgroundTransparency = 1
    desc.Position = UDim2.fromOffset(0, 24)
    desc.Size = UDim2.new(0.65, 0, 0, 30)
    desc.Font = Enum.Font.Gotham
    desc.TextSize = 13
    desc.TextXAlignment = Enum.TextXAlignment.Left
    desc.TextYAlignment = Enum.TextYAlignment.Top
    desc.TextWrapped = true
    desc.TextColor3 = Color3.fromRGB(190, 195, 210)
    desc.Text = ""
    desc.Parent = frame

    local status = Instance.new("TextLabel")
    status.BackgroundTransparency = 1
    status.AnchorPoint = Vector2.new(1, 0)
    status.Position = UDim2.new(1, 0, 0, 0)
    status.Size = UDim2.new(0.33, 0, 0, 22)
    status.Font = Enum.Font.GothamSemibold
    status.TextSize = 14
    status.TextXAlignment = Enum.TextXAlignment.Right
    status.TextColor3 = Color3.fromRGB(220, 220, 230)
    status.Text = ""
    status.Parent = frame

    local buy = Instance.new("TextButton")
    buy.AnchorPoint = Vector2.new(1, 1)
    buy.Position = UDim2.new(1, 0, 1, 0)
    buy.Size = UDim2.fromOffset(110, 28)
    buy.BackgroundColor3 = Color3.fromRGB(70, 130, 90)
    buy.Text = "Buy"
    buy.TextColor3 = Color3.fromRGB(240, 245, 240)
    buy.Font = Enum.Font.GothamBold
    buy.TextSize = 14
    buy.BorderSizePixel = 0
    buy.Parent = frame
    local bc = Instance.new("UICorner")
    bc.CornerRadius = UDim.new(0, 6)
    bc.Parent = buy

    buy.MouseButton1Click:Connect(function()
        Remotes.get(Constants.REMOTES.RequestPurchase):FireServer(itemId)
    end)

    return { frame = frame, nameLabel = name, descLabel = desc, statusLabel = status, buyBtn = buy }
end

-- ---------- render / re-render ----------

local function accentFor(item: ShopItems.ShopItem): Color3
    if item.kind == "wisp_unlock" and item.wispId then
        local def = WispTypes.get(item.wispId)
        if def then return def.color end
    end
    return Color3.fromRGB(120, 200, 255)
end

local function buildAllRows()
    for _, id in ShopItems.order() do
        local item = ShopItems.get(id)
        if not item then continue end
        if not rows[id] then
            rows[id] = makeRow(id, table.find(ShopItems.order(), id) or 0, item.displayName, accentFor(item))
        end
    end
end

local function setBuyState(row: Row, enabled: boolean, label: string, color: Color3)
    row.buyBtn.Active = enabled
    row.buyBtn.AutoButtonColor = enabled
    row.buyBtn.Text = label
    row.buyBtn.BackgroundColor3 = color
    row.buyBtn.TextTransparency = enabled and 0 or 0.3
end

local function ownsWisp(wispId: string): boolean
    for _, id in ownedWispIds do
        if id == wispId then return true end
    end
    return false
end

local function rerender()
    local snap = snapshot()
    for _, id in ShopItems.order() do
        local item = ShopItems.get(id)
        local row = rows[id]
        if not item or not row then continue end

        if item.kind == "upgrade" then
            local tier = ShopItems.currentTier(item, snap)
            local cost = ShopItems.nextTierCost(item, snap)
            local nextVal = ShopItems.nextTierValue(item, snap)
            local maxTier = item.tiers and #item.tiers or 0

            row.descLabel.Text = item.description
            if not cost or not nextVal then
                row.statusLabel.Text = string.format("Tier %d / %d (max)", tier, maxTier)
                setBuyState(row, false, "Maxed", Color3.fromRGB(70, 75, 90))
            else
                row.statusLabel.Text = string.format("Tier %d → %d  •  next: %d", tier, tier + 1, nextVal)
                local canAfford = snap.shards >= cost
                setBuyState(row, canAfford,
                    string.format("Buy: %d ✦", cost),
                    canAfford and Color3.fromRGB(70, 130, 90) or Color3.fromRGB(90, 75, 75))
            end

        elseif item.kind == "wisp_unlock" then
            row.descLabel.Text = item.description
            local cost = item.cost or 0
            if item.wispId and ownsWisp(item.wispId) then
                row.statusLabel.Text = "Owned"
                setBuyState(row, false, "Owned", Color3.fromRGB(70, 75, 90))
            else
                local missingReq = nil
                if item.requires then
                    for _, prereq in item.requires do
                        if not ownsWisp(prereq) then
                            missingReq = prereq
                            break
                        end
                    end
                end
                if missingReq then
                    local req = WispTypes.get(missingReq)
                    row.statusLabel.Text = string.format("Requires %s", req and req.displayName or missingReq)
                    setBuyState(row, false, "Locked", Color3.fromRGB(70, 75, 90))
                else
                    local canAfford = snap.shards >= cost
                    row.statusLabel.Text = "Wisp unlock"
                    setBuyState(row, canAfford,
                        string.format("Buy: %d ✦", cost),
                        canAfford and Color3.fromRGB(70, 130, 90) or Color3.fromRGB(90, 75, 75))
                end
            end
        end
    end
end

-- ---------- open / close ----------

local function setOpen(open: boolean)
    if open then
        panel.Visible = true
        panel.Size = UDim2.fromOffset(0, 0)
        panel.BackgroundTransparency = 1
        TweenService:Create(panel, TweenInfo.new(0.18, Enum.EasingStyle.Quad), {
            Size = UDim2.fromOffset(440, 360),
            BackgroundTransparency = 0.05,
        }):Play()
        rerender()
    else
        local t = TweenService:Create(panel, TweenInfo.new(0.14, Enum.EasingStyle.Quad), {
            Size = UDim2.fromOffset(0, 0),
            BackgroundTransparency = 1,
        })
        t:Play()
        t.Completed:Wait()
        panel.Visible = false
    end
end

toggleBtn.MouseButton1Click:Connect(function() setOpen(not panel.Visible) end)
closeBtn.MouseButton1Click:Connect(function() setOpen(false) end)

-- ---------- live updates ----------

if profile then
    profile.AttributeChanged:Connect(function()
        if panel.Visible then rerender() end
    end)
end

Remotes.get(Constants.REMOTES.WispRosterChanged).OnClientEvent:Connect(function(ids)
    ownedWispIds = (typeof(ids) == "table") and ids or {}
    if panel.Visible then rerender() end
end)

-- Purchase result -> flash row green/red and show reason if any.
Remotes.get(Constants.REMOTES.PurchaseResult).OnClientEvent:Connect(function(result)
    if typeof(result) ~= "table" then return end
    local row = rows[result.itemId]
    if not row then return end

    local flashColor = result.ok and Color3.fromRGB(70, 160, 90) or Color3.fromRGB(160, 70, 70)
    local original = row.frame.BackgroundColor3
    row.frame.BackgroundColor3 = flashColor
    TweenService:Create(row.frame, TweenInfo.new(0.5), { BackgroundColor3 = original }):Play()

    if not result.ok and result.reason then
        row.statusLabel.Text = result.reason
    end
end)

buildAllRows()
rerender()
