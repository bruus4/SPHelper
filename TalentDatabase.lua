------------------------------------------------------------------------
-- SPHelper  â€“  TalentDatabase.lua
-- Comprehensive talent definitions for TBC Classic, imported from NAG
-- schema and mapped to our tab/index system. Used for validation,
-- display, and rotation logic that depends on specific talents.
------------------------------------------------------------------------
local A = SPHelper

A.TalentDatabase = A.TalentDatabase or {}
local TD = A.TalentDatabase

------------------------------------------------------------------------
-- Schema notes:
-- Each talent entry uses the format:
--   ["TalentName"] = {
--       class      = "CLASS",          -- e.g. "DRUID", "PRIEST"
--       tab        = 1,                -- Talent tree (1-based)
--       index      = 5,                -- Position in tree (1-based)
--       maxRank    = 3,                -- Maximum ranks available
--       label      = "Talent Name",    -- In-game display name
--       effects    = { ... },          -- Array of effect descriptions
--       spellId    = 12345,            -- Associated spell (if any)
--   }
------------------------------------------------------------------------

TD.talents = {}

------------------------------------------------------------------------
-- DRUID â€“ Balance Tree (Tab 1)
------------------------------------------------------------------------
local druidBalance = {
    ["Starlight Wrath"] = { class = "DRUID", tab = 1, index = 1, maxRank = 5 },
    ["Nature's Grasp"] = { class = "DRUID", tab = 1, index = 2, maxRank = 1 },
    ["Improved Nature's Grasp"] = { class = "DRUID", tab = 1, index = 3, maxRank = 5 },
    ["Control of Nature"] = { class = "DRUID", tab = 1, index = 4, maxRank = 2 },
    ["Focused Starlight"] = { class = "DRUID", tab = 1, index = 5, maxRank = 5 },
    ["Improved Moonfire"] = { class = "DRUID", tab = 1, index = 6, maxRank = 3 },
    ["Brambles"] = { class = "DRUID", tab = 1, index = 7, maxRank = 2 },
    ["Insect Swarm"] = { class = "DRUID", tab = 1, index = 8, maxRank = 1 },
    ["Nature's Reach"] = { class = "DRUID", tab = 1, index = 9, maxRank = 5 },
    ["Vengeance"] = { class = "DRUID", tab = 1, index = 10, maxRank = 3 },
    ["Celestial Focus"] = { class = "DRUID", tab = 1, index = 11, maxRank = 2 },
    ["Lunar Guidance"] = { class = "DRUID", tab = 1, index = 12, maxRank = 5 },
    ["Nature's Grace"] = { class = "DRUID", tab = 1, index = 13, maxRank = 1, spellId = 16886 },
    ["Moonglow"] = { class = "DRUID", tab = 1, index = 14, maxRank = 5 },
    ["Moonfury"] = { class = "DRUID", tab = 1, index = 15, maxRank = 3 },
    ["Balance of Power"] = { class = "DRUID", tab = 1, index = 16, maxRank = 2 },
    ["Dreamstate"] = { class = "DRUID", tab = 1, index = 17, maxRank = 5 },
    ["Moonkin Form"] = { class = "DRUID", tab = 1, index = 18, maxRank = 1, spellId = 24858 },
    ["Improved Faerie Fire"] = { class = "DRUID", tab = 1, index = 19, maxRank = 3 },
    ["Wrath of Cenarius"] = { class = "DRUID", tab = 1, index = 20, maxRank = 5 },
}

------------------------------------------------------------------------
-- DRUID â€“ Feral Combat Tree (Tab 2)
------------------------------------------------------------------------
local druidFeral = {
    ["Ferocity"] = { class = "DRUID", tab = 2, index = 1, maxRank = 3 },
    ["Savage Fury"] = { class = "DRUID", tab = 2, index = 2, maxRank = 5 },
    ["Feral Aggression"] = { class = "DRUID", tab = 2, index = 3, maxRank = 2 },
    ["Ferocious Instincts"] = { class = "DRUID", tab = 2, index = 4, maxRank = 5 },
    ["Feral Swiftness"] = { class = "DRUID", tab = 2, index = 5, maxRank = 3 },
    ["Improved Rake"] = { class = "DRUID", tab = 2, index = 6, maxRank = 2 },
    ["Omen of Clarity"] = { class = "DRUID", tab = 2, index = 7, maxRank = 5 },
    ["Feral Charge (Cat)"] = { class = "DRUID", tab = 2, index = 8, maxRank = 1, spellId = 16689 },
    ["Predatory Strikes"] = { class = "DRUID", tab = 2, index = 9, maxRank = 5 },
    ["Improved Faerie Fire (Feral)"] = { class = "DRUID", tab = 2, index = 10, maxRank = 3 },
    ["Impaling Claw"] = { class = "DRUID", tab = 2, index = 11, maxRank = 5 },
    ["Improved Lacerate"] = { class = "DRUID", tab = 2, index = 12, maxRank = 3 },
    ["Shred"] = { class = "DRUID", tab = 2, index = 13, maxRank = 5 },
    ["Feral Charge (Bear)"] = { class = "DRUID", tab = 2, index = 14, maxRank = 1, spellId = 9634 },
    ["Bash (Cat)"] = { class = "DRUID", tab = 2, index = 15, maxRank = 1, spellId = 8984 },
    ["Feral Spirit"] = { class = "DRUID", tab = 2, index = 16, maxRank = 3 },
    ["Mangle (Cat)"] = { class = "DRUID", tab = 2, index = 17, maxRank = 5, spellId = 33876 },
    ["Heart of the Wild"] = { class = "DRUID", tab = 2, index = 18, maxRank = 1, spellId = 48439 },
    ["Primal Fury"] = { class = "DRUID", tab = 2, index = 19, maxRank = 5 },
}

