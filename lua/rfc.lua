local M = {}

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

--- @alias PluginCommands "rfc" | "save" | "list"

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

	return vim.split(result.stdout or "", "\n")
end

--- @alias FloatType "view" | "list" | "search"

local state = {
	floats = {},
	curr_float = {},
	curr_header = {},
}

local data = {
	list_data = {},
	view_data = {},
	search_data = {},
}

local original_mappings = {}

local function store_original_mappings()
	original_mappings.m = vim.fn.maparg("m", "n") or false
	original_mappings.n = vim.fn.maparg("n", "n") or false
	original_mappings.b = vim.fn.maparg("b", "n") or false
	original_mappings.v = vim.fn.maparg("v", "n") or false
end

local function restore_original_mappings()
	for key, mapping in pairs(original_mappings) do
		if mapping == false then
			-- No original mapping existed, so delete ours
			pcall(vim.keymap.del, "n", key)
		else
			-- Restore the original mapping
			vim.keymap.set("n", key, mapping, { noremap = mapping.noremap, silent = true })
		end
	end
end

local foreach_float = function(cb)
	for name, float in pairs(state.floats) do
		cb(name, float)
	end
end

local function create_floating_window(config, enter)
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

	local buf = vim.api.nvim_create_buf(false, true) -- No file, scratch buffer
	local win = vim.api.nvim_open_win(buf, enter or false, config)

	return { buf = buf, win = win }
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

M.setup = function()
	-- nothing
end

M.open_rfc = function()
	store_original_mappings()

	local window_config = create_window_configurations()

	state.floats.list = create_floating_window(window_config.view, true)
	state.floats.view = create_floating_window(window_config.view, true)
	state.floats.search = create_floating_window(window_config.view, true)
	state.floats.search_header = create_floating_window(window_config.search, true)

	state.curr_float = state.floats.list
	state.curr_float.type = "list"
	state.curr_header = nil

	foreach_float(function(_, float)
		vim.bo[float.buf].filetype = "markdown"
	end)

	vim.keymap.set("n", "m", function()
		vim.api.nvim_win_set_config(state.curr_float.win, { zindex = 1 })
		if state.curr_header ~= nil then
			vim.api.nvim_win_set_config(state.curr_header.win, { zindex = 1 })
		end

		vim.api.nvim_win_set_config(state.floats.view.win, { zindex = 2 })
		vim.api.nvim_set_current_win(state.floats.view.win)
		state.curr_float = state.floats.view
		state.curr_float.type = "view"
		state.curr_header = nil

		vim.api.nvim_buf_set_lines(state.curr_float.buf, 1, -1, false, { "nothing to view" })
	end, {
		noremap = true, -- Non-recursive
		silent = true, -- No command echo
	})

	vim.keymap.set("n", "n", function()
		vim.api.nvim_win_set_config(state.curr_float.win, { zindex = 1 })
		if state.curr_header ~= nil then
			vim.api.nvim_win_set_config(state.curr_header.win, { zindex = 1 })
		end

		vim.api.nvim_win_set_config(state.floats.list.win, { zindex = 2 })
		vim.api.nvim_set_current_win(state.floats.list.win)
		state.curr_float = state.floats.list
		state.curr_float.type = "list"
		state.curr_header = nil

		if #data.list_data == 0 then
			data.list_data = run_go_plugin("list", "")
		else
			vim.api.nvim_buf_set_lines(state.curr_float.buf, 1, -1, false, data.list_data)
		end

		vim.api.nvim_buf_set_lines(state.curr_float.buf, 1, -1, false, data.list_data)
	end, {
		noremap = true, -- Non-recursive
		silent = true, -- No command echo
	})

	vim.keymap.set("n", "b", function()
		vim.api.nvim_win_set_config(state.curr_float.win, { zindex = 1 })
		if state.curr_header ~= nil then
			vim.api.nvim_win_set_config(state.curr_header.win, { zindex = 1 })
		end

		vim.api.nvim_win_set_config(state.floats.search.win, { zindex = 2 })
		vim.api.nvim_win_set_config(state.floats.search_header.win, { zindex = 2 })
		vim.api.nvim_set_current_win(state.floats.search.win)
		state.curr_float = state.floats.search
		state.curr_float.type = "search"
		state.curr_header = state.floats.search_header

		if #data.search_data == 0 then
			vim.api.nvim_buf_set_lines(state.curr_float.buf, 1, -1, false, { "empty search" })
		else
			vim.api.nvim_buf_set_lines(state.curr_float.buf, 1, -1, false, data.search_data)
		end
	end, {
		noremap = true, -- Non-recursive
		silent = true, -- No command echo
	})

	vim.keymap.set("n", "v", function()
		vim.api.nvim_win_set_config(state.curr_float.win, { zindex = 1 })
		if state.curr_header ~= nil then
			vim.api.nvim_win_set_config(state.curr_header.win, { zindex = 1 })
		end

		vim.api.nvim_win_set_config(state.floats.search_header.win, { zindex = 2 })
		vim.api.nvim_set_current_win(state.floats.search_header.win)
		state.curr_header = state.floats.search_header

		watch_buffer_changes(state.curr_header.buf, function(buf)
			local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
			print("tyeee ", state.curr_float.type)
			if state.curr_float.type == "list" then
				data.list_data = run_go_plugin("list", table.concat(lines))
				vim.api.nvim_buf_set_lines(state.curr_float.buf, 1, -1, false, data.list_data)
			elseif state.curr_float.type == "search" then
				print("search")
				data.search_data = run_go_plugin("rfc", table.concat(lines))
				print("search ", table.concat(lines))
				print("search ", table.concat(data.search_data))
				vim.api.nvim_buf_set_lines(state.curr_float.buf, 1, -1, false, data.search_data)
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
end

M.close_rfc = function()
	restore_original_mappings()

	foreach_float(function(_, float)
		if float.win and vim.api.nvim_win_is_valid(float.win) then
			vim.api.nvim_win_close(float.win, { force = true })
		end
		if float.buf and vim.api.nvim_buf_is_valid(float.buf) then
			vim.api.nvim_buf_delete(float.buf, { force = true })
		end
	end)
end

return M
