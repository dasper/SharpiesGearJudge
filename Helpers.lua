local addonName, MSC = ...
_G.MSC = MSC 

-- [[ SPEED OPTIMIZATION: LOCALIZED FUNCTIONS ]]
local _G = _G
local type, pairs, ipairs, unpack, pcall, select = type, pairs, ipairs, unpack, pcall, select
local tonumber, tostring, next = tonumber, tostring, next
local math_floor, math_abs, math_max, math_min, math_sqrt = math.floor, math.abs, math.max, math.min, math.sqrt
local string_find, string_match, string_lower, string_upper, string_gsub, string_format, string_sub = string.find, string.match, string.lower, string.upper, string.gsub, string.format, string.sub
local table_insert, table_concat, table_remove, table_sort = table.insert, table.concat, table.remove, table.sort
local wipe = wipe or table.wipe
local strsplit = strsplit

-- WoW APIs
local CreateFrame = CreateFrame
local WorldFrame = WorldFrame
local GetItemInfo = GetItemInfo
local UnitClass = UnitClass
local UnitLevel = UnitLevel
local UnitRace = UnitRace
local UnitStat = UnitStat
local UnitDefense = UnitDefense
local GetInventoryItemLink = GetInventoryItemLink
local GetItemStats = GetItemStats

-- Era/Classic Specifics
local GetHitModifier = GetHitModifier
local GetSpellHitModifier = GetSpellHitModifier
local GetCritChance = GetCritChance
local GetSpellCritChance = GetSpellCritChance
local GetSpellBonusHealing = GetSpellBonusHealing
local GetSpellBonusDamage = GetSpellBonusDamage

-- TBC/Retail Specifics
local GetCombatRating = GetCombatRating
local C_Container = C_Container
local GetContainerItemInfo = C_Container and C_Container.GetContainerItemInfo or GetContainerItemInfo

-- =============================================================
-- 1. UTILITY FUNCTIONS
-- =============================================================
function MSC:SafeCopy(orig)
    local original_type = type(orig)
    local copy
    if original_type == 'table' then
        copy = {}
        for orig_key, orig_value in pairs(orig) do
            copy[orig_key] = orig_value
        end
    else
        copy = orig
    end
    return copy
end

-- [[ OPTIMIZATION: CACHE USABILITY ]]
MSC.UsableCache = {} 

function MSC.IsItemUsable(itemLink)
    if not itemLink then return false end
    
    -- Check Cache First
    if MSC.UsableCache[itemLink] ~= nil then return MSC.UsableCache[itemLink] end
    
    local _, _, _, _, _, _, _, _, _, _, _, classID, subClassID = GetItemInfo(itemLink)
    local localizedClass, playerClass = UnitClass("player")
    local result = true -- Default to true, prove false

    -- 1. WEAPON CHECK
    if classID == 2 then 
        if MSC.CurrentClass and MSC.CurrentClass.ValidWeapons then
            if not MSC.CurrentClass.ValidWeapons[subClassID] then result = false end
        end
    end

    -- 2. ARMOR CHECK
    if result and classID == 4 then 
        local level = UnitLevel("player")
        local maxArmor = 1 -- Cloth
        
        if playerClass == "WARRIOR" or playerClass == "PALADIN" then 
            maxArmor = (level >= 40) and 4 or 3
        elseif playerClass == "SHAMAN" or playerClass == "HUNTER" then 
            maxArmor = (level >= 40) and 3 or 2
        elseif playerClass == "ROGUE" or playerClass == "DRUID" then 
            maxArmor = 2 
        end
        
        if subClassID == 6 then -- Shield
            if playerClass ~= "WARRIOR" and playerClass ~= "PALADIN" and playerClass ~= "SHAMAN" then result = false end
        elseif subClassID == 7 or subClassID == 8 or subClassID == 9 then
            -- Relics: Libram (Paladin), Idol (Druid), Totem (Shaman). Many carry
            -- no "Classes:" line, so the tooltip scan below can't catch them.
            local relicClass = (subClassID == 7 and "PALADIN") or (subClassID == 8 and "DRUID") or "SHAMAN"
            if playerClass ~= relicClass then result = false end
        elseif subClassID > 0 and subClassID <= 4 then
             if subClassID > maxArmor then result = false end
        end
    end

    -- 3. RESTRICTION SCAN (Only runs if passed previous checks)
    if result then
        local tip = _G["MSC_ScannerTooltip"] or CreateFrame("GameTooltip", "MSC_ScannerTooltip", nil, "GameTooltipTemplate")
        tip:SetOwner(WorldFrame, "ANCHOR_NONE"); tip:ClearLines()
        local status = pcall(function() tip:SetHyperlink(itemLink) end)
        
        if status then
            for i = 2, tip:NumLines() do
                local line = _G["MSC_ScannerTooltipTextLeft"..i]
                local text = line and line:GetText()
                if text then
                    if string_find(text, "Classes:") or (ITEM_CLASSES_ALLOWED and string_find(text, string_gsub(ITEM_CLASSES_ALLOWED, "%%s", ""))) then
                        if not string_find(text, localizedClass) then result = false; break end
                    end
                    if string_find(text, "Races:") or (ITEM_RACES_ALLOWED and string_find(text, string_gsub(ITEM_RACES_ALLOWED, "%%s", ""))) then
                          local localizedRace = UnitRace("player")
                          if not string_find(text, localizedRace) then result = false; break end
                    end
                end
            end
        end
    end
    
    -- Save to Cache
    MSC.UsableCache[itemLink] = result
    return result
end

function MSC:IsJewelcrafter()
    -- Allow the user to force this on via settings
    if SGJ_Settings and type(SGJ_Settings.IsJC) == "boolean" then
        return SGJ_Settings.IsJC
    end
    -- Fallback: Scan Professions
    if GetNumSkillLines then
        for i = 1, GetNumSkillLines() do
            local skillName = GetSkillLineInfo(i)
            local localizedJC = MSC.L["Jewelcrafting"] or "Jewelcrafting"
			if skillName and (skillName == localizedJC or string.find(skillName, localizedJC)) then
                return true
            end
        end
    end
    return false
end

-- =============================================================
-- 2. API SHIMS
-- =============================================================
function MSC.getItemID(bagID, slotID)
    if not bagID or not slotID then return nil end
    local itemInfo = GetContainerItemInfo(bagID, slotID)
    if itemInfo then return itemInfo.itemID end
    return nil
end

-- Safely strips WoW 11.5 "secret numbers" (secure variables) from API returns
function MSC.SanitizeStat(val)
    if not val then return 0 end
    if type(val) ~= "number" then return 0 end
    local succ, s = pcall(tostring, val)
    return (succ and tonumber(s)) or 0
end

function MSC:GetPlayerStat(statType)
    local val = 0
    -- Forever gear has Hit Rating, which GetHitModifier() doesn't include.
    if MSC.IsForever and (statType == "HIT" or statType == "SPELL_HIT") and MSC.GetForeverHitPercent then
        return (MSC:GetForeverHitPercent(statType == "HIT" and "MELEE" or "SPELL"))
    end
    if MSC.IsVanillaRules then
        if statType == "HIT" then val = GetHitModifier()
        elseif statType == "SPELL_HIT" then val = MSC.SanitizeStat(GetSpellHitModifier())
        elseif statType == "CRIT" then val = MSC.SanitizeStat(GetCritChance())
        elseif statType == "SPELL_CRIT" then val = MSC.SanitizeStat(GetSpellCritChance(2))
        elseif statType == "DEFENSE" then local b, m = UnitDefense("player"); val = MSC.SanitizeStat(b) + MSC.SanitizeStat(m)
        elseif statType == "HEALING" then val = MSC.SanitizeStat(GetSpellBonusHealing())
        elseif statType == "SPELL_POWER" then val = MSC.SanitizeStat(GetSpellBonusDamage(2))
        end
    else
        if statType == "HIT" then val = GetCombatRating(6)
        elseif statType == "SPELL_HIT" then val = MSC.SanitizeStat(GetCombatRating(8))
        elseif statType == "CRIT" then val = MSC.SanitizeStat(GetCombatRating(9))
        elseif statType == "SPELL_CRIT" then val = MSC.SanitizeStat(GetCombatRating(11))
        elseif statType == "DEFENSE" then local b, m = UnitDefense("player"); val = MSC.SanitizeStat(b) + MSC.SanitizeStat(m)
        elseif statType == "HEALING" then val = MSC.SanitizeStat(GetSpellBonusHealing())
        elseif statType == "SPELL_POWER" then val = MSC.SanitizeStat(GetSpellBonusDamage(2))
        end
    end
    
    return MSC.SanitizeStat(val)
end

-- Returns MP5 gained from `spiritPoints` on gear (pass 1 for per-stat weighting).
function MSC:GetSpiritValueInMP5(level, spiritPoints)
    if not MSC.BaseRegenTable then return 0 end
    local points = spiritPoints or 1
    if points > 50 then points = 1 end -- guard against passing total Intellect by mistake
    local _, class = UnitClass("player")
    if MSC.IsVanillaRules then
        if class == "PRIEST" or class == "MAGE" then return (points / 4) + 12.5 end
        return (points / 5) + 15
    else
        if not level or level > 70 then level = 70 end
        local base = MSC.BaseRegenTable[level] or 0.009327
        local intel = MSC.SanitizeStat(UnitStat("player", 4)) or 100
        return 5 * (0.001 + base * math_sqrt(intel) * points)
    end
end

-- =============================================================
-- 3. COMPARISON MATH
-- =============================================================
function MSC.GetStatDifferences(newStats, oldStats, outTable)
    if not outTable then outTable = {} end
    wipe(outTable)
    
    local ignoreKeys = {
        ["IS_PROJECTED"] = true, ["GEMS_PROJECTED"] = true, ["BONUS_PROJECTED"] = true,
        ["GEM_TEXT"] = true, ["ENCHANT_TEXT"] = true, ["PROJECTED_GEM_IDS"] = true,
        ["META_ID"] = true, ["COLORS"] = true, ["_BONUS_STATS"] = true, ["_AUTO_PROC"] = true
    }

    local processed = {}
    for k, valNew in pairs(newStats) do
        if not ignoreKeys[k] and type(valNew) == "number" then
            local valOld = oldStats[k]
            if type(valOld) ~= "number" then valOld = 0 end
            local diff = valNew - valOld
            if math_abs(diff) > 0.01 then
                table_insert(outTable, { key = k, val = diff })
            end
            processed[k] = true
        end
    end
    for k, valOld in pairs(oldStats) do
        if not processed[k] and not ignoreKeys[k] and type(valOld) == "number" then
            local diff = 0 - valOld
            if math_abs(diff) > 0.01 then
                table_insert(outTable, { key = k, val = diff })
            end
        end
    end
    return outTable
end

function MSC.SortStatDiffs(diffs)
    table_sort(diffs, function(a,b) return a.val > b.val end)
    return diffs
end

function MSC.GetCleanStatName(key)
    if MSC.ShortNames and MSC.ShortNames[key] then return MSC.ShortNames[key] end
    if MSC.StatShortNames and MSC.StatShortNames[key] then return MSC.StatShortNames[key] end
    local s = string_gsub(string_gsub(string_gsub(key, "ITEM_MOD_", ""), "_SHORT", ""), "_", " ")
    return string_gsub(string_lower(s), "^%l", string_upper)
end

function MSC.NormalizeStatKey(key)
    if not key or not MSC.StatAliases then return key end
    return MSC.StatAliases[key] or key
end

-- =============================================================
-- 4. CACHE & CONSTANTS
-- =============================================================
MSC.StatCache = {}
local Scratch_MatchGems = {}
local Scratch_PureGems = {}
local Scratch_GemTextParts = {}
local Scratch_ProjectedIDs = {}
local Scratch_GemCounts = {}
local Scratch_GemOrder = {}
local Scratch_GemStats = {}
local Scratch_GemColors = {}
local Scratch_ProjectedColors = { RED=0, YELLOW=0, BLUE=0 }

