// Slot-based ground battle model.
//
// A planet that is under attack holds a BattleState. Each BattleState owns up to
// BATTLE_PLACES_MAX "places"; every place has BATTLE_SLOTS_PER_PLACE marine slots (a player
// deployment limit) and an UNCAPPED pool of enemy squads. A side with no opponent in its own
// place attacks into an adjacent place. See scr_battle_resolve for the end-of-turn resolution.

#macro BATTLE_PLACES_MAX 3
#macro BATTLE_SLOTS_PER_PLACE 10
// How many enemy squads one point of abstract planet_forces strength represents.
#macro ENEMY_SQUADS_PER_FORCE 3

// Global enemy survivability multiplier applied to every enemy squad's max health, so enemies are
// generally tankier. Headcount is unchanged -- each model simply takes more damage to bring down.
#macro ENEMY_HEALTH_MULT 2.5
// Vehicle-tagged enemy units (the enemy's armour) are tougher still -- their extra hull lets them
// soak the focused fire and shield their infantry, mirroring how marine vehicles tank for a squad.
// (Which unit is shot first is decided by range-reduction priority, not the vehicle tag.)
#macro ENEMY_VEHICLE_HEALTH_MULT 2.0

// Tag-interaction tuning. A marine wielding two dual-tagged weapons hits this much harder; polearms
// deal this much bonus damage to cavalry (on top of bypassing their damage reduction).
#macro DUAL_BONUS 1.3
#macro POLEARM_CAV_BONUS 0.5

// Specialist death-prevention / healing tuning. Each turn an apothecary can heal this much marine
// hp in its place, and a standard/chaplain save patches the rescued marine up to this fraction of
// its max health. Each save attempt succeeds on a d100 roll under the relevant stat
// (apothecary intelligence, techmarine technology, standard/chaplain piety).
#macro APOTHECARY_HEAL_AMOUNT 40
#macro SAVE_HEAL_FRAC 0.01

// Possible enemy unit tags. An enemy type's `tags` field is a list of these integers; helpers such
// as EnemySquad.is_vehicle() test membership with array_contains. Add new categories here.
enum eENEMY_TAG {
    VEHICLE,    // armour / war engines -- tougher hull (see ENEMY_VEHICLE_HEALTH_MULT)
    INFANTRY,   // foot troops -- hunt rank-and-file marines first
    MONSTROUS,  // monstrous creatures -- hunt marine vehicles first
    FLYER,      // flying / fast skimmers -- hunt the highest ranged-value marines first
    ELITE,      // elite / heavily-armoured infantry
    ARMOURED,
    COMMAND,
    CAVALRY,    // fast-moving shock troops (e.g. bikers)
    SNIPER,     // marksman units -- hunt marine command (captains/masters/standards/specialists)
}

// Stance bonus added to a place's net distance reduction each turn: "push" drives the line in,
// "hold" resists closing, "fallback" opens the range hard. The bulk of the shift still comes from
// unit equipment / enemy types.
#macro STANCE_PUSH_BONUS 0.05
#macro STANCE_HOLD_BONUS -0.03
#macro STANCE_FALLBACK_BONUS -0.12

// Enemy command points per turn (spent moving/reinforcing squads).
#macro ENEMY_CP_PER_TURN 5
// How many enemy squads the attacker may reposition between places each turn (legacy; the enemy
// now spends ENEMY_CP_PER_TURN instead, 1 CP per move/reinforce).
#macro ENEMY_REPOSITION_PER_TURN 3

// Objective control: a marine Chapter Master or company-standard bearer holding the objective
// place accrues control turns (cumulative, not necessarily consecutive); reaching this count wins
// the planet outright. The objective also shifts to a different place every OBJECTIVE_SHIFT_TURNS.
#macro OBJECTIVE_WIN_TURNS 6
#macro OBJECTIVE_SHIFT_TURNS 2

// Place roles. Exactly one of each exists per planet battle.
#macro PLACE_OBJECTIVE "objective"
#macro PLACE_REINFORCEMENT "reinforcement"
#macro PLACE_BASE "base"

// Terrain types and the distance band (0 = melee brawl, 1 = artillery range) each can produce.
// A place rolls its min within [min_lo, min_hi] and its max within [max_lo, max_hi] (>min).
function battle_terrain_types() {
    static _terrains = [
        {name: "Steppe",  min_lo: 0.00, min_hi: 0.20, max_lo: 0.80, max_hi: 1.00},
        {name: "Desert",  min_lo: 0.10, min_hi: 0.30, max_lo: 0.80, max_hi: 1.00},
        {name: "Hills",   min_lo: 0.15, min_hi: 0.35, max_lo: 0.65, max_hi: 0.90},
        {name: "Plains",  min_lo: 0.05, min_hi: 0.25, max_lo: 0.60, max_hi: 0.85},
        {name: "Wetland", min_lo: 0.00, min_hi: 0.20, max_lo: 0.45, max_hi: 0.70},
        {name: "Forest",  min_lo: 0.00, min_hi: 0.10, max_lo: 0.30, max_hi: 0.55},
        {name: "Urban",   min_lo: 0.00, min_hi: 0.15, max_lo: 0.40, max_hi: 0.65},
        {name: "Caves",   min_lo: 0.00, min_hi: 0.08, max_lo: 0.20, max_hi: 0.40},
    ];
    return _terrains;
}

// Rolls a concrete terrain + min/max engagement distance from a random terrain type.
function random_terrain_band() {
    var _terrains = battle_terrain_types();
    var _t = _terrains[irandom(array_length(_terrains) - 1)];
    var _min = random_range(_t.min_lo + 0.05, _t.min_hi);
    var _max_lo = min(max(_min + 0.05, _t.max_lo), _t.max_hi);
    var _max = random_range(_max_lo, _t.max_hi);
    return {terrain: _t.name, min_distance: _min, max_distance: _max};
}

// The planet's fixed per-place terrain (generated once, then persisted for the whole game).
function planet_place_terrain(system, planet) {
    var _t = system.p_place_terrain[planet];
    if (!is_array(_t) || array_length(_t) < BATTLE_PLACES_MAX) {
        _t = [];
        for (var i = 0; i < BATTLE_PLACES_MAX; i++) {
            array_push(_t, random_terrain_band());
        }
        system.p_place_terrain[planet] = _t;
    }
    return _t;
}

// Enemy unit types per faction. Each:
//   name; tier (force level it appears at); max_health (squad durability); damage (combat output
//   per phase, before range fit & remaining-strength scaling); damage_reduction (0..1 fraction of
//   incoming damage ignored); optimal (range sweetspot, 0 melee .. 1 long range); healing
//   (per-turn self-heal; overflow above max spills to wounded allies in the same place);
//   models (head count shown); dist (per-MODEL distance shift per turn: + closes, - opens).
function faction_unit_types(faction) {
    switch (faction) {
        case eFACTION.ORK: return [
            {name: "Lootas",      tags: [eENEMY_TAG.INFANTRY], tier: 1, max_health: 18,  damage: 24,   damage_reduction: 0.00, optimal: 0.20, healing: 0, models: 300,  dist:  0.0001},
            {name: "Slugga Boyz", tags: [eENEMY_TAG.INFANTRY], tier: 1, max_health: 18,  damage: 24,   damage_reduction: 0.00, optimal: 0.50, healing: 0, models: 300,  dist:  0.0000},
            {name: "Tankbustas",  tags: [eENEMY_TAG.INFANTRY], tier: 2, max_health: 18,  damage: 90,   damage_reduction: 0.00, optimal: 0.80, healing: 0, models: 100,  dist:  -0.0003},
            {name: "Ard Boyz",    tags: [eENEMY_TAG.INFANTRY, eENEMY_TAG.ARMOURED], tier: 2, max_health: 18,  damage: 36,   damage_reduction: 0.10, optimal: 0.45, healing: 0, models: 300,  dist:  0.0000},
            {name: "Ork Nobz",    tags: [eENEMY_TAG.INFANTRY, eENEMY_TAG.ARMOURED], tier: 2, max_health: 120,  damage: 90,  damage_reduction: 0.10, optimal: 0.50, healing: 0, models: 30,   dist:  0.0002},
            {name: "Warbikers",   tags: [eENEMY_TAG.CAVALRY], tier: 3, max_health: 32,  damage: 70,   damage_reduction: 0.10, optimal: 0.05, healing: 0, models: 60,  dist:  0.0008},
            {name: "Battlewagon", tags: [eENEMY_TAG.VEHICLE], tier: 3, max_health: 320,  damage: 460,   damage_reduction: 0.15, optimal: 0.25, healing: 0, models: 12,  dist:  0.0002},
            {name: "Deffkoptas",  tags: [eENEMY_TAG.VEHICLE, eENEMY_TAG.FLYER], tier: 4, max_health: 120,  damage: 460,   damage_reduction: 0.25, optimal: 0.70, healing: 0, models: 9,  dist:  -0.0012},
            {name: "Dakkajet",    tags: [eENEMY_TAG.VEHICLE, eENEMY_TAG.FLYER], tier: 4, max_health: 320,  damage: 900,   damage_reduction: 0.25, optimal: 0.55, healing: 0, models: 3,  dist:  -0.0012},
            {name: "Killa Kanz",  tags: [eENEMY_TAG.VEHICLE], tier: 5, max_health: 320,  damage: 900,   damage_reduction: 0.25, optimal: 0.10, healing: 0, models: 5,  dist:  0.0010},
            {name: "Meganobz",    tags: [eENEMY_TAG.INFANTRY, eENEMY_TAG.ARMOURED, eENEMY_TAG.ELITE], tier: 5, max_health: 120,  damage: 720,  damage_reduction: 0.40, optimal: 0.05, healing: 0, models: 15,  dist:  0.0002},
            {name: "Deff Dreads", tags: [eENEMY_TAG.VEHICLE], tier: 6, max_health: 1250,  damage: 3000,   damage_reduction: 0.50, optimal: 0.50, healing: 0, models: 1,  dist:  0.0010},
            {name: "Gorkanauts",  tags: [eENEMY_TAG.VEHICLE, eENEMY_TAG.MONSTROUS], tier: 6, max_health: 3000,  damage: 3000,   damage_reduction: 0.50, optimal: 0.15, healing: 0, models: 1,  dist:  0.0010},
            {name: "Morkanauts",  tags: [eENEMY_TAG.VEHICLE, eENEMY_TAG.MONSTROUS], tier: 6, max_health: 3000,  damage: 3000,   damage_reduction: 0.50, optimal: 0.15, healing: 0, models: 1,  dist:  0.0010},
        ];
        case eFACTION.TYRANIDS: return [
            {name: "Neophytes",        tags: [eENEMY_TAG.INFANTRY], tier: 1, max_health: 10,  damage: 21,  damage_reduction: 0.00, optimal: 0.50, healing: 0,  models: 500, dist:  0.0000},
            {name: "Gaunts",           tags: [eENEMY_TAG.INFANTRY], tier: 1, max_health: 16,  damage: 21,  damage_reduction: 0.00, optimal: 0.05, healing: 0,  models: 600, dist:  0.0001},
            {name: "Tyranid Warriors", tags: [eENEMY_TAG.INFANTRY, eENEMY_TAG.ELITE], tier: 2, max_health: 75,  damage: 100, damage_reduction: 0.00, optimal: 0.05, healing: 10,  models: 40,  dist:  0.0002},
            {name: "Carnifexes",       tags: [eENEMY_TAG.MONSTROUS], tier: 3, max_health: 260, damage: 1000, damage_reduction: 0.00, optimal: 0.05, healing: 20, models: 4,   dist:  0.0003},
        ];
        case eFACTION.TAU: return [
            {name: "Kroots",        tags: [eENEMY_TAG.INFANTRY], tier: 1, max_health: 16,  damage: 60,  damage_reduction: 0.00, optimal: 0.05, healing: 0, models: 150, dist:  0.0002},
            {name: "Fire Warriors", tags: [eENEMY_TAG.INFANTRY], tier: 2, max_health: 14,  damage: 120, damage_reduction: 0.00, optimal: 0.75, healing: 0, models: 90, dist: -0.0001},
            {name: "Crisis Suits",  tags: [eENEMY_TAG.VEHICLE], tier: 3, max_health: 70,  damage: 500, damage_reduction: 0.05, optimal: 0.50, healing: 0, models: 16, dist: 0.0000},
            {name: "Broadsides",    tags: [eENEMY_TAG.VEHICLE], tier: 5, max_health: 180, damage: 5000, damage_reduction: 0.10, optimal: 0.95, healing: 0, models: 3,  dist: -0.0006},
        ];
        case eFACTION.NECRONS: return [
            {name: "Necron Warriors", tags: [eENEMY_TAG.INFANTRY], tier: 1, max_health: 24, damage: 300, damage_reduction: 0.15, optimal: 0.70, healing: 4, models: 30, dist: -0.0001},
            {name: "Immortals",       tags: [eENEMY_TAG.INFANTRY], tier: 3, max_health: 42, damage: 57, damage_reduction: 0.40, optimal: 0.75, healing: 6, models: 15, dist: -0.0002},
            {name: "Lychguard",       tags: [eENEMY_TAG.INFANTRY], tier: 5, max_health: 64, damage: 800, damage_reduction: 0.60, optimal: 0.15, healing: 8, models: 8,  dist:  0.0004},
        ];
        case eFACTION.ELDAR: return [
            {name: "Guardians",     tags: [eENEMY_TAG.INFANTRY], tier: 1, max_health: 18, damage: 240,  damage_reduction: 0.00, optimal: 0.25, healing: 0, models: 30, dist: 0.0002},
            {name: "Dire Avengers", tags: [eENEMY_TAG.INFANTRY], tier: 3, max_health: 34, damage: 450, damage_reduction: 0.30, optimal: 0.50, healing: 0, models: 15, dist: 0.0000},
            {name: "Wraithguards",   tags: [eENEMY_TAG.VEHICLE], tier: 5, max_health: 60, damage: 810, damage_reduction: 0.30, optimal: 0.35, healing: 4, models: 8,  dist:  0.0002},
        ];
        case eFACTION.CHAOS: return [
            {name: "Chaos Cultists",      tags: [eENEMY_TAG.INFANTRY], tier: 1, max_health: 10,  damage: 12,   damage_reduction: 0.00, optimal: 0.25, healing: 0, models: 500, dist:  0.000},
            {name: "Chaos Space Marines", tags: [eENEMY_TAG.ARMOURED, eENEMY_TAG.INFANTRY], tier: 3, max_health: 200, damage: 400,  damage_reduction: 0.40, optimal: 0.50, healing: 5, models: 10,  dist:  0.0000},
            {name: "Havocs",              tags: [eENEMY_TAG.ARMOURED, eENEMY_TAG.INFANTRY], tier: 3, max_health: 200, damage: 400,  damage_reduction: 0.40, optimal: 0.95, healing: 5, models: 10,  dist:  -0.0002},
            {name: "Raptors",             tags: [eENEMY_TAG.ARMOURED, eENEMY_TAG.INFANTRY], tier: 3, max_health: 200, damage: 400,  damage_reduction: 0.40, optimal: 0.05, healing: 5, models: 10,  dist:  0.0002},
            {name: "Chaos Terminators",   tags: [eENEMY_TAG.ARMOURED, eENEMY_TAG.ELITE], tier: 5, max_health: 400, damage: 600, damage_reduction: 0.60, optimal: 0.05, healing: 5, models: 5,   dist:  0.0003},
        ];
        case eFACTION.HERETICS: return [
            {name: "Traitor Guards",    tags: [eENEMY_TAG.INFANTRY], tier: 1, max_health: 15, damage: 21,  damage_reduction: 0.00, optimal: 0.60, healing: 0, models: 60, dist: -0.0008},
            {name: "Renegade Marines", tags: [eENEMY_TAG.INFANTRY], tier: 3, max_health: 40, damage: 54, damage_reduction: 0.15, optimal: 0.50, healing: 0, models: 18, dist:  0.001},
            {name: "Chaos Spawns",      tags: [eENEMY_TAG.INFANTRY], tier: 4, max_health: 70, damage: 96, damage_reduction: 0.10, optimal: 0.10, healing: 8, models: 6,  dist:  0.006},
        ];
        case eFACTION.IMPERIUM: return [
            {name: "Guardsmen",        tags: [eENEMY_TAG.INFANTRY], tier: 1, max_health: 15, damage: 21,  damage_reduction: 0.00, optimal: 0.60, healing: 0, models: 60, dist: -0.0008},
            {name: "Tempestus Scions", tags: [eENEMY_TAG.INFANTRY], tier: 3, max_health: 30, damage: 42, damage_reduction: 0.10, optimal: 0.70, healing: 0, models: 18, dist: -0.0016},
        ];
        case eFACTION.ECCLESIARCHY: return [
            {name: "Battle Sisters", tags: [eENEMY_TAG.INFANTRY], tier: 1, max_health: 26, damage: 36, damage_reduction: 0.10, optimal: 0.55, healing: 0, models: 20, dist:  0.0004},
            {name: "Seraphim",       tags: [eENEMY_TAG.INFANTRY], tier: 3, max_health: 36, damage: 48, damage_reduction: 0.10, optimal: 0.30, healing: 0, models: 12, dist:  0.004},
        ];
        default: return [{name: "Hostiles", tags: [eENEMY_TAG.INFANTRY], tier: 1, max_health: 18, damage: 8, damage_reduction: 0.00, optimal: 0.50, healing: 0, models: 30, dist: 0.001}];
    }
}