------------------------------------------------------------------------
-- DRUID â€“ Restoration Tree (Tab 3)
------------------------------------------------------------------------
local druidResto = {
    ["Furor"] = { class = "DRUID", tab = 3, index = 1, maxRank = 5 },
    ["Improved Mark of the Wild"] = { class = "DRUID", tab = 3, index = 2, maxRank = 3 },
    ["Nature's Swiftness"] = { class = "DRUID", tab = 3, index = 3, maxRank = 1, spellId = 16870 },
    ["Improved Entangling Roots"] = { class = "DRUID", tab = 3, index = 4, maxRank = 2 },
    ["Natural Shapeshifter"] = { class = "DRUID", tab = 3, index = 5, maxRank = 5 },
    ["Improved Tranquility"] = { class = "DRUID", tab = 3, index = 6, maxRank = 2 },
    ["Nourish"] = { class = "DRUID", tab = 3, index = 7, maxRank = 1, spellId = 50485 },
    ["Improved Rejuvenation"] = { class = "DRUID", tab = 3, index = 8, maxRank = 2 },
    ["Naturalist"] = { class = "DRUID", tab = 3, index = 9, maxRank = 5 },
    ["Improved Healing Touch"] = { class = "DRUID", tab = 3, index = 10, maxRank = 3 },
    ["Gift of Nature"] = { class = "DRUID", tab = 3, index = 11, maxRank = 2 },
    ["Empowered Rejuvenation"] = { class = "DRUID", tab = 3, index = 12, maxRank = 5 },
    ["Improved Wild Growth"] = { class = "DRUID", tab = 3, index = 13, maxRank = 3 },
    ["Empowered Healing Touch"] = { class = "DRUID", tab = 3, index = 14, maxRank = 5 },
    ["Improved Innervate"] = { class = "DRUID", tab = 3, index = 15, maxRank = 2 },
    ["Empowered Renewal"] = { class = "DRUID", tab = 3, index = 16, maxRank = 5 },
    ["Revitalize"] = { class = "DRUID", tab = 3, index = 17, maxRank = 3 },
}

------------------------------------------------------------------------
-- PRIEST â€“ Shadow Tree (Tab 3)
------------------------------------------------------------------------
local priestShadow = {
    ["Improved Shadow Word: Pain"] = { class = "PRIEST", tab = 3, index = 4, maxRank = 2 },
    ["Mind Flay"] = { class = "PRIEST", tab = 3, index = 11, maxRank = 5, spellId = 15407 },
    ["Improved Mind Blast"] = { class = "PRIEST", tab = 3, index = 12, maxRank = 5 },
    ["Shadowform"] = { class = "PRIEST", tab = 3, index = 14, maxRank = 1, spellId = 15473 },
    ["Shadow Weaving"] = { class = "PRIEST", tab = 3, index = 15, maxRank = 5 },
    ["Darkness"] = { class = "PRIEST", tab = 3, index = 16, maxRank = 5 },
    ["Misery"] = { class = "PRIEST", tab = 3, index = 17, maxRank = 2 },
    ["Shadow Word: Death"] = { class = "PRIEST", tab = 3, index = 19, maxRank = 1, spellId = 32379 },
    ["Shadow Power"] = { class = "PRIEST", tab = 3, index = 20, maxRank = 5 },
    ["Vampiric Touch"] = { class = "PRIEST", tab = 3, index = 22, maxRank = 1, spellId = 34914 },
}

------------------------------------------------------------------------
-- WARRIOR â€“ Arms Tree (Tab 1)
------------------------------------------------------------------------
local warriorArms = {
    ["Improved Heroic Strike"] = { class = "WARRIOR", tab = 1, index = 1, maxRank = 5 },
    ["Deflection"] = { class = "WARRIOR", tab = 1, index = 2, maxRank = 5 },
    ["Improved Rend"] = { class = "WARRIOR", tab = 1, index = 3, maxRank = 3 },
    ["Improved Charge"] = { class = "WARRIOR", tab = 1, index = 4, maxRank = 2 },
    ["Iron Will"] = { class = "WARRIOR", tab = 1, index = 5, maxRank = 5 },
    ["Improved Thunder Clap"] = { class = "WARRIOR", tab = 1, index = 6, maxRank = 3 },
    ["Improved Overpower"] = { class = "WARRIOR", tab = 1, index = 7, maxRank = 5 },
    ["Anger Management"] = { class = "WARRIOR", tab = 1, index = 8, maxRank = 1 },
    ["Deep Wounds"] = { class = "WARRIOR", tab = 1, index = 9, maxRank = 3 },
    ["Two-Handed Weapon Specialization"] = { class = "WARRIOR", tab = 1, index = 10, maxRank = 5 },
    ["Impale"] = { class = "WARRIOR", tab = 1, index = 11, maxRank = 3 },
    ["Polearm Specialization"] = { class = "WARRIOR", tab = 1, index = 12, maxRank = 5 },
    ["Death Wish"] = { class = "WARRIOR", tab = 1, index = 13, maxRank = 1, spellId = 20647 },
    ["Mace Specialization"] = { class = "WARRIOR", tab = 1, index = 14, maxRank = 5 },
    ["Sword Specialization"] = { class = "WARRIOR", tab = 1, index = 15, maxRank = 5 },
    ["Improved Intercept"] = { class = "WARRIOR", tab = 1, index = 16, maxRank = 3 },
    ["Improved Hamstring"] = { class = "WARRIOR", tab = 1, index = 17, maxRank = 2 },
    ["Blood Craze"] = { class = "WARRIOR", tab = 1, index = 18, maxRank = 3 },
    ["Improved Bloodrage"] = { class = "WARRIOR", tab = 1, index = 19, maxRank = 2 },
    ["Savage Strike"] = { class = "WARRIOR", tab = 1, index = 20, maxRank = 5 },
}

