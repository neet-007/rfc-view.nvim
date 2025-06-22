local M = {}

local original_mappings = {}

local keys_to_store = {
	view = "m",
	list = "n",
	search = "b",
	search_header = "v",
	select = "<CR>",
	add_to_view = "s",
	delete = "d",
	refresh = "r",
	delete_all = "D",
	view_list = "z",
}

local function store_original_mappings()
	original_mappings = {}
	for _, map in ipairs(vim.api.nvim_get_keymap("n")) do
		if vim.tbl_contains(keys_to_store, map.lhs) then
			original_mappings[map.lhs] = map
		end
	end
end

local function restore_original_mappings()
	for _, key in pairs(keys_to_store) do
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
	for name, float in pairs(M.state.floats) do
		cb(name, float)
	end
	for name, float in pairs(M.state.view_floats) do
		cb(name, float)
	end
end

local function create_floating_window(config, enter, buf, is_scratch)
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

	return { buf = buf, win = win, config = config }
end

local create_window_configurations = function()
	local width = vim.o.columns
	local height = vim.o.lines

	local header_height = 1 + 2 -- 1 + border
	local body_height = height - header_height - 2 - 1 -- for our own border

	return {
		search = {
			relative = "editor",
			width = width - 16,
			height = 1,
			style = "minimal",
			border = "rounded",
			col = 8,
			row = 0,
			zindex = 2,
		},
		view = {
			relative = "editor",
			width = width - 16,
			height = body_height,
			style = "minimal",
			border = { " ", " ", " ", " ", " ", " ", " ", " " },
			col = 8,
			row = 4,
			zindex = 1,
		},
	}
end

local check_win_in_list = function(winId)
	for _, float in pairs(M.state.floats) do
		if float.win == winId then
			return true
		end
	end
	for _, float in pairs(M.state.view_floats) do
		if float.win == winId then
			return true
		end
	end
end

local has_elements = function(list)
	return next(list) ~= nil
end

local change_buffer_content = function(float, lines)
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

local change_current_window = function(float, type)
	if M.state.curr_float ~= nil and vim.api.nvim_win_is_valid(M.state.curr_float.win) then
		vim.api.nvim_win_set_config(M.state.curr_float.win, { zindex = 1 })
	end
	vim.api.nvim_win_set_config(float.win, { zindex = 2 })
	vim.api.nvim_set_current_win(float.win)
	M.state.curr_float = float
	if type ~= nil then
		M.state.curr_float.type = type
	end
end

local close_window = function(win_id, skip)
	if vim.api.nvim_win_is_valid(win_id) then
		M.skip_win_close = skip or false
		vim.api.nvim_win_close(win_id, true)
	end
end

local add_close_window_autocmd = function(buff_id)
	table.insert(
		M.autocmds,
		vim.api.nvim_create_autocmd("WinClosed", {
			buffer = buff_id,
			callback = function(args)
				local winId = tonumber(args.match)
				if not check_win_in_list(winId) then
					return
				end
				if M.skip_win_close then
					print("skip_win_close 3")
					M.skip_win_close = false
					return
				end
				print("not skip_win_close 3")
				M.close_rfc()
			end,
		})
	)
end

local add_rfc_buffer = function(title, lines)
	M.state.view_floats[title] = create_floating_window(M.window_config.view, false, nil, false)
	pcall(vim.api.nvim_buf_set_name, M.state.view_floats[title].buf, title)
	pcall(vim.api.nvim_set_option_value, true, { buf = M.state.view_floats[title].buf, scope = "local" })
	add_close_window_autocmd(M.state.view_floats[title].buf)
	change_buffer_content(M.state.view_floats[title], lines)
end

local validate_state = function()
	if
		(M.state.curr_float ~= nil and not vim.api.nvim_win_is_valid(M.state.curr_float.win))
		or (M.state.curr_header == nil)
		or (not vim.api.nvim_win_is_valid(M.state.curr_header.win))
	then
		vim.api.nvim_echo({ { "invalid M.state ", "Error" } }, true, {})
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

