// Cap on how many marines may belong to a single command-type squad (HQ / institutions),
// which legitimately hold several specialists.
#macro SQUAD_MAX_MEMBERS 10
// A line battle squad holds up to SQUAD_MAX_TROOPERS line troopers plus SQUAD_MAX_SPECIALISTS
// attached specialist (11 total).
#macro SQUAD_MAX_TROOPERS 10
#macro SQUAD_MAX_SPECIALISTS 1

function fetch_squad(array_id) {
    return obj_ini.squads[$ array_id];
}

// Whether a squad member counts as the squad's single attachable "specialist" (a command
// character: Captain, Company Ancient/standard bearer, Company Champion, plus the branch
// specialists -- Apothecary, Chaplain, Techmarine, Librarian, Codiciery, Lexicanum). Anyone
// else (rank-and-file troopers and sergeants) counts as a line trooper.
function squad_member_is_specialist(unit) {
    return is_specialist(unit.role(), SPECIALISTS_COMMAND);
}

// Whether `unit` may join `squad` under the squad-capacity rules. Line battle squads allow up
// to SQUAD_MAX_TROOPERS line troopers and SQUAD_MAX_SPECIALISTS attached specialist (11 total);
// command-type squads (HQ / institutions) keep the flat SQUAD_MAX_MEMBERS cap so they may still
// hold several specialists. A unit already in the squad is ignored (moving within doesn't count).
function squad_has_room_for(squad, unit) {
    if (squad.type == "command_squad") {
        return array_length(squad.members) < SQUAD_MAX_MEMBERS;
    }
    var _troopers = 0;
    var _specs = 0;
    for (var i = 0; i < array_length(squad.members); i++) {
        var _m = fetch_unit(squad.members[i]);
        if (!is_struct(_m) || _m.name() == "") {
            continue;
        }
        if (_m.company == unit.company && _m.marine_number == unit.marine_number) {
            continue; // the incoming unit itself doesn't count against the move
        }
        if (squad_member_is_specialist(_m)) {
            _specs++;
        } else {
            _troopers++;
        }
    }
    if (squad_member_is_specialist(unit)) {
        return _specs < SQUAD_MAX_SPECIALISTS;
    }
    return _troopers < SQUAD_MAX_TROOPERS;
}

function get_squad_ids() {
    return struct_get_names(obj_ini.squads);
}

function squad_count() {
    return array_length(get_squad_ids());
}

// constructor for new squad

/* okay so basically this function loops through a given company and attempts to sort the units in the company not in a squad already into 
the requested squad type , if the squad is not possible it will  not be made*/
// squad_type: the type of squad to be created as a string to access the correct key in obj_ini.squad_types
// company : the company you wish to create the squad in (int)
//squad_loadout: true if you want to use the squad loadout sorting algorithem to re-equip the squad in accordance with the squad type loadout

/*
        squad guidance
            define a role that can exist in a squad by defining 
            [<role>, {
                "max":<maximum number of this role allowed in squad>
                "min":<minimum number of this role required in squad>
                }
            ]
            by adding "loadout" as a key to the role struct e.g {"min":1,"max":1,"loadout":{}}
                a default or optional loadout can be created for the given role in the squad
            "loadout" has two possible keys "required" and "option"
            a required loadout always follows this syntax <loadout_slot>:[<loadout_item>,<required number>]
                so "wep1":["Bolter",4], will mean four marines are always equipped with 4 bolters in the wep1 slot

            option loadouts follow the following syntax <loudout_slot>:[[<loadout_item_list>],<allowed_number>]
                for example [["Flamer", "Meltagun"],1], means the role can have a max of one flamer or meltagun
                    [["Plasma Pistol","Bolt Pistol"], 4] means the role can have a mix of 4 plasma pistols and bolt pistols on top
                        of all required loadout options

    */