------------------------------------------------------------------------
-- WARRIOR â€“ Protection Tree (Tab 2)
------------------------------------------------------------------------
local warriorProt = {
    ["Shield Specialization"] = { class = "WARRIOR", tab = 2, index = 1, maxRank = 5 },
    ["Toughness"] = { class = "WARRIOR", tab = 2, index = 2, maxRank = 5 },
    ["Improved Shield Wall"] = { class = "WARRIOR", tab = 2, index = 3, maxRank = 2 },
    ["Improved Sunder Armor"] = { class = "WARRIOR", tab = 2, index = 4, maxRank = 3 },
    ["Defiance"] = { class = "WARRIOR", tab = 2, index = 5, maxRank = 5 },
    ["Improved Concussion Blow"] = { class = "WARRIOR", tab = 2, index = 6, maxRank = 2 },
    ["Anticipation"] = { class = "WARRIOR", tab = 2, index = 7, maxRank = 5 },
    ["Last Stand"] = { class = "WARRIOR", tab = 2, index = 8, maxRank = 1, spellId = 30695 },
    ["Improved Shield Block"] = { class = "WARRIOR", tab = 2, index = 9, maxRank = 2 },
    ["Shield Slam"] = { class = "WARRIOR", tab = 2, index = 10, maxRank = 1, spellId = 23922 },
    ["Improved Revenge"] = { class = "WARRIOR", tab = 2, index = 11, maxRank = 5 },
    ["Sanctuary"] = { class = "WARRIOR", tab = 2, index = 12, maxRank = 3 },
    ["Improved Demoralizing Shout"] = { class = "WARRIOR", tab = 2, index = 13, maxRank = 2 },
    ["Vigilance"] = { class = "WARRIOR", tab = 2, index = 14, maxRank = 1, spellId = 2565 },
    ["Improved Victory Rush"] = { class = "WARRIOR", tab = 2, index = 15, maxRank = 2 },
    ["One-Handed Weapon Specialization"] = { class = "WARRIOR", tab = 2, index = 16, maxRank = 5 },
}

------------------------------------------------------------------------
-- WARRIOR â€“ Fury Tree (Tab 3)
------------------------------------------------------------------------
local warriorFury = {
    ["Improved Bloodrage"] = { class = "WARRIOR", tab = 3, index = 1, maxRank = 2 },
    ["Improved Heroic Strike"] = { class = "WARRIOR", tab = 3, index = 2, maxRank = 5 },
    ["Improved Berserker Rage"] = { class = "WARRIOR", tab = 3, index = 3, maxRank = 2 },
    ["Strength of Arms"] = { class = "WARRIOR", tab = 3, index = 4, maxRank = 5 },
    ["Improved Whirlwind"] = { class = "WARRIOR", tab = 3, index = 5, maxRank = 2 },
    ["Endurance Training"] = { class = "WARRIOR", tab = 3, index = 6, maxRank = 5 },
    ["Improved Cleave"] = { class = "WARRIOR", tab = 3, index = 7, maxRank = 3 },
    ["Windfury"] = { class = "WARRIOR", tab = 3, index = 8, maxRank = 2 },
    ["Improved Execute"] = { class = "WARRIOR", tab = 3, index = 9, maxRank = 5 },
    ["Blade Storm"] = { class = "WARRIOR", tab = 3, index = 10, maxRank = 1, spellId = 24678 },
    ["Improved Slam"] = { class = "WARRIOR", tab = 3, index = 11, maxRank = 5 },
    ["Anger Management"] = { class = "WARRIOR", tab = 3, index = 12, maxRank = 1 },
    ["Improved Pummel"] = { class = "WARRIOR", tab = 3, index = 13, maxRank = 2 },
    ["Berserker Strength"] = { class = "WARRIOR", tab = 3, index = 14, maxRank = 5 },
    ["Improved Bloodthirst"] = { class = "WARRIOR", tab = 3, index = 15, maxRank = 2 },
    ["Bloodthirst"] = { class = "WARRIOR", tab = 3, index = 16, maxRank = 1, spellId = 29084 },
}

------------------------------------------------------------------------
-- ROGUE â€“ Assassination Tree (Tab 1)
------------------------------------------------------------------------
local rogueAssassination = {
    ["Lethality"] = { class = "ROGUE", tab = 1, index = 1, maxRank = 5 },
    ["Improved Sinister Strike"] = { class = "ROGUE", tab = 1, index = 2, maxRank = 3 },
    ["Serpent Venoms"] = { class = "ROGUE", tab = 1, index = 3, maxRank = 5 },
    ["Improved Gouge"] = { class = "ROGUE", tab = 1, index = 4, maxRank = 2 },
    ["Improved Kidney Shot"] = { class = "ROGUE", tab = 1, index = 5, maxRank = 3 },
    ["Improved Eviscerate"] = { class = "ROGUE", tab = 1, index = 6, maxRank = 2 },
    ["Rupture"] = { class = "ROGUE", tab = 1, index = 7, maxRank = 5, spellId = 96231 },
    ["Improved Expose Armor"] = { class = "ROGUE", tab = 1, index = 8, maxRank = 2 },
    ["Mutilate"] = { class = "ROGUE", tab = 1, index = 9, maxRank = 5 },
    ["Improved Backstab"] = { class = "ROGUE", tab = 1, index = 10, maxRank = 3 },
    ["Poisoned Blades"] = { class = "ROGUE", tab = 1, index = 11, maxRank = 5 },
    ["Safeguard"] = { class = "ROGUE", tab = 1, index = 12, maxRank = 3 },
    ["Improved Hemorrhage"] = { class = "ROGUE", tab = 1, index = 13, maxRank = 5 },
}

------------------------------------------------------------------------
-- ROGUE â€“ Combat Tree (Tab 2)
------------------------------------------------------------------------
local rogueCombat = {
    ["Improved Ambush"] = { class = "ROGUE", tab = 2, index = 1, maxRank = 3 },
    ["Blade Flurry"] = { class = "ROGUE", tab = 2, index = 2, maxRank = 1, spellId = 1784 },
    ["Improved Slice and Dice"] = { class = "ROGUE", tab = 2, index = 3, maxRank = 5 },
    ["Improved Sprint"] = { class = "ROGUE", tab = 2, index = 4, maxRank = 2 },
    ["Sword Specialization"] = { class = "ROGUE", tab = 2, index = 5, maxRank = 5 },
    ["Agility"] = { class = "ROGUE", tab = 2, index = 6, maxRank = 5 },
    ["Improved Garrote"] = { class = "ROGUE", tab = 2, index = 7, maxRank = 3 },
    ["Adrenaline Rush"] = { class = "ROGUE", tab = 2, index = 8, maxRank = 1, spellId = 2983 },
    ["Improved Feint"] = { class = "ROGUE", tab = 2, index = 9, maxRank = 5 },
    ["Mace Specialization"] = { class = "ROGUE", tab = 2, index = 10, maxRank = 5 },
    ["Improved Riposte"] = { class = "ROGUE", tab = 2, index = 11, maxRank = 3 },
    ["Hand of Gul'dan"] = { class = "ROGUE", tab = 2, index = 12, maxRank = 5 },
    ["Improved Kick"] = { class = "ROGUE", tab = 2, index = 13, maxRank = 2 },
}

