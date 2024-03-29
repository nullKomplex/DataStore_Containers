--[[	*** DataStore_Containers ***
Written by : Thaoky, EU-Marécages de Zangar
June 21st, 2009

This modules takes care of scanning & storing player bags, bank, & guild banks

Extended services: 
	- guild communication: at logon, sends guild bank tab info (last visit) to guildmates
	- triggers events to manage transfers of guild bank tabs
--]]
if not DataStore then return end

local addonName = "DataStore_Containers"

_G[addonName] = LibStub("AceAddon-3.0"):NewAddon(addonName, "AceConsole-3.0", "AceEvent-3.0", "AceComm-3.0", "AceSerializer-3.0")

local addon = _G[addonName]

local THIS_ACCOUNT = "Default"
local commPrefix = "DS_Cont"		-- let's keep it a bit shorter than the addon name, this goes on a comm channel, a byte is a byte ffs :p
local MAIN_BANK_SLOTS = 100		-- bag id of the 28 main bank slots

local guildMembers = {} 	-- hash table containing guild member info (tab timestamps)

-- Message types
local MSG_SEND_BANK_TIMESTAMPS				= 1	-- broacast at login
local MSG_BANK_TIMESTAMPS_REPLY				= 2	-- reply to someone else's login
local MSG_BANKTAB_REQUEST						= 3	-- request bank tab data ..
local MSG_BANKTAB_REQUEST_ACK					= 4	-- .. ack the request, tell the requester to wait
local MSG_BANKTAB_REQUEST_REJECTED			= 5	-- .. refuse the request
local MSG_BANKTAB_TRANSFER						= 6	-- .. or send the data

local VOID_STORAGE_TAB = "VoidStorage.Tab"

local containersScanningTooltip = CreateFrame("GameTooltip", "DataStoreCustomScanTooltipForPets", nil, "GameTooltipTemplate")
containersScanningTooltip:SetOwner(UIParent, "ANCHOR_NONE")

local AddonDB_Defaults = {
	global = {
		Guilds = {
			['*'] = {			-- ["Account.Realm.Name"] 
				money = nil,
				faction = nil,
				Tabs = {
					['*'] = {		-- tabID = table index [1] to [6]
						name = nil,
						icon = nil,
						visitedBy = "",
						ClientTime = 0,				-- since epoch
						ClientDate = nil,
						ClientHour = nil,
						ClientMinute = nil,
						ServerHour = nil,
						ServerMinute = nil,
						ids = {},
						links = {},
						counts = {}
					}
				},
			}
		},
		Characters = {
			['*'] = {					-- ["Account.Realm.Name"] 
				lastUpdate = nil,
				numBagSlots = 0,
				numFreeBagSlots = 0,
				numBankSlots = 0,
				numFreeBankSlots = 0,
				Containers = {
					['*'] = {					-- Containers["Bag0"]
						icon = nil,				-- Containers's texture
						link = nil,				-- Containers's itemlink
						size = 0,
						freeslots = 0,
						bagtype = 0,
						ids = {},
						links = {},
						counts = {},
						cooldowns = {}
					}
				}
			}
		}
	}
}

local ReferenceDB_Defaults = {
	global = {
        Items = {
            ['*'] = nil 
            --[[ Serialized String, containing:
            { -- itemID
                name = nil,
                link = nil,
                rarity = 0,
                level = 0,
                minLevel = 0,
                type = nil,
                subtype = nil,
                stackCount = 1,
                equipLoc = nil,
                icon = 0,
                sellPrice = 0,
                classID = 0,
                subClassID = 0,
                bindType = 0,
                expackID = 0,
                setID = 0,
                isCraftingReagent = false,
            }
            ]]--
        }
	}
}

local function GetDBVersion()
	return addon.db.global.Version or 0
end

local function SetDBVersion(version)
	addon.db.global.Version = version
end

local DBUpdaters = {
	-- Table of functions, each one updates to its index's version
	--	ex: [3] = the function that upgrades from v2 to v3
	[1] = function(self)
	
			local function CopyTable(src, dest)
				for k, v in pairs (src) do
					if type(v) == "table" then
						dest[k] = {}
						CopyTable(v, dest[k])
					else
						dest[k] = v
					end
				end
			end
		
			-- This function moves guild bank tabs from the "Guilds/Guildkey" level to the "Guilds/Guildkey/Tabs" sub-table
			for guildKey, guildTable in pairs(addon.db.global.Guilds) do
				for tabID = 1, 8 do		-- convert the 8 tabs
					if type(guildTable[tabID]) == "table" then
						CopyTable(guildTable[tabID], guildTable.Tabs[tabID])
						wipe(guildTable[tabID])
						guildTable[tabID] = nil						
					end
				end
				guildTable.money = 0
			end
		end,
}

local function UpdateDB()
	local version = GetDBVersion()
	
	for i = (version+1), #DBUpdaters do		-- start from latest version +1 to the very last
		DBUpdaters[i]()
		SetDBVersion(i)
	end
	
	DBUpdaters = nil
	GetDBVersion = nil
	SetDBVersion = nil
end

-- *** Utility functions ***
local function GetThisGuild()
	local key = DataStore:GetThisGuildKey()
	return key and addon.db.global.Guilds[key] 
end

local function GetBankTimestamps(guild)
	-- returns a | delimited string containing the list of alts in the same guild
	guild = guild or GetGuildInfo("player")
	if not guild then	return end
		
	local thisGuild = GetThisGuild()
	if not thisGuild then return end
	
	local out = {}
	for tabID, tab in pairs(thisGuild.Tabs) do
		if tab.name then
			table.insert(out, format("%d:%s:%d:%d:%d", tabID, tab.name, tab.ClientTime, tab.ServerHour, tab.ServerMinute))
		end
	end
	
	return table.concat(out, "|")
end

