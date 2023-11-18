/*
 * This file is part of budgie-desktop
 *
 * Copyright Budgie Desktop Developers
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 */

public class IconButton : Gtk.ToggleButton {
	private const double DEFAULT_OPACITY = 0.1;

	private const int INDICATOR_PADDING = 2;
	private const int INDICATOR_SIZE = 2;
	private const int INDICATOR_SPACING = 1;
	private const int INACTIVE_INDICATOR_SPACING = 4;

	private const int DEFAULT_ICON_SIZE = 32;
	private const int TARGET_ICON_PADDING = 18;
	private const double TARGET_ICON_SCALE = 2.0 / 3.0;
	private const int FORMULA_SWAP_POINT = TARGET_ICON_PADDING * 3;

	private const int64 SCROLL_TIMEOUT = 300000;

	public Budgie.Application app { get; construct; }
	public unowned Budgie.PopoverManager popover_manager { get; construct; }
	public bool pinned { get; set; default = false; }

	private Budgie.Windowing.WindowGroup? window_group = null;

	private Icon? icon;
	private ButtonPopover? popover;

	private Gtk.Allocation definite_allocation;
	private int target_icon_size = 0;
	private int panel_size = 0;
	private Budgie.PanelPosition panel_position;

	private Gtk.Orientation orientation;

	private bool has_active_window = false;
	private int64 last_scroll_time = 0;
	private bool needs_attention = false;

	public IconButton(Budgie.Application app, Budgie.PopoverManager popover_manager) {
		Object(
			app: app,
			popover_manager: popover_manager,
			relief: Gtk.ReliefStyle.NONE
		);
	}

	public IconButton.with_group(Budgie.Application app, Budgie.Windowing.WindowGroup window_group, Budgie.PopoverManager popover_manager) {
		Object(
			app: app,
			popover_manager: popover_manager,
			relief: Gtk.ReliefStyle.NONE
		);

		set_window_group(window_group);
	}

	construct {
		get_style_context().remove_class(Gtk.STYLE_CLASS_BUTTON);
		get_style_context().remove_class("toggle");
		get_style_context().add_class("launcher");

		add_events(Gdk.EventMask.SCROLL_MASK);

		definite_allocation.width = 0;
		definite_allocation.height = 0;

		icon = new Icon();

		icon.get_style_context().add_class("icon");

		popover = new ButtonPopover(this, app, window_group);

		popover.bind_property("pinned", this, "pinned", BindingFlags.BIDIRECTIONAL);

		// TODO: connect signals

		if (app != null) {
			app.launch_failed.connect_after(() => {
				icon.waiting = false;
			});
		}

		popover_manager.register_popover(this, popover);

		add(icon);

		size_allocate.connect(on_size_allocate);
	}

	private void on_size_allocate(Gtk.Allocation allocation) {
		if (definite_allocation != allocation) {
			int max = (int) Math.fmin(allocation.width, allocation.height);

			if (max > FORMULA_SWAP_POINT) {
				target_icon_size = max - TARGET_ICON_PADDING;
			} else {
				target_icon_size = (int) Math.round(TARGET_ICON_SCALE * max);
			}

			update_icon();
		}

		definite_allocation = allocation;
		base.size_allocate(definite_allocation);

		// If this button has active windows, set their button geometry
		if (window_group != null && window_group.has_windows()) {
			foreach (var win in window_group.get_windows()) {
				try {
					set_window_button_geometry(win);
				} catch (Error e) {
					warning("Unable to set button geometry for window %s: %s", win.get_name(), e.message);
				}
			}
		}
	}

	/**
	 * Sets the button geometry for a window.
	 *
	 * What this means is that when a window is minimized, it will minimize to
	 * the icon button's location on the screen.
	 *
	 * Throws: if the button geometry could not be set
	 */
	private void set_window_button_geometry(libxfce4windowing.Window window) throws Error {
		int x, y;
		var toplevel = get_toplevel();

		if (toplevel == null || toplevel.get_window() == null) return;

		translate_coordinates(toplevel, 0, 0, out x, out y);
		toplevel.get_window().get_root_coords(x, y, out x, out y);

		Gdk.Rectangle rect = {
			x,
			y,
			definite_allocation.width,
			definite_allocation.height
		};

		window.set_button_geometry(toplevel.get_window(), rect);
	}