// Picks a unit type for the given faction at a given force level. Only types whose tier is
// reached are available, weighted toward higher tiers so stronger presence fields elites.
function pick_enemy_unit_type(faction, force) {
    var _types = faction_unit_types(faction);
    var _avail = [];
    var _total_w = 0;
    for (var i = 0; i < array_length(_types); i++) {
        if (_types[i].tier <= force) {
            array_push(_avail, _types[i]);
            _total_w += _types[i].tier; // higher tier => more weight at higher force
        }
    }
    if (array_length(_avail) == 0) {
        return _types[0]; // force below the lowest tier: basic unit
    }
    var _r = random(_total_w);
    var _acc = 0;
    for (var i = 0; i < array_length(_avail); i++) {
        _acc += _avail[i].tier;
        if (_r <= _acc) {
            return _avail[i];
        }
    }
    return _avail[array_length(_avail) - 1];
}

/// @param {real} faction eFACTION of the attacker this squad belongs to.
/// @param {Struct} [type_data] A unit type from faction_unit_types(); defaults to the basic type.
// `apply_buffs` should be true for freshly-fielded squads (so the global tankiness and vehicle
// health multipliers apply to the base faction_unit_types value); pass false when restoring a
// squad from save data whose max_health is already the buffed figure, to avoid double-scaling.
function EnemySquad(faction, type_data = undefined, apply_buffs = true) constructor {
    self.faction = faction;
    if (!is_struct(type_data)) {
        type_data = faction_unit_types(faction)[0];
    }
    unit_name = type_data.name;
    tier = variable_struct_exists(type_data, "tier") ? type_data.tier : 1;
    // Unit tags: a list of eENEMY_TAG integers describing what this unit is (e.g. VEHICLE). Tested
    // via has_tag() / is_vehicle(). Set with a `tags` list in faction_unit_types.
    tags = variable_struct_exists(type_data, "tags") ? type_data.tags : [];
    var _is_vehicle = array_contains(tags, eENEMY_TAG.VEHICLE);
    // Enemies are globally tankier; vehicles (the enemy's armour) tougher still. Scaling max_health
    // (and health with it) leaves the model count unchanged -- each model just absorbs more damage.
    var _health_mult = apply_buffs ? (ENEMY_HEALTH_MULT * (_is_vehicle ? ENEMY_VEHICLE_HEALTH_MULT : 1)) : 1;
    max_health = type_data.max_health * _health_mult;
    health = max_health;                 // current hit points (depletes as damaged, heals back)
    damage = type_data.damage;           // combat output per phase (before range/strength scaling)
    damage_reduction = variable_struct_exists(type_data, "damage_reduction") ? type_data.damage_reduction : 0;
    healing = variable_struct_exists(type_data, "healing") ? type_data.healing : 0;
    optimal = variable_struct_exists(type_data, "optimal") ? type_data.optimal : 0.5;
    models = type_data.models;
    dist = variable_struct_exists(type_data, "dist") ? type_data.dist : 0;
    // Damage falloff rate (steepness of damage drop away from `optimal`). Defaults from the unit's
    // band -- melee and long-range specialists fall off steeply, mid-range units gently -- and can
    // be overridden per unit type with a `falloff` field in faction_unit_types.
    falloff = variable_struct_exists(type_data, "falloff") ? type_data.falloff
            : ((optimal <= 0.2 || optimal >= 0.75) ? 3.5 : 1.6);
    // Max enemy kills PER MODEL per combat phase: how many marines a single model of this unit can
    // cut down in one ranged/melee exchange. The squad's per-phase kill budget is model_count *
    // max_kills. Defaults to 1 (a basic trooper drops at most one marine); tougher/elite units kill
    // more and can be set explicitly via a `max_kills` field in faction_unit_types.
    max_kills = variable_struct_exists(type_data, "max_kills") ? type_data.max_kills : 1;
    deployed_this_turn = false; // reinforcements can't be repositioned the turn they arrive
    uid = scr_uuid_generate();

    static is_alive = function() {
        return health > 0;
    };

    // True if this unit carries the given eENEMY_TAG.
    static has_tag = function(tag) {
        return array_contains(tags, tag);
    };

    // The function that checks for enemy vehicles: searches the tag list for the VEHICLE tag.
    static is_vehicle = function() {
        return array_contains(tags, eENEMY_TAG.VEHICLE);
    };

    // Models still standing, scaled by remaining health.
    static model_count = function() {
        return max(1, round(models * (health / max_health)));
    };

    // This unit fights best in melee (true) or at range (false).
    static is_melee = function() {
        return optimal <= 0.4;
    };
    static is_ranged = function() {
        return optimal > 0.4;
    };

    // Net distance-reduction this squad applies per turn (positive closes, negative opens).
    static distance_reduction = function() {
        return model_count() * dist;
    };

    // Combat output at engagement distance _d: base damage scaled by range fit (using this unit's
    // falloff rate, floored at 0) and by remaining strength (a battered squad hits softer).
    static damage_output = function(_d) {
        var _eff = clamp(1 - abs(_d - optimal) * falloff, 0, 1);
        return damage * _eff * (health / max_health);
    };

    // Applies incoming damage after this unit's damage_reduction. Returns the health actually lost.
    static take_damage = function(amount) {
        return take_net_damage(amount * (1 - damage_reduction));
    };

    // Removes an exact amount of health (already past any damage_reduction / bypass maths the
    // caller did). Returns the health actually lost.
    static take_net_damage = function(net) {
        var _before = health;
        health = max(0, health - net);
        return _before - health;
    };

    // Heals up to max_health; returns any overflow that could not be absorbed (spills to allies).
    static heal = function(amount) {
        var _room = max_health - health;
        var _applied = min(max(0, amount), _room);
        health += _applied;
        return max(0, amount - _applied);
    };
}

/// @param {real} index Position of this place within its BattleState (0-based).
function BattlePlace(index, terrain_data = undefined) constructor {
    self.index = index;
    marine_slots = array_create(BATTLE_SLOTS_PER_PLACE, undefined); // holds squad uids (strings)
    enemy_slots = [];  // holds EnemySquad structs -- UNBOUNDED (no per-place cap on enemy squads)

    // Terrain + engagement distance. Distance starts at this place's max and closes each turn.
    // Terrain is fixed for the planet (passed in); only fall back to a random roll if missing.
    if (is_struct(terrain_data)) {
        terrain = terrain_data.terrain;
        min_distance = terrain_data.min_distance;
        max_distance = terrain_data.max_distance;
    } else {
        var _t = random_terrain_band();
        terrain = _t.terrain;
        min_distance = _t.min_distance;
        max_distance = _t.max_distance;
    }
    distance = max_distance;
    stance = "hold"; // "hold" closes slowly, "push" closes quickly, "fallback" opens the range
    role = PLACE_REINFORCEMENT; // objective / reinforcement / base (assigned by BattleState)

    static marine_count = function() {
        var _c = 0;
        for (var i = 0; i < BATTLE_SLOTS_PER_PLACE; i++) {
            if (marine_slots[i] != undefined) {
                _c++;
            }
        }
        return _c;
    };

    static enemy_count = function() {
        return array_length(enemy_slots); // dynamic array: no undefined holes
    };

    static free_marine_slots = function() {
        return BATTLE_SLOTS_PER_PLACE - marine_count();
    };

    // Enemy squads are uncapped per place, so there is always room.
    static free_enemy_slots = function() {
        return infinity;
    };

    static first_free_marine_slot = function() {
        for (var i = 0; i < BATTLE_SLOTS_PER_PLACE; i++) {
            if (marine_slots[i] == undefined) {
                return i;
            }
        }
        return -1;
    };

    static add_marine_squad = function(squad_uid) {
        if (array_contains(marine_slots, squad_uid)) {
            return true; // already present
        }
        var _slot = first_free_marine_slot();
        if (_slot == -1) {
            return false;
        }
        marine_slots[_slot] = squad_uid;
        return true;
    };

    static add_enemy_squad = function(enemy_squad) {
        array_push(enemy_slots, enemy_squad); // uncapped: always succeeds
        return true;
    };

    static remove_marine_squad = function(squad_uid) {
        for (var i = 0; i < BATTLE_SLOTS_PER_PLACE; i++) {
            if (marine_slots[i] == squad_uid) {
                marine_slots[i] = undefined;
                return true;
            }
        }
        return false;
    };

    static remove_enemy_squad = function(enemy_squad) {
        for (var i = 0; i < array_length(enemy_slots); i++) {
            if (enemy_slots[i] == enemy_squad) {
                array_delete(enemy_slots, i, 1);
                return true;
            }
        }
        return false;
    };

    static marine_squad_uids = function() {
        var _out = [];
        for (var i = 0; i < BATTLE_SLOTS_PER_PLACE; i++) {
            if (marine_slots[i] != undefined) {
                array_push(_out, marine_slots[i]);
            }
        }
        return _out;
    };

    static enemy_squads = function() {
        var _out = [];
        for (var i = 0; i < array_length(enemy_slots); i++) {
            array_push(_out, enemy_slots[i]);
        }
        return _out;
    };

    // Drops any enemy squads that have been reduced to zero strength.
    static cull_dead_enemies = function() {
        for (var i = array_length(enemy_slots) - 1; i >= 0; i--) {
            if (!enemy_slots[i].is_alive()) {
                array_delete(enemy_slots, i, 1);
            }
        }
    };
}

