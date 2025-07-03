local M = {}

-- TODO: add way to refresh the recently changed values
-- TODO: make search better and option to make it into pages you can scroll through
-- TODO: make better rendering functions
-- TODO: make footer look better
-- TODO: maybe make all go commands async

local state = {
	floats = {},
	curr_float = {},
	view_floats = {},
	footer_ns = vim.api.nvim_create_namespace("footer_namespace"),
	last_search_query = "",
	search_offset = 0,
}

local skip_win_close = false

local autocmds = {}

local check_win_in_list = function(winId)
	for _, float in pairs(state.floats) do
		if float.win == winId then
			return true
		end
	end
	for _, float in pairs(state.view_floats) do
		if float.win == winId then
			return true
		end
	end
end

local add_close_window_autocmd = function(buff_id)
	if autocmds[buff_id] ~= nil then
		return
	end

	autocmds[buff_id] = vim.api.nvim_create_autocmd("WinClosed", {
		buffer = buff_id,
		callback = function(args)
			local winId = tonumber(args.match)
			if not check_win_in_list(winId) then
				return
			end
			if skip_win_close then
				skip_win_close = false
				return
			end
			M.close_rfc()
		end,
	})
end

local create_window_configurations = function()
	local width = vim.o.columns
	local height = vim.o.lines

	local header_height = 1 -- 1 + border
	local footer_height = 1 -- 1 + border
	local body_height = height - header_height - footer_height - 2 - 1 -- for our own border

	return {
		search = {
			relative = "editor",
			width = width - 16,
			height = header_height,
			style = "minimal",
			border = "rounded",
			col = 8,
			row = 0,
			zindex = 2,
		},
		view = {
			relative = "editor",
			width = width - 16,
			height = body_height - 2 - 1,
			style = "minimal",
			border = { " ", " ", " ", " ", " ", " ", " ", " " },
			col = 8,
			row = header_height + 2,
			zindex = 1,
		},
		footer = {
			relative = "editor",
			width = width - 16,
			height = footer_height,
			style = "minimal",
			border = { " ", " ", " ", " ", " ", " ", " ", " " },
			col = 8,
			row = header_height + body_height,
			zindex = 2,
		},
	}
end

local delete_buffers_when_closing = false

local footer_default_data = {
	curr_view = { key = "no view", prefix = "Current view: ", show_fully = false },
	curr_float = { key = "no float", prefix = "Current float: ", show_fully = true },
	status = { key = "no status", prefix = "Status: ", show_fully = true },
}

local footer_default_order = { "curr_view", "curr_float", "status" }

local data = {
	list_data = {},
	curr_view = "__NONE__",
	search_data = { "nothing to search" },
	fetching_view_data = {},
	footer_data = {},
}

local is_searching = false
local is_downloading = false
local is_downloading_all = false
local window_config = create_window_configurations()

local original_mappings = {}

local default_keys = {
	view = "m",
	list = "n",
	search = "b",
	search_header = "v",
	select = "<CR>",
	add_to_view = "s",
	delete = "d",
	refresh = "r",
	hard_refresh = "R",
	delete_all = "D",
	view_list = "z",
	next_search = "ns",
}

local config_keys = {}

local function store_original_mappings()
	original_mappings = {}
	for _, map in ipairs(vim.api.nvim_get_keymap("n")) do
		if vim.tbl_contains(config_keys, map.lhs) then
			original_mappings[map.lhs] = map
		end
	end
end

local function restore_original_mappings()
	for _, key in pairs(config_keys) do
		local map = original_mappings[key]

		if not map then
			pcall(vim.keymap.del, "n", key)
		else
			local rhs = map.callback or map.rhs
			local opts = {
				noremap = map.noremap,
				silent = map.silent == 1,
				expr = map.expr == 1,
				nowait = map.nowait == 1,
			}

			vim.keymap.set("n", key, rhs, opts)
		end
	end
end

local foreach_float = function(cb)
	for name, float in pairs(state.floats) do
		cb(name, float)
	end
	for name, float in pairs(state.view_floats) do
		cb(name, float)
	end
end

local function create_floating_window(config, enter, buf, is_scratch, readonly, modifiable, name)
	if readonly == nil then
		readonly = false
	end
	if modifiable == nil then
		modifiable = true
	end
	if enter == nil then
		enter = false
	end
	config = config
		or {
			relative = "editor",
			width = 80,
			height = 20,
			row = 5,
			col = 5,
			style = "minimal",
			border = "rounded",
		}

	buf = buf or vim.api.nvim_create_buf(false, is_scratch or true) -- No file, scratch buffer
	local win = vim.api.nvim_open_win(buf, enter, config)

	if name ~= nil then
		pcall(vim.api.nvim_buf_set_name, buf, name)
	end
	vim.api.nvim_set_option_value("readonly", readonly, { buf = buf, scope = "local" })
	vim.api.nvim_set_option_value("modifiable", modifiable, { buf = buf, scope = "local" })

	add_close_window_autocmd(buf)

	return { buf = buf, win = win, config = config, readonly = readonly, modifiable = modifiable }
end

local count_elements = function(list)
	local count = 0
	for _ in pairs(list) do
		count = count + 1
	end
	return count