function SquadEquipmentSorting(squad, from_armoury = true, to_armoury = true) constructor {
    self.target_squad = squad;
    self.from_armoury = from_armoury;
    self.to_armoury = to_armoury;
    squad_type = target_squad.type;
    squad_unit_types = squad.find_squad_unit_types();
    full_squad_data = obj_ini.squad_types[$ squad_type];
    unit_role = "";
    members_UnitGroup = squad.get_members(true);
    members_UnitGroup.shuffle();
    optional_load = undefined;
    required_load = undefined;

    target_squad.update_fulfilment();

    static sort = function() {
        for (var i = 0; i < array_length(squad_unit_types); i++) {
            unit_role = squad_unit_types[i];
            role_squad_loadout();
        }
    };

    //TODO we proobably have amcaro or soomethinng for this somewhere
    static load_out_areas = [
        "wep1",
        "wep2",
        "armour",
        "gear",
        "mobi"
    ];

    static structure_role_optional_loadout = function(optional_data) {
        optional_load = variable_clone(optional_data); //create a fulfillment object for optional loadouts

        var _optional_loadout_slots = struct_get_names(optional_load);

        for (var slot = 0; slot < array_length(_optional_loadout_slots); slot++) {
            var _load_out_slot = _optional_loadout_slots[slot];
            for (var i = 0; i < array_length(optional_load[$ _load_out_slot]); i++) {
                array_insert(optional_load[$ _load_out_slot][i], 2, 0);
            }
        }
    };

    static structure_role_required_loadout = function(required_data) {
        //find out if the _unit type for the squad has required  equipment thresholds

        required_load = variable_clone(required_data);
        required_loadout_slots = struct_get_names(required_load);
        for (var i = 0; i < array_length(required_loadout_slots); i++) {
            var _current_load_slot = required_loadout_slots[i];
            var _equip_slot = required_load[$ _current_load_slot];
            if (is_string(required_load[$ _current_load_slot][1])) {
                if (required_load[$ _current_load_slot][1] == "max") {
                    required_load[$ _current_load_slot][1] = target_squad.squad_fulfilment[$ unit_role];
                }
            }
            array_insert(required_load[$ _current_load_slot], 2, 0);
        }
    };

    static equip_required_for_role = function(_unit) {
        if (required_load[$ current_load_slot][2] < required_load[$ current_load_slot][1]) {
            //if the required amount of equipment is not in the squad already equip this marine with equipment
            var _item_to_add = required_load[$ current_load_slot][0];
            var required_load_set = {};
            required_load_set[$ current_load_slot] = _item_to_add;
            _unit.alter_equipment(required_load_set, from_armoury, to_armoury);
            required_load[$ current_load_slot][2]++;
            return true;
        } //if all required equipment is included in the squad start adding optional equipment
        return false;
    };

    static equip_optional_for_role = function(_unit) {
        //this basically ensures the optional squad items are randomly selected and allocated in order to make squads more variable

        var _optional_groups = optional_load[$ current_load_slot];
        for (var i = 0; i < array_length(_optional_groups); i++) {
            var _optional_load_data = _optional_groups[i];
            var _optionals_filled = _optional_load_data[2];
            var _optionals_max_allowed = _optional_load_data[1];
            var _optionals_equipment = _optional_load_data[0];
            var _item_to_add;
            if (_optionals_filled < _optionals_max_allowed) {
                var _is_equipment_set = array_length(_optional_load_data) > 3;

                if (is_array(_optionals_equipment)) {
                    //if the array items are varibale e.g a struct
                    _item_to_add = array_random_element(_optionals_equipment);
                } else {
                    _item_to_add = _optionals_equipment;
                }

                // this ensures a marine never gets overloaded with an overly bulky weapon loadout
                if (current_load_slot == "wep1") {
                    var _return_item = _unit.weapon_one();
                    _unit.update_weapon_one(_item_to_add, from_armoury, to_armoury);
                    _unit.ranged_attack();
                    _unit.melee_attack();
                    if ((_unit.encumbered_ranged || _unit.encumbered_melee) && !_is_equipment_set) {
                        _unit.update_weapon_one(_return_item, from_armoury, to_armoury);
                        continue;
                    }
                } else if (current_load_slot == "wep2") {
                    var _return_item = _unit.weapon_two();
                    _unit.update_weapon_two(_item_to_add, from_armoury, to_armoury);
                    _unit.ranged_attack();
                    _unit.melee_attack();
                    if ((_unit.encumbered_ranged || _unit.encumbered_melee) && !_is_equipment_set) {
                        _unit.update_weapon_two(_return_item, from_armoury, to_armoury);
                        continue;
                    }
                }
                var _opt_load_out = {};
                _opt_load_out[$ current_load_slot] = _item_to_add;
                _unit.alter_equipment(_opt_load_out, from_armoury, to_armoury);
                _optional_load_data[1]++;
                if (_is_equipment_set) {
                    var _equip_set_data = _optional_load_data[3];
                    if (is_struct(_equip_set_data)) {
                        _unit.alter_equipment(_equip_set_data, from_armoury, to_armoury);
                        array_push(ignore_units, _unit.uid);
                    }
                }
                break;
            }
        }
    };

    static equip_loudouts_specific_equip_slot = function() {
        var _members_with_role = members_UnitGroup.get_from({role: unit_role});
        if (!struct_exists(current_unit_squad_data, "loadout")) {
            return;
        }
        var _unit;
        var _loudouts = current_unit_squad_data[$ "loadout"];
        while (_members_with_role.number() > 0) {
            _unit = _members_with_role.pop();
            if (array_contains(ignore_units, _unit.uid)) {
                continue;
            }
            if (_unit.role() != unit_role) {
                continue;
            }

            if (required_load != undefined && struct_exists(required_load, current_load_slot)) {
                var _needed_required = equip_required_for_role(_unit);
                if (_needed_required) {
                    continue;
                }
            }

            if (optional_load != undefined && struct_exists(optional_load, current_load_slot)) {
                equip_optional_for_role(_unit);
            }
        }
    };

    static role_squad_loadout = function() {
        required_load = undefined;
        optional_load = undefined;

        current_unit_squad_data = full_squad_data[$ unit_role];
        if (!struct_exists(current_unit_squad_data, "loadout")) {
            return;
        }

        var _loudout_data = current_unit_squad_data[$ "loadout"];
        //find out if the _unit type for the squad has optional equipment thresholds
        if (struct_exists(_loudout_data, "option")) {
            structure_role_optional_loadout(_loudout_data[$ "option"]);
        }

        //if there are required loadout items
        if (struct_exists(_loudout_data, "required")) {
            structure_role_required_loadout(_loudout_data[$ "required"]);
        }

        ignore_units = [];
        for (var i = 0; i < array_length(load_out_areas); i++) {
            current_load_slot = load_out_areas[i];
            equip_loudouts_specific_equip_slot();
        }
    };
}

