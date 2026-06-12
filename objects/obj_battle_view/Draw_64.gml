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

// Columns: A strategy/range | B add/deploy buttons | D place info | battlefield (marines vs enemies).
var cwA = pw * 0.15, cwB = pw * 0.09, cwD = pw * 0.16;
var caX = px0;
var cbX = caX + cwA + 6;
var cdX = cbX + cwB + 6;
var bfX = cdX + cwD + 6;        // battlefield: marines on the left, enemies on the right
var bfW = (px0 + pw) - bfX;

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

    // --- Battlefield: marine squads on the LEFT (ranged at the back, melee at the front), enemy
    //     squads on the RIGHT as yellow circles. The enemy line sits closer to the marine line the
    //     shorter the engagement range, and pulls back as the range opens. ---
    draw_set_color(c_dkgray);
    draw_rectangle(bfX, py, bfX + bfW, py + rh, true);
    var _lane_y = py + 26;        // vertical centre of the dot line
    var _range_frac = clamp(_place.distance, 0, 1); // 1 = long range (enemies far), 0 = melee (enemies close)

    // Marines: order ranged -> neutral -> melee so ranged sit behind (left) and melee lead (right).
    var _mu = _place.marine_squad_uids();
    var _ranged_list = [], _neutral_list = [], _melee_list = [];
    for (var m = 0; m < array_length(_mu); m++) {
        var _rr = squad_range_reduction(_mu[m]);
        if (_rr < -0.01)      { array_push(_ranged_list, _mu[m]); }
        else if (_rr > 0.01)  { array_push(_melee_list, _mu[m]); }
        else                  { array_push(_neutral_list, _mu[m]); }
    }
    var _ordered = [];
    array_copy(_ordered, 0, _ranged_list, 0, array_length(_ranged_list));
    array_copy(_ordered, array_length(_ordered), _neutral_list, 0, array_length(_neutral_list));
    array_copy(_ordered, array_length(_ordered), _melee_list, 0, array_length(_melee_list));

    var _mr = 9, _mstep_x = 26, _mstep_y = 36;
    var _m_zone_w = bfW * 0.42;                          // marines occupy the left ~40%
    var _m_cols = max(1, floor(_m_zone_w / _mstep_x));
    var _marine_right = bfX + 14;                        // tracks the front (rightmost) marine edge
    var _m_shown = 0;
    for (var m = 0; m < array_length(_ordered); m++) {
        var _uid = _ordered[m];
        var _cx = bfX + 16 + (m mod _m_cols) * _mstep_x;
        var _cy = _lane_y + (m div _m_cols) * _mstep_y;
        // Overflow guard: leave room for the circle, its member strip, and the enemy text band.
        if (_cy + _mr + 24 > py + rh - 54) { break; }
        _m_shown++;
        _marine_right = max(_marine_right, _cx + _mr);
        var _sqsel = (_uid == selected_squad && selected_from_place == i);
        draw_set_color(_sqsel ? c_yellow : squad_range_colour(_uid));
        draw_circle(_cx, _cy, _mr, false);
        draw_set_color(c_black);
        draw_circle(_cx, _cy, _mr, true);
        if (squad_gives_command_bonus(_uid)) {
            draw_set_color(c_white);
            draw_circle(_cx, _cy, _mr - 3, true);
        }
        // Company sign just above the circle (HQ / Roman company numeral / institution initial).
        draw_set_font(fnt_40k_10);
        draw_set_halign(fa_center);
        draw_set_valign(fa_bottom);
        draw_set_color(c_white);
        draw_text(_cx, _cy - _mr - 1, squad_company_tag(_uid));
        // A few representative members beneath the circle: sergeant (white, "S"), the attached
        // specialist if any (gold, role initial), and one regular (orange "H" if it carries the
        // squad's heavy ranged weapon, otherwise grey "T").
        var _picks = squad_roster_picks(_uid);
        var _np = array_length(_picks);
        var _chip_r = 3, _chip_gap = 9;
        var _chip_x0 = _cx - ((_np - 1) * _chip_gap) * 0.5;
        var _chip_y = _cy + _mr + 6;
        draw_set_valign(fa_top);
        for (var p = 0; p < _np; p++) {
            var _pk = _picks[p];
            var _ccol = c_white;
            var _glyph = "S";
            if (_pk.kind == "specialist") {
                _ccol = c_yellow;
                _glyph = string_char_at(_pk.unit.role(), 1);
            } else if (_pk.kind == "regular") {
                _ccol = _pk.heavy ? c_orange : make_colour_rgb(160, 160, 160);
                _glyph = _pk.heavy ? "H" : "T";
            }
            var _chx = _chip_x0 + p * _chip_gap;
            draw_set_color(_ccol);
            draw_circle(_chx, _chip_y, _chip_r, false);
            draw_set_color(c_black);
            draw_circle(_chx, _chip_y, _chip_r, true);
            draw_set_color(_ccol);
            draw_text(_chx, _chip_y + _chip_r + 5, _glyph); // sits clear below the chip
        }
        draw_set_font(fnt_40k_14b);
        draw_set_halign(fa_left);
        draw_set_valign(fa_top);
        var _hit = [_cx - _mr, _cy - _mr, _cx + _mr, _cy + _mr];
        if (scr_hit(_hit[0], _hit[1], _hit[2], _hit[3])) {
            hovered_squad = _uid;
        }
        if (point_and_click(_hit)) {
            if (_sqsel) { selected_squad = "none"; selected_from_place = -1; }
            else { selected_squad = _uid; selected_from_place = i; }
        }
    }
    // Note any marine squads that didn't fit the battlefield row(s). Sits in the gap to the
    // right of the marine block so it never collides with the company signs above the circles.
    if (_m_shown < array_length(_ordered)) {
        draw_set_color(c_gray);
        draw_set_halign(fa_left);
        draw_text(bfX + _m_zone_w + 6, py + 8, $"+{array_length(_ordered) - _m_shown} more squads");
    }

    // Enemies: gather composition + per-type counts for the breakdown line.
    var _en = _place.enemy_squads();
    var _ecount = array_length(_en);
    var _type_models = {};
    var _any_heal = false, _any_armour = false, _melee_n = 0, _ranged_n = 0, _total_models = 0;
    for (var e = 0; e < _ecount; e++) {
        var _tn = _en[e].unit_name;
        _type_models[$ _tn] = (variable_struct_exists(_type_models, _tn) ? _type_models[$ _tn] : 0) + _en[e].model_count();
        _total_models += _en[e].model_count();
        if (variable_struct_exists(_en[e], "healing") && _en[e].healing > 0) { _any_heal = true; }
        if (variable_struct_exists(_en[e], "damage_reduction") && _en[e].damage_reduction >= 0.3) { _any_armour = true; }
        if (_en[e].is_melee()) { _melee_n++; } else { _ranged_n++; }
    }
    // Enemy line: as range closes (_close -> 1), the block slides left toward the marine front.
    var _er = 7, _estep = 18;
    var _e_block_w = bfW * 0.34;
    var _e_cols = max(1, floor(_e_block_w / _estep));
    var _e_min_left = _marine_right + 18;                       // melee contact
    var _e_max_left = bfX + bfW - _e_block_w - 8;               // long range (far right)
    var _e_left = _e_min_left + _range_frac * max(0, _e_max_left - _e_min_left);
    if (_e_left > _e_max_left) { _e_left = max(_e_min_left, _e_max_left); }
    var _e_max_rows = 3;
    var _eshown = 0;
    for (var e = 0; e < _ecount; e++) {
        var _erow = _eshown div _e_cols;
        if (_erow >= _e_max_rows) { break; }
        var _ecx = _e_left + (_eshown mod _e_cols) * _estep;
        var _ecy = _lane_y + _erow * _estep;
        // Shape encodes the squad's nature by tag: flyers/cavalry -> triangle, vehicles (that are
        // neither) -> square, everything else -> circle. Monstrous units draw larger; command
        // units get a red outline.
        var _es = _en[e];
        var _r = _es.has_tag(eENEMY_TAG.MONSTROUS) ? (_er + 4) : _er;
        var _outline = _es.has_tag(eENEMY_TAG.COMMAND) ? c_red : c_black;
        if (_es.has_tag(eENEMY_TAG.FLYER) || _es.has_tag(eENEMY_TAG.CAVALRY)) {
            // equilateral triangle (point up), vertices on a circle of radius _r
            var _tx1 = _ecx + lengthdir_x(_r, 90),  _ty1 = _ecy + lengthdir_y(_r, 90);
            var _tx2 = _ecx + lengthdir_x(_r, 210), _ty2 = _ecy + lengthdir_y(_r, 210);
            var _tx3 = _ecx + lengthdir_x(_r, 330), _ty3 = _ecy + lengthdir_y(_r, 330);
            draw_set_color(c_yellow);
            draw_triangle(_tx1, _ty1, _tx2, _ty2, _tx3, _ty3, false);
            draw_set_color(_outline);
            draw_triangle(_tx1, _ty1, _tx2, _ty2, _tx3, _ty3, true);
        } else if (_es.has_tag(eENEMY_TAG.VEHICLE)) {
            draw_set_color(c_yellow);
            draw_rectangle(_ecx - _r, _ecy - _r, _ecx + _r, _ecy + _r, false);
            draw_set_color(_outline);
            draw_rectangle(_ecx - _r, _ecy - _r, _ecx + _r, _ecy + _r, true);
        } else {
            draw_set_color(c_yellow);
            draw_circle(_ecx, _ecy, _r, false);
            draw_set_color(_outline);
            draw_circle(_ecx, _ecy, _r, true);
        }
        _eshown++;
    }

    // Enemy breakdown + count, then strategy/status, along the bottom of the battlefield.
    var _tkeys = struct_get_names(_type_models);
    var _breakdown = "";
    for (var k = 0; k < array_length(_tkeys); k++) {
        _breakdown += (k > 0 ? ", " : "") + $"{_type_models[$ _tkeys[k]]}x {_tkeys[k]}";
    }
    draw_set_color(c_orange);
    if (_ecount > 0) {
        var _more = (_eshown < _ecount) ? $" (+{_ecount - _eshown} more squads)" : "";
        draw_text(bfX + 10, py + rh - 54, $"Enemy: {_ecount} squads, {_total_models} models{_more}");
        draw_text_ext(bfX + 10, py + rh - 38, _breakdown, 16, bfW - 20);
    }
    draw_set_color(c_gray);
    var _estrat = (_melee_n + _ranged_n == 0) ? "--" : ((_melee_n > _ranged_n) ? "Charging" : ((_ranged_n > _melee_n) ? "Holding the line" : "Mixed advance"));
    var _estatus = "";
    if (_any_heal && _any_armour) { _estatus = " | Regenerating, Armoured"; }
    else if (_any_heal) { _estatus = " | Regenerating"; }
    else if (_any_armour) { _estatus = " | Armoured"; }
    if (_ecount > 0) {
        draw_text(bfX + 10, py + rh - 18, $"Strategy: {_estrat}{_estatus}");
    }
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
