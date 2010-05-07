-- (c) 2007 Nymbia.  see LGPLv2.1.txt for full details.
--this tool is run in the lua command line.  http://lua.org
--socket is required for internet data.
--get socket here: http://luaforge.net/projects/luasocket/
--if available curl will be used, which allows connection re-use
--if available, sqlite3 will be used for the cache database

local SOURCE = SOURCE or "data.lua"
local DEBUG = DEBUG or 2
local INSTANCELOOT_CHKSRC = INSTANCELOOT_CHKSRC
local INSTANCELOOT_MIN = INSTANCELOOT_MIN or 50
local INSTANCELOOT_MAXSRC = INSTANCELOOT_MAXSRC or 5
local INSTANCELOOT_TRASHMINSRC = INSTANCELOOT_TRASHMINSRC or 3

local MAX_TRADESKILL_LEVEL = 450

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
	-- we remove the drop rate for these sets in the diff,
	-- because they are irrelevant to the comparison
	local has_drop_rate = set:find("InstanceLoot", nil, true)
			and not set:find("Trash Mobs", nil, true)
	local temp = {}
	if old then
		for entry in old:gmatch("[^,]+") do
			if has_drop_rate then entry = entry:match("(%d+):%d+") end
			temp[entry] = -1
		end
	end
	if new then
		for entry in new:gmatch("[^,]+") do
			if has_drop_rate then entry = entry:match("(%d+):%d+") end
			temp[entry] = (temp[entry] or 0) + 1
		end
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

local json = require"json"
json.register_constant("undefined", json.null)
local url = require("socket.url")
local httptime, httpcount = 0, 0

local WOWHEAD_FILTER_PARAMS = { "na", "minle", "maxle", "minrl", "maxrl", "qu", "sl", "cr", "crs", "crv" }

