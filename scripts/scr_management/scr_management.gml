function scr_management(argument0) {
    // argument0        1: overview         10+: that chapter -10
    // Creates the company blocks in the main management screen and assigns text to them

    // Variable creation
    var num = 0, nam = "", company = 50, q = 0;
    var romanNumerals = scr_roman_numerals();
    var chapter_name = global.chapter_name;
    var role_names = obj_ini.role[100];
    var unit;

    if (argument0 == 1) {
        with (obj_managment_panel) {
            instance_destroy();
        }

        var pane;

        // Each institution is its own storage group now, so a panel simply lists that group's
        // members (its master + free specialists) -- no by-role aggregation across companies.
        pane = instance_create(475, 180 - 48, obj_managment_panel);
        pane.company = GROUP_RECLUSIUM;
        pane.manage = 14;
        pane.header = 2;
        pane.title = "RECLUSIUM";
        var _reclusium_units = collect_company(GROUP_RECLUSIUM).index_roles();
        pane.line = array_join(pane.line, _reclusium_units.create_plural_strings_array());

        pane = instance_create(275, 180 - 48, obj_managment_panel);
        pane.company = GROUP_APOTHECARIUM;
        pane.manage = 12;
        pane.header = 2;
        pane.title = "APOTHECARIUM";
        var _apothecary_units = collect_company(GROUP_APOTHECARIUM).index_roles();
        pane.line = array_join(pane.line, _apothecary_units.create_plural_strings_array());

        pane = instance_create(925, 180 - 48, obj_managment_panel);
        pane.company = GROUP_ARMOURY;
        pane.manage = 15;
        pane.header = 2;
        pane.title = "ARMOURY";
        var _armoury_units = collect_company(GROUP_ARMOURY).index_roles();
        pane.line = array_join(pane.line, _armoury_units.create_plural_strings_array());

        pane = instance_create(1125, 180 - 48, obj_managment_panel);
        pane.company = GROUP_LIBRARIUM;
        pane.manage = 13;
        pane.header = 2;
        pane.title = "LIBRARIUM";
        var _lib_units = collect_company(GROUP_LIBRARIUM).index_roles();
        pane.line = array_join(pane.line, _lib_units.create_plural_strings_array());

        pane = instance_create(700, 180 - 48, obj_managment_panel);
        pane.company = 0;
        pane.manage = 11;
        pane.header = 3;
        pane.title = "HEADQUARTERS";
        var _command_units = collect_company(0).index_roles();
        pane.line = array_join(pane.line, _command_units.create_plural_strings_array());

        // Coordinates declaration and text initiation
        var xx = 25, yy = 400 - 48, t;

        // Creates the first 10 companies using roman numerals
        for (var company = 1; company <= 10; company++) {
            t = string_upper(scr_convert_company_to_string(company));

            var pane = instance_create(xx, yy, obj_managment_panel);
            pane.company = company;
            pane.manage = company;
            pane.header = 1;
            pane.title = t;

            var _company_group = collect_company(company).index_roles();

            pane.line = array_join(pane.line, _company_group.create_plural_strings_array());

            var num = array_create(5, 0);
            var nam = [
                "Land Raider",
                "Predator",
                "Rhino",
                "Land Speeder",
                "Whirlwind"
            ];
            // Vehicles
            for (var i = 0; i < array_length(obj_ini.veh_role[company]); i++) {
                for (var s = 0; s < array_length(nam); s++) {
                    if (obj_ini.veh_role[company][i] == nam[s]) {
                        num[s]++;
                    }
                }
            }

            for (var d = 0; d < 5; d++) {
                if (num[d] > 0) {
                    if (d == 1) {
                        array_push(pane.line, {str1: nam[d], bold: true, italic: false});
                        // obj_managment_panel.italic[q] = 1;
                    } else {
                        array_push(pane.line, nam[d], string_plural_count(nam[d], num[d], false));
                    }
                }
            }
            xx += 156;
        }
    }
}