	public override bool button_release_event(Gdk.EventButton event) {
		switch (event.button) {
			case Gdk.BUTTON_PRIMARY:
				if (window_group != null) {
					if (has_active_window) {
						var window = window_group.get_active_window();

						try {
							window.set_minimized(!window.is_minimized());
						} catch (Error e) {
							warning("Unable to set minimized state of window %s: %s", window.get_name(), e.message);
						}
					} else {
						var window = window_group.get_last_active_window();

						try {
							window.activate(event.time);
						} catch (Error e) {
							warning("Unable to activate window %s: %s", window.get_name(), e.message);
						}
					}
				} else {
					if (!pinned) {
						warning("IconButton was clicked with no active windows, but is not pinned!");
						return Gdk.EVENT_STOP;
					}

					icon.animate_launch(panel_position);
					icon.waiting = true;
					icon.animate_wait();

					if (!app.launch()) {
						warning("Failed to launch application: %s", app.name);
						return Gdk.EVENT_STOP;
					}
				}
				return Gdk.EVENT_STOP;
			case Gdk.BUTTON_SECONDARY:
				popover_manager.show_popover(this);
				return Gdk.EVENT_STOP;
		}

		return Gdk.EVENT_PROPAGATE;
	}

	public override bool scroll_event(Gdk.EventScroll event) {
		if (get_monotonic_time() - last_scroll_time < SCROLL_TIMEOUT) {
			return Gdk.EVENT_STOP;
		}

		// Nothing to do if there are no open windows
		if (window_group == null) {
			return Gdk.EVENT_STOP;
		}

		unowned libxfce4windowing.Window target_window = null;

		// Get the currently active window in the group
		unowned var active_window = window_group.get_active_window();

		// If there is no currently active window, get the last active window
		if (active_window == null) {
			active_window = window_group.get_last_active_window();
		}

		switch (event.direction) {
			case Gdk.ScrollDirection.UP:
				// Get the next window in the group to activate
				target_window = window_group.get_next_window(active_window);

				// Attempt to activate the target window
				try {
					target_window.activate(event.time);
				} catch (Error e) {
					warning("Error activating and unminimizing window '%s': %s", target_window.get_name(), e.message);
				}

				break;
			case Gdk.ScrollDirection.DOWN:
				// Make the target window the last active window
				target_window = active_window;

				if (target_window == null) {
					break;
				}

				// Break if already minimized to avoid unnecessary logging
				if (target_window.is_minimized()) {
					break;
				}

				// Attempt to minimize the target window
				try {
					target_window.set_minimized(true);
				} catch (Error e) {
					warning("Error minimizing window '%s': %s", target_window.get_name(), e.message);
				}
				break;
			default:
				break;
		}

		last_scroll_time = get_monotonic_time();

		return Gdk.EVENT_STOP;
	}