/// @param {Asset.GMObject.obj_star} system The star that owns the contested planet.
/// @param {real} planet Planet index within the system.
function BattleState(system, planet) constructor {
    self.system = system;
    self.planet = planet;
    enemy_faction = eFACTION.ORK; // set properly by start_battle / materialize
    places = [];
    var _terrain = planet_place_terrain(system, planet); // fixed terrain for this planet
    for (var i = 0; i < BATTLE_PLACES_MAX; i++) {
        array_push(places, new BattlePlace(i, _terrain[i]));
    }
    // Assign place roles: exactly one objective, one reinforcement (enemy entry), one base of
    // operations. With 3 places that is one each; if BATTLE_PLACES_MAX ever changes, extras
    // default to reinforcement.
    if (array_length(places) >= 3) {
        places[0].role = PLACE_OBJECTIVE;
        places[1].role = PLACE_REINFORCEMENT;
        places[2].role = PLACE_BASE;
        for (var i = 3; i < array_length(places); i++) {
            places[i].role = PLACE_REINFORCEMENT;
        }
    }
    objective_index = 0;          // which place is currently the objective
    objective_control_turns = 0;  // cumulative turns the objective has been held by CM/standard
    shift_timer = OBJECTIVE_SHIFT_TURNS; // turns until the objective shifts to another place
    shift_warning = false;        // true the turn before a shift (UI hint)

    // Per-turn specialist save budgets (transient; reset each turn by resolve_planet_battle).
    // used_savers: set of "company_marinenumber" keys for apothecaries/techmarines/chaplains spent
    // this turn (each may attempt one save). standard_used: set of place indices whose standard has
    // already averted a death this turn (the standard succeeds at most once per turn per place).
    used_savers = {};
    standard_used = {};

    // Upper bound on the number of enemy squads that can be fielded at once. Enemy squads are NOT
    // capped per place; this is just a high ceiling so the planet's force scalar (and the squads-
    // per-force ratio) is what actually decides how many squads materialise/reinforce.
    max_enemy_slots = 999;

    // Convenience accessors for the role places (return undefined if somehow missing).
    static place_of_role = function(_role) {
        for (var i = 0; i < array_length(places); i++) {
            if (places[i].role == _role) {
                return places[i];
            }
        }
        return undefined;
    };
    static objective_place = function() {
        return place_of_role(PLACE_OBJECTIVE);
    };
    static reinforcement_place = function() {
        return place_of_role(PLACE_REINFORCEMENT);
    };
    static base_place = function() {
        return place_of_role(PLACE_BASE);
    };

    static total_marines = function() {
        var _c = 0;
        for (var i = 0; i < array_length(places); i++) {
            _c += places[i].marine_count();
        }
        return _c;
    };

    static total_enemies = function() {
        var _c = 0;
        for (var i = 0; i < array_length(places); i++) {
            _c += places[i].enemy_count();
        }
        return _c;
    };

    static enemy_slots_filled = function() {
        return total_enemies();
    };

    // A battle ends only once no enemy squads remain anywhere on the planet.
    static is_over = function() {
        return total_enemies() == 0;
    };

    // Place with the fewest enemy squads (enemies reinforce the least-populated place first).
    static least_populated_enemy_place = function() {
        var _best = places[0];
        for (var i = 1; i < array_length(places); i++) {
            if (places[i].enemy_count() < _best.enemy_count()) {
                _best = places[i];
            }
        }
        return _best;
    };

    // Friendly place with the least available slots of the given kind ("marine" or "enemy"),
    // i.e. the most concentrated place that still has room. Returns undefined if all are full.
    static least_available_place = function(kind) {
        var _best = undefined;
        var _best_free = BATTLE_SLOTS_PER_PLACE + 1;
        for (var i = 0; i < array_length(places); i++) {
            var _free = (kind == "enemy") ? places[i].free_enemy_slots() : places[i].free_marine_slots();
            if (_free > 0 && _free < _best_free) {
                _best_free = _free;
                _best = places[i];
            }
        }
        return _best;
    };

    // Adds an enemy squad to the least-populated place that still has room. Returns true on success.
    static add_enemy_to_least_populated = function(enemy_squad) {
        if (total_enemies() >= max_enemy_slots) {
            return false;
        }
        // Re-evaluate the least-populated place per squad so fills spread out evenly.
        var _target = least_populated_enemy_place();
        if (_target.free_enemy_slots() <= 0) {
            return false;
        }
        return _target.add_enemy_squad(enemy_squad);
    };

    // Enemy reinforcements may ONLY enter at the reinforcement place. The squad is flagged as
    // deployed_this_turn so it can't be repositioned until next turn. Returns true on success.
    static add_enemy_reinforcement = function(enemy_squad) {
        if (total_enemies() >= max_enemy_slots) {
            return false;
        }
        var _target = reinforcement_place();
        if (_target == undefined || _target.free_enemy_slots() <= 0) {
            return false;
        }
        enemy_squad.deployed_this_turn = true;
        return _target.add_enemy_squad(enemy_squad);
    };

    // Plain-data form for saving (strips methods; the system reference is rebuilt on load).
    static serialize = function() {
        var _places_data = [];
        for (var i = 0; i < array_length(places); i++) {
            var _place = places[i];
            var _enemies_data = [];
            var _en = _place.enemy_squads();
            for (var e = 0; e < array_length(_en); e++) {
                // Read each field defensively so an EnemySquad created before the HP-stat rewrite
                // (which used strength/max_strength) still serialises without crashing.
                var _e = _en[e];
                var _max_hp = variable_struct_exists(_e, "max_health") ? _e.max_health
                            : (variable_struct_exists(_e, "max_strength") ? _e.max_strength : 18);
                var _hp = variable_struct_exists(_e, "health") ? _e.health
                        : (variable_struct_exists(_e, "strength") ? _e.strength : _max_hp);
                array_push(_enemies_data, {
                    faction: _e.faction,
                    unit_name: variable_struct_exists(_e, "unit_name") ? _e.unit_name : "Hostiles",
                    tier: variable_struct_exists(_e, "tier") ? _e.tier : 1,
                    max_health: _max_hp,
                    health: _hp,
                    damage: variable_struct_exists(_e, "damage") ? _e.damage : round(_max_hp * 0.45),
                    damage_reduction: variable_struct_exists(_e, "damage_reduction") ? _e.damage_reduction : 0,
                    healing: variable_struct_exists(_e, "healing") ? _e.healing : 0,
                    optimal: variable_struct_exists(_e, "optimal") ? _e.optimal : 0.5,
                    falloff: variable_struct_exists(_e, "falloff") ? _e.falloff : 1.6,
                    max_kills: variable_struct_exists(_e, "max_kills") ? _e.max_kills : 1,
                    tags: variable_struct_exists(_e, "tags") ? _e.tags : [],
                    models: variable_struct_exists(_e, "models") ? _e.models : 15,
                    dist: variable_struct_exists(_e, "dist") ? _e.dist : 0,
                    deployed_this_turn: variable_struct_exists(_e, "deployed_this_turn") ? _e.deployed_this_turn : false
                });
            }
            array_push(_places_data, {
                index: _place.index,
                marines: _place.marine_squad_uids(),
                enemies: _enemies_data,
                terrain: _place.terrain,
                min_distance: _place.min_distance,
                max_distance: _place.max_distance,
                distance: _place.distance,
                stance: _place.stance,
                role: _place.role
            });
        }
        return {
            enemy_faction: enemy_faction,
            max_enemy_slots: max_enemy_slots,
            objective_index: objective_index,
            objective_control_turns: objective_control_turns,
            shift_timer: shift_timer,
            shift_warning: shift_warning,
            places: _places_data
        };
    };
}

// Rebuilds a BattleState from the plain data produced by BattleState.serialize().
function battle_state_from_data(system, planet, data) {
    var _bs = new BattleState(system, planet);
    _bs.enemy_faction = data.enemy_faction;
    _bs.max_enemy_slots = data.max_enemy_slots;
    if (variable_struct_exists(data, "objective_index")) { _bs.objective_index = data.objective_index; }
    if (variable_struct_exists(data, "objective_control_turns")) { _bs.objective_control_turns = data.objective_control_turns; }
    if (variable_struct_exists(data, "shift_timer")) { _bs.shift_timer = data.shift_timer; }
    if (variable_struct_exists(data, "shift_warning")) { _bs.shift_warning = data.shift_warning; }
    for (var i = 0; i < array_length(data.places); i++) {
        var _pd = data.places[i];
        if (i >= array_length(_bs.places)) {
            break;
        }
        var _place = _bs.places[i];
        if (variable_struct_exists(_pd, "terrain")) {
            _place.terrain = _pd.terrain;
            _place.min_distance = _pd.min_distance;
            _place.max_distance = _pd.max_distance;
            _place.distance = _pd.distance;
            _place.stance = _pd.stance;
        }
        if (variable_struct_exists(_pd, "role")) {
            _place.role = _pd.role;
        }
        for (var m = 0; m < array_length(_pd.marines); m++) {
            _place.add_marine_squad(_pd.marines[m]);
        }
        for (var e = 0; e < array_length(_pd.enemies); e++) {
            var _ed = _pd.enemies[e];
            var _td = {
                name: variable_struct_exists(_ed, "unit_name") ? _ed.unit_name : "Hostiles",
                tier: variable_struct_exists(_ed, "tier") ? _ed.tier : 1,
                max_health: variable_struct_exists(_ed, "max_health") ? _ed.max_health : 18,
                damage: variable_struct_exists(_ed, "damage") ? _ed.damage : 8,
                damage_reduction: variable_struct_exists(_ed, "damage_reduction") ? _ed.damage_reduction : 0,
                healing: variable_struct_exists(_ed, "healing") ? _ed.healing : 0,
                optimal: variable_struct_exists(_ed, "optimal") ? _ed.optimal : 0.5,
                models: variable_struct_exists(_ed, "models") ? _ed.models : 15,
                dist: variable_struct_exists(_ed, "dist") ? _ed.dist : 0
            };
            if (variable_struct_exists(_ed, "falloff")) {
                _td.falloff = _ed.falloff; // restore saved falloff (else EnemySquad picks a band default)
            }
            if (variable_struct_exists(_ed, "max_kills")) {
                _td.max_kills = _ed.max_kills; // restore saved Max Kills (else EnemySquad defaults to 1)
            }
            if (variable_struct_exists(_ed, "tags")) {
                _td.tags = _ed.tags; // restore the unit's tag list (vehicle toughness etc.)
            }
            // apply_buffs = false: the saved max_health is already the buffed figure -- don't re-scale.
            var _sq = new EnemySquad(_ed.faction, _td, false);
            if (variable_struct_exists(_ed, "health")) {
                _sq.health = _ed.health; // restore current (possibly reduced) hit points
            }
            if (variable_struct_exists(_ed, "deployed_this_turn")) {
                _sq.deployed_this_turn = _ed.deployed_this_turn;
            }
            _place.add_enemy_squad(_sq);
        }
    }
    return _bs;
}

// Approximate number of ground squads an enemy fleet disgorges, scaled by ship size.
// Mirrors the strength weighting used for fleet sprites (capitals worth most).
function fleet_ground_squad_count(fleet) {
    var _n = (fleet.capital_number * 4) + (fleet.frigate_number * 2) + (fleet.escort_number * 1);
    return max(1, floor(_n));
}

/// @description Lands an arriving enemy fleet's troops onto a planet that already has an
/// active battle, filling enemy slots (least-populated places first) by ship size, capped by
/// the garrison-reduced max. Returns the number of squads added, or -1 if there is no active
/// battle (in which case the caller should use the normal scalar landing behaviour instead).
/// @param {Id.Instance} fleet The arriving enemy fleet (obj_en_fleet).
/// @param {Struct.PlanetData} planet_data Target planet wrapper.
/// @param {real} faction eFACTION of the attacker.
function fleet_disembark_to_battle(fleet, planet_data, faction) {
    if (!planet_data.has_battle()) {
        return -1;
    }
    var _bs = planet_data.start_battle(faction);
    var _wanted = fleet_ground_squad_count(fleet);
    var _force = planet_data.planet_forces[faction];
    var _added = 0;
    repeat (_wanted) {
        if (!_bs.add_enemy_to_least_populated(new EnemySquad(faction, pick_enemy_unit_type(faction, _force)))) {
            break; // places full (garrison cap reached)
        }
        _added++;
    }
    planet_data.sync_counts_from_places();
    return _added;
}

// =======================================================================================
// End-of-turn resolution for the slot-based ground battle model.
//
// Once per end-of-turn we, per planet:
//   1. top up enemy squads from the scalar force count and apply the garrison slot cap,
//   2. resolve every place (marine squads vs enemy squads sharing that place),
//   3. let cleared units redeploy toward the fighting,
//   4. write surviving totals back to the scalar counts; the battle persists until no
//      enemies remain (or the marines are wiped).
//
// Casualties are applied directly to the marine structs (kill_and_recover handles
// gene-seed/equipment/roster counts), so no obj_ncombat / obj_pnunit objects are needed.
// =======================================================================================

// Tuning knobs.
#macro MARINE_DAMAGE_COEF 0.6
#macro ENEMY_DAMAGE_COEF 0.6
#macro GARRISON_PER_ENEMY_SLOT 1000 // Imperial Guard headcount that removes one enemy slot

// --- Combat power & engagement distance -------------------------------------------------

// The name string of a weapon (handles plain-string weapons and artifact structs).
function weapon_name_string(weapon) {
    if (is_string(weapon)) {
        return weapon;
    }
    if (is_struct(weapon)) {
        if (variable_struct_exists(weapon, "name")) {
            return weapon.name;
        }
        if (variable_struct_exists(weapon, "base")) {
            return weapon.base;
        }
        if (variable_struct_exists(weapon, "type")) {
            return weapon.type;
        }
    }
    return "";
}

// The distance bands (0 melee .. 1 long range) at which a weapon is effective. Returns an ARRAY:
// most weapons have a single sweetspot, but combination weapons have more than one (e.g. the
// Boltstorm Gauntlet is a power fist AND a bolt pistol, so it is deadly in melee and at close
// range). Efficiency is read as the best of the weapon's sweetspots at the current distance.
function weapon_optimal_distances(weapon) {
    var _n = string_lower(weapon_name_string(weapon));
    if (_n == "") {
        return [0.5];
    }
    // --- Combination weapons: more than one sweetspot ---
    if (string_pos("boltstorm", _n)) {
        return [0.05, 0.2]; // power fist (melee) + bolt pistol (close)
    }
    if (string_pos("combi", _n)) {
        return [0.5, 0.3]; // bolter body + short-ranged special (flamer/melta/plasma)
    }
    if (string_pos("flamestorm", _n) || string_pos("flamer gauntlet", _n)) {
        return [0.05, 0.3]; // power fist + flamer
    }
    // --- Single-sweetspot weapons (keyword bands) ---
    if (string_pos("knife", _n) || string_pos("sword", _n) || string_pos("axe", _n)
        || string_pos("hammer", _n) || string_pos("claw", _n) || string_pos("fist", _n)
        || string_pos("chain", _n) || string_pos("glaive", _n) || string_pos("spear", _n)
        || string_pos("blade", _n) || string_pos("maul", _n) || string_pos("halberd", _n)
        || string_pos("whip", _n) || string_pos("melee", _n) || string_pos("crozius", _n)
        || string_pos("staff", _n) || string_pos("lance", _n) || string_pos("eviscerator", _n)) {
        return [0.05];
    }
    if (string_pos("lascannon", _n) || string_pos("missile", _n) || string_pos("cannon", _n)
        || string_pos("artillery", _n) || string_pos("las cannon", _n)) {
        return [0.95];
    }
    if (string_pos("sniper", _n) || string_pos("longrifle", _n)) {
        return [0.8];
    }
    if (string_pos("heavy bolter", _n)) {
        return [0.7];
    }
    if (string_pos("plasma", _n) && (string_pos("pistol", _n) == 0)) {
        return [0.4]; // plasma gun (plasma pistol falls through to pistol)
    }
    if (string_pos("pistol", _n)) {
        return [0.2];
    }
    if (string_pos("flamer", _n) || string_pos("melta", _n)) {
        return [0.3];
    }
    return [0.5]; // bolters, generic guns, rifles
}

