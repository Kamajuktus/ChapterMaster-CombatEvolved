var gw = display_get_gui_width();
var gh = display_get_gui_height();

// Range-role colours (shared with squad colouring): blue = ranged, green = neutral, red = melee.
var COL_RANGED = make_colour_rgb(90, 150, 255);
var COL_NEUTRAL = c_lime;
var COL_MELEE = c_red;

// Dim backdrop.
draw_set_alpha(0.92);
draw_set_color(c_black);
draw_rectangle(0, 0, gw, gh, false);
draw_set_alpha(1);

draw_set_font(fnt_40k_14b);
draw_set_valign(fa_top);
var hovered_squad = "none"; // squad whose lineup to preview (set on hover)

// =======================================================================================
// Top bar: command points, planet name, Board Idlers, Close.
// =======================================================================================
draw_set_halign(fa_left);
draw_set_color(c_aqua);
draw_text(96, 18, $"CP: {planet_command_points(target, planet)} / {target.p_command_max[planet]}");

draw_set_halign(fa_center);
draw_set_color(c_white);
draw_text(gw / 2, 14, string_upper(pdata.name()));

// Objective control progress + shift timer (centred under the planet name).
draw_set_color(c_yellow);
var _obj_line = $"Objective held {bs.objective_control_turns} / {OBJECTIVE_WIN_TURNS}    Objective shifts in {bs.shift_timer} turn(s)";
if (bs.shift_warning) {
    _obj_line += "  -  SHIFTS NEXT TURN!";
}
draw_text(gw / 2, 34, _obj_line);
draw_set_halign(fa_left);

// Close button (top-right).
var _close = [gw - 130, 14, gw - 20, 50];
if (point_and_click(_close)) {
    instance_destroy();
}
draw_set_color(c_red);
draw_rectangle(_close[0], _close[1], _close[2], _close[3], true);
draw_set_halign(fa_center);
draw_text((_close[0] + _close[2]) / 2, _close[1] + 8, "CLOSE");

// Board Idlers: send this planet's idle (non-engaged) squads back to their ships.
var _board = [gw - 300, 14, gw - 145, 50];
if (point_and_click(_board)) {
    var _boarded = recall_planet_garrison(target, planet);
    refresh_available();
}
draw_set_color(c_yellow);
draw_rectangle(_board[0], _board[1], _board[2], _board[3], true);
draw_text((_board[0] + _board[2]) / 2, _board[1] + 8, "BOARD IDLERS");
draw_set_halign(fa_left);

// =======================================================================================
// Left-side buttons: each toggles a window in the bottom panel. Top button = Deploy (the squad
// picker); the rest are scaffolding placeholders. Clicking the open panel's button collapses it.
// =======================================================================================
var strip_x = 8, strip_w = 76, strip_top = 78, strip_box_h = 56, strip_gap = 6;
draw_set_halign(fa_center);
draw_set_valign(fa_middle);
for (var s = 0; s < array_length(bottom_panels); s++) {
    var _bp = bottom_panels[s];
    var _by1 = strip_top + s * (strip_box_h + strip_gap);
    var _by2 = _by1 + strip_box_h;
    if (_by2 > gh - 12) {
        break;
    }
    var _open = (bottom_panel == _bp.id);
    if (point_and_click([strip_x, _by1, strip_x + strip_w, _by2])) {
        bottom_panel = _open ? 0 : _bp.id; // toggle: click the open one again to collapse
    }
    draw_set_alpha(_open ? 0.35 : 0.15);
    draw_set_color(_open ? c_yellow : c_gray);
    draw_rectangle(strip_x, _by1, strip_x + strip_w, _by2, false);
    draw_set_alpha(1);
    draw_set_color(_open ? c_yellow : c_gray);
    draw_rectangle(strip_x, _by1, strip_x + strip_w, _by2, true);
    draw_text((strip_x + strip_x + strip_w) / 2, (_by1 + _by2) / 2, _bp.label);
}
draw_set_halign(fa_left);
draw_set_valign(fa_top);