------------------------------------------------------------------------
-- ROGUE â€“ Subtlety Tree (Tab 3)
------------------------------------------------------------------------
local rogueSubtlety = {
    ["Initiative"] = { class = "ROGUE", tab = 3, index = 1, maxRank = 5 },
    ["Improved Vanish"] = { class = "ROGUE", tab = 3, index = 2, maxRank = 2 },
    ["Improved Stealth"] = { class = "ROGUE", tab = 3, index = 3, maxRank = 5 },
    ["Premeditation"] = { class = "ROGUE", tab = 3, index = 4, maxRank = 1 },
    ["Cold Blood"] = { class = "ROGUE", tab = 3, index = 5, maxRank = 1, spellId = 7922 },
    ["Improved Cheap Shot"] = { class = "ROGUE", tab = 3, index = 6, maxRank = 2 },
    ["Shadowsight"] = { class = "ROGUE", tab = 3, index = 7, maxRank = 5 },
    ["Improved Garrote"] = { class = "ROGUE", tab = 3, index = 8, maxRank = 3 },
    ["Envenom"] = { class = "ROGUE", tab = 3, index = 9, maxRank = 1 },
}

------------------------------------------------------------------------
-- WARLOCK â€“ Affliction Tree (Tab 1)
------------------------------------------------------------------------
local warlockAffliction = {
    ["Improved Corrupt"] = { class = "WARLOCK", tab = 1, index = 1, maxRank = 3 },
    ["Siphon Mana"] = { class = "WARLOCK", tab = 1, index = 2, maxRank = 5, spellId = 604 },
    ["Improved Drain Life"] = { class = "WARLOCK", tab = 1, index = 3, maxRank = 3 },
    ["Haunt"] = { class = "WARLOCK", tab = 1, index = 4, maxRank = 5, spellId = 63106 },
    ["Improved Curse of Agony"] = { class = "WARLOCK", tab = 1, index = 5, maxRank = 2 },
    ["Suppression"] = { class = "WARLOCK", tab = 1, index = 6, maxRank = 3 },
    ["Shadow Mastery"] = { class = "WARLOCK", tab = 1, index = 7, maxRank = 5 },
    ["Improved Life Tap"] = { class = "WARLOCK", tab = 1, index = 8, maxRank = 2 },
    ["Siphon Life"] = { class = "WARLOCK", tab = 1, index = 9, maxRank = 3 },
    ["Improved Unstable Affliction"] = { class = "WARLOCK", tab = 1, index = 10, maxRank = 2 },
    ["Unstable Affliction"] = { class = "WARLOCK", tab = 1, index = 11, maxRank = 1, spellId = 34861 },
}

------------------------------------------------------------------------
-- WARLOCK â€“ Demonology Tree (Tab 2)
------------------------------------------------------------------------
local warlockDemonology = {
    ["Improved Healthstone"] = { class = "WARLOCK", tab = 2, index = 1, maxRank = 5 },
    ["Fel Intensity"] = { class = "WARLOCK", tab = 2, index = 2, maxRank = 3 },
    ["Demonic Knowledge"] = { class = "WARLOCK", tab = 2, index = 3, maxRank = 5 },
    ["Improved Soulstone"] = { class = "WARLOCK", tab = 2, index = 4, maxRank = 2 },
    ["Demonic Sacrifice"] = { class = "WARLOCK", tab = 2, index = 5, maxRank = 1 },
    ["Fel Concentration"] = { class = "WARLOCK", tab = 2, index = 6, maxRank = 3 },
    ["Improved Shadow Bolt"] = { class = "WARLOCK", tab = 2, index = 7, maxRank = 5 },
    ["Demonic Aegis"] = { class = "WARLOCK", tab = 2, index = 8, maxRank = 3 },
    ["Demonic Tactics"] = { class = "WARLOCK", tab = 2, index = 9, maxRank = 5 },
}

------------------------------------------------------------------------
-- WARLOCK â€“ Destruction Tree (Tab 3)
------------------------------------------------------------------------
local warlockDestruction = {
    ["Improved Immolate"] = { class = "WARLOCK", tab = 3, index = 1, maxRank = 2 },
    ["Burning Embers"] = { class = "WARLOCK", tab = 3, index = 2, maxRank = 5 },
    ["Destruction Mastery"] = { class = "WARLOCK", tab = 3, index = 3, maxRank = 5 },
    ["Improved Conflagrate"] = { class = "WARLOCK", tab = 3, index = 4, maxRank = 2 },
    ["Backlash"] = { class = "WARLOCK", tab = 3, index = 5, maxRank = 3 },
    ["Destructive Reach"] = { class = "WARLOCK", tab = 3, index = 6, maxRank = 5 },
    ["Improved Shadowburn"] = { class = "WARLOCK", tab = 3, index = 7, maxRank = 2 },
    ["Ruin"] = { class = "WARLOCK", tab = 3, index = 8, maxRank = 5 },
    ["Bane"] = { class = "WARLOCK", tab = 3, index = 9, maxRank = 1 },
}

