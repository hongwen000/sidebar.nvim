local utils = require("sidebar-nvim.utils")
local Loclist = require("sidebar-nvim.components.loclist")
local config = require("sidebar-nvim.config")
local luv = vim.loop

-- Extend default configuration
if not config.search then
    config.search = {
        icon = "🔍",
        case_sensitive = false,
        use_regex = true,
        whole_word = false,
        include_pattern = "",
        exclude_pattern = "",
        max_history = 10,          -- Number of search history entries
        backup_files = true,       -- Backup files before replacement
        preview_context_lines = 3, -- Number of context lines in preview
        max_results = 1000,        -- Maximum number of results limit
    }
end

-- Initialize location list
local loclist = Loclist:new({
    show_group_count = true,
    show_empty_groups = false,
    omit_single_group = false,
})

-- SearchState class: Manages search-related state
local SearchState = {}

function SearchState:new()
    local state = {
        query = "",
        replace_text = "",
        include_pattern = config.search.include_pattern or "",
        exclude_pattern = config.search.exclude_pattern or "",
        case_sensitive = config.search.case_sensitive or false,
        use_regex = config.search.use_regex or true,
        whole_word = config.search.whole_word or false,
        searching = false,
        results = {},
        input_mode = "search",
        history = {},
        preview_buf = nil,
        preview_win = nil,
        search_handle = nil,
        timer = nil,
    }
    
    setmetatable(state, self)
    self.__index = self
    return state
end

function SearchState:set_query(query)
    if query == "" or query == self.query then return end
    
    self.query = query
    self:add_to_history(query)
end

function SearchState:add_to_history(query)
    if query == "" then return end
    
    -- Avoid duplicates
    for i, item in ipairs(self.history) do
        if item == query then
            table.remove(self.history, i)
            break
        end
    end
    
    -- Add to the beginning of history
    table.insert(self.history, 1, query)
    
    -- Limit history size
    if #self.history > config.search.max_history then
        table.remove(self.history)
    end
end

function SearchState:toggle_setting(setting)
    if self[setting] ~= nil and type(self[setting]) == "boolean" then
        self[setting] = not self[setting]
        return true
    end
    return false
end

function SearchState:cancel_search()
    if self.searching and self.search_handle and not self.search_handle:is_closing() then
        self.search_handle:kill(15)  -- SIGTERM
        self.searching = false
        
        if self.timer then
            self.timer:stop()
            self.timer:close()
            self.timer = nil
        end
        
        vim.schedule(function()
            utils.echo_warning("Search cancelled")
        end)
        return true
    end
    return false
end

function SearchState:clear_preview()
    if self.preview_win and vim.api.nvim_win_is_valid(self.preview_win) then
        vim.api.nvim_win_close(self.preview_win, true)
        self.preview_win = nil
    end
    
    if self.preview_buf and vim.api.nvim_buf_is_valid(self.preview_buf) then
        vim.api.nvim_buf_delete(self.preview_buf, { force = true })
        self.preview_buf = nil
    end
end

-- Create search state instance
local state = SearchState:new()

-- UI icon definitions
local icons = {
    case_sensitive = { on = "Aa", off = "aa" },
    word = { on = "\\b", off = "ab" },
    regex = { on = ".*", off = "\\*" },
    check = { on = "■", off = "□" },
    search = "🔍",
    replace = "🔄",
    include = "📂",
    exclude = "🚫",
    history = "📜",
    preview = "👁️",
    close = "✖",
}

-- File backup function
local function backup_file(filepath)
    if not config.search.backup_files then
        return true
    end
    
    local backup_path = filepath .. ".bak"
    local cmd
    
    if vim.fn.has("win32") == 1 then
        cmd = string.format('copy "%s" "%s"', filepath:gsub("/", "\\"), backup_path:gsub("/", "\\"))
    else
        cmd = string.format('cp "%s" "%s"', filepath, backup_path)
    end
    
    local result = vim.fn.system(cmd)
    
    if vim.v.shell_error ~= 0 then
        vim.schedule(function()
            utils.echo_warning("Failed to backup file " .. filepath .. ": " .. result)
        end)
        return false
    end
    
    return true