function UnitSquad(squad_type = undefined, company = 0) constructor {
    members = [];
    type = "";
    squad_fulfilment = {};
    base_company = company;
    life_members = 0;
    nickname = "";
    auto_named = true; // true while the squad name tracks its sergeant; false once the player renames it
    assignment = "none";
    class = [];
    squad_leader = "";
    type_data = {};
    base = "tactical";
    formation_place = "";
    formation_options = [];
    uid = scr_uuid_generate();
    allow_bulk_swap = true;

    if (squad_type != undefined) {
        change_type(squad_type);
    }

    //TODO introduce loyalty hits from long periods of exile from hierarchy nodes
    // nodes will be captains chapter masters and other senior staff
    time_from_parent_node = 0;

    // heres where the whole thing gets annoying
    /*basically each equipment slot is looped through and inside each loop each marine is looped through in a random order to ensure 
			that each squad looks different and that each marine has a range of optional and required equipment
			required equipmetn is things like boltguns and combat knives in a tactical squad
			optional equipment is stuff like lascannons and specialist equipment in a tactical squad or plasma pistols in an assualt squad
			in future i'd like to tailer these to marine skill sets e.g the marines with the best ranged stats get given the best ranged equipment	
		*/
    static sort_squad_loadout = function(from_armoury = true, to_armoury = true) {
        var _sorter = new SquadEquipmentSorting(self, from_armoury, to_armoury);
        _sorter.sort();
    };

    static stat_av = function(stat) {};

    static add_type_data = function(data) {
        type_data = data;
        display_name = type_data[$ "display_data"];
        if (struct_exists(type_data, "class")) {
            class = type_data.class;
        }
        if (struct_exists(type_data, "base")) {
            base = type_data.base;
        } else {
            base = "tactical";
        }
        if (struct_exists(type_data, "formation_options")) {
            formation_options = type_data.formation_options;
            formation_place = formation_options[0];
        }
    };

    static change_type = function(new_type) {
        type = new_type;
        add_type_data(obj_ini.squad_types[$ type].type_data);
    };

    static find_squad_unit_types = function() {
        //find out what type of units squad consists of
        var fill_squad = obj_ini.squad_types[$ type];
        squad_unit_types = struct_get_names(fill_squad);
        var _wanted_unit_role;
        var unit_type_count = array_length(squad_unit_types);
        for (var i = 0; i < unit_type_count; i++) {
            _wanted_unit_role = squad_unit_types[i];
            if (_wanted_unit_role == "type_data") {
                array_delete(squad_unit_types, i, 1);
                unit_type_count--;
                i--;
                continue;
            }
            squad_fulfilment[$ _wanted_unit_role] = 0; //create a fulfilment structure to log members of squad
        }
        return squad_unit_types;
    };

    static get_squad_structs = function(as_UnitGroup) {
        var _struct_array = [];
        for (var i = array_length(members) - 1; i >= 0; i--) {
            _unit = fetch_unit(members[i]);
            if (_unit.name() == "") {
                array_delete(members, i, 1);
                continue;
            } else {
                array_push(_struct_array, _unit);
            }
        }
        return _struct_array;
    };

    // for creating a new sergeant from existing squad members
    static new_sergeant = function(veteran = false) {
        var exp_unit = "";
        var _unit;
        var highest_exp = 0;
        var member_length = array_length(members);
        for (var i = 0; i < member_length; i++) {
            _unit = fetch_unit(members[i]);
            if (_unit.name() == "") {
                array_delete(members, i, 1);
                member_length--;
                i--;
                continue;
            }
            // Never promote a specialist / head (apothecary, librarian, chaplain, forge master,
            // master of sanctity/apothecarion, captain, etc.) into a sergeant -- that would
            // overwrite their role and can break the systems that rely on them existing.
            if (is_specialist(_unit.role())) {
                continue;
            }
            if (_unit.experience > highest_exp) {
                highest_exp = _unit.experience;
                exp_unit = _unit;
            }
        }
        if ((array_length(members) > 0) && is_struct(exp_unit)) {
            if (exp_unit.name() != "") {
                var new_role;
                if (veteran == true) {
                    new_role = obj_ini.role[100][19];
                } else {
                    new_role = obj_ini.role[100][18];
                }
                exp_unit.update_role(new_role);
                if (irandom(1) == 0) {
                    exp_unit.add_trait("lead_example");
                }
            }
        }
    };

    static kill_members = function() {
        for (var i = 0; i < array_length(members); i++) {
            scr_kill_unit(members[i][0], members[i][1]);
        }
        members = [];
    };

    static cancel_assignment = function() {};

    /*checks the status of squad so it can be either restocked or 
		deleted if there are no longer enough members ot make a squad*/
    // fill from requiures a valid UnitIndex struct
    static update_fulfilment = function(fill_from = undefined) {
        var _unit;

        squad_fulfilment = {};
        var fill_squad = obj_ini.squad_types[$ type]; //grab all the squad struct info from the squad_types struct

        var squad_unit_types = struct_get_names(fill_squad); //find out what type of units squad consists of
        var unit_type_count = array_length(squad_unit_types);
        for (var i = unit_type_count - 1; i >= 0; i--) {
            var _wanted_unit_role = squad_unit_types[i];
            if (_wanted_unit_role == "type_data") {
                array_delete(squad_unit_types, i, 1);
                continue;
            }
            squad_fulfilment[$ _wanted_unit_role] = 0; //create a fulfilment structure to log members of squad
        }
        var member_length = array_length(members);
        for (var i = member_length - 1; i >= 0; i--) {
            //checks squad member is still valid
            _unit = fetch_member(i);
            if (_unit.name() == "") {
                array_delete(members, i, 1);
                continue;
            }
            if (struct_exists(squad_fulfilment, _unit.role())) {
                squad_fulfilment[$ _unit.role()]++;
            } else {
                squad_fulfilment[$ _unit.role()] = 1;
            }
        }
        fulfilled = true;
        required = {};
        space = {};
        has_space = false;
        for (var i = 0; i < array_length(squad_unit_types); i++) {
            var _wanted_unit_role = squad_unit_types[i];
            var _max_role_count = fill_squad[$ _wanted_unit_role][$ "max"];
            var _squad_role_current = squad_fulfilment[$ _wanted_unit_role];

            var _min_role_allowed = fill_squad[$ _wanted_unit_role][$ "min"];

            if (fill_from != undefined) {
                while (fill_from.has_role(_wanted_unit_role) && _squad_role_current < _max_role_count) {
                    var _new_member = fill_from.pop_role_member(_wanted_unit_role);
                    add_member(_new_member.company, _new_member.marine_number);
                    squad_fulfilment[$ _wanted_unit_role]++;
                    _squad_role_current = squad_fulfilment[$ _wanted_unit_role];
                    _new_member.squad = uid;
                }
            }

            if (_squad_role_current < _max_role_count) {
                space[$ _wanted_unit_role] = _max_role_count - _squad_role_current;
                has_space = true;
            }

            if (squad_fulfilment[$ _wanted_unit_role] < _min_role_allowed) {
                fulfilled = false;
                required[$ _wanted_unit_role] = _min_role_allowed - _squad_role_current;
            }
        }
        var _sarge = obj_ini.role[100][eROLE.SERGEANT];
        if (struct_exists(required, _sarge)) {
            if (required[$ _sarge] > 0) {
                new_sergeant();
                required[$ _sarge]--;
            }
        }
        //find a new veteran sergeant
        var _vet_sarge = obj_ini.role[100][eROLE.VETERANSERGEANT];
        if (struct_exists(required, _vet_sarge)) {
            if (required[$ _vet_sarge] > 0) {
                new_sergeant(true);
                required[$ _vet_sarge]--;
            }
        }
    };

    static empty_squad = function() {
        for (var r = array_length(members) - 1; r >= 0; r--) {
            fetch_member(r).squad = "none";
        }
        members = [];
    };

    static empty_squad_to_index = function(index) {
        var _mems = [];
        var _mem;
        for (var r = array_length(members) - 1; r >= 0; r--) {
            _mem = fetch_member(r);
            _mem.squad = "none";
            array_push(_mems, _mem);
        }
        index.add_to_index(_mems);
        members = [];
    };

    static fetch_member = function(index) {
        return fetch_unit(members[index]);
    };

    static fetch_members = function() {
        return collect_role_group("all", "", false, {"company": base_company, "squad": uid, "max_wanted": array_length(members)});
    };

    static add_member = function(comp, unit_number) {
        if (is_struct(comp)) {
            unit_number = comp.marine_number;
            comp = comp.company;
        }
        array_push(members, [comp, unit_number]);
        life_members++;
    };

    // for saving squads
    static jsonify = function(stringify = true) {
        var copy_struct = self; //grab marine structure
        var new_struct = {};
        var copy_part;
        var names = variable_struct_get_names(copy_struct); // get all keys within structure
        for (var name = 0; name < array_length(names); name++) {
            //loop through keys to find which ones are methods as they can't be saved as a json string
            if (!is_method(copy_struct[$ names[name]])) {
                copy_part = variable_clone(copy_struct[$ names[name]]);
                variable_struct_set(new_struct, names[name], copy_part); //if key value is not a method add to copy structure
            }
        }
        if (stringify) {
            return json_stringify(new_struct, true);
        } else {
            return new_struct;
        }
    };

    //function for loading in squad save data
    static load_json_data = function(data) {
        var names = variable_struct_get_names(data);
        for (var i = 0; i < array_length(names); i++) {
            variable_struct_set(self, names[i], variable_struct_get(data, names[i]));
        }
    };

    //this dermine the relative coherency of a squad on the basis that a squad needs to more or less be all together in order ot undertake squad actions
    static squad_loci = function() {
        var member_length = array_length(members);
        var locations = [];
        var system = "";
        var unit_loc;
        var _unit;
        var same_system = true;
        var same_loc_type = true;
        var loc_type = false;
        var same_loc_id = false;
        var loc_id;
        var in_orbit = false;
        var planet_side = false;
        var exact_loc = false;
        for (var i = 0; i < member_length; i++) {
            _unit = fetch_unit(members[i]);
            if (_unit.name() == "") {
                array_delete(members, i, 1);
                member_length--;
                i--;
                continue;
            }
            unit_loc = _unit.marine_location();
            if (system == "") {
                system = unit_loc[2];
                loc_type = unit_loc[0];
                loc_id = unit_loc[1];
            }
            if (system != unit_loc[2]) {
                same_system = false;
            }
            if (same_system) {
                if (loc_type != unit_loc[0]) {
                    same_loc_type = false;
                }
            }
            if (same_loc_type && same_system) {
                if (loc_id == unit_loc[1]) {
                    exact_loc = true;
                } else {
                    exact_loc = false;
                    if (loc_type == eLOCATION_TYPES.SHIP) {
                        in_orbit = true;
                    } else if (loc_type == eLOCATION_TYPES.PLANET) {
                        planet_side = true;
                    }
                }
            }
        }
        var final_loc_status = "";
        if (!same_system) {
            final_loc_status = "Scattered";
        } else if (same_loc_type) {
            if (loc_type == eLOCATION_TYPES.SHIP) {
                if (exact_loc) {
                    final_loc_status = $"aboard {obj_ini.ship[loc_id]}";
                } else if (in_orbit) {
                    final_loc_status = $"various ships orbiting {system}";
                }
            } else if (loc_type == eLOCATION_TYPES.PLANET) {
                if (exact_loc) {
                    final_loc_status = $"{system} {scr_roman_numerals()[loc_id - 1]}";
                } else if (planet_side) {
                    final_loc_status = $"various planets in {system}";
                }
            }
        } else {
            final_loc_status = $"system {system}";
        }
        return {text: final_loc_status, system: system, same_system: same_system, exact_loc: exact_loc, planet_side: planet_side, in_orbit: in_orbit};
        //returns all the squad coherency data
    };

    //determines the leader of a squad by using the hierarchy array returned by role_hierarchy()
    //this means the highest ranking dude in a squad will always be the squad leader
    //failing that the highest experience dude
    static determine_leader = function() {
        var _unit;
        var member_length = array_length(members);
        var hierarchy = role_hierarchy();
        var leader_hier_pos = array_length(hierarchy);
        var leader = "none", _unit;
        var highest_exp = 0;
        for (var i = 0; i < member_length; i++) {
            _unit = fetch_unit(members[i]);
            if (_unit.name() == "") {
                array_delete(members, i, 1);
                member_length--;
                i--;
                continue;
            } else {
                if (leader == "none") {
                    leader = [
                        _unit.company,
                        _unit.marine_number
                    ];
                    for (var r = 0; r < array_length(hierarchy); r++) {
                        if (hierarchy[r] == _unit.role()) {
                            leader_hier_pos = r;
                            break;
                        }
                    }
                } else if (leader_hier_pos < array_length(hierarchy) && hierarchy[leader_hier_pos] == _unit.role()) {
                    var _leader = fetch_unit(leader);
                    if (_leader.experience < _unit.experience) {
                        leader = [
                            _unit.company,
                            _unit.marine_number
                        ];
                    }
                } else {
                    for (var r = 0; r < leader_hier_pos; r++) {
                        if (hierarchy[r] == _unit.role()) {
                            leader_hier_pos = r;
                            leader = [
                                _unit.company,
                                _unit.marine_number
                            ];
                            break;
                        }
                    }
                }
            }
        }
        squad_leader = leader;
        return leader;
    };

    static change_sgt = function(new_sgt) {
        sgt = determine_leader();
        var remove_sgt;
        if (sgt != "none") {
            remove_sgt = fetch_unit(sgt);
            if (remove_sgt.IsSpecialist(SPECIALISTS_SQUAD_LEADERS)) {
                var replace_role = remove_sgt.role();
                remove_sgt.update_role(new_sgt.role());
                //TODO centralise loyalty changes for role changes in the update_role method
                remove_sgt.alter_loyalty(-10);
                new_sgt.update_role(replace_role);
                new_sgt.alter_loyalty(10);
            }
        }
    };

    static set_location = function(loc, lid, wid) {
        var member_length = array_length(members);
        var member_location;
        var system = "none";
        with (obj_star) {
            if (name == loc) {
                system = self;
                break;
            }
        }
        if (system == "none") {
            return "invalid system";
        }
        member_loop(set_member_loc, {loc: loc, lid: lid, wid: wid, system: system});
    };

    static member_loop = function(member_func, data_pack) {
        var _unit;
        member_length = array_length(members);
        for (var i = 0; i < member_length; i++) {
            _unit = fetch_unit(members[i]);
            if (_unit.name() == "") {
                array_delete(members, i, 1);
                member_length--;
                i--;
                continue;
            } else {
                var pack_return;
                with (_unit) {
                    pack_return = member_func(data_pack);
                }
                data_pack = pack_return;
                if (struct_exists(data_pack, "action")) {
                    if (data_pack.action == "break") {
                        break;
                    }
                }
            }
        }
        return data_pack;
    };

    static get_members = function(as_UnitGroup = false) {
        var mems = [];
        for (var i = 0; i < array_length(members); i++) {
            array_push(mems, fetch_member(i));
        }
        if (as_UnitGroup) {
            return new UnitGroup(mems);
        }
        return mems;
    };

    // Company "sign": the home group this squad belongs to, returned as a data label.
    static display_label = function() {
        if (base_company == 0) {
            return "Headquarters";
        }
        if (base_company == GROUP_APOTHECARIUM) { return "Apothecarion"; }
        if (base_company == GROUP_LIBRARIUM) { return "Librarium"; }
        if (base_company == GROUP_RECLUSIUM) { return "Reclusium"; }
        if (base_company == GROUP_ARMOURY) { return "Armoury"; }
        var _label = scr_convert_company_to_string(base_company);
        return (_label == "") ? "Unaffiliated" : _label;
    };

    // Derives a squad name from its sergeant/leader, 40k style ("Squad Tycho").
    static name_from_leader = function() {
        var _leader = determine_leader();
        if (_leader != "none") {
            var _unit = fetch_unit(_leader);
            if (is_struct(_unit) && _unit.name() != "") {
                var _parts = string_split(_unit.name(), " ");
                var _surname = _parts[array_length(_parts) - 1];
                return $"Squad {_surname}";
            }
        }
        if (variable_struct_exists(self, "display_name") && is_string(display_name) && display_name != "") {
            return display_name;
        }
        return "Unnamed Squad";
    };

    // The squad's individual name: the player override if one is set, otherwise auto from the sergeant.
    static squad_name = function() {
        if (!auto_named && nickname != "") {
            return nickname;
        }
        return name_from_leader();
    };

    // Player-facing rename. An empty string reverts to auto (sergeant-derived) naming.
    static set_custom_name = function(new_name) {
        new_name = string_trim(new_name);
        nickname = new_name;
        auto_named = (new_name == "");
        return squad_name();
    };

    // Keeps the auto name in step with the current sergeant; a no-op once the player has renamed.
    static refresh_auto_name = function() {
        if (auto_named) {
            nickname = "";
        }
        return squad_name();
    };
}