end

local has_elements = function(list)
	return next(list) ~= nil
end

local find_element = function(list, element)
	for i, value in ipairs(list) do
		if value == element then
			return i
		end
	end
	return -1
end

local change_buffer_content = function(float, lines)
	if not vim.api.nvim_buf_is_valid(float.buf) then
		return
	end

	if lines and #lines > 0 then
		if lines[#lines] == "" then
			table.remove(lines)
		end
	end

	vim.api.nvim_set_option_value("readonly", false, { buf = float.buf, scope = "local" })
	vim.api.nvim_set_option_value("modifiable", true, { buf = float.buf, scope = "local" })
	vim.api.nvim_buf_set_lines(float.buf, 0, -1, false, lines)
	vim.api.nvim_set_option_value("readonly", float.readonly, { buf = float.buf, scope = "local" })
	vim.api.nvim_set_option_value("modifiable", float.modifiable, { buf = float.buf, scope = "local" })
end

local place_colored_shape = function(buf, line, col, hl_group, ns, shape_char)
	shape_char = shape_char or "█"

	vim.api.nvim_buf_set_extmark(buf, ns, line, col, {
		virt_text = { { shape_char, hl_group } },
		virt_text_pos = "overlay",
		end_row = line,
		end_col = col + string.len(shape_char),
	})
end

local change_footer_content = function(footer_keys, display_order)
	if not vim.api.nvim_buf_is_valid(state.floats.footer.buf) then
		return
	end

	display_order = display_order or footer_default_order

	local footer_width = window_config.footer.width
	local current_text_line = ""
	local extra_marks_coords = {}
	local current_col_offset = 0
	local rectangle_visual_width = 1
	local separator_width = 2
	local ellipsis = "..."

	vim.api.nvim_buf_clear_namespace(state.floats.footer.buf, state.footer_ns, 0, -1)

	if not has_elements(data.footer_data) then
		data.footer_data = vim.deepcopy(footer_default_data)
	end
	if type(footer_keys) == "table" then
		for key_name, key_value in pairs(footer_keys) do
			data.footer_data[key_name] = key_value
		end
	else
		vim.notify("opts must be a table", vim.log.levels.WARN)
		return
	end

	local fixed_components_width = 0
	local flexible_components = {}

	for _, component_name in ipairs(display_order) do
		local component_data = data.footer_data[component_name]
		if component_data then
			local prefix = component_data.prefix or ""
			local key_content = component_data.key or ""
			local full_text = prefix .. key_content
			local total_component_width = rectangle_visual_width + string.len(full_text)

			if component_data.show_fully then
				fixed_components_width = fixed_components_width + total_component_width
				fixed_components_width = fixed_components_width + separator_width
			else
				table.insert(flexible_components, { name = component_name, data = component_data })
			end
		end
	end

	local available_space_for_flexible = footer_width - fixed_components_width

	local truncatable_component = nil
	if #flexible_components > 0 then
		truncatable_component = flexible_components[1]
	end

	for idx, component_name in ipairs(display_order) do
		local component_data = data.footer_data[component_name]
		if component_data then
			local prefix = component_data.prefix or ""
			local key_content = component_data.key or ""
			local display_text = prefix .. key_content

			if truncatable_component and component_name == truncatable_component.name then
				local desired_text_width = available_space_for_flexible
					- rectangle_visual_width
					- (#flexible_components - 1) * separator_width

				if desired_text_width < 0 then
					display_text = ""
				elseif string.len(display_text) > desired_text_width then
					local truncate_len = desired_text_width - string.len(ellipsis)
					if truncate_len < 0 then
						truncate_len = 0
					end
					display_text = string.sub(display_text, 1, truncate_len) .. ellipsis
				end
			end

			table.insert(extra_marks_coords, { current_col_offset, 0 })

			current_text_line = current_text_line .. string.rep(" ", rectangle_visual_width) .. display_text

			current_col_offset = current_col_offset + rectangle_visual_width + string.len(display_text)

			if idx < #display_order then
				current_text_line = current_text_line .. string.rep(" ", separator_width)
				current_col_offset = current_col_offset + separator_width
			end
		end
	end

	change_buffer_content(state.floats.footer, { current_text_line })

	for _, mark in pairs(extra_marks_coords) do
		place_colored_shape(state.floats.footer.buf, mark[2], mark[1], "Footer", state.footer_ns, "█")
	end
end

local change_current_window = function(float, type, set_current)
	if set_current == nil then
		set_current = true
	end

	if state.curr_float ~= nil and vim.api.nvim_win_is_valid(state.curr_float.win) then
		vim.api.nvim_win_set_config(state.curr_float.win, { zindex = 1 })
	end
	vim.api.nvim_win_set_config(float.win, { zindex = 2 })
	if set_current then
		vim.api.nvim_set_current_win(float.win)
	end
	state.curr_float = float
	if type ~= nil then
		state.curr_float.type = type
	end

	local curr_view = data.curr_view
	if curr_view == "__NONE__" then
		curr_view = "no view"
	end
	change_footer_content({
		curr_view = { key = curr_view, prefix = "Current view: ", show_fully = false },
		curr_float = { key = state.curr_float.type, prefix = "Current float: ", show_fully = true },
	})
end

local close_window = function(win_id, skip)
	if vim.api.nvim_win_is_valid(win_id) then
		skip_win_close = skip or false
		vim.api.nvim_win_close(win_id, true)
	end
end

local add_rfc_buffer = function(title, lines)
	state.view_floats[title] = create_floating_window(window_config.view, false, nil, false, nil, nil, title)
	change_buffer_content(state.view_floats[title], lines)
end

local validate_state = function()
	if
		(state.curr_float ~= nil and not vim.api.nvim_win_is_valid(state.curr_float.win))
		or (state.floats.search_header == nil)
		or (not vim.api.nvim_win_is_valid(state.floats.search_header.win))
	then
		vim.api.nvim_echo({ { "invalid state ", "Error" } }, true, {})
		print(state.curr_float ~= nil and not vim.api.nvim_win_is_valid(state.curr_float.win))
		print(state.floats.search_header == nil)
		print(not vim.api.nvim_win_is_valid(state.floats.search_header.win))
		M.close_rfc()
		return false
	end
	return true
end

vim.keymap.set("n", "<Leader>rl", function()
	package.loaded["rfc"] = nil
	require("rfc")
end, { desc = "reload packages" })
vim.keymap.set("n", "<Leader>ro", function()
	M.open_rfc()
end, { desc = "open rfc" })
vim.keymap.set("n", "<Leader>rc", function()
	M.close_rfc()
end, { desc = "close_rfc" })
vim.keymap.set("n", "<Leader>rb", function()
	M.print_buffers()
end, { desc = "print buffers" })
vim.keymap.set("n", "<Leader>rs", function()
	M.setup({ delete_buffers_when_closing = true })
end, { desc = "setup" })

local active_watchers = {}

--- Setup buffer change listener with debouncing
---@param buf_id number Buffer handle
---@param callback function Called when content changes
---@param opts table|nil {debounce_ms = 250, on_detach = function()}
local watch_buffer_changes = function(buf_id, callback, opts)
	opts = opts or {}
	local debounce_ms = opts.debounce_ms or 250

	-- return if buffer is watched
	if active_watchers[buf_id] then
		return
	end

	local ns = vim.api.nvim_create_namespace("buffer_watcher_" .. buf_id)
	local timer = nil
	local last_changedtick = vim.b[buf_id].changedtick

	-- Debounce helper
	local function debounced_callback()
		if timer then
			timer:close()
		end
		timer = vim.defer_fn(function()
			if vim.api.nvim_buf_is_valid(buf_id) then
				callback(buf_id)
			end
			timer = nil
		end, debounce_ms)
	end

	vim.api.nvim_buf_attach(buf_id, false, {
		on_lines = function(_, _, tick)
			if tick ~= last_changedtick then
				last_changedtick = tick
				debounced_callback()
			end
		end,
		on_detach = function()
			if timer then
				timer:close()
			end
			if opts.on_detach then
				opts.on_detach(buf_id)
			end
			active_watchers[buf_id] = nil
		end,
		on_reload = function()
			debounced_callback()
		end,
	})

	active_watchers[buf_id] = {
		ns = ns,
	}
end

local add_view = function(title, lines, set_curr_view)
	if set_curr_view == nil then
		set_curr_view = true
	end

	if set_curr_view and (data.curr_view ~= "__NONE__" and data.curr_view ~= title) then
		close_window(state.view_floats[data.curr_view].win, true)
	end

	if set_curr_view then
		data.curr_view = title
		change_footer_content({ curr_view = { key = title, prefix = "Current view: ", show_fully = false } })
	end
	if state.view_floats[title] == nil then
		add_rfc_buffer(title, lines)
	else
		close_window(state.view_floats[title].win, true)
		state.view_floats[title] =
			create_floating_window(window_config.view, false, state.view_floats[title].buf, nil, nil, nil, title)
	end
end

local go_async_command = function(command, command_args, output_callback, error_callback, on_completion_callback)
	if command == "search" then
		if is_searching then
			vim.notify("Search is already running. Please wait.", vim.log.levels.WARN)
			return false
		else
			is_searching = true
		end
	elseif command == "download-all" then
		if is_downloading_all then
			vim.notify("Downloading all is already running. Please wait.", vim.log.levels.WARN)
			return false
		else
			is_downloading_all = true
		end
	elseif command == "get" then
		if is_downloading then
			vim.notify("Downloading is already running. Please wait.", vim.log.levels.WARN)
			return false
		else
			is_downloading = true
		end
	else
		vim.notify("Invalid command: " .. command, vim.log.levels.WARN)
		return false
	end

	vim.notify("Starting command: " .. command .. " " .. table.concat(command_args, " "), vim.log.levels.INFO)

	local stderr_buffer = {}

	vim.fn.jobstart(command_args, {
		on_stdout = vim.schedule_wrap(function(job_id, data_arg, event)
			if output_callback ~= nil then
				output_callback(job_id, data_arg, event)
			end
		end),

		on_stderr = vim.schedule_wrap(function(job_id, data_arg, event)
			if error_callback ~= nil then
				output_callback(job_id, data_arg, event)
			end
		end),

		on_exit = vim.schedule_wrap(function(_, exit_code, _)
			vim.notify("Command finished." .. command .. " " .. "Exit code: " .. exit_code, vim.log.levels.INFO)

			if command == "search" then
				is_searching = false
				M.search_exit_code = exit_code
			elseif command == "download-all" then
				is_downloading_all = false
				M.download_all_exit_code = exit_code
			elseif command == "get" then
				is_downloading = false
				M.get_exit_code = exit_code
			end

			if #table.concat(stderr_buffer) > 0 then
				vim.notify(
					"Command " .. command .. " " .. "errors:\n" .. table.concat(stderr_buffer, "\n"),
					vim.log.levels.WARN
				)
			end

			if on_completion_callback ~= nil then
				on_completion_callback(exit_code, M.last_command_output, M.last_command_errors)
			end
		end),
	})

	return true
end

--- @alias PluginCommands "rfc" | "save" | "list" | "view" | "get" | "delete" | "filter" | "delete-all" | "download-all" | "offset" | "build-list"

--- @param commands PluginCommands[]
--- @param args (string|nil)[] # arguments for each flag, same order, nil to skip
--- @return string[] # stdout lines
local run_go_plugin = function(commands, args)
	local binary_path = vim.fn.expand("~/personal/rfc_plugin.nvim/plugin/main")

	local cmd_args = { binary_path }

	for i, command in ipairs(commands) do
		table.insert(cmd_args, "--" .. command)
		local arg = args[i]
		if arg ~= nil then
			table.insert(cmd_args, arg)
		end
	end

	if commands[1] == "download-all" then
		if is_downloading_all then
			vim.notify("Download all is already running. Please wait.", vim.log.levels.WARN)
			return {}
		end

		change_footer_content({ status = { key = "Downloading all rfcs", prefix = "Status: ", show_fully = true } })
		go_async_command("download-all", cmd_args, nil, nil, function(exit_code, _, last_command_errors)
			change_footer_content({ status = { key = "no status", prefix = "Status: ", show_fully = true } })
			if last_command_errors ~= nil and #last_command_errors > 0 then
				vim.notify("Download all errors:\n" .. table.concat(last_command_errors, "\n"), vim.log.levels.WARN)
				data.search_data = { "Download all errors:\n" .. table.concat(last_command_errors, "\n") }
			else
				vim.notify("Download all exited with code: " .. exit_code, vim.log.levels.INFO)
				data.search_data = { "Downloaded all rfcs" }
			end
			change_buffer_content(state.floats.search, data.search_data)
		end)
		return {}
	elseif commands[1] == "rfc" then
		if is_searching then
			vim.notify("Search is already running. Please wait.", vim.log.levels.WARN)
			return {}
		end

		change_footer_content({ status = { key = "Searching for rfcs", prefix = "Status: ", show_fully = true } })
		go_async_command("search", cmd_args, function(_, data_arg, _)
			for _, line in ipairs(data_arg) do
				if line and line:match("%S") then
					table.insert(data.search_data, line)
				end
			end
		end, function(_, data_arg, _)
			vim.notify("Error: " .. table.concat(data_arg, "\n"), vim.log.levels.WARN)
		end, function(exit_code, _, last_command_errors)
			change_footer_content({ status = { key = "no status", prefix = "Status: ", show_fully = true } })
			if last_command_errors ~= nil and #last_command_errors > 0 then
				vim.notify("Search errors:\n" .. table.concat(last_command_errors, "\n"), vim.log.levels.WARN)
			else
				if state.search_offset == 0 then
					table.remove(data.search_data, 1)
				else
					table.remove(data.search_data, state.search_offset + 1)
				end
				state.search_offset = count_elements(data.search_data)
				change_buffer_content(state.floats.search, data.search_data)
				vim.notify("Search exited with code: " .. exit_code, vim.log.levels.INFO)
			end
		end)
		return {}
	elseif commands[1] == "get" then
		if is_downloading then
			vim.notify("Downloading is already running. Please wait.", vim.log.levels.WARN)
			return {}
		end

		change_footer_content({
			status = { key = "Downloading rfc " .. cmd_args[3], prefix = "Status: ", show_fully = true },
		})
		go_async_command("get", cmd_args, function(_, data_arg, _)
			for _, line in ipairs(data_arg) do
				table.insert(data.fetching_view_data, line)
			end
		end, function(_, data_arg, _)
			vim.notify("Error: " .. table.concat(data_arg, "\n"), vim.log.levels.WARN)
		end, function(exit_code, _, last_command_errors)
			change_footer_content({ status = { key = "no status", prefix = "Status: ", show_fully = true } })
			if last_command_errors ~= nil and #last_command_errors > 0 then
				vim.notify("Download errors:\n" .. table.concat(last_command_errors, "\n"), vim.log.levels.WARN)
			else
				vim.notify("Download exited with code: " .. exit_code, vim.log.levels.INFO)

				add_view(cmd_args[3], data.fetching_view_data)
			end
			data.fetching_view_data = {}
		end)
		return {}
	end

	local result = vim.system(cmd_args, { text = true }):wait()

	if result.stderr and #result.stderr > 0 then
		vim.api.nvim_echo({
			{ "Go plugin produced stderr output: " .. result.stderr, "Error" },
		}, true, {})
	end

	return vim.split(result.stdout or "", "\n")
end

local open_view = function(lines, create)
	lines = lines or { "no current view" }
	state.curr_float = state.floats.view
	state.curr_float.type = "view"

	if data.curr_view ~= "__NONE__" then
		if not vim.api.nvim_win_is_valid(state.view_floats[data.curr_view].win) then
			state.view_floats[data.curr_view] = create_floating_window(
				window_config.view,
				false,
				state.view_floats[data.curr_view].buf,
				nil,
				nil,
				nil,
				data.curr_view
			)
		end
		change_current_window(state.view_floats[data.curr_view], "view")
	else
		create = create or false
		if not vim.api.nvim_win_is_valid(state.floats.view.win) then
			if not create then
				return
			end
			if vim.api.nvim_buf_is_valid(state.floats.view.buf) then
				state.floats.view = create_floating_window(
					window_config.view,
					false,
					state.floats.view.buf,
					nil,
					state.floats.view.readonly,
					state.floats.view.modifiable,
					"view"
				)
			else
				state.floats.view = create_floating_window(
					window_config.view,
					true,
					nil,
					nil,
					state.floats.view.readonly,
					state.floats.view.modifiable,
					"view"
				)
			end
		end
		change_current_window(state.floats.view, "view")
		change_buffer_content(state.curr_float, lines)
	end
end

local open_list = function(lines, create, set_current)
	if set_current == nil then
		set_current = true
	end
	if create == nil then
		create = false
	end
	if not vim.api.nvim_win_is_valid(state.floats.list.win) then
		if not create then
			return
		end
		if vim.api.nvim_buf_is_valid(state.floats.list.buf) then
			state.floats.list = create_floating_window(
				window_config.view,
				set_current,
				state.floats.list.buf,
				nil,
				state.floats.list.readonly,
				state.floats.list.modifiable,
				"list"
			)
		else
			state.floats.list = create_floating_window(
				window_config.view,
				set_current,
				nil,
				nil,
				state.floats.list.readonly,
				state.floats.list.modifiable,
				"list"
			)
		end
	end

	change_current_window(state.floats.list, "list", set_current)

	if lines ~= nil then
		data.list_data = lines
	elseif not has_elements(data.list_data) then
		data.list_data = run_go_plugin({ "list" }, { nil })
	end
	if not has_elements(data.list_data) then
		data.list_data = { "nothing to list" }
	end

	change_buffer_content(state.curr_float, data.list_data)
end

local open_search = function(lines, create, set_current)
	if set_current == nil then
		set_current = true
	end

	if create == nil then
		create = false
	end
	if not vim.api.nvim_win_is_valid(state.floats.search.win) then
		if not create then
			return
		end
		if vim.api.nvim_buf_is_valid(state.floats.search.buf) then
			state.floats.search = create_floating_window(
				window_config.view,
				set_current,
				state.floats.search.buf,
				nil,
				state.floats.search.readonly,
				state.floats.search.modifiable,
				"search"
			)
		else
			state.floats.search = create_floating_window(
				window_config.view,
				set_current,
				nil,
				nil,
				state.floats.search.readonly,
				state.floats.search.modifiable,
				"search"
			)
		end
	end
	if lines ~= nil then
		data.search_data = lines
	end

	change_current_window(state.floats.search, "search", set_current)
	change_buffer_content(state.curr_float, data.search_data)
end

local open_search_header = function(create)
	create = create or false
	if not state.floats.search_header then
		if create then
			state.floats.search_header = create_floating_window(
				window_config.search,
				true,
				nil,
				nil,
				state.floats.search_header.readonly,
				state.floats.search_header.modifiable,
				"search_header"
			)
		else
			vim.notify("search header not created", vim.log.levels.WARN)
			return
		end
	else
		if not vim.api.nvim_win_is_valid(state.floats.search_header.win) then
			if not create then
				return
			end
			state.floats.search_header = create_floating_window(
				window_config.search,
				true,
				nil,
				nil,
				state.floats.search_header.readonly,
				state.floats.search_header.modifiable,
				"search_header"
			)
		else
			vim.notify("search header not created", vim.log.levels.WARN)
			return
		end
	end

	vim.api.nvim_set_current_win(state.floats.search_header.win)

	watch_buffer_changes(state.floats.search_header.buf, function(buf)
		local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
		if state.curr_float.type == "list" then
			open_list(run_go_plugin({ "list", "filter" }, { nil, table.concat(lines) }), nil, false)
		elseif state.curr_float.type == "search" then
			state.last_search = table.concat(lines)
			run_go_plugin({ "rfc" }, { state.last_search })
			open_search({ "searching for " .. table.concat(lines) }, nil, false)
		end
	end, {
		debounce_ms = 500, -- Only trigger after 500ms of no changes
		on_detach = function(buf) end,
	})
end

local open_footer = function(create)
	create = create or false
	if not state.floats.footer then
		if create then
			state.floats.footer = create_floating_window(
				window_config.footer,
				true,
				nil,
				nil,
				state.floats.footer.readonly,
				state.floats.footer.modifiable,
				"footer"
			)
			local curr_view = data.curr_view
			if curr_view == "__NONE__" then
				curr_view = "no view"
			end

			change_footer_content({
				curr_view = { key = curr_view, prefix = "Current view: ", show_fully = true },
				curr_float = { key = state.curr_float.type, prefix = "Current float: ", show_fully = false },
				status = { key = "no status", prefix = "Status: ", show_fully = true },
			})
		else
			vim.notify("footer not created", vim.log.levels.WARN)
			return
		end
	else
		if not vim.api.nvim_win_is_valid(state.floats.footer.win) then
			if not create then
				return
			end
			state.floats.footer = create_floating_window(
				window_config.footer,
				true,
				nil,
				nil,
				state.floats.footer.readonly,
				state.floats.footer.modifiable,
				"footer"
			)
			local curr_view = data.curr_view
			if curr_view == "__NONE__" then
				curr_view = "no view"
			end

			change_footer_content({
				curr_view = { key = curr_view, prefix = "Current view: ", show_fully = true },
				curr_float = { key = state.curr_float.type, prefix = "Current float: ", show_fully = false },
			})
		else
			vim.notify("footer not created", vim.log.levels.WARN)
			return
		end
	end
end

local open_view_list = function(create)
	create = create or false
	if not vim.api.nvim_win_is_valid(state.floats.view_list.win) then
		if not create then
			return
		end
		if vim.api.nvim_buf_is_valid(state.floats.view_list.buf) then
			state.floats.view_list = create_floating_window(
				window_config.view,
				false,
				state.floats.view_list.buf,
				nil,
				state.floats.view_list.readonly,
				state.floats.view_list.modifiable,
				"view_list"
			)
		else
			state.floats.view_list = create_floating_window(
				window_config.view,
				true,
				nil,
				nil,
				state.floats.view_list.readonly,
				state.floats.view_list.modifiable,
				"view_list"
			)
		end
	end

	local count = 0
	for _, _ in pairs(state.view_floats) do
		count = count + 1
	end

	if count == 0 then
		change_buffer_content(state.floats.view_list, { "no current views" })
	else
		local new_lines = {}
		table.insert(new_lines, "Total line count: " .. count)
		for name, _ in pairs(state.view_floats) do
			table.insert(new_lines, name)
		end
		change_buffer_content(state.floats.view_list, new_lines)
	end
	change_current_window(state.floats.view_list, "view_list")
end

--- @alias FloatType "view" | "list" | "search" | "view_list"

local initial_state = function()
	for _, autocmd in pairs(autocmds) do
		pcall(vim.api.nvim_del_autocmd, autocmd)
	end

	state.floats.view = create_floating_window(window_config.view, true, nil, nil, false, true, "view")
	state.floats.list = create_floating_window(window_config.view, false, nil, nil, true, false, "list")
	state.floats.view_list = create_floating_window(window_config.view, false, nil, nil, true, false, "view_list")
	state.floats.search = create_floating_window(window_config.view, false, nil, nil, true, false, "search")
	state.floats.search_header =
		create_floating_window(window_config.search, true, nil, nil, false, true, "search_header")
	state.floats.footer = create_floating_window(window_config.footer, true, nil, nil, false, true, "footer")
end

M.setup = function(opts)
	opts = opts or {}
	config_keys = vim.deepcopy(default_keys)
	if opts.keys and type(opts.keys) == "table" then
		for key_name, key_value in pairs(opts.keys) do
			config_keys[key_name] = key_value
		end
	end

	delete_buffers_when_closing = opts.delete_buffers_when_closing or false
end

M.open_rfc = function()
	store_original_mappings()

	if not has_elements(state.curr_float) then
		initial_state()
		open_view()

		local curr_view = data.curr_view
		if curr_view == "__NONE__" then
			curr_view = "no view"
		end
		change_footer_content({
			curr_view = { key = curr_view, prefix = "Current view: ", show_fully = false },
			curr_float = { key = state.curr_float.type, prefix = "Current float: ", show_fully = true },
		})
	else
		open_search_header(true)
		open_footer(true)
		if state.curr_float.type == "view" then
			open_view(nil, true)
		elseif state.curr_float.type == "list" then
			open_list(nil, true)
		elseif state.curr_float.type == "search" then
			open_search(nil, true)
		elseif state.curr_float.type == "view_list" then
			open_view_list(true)
		end
	end

	vim.keymap.set("n", config_keys["view"], function()
		if not validate_state() then
			return
		end

		open_view(nil, true)
	end, {
		noremap = true, -- Non-recursive
		silent = true, -- No command echo
	})

	vim.keymap.set("n", config_keys["list"], function()
		if not validate_state() then
			return
		end

		open_list(nil, true)
	end, {
		noremap = true, -- Non-recursive
		silent = true, -- No command echo
	})

	vim.keymap.set("n", config_keys["search"], function()
		if not validate_state() then
			return
		end

		open_search(nil, true)
	end, {
		noremap = true, -- Non-recursive
		silent = true, -- No command echo
	})

	vim.keymap.set("n", config_keys["next_search"], function()
		if not validate_state() or state.curr_float.type ~= "search" then
			return
		end

		run_go_plugin({ "rfc", "offset" }, { state.last_search, tostring(state.search_offset) })
	end, {
		noremap = true, -- Non-recursive
		silent = true, -- No command echo
	})

	vim.keymap.set("n", config_keys["view_list"], function()
		if not validate_state() then
			return
		end

		open_view_list(true)
	end, {
		noremap = true, -- Non-recursive
		silent = true, -- No command echo
	})

	vim.keymap.set("n", config_keys["search_header"], function()
		if not validate_state() then
			return
		end

		vim.api.nvim_set_current_win(state.floats.search_header.win)

		watch_buffer_changes(state.floats.search_header.buf, function(buf)
			local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
			if state.curr_float.type == "list" then
				open_list(run_go_plugin({ "list", "filter" }, { nil, table.concat(lines) }), nil, false)
			elseif state.curr_float.type == "search" then
				state.last_search = table.concat(lines)
				run_go_plugin({ "rfc" }, { state.last_search })
				open_search({ "searching for " .. table.concat(lines) }, nil, false)
			end
		end, {
			debounce_ms = 500, -- Only trigger after 500ms of no changes
			on_detach = function(buf) end,
		})
	end, {
		noremap = true, -- Non-recursive
		silent = true, -- No command echo
	})

	vim.keymap.set("n", config_keys["select"], function()
		if not validate_state() then
			return
		end

		local cursor_info = vim.api.nvim_win_get_cursor(state.curr_float.win)
		if state.curr_float.type == "list" or state.curr_float.type == "view_list" then
			if cursor_info[1] < 2 then
				return
			else
				if not validate_state() then
					return
				end

				local lines = vim.api.nvim_buf_get_lines(state.curr_float.buf, 0, -1, false)
				local new_lines = run_go_plugin({ "view" }, { lines[cursor_info[1]] })

				add_view(lines[cursor_info[1]], new_lines)
			end
		elseif state.curr_float.type == "search" then
			if cursor_info[1] < 2 then
				return
			else
				if not validate_state() then
					return
				end

				local lines = vim.api.nvim_buf_get_lines(state.curr_float.buf, 0, -1, false)
				run_go_plugin({ "get" }, { lines[cursor_info[1]] })
			end
		end
	end, {
		noremap = true, -- Non-recursive
		silent = true, -- No command echo
	})

	vim.keymap.set("n", config_keys["add_to_view"], function()
		if state.curr_float.type ~= "list" then
			return
		end

		if not validate_state() then
			return
		end

		local lines = vim.api.nvim_buf_get_lines(state.curr_float.buf, 0, -1, false)
		local cursor_info = vim.api.nvim_win_get_cursor(state.curr_float.win)
		if cursor_info[1] < 2 then
		else
			local new_lines = run_go_plugin({ "view" }, { lines[cursor_info[1]] })
			add_view(lines[cursor_info[1]], new_lines, false)
		end
	end, {
		noremap = true, -- Non-recursive
		silent = true, -- No command echo
	})

	vim.keymap.set("n", config_keys["delete"], function()
		if
			state.curr_float.type ~= "list"
			and state.curr_float.type ~= "view_list"
			and state.curr_float.type ~= "view"
			and state.curr_float.type ~= "search"
		then
			return
		end

		if state.curr_float.type == "search" then
			run_go_plugin({ "download-all" }, { nil })

			open_search({ "downloading all rfcs" })
			return
		end

		if state.curr_float.type == "view" then
			state.curr_float = state.floats.view
			state.curr_float.type = "view"

			close_window(state.view_floats[data.curr_view].win, true)
			vim.api.nvim_buf_delete(state.view_floats[data.curr_view].buf, { force = true })
			state.view_floats[data.curr_view] = nil
			data.curr_view = "__NONE__"

			open_view(nil, true)
			return
		end

		if not validate_state() then
			return
		end

		local lines = vim.api.nvim_buf_get_lines(state.curr_float.buf, 0, -1, false)
		local cursor_info = vim.api.nvim_win_get_cursor(state.curr_float.win)
		if cursor_info[1] < 2 then
		else
			if state.curr_float.type == "list" then
				run_go_plugin({ "delete" }, { lines[cursor_info[1]] })
				table.remove(data.list_data, find_element(data.list_data, lines[cursor_info[1]]))
				open_list()
			end
			if data.curr_view == lines[cursor_info[1]] then
				data.curr_view = "__NONE__"
			end
			if state.view_floats[lines[cursor_info[1]]] ~= nil then
				close_window(state.view_floats[lines[cursor_info[1]]].win, true)
				vim.api.nvim_buf_delete(state.view_floats[lines[cursor_info[1]]].buf, { force = true })
				state.view_floats[lines[cursor_info[1]]] = nil
			end
		end
	end, {
		noremap = true, -- Non-recursive
		silent = true, -- No command echo
	})

	vim.keymap.set("n", config_keys["delete_all"], function()
		if
			state.curr_float.type ~= "list"
			and state.curr_float.type ~= "view_list"
			and state.curr_float.type ~= "view"
		then
			return
		end

		if not validate_state() then
			return
		end

		for name, float in pairs(state.view_floats) do
			if name ~= "__NONE__" then
				close_window(float.win, true)
				if vim.api.nvim_buf_is_valid(float.buf) then
					vim.api.nvim_buf_delete(float.buf, { force = true })
				end
				state.view_floats[name] = nil
			end
		end

		data.curr_view = "__NONE__"

		if state.curr_float.type == "view" then
			open_view(nil, true)
		elseif state.curr_float.type == "view_list" then
			open_view_list()
		else
			run_go_plugin({ "delete-all" }, { nil })
			open_list({ "Total line count: 0" })
		end
	end)

	vim.keymap.set("n", config_keys["refresh"], function()
		if not validate_state() then
			return
		end

		if state.curr_float.type == "list" then
			open_list(run_go_plugin({ "list" }, { nil }))
		elseif state.curr_float.type == "view_list" then
			open_view_list()
		elseif state.curr_float.type == "view" then
			open_view()
		end
	end)

	vim.keymap.set("n", config_keys["hard_refresh"], function()
		if not validate_state() then
			return
		end

		if state.curr_float.type == "list" then
			open_list(run_go_plugin({ "build-list" }, { nil }))
		end
	end)
end

M.close_rfc = function()
	restore_original_mappings()
	data.list_data = {}

	foreach_float(function(name, float)
		if float.win and vim.api.nvim_win_is_valid(float.win) then
			vim.api.nvim_win_close(float.win, true)
		end
		if
			delete_buffers_when_closing
			and (not (string.sub(name, 1, #"rfc") == "rfc") and float.buf and vim.api.nvim_buf_is_valid(float.buf))
		then
			vim.api.nvim_buf_delete(float.buf, { force = true })
		end
	end)
end

M.delete_buffers = function(delete_rfc_buffers)
	foreach_float(function(name, float)
		if float.win and vim.api.nvim_win_is_valid(float.win) then
			vim.api.nvim_win_close(float.win, true)
		end
		if float.buf and vim.api.nvim_buf_is_valid(float.buf) then
			if string.sub(name, 1, #"rfc") == "rfc" and not delete_rfc_buffers then
				return
			end
			vim.api.nvim_buf_delete(float.buf, { force = true })
		end
	end)
end

-- FOR DEBUG

M.print_buffers = function()
	-- Get a list of all buffer IDs
	local buffer_ids = vim.api.nvim_list_bufs()

	print("--- All Buffers (including unlisted) ---")
	for _, buf_id in ipairs(buffer_ids) do
		-- Check if the buffer is valid (not deleted)
		if vim.api.nvim_buf_is_valid(buf_id) then
			local buf_name = vim.api.nvim_buf_get_name(buf_id)
			local is_loaded = vim.api.nvim_buf_is_loaded(buf_id)
			local is_listed = vim.api.nvim_buf_get_option(buf_id, "buflisted")

			local status = ""
			if not is_loaded then
				status = status .. "[Unloaded]"
			end
			if not is_listed then
				status = status .. "[Unlisted]"
			end

			print(string.format("ID: %s, Name: '%s' %s", buf_id, buf_name, status))
		end
	end

	print("\n--- Only Listed Buffers ---")
	-- Filter for only 'listed' buffers (like what :ls shows by default)
	for _, buf_id in ipairs(buffer_ids) do
		if vim.api.nvim_buf_is_valid(buf_id) and vim.api.nvim_buf_get_option(buf_id, "buflisted") then
			local buf_name = vim.api.nvim_buf_get_name(buf_id)
			print(string.format("ID: %s, Name: '%s'", buf_id, buf_name))
		end
	end
end

M.print_windows = function()
	local window_ids = vim.api.nvim_list_wins()

	print("--- All Windows ---")
	if #window_ids == 0 then
		print("No windows currently open.")
		return
	end

	for _, win_id in ipairs(window_ids) do
		if vim.api.nvim_win_is_valid(win_id) then
			local buf_id = vim.api.nvim_win_get_buf(win_id)
			local is_current = (win_id == vim.api.nvim_get_current_win())

			local buf_name = "[No Name]"
			local buf_status = ""
			if vim.api.nvim_buf_is_valid(buf_id) then
				if vim.api.nvim_buf_is_loaded(buf_id) then
					local name = vim.api.nvim_buf_get_name(buf_id)
					if name ~= "" then
						buf_name = name
					end
				else
					buf_status = buf_status .. "[BufUnloaded]"
				end

				local is_listed = vim.api.nvim_get_option_value("buflisted", { buf = buf_id })
				if not is_listed then
					buf_status = buf_status .. "[BufUnlisted]"
				end
			else
				buf_name = "[Invalid Buffer]"
				buf_status = buf_status .. "[BufInvalid]"
			end

			local win_config = vim.api.nvim_win_get_config(win_id)
			local win_type = ""
			if win_config.relative ~= "" then
				win_type = "Floating"
			else
				win_type = "Normal"
			end

			local win_info = string.format("Type: %s", win_type)
			if is_current then
				win_info = win_info .. " [CURRENT]"
			end

			print(
				string.format(
					"Win ID: %d, Buf ID: %d, Name: '%s' %s, Info: %s",
					win_id,
					buf_id,
					buf_name,
					buf_status,
					win_info
				)
			)
		end
	end
end

M.print_state = function()
	print(vim.inspect(state))
end

return M