local function SaveBankTimestamps(sender, timestamps)
	if not timestamps or strlen(timestamps) == 0 then return end	-- sender has no tabs
	
	guildMembers[sender] = guildMembers[sender] or {}
	wipe(guildMembers[sender])

	for _, v in pairs( { strsplit("|", timestamps) }) do	
		local id, name, clientTime, serverHour, serverMinute = strsplit(":", v)

		-- ex: guildMembers["Thaoky"]["RaidFood"] = {	clientTime = 123, serverHour = ... }
		guildMembers[sender][name] = {}
		local tab = guildMembers[sender][name]
		tab.id = tonumber(id)
		tab.clientTime = tonumber(clientTime)
		tab.serverHour = tonumber(serverHour)
		tab.serverMinute = tonumber(serverMinute)
	end
	addon:SendMessage("DATASTORE_GUILD_BANKTABS_UPDATED", sender)
end

local function GuildBroadcast(messageType, ...)
	local serializedData = addon:Serialize(messageType, ...)
	addon:SendCommMessage(commPrefix, serializedData, "GUILD")
end

local function GuildWhisper(player, messageType, ...)
	if DataStore:IsGuildMemberOnline(player) then
		local serializedData = addon:Serialize(messageType, ...)
		addon:SendCommMessage(commPrefix, serializedData, "WHISPER", player)
	end
end

local function IsEnchanted(link)
	if not link then return end
	
	if not string.find(link, "item:%d+:0:0:0:0:0:0:%d+:%d+:0:0") then	-- 7th is the UniqueID, 8th LinkLevel which are irrelevant
		-- enchants/jewels store values instead of zeroes in the link, if this string can't be found, there's at least one enchant/jewel
		return true
	end
end

local BAGS			= 1		-- All bags, 0 to 11, and keyring ( id -2 )
local BANK			= 2		-- 28 main slots
local GUILDBANK	= 3		-- 98 main slots

local ContainerTypes = {
	[BAGS] = {
		GetSize = function(self, bagID)
				return GetContainerNumSlots(bagID)
			end,
		GetFreeSlots = function(self, bagID)
				local freeSlots, bagType = GetContainerNumFreeSlots(bagID)
                if (bagID == -3) then 
                    if not addon.isBankOpen then
                        -- Player isn't at the bank, so GetContainerNumFreeSlots always returns zero
                        -- Have to count the number of slots instead
                        local count = 0
                        for i = 1, 98 do
                            if GetContainerItemLink(-3, i) then
                                count = count + 1
                            end
                        end
                        freeSlots = 98 - count
                    end
                end
				return freeSlots, bagType
			end,
		GetLink = function(self, slotID, bagID)
				return GetContainerItemLink(bagID, slotID)
			end,
		GetCount = function(self, slotID, bagID)
				local _, count = GetContainerItemInfo(bagID, slotID)
				return count
			end,
		GetCooldown = function(self, slotID, bagID)
				local startTime, duration, isEnabled = GetContainerItemCooldown(bagID, slotID)
				return startTime, duration, isEnabled
			end,
	},
	[BANK] = {
		GetSize = function(self)
				return NUM_BANKGENERIC_SLOTS or 28		-- hardcoded in case the constant is not set
			end,
		GetFreeSlots = function(self)
				local freeSlots, bagType = GetContainerNumFreeSlots(-1)		-- -1 = player bank
				return freeSlots, bagType
			end,
		GetLink = function(self, slotID)
				-- return GetInventoryItemLink("player", slotID)
				return GetContainerItemLink(-1, slotID)
			end,
		GetCount = function(self, slotID)
				-- return GetInventoryItemCount("player", slotID)
				return select(2, GetContainerItemInfo(-1, slotID))
			end,
		GetCooldown = function(self, slotID)
				local startTime, duration, isEnabled = GetInventoryItemCooldown("player", slotID)
				return startTime, duration, isEnabled
			end,
	},
	[GUILDBANK] = {
		GetSize = function(self)
				return MAX_GUILDBANK_SLOTS_PER_TAB or 98		-- hardcoded in case the constant is not set
			end,
		GetFreeSlots = function(self)
				return nil, nil
			end,
		GetLink = function(self, slotID, tabID)
				return GetGuildBankItemLink(tabID, slotID)
			end,
		GetCount = function(self, slotID, tabID)
				local _, count = GetGuildBankItemInfo(tabID, slotID)
				return count
			end,
		GetCooldown = function(self, slotID)
				return nil
			end,
	}
}

local function detectBagChanges(originalBag, newBag)
    local changes = {}

    for slotID = 1, originalBag.size do
        local itemID = originalBag.ids[slotID]
        if itemID == nil then
            -- slot was originally empty
            if newBag.ids[slotID] ~= nil then
                -- an item has been moved into this slot
                table.insert(changes, {["changeType"] = "insert", ["slotID"] = slotID, ["itemID"] = newBag.ids[slotID], ["count"] = newBag.counts[slotID] })
            end
        else
            -- slot originally had an item
            if newBag.ids[slotID] == nil then
                -- an item has been removed from this slot
                table.insert(changes, {["changeType"] = "delete", ["slotID"] = slotID, ["itemID"] = itemID})
            else
                if (itemID ~= newBag.ids[slotID]) or (originalBag.counts[slotID] ~= newBag.counts[slotID]) then
                    -- a different item is now in this slot OR its count changed
                    table.insert(changes, { 
                        ["changeType"] = "changed", 
                        ["slotID"] = slotID, 
                        ["originalItemID"] = itemID, 
                        ["newItemID"] = newBag.ids[slotID], 
                        ["originalCount"] = originalBag.counts[slotID], 
                        ["newCount"] = newBag.counts[slotID], 
                    } )
                end
            end
        end
    end

    return changes
end