// Moves a single marine from its current squad into another squad, recomputing
// both squads' composition and leadership afterwards. Returns true on success.
function move_marine_to_squad(unit, new_squad_uid) {
    if (!is_struct(unit) || unit.name() == "") {
        return false;
    }
    var _old_uid = unit.squad;
    if (_old_uid == new_squad_uid) {
        return false;
    }
    var _new_squad = fetch_squad(new_squad_uid);
    if (!is_struct(_new_squad)) {
        return false;
    }
    // A line squad holds up to 10 line troopers + 1 specialist; command squads keep the flat cap.
    if (!squad_has_room_for(_new_squad, unit)) {
        return false;
    }
    // Dreadnoughts fight alone: nothing may join a dreadnought's squad, and a dreadnought may
    // not be moved into another squad (it stays the leader of its own). Detected by armour
    // (covers both "Dreadnought" and "Venerable Dreadnought").
    if (unit.is_dreadnought()) {
        return false;
    }
    if (squad_has_dreadnought(_new_squad)) {
        return false;
    }
    unit.add_to_squad(new_squad_uid); // removes from the old squad first

    // Leadership: a sergeant moved into a squad that already has a sergeant becomes a trooper.
    var _sgt = obj_ini.role[100][eROLE.SERGEANT];
    var _vsgt = obj_ini.role[100][eROLE.VETERANSERGEANT];
    if (unit.role() == _sgt || unit.role() == _vsgt) {
        var _other_sgt = false;
        for (var i = 0; i < array_length(_new_squad.members); i++) {
            var _m = fetch_unit(_new_squad.members[i]);
            if (!is_struct(_m) || _m.name() == "") {
                continue;
            }
            if (_m.company == unit.company && _m.marine_number == unit.marine_number) {
                continue;
            }
            if (_m.role() == _sgt || _m.role() == _vsgt) {
                _other_sgt = true;
                break;
            }
        }
        if (_other_sgt) {
            unit.update_role(squad_trooper_role(_new_squad, unit));
            unit.alter_loyalty(-5);
        }
    }

    if (_old_uid != "none") {
        var _old_squad = fetch_squad(_old_uid);
        if (is_struct(_old_squad)) {
            // update_fulfilment promotes a fresh sergeant if the old one just left.
            _old_squad.update_fulfilment();
            _old_squad.determine_leader();
        }
    }
    _new_squad.update_fulfilment();
    _new_squad.determine_leader();
    return true;
}