// The weapon's primary sweetspot (the first listed) -- used for classification and display.
function weapon_optimal_distance(weapon) {
    return weapon_optimal_distances(weapon)[0];
}

// Damage falloff rate: how fast effectiveness drops per unit of distance away from a sweetspot.
// Higher = steeper. At rate R, a weapon at distance D from its sweetspot does (1 - D*R) of its
// damage, floored at 0. Examples: chainsword R=5 -> 100% at 0.05, 0% by 0.25; bolter R~1.1 ->
// 100% at 0.50, ~50% at 0.05; heavy/long-range weapons are steep so they're useless up close.
function weapon_falloff(weapon) {
    var _n = string_lower(weapon_name_string(weapon));
    if (_n == "") {
        return 1.5;
    }
    // Melee weapons: extremely steep (deadly in the clinch, useless at any range).
    if (string_pos("knife", _n) || string_pos("sword", _n) || string_pos("axe", _n)
        || string_pos("hammer", _n) || string_pos("claw", _n) || string_pos("fist", _n)
        || string_pos("chain", _n) || string_pos("glaive", _n) || string_pos("spear", _n)
        || string_pos("blade", _n) || string_pos("maul", _n) || string_pos("halberd", _n)
        || string_pos("whip", _n) || string_pos("melee", _n) || string_pos("crozius", _n)
        || string_pos("staff", _n) || string_pos("lance", _n) || string_pos("eviscerator", _n)
        || string_pos("boltstorm", _n) || string_pos("flamestorm", _n)) {
        return 5.0;
    }
    // Heavy / long-range weapons: steep, so they fall off hard if the enemy closes in.
    if (string_pos("lascannon", _n) || string_pos("missile", _n) || string_pos("cannon", _n)
        || string_pos("artillery", _n) || string_pos("sniper", _n) || string_pos("longrifle", _n)
        || string_pos("heavy bolter", _n) || string_pos("multi-melta", _n) || string_pos("multimelta", _n)) {
        return 5.0;
    }
    // Pistols: short-ranged, fairly steep.
    if (string_pos("pistol", _n)) {
        return 2.5;
    }
    // Flamers / meltas: short range, steep.
    if (string_pos("flamer", _n) || string_pos("melta", _n)) {
        return 3.0;
    }
    if (string_pos("plasma", _n)) {
        return 1.5;
    }
    return 1.1; // bolters / generic guns / rifles: gentle falloff
}

// A weapon's "Max Kills" -- the most enemies it can cut down in one combat phase. This is the
// weapon's `spli` (splash) stat, floored at 1, matching the "Max Kills: {max(1, spli)}" shown in
// the equipment tooltip. Reads it from an EquipmentStruct/artifact directly, otherwise from the
// global weapons table by name; falls back to 1 for unknown/empty weapons.
function weapon_max_kills(weapon) {
    if (is_struct(weapon) && variable_struct_exists(weapon, "spli")) {
        return max(1, weapon.spli);
    }
    var _name = weapon_name_string(weapon);
    if (_name != "" && variable_struct_exists(global.weapons, _name)) {
        var _w = global.weapons[$ _name];
        if (variable_struct_exists(_w, "spli")) {
            return max(1, _w.spli);
        }
    }
    return 1;
}

// Weapon effectiveness at a given engagement distance (0 = useless .. 1 = optimal), taken as the
// best of the weapon's sweetspots, using the weapon's own falloff rate.
function weapon_distance_efficiency(weapon, distance) {
    var _opts = weapon_optimal_distances(weapon);
    var _fall = weapon_falloff(weapon);
    var _best = 0;
    for (var i = 0; i < array_length(_opts); i++) {
        var _e = clamp(1 - abs(distance - _opts[i]) * _fall, 0, 1);
        if (_e > _best) {
            _best = _e;
        }
    }
    return _best;
}

// A weapon's tag list (the lowercase tag strings from weapons.json). Reads an EquipmentStruct /
// artifact's own `tags` if present, otherwise looks the weapon up by name in the global weapons
// table. Returns an empty array for unknown/untagged weapons.
function weapon_tag_list(weapon) {
    if (is_struct(weapon) && variable_struct_exists(weapon, "tags") && is_array(weapon.tags)) {
        return weapon.tags;
    }
    var _name = weapon_name_string(weapon);
    if (_name != "" && variable_struct_exists(global.weapons, _name)) {
        var _w = global.weapons[$ _name];
        if (variable_struct_exists(_w, "tags") && is_array(_w.tags)) {
            return _w.tags;
        }
    }
    return [];
}

// True if the tag list marks a melee (close-combat) weapon. A generic "melee" tag is honoured, as
// are the specific close-combat weapon tags used in weapons.json.
function weapon_is_melee_tagged(_tags) {
    var _melee = ["melee", "sword", "axe", "fist", "hammer", "mace", "chain", "spear", "heavy_melee", "power", "force"];
    for (var i = 0; i < array_length(_melee); i++) {
        if (array_contains(_tags, _melee[i])) {
            return true;
        }
    }
    return false;
}

// Per-turn range-reduction a weapon contributes (positive closes toward melee, negative opens
// toward range), decided entirely by the weapon's TAGS:
//   - banner: a company standard rallies the line and holds it at range (strong negative).
//   - heavy_ranged, unless it is also flame/melta: heavy guns kite to keep the range open.
//   - sniper: snipers / long rifles likewise open the range (they are not "heavy" weapons).
//   - melee, unless it is a knife or polearm: close-combat weapons drive the charge in.
//   - everything else (bolters, pistols, knives, polearms, short-ranged flame/melta heavies): neutral.
function weapon_distance_reduction(weapon) {
    var _tags = weapon_tag_list(weapon);
    if (array_contains(_tags, "banner") || array_contains(_tags, "standard")) {
        return -0.017;
    }
    if (array_contains(_tags, "heavy_ranged") && !array_contains(_tags, "flame") && !array_contains(_tags, "melta")) {
        return -0.013;
    }
    if (array_contains(_tags, "sniper")) {
        return -0.013;
    }
    if (weapon_is_melee_tagged(_tags) && !array_contains(_tags, "knife") && !array_contains(_tags, "polearm")) {
        return 0.01;
    }
    return 0;
}

// Mobility (jump pack / bike) lets a marine close distance quickly.
function mobility_distance_reduction(mobi) {
    var _n = string_lower(weapon_name_string(mobi));
    if (string_pos("jump", _n) || string_pos("bike", _n) || string_pos("speeder", _n)) {
        return 0.02;
    }
    return 0;
}

// Total per-turn distance reduction a single marine contributes (weapons + mobility + gear).
function marine_distance_reduction(unit) {
    if (!is_struct(unit) || unit.name() == "" || unit.hp() <= 0) {
        return 0;
    }
    var _r = 0;
    _r += weapon_distance_reduction(unit.weapon_one());
    _r += weapon_distance_reduction(unit.weapon_two());
    _r += mobility_distance_reduction(unit.mobility_item());
    _r += weapon_distance_reduction(unit.gear()); // catches a company standard carried as gear
    return _r;
}

// Net per-turn distance reduction from all marines in a place (positive closes the range).
function place_marine_distance_reduction(place) {
    var _r = 0;
    var _uids = place.marine_squad_uids();
    for (var s = 0; s < array_length(_uids); s++) {
        var _mems = marine_squad_living_members(_uids[s]);
        for (var m = 0; m < array_length(_mems); m++) {
            _r += marine_distance_reduction(_mems[m]);
        }
    }
    return _r;
}

// Net per-turn distance reduction from all enemy squads in a place.
function place_enemy_distance_reduction(place) {
    var _r = 0;
    var _en = place.enemy_squads();
    for (var e = 0; e < array_length(_en); e++) {
        _r += _en[e].distance_reduction();
    }
    return _r;
}

// The engagement distance this place is expected to reach next turn, given its current
// occupants and stance. Mirrors the end-of-turn update in resolve_planet_battle so the battle
// view can show a live "Range: now -> next" prediction that updates as the player deploys/moves
// squads or toggles push/hold. A place with only one side present does not move.
// Per-turn distance bonus from a place's stance: push closes, hold holds, fallback opens hard.
function stance_distance_bonus(stance) {
    switch (stance) {
        case "push":     return STANCE_PUSH_BONUS;
        case "fallback": return STANCE_FALLBACK_BONUS;
        default:         return STANCE_HOLD_BONUS; // "hold"
    }
}

// The next stance when the player clicks the toggle (hold -> push -> fallback -> hold).
function next_stance(stance) {
    switch (stance) {
        case "hold":     return "push";
        case "push":     return "fallback";
        default:         return "hold"; // "fallback"
    }
}

function expected_next_distance(place) {
    if (place.marine_count() == 0 || place.enemy_count() == 0) {
        return place.distance;
    }
    var _reduction = place_marine_distance_reduction(place) + place_enemy_distance_reduction(place);
    _reduction += stance_distance_bonus(place.stance);
    return clamp(place.distance - _reduction, place.min_distance, place.max_distance);
}

// Human-readable description of a single sweetspot value.
function sweetspot_band_name(_o) {
    if (_o <= 0.2) { return "melee"; }
    if (_o <= 0.45) { return "close"; }
    if (_o <= 0.65) { return "mid-range"; }
    if (_o <= 0.85) { return "long-range"; }
    return "extreme range";
}

// Human-readable "optimal distance" line for weapon tooltips. Lists every sweetspot, so a
// combination weapon reads e.g. "Optimal distance: 0.05 (melee), 0.20 (close)".
function weapon_sweetspot_text(weapon) {
    if (weapon_name_string(weapon) == "") {
        return "";
    }
    var _opts = weapon_optimal_distances(weapon);
    var _txt = "Optimal distance: ";
    for (var i = 0; i < array_length(_opts); i++) {
        _txt += (i > 0 ? ", " : "") + $"{string_format(_opts[i], 1, 2)} ({sweetspot_band_name(_opts[i])})";
    }
    return _txt;
}

// Human-readable per-turn range-reduction line for weapon/equipment tooltips.
function weapon_range_reduction_text(weapon) {
    if (weapon_name_string(weapon) == "") {
        return "";
    }
    var _r = weapon_distance_reduction(weapon);
    if (_r > 0) {
        return $"Range reduction: +{string_format(_r, 1, 3)} (closes the gap)";
    }
    if (_r < 0) {
        return $"Range reduction: {string_format(_r, 1, 3)} (opens the range)";
    }
    return "Range reduction: 0 (neutral)";
}

function vehicle_optimal_distance(role) {
    switch (role) {
        case "Whirlwind":    return 0.95;
        case "Predator":     return 0.80;
        case "Land Raider":  return 0.70;
        case "Land Speeder": return 0.15;
        case "Rhino":        return 0.25;
        default:             return 0.50;
    }
}

function marine_unit_combat_value(unit, distance = 0.5) {
    if (!is_struct(unit) || unit.name() == "" || unit.hp() <= 0) {
        return 0;
    }
    var _ws = unit.weapon_skill, _bs = unit.ballistic_skill, _str = unit.strength;
    var _weps = [unit.weapon_one(), unit.weapon_two()];
    var _best = 0;
    for (var w = 0; w < array_length(_weps); w++) {
        if (weapon_name_string(_weps[w]) == "") {
            continue;
        }
        var _o = weapon_optimal_distance(_weps[w]);
        var _eff = weapon_distance_efficiency(_weps[w], distance); // uses the weapon's falloff
        // Melee weapons (low optimal) draw on weapon skill + strength; ranged on ballistic skill.
        var _stat = (_o <= 0.25) ? ((_ws + _str) / 2) : _bs;
        var _val = (1 + _stat / 20) * _eff;
        if (_val > _best) {
            _best = _val;
        }
    }
    if (_best <= 0) {
        _best = (1 + (_ws + _bs + _str) / 30) * 0.5; // no weapon data: generic, halved
    }
    return _best;
}

// A marine's combat value contributed in a specific phase ("ranged" or "melee"). Each of the
// unit's weapons contributes through ANY sweetspot that falls in the phase's band (a sweetspot
// <= 0.25 is a melee sweetspot, otherwise ranged), so a combination weapon (e.g. the Boltstorm
// Gauntlet) can fight in both phases. A weaponless marine falls back to a token melee value.
// A marine's best phase contribution AND the weapon that produced it, as { value, weapon }. The
// weapon is returned so callers can read its tags (sniper/melta/las/polearm) for tag interactions.
// A marine wielding two dual-tagged weapons hits harder (DUAL_BONUS).
function marine_phase_best(unit, distance, phase) {
    if (!is_struct(unit) || unit.name() == "" || unit.hp() <= 0) {
        return {value: 0, weapon: ""};
    }
    var _ws = unit.weapon_skill, _bs = unit.ballistic_skill, _str = unit.strength;
    var _w1 = unit.weapon_one(), _w2 = unit.weapon_two();
    var _weps = [_w1, _w2];
    var _best = 0;
    var _best_w = "";
    var _has_any = false;
    for (var w = 0; w < array_length(_weps); w++) {
        if (weapon_name_string(_weps[w]) == "") {
            continue;
        }
        _has_any = true;
        var _opts = weapon_optimal_distances(_weps[w]);
        var _fall = weapon_falloff(_weps[w]);
        for (var o = 0; o < array_length(_opts); o++) {
            var _od = _opts[o];
            var _is_melee_sweet = (_od <= 0.25);
            if (phase == "melee" && !_is_melee_sweet) { continue; }
            if (phase == "ranged" && _is_melee_sweet) { continue; }
            var _eff = clamp(1 - abs(distance - _od) * _fall, 0, 1);
            var _stat = _is_melee_sweet ? ((_ws + _str) / 2) : _bs;
            var _val = (1 + _stat / 20) * _eff;
            if (_val > _best) {
                _best = _val;
                _best_w = _weps[w];
            }
        }
    }
    if (_best <= 0 && !_has_any && phase == "melee") {
        _best = (1 + (_ws + _str) / 30) * 0.4; // unarmed: weak melee only
    }
    // Dual-wield bonus: both weapon slots occupied with dual-tagged weapons hit harder.
    if (_best > 0 && array_contains(weapon_tag_list(_w1), "dual") && array_contains(weapon_tag_list(_w2), "dual")) {
        _best *= DUAL_BONUS;
    }
    return {value: _best, weapon: _best_w};
}

// A marine's best phase contribution value (the combat power it adds in this phase).
function marine_phase_value(unit, distance, phase) {
    return marine_phase_best(unit, distance, phase).value;
}