// =======================================================================================
// Places: one full-width row each. Columns: strategy/range | add buttons | squads | place | enemy.
// =======================================================================================
var px0 = strip_x + strip_w + 14;
var pw = gw - 12 - px0;
var ptop = 70;
var pbot = floor(gh * 0.62);
var rgap = 8;
var rh = (pbot - ptop - rgap * (BATTLE_PLACES_MAX - 1)) / BATTLE_PLACES_MAX;

var cwA = pw * 0.15, cwB = pw * 0.09, cwC = pw * 0.39, cwD = pw * 0.16, cwE = pw * 0.19;
var caX = px0;
var cbX = caX + cwA + 6;
var ccX = cbX + cwB + 6;
var cdX = ccX + cwC + 6;
var ceX = cdX + cwD + 6;

for (var i = 0; i < BATTLE_PLACES_MAX; i++) {
    var py = ptop + i * (rh + rgap);
    var _place = bs.places[i];
    draw_set_halign(fa_left);

    // --- Column A: marine strategy + engagement range ---
    draw_set_color(c_dkgray);
    draw_rectangle(caX, py, caX + cwA, py + rh, true);

    // Strategy toggle cycles hold -> push -> fall back. Push closes the range, hold holds,
    // fall back opens it hard (strong negative range reduction).
    var _stance_label = "Strategy: Hold";
    var _stance_col = COL_NEUTRAL;
    if (_place.stance == "push") {
        _stance_label = "Strategy: Push";
        _stance_col = c_red;
    } else if (_place.stance == "fallback") {
        _stance_label = "Strategy: Fall Back";
        _stance_col = COL_RANGED;
    }
    var _stbtn = draw_unit_buttons([caX + 8, py + 8], _stance_label, [1, 1], _stance_col);
    if (point_and_click(_stbtn)) {
        _place.stance = next_stance(_place.stance);
    }

    // Range bar: left = long range (blue, distance 1), right = melee/close (red, distance 0).
    // White marker = current range, yellow = predicted. Note the marker maps reversed (1 - dist).
    var _bar_x1 = caX + 8, _bar_x2 = caX + cwA - 8, _bar_y = py + 42, _bar_h = 8;
    draw_rectangle_colour(_bar_x1, _bar_y, _bar_x2, _bar_y + _bar_h, COL_RANGED, COL_MELEE, COL_MELEE, COL_RANGED, false);
    var _bw = _bar_x2 - _bar_x1;
    var _now_x = _bar_x1 + (1 - clamp(_place.distance, 0, 1)) * _bw;
    draw_set_color(c_white);
    draw_line_width(_now_x, _bar_y - 3, _now_x, _bar_y + _bar_h + 3, 2);
    var _next_dist = expected_next_distance(_place);
    if (_place.marine_count() > 0 && _place.enemy_count() > 0) {
        var _next_x = _bar_x1 + (1 - clamp(_next_dist, 0, 1)) * _bw;
        draw_set_color(c_yellow);
        draw_line_width(_next_x, _bar_y - 3, _next_x, _bar_y + _bar_h + 3, 2);
    }
    draw_set_color(c_aqua);
    draw_text(caX + 8, py + 56, $"Range {string_format(_place.distance, 1, 2)} -> {string_format(_next_dist, 1, 2)}");
    // Marine effect (net per-turn range pull from this place's marines + stance).
    var _m_pull = place_marine_distance_reduction(_place) + stance_distance_bonus(_place.stance);
    draw_set_color(c_gray);
    draw_text(caX + 8, py + 76, $"Marine pull: {string_format(_m_pull, 1, 3)}");
    draw_text_ext(caX + 8, py + 94, "Effects: --", 14, cwA - 16); // scaffolding for future buffs

    // --- Column B: auto-deploy add buttons + Move/Deploy Here ---
    draw_set_color(c_dkgray);
    draw_rectangle(cbX, py, cbX + cwB, py + rh, true);
    var _b1 = draw_unit_buttons([cbX + 8, py + 8], "+", [1, 1], COL_RANGED);
    if (point_and_click(_b1)) {
        add_best_squad_to_place(i, "ranged");
    }
    var _b2 = draw_unit_buttons([_b1[2] + 4, py + 8], "+", [1, 1], COL_NEUTRAL);
    if (point_and_click(_b2)) {
        add_best_squad_to_place(i, "neutral");
    }
    var _b3 = draw_unit_buttons([_b2[2] + 4, py + 8], "+", [1, 1], COL_MELEE);
    if (point_and_click(_b3)) {
        add_best_squad_to_place(i, "melee");
    }
    draw_set_color(c_dkgray);
    draw_text(cbX + 8, py + 34, "add by role");
    if (selected_squad != "none" && selected_from_place != i) {
        var _is_move = (selected_from_place != -1);
        var _dh = draw_unit_buttons([cbX + 8, py + 54], _is_move ? "MOVE" : "DEPLOY", [1, 1], c_yellow);
        if (point_and_click(_dh)) {
            if (_is_move) {
                move_to_place(selected_squad, selected_from_place, i);
            } else {
                deploy_to(selected_squad, i);
            }
            selected_squad = "none";
            selected_from_place = -1;
        }
    }

    // --- Column C: deployed squads, grouped into ranged | neutral | melee sub-columns ---
    draw_set_color(c_dkgray);
    draw_rectangle(ccX, py, ccX + cwC, py + rh, true);
    var _mu = _place.marine_squad_uids();
    var _buckets = [[], [], []]; // 0 ranged, 1 neutral, 2 melee
    for (var m = 0; m < array_length(_mu); m++) {
        var _rr = squad_range_reduction(_mu[m]);
        var _b = (_rr > 0.01) ? 2 : ((_rr < -0.01) ? 0 : 1);
        array_push(_buckets[_b], _mu[m]);
    }
    var _subw = cwC / 3;
    for (var _col = 0; _col < 3; _col++) {
        var _sx = ccX + _col * _subw + 6;
        var _list = _buckets[_col];
        for (var r = 0; r < array_length(_list); r++) {
            var _uid = _list[r];
            var _sy2 = py + 8 + r * 22;
            if (_sy2 + 18 > py + rh) {
                break; // overflow: too many to show in this row
            }
            var _sqsel = (_uid == selected_squad && selected_from_place == i);
            var _sbtn = draw_unit_buttons([_sx, _sy2], squad_battle_label(_uid), [1, 1], _sqsel ? c_yellow : squad_range_colour(_uid));
            if (scr_hit(_sbtn[0], _sbtn[1], _sbtn[2], _sbtn[3])) {
                hovered_squad = _uid;
            }
            if (point_and_click(_sbtn)) {
                if (_sqsel) {
                    selected_squad = "none";
                    selected_from_place = -1;
                } else {
                    selected_squad = _uid;
                    selected_from_place = i;
                }
            }
        }
    }

    // --- Column D: place role + terrain / range band / effect ---
    draw_set_color(c_dkgray);
    draw_rectangle(cdX, py, cdX + cwD, py + rh, true);
    // Role: Objective (highlighted), Reinforcement (enemy entry), or Base of Operations.
    var _role_label = "Base of Operations";
    var _role_col = c_white;
    if (_place.role == PLACE_OBJECTIVE) {
        _role_label = ">> OBJECTIVE <<";
        _role_col = c_yellow;
    } else if (_place.role == PLACE_REINFORCEMENT) {
        _role_label = "Reinforcement (enemy entry)";
        _role_col = c_orange;
    }
    draw_set_color(_role_col);
    draw_text(cdX + 8, py + 8, _role_label);
    draw_set_color(c_white);
    draw_text(cdX + 8, py + 28, $"Terrain: {_place.terrain}");
    draw_text(cdX + 8, py + 48, $"Range band: {string_format(_place.min_distance, 1, 2)} - {string_format(_place.max_distance, 1, 2)}");
    draw_set_color(c_gray);
    draw_text_ext(cdX + 8, py + 76, "Effect of place: --", 16, cwD - 16); // scaffolding

    // --- Column E: enemy lineup / strategy / status (some scaffolding) ---
    draw_set_color(c_dkgray);
    draw_rectangle(ceX, py, ceX + cwE, py + rh, true);
    var _en = _place.enemy_squads();
    var _type_models = {};
    var _any_heal = false, _any_armour = false, _melee_n = 0, _ranged_n = 0;
    for (var e = 0; e < array_length(_en); e++) {
        var _tn = _en[e].unit_name;
        _type_models[$ _tn] = (variable_struct_exists(_type_models, _tn) ? _type_models[$ _tn] : 0) + _en[e].model_count();
        if (variable_struct_exists(_en[e], "healing") && _en[e].healing > 0) { _any_heal = true; }
        if (variable_struct_exists(_en[e], "damage_reduction") && _en[e].damage_reduction >= 0.3) { _any_armour = true; }
        if (_en[e].is_melee()) { _melee_n++; } else { _ranged_n++; }
    }
    draw_set_color(c_orange);
    var _ey = py + 8;
    var _tkeys = struct_get_names(_type_models);
    for (var k = 0; k < array_length(_tkeys); k++) {
        draw_text(ceX + 8, _ey, $"{_type_models[$ _tkeys[k]]} x {_tkeys[k]}");
        _ey += 18;
    }
    // Enemy strategy + status, derived from composition (scaffolding for future explicit AI state).
    draw_set_color(c_gray);
    var _estrat = (_melee_n + _ranged_n == 0) ? "--" : ((_melee_n > _ranged_n) ? "Charging" : ((_ranged_n > _melee_n) ? "Holding the line" : "Mixed advance"));
    draw_text(ceX + 8, py + rh - 40, $"Strategy: {_estrat}");
    var _estatus = "--";
    if (_any_heal && _any_armour) { _estatus = "Regenerating, Armoured"; }
    else if (_any_heal) { _estatus = "Regenerating"; }
    else if (_any_armour) { _estatus = "Armoured"; }
    draw_text_ext(ceX + 8, py + rh - 22, $"Status: {_estatus}", 16, cwE - 16);
}