// The default trooper role for a squad, used when demoting an excess sergeant. Prefers an
// existing non-sergeant member's role; falls back to the basic Tactical role.
function squad_trooper_role(squad, exclude_unit = undefined) {
    var _sgt = obj_ini.role[100][eROLE.SERGEANT];
    var _vsgt = obj_ini.role[100][eROLE.VETERANSERGEANT];
    for (var i = 0; i < array_length(squad.members); i++) {
        var _m = fetch_unit(squad.members[i]);
        if (!is_struct(_m) || _m.name() == "") {
            continue;
        }
        if (exclude_unit != undefined && _m.company == exclude_unit.company && _m.marine_number == exclude_unit.marine_number) {
            continue;
        }
        if (_m.role() != _sgt && _m.role() != _vsgt) {
            return _m.role();
        }
    }
    return obj_ini.role[100][eROLE.TACTICAL];
}

// Releases a squad from garrison/battle duty: clears its assignment and removes it from any
// planet's operatives list and active battle. Used when its marines are pulled back to ship.
function free_squad_from_garrison(squad_uid) {
    if (squad_uid == "none" || squad_uid == "") {
        return;
    }
    var _sq = fetch_squad(squad_uid);
    if (is_struct(_sq)) {
        _sq.assignment = "none";
    }
    with (obj_star) {
        for (var p = 1; p <= planets; p++) {
            var _ops = p_operatives[p];
            for (var i = array_length(_ops) - 1; i >= 0; i--) {
                if (is_struct(_ops[i]) && variable_struct_exists(_ops[i], "type") && _ops[i].type == "squad" && _ops[i].reference == squad_uid) {
                    array_delete(_ops, i, 1);
                }
            }
            if (is_struct(p_battle[p])) {
                var _bs = p_battle[p];
                for (var pl = 0; pl < array_length(_bs.places); pl++) {
                    _bs.places[pl].remove_marine_squad(squad_uid);
                }
            }
        }
    }
}

