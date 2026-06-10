// Free any cached preview sprites (created from surfaces) before closing.
if (variable_instance_exists(id, "clear_preview")) {
    clear_preview();
}

instance_activate_object(obj_star_select);
if (variable_instance_exists(id, "prev_menu")) {
    obj_controller.menu = prev_menu;
}
obj_controller.cooldown = 10;