// The most enemies a marine can kill in a given phase: the Max Kills of whichever of its weapons
// is effective in that phase (a sweetspot <= 0.25 is melee, otherwise ranged). Returns 0 if the
// marine has no weapon that fights in this phase (so it adds nothing to the side's kill budget),
// except an unarmed marine can still cut down one foe in melee.
function marine_phase_max_kills(unit, phase) {
    if (!is_struct(unit) || unit.name() == "" || unit.hp() <= 0) {
        return 0;
    }
    var _weps = [unit.weapon_one(), unit.weapon_two()];
    var _best = 0;
    var _has_any = false;
    for (var w = 0; w < array_length(_weps); w++) {
        if (weapon_name_string(_weps[w]) == "") {
            continue;
        }
        _has_any = true;
        var _opts = weapon_optimal_distances(_weps[w]);
        for (var o = 0; o < array_length(_opts); o++) {
            var _is_melee_sweet = (_opts[o] <= 0.25);
            if (phase == "melee" && !_is_melee_sweet) { continue; }
            if (phase == "ranged" && _is_melee_sweet) { continue; }
            _best = max(_best, weapon_max_kills(_weps[w]));
        }
    }
    if (_best <= 0 && !_has_any && phase == "melee") {
        _best = 1; // unarmed marine still kills at most one foe in melee
    }
    return _best;
}

// Living, named members of a squad (by uid).
function marine_squad_living_members(squad_uid) {
    var _sq = fetch_squad(squad_uid);
    if (!is_struct(_sq)) {
        return [];
    }
    var _out = [];
    for (var i = 0; i < array_length(_sq.members); i++) {
        var _u = fetch_unit(_sq.members[i]);
        if (is_struct(_u) && _u.name() != "" && _u.hp() > 0) {
            array_push(_out, _u);
        }
    }
    return _out;
}

// Combat value of an assigned vehicle, scaled by remaining hull and engagement distance.
function vehicle_combat_value(co, slot, distance = 0.5) {
    var _hp = obj_ini.veh_hp[co][slot];
    if (_hp <= 0) {
        return 0;
    }
    var _role = obj_ini.veh_role[co][slot];
    var _base = 2;
    switch (_role) {
        case "Land Raider": _base = 6; break;
        case "Predator":    _base = 4; break;
        case "Whirlwind":   _base = 3; break;
        case "Land Speeder": _base = 2; break;
        case "Rhino":       _base = 1.5; break;
        default:            _base = 1.5; break;
    }
    // Effectiveness falls off faster than linearly with hull damage (squared), so a battered
    // vehicle contributes much less fire support before it is finally destroyed.
    var _hull = clamp(_hp / 100, 0, 1);
    var _eff = clamp(1 - abs(distance - vehicle_optimal_distance(_role)) * 1.5, 0.05, 1);
    return _base * (_hull * _hull) * _eff;
}

// All [company, slot] vehicles belonging to the marine squads currently in a place.
function place_vehicles(place) {
    var _out = [];
    var _uids = place.marine_squad_uids();
    for (var s = 0; s < array_length(_uids); s++) {
        var _vs = squad_vehicle_slots(_uids[s]);
        for (var v = 0; v < array_length(_vs); v++) {
            array_push(_out, _vs[v]);
        }
    }
    return _out;
}

// A marine side's combat output in a given phase ("ranged"/"melee"): the matching-phase weapon
// value of every marine, plus assigned vehicles whose role fits the phase.
function place_marine_phase_power(place, phase) {
    var _d = place.distance;
    var _power = 0;
    var _uids = place.marine_squad_uids();
    for (var s = 0; s < array_length(_uids); s++) {
        var _mems = marine_squad_living_members(_uids[s]);
        for (var m = 0; m < array_length(_mems); m++) {
            _power += marine_phase_value(_mems[m], _d, phase);
        }
    }
    // Assigned vehicles fight in the phase that matches their effective range.
    var _vehs = place_vehicles(place);
    for (var v = 0; v < array_length(_vehs); v++) {
        var _veh_melee = (vehicle_optimal_distance(obj_ini.veh_role[_vehs[v][0]][_vehs[v][1]]) <= 0.4);
        if ((phase == "melee") == _veh_melee) {
            _power += vehicle_combat_value(_vehs[v][0], _vehs[v][1], _d);
        }
    }
    return _power;
}

// The marine side's attack profile for a phase: total power, plus how much of that power comes from
// weapons with tags that trigger enemy interactions (melta / las / polearm), and whether any sniper
// is present. The sub-powers let apply_damage_to_enemies bypass the right enemies' damage reduction.
function place_marine_attack_profile(place, phase) {
    var _d = place.distance;
    var _p = {total: 0, melta: 0, las: 0, polearm: 0, has_sniper: false, has_bolt: false};
    var _uids = place.marine_squad_uids();
    for (var s = 0; s < array_length(_uids); s++) {
        var _mems = marine_squad_living_members(_uids[s]);
        for (var m = 0; m < array_length(_mems); m++) {
            var _best = marine_phase_best(_mems[m], _d, phase);
            if (_best.value <= 0) {
                continue;
            }
            _p.total += _best.value;
            var _t = weapon_tag_list(_best.weapon);
            if (array_contains(_t, "melta"))   { _p.melta   += _best.value; }
            if (array_contains(_t, "las"))     { _p.las     += _best.value; }
            if (array_contains(_t, "polearm")) { _p.polearm += _best.value; }
            if (array_contains(_t, "sniper"))  { _p.has_sniper = true; }
            if (array_contains(_t, "bolt"))    { _p.has_bolt = true; }
        }
    }
    // Vehicles add generic power (no special weapon-tag interactions modelled for them here).
    var _vehs = place_vehicles(place);
    for (var v = 0; v < array_length(_vehs); v++) {
        var _veh_melee = (vehicle_optimal_distance(obj_ini.veh_role[_vehs[v][0]][_vehs[v][1]]) <= 0.4);
        if ((phase == "melee") == _veh_melee) {
            _p.total += vehicle_combat_value(_vehs[v][0], _vehs[v][1], _d);
        }
    }
    return _p;
}

// An enemy side's combat output in a given phase: the damage_output of enemy squads whose range
// sweetspot fits that phase (melee squads in the melee phase, gunline squads in the ranged phase).
function place_enemy_phase_power(place, phase) {
    var _d = place.distance;
    var _power = 0;
    var _en = place.enemy_squads();
    for (var e = 0; e < array_length(_en); e++) {
        if ((phase == "melee") == _en[e].is_melee()) {
            _power += _en[e].damage_output(_d);
        }
    }
    return _power;
}

// The marine side's Max Kills budget for a phase: the sum of every living marine's per-phase
// max kills (plus phase-fitting vehicles). This caps how many enemy MODELS the marines can remove
// in this phase, so a strong force can't wipe a 10,000-strong horde in a single turn.
function place_marine_phase_kill_cap(place, phase) {
    var _cap = 0;
    var _uids = place.marine_squad_uids();
    for (var s = 0; s < array_length(_uids); s++) {
        var _mems = marine_squad_living_members(_uids[s]);
        for (var m = 0; m < array_length(_mems); m++) {
            _cap += marine_phase_max_kills(_mems[m], phase);
        }
    }
    // Phase-fitting vehicles each contribute their weapon's max kills (none while vehicles aren't
    // squad-linked, since place_vehicles is empty, but kept for when that linkage is added).
    var _vehs = place_vehicles(place);
    for (var v = 0; v < array_length(_vehs); v++) {
        var _role = obj_ini.veh_role[_vehs[v][0]][_vehs[v][1]];
        var _veh_melee = (vehicle_optimal_distance(_role) <= 0.4);
        if ((phase == "melee") == _veh_melee) {
            _cap += 5; // a vehicle's heavy weapons can account for several models a phase
        }
    }
    return _cap;
}

// The enemy side's Max Kills budget for a phase: the sum over phase-fitting enemy squads of
// model_count * max_kills. Caps how many marines the enemy can cut down in this phase.
function place_enemy_phase_kill_cap(place, phase) {
    var _cap = 0;
    var _en = place.enemy_squads();
    for (var e = 0; e < array_length(_en); e++) {
        if ((phase == "melee") == _en[e].is_melee()) {
            _cap += _en[e].model_count() * _en[e].max_kills;
        }
    }
    return _cap;
}

// Combined power across both phases (rough comparison / display helpers).
function place_marine_power(place) {
    return place_marine_phase_power(place, "ranged") + place_marine_phase_power(place, "melee");
}
function place_enemy_power(place) {
    return place_enemy_phase_power(place, "ranged") + place_enemy_phase_power(place, "melee");
}

// --- Damage application -----------------------------------------------------------------

// Comparators for target priority: units contributing the most to range reduction (closing or
// opening the engagement most) are dealt with FIRST, the least-contributing LAST. Sort descending
// by the unit's signed distance_reduction.
function enemy_range_priority_compare(a, b) {
    var _ra = a.distance_reduction();
    var _rb = b.distance_reduction();
    if (_ra < _rb) { return 1; }
    if (_ra > _rb) { return -1; }
    return 0;
}
function marine_range_priority_compare(a, b) {
    var _ra = marine_distance_reduction(a);
    var _rb = marine_distance_reduction(b);
    if (_ra < _rb) { return 1; }
    if (_ra > _rb) { return -1; }
    return 0;
}

// Sniper target priority: ELITE / COMMAND squads are hunted FIRST, and within each group the
// highest range-reduction contributor is taken before the lowest.
function enemy_sniper_priority_compare(a, b) {
    var _ea = (a.has_tag(eENEMY_TAG.ELITE) || a.has_tag(eENEMY_TAG.COMMAND));
    var _eb = (b.has_tag(eENEMY_TAG.ELITE) || b.has_tag(eENEMY_TAG.COMMAND));
    if (_ea != _eb) { return _ea ? -1 : 1; } // elite / commander first
    var _ra = a.distance_reduction();
    var _rb = b.distance_reduction();
    if (_ra < _rb) { return 1; }
    if (_ra > _rb) { return -1; }
    return 0;
}

// Bolt-weapon target priority: INFANTRY squads first (bolters chew through infantry), then by
// range-reduction. (A bolt weapon that is ALSO a sniper uses the sniper priority instead.)
function enemy_infantry_priority_compare(a, b) {
    var _ia = a.has_tag(eENEMY_TAG.INFANTRY);
    var _ib = b.has_tag(eENEMY_TAG.INFANTRY);
    if (_ia != _ib) { return _ia ? -1 : 1; } // infantry first
    var _ra = a.distance_reduction();
    var _rb = b.distance_reduction();
    if (_ra < _rb) { return 1; }
    if (_ra > _rb) { return -1; }
    return 0;
}

// --- Marine target classification (for enemy targeting priorities) -----------------------

// A high-value marine target: a captain, institution master, company standard bearer, or any
// command-tier specialist (apothecary/chaplain/techmarine/librarian/champion/ancient/etc.).
function marine_is_high_value(unit) {
    if (!is_struct(unit)) { return false; }
    var _role = unit.role();
    return is_specialist(_role, SPECIALISTS_COMMAND)
        || is_specialist(_role, SPECIALISTS_HEADS)
        || marine_carries_standard(unit);
}

// A marine's ranged attack value, used by flyers to pick the juiciest gun-line targets. Measured as
// its ranged-phase combat value at a representative long range (distance-independent of the place).
function marine_ranged_value(unit) {
    return marine_phase_value(unit, 0.8, "ranged");
}

// Sniper enemies hunt marine command first (captains/masters/standards/specialists), then by
// range-reduction within each group.
function marine_highvalue_priority_compare(a, b) {
    var _ha = marine_is_high_value(a);
    var _hb = marine_is_high_value(b);
    if (_ha != _hb) { return _ha ? -1 : 1; }
    var _ra = marine_distance_reduction(a);
    var _rb = marine_distance_reduction(b);
    if (_ra < _rb) { return 1; }
    if (_ra > _rb) { return -1; }
    return 0;
}

// Flyer enemies hunt the highest ranged-attack-value marines first (strafing the gun line).
function marine_ranged_priority_compare(a, b) {
    var _va = marine_ranged_value(a);
    var _vb = marine_ranged_value(b);
    if (_va < _vb) { return 1; }
    if (_va > _vb) { return -1; }
    return 0;
}

// Infantry enemies hunt rank-and-file (line) marines first, leaving command for last.
function marine_line_priority_compare(a, b) {
    var _ha = marine_is_high_value(a);
    var _hb = marine_is_high_value(b);
    if (_ha != _hb) { return _ha ? 1 : -1; } // line (non-command) first
    var _ra = marine_distance_reduction(a);
    var _rb = marine_distance_reduction(b);
    if (_ra < _rb) { return 1; }
    if (_ra > _rb) { return -1; }
    return 0;
}

// How the enemy units firing FROM a place pick their marine targets, by tag precedence:
//   sniper -> marine command; flyer -> highest ranged value; vehicle/monstrous -> marine vehicles
//   (handled in apply_damage_to_vehicles); infantry -> line troopers; otherwise -> range-reduction.
function enemy_target_mode(place) {
    var _en = place.enemy_squads();
    var _sniper = false, _flyer = false, _armour = false, _infantry = false;
    for (var e = 0; e < array_length(_en); e++) {
        var _u = _en[e];
        if (_u.has_tag(eENEMY_TAG.SNIPER))    { _sniper = true; }
        if (_u.has_tag(eENEMY_TAG.FLYER))     { _flyer = true; }
        if (_u.has_tag(eENEMY_TAG.VEHICLE) || _u.has_tag(eENEMY_TAG.MONSTROUS)) { _armour = true; }
        if (_u.has_tag(eENEMY_TAG.INFANTRY))  { _infantry = true; }
    }
    if (_sniper)   { return "sniper"; }
    if (_flyer)    { return "flyer"; }
    if (_armour)   { return "vehicle"; }
    if (_infantry) { return "infantry"; }
    return "range";
}