// Recalls every garrisoned squad on a planet: frees them from duty and loads each marine
// back onto its last ship (if that ship is in the system with room). Returns marines recalled.
// Loads a squad's living members back onto their last ship (best effort).
function load_squad_to_ships(system, squad_uid) {
    var _loaded = 0;
    var _mems = marine_squad_living_members(squad_uid);
    for (var m = 0; m < array_length(_mems); m++) {
        var _u = _mems[m];
        if (is_struct(_u.last_ship) && variable_struct_exists(_u.last_ship, "uid")) {
            var _ship_id = array_get_index(obj_ini.ship_uid, _u.last_ship.uid);
            if (_ship_id >= 0) {
                _u.load_marine(_ship_id, system);
                _loaded++;
            }
        }
    }
    return _loaded;
}

// Recalls all NON-engaged garrison squads on a planet to their ships (free). Squads in direct
// combat must use the per-squad escape instead.
function recall_planet_garrison(system, planet) {
    var _uids = planet_marine_squad_uids(system, planet);
    var _recalled = 0;
    for (var s = 0; s < array_length(_uids); s++) {
        var _uid = _uids[s];
        if (squad_is_engaged(_uid)) {
            continue; // engaged squads escape via the battle screen (costs a command point)
        }
        free_squad_from_garrison(_uid);
        _recalled += load_squad_to_ships(system, _uid);
    }
    return _recalled;
}

// True if a planet has deployed marine squads but no enemy squads present (i.e. idling).
function planet_has_idle_squads(system, planet) {
    if (is_struct(system.p_battle[planet]) && system.p_battle[planet].total_enemies() > 0) {
        return false; // enemies present -> not idling
    }
    return array_length(planet_marine_squad_uids(system, planet)) > 0;
}

// True if any planet in the system has idling deployed squads (for the sector-view "Zzz").
function system_has_idle_squads(system) {
    for (var p = 1; p <= system.planets; p++) {
        if (planet_has_idle_squads(system, p)) {
            return true;
        }
    }
    return false;
}

// Recalls every idling squad across the system (planets with no enemy squads present) back to
// their ships. Planets that still have enemies are left untouched.
function recall_system_idle_squads(system) {
    var _recalled = 0;
    for (var p = 1; p <= system.planets; p++) {
        if (!planet_has_idle_squads(system, p)) {
            continue;
        }
        var _uids = planet_marine_squad_uids(system, p);
        for (var s = 0; s < array_length(_uids); s++) {
            free_squad_from_garrison(_uids[s]);
            _recalled += load_squad_to_ships(system, _uids[s]);
        }
    }
    return _recalled;
}

// Disengages a single squad from a battle and loads it onto its ships. Costs 1 command point.
function escape_squad_from_battle(system, planet, squad_uid) {
    // Need at least one valid ship to escape to, or the command point would be wasted.
    var _mems = marine_squad_living_members(squad_uid);
    var _has_ship = false;
    for (var m = 0; m < array_length(_mems); m++) {
        var _ls = _mems[m].last_ship;
        if (is_struct(_ls) && variable_struct_exists(_ls, "uid") && array_get_index(obj_ini.ship_uid, _ls.uid) >= 0) {
            _has_ship = true;
            break;
        }
    }
    if (!_has_ship) {
        return false;
    }
    if (!spend_command_point(system, planet, 1)) {
        return false; // no command points left this turn
    }
    free_squad_from_garrison(squad_uid);
    load_squad_to_ships(system, squad_uid);
    return true;
}