// =======================================================================================
// Bottom panel: shows whichever window the left-side buttons have open (0 = collapsed).
//   Panel 1 = Deploy (squad picker + escape + hover preview). Panels 2-4 are scaffolding.
// =======================================================================================
if (bottom_panel != 0) {
    var mtop = pbot + 10;
    var mx1 = 12, mx2 = gw - 12, my2 = gh - 12;
    draw_set_color(c_dkgray);
    draw_rectangle(mx1, mtop, mx2, my2, true);

    var ay = mtop + 12;
    draw_set_halign(fa_left);

    if (bottom_panel == 1) {
        // --- Deploy window: squad picker (company -> squad), escape, hover preview ---

        // Escape the selected deployed squad (costs 1 command point).
        if (selected_from_place != -1 && selected_squad != "none") {
            var _esc = [mx2 - 220, ay - 4, mx2 - 30, ay + 22];
            if (point_and_click(_esc)) {
                if (escape_squad_from_battle(target, planet, selected_squad)) {
                    selected_squad = "none";
                    selected_from_place = -1;
                    refresh_available();
                }
            }
            draw_set_color(c_yellow);
            draw_rectangle(_esc[0], _esc[1], _esc[2], _esc[3], true);
            draw_set_halign(fa_center);
            draw_text((_esc[0] + _esc[2]) / 2, _esc[1] + 4, "Escape Squad (1 CP)");
            draw_set_halign(fa_left);
        }

        if (selected_company == -1) {
            draw_set_color(c_white);
            draw_text(mx1 + 16, ay, "Select a company / group:");
            var bx = mx1 + 16, by = ay + 26;
            for (var c = 0; c < array_length(companies_available); c++) {
                var _comp = companies_available[c];
                var _count = 0;
                for (var a = 0; a < array_length(available); a++) {
                    if (picker_group(fetch_squad(available[a]).base_company) == _comp) {
                        _count++;
                    }
                }
                var _label = (_comp == 0) ? $"HQ ({_count})" : $"{scr_convert_company_to_string(_comp)} ({_count})";
                var _btn = draw_unit_buttons([bx, by], _label, [1, 1], #50a076);
                if (point_and_click(_btn)) {
                    selected_company = _comp;
                    selected_squad = "none";
                    selected_from_place = -1;
                    clear_preview();
                }
                bx = _btn[2] + 12;
                if (bx > mx2 - 240) {
                    bx = mx1 + 16;
                    by += 30;
                }
            }
        } else {
            draw_set_color(c_white);
            var _comp_label = (selected_company == 0) ? "HQ" : scr_convert_company_to_string(selected_company);
            draw_text(mx1 + 16, ay, $"{_comp_label} - select a squad (hover to preview):");

            var _back = draw_unit_buttons([mx2 - 470, ay - 4, mx2 - 370, ay + 22], "< Groups", [1, 1], c_orange);
            if (point_and_click(_back)) {
                selected_company = -1;
                selected_squad = "none";
                clear_preview();
            }

            var bx = mx1 + 16, by = ay + 26;
            for (var a = 0; a < array_length(available); a++) {
                var _uid = available[a];
                var _sq = fetch_squad(_uid);
                if (!is_struct(_sq) || picker_group(_sq.base_company) != selected_company) {
                    continue;
                }
                var _sel = (_uid == selected_squad);
                var _btn = draw_unit_buttons([bx, by], squad_battle_label(_uid), [1, 1], _sel ? c_yellow : squad_range_colour(_uid));
                if (scr_hit(_btn[0], _btn[1], _btn[2], _btn[3])) {
                    hovered_squad = _uid;
                }
                if (point_and_click(_btn)) {
                    selected_squad = _sel ? "none" : _uid;
                    selected_from_place = -1;
                }
                bx = _btn[2] + 12;
                if (bx > mx2 - 240) {
                    bx = mx1 + 16;
                    by += 30;
                }
            }
        }

        // Rebuild the lineup preview only when the hovered squad changes.
        if (hovered_squad != "none" && hovered_squad != preview_squad) {
            build_preview(hovered_squad);
        }

        // Hover lineup preview (drawn in the bottom-right of the panel).
        if (preview_squad != "none" && array_length(preview_images) > 0) {
            var _scale = 0.45;
            var _step = 84;
            var _py = my2 - 150;
            var _pw = min(array_length(preview_images), 8) * _step + 20;
            var _px = mx2 - _pw - 16;
            draw_set_alpha(0.95);
            draw_set_color(c_black);
            draw_rectangle(_px - 6, _py - 28, _px + _pw, _py + 130, false);
            draw_set_alpha(1);
            draw_set_color(c_gray);
            var _pname = fetch_squad(preview_squad);
            draw_text(_px, _py - 24, is_struct(_pname) ? _pname.squad_name() : "");
            for (var i = 0; i < array_length(preview_images) && i < 8; i++) {
                var _ux = _px + 20 + i * _step + 200 * (1 - _scale);
                var _uy = _py + 90 * (1 - _scale);
                preview_images[i].draw(_ux, _uy, false, _scale, _scale);
            }
        }
    } else {
        // --- Scaffolding for the other windows (Orders / Intel / Log) ---
        var _plabel = "Window";
        for (var p = 0; p < array_length(bottom_panels); p++) {
            if (bottom_panels[p].id == bottom_panel) {
                _plabel = bottom_panels[p].label;
            }
        }
        draw_set_color(c_white);
        draw_text(mx1 + 16, ay, _plabel);
        draw_set_color(c_gray);
        draw_text(mx1 + 16, ay + 26, "(Not implemented yet -- scaffolding for a future window.)");
    }
}

draw_set_halign(fa_left);
draw_set_valign(fa_top);