// The net-damage multiplier marine fire of a given weapon-tag mix deals to one enemy squad: starts
// from the squad's damage reduction, but the melta / las / polearm fractions of the fire bypass
// that reduction against the unit types they counter, and polearms deal bonus damage to cavalry.
//   - melta  bypasses the DR of vehicles and armoured units
//   - las    bypasses the DR of flyers and cavalry
//   - polearm bypasses the DR of cavalry (and adds POLEARM_CAV_BONUS damage vs cavalry)
function marine_damage_factor(squad, melta_frac, las_frac, polearm_frac) {
    var _bypass = 0;
    if (squad.has_tag(eENEMY_TAG.VEHICLE) || squad.has_tag(eENEMY_TAG.ARMOURED)) { _bypass += melta_frac; }
    if (squad.has_tag(eENEMY_TAG.FLYER)   || squad.has_tag(eENEMY_TAG.CAVALRY))  { _bypass += las_frac; }
    if (squad.has_tag(eENEMY_TAG.CAVALRY)) { _bypass += polearm_frac; }
    _bypass = clamp(_bypass, 0, 1);
    var _factor = 1 - squad.damage_reduction * (1 - _bypass);
    if (squad.has_tag(eENEMY_TAG.CAVALRY)) {
        _factor += polearm_frac * POLEARM_CAV_BONUS; // polearms savage cavalry
    }
    return _factor;
}

// Fire on the enemy squads in a place, prioritising those with the highest range-reduction
// contribution: damage focus-fires the top-priority squad, spilling any overkill down the list, so
// the lowest-contribution squads are hit last. Each squad mitigates by its own damage_reduction.
// `kill_cap` limits how many enemy MODELS may be removed (Max Kills): if the focused fire would
// kill more than that, it is scaled down so roughly kill_cap models fall. Returns total health
// removed (for experience awards).
function apply_damage_to_enemies(place, damage, kill_cap = infinity, melta_frac = 0, las_frac = 0, polearm_frac = 0, target_mode = "range") {
    var _en = place.enemy_squads(); // fresh array -- safe to reorder for targeting priority
    var _n = array_length(_en);
    if (_n == 0) {
        return 0;
    }
    // Target priority by the firing weapons: snipers hunt elite/commander, bolters hunt infantry,
    // otherwise focus the highest range-reduction contributor.
    var _cmp = enemy_range_priority_compare;
    if (target_mode == "sniper")        { _cmp = enemy_sniper_priority_compare; }
    else if (target_mode == "infantry") { _cmp = enemy_infantry_priority_compare; }
    array_sort(_en, _cmp);

    // Max Kills: simulate the focus-fire and scale damage so at most ~kill_cap models fall.
    if (kill_cap < infinity) {
        var _would_kill = 0;
        var _dsim = damage;
        for (var e = 0; e < _n && _dsim > 0; e++) {
            var _eu = _en[e];
            var _factor = marine_damage_factor(_eu, melta_frac, las_frac, polearm_frac);
            if (_factor <= 0) { continue; }
            var _net = _dsim * _factor;
            var _new_health = max(0, _eu.health - _net);
            var _after = (_new_health <= 0) ? 0 : max(1, round(_eu.models * (_new_health / _eu.max_health)));
            _would_kill += max(0, _eu.model_count() - _after);
            var _hlost = _eu.health - _new_health;
            _dsim -= _hlost / _factor;
        }
        if (_would_kill > kill_cap && _would_kill > 0) {
            damage *= (kill_cap / _would_kill);
        }
    }

    // Focus-fire down the priority list, spilling leftover damage to the next target. Each squad's
    // net loss is scaled by marine_damage_factor (its DR, minus any tag bypass, plus cavalry bonus).
    var _removed = 0;
    var _dleft = damage;
    for (var e = 0; e < _n && _dleft > 0; e++) {
        var _eu = _en[e];
        var _factor = marine_damage_factor(_eu, melta_frac, las_frac, polearm_frac);
        if (_factor <= 0) { continue; }
        var _net = min(_dleft * _factor, _eu.health);
        _removed += _eu.take_net_damage(_net);
        _dleft -= _net / _factor;
    }
    return _removed;
}

// --- Specialist death prevention / healing --------------------------------------------------

// A d100 stat check: succeeds when a roll of 1..100 comes in at or under the unit's stat (0..100).
function marine_stat_check(unit, stat_name) {
    return roll_dice(1, 100) <= unit[$ stat_name];
}

// Unique per-turn key for a specialist, so each can be spent at most once a turn.
function saver_key(unit) {
    return string(unit.company) + "_" + string(unit.marine_number);
}

// All living marines currently deployed in a place.
function place_living_marines(place) {
    var _out = [];
    var _uids = place.marine_squad_uids();
    for (var s = 0; s < array_length(_uids); s++) {
        var _mems = marine_squad_living_members(_uids[s]);
        for (var m = 0; m < array_length(_mems); m++) {
            array_push(_out, _mems[m]);
        }
    }
    return _out;
}

// First living specialist of `group` in `members` not yet spent this turn (per used_savers).
function place_find_unused_saver(battle_state, members, group) {
    for (var i = 0; i < array_length(members); i++) {
        var _u = members[i];
        if (is_specialist(_u.role(), group) && !variable_struct_exists(battle_state.used_savers, saver_key(_u))) {
            return _u;
        }
    }
    return undefined;
}

// A rallied marine (saved by a standard or chaplain) clings on at SAVE_HEAL_FRAC of its max hp and
// immediately makes one extra attack against the enemies sharing its place.
function marine_rally_save(place, dying, phase) {
    var _target_hp = max(1, ceil(dying.max_health() * SAVE_HEAL_FRAC));
    dying.add_or_sub_health(_target_hp - dying.hp());
    if (place.enemy_count() > 0) {
        var _bonus = marine_phase_value(dying, place.distance, phase) * MARINE_DAMAGE_COEF;
        if (_bonus > 0) {
            apply_damage_to_enemies(place, _bonus, infinity);
        }
    }
}

// Attempts to save a marine about to die, trying sources in order: company standard (once per turn
// per place, on the dying marine's faith) -> chaplain (each, on its own faith) -> apothecary (each,
// on its intelligence). Standard/chaplain rally the marine (clings on + extra attack); an apothecary
// puts it out of battle (fully stabilised). Each specialist is spent for the turn once attempted.
// Returns true if the marine was saved.
function attempt_marine_save(battle_state, place, dying, phase) {
    var _members = place_living_marines(place);

    // 1. Company standard -- place-level, succeeds at most once per turn, on the dying marine's faith.
    if (!variable_struct_exists(battle_state.standard_used, string(place.index))) {
        var _has_standard = false;
        for (var i = 0; i < array_length(_members); i++) {
            if (marine_carries_standard(_members[i])) { _has_standard = true; break; }
        }
        if (_has_standard && marine_stat_check(dying, "piety")) {
            battle_state.standard_used[$ string(place.index)] = true;
            marine_rally_save(place, dying, phase);
            return true;
        }
    }

    // 2. Chaplain -- each may attempt once, on its own faith.
    var _chap = place_find_unused_saver(battle_state, _members, SPECIALISTS_CHAPLAINS);
    if (_chap != undefined) {
        battle_state.used_savers[$ saver_key(_chap)] = true;
        if (marine_stat_check(_chap, "piety")) {
            marine_rally_save(place, dying, phase);
            return true;
        }
    }

    // 3. Apothecary -- each may attempt once, on its intelligence; stabilises the dying marine so
    //    it survives the wound (clinging on at low hp), rather than removing it from battle.
    var _apo = place_find_unused_saver(battle_state, _members, SPECIALISTS_APOTHECARIES);
    if (_apo != undefined) {
        battle_state.used_savers[$ saver_key(_apo)] = true;
        if (marine_stat_check(_apo, "intelligence")) {
            var _stab = max(1, ceil(dying.max_health() * SAVE_HEAL_FRAC));
            dying.add_or_sub_health(_stab - dying.hp()); // stabilised -- survives at low hp
            return true;
        }
    }
    return false;
}

// True if a living apothecary is deployed in the place (used for gene-seed recovery on death).
function place_has_apothecary(place) {
    var _members = place_living_marines(place);
    for (var i = 0; i < array_length(_members); i++) {
        if (is_specialist(_members[i].role(), SPECIALISTS_APOTHECARIES)) {
            return true;
        }
    }
    return false;
}

// Attempts a techmarine save of a vehicle about to be destroyed: an unspent techmarine in the place
// rolls technology; on success the vehicle is preserved (repaired / out of battle).
function attempt_vehicle_save(battle_state, place) {
    var _members = place_living_marines(place);
    var _tech = place_find_unused_saver(battle_state, _members, SPECIALISTS_TECHMARINES);
    if (_tech != undefined) {
        battle_state.used_savers[$ saver_key(_tech)] = true;
        if (marine_stat_check(_tech, "technology")) {
            return true;
        }
    }
    return false;
}

// Enemy fire falls on the living marines in a place, prioritising those with the highest range-
// reduction contribution: it focus-fires the top-priority marine (killing it and spilling overkill
// to the next), so the lowest-contribution marines are hit last. No more than `kill_cap` marines
// may die this phase (the enemy's Max Kills); once that is reached the current target clings on at
// 1 hp and the rest are spared this exchange. Before a marine dies, specialist saves are attempted
// (see attempt_marine_save). `battle_state` carries the per-turn save budgets.
function apply_damage_to_marines(place, damage, kill_cap = infinity, target_mode = "range", battle_state = undefined, phase = "ranged") {
    var _members = [];
    var _uids = place.marine_squad_uids();
    for (var s = 0; s < array_length(_uids); s++) {
        var _mems = marine_squad_living_members(_uids[s]);
        for (var m = 0; m < array_length(_mems); m++) {
            array_push(_members, _mems[m]);
        }
    }
    var _n = array_length(_members);
    if (_n == 0) {
        return;
    }
    // Target priority set by the firing enemies (enemy_target_mode): snipers hunt marine command,
    // flyers hunt the gun line, infantry hunt line troopers; otherwise focus by range-reduction.
    // ("vehicle" mode prioritises marine vehicles, handled in apply_damage_to_vehicles.)
    var _cmp = marine_range_priority_compare;
    if (target_mode == "sniper")        { _cmp = marine_highvalue_priority_compare; }
    else if (target_mode == "flyer")    { _cmp = marine_ranged_priority_compare; }
    else if (target_mode == "infantry") { _cmp = marine_line_priority_compare; }
    array_sort(_members, _cmp);

    // Gene-seed is only recovered from the fallen while a living apothecary is present to harvest it.
    var _can_recover_geneseed = place_has_apothecary(place);

    var _deaths = 0;
    var _dleft = damage;
    for (var i = 0; i < _n && _dleft > 0; i++) {
        var _u = _members[i];
        var _hp = _u.hp();
        if (_dleft >= _hp) {
            // Enough fire to drop this marine.
            if (_deaths >= kill_cap) {
                _u.add_or_sub_health(1 - _hp); // Max Kills reached: clings on at 1 hp, fire stops here
                break;
            }
            // A specialist (standard / chaplain / apothecary) may avert the death.
            if (battle_state != undefined && attempt_marine_save(battle_state, place, _u, phase)) {
                _dleft -= _hp; // the lethal hit is spent; the save handled the survivor
                continue;
            }
            _u.add_or_sub_health(-_hp);
            kill_and_recover(_u.company, _u.marine_number, true, _can_recover_geneseed);
            _deaths++;
            _dleft -= _hp; // overkill spills to the next priority marine
        } else {
            _u.add_or_sub_health(-_dleft); // wounds but does not kill
            _dleft = 0;
        }
    }
}

// Spreads a share of incoming damage across the place's vehicles; destroys any at <= 0 hull, unless
// an unspent techmarine saves it (rolls technology). `battle_state` carries the per-turn budgets.
function apply_damage_to_vehicles(place, damage, battle_state = undefined) {
    var _vehs = place_vehicles(place);
    var _n = array_length(_vehs);
    if (_n == 0) {
        return;
    }
    var _share = damage / _n;
    for (var i = 0; i < _n; i++) {
        var _co = _vehs[i][0], _slot = _vehs[i][1];
        obj_ini.veh_hp[_co][_slot] -= _share;
        if (obj_ini.veh_hp[_co][_slot] <= 0) {
            if (battle_state != undefined && attempt_vehicle_save(battle_state, place)) {
                obj_ini.veh_hp[_co][_slot] = 100; // repaired to full hull -- out of battle
            } else {
                destroy_vehicle(_co, _slot);
            }
        }
    }
}

function award_place_experience(place, killed_strength) {
    if (killed_strength <= 0) {
        return;
    }
    var _xp = ceil(killed_strength * 0.2);
    var _uids = place.marine_squad_uids();
    for (var s = 0; s < array_length(_uids); s++) {
        var _mems = marine_squad_living_members(_uids[s]);
        for (var m = 0; m < array_length(_mems); m++) {
            _mems[m].add_exp(_xp);
        }
    }
}

// Removes marine squads that have no living members left from a place's slots.
function free_empty_marine_slots(place) {
    var _uids = place.marine_squad_uids();
    for (var s = 0; s < array_length(_uids); s++) {
        if (array_length(marine_squad_living_members(_uids[s])) == 0) {
            place.remove_marine_squad(_uids[s]);
        }
    }
}

// Indices of the places physically adjacent to place `idx`. Places form a line (0-1-2...), so each
// has one or two neighbours.
function adjacent_place_indices(battle_state, idx) {
    var _out = [];
    var _n = array_length(battle_state.places);
    if (idx - 1 >= 0)  { array_push(_out, idx - 1); }
    if (idx + 1 < _n)  { array_push(_out, idx + 1); }
    return _out;
}

// The place that units in place `idx` attack this phase. They strike their OWN place if it holds
// opposing targets; otherwise they reach into the adjacent place -- and when two are adjacent, the
// one with FEWER targets (concentrating force to mop up the weaker flank). `want` is "enemies"
// (marines choosing a target) or "marines" (enemies choosing a target). Returns undefined when
// there is nothing in reach to attack.
function combat_target_place(battle_state, idx, want) {
    var _here = battle_state.places[idx];
    var _local = (want == "enemies") ? _here.enemy_count() : _here.marine_count();
    if (_local > 0) {
        return _here;
    }
    var _adj = adjacent_place_indices(battle_state, idx);
    var _best = undefined;
    var _best_count = infinity;
    for (var a = 0; a < array_length(_adj); a++) {
        var _q = battle_state.places[_adj[a]];
        var _c = (want == "enemies") ? _q.enemy_count() : _q.marine_count();
        if (_c > 0 && _c < _best_count) {
            _best_count = _c;
            _best = _q;
        }
    }
    return _best;
}