// Picks an appropriate squad type for a lone marine based on their role.
function role_to_squad_type(role_name) {
    var _r = obj_ini.role[100];
    // Only explicit line-trooper roles use line squad types (which may auto-promote a lone
    // member to sergeant). EVERY other role -- specialists, HQ, senior titles like "Forge
    // Master", dreadnoughts, or anything unrecognised -- goes into a command_squad, which has
    // no Sergeant requirement, so update_fulfilment can never overwrite their role.
    var _type = "command_squad";
    if (role_name == _r[eROLE.TACTICAL] || role_name == _r[eROLE.SERGEANT] || role_name == _r[eROLE.VETERANSERGEANT]) {
        _type = "tactical_squad";
    } else if (role_name == _r[eROLE.DEVASTATOR]) {
        _type = "devastator_squad";
    } else if (role_name == _r[eROLE.ASSAULT]) {
        _type = "assault_squad";
    } else if (role_name == _r[eROLE.TERMINATOR]) {
        _type = "terminator_squad";
    } else if (role_name == _r[eROLE.VETERAN]) {
        _type = "veteran_squad";
    } else if (role_name == _r[eROLE.SCOUT]) {
        _type = "scout_squad";
    }
    if (!struct_exists(obj_ini.squad_types, _type)) {
        _type = "tactical_squad";
    }
    return _type;
}

// True if any member of a squad is a dreadnought (by armour, so "Venerable Dreadnought" counts).
function squad_has_dreadnought(squad) {
    for (var i = 0; i < array_length(squad.members); i++) {
        var _m = fetch_unit(squad.members[i]);
        if (is_struct(_m) && _m.name() != "" && _m.is_dreadnought()) {
            return true;
        }
    }
    return false;
}

// Builds a single squad from a list of squadless marine structs (first becomes the basis for the
// squad type/company; the highest-ranking member ends up as leader). Returns the squad uid, or
// "none" if no valid members. Used for the bespoke game-start command/specialist squads.
function build_squad_from_units(unit_list) {
    var _valid = [];
    for (var i = 0; i < array_length(unit_list); i++) {
        var _u = unit_list[i];
        if (is_struct(_u) && _u.name() != "" && _u.squad == "none") {
            array_push(_valid, _u);
        }
    }
    if (array_length(_valid) == 0) {
        return "none";
    }
    var _leader = _valid[0];
    var _sq = new UnitSquad(role_to_squad_type(_leader.role()), _leader.company);
    obj_ini.squads[$ _sq.uid] = _sq;
    for (var i = 0; i < array_length(_valid); i++) {
        _valid[i].add_to_squad(_sq.uid);
    }
    _sq.base_company = _leader.company;
    _sq.update_fulfilment();
    _sq.determine_leader();
    return _sq.uid;
}

// Game-start squads for the command groups (called once, before squad_up_loose_marines):
//   - HQ: the Chapter Master leads a squad of up to 10 (himself + 9 Honour Guards); any further
//     Honour Guards form additional 10-man squads.
//   - Each institution: its master + 4 free specialists form a command squad; any remaining
//     specialists are grouped into 5-man squads.
function squad_up_command_groups() {
    // --- Headquarters: Chapter Master + Honour Guards, in squads of at most SQUAD_MAX_MEMBERS ---
    var _cm_role = obj_ini.role[100][eROLE.CHAPTERMASTER];
    var _hg_role = obj_ini.role[100][eROLE.HONOURGUARD];
    var _hq = obj_ini.TTRPG[0];
    var _hq_units = [];
    for (var i = 0; i < array_length(_hq); i++) { // Chapter Master leads the first squad
        var _u = _hq[i];
        if (is_struct(_u) && _u.name() != "" && _u.squad == "none" && _u.role() == _cm_role) {
            array_push(_hq_units, _u);
        }
    }
    for (var i = 0; i < array_length(_hq); i++) { // then every Honour Guard
        var _u = _hq[i];
        if (is_struct(_u) && _u.name() != "" && _u.squad == "none" && _u.role() == _hg_role) {
            array_push(_hq_units, _u);
        }
    }
    // Split into 10-man squads: first is CM + 9 Honour Guards, rest are 10 Honour Guards each.
    while (array_length(_hq_units) > 0) {
        var _hq_chunk = [];
        while (array_length(_hq_chunk) < SQUAD_MAX_MEMBERS && array_length(_hq_units) > 0) {
            array_push(_hq_chunk, _hq_units[0]);
            array_delete(_hq_units, 0, 1);
        }
        build_squad_from_units(_hq_chunk);
    }

    // --- Institutions: master + 4 specialists, then the rest in 5-man squads ---
    var _groups = [GROUP_APOTHECARIUM, GROUP_LIBRARIUM, GROUP_RECLUSIUM, GROUP_ARMOURY];
    for (var g = 0; g < array_length(_groups); g++) {
        var _comp = obj_ini.TTRPG[_groups[g]];
        var _heads = [];
        var _rest = [];
        for (var i = 0; i < array_length(_comp); i++) {
            var _u = _comp[i];
            if (!is_struct(_u) || _u.name() == "" || _u.squad != "none") {
                continue;
            }
            if (is_specialist(_u.role(), SPECIALISTS_HEADS)) {
                array_push(_heads, _u); // the institution master
            } else {
                array_push(_rest, _u);
            }
        }
        // First squad: the master plus up to four specialists (5 total).
        var _first = _heads;
        while (array_length(_first) < 5 && array_length(_rest) > 0) {
            array_push(_first, _rest[0]);
            array_delete(_rest, 0, 1);
        }
        if (array_length(_first) > 0) {
            build_squad_from_units(_first);
        }
        // Remaining specialists in 5-man squads.
        while (array_length(_rest) > 0) {
            var _chunk = [];
            while (array_length(_chunk) < 5 && array_length(_rest) > 0) {
                array_push(_chunk, _rest[0]);
                array_delete(_rest, 0, 1);
            }
            build_squad_from_units(_chunk);
        }
    }
}