----------------------------------------------------------------------
-- SHAMAN (Elemental=1, Enhancement=2, Restoration=3) â€” from NAG schema
----------------------------------------------------------------------
local shamanElemental = {
    ["Convection"] = { class = "SHAMAN", tab = 1, index = 1, maxRank = 3 },
    ["Concussion Blow"] = { class = "SHAMAN", tab = 1, index = 2, maxRank = 5 },
    ["Earth's Grasp"] = { class = "SHAMAN", tab = 1, index = 3, maxRank = 3 },
    ["Elemental Warding"] = { class = "SHAMAN", tab = 1, index = 4, maxRank = 3 },
    ["Call of Flame"] = { class = "SHAMAN", tab = 1, index = 5, maxRank = 3 },
    ["Elemental Focus"] = { class = "SHAMAN", tab = 1, index = 6, maxRank = 1 },
    ["Reverberation"] = { class = "SHAMAN", tab = 1, index = 7, maxRank = 2 },
    ["Call of Thunder"] = { class = "SHAMAN", tab = 1, index = 8, maxRank = 3 },
    ["Improved Fire Totems"] = { class = "SHAMAN", tab = 1, index = 9, maxRank = 3 },
    ["Eye of the Storm"] = { class = "SHAMAN", tab = 1, index = 10, maxRank = 2 },
    ["Elemental Devastation"] = { class = "SHAMAN", tab = 1, index = 11, maxRank = 3 },
    ["Storm Reach"] = { class = "SHAMAN", tab = 1, index = 12, maxRank = 3 },
    ["Elemental Fury"] = { class = "SHAMAN", tab = 1, index = 13, maxRank = 1 },
    ["Unrelenting Storm"] = { class = "SHAMAN", tab = 1, index = 14, maxRank = 2 },
    ["Elemental Precision"] = { class = "SHAMAN", tab = 1, index = 15, maxRank = 3 },
    ["Lightning Mastery"] = { class = "SHAMAN", tab = 1, index = 16, maxRank = 3 },
    ["Elemental Mastery"] = { class = "SHAMAN", tab = 1, index = 17, maxRank = 1 },
    ["Elemental Shields"] = { class = "SHAMAN", tab = 1, index = 18, maxRank = 2 },
    ["Lightning Overload"] = { class = "SHAMAN", tab = 1, index = 19, maxRank = 3 },
    ["Totem of Wrath"] = { class = "SHAMAN", tab = 1, index = 20, maxRank = 1 },
}

local shamanEnhancement = {
    ["Ancestral Knowledge"] = { class = "SHAMAN", tab = 2, index = 1, maxRank = 3 },
    ["Shield Specialization"] = { class = "SHAMAN", tab = 2, index = 2, maxRank = 3 },
    ["Guardian Totems"] = { class = "SHAMAN", tab = 2, index = 3, maxRank = 3 },
    ["Thundering Strikes"] = { class = "SHAMAN", tab = 2, index = 4, maxRank = 3 },
    ["Improved Ghost Wolf"] = { class = "SHAMAN", tab = 2, index = 5, maxRank = 3 },
    ["Improved Lightning Shield"] = { class = "SHAMAN", tab = 2, index = 6, maxRank = 3 },
    ["Enhancing Totems"] = { class = "SHAMAN", tab = 2, index = 7, maxRank = 3 },
    ["Shamanistic Focus"] = { class = "SHAMAN", tab = 2, index = 8, maxRank = 1 },
    ["Anticipation"] = { class = "SHAMAN", tab = 2, index = 9, maxRank = 3 },
    ["Flurry"] = { class = "SHAMAN", tab = 2, index = 10, maxRank = 5 },
    ["Toughness"] = { class = "SHAMAN", tab = 2, index = 11, maxRank = 3 },
    ["Improved Weapon Totems"] = { class = "SHAMAN", tab = 2, index = 12, maxRank = 3 },
    ["Spirit Weapons"] = { class = "SHAMAN", tab = 2, index = 13, maxRank = 1 },
    ["Elemental Weapons"] = { class = "SHAMAN", tab = 2, index = 14, maxRank = 3 },
    ["Mental Quickness"] = { class = "SHAMAN", tab = 2, index = 15, maxRank = 3 },
    ["Weapon Mastery"] = { class = "SHAMAN", tab = 2, index = 16, maxRank = 3 },
    ["Dual Wield Specialization"] = { class = "SHAMAN", tab = 2, index = 17, maxRank = 3 },
    ["Dual Wield"] = { class = "SHAMAN", tab = 2, index = 18, maxRank = 1 },
    ["Stormstrike"] = { class = "SHAMAN", tab = 2, index = 19, maxRank = 1 },
    ["Unleashed Rage"] = { class = "SHAMAN", tab = 2, index = 20, maxRank = 3 },
    ["Shamanistic Rage"] = { class = "SHAMAN", tab = 2, index = 21, maxRank = 1 },
}

local shamanRestoration = {
    ["Improved Healing Wave"] = { class = "SHAMAN", tab = 3, index = 1, maxRank = 3 },
    ["Tidal Focus"] = { class = "SHAMAN", tab = 3, index = 2, maxRank = 3 },
    ["Improved Reincarnation"] = { class = "SHAMAN", tab = 3, index = 3, maxRank = 3 },
    ["Ancestral Healing"] = { class = "SHAMAN", tab = 3, index = 4, maxRank = 2 },
    ["Totemic Focus"] = { class = "SHAMAN", tab = 3, index = 5, maxRank = 3 },
    ["Nature's Guidance"] = { class = "SHAMAN", tab = 3, index = 6, maxRank = 3 },
    ["Healing Focus"] = { class = "SHAMAN", tab = 3, index = 7, maxRank = 3 },
    ["Totemic Mastery"] = { class = "SHAMAN", tab = 3, index = 8, maxRank = 1 },
    ["Healing Grace"] = { class = "SHAMAN", tab = 3, index = 9, maxRank = 2 },
    ["Restorative Totems"] = { class = "SHAMAN", tab = 3, index = 10, maxRank = 3 },
    ["Tidal Mastery"] = { class = "SHAMAN", tab = 3, index = 11, maxRank = 3 },
    ["Healing Way"] = { class = "SHAMAN", tab = 3, index = 12, maxRank = 5 },
    ["Nature's Swiftness"] = { class = "SHAMAN", tab = 3, index = 13, maxRank = 1 },
    ["Focused Mind"] = { class = "SHAMAN", tab = 3, index = 14, maxRank = 3 },
    ["Purification"] = { class = "SHAMAN", tab = 3, index = 15, maxRank = 3 },
    ["Mana Tide Totem"] = { class = "SHAMAN", tab = 3, index = 16, maxRank = 1 },
    ["Nature's Guardian"] = { class = "SHAMAN", tab = 3, index = 17, maxRank = 3 },
    ["Nature's Blessing"] = { class = "SHAMAN", tab = 3, index = 18, maxRank = 2 },
    ["Improved Chain Heal"] = { class = "SHAMAN", tab = 3, index = 19, maxRank = 3 },
}