local function _CacheItemID(itemID)
    if not itemID then return end
    if addon.ref.global.Items[itemID] then
        local info = {}
        info.name, info.link, info.rarity, info.level, info.minLevel, info.type, info.subType, info.stackCount, info.equipLoc, info.icon, info.sellPrice, info.classID, info.subClassID, info.bindType, info.expacID, info.setID, info.isCraftingReagent = GetItemInfo(itemID)
        if info.name then
            addon.ref.global.Items[itemID] = addon:Serialize(info)
        end
    end
end

-- *** Scanning functions ***
local function ScanContainer(bagID, containerType)
	local Container = ContainerTypes[containerType]

	local originalBag
    local newBag = {}
    
	if containerType == GUILDBANK then
		local thisGuild = GetThisGuild()
		if not thisGuild then return end
	
		originalBag = thisGuild.Tabs[bagID]	-- bag is actually the current tab
        thisGuild.Tabs[bagID] = newBag
	else
		originalBag = addon.ThisCharacter.Containers["Bag" .. bagID]
        newBag.cooldowns = {}
        addon.ThisCharacter.Containers["Bag"..bagID] = newBag
	end
        
    newBag.ids = {}
    newBag.counts = {}
    newBag.links = {}
    newBag.icon = originalBag.icon
    newBag.link = originalBag.link
    newBag.rarity = originalBag.rarity
	
	local link, count
	local startTime, duration, isEnabled
	
	newBag.size = Container:GetSize(bagID)
	newBag.freeslots, newBag.bagtype = Container:GetFreeSlots(bagID)

	-- Scan from 1 to bagsize for normal bags or guild bank tabs, but from 40 to 67 for main bank slots
	-- local baseIndex = (containerType == BANK) and 39 or 0
	local baseIndex = 0
	local index
	
	for slotID = baseIndex + 1, baseIndex + newBag.size do
		index = slotID - baseIndex
		link = Container:GetLink(slotID, bagID)
		if link then
			newBag.ids[index] = tonumber(link:match("item:(%d+)"))

			if link:match("|Hkeystone:") then
				-- mythic keystones are actually all using the same item id
				newBag.ids[index] = 158923

			elseif link:match("|Hbattlepet:") then
				-- special treatment for battle pets, save texture id instead of item id..
				-- texture, itemCount, locked, quality, readable, _, _, isFiltered, noValue, itemID = GetContainerItemInfo(id, itemButton:GetID());
				newBag.ids[index] = GetContainerItemInfo(bagID, slotID)
			elseif link:match("|Hitem:82800") then
				local texture=GetGuildBankItemInfo(bagID, slotID)
			
				containersScanningTooltip:ClearLines()
				if texture then
					containersScanningTooltip:ClearLines()
					local speciesID, level, breedQuality, maxHealth, power, speed, name = containersScanningTooltip:SetGuildBankItem( bagID, slotID )
					if speciesID then
						local pet_link = string.format( "|Hbattlepet:%s:%s:%s:%s:%s:%s:0000000000000000:0|h[%s]|h", speciesID or 0, level or 0, breedQuality or 0, maxHealth or 0, power or 0, speed or 0, name or "" )
						local color=ITEM_QUALITY_COLORS[breedQuality].hex
						pet_link = color..pet_link.."|r" 
						newBag.ids[index] = texture
						newBag.links[index] = pet_link
					end
				end
				
			end
			
			if IsEnchanted(link) and not link:match("|Hitem:82800") then
				newBag.links[index] = link
			end
		
			count = Container:GetCount(slotID, bagID)
			if count and count > 1  then
				newBag.counts[index] = count	-- only save the count if it's > 1 (to save some space since a count of 1 is extremely redundant)
			end
            
            _CacheItemID(newBag.ids[index])
		end
		
		startTime, duration, isEnabled = Container:GetCooldown(slotID, bagID)
		if startTime and startTime > 0 then
			newBag.cooldowns[index] = format("%s|%s|1", startTime, duration)
		end
	end
	
	addon.ThisCharacter.lastUpdate = time()
	addon:SendMessage("DATASTORE_CONTAINER_UPDATED", bagID, containerType)
    
    local changes
    
    if containerType ~= GUILDBANK then 
        changes = detectBagChanges(originalBag, newBag)
    else
        return nil
    end

    -- detect if the table is empty
    local next = next
    if next(changes) == nil then
        return nil
    else
        changes.bagID = bagID
        return changes
    end
end

local function ScanBagSlotsInfo()
	local char = addon.ThisCharacter

	local numBagSlots = 0
	local numFreeBagSlots = 0

	for bagID = 0, NUM_BAG_SLOTS do
		local bag = char.Containers["Bag" .. bagID]
		numBagSlots = numBagSlots + bag.size
        if not bag.freeslots then bag.freeslots = 0 end
		numFreeBagSlots = numFreeBagSlots + bag.freeslots
	end
	
	char.numBagSlots = numBagSlots
	char.numFreeBagSlots = numFreeBagSlots
end

local function ScanBankSlotsInfo()
	local char = addon.ThisCharacter
	
	local numBankSlots = NUM_BANKGENERIC_SLOTS
	local numFreeBankSlots = char.Containers["Bag"..MAIN_BANK_SLOTS].freeslots

	for bagID = NUM_BAG_SLOTS + 1, NUM_BAG_SLOTS + NUM_BANKBAGSLOTS do		-- 5 to 11
		local bag = char.Containers["Bag" .. bagID]
		
		numBankSlots = numBankSlots + bag.size
		numFreeBankSlots = numFreeBankSlots + bag.freeslots
	end
	
	char.numBankSlots = numBankSlots
	char.numFreeBankSlots = numFreeBankSlots
end

local function ScanGuildBankInfo()
	-- only the current tab can be updated
	local thisGuild = GetThisGuild()
	if not thisGuild then return end

	local tabID = GetCurrentGuildBankTab()
	local t = thisGuild.Tabs[tabID]	-- t = current tab
	t.name, t.icon = GetGuildBankTabInfo(tabID)
	t.visitedBy = UnitName("player")
	t.ClientTime = time()
    
	if GetLocale() == "enUS" then				-- adjust this test if there's demand
		t.ClientDate = date("%m/%d/%Y")
	else
		t.ClientDate = date("%d/%m/%Y")
	end
    
	t.ClientHour = tonumber(date("%H"))
	t.ClientMinute = tonumber(date("%M"))
	t.ServerHour, t.ServerMinute = GetGameTime()