MSC.StatShortNames = {
    ["MSC_WAND_DPS"] = MSC.L["Wand DPS"], ["MSC_WEAPON_DPS"] = MSC.L["Weapon DPS"], ["MSC_WEAPON_DPS_MELEE"] = MSC.L["Melee Weapon DPS"], ["MSC_WEAPON_SPEED"] = MSC.L["Speed"], ["MSC_OH_WEAPON_SPEED"] = MSC.L["OH Speed"],
    ["ITEM_MOD_STAMINA_SHORT"] = MSC.L["Stam"], ["ITEM_MOD_INTELLECT_SHORT"] = MSC.L["Int"],
    ["ITEM_MOD_AGILITY_SHORT"] = MSC.L["Agi"], ["ITEM_MOD_STRENGTH_SHORT"] = MSC.L["Str"],
    ["ITEM_MOD_SPIRIT_SHORT"] = MSC.L["Spt"], ["ITEM_MOD_SPELL_POWER_SHORT"] = MSC.L["SP"],
    ["ITEM_MOD_SPELL_DAMAGE_DONE_SHORT"] = MSC.L["Spell Dmg"], ["ITEM_MOD_HEALTH_REGENERATION_SHORT"] = MSC.L["Hp5"],
    ["ITEM_MOD_SPELL_HEALING_DONE_SHORT"] = MSC.L["Heal"], ["ITEM_MOD_MANA_REGENERATION_SHORT"] = MSC.L["Mp5"],
    ["ITEM_MOD_ATTACK_POWER_SHORT"] = MSC.L["AP"], ["ITEM_MOD_CRIT_RATING_SHORT"] = MSC.L["Crit"],
    ["ITEM_MOD_SPELL_CRIT_RATING_SHORT"] = MSC.L["Spell Crit"], ["ITEM_MOD_HIT_RATING_SHORT"] = MSC.L["Hit"],
    ["ITEM_MOD_HIT_SPELL_RATING_SHORT"] = MSC.L["Spell Hit"], ["ITEM_MOD_HASTE_RATING_SHORT"] = MSC.L["Haste"],
    ["ITEM_MOD_EXPERTISE_RATING_SHORT"] = MSC.L["Exp"], ["ITEM_MOD_DEFENSE_SKILL_RATING_SHORT"] = MSC.L["Def"],
    ["ITEM_MOD_RESILIENCE_RATING_SHORT"] = MSC.L["Resil"], ["ITEM_MOD_ARMOR_PENETRATION_RATING_SHORT"] = MSC.L["ArP"],
    ["ITEM_MOD_BLOCK_VALUE_SHORT"] = MSC.L["BlockVal"], ["ITEM_MOD_BLOCK_RATING_SHORT"] = MSC.L["Block"],
    ["ITEM_MOD_DODGE_RATING_SHORT"] = MSC.L["Dodge"], ["ITEM_MOD_PARRY_RATING_SHORT"] = MSC.L["Parry"],
    ["ITEM_MOD_SHADOW_DAMAGE_SHORT"] = MSC.L["Shadow"], ["ITEM_MOD_FIRE_DAMAGE_SHORT"] = MSC.L["Fire"],
    ["ITEM_MOD_FROST_DAMAGE_SHORT"] = MSC.L["Frost"], ["ITEM_MOD_ARCANE_DAMAGE_SHORT"] = MSC.L["Arcane"],
    ["ITEM_MOD_NATURE_DAMAGE_SHORT"] = MSC.L["Nature"], ["ITEM_MOD_HOLY_DAMAGE_SHORT"] = MSC.L["Holy"],
    ["ITEM_MOD_DAMAGE_PER_SECOND_SHORT"] = MSC.L["Dmg"], ["ITEM_MOD_ARMOR_SHORT"] = MSC.L["Armor"],
    ["ITEM_MOD_ALL_RESISTANCE_SHORT"] = MSC.L["All Res"],
    ["ITEM_MOD_FERAL_ATTACK_POWER_SHORT"] = MSC.L["Feral AP"],
    ["ITEM_MOD_RANGED_ATTACK_POWER_SHORT"] = MSC.L["Ranged AP"],
}

function MSC.Round(num, numDecimalPlaces)
    local mult = 10^(numDecimalPlaces or 0)
    return math_floor(num * mult + 0.5) / mult
end

-- =============================================================
-- 5. RATING CONVERTER
-- =============================================================
function MSC:GetRatingPercent(statKey, ratingVal, level)
    if not MSC.CombatRatingScalars or not MSC.RatingIndexMap then return nil end
    local idx = MSC.RatingIndexMap[statKey]
    if not idx then return nil end
    local levelData = MSC.CombatRatingScalars[level]
    if not levelData then 
        if level < 60 then levelData = MSC.CombatRatingScalars[60] 
        elseif level > 70 then levelData = MSC.CombatRatingScalars[70] end
    end
    if not levelData or not levelData[idx] then return nil end
    return ratingVal / levelData[idx]
end

-- =============================================================
-- 5.5 FOREVER WEAPON RACIALS
-- =============================================================
-- Server-granted crit specializations native to WoW: Forever (confirmed via
-- wowforevertools.com/races). Crit is unified there (affects both melee and
-- spell), unlike Era/TBC's flat weapon-SKILL racials (Classes\ERA|TBC's
-- per-class GetWeaponBonus), so this is shared across every class rather than
-- reimplemented per profile.
MSC.ForeverWeaponRacials = {
    Human = { critPct = 2, subclasses = { [7] = true, [8] = true } },  -- Sword Specialization
    Dwarf = { critPct = 1, subclasses = { [4] = true, [5] = true } },  -- Mace Specialization
    Orc   = { critPct = 1, subclasses = { [0] = true, [1] = true } },  -- Axe Specialization
}

-- otherHandLink: the weapon in the other hand. The racial applies once while
-- either hand holds that weapon type, so when the other hand already
-- qualifies this item adds nothing (dual wielders with two swords, or an
-- off-hand sword next to a main-hand sword).
function MSC.GetForeverWeaponRacialBonus(itemLink, weights, otherHandLink)
    if not itemLink or not weights then return 0 end
    local _, race = UnitRace("player")
    local racial = race and MSC.ForeverWeaponRacials[race]
    if not racial then return 0 end

    local _, _, _, _, _, _, _, _, _, _, _, classID, subClassID = GetItemInfo(itemLink)
    if classID ~= 2 or not subClassID or not racial.subclasses[subClassID] then return 0 end
    if otherHandLink then
        local _, _, _, _, _, _, _, _, _, _, _, otherClass, otherSub = GetItemInfo(otherHandLink)
        if otherClass == 2 and otherSub and racial.subclasses[otherSub] then return 0 end
    end

    -- Crit weights are "per 1%" (GetItemScore converts rating to percent
    -- before weighting), so +N% crit is worth N x the weight -- exactly what
    -- the equivalent Critical Strike Rating on an item scores. Uses the larger
    -- of the two crit weights, matching GetItemScore's Forever crit unification.
    local critWeight = math_max(weights["ITEM_MOD_CRIT_RATING_SHORT"] or 0, weights["ITEM_MOD_SPELL_CRIT_RATING_SHORT"] or 0)

    return racial.critPct * critWeight
end

