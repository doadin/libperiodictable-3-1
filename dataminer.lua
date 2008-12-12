-- (c) 2007 Nymbia.  see LGPLv2.1.txt for full details.
--this tool is run in the lua command line.  http://lua.org
--socket is required for internet data.
--get socket here: http://luaforge.net/projects/luasocket/
--if available curl will be used, which allows connection re-use
--if available, sqlite3 will be used for the cache database

local SOURCE = SOURCE or "data.lua"
local DEBUG = DEBUG or 1
local INSTANCELOOT_CHKSRC = INSTANCELOOT_CHKSRC
local INSTANCELOOT_MIN = INSTANCELOOT_MIN or 50
local INSTANCELOOT_MAXSRC = INSTANCELOOT_MAXSRC or 10
local INSTANCELOOT_TRASHMINSRC = INSTANCELOOT_TRASHMINSRC or 3

if arg[1] == "-chksrc" and arg[2] then
	table.remove(arg, 1)
	print("Enabling deep scan for Loot table of the following tables", arg[1])
	INSTANCELOOT_CHKSRC = true
	INSTANCELOOT_MIN = 100
end

local function dprint(dlevel, ...)
	if dlevel and DEBUG >= dlevel then
		print(...)
	end
end

local function printdiff(set, old, new)
	if DEBUG < 2 then return end
	local temp = {}
	for entry in old:gmatch("[^,]+") do
		temp[entry] = -1
	end
	for entry in new:gmatch("[^,]+") do
		temp[entry] = (temp[entry] or 0) + 1
	end
	local added, removed = {}, {}
	for entry, value in pairs(temp) do
		if value > 0 then
			added[#added + 1] = entry
		elseif value < 0 then
			removed[#removed + 1] = entry
		end
	end
	if #added + #removed > 0 then
		dprint(2, "CHANGED", set)
	end

	if #removed > 0 then
		dprint(2, "REMOVED", table.concat(removed, ","))
	end
	if #added > 0 then
		dprint(2, "ADDED", table.concat(added, ","))
	end
end

local sets

local url = require("socket.url")
local httptime, httpcount = 0, 0
local getpage
do
	local status, curl = pcall(require, "luacurl")
	if status then
		local write = function (temp, s)
			temp[#temp + 1] = s
			return s:len()
		end
		local c = curl.new()
		function getpage(url)
			dprint(2, "curl", url)
			local temp = {}
			c:setopt(curl.OPT_URL, url)
			c:setopt(curl.OPT_WRITEFUNCTION, write)
			c:setopt(curl.OPT_WRITEDATA, temp)
			local stime = os.time()
			local status, info = c:perform()
			httptime = httptime + (os.time() - stime)
			httpcount = httpcount + 1
			if not status then
				dprint(1, "curl error", url, info)
			else
				temp = table.concat(temp)
				if temp:len() > 0 then
					return temp
				end
			end
		end
	else
		local http = require("socket.http")

		function getpage(url)
			dprint(2, "socket.http", url)
			local stime = os.time()
			local r = http.request(url)
			httptime = httptime + (os.time() - stime)
			httpcount = httpcount + 1
			return r
		end
	end
end

if not NOCACHE then
	local real_getpage = getpage
	local status, sqlite = pcall(require, "lsqlite3")
	if status then
		db = sqlite.open("wowhead.db")
		db:exec([[
CREATE TABLE IF NOT EXISTS cache (
	url TEXT,
	content BLOB,
	time TEXT,
	PRIMARY KEY (url)
)]])
		local CACHE_TIMEOUT = CACHE_TIMEOUT or "+7 day"
		local select_stmt = db:prepare("SELECT content FROM cache WHERE url = ? AND datetime(time, '"..CACHE_TIMEOUT.."') > datetime('now')")
		local insert_stmt = db:prepare("INSERT OR REPLACE INTO cache VALUES (?, ?, CURRENT_TIMESTAMP)")
		getpage = function (url)
			select_stmt:bind_values(url)
			local result = select_stmt:step()
			dprint(2, "cache", url, result == sqlite3.ROW and "hit" or "miss")
			if result == sqlite3.ROW then
				result = select_stmt:get_value(0)
				select_stmt:reset()
				return result
			else
				select_stmt:reset()
			end
			local content = real_getpage(url)
			if content then
				insert_stmt:bind_values(url, content)
				insert_stmt:step()
				insert_stmt:reset()
			end
			return content
		end
	else
		local page_cache = {}
		getpage = function (url)
			local page = page_cache[url]
			if not page then
				page = real_getpage(url)
				page_cache[url] = page
			end
			return page
		end
	end
end

local function read_data_file()
	local subset = arg[1] or ''
	local f = assert(io.open(SOURCE, "r"))
	local file = f:read("*all")
	f:close()

	local sets = {}
	local setcount = 0
	for set, data in file:gmatch('\t%[%"('..subset..'[^"]+)%"%][^=]-= "([^"]-)"') do
		sets[set] = data
		setcount = setcount + 1
	end
	return file, sets, setcount
end

local handlers = {}
--[=[ HELPER FUNCTIONS

Use the helper functions whenever possible.

Doing "for itemid, content in page:gmatch("_%[(%d+)%]=(%b[])") do ... end" is deprecated, because it will match
any item that has a tooltip in the current page. It could be currency, or reagents, or anything else, not just what
you're looking for. Right now, the only exception is the "Bandage" Data, because the tooltip content is analysed.



list = basic_listview_handler(url[, handler[, names]])

basic_listview_handler is a function that should be used as much as possible.

Parameters:
_ url is the url to to fetch data from.
_ handler is the (optional) entry handler. See below.
_ names is the optional name of the listview, in case the url returns several lists. Can be a string or a table.
  if not given, the first table will be used.

_ list is the resulting periodic table.

the handler should be of the form :
result = handler(data)

_ data is the listview data, as a string. Usually has the form : "{id:12345,name:'5foo',...}"
_ result should be the entry in the periodic table, or nil if the entry is not correct.

The default handler will return the "id" of the data.



id = basic_listview_get_first_id(url)

this function return the first "id" of the first entry in the first listview of the given url.
Used when searching for mobs or containers by name.
]=]

local locale_data
local function fetch_locale_data()
	if not locale_data then
		locale_data = {}
		local page = getpage("http://static.wowhead.com/js/locale_enus.js")
		local zones = page:match("g_zones={(.-)}")
		for id, zone in zones:gmatch("(%d+):\"(.-)\"") do
			locale_data[tonumber(id)] = zone
		end
	end
end
local function get_zone_name_from_id(id)
	fetch_locale_data()
	return locale_data[tonumber(id)]
end
local function get_zone_id_from_name(name)
	fetch_locale_data()
	for id,zone in pairs(locale_data) do
		if zone == name then
			return id
		end
	end
end

-- Split string str using sep and merge into t if provided
-- return t or a new table containing the split values
local function StrSplitMerge(sep, str, t)
	local r = t
	if (not r) then
		r = {}
	end

    local nb = # t
    if (string.find(str, sep) == nil) then
	    r[nb + 1] = str
        return r
    end
    local pat = "(.-)" .. sep .. "()"
    local lastPos
    for part, pos in string.gfind(str, pat) do
        nb = nb + 1
        r[nb] = part
        lastPos = pos
    end
    -- Handle the last field
    r[nb + 1] = string.sub(str, lastPos)

	return r
end

-- Used to sort tables with values [-id|id][:value]
local function sortSet(a, b)
	local aId, aValue = a:match("(%-?%d+):(%-?%d+)")
	local bId, bValue = b:match("(%-?%d+):(%-?%d+)")
	if (not aId) then
		aId = a
	else
		aValue = tonumber(aValue)
	end
	if (not bId) then
		bId = b
	else
		bValue = tonumber(bValue)
	end
	aId = tonumber(aId)
	bId = tonumber(bId)

	if (aValue and bValue) then
		if (aValue == bValue) then
			return aId < bId
		else
			return aValue < bValue
		end
	elseif (aValue) then
		return false
	elseif (bValue) then
		return true
	else
		return aId < bId
	end
end

local function basic_itemid_handler(itemstring)
	return itemstring:match("{id:(%-?%d+)")
end

local function basic_listview_handler(url, handler, names)
	if not handler then handler = basic_itemid_handler end
	local page = getpage(url)
	local newset = {}
	if type(names) == "string" then
		names = {[names] = true}
	end
	for view in page:gmatch("new Listview(%b())") do
		local name = view:match("id: '([^']+)'")
		if not names or names[name] then
			local itemlist = view:match("data%: (%b[])")
			for itemstring in itemlist:gmatch("%b{}") do
				local s = handler(itemstring)
				if s then
					newset[#newset + 1] = s
				end
			end
		end
		if not names then break end
	end
	local itemcount = #newset
	dprint(3, itemcount, url)
	table.sort(newset, sortSet)
	return table.concat(newset, ",")
end

local function basic_listview_get_first_id(url)
	local page = getpage(url)
	if not page then return end
	page = page:match("new Listview(%b())")
	if not page then return end
	page = page:match("data: (%b[])")
	if not page then return end
	page = page:match("{id:(%-?%d+)")
	if not page then return end
	return tonumber(page)
end

local function basic_listview_get_npc_id(npc, zone)
	-- override because of a bug in wowhead where the mob is not reported as lootable.
	if npc == "Sathrovarr the Corruptor" then return 24892 end
	local url = "http://www.wowhead.com/?npcs&filter=na="..url.escape(npc)..";cr=9;crs=1;crv=0"
	local page = getpage(url)
	if not page then return end
	page = page:match("new Listview(%b())")
	if not page then return end
	page = page:match("data: (%b[])")
	if not page then return end
	if zone then zone = get_zone_id_from_name(zone) end
	local first_id
	for entry in page:gmatch("%b{}") do
		entry = entry:gsub("'", "\""):gsub("\\\"", "'")
		local id = entry:match("{id:(%d+)")
		local name = entry:match("name:\"([^\"]+)\"")
		local location = entry:match("location:(%[[^%]]+%])")
		if name == npc then
			if zone then
				if location:match("[%[,]"..zone.."[%],]") then
					return tonumber(id)
				end
			else
				return tonumber(id)
			end
		end
		if not first_id then first_id = id end
	end
	return first_id and tonumber(first_id)
end

--[[ STATIC DATA ]]

local Class_Skills = {
	["Death Knight"] = {
		Blood = "7.6.770",
		Frost = "7.6.771",
		Unholy = "7.6.772",
	},
	Druid = {
		Balance = "7.11.574",
		["Feral Combat"] = "7.11.134",
		Restoration = "7.11.573",
	},
	Hunter = {
		["Beast Mastery"] = "7.3.50",
		Marksmanship = "7.3.163",
		Survival = "7.3.51",
	},
	Mage = {
		Arcane = "7.8.237",
		Fire = "7.8.8",
		Frost = "7.8.6",
	},
	Paladin = {
		Holy = "7.2.594",
		Protection = "7.2.267",
		Retribution = "7.2.184",
	},
	Priest = {
		Discipline = "7.5.613",
		Holy = "7.5.56",
		["Shadow Magic"] = "7.5.78",
	},
	Rogue = {
		Assassination = "7.4.253",
		Combat = "7.4.38",
		Subtlety = "7.4.39",
	},
	Shaman = {
		["Elemental Combat"] = "7.7.375",
		Enhancement = "7.7.373",
		Restoration = "7.7.374",
	},
	Warlock = {
		Affliction = "7.9.355",
		Demonology = "7.9.354",
		Destruction = "7.9.593",
	},
	Warrior = {
		Arms = "7.1.26",
		Fury = "7.1.256",
		Protection = "7.1.257",
	},
}

local Tradeskill_Gather_filters = {
	Disenchant = 68,
	Fishing = 69,
	Herbalism = 70,
--	Milling = 0, -- TODO: missing on wowhead 08/11/27
	Mining = 73,
	Pickpocketing = 75,
	Skinning = 76,
	Prospecting = 88,
}

local Tradeskill_Tool_filters = {
	Alchemy = {
		"cr=91;crs=12;crv=0", -- Tool - Philosopher's Stone
	},
	Blacksmithing = {
		"cr=91;crs=162;crv=0",-- Tool - Blacksmith Hammer
		"cr=91;crs=161;crv=0",-- Tool - Gnomish Army Knife
		"cr=91;crs=167;crv=0",-- Tool - Hammer Pick
	},
	Cooking = {
		"cr=91;crs=169;crv=0",-- Tool - Flint and Tinder
		"cr=91;crs=161;crv=0",-- Tool - Gnomish Army Knife
	},
	Enchanting = {
		"cr=91;crs=62;crv=0", -- Tool - Runed Adamantite Rod
		"cr=91;crs=10;crv=0", -- Tool - Runed Arcanite Rod
		"cr=91;crs=101;crv=0",-- Tool - Runed Azurite Rod
		"cr=91;crs=6;crv=0",  -- Tool - Runed Copper Rod
		"cr=91;crs=63;crv=0", -- Tool - Runed Eternium Rod
		"cr=91;crs=41;crv=0", -- Tool - Runed Fel Iron Rod
		"cr=91;crs=8;crv=0",  -- Tool - Runed Golden Rod
		"cr=91;crs=7;crv=0",  -- Tool - Runed Silver Rod
		"cr=91;crs=9;crv=0",  -- Tool - Runed Truesilver Rod
	},
	Engineering = {
		"cr=91;crs=14;crv=0", -- Tool - Arclight Spanner
		"cr=91;crs=162;crv=0",-- Tool - Blacksmith Hammer
		"cr=91;crs=161;crv=0",-- Tool - Gnomish Army Knife
		"cr=91;crs=15;crv=0", -- Tool - Gyromatic Micro-Adjustor
	},
	Inscription = {
		--"cr=91;crs=81;crv=0", -- Tool - Hollow Quill
		"cr=91;crs=121;crv=0",-- Tool - Scribe Tools
	},
--	Jewelcrafting = { -- TODO: missing on wowhead 08/11/27
--	},
	Mining = {
		"cr=91;crs=168;crv=0",-- Tool - Bladed Pickaxe
		"cr=91;crs=161;crv=0",-- Tool - Gnomish Army Knife
		"cr=91;crs=167;crv=0",-- Tool - Hammer Pick
		"cr=91;crs=165;crv=0",-- Tool - Mining Pick
	},
	Skinning = {
		"cr=91;crs=168;crv=0",-- Tool - Bladed Pickaxe
		"cr=91;crs=161;crv=0",-- Tool - Gnomish Army Knife
		"cr=91;crs=166;crv=0",-- Tool - Skinning Knife
	},
}

local Reagent_Ammo_filters = {
	Arrow = "6.2",
	Bullet = "6.3",
	Thrown = "2.16",
}

local Containers_ItemsInType_items = {
	["Soul Shard"] = 21342,
	Herb = 22251,
	Enchanting = 21858,
	Engineering = 30745,
	Gem = 30747,
	Inscription = 39489,
	Leatherworking = 34482,
	Mining = 29540,
}

local Bag_filters = {
	Basic = "1.0",
	["Soul Shard"] = "1.1",
	Herb = "1.2",
	Enchanting = "1.3",
	Engineering = "1.4",
	Inscription = "1.8",
	Jewelcrafting = "1.5",
	Leatherworking = "1.7",
	Mining = "1.6",
	Ammo = "11.3",
	Quiver = "11.2",
}

local Tradeskill_Recipe_professions = {
	Leatherworking = 1,
	Tailoring = 2,
	Engineering = 3,
	Blacksmithing = 4,
	Cooking = 5,
	Alchemy = 6,
	["First Aid"] = 7,
	Enchanting = 8,
	Fishing = 9,
	Jewelcrafting = 10,
	-- None for Inscription, yet
}

local Tradeskill_Recipe_filters = {
	Quest = "18;crs=1;crv=0",
	Drop = "72;crs=1;crv=0",
	Crafted = "86;crs=11;crv=0",
	Vendor = "92;crs=1;crv=0",
	Other = "18:72:86:92;crs=5:2:12:2;crv=0:0:0:0",
}

local Tradeskill_Gather_GemsInNodes_nodes = {
	["Copper Vein"] = 1731,
	["Tin Vein"] = 1732,
	["Silver Vein"] = 1733,
	["Iron Deposit"] = 1735,
	["Gold Vein"] = 1734,
	["Mithril Deposit"] = 2040,
	["Dark Iron Deposit"] = 165658,
	["Truesilver Deposit"] = 2047,
	["Small Thorium Vein"] = 324,
	["Hakkari Thorium Vein"] = 180215,
	["Rich Thorium Vein"] = 175404,
	["Fel Iron Deposit"] = 181555,
	["Adamantite Deposit"] = 181556,
	["Rich Adamantite Deposit"] = 181569,
	["Khorium Vein"] = 181557,
	["Cobalt Node"] = 189978,
	["Rich Cobalt Node"] = 189979,
	["Saronite Node"] = 189980,
	["Rich Saronite Node"] = 189981,
	["Titanium Node"] = 191133,
}

local Tradeskill_Profession_filters = {
	Alchemy = "11.171",
	["Blacksmithing.Basic"] = "11.164&filter=cr=5;crs=2;crv=0",
	["Blacksmithing.Armorsmith"] = "11.164.9788",
	["Blacksmithing.Weaponsmith.Axesmith"] = "11.164.17041",
	["Blacksmithing.Weaponsmith.Hammersmith"] = "11.164.17040",
	["Blacksmithing.Weaponsmith.Swordsmith"] = "11.164.17039",
	["Blacksmithing.Weaponsmith.Basic"] = "11.164.9787",
	Cooking = "9.185",
	Enchanting = "11.333",
	["Engineering.Basic"] = "11.202&filter=cr=5;crs=2;crv=0",
	["Engineering.Gnomish"] = "11.202.20219",
	["Engineering.Goblin"] = "11.202.20222",
	["First Aid"] = "9.129",
	Inscription = "11.773",
	Jewelcrafting = "11.755",
	["Leatherworking.Basic"] = "11.165&filter=cr=5;crs=2;crv=0",
	["Leatherworking.Dragonscale"] = "11.165.10656",
	["Leatherworking.Elemental"] = "11.165.10658",
	["Leatherworking.Tribal"] = "11.165.10660",
	Smelting = "11.186",
	["Tailoring.Basic"] = "11.197&filter=cr=5;crs=2;crv=0",
	["Tailoring.Mooncloth"] = "11.197.26798",
	["Tailoring.Shadoweave"] = "11.197.26801",
	["Tailoring.Spellfire"] = "11.197.26797",
	Poisons = "7.4.40",
}

local Gear_Socketed_filters = { -- TODO: check against 200 items/query limit
	Back	= {
		"sl=16;cr=80;crs=5;crv=0",
	},
	Chest	= {
		"sl=5;cr=72:80;crs=1:5;crv=0:0",
		"sl=5;cr=93:80;crs=1:5;crv=0:0",
		"sl=5;cr=93:80:72;crs=2:5:2;crv=0:0:0",
	},
	Feet	= {
		"sl=8;cr=80;crs=5;crv=0",
	},
	Finger	= {
		"sl=11;cr=80;crs=5;crv=0",
	},
	Hands	= {
		"sl=10;cr=80;crs=5;crv=0",
	},
	Head	= {
		"sl=1;cr=80:72;crs=5:1;crv=0:0",
		"sl=1;cr=80:93;crs=5:1;crv=0:0",
		"sl=1;cr=80:93:72;crs=5:2:2;crv=0:0:0",
	},
	Legs	= {
		"sl=7;cr=80;crs=5;crv=0",
	},
	["Main Hand"]	= {
		"sl=21;cr=80;crs=5;crv=0",
	},
	Neck	= {
		"sl=2;cr=80;crs=5;crv=0",
	},
	["One Hand"]	= {
		"sl=13;cr=80;crs=5;crv=0",
	},
	Ranged	= {
		"sl=15;cr=80;crs=5;crv=0",
	},
	Shield	= {
		"sl=14;cr=80;crs=5;crv=0",
	},
	Shoulder	= {
		"sl=3;cr=80:72;crs=5:1;crv=0:0",
		"sl=3;cr=80:93;crs=5:1;crv=0:0",
		"sl=3;cr=80:93:72;crs=5:2:2;crv=0:0:0",
	},
	["Two Hand"]	= {
		"sl=17;cr=80;crs=5;crv=0",
	},
	Waist	= {
		"sl=6;cr=80;crs=5;crv=0",
	},
	Wrist	= {
		"sl=9;cr=80;crs=5;crv=0",
	},
}

local Gear_levelgroups = {
	";maxrl=69",
	";minrl=70;maxrl=70",
	";minrl=71;maxrl=79",
	";minrl=80;maxrl=80",
}

local Gear_Vendor = {
	["Badge of Justice"] = {
		id = 29434,
		["G'eras"] = 18525,
		["Smith Hauthaa"] = 25046,
	},
}

local GearSets_fixedids = {
	["Battlegear of Undead Slaying"] = 533,
	["Blessed Battlegear of Undead Slaying"] = 784,
	["Garb of the Undead Slayer"] = 535,
	["Blessed Garb of the Undead Slayer"] = 783,
	["Regalia of Undead Cleansing"] = 536,
	["Blessed Regalia of Undead Cleansing"] = 781,
	["Undead Slayer's Armor"] = 534,
	["Undead Slayer's Blessed Armor"] = 782,
}

local Currency_Items = {
	["Alterac Valley Mark of Honor"] = 20560,
	["Apexis Crystal"] = 32572,
	["Apexis Shard"] = 32569,
	["Arathi Basin Mark of Honor"] = 20559,
	["Arcane Rune"] = 29736,
	["Arctic Fur"] = 44128,
--	["Arena Points"] = 43307,
	["Badge of Justice"] = 29434,
	["Brewfest Prize Token"] = 37829,
	["Burning Blossom"] = 23247,
	["Coilfang Armaments"] = 24368,
	["Dalaran Cooking Award"] = 43016,
	["Dalaran Jewelcrafter's Token"] = 41596,
	["Dream Shard"] = 34052,
	["Emblem of Heroism"] = 40752,
	["Emblem of Valor"] = 40753,
	["Glowcap"] = 24245,
	["Halaa Battle Token"] = 26045,
	["Halaa Research Token"] = 26044,
	["Heavy Borean Leather"] = 38425,
	["Holy Dust"] = 29735,
--	["Honor Points"] = 43308,
	["Mark of Honor Hold"] = 24579,
	["Mark of the Illidari"] = 32897,
	["Mark of Thrallmar"] = 24581,
	["Necrotic Rune"] = 22484,
	["Spirit Shard"] = 28558,
	["Stone Keeper's Shard"] = 43228,
	["Strand of the Ancients Mark of Honor"] = 42425,
	["Sunmote"] = 34664,
	["Venture Coin"] = 37836,
	["Warsong Gulch Mark of Honor"] = 20558,
	["Winterfin Clam"] = 34597,
	["Wintergrasp Mark of Honor"] = 43589,
}

local Tradeskill_Gem_Color_filters = {
	Red = 0,
	Blue = 1,
	Yellow = 2,
	Purple = 3,
	Green = 4,
	Orange = 5,
	Meta = 6,
	-- Simple = 7,
	Prismatic = 8
}

local Consumable_Bandage_filters = {
	Basic = "cr=86;crs=6;crv=0",
	["Alterac Valley"] = "na=bandage;cr=92:104;crs=1:0;crv=0:Alterac",
	["Warsong Gulch"] = "na=bandage;cr=92:107;crs=1:0;crv=0:Warsong",
	["Arathi Basin"] = "na=bandage;cr=92:107;crs=1:0;crv=0:Arathi",
}

local Consumable_Buff_Type_filters = {
	["Battle"] = "cr=107;crs=0;crv=battle+elixir",
	["Guardian"] = "cr=107;crs=0;crv=guardian+elixir",
	["Both1"] = "cr=107;crs=0;crv=guardian+and+battle+elixir",
	["Both2"] = "cr=107;crs=0;crv=effect+persists+through+death",
}

local InstanceLoot_TrashMobs = {
	["Molten Core"] = { id = 2717, boe = true, levels = 66, },
	["Blackwing Lair"] = { id = 2677, levels = {70,71}, },
	-- ["Zul'Gurub"] = { id = , levels = , }, -- Zul'Gurub has none
	-- ["Ruins of Ahn'Qiraj"] = { id = , levels = , }, -- Ruins of Ahn'Qiraj has none
	["Ahn'Qiraj"] = { id = 3428, levels = 71, }, -- Temple of Ahn'Qiraj really
	["Naxxramas"] = { id = 3456, levels = {83, 85}, },
	["Karazhan"] = { id = 2562, levels = 115, },
	["Serpentshrine Cavern"] = { id = 3607, levels = 128, },
	["The Eye"] = { id = 3842, levels = 128, },
	["Hyjal Summit"] = { id = 3606, levels = 141, },
	["Black Temple"] = { id = 3959, levels = 141, },
	["Sunwell Plateau"] = { id = 4075, levels = 154 },
}

--[[ SET HANDLERS ]]

local function handle_trash_mobs(set)
	local instance = set:match("^InstanceLoot%.([^%.]+)")
	local info = assert(InstanceLoot_TrashMobs[instance], "Instance "..instance.." not found !")
	local levels = type(info.levels) == "number" and { info.levels } or info.levels
	local sets = {}
	for _, level in ipairs(levels) do
		local url = "http://www.wowhead.com/?items&filter=minle="..level..";maxle="..level..";cr=16:"..(info.boe and "3" or "2")..";crs="..info.id..":1;crv=0:0#0+2+1"
		local set = basic_listview_handler(url, function (itemstring)
			local itemid = itemstring:match("{id:(%d+)")
			local count = 0
			local url = "http://www.wowhead.com/?item="..itemid
			basic_listview_handler(url, function (itemstring)
				if instance == "Blackwing Lair" and itemstring:find("Death Talon") then -- Hack for BWL
					count = count + INSTANCELOOT_TRASHMINSRC
				end
				count = count + 1
			end, "dropped-by")
			if count <= INSTANCELOOT_TRASHMINSRC then
				return
			end
			return itemid
		end)
		if set and set ~= "" then
			table.insert(sets, set)
		end
	end
	return table.concat(sets, ",")
end

local is_junk_drop
do
	local junkdrops = {}
	is_junk_drop = function (itemid)
		local value = junkdrops[itemid]
		if value ~= nil then return value end

		local count = 0
		local url = "http://www.wowhead.com/?item="..itemid
		local page = getpage(url)

		local name = page:match("<h1>([^<%-]+)</h1>")
		dprint(4, "name", name)

		basic_listview_handler(url, function () count = count + 1 end, "dropped-by")
		dprint(4, boss, itemid, droprate, count, count > INSTANCELOOT_MAXSRC)

		if count > INSTANCELOOT_MAXSRC then
			dprint(3, name, "Added to Junk (too many source)")
			junkdrops[itemid] = true
			return true
		elseif count == 1 then
			junkdrops[itemid] = false
			return false
		end

		for n, binding in page:gmatch("<b[^>]+>([^<]+)</b><br />Binds when ([a-z ]+)") do
			dprint(5, "Junk check", name, n, binding)
			if n == name and binding == "equipped" then
				dprint(3, name, "Added to Junk (equipped)")
				junkdrops[itemid] = true
				return true
			end
		end

		junkdrops[itemid] = false
		return false
	end
end

handlers["^InstanceLoot%."] = function (set, data)
	if not INSTANCELOOT_CHKSRC then return end
	local newset
	local zone, boss = set:match("([^%.]+)%.([^%.]+)$")
	if boss == " Smite" then
		boss = "Mr. Smite"
		zone = "The Deadmines"
	end
	if boss == "Trash Mobs" then
		return handle_trash_mobs(set)
	end
	local id, type = basic_listview_get_npc_id(boss, zone), "npc"
	if not id then
		id, type = basic_listview_get_first_id("http://www.wowhead.com/?objects&filter=na="..url.escape(boss)), "object"
	end
	if id then
		page = getpage("http://www.wowhead.com/?"..type.."="..id)
		local count = 0
		local drops = {}
		local normaldropslist, heroicdropslist, dropslist
		for list in page:gmatch("new Listview(%b())") do
			local id = list:match("id: '([^']+)'")
			local data = list:match("data%: (%b[])")
			local count = tonumber(list:match("note:[^,]+, (%d+)"))
			dprint(4, id, count)
			if
				id == "contains" or
				id == "normal-drops" or
				id == "drops" or
				id == "normal-contents"
			then
				drops.normal = { data, count }
			elseif id == "heroic-drops" or id == "heroic-contents"	then
				drops.heroic = { data, count }
			end
		end
		local totaldrops

		local handler = function (itemstring)
			local itemid = itemstring:match("{id:(%d+)")
			dprint(8, "checking item", itemid)
			if is_junk_drop(itemid) then return end
			local dropcount = tonumber(itemstring:match("count:(%d+)"))
			local droprate = dropcount and math.floor(dropcount / totaldrops * 1000) or 0
			local quality = 6 - tonumber(itemstring:match("name:'(%d)"))
			if quality < 1 then return end
			return itemid..":"..droprate
		end

		if drops.normal then
			local itemlist
			itemlist, totaldrops = unpack(drops.normal)
			for itemstring in itemlist:gmatch("%b{}") do
				local v = handler(itemstring)
				if v then
					if newset then
						newset = newset..","..v
					else
						newset = v
					end
					count = count + 1
				end
			end
		else
			print("*ERROR* NO DROPS FOR "..boss)
		end
		if drops.heroic then
			local normalsub = set:match("^InstanceLoot%.(.+)$")
			local heroicname = "InstanceLootHeroic."..normalsub
			local heroicstr, itemlist
			itemlist, totaldrops = unpack(drops.heroic)
			for itemstring in itemlist:gmatch("%b{}") do
				local v = handler(itemstring)
				if v then
					if heroicstr then
						heroicstr = heroicstr..","..v
					else
						heroicstr = v
					end
				end
			end
			sets[heroicname] = heroicstr
		end
		dprint(2, "InstanceLoot: "..boss.." has "..count)
		if count == 0 then newset = "" end
	else
		print("*ERROR* "..boss.. " NOT FOUND !")
	end
	return newset
end

handlers["^GearSet"] = function (set, data)
	local newset, id
	local setname = set:match("%.([^%.]+)$")
	if GearSets_fixedids[setname] then
		id = GearSets_fixedids[setname]
	elseif set:find(".PvP.Arena.") then
		id = basic_listview_get_first_id("http://www.wowhead.com/?itemsets&filter=qu=4;maxle=130;na="..url.escape(setname))
	else
		id = basic_listview_get_first_id("http://www.wowhead.com/?itemsets&filter=na="..url.escape(setname))
	end
	if id then
		local count = 0
		page = getpage("http://www.wowhead.com/?itemset="..id)
		for itemstring in page:gmatch("ge%('iconlist%-icon%d+'%)[^\n]+") do
			local itemid = itemstring:match("%.createIcon%((%d+)")
			if itemid then
				if newset then
					newset = newset..","..itemid
				else
					newset = itemid
				end
				count = count + 1
			else
				error("no itemid")
			end
		end
		dprint(2, "GearSet: "..setname.." has "..count)
	end
	return newset
end

handlers["^Misc%.Reagent%.Ammo"] = function (set, data)
	local newset
	local setname = set:match("%.([^%.]+)$")
	local count = 0
	local filter = Reagent_Ammo_filters[setname]
	if not filter then return end
	newset = basic_listview_handler("http://www.wowhead.com/?items="..filter, function (itemstring)
		count = count + 1
		local itemid = itemstring:match("{id:(%d+)")
		local dps = itemstring:match("dps:(%d+%.%d+)")
		dps = math.floor(tonumber(dps)*10)
		return itemid..":"..dps
	end)
	dprint(2, "Reagent.Ammo."..setname..":"..count)
	return newset
end

handlers["^Misc%.Bag%."] = function (set, data)
	local setname = set:match("%.([^%.]+)$")
	local searchstring = Bag_filters[setname]
	if not searchstring then return end
	return basic_listview_handler("http://www.wowhead.com/?items="..searchstring, function (itemstring)
		local itemid = itemstring:match("{id:(%d+)")
		local nslots = itemstring:match("nslots:(%d+)")
		return itemid..":"..nslots
	end)
end

handlers["^Consumable%.Bandage"] = function (set, data)
	local newset
	local setname = set:match("%.([^%.]+)$")
	local filter = Consumable_Bandage_filters[setname]
	if not filter then return end
	local page = getpage("http://www.wowhead.com/?items&filter="..filter)
	for itemid, content in page:gmatch("_%[(%d+)%]=(%b[])") do
		local heal = content:match("Heals (%d+) damage")
		if heal then
			if newset then
				newset = newset..","..itemid..":"..heal
			else
				newset = itemid..":"..heal
			end
		end
	end
	return newset
end

handlers["^Consumable%.Buff Type"] = function (set, data)
	local newset
	local setname = set:match("%.([^%.]+)$")

	local filter = Consumable_Buff_Type_filters[setname]
	if setname ~= "Both"and not filter then return end

	local list = {}
	local handler = function (itemstring)
		local id = itemstring:match("{id:(%d+)")
		list[id] = true
	end
	basic_listview_handler("http://www.wowhead.com/?items&filter="..Consumable_Buff_Type_filters.Both1, handler)
	basic_listview_handler("http://www.wowhead.com/?items&filter="..Consumable_Buff_Type_filters.Both2, handler)
	local both = {}
	for entry in pairs(list) do
		both[#both+1] = entry
	end
	both = table.concat(both,",")

	if setname == 'Both' then
		return both
	end

	local page = getpage("http://www.wowhead.com/?items&filter="..filter)

	return basic_listview_handler("http://www.wowhead.com/?items&filter="..filter, function (itemstring)
		local itemid = itemstring:match("{id:(%d+)")
		if not both:match(itemid) then
			return itemid
		end
	end)
end

handlers["^Tradeskill%.Gather%.GemsInNodes"] = function (set, data)
	local nodetype = set:match("%.([^%.]+)$")
	local count = 0
	dprint(9, nodetype)
	local id = Tradeskill_Gather_GemsInNodes_nodes[nodetype]
	if not id then return end
	return basic_listview_handler("http://www.wowhead.com/?object="..id, function(itemstring)
		local itemid = itemstring:match("{id:(%d+)")
		local class = itemstring:match("classs?:(%d+)")
		if class == "3" then return itemid end
	end)
end


handlers["^Tradeskill%.Crafted"] = function (set, data)
	local profession = set:match("^Tradeskill%.Crafted%.(.+)$")
	dprint(9, "profession", profession)
	local filter = Tradeskill_Profession_filters[profession]
	if not filter then return end

	local newset, fp_set, rp_set, lp_set = {}, {}, {}, {}

	local reagenttable = {}
	basic_listview_handler("http://www.wowhead.com/?spells="..filter, function (itemstring)
		local spellid = itemstring:match("%{id:(%d+)")
		local skilllvl = itemstring:match("learnedat:(%d+)")
		local reagentstring = itemstring:match("reagents:(%b[])")
		if not reagentstring then return end
		skilllvl = math.min(450, tonumber(skilllvl) or 450)
		local itemid
		dprint(3, profession, itemid, skilllvl, reagentstring)
		itemid = itemstring:match("creates:%[(%d+),(%d+),(%d+)%]") or (-1 * spellid) -- count ?
		if itemid and skilllvl > 0 then
			newset[#newset + 1] = itemid..":"..skilllvl
			local newrecipemats = itemid..":"
			for reagentid,reagentnum in reagentstring:sub(2,-2):gmatch("%[(%d+),(%d+)%]") do
				if reagenttable[reagentid] then
					reagenttable[reagentid] = reagenttable[reagentid]..";"..itemid.."x"..reagentnum
				else
					reagenttable[reagentid] = itemid.."x"..reagentnum
				end
				newrecipemats = newrecipemats..reagentid.."x"..reagentnum..";"
			end
			newrecipemats = newrecipemats:sub(1,-2)
			fp_set[#fp_set + 1] = newrecipemats
			lp_set[#lp_set + 1] = "-"..spellid..":"..itemid
		end
	end)
	for k,v in pairs(reagenttable) do
		rp_set[#rp_set + 1] = k..":"..v
	end

	sets["TradeskillResultMats.Forward."..profession] = table.concat(fp_set, ",")
	sets["TradeskillResultMats.Reverse."..profession] = table.concat(rp_set, ",")
	table.sort(lp_set, sortSet)
	sets["Tradeskill.RecipeLinks."..profession] = table.concat(lp_set, ",")

	table.sort(newset, sortSet)
	return table.concat(newset, ",")
end

handlers["^Tradeskill%.Gather"] = function (set, data)
	local count = 0
	local gathertype = set:match("%.([^%.]+)$")
	local filter = Tradeskill_Gather_filters[gathertype]
	if filter then
		return basic_listview_handler("http://www.wowhead.com/?items&filter=cr="..filter..";crs=1;crv=0")
	end
end

handlers["^Tradeskill%.Recipe%."] = function (set, data)
	local count = 0
	local profession, filter = set:match("^Tradeskill%.Recipe%.([^%.]+)%.(.+)$")
	profession = Tradeskill_Recipe_professions[profession]
	filter = Tradeskill_Recipe_filters[filter]
	if not profession or not filter then return end

	local url = "http://www.wowhead.com/?items=9."..profession.."&filter=cr="..filter

	return basic_listview_handler(url, function (itemstring)
		local itemid = itemstring:match("{id:(%d+)")
		local skilllvl = itemstring:match("skill:(%d+)")
		return itemid..":"..skilllvl
	end)
end

handlers["^Tradeskill%.Tool"] = function (set, data)
	local newset = {}
	local count = 0
	local profession = set:match("^Tradeskill%.Tool%.(.+)$")
	local filters = Tradeskill_Tool_filters[profession]
	if not filters then return end

	for _, filter in ipairs(filters) do
		local nset = basic_listview_handler("http://www.wowhead.com/?items&filter="..filter)
		if nset and nset ~= "" then
			StrSplitMerge(",", nset, newset)
		end
	end

	table.sort(newset, sortSet)
	return table.concat(newset, ",")
end

handlers["^Tradeskill%.Mat%.ByProfession"] = function (set, data)
	local profession = set:match("^Tradeskill%.Mat%.ByProfession%.(.+)$")
	local filter = Tradeskill_Profession_filters[profession]
	if not filter then return end
	local reagentlist = {}

	basic_listview_handler("http://www.wowhead.com/?spells="..filter, function (itemstring)
		local reagents = itemstring:match("reagents:%b[]")
		if not reagents then return end
		for r in reagents:gmatch("%[(%d+),%d+%]") do
			reagentlist[tonumber(r)] = true
		end
	end)
	local newset = {}
	for reagent in pairs(reagentlist) do
		newset[#newset + 1] = reagent
	end
	table.sort(newset)
	return table.concat(newset, ",")
end

handlers["^Tradeskill%.Gem%.Cut$"] = function (set, data)
	local newset
	local gems = {}
	basic_listview_handler("http://www.wowhead.com/?items&filter=cr=81;crs=5;crv=0", function (itemstring)
		local itemid = itemstring:match("{id:(%d+)")
		local page = getpage("http://www.wowhead.com/?item="..itemid)
		for list in page:gmatch("new Listview(%b())") do
			if list:match("id: 'created%-by'") then
				local itemlist = list:match("data: %b[]")
				for itemstring in itemlist:gmatch("%b{}") do
					local reagents = itemstring:match("reagents:%b[]")
					for src_id, count in reagents:gmatch("%[(%d+),(%d+)%]") do
						if src_id ~= "27860" then -- Purified Draenic Water
							local src = gems[src_id] or ""
							gems[src_id] = src..";"..itemid
						end
					end
				end
			end
		end
	end)
	for k, v in pairs(gems) do
		if newset then
			newset = newset..","..k..":"..v:sub(2)
		else
			newset = k..":"..v:sub(2)
		end
	end
	return newset
end

handlers["^Tradeskill%.Gem"] = function (set, data)
	local color = set:match("%.([^%.]+)$")
	local filter = Tradeskill_Gem_Color_filters[color]
	if not filter then return end
	return basic_listview_handler("http://www.wowhead.com/?items=3."..filter)
end

handlers["^Misc%.Minipet%.Normal"] = function (set, data)
	local newset
	local count = 0
	local page = getpage("http://www.wowhead.com/?items=15.2")
	local itemlist = page:match("new Listview(%b())"):match("data%: (%b[])")
	for itemstring in itemlist:gmatch("%b{}") do
		local itemid = itemstring:match("{id:(%d+)")
		if newset then
			newset = newset..","..itemid
		else
			newset = itemid
		end
		count = count + 1
	end
	return newset
end

handlers["^Misc%.Lockboxes"] = function (set, data)
	return basic_listview_handler("http://www.wowhead.com/?items&filter=cr=10;crs=1;crv=0", function (itemstring)
		local itemid = itemstring:match("{id:(%d+)")
		page = getpage("http://www.wowhead.com/?item="..itemid.."&xml")
		local skill = page:match("Requires Lockpicking %((%d+)%)")
		if skill then
			return itemid..":"..skill
		else
			print("Misc Lockboxes error for item "..itemid)
		end
	end)
end

handlers["Misc%.Container%.ItemsInType"] = function (set, data)
	local newset
	local container = set:match("%.([^%.]+)$")
	local container_id = Containers_ItemsInType_items[container]
	if not container_id then return end
	local page = getpage("http://www.wowhead.com/?item="..container_id)
	for list in page:gmatch("new Listview(%b())") do
		if list:match("id: 'can%-contain'") then
			local itemlist = list:match("data: %b[]")
			for itemstring in itemlist:gmatch("%b{}") do
				local itemid = itemstring:match("{id:(%d+)")
				if newset then
					newset = newset..","..itemid
				else
					newset = itemid
				end
			end
		end
	end
	return newset
end

handlers["^Misc%.Usable%.StartsQuest$"] = function (set, data)
	local tmp = {}
	local l
	for q = 0, 5 do	-- do not do 6 heirloom, it just causes a timeout delay as there are none atm
		if (q == 1) then
			for level = 0, 90, 30 do
				l = basic_listview_handler(string.format("http://www.wowhead.com/?items&filter=qu=1;minrl=%d;maxrl=%d;cr=6;crs=1;crv=0", level, level + 29))
				if l and l ~= "" then
					StrSplitMerge(",", l, tmp)
				end
			end
		else
			l = basic_listview_handler(string.format("http://www.wowhead.com/?items&filter=qu=%d;cr=6;crs=1;crv=0", q))
			if l and l ~= "" then
				StrSplitMerge(",", l, tmp)
			end
		end
	end
	table.sort(tmp, sortSet)
	return table.concat(tmp, ",")
end
--[[
-- For the love of god, there is no way in HELL for wowhead to return the right stuff.  Do not ever enable this rubbish.  I spent a LOT of time getting the list correct.
handlers["^Misc%.Usable%.Quest$"] = function (set, data)
	-- DO NOT EVER IMPLEMENT THIS
end
]]

handlers["^Gear%.Socketed"] = function (set, data)
	local newset = {}
	local slot = set:match("%.([^%.]+)$")
	for _,filter in ipairs(Gear_Socketed_filters[slot]) do
		for _, levelfilter in ipairs(Gear_levelgroups) do
			local nset = basic_listview_handler("http://www.wowhead.com/?items&filter="..filter..levelfilter)
			if nset and nset ~= "" then
				StrSplitMerge(",", nset, newset)
			end
		end
	end

	table.sort(newset, sortSet)
	return table.concat(newset, ",")
end

handlers["^Gear%.Trinket$"] = function (set, data)
	return basic_listview_handler("http://www.wowhead.com/?items=4.-4")
end

handlers["^ClassSpell"] = function (set, data)
	local class, tree = set:match('^ClassSpell%.(.+)%.(.+)$')
	return basic_listview_handler("http://www.wowhead.com/?spells="..Class_Skills[class][tree], function(itemstr)
		local itemid = (-1 * itemstr:match("{id:(%d+)"))
		local level = itemstr:match('level:(%d+)')
		return itemid..":"..level
	end)
end

handlers["^Gear%.Vendor"] = function (set, data)
	local currency, vendor = set:match("^Gear%.Vendor%.(.+)%.(.+)$")
	local currency_id, vendor_id = assert(Gear_Vendor[currency].id), assert(Gear_Vendor[currency][vendor])
	return basic_listview_handler("http://www.wowhead.com/?npc="..vendor_id, function (itemstr)
		local itemid = itemstr:match("{id:(%d+)")
		local class = tonumber(itemstr:match("classs:(%d+)"))
		local count = itemstr:match("%[%["..currency_id..",(%d+)%]%]")
--		print(itemid, count)
		if count and (class == 2 or class == 4) then
			return itemid..":"..count
		end
	end, "sells")
end

handlers["^CurrencyItems"] = function (set, data)
	local currency = set:match("^CurrencyItems%.([^%.]+)")
	if not Currency_Items[currency] then return end
	local currency_id = assert(Currency_Items[currency])
	return basic_listview_handler("http://www.wowhead.com/?item="..currency_id, function (itemstr)
		local itemid = itemstr:match("{id:(%d+)")
		local cost = itemstr:match("cost:(%b[])")
		local count = cost:match("%["..currency_id..",(%d+)%]")
		if not count then print(itemstr) end
		return itemid..":"..count
	end, "currency-for")
end


local function update_all_sets(sets, setcount)
	local setid = 0
	local notmined = {}
	for set, data in pairs(sets) do
		setid = setid + 1
		dprint(1, ("current set: %4d/%4d"):format(setid, setcount), set)
		local newset
		if data:sub(1,2) ~= "m," then
			for pattern, handler in pairs(handlers) do
				if set:match(pattern) then
					local status, result = pcall(handler, set, data)
					if status then
						if result then
							newset = result
							break
						end
					else
						dprint(1, "ERR", set, pattern, result)
					end
				end
			end
		end
		if newset then
			printdiff(set, sets[set], newset)
			sets[set] = newset
		else
			table.insert(notmined, set)
		end
	end
	return notmined
end

local function write_output(file, sets)
	local f = assert(io.open(SOURCE, "w"))
	for line in file:gmatch('([^\n]-\n)') do
		local setname, spaces, comment = line:match('\t%[%"([^"]+)%"%]([^=]-)= "[^"]-",([^\n]-)\n')
		if setname and sets[setname] then
			f:write('\t["'..setname..'"]'..spaces..'= "'..sets[setname]..'",'..comment..'\n')
		else
			f:write(line)
		end
	end
	f:close()
end

local function main()
	local starttime = os.time()

	local file, setcount
	file, sets, setcount = read_data_file()
	local notmined = update_all_sets(sets, setcount)
	local elapsed = os.time()- starttime
	local cputime = os.clock()
	print(("Elapsed Time: %dm %ds"):format(elapsed/60, elapsed%60))
	print(("%dm %ds spent servicing %d web requests"):format(httptime/60, httptime%60, httpcount))
	print(("%dm %ds spent in processing data"):format((elapsed-httptime)/60,(elapsed-httptime)%60))
	print(("Approx %dm %.2fs CPU time used"):format(cputime/60, cputime%60))
	local notminedcount = 0
	for k,v in ipairs(notmined) do
		--print("not mined:"..v)
		notminedcount = notminedcount + 1
	end
	print(("%d sets mined, %d sets not mined."):format(setcount-notminedcount, notminedcount))
	write_output(file, sets)
end

main()