	public override bool draw(Cairo.Context ctx) {
		int x = definite_allocation.x;
		int y = definite_allocation.y;
		int width = definite_allocation.width;
		int height = definite_allocation.height;

		List<unowned libxfce4windowing.Window> windows;

		// Get the windows in this group, if any
		if (window_group != null && window_group.has_windows()) {
			windows = window_group.get_windows();
		} else {
			windows = new List<unowned libxfce4windowing.Window>();
		}

		// No indicators if there are no windows
		if (windows.is_empty()) {
			return base.draw(ctx);
		}

		// If this button does not have any focused windows,
		// draw the inactive versions of the window indicators
		if (!get_active()) {
			return draw_inactive(ctx);
		}

		int count = int.min((int) windows.length(), 5);

		// Calculate the spacing between individual indicators
		int spacing = width % count;
		spacing = (spacing == 0) ? INDICATOR_SPACING : spacing;

		int previous_x = 0;
		int previous_y = 0;

		// Draw an indicator for each window
		for (int i = 0; i < count; i++) {
			// Get the window
			var window = windows.nth_data(i);

			// No indicator for skippers
			if (window.is_skip_tasklist()) continue;

			// Set the inital position of our window indicators to 0,0
			int indicator_x = 0;
			int indicator_y = 0;
			int length = 0;

			// Calculate the length of the indicator
			switch (panel_position) {
				case Budgie.PanelPosition.LEFT:
				case Budgie.PanelPosition.RIGHT:
					length = (height / count);
					break;
				default:
					length = (width / count);
					break;
			}

			// Calculate the starting x coord
			switch (panel_position) {
				case Budgie.PanelPosition.LEFT:
					indicator_x = x + INDICATOR_PADDING; // Set x to just off the left of the button
					break;
				case Budgie.PanelPosition.RIGHT:
					indicator_x = x + width - INDICATOR_PADDING; // Set x to just off the right of the button
					break;
				case Budgie.PanelPosition.TOP:
				case Budgie.PanelPosition.BOTTOM:
					if (i == 0) { // First indicator
						indicator_x = x; // Set x to the starting x of the button
					} else { // Not the first indicator
						indicator_x = previous_x; // Set x to the x coord of the previous indicator
						indicator_x += length; // Add the length of the indicator to the x coord
						previous_x = indicator_x; // Set the new x to the previous x
						indicator_x += spacing; // Add the spacing to the x coord
					}
					break;
				default:
					break;
			}

			// Calculate the starting y coord
			switch (panel_position) {
				case Budgie.PanelPosition.LEFT:
				case Budgie.PanelPosition.RIGHT:
					if (i == 0) { // First indicator
						indicator_y = y; // Set y to the starting y of the button
					} else { // Not the first indicator
						indicator_y = previous_y; // Set y to the y coord of the previous indicator
						indicator_y += length; // Add the indicator length to the y coord
						previous_y = indicator_y; // Set the new y to the previous y
						indicator_y += spacing; // Add the spacing to the y coord						
					}
					break;
				case Budgie.PanelPosition.TOP:
					indicator_y = y + INDICATOR_PADDING; // Set the y coord to just off the top of the button
					break;
				case Budgie.PanelPosition.BOTTOM:
					indicator_y = y + height - INDICATOR_PADDING; // Set the y coord to just off the bottom of the button
					break;
				default:
					break;
			}

			// Set the color of the indicator
			Gdk.RGBA color;

			if (has_active_window && window == window_group.get_active_window()) {
				if (!get_style_context().lookup_color("budgie_tasklist_indicator_color_active_window", out color)) {
					color.parse("#6BBFFF");
				}
			} else if (needs_attention) {
				if (!get_style_context().lookup_color("budgie_tasklist_indicator_color_attention", out color)) {
					color.parse("#D84E4E");
				}
			} else {
				if (!get_style_context().lookup_color("budgie_tasklist_indicator_color_active", out color)) {
					color.parse("#5294E2");
				}
			}

			ctx.set_source_rgba(color.red, color.green, color.blue, 1);

			// Set the indicator thickness
			ctx.set_line_width(INDICATOR_SIZE + 1);

			// Move to the start coords
			ctx.move_to(indicator_x, indicator_y);

			// Calculate the ending x or y coord and set the line to be drawn
			int to = 0;
			switch (panel_position) {
				case Budgie.PanelPosition.LEFT:
				case Budgie.PanelPosition.RIGHT:
					if (i == count - 1) { // Last indicator
						to = y + height; // Set 'to' to the end of the button
					} else { // Not the last indicator
						to = previous_y; // Set 'to' to the y of the previous indicator
						to += length; // Add the indicator length to the end location
					}

					// Draw a line from the start down to the end
					ctx.line_to(indicator_y, to);
					break;
				default:
					if (i == count - 1) { // Last indicator
						to = x + width; // Set 'to' to the end of the button
					} else { // Not the last indicator
						to = previous_x; // Set 'to' to the y of the previous indicator
						to += length; // Add the indicator length to the end location
					}

					// Draw a line from the start right to the end
					ctx.line_to(to, indicator_y);
					break;
			}

			// Draw the indicator
			ctx.stroke();
		}

		return base.draw(ctx);
	}

	public bool draw_inactive(Cairo.Context ctx) {
		int x = definite_allocation.x;
		int y = definite_allocation.y;
		int width = definite_allocation.width;
		int height = definite_allocation.height;

		List<unowned libxfce4windowing.Window> windows;

		// Get the windows in this group, if any
		if (window_group != null && window_group.has_windows()) {
			windows = window_group.get_windows();
		} else {
			windows = new List<unowned libxfce4windowing.Window>();
		}

		// No windows, no indicators
		if (windows.is_empty()) {
			return base.draw(ctx);
		}

		int count = int.min((int) windows.length(), 5);

		// Iterate over the number of windows
		for (int i = 0; i < count; i++) {
			var window = windows.nth_data(i);

			// No indicators for skippers!
			if (window.is_skip_tasklist()) continue;

			// Initialize our x,y coords
			int indicator_x = 0;
			int indicator_y = 0;

			// Calculate the x coord
			switch (panel_position) {
				case Budgie.PanelPosition.TOP:
				case Budgie.PanelPosition.BOTTOM:
					indicator_x = x + (width / 2);
					indicator_x -= ((count * (INDICATOR_SIZE + INACTIVE_INDICATOR_SPACING)) / 2) - INACTIVE_INDICATOR_SPACING;
					indicator_x += ((INDICATOR_SIZE + INACTIVE_INDICATOR_SPACING) * i) - 1;
					break;
				case Budgie.PanelPosition.LEFT:
					indicator_x = y + (INDICATOR_SIZE / 2) - INDICATOR_PADDING;
					break;
				case Budgie.PanelPosition.RIGHT:
					indicator_x = y + width - (INDICATOR_SIZE / 2) + INDICATOR_PADDING;
					break;
				default:
					break;
			}

			// Calculate the y coord
			switch (panel_position) {
				case Budgie.PanelPosition.TOP:
					indicator_y = y + (INDICATOR_SIZE / 2) + INDICATOR_PADDING;
					break;
				case Budgie.PanelPosition.BOTTOM:
					indicator_y = y + height - (INDICATOR_SIZE / 2) - INDICATOR_PADDING;
					break;
				case Budgie.PanelPosition.LEFT:
					indicator_y = x + (height / 2);
					indicator_y -= ((count * (INDICATOR_SIZE + INACTIVE_INDICATOR_SPACING)) / 2) - (INACTIVE_INDICATOR_SPACING * 2);
					indicator_y += (((INDICATOR_SIZE) + INACTIVE_INDICATOR_SPACING) * i);
					break;
				case Budgie.PanelPosition.RIGHT:
					indicator_y = x + (height / 2);
					indicator_y -= ((count * (INDICATOR_SIZE + INACTIVE_INDICATOR_SPACING)) / 2) - INACTIVE_INDICATOR_SPACING;
					indicator_y += ((INDICATOR_SIZE + INACTIVE_INDICATOR_SPACING) * i);
					break;
				default:
					break;
			}

			// Set the color of the indicator
			Gdk.RGBA color;

			if (!get_style_context().lookup_color("budgie_tasklist_indicator_color", out color)) {
				color.parse("#3C6DA6");
			}

			ctx.set_source_rgba(color.red, color.green, color.blue, 1);

			// Create a circle at the coords for the indicator
			ctx.arc(indicator_x, indicator_y, INDICATOR_SIZE, 0, Math.PI * 2);

			// Fill it with color
			ctx.fill();
		}

		return base.draw(ctx);
	}