// Resolves one combat PHASE ("ranged" or "melee") across the WHOLE battle. Every place's marines
// fire on enemies and every place's enemies fall on marines -- striking their own place when it
// holds opposing targets, otherwise reaching into the adjacent place with fewer targets. Power and
// Max-Kills are computed from the attacker's place; damage lands on the target place. Enemies are
// mitigated by their damage_reduction (inside take_damage); marines/vehicles take their share.
function resolve_battle_phase(battle_state, phase) {
    var _places = battle_state.places;
    var _n = array_length(_places);
    for (var i = 0; i < _n; i++) {
        var P = _places[i];
        // Marines in P fire on enemies (here, or the lighter adjacent place). The attack profile
        // carries the weapon-tag mix so melta/las/polearm fire bypasses the right enemies' damage
        // reduction, and snipers redirect the focus onto elite/commander squads.
        var _etarget = combat_target_place(battle_state, i, "enemies");
        if (_etarget != undefined) {
            var _profile = place_marine_attack_profile(P, phase);
            if (_profile.total > 0) {
                var _enemy_damage = _profile.total * MARINE_DAMAGE_COEF * random_range(0.8, 1.2);
                var _marine_kill_cap = place_marine_phase_kill_cap(P, phase);
                var _mf = _profile.melta / _profile.total;
                var _lf = _profile.las / _profile.total;
                var _pf = _profile.polearm / _profile.total;
                // Snipers pick command/elite; otherwise bolters hunt infantry; otherwise range.
                var _mode = _profile.has_sniper ? "sniper" : (_profile.has_bolt ? "infantry" : "range");
                var _removed = apply_damage_to_enemies(_etarget, _enemy_damage, _marine_kill_cap, _mf, _lf, _pf, _mode);
                award_place_experience(P, _removed);
            }
        }
        // Enemies in P fall on marines (here, or the lighter adjacent place). The enemy units' tags
        // set who they hunt (snipers -> command, flyers -> gun line, infantry -> line troopers,
        // vehicles/monstrous -> marine vehicles).
        var _mtarget = combat_target_place(battle_state, i, "marines");
        if (_mtarget != undefined) {
            var _e_power = place_enemy_phase_power(P, phase);
            if (_e_power > 0) {
                var _marine_damage = _e_power * ENEMY_DAMAGE_COEF * random_range(0.8, 1.2);
                var _enemy_kill_cap = place_enemy_phase_kill_cap(P, phase);
                var _emode = enemy_target_mode(P);
                apply_damage_to_marines(_mtarget, _marine_damage, _enemy_kill_cap, _emode, battle_state, phase);
                // Vehicle/monstrous enemies concentrate on armour: marine vehicles draw the full hit.
                apply_damage_to_vehicles(_mtarget, _marine_damage * (_emode == "vehicle" ? 1.0 : 0.85), battle_state);
            }
        }
    }
    // Clear casualties everywhere once the exchange is done.
    for (var i = 0; i < _n; i++) {
        _places[i].cull_dead_enemies();
        free_empty_marine_slots(_places[i]);
    }
}

// Rebuilds any legacy enemy squad (created before the HP-stat rewrite -- it lacks `health` and the
// new combat methods) into a current EnemySquad, in place. Lets pre-rewrite battles still in
// memory resolve without crashing. Safe to call every turn (proper squads are left untouched).
function repair_battle_enemy_squads(battle_state) {
    for (var p = 0; p < array_length(battle_state.places); p++) {
        var _place = battle_state.places[p];
        for (var i = 0; i < array_length(_place.enemy_slots); i++) {
            var _e = _place.enemy_slots[i];
            if (!is_struct(_e)) {
                continue;
            }
            if (variable_struct_exists(_e, "health") && variable_struct_exists(_e, "max_health")
                && variable_struct_exists(_e, "damage") && variable_struct_exists(_e, "healing")) {
                continue; // already a current squad
            }
            var _max_hp = variable_struct_exists(_e, "max_health") ? _e.max_health
                        : (variable_struct_exists(_e, "max_strength") ? _e.max_strength
                        : (variable_struct_exists(_e, "strength") ? _e.strength : 18));
            var _hp = variable_struct_exists(_e, "health") ? _e.health
                    : (variable_struct_exists(_e, "strength") ? _e.strength : _max_hp);
            var _td = {
                name: variable_struct_exists(_e, "unit_name") ? _e.unit_name : "Hostiles",
                tier: variable_struct_exists(_e, "tier") ? _e.tier : 1,
                max_health: _max_hp,
                damage: variable_struct_exists(_e, "damage") ? _e.damage : round(_max_hp * 0.45),
                damage_reduction: variable_struct_exists(_e, "damage_reduction") ? _e.damage_reduction : 0,
                healing: variable_struct_exists(_e, "healing") ? _e.healing : 0,
                optimal: variable_struct_exists(_e, "optimal") ? _e.optimal : 0.5,
                models: variable_struct_exists(_e, "models") ? _e.models : 15,
                dist: variable_struct_exists(_e, "dist") ? _e.dist : 0
            };
            if (variable_struct_exists(_e, "falloff")) {
                _td.falloff = _e.falloff; // preserve any existing falloff (else EnemySquad picks a band default)
            }
            if (variable_struct_exists(_e, "max_kills")) {
                _td.max_kills = _e.max_kills; // preserve any existing Max Kills (else EnemySquad defaults to 1)
            }
            if (variable_struct_exists(_e, "tags")) {
                _td.tags = _e.tags; // preserve the unit's tag list if it was already set
            }
            var _faction = variable_struct_exists(_e, "faction") ? _e.faction : battle_state.enemy_faction;
            // apply_buffs = false: _max_hp is taken from the existing squad as-is, not re-scaled.
            var _new = new EnemySquad(_faction, _td, false);
            _new.health = clamp(_hp, 0, _new.max_health);
            _place.enemy_slots[i] = _new;
        }
    }
}

// Gathers a one-line summary of every active ground battle in a star system, for the system-select
// overview. Returns an array of structs (one per planet with a live battle):
//   { planet, planet_name, marines (living marine models), enemies (enemy models still standing),
//     objective_turns (cumulative turns the objective has been held), objective_win }
function system_battle_summaries(system) {
    var _out = [];
    if (!instance_exists(system)) {
        return _out;
    }
    for (var p = 1; p <= system.planets; p++) {
        var _bs = system.p_battle[p];
        if (!is_struct(_bs)) {
            continue;
        }
        repair_battle_enemy_squads(_bs); // ensure legacy enemy squads have model_count() etc.
        var _marines = 0, _enemies = 0;
        for (var i = 0; i < array_length(_bs.places); i++) {
            var _place = _bs.places[i];
            var _muids = _place.marine_squad_uids();
            for (var m = 0; m < array_length(_muids); m++) {
                _marines += array_length(marine_squad_living_members(_muids[m]));
            }
            var _en = _place.enemy_squads();
            for (var e = 0; e < array_length(_en); e++) {
                _enemies += _en[e].model_count();
            }
        }
        var _turns = variable_struct_exists(_bs, "objective_control_turns") ? _bs.objective_control_turns : 0;
        array_push(_out, {
            planet: p,
            planet_name: planet_numeral_name(p, system),
            marines: _marines,
            enemies: _enemies,
            objective_turns: _turns,
            objective_win: OBJECTIVE_WIN_TURNS
        });
    }
    return _out;
}

// Healing / repair phase: each enemy squad with a healing value restores its own health first;
// any amount that would exceed its max spills over to the most-wounded other enemy squad(s) in
// the same place (and so on) until the heal is spent or every squad is at full health.
function resolve_place_healing(place) {
    // Apothecaries patch up wounded marines (and themselves) in their place each turn.
    var _marines = place_living_marines(place);
    var _apo_count = 0;
    for (var m = 0; m < array_length(_marines); m++) {
        if (is_specialist(_marines[m].role(), SPECIALISTS_APOTHECARIES)) { _apo_count++; }
    }
    if (_apo_count > 0) {
        var _heal_pool = _apo_count * APOTHECARY_HEAL_AMOUNT;
        var _hguard = 0;
        while (_heal_pool > 0 && _hguard < 500) {
            _hguard++;
            var _wt = undefined, _wmiss = 0;
            for (var m = 0; m < array_length(_marines); m++) {
                var _miss = _marines[m].max_health() - _marines[m].hp();
                if (_miss > _wmiss) { _wmiss = _miss; _wt = _marines[m]; }
            }
            if (_wt == undefined) { break; } // every marine at full health
            var _apply = min(_heal_pool, _wmiss);
            _wt.add_or_sub_health(_apply);
            _heal_pool -= _apply;
        }
    }

    var _en = place.enemy_squads();
    var _n = array_length(_en);
    if (_n == 0) {
        return;
    }
    for (var i = 0; i < _n; i++) {
        if (!variable_struct_exists(_en[i], "healing") || _en[i].healing <= 0) {
            continue;
        }
        var _overflow = _en[i].heal(_en[i].healing); // self first
        var _guard = 0;
        while (_overflow > 0 && _guard < 100) {
            _guard++;
            // Find the most-wounded squad that still has room.
            var _target = undefined;
            var _best_missing = 0;
            for (var t = 0; t < _n; t++) {
                var _missing = _en[t].max_health - _en[t].health;
                if (_missing > _best_missing) {
                    _best_missing = _missing;
                    _target = _en[t];
                }
            }
            if (_target == undefined) {
                break; // everyone at full health
            }
            _overflow = _target.heal(_overflow);
        }
    }
}

// --- Maneuver ---------------------------------------------------------------------------

// Best place (other than exclude_place) for a unit of the given kind to relocate to: prefers
// the most concentrated friendly place that still has room AND holds the opposing force, so
// units move toward the fighting. Falls back to any place with room. undefined if none.
function relocation_target(battle_state, kind, exclude_place) {
    var _places = battle_state.places;
    var _best = undefined, _best_free = BATTLE_SLOTS_PER_PLACE + 1;
    var _fallback = undefined, _fallback_free = BATTLE_SLOTS_PER_PLACE + 1;
    for (var i = 0; i < array_length(_places); i++) {
        var P = _places[i];
        if (P == exclude_place) {
            continue;
        }
        var _free = (kind == "enemy") ? P.free_enemy_slots() : P.free_marine_slots();
        if (_free <= 0) {
            continue;
        }
        var _has_opposing = (kind == "enemy") ? (P.marine_count() > 0) : (P.enemy_count() > 0);
        if (_has_opposing && _free < _best_free) {
            _best_free = _free;
            _best = P;
        }
        if (_free < _fallback_free) {
            _fallback_free = _free;
            _fallback = P;
        }
    }
    return (_best != undefined) ? _best : _fallback;
}

// The enemy place most lacking marines (enemy_count - marine_count, largest positive) that
// still has room, other than exclude_place. undefined once every enemy place is >= 1:1.
function most_understaffed_place(battle_state, exclude_place) {
    var _places = battle_state.places;
    var _best = undefined, _best_deficit = 0;
    for (var i = 0; i < array_length(_places); i++) {
        var P = _places[i];
        if (P == exclude_place || P.enemy_count() == 0 || P.free_marine_slots() <= 0) {
            continue;
        }
        var _deficit = P.enemy_count() - P.marine_count();
        if (_deficit > _best_deficit) {
            _best_deficit = _deficit;
            _best = P;
        }
    }
    return _best;
}

// Marines in cleared places (no enemies) auto-regroup toward places that still have enemies,
// reinforcing the most under-defended first. Each relocation costs a command point.
function maneuver_battle(battle_state) {
    var _places = battle_state.places;
    var _free_squads = [];
    for (var i = 0; i < array_length(_places); i++) {
        var P = _places[i];
        if (P.marine_count() > 0 && P.enemy_count() == 0) {
            var _uids = P.marine_squad_uids();
            for (var s = 0; s < array_length(_uids); s++) {
                array_push(_free_squads, {uid: _uids[s], from: P});
            }
        }
    }
    for (var f = 0; f < array_length(_free_squads); f++) {
        var _sqd = _free_squads[f];
        var T = most_understaffed_place(battle_state, _sqd.from);
        if (T == undefined) {
            break; // every enemy place is already at >= 1:1; keep the rest in reserve
        }
        if (!spend_command_point(battle_state.system, battle_state.planet, 1)) {
            break; // out of command points
        }
        _sqd.from.remove_marine_squad(_sqd.uid);
        T.add_marine_squad(_sqd.uid);
    }
}

// The enemy's reinforcement phase. Fresh squads enter at the reinforcement place (drawn from the
// planet's force reserve, up to the field strength it implies), one per enemy command point.
// Enemies do NOT relocate between places: a place with no marines to fight simply attacks into the
// adjacent place during engagement (see resolve_battle_phase), so each place keeps its garrison.
function resolve_enemy_turn(battle_state, planet_data) {
    var _cp = ENEMY_CP_PER_TURN;
    var _faction = battle_state.enemy_faction;
    var _force = planet_data.planet_forces[_faction];
    var _field_cap = min(_force * ENEMY_SQUADS_PER_FORCE, battle_state.max_enemy_slots);

    while (_cp > 0 && battle_state.total_enemies() < _field_cap) {
        if (!battle_state.add_enemy_reinforcement(new EnemySquad(_faction, pick_enemy_unit_type(_faction, _force)))) {
            break; // reinforcement place unavailable
        }
        _cp--;
    }
}

// --- Garrison cap -----------------------------------------------------------------------

function battle_remove_one_enemy(battle_state) {
    for (var i = 0; i < array_length(battle_state.places); i++) {
        var _en = battle_state.places[i].enemy_squads();
        if (array_length(_en) > 0) {
            battle_state.places[i].remove_enemy_squad(_en[0]);
            return true;
        }
    }
    return false;
}

// A planet's Imperial Guard garrison lowers the number of enemy slots the attackers may hold.
function apply_garrison_cap(pdata, battle_state) {
    var _reduction = floor(pdata.guardsmen / GARRISON_PER_ENEMY_SLOT);
    var _full = BATTLE_PLACES_MAX * BATTLE_SLOTS_PER_PLACE;
    battle_state.max_enemy_slots = clamp(_full - _reduction, BATTLE_PLACES_MAX, _full);
    while (battle_state.total_enemies() > battle_state.max_enemy_slots) {
        if (!battle_remove_one_enemy(battle_state)) {
            break;
        }
    }
}

// --- Marine deployment ------------------------------------------------------------------