----------------------------------------------------------------------
-- MAGE (Arcane=1, Fire=2, Frost=3) â€” from NAG schema
----------------------------------------------------------------------
local mageArcane = {
    ["Arcane Subtlety"] = { class = "MAGE", tab = 1, index = 1, maxRank = 5 },
    ["Arcane Focus"] = { class = "MAGE", tab = 1, index = 2, maxRank = 3 },
    ["Improved Arcane Missiles"] = { class = "MAGE", tab = 1, index = 3, maxRank = 3 },
    ["Wand Specialization"] = { class = "MAGE", tab = 1, index = 4, maxRank = 5 },
    ["Magic Absorption"] = { class = "MAGE", tab = 1, index = 5, maxRank = 3 },
    ["Arcane Concentration"] = { class = "MAGE", tab = 1, index = 6, maxRank = 5 },
    ["Magic Attunement"] = { class = "MAGE", tab = 1, index = 7, maxRank = 3 },
    ["Arcane Impact"] = { class = "MAGE", tab = 1, index = 8, maxRank = 2 },
    ["Arcane Fortitude"] = { class = "MAGE", tab = 1, index = 9, maxRank = 1 },
    ["Improved Mana Shield"] = { class = "MAGE", tab = 1, index = 10, maxRank = 3 },
    ["Improved Counterspell"] = { class = "MAGE", tab = 1, index = 11, maxRank = 2 },
    ["Arcane Meditation"] = { class = "MAGE", tab = 1, index = 12, maxRank = 5 },
    ["Improved Blink"] = { class = "MAGE", tab = 1, index = 13, maxRank = 2 },
    ["Presence of Mind"] = { class = "MAGE", tab = 1, index = 14, maxRank = 1 },
    ["Arcane Mind"] = { class = "MAGE", tab = 1, index = 15, maxRank = 3 },
    ["Prismatic Cloak"] = { class = "MAGE", tab = 1, index = 16, maxRank = 2 },
    ["Arcane Instability"] = { class = "MAGE", tab = 1, index = 17, maxRank = 3 },
    ["Arcane Potency"] = { class = "MAGE", tab = 1, index = 18, maxRank = 3 },
    ["Empowered Arcane Missiles"] = { class = "MAGE", tab = 1, index = 19, maxRank = 3 },
    ["Arcane Power"] = { class = "MAGE", tab = 1, index = 20, maxRank = 1 },
}

local mageFire = {
    ["Spell Power"] = { class = "MAGE", tab = 2, index = 1, maxRank = 3 },
    ["Mind Mastery"] = { class = "MAGE", tab = 2, index = 2, maxRank = 5 },
    ["Slow"] = { class = "MAGE", tab = 2, index = 3, maxRank = 1 },
    ["Improved Fireball"] = { class = "MAGE", tab = 2, index = 4, maxRank = 3 },
    ["Impact"] = { class = "MAGE", tab = 2, index = 5, maxRank = 3 },
    ["Ignite"] = { class = "MAGE", tab = 2, index = 6, maxRank = 3 },
    ["Flame Throwing"] = { class = "MAGE", tab = 2, index = 7, maxRank = 5 },
    ["Improved Fire Blast"] = { class = "MAGE", tab = 2, index = 8, maxRank = 3 },
    ["Incineration"] = { class = "MAGE", tab = 2, index = 9, maxRank = 3 },
    ["Improved Flamestrike"] = { class = "MAGE", tab = 2, index = 10, maxRank = 3 },
    ["Pyroblast"] = { class = "MAGE", tab = 2, index = 11, maxRank = 1 },
}

local mageFrost = {
    ["Frost Warding"] = { class = "MAGE", tab = 3, index = 1, maxRank = 5 },
    ["Ice Barrier"] = { class = "MAGE", tab = 3, index = 2, maxRank = 1 },
    ["Improved Frost Nova"] = { class = "MAGE", tab = 3, index = 3, maxRank = 3 },
    ["Frost Channeling"] = { class = "MAGE", tab = 3, index = 4, maxRank = 5 },
    ["Shatter"] = { class = "MAGE", tab = 3, index = 5, maxRank = 3 },
    ["Improved Blizzard"] = { class = "MAGE", tab = 3, index = 6, maxRank = 2 },
    ["Arctic Reach"] = { class = "MAGE", tab = 3, index = 7, maxRank = 3 },
    ["Ice Shards"] = { class = "MAGE", tab = 3, index = 8, maxRank = 5 },
    ["Frost Specialty"] = { class = "MAGE", tab = 3, index = 9, maxRank = 5 },
    ["Piercing Ice"] = { class = "MAGE", tab = 3, index = 10, maxRank = 2 },
    ["Winter's Chill"] = { class = "MAGE", tab = 3, index = 11, maxRank = 3 },
    ["Frozen Power"] = { class = "MAGE", tab = 3, index = 12, maxRank = 3 },
    ["Empowered Frostbolt"] = { class = "MAGE", tab = 3, index = 13, maxRank = 3 },
}

----------------------------------------------------------------------
-- HUNTER (Beast Mastery=1, Marksmanship=2, Survival=3) â€” from NAG schema
----------------------------------------------------------------------
local hunterBeastMastery = {
    ["Endurance Training"] = { class = "HUNTER", tab = 1, index = 1, maxRank = 5 },
    ["Thick Hide"] = { class = "HUNTER", tab = 1, index = 2, maxRank = 3 },
    ["Spirit Bond"] = { class = "HUNTER", tab = 1, index = 3, maxRank = 3 },
    ["Pathfinding"] = { class = "HUNTER", tab = 1, index = 4, maxRank = 2 },
    ["Beast Soul"] = { class = "HUNTER", tab = 1, index = 5, maxRank = 3 },
    ["Sanctuary"] = { class = "HUNTER", tab = 1, index = 6, maxRank = 3 },
    ["Unleashed Fury"] = { class = "HUNTER", tab = 1, index = 7, maxRank = 5 },
    ["Ferocity"] = { class = "HUNTER", tab = 1, index = 8, maxRank = 3 },
    ["Tenacity"] = { class = "HUNTER", tab = 1, index = 9, maxRank = 3 },
    ["Primal Tenacity"] = { class = "HUNTER", tab = 1, index = 10, maxRank = 2 },
    ["Animal Handler"] = { class = "HUNTER", tab = 1, index = 11, maxRank = 3 },
    ["Bestial Discipline"] = { class = "HUNTER", tab = 1, index = 12, maxRank = 3 },
    ["Improved Revive Pet"] = { class = "HUNTER", tab = 1, index = 13, maxRank = 3 },
    ["Cruelty"] = { class = "HUNTER", tab = 1, index = 14, maxRank = 5 },
    ["Beast Training"] = { class = "HUNTER", tab = 1, index = 15, maxRank = 3 },
    ["Exotic Beasts"] = { class = "HUNTER", tab = 1, index = 16, maxRank = 1 },
}

