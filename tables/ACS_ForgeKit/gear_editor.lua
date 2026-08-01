--[[
  ACS Forge Kit — Gear Desk (Byte Engine)

  Own editor for weapons / belts / cloaks / outfits / colors.
  Stash qty stays in inventory_editor.lua (BeWT item+0x28).

  Gear ownership is a separate owned-pointer list (forge resource hashes),
  researched from live ACS + public CT layout hints — implemented here from
  scratch to match ForgeKit style (no pasted unlocker scripts).

  Resolve (auto on open; Retry available):
    manager AOB -> rip-rel head -> writable qword hit = gearRoot (mainstruct)
    holder = double-deref at gearRoot+0xBC (unlocker: mainstruct+188)
    list   = holder+0x40
    count  = u16 at holder+0x4A
    cap    = u16 at holder+0x48
  SAFETY: refuse list/def pointers inside ACS.exe or below 4GB (false hits crash the game).

  Grant:
    find def blob "01 00 00 80" + LE resource hash (non-exec)
    node = hit - 0x0C
    append node to list if missing; grow buffer if count==cap
]]

if ACS_ForgeGear and ACS_ForgeGear.form then
  pcall(function()
    if not ACS_ForgeGear.form.Destroyed then ACS_ForgeGear.form.destroy() end
  end)
end

ACS_ForgeGear = {}
ACS_Gear = ACS_Gear or {}