end

-- Highlight match results
local function highlight_match(text, pattern, is_regex, case_sensitive)
    if not is_regex then
        pattern = vim.pesc(pattern)
    end
    
    local flags = case_sensitive and "" or "i"
    
    local ok, start_pos, end_pos = pcall(function()
        return text:find(pattern, 1, false, flags)
    end)
    
    if not ok or not start_pos then
        return nil
    end
    
    return start_pos, end_pos
end

-- Process search results and update location list
local function process_search_results(results)
    local items = {}
    loclist:clear()
    
    if not results or #results == 0 then
        return
    end
    
    -- Group results by file
    local files = {}
    for _, match in ipairs(results) do
        local filepath = match.filepath
        if not files[filepath] then
            files[filepath] = {}
            loclist:add_group(filepath)
        end
        table.insert(files[filepath], match)
    end
    
    -- Add items to location list
    for filepath, matches in pairs(files) do
        for _, match in ipairs(matches) do
            local line_text = match.line_text:gsub("\t", "    ") -- Replace tabs with spaces
            local start_pos, end_pos
            
            -- Try to highlight matching text
            if state.query ~= "" then
                start_pos, end_pos = highlight_match(
                    line_text, 
                    state.query, 
                    state.use_regex, 
                    state.case_sensitive
                )
            end
            
            if start_pos and end_pos then
                -- Add item with highlighting
                table.insert(items, {
                    group = match.filepath,
                    left = {
                        { text = match.line_num .. ": ", hl = "SidebarNvimLineNr" },
                        { text = line_text:sub(1, start_pos - 1) },
                        { text = line_text:sub(start_pos, end_pos), hl = "SidebarNvimSearchMatch" },
                        { text = line_text:sub(end_pos + 1) },
                    },
                    filepath = match.filepath,
                    line_num = match.line_num,
                    col = match.col,
                    context = match.context or {},
                })
            else
                -- Fallback to normal display
                table.insert(items, {
                    group = match.filepath,
                    left = {
                        { text = match.line_num .. ": ", hl = "SidebarNvimLineNr" },
                        { text = line_text },
                    },
                    filepath = match.filepath,
                    line_num = match.line_num,
                    col = match.col,
                    context = match.context or {},
                })
            end
        end
    end
    
    loclist:set_items(items, { remove_groups = false })
end

