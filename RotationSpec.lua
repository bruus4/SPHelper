-- RotationSpec.lua
-- Data-driven rotation specification for SPHelper.
-- This file declares `SPHelper.RotationSpec` as a Lua table describing
-- spells, priorities and the condition types used by `Rotation.lua`.

local A = SPHelper

-- Versioned spec so future migrations are possible
A.RotationSpec = {
    version = 1,

    -- Timing constants (these mirror the values used in Rotation.lua)
    constants = {
        VT_CAST_TIME = 1.5,
        MF_CAST_TIME = 3.0,
        MIN_MF_DURATION = 1.0,
        SAFETY = 0.5,
        DEFAULT_SF_MANA_PCT = 0.35, -- 35%
    },

    -- Supported condition types (documentation table for implementers)
    -- Evaluator should support the following condition `type` keys:
    -- - `cooldown_ready` : true when spell/item CD == 0 (params: id)
    -- - `dot_missing` : true when player-applied debuff missing on target (params: name)
    -- - `projected_dot_time_left_lt` : projected remaining dot after current cast < seconds
    --       (params: name, seconds, cast_adjust = {cast_time_field})
    -- - `dot_time_left_lt` : current remaining dot < seconds (params: name, seconds)
    -- - `gcd_adjusted_time` : compare to gcd+latency+SAFETY (params: seconds)
    -- - `resource_pct_lt` : resource percent less than (params: resource=`mana`/`hp`, pct)
    -- - `resource_pct_gt` : resource percent greater than (params: resource, pct)
    -- - `predicted_damage_ge_target_hp` : compare predicted damage to target HP (params: formula)
    -- - `player_hp_gt` : player's HP absolute > amount (params: amount)
    -- - `item_ready_and_owned` : item ready and in inventory (params: itemId)
    -- - `content_mode_allow` : checks per-content mode settings (params: dbKey -> e.g. swdRaid)
    -- - `not_recently_cast` : suppress if was recently cast (params: name, window)
    -- - `always` : unconditional true
    -- - `not_target_valid` / `target_valid` : target existence and attackable check
    -- - `not_debuff_on_target` : inverse of `dot_missing` alias
    -- - `min_cast_duration_available` : allow casting a channel only if a minimum duration remains

    -- Spell entries: key is the canonical full spell name (e.g. "Vampiric Touch", "Shadow Word: Pain", "Mind Blast"...)
    spells = {
        VT = {
            id = A.SPELLS and A.SPELLS.VT and A.SPELLS.VT.id,
            name = A.SPELLS and A.SPELLS.VT and A.SPELLS.VT.name,
            -- Priority is implicit in order used by rotation engine; include a hint value
            priorityHint = 100,
            conditions = {
                -- Only consider when target valid
                { type = "target_valid" },
                -- Cast if dot missing OR it will fall off before we can re-cast
                { type = "dot_missing", name = A.SPELLS and A.SPELLS.VT and A.SPELLS.VT.name },
                { type = "projected_dot_time_left_lt", name = A.SPELLS and A.SPELLS.VT and A.SPELLS.VT.name,
                  seconds =  function(constants, ctx) -- example eval-time helper usage
                      return (constants.VT_CAST_TIME / (ctx.hasteMul or 1)) + (ctx.lat or 0) + constants.SAFETY
                  end
                },
            },
            notes = "VT urgent when vtAfter < vtCastEff + lat + SAFETY",
        },

        SWP = {
            id = A.SPELLS and A.SPELLS.SWP and A.SPELLS.SWP.id,
            name = A.SPELLS and A.SPELLS.SWP and A.SPELLS.SWP.name,
            priorityHint = 95,
            conditions = {
                { type = "target_valid" },
                { type = "dot_missing", name = A.SPELLS and A.SPELLS.SWP and A.SPELLS.SWP.name },
                { type = "projected_dot_time_left_lt", name = A.SPELLS and A.SPELLS.SWP and A.SPELLS.SWP.name,
                  seconds = function(constants, ctx) return (ctx.gcd or 1.0) + (ctx.lat or 0) + constants.SAFETY end
                },
            },
            notes = "SWP urgent when swpAfter < gcd + lat + SAFETY",
        },

        MB = {
            id = A.SPELLS and A.SPELLS.MB and A.SPELLS.MB.id,
            name = A.SPELLS and A.SPELLS.MB and A.SPELLS.MB.name,
            priorityHint = 90,
            conditions = {
                { type = "target_valid" },
                { type = "cooldown_ready", id = A.SPELLS and A.SPELLS.MB and A.SPELLS.MB.id }
            },
            notes = "Mind Blast when off cooldown",
        },

        MF = {
            id = A.SPELLS and A.SPELLS.MF and A.SPELLS.MF.id,
            name = A.SPELLS and A.SPELLS.MF and A.SPELLS.MF.name,
            priorityHint = 10,
            conditions = {
                { type = "target_valid" },
                { type = "always" } -- filler fallback; MF has special clip rules in engine
            },
            clipRules = {
                -- If MB/SWD/dot will be ready/expire within MF cast time, mark as clip
                lookahead_seconds = function(constants, ctx) return (constants.MF_CAST_TIME / (ctx.hasteMul or 1)) end,
                min_duration = function(constants, ctx) return (constants.MIN_MF_DURATION / (ctx.hasteMul or 1)) end,
            },
        },

        SF = {
            id = A.SPELLS and A.SPELLS.SF and A.SPELLS.SF.id,
            name = A.SPELLS and A.SPELLS.SF and A.SPELLS.SF.name,
            priorityHint = 80,
            conditions = {
                { type = "resource_pct_lt", resource = "mana", pct = function(db) return (db and db.sfManaThreshold or 35) / 100 end },
                { type = "cooldown_ready", id = A.SPELLS and A.SPELLS.SF and A.SPELLS.SF.id }
            },
            notes = "Shadowfiend for mana emergency; threshold from db.sfManaThreshold",
        },

        SWD = {
            id = A.SPELLS and A.SPELLS.SWD and A.SPELLS.SWD.id,
            name = A.SPELLS and A.SPELLS.SWD and A.SPELLS.SWD.name,
            priorityHint = 110,
            conditions = {
                { type = "target_valid" },
                { type = "cooldown_ready", id = A.SPELLS and A.SPELLS.SWD and A.SPELLS.SWD.id },
                -- Per-content mode handled by evaluator via `contentMode` and `safetyPct` from DB
                { type = "content_mode_allow", dbKey = "swd" },
                { type = "resource_pct_gt", resource = "hp", pct = 0.20 },
            },
            alwaysModeSafety = {
                -- when mode == "always" require playerHP > predicted crit damage
                predictedDamageFormula = function(getSpellPower)
                    local sp = (getSpellPower and getSpellPower()) or 0
                    local swdHit = math.floor(sp * 1.55 + 0.5)
                    local swdCrit = math.floor(swdHit * 1.5 + 0.5)
                    return swdCrit
                end,
            },
            notes = "SWD uses per-content mode: never/execute/always",
        },

        DP = {
            id = A.SPELLS and A.SPELLS.DP and A.SPELLS.DP.id,
            name = A.SPELLS and A.SPELLS.DP and A.SPELLS.DP.name,
            priorityHint = 70,
            conditions = {
                { type = "target_valid" },
                { type = "not_debuff_on_target", name = A.SPELLS and A.SPELLS.DP and A.SPELLS.DP.name },
                { type = "cooldown_ready", id = A.SPELLS and A.SPELLS.DP and A.SPELLS.DP.id }
            },
        },

        POTION = {
            id = nil,
            name = "POTION",
            priorityHint = 60,
            conditions = {
                { type = "item_ready_and_owned", item_pref_db = "selectedPotionItem" },
                { type = "resource_pct_lt", resource = "mana", pct = function(db) return (db and db.potManaThreshold or 70) / 100 end }
            },
            notes = "Configurable potion suggestion; `potEarly` alters placement in engine",
        },

        RUNE = {
            id = nil,
            name = "RUNE",
            priorityHint = 50,
            conditions = {
                { type = "item_ready_and_owned", item_pref_db = "selectedRuneItem" },
                { type = "resource_pct_lt", resource = "mana", pct = function(db) return (db and db.runeManaThreshold or 40) / 100 end }
            },
        },

        IF = {
            id = A.SPELLS and A.SPELLS.IF and A.SPELLS.IF.id,
            name = A.SPELLS and A.SPELLS.IF and A.SPELLS.IF.name,
            priorityHint = 85,
            conditions = {
                { type = "cooldown_ready", id = A.SPELLS and A.SPELLS.IF and A.SPELLS.IF.id },
                { type = "not_buff_on_player", name = A.SPELLS and A.SPELLS.IF and A.SPELLS.IF.name }
            },
            insertBefore = { -- config-driven: db.ifInsert.before handled by engine
                window = 4.0
            }
        }
    },

    -- Example evaluator hints: how the engine may compute ctx values
    evaluatorHints = {
        ctxFields = { "now", "castRemaining", "hasteMul", "lat", "gcd", "vtRem", "swpRem", "vtAfter", "swpAfter" },
        dbAccess = "A.db.rotation or A.db",
        functionsNeeded = { "GetSpellCDReal", "FindPlayerDebuff", "GetItemCooldownSafe", "GetItemCount", "GetSpellPower", "GetHaste" }
    }
}

-- Notes for integration:
-- 1) Add this file to `SPHelper.toc` so the table is available at load time.
-- 2) `Rotation.lua` can read `A.RotationSpec` and evaluate each spell's `conditions`.
-- 3) Condition `seconds` or `pct` fields may be functions evaluated at runtime
--    with the signature `(constants, ctx, db) -> number` to allow haste/db-aware values.

return A.RotationSpec