function battle_contains_marine(battle_state, squad_uid) {
    for (var i = 0; i < array_length(battle_state.places); i++) {
        if (array_contains(battle_state.places[i].marine_squad_uids(), squad_uid)) {
            return true;
        }
    }
    return false;
}

// True if the squad is committed to ANY active planet battle, so it can't be deployed to a
// second planet in the same turn.
function squad_in_any_battle(squad_uid) {
    var _found = false;
    with (obj_star) {
        for (var p = 1; p <= planets; p++) {
            if (is_struct(p_battle[p]) && battle_contains_marine(p_battle[p], squad_uid)) {
                _found = true;
            }
        }
    }
    return _found;
}

// True if the squad shares a place with enemies (directly in combat). Such squads can't board
// ships normally; they must use the battle screen's per-squad escape (costs a command point).
function squad_is_engaged(squad_uid) {
    var _engaged = false;
    with (obj_star) {
        for (var p = 1; p <= planets; p++) {
            if (!is_struct(p_battle[p])) {
                continue;
            }
            var _bs = p_battle[p];
            for (var pl = 0; pl < array_length(_bs.places); pl++) {
                var _place = _bs.places[pl];
                if (_place.enemy_count() > 0 && array_contains(_place.marine_squad_uids(), squad_uid)) {
                    _engaged = true;
                }
            }
        }
    }
    return _engaged;
}

// Place where a marine squad should deploy by default: the place with the most free marine
// slots (spreads the defenders out across the contested ground).
function most_open_marine_place(battle_state) {
    var _best = battle_state.places[0];
    for (var i = 1; i < array_length(battle_state.places); i++) {
        if (battle_state.places[i].free_marine_slots() > _best.free_marine_slots()) {
            _best = battle_state.places[i];
        }
    }
    return _best;
}

// Adds any not-yet-deployed marine squads (by uid) into the battle, spread across places.
function deploy_marine_squads_into_battle(pdata, marine_uids) {
    var _bs = pdata.battle_state();
    for (var s = 0; s < array_length(marine_uids); s++) {
        if (battle_contains_marine(_bs, marine_uids[s])) {
            continue;
        }
        var _target = most_open_marine_place(_bs);
        _target.add_marine_squad(marine_uids[s]);
    }
}

// Marine squads garrisoned on a planet (via p_operatives) that still have living members.
function planet_marine_squad_uids(system, planet) {
    var _out = [];
    var _ops = system.p_operatives[planet];
    for (var i = 0; i < array_length(_ops); i++) {
        var _op = _ops[i];
        if (is_struct(_op) && variable_struct_exists(_op, "type") && _op.type == "squad") {
            if (array_length(marine_squad_living_members(_op.reference)) > 0) {
                array_push(_out, _op.reference);
            }
        }
    }
    return _out;
}

// --- Command points --------------------------------------------------------------------
// Each planet has a per-turn pool spent on assigning a squad to a place or moving a squad
// between places (including the automatic garrison interception move).

function planet_command_points(system, planet) {
    return system.p_command_points[planet];
}

function spend_command_point(system, planet, amount = 1) {
    if (system.p_command_points[planet] >= amount) {
        system.p_command_points[planet] -= amount;
        return true;
    }
    return false;
}

// Grants command points mid-turn (no cap).
function grant_command_point(system, planet, amount = 1) {
    system.p_command_points[planet] += amount;
}

// True if any squad currently deployed on the planet contains a command element (Captain/master).
function planet_has_command_deployed(system, planet) {
    var _uids = planet_marine_squad_uids(system, planet);
    for (var s = 0; s < array_length(_uids); s++) {
        if (squad_has_command_element(_uids[s])) {
            return true;
        }
    }
    return false;
}

// True if a squad contains a command element: a Captain or any chapter "master" (Chapter Master,
// Master of Sanctity / Apothecarion, Forge Master, Chief Librarian).
function squad_has_command_element(squad_uid) {
    var _mems = marine_squad_living_members(squad_uid);
    var _capt = obj_ini.role[100][eROLE.CAPTAIN];
    for (var i = 0; i < array_length(_mems); i++) {
        var _r = _mems[i].role();
        if (_r == _capt || is_specialist(_r, SPECIALISTS_HEADS)) {
            return true;
        }
    }
    return false;
}

// Turn maximum command points for a planet: 3 base, +1 if a Captain or master is deployed
// anywhere on the planet, +1 more if such a command element is in the Base-of-Operations place.
function planet_command_max(system, planet) {
    var _max = 3;
    var _uids = planet_marine_squad_uids(system, planet);
    if (array_length(_uids) == 0) {
        return _max;
    }

    // Squads currently in the Base-of-Operations place (for the extra +1).
    var _boo_uids = [];
    if (is_struct(system.p_battle[planet])) {
        var _boo = system.p_battle[planet].base_place();
        if (_boo != undefined) {
            _boo_uids = _boo.marine_squad_uids();
        }
    }

    var _has_command = false;
    var _command_on_boo = false;
    for (var s = 0; s < array_length(_uids); s++) {
        if (squad_has_command_element(_uids[s])) {
            _has_command = true;
            if (array_contains(_boo_uids, _uids[s])) {
                _command_on_boo = true;
            }
        }
    }
    if (_has_command) {
        _max += 1;
    }
    if (_command_on_boo) {
        _max += 1;
    }
    return _max;
}

// Recomputes each planet's command-point maximum and refills the pool (called at end of turn,
// so each planet starts the next turn at its maximum).
function refresh_all_command_points() {
    with (obj_star) {
        for (var p = 1; p <= planets; p++) {
            var _max = planet_command_max(self, p);
            p_command_max[p] = _max;
            p_command_points[p] = _max;
        }
    }
}

// --- Per-planet / global resolution -----------------------------------------------------

// True if a marine carries a company standard / banner (in either weapon slot or as gear).
function marine_carries_standard(unit) {
    if (!is_struct(unit)) {
        return false;
    }
    var _items = [unit.weapon_one(), unit.weapon_two(), unit.gear()];
    for (var i = 0; i < array_length(_items); i++) {
        var _n = string_lower(weapon_name_string(_items[i]));
        if (string_pos("standard", _n) || string_pos("banner", _n)) {
            return true;
        }
    }
    return false;
}

// True if the objective place currently holds a living Chapter Master or a company-standard
// bearer -- the condition that accrues objective-control turns toward an outright planet win.
function objective_held_by_command(battle_state) {
    var _obj = battle_state.objective_place();
    if (_obj == undefined) {
        return false;
    }
    var _cm_role = obj_ini.role[100][eROLE.CHAPTERMASTER];
    var _uids = _obj.marine_squad_uids();
    for (var s = 0; s < array_length(_uids); s++) {
        var _mems = marine_squad_living_members(_uids[s]);
        for (var m = 0; m < array_length(_mems); m++) {
            if (_mems[m].role() == _cm_role || marine_carries_standard(_mems[m])) {
                return true;
            }
        }
    }
    return false;
}

// Shifts the objective to the next place (by array order), swapping roles so the old objective
// takes over the target's former role (reinforcement / base). Keeps exactly one of each role.
function apply_objective_shift(battle_state) {
    var _places = battle_state.places;
    var _n = array_length(_places);
    if (_n < 2) {
        return;
    }
    var _obj = battle_state.objective_place();
    if (_obj == undefined) {
        return;
    }
    var _pos = -1;
    for (var i = 0; i < _n; i++) {
        if (_places[i] == _obj) {
            _pos = i;
        }
    }
    if (_pos < 0) {
        return;
    }
    var _tpos = (_pos + 1) mod _n;
    var _target = _places[_tpos];
    var _tmp = _obj.role;          // PLACE_OBJECTIVE
    _obj.role = _target.role;      // old objective takes the target's former role
    _target.role = _tmp;           // target becomes the new objective
    battle_state.objective_index = _tpos;
}

// End-of-turn resolution. Sequence (the player's interactive deploy/move happened during their
// turn; this runs when they end it):
//   Movement & reinforcement -> Engagement (ranged, melee, healing, range shift) ->
//   Control, win-checks & objective update.
// (Marine CP for the next turn is granted afterwards by refresh_all_command_points.)
function resolve_planet_battle(system, planet) {
    var _pdata = new PlanetData(planet, system);
    if (!_pdata.has_battle()) {
        return;
    }
    var _bs = _pdata.battle_state();
    repair_battle_enemy_squads(_bs); // migrate any pre-rewrite enemy squads still in memory

    // Reset this turn's specialist save budgets (each apothecary/techmarine/chaplain may attempt one
    // save, and each place's standard may avert one death).
    _bs.used_savers = {};
    _bs.standard_used = {};

    var _m_before = _bs.total_marines();
    var _e_before = _bs.total_enemies();

    // --- Reinforcement: enemy brings fresh squads in at the reinforcement place (up to the force
    //     scalar). Units no longer relocate -- they engage across place boundaries instead. ---
    resolve_enemy_turn(_bs, _pdata);

    // --- Engagement resolution: ranged, then melee, then healing, then range shift. Each phase
    //     resolves the whole battle so units with no local foe strike into the adjacent place. ---
    resolve_battle_phase(_bs, "ranged");
    resolve_battle_phase(_bs, "melee");
    for (var i = 0; i < array_length(_bs.places); i++) {
        resolve_place_healing(_bs.places[i]);
    }
    for (var i = 0; i < array_length(_bs.places); i++) {
        var _pl = _bs.places[i];
        if (_pl.marine_count() == 0 || _pl.enemy_count() == 0) {
            continue;
        }
        var _reduction = place_marine_distance_reduction(_pl) + place_enemy_distance_reduction(_pl);
        _reduction += stance_distance_bonus(_pl.stance);
        _pl.distance = clamp(_pl.distance - _reduction, _pl.min_distance, _pl.max_distance);
    }

    var _m_after = _bs.total_marines();
    var _e_after = _bs.total_enemies();

    // --- Control & win checks ---
    // Objective control accrues whenever a CM or standard-bearer holds the objective place.
    if (objective_held_by_command(_bs)) {
        _bs.objective_control_turns += 1;
    }
    var _objective_won = (_bs.objective_control_turns >= OBJECTIVE_WIN_TURNS);

    _pdata.sync_counts_from_places(); // writes survivors to the scalar; clears battle if no enemies

    if (_objective_won && _pdata.has_battle()) {
        scr_event_log("green", $"The objective on {_pdata.name()} has been held for {OBJECTIVE_WIN_TURNS} turns -- the planet is secured!", system.name);
        _pdata.edit_forces(_bs.enemy_faction, 0); // remaining attackers are routed
        _pdata.clear_battle();
    }
    if (_pdata.has_battle() && _bs.total_marines() == 0) {
        _pdata.clear_battle(); // marines wiped out; the planet stays invaded via the scalar count
    }

    // Status log.
    if (_e_before > 0 && _m_before > 0) {
        var _msg = $"Battle on {_pdata.name()}: marine squads {_m_before} -> {_m_after}, enemy squads {_e_before} -> {_e_after}.";
        if (!_pdata.has_battle() && _e_after <= 0) {
            scr_event_log("green", _msg + " The planet is cleared!", system.name);
        } else if (_m_after <= 0) {
            scr_event_log("red", _msg + " Our forces were wiped out.", system.name);
        } else {
            scr_event_log("", _msg, system.name);
        }
    }

    // Victory clean-up: a cleared planet with no lingering heresy/Tyranid influence sends its now
    // idle garrison back to any available ship instead of loitering planet-side.
    if (_e_before > 0 && !_pdata.has_battle() && _m_after > 0) {
        var _no_heresy = (system.p_heresy[planet] <= 0) && (!system.p_hurssy[planet]);
        var _no_tyranid = (system.p_influence[planet][eFACTION.TYRANIDS] <= 0);
        if (_no_heresy && _no_tyranid) {
            var _recalled = recall_planet_garrison(system, planet);
            if (_recalled > 0) {
                scr_event_log("green", $"With {_pdata.name()} secured, {_recalled} battle-brother(s) re-embark to the fleet.", system.name);
            }
        }
    }

    // --- Objective shift: the objective relocates every OBJECTIVE_SHIFT_TURNS turns. The
    //     following turn is flagged with shift_warning for the UI. ---
    if (_pdata.has_battle()) {
        _bs.shift_timer -= 1;
        if (_bs.shift_timer <= 0) {
            apply_objective_shift(_bs);
            _bs.shift_timer = OBJECTIVE_SHIFT_TURNS;
            scr_event_log("", $"The objective on {_pdata.name()} has shifted to new ground.", system.name);
        }
        _bs.shift_warning = (_bs.shift_timer == 1);
    }
}

// Resolves every contested planet, and auto-starts a slot battle on any planet where a player
// garrison and an enemy force coexist. AI-vs-AI worlds are left to the existing scalar systems.
function resolve_all_ground_battles() {
    with (obj_star) {
        for (var p = 1; p <= planets; p++) {
            var _pdata = new PlanetData(p, self);
            if (_pdata.has_battle()) {
                resolve_planet_battle(self, p);
                continue;
            }
            var _enemy = _pdata.dominant_enemy_faction();
            if (_enemy == 0) {
                continue;
            }
            var _marine_uids = planet_marine_squad_uids(self, p);
            if (array_length(_marine_uids) == 0) {
                continue; // no player forces -> leave to existing AI resolution
            }
            _pdata.start_battle(_enemy);
            _pdata.materialize_enemies_from_counts(_enemy);
            deploy_marine_squads_into_battle(_pdata, _marine_uids);
            resolve_planet_battle(self, p);
        }
    }
}

// Marines stationed on a planet steadily root out genestealer cult / Tyranid influence; more
// deployed squads suppress it faster. Collapses the cult once influence is driven down.
function marines_suppress_cult_influence() {
    with (obj_star) {
        for (var p = 1; p <= planets; p++) {
            if (p_influence[p][eFACTION.TYRANIDS] <= 0) {
                continue;
            }
            var _squads = array_length(planet_marine_squad_uids(self, p));
            if (_squads <= 0) {
                continue;
            }
            var _reduction = 8 + _squads * 5; // base + per deployed squad
            adjust_influence(eFACTION.TYRANIDS, -min(_reduction, p_influence[p][eFACTION.TYRANIDS]), p);
            if (p_influence[p][eFACTION.TYRANIDS] <= 0 && planet_feature_bool(p_feature[p], eP_FEATURES.GENE_STEALER_CULT)) {
                delete_features(p_feature[p], eP_FEATURES.GENE_STEALER_CULT);
            }
        }
    }
}
