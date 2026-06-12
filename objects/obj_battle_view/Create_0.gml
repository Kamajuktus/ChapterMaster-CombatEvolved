// Opened from the single "Battle" planet button. Shows the slot-based ground battle for a
// planet (its 4 places, each with marine + enemy slots) and lets the player deploy local
// squads into a chosen place. Combat itself resolves at end of turn (scr_battle_place).
//
// `target` (obj_star) and `planet` (index) are supplied via the creation var struct.

global.slot_battle_mode = true; // battles started this way resolve through the new system

instance_deactivate_object(obj_star_select);
prev_menu = obj_controller.menu;
obj_controller.menu = 999; // block map/menu input while the battle view is open
obj_controller.cooldown = 10;

pdata = new PlanetData(planet, target);

var _faction = pdata.dominant_enemy_faction();
if (_faction == 0 && pdata.has_battle()) {
    _faction = pdata.battle_state().enemy_faction;
}
pdata.start_battle(_faction);
if (_faction != 0) {
    pdata.materialize_enemies_from_counts(_faction);
}
bs = pdata.battle_state();
repair_battle_enemy_squads(bs); // migrate any pre-rewrite enemy squads so the view can't fault

// Station the planet's existing garrison squads into the places (free; they're already
// stationed here) so they defend and are visible when the battle view is opened.
deploy_marine_squads_into_battle(pdata, planet_marine_squad_uids(target, planet));

selected_company = -1;   // -1 = showing the company list; otherwise the chosen company
selected_squad = "none"; // squad chosen for deployment / movement
selected_from_place = -1; // -1 = selection is an undeployed squad; else the place it sits in
available = [];           // squad uids deployable from this system
companies_available = []; // companies that have at least one deployable squad

preview_squad = "none";   // squad whose lineup is being previewed on hover
preview_images = [];      // cached UnitImage structs for the previewed squad's members

// Which bottom window the left-side buttons have open. 0 = collapsed (no window). Each left
// button toggles its panel; only the "deploy" panel (the squad picker) is implemented so far,
// the rest are scaffolding placeholders.
//   1 = Deploy (squad picker), 2 = Orders, 3 = Intel, 4 = Log
bottom_panel = 1;
// Left-side button definitions: {id, label}. Add new bottom windows by adding an entry here and
// a matching draw branch in Draw_64's bottom-panel section.
bottom_panels = [
    {id: 1, label: "Deploy"},
    {id: 2, label: "Orders"},
    {id: 3, label: "Intel"},
    {id: 4, label: "Log"},
];

// Frees the cached preview sprites (they are created from surfaces and must be released).
clear_preview = function() {
    for (var i = 0; i < array_length(preview_images); i++) {
        if (is_struct(preview_images[i])) {
            preview_images[i].destroy_image();
        }
    }
    preview_images = [];
    preview_squad = "none";
};

// Builds the member lineup images for a squad (called once when the hovered squad changes).
build_preview = function(squad_uid) {
    clear_preview();
    preview_squad = squad_uid;
    var _mems = marine_squad_living_members(squad_uid);
    for (var i = 0; i < array_length(_mems); i++) {
        array_push(preview_images, _mems[i].draw_unit_image());
    }
};

// The squad-picker group a squad belongs to: HQ (0) and the four institutions (11-14) are all
// presented together under "HQ"; line companies (1-10) keep their own group.
picker_group = function(_base_company) {
    return (_base_company == 0 || _base_company > LINE_COMPANY_MAX) ? 0 : _base_company;
};

// Total range-pull of a squad = sum of its living members' per-turn distance reduction.
// Positive = the squad drives the engagement toward melee; negative = it holds at range.
squad_range_reduction = function(squad_uid) {
    var _mems = marine_squad_living_members(squad_uid);
    var _r = 0;
    for (var i = 0; i < array_length(_mems); i++) {
        _r += marine_distance_reduction(_mems[i]);
    }
    return _r;
};

// Colour a squad by its range role: red = drives to melee (>+0.01), green = neutral
// (-0.01..+0.01), blue = holds at range (<-0.01).
squad_range_colour = function(squad_uid) {
    var _r = squad_range_reduction(squad_uid);
    if (_r > 0.01) {
        return c_red;
    }
    if (_r < -0.01) {
        return make_colour_rgb(90, 150, 255); // blue
    }
    return c_lime; // green / neutral
};

// True if a squad contains a command element (Captain or any institution master) that grants
// the planet its +2 command-point bonus.
squad_gives_command_bonus = function(squad_uid) {
    var _mems = marine_squad_living_members(squad_uid);
    var _capt = obj_ini.role[100][eROLE.CAPTAIN];
    for (var i = 0; i < array_length(_mems); i++) {
        var _role = _mems[i].role();
        if (_role == _capt || is_specialist(_role, SPECIALISTS_HEADS)) {
            return true;
        }
    }
    return false;
};