function M.go_async_command(command, command_args, output_callback, error_callback, on_completion_callback)
	if command == "search" then
		if M.is_searching then
			vim.notify("Search is already running. Please wait.", vim.log.levels.WARN)
			return false
		else
			M.is_searching = true
		end
	elseif command == "download-all" then
		if M.is_downloading_all then
			vim.notify("Downloading all is already running. Please wait.", vim.log.levels.WARN)
			return false
		else
			M.is_downloading_all = true
		end
	elseif command == "get" then
		if M.is_downloading then
			vim.notify("Downloading is already running. Please wait.", vim.log.levels.WARN)
			return false
		else
			M.is_downloading = true
		end
	else
		vim.notify("Invalid command: " .. command, vim.log.levels.WARN)
		return false
	end

	vim.notify("Starting command: " .. command .. " " .. table.concat(command_args, " "), vim.log.levels.INFO)

	local stderr_buffer = {}

	vim.fn.jobstart(command_args, {
		on_stdout = vim.schedule_wrap(function(job_id, data, event)
			if output_callback ~= nil then
				output_callback(job_id, data, event)
			end
		end),

		on_stderr = vim.schedule_wrap(function(job_id, data, event)
			if error_callback ~= nil then
				output_callback(job_id, data, event)
			end
		end),

		on_exit = vim.schedule_wrap(function(job_id, exit_code, event)
			vim.notify("Command finished." .. command .. " " .. "Exit code: " .. exit_code, vim.log.levels.INFO)

			if command == "search" then
				M.is_searching = false
				M.search_exit_code = exit_code
			elseif command == "download-all" then
				M.is_downloading_all = false
				M.download_all_exit_code = exit_code
			elseif command == "get" then
				M.is_downloading = false
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

--- @alias PluginCommands "rfc" | "save" | "list" | "view" | "get" | "delete" | "filter" | "delete-all" | "download-all"

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
		if M.is_downloading_all then
			vim.notify("Download all is already running. Please wait.", vim.log.levels.WARN)
			return {}
		end

		M.go_async_command(
			"download-all",
			cmd_args,
			nil,
			nil,
			function(exit_code, last_command_output, last_command_errors)
				if last_command_errors ~= nil and #last_command_errors > 0 then
					vim.notify("Download all errors:\n" .. table.concat(last_command_errors, "\n"), vim.log.levels.WARN)
					M.data.search_data = { "Download all errors:\n" .. table.concat(last_command_errors, "\n") }
				else
					vim.notify("Download all exited with code: " .. exit_code, vim.log.levels.INFO)
					M.data.search_data = { "downloaded all rfcs" }
				end
				change_buffer_content(M.state.floats.search, M.data.search_data)
			end
		)
		return {}
	elseif commands[1] == "rfc" then
		if M.is_searching then
			vim.notify("Search is already running. Please wait.", vim.log.levels.WARN)
			return {}
		end

		M.go_async_command("search", cmd_args, function(job_id, data, event)
			for _, line in ipairs(data) do
				if line and line:match("%S") then
					table.insert(M.data.search_data, line)
				end
			end
		end, function(job_id, data, event)
			vim.notify("Error: " .. table.concat(data, "\n"), vim.log.levels.WARN)
		end, function(exit_code, last_command_output, last_command_errors)
			if last_command_errors ~= nil and #last_command_errors > 0 then
				vim.notify("Search errors:\n" .. table.concat(last_command_errors, "\n"), vim.log.levels.WARN)
			else
				change_buffer_content(M.state.floats.search, M.data.search_data)
				vim.notify("Search exited with code: " .. exit_code, vim.log.levels.INFO)
			end
		end)
		return {}
	elseif commands[1] == "get" then
		if M.is_downloading then
			vim.notify("Downloading is already running. Please wait.", vim.log.levels.WARN)
			return {}
		end

		M.go_async_command("get", cmd_args, function(job_id, data, event)
			for _, line in ipairs(data) do
				table.insert(M.data.fetching_view_data, line)
			end
		end, function(job_id, data, event)
			vim.notify("Error: " .. table.concat(data, "\n"), vim.log.levels.WARN)
		end, function(exit_code, last_command_output, last_command_errors)
			if last_command_errors ~= nil and #last_command_errors > 0 then
				vim.notify("Download errors:\n" .. table.concat(last_command_errors, "\n"), vim.log.levels.WARN)
			else
				vim.notify("Download exited with code: " .. exit_code, vim.log.levels.INFO)

				if M.data.curr_view ~= "__NONE__" and M.data.curr_view ~= cmd_args[3] then
					if vim.api.nvim_win_is_valid(M.state.view_floats[M.data.curr_view].win) then
						M.skip_win_close = true
						vim.api.nvim_win_close(M.state.view_floats[M.data.curr_view].win, true)
					end
				end

				M.data.curr_view = cmd_args[3]
				if M.state.view_floats[cmd_args[3]] == nil then
					M.state.view_floats[cmd_args[3]] = create_floating_window(M.window_config.view, false, nil, false)
					pcall(vim.api.nvim_buf_set_name, M.state.view_floats[cmd_args[3]].buf, cmd_args[3])
					pcall(
						vim.api.nvim_set_option_value,
						true,
						{ buf = M.state.view_floats[M.data.curr_view].buf, scope = "local" }
					)
					add_close_window_autocmd(M.state.view_floats[cmd_args[3]].buf)
					change_buffer_content(M.state.view_floats[cmd_args[3]], M.data.fetching_view_data)
				else
					if vim.api.nvim_win_is_valid(M.state.view_floats[cmd_args[3]].win) then
						M.skip_win_close = true
						vim.api.nvim_win_close(M.state.view_floats[cmd_args[3]].win, true)
					end
					M.state.view_floats[cmd_args[3]] =
						create_floating_window(M.window_config.view, false, M.state.view_floats[cmd_args[3]].buf)
				end
			end
			M.data.fetching_view_data = {}
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

--- @alias FloatType "view" | "list" | "search" | "view_list"

M.state = {
	floats = {},
	curr_float = {},
	curr_header = {},
	view_floats = {},
}

M.skip_win_close = false

M.autocmds = {}

M.data = {
	list_data = {},
	curr_view = "__NONE__",
	search_data = { "nothing to search" },
	fetching_view_data = {},
}

M.is_searching = false
M.is_downloading = false
M.is_downloading_all = false
M.window_config = create_window_configurations()

M.setup = function()
	-- nothing
end

M.open_rfc = function()
	store_original_mappings()

	M.state.floats.view = create_floating_window(M.window_config.view, true)
	M.state.floats.list = create_floating_window(M.window_config.view, false)
	M.state.floats.view_list = create_floating_window(M.window_config.view, false)
	M.state.floats.search = create_floating_window(M.window_config.view, false)
	M.state.floats.search_header = create_floating_window(M.window_config.search, true)

	M.state.floats.view.readonly = false
	M.state.floats.view.modifiable = true
	M.state.floats.list.readonly = true
	M.state.floats.list.modifiable = false
	M.state.floats.view_list.readonly = true
	M.state.floats.view_list.modifiable = false
	M.state.floats.search.readonly = true
	M.state.floats.search.modifiable = false
	M.state.floats.search_header.readonly = false
	M.state.floats.search_header.modifiable = true

	M.state.curr_float = M.state.floats.view
	M.state.curr_float.type = "view"
	M.state.curr_header = M.state.floats.search_header

	if M.data.curr_view ~= "__NONE__" then
		if not vim.api.nvim_win_is_valid(M.state.view_floats[M.data.curr_view].win) then
			M.state.view_floats[M.data.curr_view] =
				create_floating_window(M.window_config.view, false, M.state.view_floats[M.data.curr_view].buf)
		end
		change_current_window(M.state.view_floats[M.data.curr_view], "view")
	else
		change_current_window(M.state.floats.view, "view")
		change_buffer_content(M.state.curr_float, { "no current view" })
	end

	for _, autocmd in ipairs(M.autocmds) do
		pcall(vim.api.nvim_del_autocmd, autocmd)
	end

	foreach_float(function(name, float)
		vim.bo[float.buf].filetype = "markdown"
		pcall(vim.api.nvim_buf_set_name, float.buf, name)
		if name ~= "view" and name ~= "search_header" then
			vim.api.nvim_set_option_value("readonly", true, { buf = float.buf, scope = "local" })
			vim.api.nvim_set_option_value("modifiable", false, { buf = float.buf, scope = "local" })
		end
		add_close_window_autocmd(float.buf)
	end)

	vim.keymap.set("n", "m", function()
		if not validate_state() then
			return
		end

		vim.api.nvim_win_set_config(M.state.curr_float.win, { zindex = 1 })
		if M.state.curr_header ~= nil then
			vim.api.nvim_win_set_config(M.state.curr_header.win, { zindex = 1 })
		end

		if M.data.curr_view ~= "__NONE__" then
			change_current_window(M.state.view_floats[M.data.curr_view], "view")
		else
			change_current_window(M.state.floats.view, "view")
			change_buffer_content(M.state.curr_float, { "no current view" })
		end
	end, {
		noremap = true, -- Non-recursive
		silent = true, -- No command echo
	})

	vim.keymap.set("n", "n", function()
		if not validate_state() then
			return
		end

		change_current_window(M.state.floats.list, "list")

		if not has_elements(M.data.list_data) then
			M.data.list_data = run_go_plugin({ "list" }, { nil })
		end
		if not has_elements(M.data.list_data) then
			M.data.list_data = { "nothing to list" }
		end

		change_buffer_content(M.state.curr_float, M.data.list_data)
	end, {
		noremap = true, -- Non-recursive
		silent = true, -- No command echo
	})

	vim.keymap.set("n", "b", function()
		if not validate_state() then
			return
		end

		change_current_window(M.state.floats.search, "search")
		change_buffer_content(M.state.curr_float, M.data.search_data)
	end, {
		noremap = true, -- Non-recursive
		silent = true, -- No command echo
	})

	vim.keymap.set("n", "v", function()
		if not validate_state() then
			return
		end

		vim.api.nvim_set_current_win(M.state.floats.search_header.win)

		watch_buffer_changes(M.state.curr_header.buf, function(buf)
			local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
			if M.state.curr_float.type == "list" then
				M.data.list_data = run_go_plugin({ "list", "filter" }, { nil, table.concat(lines) })
				change_buffer_content(M.state.curr_float, M.data.list_data)
			elseif M.state.curr_float.type == "search" then
				print("search")
				M.data.search_data = run_go_plugin({ "rfc" }, { table.concat(lines) })
				change_buffer_content(M.state.curr_float, M.data.search_data)
			end
		end, {
			debounce_ms = 500, -- Only trigger after 500ms of no changes
			on_detach = function(buf)
				print("Stopped watching buffer", buf)
			end,
		})
	end, {
		noremap = true, -- Non-recursive
		silent = true, -- No command echo
	})

	vim.keymap.set("n", "<CR>", function()
		if not validate_state() then
			return
		end

		local cursor_info = vim.api.nvim_win_get_cursor(M.state.curr_float.win)
		if M.state.curr_float.type == "list" or M.state.curr_float.type == "view_list" then
			if cursor_info[1] < 2 then
				return
			else
				if not validate_state() then
					return
				end

				local lines = vim.api.nvim_buf_get_lines(M.state.curr_float.buf, 0, -1, false)
				local new_lines = run_go_plugin({ "view" }, { lines[cursor_info[1]] })

				if M.data.curr_view ~= "__NONE__" and M.data.curr_view ~= lines[cursor_info[1]] then
					close_window(M.state.view_floats[M.data.curr_view].win, true)
				end

				M.data.curr_view = lines[cursor_info[1]]
				if M.state.view_floats[lines[cursor_info[1]]] == nil then
					add_rfc_buffer(lines[cursor_info[1]], new_lines)
				else
					close_window(M.state.view_floats[lines[cursor_info[1]]].win, true)
					M.state.view_floats[lines[cursor_info[1]]] = create_floating_window(
						M.window_config.view,
						false,
						M.state.view_floats[lines[cursor_info[1]]].buf
					)
				end
			end
		elseif M.state.curr_float.type == "search" then
			if cursor_info[1] < 2 then
				return
			else
				if not validate_state() then
					return
				end

				local lines = vim.api.nvim_buf_get_lines(M.state.curr_float.buf, 0, -1, false)
				run_go_plugin({ "get" }, { lines[cursor_info[1]] })
			end
		end
	end, {
		noremap = true, -- Non-recursive
		silent = true, -- No command echo
	})

	vim.keymap.set("n", "s", function()
		if M.state.curr_float.type ~= "list" then
			return
		end

		if not validate_state() then
			return
		end

		local lines = vim.api.nvim_buf_get_lines(M.state.curr_float.buf, 0, -1, false)
		local cursor_info = vim.api.nvim_win_get_cursor(M.state.curr_float.win)
		if cursor_info[1] < 2 then
			print("less than 2")
		else
			local new_lines = run_go_plugin({ "view" }, { lines[cursor_info[1]] })
			if type(lines[cursor_info[1]]) ~= "string" then
				print("NOT STRING NOT STRING", lines[cursor_info[1]])
			end
			add_rfc_buffer(lines[cursor_info[1]], new_lines)
		end
	end, {
		noremap = true, -- Non-recursive
		silent = true, -- No command echo
	})

	vim.keymap.set("n", "z", function()
		if not validate_state() then
			return
		end

		change_current_window(M.state.floats.view_list, "view_list")

		local count = 0
		for _, _ in pairs(M.state.view_floats) do
			count = count + 1
		end

		if count == 0 then
			change_buffer_content(M.state.curr_float, { "no current views" })
		else
			local new_lines = {}
			table.insert(new_lines, "Total line count: " .. count)
			for name, _ in pairs(M.state.view_floats) do
				if type(name) ~= "string" then
					print("name not string ", name)
				end
				table.insert(new_lines, name)
			end
			change_buffer_content(M.state.curr_float, new_lines)
		end
	end, {
		noremap = true, -- Non-recursive
		silent = true, -- No command echo
	})

	vim.keymap.set("n", "d", function()
		if
			M.state.curr_float.type ~= "list"
			and M.state.curr_float.type ~= "view_list"
			and M.state.curr_float.type ~= "view"
			and M.state.curr_float.type ~= "search"
		then
			return
		end

		if M.state.curr_float.type == "search" then
			run_go_plugin({ "download-all" }, { nil })

			change_buffer_content(M.state.curr_float, { "downloading all rfcs" })
			return
		end

		if M.state.curr_float.type == "view" then
			M.state.curr_float = M.state.floats.view
			M.state.curr_float.type = "view"
			M.state.curr_header = nil

			close_window(M.state.view_floats[M.data.curr_view].win, true)
			--[[
			M.skip_win_close = true
			vim.api.nvim_win_close(M.state.view_floats[M.data.curr_view].win, true)
			--]]
			vim.api.nvim_buf_delete(M.state.view_floats[M.data.curr_view].buf, { force = true })
			M.state.view_floats[M.data.curr_view] = nil
			M.data.curr_view = "__NONE__"

			if not vim.api.nvim_win_is_valid(M.state.floats.view.win) then
				if not vim.api.nvim_buf_is_valid(M.state.floats.view.buf) then
					M.state.floats.view = create_floating_window(M.window_config.view, false)
				else
					M.state.floats.view = create_floating_window(M.window_config.view, false, M.state.floats.view.buf)
				end
			end

			change_current_window(M.state.floats.view, "view")
			change_buffer_content(M.state.curr_float, { "no current view" })

			return
		end

		if not validate_state() then
			return
		end

		local lines = vim.api.nvim_buf_get_lines(M.state.curr_float.buf, 0, -1, false)
		local cursor_info = vim.api.nvim_win_get_cursor(M.state.curr_float.win)
		if cursor_info[1] < 2 then
		else
			if M.state.curr_float.type == "list" then
				run_go_plugin({ "delete" }, { lines[cursor_info[1]] })
				M.data.list_data[lines[cursor_info[1]]] = nil
			end
			if M.data.curr_view == lines[cursor_info[1]] then
				M.data.curr_view = "__NONE__"
			end
			if M.state.view_floats[lines[cursor_info[1]]] ~= nil then
				close_window(M.state.view_floats[lines[cursor_info[1]]].win, true)
				vim.api.nvim_buf_delete(M.state.view_floats[lines[cursor_info[1]]].buf, { force = true })
				M.state.view_floats[lines[cursor_info[1]]] = nil
			end
		end
	end, {
		noremap = true, -- Non-recursive
		silent = true, -- No command echo
	})

	vim.keymap.set("n", "D", function()
		if
			M.state.curr_float.type ~= "list"
			and M.state.curr_float.type ~= "view_list"
			and M.state.curr_float.type ~= "view"
		then
			return
		end

		if not validate_state() then
			return
		end

		for name, float in pairs(M.state.view_floats) do
			if name ~= "__NONE__" then
				close_window(float.win, true)
				if vim.api.nvim_buf_is_valid(float.buf) then
					vim.api.nvim_buf_delete(float.buf, { force = true })
				end
				M.state.view_floats[name] = nil
			end
		end

		M.data.curr_view = "__NONE__"

		if not vim.api.nvim_win_is_valid(M.state.floats.view.win) then
			if not vim.api.nvim_buf_is_valid(M.state.floats.view.buf) then
				M.state.floats.view = create_floating_window(M.window_config.view, false)
			else
				M.state.floats.view = create_floating_window(M.window_config.view, false, M.state.floats.view.buf)
			end
		end

		if M.state.curr_float.type == "view" then
			change_current_window(M.state.floats.view, "view")
			change_buffer_content(M.state.curr_float, { "no current view" })
		elseif M.state.curr_float.type == "view_list" then
			change_current_window(M.state.floats.view_list)
			change_buffer_content(M.state.curr_float, { "no current views" })
		else
			run_go_plugin({ "delete-all" }, { nil })
			change_current_window(M.state.curr_float)
			change_buffer_content(M.state.curr_float, { "Total line count: 0" })
		end
		M.state.curr_header = nil
	end)

	vim.keymap.set("n", "r", function()
		if not validate_state() then
			return
		end

		if M.state.curr_float.type == "list" then
			M.data.list_data = run_go_plugin({ "list" }, { nil })

			change_buffer_content(M.state.curr_float, M.data.list_data)
		elseif M.state.curr_float.type == "view_list" then
			local count = 0
			for _, _ in pairs(M.state.view_floats) do
				count = count + 1
			end

			if count == 0 then
				change_buffer_content(M.state.curr_float, { "no current views" })
			else
				local new_lines = {}
				table.insert(new_lines, "Total line count: " .. count)
				for name, _ in pairs(M.state.view_floats) do
					if type(name) ~= "string" then
						print("name not string ", name)
					end
					table.insert(new_lines, name)
				end
				change_buffer_content(M.state.curr_float, new_lines)
			end
		elseif M.state.curr_float.type == "view" then
			if M.data.curr_view ~= "__NONE__" then
				change_current_window(M.state.view_floats[M.data.curr_view], "view")
			end
		end
	end)
end

M.close_rfc = function()
	restore_original_mappings()
	M.data.list_data = {}

	foreach_float(function(name, float)
		if float.win and vim.api.nvim_win_is_valid(float.win) then
			vim.api.nvim_win_close(float.win, true)
		end
		if not (string.sub(name, 1, #"rfc") == "rfc") and float.buf and vim.api.nvim_buf_is_valid(float.buf) then
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
	print(vim.inspect(M.state))
end

return M