-- =============================================================
-- 5.6 FOREVER DUAL-WIELD HIT TAPER
-- =============================================================
-- Dual-wield melee (Rogue, Enhancement Shaman, DW Fury Warrior) don't fall off
-- a cliff at the 9% yellow-hit cap the way single-wield/2H specs do. Per the
-- confirmed Forever formula, White Crit Cap = 100% - (28% - Hit) - 5.6% dodge
-- - 40% glancing: at 0 gear Hit that's a 26.4% base crit cap, and every point
-- of Hit raises it 1:1, topping out at 54.4% once Hit reaches 28% (the same
-- ceiling 2H specs sit at, since 28 Hit fully cancels the DW miss penalty).
-- Between the 9% yellow cap and the 28% white cap, Hit no longer helps yellow
-- abilities (already at 0% miss there) but keeps cutting white-swing misses
-- 1:1 the whole way to 28%, so its marginal value doesn't keep decaying in
-- that band -- it's a plateau, not a fade. Past 28% both the white miss and
-- the crit ceiling are maxed out, so Hit provides essentially nothing.
-- =============================================================
-- 5.7 FOREVER CAPS (hit, spell hit, tank defense)
-- =============================================================
-- Two targets per cap: what's useful against level-appropriate mobs while
-- leveling, and what raiding at 60 needs (level-63 bosses). From level 50 the
-- target slides linearly toward the raid one, so players gearing for raids
-- keep valuing hit and defense past the leveling target. "Gear for raiding"
-- (Protocol, on by default) can turn the slide off for pure levelers.
MSC.ForeverCaps = {
    RAID_BLEND_START = 50,
    MELEE = { leveling = 5, raid = 9 },   -- yellow/2H miss vs same level / vs +3 boss
    SPELL = { leveling = 3, raid = 16 },  -- 4% miss (1% can't be removed) / 17% vs +3
    DW_WHITE = { leveling = 24, raid = 28 }, -- dual-wield white swings
    DEFENSE_RAID = 440,                   -- crit immunity vs level-63 bosses
    UNCRUSHABLE = 102.4,                  -- miss + dodge + parry + block vs +3
}

function MSC.IsGearingForRaids()
    return not (SGJ_Settings and SGJ_Settings.GearForRaiding == false)
end

-- 0 below 50 (or when not gearing for raids), 1 at 60+.
function MSC.GetRaidBlend(level)
    level = level or UnitLevel("player") or 1
    if level >= 60 then return 1 end
    if not MSC.IsGearingForRaids() then return 0 end
    local start = MSC.ForeverCaps.RAID_BLEND_START
    if level <= start then return 0 end
    return (level - start) / (60 - start)
end

function MSC.GetForeverCapTarget(kind, level)
    local c = MSC.ForeverCaps[kind]
    if not c then return nil end
    local t = MSC.GetRaidBlend(level)
    return c.leveling + (c.raid - c.leveling) * t
end

-- Defense skill a tank should aim for: none below 50 (returns nil), then a
-- slide from the level's base defense (5 x level) to 440 at 60.
function MSC.GetForeverDefenseTarget(level)
    level = level or UnitLevel("player") or 1
    local t = MSC.GetRaidBlend(level)
    if t <= 0 then return nil end
    local base = 5 * math_min(level, 60)
    return base + (MSC.ForeverCaps.DEFENSE_RAID - base) * t
end

-- Current hit % in one place, talents included once. Forever gear carries
-- Hit Rating (10 = 1%), which the old GetHitModifier() path didn't see.
-- kind: "MELEE", "RANGED" or "SPELL". /sgj hitcheck prints the parts.
local CR_HIT = { MELEE = 6, RANGED = 7, SPELL = 8 }
function MSC:GetForeverHitPercent(kind)
    kind = kind or "MELEE"
    local cr = CR_HIT[kind] or 6
    local fromRating
    if GetCombatRatingBonus then
        fromRating = MSC.SanitizeStat(GetCombatRatingBonus(cr))
    else
        fromRating = MSC.SanitizeStat(GetCombatRating and GetCombatRating(cr) or 0) / 10
    end
    local modifier
    if kind == "SPELL" then
        modifier = MSC.SanitizeStat(GetSpellHitModifier and GetSpellHitModifier() or 0)
    else
        modifier = MSC.SanitizeStat(GetHitModifier and GetHitModifier() or 0)
    end
    return fromRating + modifier, fromRating, modifier
end

-- Scales a hit weight for the current hit % against the level's target:
-- full value below the target, overcapMult of it above. extraHit is for
-- school-only talents (Shadow Focus, Elemental Precision, Suppression) that
-- the game's general spell-hit number doesn't include.
function MSC.ApplyForeverHitCap(weights, key, kind, overcapMult, label, activeCaps, extraHit)
    local cap = MSC.GetForeverCapTarget(kind == "RANGED" and "MELEE" or kind)
    MSC.ApplyForeverHitKnees(weights, key, kind, { { cap = cap, mult = overcapMult or 0.1 } }, label, activeCaps, extraHit)
end

-- General form: knees = { { cap = pct, mult = m }, ... } in rising order.
-- Hit is worth the full weight below the first cap, then each knee's mult
-- of it. Sets the weight for the player's current hit and records the curve
-- in MSC.ForeverHitCapState so the upgrade check can value an item that
-- crosses a cap (see MSC.ForeverHitCapCorrection).
function MSC.ApplyForeverHitKnees(weights, key, kind, knees, label, activeCaps, extraHit)
    local full = weights[key]
    if not full or full <= 0 then return end
    local hit = MSC:GetForeverHitPercent(kind) + (extraHit or 0)
    local mult, reached = 1, nil
    for _, k in ipairs(knees) do
        if hit >= k.cap then mult, reached = k.mult, k.cap end
    end
    weights[key] = full * mult
    -- Kept per weights table (weak keys), so each profile's curve stays with
    -- the weights it produced.
    MSC.ForeverHitCapState = MSC.ForeverHitCapState or setmetatable({}, { __mode = "k" })
    local byKey = MSC.ForeverHitCapState[weights] or {}
    byKey[key] = { kind = kind, extra = extraHit or 0, knees = knees, mult = mult }
    MSC.ForeverHitCapState[weights] = byKey
    if reached and activeCaps then table.insert(activeCaps, string_format("%s (%.1f%%)", label or "Hit", reached)) end
end

-- Value of `hit` percent points under a knee curve, in units of the full weight.
local function KneeValue(knees, hit)
    local value, prevCap, prevMult = 0, 0, 1
    for _, k in ipairs(knees) do
        if hit <= k.cap then return value + (hit - prevCap) * prevMult end
        value = value + (k.cap - prevCap) * prevMult
        prevCap, prevMult = k.cap, k.mult
    end
    return value + (hit - prevCap) * prevMult
end

-- Score correction for swapping gear from oldRating to newRating total Hit
-- Rating (Forever: 10 rating = 1%). The weights charge every point at the
-- current slope; this replaces that with the true curve, so hit that goes
-- past a cap is discounted and hit that drops back below one is charged in
-- full. Returns the correction and the cap crossed downward, if any.
function MSC.ForeverHitCapCorrection(weights, oldRating, newRating)
    local state = MSC.ForeverHitCapState and MSC.ForeverHitCapState[weights]
    if not state or oldRating == newRating then return 0 end
    -- Use the hit key the scorer uses (the largest hit weight)
    local key, w = nil, 0
    for k, st in pairs(state) do
        local kw = weights[k] or 0
        if kw > w then key, w = k, kw end
    end
    if not key then return 0 end
    local st = state[key]
    if st.mult <= 0 then return 0 end
    local full = w / st.mult
    local _, _, modifier = MSC:GetForeverHitPercent(st.kind)
    local base = modifier + st.extra
    local cur, fut = base + oldRating / 10, base + newRating / 10
    local trueDelta = full * (KneeValue(st.knees, fut) - KneeValue(st.knees, cur))
    local charged = w * (fut - cur)
    local firstCap = st.knees[1] and st.knees[1].cap
    local droppedBelow = firstCap and cur >= firstCap and fut < firstCap and (fut - firstCap) or nil
    return trueDelta - charged, droppedBelow
end

-- Tank defense toward the raid target: past the target, Defense is worth
-- much less (Stamina and armor take over).
function MSC.ApplyForeverDefenseTarget(weights, activeCaps)
    local w = weights["ITEM_MOD_DEFENSE_SKILL_RATING_SHORT"]
    if not w or w <= 0 then return end
    local target = MSC.GetForeverDefenseTarget()
    if not target then return end
    local def = MSC:GetPlayerStat("DEFENSE")
    if def >= target then
        weights["ITEM_MOD_DEFENSE_SKILL_RATING_SHORT"] = w * 0.3
        if activeCaps then table.insert(activeCaps, string_format("Defense (%d)", target)) end
    end
end

-- Shield tanks: once miss + dodge + parry + block (+ the shield's active
-- block ability) reaches 102.4%, crushing blows can't land, so more
-- avoidance/block is worth less and effective health takes over. From 50
-- when gearing for raids (dungeon and raid bosses are +2/+3), always at 60.
function MSC.ApplyForeverUncrushable(weights, activeBlockPct, activeCaps)
    if MSC.GetRaidBlend() <= 0 then return end
    local dodge = GetDodgeChance and MSC.SanitizeStat(GetDodgeChance()) or 0
    local parry = GetParryChance and MSC.SanitizeStat(GetParryChance()) or 0
    local block = GetBlockChance and MSC.SanitizeStat(GetBlockChance()) or 0
    local total = 5 + dodge + parry + block + (activeBlockPct or 0)
    if total >= MSC.ForeverCaps.UNCRUSHABLE then
        for _, k in ipairs({ "ITEM_MOD_BLOCK_RATING_SHORT", "ITEM_MOD_DODGE_RATING_SHORT", "ITEM_MOD_PARRY_RATING_SHORT" }) do
            if weights[k] then weights[k] = weights[k] * 0.8 end
        end
        if weights["ITEM_MOD_STAMINA_SHORT"] then weights["ITEM_MOD_STAMINA_SHORT"] = weights["ITEM_MOD_STAMINA_SHORT"] * 1.2 end
        if weights["ITEM_MOD_ARMOR_SHORT"] then weights["ITEM_MOD_ARMOR_SHORT"] = weights["ITEM_MOD_ARMOR_SHORT"] * 1.2 end
        if activeCaps then table.insert(activeCaps, "Uncrushable") end
    end
end

-- =============================================================
-- 5.8 FOREVER RELICS
-- =============================================================
-- Relic effects are mostly percentages and cooldowns the parser can't read,
-- so each class's Relics table turns them into equivalent stats for the
-- player's spec (see Classes/Forever/Paladin|Druid|Shaman.lua). This is the
-- live character data those conversions use.
function MSC.GetRelicContext()
    local _, class = UnitClass("player")
    local level = UnitLevel("player") or 1
    local spirit = MSC.SanitizeStat(UnitStat("player", 5))
    local agi = MSC.SanitizeStat(UnitStat("player", 2))
    local baseArmor = UnitArmor and MSC.SanitizeStat((UnitArmor("player"))) or 0
    local apBase, apPos, apNeg = 0, 0, 0
    if UnitAttackPower then apBase, apPos, apNeg = UnitAttackPower("player") end
    local ap = MSC.SanitizeStat(apBase) + MSC.SanitizeStat(apPos) + MSC.SanitizeStat(apNeg)
    -- Classic mana regen from Spirit, per 5 sec outside the five-second rule
    local regenPerTick = (class == "SHAMAN") and (17 + spirit / 5) or (15 + spirit / 5)
    return {
        level = level, spirit = spirit, ap = ap,
        itemArmor = math_max(0, baseArmor - 2 * agi),
        spiritRegen5 = regenPerTick * 2.5,
        shieldBlock = GetShieldBlock and MSC.SanitizeStat(GetShieldBlock()) or 0,
    }
end

-- Which kind of spec a relic is being valued for.
function MSC.RelicRole(spec)
    local s = (spec or ""):upper()
    if s:find("HEAL") or s:find("RESTO") or s:find("HOLY") then return "healer" end
    if s:find("TANK") or s:find("BEAR") or s:find("PROT") then return "tank" end
    if s:find("CASTER") or s:find("BALANCE") or s:find("BOOMKIN") or s:find("ELE") then return "caster" end
    return "melee"
end

-- Shared GetRelicBonus body: Relics entries are either a stat table or a
-- function(role, ctx, spec) returning one.
function MSC.GetForeverRelicBonus(relics, itemID, spec)
    local entry = relics and relics[itemID]
    if not entry then return {} end
    if type(entry) == "function" then
        local ok, res = pcall(entry, MSC.RelicRole(spec), MSC.GetRelicContext(), spec or "")
        return (ok and type(res) == "table") and res or {}
    end
    local bonus = {}
    for k, v in pairs(entry) do bonus[k] = v end
    return bonus
end

function MSC.ApplyForeverDualWieldHitTaper(hitWeight, totalHitPct, softCap, hardCap)
    softCap = softCap or 9
    hardCap = hardCap or 28
    if not hitWeight or totalHitPct < softCap then return hitWeight, false end
    if totalHitPct >= hardCap then return hitWeight * 0.05, true end
    return hitWeight * 0.6, true -- retains most of its value across the 9%-28% band
end

-- =============================================================
-- 5.9 FOREVER TALENT HOOK HELPERS
-- =============================================================
-- Shared pieces for the per-class ApplyScalers talent hooks so every class
-- applies the same rules:
--   * a crit multiplier must also move the primary stat that carries crit
--     (Agility for melee, Intellect for spells), because primary stats are
--     scored only through their own weight;
--   * a flat "+X% damage" talent scales every damage-derived weight
--     together, so it is applied by dividing the safety stats instead of
--     multiplying Spell Power or Attack Power alone.
-- Stat-per-1%-crit tables come from the client's PlayerExpectedStat
-- (build 1.60.1.70009), index = level 1..60.
MSC.ForeverCritPerStat = {
    WARRIOR = {
        agi = { 4, 4.20, 4.20, 4.40, 4.60, 4.80, 4.80, 5, 5.20, 5.20, 5.40, 5.60, 6, 6.20, 6.40, 6.60, 6.80, 7.20, 7.40, 7.80, 7.80, 8, 8.40, 8.60, 9, 9.20, 9.40, 9.80, 10, 10.40, 10.60, 10.80, 11.20, 11.40, 11.81, 12, 12.20, 12.59, 12.80, 13.19, 13.61, 13.79, 14.20, 14.41, 14.79, 14.99, 15.41, 15.80, 16, 16.39, 16.81, 17.01, 17.39, 17.79, 18.21, 18.42, 18.80, 19.19, 19.61, 20 },
        int = nil,
    },
    PALADIN = {
        agi = { 4.65, 4.88, 4.88, 5.12, 5.12, 5.35, 5.35, 5.58, 5.58, 5.81, 5.81, 6.05, 6.51, 6.51, 6.98, 6.98, 7.21, 7.67, 7.67, 8.14, 8.38, 8.38, 8.83, 9.07, 9.30, 9.53, 9.77, 10, 10.24, 10.70, 10.93, 10.93, 11.39, 11.63, 12.09, 12.33, 12.33, 12.79, 13.02, 13.50, 13.72, 13.72, 14.18, 14.41, 14.88, 15.11, 15.34, 15.82, 16.05, 16.50, 16.75, 16.98, 17.45, 17.67, 18.15, 18.38, 18.59, 19.08, 19.31, 19.76 },
        int = { 13.33, 14.01, 14.01, 14.66, 14.66, 15.34, 16, 16, 16.67, 16.67, 17.33, 17.99, 18.66, 19.34, 20.66, 20.66, 21.32, 22.68, 22.68, 23.98, 24.69, 25.32, 25.97, 26.67, 28.01, 28.65, 28.65, 30.03, 30.67, 31.95, 32.68, 33.33, 34.01, 34.72, 35.97, 36.63, 37.31, 38.61, 39.37, 40.65, 41.32, 42.02, 43.29, 43.29, 44.64, 45.25, 46.73, 48.08, 48.78, 50, 50.76, 51.28, 52.63, 53.19, 54.64, 55.25, 55.87, 58.14, 58.82, 59.88 },
    },
    HUNTER = {
        agi = { 4.60, 4.80, 5, 5.40, 5.60, 5.80, 6, 6.20, 6.60, 6.80, 7.40, 8.40, 9.20, 10, 11, 11.60, 12.41, 13.40, 14.20, 15.20, 15.80, 16.81, 17.61, 18.59, 19.42, 20.20, 21.19, 21.98, 22.99, 23.98, 24.57, 25.58, 26.60, 27.40, 28.41, 29.24, 30.21, 31.15, 32.15, 33, 33.78, 34.84, 35.84, 36.76, 37.74, 38.61, 39.53, 40.82, 41.84, 42.74, 43.67, 44.64, 45.66, 46.73, 47.85, 48.54, 49.75, 50.76, 52.08, 52.91 },
        int = { 14.29, 14.99, 14.99, 15.72, 15.72, 16.42, 16.42, 17.15, 17.15, 17.86, 17.86, 18.59, 20, 20, 21.41, 21.41, 22.12, 23.58, 23.58, 25, 25.71, 25.71, 27.17, 27.86, 28.57, 29.33, 30.03, 30.67, 31.45, 32.89, 33.56, 33.56, 34.97, 35.71, 37.17, 37.88, 37.88, 39.22, 40, 41.49, 42.19, 42.19, 43.48, 44.25, 45.66, 46.51, 47.17, 48.54, 49.26, 50.76, 51.55, 52.08, 53.48, 54.35, 55.87, 56.50, 57.14, 58.48, 59.17, 60.61 },
    },
    ROGUE = {
        agi = { 2.30, 2.40, 2.50, 2.70, 2.80, 2.90, 3.10, 3.20, 3.30, 3.50, 3.90, 4.30, 4.80, 5.20, 5.80, 6.20, 6.60, 7.10, 7.60, 8.10, 8.60, 9, 9.50, 9.90, 10.50, 11, 11.40, 11.90, 12.41, 13, 13.40, 13.91, 14.41, 14.90, 15.50, 16, 16.39, 16.89, 17.39, 17.99, 18.48, 19.01, 19.49, 20.08, 20.70, 21.19, 21.69, 22.22, 22.68, 23.42, 23.92, 24.39, 25, 25.51, 26.11, 26.67, 27.17, 27.78, 28.33, 28.99 },
        int = nil,
    },
    PRIEST = {
        agi = { 10, 10, 10, 10.50, 10.50, 10.50, 10.50, 11, 11, 11, 11, 11.49, 11.49, 11.49, 11.49, 12, 12, 12, 12.50, 12.50, 12.50, 12.50, 13, 13, 13, 13.50, 13.50, 13.50, 14.01, 14.01, 14.01, 14.49, 14.49, 14.49, 14.99, 14.99, 14.99, 15.50, 15.50, 15.50, 16, 16, 16.50, 16.50, 16.50, 17.01, 17.01, 17.51, 17.51, 17.51, 17.99, 17.99, 18.48, 18.48, 19.01, 19.01, 19.49, 19.49, 20, 20 },
        int = { 5.24, 5.48, 5.71, 5.95, 6.43, 6.67, 6.91, 7.14, 7.38, 7.86, 8.57, 9.52, 10.24, 11.43, 12.38, 13.09, 14.29, 14.99, 15.95, 17.15, 17.86, 19.05, 19.76, 20.96, 21.88, 22.83, 23.81, 24.75, 25.71, 26.88, 27.86, 28.82, 29.76, 30.96, 31.95, 32.89, 34.01, 34.97, 35.97, 37.17, 38.02, 39.22, 40.16, 41.49, 42.55, 43.48, 44.84, 45.66, 46.95, 48.08, 49.02, 50.25, 51.28, 52.36, 53.76, 54.64, 55.87, 56.82, 58.48, 59.52 },
    },
    SHAMAN = {
        agi = { 6.06, 6.06, 6.37, 6.37, 6.67, 6.67, 6.67, 6.97, 6.97, 7.27, 7.27, 7.58, 7.58, 7.88, 8.18, 8.48, 8.48, 8.79, 8.79, 9.39, 9.39, 9.70, 9.70, 10, 10.30, 10.60, 10.60, 10.91, 10.91, 11.52, 11.52, 11.82, 12.12, 12.12, 12.72, 13.04, 13.04, 13.33, 13.33, 13.95, 14.25, 14.25, 14.53, 14.86, 15.15, 15.46, 15.75, 16.05, 16.05, 16.67, 16.98, 17.27, 17.27, 17.57, 18.18, 18.48, 18.80, 18.80, 19.08, 19.69 },
        int = { 7.78, 8.15, 8.52, 8.52, 8.89, 9.26, 9.63, 10, 10.37, 10.37, 11.11, 11.85, 12.97, 13.70, 14.81, 15.55, 16.29, 17.42, 18.15, 19.27, 20, 20.75, 21.83, 22.57, 23.70, 24.45, 25.19, 26.32, 27.03, 28.17, 29.24, 30.03, 31.15, 31.85, 33, 34.13, 34.84, 35.97, 36.63, 38.17, 38.91, 39.68, 40.82, 41.84, 42.92, 44.05, 44.84, 45.87, 46.95, 48.08, 49.26, 50, 51.55, 52.36, 53.76, 54.35, 55.56, 57.14, 57.80, 59.17 },
    },
    MAGE = {
        agi = { 11.11, 11.11, 11.11, 11.67, 11.67, 11.67, 11.67, 11.67, 11.67, 12.22, 12.22, 12.22, 12.22, 12.22, 12.77, 12.77, 12.77, 12.77, 12.77, 13.33, 13.33, 13.33, 13.33, 13.89, 13.89, 13.89, 13.89, 13.89, 14.45, 14.45, 14.45, 14.45, 14.99, 14.99, 14.99, 15.55, 15.55, 15.55, 15.55, 16.10, 16.10, 16.10, 16.10, 16.67, 16.67, 16.67, 17.21, 17.21, 17.21, 17.76, 17.76, 17.76, 18.35, 18.35, 18.35, 18.90, 18.90, 18.90, 19.46, 19.46 },
        int = { 5.21, 5.42, 5.62, 6.04, 6.25, 6.46, 6.67, 6.87, 7.29, 7.50, 8.12, 9.17, 9.79, 11.67, 12.71, 13.33, 14.16, 14.99, 15.82, 16.86, 17.51, 18.55, 19.16, 20.20, 21.05, 21.88, 22.94, 25.19, 26.25, 27.32, 27.93, 28.99, 29.76, 30.58, 31.65, 32.47, 33.56, 34.36, 35.46, 36.23, 37.04, 39.53, 40.49, 41.49, 42.55, 43.29, 44.44, 45.45, 46.51, 47.39, 48.31, 49.26, 50.25, 51.55, 52.63, 55.25, 56.50, 57.14, 58.48, 59.52 },
    },
    WARLOCK = {
        agi = { 6.67, 6.67, 7, 7, 7, 7.33, 7.33, 7.33, 7.67, 7.67, 8, 8, 8, 8.33, 8.67, 9, 9, 9, 9.34, 9.67, 10, 10, 10.33, 10.33, 11, 11, 11, 11.34, 11.34, 12, 12, 12.33, 12.33, 12.67, 13, 13.33, 13.66, 13.66, 14.01, 14.33, 14.66, 14.66, 14.99, 14.99, 15.67, 16, 16, 16.34, 16.67, 17.01, 17.33, 17.33, 17.67, 17.99, 18.35, 18.66, 19.01, 19.34, 19.34, 20 },
        int = { 6.67, 6.97, 7.27, 7.58, 7.88, 8.18, 8.48, 8.79, 9.09, 9.39, 10.30, 11.21, 12.12, 13.04, 13.95, 14.53, 15.75, 16.67, 17.57, 18.48, 19.38, 20.28, 21.23, 22.42, 23.31, 23.92, 25.13, 26.04, 27.25, 28.17, 28.82, 30.03, 30.86, 32.15, 33, 33.90, 35.21, 36.10, 37.31, 38.17, 39.06, 40.32, 41.15, 42.37, 43.67, 44.64, 45.45, 46.73, 47.85, 49.02, 50, 51.28, 52.36, 53.76, 54.95, 55.87, 56.82, 58.14, 59.52, 60.61 },
    },
    DRUID = {
        agi = { 4.88, 4.88, 5.12, 5.12, 5.36, 5.36, 5.61, 5.61, 5.85, 6.34, 6.58, 6.58, 6.83, 6.83, 7.32, 7.32, 7.56, 7.81, 7.81, 8.78, 8.78, 9.03, 9.27, 9.27, 9.76, 9.76, 10, 10.25, 10.25, 11.22, 11.47, 11.47, 11.71, 11.95, 12.20, 12.44, 12.69, 12.69, 12.92, 13.91, 14.14, 14.14, 14.39, 14.64, 15.13, 15.36, 15.36, 15.60, 15.85, 16.84, 17.06, 17.33, 17.57, 17.57, 18.05, 18.28, 18.55, 18.80, 19.01, 20 },
        int = { 6.87, 7.19, 7.50, 7.81, 8.12, 8.44, 8.75, 8.75, 9.07, 10, 10.63, 11.56, 12.18, 13.12, 14.37, 14.99, 15.95, 16.56, 17.51, 19.05, 19.69, 20.62, 21.23, 22.52, 23.42, 24.04, 25, 25.64, 26.88, 28.41, 29.07, 30.30, 30.96, 31.85, 33.11, 33.78, 34.72, 35.59, 36.50, 38.46, 39.06, 40.32, 40.98, 42.19, 43.10, 44.05, 45.05, 45.87, 47.17, 48.78, 49.75, 51.02, 51.55, 52.91, 54.05, 54.95, 55.87, 56.82, 58.14, 59.88 },
    },
}

function MSC.GetForeverLevel()
    return (UnitLevel and UnitLevel("player")) or 60
end

-- Agility points per 1% melee crit / Intellect points per 1% spell crit for
-- the player's class at a level (defaults: current level).
function MSC.GetForeverAgiPerCrit(level)
    local _, cls = UnitClass("player")
    local t = MSC.ForeverCritPerStat[cls or ""]
    local L = math.max(1, math.min(60, math.floor(level or MSC.GetForeverLevel())))
    return (t and t.agi and t.agi[L]) or 20
end

function MSC.GetForeverIntPerSpellCrit(level)
    local _, cls = UnitClass("player")
    local t = MSC.ForeverCritPerStat[cls or ""]
    local L = math.max(1, math.min(60, math.floor(level or MSC.GetForeverLevel())))
    return (t and t.int and t.int[L]) or 60
end

-- Linear interpolation through { {level, value}, ... } (sorted by level);
-- clamps outside the first/last point.
function MSC.ForeverLevelLerp(points, level)
    level = level or MSC.GetForeverLevel()
    if not points or #points == 0 then return 0 end
    if level <= points[1][1] then return points[1][2] end
    for i = 2, #points do
        local a, b = points[i - 1], points[i]
        if level <= b[1] then
            local t = (level - a[1]) / (b[1] - a[1])
            return a[2] + (b[2] - a[2]) * t
        end
    end
    return points[#points][2]
end

-- Multiply every listed key that exists in the row.
function MSC.ScaleForeverKeys(weights, keys, mult)
    if not weights or not mult or mult == 1 then return end
    for _, k in ipairs(keys) do
        if weights[k] then weights[k] = weights[k] * mult end
    end
end

-- Melee crit multiplier: scales the crit weight and adds the same gain to
-- Agility through the class's agi-per-crit at this level. Feral crit
-- (ITEM_MOD_CRIT_RATING_SHORT) uses the same key.
function MSC.ScaleForeverMeleeCrit(weights, mult, level)
    local key = "ITEM_MOD_CRIT_RATING_SHORT"
    if not weights or not weights[key] or not mult or mult == 1 then return end
    local old = weights[key]
    weights[key] = old * mult
    if weights["ITEM_MOD_AGILITY_SHORT"] then
        weights["ITEM_MOD_AGILITY_SHORT"] = weights["ITEM_MOD_AGILITY_SHORT"] + (weights[key] - old) / MSC.GetForeverAgiPerCrit(level)
    end
end

-- Spell crit multiplier: scales the spell crit weight and moves Intellect's
-- crit share by the same gain (int-per-spell-crit at this level).
function MSC.ScaleForeverSpellCrit(weights, mult, level)
    local key = "ITEM_MOD_SPELL_CRIT_RATING_SHORT"
    if not weights or not weights[key] or not mult or mult == 1 then return end
    local old = weights[key]
    weights[key] = old * mult
    if weights["ITEM_MOD_INTELLECT_SHORT"] then
        weights["ITEM_MOD_INTELLECT_SHORT"] = weights["ITEM_MOD_INTELLECT_SHORT"] + (weights[key] - old) / MSC.GetForeverIntPerSpellCrit(level)
    end
end

-- Keys that are NOT damage/healing-derived: a flat "+X% damage" talent
-- leaves these alone while everything else gains, so the talent is applied
-- as a division of this set (the AP / Spell Power unit stays fixed).
MSC.ForeverSafetyKeys = {
    "ITEM_MOD_STAMINA_SHORT", "ITEM_MOD_HEALTH_SHORT", "ITEM_MOD_ARMOR_SHORT",
    "ITEM_MOD_DODGE_RATING_SHORT", "ITEM_MOD_PARRY_RATING_SHORT", "ITEM_MOD_BLOCK_RATING_SHORT",
    "ITEM_MOD_BLOCK_VALUE_SHORT", "ITEM_MOD_DEFENSE_SKILL_RATING_SHORT",
    "ITEM_MOD_HEALTH_REGENERATION_SHORT", "ITEM_MOD_RESILIENCE_RATING_SHORT",
    "ITEM_MOD_FIRE_RESISTANCE_SHORT", "ITEM_MOD_FROST_RESISTANCE_SHORT", "ITEM_MOD_NATURE_RESISTANCE_SHORT",
    "ITEM_MOD_SHADOW_RESISTANCE_SHORT", "ITEM_MOD_ARCANE_RESISTANCE_SHORT",
}

-- Flat damage (or healing) multiplier `mult` for the whole row: divides the
-- safety keys plus any `alsoKeep` keys (e.g. the wand for casters, since a
-- spell-damage talent does not touch it) by mult, so the damage family
-- rises relative to them without changing the unit.
function MSC.ApplyForeverDamageMult(weights, mult, alsoKeep)
    if not weights or not mult or mult == 1 or mult <= 0 then return end
    local inv = 1 / mult
    MSC.ScaleForeverKeys(weights, MSC.ForeverSafetyKeys, inv)
    if alsoKeep then MSC.ScaleForeverKeys(weights, alsoKeep, inv) end
end

-- The physical damage family, for talents that only boost melee/ranged
-- damage (e.g. a one-handed weapon specialization on a hybrid row).
MSC.ForeverMeleeDamageKeys = {
    "ITEM_MOD_ATTACK_POWER_SHORT", "ITEM_MOD_STRENGTH_SHORT", "ITEM_MOD_FERAL_ATTACK_POWER_SHORT",
    "ITEM_MOD_RANGED_ATTACK_POWER_SHORT", "MSC_WEAPON_DPS_MELEE", "MSC_WEAPON_DPS_OH",
    "ITEM_MOD_DAMAGE_PER_SECOND_SHORT", "ITEM_MOD_CRIT_RATING_SHORT", "ITEM_MOD_HIT_RATING_SHORT",
    "MSC_WEAPON_SPEED", "MSC_OH_WEAPON_SPEED", "MSC_RANGED_WEAPON_SPEED", "ITEM_MOD_AGILITY_SHORT",
}

-- The spell damage family (school keys included), for a school-limited
-- damage talent applied at its school share.
MSC.ForeverSpellDamageKeys = {
    "ITEM_MOD_SPELL_POWER_SHORT", "ITEM_MOD_SPELL_DAMAGE_DONE_SHORT",
    "ITEM_MOD_FIRE_DAMAGE_SHORT", "ITEM_MOD_FROST_DAMAGE_SHORT", "ITEM_MOD_ARCANE_DAMAGE_SHORT",
    "ITEM_MOD_NATURE_DAMAGE_SHORT", "ITEM_MOD_SHADOW_DAMAGE_SHORT", "ITEM_MOD_HOLY_DAMAGE_SHORT",
    "ITEM_MOD_HIT_SPELL_RATING_SHORT", "ITEM_MOD_SPELL_CRIT_RATING_SHORT",
}

-- Mana-derived keys (the value of "more casts").
MSC.ForeverManaKeys = {
    "ITEM_MOD_INTELLECT_SHORT", "ITEM_MOD_MANA_SHORT", "ITEM_MOD_SPIRIT_SHORT", "ITEM_MOD_MANA_REGENERATION_SHORT",
}

-- =============================================================
-- 6. SCANNING
-- =============================================================
function MSC.GetRawItemStats(itemLink)
    if not itemLink then return {} end
    if MSC.StatCache[itemLink] then return MSC.StatCache[itemLink] end

    -- 1. EXECUTE SCANNER
    local scanData = nil
    if MSC.Scanner and MSC.Scanner.Scan then
        local status, result = pcall(MSC.Scanner.Scan, itemLink)
        if status and result then scanData = result end
    end
    if not scanData then scanData = { Stats = {}, UseEffects = {}, Procs = {}, Meta = {} } end
    
    -- 2. FLATTEN STATS
    local finalStats = scanData.Stats or {}
    local bonusStats = {}

    -- 3. INTEGRATE USE EFFECTS (skip when ProcDB/trinket entry owns the item)
    local itemID = tonumber(string_match(itemLink, "item:(%d+)"))
    local hasProcEntry = itemID and (
        (MSC.ProcDB and MSC.ProcDB[itemID]) or
        (MSC.WeaponDB and MSC.WeaponDB[itemID]) or
        (MSC.TrinketDB and MSC.TrinketDB[itemID])
    )
    if not hasProcEntry and scanData.UseEffects then
        for _, effect in ipairs(scanData.UseEffects) do
            if effect.statKey and effect.averageVal and effect.averageVal > 0 then
                 local sk = MSC.NormalizeStatKey and MSC.NormalizeStatKey(effect.statKey) or effect.statKey
                 finalStats[sk] = (finalStats[sk] or 0) + effect.averageVal
                 if not finalStats._AUTO_PROC then finalStats._AUTO_PROC = { stat=sk, val=effect.averageVal } end
            end
        end
    end

    -- 4. OVERRIDES
    if itemID then
        if MSC.CurrentClass then
            local classDB = MSC.CurrentClass.Relics or MSC.CurrentClass.Totems or MSC.CurrentClass.Idols or MSC.CurrentClass.ItemOverrides
            if type(classDB) ~= "table" then return end
            local entry = classDB[itemID]
            if type(entry) == "function" then
                entry = entry()
            end
            if type(entry) == "table" then
                for statKey, val in pairs(entry) do -- Use 'entry', not classDB[itemID]
                    if statKey ~= "note" and type(val) == "number" then
                        finalStats[statKey] = (finalStats[statKey] or 0) + val
                    end
                end
            end
        end
        end
        local entry = nil
        if MSC.ProcDB and MSC.ProcDB[itemID] then entry = MSC.ProcDB[itemID]
        elseif MSC.WeaponDB and MSC.WeaponDB[itemID] then entry = MSC.WeaponDB[itemID]
        elseif MSC.TrinketDB and MSC.TrinketDB[itemID] then entry = MSC.TrinketDB[itemID]
        end

        if entry then
            -- [[ PROC MATH CALCULATION ]]
            local calcVal = entry.val
            if entry.ppm and entry.val then
                if entry.dur then
                    calcVal = (entry.val * entry.ppm * entry.dur) / 60
                else
                    if entry.stat and (string.find(entry.stat, "REGENERATION") or string.find(entry.stat, "MANA") or string.find(entry.stat, "HEALTH")) then
                         calcVal = (entry.val * entry.ppm * 5) / 60
                    else
                         calcVal = (entry.val * entry.ppm) / 60
                    end
                end
            end

            if calcVal and entry.stat then
                local sk = MSC.NormalizeStatKey(entry.stat)
                finalStats[sk] = (finalStats[sk] or 0) + calcVal
                if not finalStats._AUTO_PROC then finalStats._AUTO_PROC = { stat=sk, val=calcVal } end
            end
            if entry.score then finalStats._MANUAL_SCORE = entry.score end
        end
    end

    -- 5. SOCKET BONUSES
    if scanData.Meta and scanData.Meta.BonusStats then bonusStats = scanData.Meta.BonusStats end
    local normalized = {}
    for k, v in pairs(finalStats) do
        if type(v) == "number" and k ~= "_BONUS_STATS" then
            local nk = MSC.NormalizeStatKey(k)
            normalized[nk] = (normalized[nk] or 0) + v
        else
            normalized[k] = v
        end
    end
    finalStats = normalized
    finalStats._BONUS_STATS = bonusStats
    -- Raw "chance on hit" / temporary Equip: proc text the scanner found but
    -- couldn't score (no ProcDB/WeaponDB/TrinketDB/PvPDB entry exists yet).
    -- Rides along through SafeGetItemStats/EvaluateUpgrade so the tooltip can
    -- warn that the item's score is stats-only when this is non-empty and no
    -- curated entry was found.
    if scanData.Procs and #scanData.Procs > 0 then finalStats._RAW_PROCS = scanData.Procs end

    MSC.StatCache[itemLink] = finalStats
    return finalStats
end

-- =============================================================
-- 7. ENCHANT & GEM ENGINE
-- =============================================================
function MSC:GetValidEnchantType(itemLink)
    if not itemLink then return nil end
    local _, _, _, _, _, _, _, _, equipLoc, _, _, classID, subClassID = GetItemInfo(itemLink)
    if not equipLoc then return nil end
    
    if classID == 2 then 
        if equipLoc == "INVTYPE_2HWEAPON" or equipLoc == "INVTYPE_STAFF" or equipLoc == "INVTYPE_POLEARM" then return "2H"
        elseif equipLoc == "INVTYPE_RANGED" or equipLoc == "INVTYPE_RANGEDRIGHT" or equipLoc == "INVTYPE_THROWN" then
            if subClassID == 2 or subClassID == 3 or subClassID == 18 then return "Bow" end
            return "Relic"
        elseif equipLoc == "INVTYPE_WEAPON" or equipLoc == "INVTYPE_WEAPONMAINHAND" or equipLoc == "INVTYPE_WEAPONOFFHAND" then return "Weapon" end
    end
    if classID == 4 then
        if subClassID == 6 then return "Shield" end
        if subClassID == 0 then return "Relic" end
        return "Armor"
    end
    return "Armor"
end

function MSC.GetEnchantScore(enchantID, weights)
    if not enchantID or not MSC.EnchantDB[enchantID] then return 0 end
    local stats = MSC.EnchantDB[enchantID].stats
    if not stats then return 0 end
    local score = 0
    for stat, value in pairs(stats) do
        if weights[stat] then score = score + (value * weights[stat]) end
    end
    return score
end

function MSC.GetBestEnchantForSlot(slotId, level, specName, enchantType, weights)
    local candidates = (level < 60 and MSC.EnchantCandidates_Leveling and MSC.EnchantCandidates_Leveling[slotId])
    if not candidates or #candidates == 0 then candidates = MSC.EnchantCandidates and MSC.EnchantCandidates[slotId] end
    if not candidates then return nil end

    local bestID, bestScore = nil, -1
    for _, id in ipairs(candidates) do
        local data = MSC.EnchantDB[id]
        if data then
            local allowed = true
            if data.requires2H and enchantType ~= "2H" then allowed = false end
            if slotId == 17 then
                if enchantType == "Shield" and not data.isShield then allowed = false end
                if enchantType ~= "Shield" and data.isShield then allowed = false end
                if enchantType ~= "Weapon" and not data.isShield and not data.isScope then allowed = false end
            end
            if slotId == 18 and ((enchantType == "Bow" and not data.isScope) or (enchantType == "Relic")) then allowed = false end
            if allowed then
                local score = MSC.GetEnchantScore(id, weights)
                if score > bestScore then bestScore = score; bestID = id end
            end
        end
    end
    return (bestScore > 0) and bestID or nil
end

local function InferCurrentEnchantFromDelta(slotId, rawStats, baseRaw)
    if not slotId or not rawStats or not baseRaw or not MSC.EnchantDB then return nil end

    local candidates = MSC.EnchantCandidates and MSC.EnchantCandidates[slotId]
    if not candidates then return nil end

    local bestMatch, bestTotal = nil, 0

    for _, enchantID in ipairs(candidates) do
        local data = MSC.EnchantDB[enchantID]
        if data and data.stats then
            local matched = true
            local total = 0

            for statKey, statVal in pairs(data.stats) do
                if type(statVal) == "number" then
                    local rawDelta = math_max(0, (rawStats[statKey] or 0) - (baseRaw[statKey] or 0))
                    if math_abs(rawDelta - statVal) > 0.01 then
                        matched = false
                        break
                    end
                    total = total + statVal
                end
            end

            if matched then
                for statKey, rawVal in pairs(rawStats) do
                    if type(rawVal) == "number" then
                        local rawDelta = math_max(0, rawVal - (baseRaw[statKey] or 0))
                        local enchantVal = data.stats[statKey] or 0
                        if math_abs(rawDelta - enchantVal) > 0.01 then
                            matched = false
                            break
                        end
                    end
                end
            end

            if matched and total > bestTotal then
                bestMatch, bestTotal = data, total
            end
        end
    end

    return bestMatch
end

function MSC.GetBestGemForSocket(socketColor, level, weights, excludeList, isJC)
    local bestGem, bestScore = nil, 0
    local db = (level >= 60 and MSC.GemOptions) and MSC.GemOptions or MSC.GemOptions_Leveling
    if not db or not weights then return nil, 0 end
    
    -- Fetch the player's selected quality budget (Defaults to 3 / Rare)
    local maxQual = SGJ_Settings and SGJ_Settings.GemQuality or 3

    local lists = {}
    if socketColor == "ANY" then
        if db["EMPTY_SOCKET_RED"] then table_insert(lists, db["EMPTY_SOCKET_RED"]) end
        if db["EMPTY_SOCKET_YELLOW"] then table_insert(lists, db["EMPTY_SOCKET_YELLOW"]) end
        if db["EMPTY_SOCKET_BLUE"] then table_insert(lists, db["EMPTY_SOCKET_BLUE"]) end
    elseif socketColor == "EMPTY_SOCKET_META" then
        if db["EMPTY_SOCKET_META"] then table_insert(lists, db["EMPTY_SOCKET_META"]) end
    else
        if socketColor == "EMPTY_SOCKET_PRISMATIC" then
            if db["EMPTY_SOCKET_RED"] then table_insert(lists, db["EMPTY_SOCKET_RED"]) end
            if db["EMPTY_SOCKET_YELLOW"] then table_insert(lists, db["EMPTY_SOCKET_YELLOW"]) end
            if db["EMPTY_SOCKET_BLUE"] then table_insert(lists, db["EMPTY_SOCKET_BLUE"]) end
        else
            if db[socketColor] then table_insert(lists, db[socketColor]) end
        end
    end

    for _, list in ipairs(lists) do
        for _, gem in ipairs(list) do
            local isUniqueBlocked = (gem.unique and excludeList and excludeList[gem.id])
            local isJCBlocked = (gem.isJC and not isJC)
            
            -- Verify if the gem exceeds the player's chosen budget
            local gemQual = gem.quality or 3
            local isQualityBlocked = (gemQual > maxQual)

            if not isUniqueBlocked and not isJCBlocked and not isQualityBlocked then
                local score = 0
                if gem.stat and weights[gem.stat] then score = score + (gem.val * weights[gem.stat]) end
                if gem.stat2 and weights[gem.stat2] then score = score + (gem.val2 * weights[gem.stat2]) end
                if score > bestScore then bestScore = score; bestGem = gem end
            end
        end
    end
    return bestGem, bestScore
end

-- =============================================================
-- 8. GEM CACHE & LOOKUP
-- =============================================================
MSC.GemIDCache = {}

function MSC:BuildGemCache()
    local dbs = { MSC.GemOptions, MSC.GemOptions_Leveling }
    for _, db in ipairs(dbs) do
        if db then
            for _, list in pairs(db) do
                for _, gem in ipairs(list) do MSC.GemIDCache[gem.id] = gem end
            end
        end
    end
end

function MSC.GetGemStatsByID(gemID)
    if not gemID then return nil end
    local id = tonumber(gemID)
    if MSC.GemIDCache[id] then return MSC.GemIDCache[id] end
    MSC:BuildGemCache()
    return MSC.GemIDCache[id]
end

function MSC.GetGemColor(gemID)
    local gem = MSC.GetGemStatsByID(gemID)
    if gem and gem.colorType then return gem.colorType end
    local _, _, _, _, _, _, _, _, _, icon = GetItemInfo(gemID or 0)
    if icon then
        if string_find(icon, "Red") or string_find(icon, "Garnet") or string_find(icon, "Ruby") then return "RED"
        elseif string_find(icon, "Yellow") or string_find(icon, "Golden") or string_find(icon, "Dawnstone") then return "YELLOW"
        elseif string_find(icon, "Blue") or string_find(icon, "Azure") or string_find(icon, "Star") then return "BLUE"
        elseif string_find(icon, "Orange") or string_find(icon, "Topaz") then return "ORANGE"
        elseif string_find(icon, "Purple") or string_find(icon, "Nightseye") then return "PURPLE"
        elseif string_find(icon, "Green") or string_find(icon, "Talasite") then return "GREEN" end
    end
    return nil
end

function MSC.ApplyGemColorCount(gData, colors)
    if not gData or not gData.colorType or MSC.IsVanillaRules or not colors then return end
    local ct = gData.colorType
    if ct == "RED" then
        colors.RED = colors.RED + 1
    elseif ct == "BLUE" then
        colors.BLUE = colors.BLUE + 1
    elseif ct == "YELLOW" then
        colors.YELLOW = colors.YELLOW + 1
    elseif ct == "PURPLE" then
        colors.RED = colors.RED + 1
        colors.BLUE = colors.BLUE + 1
    elseif ct == "ORANGE" then
        colors.RED = colors.RED + 1
        colors.YELLOW = colors.YELLOW + 1
    elseif ct == "GREEN" then
        colors.BLUE = colors.BLUE + 1
        colors.YELLOW = colors.YELLOW + 1
    elseif ct == "PRISMATIC" then
        colors.RED = colors.RED + 1
        colors.BLUE = colors.BLUE + 1
        colors.YELLOW = colors.YELLOW + 1
    end
end

MSC.ColorMatchCache = MSC.ColorMatchCache or {}
MSC.ProcessedStatCache = MSC.ProcessedStatCache or {}

function MSC.SolveColorMatch(gemIDs, baseLink)
    local gemKey = table_concat(gemIDs, ",") .. "|" .. (baseLink or "")
    if MSC.ColorMatchCache[gemKey] ~= nil then
        return MSC.ColorMatchCache[gemKey]
    end

    local template = GetItemStats(baseLink) or {}
    local sockets = {}
    for i=1, (template["EMPTY_SOCKET_RED"] or 0) do table_insert(sockets, "RED") end
    for i=1, (template["EMPTY_SOCKET_YELLOW"] or 0) do table_insert(sockets, "YELLOW") end
    for i=1, (template["EMPTY_SOCKET_BLUE"] or 0) do table_insert(sockets, "BLUE") end
    if #sockets == 0 then return true end

    local function MatchRecursive(gemIdx, availableSockets)
        if gemIdx > #gemIDs then return #availableSockets == 0 end 
        if #availableSockets == 0 then return true end
        
        local gID = gemIDs[gemIdx]
        local gColor = MSC.GetGemColor(gID)
        
        if gColor then
            for i, sColor in ipairs(availableSockets) do
                local match = false
                if gColor == "PRISMATIC" then match = true
                elseif gColor == sColor then match = true
                elseif gColor == "ORANGE" and (sColor == "RED" or sColor == "YELLOW") then match = true
                elseif gColor == "PURPLE" and (sColor == "RED" or sColor == "BLUE") then match = true
                elseif gColor == "GREEN" and (sColor == "BLUE" or sColor == "YELLOW") then match = true
                end

                if match then
                    local nextSockets = { unpack(availableSockets) }
                    table_remove(nextSockets, i)
                    if MatchRecursive(gemIdx + 1, nextSockets) then return true end
                end
            end
        end
        return MatchRecursive(gemIdx + 1, availableSockets)
    end
    local matched = MatchRecursive(1, sockets)
    MSC.ColorMatchCache[gemKey] = matched
    return matched
end

function MSC.SafeGetItemStats(itemLink, slotId, weights, specName, globalUniques)
    if not itemLink then return {} end

    local enchantMode = SGJ_Settings and SGJ_Settings.EnchantMode or 1
    local gemMode = SGJ_Settings and SGJ_Settings.GemMode or 1
    local gemQuality = SGJ_Settings and SGJ_Settings.GemQuality or 3
    local uniqueKey = ""
    if globalUniques then
        local parts = {}
        for id, _ in pairs(globalUniques) do table_insert(parts, tostring(id)) end
        table_sort(parts)
        uniqueKey = table.concat(parts, ",")
    end
    local procKey = itemLink .. "|" .. tostring(slotId or 0) .. "|" .. tostring(specName or "") .. "|" .. enchantMode .. "|" .. gemMode .. "|" .. gemQuality .. "|" .. (MSC.ScoringRevision or 0) .. "|" .. uniqueKey
    if globalUniques and next(globalUniques) then
        -- skip cache when tracking unique-equipped gems across character score
    elseif weights and MSC.ProcessedStatCache and MSC.ProcessedStatCache[procKey] then
        return MSC:SafeCopy(MSC.ProcessedStatCache[procKey], {})
    end
    
    local rawStats = MSC.GetRawItemStats(itemLink)
    local finalStats = {}
    for k,v in pairs(rawStats) do if k ~= "_BONUS_STATS" then finalStats[k] = v end end
    if MSC.IsForever and finalStats.MSC_WEAPON_DPS and not finalStats.ITEM_MOD_DAMAGE_PER_SECOND_SHORT then finalStats.ITEM_MOD_DAMAGE_PER_SECOND_SHORT = finalStats.MSC_WEAPON_DPS end
    local bonusStats = rawStats._BONUS_STATS or {}
    local baseLink = MSC.GetBaseLink and MSC.GetBaseLink(itemLink) or nil
    local baseRaw = nil

    if baseLink and baseLink ~= itemLink then
        baseRaw = MSC.GetRawItemStats(baseLink)
        if not next(bonusStats) and baseRaw._BONUS_STATS and next(baseRaw._BONUS_STATS) then
            bonusStats = baseRaw._BONUS_STATS
        end
    end

    if not weights then return finalStats end
    
    local level = UnitLevel("player")
    
    local derivedSlotId = slotId
    if not derivedSlotId and MSC.SlotMap then
        local _, _, _, _, _, _, _, _, equipLoc = GetItemInfo(itemLink)
        if equipLoc then derivedSlotId = MSC.SlotMap[equipLoc] end
    end
    
    local physicalEnchantID = 0
    local currentEnchantData = nil
    local itemString = string_match(itemLink, "item[%-?%d:]+")
    if itemString then
        local _, _, eid = strsplit(":", itemString)
        physicalEnchantID = tonumber(eid) or 0
    end

    if physicalEnchantID > 0 and MSC.EnchantDB and MSC.EnchantDB[physicalEnchantID] then
        currentEnchantData = MSC.EnchantDB[physicalEnchantID]
    elseif baseRaw then
        currentEnchantData = InferCurrentEnchantFromDelta(derivedSlotId, rawStats, baseRaw)
    end

    if currentEnchantData and currentEnchantData.stats then
        for k, v in pairs(currentEnchantData.stats) do
            if type(v) == "number" then
                local removable = v
                if baseRaw then
                    removable = math_min(v, math_max(0, (rawStats[k] or 0) - (baseRaw[k] or 0)))
                elseif (finalStats[k] or 0) < v then
                    removable = 0
                end

                if removable > 0 then
                    finalStats[k] = math_max(0, (finalStats[k] or 0) - removable)
                end
            end
        end
    end

    if derivedSlotId and enchantMode ~= 1 then
        if enchantMode == 2 then
            local equippedLink = GetInventoryItemLink("player", derivedSlotId)
            if equippedLink then
                local eqEnchantID = 0
                local eqStr = string_match(equippedLink, "item[%-?%d:]+")
                if eqStr then
                    local _, _, eid = strsplit(":", eqStr)
                    eqEnchantID = tonumber(eid) or 0
                end
                
                if eqEnchantID > 0 and MSC.EnchantDB and MSC.EnchantDB[eqEnchantID] then
                    local eqData = MSC.EnchantDB[eqEnchantID]
                    if eqData.stats then
                        for k, v in pairs(eqData.stats) do
                            if type(v) == "number" then finalStats[k] = (finalStats[k] or 0) + v end
                        end
                    end
                    finalStats.IS_PROJECTED = true
                    finalStats.ENCHANT_TEXT = eqData.name .. " " .. MSC.L["(Equipped)"]
                end
            end
            
        elseif enchantMode == 3 then
            local enchantType = MSC:GetValidEnchantType(itemLink)
            if not enchantType and derivedSlotId then
                  local s = derivedSlotId
                  if s==1 or s==3 or s==5 or s==6 or s==7 or s==8 or s==9 or s==10 then enchantType = "Armor"
                  elseif s==15 then enchantType = "Armor" 
                  elseif s==17 then enchantType = "Shield"
                  end
            end

            if enchantType then
                local bestID = MSC.GetBestEnchantForSlot(derivedSlotId, level, specName, enchantType, weights)
                if bestID and MSC.EnchantDB[bestID] then
                    local bestData = MSC.EnchantDB[bestID]
                    if bestData.stats then
                        for k, v in pairs(bestData.stats) do 
                            if type(v) == "number" then finalStats[k] = (finalStats[k] or 0) + v end
                        end
                    end
                    finalStats.IS_PROJECTED = true
                    finalStats.ENCHANT_TEXT = bestData.name
                end
            end
        end
    end

    if not MSC.IsVanillaRules and gemMode ~= 1 then
        wipe(Scratch_GemTextParts); wipe(Scratch_ProjectedIDs); wipe(Scratch_GemCounts); wipe(Scratch_GemOrder)
        wipe(Scratch_GemStats); wipe(Scratch_GemColors); wipe(Scratch_ProjectedColors)
        Scratch_ProjectedColors.RED=0; Scratch_ProjectedColors.YELLOW=0; Scratch_ProjectedColors.BLUE=0
        local projectedMeta = nil
        local isJC = MSC:IsJewelcrafter() -- Grabbing JC Status

        if gemMode == 1 then
            for k, v in pairs(bonusStats) do finalStats[k] = (finalStats[k] or 0) + v end
        else
            local baseLink = MSC.GetBaseLink(itemLink)
            local socketsToFill = {}
            local existingGems = {}
            
            if gemMode == 3 then
                local currentGems = { string_match(itemLink, "item:%d+:%d+:(%d+):(%d+):(%d+):(%d+)") }
                for _, gID in ipairs(currentGems) do
                    local id = tonumber(gID)
                    if id and id > 0 and MSC.GetGemStatsByID then
                        local gData = MSC.GetGemStatsByID(id)
                        if gData then
                            if gData.stat then finalStats[gData.stat] = math_max(0, (finalStats[gData.stat] or 0) - (gData.val or 0)) end
                            if gData.stat2 then finalStats[gData.stat2] = math_max(0, (finalStats[gData.stat2] or 0) - (gData.val2 or 0)) end
                        end
                    end
                end
                socketsToFill = GetItemStats(baseLink) or {} 
                
            elseif gemMode == 2 then
                socketsToFill = GetItemStats(itemLink) or {} 
                local _, _, ids = MSC:GetItemGems(itemLink)
                for _, id in ipairs(ids) do table_insert(existingGems, id) end
                for _, gID in ipairs(existingGems) do
                    local id = tonumber(gID)
                    if id and id > 0 then
                        local gData = MSC.GetGemStatsByID(id)
                        if gData then
                            if gData.stat then finalStats[gData.stat] = math_max(0, (finalStats[gData.stat] or 0) - (gData.val or 0)) end
                            if gData.stat2 then finalStats[gData.stat2] = math_max(0, (finalStats[gData.stat2] or 0) - (gData.val2 or 0)) end
                        end
                    end
                end
            end

            local totalSockets = 0
            for _, colorKey in ipairs({"EMPTY_SOCKET_RED", "EMPTY_SOCKET_YELLOW", "EMPTY_SOCKET_BLUE", "EMPTY_SOCKET_META", "EMPTY_SOCKET_PRISMATIC"}) do
                totalSockets = totalSockets + (socketsToFill[colorKey] or 0)
            end
            local totalFilled = 0
            for _, gID in ipairs(existingGems) do
                if tonumber(gID) and tonumber(gID) > 0 then totalFilled = totalFilled + 1 end
            end
            local socketsLeftToProject = math_max(0, totalSockets - totalFilled)

            for _, gID in ipairs(existingGems) do
                MSC.ApplyGemColorCount(MSC.GetGemStatsByID(gID), Scratch_ProjectedColors)
            end

            if MSC.GetBaseLink and MSC.GetBestGemForSocket then
                wipe(Scratch_MatchGems); wipe(Scratch_PureGems)
                local matchScore = 0; local pureScore = 0
                local socketKeys = {"EMPTY_SOCKET_RED", "EMPTY_SOCKET_YELLOW", "EMPTY_SOCKET_BLUE", "EMPTY_SOCKET_META", "EMPTY_SOCKET_PRISMATIC"}

                local uniqueTrackerMatch = globalUniques and MSC:SafeCopy(globalUniques) or {} 
                for _, colorKey in ipairs(socketKeys) do
                    local count = socketsToFill[colorKey] or 0
                    for i=1, count do
                        if gemMode == 2 and socketsLeftToProject <= 0 then break end
                        local bestGem, score = MSC.GetBestGemForSocket(colorKey, level, weights, uniqueTrackerMatch, isJC)
                        if bestGem then 
                            matchScore = matchScore + score
                            table_insert(Scratch_MatchGems, bestGem)
                            if bestGem.unique then uniqueTrackerMatch[bestGem.id] = true end
                            if gemMode == 2 then socketsLeftToProject = socketsLeftToProject - 1 end
                        end
                    end
                end
                local matchCandidateIDs = { unpack(existingGems) }
                for _, g in ipairs(Scratch_MatchGems) do table_insert(matchCandidateIDs, g.id) end
                local matchBonusActive = MSC.SolveColorMatch(matchCandidateIDs, baseLink)
                if matchBonusActive and next(bonusStats) then
                      for k,v in pairs(bonusStats) do if weights[k] then matchScore = matchScore + (v * weights[k]) end end
                end

                if gemMode == 3 then
                    local uniqueTrackerPure = globalUniques and MSC:SafeCopy(globalUniques) or {}
                    for _, colorKey in ipairs(socketKeys) do
                        local count = socketsToFill[colorKey] or 0
                        for i=1, count do
                            local searchKey = (colorKey == "EMPTY_SOCKET_META") and "EMPTY_SOCKET_META" or "ANY"
                            local bestGem, score = MSC.GetBestGemForSocket(searchKey, level, weights, uniqueTrackerPure, isJC)
                            if bestGem then 
                                pureScore = pureScore + score
                                table_insert(Scratch_PureGems, bestGem)
                                if bestGem.unique then uniqueTrackerPure[bestGem.id] = true end
                            end
                        end
                    end
                    local pureCandidateIDs = { unpack(existingGems) }
                    for _, g in ipairs(Scratch_PureGems) do table_insert(pureCandidateIDs, g.id) end
                    local pureBonusActive = MSC.SolveColorMatch(pureCandidateIDs, baseLink)
                    if pureBonusActive and next(bonusStats) then
                         for k,v in pairs(bonusStats) do if weights[k] then pureScore = pureScore + (v * weights[k]) end end
                    end
                end

                local usePure = (gemMode == 3) and (pureScore > matchScore)
                local chosenGems = usePure and Scratch_PureGems or Scratch_MatchGems
                local bonusActive = usePure and (MSC.SolveColorMatch(MSC:SafeCopy(existingGems), baseLink)) or matchBonusActive 
                
                if globalUniques then
                    for _, gem in ipairs(chosenGems) do
                        if gem.unique then globalUniques[gem.id] = true end
                    end
                end 
                if usePure then
                    local allGems = { unpack(existingGems) }
                    for _, g in ipairs(Scratch_PureGems) do table_insert(allGems, g.id) end
                    bonusActive = MSC.SolveColorMatch(allGems, baseLink)
                end
                
                for _, gem in ipairs(chosenGems) do
                    if gem.stat then 
                        finalStats[gem.stat] = (finalStats[gem.stat] or 0) + gem.val 
                        Scratch_GemStats[gem.stat] = (Scratch_GemStats[gem.stat] or 0) + gem.val 
                    end
                    if gem.stat2 then 
                        finalStats[gem.stat2] = (finalStats[gem.stat2] or 0) + gem.val2 
                        Scratch_GemStats[gem.stat2] = (Scratch_GemStats[gem.stat2] or 0) + gem.val2 
                    end
                    if gem.isMeta then projectedMeta = gem.id end
                    MSC.ApplyGemColorCount(gem.colorType and gem or MSC.GetGemStatsByID(gem.id), Scratch_ProjectedColors)
                    table_insert(Scratch_ProjectedIDs, gem.id)
                end
                
                if bonusActive and next(bonusStats) then
                    for k, v in pairs(bonusStats) do 
                        finalStats[k] = (finalStats[k] or 0) + v 
                        Scratch_GemStats[k] = (Scratch_GemStats[k] or 0) + v
                    end
                    finalStats.BONUS_PROJECTED = true
                end
                
                local function AddToDisplay(id)
                    local gName = GetItemInfo(id)
                    local cType = MSC.GetGemColor(id) or "Unknown"
                    if type(cType) == "string" then cType = cType:sub(1,1)..cType:sub(2):lower() end
                    if not gName then 
                        local g = MSC.GetGemStatsByID(id)
                        gName = g and (MSC.StatShortNames[g.stat] or MSC.L["Gem"]) or MSC.L["Gem"]
                    end
                    if not Scratch_GemCounts[gName] then
                        Scratch_GemCounts[gName] = 0; Scratch_GemColors[gName] = cType; table_insert(Scratch_GemOrder, gName)
                    end
                    Scratch_GemCounts[gName] = Scratch_GemCounts[gName] + 1
                end
                for _, id in ipairs(existingGems) do AddToDisplay(id) end
                for _, gem in ipairs(chosenGems) do AddToDisplay(gem.id) end
                
                finalStats.PROJECTION_DATA = { Gems = {}, Bonus = nil, Stats = "" }
                for _, gName in ipairs(Scratch_GemOrder) do
                    table_insert(finalStats.PROJECTION_DATA.Gems, { text = Scratch_GemCounts[gName] .. "x " .. gName, color = Scratch_GemColors[gName] })
                end
                if bonusActive and next(bonusStats) then
                    local bParts = {}
                    for k, v in pairs(bonusStats) do table_insert(bParts, "+" .. v .. " " .. ((MSC.StatShortNames and MSC.StatShortNames[k]) or "Stat")) end
                    finalStats.PROJECTION_DATA.Bonus = MSC.L["Socket Bonus: "] .. table_concat(bParts, ", ")
                end
                local statParts = {}
                for k, v in pairs(Scratch_GemStats) do
                    local short = (MSC.StatShortNames and MSC.StatShortNames[k]) or MSC.L["Stat"]
                    table_insert(statParts, "+" .. v .. " " .. short)
                end
                if #statParts > 0 then finalStats.PROJECTION_DATA.Stats = "(" .. table_concat(statParts, ", ") .. ")" end

                finalStats.GEMS_PROJECTED = #finalStats.PROJECTION_DATA.Gems
                finalStats.META_ID = projectedMeta
                finalStats.COLORS = MSC:SafeCopy(Scratch_ProjectedColors)
            end
        end
    end
    -- Relics (Libram 7, Idol 8, Totem 9): their effects are text the parser
    -- can't read, so add the class's equivalent stats for this spec. (Before
    -- this, GetRelicBonus only fed a tooltip note and relics scored ~0.)
    if MSC.CurrentClass and MSC.CurrentClass.GetRelicBonus and GetItemInfoInstant then
        local relicID, _, _, _, _, relicClassID, relicSubClassID = GetItemInfoInstant(itemLink)
        if relicClassID == 4 and (relicSubClassID == 7 or relicSubClassID == 8 or relicSubClassID == 9) then
            local ok, bonus = pcall(MSC.CurrentClass.GetRelicBonus, MSC.CurrentClass, relicID, specName or MSC.CachedSpecKey or "")
            if ok and type(bonus) == "table" then
                for k, v in pairs(bonus) do
                    if type(v) == "number" and v > 0 then finalStats[k] = (finalStats[k] or 0) + v end
                end
            end
        end
    end
    -- Weapon types a class can equip but not attack with (Forever Hunters
    -- and thrown weapons: Auto Shot and shots need a bow, gun or crossbow)
    -- are scored on their stats only, so their DPS can't beat a real bow.
    local statsOnly = MSC.CurrentClass and MSC.CurrentClass.StatsOnlyWeapons
    if statsOnly and GetItemInfoInstant then
        local _, _, _, _, _, itemClassID, itemSubClassID = GetItemInfoInstant(itemLink)
        if itemClassID == 2 and statsOnly[itemSubClassID] then
            finalStats.ITEM_MOD_DAMAGE_PER_SECOND_SHORT = nil
            finalStats.MSC_WEAPON_DPS = nil
            finalStats.MSC_WEAPON_SPEED = nil
        end
    end
    if weights and MSC.ProcessedStatCache and not (globalUniques and next(globalUniques)) then
        MSC.ProcessedStatCache[procKey] = MSC:SafeCopy(finalStats, {})
    end
    return finalStats
end

-- =============================================================
-- 9. MISC HELPERS
-- =============================================================
function MSC.GetInterpolatedRatio(table, level)
    if not table then return nil end
    if level <= table[1][1] then return table[1][2] end
    local count = #table
    if level >= table[count][1] then return table[count][2] end
    for i = 1, count - 1 do
        local lowNode, highNode = table[i], table[i+1]
        if level >= lowNode[1] and level <= highNode[1] then
            return lowNode[2] + ((level - lowNode[1]) / (highNode[1] - lowNode[1])) * (highNode[2] - lowNode[2])
        end
    end
    return table[count][2]
end

function MSC.ExpandDerivedStats(stats, itemLink, dest)
    if not dest then dest = {} end
    wipe(dest)
    if not stats then return dest end
    for k, v in pairs(stats) do dest[k] = v end
    return dest
end

function MSC.GetBaseLink(itemLink)
    if not itemLink then return nil end
    local id = string_match(itemLink, "item:(%d+)")
    if id then return "item:" .. id .. ":0:0:0:0:0:0:0:0" end
    return itemLink
end

-- =============================================================
-- 10. SCORING ENGINE
-- =============================================================
function MSC.GetItemScore(stats, weights, specName, slotId)
    if not stats or not weights then return 0 end
    if stats._MANUAL_SCORE and stats._MANUAL_SCORE > 0 then
        return math_max(0, MSC.Round(stats._MANUAL_SCORE, 1))
    end
    local score = 0
    local usefulRaw = 0
    local uselessRaw = 0
    -- Forever items carry raw Combat Ratings (e.g. "+10 Hit Rating"), confirmed
    -- against real datamined items (foreverchanges.pro) and this file's own
    -- CombatRatingScalars table -- 10 rating = 1% Hit at level 60, etc. Every
    -- class's Hit/Crit/Weapon Skill/Defense/Dodge/Parry weight was calibrated
    -- as "points per 1% (or per 1 skill point)", so the raw rating value must
    -- be converted through that same table before being multiplied by weight,
    -- or it overvalues those stats by the rating-per-percent factor (10x-22x
    -- depending on stat/level). GetRatingPercent already does this exact
    -- conversion for the tooltip's cosmetic display text; reusing it here
    -- fixes every class/profile's rating stats in one place.
    local foreverLevel = MSC.IsForever and UnitLevel("player")

    for stat, val in pairs(stats) do
        if stat == "_MANUAL_SCORE" or stat == "_AUTO_PROC" or stat == "IS_PROJECTED" or stat == "GEMS_PROJECTED" or stat == "BONUS_PROJECTED" then
            -- metadata keys
        elseif type(val) == "number" then
            local weightKey = stat
            local isWeaponDps = (stat == "MSC_WEAPON_DPS" or stat == "ITEM_MOD_DAMAGE_PER_SECOND_SHORT")
            if isWeaponDps and (slotId == 16 or slotId == 17) then
                -- MSC_WEAPON_DPS_MELEE: a class module can set this in ApplyScalers
                -- when its Weapon DPS weight is anchored to the ranged slot (e.g. a
                -- ranged Hunter, whose melee weapon is mostly a stat stick).
                if slotId == 17 and weights["MSC_WEAPON_DPS_OH"] then weightKey = "MSC_WEAPON_DPS_OH"
                elseif weights["MSC_WEAPON_DPS_MELEE"] then weightKey = "MSC_WEAPON_DPS_MELEE" end
            end
            if slotId == 17 and stat == "MSC_WEAPON_SPEED" then
                if weights["MSC_OH_WEAPON_SPEED"] then weightKey = "MSC_OH_WEAPON_SPEED" end
            end
            -- Forever's speed weights model melee swings; a bow/gun/wand's
            -- speed in the ranged slot shouldn't inherit them. (TBC Hunter
            -- profiles weight ranged speed on purpose, so Forever only.)
            if MSC.IsForever and slotId == 18 and stat == "MSC_WEAPON_SPEED" then weightKey = "MSC_RANGED_WEAPON_SPEED" end
            
            local w = weights[weightKey] or 0
            
            -- [[ WoW Forever Stat Unifications ]]
            if MSC.IsForever then
                if stat == "ITEM_MOD_HIT_RATING_SHORT" or stat == "ITEM_MOD_HIT_SPELL_RATING_SHORT" or stat == "ITEM_MOD_HIT_MELEE_RATING_SHORT" or stat == "ITEM_MOD_HIT_RANGED_RATING_SHORT" then
                    w = math_max(w, weights["ITEM_MOD_HIT_RATING_SHORT"] or 0, weights["ITEM_MOD_HIT_SPELL_RATING_SHORT"] or 0, weights["ITEM_MOD_HIT_MELEE_RATING_SHORT"] or 0, weights["ITEM_MOD_HIT_RANGED_RATING_SHORT"] or 0)
                elseif stat == "ITEM_MOD_CRIT_RATING_SHORT" or stat == "ITEM_MOD_SPELL_CRIT_RATING_SHORT" or stat == "ITEM_MOD_CRIT_MELEE_RATING_SHORT" or stat == "ITEM_MOD_CRIT_RANGED_RATING_SHORT" then
                    w = math_max(w, weights["ITEM_MOD_CRIT_RATING_SHORT"] or 0, weights["ITEM_MOD_SPELL_CRIT_RATING_SHORT"] or 0, weights["ITEM_MOD_CRIT_MELEE_RATING_SHORT"] or 0, weights["ITEM_MOD_CRIT_RANGED_RATING_SHORT"] or 0)
                elseif stat == "ITEM_MOD_SPELL_DAMAGE_DONE_SHORT" and w == 0 then
                    -- "+X Spell Damage" is damage-only (Parse.lua keeps it apart
                    -- from Spell Power), so it's worth the profile's Spell Power
                    -- weight -- but unlike Spell Power it is never folded into
                    -- healing (Evaluator only folds ITEM_MOD_SPELL_POWER_SHORT).
                    w = weights["ITEM_MOD_SPELL_POWER_SHORT"] or 0
                end
            end

            if w > 0 then
                local finalVal = val
                if foreverLevel and MSC.RatingIndexMap[stat] then
                    local converted = MSC:GetRatingPercent(stat, val, foreverLevel)
                    if converted then finalVal = converted end
                end
                if slotId == 17 and isWeaponDps and weightKey ~= "MSC_WEAPON_DPS_OH" then finalVal = val * 0.5 end
                score = score + (finalVal * w)
                if w >= 0.02 then usefulRaw = usefulRaw + val else uselessRaw = uselessRaw + val end
            end
            -- Spell Power also heals, so its healing half scores at the
            -- Healing weight. This used to happen only on the full-character
            -- path (Evaluator folded SP into Healing there), so tooltips and
            -- upgrade arrows under-scored Spell Power for healer profiles.
            if stat == "ITEM_MOD_SPELL_POWER_SHORT" then
                local hw = weights["ITEM_MOD_SPELL_HEALING_DONE_SHORT"] or 0
                if hw > 0 then
                    score = score + (val * hw)
                    if w < 0.02 then usefulRaw = usefulRaw + val end
                end
            end
            -- (No implicit "+Healing grants 1/3 as Spell Power" bonus on Forever:
            -- its items print that third explicitly as a separate "+X Spell
            -- Damage" line -- e.g. Holy Shroud is +33 Healing / +11 Spell
            -- Damage -- and 77 healing items carry no damage at all, so
            -- inferring one double-counted it.)
        end
    end
    
    local bonusScore = 0
    if SGJ_Settings and SGJ_Settings.AssumeCampingBuffs and MSC.IsForever then
        if (slotId == 16 or slotId == 17) and stats["MSC_WEAPON_SPEED"] and stats["MSC_WEAPON_SPEED"] > 0 then
            local bonusDamage = 2 -- Placeholder for early game Rough Sharpening/Weightstone
            local bonusDps = bonusDamage / stats["MSC_WEAPON_SPEED"]
            local w = weights["MSC_WEAPON_DPS"] or 0
            if slotId == 17 and weights["MSC_WEAPON_DPS_OH"] then
                w = weights["MSC_WEAPON_DPS_OH"]
            elseif slotId == 17 then
                bonusDps = bonusDps * 0.5 -- native OH penalty if OH weight not distinct
            end
            bonusScore = bonusScore + (bonusDps * w)
        end
    end
    score = score + bonusScore

    
    if not MSC.IsVanillaRules and stats["ITEM_MOD_RESILIENCE_RATING_SHORT"] then
        local resVal = stats["ITEM_MOD_RESILIENCE_RATING_SHORT"]
        local resWeight = weights["ITEM_MOD_RESILIENCE_RATING_SHORT"] or 0
        if resVal > 0 and resWeight <= 0.05 then score = score - (resVal * 1.5) end
    end

    if uselessRaw > (usefulRaw * 2) then return 0 end
    return math_max(0, MSC.Round(score, 1))
end

function MSC.ApplyElvUISkin(frame) end

-- =============================================================
-- 11. EXTERNAL HELPERS
-- =============================================================
function MSC:GetItemSetID(itemIDOrLink)
    if not itemIDOrLink then return nil end
    local _, _, _, _, _, _, _, _, _, _, _, _, _, _, setID = GetItemInfo(itemIDOrLink)
    if setID then return setID end
    local tipName = "MSC_ScannerTooltip"
    local tip = _G[tipName] or CreateFrame("GameTooltip", tipName, nil, "GameTooltipTemplate")
    tip:SetOwner(WorldFrame, "ANCHOR_NONE"); tip:ClearLines()
    local status = pcall(function() tip:SetHyperlink(itemIDOrLink) end)
    if status then
        for i = 2, tip:NumLines() do
            local line = _G[tipName.."TextLeft"..i]
            local text = line and line:GetText()
            local setPattern = MSC.L["^Set: (.*) %("] or "^Set: (.*) %("
				if string_find(text, MSC.L["Set: "] or "Set: ") then
					local setName = string_match(text, setPattern)
					return setName
				end
            end
        end
    return nil
end

local Scratch_ItemColors = { RED=0, YELLOW=0, BLUE=0 }
local Scratch_ItemGemIDs = {}

function MSC:GetItemGems(itemLink)
    Scratch_ItemColors.RED = 0; Scratch_ItemColors.YELLOW = 0; Scratch_ItemColors.BLUE = 0; wipe(Scratch_ItemGemIDs)
    local metaID = nil
    if not itemLink then return MSC:SafeCopy(Scratch_ItemColors), nil, MSC:SafeCopy(Scratch_ItemGemIDs) end
    
    local g1, g2, g3, g4 = string_match(itemLink, "item:%d+:%d+:(%d+):(%d+):(%d+):(%d+)")
    local foundGems = { tonumber(g1), tonumber(g2), tonumber(g3), tonumber(g4) }
    
    for _, id in ipairs(foundGems) do
        if id and id > 0 then
            table_insert(Scratch_ItemGemIDs, id)
            if MSC.GemOptions and MSC.GemOptions["EMPTY_SOCKET_META"] then
                for _, g in ipairs(MSC.GemOptions["EMPTY_SOCKET_META"]) do if g.id == id then metaID = id; break end end
            end
            local cType = MSC.GetGemColor and MSC.GetGemColor(id)
            if cType then
                if cType == "RED" then Scratch_ItemColors.RED = Scratch_ItemColors.RED + 1
                elseif cType == "YELLOW" then Scratch_ItemColors.YELLOW = Scratch_ItemColors.YELLOW + 1
                elseif cType == "BLUE" then Scratch_ItemColors.BLUE = Scratch_ItemColors.BLUE + 1
                elseif cType == "ORANGE" then Scratch_ItemColors.RED = Scratch_ItemColors.RED + 1; Scratch_ItemColors.YELLOW = Scratch_ItemColors.YELLOW + 1
                elseif cType == "PURPLE" then Scratch_ItemColors.RED = Scratch_ItemColors.RED + 1; Scratch_ItemColors.BLUE = Scratch_ItemColors.BLUE + 1
                elseif cType == "GREEN" then Scratch_ItemColors.YELLOW = Scratch_ItemColors.YELLOW + 1; Scratch_ItemColors.BLUE = Scratch_ItemColors.BLUE + 1
                elseif cType == "PRISMATIC" then Scratch_ItemColors.RED = Scratch_ItemColors.RED + 1; Scratch_ItemColors.YELLOW = Scratch_ItemColors.YELLOW + 1; Scratch_ItemColors.BLUE = Scratch_ItemColors.BLUE + 1 end
            end
        end
    end
    return MSC:SafeCopy(Scratch_ItemColors), metaID, MSC:SafeCopy(Scratch_ItemGemIDs)
end

-- =============================================================
-- 12. DEBUG
-- =============================================================
function MSC:DebugItem()
    local tip = GameTooltip
    local _, link = tip:GetItem()
    if not link then print(MSC.L["|cffff0000SGJ: Please hover over an item to debug.|r"]) return end
    local weights, specName = MSC.GetCurrentWeights()
    if not weights then print(MSC.L["|cffff0000SGJ: No weights loaded.|r"]) return end
    local stats = MSC.SafeGetItemStats(link, nil, weights, specName)
    local score = 0
    print(" ")
    print(MSC.L["|cff00ccff--- SGJ DEBUG REPORT ---|r"])
	print(MSC.L["Item: "] .. link)
	print(MSC.L["Profile: "] .. "|cffffd100" .. (specName or MSC.L["Unknown"]) .. "|r")
    for stat, val in pairs(stats) do
        if type(val) == "number" then
            local w = weights[stat]
            if w then
                local lineScore = val * w
                score = score + lineScore
                local statName = string_gsub(string_gsub(stat, "ITEM_MOD_", ""), "_SHORT", "")
                print(string_format(MSC.L["|cffffffff%s:|r %.1f x %.2f = |cff00ff00%.1f|r"], statName, val, w, lineScore))
            else
                local statName = string_gsub(string_gsub(stat, "ITEM_MOD_", ""), "_SHORT", "")
                print(string_format(MSC.L["|cff888888%s: %.1f (Weight: 0)|r"], statName, val))
            end
        end
    end
    local useful, useless = 0, 0
    for stat, val in pairs(stats) do
        if type(val) == "number" then
            if (weights[stat] or 0) >= 0.1 then useful = useful + val else useless = useless + val end
        end
    end
		print(MSC.L["Ratio Check: "] .. string_format(MSC.L["Useful: %.1f / Useless: %.1f"], useful, useless))
		if useless > (useful * 2) then 
			print(MSC.L["|cffff0000[FAIL] Item rejected by Bouncer (Mostly Junk)|r"])
		else 
			print(MSC.L["|cff00ff00[PASS] Item accepted|r"]) 
		end
		print(MSC.L["Final Score: "] .. "|cff00ccff" .. MSC.Round(score, 1) .. "|r")
end

function MSC:GetDefenseFloor(rule)
    -- Forever: the same target the tank scalers use (none below 50, then
    -- sliding to 440 by 60), so the "don't drop below" check agrees with them.
    if MSC.IsForever and rule and rule.dynamic and MSC.GetForeverDefenseTarget then
        return MSC.GetForeverDefenseTarget() or math.huge
    end
    if rule and rule.dynamic then
        return UnitLevel("player") * 5 + 140
    end
    return rule and rule.base or 0
end

-- =============================================================
-- 13. LOAD SAVED WEIGHTS (Startup Race Condition Handler)
-- =============================================================
local dbLoader = CreateFrame("Frame")
dbLoader:RegisterEvent("PLAYER_LOGIN")
dbLoader:SetScript("OnEvent", function()
    C_Timer.After(0.5, function()
        if SharpiesGearJudgeDB and SharpiesGearJudgeDB.customWeights and SGJ_Settings then
            local mode = SGJ_Settings.Mode
            if mode and mode ~= "AUTO" and SharpiesGearJudgeDB.customWeights[mode] then
                MSC.CachedWeights = nil
                MSC.CachedWeightsBySpec = MSC.CachedWeightsBySpec or {}
                wipe(MSC.CachedWeightsBySpec)
                if MSC.BumpScoringRevision then MSC:BumpScoringRevision() end
            end
        end
        if MSC.InitSettingsView and MSC.MainFrame and MSC.MainFrame:IsShown() then
            MSC.InitSettingsView(MSC.MainFrame.Content)
        end
    end)
end)

-- =============================================================
-- 14. COMBAT LAB: ON-USE TRINKET DETECTION
-- =============================================================
function MSC.IsValuableOnUseTrinket(itemID)
    if not itemID then return false end

    -- Search the three primary databases where you store trinket data
    local data = MSC.TrinketDB[itemID] or MSC.ItemOverrides[itemID] or MSC.ProcDB[itemID]

    if data and data.note then
        local noteStr = tostring(data.note)
        
        -- We only care about trinkets that have an active "Use:" effect
        if string.find(noteStr, "Use:") then
            -- We want to pop throughput stats during Burn Phases. 
            -- This filters out Defensive/Health/Utility trinkets.
            if string.find(noteStr, "AP") or 
               string.find(noteStr, "SP") or 
               string.find(noteStr, "Haste") or 
               string.find(noteStr, "Heal") or 
               string.find(noteStr, "Damage") or
               string.find(noteStr, "Crit") then
                return true
            end
        end
    end
    
    return false
end