// Creates a new single-member squad for a squadless marine, with them as its leader. The unit
// keeps its role (no forced promotion), so specialists / HQ / dreadnoughts stay themselves.
function form_new_squad_for(unit) {
    if (!is_struct(unit) || unit.name() == "" || unit.squad != "none") {
        return "none";
    }
    // Any chapter member may form a squad: line troops (base_group "astartes") plus all
    // specialists, masters, honour guard and dreadnoughts (caught by is_specialist).
    if (unit.base_group != "astartes" && !is_specialist(unit.role())) {
        return "none";
    }
    var _sq = new UnitSquad(role_to_squad_type(unit.role()), unit.company);
    obj_ini.squads[$ _sq.uid] = _sq;
    unit.add_to_squad(_sq.uid);
    _sq.base_company = unit.company;
    // update_fulfilment promotes a lone line trooper to sergeant (the leader of its new squad);
    // specialists / HQ / dreadnoughts use command_squad which has no sergeant requirement, so
    // their roles are left untouched.
    _sq.update_fulfilment();
    _sq.determine_leader();
    return _sq.uid;
}

// Any controllable marine without a squad (line troops, HQ, specialists, dreadnoughts) forms a
// new single-member squad in their company so it can be deployed. Includes HQ (company 0).
// Iterates the full TTRPG company arrays (slots can run past 100 -- dreadnoughts and other
// late-added units sit at high indices, so a hard 0..100 cap silently skipped them).
function squad_up_loose_marines() {
    for (var comp = 0; comp <= STORAGE_GROUP_MAX; comp++) {
        var _company = obj_ini.TTRPG[comp];
        var _slots = array_length(_company);
        for (var num = 0; num < _slots; num++) {
            var _u = fetch_unit([comp, num]);
            if (!is_struct(_u) || _u.name() == "") {
                continue;
            }
            if (_u.squad != "none") {
                continue;
            }
            // Line troops, specialists, masters, honour guard and dreadnoughts are all eligible.
            if (_u.base_group != "astartes" && !is_specialist(_u.role())) {
                continue;
            }
            if (!_u.controllable()) {
                continue;
            }
            form_new_squad_for(_u);
        }
    }
}

// --- Vehicle <-> squad assignment ------------------------------------------------------
// Vehicles are linked to squads on the vehicle side (obj_ini.veh_squad), so the link
// survives scr_vehicle_order compaction.

function vehicle_owner_squad(co, slot) {
    return obj_ini.veh_squad[co][slot];
}

function assign_vehicle_to_squad(co, slot, squad_uid) {
    // Only one vehicle may be assigned per squad.
    if (array_length(squad_vehicle_slots(squad_uid)) > 0) {
        return false;
    }
    obj_ini.veh_squad[co][slot] = squad_uid;
    return true;
}

// Assigns one spare company vehicle to each squad that has none (used at game start).
function preassign_vehicles_to_squads() {
    var _names = struct_get_names(obj_ini.squads);
    for (var i = 0; i < array_length(_names); i++) {
        var _sq = obj_ini.squads[$ _names[i]];
        if (!is_struct(_sq)) {
            continue;
        }
        if (array_length(squad_vehicle_slots(_sq.uid)) > 0) {
            continue; // already has a vehicle
        }
        var _free = company_unassigned_vehicle_slots(_sq.base_company);
        if (array_length(_free) > 0) {
            assign_vehicle_to_squad(_sq.base_company, _free[0], _sq.uid);
        }
    }
}

function unassign_vehicle_from_squad(co, slot) {
    obj_ini.veh_squad[co][slot] = "";
}

// All [company, slot] vehicle references currently assigned to a squad.
function squad_vehicle_slots(squad_uid) {
    var _out = [];
    if (squad_uid == "none" || squad_uid == "") {
        return _out;
    }
    for (var co = 0; co <= STORAGE_GROUP_MAX; co++) {
        var _len = array_length(obj_ini.veh_role[co]);
        for (var slot = 0; slot < _len; slot++) {
            if (obj_ini.veh_role[co][slot] != "" && obj_ini.veh_squad[co][slot] == squad_uid) {
                array_push(_out, [co, slot]);
            }
        }
    }
    return _out;
}

// Vehicle slots in a company that belong to no squad (available to assign). Vehicles whose
// owning squad no longer exists are treated as free (and the stale link is cleared).
function company_unassigned_vehicle_slots(co) {
    var _out = [];
    var _len = array_length(obj_ini.veh_role[co]);
    for (var slot = 0; slot < _len; slot++) {
        if (obj_ini.veh_role[co][slot] == "") {
            continue;
        }
        var _owner = obj_ini.veh_squad[co][slot];
        if (_owner != "" && !struct_exists(obj_ini.squads, _owner)) {
            obj_ini.veh_squad[co][slot] = ""; // self-heal: owning squad is gone
            _owner = "";
        }
        if (_owner == "") {
            array_push(_out, slot);
        }
    }
    return _out;
}

// creates the origional distribution of squads accross the chapter
// lots of room for customisation of different chapters here

function game_start_squads() {
    obj_ini.squads = {};
    if (struct_exists(chapter_squad_arrangement, "companies")) {
        var _comp_datas = chapter_squad_arrangement.companies;
        for (var i = 0; i < array_length(_comp_datas); i++) {
            var _company = collect_company(_comp_datas[i].company);
            _company.organise_by_template(_comp_datas[i]);
        }
    }
}

function set_member_loc(loc_data) {
    var loc = loc_data.loc;
    var lid = loc_data.lid;
    var wid = loc_data.wid;
    var system = loc_data.system;
    var member_location = marine_location();
    if (wid > 0 && loc == member_location[2]) {
        if (member_location[0] == eLOCATION_TYPES.SHIP) {
            unload(wid, system);
        } else if (member_location[0] == eLOCATION_TYPES.PLANET && member_location[1] != wid && member_location[2] == loc) {
            get_unit_size();
            system.p_player[member_location[1]] -= size;
            system.p_player[wid] += size;
            planet_location = wid;
            ship_location = -1;
        }
    } else {
        if (wid == 0 && lid > -1) {
            load_marine(lid);
        }
    }
    return loc_data;
}
//finds all the squads linked to a given company
//TODO coalece lots of these functions to make make a company object
//maybe then we can have more than 10 companies 