local function WH(page, value, filter)
	local escape = url.escape
	local url = {"http://www.wowhead.com/", page}
	if value then
		url[#url + 1] = "="
		url[#url + 1] = escape(value)
	end
	if filter then
		url[#url + 1] = "&filter="
		if type(filter) == "table" then
			local first = true
			for _, k in ipairs(WOWHEAD_FILTER_PARAMS) do
				local v = filter[k]
				if v then
					if not first then
						url[#url + 1] = ";"
					else
						first = false
					end
					url[#url + 1] = escape(k)
					url[#url + 1] = "="
					if type(v) == "table" then
						for i, s in ipairs(v) do
							if i > 1 then url[#url + 1] = ":" end
							url[#url + 1] = escape(s)
						end
					else
						url[#url + 1] = escape(v)
					end
				end
			end
		else
			-- we don't escape if filter is a string
			url[#url + 1] = filter
		end
	end
	return table.concat(url)
end

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
			dprint(3, "curl", url)
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
			dprint(3, "socket.http", url)
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
			dprint(4, "cache", url, result == sqlite3.ROW and "hit" or "miss")
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
	local subset = string.gsub(arg[1] or '','%.','%.')
	local f = assert(io.open(SOURCE, "r"))
	local file = f:read("*all")
	f:close()

	local sets = {}
	local setcount = 0
	for set, data in file:gmatch('\t%[%"('..subset..'[^"]*)%"%][^=]-= "([^"]-)"') do
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

Use WH() to create url to wowhead. This will allow a single place to modify in case wowhead changes it's url format again.

url = WH(type[, value[, filter]])

Parameters:
_ type is the basic query type ("items", "item", "spell", ...)
_ value is the optional base value of the request (for instance WH("spell", 12345) will return the URL for the spell 12345
_ filter is the optional filtering data. It can either be a table or a string. The string is added as-is in the url, the table
  is analysed and transformed into a string using the format required by wowhead. USE the table format if possible.

The function returns the url for the query.

list = basic_listview_handler(url[, handler[, names[, inplace_list]]])

basic_listview_handler is a function that should be used as much as possible.

Parameters:
_ url is the url to to fetch data from.
_ handler is the (optional) entry handler. See below.
_ names is the optional name of the listview, in case the url returns several lists. Can be a string or a table.
  if not given, the first table will be used.
_ inplace_list is an optional array that will be filled with the result of handlers, instead of a new one.
  If inplace_list is given, then basic_listview_handler() return value should be discarded.
  No sorting and string concat is performed if inplace_list is not nil.

_ list is the resulting periodic table.

the handler should be of the form :
result = handler(data)

_ data is on entry in the listview, as a lua array.
_ result should be the entry in the periodic table, or nil if the entry is not correct.
  result will be converted to string after handler.

The default handler will return the id of the data.

id = basic_listview_get_first_id(url)

this function return the first "id" of the first entry in the first listview of the given url.
Used when searching for mobs or containers by name.

multiple_qualities_listview_handler is used to split a search between several qualities and level restrictions
when the amount of elements returned by a simple search is too important.

]=]

local REJECTED_TEMPLATES = {
	comment = true,
	screenshot = true,
}
local function get_page_listviews(url)
	local page = assert(getpage(url))
	local views = {}
	for view in page:gmatch("new Listview(%b())") do
		local template = view:match("template: ?'(.-)'[,}]")
		local id = view:match("id: ?'(.-)'[,}]")
		local data = view:match("data: ?(%b[])[,}]")
		if data and not REJECTED_TEMPLATES[template] then
			-- for droprate support
			local count = view:match("_totalCount: ?(%d+)[,}]")
			views[id] = {id = id, data = json(data, true), count = count and tonumber(count)}
		end
	end
	return views
end

local locale_data
local function fetch_locale_data()
	if not locale_data then
		local page = assert(getpage("http://static.wowhead.com/js/locale_enus.js"))
		locale_data = json(page:match("g_zones=(%b{})"), true)
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


-- Used to sort tables with values [-id|id][:value] using value as primary sort data
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

-- Used to sort tables with values [-id|id][:value] using id as primary sort data
local function sortSet_id(a, b)
	local aId, aValue = a:match("(%-?%d+):")
	local bId, bValue = b:match("(%-?%d+):")
	if (not aId) then
		aId = a
	end
	if (not bId) then
		bId = b
	end
	aId = tonumber(aId)
	bId = tonumber(bId)

	return aId < bId
end

local function basic_itemid_handler(item)
	return item.id
end

local function basic_listview_handler(url, handler, names, inplace_set)
	if not handler then handler = basic_itemid_handler end
	local newset = inplace_set or {}
	if type(names) == "string" then
		names = {[names] = true}
	end
	local views = get_page_listviews(url)
	for name, view in pairs(views) do
		if not names or names[name] then
			for _, item in ipairs(view.data) do
				local s = handler(item)
				if s then
					newset[#newset + 1] = tostring(s)
				end
			end
		end
		if not names then break end
	end
	local itemcount = #newset
	dprint(3, itemcount, url)
	if not inplace_set then
		table.sort(newset, sortSet)
		return table.concat(newset, ",")
	end
end

local function basic_listview_get_first_id(url)
	local views = get_page_listviews(url)
	if not views then return end
	local _, view = next(views)
	if not view then return end
	local _, item = next(view.data)
	if not item then return end
	return item.id
end

local function is_in(table, value)
	for _, v in pairs(table) do
		if v == value then return true end
	end
end

local function basic_listview_get_npc_id(npc, zone)
	-- override because of a bug in wowhead where the mob is not reported as lootable.
	if npc == "Sathrovarr the Corruptor" then return 24892 end
	local url = WH("npcs", nil, {na = npc, cr=9, crs=1, crv=0})
	local views = get_page_listviews(url)
	if not views.npcs then return end
	local data = views.npcs.data
	if zone then zone = get_zone_id_from_name(zone) end
	local first_id
	for _, entry in ipairs(data) do
		if entry.name == npc and (not zone or not entry.location or is_in(entry.location, zone)) then
			return entry.id
		end
		if not first_id then first_id = entry.id end
	end
	return first_id
end

local function multiple_qualities_listview_handler(type, value, filter, set, typelevel)
	local min, max = "min"..typelevel, "max"..typelevel
	for q = 0, 7 do
		filter.qu = q
		if q == 1 then
			-- we split here because there's a lot of them
			for level = 0, 90, 30 do
				filter[min] = level
				filter[max] = level + 29
				basic_listview_handler(WH(type, value, filter), nil, nil, set)
			end
			filter[min] = nil
			filter[max] = nil
		else
			basic_listview_handler(WH(type, value, filter), nil, nil, set)
		end
	end
end

--[[ STATIC DATA ]]

local Class_Skills_categories = {
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

local Tradeskill_Gather_filter_values = {
	Disenchant = 68,
	Fishing = 69,
	Herbalism = 70,
	Milling = 143,
	Mining = 73,
	Pickpocketing = 75,
	Skinning = 76,
	Prospecting = 88,
}

local Tradeskill_Tool_filters = {
	Alchemy = {
		{cr=91,crs=12,crv=0}, -- Tool - Philosopher's Stone
	},
	Blacksmithing = {
		{cr=91,crs=162,crv=0},-- Tool - Blacksmith Hammer
		{cr=91,crs=161,crv=0},-- Tool - Gnomish Army Knife
		{cr=91,crs=167,crv=0},-- Tool - Hammer Pick
	},
	Cooking = {
		{cr=91,crs=169,crv=0},-- Tool - Flint and Tinder
		{cr=91,crs=161,crv=0},-- Tool - Gnomish Army Knife
	},
	Enchanting = {
		{cr=91,crs=62,crv=0}, -- Tool - Runed Adamantite Rod
		{cr=91,crs=10,crv=0}, -- Tool - Runed Arcanite Rod
		{cr=91,crs=101,crv=0},-- Tool - Runed Azurite Rod
		{cr=91,crs=6,crv=0},  -- Tool - Runed Copper Rod
		{cr=91,crs=63,crv=0}, -- Tool - Runed Eternium Rod
		{cr=91,crs=41,crv=0}, -- Tool - Runed Fel Iron Rod
		{cr=91,crs=8,crv=0},  -- Tool - Runed Golden Rod
		{cr=91,crs=7,crv=0},  -- Tool - Runed Silver Rod
		{cr=91,crs=9,crv=0},  -- Tool - Runed Truesilver Rod
	},
	Engineering = {
		{cr=91,crs=14,crv=0}, -- Tool - Arclight Spanner
		{cr=91,crs=162,crv=0},-- Tool - Blacksmith Hammer
		{cr=91,crs=161,crv=0},-- Tool - Gnomish Army Knife
		{cr=91,crs=15,crv=0}, -- Tool - Gyromatic Micro-Adjustor
	},
	Inscription = {
		--{cr=91,crs=81,crv=0}, -- Tool - Hollow Quill
		{cr=91,crs=121,crv=0},-- Tool - Scribe Tools
	},
--	Jewelcrafting = { -- TODO: missing on wowhead 08/11/27
--	},
	Mining = {
		{cr=91,crs=168,crv=0},-- Tool - Bladed Pickaxe
		{cr=91,crs=161,crv=0},-- Tool - Gnomish Army Knife
		{cr=91,crs=167,crv=0},-- Tool - Hammer Pick
		{cr=91,crs=165,crv=0},-- Tool - Mining Pick
	},
	Skinning = {
		{cr=91,crs=168,crv=0},-- Tool - Bladed Pickaxe
		{cr=91,crs=161,crv=0},-- Tool - Gnomish Army Knife
		{cr=91,crs=166,crv=0},-- Tool - Skinning Knife
	},
}

local Reagent_Ammo_categories = {
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

local Bag_categories = {
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

local Tradeskill_Recipe_categories = {
	Leatherworking = "9.1",
	Tailoring = "9.2",
	Engineering = "9.3",
	Blacksmithing = "9.4",
	Cooking = "9.5",
	Alchemy = "9.6",
	["First Aid"] = "9.7",
	Enchanting = "9.8",
	Fishing = "9.9",
	Jewelcrafting = "9.10",
	-- None for Inscription, yet
}

local Tradeskill_Recipe_filters = {
	Quest = {cr=18,crs=1,crv=0},
	Drop = {cr=72,crs=1,crv=0},
	Crafted = {cr=86,crs=11,crv=0},
	Vendor = {cr=92,crs=1,crv=0},
	Other = {cr={18,72,86,92},crs={5,2,12,2},crv={0,0,0,0}},
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
	["Blacksmithing.Basic"] = {cr=5,crs=2,crv=0},
	["Engineering.Basic"] = {cr=5,crs=2,crv=0},
	["Leatherworking.Basic"] = {cr=5,crs=2,crv=0},
	["Tailoring.Basic"] = {cr=5,crs=2,crv=0},
}

local Tradeskill_Profession_categories = {
	Alchemy = "11.171",
	["Blacksmithing.Basic"] = "11.164",
	["Blacksmithing.Armorsmith"] = "11.164.9788",
	["Blacksmithing.Weaponsmith.Axesmith"] = "11.164.17041",
	["Blacksmithing.Weaponsmith.Hammersmith"] = "11.164.17040",
	["Blacksmithing.Weaponsmith.Swordsmith"] = "11.164.17039",
	["Blacksmithing.Weaponsmith.Basic"] = "11.164.9787",
	Cooking = "9.185",
	Enchanting = "11.333",
	["Engineering.Basic"] = "11.202",
	["Engineering.Gnomish"] = "11.202.20219",
	["Engineering.Goblin"] = "11.202.20222",
	["First Aid"] = "9.129",
	Inscription = "11.773",
	Jewelcrafting = "11.755",
	["Leatherworking.Basic"] = "11.165",
	["Leatherworking.Dragonscale"] = "11.165.10656",
	["Leatherworking.Elemental"] = "11.165.10658",
	["Leatherworking.Tribal"] = "11.165.10660",
	Smelting = "11.186",
	["Tailoring.Basic"] = "11.197",
	["Tailoring.Mooncloth"] = "11.197.26798",
	["Tailoring.Shadoweave"] = "11.197.26801",
	["Tailoring.Spellfire"] = "11.197.26797",
	Poisons = "7.4.40",
}


local Gear_Socketed_filters = {
	Back	= {
		{sl=16,cr=80,crs=5,crv=0},
	},
	Chest	= {
		{sl=5,cr=80,crs=5,crv=0,qu={0,1,2,3}},
		{sl=5,cr=80,crs=5,crv=0,qu={4,5,6,7}},
	},
	Feet	= {
		{sl=8,cr=80,crs=5,crv=0},
	},
	Finger	= {
		{sl=11,cr=80,crs=5,crv=0},
	},
	Hands	= {
		{sl=10,cr=80,crs=5,crv=0},
	},
	Head	= {
		{sl=1,cr=80,crs=5,crv=0,qu={0,1,2,3}},
		{sl=1,cr=80,crs=5,crv=0,qu={4,5,6,7}},
	},
	Legs	= {
		{sl=7,cr=80,crs=5,crv=0},
	},
	["Main Hand"]	= {
		{sl=21,cr=80,crs=5,crv=0},
	},
	Neck	= {
		{sl=2,cr=80,crs=5,crv=0},
	},
	["Off Hand"]	= {
		{sl=22,cr=80,crs=5,crv=0},
	},
	["One Hand"]	= {
		{sl=13,cr=80,crs=5,crv=0},
	},
	Ranged	= {
		{sl=15,cr=80,crs=5,crv=0},
	},
	Shield	= {
		{sl=14,cr=80,crs=5,crv=0},
	},
	Shoulder	= {
		{sl=3,cr=80,crs=5,crv=0,qu={0,1,2,3}},
		{sl=3,cr=80,crs=5,crv=0,qu={4,5,6,7}},
	},
	Trinket	= {
		{sl=12,cr=80,crs=5,crv=0},
	},
	["Two Hand"]	= {
		{sl=17,cr=80,crs=5,crv=0},
	},
	Waist	= {
		{sl=6,cr=80,crs=5,crv=0},
	},
	Wrist	= {
		{sl=9,cr=80,crs=5,crv=0},
	},
}

local Gear_level_filters = {
	{maxrl=59},
	{minrl=60,maxrl=60},
	{minrl=61,maxrl=69},
	{minrl=70,maxrl=70},
	{minrl=71,maxrl=79},
	{minrl=80,maxrl=80},
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
	["Conqueror's Battlegear"] = 496,
	["Garb of the Undead Slayer"] = 535,
	["Blessed Garb of the Undead Slayer"] = 783,
	["Regalia of Undead Cleansing"] = 536,
	["Blessed Regalia of Undead Cleansing"] = 781,
	["Undead Slayer's Armor"] = 534,
	["Undead Slayer's Blessed Armor"] = 782,

-- Arena Season 1
	["Gladiator's Aegis"] = 582,
	["Gladiator's Battlegear"] = 567,
	["Gladiator's Dreadgear"] = 568,
	["Gladiator's Earthshaker"] = 578,
	["Gladiator's Felshroud"] = 615,
	["Gladiator's Investiture"] = 687,
	["Gladiator's Pursuit"] = 586,
	["Gladiator's Raiment"] = 581,
	["Gladiator's Redemption"] = 690,
	["Gladiator's Refuge"] = 685,
	["Gladiator's Regalia"] = 579,
	["Gladiator's Sanctuary"] = 584,
	["Gladiator's Thunderfist"] = 580,
	["Gladiator's Vestments"] = 577,
	["Gladiator's Vindication"] = 583,
	["Gladiator's Wartide"] = 686,
	["Gladiator's Wildhide"] = 585,
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
	["Champion's Seal"] = 44990,
	["Coilfang Armaments"] = 24368,
	["Coin of Ancestry"] = 21100,
	["Dalaran Cooking Award"] = 43016,
	["Dalaran Jewelcrafter's Token"] = 41596,
	["Dream Shard"] = 34052,
	["Emblem of Frost"] = 49426,
	["Emblem of Conquest"] = 45624,
	["Emblem of Heroism"] = 40752,
	["Emblem of Triumph"] = 47241,
	["Emblem of Valor"] = 40753,
	["Glowcap"] = 24245,
	["Halaa Battle Token"] = 26045,
	["Halaa Research Token"] = 26044,
	["Heavy Borean Leather"] = 38425,
	["Holy Dust"] = 29735,
--	["Honor Points"] = 43308,
	["Isle of Conquest Mark of Honor"] = 47395,
	["Mark of Honor Hold"] = 24579,
	["Mark of the Illidari"] = 32897,
	["Mark of Thrallmar"] = 24581,
	["Necrotic Rune"] = 22484,
	["Noblegarden Chocolate"] = 44791,
	["Spirit Shard"] = 28558,
	["Stone Keeper's Shard"] = 43228,
	["Strand of the Ancients Mark of Honor"] = 42425,
	["Sunmote"] = 34664,
	["Venture Coin"] = 37836,
	["Warsong Gulch Mark of Honor"] = 20558,
	["Winterfin Clam"] = 34597,
	["Wintergrasp Mark of Honor"] = 43589,
}

local Tradeskill_Gem_Cut_level_filters = {
	{maxle=60},
	{minle=61,maxle=70,qu=2},
	{minle=61,maxle=70,qu=3},
	{minle=61,maxle=70,qu=4},
	{minle=71,maxle=80,qu=2},
	{minle=71,maxle=80,qu=3},
	{minle=71,maxle=80,qu=4},
	{minle=81},
}

local Tradeskill_Gem_Color_categories = {
	Red = "3.0",
	Blue = "3.1",
	Yellow = "3.2",
	Purple = "3.3",
	Green = "3.4",
	Orange = "3.5",
	Meta = "3.6",
	-- Simple = "3.7",
	Prismatic = "3.8"
}

local Consumable_Bandage_filters = {
	Basic = {cr=86,crs=6,crv=0},
	["Alterac Valley"] = {na="bandage",cr={92,104},crs={1,0},crv={0,"Alterac"}},
	["Warsong Gulch"] = {na="bandage",cr={92,107},crs={1,0},crv={0,"Warsong"}},
	["Arathi Basin"] = {na="bandage",cr={92,107},crs={1,0},crv={0,"Arathi"}},
}

local Consumable_Buff_Type_filters = {
	["Battle"] = {cr=107,crs=0,crv="battle elixir"},
	["Guardian"] = {cr=107,crs=0,crv="guardian elixir"},
	["Both1"] = {cr=107,crs=0,crv="guardian and battle elixir"},
	["Both2"] = {cr=107,crs=0,crv="effect persists through death"},
}

local InstanceLoot_TrashMobs = {
	["Molten Core"] = { id = 2717, boe = true, levels = 66, },
	["Blackwing Lair"] = { id = 2677, levels = {70,71}, },
	-- ["Zul'Gurub"] = { id = , levels = , }, -- Zul'Gurub has none
	-- ["Ruins of Ahn'Qiraj"] = { id = , levels = , }, -- Ruins of Ahn'Qiraj has none
	["Ahn'Qiraj"] = { id = 3428, levels = 71, }, -- Temple of Ahn'Qiraj really
	["Karazhan"] = { id = 2562, levels = 115, },
	["Serpentshrine Cavern"] = { id = 3607, levels = 128, },
	["The Eye"] = { id = 3842, levels = 128, },
	["Hyjal Summit"] = { id = 3606, levels = 141, },
	["Black Temple"] = { id = 3959, levels = 141, },
	["Sunwell Plateau"] = { id = 4075, levels = 154, },
	["Naxxramas"] = { id = 3456, levels = {200, 213}, hasheroic = true },
	["Ulduar"] = { id = 4273, levels = {219, 226, 232}, hasheroic = true },
}



--[[ SET HANDLERS ]]

local function handle_trash_mobs(set)
	local instance = set:match("^InstanceLoot.-%.([^%.]+)")
	local info = assert(InstanceLoot_TrashMobs[instance], "Instance "..instance.." not found !")
	-- 16 = "Drops in...", 105 = "Drops in... (Normal mode), 106 = "Drops in... (Heroic mode)
	local dropsin = set:match("^InstanceLootHeroic%.") and "106" or info.hasheroic and "105" or "16"
	local levels = type(info.levels) == "number" and { info.levels } or info.levels
	local sets = {}
	for _, level in ipairs(levels) do
		local url = WH("items", nil, {minle = level, maxle = level, cr = {dropsin, info.boe and "3" or "2"}, crs = {info.id, 1}, crv={0, 0}})
		local set = basic_listview_handler(url, function (item)
			local itemid = item.id
			local count = 0
			local url = WH("item", itemid)
			basic_listview_handler(url, function (item)
				if instance == "Blackwing Lair" and item.name:find("Death Talon") then -- Hack for BWL
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
		local url = WH("item", itemid)
		local page = getpage(url)

		local name = page:match("<h1>([^<%-]+)</h1>")
		dprint(4, "name", name)

		basic_listview_handler(url, function () count = count + 1 end, "dropped-by")
		dprint(4, boss, itemid, droprate, count, count > INSTANCELOOT_MAXSRC)

		if count > INSTANCELOOT_MAXSRC then
			dprint(3, name, "Added to Junk (too many source)")
			junkdrops[itemid] = true
			return true
		else--if count == 1 then
			junkdrops[itemid] = false
			return false
		end

--~ 		for n, binding in page:gmatch("<b[^>]+>([^<]+)</b><br />Binds when ([a-z ]+)") do
--~ 			dprint(5, "Junk check", name, n, binding)
--~ 			if n == name and binding == "equipped" then
--~ 				dprint(3, name, "Added to Junk (equipped)")
--~ 				junkdrops[itemid] = true
--~ 				return true
--~ 			end
--~ 		end

--~ 		junkdrops[itemid] = false
--~ 		return false
	end
end

handlers["^ClassSpell"] = function (set, data)
	local class, tree = set:match('^ClassSpell%.(.+)%.(.+)$')
	return basic_listview_handler(WH("spells", Class_Skills_categories[class][tree]), function(item)
		return "-"..item.id..":"..item.level
	end)
end

handlers["^Consumable%.Bandage"] = function (set, data)
	local newset
	local setname = set:match("%.([^%.]+)$")
	local filter = Consumable_Bandage_filters[setname]
	if not filter then return end
	local page = getpage(WH("items", nil, filter))
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

local both_buff_types
handlers["^Consumable%.Buff Type"] = function (set, data)
	local newset
	local setname = set:match("%.([^%.]+)$")

	local filter = Consumable_Buff_Type_filters[setname]
	if setname ~= "Both" and not filter then return end

	if not both_buff_types then
		both_buff_types = {}
		local handler = function (item)
			both_buff_types[item.id] = true
		end
		basic_listview_handler(WH("items", nil, Consumable_Buff_Type_filters.Both1), handler)
		basic_listview_handler(WH("items", nil, Consumable_Buff_Type_filters.Both2), handler)
	end


	if setname == 'Both' then
		local list = {}
		for entry in pairs(both_buff_types) do
			list[#list + 1] = entry
		end
		return table.concat(list,",")
	end

	return basic_listview_handler(WH("items", nil, filter), function (item)
		local itemid = item.id
		if not both_buff_types[itemid] then
			return itemid
		end
	end)
end

handlers["^Consumable%.Scroll"] = function (set, data)
	return basic_listview_handler(WH("items", "0.4"))
end

handlers["^CurrencyItems"] = function (set, data)
	local currency = set:match("^CurrencyItems%.([^%.]+)")
	if not Currency_Items[currency] then return end
	local currency_id = assert(Currency_Items[currency])
	return basic_listview_handler(WH("item", currency_id), function (item)

		local count
		for _, v in ipairs(item.cost[4]) do
			if v[1] == currency_id then
				count = v[2]
				break
			end
		end
		if not count then print(itemstr) end
		return item.id..":"..count
	end, "currency-for")
end


handlers["^Gear%.Socketed"] = function (set, data)
	local newset = {}
	local slot = set:match("%.([^%.]+)$")
	for _, filter in ipairs(Gear_Socketed_filters[slot]) do
		for _, levelfilter in ipairs(Gear_level_filters) do
			filter.minrl = levelfilter.minrl
			filter.maxrl = levelfilter.maxrl
			basic_listview_handler(WH("items", nil, filter), nil, nil, newset)
		end
	end

	table.sort(newset, sortSet)
	return table.concat(newset, ",")
end

handlers["^Gear%.Trinket$"] = function (set, data)
	local newset = {}
	for q = 1, 7  do
		basic_listview_handler(WH("items", "4.-4", {qu=q}), nil, nil, newset)
	end

	table.sort(newset, sortSet)
	print("Trinkets Total:", # newset)
	return table.concat(newset, ",")
end

handlers["^Gear%.Vendor"] = function (set, data)
	local currency, vendor = set:match("^Gear%.Vendor%.(.+)%.(.+)$")
	local currency_id, vendor_id = assert(Gear_Vendor[currency].id), assert(Gear_Vendor[currency][vendor])
	return basic_listview_handler(WH("npc", vendor_id), function (item)
		local class = item.classs
		local count
		for i, v in ipairs(item.cost) do
			if v == currency_id then
				count = item.cost[i + 1]
				break
			end
		end
		if count and (class == 2 or class == 4) then
			return item.id..":"..count
		end
	end, "sells")
end

handlers["^GearSet"] = function (set, data)
	local newset, id = {}, nil
	local setname = set:match("%.([^%.]+)$")
	if GearSets_fixedids[setname] then
		id = GearSets_fixedids[setname]
	elseif set:find(".Gray.") then
	-- these aren't real sets so they can't be auto-mined
		return nil
	elseif set:find(".PvP.Arena.") then
	-- wowhead can't do exact match on name as it seems so other arena sets including the name would show up to (and be picked unfortunatly)
		id = basic_listview_get_first_id(WH("itemsets", nil, {qu=4, na=setname}))
	else
		id = basic_listview_get_first_id(WH("itemsets", nil, {na=setname}))
	end
	if id then
		local count = 0
		page = getpage(WH("itemset", id))
		local summary = json(page:match("new Summary%((%b{})%)"), true)
		for _, g in ipairs(summary.groups) do
			local itemid = g[1][1]
			if itemid then
				newset[#newset + 1] = tostring(itemid)
				count = count + 1
			else
				error("no itemid")
			end
		end
		dprint(2, "GearSet: "..setname.." has "..count)
		table.sort(newset, sortSet)
		return table.concat(newset, ",")
	end
end

handlers["^InstanceLoot%."] = function (set, data)
	if not INSTANCELOOT_CHKSRC then return end
	local newset = {}
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
		local zoneid = get_zone_id_from_name(zone)
		local filter = zoneid and {cr=1, crs=zoneid, crv=0} or {}
		filter.na = boss
		id, type = basic_listview_get_first_id(WH("objects", nil, filter)), "object"
	end
	if id then
		local views = get_page_listviews(WH(type, id))
		local heroicname, heroicset

		local handler = function (item)
			dprint(8, "checking item", item.id)
			if is_junk_drop(item.id) then return end
			local droprate = item.count and (totaldrops > 0) and math.floor(item.count / totaldrops * 1000) or 0
			local quality = 6 - tonumber(item.name:match("^(%d)"))
			if quality < 1 then return end
			return item.id..":"..droprate
		end

		local handle_normal_list = function (itemlist, count)
			totaldrops = count
			for _, item in ipairs(itemlist) do
				local v = handler(item)
				if v and not is_in(newset, v) then
					newset[#newset + 1] = v
				end
			end
		end

		local handle_heroic_list = function (itemlist, count)
			if heroicname == nil then
				local normalsub = set:match("^InstanceLoot%.(.+)$")
				heroicname = "InstanceLootHeroic."..normalsub
				if not sets[heroicname] then
					dprint(2, "ERR MISSING Heroic set for " .. normalsub)
					heroicname = false
				else
					heroicset = {}
				end
			end
			if not heroicname then return end
			totaldrops = count
			for _, item in ipairs(itemlist) do
				local v = handler(item)
				if v and not is_in(heroicset, v) then
					heroicset[#heroicset + 1] = v
				end
			end
		end

		-- two pass to handle the changing meaning of "heroic"
		for id, view in pairs(views) do
			if
				id == "heroic-drops" or
				id == "heroic-contents" or
				id == "heroic-10-drops" or
				id == "heroic-25-drops"
			then
				handle_heroic_list(view.data, view.count)
			end
		end
		for id, view in pairs(views) do
			if
				id == "contains" or
				id == "normal-drops" or
				id == "drops" or
				id == "normal-contents" or
				id == "normal-10-drops"
			then
				handle_normal_list(view.data, view.count)
			elseif id == "normal-25-drops" then
				if heroicset then
					handle_normal_list(view.data, view.count)
				else
					handle_heroic_list(view.data, view.count)
				end
			end
		end
		if heroicset then
			table.sort(heroicset, sortSet_id)
			local set = table.concat(heroicset, ",")
			printdiff(heroicname, sets[heroicname] or "", set)
			sets[heroicname] = set
		end
		local count_normal = newset and #newset or 0
		local count_heroic = heroicset and #heroicset or 0
		dprint(2, "InstanceLoot: "..boss.." has "..count_normal.." normal and "..count_heroic.." heroic drops.")
		table.sort(newset, sortSet_id)
		return table.concat(newset, ",")
	else
		print("*ERROR* "..boss.. " NOT FOUND !")
	end
end

handlers["^InstanceLootHeroic%..+%.Trash Mobs"] = function (set, data)
	return handle_trash_mobs(set)
end

handlers["^Misc%.Bag%."] = function (set, data)
	local setname = set:match("%.([^%.]+)$")
	local cat = Bag_categories[setname]
	if not cat then return end
	return basic_listview_handler(WH("items", cat), function (item)
		return item.id..":"..item.nslots
	end)
end

handlers["^Misc%.Container%.ItemsInType"] = function (set, data)
	local newset = {}
	local container = set:match("%.([^%.]+)$")
	local container_id = Containers_ItemsInType_items[container]
	if not container_id then return end
	return basic_listview_handler(WH("item", container_id), nil, "can-contain")
end

handlers["^Misc%.Openable"] = function (set, data)
	local newset = {}
	multiple_qualities_listview_handler("items", nil, {cr=11,crs=1,crv=0}, newset, "le")
	-- Add the clams that are not in the query
	basic_listview_handler(WH("items", nil, {na="clam", cr=107, crs=0, crv="Open"}), nil, nil, newset)
	table.sort(newset, sortSet)
	return table.concat(newset, ",")
end

handlers["^Misc%.Key"] = function (set, data)
	local setname = set:match("%.([^%.]+)$")
	return basic_listview_handler(WH("items", 13), nil, nil, newset)
end

handlers["^Misc%.Lockboxes"] = function (set, data)
	return basic_listview_handler(WH("items", nil, {cr=10,crs=1,crv=0}), function (item)
		page = getpage(WH("item", item.id).."&xml") -- hack
		local skill = page:match("Requires Lockpicking %((%d+)%)")
		if skill then
			return item.id..":"..skill
		else
			print("Misc Lockboxes error for item "..item.id)
		end
	end)
end

handlers["^Misc%.Minipet%.Normal"] = function (set, data)
	return basic_listview_handler(WH("items", "15.2"))
end

handlers["^Misc%.Reagent%.Ammo"] = function (set, data)
	local newset
	local setname = set:match("%.([^%.]+)$")
	local count = 0
	local filter = Reagent_Ammo_categories[setname]
	if not filter then return end
	newset = basic_listview_handler(WH("items", filter), function (item)
		count = count + 1
		return item.id..":"..math.floor(item.dps * 10)
	end)
	dprint(2, "Reagent.Ammo."..setname..":"..count)
	return newset
end

handlers["^Misc%.Usable%.StartsQuest$"] = function (set, data)
	local newset = {}
	multiple_qualities_listview_handler("items", nil, {cr=6,crs=1,crv=0}, newset, "rl")
	table.sort(newset, sortSet)
	return table.concat(newset, ",")
end

handlers["^Tradeskill%.Crafted"] = function (set, data)
	local profession = set:match("^Tradeskill%.Crafted%.(.+)$")
	dprint(9, "profession", profession)
	local cat = Tradeskill_Profession_categories[profession]
	if not cat then return end

	local newset, fp_set, rp_set, lp_set, level_set = {}, {}, {}, {}, {}

	local reagenttable = {}
	basic_listview_handler(WH("spells", cat, Tradeskill_Profession_filters[profession]), function (item)
		local spellid = item.id
		if not item.reagents then return end
		-- local colorstring = itemstring:match("colors:(%b[])")
		local skilllvl = math.min(MAX_TRADESKILL_LEVEL, tonumber(item.learnedat) or MAX_TRADESKILL_LEVEL)
		local itemid = item.creates and item.creates[1] or (-1 * spellid) -- count ?
		dprint(3, profession, itemid, skilllvl)
		if itemid and skilllvl > 0 then
			newset[#newset + 1] = itemid..":"..item.learnedat
			local newrecipemats = itemid..":"
			for _, reagent in ipairs(item.reagents) do
				local reagentid, reagentnum = unpack(reagent)
				if reagenttable[reagentid] then
					reagenttable[reagentid] = reagenttable[reagentid]..";"..itemid.."x"..reagentnum
				else
					reagenttable[reagentid] = itemid.."x"..reagentnum
				end
				newrecipemats = newrecipemats..reagentid.."x"..reagentnum..";"
			end
			newrecipemats = newrecipemats:sub(1,-2)
			local levels = {}
			for k,v in ipairs(item.colors) do
				levels[k] = v == 0 and "-" or tostring(v)
			end
			fp_set[#fp_set + 1] = newrecipemats
			lp_set[#lp_set + 1] = "-"..spellid..":"..itemid
			level_set[#level_set + 1] = itemid..":"..table.concat(levels, "/")
		end
	end)
	for k,v in pairs(reagenttable) do
		rp_set[#rp_set + 1] = k..":"..v
	end

	table.sort(fp_set, sortSet_id)
	fp_set = table.concat(fp_set, ",")
	printdiff("TradeskillResultMats.Forward."..profession, sets["TradeskillResultMats.Forward."..profession], fp_set)
	sets["TradeskillResultMats.Forward."..profession] = fp_set
	table.sort(rp_set, sortSet_id)
	rp_set = table.concat(rp_set, ",")
	printdiff("TradeskillResultMats.Reverse."..profession, sets["TradeskillResultMats.Reverse."..profession], rp_set)
	sets["TradeskillResultMats.Reverse."..profession] = rp_set
	table.sort(lp_set, sortSet)
	lp_set = table.concat(lp_set, ",")
	printdiff("Tradeskill.RecipeLinks."..profession, sets["Tradeskill.RecipeLinks."..profession], lp_set)
	sets["Tradeskill.RecipeLinks."..profession] = lp_set
	table.sort(level_set, sortSet_id)
	level_set = table.concat(level_set, ",")
	printdiff("TradeskillLevels."..profession, sets["TradeskillLevels."..profession], level_set)
	sets["TradeskillLevels."..profession] = level_set

	table.sort(newset, sortSet)
	return table.concat(newset, ",")
end

handlers["^Tradeskill%.Gather"] = function (set, data)
	local count = 0
	if set:match("^Tradeskill%.Gather%.GemsInNodes") then
		local nodetype = set:match("%.([^%.]+)$")
		local id = Tradeskill_Gather_GemsInNodes_nodes[nodetype]
		if not id then return end
		return basic_listview_handler(WH("object", id), function(item)
			if item.classs == "3" then return item.id end
		end)
	else
		local gathertype = set:match("%.([^%.]+)$")
		local filter = Tradeskill_Gather_filter_values[gathertype]
		return filter and basic_listview_handler(WH("items", nil, {cr=filter, crs=1, crv=0}))
	end
end

handlers["^Tradeskill%.Gem"] = function (set, data)
	local color = set:match("%.([^%.]+)$")
	if color == "Cut" then
		local newset = {}
		local gems = {}
		local gem_cut_func = function (item)
			local itemid = item.id
			basic_listview_handler(WH("item", itemid), function (item)
				for _, reagent in ipairs(item.reagents) do
					local src_id, count = unpack(reagent)
					if src_id ~= 27860 then -- Purified Draenic Water
						if not gems[src_id] then gems[src_id] = {} end
						gems[src_id][#(gems[src_id]) + 1] = itemid
					end
				end
			end, 'created-by')
		end
		local filter = {cr=81,crs=5,crv=0}
		for _, entry in ipairs(Tradeskill_Gem_Cut_level_filters) do
			filter.minle = entry.minle
			filter.maxle = entry.maxle
			filter.qu = entry.qu
			basic_listview_handler(WH("items", nil, filter), gem_cut_func)
		end
		for k, v in pairs(gems) do
			table.sort(v)
			newset[#newset + 1] = k..":"..table.concat(v, ";")
		end
		table.sort(newset, sortSet_id)
		return table.concat(newset, ",")
	else
		local filter = Tradeskill_Gem_Color_categories[color]
		return filter and basic_listview_handler(WH("items", filter))
	end
end

handlers["^Tradeskill%.Mat%.ByProfession"] = function (set, data)
	local profession = set:match("^Tradeskill%.Mat%.ByProfession%.(.+)$")
	local cat = Tradeskill_Profession_categories[profession]
	if not cat then return end
	local reagentlist = {}

	basic_listview_handler(WH("spells", cat, Tradeskill_Profession_filters[profession]), function (item)
		if not item.reagents then return end
		for _, r in ipairs(item.reagents) do
			reagentlist[r[1]] = true
		end
	end)
	local newset = {}
	for reagent in pairs(reagentlist) do
		newset[#newset + 1] = reagent
	end
	table.sort(newset)
	return table.concat(newset, ",")
end

handlers["^Tradeskill%.Recipe%."] = function (set, data)
	local count = 0
	local profession, src = set:match("^Tradeskill%.Recipe%.([^%.]+)%.(.+)$")
	profession = Tradeskill_Recipe_categories[profession]
	filter = Tradeskill_Recipe_filters[filter]
	if not profession or not filter then return end

	return basic_listview_handler(WH("items", profession, filter),
		function (item) return item.id..":"..item.skill end)
end

handlers["^Tradeskill%.Tool"] = function (set, data)
	local newset = {}
	local count = 0
	local profession = set:match("^Tradeskill%.Tool%.(.+)$")
	local filters = Tradeskill_Tool_filters[profession]
	if not filters then return end

	for _, filter in ipairs(filters) do
		basic_listview_handler(WH("items", nil, filter), nil, nil, newset)
	end

	table.sort(newset, sortSet)
	return table.concat(newset, ",")
end

-- Adds items not mineable / easily mineable to the end of a set
-- For instance rank 1 talents to ClassSpell
local additionalSetItems = {
	["ClassSpell.Death Knight.Blood"] = ",-48982:20,-49005:30,-49016:40,-55233:45,-55050:50,-49028:60",
	["ClassSpell.Death Knight.Frost"] = ",-49039:20,-49796:30,-49203:40,-51271:45,-49143:50,-49184:60",
	["ClassSpell.Death Knight.Unholy"] = ",-49158:20,-51052:40,-63560:40,-49222:45,-55090:50,-49206:60",
	["ClassSpell.Druid.Balance"] = ",-5570:30,-33831:50,-50516:50,-48505:60",
	["ClassSpell.Druid.Feral Combat"] = ",-49377:30,-33878:50,-33876:50,-50334:60",
	["ClassSpell.Druid.Restoration"] = ",-17116:30,-18562:40,-48438:60",
	["ClassSpell.Mage.Frost"] = ",-12472:20,-11958:30,-11426:40,-31687:50,-44572:60",
	["ClassSpell.Paladin.Protection"] = ",-64205:20",
	["ClassSpell.Rogue.Combat"] = ",-51690:60",
}

local function update_all_sets(sets, setcount)
	local setid = 0
	local failed = 0
	for set, data in pairs(sets) do
		setid = setid + 1
		local newset
		if data:sub(1,2) ~= "m," then
			dprint(1, ("current set: %4d/%4d"):format(setid, setcount), set)
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
		else
			dprint(1, ("current set: %4d/%4d"):format(setid, setcount), set, "   - skipped: multiset")
		end
		if newset then
			local add = additionalSetItems[set]
			if add then newset = newset..add end
			printdiff(set, sets[set] or "", newset)
			-- check if we mined an empty set that would overwrite existing data
			if newset == "" and sets[set] ~= newset then
				dprint(1, "WARNING: mined empty data for non-empty set. skipping set", set)
			else
				sets[set] = newset
			end
		else
			failed = failed + 1
		end
	end
	return failed
end

local function write_output(file, sets)
	local f = assert(io.open(SOURCE, "w"))
	for line in file:gmatch('([^\n]-\n)') do
		local setname, spaces, comment = line:match('\t%[%"([^"]+)%"%]([^=]-)= "[^"]-",([^\n]-)\n')
		if setname and sets[setname] then
			f:write('\t["',setname,'"]',spaces,'= "',sets[setname],'",',comment,'\n')
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
	print(("%d sets in datafile"):format(setcount))
	local notmined = update_all_sets(sets, setcount)
	local elapsed = os.time()- starttime
	local cputime = os.clock()
	print(("Elapsed Time: %dm %ds"):format(elapsed/60, elapsed%60))
	print(("%dm %ds spent servicing %d web requests"):format(httptime/60, httptime%60, httpcount))
	print(("%dm %ds spent in processing data"):format((elapsed-httptime)/60,(elapsed-httptime)%60))
	print(("Approx %dm %.2fs CPU time used"):format(cputime/60, cputime%60))
	print(("%d sets mined, %d sets not mined."):format(setcount - notmined, notmined))
	write_output(file, sets)
end

main()