	public override void get_preferred_width(out int min, out int nat) {
		if (orientation == Gtk.Orientation.HORIZONTAL) {
			min = nat = panel_size;
		} else {
			int m, n;
			base.get_preferred_width(out m, out n);
			min = m;
			nat = n;
		}
	}

	public override void get_preferred_height(out int min, out int nat) {
		if (orientation == Gtk.Orientation.VERTICAL) {
			min = nat = panel_size;
		} else {
			int m, n;
			base.get_preferred_height(out m, out n);
			min = m;
			nat = n;
		}
	}

	public bool has_window(libxfce4windowing.Window window) {
		return window_group != null && window_group.has_window(window);
	}

	public Icon? get_icon() {
		return icon;
	}

	public void set_active_window(bool active) {
		has_active_window = active;
	}

	public void set_icon_size(int size) {
		target_icon_size = size;
	}

	public void set_orientation(Gtk.Orientation orientation) {
		this.orientation = orientation;
	}

	public void set_panel_size(int size) {
		panel_size = size;
	}

	public void set_panel_position(Budgie.PanelPosition position) {
		panel_position = position;
	}

	public Budgie.Windowing.WindowGroup? get_window_group() {
		return window_group;
	}

	public void set_window_group(Budgie.Windowing.WindowGroup? window_group) {
		this.window_group = window_group;
		popover.group = window_group;

		if (window_group == null) return;

		foreach (var window in window_group.get_windows()) {
			popover.add_window(window);
		}

		window_group.app_icon_changed.connect_after(() => {
			update_icon();
		});

		window_group.window_added.connect((window) => {
			var id = window.get_id();
			var name = window.get_name() ?? "Loading...";

			popover.add_window(window);

			update();
		});

		window_group.window_removed.connect((window) => {
			popover.remove_window(window);

			update();
		});
	}

	public void update() {
		if (window_group != null && window_group.has_windows()) {
			get_style_context().add_class("running");
		} else {
			get_style_context().remove_class("running");

			if (pinned) {
				window_group = null;
			} else {
				return;
			}
		}

		set_active(has_active_window);

		update_icon();
		queue_resize();
	}

	public void update_icon() {
		if (window_group != null && window_group.has_windows()) {
			icon.waiting = false;
		}

		unowned GLib.Icon? app_icon = app.icon;
		Gdk.Pixbuf? pixbuf_icon = null;

		if (window_group != null) {
			var size = target_icon_size == 0 ? DEFAULT_ICON_SIZE : target_icon_size;
			pixbuf_icon = window_group.get_icon(size, 1);
		}

		if (app_icon != null) {
			icon.set_from_gicon(app_icon, Gtk.IconSize.INVALID);
		} else if (pixbuf_icon != null) {
			icon.set_from_pixbuf(pixbuf_icon);
		} else {
			icon.set_from_icon_name("image-missing", Gtk.IconSize.INVALID);
		}

		if (target_icon_size > 0) {
			icon.pixel_size = target_icon_size;
		} else {
			// prevents apps making the panel massive when the icon initially gets added
			icon.pixel_size = DEFAULT_ICON_SIZE;
		}
	}
}