end

local function ScanBag(bagID)
	if bagID < 0 then return end

	local char = addon.ThisCharacter
	local bag = char.Containers["Bag" .. bagID]
	
	if bagID == 0 then	-- Bag 0	
		bag.icon = "Interface\\Buttons\\Button-Backpack-Up";
		bag.link = nil;
	else						-- Bags 1 through 11
		bag.icon = GetInventoryItemTexture("player", ContainerIDToInventoryID(bagID))
		bag.link = GetInventoryItemLink("player", ContainerIDToInventoryID(bagID))
		if bag.link then
			local _, _, rarity = GetItemInfo(bag.link)
			if rarity then	-- in case rarity was known from a previous scan, and GetItemInfo returns nil for some reason .. don't overwrite
				bag.rarity = rarity
			end
		end
	end
    local changes = ScanContainer(bagID, BAGS) 
	ScanBagSlotsInfo()
    return changes
end

local function ScanVoidStorage()
	-- delete the old data from the "VoidStorage" container, now stored in .Tab1, .Tab2 (since they'll likely add more later on)
	wipe(addon.ThisCharacter.Containers["VoidStorage"])

	local bag
	local itemID
	
	for tab = 1, 2 do
		bag = addon.ThisCharacter.Containers[VOID_STORAGE_TAB .. tab]
		bag.size = 80
        bag.freeslots = 80
	
		for slot = 1, bag.size do
			itemID = GetVoidItemInfo(tab, slot)
            if itemID then
                bag.freeslots = bag.freeslots - 1
            end
			bag.ids[slot] = itemID
		end
	end
	addon:SendMessage("DATASTORE_VOIDSTORAGE_UPDATED")
end

local function ScanReagentBank()
	ScanContainer(REAGENTBANK_CONTAINER, BAGS)
end

local bagUpdateQueue = {} 
-- *** Event Handlers ***
local function OnBagUpdate(event, bag)
	if bag < 0 then
		return
	end
	
	if (bag >= 5) and (bag <= 11) and not addon.isBankOpen then
		return
	end

    table.insert(bagUpdateQueue, bag)
end

local function OnBagUpdateDelayed(event)
    if #bagUpdateQueue == 0 then return end

    for _, v in ipairs(bagUpdateQueue) do
        local changes = ScanBag(v)
        if changes then
            addon:SendMessage("DATASTORE_CONTAINER_CHANGES_SINGLE", changes)
        end        
    end

    wipe(bagUpdateQueue)
end

local function OnBankFrameClosed()
	addon.isBankOpen = nil
	addon:UnregisterEvent("BANKFRAME_CLOSED")
	addon:UnregisterEvent("PLAYERBANKSLOTS_CHANGED")
end

local function OnPlayerBankSlotsChanged(event, slotID)
	-- from top left to bottom right, slotID = 1 to 28for main slots, and 29 to 35 for the additional bags
	if (slotID >= 29) and (slotID <= 35) then
		ScanBag(slotID - 24)		-- bagID for bank bags goes from 5 to 11, so slotID - 24
	else
        local changes = ScanContainer(MAIN_BANK_SLOTS, BANK) 
        if changes then
            addon:SendMessage("DATASTORE_CONTAINER_CHANGES_SINGLE", changes)
        end
		ScanBankSlotsInfo()
	end
end

local function OnPlayerReagentBankSlotsChanged(event)
	ScanReagentBank()
end

local function OnBankFrameOpened()
	addon.isBankOpen = true
	for bagID = NUM_BAG_SLOTS + 1, NUM_BAG_SLOTS + NUM_BANKBAGSLOTS do		-- 5 to 11
		ScanBag(bagID)
	end
	
    ScanContainer(MAIN_BANK_SLOTS, BANK)
	ScanBankSlotsInfo()
    
	addon:RegisterEvent("BANKFRAME_CLOSED", OnBankFrameClosed)
	addon:RegisterEvent("PLAYERBANKSLOTS_CHANGED", OnPlayerBankSlotsChanged)
end

local function OnGuildBankFrameClosed()
	addon:UnregisterEvent("GUILDBANKFRAME_CLOSED")
	addon:UnregisterEvent("GUILDBANKBAGSLOTS_CHANGED")
	addon:UnregisterEvent("GUILDBANKBAGSLOTS_CHANGED")
	
	local guildName = GetGuildInfo("player")
	if guildName then
		GuildBroadcast(MSG_SEND_BANK_TIMESTAMPS, GetBankTimestamps(guildName))
	end
end

local function OnGuildBankBagSlotsChanged()
	ScanContainer(GetCurrentGuildBankTab(), GUILDBANK)
	ScanGuildBankInfo()
end

local function OnGuildBankFrameOpened()
	addon:RegisterEvent("GUILDBANKFRAME_CLOSED", OnGuildBankFrameClosed)
	addon:RegisterEvent("GUILDBANKBAGSLOTS_CHANGED", OnGuildBankBagSlotsChanged)
	
	local thisGuild = GetThisGuild()
	if thisGuild then
		thisGuild.money = GetGuildBankMoney()
		thisGuild.faction = UnitFactionGroup("player")
	end
end

local function OnAuctionMultiSellStart()
	-- if a multi sell starts, unregister bag updates.
	addon:UnregisterEvent("BAG_UPDATE")
    addon:UnregisterEvent("BAG_UPDATE_DELAYED") 
end

local function OnAuctionMultiSellUpdate(event, current, total)
	if current == total then	-- ex: multisell = 8 items, if we're on the 8th, resume bag updates.
		addon:RegisterEvent("BAG_UPDATE", OnBagUpdate)
        addon:RegisterEvent("BAG_UPDATE_DELAYED", OnBagUpdateDelayed) 
	end
end

local function OnAuctionHouseClosed()
	addon:UnregisterEvent("AUCTION_MULTISELL_START")
	addon:UnregisterEvent("AUCTION_MULTISELL_UPDATE")
	addon:UnregisterEvent("AUCTION_HOUSE_CLOSED")
	
	addon:RegisterEvent("BAG_UPDATE", OnBagUpdate)	-- just in case things went wrong
    addon:RegisterEvent("BAG_UPDATE_DELAYED", OnBagUpdateDelayed) 
end

local function OnAuctionHouseShow()
	-- when going to the AH, listen to multi-sell
	addon:RegisterEvent("AUCTION_MULTISELL_START", OnAuctionMultiSellStart)
	addon:RegisterEvent("AUCTION_MULTISELL_UPDATE", OnAuctionMultiSellUpdate)
	addon:RegisterEvent("AUCTION_HOUSE_CLOSED", OnAuctionHouseClosed)
end

local function OnVoidStorageClosed()
	addon:UnregisterEvent("VOID_STORAGE_CLOSE")
	addon:UnregisterEvent("VOID_STORAGE_UPDATE")
	addon:UnregisterEvent("VOID_STORAGE_CONTENTS_UPDATE")
	addon:UnregisterEvent("VOID_TRANSFER_DONE")
end

local function OnVoidStorageTransferDone()
	ScanVoidStorage()
end

local function OnVoidStorageOpened()
	ScanVoidStorage()
	addon:RegisterEvent("VOID_STORAGE_CLOSE", OnVoidStorageClosed)
	addon:RegisterEvent("VOID_STORAGE_UPDATE", ScanVoidStorage)
	addon:RegisterEvent("VOID_STORAGE_CONTENTS_UPDATE", ScanVoidStorage)
	addon:RegisterEvent("VOID_TRANSFER_DONE", OnVoidStorageTransferDone)
end


-- ** Mixins **
local function _GetContainer(character, containerID)
	-- containerID can be number or string
	if type(containerID) == "number" then
		return character.Containers["Bag" .. containerID]
	end
	return character.Containers[containerID]
end

local function _GetContainers(character)
	return character.Containers
end

local BagTypeStrings = {
	-- [1] = "Quiver",
	-- [2] = "Ammo Pouch",
	[4] = GetItemSubClassInfo(LE_ITEM_CLASS_CONTAINER, 1), -- "Soul Bag",
	[8] = GetItemSubClassInfo(LE_ITEM_CLASS_CONTAINER, 7), -- "Leatherworking Bag",
	[16] = GetItemSubClassInfo(LE_ITEM_CLASS_CONTAINER, 8), -- "Inscription Bag",
	[32] = GetItemSubClassInfo(LE_ITEM_CLASS_CONTAINER, 2), -- "Herb Bag"
	[64] = GetItemSubClassInfo(LE_ITEM_CLASS_CONTAINER, 3), -- "Enchanting Bag",
	[128] = GetItemSubClassInfo(LE_ITEM_CLASS_CONTAINER, 4), -- "Engineering Bag",
	[512] = GetItemSubClassInfo(LE_ITEM_CLASS_CONTAINER, 5), -- "Gem Bag",
	[1024] = GetItemSubClassInfo(LE_ITEM_CLASS_CONTAINER, 6), -- "Mining Bag",
	
}

local function _ImportBagChanges(character, changes)
    -- first, integrity checks...
    if not character then return end
    if not changes then return end
    if type(changes) ~= "table" then return end
    if not changes.bagID then return end
    local container = _GetContainer(character, changes.bagID) 
    if not container then return end

    for _, change in pairs(changes) do
        if type(change) == "table" then
            if change.changeType == "insert" then
                if change.slotID and change.itemID then
                    local existingItem = container.ids[change.slotID]
                    container.ids[change.slotID] = change.itemID
                    local item = Item:CreateFromItemID(change.itemID)
                    item:ContinueOnItemLoad(function()
	                    container.links[change.slotID] = item:GetItemLink()
                    end)
                    container.counts[change.slotID] = change.count 
                end
            elseif change.changeType == "delete" then
                if change.slotID and change.itemID then
                    local existingItem = container.ids[change.slotID]
                    container.ids[change.slotID] = nil
                    container.links[change.slotID] = nil
                    container.counts[change.slotID] = nil
                end
            elseif change.changeType == "changed" then
                if change.slotID and change.originalItemID and change.newItemID then
                    local existingItem = container.ids[change.slotID]
                    container.ids[change.slotID] = change.newItemID
                    local item = Item:CreateFromItemID(change.newItemID)
                    item:ContinueOnItemLoad(function()
	                    container.links[change.slotID] = item:GetItemLink()
                    end)
                    container.counts[change.slotID] = change.newCount 
                end
            end
        end
    end
end

local function _GetContainerInfo(character, containerID)
	local bag = _GetContainer(character, containerID)
	
    if not bag then return nil end
    
	local icon = bag.icon
	local size = bag.size
	
	if containerID == MAIN_BANK_SLOTS then	-- main bank slots
		icon = "Interface\\Icons\\inv_misc_enggizmos_17"
	elseif containerID == REAGENTBANK_CONTAINER then
		icon = "Interface\\Icons\\inv_misc_bag_satchelofcenarius"
	elseif string.sub(containerID, 1, string.len(VOID_STORAGE_TAB)) == VOID_STORAGE_TAB then
		icon = "Interface\\Icons\\spell_nature_astralrecalgroup"
		size = 80
	end
	
	return icon, bag.link, size, bag.freeslots, BagTypeStrings[bag.bagtype]
end

local function _GetContainerSize(character, containerID)
	-- containerID can be number or string
	if type(containerID) == "number" then
		if not character.Containers["Bag"..containerID] then return 0 end
        return character.Containers["Bag" .. containerID].size
	end
	return character.Containers[containerID].size
end

local rarityColors = {
	[2] = "|cFF1EFF00",
	[3] = "|cFF0070DD",
	[4] = "|cFFA335EE"
}

local function _GetColoredContainerSize(character, containerID)
	local bag = _GetContainer(character, containerID)
	local size = _GetContainerSize(character, containerID) or 0
	
	if bag and bag.rarity and rarityColors[bag.rarity] then
		return format("%s%s", rarityColors[bag.rarity], size)
	end
	
	return format("%s%s", "|cFFFFFFFF", size)
end

local function _GetSlotInfo(bag, slotID)
	assert(type(bag) == "table")		-- this is the pointer to a bag table, obtained through addon:GetContainer()
	assert(type(slotID) == "number")

	local link = bag.links[slotID]
	local isBattlePet
	
	if link then
		isBattlePet = link:match("|Hbattlepet:")
	end
	
	-- return itemID, itemLink, itemCount, isBattlePet
	return bag.ids[slotID], link, bag.counts[slotID] or 1, isBattlePet
end

local function _GetContainerCooldownInfo(bag, slotID)
	assert(type(bag) == "table")		-- this is the pointer to a bag table, obtained through addon:GetContainer()
	assert(type(slotID) == "number")
    
    if not bag.cooldowns then
        bag.cooldowns = {}
        return nil
    end
    
	local cd = bag.cooldowns[slotID]
	if cd then
		local startTime, duration, isEnabled = strsplit("|", bag.cooldowns[slotID])
		local remaining = duration - (GetTime() - startTime)
		
		if remaining > 0 then		-- valid cd ? return it
			return tonumber(startTime), tonumber(duration), tonumber(isEnabled)
		end
		-- cooldown expired ? clean it from the db
		bag.cooldowns[slotID] = nil
	end
end

local function _GetContainerItemCount(character, searchedID)
	local bagCount = 0
	local bankCount = 0
	local voidCount = 0
	local reagentBankCount = 0
	local id
	
	-- old voidstorage, simply delete it, might still be listed if players haven't logged on all their alts					
	character.Containers["VoidStorage"] = nil
		
	for containerName, container in pairs(character.Containers) do
		for slotID = 1, container.size do
			id = container.ids[slotID]
			
			if (id) and (id == searchedID) then
				local itemCount = container.counts[slotID] or 1
				if (containerName == "VoidStorage.Tab1") or (containerName == "VoidStorage.Tab2") then
					voidCount = voidCount + 1
				elseif (containerName == "Bag"..MAIN_BANK_SLOTS) then
					bankCount = bankCount + itemCount
				elseif (containerName == "Bag-2") then
					bagCount = bagCount + itemCount
				elseif (containerName == "Bag-3") then
					reagentBankCount = reagentBankCount + itemCount
				else
					local bagNum = tonumber(string.sub(containerName, 4))
					if (bagNum >= 0) and (bagNum <= 4) then
						bagCount = bagCount + itemCount
					else
						bankCount = bankCount + itemCount
					end
				end
			end
		end
	end

	return bagCount, bankCount, voidCount, reagentBankCount
end

local function _GetNumBagSlots(character)
	return character.numBagSlots
end

local function _GetNumFreeBagSlots(character)
	return character.numFreeBagSlots
end

local function _GetNumBankSlots(character)
	return character.numBankSlots
end

local function _GetNumFreeBankSlots(character)
	return character.numFreeBankSlots
end

local function _GetNumFreeReagentBankSlots(character)
    if not character.Containers then return 0 end
    if not character.Containers["Bag-3"] then return 0 end
    return character.Containers["Bag-3"].freeslots
end

local function _GetNumFreeVoidStorageSlots(character)
    local tab1Slots = 0
    if character.Containers["VoidStorage.Tab1"] then
        tab1Slots = character.Containers["VoidStorage.Tab1"].freeslots
    end
    local tab2Slots = 0
    if character.Containers["VoidStorage.Tab2"] then
        tab2Slots = character.Containers["VoidStorage.Tab2"].freeslots
    end
    return tab1Slots + tab2Slots
end

-- Seems like this should be updated to include tab1 / tab2.
local function _GetVoidStorageItem(character, index)
	return character.Containers["VoidStorage"].ids[index]
end

-- local function _DeleteGuild(name, realm, account)
	-- realm = realm or GetRealmName()
	-- account = account or THIS_ACCOUNT
	
	-- local key = format("%s.%s.%s", account, realm, name)
	-- addon.db.global.Guilds[key] = nil
-- end

local function _GetGuildBankItemCount(guild, searchedID)
	local count = 0
	for _, container in pairs(guild.Tabs) do
	   for slotID, id in pairs(container.ids) do
	      if (id == searchedID) then
	         count = count + (container.counts[slotID] or 1)
	      end
	   end
	end
	return count
end
	
local function _GetGuildBankTab(guild, tabID)
	return guild.Tabs[tabID]
end
	
local function _GetGuildBankTabName(guild, tabID)
	return guild.Tabs[tabID].name
end

local function _GetGuildBankTabIcon(guild, tabID)
	return guild.Tabs[tabID].icon
end

local function _GetGuildBankTabItemCount(guild, tabID, searchedID)
	local count = 0
	local container = guild.Tabs[tabID]
	
	for slotID, id in pairs(container.ids) do
		if (id == searchedID) then
			count = count + (container.counts[slotID] or 1)
		end
	end
	return count
end

local function _GetGuildBankTabLastUpdate(guild, tabID)
	return guild.Tabs[tabID].ClientTime
end

local function _GetGuildBankMoney(guild)
	return guild.money
end

local function _GetGuildBankFaction(guild)
	return guild.faction
end

local function _ImportGuildBankTab(guild, tabID, data)
	wipe(guild.Tabs[tabID])							-- clear existing data
	guild.Tabs[tabID] = data
end

local function _GetGuildBankTabSuppliers()
	return guildMembers
end

local function _GetGuildMemberBankTabInfo(member, tabName)
	-- for the current guild, return the guild member's data about a given tab
	if guildMembers[member] then
		if guildMembers[member][tabName] then
			local tab = guildMembers[member][tabName]
			return tab.clientTime, tab.serverHour, tab.serverMinute
		end
	end
end

local function _RequestGuildMemberBankTab(member, tabName)
	GuildWhisper(member, MSG_BANKTAB_REQUEST, tabName)
end

local function _RejectBankTabRequest(member)
	GuildWhisper(member, MSG_BANKTAB_REQUEST_REJECTED)
end

local function _SendBankTabToGuildMember(member, tabName)
	-- send the actual content of a bank tab to a guild member
	local thisGuild = GetThisGuild()
	if thisGuild then
		local tabID
		if guildMembers[member] then
			if guildMembers[member][tabName] then
				tabID = guildMembers[member][tabName].id
			end
		end	
	
		if tabID then
			GuildWhisper(member, MSG_BANKTAB_TRANSFER, thisGuild.Tabs[tabID])
		end
	end
end

local function _GetSavedGuildKeys()
    local keys = {}
    for key in pairs(addon.db.global.Guilds) do
        table.insert(keys, key)
    end
    return keys
end

local function _GetReferenceItemInfo(itemID)
    local ref = addon.ref.global.Items[itemID]
    if not ref then return end
    if type(ref) == "table" then return ref end
    if type(ref) == "string" then
        local result, ref = addon:Deserialize(ref)
        --[[if not result then --debug
            print(ref)
        end]]--
        return ref
    end
end

--[[debug purposes only
local function _CacheAllItems()
    for accountName in pairs(DataStore:GetAccounts()) do
        for realmName in pairs(DataStore:GetRealms(accountName)) do
            for charName,character in pairs(DataStore:GetCharacters(realmName, accountName)) do
                for g,h in pairs(DataStore:GetContainers(character)) do
                    for i,j in pairs(h.ids) do
                        _CacheItemID(j)
                    end
                end
            end
        end
    end
end]]--

local PublicMethods = {
	GetContainer = _GetContainer,
	GetContainers = _GetContainers,
	GetContainerInfo = _GetContainerInfo,
	GetContainerSize = _GetContainerSize,
	GetColoredContainerSize = _GetColoredContainerSize,
	GetSlotInfo = _GetSlotInfo,
	GetContainerCooldownInfo = _GetContainerCooldownInfo,
	GetContainerItemCount = _GetContainerItemCount,
	GetNumBagSlots = _GetNumBagSlots,
	GetNumFreeBagSlots = _GetNumFreeBagSlots,
	GetNumBankSlots = _GetNumBankSlots,
	GetNumFreeBankSlots = _GetNumFreeBankSlots,
    GetNumFreeReagentBankSlots = _GetNumFreeReagentBankSlots,
    GetNumFreeVoidStorageSlots = _GetNumFreeVoidStorageSlots, 
	GetVoidStorageItem = _GetVoidStorageItem,
	-- DeleteGuild = _DeleteGuild,
	GetGuildBankItemCount = _GetGuildBankItemCount,
	GetGuildBankTab = _GetGuildBankTab,
	GetGuildBankTabName = _GetGuildBankTabName,
	GetGuildBankTabIcon = _GetGuildBankTabIcon,
	GetGuildBankTabItemCount = _GetGuildBankTabItemCount,
	GetGuildBankTabLastUpdate = _GetGuildBankTabLastUpdate,
	GetGuildBankMoney = _GetGuildBankMoney,
	GetGuildBankFaction = _GetGuildBankFaction,
	ImportGuildBankTab = _ImportGuildBankTab,
	GetGuildMemberBankTabInfo = _GetGuildMemberBankTabInfo,
	RequestGuildMemberBankTab = _RequestGuildMemberBankTab,
	RejectBankTabRequest = _RejectBankTabRequest,
	SendBankTabToGuildMember = _SendBankTabToGuildMember,
	GetGuildBankTabSuppliers = _GetGuildBankTabSuppliers,
    GetSavedGuildKeys = _GetSavedGuildKeys,
    ImportBagChanges = _ImportBagChanges,
    GetReferenceItemInfo = _GetReferenceItemInfo,
    CacheItemID = _CacheItemID,
    --CacheAllItems = _CacheAllItems, 
}

-- *** Guild Comm ***
--[[	*** Protocol ***

At login: 
	Broadcast of guild bank timers on the guild channel
After the guild bank frame is closed:
	Broadcast of guild bank timers on the guild channel

Client addon calls: DataStore:RequestGuildMemberBankTab()
	Client				Server

	==> MSG_BANKTAB_REQUEST 
	<== MSG_BANKTAB_REQUEST_ACK (immediate ack)   

	<== MSG_BANKTAB_REQUEST_REJECTED (stop)   
	or 
	<== MSG_BANKTAB_TRANSFER (actual data transfer)
--]]

local function OnAnnounceLogin(self, guildName)
	-- when the main DataStore module sends its login info, share the guild bank last visit time across guild members
	local timestamps = GetBankTimestamps(guildName)
	if timestamps then	-- nil if guild bank hasn't been visited yet, so don't broadcast anything
		GuildBroadcast(MSG_SEND_BANK_TIMESTAMPS, timestamps)
	end
end

local function OnGuildMemberOffline(self, member)
	guildMembers[member] = nil
	addon:SendMessage("DATASTORE_GUILD_BANKTABS_UPDATED", member)
end

local GuildCommCallbacks = {
	[MSG_SEND_BANK_TIMESTAMPS] = function(sender, timestamps)
			if sender ~= UnitName("player") then						-- don't send back to self
				local timestamps = GetBankTimestamps()
				if timestamps then
					GuildWhisper(sender, MSG_BANK_TIMESTAMPS_REPLY, timestamps)		-- reply by sending my own data..
				end
			end
			SaveBankTimestamps(sender, timestamps)
		end,
	[MSG_BANK_TIMESTAMPS_REPLY] = function(sender, timestamps)
			SaveBankTimestamps(sender, timestamps)
		end,
	[MSG_BANKTAB_REQUEST] = function(sender, tabName)
			-- trigger the event only, actual response (ack or not) must be handled by client addons
			GuildWhisper(sender, MSG_BANKTAB_REQUEST_ACK)		-- confirm that the request has been received
			addon:SendMessage("DATASTORE_BANKTAB_REQUESTED", sender, tabName)
		end,
	[MSG_BANKTAB_REQUEST_ACK] = function(sender)
			addon:SendMessage("DATASTORE_BANKTAB_REQUEST_ACK", sender)
		end,
	[MSG_BANKTAB_REQUEST_REJECTED] = function(sender)
			addon:SendMessage("DATASTORE_BANKTAB_REQUEST_REJECTED", sender)
		end,
	[MSG_BANKTAB_TRANSFER] = function(sender, data)
			local guildName = GetGuildInfo("player")
			local guild	= GetThisGuild()
			
			for tabID, tab in pairs(guild.Tabs) do
				if tab.name == data.name then	-- this is the tab being updated
					_ImportGuildBankTab(guild, tabID, data)
					addon:SendMessage("DATASTORE_BANKTAB_UPDATE_SUCCESS", sender, guildName, data.name, tabID)
					GuildBroadcast(MSG_SEND_BANK_TIMESTAMPS, GetBankTimestamps(guildName))
				end
			end
		end,
}

function addon:OnInitialize()
	addon.db = LibStub("AceDB-3.0"):New(addonName .. "DB", AddonDB_Defaults)
	addon.ref = LibStub("AceDB-3.0"):New(addonName .. "RefDB", ReferenceDB_Defaults)
	UpdateDB()

	DataStore:RegisterModule(addonName, addon, PublicMethods)
	DataStore:SetGuildCommCallbacks(commPrefix, GuildCommCallbacks)
	
	DataStore:SetCharacterBasedMethod("GetContainer")
	DataStore:SetCharacterBasedMethod("GetContainers")
	DataStore:SetCharacterBasedMethod("GetContainerInfo")
	DataStore:SetCharacterBasedMethod("GetContainerSize")
	DataStore:SetCharacterBasedMethod("GetColoredContainerSize")
	DataStore:SetCharacterBasedMethod("GetContainerItemCount")
	DataStore:SetCharacterBasedMethod("GetNumBagSlots")
	DataStore:SetCharacterBasedMethod("GetNumFreeBagSlots")
	DataStore:SetCharacterBasedMethod("GetNumBankSlots")
	DataStore:SetCharacterBasedMethod("GetNumFreeBankSlots")
    DataStore:SetCharacterBasedMethod("GetNumFreeReagentBankSlots")
    DataStore:SetCharacterBasedMethod("GetNumFreeVoidStorageSlots")
    DataStore:SetCharacterBasedMethod("ImportBagChanges") 
	DataStore:SetCharacterBasedMethod("GetVoidStorageItem")
	
	DataStore:SetGuildBasedMethod("GetGuildBankItemCount")
	DataStore:SetGuildBasedMethod("GetGuildBankTab")
	DataStore:SetGuildBasedMethod("GetGuildBankTabName")
	DataStore:SetGuildBasedMethod("GetGuildBankTabIcon")
	DataStore:SetGuildBasedMethod("GetGuildBankTabItemCount")
	DataStore:SetGuildBasedMethod("GetGuildBankTabLastUpdate")
	DataStore:SetGuildBasedMethod("GetGuildBankMoney")
	DataStore:SetGuildBasedMethod("GetGuildBankFaction")
	DataStore:SetGuildBasedMethod("ImportGuildBankTab")
	
	addon:RegisterMessage("DATASTORE_ANNOUNCELOGIN", OnAnnounceLogin)
	addon:RegisterMessage("DATASTORE_GUILD_MEMBER_OFFLINE", OnGuildMemberOffline)
	addon:RegisterComm(commPrefix, DataStore:GetGuildCommHandler())
end

function addon:OnEnable()
	-- manually update bags 0 to 4, then register the event, this avoids reacting to the flood of BAG_UPDATE events at login
	for bagID = 0, NUM_BAG_SLOTS do
		ScanBag(bagID)
	end
	
	ScanReagentBank()
	
	addon:RegisterEvent("BAG_UPDATE", OnBagUpdate)
    addon:RegisterEvent("BAG_UPDATE_DELAYED", OnBagUpdateDelayed) 
	addon:RegisterEvent("BANKFRAME_OPENED", OnBankFrameOpened)
	addon:RegisterEvent("GUILDBANKFRAME_OPENED", OnGuildBankFrameOpened)
	addon:RegisterEvent("VOID_STORAGE_OPEN", OnVoidStorageOpened)
	addon:RegisterEvent("PLAYERREAGENTBANKSLOTS_CHANGED", OnPlayerReagentBankSlotsChanged)
	
	-- disable bag updates during multi sell at the AH
	addon:RegisterEvent("AUCTION_HOUSE_SHOW", OnAuctionHouseShow)
end

function addon:OnDisable()
	addon:UnregisterEvent("BAG_UPDATE")
    addon:UnregisterEvent("BAG_UPDATE_DELAYED") 
	addon:UnregisterEvent("BANKFRAME_OPENED")
	addon:UnregisterEvent("GUILDBANKFRAME_OPENED")
	addon:UnregisterEvent("AUCTION_HOUSE_SHOW")
	addon:UnregisterEvent("VOID_STORAGE_OPEN")
	addon:UnregisterEvent("PLAYERREAGENTBANKSLOTS_CHANGED")
end