// A squad's display name in the battle picker, with a "*" suffix if it grants the +2 CP bonus.
squad_battle_label = function(squad_uid) {
    var _sq = fetch_squad(squad_uid);
    var _nm = is_struct(_sq) ? _sq.squad_name() : "?";
    return squad_gives_command_bonus(squad_uid) ? (_nm + " *") : _nm;
};

// Roman numeral for a positive integer (1 -> "I", 4 -> "IV", 10 -> "X", ...).
int_to_roman = function(n) {
    if (n <= 0) { return string(n); }
    var _vals = [1000, 900, 500, 400, 100, 90, 50, 40, 10, 9, 5, 4, 1];
    var _syms = ["M", "CM", "D", "CD", "C", "XC", "L", "XL", "X", "IX", "V", "IV", "I"];
    var _out = "";
    for (var i = 0; i < array_length(_vals); i++) {
        while (n >= _vals[i]) {
            _out += _syms[i];
            n -= _vals[i];
        }
    }
    return _out;
};

// Short company "sign" for a squad's battlefield circle: line companies as a Roman numeral,
// Headquarters as "HQ", the four institutions as a single initial.
squad_company_tag = function(squad_uid) {
    var _sq = fetch_squad(squad_uid);
    if (!is_struct(_sq)) { return "?"; }
    var _c = _sq.base_company;
    if (_c == 0) { return "HQ"; }
    if (_c == GROUP_APOTHECARIUM) { return "A"; }
    if (_c == GROUP_LIBRARIUM) { return "L"; }
    if (_c == GROUP_RECLUSIUM) { return "R"; }
    if (_c == GROUP_ARMOURY) { return "M"; }
    return int_to_roman(_c);
};

// True if either of a unit's weapons carries the heavy_ranged tag (a squad heavy weapon).
marine_has_heavy_ranged = function(unit) {
    return array_contains(weapon_tag_list(unit.weapon_one()), "heavy_ranged")
        || array_contains(weapon_tag_list(unit.weapon_two()), "heavy_ranged");
};

// Up to three representative members to show beneath a squad's circle: its sergeant/leader,
// its attached specialist (if any), and one regular trooper -- preferring whoever carries a
// heavy ranged weapon. Returns an array of { unit, kind, heavy } with kind in
// "sergeant" | "specialist" | "regular", in that draw order.
squad_roster_picks = function(squad_uid) {
    var _mems = marine_squad_living_members(squad_uid);
    var _sq = fetch_squad(squad_uid);
    var _leader = is_struct(_sq) ? _sq.squad_leader : "none";

    var _sgt = undefined, _spec = undefined, _reg_heavy = undefined, _reg_any = undefined;
    for (var i = 0; i < array_length(_mems); i++) {
        var _u = _mems[i];
        var _is_leader = (is_array(_leader) && _u.company == _leader[0] && _u.marine_number == _leader[1]);
        if (_is_leader && _sgt == undefined) { _sgt = _u; continue; }
        if (_spec == undefined && squad_member_is_specialist(_u)) { _spec = _u; continue; }
        if (_reg_heavy == undefined && marine_has_heavy_ranged(_u)) { _reg_heavy = _u; }
        if (_reg_any == undefined) { _reg_any = _u; }
    }
    var _reg = (_reg_heavy != undefined) ? _reg_heavy : _reg_any;

    var _picks = [];
    if (_sgt != undefined)  { array_push(_picks, { unit: _sgt,  kind: "sergeant",   heavy: marine_has_heavy_ranged(_sgt) }); }
    if (_spec != undefined) { array_push(_picks, { unit: _spec, kind: "specialist", heavy: marine_has_heavy_ranged(_spec) }); }
    if (_reg != undefined)  { array_push(_picks, { unit: _reg,  kind: "regular",    heavy: marine_has_heavy_ranged(_reg) }); }
    return _picks;
};

// Player squads in this system, with living members, not already committed to any battle.
refresh_available = function() {
    available = [];
    var _comps = {};
    var _names = struct_get_names(obj_ini.squads);
    for (var i = 0; i < array_length(_names); i++) {
        var _sq = obj_ini.squads[$ _names[i]];
        if (!is_struct(_sq)) {
            continue;
        }
        if (array_length(marine_squad_living_members(_sq.uid)) == 0) {
            continue;
        }
        if (squad_in_any_battle(_sq.uid)) {
            continue; // already deployed on a planet this turn
        }
        var _loc = _sq.squad_loci();
        if (_loc.system == target.name) {
            array_push(available, _sq.uid);
            _comps[$ string(picker_group(_sq.base_company))] = true;
        }
    }
    companies_available = [];
    var _cnames = struct_get_names(_comps);
    for (var c = 0; c < array_length(_cnames); c++) {
        array_push(companies_available, real(_cnames[c]));
    }
    array_sort(companies_available, true);
};
refresh_available();

