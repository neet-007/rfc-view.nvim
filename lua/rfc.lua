local M = {}

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

--- @alias PluginCommands "rfc" | "save" | "list" | "view" | "get" | "delete"

--- @param command PluginCommands
--- @param args string
--- @return string[]
local run_go_plugin = function(command, args)
	local binary_path = vim.fn.expand("~/personal/rfc_plugin.nvim/plugin/main")
	local result = vim.system({
		binary_path,
		"--" .. command, -- add flag prefix
		args,
	}, { text = true }):wait()

	if result.stderr and #result.stderr > 0 then
		vim.api.nvim_echo({
			{
				"Go plugin produced stderr output: " .. result.stderr,
				"Error",
			},
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
	list_data = { "nothing to list" },
	curr_view = "__NONE__",
	search_data = { "nothing to search" },
}

local original_mappings = {}

local keys_to_store = { "m", "n", "b", "v", "<CR>", "s", "d" }

local function store_original_mappings()
	original_mappings = {}
	for _, map in ipairs(vim.api.nvim_get_keymap("n")) do
		if vim.tbl_contains(keys_to_store, map.lhs) then
			original_mappings[map.lhs] = map
		end
	end
end

local function restore_original_mappings()
	for _, key in ipairs(keys_to_store) do
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

local change_buffer_content = function(float, lines)
	vim.api.nvim_set_option_value("readonly", false, { buf = float.buf, scope = "local" })
	vim.api.nvim_set_option_value("modifiable", true, { buf = float.buf, scope = "local" })
	vim.api.nvim_buf_set_lines(float.buf, 0, -1, false, lines)
	vim.api.nvim_set_option_value("readonly", float.readonly, { buf = float.buf, scope = "local" })
	vim.api.nvim_set_option_value("modifiable", float.modifiable, { buf = float.buf, scope = "local" })
end

M.setup = function()
	-- nothing
end

M.open_rfc = function()
	store_original_mappings()

	local window_config = create_window_configurations()

	M.state.floats.view = create_floating_window(window_config.view, true)
	M.state.floats.list = create_floating_window(window_config.view, false)
	M.state.floats.view_list = create_floating_window(window_config.view, false)
	M.state.floats.search = create_floating_window(window_config.view, false)
	M.state.floats.search_header = create_floating_window(window_config.search, true)

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
	M.state.curr_header = nil

	if M.data.curr_view ~= "__NONE__" then
		if not vim.api.nvim_win_is_valid(M.state.view_floats[M.data.curr_view].win) then
			M.state.view_floats[M.data.curr_view] =
				create_floating_window(window_config.view, false, M.state.view_floats[M.data.curr_view].buf)
		end
		vim.api.nvim_win_set_config(M.state.view_floats[M.data.curr_view].win, { zindex = 2 })
		vim.api.nvim_set_current_win(M.state.view_floats[M.data.curr_view].win)
		M.state.curr_float = M.state.view_floats[M.data.curr_view]
		M.state.curr_float.type = "view"
	else
		vim.api.nvim_win_set_config(M.state.floats.view.win, { zindex = 2 })
		vim.api.nvim_set_current_win(M.state.floats.view.win)
		M.state.curr_float = M.state.floats.view
		M.state.curr_float.type = "view"
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
		table.insert(
			M.autocmds,
			vim.api.nvim_create_autocmd("WinClosed", {
				buffer = float.buf,
				callback = function()
					if M.skip_win_close then
						print("skip_win_close 1")
						M.skip_win_close = false
						return
					end
					print("not skip_win_close 1")
					M.close_rfc()
				end,
			})
		)
	end)

	vim.keymap.set("n", "m", function()
		if
			not vim.api.nvim_win_is_valid(M.state.curr_float.win)
			or (M.state.curr_header ~= nil and not vim.api.nvim_win_is_valid(M.state.curr_header.win))
		then
			vim.api.nvim_echo({
				{
					string.format(
						"invalid state view %s %s",
						vim.api.nvim_win_is_valid(M.state.curr_float.win),
						(M.state.curr_header ~= nil and not vim.api.nvim_win_is_valid(M.state.curr_header.win))
					),
					"Error",
				},
			}, true, {})
			M.close_rfc()
			return
		end

		vim.api.nvim_win_set_config(M.state.curr_float.win, { zindex = 1 })
		if M.state.curr_header ~= nil then
			vim.api.nvim_win_set_config(M.state.curr_header.win, { zindex = 1 })
		end

		if M.data.curr_view ~= "__NONE__" then
			vim.api.nvim_win_set_config(M.state.view_floats[M.data.curr_view].win, { zindex = 2 })
			vim.api.nvim_set_current_win(M.state.view_floats[M.data.curr_view].win)
			M.state.curr_float = M.state.view_floats[M.data.curr_view]
			M.state.curr_float.type = "view"
			M.state.curr_header = nil
		else
			vim.api.nvim_win_set_config(M.state.floats.view.win, { zindex = 2 })
			vim.api.nvim_set_current_win(M.state.floats.view.win)
			M.state.curr_float = M.state.floats.view
			M.state.curr_float.type = "view"
			M.state.curr_header = nil

			change_buffer_content(M.state.curr_float, { "no current view" })
		end
	end, {
		noremap = true, -- Non-recursive
		silent = true, -- No command echo
	})

	vim.keymap.set("n", "n", function()
		if
			not vim.api.nvim_win_is_valid(M.state.curr_float.win)
			or (M.state.curr_header ~= nil and not vim.api.nvim_win_is_valid(M.state.curr_header.win))
		then
			vim.api.nvim_echo({ { "invalid M.state list", "Error" } }, true, {})
			M.close_rfc()
			return
		end

		vim.api.nvim_win_set_config(M.state.curr_float.win, { zindex = 1 })
		if M.state.curr_header ~= nil then
			vim.api.nvim_win_set_config(M.state.curr_header.win, { zindex = 1 })
		end

		vim.api.nvim_win_set_config(M.state.floats.list.win, { zindex = 2 })
		vim.api.nvim_set_current_win(M.state.floats.list.win)
		M.state.curr_float = M.state.floats.list
		M.state.curr_float.type = "list"
		M.state.curr_header = nil

		M.data.list_data = run_go_plugin("list", "")

		change_buffer_content(M.state.curr_float, M.data.list_data)
	end, {
		noremap = true, -- Non-recursive
		silent = true, -- No command echo
	})

	vim.keymap.set("n", "b", function()
		if
			not vim.api.nvim_win_is_valid(M.state.curr_float.win)
			or (M.state.curr_header ~= nil and not vim.api.nvim_win_is_valid(M.state.curr_header.win))
		then
			vim.api.nvim_echo({ { "invalid M.state search", "Error" } }, true, {})
			M.close_rfc()
			return
		end

		vim.api.nvim_win_set_config(M.state.curr_float.win, { zindex = 1 })
		if M.state.curr_header ~= nil then
			vim.api.nvim_win_set_config(M.state.curr_header.win, { zindex = 1 })
		end

		vim.api.nvim_win_set_config(M.state.floats.search.win, { zindex = 2 })
		vim.api.nvim_win_set_config(M.state.floats.search_header.win, { zindex = 2 })
		vim.api.nvim_set_current_win(M.state.floats.search.win)
		M.state.curr_float = M.state.floats.search
		M.state.curr_float.type = "search"
		M.state.curr_header = M.state.floats.search_header

		change_buffer_content(M.state.curr_float, M.data.search_data)
	end, {
		noremap = true, -- Non-recursive
		silent = true, -- No command echo
	})

	vim.keymap.set("n", "v", function()
		if
			not vim.api.nvim_win_is_valid(M.state.curr_float.win)
			or (M.state.curr_header ~= nil and not vim.api.nvim_win_is_valid(M.state.curr_header.win))
		then
			vim.api.nvim_echo({ { "invalid M.state search header", "Error" } }, true, {})
			M.close_rfc()
			return
		end

		vim.api.nvim_win_set_config(M.state.curr_float.win, { zindex = 1 })
		if M.state.curr_header ~= nil then
			vim.api.nvim_win_set_config(M.state.curr_header.win, { zindex = 1 })
		end

		vim.api.nvim_win_set_config(M.state.floats.search_header.win, { zindex = 2 })
		vim.api.nvim_set_current_win(M.state.floats.search_header.win)
		M.state.curr_header = M.state.floats.search_header

		watch_buffer_changes(M.state.curr_header.buf, function(buf)
			local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
			if M.state.curr_float.type == "list" then
				M.data.list_data = run_go_plugin("list", table.concat(lines))
				change_buffer_content(M.state.curr_float, M.data.list_data)
			elseif M.state.curr_float.type == "search" then
				print("search")
				M.data.search_data = run_go_plugin("rfc", table.concat(lines))
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
		if not vim.api.nvim_win_is_valid(M.state.curr_float.win) then
			vim.api.nvim_echo({ { "invalid M.state", "Error" } }, true, {})
			M.close_rfc()
			return
		end

		local cursor_info = vim.api.nvim_win_get_cursor(M.state.curr_float.win)
		if M.state.curr_float.type == "list" or M.state.curr_float.type == "view_list" then
			-- TODO: dont make anything for nothing to view here for view_list
			if cursor_info[1] < 2 then
				print("less than 2")
			else
				if not vim.api.nvim_win_is_valid(M.state.curr_float.win) then
					vim.api.nvim_echo({ { "invalid M.state", "Error" } }, true, {})
					M.close_rfc()
					return
				end

				local lines = vim.api.nvim_buf_get_lines(M.state.curr_float.buf, 0, -1, false)
				local new_lines = run_go_plugin("view", lines[cursor_info[1]])
				M.data.curr_view = lines[cursor_info[1]]
				if M.state.view_floats[lines[cursor_info[1]]] == nil then
					M.state.view_floats[lines[cursor_info[1]]] =
						create_floating_window(window_config.view, false, nil, false)
					pcall(
						vim.api.nvim_buf_set_name,
						M.state.view_floats[lines[cursor_info[1]]].buf,
						lines[cursor_info[1]]
					)
					table.insert(
						M.autocmds,
						vim.api.nvim_create_autocmd("WinClosed", {
							buffer = M.state.view_floats[lines[cursor_info[1]]].buf,
							callback = function()
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
					change_buffer_content(M.state.view_floats[lines[cursor_info[1]]], new_lines)
				else
					M.skip_win_close = true
					if vim.api.nvim_win_is_valid(M.state.view_floats[lines[cursor_info[1]]].win) then
						vim.api.nvim_win_close(M.state.view_floats[lines[cursor_info[1]]].win, true)
					end
					M.state.view_floats[lines[cursor_info[1]]] = create_floating_window(
						window_config.view,
						false,
						M.state.view_floats[lines[cursor_info[1]]].buf
					)
				end
			end
		elseif M.state.curr_float.type == "search" then
			if cursor_info[1] < 2 then
				print("less than 2")
			else
				if not vim.api.nvim_win_is_valid(M.state.curr_float.win) then
					vim.api.nvim_echo({ { "invalid M.state", "Error" } }, true, {})
					M.close_rfc()
					return
				end

				local lines = vim.api.nvim_buf_get_lines(M.state.curr_float.buf, 0, -1, false)
				local new_lines = run_go_plugin("get", lines[cursor_info[1]])
				M.data.curr_view = lines[cursor_info[1]]
				M.state.view_floats[lines[cursor_info[1]]] = create_floating_window(window_config.view, false)
				pcall(vim.api.nvim_buf_set_name, M.state.view_floats[lines[cursor_info[1]]].buf, lines[cursor_info[1]])
				table.insert(
					M.autocmds,
					vim.api.nvim_create_autocmd("WinClosed", {
						buffer = M.state.view_floats[lines[cursor_info[1]]].buf,
						callback = function()
							if M.skip_win_close then
								print("skip_win_close 2")
								M.skip_win_close = false
								return
							end
							print("not skip_win_close 2")
							M.close_rfc()
						end,
					})
				)
				change_buffer_content(M.state.view_floats[lines[cursor_info[1]]], new_lines)
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

		if not vim.api.nvim_win_is_valid(M.state.curr_float.win) then
			vim.api.nvim_echo({ { "invalid M.state", "Error" } }, true, {})
			M.close_rfc()
			return
		end

		local lines = vim.api.nvim_buf_get_lines(M.state.curr_float.buf, 0, -1, false)
		local cursor_info = vim.api.nvim_win_get_cursor(M.state.curr_float.win)
		if cursor_info[1] < 2 then
			print("less than 2")
		else
			local new_lines = run_go_plugin("view", lines[cursor_info[1]])
			if type(lines[cursor_info[1]]) ~= "string" then
				print("NOT STRING NOT STRING", lines[cursor_info[1]])
			end
			M.state.view_floats[lines[cursor_info[1]]] = create_floating_window(window_config.view, false, nil, false)
			pcall(vim.api.nvim_buf_set_name, M.state.view_floats[lines[cursor_info[1]]].buf, lines[cursor_info[1]])
			table.insert(
				M.autocmds,
				vim.api.nvim_create_autocmd("WinClosed", {
					buffer = M.state.view_floats[lines[cursor_info[1]]].buf,
					callback = function()
						if M.skip_win_close then
							print("skip_win_close 4")
							M.skip_win_close = false
							return
						end
						print("not skip_win_close 4")
						M.close_rfc()
					end,
				})
			)
			change_buffer_content(M.state.view_floats[lines[cursor_info[1]]], new_lines)
		end
	end, {
		noremap = true, -- Non-recursive
		silent = true, -- No command echo
	})

	vim.keymap.set("n", "z", function()
		if
			not vim.api.nvim_win_is_valid(M.state.curr_float.win)
			or (M.state.curr_header ~= nil and not vim.api.nvim_win_is_valid(M.state.curr_header.win))
		then
			vim.api.nvim_echo({ { "invalid M.state list", "Error" } }, true, {})
			M.close_rfc()
			return
		end

		vim.api.nvim_win_set_config(M.state.curr_float.win, { zindex = 1 })
		if M.state.curr_header ~= nil then
			vim.api.nvim_win_set_config(M.state.curr_header.win, { zindex = 1 })
		end

		vim.api.nvim_win_set_config(M.state.floats.view_list.win, { zindex = 2 })
		vim.api.nvim_set_current_win(M.state.floats.view_list.win)
		M.state.curr_float = M.state.floats.view_list
		M.state.curr_float.type = "view_list"
		M.state.curr_header = nil

		local count = 0
		for _, _ in pairs(M.state.view_floats) do
			count = count + 1
		end

		if count == 0 then
			change_buffer_content(M.state.curr_float, { "no current views" })
		else
			local new_lines = {}
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
		then
			return
		end

		if M.state.curr_float.type == "view" then
			M.state.curr_float = M.state.floats.view
			M.state.curr_float.type = "view"
			M.state.curr_header = nil

			M.skip_win_close = true
			vim.api.nvim_win_close(M.state.view_floats[M.data.curr_view].win, true)
			vim.api.nvim_buf_delete(M.state.view_floats[M.data.curr_view].buf, { force = true })
			M.state.view_floats[M.data.curr_view] = nil
			M.data.curr_view = "__NONE__"

			vim.api.nvim_win_set_config(M.state.floats.view.win, { zindex = 2 })
			vim.api.nvim_set_current_win(M.state.floats.view.win)
			M.state.curr_float = M.state.floats.view
			M.state.curr_float.type = "view"
			change_buffer_content(M.state.curr_float, { "no current view" })

			return
		end

		if not vim.api.nvim_win_is_valid(M.state.curr_float.win) then
			vim.api.nvim_echo({ { "invalid M.state", "Error" } }, true, {})
			M.close_rfc()
			return
		end

		local lines = vim.api.nvim_buf_get_lines(M.state.curr_float.buf, 0, -1, false)
		local cursor_info = vim.api.nvim_win_get_cursor(M.state.curr_float.win)
		if cursor_info[1] < 2 then
			print("less than 2")
		else
			if M.state.curr_float.type == "list" then
				run_go_plugin("delete", lines[cursor_info[1]])
				M.data.list_data[lines[cursor_info[1]]] = nil
			else
				if M.data.curr_view == lines[cursor_info[1]] then
					M.data.curr_view = "__NONE__"
				end
				M.skip_win_close = true
				vim.api.nvim_win_close(M.state.view_floats[lines[cursor_info[1]]].win, true)
				vim.api.nvim_buf_delete(M.state.view_floats[lines[cursor_info[1]]].buf, { force = true })
				M.state.view_floats[lines[cursor_info[1]]] = nil
			end
		end
	end, {
		noremap = true, -- Non-recursive
		silent = true, -- No command echo
	})
end

M.close_rfc = function()
	restore_original_mappings()

	foreach_float(function(name, float)
		if float.win and vim.api.nvim_win_is_valid(float.win) then
			vim.api.nvim_win_close(float.win, true)
		end
		if not (string.sub(name, 1, #"rfc") == "rfc") and float.buf and vim.api.nvim_buf_is_valid(float.buf) then
			vim.api.nvim_buf_delete(float.buf, { force = true })
		end
	end)
end

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