local hunterMarksmanship = {
    ["Aimed Shot"] = { class = "HUNTER", tab = 2, index = 1, maxRank = 5 },
    ["Improved Arcane Shot"] = { class = "HUNTER", tab = 2, index = 2, maxRank = 3 },
    ["Ranged Weapon Specialization"] = { class = "HUNTER", tab = 2, index = 3, maxRank = 5 },
    ["Improved Wing Clip"] = { class = "HUNTER", tab = 2, index = 4, maxRank = 3 },
    ["Improved Kill Command"] = { class = "HUNTER", tab = 2, index = 5, maxRank = 3 },
    ["Survival Instincts"] = { class = "HUNTER", tab = 2, index = 6, maxRank = 1 },
    ["Improved Aspect of the Pack"] = { class = "HUNTER", tab = 2, index = 7, maxRank = 3 },
    ["Traps"] = { class = "HUNTER", tab = 2, index = 8, maxRank = 5 },
    ["Improved Concussive Shot"] = { class = "HUNTER", tab = 2, index = 9, maxRank = 3 },
    ["Lethal Shots"] = { class = "HUNTER", tab = 2, index = 10, maxRank = 5 },
    ["Improved Serpent Sting"] = { class = "HUNTER", tab = 2, index = 11, maxRank = 3 },
    ["Go for the Throat"] = { class = "HUNTER", tab = 2, index = 12, maxRank = 5 },
    ["Improved Wyvern Sting"] = { class = "HUNTER", tab = 2, index = 13, maxRank = 3 },
}

local hunterSurvival = {
    ["Savage Beast"] = { class = "HUNTER", tab = 3, index = 1, maxRank = 5 },
    ["Improved Scavenger"] = { class = "HUNTER", tab = 3, index = 2, maxRank = 3 },
    ["Pursuit"] = { class = "HUNTER", tab = 3, index = 3, maxRank = 5 },
    ["Improved Hunter's Mark"] = { class = "HUNTER", tab = 3, index = 4, maxRank = 3 },
    ["Vigor"] = { class = "HUNTER", tab = 3, index = 5, maxRank = 3 },
    ["Improved Mend Pet"] = { class = "HUNTER", tab = 3, index = 6, maxRank = 3 },
    ["Fervor"] = { class = "HUNTER", tab = 3, index = 7, maxRank = 5 },
    ["Improved Feign Death"] = { class = "HUNTER", tab = 3, index = 8, maxRank = 2 },
    ["Trap Mastery"] = { class = "HUNTER", tab = 3, index = 9, maxRank = 3 },
    ["Serpent Swiftness"] = { class = "HUNTER", tab = 3, index = 10, maxRank = 5 },
    ["Improved Aspect of the Cheetah"] = { class = "HUNTER", tab = 3, index = 11, maxRank = 2 },
    ["Surefooted"] = { class = "HUNTER", tab = 3, index = 12, maxRank = 3 },
    ["Improved Aspect of the Monkey"] = { class = "HUNTER", tab = 3, index = 13, maxRank = 3 },
}

----------------------------------------------------------------------
-- PALADIN (Holy=1, Protection=2, Retribution=3) â€” from NAG schema
----------------------------------------------------------------------
local paladinHoly = {
    ["Divine Strength"] = { class = "PALADIN", tab = 1, index = 1, maxRank = 5 },
    ["Divine Intellect"] = { class = "PALADIN", tab = 1, index = 2, maxRank = 3 },
    ["Spiritual Focus"] = { class = "PALADIN", tab = 1, index = 3, maxRank = 5 },
    ["Improved Seal of Righteousness"] = { class = "PALADIN", tab = 1, index = 4, maxRank = 2 },
    ["Healing Light"] = { class = "PALADIN", tab = 1, index = 5, maxRank = 3 },
    ["Aura Mastery"] = { class = "PALADIN", tab = 1, index = 6, maxRank = 1 },
    ["Improved Lay on Hands"] = { class = "PALADIN", tab = 1, index = 7, maxRank = 2 },
    ["Unyielding Faith"] = { class = "PALADIN", tab = 1, index = 8, maxRank = 3 },
    ["Illumination"] = { class = "PALADIN", tab = 1, index = 9, maxRank = 5 },
    ["Improved Blessing of Wisdom"] = { class = "PALADIN", tab = 1, index = 10, maxRank = 3 },
    ["Pure of Heart"] = { class = "PALADIN", tab = 1, index = 11, maxRank = 2 },
    ["Divine Favor"] = { class = "PALADIN", tab = 1, index = 12, maxRank = 1 },
    ["Sanctified Light"] = { class = "PALADIN", tab = 1, index = 13, maxRank = 3 },
    ["Purifying Power"] = { class = "PALADIN", tab = 1, index = 14, maxRank = 5 },
    ["Holy Power"] = { class = "PALADIN", tab = 1, index = 15, maxRank = 3 },
    ["Light's Grace"] = { class = "PALADIN", tab = 1, index = 16, maxRank = 2 },
    ["Holy Shock"] = { class = "PALADIN", tab = 1, index = 17, maxRank = 1 },
}