-- #region agent log
local function agent_log(hid, loc, msg, data)
  local ok, payload = pcall(function()
    local parts = {
      string.format('"sessionId":"f9ebbe","runId":"gear","hypothesisId":"%s","location":"%s","message":"%s","timestamp":%d',
        tostring(hid), tostring(loc), tostring(msg):gsub('"', "'"), (os.time() or 0) * 1000)
    }
    if type(data) == "table" then
      local bits = {}
      for k, v in pairs(data) do
        local vv = v
        if type(v) == "number" then vv = string.format("%.0f", v)
        elseif type(v) == "boolean" then vv = v and "true" or "false"
        else vv = '"' .. tostring(v):gsub('"', "'") .. '"' end
        bits[#bits + 1] = string.format('"%s":%s', tostring(k), vv)
      end
      parts[#parts + 1] = ',"data":{' .. table.concat(bits, ",") .. "}"
    end
    return "{" .. table.concat(parts, "") .. "}\n"
  end)
  if not ok or not payload then return end
  for _, p in ipairs({
    [[debug-f9ebbe.log]],
    [[debug-f9ebbe.log]],
  }) do
    local f = io.open(p, "a")
    if f then f:write(payload); f:close() end
  end
end
agent_log("H1", "gear_editor.lua:load", "gear_editor_parsed_ok", {fix="post-comment-fix"})
-- #endregion

local MOD = "ACS.exe"
-- Spaced pattern required — Byte Engine ParseAob only splits on spaces (compact hex = empty scan).
local MANAGER_AOB = "45 33 F6 48 8D 05 ?? ?? ?? ?? 48 89 06 48 8D 05 ?? ?? ?? ?? 48 8D 8E 88 00 00 00"
local DEF_PREFIX = "01000080"
-- Page-mark helper used when growing the owned list (module-relative).
local PAGE_MARK_RVA = 0x7159DB8

-- Real unlockables only (UI texture Map categories are not ownership defs).
-- Live linked/other = nested def fragments from harvest; appending them grows the
-- ownership list in memory but the game does not treat them as equipable gear.
local GRANTABLE = {
  ["Kukri"] = true, ["Cane-swords"] = true, ["Knuckles"] = true, ["Gauntlets"] = true,
  ["Firearms"] = true, ["Belts Jacob"] = true, ["Capes Evie"] = true,
  ["Outfits Jacob"] = true, ["Outfits Evie"] = true, ["Colors"] = true,
  -- Live harvest IDs stay in catalog for research but are NOT grantable —
  -- appending them inflated +0x150 without showing as equipable gear.
}

-- Catalog: resource hashes cross-checked against forge UI + research notes.
-- Generated into this table by _build_gear_desk.py — edit that, not by hand.
local CATALOG = {
  {cat="Kukri", name="Ruby", hash_le="FB065D4941000000", id="0x00000041495D06FB"},
  {cat="Kukri", name="Bold Eagle", hash_le="FA065D4941000000", id="0x00000041495D06FA"},
  {cat="Kukri", name="Jade", hash_le="4E1F93F839000000", id="0x00000039F8931F4E"},
  {cat="Kukri", name="Master Ruby", hash_le="A581533C43000000", id="0x000000433C5381A5"},
  {cat="Kukri", name="Gold Blessing", hash_le="A181533C43000000", id="0x000000433C5381A1"},
  {cat="Kukri", name="Master Assassin", hash_le="9981533C43000000", id="0x000000433C538199"},
  {cat="Kukri", name="Serrated Death", hash_le="5B075D4941000000", id="0x00000041495D075B"},
  {cat="Kukri", name="Legendary Assassin", hash_le="5A075D4941000000", id="0x00000041495D075A"},
  {cat="Kukri", name="Ceremonial Kukri (Promo)", hash_le="8D81533C43000000", id="0x000000433C53818D"},
  {cat="Kukri", name="Golden (Promo)", hash_le="8981533C43000000", id="0x000000433C538189"},
  {cat="Kukri", name="Ram's (Promo)", hash_le="8581533C43000000", id="0x000000433C538185"},
  {cat="Cane-swords", name="Adept", hash_le="29085D4941000000", id="0x00000041495D0829"},
  {cat="Cane-swords", name="Mayan", hash_le="1282533C43000000", id="0x000000433C538212"},
  {cat="Cane-swords", name="Goddess", hash_le="28085D4941000000", id="0x00000041495D0828"},
  {cat="Cane-swords", name="Sir Lemay", hash_le="27085D4941000000", id="0x00000041495D0827"},
  {cat="Cane-swords", name="Charles Dickens", hash_le="0E82533C43000000", id="0x000000433C53820E"},
  {cat="Cane-swords", name="Golden Lion", hash_le="26085D4941000000", id="0x00000041495D0826"},
  {cat="Cane-swords", name="Lord Pearson", hash_le="0A82533C43000000", id="0x000000433C53820A"},
  {cat="Cane-swords", name="Jade Dragon", hash_le="25085D4941000000", id="0x00000041495D0825"},
  {cat="Cane-swords", name="Runic Mayan", hash_le="0682533C43000000", id="0x000000433C538206"},
  {cat="Cane-swords", name="Light and dark", hash_le="FE81533C43000000", id="0x000000433C5381FE"},
  {cat="Cane-swords", name="Flame Dragon", hash_le="2982533C43000000", id="0x000000433C538229"},
  {cat="Cane-swords", name="World's greatest", hash_le="F681533C43000000", id="0x000000433C5381F6"},
  {cat="Cane-swords", name="Arbaaz Mir (Uplay)", hash_le="EE81533C43000000", id="0x000000433C5381EE"},
  {cat="Cane-swords", name="Ocean (Promo)", hash_le="F281533C43000000", id="0x000000433C5381F2"},
  {cat="Cane-swords", name="Dove (Dreadful Crimes DLC)", hash_le="2D82533C43000000", id="0x000000433C53822D"},
  {cat="Knuckles", name="Crows Strength", hash_le="08095D4941000000", id="0x00000041495D0908"},
  {cat="Knuckles", name="Steel", hash_le="07095D4941000000", id="0x00000041495D0907"},
  {cat="Knuckles", name="Darbe's Bear Paw", hash_le="C382533C43000000", id="0x000000433C5382C3"},
  {cat="Knuckles", name="Lord Jonathan's Retribution", hash_le="B782533C43000000", id="0x000000433C5382B7"},
  {cat="Knuckles", name="Jaw Tenderizer", hash_le="04095D4941000000", id="0x00000041495D0904"},
  {cat="Knuckles", name="Death", hash_le="BB82533C43000000", id="0x000000433C5382BB"},
  {cat="Knuckles", name="Copper Love", hash_le="03095D4941000000", id="0x00000041495D0903"},
  {cat="Knuckles", name="Eagle's Splendor", hash_le="BF82533C43000000", id="0x000000433C5382BF"},
  {cat="Knuckles", name="Dirty (Promo)", hash_le="AB82533C43000000", id="0x000000433C5382AB"},
  {cat="Knuckles", name="Angel (Promo)", hash_le="AF82533C43000000", id="0x000000433C5382AF"},
  {cat="Knuckles", name="Pirate (Promo)", hash_le="A382533C43000000", id="0x000000433C5382A3"},
  {cat="Knuckles", name="Engraved (Dreadful Crimes DLC)", hash_le="05095D4941000000", id="0x00000041495D0905"},
  {cat="Gauntlets", name="Reinforced", hash_le="BBD879103F000000", id="0x0000003F1079D8BB"},
  {cat="Gauntlets", name="Black Leather", hash_le="BAD879103F000000", id="0x0000003F1079D8BA"},
  {cat="Gauntlets", name="Mirage", hash_le="B9D879103F000000", id="0x0000003F1079D8B9"},
  {cat="Gauntlets", name="Iron Death", hash_le="421F93F839000000", id="0x00000039F8931F42"},
  {cat="Gauntlets", name="Assassin", hash_le="431F93F839000000", id="0x00000039F8931F43"},
  {cat="Gauntlets", name="Devil's Handshake", hash_le="C0D879103F000000", id="0x0000003F1079D8C0"},
  {cat="Gauntlets", name="Chimera", hash_le="BED879103F000000", id="0x0000003F1079D8BE"},
  {cat="Gauntlets", name="Legendary Assassin", hash_le="D9F3EAAA1D000000", id="0x0000001DAAEAF3D9"},
  {cat="Gauntlets", name="Redback (Uplay)", hash_le="099A533C43000000", id="0x000000433C539A09"},
  {cat="Gauntlets", name="Industrial (Uplay)", hash_le="019A533C43000000", id="0x000000433C539A01"},
  {cat="Gauntlets", name="Royal (Uplay)", hash_le="059A533C43000000", id="0x000000433C539A05"},
  {cat="Firearms", name="Model 1", hash_le="918ADC4342000000", id="0x0000004243DC8A91"},
  {cat="Firearms", name="(54 Bore) 1856 Revolver", hash_le="858ADC4342000000", id="0x0000004243DC8A85"},
  {cat="Firearms", name="Lancaster 4-Barrels", hash_le="898ADC4342000000", id="0x0000004243DC8A89"},
  {cat="Firearms", name=".38 Double Action", hash_le="422293F839000000", id="0x00000039F8932242"},
  {cat="Firearms", name="M1877 Lightning", hash_le="3E2293F839000000", id="0x00000039F893223E"},
  {cat="Firearms", name="M1877 Thunderer", hash_le="8D8ADC4342000000", id="0x0000004243DC8A8D"},
  {cat="Firearms", name="Model 3", hash_le="9D8ADC4342000000", id="0x0000004243DC8A9D"},
  {cat="Firearms", name="Self-Loading Pistol Model 1868", hash_le="958ADC4342000000", id="0x0000004243DC8A95"},
  {cat="Firearms", name="The Mars", hash_le="998ADC4342000000", id="0x0000004243DC8A99"},
  {cat="Firearms", name="Bullseye Revolver (Uplay)", hash_le="1AA555625D000000", id="0x0000005D6255A51A"},
  {cat="Firearms", name="Demonic Revolver (Uplay)", hash_le="12A555625D000000", id="0x0000005D6255A512"},
  {cat="Firearms", name="Stealth Revolver (Uplay)", hash_le="16A555625D000000", id="0x0000005D6255A516"},
  {cat="Belts Jacob", name="Rough and Tumble", hash_le="1B8F821643000000", id="0x0000004316828F1B"},
  {cat="Belts Jacob", name="Dark Leather", hash_le="238F821643000000", id="0x0000004316828F23"},
  {cat="Belts Jacob", name="Thief", hash_le="1A8F821643000000", id="0x0000004316828F1A"},
  {cat="Belts Jacob", name="Crossroad", hash_le="258F821643000000", id="0x0000004316828F25"},
  {cat="Belts Jacob", name="Metal Web", hash_le="2C8F821643000000", id="0x0000004316828F2C"},
  {cat="Belts Jacob", name="Reaper", hash_le="1F8F821643000000", id="0x0000004316828F1F"},
  {cat="Belts Jacob", name="Eagle Splendor", hash_le="288F821643000000", id="0x0000004316828F28"},
  {cat="Belts Jacob", name="Iron Scale", hash_le="298F821643000000", id="0x0000004316828F29"},
  {cat="Belts Jacob", name="Black Death", hash_le="278F821643000000", id="0x0000004316828F27"},
  {cat="Belts Jacob", name="Eagle Dive", hash_le="208F821643000000", id="0x0000004316828F20"},
  {cat="Belts Jacob", name="Spring-Heeled Jack", hash_le="218F821643000000", id="0x0000004316828F21"},
  {cat="Belts Jacob", name="Master Assassin's", hash_le="2A8F821643000000", id="0x0000004316828F2A"},
  {cat="Belts Jacob", name="Beer Collector", hash_le="2B8F821643000000", id="0x0000004316828F2B"},
  {cat="Belts Jacob", name="Legendary Assassin", hash_le="228F821643000000", id="0x0000004316828F22"},
  {cat="Belts Jacob", name="Iron (Uplay)", hash_le="7A8F821643000000", id="0x0000004316828F7A"},
  {cat="Belts Jacob", name="Suave (Uplay)", hash_le="7B8F821643000000", id="0x0000004316828F7B"},
  {cat="Belts Jacob", name="Noble Assassin (Uplay)", hash_le="798F821643000000", id="0x0000004316828F79"},
  {cat="Capes Evie", name="Hunter's Mantle", hash_le="7D90821643000000", id="0x000000431682907D"},
  {cat="Capes Evie", name="Killer's Lace", hash_le="6A90821643000000", id="0x000000431682906A"},
  {cat="Capes Evie", name="Crimson Wing", hash_le="6990821643000000", id="0x0000004316829069"},
  {cat="Capes Evie", name="Patchwork", hash_le="7C90821643000000", id="0x000000431682907C"},
  {cat="Capes Evie", name="Eagle Dive", hash_le="7490821643000000", id="0x0000004316829074"},
  {cat="Capes Evie", name="Light and Dark", hash_le="7190821643000000", id="0x0000004316829071"},
  {cat="Capes Evie", name="Goldred Cloak", hash_le="7990821643000000", id="0x0000004316829079"},
  {cat="Capes Evie", name="Emerald Isle Cape", hash_le="6F90821643000000", id="0x000000431682906F"},
  {cat="Capes Evie", name="Lady Cyrielle's Shawl", hash_le="7890821643000000", id="0x0000004316829078"},
  {cat="Capes Evie", name="Cloak of Victory", hash_le="6E90821643000000", id="0x000000431682906E"},
  {cat="Capes Evie", name="Royal Cloak", hash_le="7690821643000000", id="0x0000004316829076"},
  {cat="Capes Evie", name="Aegis Cloak", hash_le="6D90821643000000", id="0x000000431682906D"},
  {cat="Capes Evie", name="Out of the blue (Promo)", hash_le="6B90821643000000", id="0x000000431682906B"},
  {cat="Capes Evie", name="Country Cloak (Dreadful Crimes DLC)", hash_le="7290821643000000", id="0x0000004316829072"},
  {cat="Outfits Jacob", name="Gunslinger Coat", hash_le="67864A3041000000", id="0x00000041304A8667"},
  {cat="Outfits Jacob", name="Outdoorsman Outfit", hash_le="66864A3041000000", id="0x00000041304A8666"},
  {cat="Outfits Jacob", name="Master Assassin", hash_le="65864A3041000000", id="0x00000041304A8665"},
  {cat="Outfits Jacob", name="Blackguard Suit", hash_le="64864A3041000000", id="0x00000041304A8664"},
  {cat="Outfits Jacob", name="Maximum Dracula", hash_le="63864A3041000000", id="0x00000041304A8663"},
  {cat="Outfits Jacob", name="Baron Jordane's Finery", hash_le="62864A3041000000", id="0x00000041304A8662"},
  {cat="Outfits Jacob", name="Ezio (Uplay)", hash_le="61864A3041000000", id="0x00000041304A8661"},
  {cat="Outfits Jacob", name="Edward (Uplay)", hash_le="BA864A3041000000", id="0x00000041304A86BA"},
  {cat="Outfits Jacob", name="Huntsman's (Uplay)", hash_le="C2864A3041000000", id="0x00000041304A86C2"},
  {cat="Outfits Jacob", name="Suave (Promo)", hash_le="C1864A3041000000", id="0x00000041304A86C1"},
  {cat="Outfits Evie", name="Nightshade Cloak", hash_le="BB864A3041000000", id="0x00000041304A86BB"},
  {cat="Outfits Evie", name="Military Suit", hash_le="C0864A3041000000", id="0x00000041304A86C0"},
  {cat="Outfits Evie", name="Defender's Garb", hash_le="BF864A3041000000", id="0x00000041304A86BF"},
  {cat="Outfits Evie", name="Lady Melyne's Gown", hash_le="BD864A3041000000", id="0x00000041304A86BD"},
  {cat="Outfits Evie", name="Master Assassin", hash_le="BC864A3041000000", id="0x00000041304A86BC"},
  {cat="Outfits Evie", name="The Aegis", hash_le="BE864A3041000000", id="0x00000041304A86BE"},
  {cat="Outfits Evie", name="Elise (Uplay)", hash_le="1E1F93F839000000", id="0x00000039F8931F1E"},
  {cat="Outfits Evie", name="Aveline (Uplay)", hash_le="1F1F93F839000000", id="0x00000039F8931F1F"},
  {cat="Outfits Evie", name="Shao Jun (Uplay)", hash_le="201F93F839000000", id="0x00000039F8931F20"},
  {cat="Outfits Evie", name="Nighthawk Outfit (Promo)", hash_le="221F93F839000000", id="0x00000039F8931F22"},
  {cat="Colors", name="Violet", hash_le="12A4EC9323000000", id="0x0000002393ECA412"},
  {cat="Colors", name="Fuchsia", hash_le="A0A5EC9323000000", id="0x0000002393ECA5A0"},
  {cat="Colors", name="Midnight Blue", hash_le="9CA5EC9323000000", id="0x0000002393ECA59C"},
  {cat="Colors", name="Black", hash_le="98A5EC9323000000", id="0x0000002393ECA598"},
  {cat="Colors", name="Steel Gray", hash_le="94A5EC9323000000", id="0x0000002393ECA594"},
  {cat="Colors", name="Crimson", hash_le="90A5EC9323000000", id="0x0000002393ECA590"},
  {cat="Colors", name="Wine", hash_le="58A5EC9323000000", id="0x0000002393ECA558"},
  {cat="Colors", name="Green", hash_le="A4A5EC9323000000", id="0x0000002393ECA5A4"},
  {cat="Colors", name="Ubisoft Blue (Uplay)", hash_le="54A5EC9323000000", id="0x0000002393ECA554"},
  {cat="Colors", name="Teal (Uplay)", hash_le="5CA5EC9323000000", id="0x0000002393ECA55C"},
  -- Live-harvested runtime IDs (nested 01000080 defs / mainstruct walk)
  {cat="Live linked", name="Linked FFEAEF00", hash_le="00EFEAFF45000000", id="0x00000045FFEAEF00"},
  {cat="Live linked", name="Linked FFEAEF01", hash_le="01EFEAFF45000000", id="0x00000045FFEAEF01"},
  {cat="Knuckles", name="Live 495D0902", hash_le="02095D4941000000", id="0x00000041495D0902"},
  {cat="Cane-swords", name="Live 3C538202", hash_le="0282533C43000000", id="0x000000433C538202"},
  {cat="Live linked", name="Linked FFEAEF02", hash_le="02EFEAFF45000000", id="0x00000045FFEAEF02"},
  {cat="Live linked", name="Linked FFEAEF03", hash_le="03EFEAFF45000000", id="0x00000045FFEAEF03"},
  {cat="Live linked", name="Linked FFEAEF04", hash_le="04EFEAFF45000000", id="0x00000045FFEAEF04"},
  {cat="Live linked", name="Linked FFEAEF05", hash_le="05EFEAFF45000000", id="0x00000045FFEAEF05"},
  {cat="Knuckles", name="Live 495D0906", hash_le="06095D4941000000", id="0x00000041495D0906"},
  {cat="Live linked", name="Linked FFEAEF06", hash_le="06EFEAFF45000000", id="0x00000045FFEAEF06"},
  {cat="Live linked", name="Linked FFEAEF07", hash_le="07EFEAFF45000000", id="0x00000045FFEAEF07"},
  {cat="Live linked", name="Linked FFEAEF08", hash_le="08EFEAFF45000000", id="0x00000045FFEAEF08"},
  {cat="Knuckles", name="Live 495D0909", hash_le="09095D4941000000", id="0x00000041495D0909"},
  {cat="Live other", name="Fam2E 39C74A09", hash_le="094AC7392E000000", id="0x0000002E39C74A09"},
  {cat="Live linked", name="Linked FFEAEF09", hash_le="09EFEAFF45000000", id="0x00000045FFEAEF09"},
  {cat="Knuckles", name="Live 495D090A", hash_le="0A095D4941000000", id="0x00000041495D090A"},
  {cat="Live other", name="Fam58 D53AE50B", hash_le="0BE53AD558000000", id="0x00000058D53AE50B"},
  {cat="Live other", name="Fam2E 39C74A0D", hash_le="0D4AC7392E000000", id="0x0000002E39C74A0D"},
  {cat="Live other", name="Fam58 D53AE50F", hash_le="0FE53AD558000000", id="0x00000058D53AE50F"},
  {cat="Live linked", name="Linked FFEAEE0F", hash_le="0FEEEAFF45000000", id="0x00000045FFEAEE0F"},
  {cat="Live other", name="Fam2E 39C74A11", hash_le="114AC7392E000000", id="0x0000002E39C74A11"},
  {cat="Live other", name="Fam15 62860713", hash_le="1307866215000000", id="0x0000001562860713"},
  {cat="Live other", name="Fam58 D53AE513", hash_le="13E53AD558000000", id="0x00000058D53AE513"},
  {cat="Live linked", name="Linked FFEAEE13", hash_le="13EEEAFF45000000", id="0x00000045FFEAEE13"},
  {cat="Live linked", name="Linked FFEAEE17", hash_le="17EEEAFF45000000", id="0x00000045FFEAEE17"},
  {cat="Live gear-43", name="Live 6BD7E91A", hash_le="1AE9D76B43000000", id="0x000000436BD7E91A"},
  {cat="Belts Jacob", name="Live 16828F1C", hash_le="1C8F821643000000", id="0x0000004316828F1C"},
  {cat="Belts Jacob", name="Live 16828F1D", hash_le="1D8F821643000000", id="0x0000004316828F1D"},
  {cat="Live other", name="Fam44 9533491E", hash_le="1E49339544000000", id="0x000000449533491E"},
  {cat="Firearms", name="Live 43DC8A1E", hash_le="1E8ADC4342000000", id="0x0000004243DC8A1E"},
  {cat="Belts Jacob", name="Live 16828F1E", hash_le="1E8F821643000000", id="0x0000004316828F1E"},
  {cat="Cane-swords", name="Live 495D0824", hash_le="24085D4941000000", id="0x00000041495D0824"},
  {cat="Belts Jacob", name="Live 16828F24", hash_le="248F821643000000", id="0x0000004316828F24"},
  {cat="Belts Jacob", name="Live 16828F26", hash_le="268F821643000000", id="0x0000004316828F26"},
  {cat="Cane-swords", name="Live 495D082A", hash_le="2A085D4941000000", id="0x00000041495D082A"},
  {cat="Cane-swords", name="Live 495D082B", hash_le="2B085D4941000000", id="0x00000041495D082B"},
  {cat="Live linked", name="Linked 3C72362C", hash_le="2C36723C45000000", id="0x000000453C72362C"},
  {cat="Live linked", name="Linked 3C72362D", hash_le="2D36723C45000000", id="0x000000453C72362D"},
  {cat="Live linked", name="Linked 3C72362E", hash_le="2E36723C45000000", id="0x000000453C72362E"},
  {cat="Live linked", name="Linked 3C72362F", hash_le="2F36723C45000000", id="0x000000453C72362F"},
  {cat="Live linked", name="Linked FFEAEE2F", hash_le="2FEEEAFF45000000", id="0x00000045FFEAEE2F"},
  {cat="Live linked", name="Linked 3C723630", hash_le="3036723C45000000", id="0x000000453C723630"},
  {cat="Live other", name="Fam49 96FDE330", hash_le="30E3FD9649000000", id="0x0000004996FDE330"},
  {cat="Live linked", name="Linked 3C723631", hash_le="3136723C45000000", id="0x000000453C723631"},
  {cat="Live linked", name="Linked 3C723632", hash_le="3236723C45000000", id="0x000000453C723632"},
  {cat="Live linked", name="Linked 3C723633", hash_le="3336723C45000000", id="0x000000453C723633"},
  {cat="Live linked", name="Linked FFEAEE33", hash_le="33EEEAFF45000000", id="0x00000045FFEAEE33"},
  {cat="Live linked", name="Linked 3C723634", hash_le="3436723C45000000", id="0x000000453C723634"},
  {cat="Live other", name="Fam47 41C94634", hash_le="3446C94147000000", id="0x0000004741C94634"},
  {cat="Live other", name="Fam3D DD871936", hash_le="361987DD3D000000", id="0x0000003DDD871936"},
  {cat="Live linked", name="Linked FFEAEE37", hash_le="37EEEAFF45000000", id="0x00000045FFEAEE37"},
  {cat="Outfits Live", name="Live F8931F3E", hash_le="3E1F93F839000000", id="0x00000039F8931F3E"},
  {cat="Outfits Live", name="Live F8931F44", hash_le="441F93F839000000", id="0x00000039F8931F44"},
  {cat="Live other", name="Fam1D AAEAFD45", hash_le="45FDEAAA1D000000", id="0x0000001DAAEAFD45"},
  {cat="Live other", name="Fam1D AAEAFD46", hash_le="46FDEAAA1D000000", id="0x0000001DAAEAFD46"},
  {cat="Firearms", name="Live 43DC8A48", hash_le="488ADC4342000000", id="0x0000004243DC8A48"},
  {cat="Live other", name="Fam1D AAEAFD48", hash_le="48FDEAAA1D000000", id="0x0000001DAAEAFD48"},
  {cat="Live other", name="Fam1D AAEAFD49", hash_le="49FDEAAA1D000000", id="0x0000001DAAEAFD49"},
  {cat="Live other", name="Fam39 F8931E4E", hash_le="4E1E93F839000000", id="0x00000039F8931E4E"},
  {cat="Live other", name="Fam47 08AD3E54", hash_le="543EAD0847000000", id="0x0000004708AD3E54"},
  {cat="Live other", name="Fam47 08AD3E56", hash_le="563EAD0847000000", id="0x0000004708AD3E56"},
  {cat="Kukri", name="Live 495D075C", hash_le="5C075D4941000000", id="0x00000041495D075C"},
  {cat="Live linked", name="Linked FFEAFE61", hash_le="61FEEAFF45000000", id="0x00000045FFEAFE61"},
  {cat="Live linked", name="Linked FFEAFE63", hash_le="63FEEAFF45000000", id="0x00000045FFEAFE63"},
  {cat="Live linked", name="Linked FFEAFE64", hash_le="64FEEAFF45000000", id="0x00000045FFEAFE64"},
  {cat="Live linked", name="Linked FFEAFE65", hash_le="65FEEAFF45000000", id="0x00000045FFEAFE65"},
  {cat="Live linked", name="Linked FFEAFE66", hash_le="66FEEAFF45000000", id="0x00000045FFEAFE66"},
  {cat="Live linked", name="Linked FFEAFE67", hash_le="67FEEAFF45000000", id="0x00000045FFEAFE67"},
  {cat="Live linked", name="Linked FFEAFE68", hash_le="68FEEAFF45000000", id="0x00000045FFEAFE68"},
  {cat="Live linked", name="Linked FFEAFE69", hash_le="69FEEAFF45000000", id="0x00000045FFEAFE69"},
  {cat="Live linked", name="Linked FFEAFE6A", hash_le="6AFEEAFF45000000", id="0x00000045FFEAFE6A"},
  {cat="Live other", name="Fam47 41C9456C", hash_le="6C45C94147000000", id="0x0000004741C9456C"},
  {cat="Capes Evie", name="Live 1682906C", hash_le="6C90821643000000", id="0x000000431682906C"},
  {cat="Live other", name="Fam47 41C94570", hash_le="7045C94147000000", id="0x0000004741C94570"},
  {cat="Capes Evie", name="Live 16829070", hash_le="7090821643000000", id="0x0000004316829070"},
  {cat="Capes Evie", name="Live 16829073", hash_le="7390821643000000", id="0x0000004316829073"},
  {cat="Live other", name="Fam47 41C94574", hash_le="7445C94147000000", id="0x0000004741C94574"},
  {cat="Capes Evie", name="Live 16829075", hash_le="7590821643000000", id="0x0000004316829075"},
  {cat="Capes Evie", name="Live 16829077", hash_le="7790821643000000", id="0x0000004316829077"},
  {cat="Live linked", name="Linked FFEAEE77", hash_le="77EEEAFF45000000", id="0x00000045FFEAEE77"},
  {cat="Live linked", name="Linked FFEAEE78", hash_le="78EEEAFF45000000", id="0x00000045FFEAEE78"},
  {cat="Live linked", name="Linked FFEAFA78", hash_le="78FAEAFF45000000", id="0x00000045FFEAFA78"},
  {cat="Live linked", name="Linked FFEAEE79", hash_le="79EEEAFF45000000", id="0x00000045FFEAEE79"},
  {cat="Live linked", name="Linked FFEAFA79", hash_le="79FAEAFF45000000", id="0x00000045FFEAFA79"},
  {cat="Capes Evie", name="Live 1682907A", hash_le="7A90821643000000", id="0x000000431682907A"},
  {cat="Live linked", name="Linked FFEAEE7A", hash_le="7AEEEAFF45000000", id="0x00000045FFEAEE7A"},
  {cat="Live linked", name="Linked FFEAFA7A", hash_le="7AFAEAFF45000000", id="0x00000045FFEAFA7A"},
  {cat="Capes Evie", name="Live 1682907B", hash_le="7B90821643000000", id="0x000000431682907B"},
  {cat="Live linked", name="Linked FFEAFA7B", hash_le="7BFAEAFF45000000", id="0x00000045FFEAFA7B"},
  {cat="Live other", name="Fam47 41C9607C", hash_le="7C60C94147000000", id="0x0000004741C9607C"},
  {cat="Colors", name="Live 93ECA57C", hash_le="7CA5EC9323000000", id="0x0000002393ECA57C"},
  {cat="Live linked", name="Linked FFEAFA7C", hash_le="7CFAEAFF45000000", id="0x00000045FFEAFA7C"},
  {cat="Live linked", name="Linked FFEAFA7D", hash_le="7DFAEAFF45000000", id="0x00000045FFEAFA7D"},
  {cat="Capes Evie", name="Live 1682907E", hash_le="7E90821643000000", id="0x000000431682907E"},
  {cat="Live linked", name="Linked FFEAFA7E", hash_le="7EFAEAFF45000000", id="0x00000045FFEAFA7E"},
  {cat="Capes Evie", name="Live 1682907F", hash_le="7F90821643000000", id="0x000000431682907F"},
  {cat="Live linked", name="Linked FFEAFA7F", hash_le="7FFAEAFF45000000", id="0x00000045FFEAFA7F"},
  {cat="Live other", name="Fam47 41C96080", hash_le="8060C94147000000", id="0x0000004741C96080"},
  {cat="Colors", name="Live 93ECA580", hash_le="80A5EC9323000000", id="0x0000002393ECA580"},
  {cat="Live linked", name="Linked FFEAFA80", hash_le="80FAEAFF45000000", id="0x00000045FFEAFA80"},
  {cat="Live linked", name="Linked FFEAFA81", hash_le="81FAEAFF45000000", id="0x00000045FFEAFA81"},
  {cat="Live other", name="Fam42 43DC8982", hash_le="8289DC4342000000", id="0x0000004243DC8982"},
  {cat="Live linked", name="Linked FFEAFA82", hash_le="82FAEAFF45000000", id="0x00000045FFEAFA82"},
  {cat="Live linked", name="Linked FFEAFA83", hash_le="83FAEAFF45000000", id="0x00000045FFEAFA83"},
  {cat="Colors", name="Live 93ECA584", hash_le="84A5EC9323000000", id="0x0000002393ECA584"},
  {cat="Live linked", name="Linked FFEAFA84", hash_le="84FAEAFF45000000", id="0x00000045FFEAFA84"},
  {cat="Live linked", name="Linked FFEAFA85", hash_le="85FAEAFF45000000", id="0x00000045FFEAFA85"},
  {cat="Live linked", name="Linked FFEAFA86", hash_le="86FAEAFF45000000", id="0x00000045FFEAFA86"},
  {cat="Firearms", name="Live 6255A587", hash_le="87A555625D000000", id="0x0000005D6255A587"},
  {cat="Live linked", name="Linked FFEAFA87", hash_le="87FAEAFF45000000", id="0x00000045FFEAFA87"},
  {cat="Colors", name="Live 93ECA588", hash_le="88A5EC9323000000", id="0x0000002393ECA588"},
  {cat="Live other", name="Fam22 0572ED88", hash_le="88ED720522000000", id="0x000000220572ED88"},
  {cat="Live linked", name="Linked FFEAFA88", hash_le="88FAEAFF45000000", id="0x00000045FFEAFA88"},
  {cat="Live linked", name="Linked FFEAFA89", hash_le="89FAEAFF45000000", id="0x00000045FFEAFA89"},
  {cat="Live linked", name="Linked FFEAFA8A", hash_le="8AFAEAFF45000000", id="0x00000045FFEAFA8A"},
  {cat="Firearms", name="Live 6255A58B", hash_le="8BA555625D000000", id="0x0000005D6255A58B"},
  {cat="Live linked", name="Linked FFEAFA8B", hash_le="8BFAEAFF45000000", id="0x00000045FFEAFA8B"},
  {cat="Colors", name="Live 93ECA58C", hash_le="8CA5EC9323000000", id="0x0000002393ECA58C"},
  {cat="Live linked", name="Linked FFEAFA8C", hash_le="8CFAEAFF45000000", id="0x00000045FFEAFA8C"},
  {cat="Live linked", name="Linked FFEAFA8D", hash_le="8DFAEAFF45000000", id="0x00000045FFEAFA8D"},
  {cat="Live linked", name="Linked FFEAFA8E", hash_le="8EFAEAFF45000000", id="0x00000045FFEAFA8E"},
  {cat="Firearms", name="Live 6255A58F", hash_le="8FA555625D000000", id="0x0000005D6255A58F"},
  {cat="Live linked", name="Linked FFEAFA8F", hash_le="8FFAEAFF45000000", id="0x00000045FFEAFA8F"},
  {cat="Live linked", name="Linked FFEAFA90", hash_le="90FAEAFF45000000", id="0x00000045FFEAFA90"},
  {cat="Kukri", name="Live 3C538191", hash_le="9181533C43000000", id="0x000000433C538191"},
  {cat="Live linked", name="Linked FFEAFA91", hash_le="91FAEAFF45000000", id="0x00000045FFEAFA91"},
  {cat="Live linked", name="Linked FFEAFA92", hash_le="92FAEAFF45000000", id="0x00000045FFEAFA92"},
  {cat="Live linked", name="Linked FFEAFA93", hash_le="93FAEAFF45000000", id="0x00000045FFEAFA93"},
  {cat="Live linked", name="Linked FFEAFA94", hash_le="94FAEAFF45000000", id="0x00000045FFEAFA94"},
  {cat="Kukri", name="Live 3C538195", hash_le="9581533C43000000", id="0x000000433C538195"},
  {cat="Live linked", name="Linked FFEAFA95", hash_le="95FAEAFF45000000", id="0x00000045FFEAFA95"},
  {cat="Live linked", name="Linked FFEAFA96", hash_le="96FAEAFF45000000", id="0x00000045FFEAFA96"},
  {cat="Live linked", name="Linked FFEAFA97", hash_le="97FAEAFF45000000", id="0x00000045FFEAFA97"},
  {cat="Live linked", name="Linked FFEAFA98", hash_le="98FAEAFF45000000", id="0x00000045FFEAFA98"},
  {cat="Live linked", name="Linked FFEAFB98", hash_le="98FBEAFF45000000", id="0x00000045FFEAFB98"},
  {cat="Live linked", name="Linked FFEAFA99", hash_le="99FAEAFF45000000", id="0x00000045FFEAFA99"},
  {cat="Live linked", name="Linked FFEAFA9A", hash_le="9AFAEAFF45000000", id="0x00000045FFEAFA9A"},
  {cat="Live linked", name="Linked FFEAFA9B", hash_le="9BFAEAFF45000000", id="0x00000045FFEAFA9B"},
  {cat="Live linked", name="Linked FFEAFA9C", hash_le="9CFAEAFF45000000", id="0x00000045FFEAFA9C"},
  {cat="Kukri", name="Live 3C53819D", hash_le="9D81533C43000000", id="0x000000433C53819D"},
  {cat="Live linked", name="Linked FFEAFA9D", hash_le="9DFAEAFF45000000", id="0x00000045FFEAFA9D"},
  {cat="Live linked", name="Linked FFEAFA9E", hash_le="9EFAEAFF45000000", id="0x00000045FFEAFA9E"},
  {cat="Live linked", name="Linked FFEAFA9F", hash_le="9FFAEAFF45000000", id="0x00000045FFEAFA9F"},
  {cat="Live linked", name="Linked FFEAFAA0", hash_le="A0FAEAFF45000000", id="0x00000045FFEAFAA0"},
  {cat="Live linked", name="Linked FFEAFAA1", hash_le="A1FAEAFF45000000", id="0x00000045FFEAFAA1"},
  {cat="Live linked", name="Linked FFEAFAA2", hash_le="A2FAEAFF45000000", id="0x00000045FFEAFAA2"},
  {cat="Live linked", name="Linked FFEAFAA3", hash_le="A3FAEAFF45000000", id="0x00000045FFEAFAA3"},
  {cat="Live linked", name="Linked FFEAFAA4", hash_le="A4FAEAFF45000000", id="0x00000045FFEAFAA4"},
  {cat="Live linked", name="Linked FFEAFAA5", hash_le="A5FAEAFF45000000", id="0x00000045FFEAFAA5"},
  {cat="Live linked", name="Linked FFEAFAA6", hash_le="A6FAEAFF45000000", id="0x00000045FFEAFAA6"},
  {cat="Knuckles", name="Live 3C5382A7", hash_le="A782533C43000000", id="0x000000433C5382A7"},
  {cat="Live linked", name="Linked FFEAFAA7", hash_le="A7FAEAFF45000000", id="0x00000045FFEAFAA7"},
  {cat="Live linked", name="Linked FFEAFAA8", hash_le="A8FAEAFF45000000", id="0x00000045FFEAFAA8"},
  {cat="Kukri", name="Live 3C5381A9", hash_le="A981533C43000000", id="0x000000433C5381A9"},
  {cat="Live linked", name="Linked FFEAFAA9", hash_le="A9FAEAFF45000000", id="0x00000045FFEAFAA9"},
  {cat="Live linked", name="Linked FFEAFAAA", hash_le="AAFAEAFF45000000", id="0x00000045FFEAFAAA"},
  {cat="Live linked", name="Linked FFEAFAAB", hash_le="ABFAEAFF45000000", id="0x00000045FFEAFAAB"},
  {cat="Live linked", name="Linked FFEAFAAC", hash_le="ACFAEAFF45000000", id="0x00000045FFEAFAAC"},
  {cat="Kukri", name="Live 3C5381AD", hash_le="AD81533C43000000", id="0x000000433C5381AD"},
  {cat="Live linked", name="Linked FFEAFAAD", hash_le="ADFAEAFF45000000", id="0x00000045FFEAFAAD"},
  {cat="Live linked", name="Linked FFEAFAAE", hash_le="AEFAEAFF45000000", id="0x00000045FFEAFAAE"},
  {cat="Live linked", name="Linked FFEAFAAF", hash_le="AFFAEAFF45000000", id="0x00000045FFEAFAAF"},
  {cat="Live linked", name="Linked FFEAFAB1", hash_le="B1FAEAFF45000000", id="0x00000045FFEAFAB1"},
  {cat="Live linked", name="Linked FFEAFAB2", hash_le="B2FAEAFF45000000", id="0x00000045FFEAFAB2"},
  {cat="Knuckles", name="Live 3C5382B3", hash_le="B382533C43000000", id="0x000000433C5382B3"},
  {cat="Live linked", name="Linked FFEAFAB3", hash_le="B3FAEAFF45000000", id="0x00000045FFEAFAB3"},
  {cat="Live linked", name="Linked FFEAFAB4", hash_le="B4FAEAFF45000000", id="0x00000045FFEAFAB4"},
  {cat="Live linked", name="Linked FFEAFAB5", hash_le="B5FAEAFF45000000", id="0x00000045FFEAFAB5"},
  {cat="Live linked", name="Linked FFEAFAB6", hash_le="B6FAEAFF45000000", id="0x00000045FFEAFAB6"},
  {cat="Gauntlets", name="Live 1079D8B7", hash_le="B7D879103F000000", id="0x0000003F1079D8B7"},
  {cat="Live linked", name="Linked FFEAEFB7", hash_le="B7EFEAFF45000000", id="0x00000045FFEAEFB7"},
  {cat="Live linked", name="Linked FFEAFAB7", hash_le="B7FAEAFF45000000", id="0x00000045FFEAFAB7"},
  {cat="Gauntlets", name="Live 1079D8B8", hash_le="B8D879103F000000", id="0x0000003F1079D8B8"},
  {cat="Live linked", name="Linked FFEAEFB8", hash_le="B8EFEAFF45000000", id="0x00000045FFEAEFB8"},
  {cat="Live linked", name="Linked FFEAFAB8", hash_le="B8FAEAFF45000000", id="0x00000045FFEAFAB8"},
  {cat="Live linked", name="Linked FFEAEFB9", hash_le="B9EFEAFF45000000", id="0x00000045FFEAEFB9"},
  {cat="Live linked", name="Linked FFEAFAB9", hash_le="B9FAEAFF45000000", id="0x00000045FFEAFAB9"},
  {cat="Live linked", name="Linked FFEAEFBA", hash_le="BAEFEAFF45000000", id="0x00000045FFEAEFBA"},
  {cat="Live linked", name="Linked FFEAFABA", hash_le="BAFAEAFF45000000", id="0x00000045FFEAFABA"},
  {cat="Live linked", name="Linked FFEAEFBB", hash_le="BBEFEAFF45000000", id="0x00000045FFEAEFBB"},
  {cat="Live linked", name="Linked FFEAFABB", hash_le="BBFAEAFF45000000", id="0x00000045FFEAFABB"},
  {cat="Gauntlets", name="Live 1079D8BC", hash_le="BCD879103F000000", id="0x0000003F1079D8BC"},
  {cat="Live linked", name="Linked FFEAEFBC", hash_le="BCEFEAFF45000000", id="0x00000045FFEAEFBC"},
  {cat="Live linked", name="Linked FFEAFABC", hash_le="BCFAEAFF45000000", id="0x00000045FFEAFABC"},
  {cat="Gauntlets", name="Live 1079D8BD", hash_le="BDD879103F000000", id="0x0000003F1079D8BD"},
  {cat="Live linked", name="Linked FFEAEFBD", hash_le="BDEFEAFF45000000", id="0x00000045FFEAEFBD"},
  {cat="Live linked", name="Linked FFEAFABD", hash_le="BDFAEAFF45000000", id="0x00000045FFEAFABD"},
  {cat="Live linked", name="Linked FFEAEFBE", hash_le="BEEFEAFF45000000", id="0x00000045FFEAEFBE"},
  {cat="Live linked", name="Linked FFEAFABE", hash_le="BEFAEAFF45000000", id="0x00000045FFEAFABE"},
  {cat="Gauntlets", name="Live 1079D8BF", hash_le="BFD879103F000000", id="0x0000003F1079D8BF"},
  {cat="Live linked", name="Linked FFEAEFBF", hash_le="BFEFEAFF45000000", id="0x00000045FFEAEFBF"},
  {cat="Live linked", name="Linked FFEAFABF", hash_le="BFFAEAFF45000000", id="0x00000045FFEAFABF"},
  {cat="Live linked", name="Linked FFEAEFC0", hash_le="C0EFEAFF45000000", id="0x00000045FFEAEFC0"},
  {cat="Live linked", name="Linked FFEAEFC1", hash_le="C1EFEAFF45000000", id="0x00000045FFEAEFC1"},
  {cat="Live linked", name="Linked FFEAEFC2", hash_le="C2EFEAFF45000000", id="0x00000045FFEAEFC2"},
  {cat="Live linked", name="Linked FFEAEFC3", hash_le="C3EFEAFF45000000", id="0x00000045FFEAEFC3"},
  {cat="Live linked", name="Linked FFEAEFC4", hash_le="C4EFEAFF45000000", id="0x00000045FFEAEFC4"},
  {cat="Live linked", name="Linked FFEAEFC5", hash_le="C5EFEAFF45000000", id="0x00000045FFEAEFC5"},
  {cat="Live linked", name="Linked FFEAEFC6", hash_le="C6EFEAFF45000000", id="0x00000045FFEAEFC6"},
  {cat="Live linked", name="Linked FFEAEFC7", hash_le="C7EFEAFF45000000", id="0x00000045FFEAEFC7"},
  {cat="Live linked", name="Linked FFEAEFC8", hash_le="C8EFEAFF45000000", id="0x00000045FFEAEFC8"},
  {cat="Live linked", name="Linked FFEAEFC9", hash_le="C9EFEAFF45000000", id="0x00000045FFEAEFC9"},
  {cat="Live linked", name="Linked FFEAEFCA", hash_le="CAEFEAFF45000000", id="0x00000045FFEAEFCA"},
  {cat="Live linked", name="Linked FFEAEFCB", hash_le="CBEFEAFF45000000", id="0x00000045FFEAEFCB"},
  {cat="Live other", name="Fam47 41C960CC", hash_le="CC60C94147000000", id="0x0000004741C960CC"},
  {cat="Live linked", name="Linked FFEAEFCC", hash_le="CCEFEAFF45000000", id="0x00000045FFEAEFCC"},
  {cat="Live linked", name="Linked FFEAEFCD", hash_le="CDEFEAFF45000000", id="0x00000045FFEAEFCD"},
  {cat="Live linked", name="Linked FFEAEFCE", hash_le="CEEFEAFF45000000", id="0x00000045FFEAEFCE"},
  {cat="Live other", name="Fam3A E402B5CF", hash_le="CFB502E43A000000", id="0x0000003AE402B5CF"},
  {cat="Live linked", name="Linked FFEAEFCF", hash_le="CFEFEAFF45000000", id="0x00000045FFEAEFCF"},
  {cat="Live other", name="Fam44 F01A36D0", hash_le="D0361AF044000000", id="0x00000044F01A36D0"},
  {cat="Live other", name="Fam47 41C960D0", hash_le="D060C94147000000", id="0x0000004741C960D0"},
  {cat="Live other", name="Fam3A E402B5D0", hash_le="D0B502E43A000000", id="0x0000003AE402B5D0"},
  {cat="Live linked", name="Linked FFEAEFD0", hash_le="D0EFEAFF45000000", id="0x00000045FFEAEFD0"},
  {cat="Live other", name="Fam3A E402B5D1", hash_le="D1B502E43A000000", id="0x0000003AE402B5D1"},
  {cat="Live linked", name="Linked FFEAEFD1", hash_le="D1EFEAFF45000000", id="0x00000045FFEAEFD1"},
  {cat="Live other", name="Fam3A E402B5D2", hash_le="D2B502E43A000000", id="0x0000003AE402B5D2"},
  {cat="Live linked", name="Linked FFEAEFD2", hash_le="D2EFEAFF45000000", id="0x00000045FFEAEFD2"},
  {cat="Live other", name="Fam3A E402B5D3", hash_le="D3B502E43A000000", id="0x0000003AE402B5D3"},
  {cat="Live linked", name="Linked FFEAEFD3", hash_le="D3EFEAFF45000000", id="0x00000045FFEAEFD3"},
  {cat="Live other", name="Fam47 41C960D4", hash_le="D460C94147000000", id="0x0000004741C960D4"},
  {cat="Live other", name="Fam3A E402B5D4", hash_le="D4B502E43A000000", id="0x0000003AE402B5D4"},
  {cat="Live linked", name="Linked FFEAEFD4", hash_le="D4EFEAFF45000000", id="0x00000045FFEAEFD4"},
  {cat="Live other", name="Fam3A E402B5D5", hash_le="D5B502E43A000000", id="0x0000003AE402B5D5"},
  {cat="Live linked", name="Linked FFEAEFD5", hash_le="D5EFEAFF45000000", id="0x00000045FFEAEFD5"},
  {cat="Gauntlets", name="Live AAEAF3D5", hash_le="D5F3EAAA1D000000", id="0x0000001DAAEAF3D5"},
  {cat="Live other", name="Fam3A E402B5D6", hash_le="D6B502E43A000000", id="0x0000003AE402B5D6"},
  {cat="Live linked", name="Linked FFEAEFD6", hash_le="D6EFEAFF45000000", id="0x00000045FFEAEFD6"},
  {cat="Live other", name="Fam15 EA87B7D7", hash_le="D7B787EA15000000", id="0x00000015EA87B7D7"},
  {cat="Live linked", name="Linked FFEAEFD7", hash_le="D7EFEAFF45000000", id="0x00000045FFEAEFD7"},
  {cat="Live linked", name="Linked FFEAEFD8", hash_le="D8EFEAFF45000000", id="0x00000045FFEAEFD8"},
  {cat="Live linked", name="Linked FFEAEFD9", hash_le="D9EFEAFF45000000", id="0x00000045FFEAEFD9"},
  {cat="Live linked", name="Linked FFEAEFDA", hash_le="DAEFEAFF45000000", id="0x00000045FFEAEFDA"},
  {cat="Live linked", name="Linked FFEAEFDB", hash_le="DBEFEAFF45000000", id="0x00000045FFEAEFDB"},
  {cat="Live linked", name="Linked FFEAEFDC", hash_le="DCEFEAFF45000000", id="0x00000045FFEAEFDC"},
  {cat="Live linked", name="Linked FFEAEFDD", hash_le="DDEFEAFF45000000", id="0x00000045FFEAEFDD"},
  {cat="Gauntlets", name="Live AAEAF3DD", hash_le="DDF3EAAA1D000000", id="0x0000001DAAEAF3DD"},
  {cat="Live linked", name="Linked FFEAEFDE", hash_le="DEEFEAFF45000000", id="0x00000045FFEAEFDE"},
  {cat="Live linked", name="Linked FFEAEFDF", hash_le="DFEFEAFF45000000", id="0x00000045FFEAEFDF"},
  {cat="Live linked", name="Linked FFEAEFE0", hash_le="E0EFEAFF45000000", id="0x00000045FFEAEFE0"},
  {cat="Live linked", name="Linked FFEAEFE1", hash_le="E1EFEAFF45000000", id="0x00000045FFEAEFE1"},
  {cat="Live linked", name="Linked FFEAEFE2", hash_le="E2EFEAFF45000000", id="0x00000045FFEAEFE2"},
  {cat="Live linked", name="Linked FFEAEFE3", hash_le="E3EFEAFF45000000", id="0x00000045FFEAEFE3"},
  {cat="Live linked", name="Linked FFEAEFE4", hash_le="E4EFEAFF45000000", id="0x00000045FFEAEFE4"},
  {cat="Gauntlets", name="Live AAEAF3E5", hash_le="E5F3EAAA1D000000", id="0x0000001DAAEAF3E5"},
  {cat="Gauntlets", name="Live AAEAF3E9", hash_le="E9F3EAAA1D000000", id="0x0000001DAAEAF3E9"},
  {cat="Kukri", name="Live 3C5381EA", hash_le="EA81533C43000000", id="0x000000433C5381EA"},
  {cat="Live other", name="Fam47 41C95FF6", hash_le="F65FC94147000000", id="0x0000004741C95FF6"},
  {cat="Kukri", name="Live 3C5381FA", hash_le="FA81533C43000000", id="0x000000433C5381FA"},
  {cat="Kukri", name="Live 495D06FD", hash_le="FD065D4941000000", id="0x00000041495D06FD"},
  {cat="Kukri", name="Live 495D06FE", hash_le="FE065D4941000000", id="0x00000041495D06FE"},
  {cat="Live linked", name="Linked FFEAEEFF", hash_le="FFEEEAFF45000000", id="0x00000045FFEAEEFF"},
  {cat="Forge Weapons UI", name="ACVI_Crafting_Brassknuckle_Map", hash_le="873FA71149000000", id="0x0000004911A73F87"},
  {cat="Forge Weapons UI", name="ACVI_Crafting_Cane_Map", hash_le="AC3DA71149000000", id="0x0000004911A73DAC"},
  {cat="Forge Weapons UI", name="ACVI_Crafting_Kukri_Map", hash_le="BA3FA71149000000", id="0x0000004911A73FBA"},
  {cat="Forge Weapons UI", name="ACVI_Crafting_PistolAmmoPouch_01_Celebration_Map", hash_le="7FA94FC961000000", id="0x00000061C94FA97F"},
  {cat="Forge Weapons UI", name="ACVI_Crafting_PistolAmmoPouch_01_Map", hash_le="47F3504349000000", id="0x000000494350F347"},
  {cat="Forge Weapons UI", name="ACVI_Crafting_PistolAmmoPouch_01_SideImage_Map", hash_le="31694BE36B000000", id="0x0000006BE34B6931"},
  {cat="Forge Weapons UI", name="ACVI_Crafting_PistolAmmoPouch_02_Celebration_Map", hash_le="DDA74FC961000000", id="0x00000061C94FA7DD"},
  {cat="Forge Weapons UI", name="ACVI_Crafting_PistolAmmoPouch_02_Map", hash_le="7AF3504349000000", id="0x000000494350F37A"},
  {cat="Forge Weapons UI", name="ACVI_Crafting_PistolAmmoPouch_02_SideImage_Map", hash_le="3C694BE36B000000", id="0x0000006BE34B693C"},
  {cat="Forge Weapons UI", name="ACVI_Crafting_Revolvers_Map", hash_le="2C3FA71149000000", id="0x0000004911A73F2C"},
  {cat="Forge Weapons UI", name="ACVI_Icons_Tools_PistolAmmo_Map", hash_le="1A81D97A40000000", id="0x000000407AD9811A"},
  {cat="Forge Weapons UI", name="ACVI_Icons_Tools_Pistol_Map", hash_le="93EE3F5740000000", id="0x00000040573FEE93"},
  {cat="Forge Weapons UI", name="ACVI_UI_Icon_Crafting_Gauntlet_Map", hash_le="5B48E59F41000000", id="0x000000419FE5485B"},
  {cat="Forge Weapons UI", name="ACVI_UI_Menu_EStore_ULC_PanelImage_WeaponsAngelKnuckles_Map", hash_le="944884686F000000", id="0x0000006F68844894"},
  {cat="Forge Weapons UI", name="ACVI_UI_Menu_EStore_ULC_PanelImage_WeaponsCooperCane_Map", hash_le="A94884686F000000", id="0x0000006F688448A9"},
  {cat="Forge Weapons UI", name="ACVI_UI_Menu_EStore_ULC_PanelImage_WeaponsDemonPistol_Map", hash_le="B04884686F000000", id="0x0000006F688448B0"},
  {cat="Forge Weapons UI", name="ACVI_UI_Menu_EStore_ULC_PanelImage_WeaponsDirtyKnuckles_Map", hash_le="9B4884686F000000", id="0x0000006F6884489B"},
  {cat="Forge Weapons UI", name="ACVI_UI_Menu_EStore_ULC_PanelImage_WeaponsGoldenKukri_Map", hash_le="B74884686F000000", id="0x0000006F688448B7"},
  {cat="Forge Weapons UI", name="ACVI_UI_Menu_EStore_ULC_PanelImage_WeaponsOceanCane_Map", hash_le="CC4884686F000000", id="0x0000006F688448CC"},
  {cat="Forge Weapons UI", name="ACVI_UI_Menu_EStore_ULC_PanelImage_WeaponsPirateKnuckles_Map", hash_le="D34884686F000000", id="0x0000006F688448D3"},
  {cat="Forge Weapons UI", name="ACVI_UI_Menu_EStore_ULC_PanelImage_WeaponsRamsKukri_Map", hash_le="DA4884686F000000", id="0x0000006F688448DA"},
  {cat="Forge Weapons UI", name="ACVI_UI_Menu_EStore_ULC_PanelImage_WeaponsStealthPistol_Map", hash_le="EF4884686F000000", id="0x0000006F688448EF"},
  {cat="Forge Weapons UI", name="ACVI_UI_Menu_EStore_ULC_PanelImage_WeaponsVoodooKukri_Map", hash_le="A24884686F000000", id="0x0000006F688448A2"},
  {cat="Forge Weapons UI", name="ACVI_UIicons_Menu_Weapon_BrassKnucks_Map", hash_le="50A4978942000000", id="0x000000428997A450"},
  {cat="Forge Weapons UI", name="ACVI_UIicons_Menu_Weapon_Canes_Map", hash_le="57A4978942000000", id="0x000000428997A457"},
  {cat="Forge Weapons UI", name="ACVI_UIicons_Menu_Weapon_Gauntlet_Map", hash_le="5EA4978942000000", id="0x000000428997A45E"},
  {cat="Forge Weapons UI", name="ACVI_UIicons_Menu_Weapon_Kukri_Map", hash_le="65A4978942000000", id="0x000000428997A465"},
  {cat="Forge Weapons UI", name="UIicon_Weapon_AssassinBlade_Map", hash_le="271469481B000000", id="0x0000001B48691427"},
  {cat="Forge Weapons UI", name="UIicon_Weapon_Long_Map", hash_le="958C109D11000000", id="0x000000119D108C95"},
  {cat="Forge Weapons UI", name="UIicon_Weapon_TwoHands_Map", hash_le="D18C109D11000000", id="0x000000119D108CD1"},
  {cat="Forge Armor/Gear UI", name="ACVI_Crafting_Belt_Map", hash_le="653DA71149000000", id="0x0000004911A73D65"},
  {cat="Forge Armor/Gear UI", name="ACVI_Crafting_Bracer_01_Map", hash_le="D5FA504349000000", id="0x000000494350FAD5"},
  {cat="Forge Armor/Gear UI", name="ACVI_Crafting_Bracer_02_Map", hash_le="F4FA504349000000", id="0x000000494350FAF4"},
  {cat="Forge Armor/Gear UI", name="ACVI_Crafting_Bracers_Map", hash_le="593EA71149000000", id="0x0000004911A73E59"},
  {cat="Forge Armor/Gear UI", name="ACVI_Crafting_Cloak_Map", hash_le="F33DA71149000000", id="0x0000004911A73DF3"},
  {cat="Forge Armor/Gear UI", name="ACVI_Crafting_Outfit_Map", hash_le="263EA71149000000", id="0x0000004911A73E26"},
  {cat="Forge Armor/Gear UI", name="ACVI_UI_Icon_Rewards_Hats_Map", hash_le="313A60F241000000", id="0x00000041F2603A31"},
  {cat="Forge Armor/Gear UI", name="ACVI_UI_Menu_EStore_ULC_PanelImage_OutfitAveline_Map", hash_le="D44A84686F000000", id="0x0000006F68844AD4"},
  {cat="Forge Armor/Gear UI", name="ACVI_UI_Menu_EStore_ULC_PanelImage_OutfitBakerStreet_Map", hash_le="DB4A84686F000000", id="0x0000006F68844ADB"},
  {cat="Forge Armor/Gear UI", name="ACVI_UI_Menu_EStore_ULC_PanelImage_OutfitEdward_Map", hash_le="E24A84686F000000", id="0x0000006F68844AE2"},
  {cat="Forge Armor/Gear UI", name="ACVI_UI_Menu_EStore_ULC_PanelImage_OutfitElise_Map", hash_le="E94A84686F000000", id="0x0000006F68844AE9"},
  {cat="Forge Armor/Gear UI", name="ACVI_UI_Menu_EStore_ULC_PanelImage_OutfitEzio_Map", hash_le="F04A84686F000000", id="0x0000006F68844AF0"},
  {cat="Forge Armor/Gear UI", name="ACVI_UI_Menu_EStore_ULC_PanelImage_OutfitNighthawk_Map", hash_le="484C84686F000000", id="0x0000006F68844C48"},
  {cat="Forge Armor/Gear UI", name="ACVI_UI_Menu_EStore_ULC_PanelImage_OutfitShaoJun_Map", hash_le="F74A84686F000000", id="0x0000006F68844AF7"},
  {cat="Forge Armor/Gear UI", name="ACVI_UI_Menu_EStore_ULC_PanelImage_OutfitSuave_Map", hash_le="4F4C84686F000000", id="0x0000006F68844C4F"},
  {cat="Forge Armor/Gear UI", name="ACVI_UIicons_Menu_Gear_Belts_Map", hash_le="E2A3978942000000", id="0x000000428997A3E2"},
  {cat="Forge Armor/Gear UI", name="ACVI_UIicons_Menu_Gear_Cloaks_Map", hash_le="E9A3978942000000", id="0x000000428997A3E9"},
  {cat="Forge Armor/Gear UI", name="ACVI_UIicons_Menu_Gear_Colors_Map", hash_le="F0A3978942000000", id="0x000000428997A3F0"},
  {cat="Forge Armor/Gear UI", name="ACVI_UIicons_Menu_Gear_Outfits_Map", hash_le="F7A3978942000000", id="0x000000428997A3F7"},
  {cat="Forge Armor/Gear UI", name="ACVI_UIicons_REW_Outfits_Map", hash_le="195B09F44B000000", id="0x0000004BF4095B19"},
  {cat="Forge Outfits", name="ACVI_Gear_Body_OutfitAvelineDeGrandpre_Map", hash_le="705D2D4B48000000", id="0x000000484B2D5D70"},
  {cat="Forge Outfits", name="ACVI_Gear_Body_OutfitEliseDeLaSerre_Map", hash_le="ED5C2D4B48000000", id="0x000000484B2D5CED"},
  {cat="Forge Outfits", name="ACVI_Gear_Body_OutfitEvie11_Map", hash_le="265E2D4B48000000", id="0x000000484B2D5E26"},
  {cat="Forge Outfits", name="ACVI_Gear_Body_OutfitEvie12_Map", hash_le="211F40C079000000", id="0x00000079C0401F21"},
  {cat="Forge Outfits", name="ACVI_Gear_Body_OutfitEvie13_Map", hash_le="4E701D6377000000", id="0x00000077631D704E"},
  {cat="Forge Outfits", name="ACVI_Gear_Body_OutfitEvie1_Map", hash_le="12F1F6F947000000", id="0x00000047F9F6F112"},
  {cat="Forge Outfits", name="ACVI_Gear_Body_OutfitEvie2_Map", hash_le="6DF1F6F947000000", id="0x00000047F9F6F16D"},
  {cat="Forge Outfits", name="ACVI_Gear_Body_OutfitEvie3_Map", hash_le="E3F2F6F947000000", id="0x00000047F9F6F2E3"},
  {cat="Forge Outfits", name="ACVI_Gear_Body_OutfitEvie4_Map", hash_le="D3F1F6F947000000", id="0x00000047F9F6F1D3"},
  {cat="Forge Outfits", name="ACVI_Gear_Body_OutfitEvie5_Map", hash_le="2EF2F6F947000000", id="0x00000047F9F6F22E"},
  {cat="Forge Outfits", name="ACVI_Gear_Body_OutfitEvie6_Map", hash_le="61F2F6F947000000", id="0x00000047F9F6F261"},
  {cat="Forge Outfits", name="ACVI_Gear_Body_OutfitEvie7_Map", hash_le="DFEDF6F947000000", id="0x00000047F9F6EDDF"},
  {cat="Forge Outfits", name="ACVI_Gear_Body_OutfitJacob10_Map", hash_le="9E472D4B48000000", id="0x000000484B2D479E"},
  {cat="Forge Outfits", name="ACVI_Gear_Body_OutfitJacob11_Map", hash_le="8FF0F6F947000000", id="0x00000047F9F6F08F"},
  {cat="Forge Outfits", name="ACVI_Gear_Body_OutfitJacob12_Map", hash_le="281F40C079000000", id="0x00000079C0401F28"},
  {cat="Forge Outfits", name="ACVI_Gear_Body_OutfitJacob13_Map", hash_le="55701D6377000000", id="0x00000077631D7055"},
  {cat="Forge Outfits", name="ACVI_Gear_Body_OutfitJacob1_Map", hash_le="62EEF6F947000000", id="0x00000047F9F6EE62"},
  {cat="Forge Outfits", name="ACVI_Gear_Body_OutfitJacob2_Map", hash_le="BDEEF6F947000000", id="0x00000047F9F6EEBD"},
  {cat="Forge Outfits", name="ACVI_Gear_Body_OutfitJacob3_Map", hash_le="18EFF6F947000000", id="0x00000047F9F6EF18"},
  {cat="Forge Outfits", name="ACVI_Gear_Body_OutfitJacob4_Map", hash_le="73EFF6F947000000", id="0x00000047F9F6EF73"},
  {cat="Forge Outfits", name="ACVI_Gear_Body_OutfitJacob5_Map", hash_le="A6EFF6F947000000", id="0x00000047F9F6EFA6"},
  {cat="Forge Outfits", name="ACVI_Gear_Body_OutfitJacob6_Map", hash_le="01F0F6F947000000", id="0x00000047F9F6F001"},
  {cat="Forge Outfits", name="ACVI_Gear_Body_OutfitJacob7_Map", hash_le="5CF0F6F947000000", id="0x00000047F9F6F05C"},
  {cat="Forge Outfits", name="ACVI_Gear_Body_OutfitJacob8_Map", hash_le="7F5A2D4B48000000", id="0x000000484B2D5A7F"},
  {cat="Forge Outfits", name="ACVI_Gear_Body_OutfitJacob9_Map", hash_le="DA5A2D4B48000000", id="0x000000484B2D5ADA"},
  {cat="Forge Outfits", name="ACVI_Gear_Body_OutfitShaoJun_Map", hash_le="A35D2D4B48000000", id="0x000000484B2D5DA3"},
  {cat="Forge Weapons Extra", name="ACVI_Icons_Panels_RewardsPistol_Map", hash_le="C91299CC58000000", id="0x00000058CC9912C9"},
  {cat="Forge Weapons Extra", name="UIicon_Reward_MysteryWeapon_Map", hash_le="D548C0D12A000000", id="0x0000002AD1C048D5"},
  {cat="Forge Weapons Extra", name="ACVI_UIicon_Skills_CombatRegen_Map", hash_le="F6588DF145000000", id="0x00000045F18D58F6"},
  {cat="Forge Weapons Extra", name="UIicon_Reward_Weapons_Map", hash_le="489B251738000000", id="0x0000003817259B48"},
  {cat="Forge Armor Extra", name="ACVI_UIicon_DistrictAct_MurderMysteries_InvestigationZone_Map", hash_le="FE02C50751000000", id="0x0000005107C502FE"},
  {cat="Forge Armor Extra", name="UIicon_Reward_LethatlBooster_Map", hash_le="698F57652C000000", id="0x0000002C65578F69"},
  {cat="Forge Armor Extra", name="ACVIDLC_UIiconACT_Alberline_SlowCartEscape_Map", hash_le="1A29368B62000000", id="0x000000628B36291A"},
  {cat="Forge Armor Extra", name="ACVI_UIicon_DistrictAct_MurderMysteries_CompletedInvestigationZone_Map", hash_le="F702C50751000000", id="0x0000005107C502F7"},
  {cat="Forge Armor Extra", name="ACVI_UIicon_LondonUpgrades_EscapePlan_Celebration_Map", hash_le="59D682D660000000", id="0x00000060D682D659"},
  {cat="Forge Armor Extra", name="ACVI_UIicon_LondonUpgrades_EscapePlan_Map", hash_le="1FFFB58148000000", id="0x0000004881B5FF1F"},
  {cat="Forge Armor Extra", name="ACVI_UIicon_LondonUpgrades_PubInvestor_Celebration_Map", hash_le="06D882D660000000", id="0x00000060D682D806"},
  {cat="Forge Armor Extra", name="ACVI_UIicon_LondonUpgrades_PubInvestor_Map", hash_le="81FFB58148000000", id="0x0000004881B5FF81"},
  {cat="Forge Armor Extra", name="ACVI_UIicon_LondonUpgrades_ShopInvestor_Celebration_Map", hash_le="1CD882D660000000", id="0x00000060D682D81C"},
  {cat="Forge Armor Extra", name="ACVI_UIicon_LondonUpgrades_ShopInvestor_Map", hash_le="8FFFB58148000000", id="0x0000004881B5FF8F"},
  {cat="Forge Armor Extra", name="ACVI_UI_MENU_Map_VertGridMask_Map", hash_le="7C9B73D053000000", id="0x00000053D0739B7C"},
  {cat="Forge Armor Extra", name="ACVI_UI_Menu_EStore_ULC_PanelImage_GearIndustrialBracer_Map", hash_le="C54884686F000000", id="0x0000006F688448C5"},
  {cat="Forge Armor Extra", name="ACVI_UI_Menu_EStore_ULC_PanelImage_GearIronBelt_Map", hash_le="254C84686F000000", id="0x0000006F68844C25"},
  {cat="Forge Armor Extra", name="ACVI_UI_Menu_EStore_ULC_PanelImage_GearOutoftheBlueCloack_Map", hash_le="3A4C84686F000000", id="0x0000006F68844C3A"},
  {cat="Forge Armor Extra", name="ACVI_UI_Menu_EStore_ULC_PanelImage_GearRedbackBracer_Map", hash_le="E14884686F000000", id="0x0000006F688448E1"},
  {cat="Forge Armor Extra", name="ACVI_UI_Menu_EStore_ULC_PanelImage_GearRoyalBracer_Map", hash_le="F64884686F000000", id="0x0000006F688448F6"},
  {cat="Forge Armor Extra", name="ACVI_UI_Menu_EStore_ULC_PanelImage_GearCrimsonWingCloak_Map", hash_le="1E4C84686F000000", id="0x0000006F68844C1E"},
  {cat="Forge Armor Extra", name="ACVI_UI_Menu_EStore_ULC_PanelImage_GearKillersCloak_Map", hash_le="2C4C84686F000000", id="0x0000006F68844C2C"},
  {cat="Forge Armor Extra", name="ACVI_UI_Menu_EStore_ULC_PanelImage_GearNobleBrotherhoodBelt_Map", hash_le="334C84686F000000", id="0x0000006F68844C33"},
  {cat="Forge Armor Extra", name="ACVI_UI_Menu_EStore_ULC_PanelImage_GearSuaveBelt_Map", hash_le="414C84686F000000", id="0x0000006F68844C41"},
}

-- #region agent log
agent_log("G0", "gear_editor.lua:load", "gear_desk_loaded", {catalog=#CATALOG, liveInjected=true})
-- #endregion

-- ACS Anvil heaps freely use low user VA (e.g. def nodes ~0x09xxxxxx).
-- Reject ONLY null/junk and ACS.exe image — never require >=4GB (that hid the real list).
local function gamePtr(p)
  return type(p) == "number" and p > 0x10000 and p < 0x800000000000
end

-- Alias kept for older call sites / logs.
local function heapPtr(p)
  return gamePtr(p)
end

-- Readable probe address (mainstruct itself can sit below 4GB).
local function canRead(a)
  return type(a) == "number" and a > 0x10000 and a < 0x800000000000
end

local function moduleRange()
  local base = getAddressSafe(MOD) or getAddress(MOD)
  local size = 0x4000000
  pcall(function()
    if getModuleSize then size = getModuleSize(MOD) or size end
  end)
  if not base or base == 0 then return nil, nil end
  return math.floor(base), math.floor(size)
end

local function inAcsModule(p)
  if type(p) ~= "number" then return false end
  local base, size = moduleRange()
  if not base then return false end
  return p >= base and p < (base + size)
end

local function looksLikeDefNode(node, hashLe)
  if not gamePtr(node) or inAcsModule(node) then return false end
  -- Live layout: [+0 ptr][+8 u32 small][+0xC 01 00 00 80][+0x10 hash_le]
  local okHdr, hdr = pcall(readInteger, node + 8)
  if not okHdr or type(hdr) ~= "number" then return false end
  local n = hdr % 0x100000000
  if n < 1 or n > 0x200 then return false end
  local ok, b = pcall(readBytes, node + 0x0C, 4 + 8, true)
  if not ok or type(b) ~= "table" or #b < 12 then return false end
  -- 01 00 00 80 + LE resource hash
  if not (b[1] == 1 and b[2] == 0 and b[3] == 0 and b[4] == 0x80) then return false end
  local want = tostring(hashLe or ""):gsub("%s+", ""):upper()
  if #want < 16 then return true end
  local got = {}
  for i = 5, 12 do got[#got + 1] = string.format("%02X", b[i] or 0) end
  return table.concat(got) == want:sub(1, 16)
end

local function hashAtNode(node)
  local ok, b = pcall(readBytes, node + 0x10, 8, true)
  if not ok or type(b) ~= "table" or #b < 8 then return nil end
  local s = {}
  for i = 1, 8 do s[i] = string.format("%02X", b[i] or 0) end
  return table.concat(s)
end

local function rq(a)
  if not canRead(a) then return nil end
  local ok, v = pcall(readQword, a)
  if ok and gamePtr(v) and not inAcsModule(v) then return v end
  return nil
end

local function ru16(a)
  if not canRead(a) then return nil end
  local ok, v = pcall(readSmallInteger, a)
  if ok and type(v) == "number" then return v % 65536 end
  ok, v = pcall(readInteger, a)
  if ok and type(v) == "number" then return v % 65536 end
  return nil
end

-- Byte Engine ParseAob only tokenizes on spaces. Compact "AABB??CC" scans as empty.
local function spaceHex(compact)
  local s = tostring(compact or ""):gsub("%s+", ""):upper()
  local out = {}
  local i = 1
  while i <= #s do
    local c = s:sub(i, i)
    if c == "?" then
      out[#out + 1] = "??"
      i = i + 1
      if s:sub(i, i) == "?" then i = i + 1 end
    else
      out[#out + 1] = s:sub(i, i + 1)
      i = i + 2
    end
  end
  return table.concat(out, " ")
end

local function toAddr(v)
  if type(v) == "number" and v > 0 then return math.floor(v) end
  if type(v) == "string" and v ~= "" then
    local hex = v:match("^0[xX](%x+)$") or (v:match("^%x+$") and v)
    if hex and not v:match("^%d+$") then return tonumber(hex, 16) end
    return tonumber(v, 16) or tonumber(v)
  end
  return nil
end

local function qwordToLeAob(v)
  local n = math.floor(tonumber(v) or 0)
  local parts = {}
  if type(bAnd) == "function" and type(bShr) == "function" then
    for i = 0, 7 do
      parts[#parts + 1] = string.format("%02X", bAnd(bShr(n, i * 8), 0xFF))
    end
  else
    local u = n
    for _ = 1, 8 do
      local b = u % 256
      if b < 0 then b = b + 256 end
      parts[#parts + 1] = string.format("%02X", b)
      u = math.floor(u / 256)
    end
  end
  return table.concat(parts, " ")
end

-- Module-bounded scan only. Full-process AOBScan hangs Byte Engine (gear desk freeze).
local function firstAobHit(pattern, prot, moduleName)
  local pat = tostring(pattern or "")
  if not pat:find("%s") then pat = spaceHex(pat) end
  if pat == "" then return nil end

  if moduleName and type(AOBScanModule) == "function" then
    local ok, r = pcall(AOBScanModule, moduleName, pat)
    if ok and r then
      local a = nil
      if type(r.getString) == "function" and (r.Count or 0) > 0 then
        a = toAddr(r.getString(0))
      elseif type(r) == "string" or type(r) == "number" then
        a = toAddr(r)
      end
      if type(r.destroy) == "function" then pcall(r.destroy) end
      if a then return a end
    end
  end

  local base, size = nil, nil
  if moduleName then
    base = getAddressSafe(moduleName) or getAddress(moduleName)
    if type(getModuleSize) == "function" then
      local ok, sz = pcall(getModuleSize, moduleName)
      if ok then size = sz end
    end
  end
  if not canRead(base) then
    base = 0
    size = nil
  end
  local stop = size and (base + size) or 0x7FFFFFFFFFFF
  -- Prefer module window; never start an unbounded scan when moduleName was requested.
  if moduleName and not size then
    size = 0x4000000
    stop = base + size
  end

  local ms = createMemScan()
  if not ms then return nil end
  local okScan = pcall(function()
    ms.firstScan(
      soExactValue, vtByteArray, rtRounded, pat, nil,
      base, stop, prot or "", fsmAligned, "1",
      true, false, false, false)
  end)
  if not okScan then
    pcall(function() ms.destroy() end)
    return nil
  end
  if type(ms.waitTillDone) == "function" then pcall(ms.waitTillDone) end
  local hit = nil
  local fl = nil
  if type(createFoundList) == "function" then
    local okFl, f = pcall(createFoundList, ms)
    if okFl and f then
      fl = f
      pcall(function() fl.initialize() end)
      if (fl.Count or 0) > 0 then
        hit = toAddr(fl.Address and fl.Address[0]) or toAddr(fl.getAddress and fl.getAddress(0))
      end
      pcall(function() fl.destroy() end)
    end
  end
  if not hit and (ms.Count or 0) > 0 then
    hit = toAddr(ms.Address and ms.Address[0]) or toAddr(ms.getAddress and ms.getAddress(0))
  end
  pcall(function() ms.destroy() end)
  return hit
end

local function scanModuleAob(pattern)
  return firstAobHit(pattern, "+X-W", MOD)
end

local function scanQwordWritableAll(value, maxHits)
  maxHits = maxHits or 24
  local hits = {}
  local head = math.floor(tonumber(value) or 0)
  if head == 0 then return hits end

  -- Prefer typed qword scan (much faster than 8-byte AOB over all memory).
  local ms = createMemScan()
  if not ms then return hits end
  local ok = pcall(function()
    ms.firstScan(
      soExactValue, vtQword, rtRounded, string.format("%d", head), nil,
      0x10000, 0x7FFFFFFFFFFF, "-X+W", fsmAligned, "8",
      true, false, false, false)
  end)
  if not ok then
    -- fallback LE bytes
    local le = qwordToLeAob(head)
    ok = pcall(function()
      ms.firstScan(
        soExactValue, vtByteArray, rtRounded, le, nil,
        0x10000, 0x7FFFFFFFFFFF, "-X+W", fsmAligned, "1",
        true, false, false, false)
    end)
  end
  if ok and type(ms.waitTillDone) == "function" then pcall(ms.waitTillDone) end
  if type(createFoundList) == "function" then
    local okFl, fl = pcall(createFoundList, ms)
    if okFl and fl then
      pcall(function() fl.initialize() end)
      local n = tonumber(fl.Count) or 0
      for i = 0, math.min(n, maxHits) - 1 do
        local a = toAddr(fl.Address and fl.Address[i])
        if a then hits[#hits + 1] = a end
      end
      pcall(function() fl.destroy() end)
    end
  end
  pcall(function() ms.destroy() end)
  return hits
end

local function listContains(base, count, needle)
  if not canRead(base) or not count or count < 1 then return false end
  needle = math.floor(needle)
  for i = 0, count - 1 do
    local ok, v = pcall(readQword, base + 8 * i)
    if ok and v and math.floor(v) == needle then return true end
  end
  return false
end

local function markGrownPage(addr)
  -- Disabled: writing the Anvil page-mark table from BE's UI thread was a
  -- candidate for ByteEngine 0xC0000005 ("Exception Processing Message").
  -- Unlocker uses this after grow; we skip it and rely on heap alloc alone.
  -- #region agent log
  agent_log("H6", "markGrownPage", "skipped", {addr = addr or 0})
  -- #endregion
  return
end

-- Empty lists often point at a static sentinel inside ACS.exe. Writing there
-- crashes. Promote to a heap buffer first (unlocker grow path), then grant.
local function promoteModuleSentinel(holder, cap)
  if not gamePtr(holder) or inAcsModule(holder) then return nil end
  local list = nil
  pcall(function() list = readQword(holder + 0x40) end)
  if not list or not inAcsModule(list) then return nil end
  local count = ru16(holder + 0x4A) or 0
  cap = cap or ru16(holder + 0x48) or 0
  if count ~= 0 or cap < 4 or cap > 256 then return nil end
  local raw = allocateMemory(cap * 8 + 976)
  if not raw or raw == 0 then return nil end
  local alloc = raw + 16
  pcall(markGrownPage, alloc)
  if not pcall(writeQword, holder + 0x40, alloc) then return nil end
  local now = nil
  pcall(function() now = readQword(holder + 0x40) end)
  -- #region agent log
  agent_log("H4", "promoteModuleSentinel", "done", {
    holder = holder, oldList = list, alloc = alloc, now = now or 0, cap = cap,
  })
  -- #endregion
  if now and math.floor(now) == math.floor(alloc) and not inAcsModule(now) then
    return now
  end
  return nil
end

local function tryHolder(holder, via, opts)
  opts = opts or {}
  if not gamePtr(holder) or inAcsModule(holder) then
    return nil, via .. " holder bad"
  end
  local list = nil
  pcall(function() list = readQword(holder + 0x40) end)
  local count = ru16(holder + 0x4A)
  local cap = ru16(holder + 0x48)
  if not list or count == nil or cap == nil then
    return nil, via .. " list fields unreadable"
  end
  if inAcsModule(list) then
    local promoted = promoteModuleSentinel(holder, cap)
    if not promoted then
      return nil, via .. " list not heap (refuses module VA)"
    end
    list = promoted
    via = via .. "+promo"
  end
  if not gamePtr(list) or inAcsModule(list) then
    return nil, via .. " list not heap"
  end
  if cap < 4 or cap > 20000 or count > cap then
    return nil, string.format("%s count/cap nonsense %s/%s", via, tostring(count), tostring(cap))
  end
  -- Unlocker path (+0xBC) may have stale/partial entries; still trust the
  -- holder layout. Alternate paths keep the strict def-node sample.
  if count > 0 and not opts.loose then
    local defs = 0
    local n = math.min(count, 6)
    for i = 0, n - 1 do
      local e = nil
      pcall(function() e = readQword(list + 8 * i) end)
      if e and looksLikeDefNode(e) then defs = defs + 1 end
    end
    if defs == 0 then
      return nil, via .. " list entries not def nodes"
    end
  end
  return { holder = holder, list = list, count = count, cap = cap, via = via }, nil
end

local function probeSide(root, off)
  local mid, holder, list = nil, nil, nil
  pcall(function() mid = readQword(root + off) end)
  if gamePtr(mid) and not inAcsModule(mid) then
    pcall(function() holder = readQword(mid) end)
  end
  if not gamePtr(holder) then
    pcall(function() holder = readQword(root + off) end) -- L1 fallback
  end
  local count, cap = -1, -1
  if gamePtr(holder) then
    pcall(function() list = readQword(holder + 0x40) end)
    count = ru16(holder + 0x4A) or -1
    cap = ru16(holder + 0x48) or -1
  end
  return {
    off = off, mid = mid or 0, holder = holder or 0, list = list or 0,
    count = count, cap = cap,
  }
end

local function holderLooksValid(root)
  local function doubleAt(off, loose)
    local mid = nil
    pcall(function() mid = readQword(root + off) end)
    if not gamePtr(mid) or inAcsModule(mid) then return nil, "mid invalid" end
    local h = nil
    pcall(function() h = readQword(mid) end)
    return tryHolder(h, string.format("L2+0x%X", off), { loose = loose })
  end

  local function singleAt(off, loose)
    local h = nil
    pcall(function() h = readQword(root + off) end)
    return tryHolder(h, string.format("L1+0x%X", off), { loose = loose })
  end

  -- Unlocker writes ONLY mainstruct+188 (0xBC). Prefer that path even when
  -- entries look imperfect; +0x150 is a fallback / mirror target.
  local bc = probeSide(root, 0xBC)
  local s150 = probeSide(root, 0x150)
  -- #region agent log
  agent_log("A", "holderLooksValid", "probe_sides", {
    bcMid = bc.mid, bcHolder = bc.holder, bcList = bc.list, bcCount = bc.count, bcCap = bc.cap,
    s150Mid = s150.mid, s150Holder = s150.holder, s150List = s150.list,
    s150Count = s150.count, s150Cap = s150.cap,
  })
  -- #endregion

  local why = nil
  local m, err = doubleAt(0xBC, true)
  if m then
    ACS_Gear._altHolder = nil
    local alt = doubleAt(0x150, false)
    if alt and alt.holder ~= m.holder then ACS_Gear._altHolder = alt end
    return m, nil
  end
  why = err or why
  m, err = singleAt(0xBC, true)
  if m then
    ACS_Gear._altHolder = nil
    return m, nil
  end
  if err then why = err end

  m, err = doubleAt(0x150, false)
  if m then
    -- #region agent log
    agent_log("A", "holderLooksValid", "fallback_150", {why = tostring(why or ""), count = m.count})
    -- #endregion
    return m, nil
  end
  why = err or why
  m, err = singleAt(0x150, false)
  if m then return m, nil end
  if err then why = err end
  return nil, why or "holder @[+0xBC/+0x150] not ready"
end

function ACS_Gear.bindRoot(root)
  root = math.floor(tonumber(root) or 0)
  if root == 0 then return false, "bad root" end
  local meta, err = holderLooksValid(root)
  if not meta then return false, err end
  ACS_Gear.root = root
  ACS_Gear.holder = meta.holder
  ACS_Gear.via = meta.via
  -- #region agent log
  agent_log("H4", "bindRoot", "ok", {
    root = root, holder = meta.holder, via = tostring(meta.via),
    count = meta.count, cap = meta.cap,
  })
  -- #endregion
  pcall(unregisterSymbol, "acsGearRoot")
  pcall(registerSymbol, "acsGearRoot", root)
  pcall(unregisterSymbol, "mainstruct")
  pcall(registerSymbol, "mainstruct", root)
  return true, meta
end

function ACS_Gear.resolveRoot()
  ACS_Gear.root = nil
  ACS_Gear.holder = nil
  ACS_Gear.growBuf = nil
  ACS_Gear.lastErr = nil

  -- #region agent log
  agent_log("G3", "resolveRoot", "begin", {})
  -- #endregion
  if type(processMessages) == "function" then pcall(processMessages) end

  local aob = scanModuleAob(MANAGER_AOB)
  -- #region agent log
  agent_log("G3", "resolveRoot", "aob_done", {aob=aob or 0})
  -- #endregion
  if not aob then
    ACS_Gear.lastErr = "gear manager AOB missing — attach ACS.exe and stand in open world"
    return false, ACS_Gear.lastErr
  end

  local disp = readInteger(aob + 6)
  if not disp then
    ACS_Gear.lastErr = "failed to read lea displacement @ manager+6"
    return false, ACS_Gear.lastErr
  end
  local head = (aob + 0x0A) + disp
  ACS_Gear.managerAob = aob
  ACS_Gear.head = head
  -- #region agent log
  agent_log("G3", "resolveRoot", "head", {head=head})
  -- #endregion

  if type(processMessages) == "function" then pcall(processMessages) end
  local candidates = scanQwordWritableAll(head, 24)
  -- #region agent log
  agent_log("G3", "resolveRoot", "candidates", {n=#candidates, head=head})
  -- #endregion
  if #candidates == 0 then
    ACS_Gear.lastErr = string.format(
      "gearRoot (ptr to %X) not found — be in-world; open pause/gear menu once",
      math.floor(head))
    return false, ACS_Gear.lastErr
  end

  local root, meta, why = nil, nil, nil
  for _, cand in ipairs(candidates) do
    local m, err = holderLooksValid(cand)
    -- #region agent log
    agent_log("G3", "resolveRoot", "candidate", {
      root=cand, ok=m ~= nil, err=tostring(err or ""),
    })
    -- #endregion
    if m then
      root, meta = cand, m
      break
    end
    why = err
  end

  if not root then
    ACS_Gear.lastErr = string.format(
      "holder @[%X] invalid (%s) — open world / gear menu, retry",
      math.floor(candidates[1] or 0), tostring(why or "?"))
    return false, ACS_Gear.lastErr
  end

  ACS_Gear.root = root
  ACS_Gear.holder = meta.holder
  ACS_Gear.via = meta.via
  -- #region agent log
  agent_log("G3", "resolveRoot", "picked", {
    root=root, holder=meta.holder, via=tostring(meta.via),
    count=meta.count, cap=meta.cap,
  })
  -- #endregion
  pcall(unregisterSymbol, "acsGearRoot")
  pcall(registerSymbol, "acsGearRoot", root)
  pcall(unregisterSymbol, "mainstruct")
  pcall(registerSymbol, "mainstruct", root)
  return true, root
end

local function ownershipList()
  local holder = ACS_Gear.holder
  if not holder then return nil end
  local list = rq(holder + 0x40)
  local count = ru16(holder + 0x4A)
  local cap = ru16(holder + 0x48)
  if not list or count == nil or cap == nil then return nil end
  return list, count, cap, holder
end

local function seedDefCacheFromOwnership()
  local list, count = ownershipList()
  if not list or not count or count <= 0 then return 0 end
  local n = 0
  for i = 0, math.min(count, 4000) - 1 do
    local item = nil
    pcall(function() item = readQword(list + 8 * i) end)
    if item and looksLikeDefNode(item) then
      local h = hashAtNode(item)
      if h then
        ACS_Gear._defCache[h] = item
        n = n + 1
      end
    end
  end
  -- #region agent log
  agent_log("G1", "seedDefCache", "done", {seeded = n, count = count})
  -- #endregion
  return n
end

ACS_Gear._defCache = ACS_Gear._defCache or {}

function ACS_Gear.findDefNode(hashLe)
  local key = tostring(hashLe or ""):gsub("%s+", ""):upper()
  if ACS_Gear._defCache[key] and looksLikeDefNode(ACS_Gear._defCache[key], key) then
    -- #region agent log
    agent_log("G1", "findDefNode", "cache_hit", {hash=key, node=ACS_Gear._defCache[key]})
    -- #endregion
    return ACS_Gear._defCache[key]
  end

  seedDefCacheFromOwnership()
  if ACS_Gear._defCache[key] and looksLikeDefNode(ACS_Gear._defCache[key], key) then
    -- #region agent log
    agent_log("G1", "findDefNode", "seed_hit", {hash=key, node=ACS_Gear._defCache[key]})
    -- #endregion
    return ACS_Gear._defCache[key]
  end

  -- Build expected 12 bytes at node+0x0C: 01 00 00 80 + LE hash
  local want = { 1, 0, 0, 0x80 }
  for i = 1, 16, 2 do
    want[#want + 1] = tonumber(key:sub(i, i + 1), 16) or 0
  end

  local t0 = os.clock()
  -- #region agent log
  agent_log("H5", "findDefNode", "chunk_begin", {hash=key})
  -- #endregion

  -- NO MemScan / AOBScan — both hard-crashed ByteEngine (0xC0000005) from UI.
  -- Prefer tight windows around known ownership defs; avoid multi-minute scans.
  local ranges = {
    { 0x09A00000, 0x09C00000 },
  }
  for _, n in pairs(ACS_Gear._defCache) do
    if type(n) == "number" and n > 0x10000 then
      local lo = math.max(0x10000, n - 0x80000)
      local hi = n + 0x80000
      ranges[#ranges + 1] = { lo, hi }
    end
  end

  local node, hit = nil, nil
  local chunk = 0x1000
  local deadline = (t0 or 0) + 3.0
  for _, rg in ipairs(ranges) do
    if node then break end
    if (os.clock() or 0) > deadline then break end
    local a = rg[1] - (rg[1] % 4)
    while a < rg[2] and not node do
      if (os.clock() or 0) > deadline then break end
      if type(processMessages) == "function" then pcall(processMessages) end
      local probeOk = pcall(readQword, a)
      if probeOk then
        local ok, bytes = pcall(readBytes, a, chunk, true)
        if ok and type(bytes) == "table" and #bytes >= 12 then
          local limit = #bytes - 12
          local i = 1
          while i <= limit do
            local match = true
            for k = 1, 12 do
              if bytes[i + k - 1] ~= want[k] then match = false break end
            end
            if match then
              local h = a + (i - 1)
              local cand = h - 0x0C
              if looksLikeDefNode(cand, key) and not inAcsModule(cand) then
                hit, node = h, cand
                break
              end
            end
            i = i + 4
          end
        end
      end
      a = a + chunk
    end
  end

  local elapsedMs = math.floor(((os.clock() or 0) - (t0 or 0)) * 1000)
  if not node then
    -- #region agent log
    agent_log("G1", "findDefNode", "aob_miss", {hash=key, elapsedMs=elapsedMs})
    -- #endregion
    return nil
  end
  ACS_Gear._defCache[key] = node
  -- #region agent log
  agent_log("G1", "findDefNode", "aob_hit", {hash=key, hit=hit, node=node, elapsedMs=elapsedMs})
  -- #endregion
  return node
end

local function appendToHolder(holder, via, node, growKey)
  local list = nil
  pcall(function() list = readQword(holder + 0x40) end)
  local count = ru16(holder + 0x4A)
  local cap = ru16(holder + 0x48)
  if not list or count == nil or cap == nil or inAcsModule(list) then
    return false, "list_bad", { via = via, list = list or 0, count = count or -1, cap = cap or -1 }
  end
  if listContains(list, count, node) then
    return true, "already_owned", { via = via, count = count, cap = cap, node = node }
  end
  if count == cap then
    local gk = growKey or "growBuf"
    if not ACS_Gear[gk] then
      local buf = allocateMemory(count * 8 + 976)
      if not buf or buf == 0 then
        return false, "alloc_fail", { via = via, count = count }
      end
      ACS_Gear[gk] = buf + 16
      pcall(unregisterSymbol, "acsGearGrow")
      pcall(registerSymbol, "acsGearGrow", ACS_Gear[gk])
    end
    if not copyMemory(ACS_Gear[gk], list, count * 8) then
      return false, "copy_fail", { via = via }
    end
    writeQword(holder + 0x40, ACS_Gear[gk])
    writeSmallInteger(holder + 0x48, cap + 10)
    list = ACS_Gear[gk]
  end
  local wOk = pcall(writeQword, list + 8 * count, node)
  local cOk = pcall(writeSmallInteger, holder + 0x4A, count + 1)
  local newCount = ru16(holder + 0x4A)
  local verify = nil
  do
    local okv, v = pcall(readQword, list + 8 * count)
    if okv then verify = v end
  end
  local ok = wOk and cOk and verify == node and newCount == count + 1
  return ok, ok and "appended" or "write_fail", {
    via = via, list = list, countBefore = count, cap = cap,
    newCount = newCount or -1, verify = verify or 0, node = node,
    wOk = wOk and true or false, cOk = cOk and true or false,
  }
end

function ACS_Gear.grant(entry)
  -- #region agent log
  agent_log("G2", "grant", "enter", {
    name=entry and entry.name or "?",
    cat=entry and entry.cat or "?",
    hash=entry and entry.hash_le or "?",
    hasRoot=ACS_Gear.root ~= nil,
    hasHolder=ACS_Gear.holder ~= nil,
  })
  -- #endregion
  if not entry or not GRANTABLE[entry.cat] then
    return false, "not a grantable gear item", "blocked"
  end
  if not ACS_Gear.root or not ACS_Gear.holder then
    local ok, err = ACS_Gear.resolveRoot()
    if not ok then return false, err, "no_root" end
  end

  -- Prefer rebinding via unlocker +0xBC when possible (not sticky on +0x150).
  do
    if ACS_Gear.root then
      local sides = { probeSide(ACS_Gear.root, 0xBC), probeSide(ACS_Gear.root, 0x150) }
      -- #region agent log
      agent_log("A", "grant", "sides", {
        bcCount = sides[1].count, bcHolder = sides[1].holder,
        s150Count = sides[2].count, s150Holder = sides[2].holder,
        via = tostring(ACS_Gear.via or ""),
      })
      -- #endregion
      local metaBC = tryHolder(sides[1].holder, "L2+0xBC", { loose = true })
      if metaBC then
        ACS_Gear.holder = metaBC.holder
        ACS_Gear.via = metaBC.via
        local meta150 = tryHolder(sides[2].holder, "L2+0x150", { loose = true })
        if meta150 and meta150.holder ~= metaBC.holder then
          ACS_Gear._altHolder = meta150
        else
          ACS_Gear._altHolder = nil
        end
      end
    end
    -- #region agent log
    agent_log("H5", "grant", "revalidate_begin", {
      via = tostring(ACS_Gear.via or ""), holder = ACS_Gear.holder or 0,
    })
    -- #endregion
    local loose = tostring(ACS_Gear.via or ""):find("0xBC", 1, true) ~= nil
    local meta, err = tryHolder(ACS_Gear.holder, tostring(ACS_Gear.via or "held"), { loose = loose })
    if not meta then
      ACS_Gear.holder = nil
      local ok2, err2 = ACS_Gear.resolveRoot()
      if not ok2 then return false, err or err2 or "gear list not ready — open in-game gear menu", "no_holder" end
      meta, err = tryHolder(ACS_Gear.holder, tostring(ACS_Gear.via or "held"), { loose = true })
      if not meta then return false, err or "gear list not ready", "no_holder" end
    end
    ACS_Gear.holder = meta.holder
    ACS_Gear.via = meta.via
    -- #region agent log
    agent_log("H5", "grant", "revalidate_ok", {via = tostring(meta.via), list = meta.list, count = meta.count})
    -- #endregion
  end

  -- #region agent log
  agent_log("H5", "grant", "before_findDef", {hash = entry.hash_le})
  -- #endregion
  local node = ACS_Gear.findDefNode(entry.hash_le)
  -- #region agent log
  agent_log("H5", "grant", "after_findDef", {node = node or 0})
  -- #endregion
  if not node or not looksLikeDefNode(node, entry.hash_le) then
    -- #region agent log
    agent_log("G1", "grant", "def_missing", {name=entry.name, hash=entry.hash_le, node=node or 0})
    -- #endregion
    return false, "definition not loaded — open gear/crafting UI once (defs must be in heap)", "def_missing"
  end

  local okPrimary, kindPrimary, infoPrimary = appendToHolder(
    ACS_Gear.holder, tostring(ACS_Gear.via or "primary"), node, "growBuf")
  -- #region agent log
  agent_log("G5", "grant", kindPrimary or "primary", {
    name = entry.name, via = infoPrimary and infoPrimary.via or "",
    countBefore = infoPrimary and infoPrimary.countBefore or infoPrimary and infoPrimary.count or -1,
    newCount = infoPrimary and infoPrimary.newCount or -1,
    wOk = infoPrimary and infoPrimary.wOk, cOk = infoPrimary and infoPrimary.cOk,
    verify = infoPrimary and infoPrimary.verify or 0, node = node,
  })
  -- #endregion

  local kindAlt = nil
  if ACS_Gear._altHolder and ACS_Gear._altHolder.holder and ACS_Gear._altHolder.holder ~= ACS_Gear.holder then
    local okAlt, kAlt, infoAlt = appendToHolder(
      ACS_Gear._altHolder.holder, tostring(ACS_Gear._altHolder.via or "alt"), node, "growBufAlt")
    kindAlt = kAlt
    -- #region agent log
    agent_log("A", "grant", "alt_" .. tostring(kAlt), {
      name = entry.name, via = infoAlt and infoAlt.via or "",
      newCount = infoAlt and infoAlt.newCount or -1, ok = okAlt and true or false,
    })
    -- #endregion
  end

  if kindPrimary == "appended" then
    return true, string.format("APPENDED via %s → count %s", tostring(ACS_Gear.via), tostring(infoPrimary.newCount)), "appended"
  end
  if kindPrimary == "already_owned" then
    return true, "already owned (" .. tostring(ACS_Gear.via) .. ")", "already_owned"
  end
  if kindAlt == "appended" then
    return true, "APPENDED via alt list", "appended"
  end
  return false, tostring(kindPrimary or "write_fail"), kindPrimary or "write_fail"
end

function ACS_Gear.grantCategory(cat)
  local appended, owned, badN = 0, 0, 0
  local firstErr = nil
  for _, e in ipairs(CATALOG) do
    if e.cat == cat and GRANTABLE[e.cat] then
      local ok, info, kind = ACS_Gear.grant(e)
      if kind == "appended" then appended = appended + 1
      elseif kind == "already_owned" or (ok and tostring(info or ""):find("already", 1, true)) then
        owned = owned + 1
      else
        badN = badN + 1
        firstErr = firstErr or info
      end
    end
  end
  return appended, badN, firstErr, owned
end

function ACS_Gear.grantAll()
  local appended, owned, badN = 0, 0, 0
  local firstErr = nil
  if not ACS_Gear.root then
    local ok, err = ACS_Gear.resolveRoot()
    if not ok then return 0, 0, err, 0 end
  end
  for _, e in ipairs(CATALOG) do
    if GRANTABLE[e.cat] then
      local ok, info, kind = ACS_Gear.grant(e)
      if kind == "appended" then appended = appended + 1
      elseif kind == "already_owned" or (ok and tostring(info or ""):find("already", 1, true)) then
        owned = owned + 1
      else
        badN = badN + 1
        firstErr = firstErr or info
      end
      if type(processMessages) == "function" then pcall(processMessages) end
    end
  end
  return appended, badN, firstErr, owned
end

-- Runtime evidence: on this ACS build mainstruct+0xBC is garbage while the real
-- owned list lives at +0x150 (often polluted with family-0x45 linked fragments).
-- Grant All then reports NEW=0 / already=N because hashes are already in +0x150,
-- but the in-game gear UI still follows the unlocker +0xBC path and sees nothing.
-- Repair: wire +0xBC -> same mid as +0x150, rebuild a clean grantable-only list.
function ACS_Gear.repairForUi()
  if not ACS_Gear.root then
    local ok, err = ACS_Gear.resolveRoot()
    if not ok then return false, err end
  end
  local root = ACS_Gear.root
  local beforeBc = probeSide(root, 0xBC)
  local before150 = probeSide(root, 0x150)
  -- #region agent log
  agent_log("F", "repairForUi", "before", {
    bcMid = beforeBc.mid, bcCount = beforeBc.count,
    s150Mid = before150.mid, s150Count = before150.count, s150Holder = before150.holder,
  })
  -- #endregion

  local mid150 = nil
  pcall(function() mid150 = readQword(root + 0x150) end)
  if not gamePtr(mid150) or inAcsModule(mid150) then
    return false, "+0x150 mid missing — open gear menu once, Retry Resolve"
  end
  local holder = nil
  pcall(function() holder = readQword(mid150) end)
  local meta, err = tryHolder(holder, "repair+0x150", { loose = true })
  if not meta then return false, err or "holder invalid" end
  ACS_Gear.holder = meta.holder
  ACS_Gear.via = "L2+0x150+repair"

  -- Wire unlocker path (+0xBC) to the live mid used by +0x150.
  local bcMidNow = nil
  pcall(function() bcMidNow = readQword(root + 0xBC) end)
  local wired = false
  if not gamePtr(bcMidNow) or inAcsModule(bcMidNow) or bcMidNow ~= mid150 then
    local wOk = pcall(writeQword, root + 0xBC, mid150)
    wired = wOk and true or false
    -- #region agent log
    agent_log("F", "repairForUi", "wire_bc", {
      wOk = wired, mid150 = mid150, oldBc = bcMidNow or 0,
    })
    -- #endregion
  end

  -- Collect clean grantable def nodes (skip Live linked fragments).
  seedDefCacheFromOwnership()
  local nodes, seen = {}, {}
  for _, e in ipairs(CATALOG) do
    if GRANTABLE[e.cat] then
      local node = ACS_Gear.findDefNode(e.hash_le)
      if node and looksLikeDefNode(node, e.hash_le) and not seen[node] then
        seen[node] = true
        nodes[#nodes + 1] = node
      end
    end
  end
  if #nodes < 8 then
    return false, string.format("only found %d grantable defs — open gear/forge UI once", #nodes)
  end

  local need = #nodes
  local cap = math.max(need + 32, 128)
  local buf = allocateMemory(cap * 8 + 976)
  if not buf or buf == 0 then return false, "allocateMemory failed" end
  local newList = buf + 16
  for i, node in ipairs(nodes) do
    writeQword(newList + 8 * (i - 1), node)
  end
  writeQword(meta.holder + 0x40, newList)
  writeSmallInteger(meta.holder + 0x48, cap)
  writeSmallInteger(meta.holder + 0x4A, need)
  ACS_Gear.growBuf = newList
  pcall(unregisterSymbol, "acsGearGrow")
  pcall(registerSymbol, "acsGearGrow", newList)

  local afterBc = probeSide(root, 0xBC)
  local after150 = probeSide(root, 0x150)
  -- #region agent log
  agent_log("F", "repairForUi", "after", {
    wired = wired, cleanN = need, cap = cap, newList = newList,
    bcCount = afterBc.count, bcHolder = afterBc.holder,
    s150Count = after150.count, via = tostring(ACS_Gear.via),
  })
  -- #endregion

  local msg = string.format(
    "Repaired: %d/%d gear hashes now in owned list (second number is list CAPACITY / spare room, not missing unlocks). BC wired=%s. Re-open in-game Gear menu.",
    need, cap, tostring(wired))
  return true, msg
end

-- Unlocker skill points: [[mainstruct+188]+0]+0x11C == holder+0x11C
function ACS_Gear.getSkillPoints()
  if not ACS_Gear.holder then return nil end
  local ok, v = pcall(readInteger, ACS_Gear.holder + 0x11C)
  if ok then return v end
  return nil
end

function ACS_Gear.setSkillPoints(n)
  n = math.floor(tonumber(n) or 0)
  if n < 0 then n = 0 end
  if n > 999999 then n = 999999 end
  if not ACS_Gear.holder then
    local ok, err = ACS_Gear.resolveRoot()
    if not ok then return false, err end
  end
  local addr = ACS_Gear.holder + 0x11C
  local before = ACS_Gear.getSkillPoints()
  local wOk = pcall(writeInteger, addr, n)
  local after = ACS_Gear.getSkillPoints()
  -- #region agent log
  agent_log("S", "setSkillPoints", "done", {
    wOk = wOk and true or false, before = before or -1, after = after or -1, want = n,
  })
  -- #endregion
  if not wOk then return false, "write failed" end
  return true, after
end

function ACS_Gear.fillInventory()
  if type(ACS_Inv) ~= "table" or type(ACS_Inv.setQty) ~= "function" then
    -- lazy-load inventory editor if present beside this script
    pcall(function()
      local paths = {
        [[tables\ACS_ForgeKit\inventory_editor.lua]],
        [[tables\ACS_ForgeKit\inventory_editor.lua]],
        [[tables\ACS_ForgeKit\inventory_editor.lua]],
      }
      for _, p in ipairs(paths) do
        local f = io.open(p, "r")
        if f then
          local src = f:read("*a"); f:close()
          local fn, err = loadstring(src, p)
          if fn then fn() break end
        end
      end
    end)
  end
  if type(ACS_Inv) ~= "table" then
    return 0, "inventory_editor not loaded — open Inventory Desk once"
  end
  if type(ACS_Inv.resolve) == "function" then pcall(ACS_Inv.resolve) end
  local n = 0
  local ids = {1, 5, 8, 9, 0xA, 0xE, 0x2B, 0x2C, 0x2D, 0x38, 0x39, 0x3A, 0x3C}
  for _, id in ipairs(ids) do
    local ok = false
    pcall(function() ok = ACS_Inv.setQty(id, 9999, true) end)
    if ok then n = n + 1 end
  end
  -- #region agent log
  agent_log("S", "fillInventory", "done", {filled = n})
  -- #endregion
  return n, nil
end

-- One-shot: everything we can do with known runtime paths.
-- Gang borough upgrades / perk trees / map fog are NOT gear hashes — those
-- need separate live RE (not missing from the 175 gear list).
function ACS_Gear.unlockEverything()
  local lines = {}
  local function add(s) lines[#lines + 1] = s end

  if not ACS_Gear.root then
    local ok, err = ACS_Gear.resolveRoot()
    if not ok then return false, tostring(err) end
  end

  local rok, rinfo = ACS_Gear.repairForUi()
  add(rok and ("GEAR LIST: " .. tostring(rinfo)) or ("GEAR LIST FAIL: " .. tostring(rinfo)))

  local appended, badN, err, owned = ACS_Gear.grantAll()
  add(string.format("GEAR GRANT: NEW=%d already=%d fail=%d (catalog gear=%d)",
    appended or 0, owned or 0, badN or 0, (appended or 0) + (owned or 0)))
  if err and (badN or 0) > 0 then add("  firstErr: " .. tostring(err)) end

  local sok, sk = ACS_Gear.setSkillPoints(999)
  add(sok and ("SKILL POINTS: set to " .. tostring(sk)) or ("SKILL POINTS FAIL: " .. tostring(sk)))

  local filled, ierr = ACS_Gear.fillInventory()
  add(string.format("INVENTORY/CRAFT MATS: filled %d stacks @9999%s",
    filled or 0, ierr and (" (" .. tostring(ierr) .. ")") or ""))

  add("")
  add("NOT in gear list (separate systems — next RE pass):")
  add("  - Gang / borough / stronghold upgrades")
  add("  - Perk tree completion flags")
  add("  - Map fog / world unlock tables")
  add("  - Crafting PLAN unlocks (beyond maxing mats)")
  add("175/207 on status = owned/capacity, NOT 32 missing items.")

  -- #region agent log
  agent_log("S", "unlockEverything", "done", {
    appended = appended or 0, owned = owned or 0, badN = badN or 0,
    skill = sk or -1, invFilled = filled or 0, repairOk = rok and true or false,
  })
  -- #endregion
  return true, table.concat(lines, "\n")
end

local function catOrder()
  local out, seen = {}, {}
  for _, e in ipairs(CATALOG) do
    if GRANTABLE[e.cat] and not seen[e.cat] then
      seen[e.cat] = true
      out[#out + 1] = e.cat
    end
  end
  return out
end

------------------------------------------------------------------
-- GUI (Byte Engine Inventory Desk twin)
------------------------------------------------------------------

local function safeClick(fn)
  return function(...)
    local ok, err = pcall(fn, ...)
    if not ok then
      local msg = tostring(err)
      print("[Gear Desk] " .. msg)
      pcall(showMessage, "Gear Desk error:\n" .. msg)
    end
  end
end

local function buildForm()
  local f = createForm(false)
  f.Caption = "ACS Forge — Gear Desk"
  f.Width = 640
  f.Height = 560
  pcall(function() f.Position = "poScreenCenter" end)
  pcall(function() f.BorderStyle = "bsSizeable" end)

  local title = createLabel(f)
  title.Caption = "Gear Desk  (weapons / armor / outfits)"
  title.Left = 16
  title.Top = 12
  pcall(function() title.Font.Size = 14 end)

  local status = createLabel(f)
  status.Left = 16
  status.Top = 40
  status.Width = 600
  status.Height = 36
  local function setStatus(s) status.Caption = "Status: " .. (s or "") end

  local cats = catOrder()
  local catBox = createComboBox(f)
  catBox.Left = 16
  catBox.Top = 84
  catBox.Width = 220
  -- Do NOT set Style=csDropDownList — BE marks TComboBox.Style unimplemented and throws.
  for _, c in ipairs(cats) do
    pcall(function() catBox.Items.add(c) end)
  end
  if #cats > 0 then pcall(function() catBox.ItemIndex = 0 end) end

  local list = createListBox(f)
  list.Left = 16
  list.Top = 120
  list.Width = 600
  list.Height = 320

  local rows = {}
  local function currentCat()
    local i = tonumber(catBox.ItemIndex) or 0
    if i < 0 then i = 0 end
    -- BE stringlists are not indexable with [n]; use getString / Lua table.
    if type(catBox.Items.getString) == "function" then
      local s = catBox.Items.getString(i)
      if s and s ~= "" then return s end
    end
    return cats[i + 1]
  end

  local function refill()
    pcall(function() list.Items.clear() end)
    rows = {}
    local cat = currentCat()
    for _, e in ipairs(CATALOG) do
      if e.cat == cat then
        rows[#rows + 1] = e
        pcall(function()
          list.Items.add(string.format("%s    %s", e.name, e.id))
        end)
      end
    end
    setStatus(string.format("%s — %d entries", tostring(cat), #rows))
  end
  catBox.OnChange = safeClick(refill)

  local function doResolve(silent)
    setStatus("Auto-resolving gear root…")
    if type(processMessages) == "function" then pcall(processMessages) end
    local ok, info = ACS_Gear.resolveRoot()
    if ok then
      local _, cnt, cap = ownershipList()
      local bc = probeSide(ACS_Gear.root, 0xBC)
      local bcOk = gamePtr(bc.mid) and (bc.count or -1) >= 0
      -- #region agent log
      agent_log("G3", "resolveRoot", "ok", {
        root=ACS_Gear.root or 0, holder=ACS_Gear.holder or 0,
        count=cnt or -1, cap=cap or -1, silent=silent and true or false,
        via=tostring(ACS_Gear.via or ""), bcOk=bcOk and true or false, bcCount=bc.count or -1,
      })
      -- #endregion
      setStatus(string.format("Ready — gear owned %s of %s  (list capacity %s = spare room, not missing)  via=%s",
        tostring(cnt), tostring(cnt), tostring(cap), tostring(ACS_Gear.via or "?")))
      return true
    end
    -- #region agent log
    agent_log("G3", "resolveRoot", "fail", {err=tostring(info), silent=silent and true or false})
    -- #endregion
    setStatus("Auto-resolve failed: " .. tostring(info))
    if not silent then showMessage(tostring(info)) end
    return false
  end

  local btnResolve = createButton(f)
  btnResolve.Caption = "Retry Resolve"
  btnResolve.Left = 250
  btnResolve.Top = 82
  btnResolve.Width = 110
  btnResolve.OnClick = safeClick(function() doResolve(false) end)

  local btnRepair = createButton(f)
  btnRepair.Caption = "Repair UI List"
  btnRepair.Left = 370
  btnRepair.Top = 82
  btnRepair.Width = 110
  btnRepair.OnClick = safeClick(function()
    if not ACS_Gear.root then doResolve(true) end
    setStatus("Repairing owned list + wiring +0xBC…")
    -- #region agent log
    agent_log("F", "ui", "repair_click", {})
    -- #endregion
    local ok, info = ACS_Gear.repairForUi()
    -- #region agent log
    agent_log("F", "ui", "repair_done", {ok = ok and true or false, info = tostring(info or "")})
    -- #endregion
    setStatus(tostring(info))
    showMessage(tostring(info))
    if ok then doResolve(true) end
  end)

  local btnAllSystems = createButton(f)
  btnAllSystems.Caption = "UNLOCK EVERYTHING"
  btnAllSystems.Left = 490
  btnAllSystems.Top = 82
  btnAllSystems.Width = 130
  btnAllSystems.OnClick = safeClick(function()
    setStatus("Unlocking everything known…")
    if type(processMessages) == "function" then pcall(processMessages) end
    -- #region agent log
    agent_log("S", "ui", "unlock_everything_click", {})
    -- #endregion
    local ok, info = ACS_Gear.unlockEverything()
    -- #region agent log
    agent_log("S", "ui", "unlock_everything_done", {ok = ok and true or false})
    -- #endregion
    setStatus((tostring(info or "")):gsub("\n", " | "):sub(1, 180))
    showMessage(tostring(info))
    doResolve(true)
  end)

  local btnOne = createButton(f)
  btnOne.Caption = "Grant Selected"
  btnOne.Left = 16
  btnOne.Top = 456
  btnOne.Width = 120
  btnOne.OnClick = safeClick(function()
    local i = tonumber(list.ItemIndex) or -1
    if i < 0 or not rows[i + 1] then showMessage("Select an item") return end
    local e = rows[i + 1]
    if not ACS_Gear.root then doResolve(true) end
    -- #region agent log
    agent_log("G2", "ui", "grant_selected_click", {idx=i, name=e.name, hash=e.hash_le})
    -- #endregion
    local ok, info, kind = ACS_Gear.grant(e)
    -- #region agent log
    agent_log("G2", "ui", "grant_selected_result", {
      ok=ok and true or false, kind=tostring(kind or ""), info=tostring(info),
      via=tostring(ACS_Gear.via or ""),
    })
    -- #endregion
    local msg = string.format("%s [%s] via=%s\n%s", e.name, tostring(kind or "?"), tostring(ACS_Gear.via or "?"), tostring(info))
    setStatus(msg:gsub("\n", " | "))
    showMessage(msg)
  end)

  local btnCat = createButton(f)
  btnCat.Caption = "Grant Category"
  btnCat.Left = 150
  btnCat.Top = 456
  btnCat.Width = 120
  btnCat.OnClick = safeClick(function()
    setStatus("Granting category…")
    if type(processMessages) == "function" then pcall(processMessages) end
    if not ACS_Gear.root then doResolve(true) end
    local cat = currentCat()
    -- #region agent log
    agent_log("G2", "ui", "grant_category_start", {cat=tostring(cat)})
    -- #endregion
    local appended, badN, err, owned = ACS_Gear.grantCategory(cat)
    -- #region agent log
    agent_log("G2", "ui", "grant_category_done", {
      appended=appended, owned=owned or 0, badN=badN, err=tostring(err or ""),
      via=tostring(ACS_Gear.via or ""),
    })
    -- #endregion
    local msg = string.format("%s: NEW=%d already=%d fail=%d via=%s",
      tostring(cat), appended, owned or 0, badN, tostring(ACS_Gear.via or "?"))
    if err then msg = msg .. " | " .. tostring(err) end
    setStatus(msg)
    showMessage(msg)
  end)

  local btnAll = createButton(f)
  btnAll.Caption = "Grant All"
  btnAll.Left = 284
  btnAll.Top = 456
  btnAll.Width = 100
  btnAll.OnClick = safeClick(function()
    setStatus("Granting all (open gear menu once first)…")
    if type(processMessages) == "function" then pcall(processMessages) end
    if not ACS_Gear.root then doResolve(true) end
    -- #region agent log
    agent_log("G2", "ui", "grant_all_start", {hasRoot=ACS_Gear.root ~= nil})
    -- #endregion
    local appended, badN, err, owned = ACS_Gear.grantAll()
    -- #region agent log
    agent_log("G2", "ui", "grant_all_done", {
      appended=appended, owned=owned or 0, badN=badN, err=tostring(err or ""),
      via=tostring(ACS_Gear.via or ""),
    })
    -- #endregion
    local msg = string.format("ALL: NEW=%d already=%d fail=%d\nvia=%s",
      appended, owned or 0, badN, tostring(ACS_Gear.via or "?"))
    if err then msg = msg .. "\n" .. tostring(err) end
    setStatus(msg:gsub("\n", " | "))
    showMessage(msg)
  end)

  local tip = createLabel(f)
  tip.Caption = "175/207 = owned/capacity (spare slots). UNLOCK EVERYTHING = gear+skills+mats. Gang/perks/map = separate RE."
  tip.Left = 16
  tip.Top = 492
  tip.Width = 600

  f.OnClose = function() return caHide end
  ACS_ForgeGear.form = f
  refill()
  setStatus("Opening — auto-resolve starts next tick…")
  pcall(function() f.Visible = true end)
  if type(f.Show) == "function" then pcall(function() f.Show() end) end

  -- Defer so the form paints before the (slow) AOB walk.
  local autoStarted = false
  local retryN = 0
  local kick = nil
  local retry = nil
  if type(createTimer) == "function" then
    kick = createTimer(f)
  end
  if kick then
    kick.Interval = 80
    kick.OnTimer = function(tm)
      if autoStarted then
        pcall(function() tm.Enabled = false end)
        return
      end
      autoStarted = true
      pcall(function() tm.Enabled = false end)
      pcall(function() if type(tm.destroy) == "function" then tm.destroy() end end)
      -- #region agent log
      agent_log("G0", "ui", "auto_resolve_kick", {})
      -- #endregion
      local ok = false
      pcall(function() ok = doResolve(true) end)
      if not ok and type(createTimer) == "function" then
        retry = createTimer(f)
        if retry then
          retry.Interval = 1500
          retry.OnTimer = function(rt)
            if ACS_Gear.holder then
              pcall(function() rt.Enabled = false end)
              return
            end
            retryN = retryN + 1
            if retryN > 40 then
              pcall(function() rt.Enabled = false end)
              setStatus("Still waiting on gear list — open in-game Gear/Forge UI, then Retry Resolve")
              return
            end
            -- #region agent log
            agent_log("H3", "ui", "auto_resolve_retry", {n = retryN})
            -- #endregion
            pcall(doResolve, true)
          end
          pcall(function() retry.Enabled = true end)
        end
      end
    end
    pcall(function() kick.Enabled = true end)
  else
    pcall(doResolve, true)
  end
end

ACS_ForgeGear.open = buildForm
if not ACS_Progress_silentLoad then
  buildForm()
end