-- Execute search
local function execute_search()
    if state.query == "" or state.searching then
        return
    end
    
    -- Cancel ongoing search
    state:cancel_search()
    
    state.searching = true
    local results = {}
    local stdout = luv.new_pipe(false)
    local stderr = luv.new_pipe(false)
    
    local cmd = "rg"
    local args = {}
    
    if vim.fn.executable("rg") == 1 then
        cmd = "rg"
        args = {
            "--line-number",
            "--column",
            "--no-heading",
            "--color", "never",
            "--max-count", tostring(config.search.max_results),
        }
        
        if not state.case_sensitive then
            table.insert(args, "--ignore-case")
        end
        
        if state.whole_word then
            table.insert(args, "--word-regexp")
        end
        
        if not state.use_regex then
            table.insert(args, "--fixed-strings")
        end
        
        if state.include_pattern ~= "" then
            for _, pattern in ipairs(vim.split(state.include_pattern, ",")) do
                pattern = vim.trim(pattern)
                if pattern ~= "" then
                    table.insert(args, "--glob")
                    table.insert(args, pattern)
                end
            end
        end
        
        if state.exclude_pattern ~= "" then
            for _, pattern in ipairs(vim.split(state.exclude_pattern, ",")) do
                pattern = vim.trim(pattern)
                if pattern ~= "" then
                    table.insert(args, "--glob")
                    table.insert(args, "!" .. pattern)
                end
            end
        end
        
        table.insert(args, "--context")
        table.insert(args, tostring(config.search.preview_context_lines))
        
        table.insert(args, state.query)
    else
        -- Fallback to grep if ripgrep is not available
        cmd = "grep"
        args = {
            "-n", -- Line number
            "-H", -- Print filename
            "--color=never",
        }
        
        if not state.case_sensitive then
            table.insert(args, "-i")
        end
        
        if state.whole_word then
            table.insert(args, "-w")
        end
        
        if not state.use_regex then
            table.insert(args, "-F")
        end
        
        table.insert(args, state.query)
        
        if state.include_pattern ~= "" then
            table.insert(args, state.include_pattern)
        else
            table.insert(args, "*")
        end
    end
    
    -- Create progress timer
    state.timer = luv.new_timer()
    state.timer:start(100, 100, vim.schedule_wrap(function()
        if state.searching then
            utils.echo_info(string.format("Searching... Found %d results", #results))
        end
    end))
    
    state.search_handle = luv.spawn(cmd, {
        args = args,
        stdio = { nil, stdout, stderr },
        cwd = luv.cwd(),
    }, function()
        state.searching = false
        
        if state.timer then
            state.timer:stop()
            state.timer:close()
            state.timer = nil
        end
        
        vim.schedule(function()
            process_search_results(results)
            utils.echo_info(string.format("Found %d matches in %d files", 
                #results,
                vim.tbl_count(loclist:get_groups())
            ))
        end)
        
        luv.read_stop(stdout)
        luv.read_stop(stderr)
        stdout:close()
        stderr:close()
        state.search_handle:close()
    end)
    
    -- Process ripgrep output with context
    local current_file = nil
    local current_matches = {}
    local context_lines = {}
    
    luv.read_start(stdout, function(err, data)
        if data == nil then return end
        
        for _, line in ipairs(vim.split(data, "\n")) do
            if line ~= "" then
                -- Parse ripgrep output format
                local file_sep = line:match("^(.+)%-%-$")
                
                if file_sep then
                    -- File separator, save previous context and reset
                    if current_file and #current_matches > 0 then
                        for _, match in ipairs(current_matches) do
                            match.context = context_lines
                        end
                        vim.list_extend(results, current_matches)
                    end
                    
                    current_file = nil
                    current_matches = {}
                    context_lines = {}
                elseif line:match("^%d+%[") then
                    -- Context line (non-match)
                    local line_num, content = line:match("^(%d+)%[.-%](.*)$")
                    if line_num and content then
                        table.insert(context_lines, {
                            line_num = tonumber(line_num),
                            content = content,
                            is_match = false
                        })
                    end
                elseif line:match("^%d+:") then
                    -- Match line
                    local filepath, line_num, col, line_text = line:match("^(.+):(%d+):(%d+):(.*)$")
                    
                    if filepath and line_num and col and line_text then
                        if current_file ~= filepath then
                            -- Found new file
                            if current_file and #current_matches > 0 then
                                for _, match in ipairs(current_matches) do
                                    match.context = context_lines
                                end
                                vim.list_extend(results, current_matches)
                            end
                            
                            current_file = filepath
                            current_matches = {}
                            context_lines = {}
                        end
                        
                        -- Add to context lines
                        table.insert(context_lines, {
                            line_num = tonumber(line_num),
                            content = line_text,
                            is_match = true
                        })
                        
                        -- Add to match items
                        table.insert(current_matches, {
                            filepath = filepath,
                            line_num = tonumber(line_num),
                            col = tonumber(col),
                            line_text = line_text,
                        })
                    end
                end
            end
        end
        
        if err ~= nil then
            vim.schedule(function()
                utils.echo_warning(err)
            end)
        end
    end)
    
    luv.read_start(stderr, function(err, data)
        if data == nil then return end
        
        if err ~= nil or data:match("error") then
            vim.schedule(function()
                utils.echo_warning("Search error: " .. (data or err))
            end)
        end
    end)
    
    -- Add to history
    state:add_to_history(state.query)
end

-- Execute replace operation
local function execute_replace()
    if state.query == "" or state.replace_text == "" then
        utils.echo_warning("Search query and replacement text cannot be empty")
        return
    end
    
    local locations = loclist:get_all_locations()
    if #locations == 0 then
        utils.echo_warning("No search results to replace")
        return
    end
    
    -- Collect unique files
    local files_to_replace = {}
    for _, location in ipairs(locations) do
        files_to_replace[location.filepath] = true
    end
    
    -- Confirm before replacement
    local file_count = vim.tbl_count(files_to_replace)
    local confirm = vim.fn.confirm(
        string.format("Replace '%s' with '%s' in %d files?", 
            state.query, state.replace_text, file_count),
        "&Confirm\n&Cancel\n&Preview", 
        2
    )
    
    if confirm ~= 1 then
        if confirm == 3 then
            -- Show preview of changes
            preview_replace(files_to_replace)
        end
        return
    end
    
    -- Backup files first
    local all_backed_up = true
    for filepath in pairs(files_to_replace) do
        if not backup_file(filepath) then
            all_backed_up = false
            break
        end
    end
    
    if not all_backed_up then
        local continue = vim.fn.confirm(
            "Some files could not be backed up. Continue anyway?",
            "&Continue\n&Cancel",
            2
        )
        if continue ~= 1 then
            return
        end
    end
    
    -- Execute the replacement
    local success_count = 0
    local failure_count = 0
    
    for filepath in pairs(files_to_replace) do
        local sed_cmd = "sed"
        local sed_args = {}
        
        if vim.fn.has("win32") == 1 then
            -- Use PowerShell for replacements on Windows
            sed_cmd = "powershell"
            local search_pattern = state.query
            if not state.use_regex then
                -- Escape special characters if not using regex
                search_pattern = search_pattern:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "\\%1")
            end
            
            sed_args = {
                "-Command",
                "(Get-Content '" .. filepath .. "') | ForEach-Object { $_ -replace '" .. 
                search_pattern .. "', '" .. state.replace_text .. "' } | Set-Content '" .. filepath .. "'"
            }
        else
            -- Unix systems
            local flags = "g"  -- Global replacement
            if not state.case_sensitive then
                flags = flags .. "i"  -- Case insensitive
            end
            
            sed_args = {
                "-i",
                "s/" .. state.query .. "/" .. state.replace_text .. "/" .. flags,
                filepath
            }
        end
        
        local result = vim.fn.system(sed_cmd .. " " .. table.concat(sed_args, " "))
        if vim.v.shell_error ~= 0 then
            utils.echo_warning("Error replacing in file " .. filepath .. ": " .. result)
            failure_count = failure_count + 1
        else
            success_count = success_count + 1
        end
    end
    
    -- Report results
    utils.echo_info(string.format(
        "Replaced '%s' with '%s' in %d/%d files%s", 
        state.query, 
        state.replace_text, 
        success_count,
        file_count,
        failure_count > 0 and " (" .. failure_count .. " failed)" or ""
    ))
    
    -- Run search again to update results
    execute_search()
end

-- Preview replacement
local function preview_replace(files_to_replace)
    -- Create preview buffer
    if not state.preview_buf or not vim.api.nvim_buf_is_valid(state.preview_buf) then
        state.preview_buf = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_option(state.preview_buf, "buftype", "nofile")
        vim.api.nvim_buf_set_option(state.preview_buf, "bufhidden", "wipe")
        vim.api.nvim_buf_set_option(state.preview_buf, "swapfile", false)
        vim.api.nvim_buf_set_option(state.preview_buf, "filetype", "diff")
    end
    
    -- Generate diff preview
    local preview_lines = {}
    table.insert(preview_lines, "Replacement Preview:")
    table.insert(preview_lines, "Search: " .. state.query)
    table.insert(preview_lines, "Replace: " .. state.replace_text)
    table.insert(preview_lines, string.rep("-", 40))
    
    for filepath in pairs(files_to_replace) do
        local file_content = {}
        
        -- Read file
        local file = io.open(filepath, "r")
        if file then
            for line in file:lines() do
                table.insert(file_content, line)
            end
            file:close()
            
            -- Preview changes
            table.insert(preview_lines, "File: " .. filepath)
            table.insert(preview_lines, "")
            
            for i, line in ipairs(file_content) do
                local start_pos, end_pos
                
                if state.use_regex then
                    -- Try to use regex to find matches
                    local ok, s, e = pcall(function()
                        return line:find(state.query)
                    end)
                    
                    if ok and s then
                        start_pos, end_pos = s, e
                    end
                else
                    -- Normal text search
                    start_pos, end_pos = line:find(state.query, 1, true)
                end
                
                if start_pos then
                    local new_line = line:sub(1, start_pos - 1) .. 
                                    state.replace_text .. 
                                    line:sub(end_pos + 1)
                    
                    table.insert(preview_lines, "- " .. line)
                    table.insert(preview_lines, "+ " .. new_line)
                    table.insert(preview_lines, "")
                end
            end
            
            table.insert(preview_lines, string.rep("-", 40))
        end
    end
    
    -- Set buffer content
    vim.api.nvim_buf_set_lines(state.preview_buf, 0, -1, false, preview_lines)
    
    -- Create window
    if not state.preview_win or not vim.api.nvim_win_is_valid(state.preview_win) then
        vim.cmd("botright split")
        state.preview_win = vim.api.nvim_get_current_win()
        vim.api.nvim_win_set_buf(state.preview_win, state.preview_buf)
        vim.api.nvim_win_set_height(state.preview_win, 15)
        
        -- Add mapping to close preview
        vim.api.nvim_buf_set_keymap(
            state.preview_buf, 
            "n", 
            "q", 
            "<cmd>lua require('sidebar-nvim.builtin.search').close_preview()<CR>", 
            { noremap = true, silent = true }
        )
    end
end

-- Browse and select search history
local function browse_history()
    if #state.history == 0 then
        utils.echo_warning("No search history")
        return
    end
    
    vim.ui.select(state.history, {
        prompt = "Select from search history:",
        format_item = function(item) return item end,
    }, function(choice)
        if not choice then return end
        
        state.query = choice
        execute_search()
    end)
end

-- Show file preview
local function show_preview(location)
    if not location or not location.filepath then
        return
    end
    
    -- Clear existing preview
    state:clear_preview()
    
    -- Create preview buffer
    state.preview_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_option(state.preview_buf, "buftype", "nofile")
    vim.api.nvim_buf_set_option(state.preview_buf, "bufhidden", "wipe")
    vim.api.nvim_buf_set_option(state.preview_buf, "swapfile", false)
    vim.api.nvim_buf_set_name(state.preview_buf, "Preview: " .. location.filepath)
    
    -- Read file content
    local file_content = {}
    local file = io.open(location.filepath, "r")
    if file then
        for line in file:lines() do
            table.insert(file_content, line)
        end
        file:close()
        
        -- Set buffer content
        vim.api.nvim_buf_set_lines(state.preview_buf, 0, -1, false, file_content)
        
        -- Set syntax highlighting based on file type
        local ft = vim.filetype.match({ filename = location.filepath })
        if ft then
            vim.api.nvim_buf_set_option(state.preview_buf, "filetype", ft)
        end
        
        -- Create preview window
        vim.cmd("botright split")
        state.preview_win = vim.api.nvim_get_current_win()
        vim.api.nvim_win_set_buf(state.preview_win, state.preview_buf)
        vim.api.nvim_win_set_height(state.preview_win, 10)
        
        -- Jump to matching line
        vim.api.nvim_win_set_cursor(state.preview_win, {location.line_num, location.col - 1})
        
        -- Center view on matching line
        vim.cmd("normal! zz")
        
        -- Highlight search term
        if state.query ~= "" then
            vim.fn.matchadd("Search", state.use_regex and state.query or vim.fn.escape(state.query, "\\.*^$[]"))
        end
        
        -- Add mapping to close preview
        vim.api.nvim_buf_set_keymap(
            state.preview_buf, 
            "n", 
            "q", 
            "<cmd>lua require('sidebar-nvim.builtin.search').close_preview()<CR>", 
            { noremap = true, silent = true }
        )
    else
        utils.echo_warning("Could not open file: " .. location.filepath)
    end
end

-- Handle search field input
local function handle_input(field)
    local prompt_prefix = ""
    local current_value = ""
    
    if field == "search" then
        prompt_prefix = "Search: "
        current_value = state.query
    elseif field == "replace" then
        prompt_prefix = "Replace: "
        current_value = state.replace_text
    elseif field == "include" then
        prompt_prefix = "Include pattern: "
        current_value = state.include_pattern
    elseif field == "exclude" then
        prompt_prefix = "Exclude pattern: "
        current_value = state.exclude_pattern
    end
    
    -- Switch to normal window for input
    vim.cmd("wincmd p")
    
    local completion = ""
    if field == "include" or field == "exclude" then
        completion = "file"
    end
    
    local new_value = vim.fn.input({
        prompt = prompt_prefix,
        default = current_value,
        completion = completion,
    })
    
    -- Switch back to sidebar
    vim.cmd("wincmd p")
    
    if field == "search" then
        if new_value ~= state.query then
            state.query = new_value
            if state.query ~= "" then
                execute_search()
            end
        end
    elseif field == "replace" then
        state.replace_text = new_value
    elseif field == "include" then
        state.include_pattern = new_value
    elseif field == "exclude" then
        state.exclude_pattern = new_value
    end
    
    state.input_mode = field
end

-- Draw search form
local function draw_search_form(ctx)
    local lines = {}
    local hl = {}
    local width = ctx.width - 2
    
    -- Search input field
    local search_prefix = " " .. icons.search .. " Search : "
    local search_display = state.query
    if search_display == "" then
        search_display = "__________________"
    end
    local search_line = search_prefix .. search_display
    
    table.insert(lines, search_line)
    
    if state.input_mode == "search" then
        table.insert(hl, { "SidebarNvimSearchActive", #lines, #search_prefix, #search_prefix + #search_display })
    else
        table.insert(hl, { "SidebarNvimSearch", #lines, #search_prefix, #search_prefix + #search_display })
    end
    
    -- Add case, regex, word toggle buttons
    local toggle_offset = width - 12
    -- Case sensitive
    local case_icon = state.case_sensitive and icons.case_sensitive.on or icons.case_sensitive.off
    table.insert(hl, { "SidebarNvimSearchToggle", #lines, toggle_offset, toggle_offset + 2 })
    lines[#lines] = lines[#lines] .. string.rep(" ", toggle_offset - #lines[#lines]) .. case_icon
    
    -- Word boundary
    local word_icon = state.whole_word and icons.word.on or icons.word.off
    table.insert(hl, { "SidebarNvimSearchToggle", #lines, toggle_offset + 3, toggle_offset + 5 })
    lines[#lines] = lines[#lines] .. " " .. word_icon
    
    -- Regex toggle
    local regex_icon = state.use_regex and icons.regex.on or icons.regex.off
    table.insert(hl, { "SidebarNvimSearchToggle", #lines, toggle_offset + 6, toggle_offset + 8 })
    lines[#lines] = lines[#lines] .. " " .. regex_icon
    
    -- History button
    table.insert(hl, { "SidebarNvimSearchButton", #lines, toggle_offset + 9, toggle_offset + 10 })
    lines[#lines] = lines[#lines] .. " " .. icons.history
    
    -- Replace input field
    local replace_prefix = " " .. icons.replace .. " Replace : "
    local replace_display = state.replace_text
    if replace_display == "" then
        replace_display = "__________________"
    end
    local replace_line = replace_prefix .. replace_display
    
    table.insert(lines, replace_line)
    
    if state.input_mode == "replace" then
        table.insert(hl, { "SidebarNvimSearchActive", #lines, #replace_prefix, #replace_prefix + #replace_display })
    else
        table.insert(hl, { "SidebarNvimSearch", #lines, #replace_prefix, #replace_prefix + #replace_display })
    end
    
    -- Replace button
    table.insert(hl, { "SidebarNvimSearchButton", #lines, width - 2, width })
    lines[#lines] = lines[#lines] .. string.rep(" ", width - #lines[#lines] - 2) .. " R"
    
    -- Include pattern field
    local include_prefix = " " .. icons.include .. " Include : "
    local include_display = state.include_pattern
    if include_display == "" then
        include_display = "*.{js,ts,lua}"
    end
    local include_line = include_prefix .. include_display
    
    table.insert(lines, include_line)
    
    if state.input_mode == "include" then
        table.insert(hl, { "SidebarNvimSearchActive", #lines, #include_prefix, #include_prefix + #include_display })
    else
        table.insert(hl, { "SidebarNvimSearch", #lines, #include_prefix, #include_prefix + #include_display })
    end
    
    -- Preview icon
    table.insert(hl, { "SidebarNvimSearchButton", #lines, width - 2, width })
    lines[#lines] = lines[#lines] .. string.rep(" ", width - #lines[#lines] - 2) .. " " .. icons.preview
    
    -- Exclude pattern field
    local exclude_prefix = " " .. icons.exclude .. " Exclude : "
    local exclude_display = state.exclude_pattern
    if exclude_display == "" then
        exclude_display = "node_modules,dist"
    end
    local exclude_line = exclude_prefix .. exclude_display
    
    table.insert(lines, exclude_line)
    
    if state.input_mode == "exclude" then
        table.insert(hl, { "SidebarNvimSearchActive", #lines, #exclude_prefix, #exclude_prefix + #exclude_display })
    else
        table.insert(hl, { "SidebarNvimSearch", #lines, #exclude_prefix, #exclude_prefix + #exclude_display })
    end
    
    -- Settings icon
    table.insert(hl, { "SidebarNvimSearchButton", #lines, width - 2, width })
    lines[#lines] = lines[#lines] .. string.rep(" ", width - #lines[#lines] - 2) .. " ⚙"
    
    -- Status line
    local status_line = string.rep("─", width)
    if state.searching then
        status_line = " 🔄 Searching... "
        table.insert(hl, { "SidebarNvimSearchProgress", #lines + 1, 0, #status_line })
    end
    table.insert(lines, status_line)
    
    return lines, hl
end

-- Export module functions
local M = {
    close_preview = function()
        state:clear_preview() 
    end,
}

-- Return sidebar section definition
M.section = {
    title = "Search",
    icon = config.search.icon,
    draw = function(ctx)
        local form_lines, form_hl = draw_search_form(ctx)
        
        -- Draw search results
        local result_lines = {}
        local result_hl = {}
        
        loclist:draw(ctx, result_lines, result_hl)
        
        -- Merge form and results
        local lines = {}
        local hl = {}
        
        vim.list_extend(lines, form_lines)
        for _, highlight in ipairs(form_hl) do
            table.insert(hl, highlight)
        end
        
        vim.list_extend(lines, result_lines)
        for _, highlight in ipairs(result_hl) do
            -- Adjust highlight line numbers to accommodate form lines
            highlight[2] = highlight[2] + #form_lines
            table.insert(hl, highlight)
        end
        
        if #result_lines == 0 and state.query ~= "" then
            if state.searching then
                table.insert(lines, " Searching...")
                table.insert(hl, { "SidebarNvimSearchProgress", #lines, 0, 12 })
            else
                table.insert(lines, " No results found")
                table.insert(hl, { "SidebarNvimComment", #lines, 0, 16 })
            end
        end
        
        return { lines = lines, hl = hl }
    end,
    
    highlights = {
        groups = {
            SidebarNvimSearch = { fg = "#CCCCCC" },
            SidebarNvimSearchActive = { fg = "#FFFFFF", bg = "#264F78" },
            SidebarNvimSearchButton = { fg = "#00AAFF" },
            SidebarNvimSearchToggle = { fg = "#DDDDDD" },
            SidebarNvimSearchMatch = { fg = "#FFFF00", bold = true },
            SidebarNvimSearchProgress = { fg = "#88FF88" },
            SidebarNvimComment = { fg = "#888888" },
        },
        links = {},
    },
    
    bindings = {
        -- Form field navigation
        ["<Tab>"] = function()
            if state.input_mode == "search" then
                state.input_mode = "replace"
            elseif state.input_mode == "replace" then
                state.input_mode = "include"
            elseif state.input_mode == "include" then
                state.input_mode = "exclude"
            else
                state.input_mode = "search"
            end
        end,
        
        ["<S-Tab>"] = function()
            if state.input_mode == "search" then
                state.input_mode = "exclude"
            elseif state.input_mode == "replace" then
                state.input_mode = "search"
            elseif state.input_mode == "include" then
                state.input_mode = "replace"
            else
                state.input_mode = "include"
            end
        end,
        
        -- Edit search field
        ["s"] = function()
            handle_input("search")
        end,
        
        -- Edit replace field
        ["r"] = function()
            handle_input("replace")
        end,
        
        -- Edit include pattern
        ["i"] = function()
            handle_input("include") 
        end,
        
        -- Edit exclude pattern
        ["x"] = function()
            handle_input("exclude")
        end,
        
        -- Access search history
        ["h"] = function()
            browse_history()
        end,
        
        -- Cancel ongoing search
        ["<C-c>"] = function()
            state:cancel_search()
        end,
        
        -- Toggle case sensitivity
        ["c"] = function()
            state:toggle_setting("case_sensitive")
        end,
        
        -- Toggle regex mode
        ["."] = function()
            state:toggle_setting("use_regex") 
        end,
        
        -- Toggle whole word match
        ["w"] = function()
            state:toggle_setting("whole_word")
        end,
        
        -- Execute search
        ["<CR>"] = function(line)
            if line <= 4 then
                -- In form input section
                if line == 1 then
                    handle_input("search")
                elseif line == 2 then
                    handle_input("replace")
                elseif line == 3 then
                    handle_input("include")
                elseif line == 4 then
                    handle_input("exclude")
                end
            else
                -- In results section, open file
                local location = loclist:get_location_at(line - 5)  -- Form offset
                if location then
                    vim.cmd("wincmd p")
                    vim.cmd("e " .. location.filepath)
                    vim.fn.cursor(location.line_num, location.col)
                end
            end
        end,
        
        -- Preview file without opening
        ["p"] = function(line)
            if line <= 5 then return end  -- Skip form inputs
            
            local location = loclist:get_location_at(line - 5)  -- Form offset
            if location then
                show_preview(location)
            end
        end,
        
        -- Open file at location
        ["e"] = function(line)
            if line <= 5 then return end  -- Skip form inputs
            
            local location = loclist:get_location_at(line - 5)  -- Form offset
            if location then
                vim.cmd("wincmd p")
                vim.cmd("e " .. location.filepath)
                vim.fn.cursor(location.line_num, location.col)
            end
        end,
        
        -- Execute replacement
        ["R"] = function()
            execute_replace()
        end,
        
        -- Toggle result groups
        ["t"] = function(line)
            if line <= 5 then return end  -- Skip form inputs
            loclist:toggle_group_at(line - 5)  -- Form offset
        end,
        
        -- Close preview window
        ["q"] = function()
            state:clear_preview()
        end,
    },
    
    setup = function(ctx)
        -- Register exported functions
        M.execute_search = execute_search
        M.execute_replace = execute_replace
        M.browse_history = browse_history
        M.show_preview = show_preview
        
        -- Initial setup
        vim.api.nvim_set_hl(0, "SidebarNvimSearchMatch", { fg = "#FFFF00", bold = true })
    end,
    
    update = function(ctx)
        -- Update if search query has changed
        if state.query ~= "" and not state.searching then
            execute_search()
        end
    end,
}

return M