local paladinProtection = {
    ["Blessed Life"] = { class = "PALADIN", tab = 2, index = 1, maxRank = 3 },
    ["Holy Guidance"] = { class = "PALADIN", tab = 2, index = 2, maxRank = 5 },
    ["Divine Illumination"] = { class = "PALADIN", tab = 2, index = 3, maxRank = 1 },
    ["Improved Devotion Aura"] = { class = "PALADIN", tab = 2, index = 4, maxRank = 3 },
    ["Redoubt"] = { class = "PALADIN", tab = 2, index = 5, maxRank = 3 },
    ["Precision"] = { class = "PALADIN", tab = 2, index = 6, maxRank = 5 },
    ["Guardian's Favor"] = { class = "PALADIN", tab = 2, index = 7, maxRank = 3 },
    ["Toughness"] = { class = "PALADIN", tab = 2, index = 8, maxRank = 5 },
    ["Blessing of Kings"] = { class = "PALADIN", tab = 2, index = 9, maxRank = 1 },
    ["Improved Righteous Fury"] = { class = "PALADIN", tab = 2, index = 10, maxRank = 3 },
    ["Shield Specialization"] = { class = "PALADIN", tab = 2, index = 11, maxRank = 5 },
    ["Anticipation"] = { class = "PALADIN", tab = 2, index = 12, maxRank = 3 },
    ["Stoicism"] = { class = "PALADIN", tab = 2, index = 13, maxRank = 3 },
    ["Improved Hammer of Justice"] = { class = "PALADIN", tab = 2, index = 14, maxRank = 3 },
    ["Improved Concentration Aura"] = { class = "PALADIN", tab = 2, index = 15, maxRank = 3 },
    ["Spell Warding"] = { class = "PALADIN", tab = 2, index = 16, maxRank = 3 },
    ["Blessing of Sanctuary"] = { class = "PALADIN", tab = 2, index = 17, maxRank = 1 },
    ["Reckoning"] = { class = "PALADIN", tab = 2, index = 18, maxRank = 3 },
    ["Sacred Duty"] = { class = "PALADIN", tab = 2, index = 19, maxRank = 5 },
    ["One-Handed Weapon Specialization"] = { class = "PALADIN", tab = 2, index = 20, maxRank = 3 },
    ["Improved Holy Shield"] = { class = "PALADIN", tab = 2, index = 21, maxRank = 3 },
    ["Holy Shield"] = { class = "PALADIN", tab = 2, index = 22, maxRank = 1 },
    ["Ardent Defender"] = { class = "PALADIN", tab = 2, index = 23, maxRank = 3 },
    ["Combat Expertise"] = { class = "PALADIN", tab = 2, index = 24, maxRank = 5 },
    ["Avenger's Shield"] = { class = "PALADIN", tab = 2, index = 25, maxRank = 1 },
}

local paladinRetribution = {
    ["Improved Blessing of Might"] = { class = "PALADIN", tab = 3, index = 1, maxRank = 3 },
    ["Benediction"] = { class = "PALADIN", tab = 3, index = 2, maxRank = 5 },
    ["Improved Judgement"] = { class = "PALADIN", tab = 3, index = 3, maxRank = 5 },
    ["Improved Seal of the Crusader"] = { class = "PALADIN", tab = 3, index = 4, maxRank = 2 },
    ["Deflection"] = { class = "PALADIN", tab = 3, index = 5, maxRank = 5 },
    ["Vindication"] = { class = "PALADIN", tab = 3, index = 6, maxRank = 3 },
    ["Conviction"] = { class = "PALADIN", tab = 3, index = 7, maxRank = 3 },
    ["Seal of Command"] = { class = "PALADIN", tab = 3, index = 8, maxRank = 1 },
    ["Pursuit of Justice"] = { class = "PALADIN", tab = 3, index = 9, maxRank = 5 },
    ["Eye for an Eye"] = { class = "PALADIN", tab = 3, index = 10, maxRank = 3 },
    ["Improved Retribution Aura"] = { class = "PALADIN", tab = 3, index = 11, maxRank = 3 },
    ["Crusade"] = { class = "PALADIN", tab = 3, index = 12, maxRank = 5 },
    ["Two-Handed Weapon Specialization"] = { class = "PALADIN", tab = 3, index = 13, maxRank = 3 },
    ["Sanctity Aura"] = { class = "PALADIN", tab = 3, index = 14, maxRank = 1 },
    ["Improved Sanctity Aura"] = { class = "PALADIN", tab = 3, index = 15, maxRank = 3 },
    ["Vengeance"] = { class = "PALADIN", tab = 3, index = 16, maxRank = 3 },
    ["Sanctified Judgement"] = { class = "PALADIN", tab = 3, index = 17, maxRank = 5 },
    ["Sanctified Seals"] = { class = "PALADIN", tab = 3, index = 18, maxRank = 3 },
    ["Repentance"] = { class = "PALADIN", tab = 3, index = 19, maxRank = 1 },
    ["Divine Purpose"] = { class = "PALADIN", tab = 3, index = 20, maxRank = 5 },
    ["Fanaticism"] = { class = "PALADIN", tab = 3, index = 21, maxRank = 3 },
}


------------------------------------------------------------------------
-- Helper: Build reverse lookup by (class, tab, index)
------------------------------------------------------------------------
function TD:GetTalentByPosition(classToken, tab, index)
    for name, def in pairs(TD.talents) do
        if def.class == classToken and def.tab == tab and def.index == index then
            return name, def
        end
    end
    return nil, nil
end

function TD:GetTalentByName(classToken, talentName)
    for name, def in pairs(TD.talents) do
        if def.class == classToken and name:lower() == (talentName or ""):lower() then
            return name, def
        end
    end
    return nil, nil
end

-- Populate the master table from all groups
for _, group in ipairs({
    druidBalance, druidFeral, druidResto,
    priestShadow,
    warriorArms, warriorProt, warriorFury,
    rogueAssassination, rogueCombat, rogueSubtlety,
    warlockAffliction, warlockDemonology, warlockDestruction,
    shamanElemental, shamanEnhancement, shamanRestoration,
    mageArcane, mageFire, mageFrost,
    hunterBeastMastery, hunterMarksmanship, hunterSurvival,
    paladinHoly, paladinProtection, paladinRetribution,
}) do
    for name, def in pairs(group) do
        TD.talents[name] = def
    end
end
