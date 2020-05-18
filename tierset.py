
import re
import random
import urllib.request
import time
import json
from collections import defaultdict

class_ids = {"Death Knight" : 6, "Druid" : 11, "Hunter" : 3, "Mage" : 8, "Monk" : 10, "Paladin" : 2, "Priest" : 5, "Rogue" : 4, "Shaman" : 7, "Warlock" : 9, "Warrior" : 1}
classictierlisttoid = {
    "1" : 3,
    "2" : 4,
    "3" : 5
}
retailtierlisttoid = {
    "1" : 3,
    "2" : 4,
    "3" : 5,
    "4" : 12,
    "5" : 13,
    "6" : 18,
    "7" : 23,
    "8" : 25,
    "9" : 27,
    "10" : 29,
    "11" : 31,
    "12" : 35,
    "13" : 38,
    "14" : 39,
    "15" : 43,
    "16" : 64,
    "17" : 65,
    "18" : 71,
    "19" : 78,
    "20" : 82,
    "21" : 86
}
#set_id = 3  #Tier 1
#set_id = 4  #Tier 2
#set_id = 5  #Tier 3
#set_id = 12 #Tier 4
#set_id = 13 #Tier 5
#set_id = 18 #Tier 6
#set_id = 23 #Tier 7
#set_id = 25 #Tier 8
#set_id = 27 #Tier 9
#set_id = 29 #Tier 10
#set_id = 31 #Tier 11
#set_id = 35 #Tier 12
#set_id = 38 #Tier 13
#set_id = 39 #Tier 14
#set_id = 43 #Tier 15
#set_id = 64 #Tier 16
#set_id = 65 #tier 17
#set_id = 71 #tier 18
#set_id = 78 #tier 19
#set_id = 82 #tier 20
#set_id = 86 #tier 21

def get_data(p_class_id, p_set_id, classic):
    opener = urllib.request.build_opener()
    opener.addheaders = [('User-agent', 'Mozilla/5.0')]
    urllib.request.install_opener(opener)
    if classic:
        item_url = "http://classic.wowhead.com/item-sets?filter=cl={0};ta={1}&xml".format(p_class_id, p_set_id)
    else:
        item_url = "http://wowhead.com/item-sets?filter=cl={0};ta={1}&xml".format(p_class_id, p_set_id)
    #print(item_url)
    usock = urllib.request.urlopen(url=item_url, timeout=30)
    data = usock.read().decode('utf-8')
    usock.close()
    
    m = re.search(r'new\s+Listview\s*\((.+?)\)', data, flags=re.DOTALL)
    try:
        listview = m.group(1)
    except AttributeError:
        print("Error: failed to find data for class id {0}".format(p_class_id))
        return
    #print "id:{1}\n {0}\n".format(listview, p_class_id)
    
    listview2 = re.search(r'data:\s*(\[.+\])', listview, flags=re.DOTALL).group(1)
    #print "*********"
    #print(listview2 + "\n")
    
    
    j_data = json.loads(listview2)
    
    #print(json.dumps(j_data, sort_keys=True, indent=3, separators=(',', ': ')))
    
    my_dict = {}
    
    for entry in j_data:
        #item = re.sub('firstseenpatch', '"firstseenpatch"', item)
        #item = re.sub('cost', '"cost"', item)
        #print item
        #print(json.dumps(entry, sort_keys=True, indent=3, separators=(',', ': ')))
        name = entry["name"]
        level = entry["maxlevel"]
        id = entry["id"]
        pieces = entry["pieces"]
        #print("Name: {0}, Level:{1}, ID:{2}, Pieces:{3}".format(name, level, id, entry["pieces"]))
        if name not in my_dict:
            my_dict[name] = {}
        my_dict[name][level] = id
    
    #print(my_dict)
    
    #print(sorted(my_dict.keys()))
    return my_dict

def process_data_lua(p_data_dict, p_tier, p_class_name, classic):
    if classic:
        f = open(LibPeriodicTable-3.1-GearSet-classic.lua, "a")
    else:
        f = open(LibPeriodicTable-3.1-GearSet.lua, "a")
    for name in p_data_dict.keys():
        for id_key in sorted(p_data_dict[name].keys()):
            line = "\t[\"GearSet.Tier {0}.{1}.{2}.{3}\"] = \"\",\n".format(p_tier, id_key, p_class_name, name)	
            f.write(line)
        f.write(line)
#["GearSet.Tier 16.566.Warrior.Plate of the Prehistoric Marauder"] = "99407,99408,99409,99410,99415",  
def createstartfile(filename):  
    f = open(filename, "a")
    line = 'if not LibStub("LibPeriodicTable-3.1", true) then error("PT3 must be loaded before data") end\n'
    f.write(line)
    line = 'LibStub("LibPeriodicTable-3.1"):AddData("GearSet", gsub("$Rev: 584 $", "(%d+)", function(n) return n+90000 end), {\n'
    f.write(line)
def createendfile(filename):  
    f = open(filename, "a")
    line = '}\n'
    f.write(line)
def generatelist(tier,setid, classic): 
    for class_key in sorted(class_ids.keys()):
        data = get_data(class_ids[class_key], setid, classic)
        
        process_data_lua(data, tier, class_key, classic)
createstartfile()
def createretaillist():
    filename = "LibPeriodicTable-3.1-GearSet.lua"
    createstartfile(filename)
    for tier, id in retailtierlisttoid:
        generatelist(tier,id)
    createendfile(filename)
def createclassiclist():
    filename = "LibPeriodicTable-3.1-GearSet-classic.lua"
    createstartfile(filename)
    for tier, id in classictierlisttoid:
        generatelist(tier,id,true)
    createendfile(filename)
createretaillist()
createclassiclist()
#print()