// Deploys the best available (not-yet-deployed) squad into a place by range-pull:
//   "melee"   -> most positive range reduction (drives hardest toward melee)
//   "ranged"  -> most negative range reduction (holds at range)
//   "neutral" -> range reduction closest to zero
// Each mode is scored so that the highest score wins.
add_best_squad_to_place = function(place_index, mode) {
    if (planet_command_points(target, planet) <= 0) {
        return; // no command points left this turn
    }
    if (bs.places[place_index].free_marine_slots() <= 0) {
        return; // place full
    }
    refresh_available();
    var _best = "none";
    var _best_score = 0;
    for (var i = 0; i < array_length(available); i++) {
        var _uid = available[i];
        var _r = squad_range_reduction(_uid);
        var _score;
        if (mode == "melee") {
            _score = _r;
        } else if (mode == "ranged") {
            _score = -_r;
        } else {
            _score = -abs(_r);
        }
        if (_best == "none" || _score > _best_score) {
            _best_score = _score;
            _best = _uid;
        }
    }
    if (_best != "none") {
        deploy_to(_best, place_index);
    }
};

// Places a squad into a place, disembarks its members onto the planet, and records it as a
// persistent planet garrison operative.
deploy_to = function(squad_uid, place_index) {
    if (squad_in_any_battle(squad_uid)) {
        return; // a squad can only deploy on one planet per turn
    }
    if (planet_command_points(target, planet) <= 0) {
        return; // no command points left this turn
    }
    var _place = bs.places[place_index];
    if (!_place.add_marine_squad(squad_uid)) {
        return; // place full
    }
    // Deploying the FIRST command element (Captain or master) immediately grants +1 CP (the
    // start-of-turn command bonus, applied now so you don't have to wait a turn for it).
    var _had_command = planet_has_command_deployed(target, planet);
    spend_command_point(target, planet, 1);
    if (!_had_command && squad_has_command_element(squad_uid)) {
        grant_command_point(target, planet, 1);
    }

    var _sq = fetch_squad(squad_uid);
    if (is_struct(_sq)) {
        // Disembark every living member that is still aboard a ship onto the planet, so
        // management shows them on-world (members already planet-side are left as-is).
        var _mems = marine_squad_living_members(squad_uid);
        for (var i = 0; i < array_length(_mems); i++) {
            if (_mems[i].marine_location()[0] == eLOCATION_TYPES.SHIP) {
                _mems[i].unload(planet, target);
            }
        }
        _sq.assignment = {type: "garrison", location: target.name, ident: planet};

        // Assigned vehicles deploy to the planet alongside the squad.
        var _vslots = squad_vehicle_slots(squad_uid);
        for (var v = 0; v < array_length(_vslots); v++) {
            var _vc = _vslots[v][0], _vs = _vslots[v][1];
            obj_ini.veh_wid[_vc][_vs] = planet;
            obj_ini.veh_lid[_vc][_vs] = -1;
            obj_ini.veh_loc[_vc][_vs] = target.name;
        }
    }

    // Record as a garrison operative so the squad persists on the planet across turns.
    var _exists = false;
    var _ops = target.p_operatives[planet];
    for (var i = 0; i < array_length(_ops); i++) {
        if (is_struct(_ops[i]) && variable_struct_exists(_ops[i], "type") && _ops[i].type == "squad" && _ops[i].reference == squad_uid) {
            _exists = true;
            break;
        }
    }
    if (!_exists) {
        array_push(target.p_operatives[planet], {type: "squad", reference: squad_uid, job: "garrison", task_time: 0});
    }
    refresh_available();
};

// Moves an already-deployed squad between places on this planet (costs a command point).
move_to_place = function(squad_uid, from_place, to_place) {
    if (from_place == to_place || from_place < 0) {
        return;
    }
    if (planet_command_points(target, planet) <= 0) {
        return; // no command points left this turn
    }
    var _to = bs.places[to_place];
    if (_to.free_marine_slots() <= 0) {
        return; // destination full
    }
    bs.places[from_place].remove_marine_squad(squad_uid);
    _to.add_marine_squad(squad_uid);
    spend_command_point(target, planet, 1);
};
